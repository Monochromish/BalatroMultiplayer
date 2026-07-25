-- Code for networking stuff that runs in a separate thread

-- Since threads run on a separate lua environment, we need to require
-- the necessary modules again
return [[
local CONFIG_URL, CONFIG_PORT = ...

require("love.filesystem")
local json = require("json")
local socket = require("socket")

local DEBUGGING = false

-- Defining this again, for debugging this thread
local function initializeThreadDebugSocketConnection()
	CLIENT = socket.connect("localhost", 12346)
	if not CLIENT then
		sendWarnMessage("Failed to connect to the debug server", "MULTIPLAYER")
	end
end

function SEND_THREAD_DEBUG_MESSAGE(message)
	if DEBUGGING and CLIENT and message then
		CLIENT:send(message .. "\n")
	end
end

if DEBUGGING then
	initializeThreadDebugSocketConnection()
end

Networking = {}
local networkToUiChannel = love.thread.getChannel("networkToUi")
local uiToNetworkChannel = love.thread.getChannel("uiToNetwork")

-- Worst case detection is KEEPALIVE_IDLE + KEEPALIVE_PROBES * KEEPALIVE_PROBE,
-- plus CONNECT_TIMEOUT before the first reattempt lands: 24s. That has to stay
-- comfortably under the server's lobby grace period (60s, per enemyDisconnected).
local TICK = 0.05
local CONNECT_TIMEOUT = 5
local KEEPALIVE_IDLE = 10
local KEEPALIVE_PROBE = 3
local KEEPALIVE_PROBES = 3
local RECONNECT_DELAYS = { 0, 1, 2, 3, 5, 8, 10 } -- last value repeats forever
local RECONNECT_NOTIFY_AFTER = 120
local RECV_BUFFER_MAX = 8 * 1024 * 1024

local STATE_IDLE = "idle"
local STATE_CONNECTED = "connected"
local STATE_RETRYING = "retrying"

local state = STATE_IDLE
local retryIndex = 0
local retryAt = 0
local outageStartedAt = nil
local notifiedGaveUp = false

local sendQueue = {}
local sendHead = 1
local sendOffset = 0 -- bytes of sendQueue[sendHead] already written

-- receive("*l") returns nil, "timeout", partial when a line straddles two reads,
-- and the partial is already consumed from the socket. It has to be fed back as
-- the prefix argument or the front of the message is gone.
local recvBuffer = ""

local lastRecvAt = 0
local probesSent = 0
local nextProbeAt = nil

local function now()
	return socket.gettime()
end

local function resetSendQueue()
	sendQueue = {}
	sendHead = 1
	sendOffset = 0
end

local function enqueue(msg)
	sendQueue[#sendQueue + 1] = msg .. "\n"
end

local function retryDelay(index)
	local last = #RECONNECT_DELAYS
	if index < 1 then index = 1 end
	if index > last then index = last end
	return RECONNECT_DELAYS[index]
end

function Networking.closeSocket()
	if Networking.Client then
		pcall(function()
			Networking.Client:close()
		end)
	end
	Networking.Client = nil
	recvBuffer = ""
	resetSendQueue()
end

-- Safe to call repeatedly; only the first call of an outage notifies the UI.
local function markDisconnected()
	local wasConnected = state == STATE_CONNECTED
	Networking.closeSocket()
	state = STATE_RETRYING
	retryIndex = 0
	retryAt = now()
	probesSent = 0
	nextProbeAt = nil

	if not outageStartedAt then
		outageStartedAt = now()
		notifiedGaveUp = false
	end

	if wasConnected then
		SEND_THREAD_DEBUG_MESSAGE("Connection lost, retrying...")
		networkToUiChannel:push("{\"action\":\"reconnecting\"}")
	end
end

-- announceFailure only for a user-initiated connect, so background retries do
-- not spam an error overlay.
function Networking.connect(announceFailure)
	SEND_THREAD_DEBUG_MESSAGE(
		string.format("Attempting to connect to multiplayer server... URL: %s, PORT: %d", CONFIG_URL, CONFIG_PORT)
	)

	Networking.closeSocket()

	local client = socket.tcp()
	if not client then
		SEND_THREAD_DEBUG_MESSAGE("socket.tcp() returned nil")
		return false
	end

	client:settimeout(CONNECT_TIMEOUT)
	local connectionResult, errorMessage = client:connect(CONFIG_URL, CONFIG_PORT)

	if connectionResult ~= 1 then
		SEND_THREAD_DEBUG_MESSAGE(string.format("%s", errorMessage or "connect failed"))
		pcall(function()
			client:close()
		end)
		if announceFailure then
			networkToUiChannel:push(json.encode({
				action = "error",
				message = "Failed to connect to multiplayer server",
			}))
		end
		return false
	end

	client:setoption("tcp-nodelay", true)
	client:settimeout(0)

	Networking.Client = client
	state = STATE_CONNECTED
	recvBuffer = ""
	resetSendQueue()
	lastRecvAt = now()
	probesSent = 0
	nextProbeAt = nil
	outageStartedAt = nil
	notifiedGaveUp = false
	retryIndex = 0

	SEND_THREAD_DEBUG_MESSAGE("Connected.")
	return true
end

-- Messages pushed while the link is down are discarded rather than queued: they
-- would land ahead of the rejoinLobby handshake. resync_after_rejoin re-states
-- what matters once we are back.
local function pumpOutbound()
	for _ = 1, 100 do
		local msg = uiToNetworkChannel:pop()
		if not msg then return end

		if msg == "{\"action\":\"connect\"}" then
			outageStartedAt = nil
			notifiedGaveUp = false
			if not Networking.connect(true) then
				state = STATE_RETRYING
				retryIndex = 0
				retryAt = now() + retryDelay(1)
				outageStartedAt = now()
			end
		elseif state == STATE_CONNECTED then
			enqueue(msg)
		end
	end
end

local function flushOutbound()
	if state ~= STATE_CONNECTED or not Networking.Client then return end

	while sendHead <= #sendQueue do
		local msg = sendQueue[sendHead]
		local sent, err, lastSent = Networking.Client:send(msg, sendOffset + 1)

		if sent then
			sendQueue[sendHead] = nil
			sendHead = sendHead + 1
			sendOffset = 0
		elseif err == "timeout" then
			-- Buffer full; resume from this byte next tick.
			if lastSent and lastSent > sendOffset then sendOffset = lastSent end
			return
		else
			SEND_THREAD_DEBUG_MESSAGE(string.format("send failed: %s", tostring(err)))
			markDisconnected()
			return
		end
	end

	resetSendQueue()
end

local function handleLine(data)
	lastRecvAt = now()
	probesSent = 0
	nextProbeAt = nil

	-- Answered here rather than via the UI thread to save a frame. Queued, not
	-- sent inline, so it cannot interleave with a partially-written message.
	if string.find(data, '"keepAlive"', 1, true) and not string.find(data, "Ack", 1, true) then
		enqueue('{"action":"keepAliveAck"}')
	end

	networkToUiChannel:push(data)
end

local function pumpInbound()
	if state ~= STATE_CONNECTED or not Networking.Client then return end

	for _ = 1, 100 do
		local data, err, partial = Networking.Client:receive("*l", recvBuffer)

		if data then
			recvBuffer = ""
			handleLine(data)
		elseif err == "timeout" then
			recvBuffer = partial or recvBuffer
			if #recvBuffer > RECV_BUFFER_MAX then
				SEND_THREAD_DEBUG_MESSAGE("Inbound buffer overflow, dropping connection")
				markDisconnected()
			end
			return
		else
			SEND_THREAD_DEBUG_MESSAGE(string.format("receive failed: %s", tostring(err)))
			markDisconnected()
			return
		end
	end
end

local function pumpKeepAlive()
	if state ~= STATE_CONNECTED then return end
	local t = now()

	if nextProbeAt then
		if t >= nextProbeAt then
			if probesSent >= KEEPALIVE_PROBES then
				SEND_THREAD_DEBUG_MESSAGE("Keepalive unanswered, dropping connection")
				markDisconnected()
			else
				enqueue('{"action":"keepAlive"}')
				probesSent = probesSent + 1
				nextProbeAt = t + KEEPALIVE_PROBE
			end
		end
	elseif t - lastRecvAt >= KEEPALIVE_IDLE then
		enqueue('{"action":"keepAlive"}')
		probesSent = 1
		nextProbeAt = t + KEEPALIVE_PROBE
	end
end

local function pumpReconnect()
	if state ~= STATE_RETRYING then return end
	local t = now()

	-- Tell the UI once, but keep retrying so the menu recovers on its own.
	if not notifiedGaveUp and outageStartedAt and (t - outageStartedAt) >= RECONNECT_NOTIFY_AFTER then
		notifiedGaveUp = true
		networkToUiChannel:push("{\"action\":\"disconnected\"}")
	end

	if t < retryAt then return end

	retryIndex = retryIndex + 1
	SEND_THREAD_DEBUG_MESSAGE(string.format("Reconnect attempt %d...", retryIndex))

	if not Networking.connect(false) then
		retryAt = now() + retryDelay(retryIndex + 1)
	end
end

-- Nothing here blocks for longer than one connect attempt, so a stalled link
-- cannot freeze the thread the way the old sleep-based backoff did.
while true do
	pumpOutbound()
	flushOutbound()
	pumpInbound()
	pumpKeepAlive()
	pumpReconnect()

	socket.sleep(TICK)
end
]]
