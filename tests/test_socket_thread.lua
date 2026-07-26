-- Drives the thread source in networking/socket.lua against a mock socket that
-- reproduces LuaSocket's partial-IO semantics: receive("*l") consumes the partial
-- it returns on timeout, and send() can accept only part of a payload.
--
-- Run with luajit, NOT lua: Balatro runs LuaJIT, and the two disagree on # for a
-- table with nil holes. A queue-drain bug that loses messages on LuaJIT passes
-- silently under Lua 5.4/5.5.
--
--   luajit tests/test_socket_thread.lua

local failures = 0
local checks = 0

local function check(ok, label, detail)
	checks = checks + 1
	if ok then
		print(string.format("  ok   %s", label))
	else
		failures = failures + 1
		print(string.format("  FAIL %s%s", label, detail and ("\n         " .. detail) or ""))
	end
end

local function eq(actual, expected, label)
	check(actual == expected, label, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

-- Mock socket, matching LuaSocket's documented contract.
local function new_mock_socket(harness)
	local sock = {
		inbox = "", -- bytes the "server" has made available to us
		sent = "", -- bytes we have accepted from the client
		closed = false,
		send_limit = math.huge, -- bytes accept()ed per send() call
	}

	function sock:settimeout() end
	function sock:setoption() end
	function sock:close()
		self.closed = true
	end

	function sock:connect()
		if harness.connect_should_fail then return nil, "connection refused" end
		return 1
	end

	-- On timeout: nil, "timeout", prefix..partial — and the partial is consumed.
	function sock:receive(_pattern, prefix)
		prefix = prefix or ""
		if self.closed then return nil, "closed" end
		local nl = self.inbox:find("\n", 1, true)
		if nl then
			local line = self.inbox:sub(1, nl - 1)
			self.inbox = self.inbox:sub(nl + 1)
			return prefix .. line
		end
		local partial = self.inbox
		self.inbox = ""
		return nil, "timeout", prefix .. partial
	end

	-- Returns the absolute index of the last byte written, or nil, "timeout",
	-- lastIndexWritten when the buffer fills.
	function sock:send(data, i)
		i = i or 1
		if self.closed then return nil, "closed" end
		local remaining = #data - i + 1
		local accepted = math.min(remaining, self.send_limit)
		self.sent = self.sent .. data:sub(i, i + accepted - 1)
		local last = i + accepted - 1
		if accepted < remaining then return nil, "timeout", last end
		return last
	end

	return sock
end

-- Harness: run the thread loop for a bounded number of ticks.
local function run_thread(opts)
	local harness = {
		clock = 0,
		ticks = 0,
		max_ticks = opts.max_ticks or 200,
		connect_should_fail = false,
		connect_attempts = 0,
		sockets = {},
	}

	local to_ui, to_net = {}, {}

	local channels = {
		networkToUi = {
			push = function(_, v)
				to_ui[#to_ui + 1] = v
			end,
			pop = function()
				return table.remove(to_ui, 1)
			end,
		},
		uiToNetwork = {
			push = function(_, v)
				to_net[#to_net + 1] = v
			end,
			pop = function()
				return table.remove(to_net, 1)
			end,
		},
	}

	local socket_lib = {
		gettime = function()
			return harness.clock
		end,
		sleep = function(t)
			harness.clock = harness.clock + t
			harness.ticks = harness.ticks + 1
			if opts.on_tick then opts.on_tick(harness) end
			if harness.ticks >= harness.max_ticks then error("__STOP__", 0) end
		end,
		tcp = function()
			harness.connect_attempts = harness.connect_attempts + 1
			local s = new_mock_socket(harness)
			harness.sockets[#harness.sockets + 1] = s
			harness.current = s
			if opts.on_socket then opts.on_socket(s, harness) end
			return s
		end,
		connect = function()
			return nil
		end,
	}

	local env = {
		require = function(name)
			if name == "socket" then return socket_lib end
			if name == "json" then
				return {
					encode = function(t)
						return string.format('{"action":"%s"}', tostring(t.action))
					end,
				}
			end
			return {}
		end,
		love = {
			thread = {
				getChannel = function(name)
					return channels[name]
				end,
			},
		},
		string = string,
		table = table,
		math = math,
		os = os,
		pcall = pcall,
		tostring = tostring,
		type = type,
		ipairs = ipairs,
		pairs = pairs,
		error = error,
		print = print,
		select = select,
	}

	local outer = assert(loadfile(opts.path or "networking/socket.lua"))
	local src = outer()
	local chunk = assert(load(src, "@socket-thread", "t", env))

	harness.to_ui, harness.to_net = to_ui, to_net
	harness.push_ui = function(msg)
		to_net[#to_net + 1] = msg
	end

	local ok, err = pcall(chunk, "test.host", 1234)
	if not ok and err ~= "__STOP__" then error(err, 0) end
	return harness
end

local CONNECT = '{"action":"connect"}'

-- 1. A line split across reads must be reassembled, not dropped
print("\npartial inbound line reassembly")
do
	local delivered = {}
	run_thread({
		max_ticks = 12,
		on_tick = function(harness)
			local s = harness.current
			if not s then
				harness.to_net[#harness.to_net + 1] = CONNECT
				return
			end
			-- Dribble one JSON message in three fragments across three ticks,
			-- straddling tick boundaries mid-token.
			if harness.ticks == 3 then
				s.inbox = s.inbox .. '{"action":"startB'
			elseif harness.ticks == 4 then
				s.inbox = s.inbox .. 'lind","firstPlay'
			elseif harness.ticks == 5 then
				s.inbox = s.inbox .. 'er":"host"}\n'
			end
			while true do
				local m = harness.to_ui[1]
				if not m then break end
				table.remove(harness.to_ui, 1)
				delivered[#delivered + 1] = m
			end
		end,
	})

	local found = nil
	for _, m in ipairs(delivered) do
		if m:find("startBlind", 1, true) then found = m end
	end
	eq(found, '{"action":"startBlind","firstPlayer":"host"}', "three-way split line arrives intact")
end

-- 2. Two messages in one read, second incomplete
print("\ncoalesced reads with a trailing partial")
do
	local delivered = {}
	run_thread({
		max_ticks = 12,
		on_tick = function(harness)
			local s = harness.current
			if not s then
				harness.to_net[#harness.to_net + 1] = CONNECT
				return
			end
			if harness.ticks == 3 then
				-- One TCP segment carrying a whole message plus half of the next.
				s.inbox = s.inbox .. '{"action":"endPvP"}\n{"action":"stop'
			elseif harness.ticks == 5 then
				s.inbox = s.inbox .. 'Game"}\n'
			end
			while true do
				local m = harness.to_ui[1]
				if not m then break end
				table.remove(harness.to_ui, 1)
				delivered[#delivered + 1] = m
			end
		end,
	})

	local got = {}
	for _, m in ipairs(delivered) do
		if m:find("endPvP", 1, true) or m:find("stopGame", 1, true) then got[#got + 1] = m end
	end
	eq(got[1], '{"action":"endPvP"}', "first complete message delivered")
	eq(got[2], '{"action":"stopGame"}', "trailing partial completed on a later tick")
end

-- 3. Partial writes resume from the right byte, in order
print("\nresumable outbound writes")
do
	local big = '{"action":"receiveEndGameJokers","keys":"' .. string.rep("A", 4000) .. '"}'
	local second = '{"action":"playHand","score":"12345","handsLeft":3}'

	-- 97 bytes per send() forces ~42 partial writes, one per tick, for the 4kB
	-- payload; the tick budget has to cover that plus the second message.
	local h = run_thread({
		max_ticks = 120,
		on_socket = function(s)
			s.send_limit = 97 -- awkward boundary, never aligned to the payload
		end,
		on_tick = function(harness)
			local s = harness.current
			if not s then
				harness.to_net[#harness.to_net + 1] = CONNECT
				return
			end
			if harness.ticks == 3 then
				harness.to_net[#harness.to_net + 1] = big
				harness.to_net[#harness.to_net + 1] = second
			end
		end,
	})

	local sent = h.current.sent
	eq(sent, big .. "\n" .. second .. "\n", "both payloads written whole and in order")
	check(not sent:find("}{", 1, true), "no interleaving between queued messages")
end

-- 3b. A burst queued in one tick must all go out, in order.
-- G.FUNCS.mp_toggle_ready sends setLocation + readyBlind (and pause_ante_timer
-- when unreadying) in a single frame, so they land in one tick together.
print("\nmulti-message burst in a single tick")
do
	-- Exactly three: the unready path's setLocation + pauseAnteTimer +
	-- unreadyBlind. On LuaJIT a three-element queue drained by punching nil holes
	-- loses the last entry, which is the bug this guards.
	local burst = {
		'{"action":"setLocation","location":"loc_selecting-bl_mp_nemesis"}',
		'{"action":"pauseAnteTimer","time":150}',
		'{"action":"unreadyBlind"}',
	}

	local h = run_thread({
		max_ticks = 40,
		on_tick = function(harness)
			local s = harness.current
			if not s then
				harness.to_net[#harness.to_net + 1] = CONNECT
				return
			end
			if harness.ticks == 3 then
				for _, m in ipairs(burst) do
					harness.to_net[#harness.to_net + 1] = m
				end
			end
		end,
	})

	local expected = table.concat(burst, "\n") .. "\n"
	eq(h.current.sent, expected, "all three burst messages sent, in order")
	check(h.current.sent:find("unreadyBlind", 1, true) ~= nil, "the last message in the burst survived")
end

-- 4. Keepalive probes, then declare the link dead
print("\nkeepalive probing on a silent link")
do
	local h = run_thread({
		max_ticks = 700, -- 700 * 0.05s = 35s of virtual time
		on_tick = function(harness)
			if not harness.current then harness.to_net[#harness.to_net + 1] = CONNECT end
		end,
	})

	-- First socket, not harness.current: a dead link means a replacement was opened.
	local probes = 0
	for _ in h.sockets[1].sent:gmatch('"keepAlive"') do
		probes = probes + 1
	end
	eq(probes, 3, "sent exactly KEEPALIVE_PROBES probes before giving up on the link")

	local announced = false
	for _, m in ipairs(h.to_ui) do
		if m:find("reconnecting", 1, true) then announced = true end
	end
	check(announced, "announced reconnecting once probes went unanswered")
end

-- 5. Traffic resets the keepalive timer
print("\nkeepalive backs off while traffic flows")
do
	local h = run_thread({
		max_ticks = 400, -- 20s
		on_tick = function(harness)
			local s = harness.current
			if not s then
				harness.to_net[#harness.to_net + 1] = CONNECT
				return
			end
			-- Server chatter every 2s, as enemyInfo would be.
			if harness.ticks % 40 == 0 then s.inbox = s.inbox .. '{"action":"enemyInfo"}\n' end
			for i = #harness.to_ui, 1, -1 do
				table.remove(harness.to_ui, i)
			end
		end,
	})

	local probes = 0
	for _ in h.current.sent:gmatch('"keepAlive"') do
		probes = probes + 1
	end
	eq(probes, 0, "no probes needed while the server keeps talking")
end

-- 6. A closed socket triggers retries without blocking the loop
print("\nreconnect after the socket closes")
do
	-- 12.5s: the close lands at 0.5s and retries at once; the replacement socket is
	-- silent, so a second genuine outage would start ~19.5s. Stop before then.
	local h = run_thread({
		max_ticks = 250,
		on_tick = function(harness)
			local s = harness.current
			if not s then
				harness.to_net[#harness.to_net + 1] = CONNECT
				return
			end
			if harness.ticks == 10 then s.closed = true end
		end,
	})

	check(h.connect_attempts >= 2, "retried the connection", "attempts=" .. h.connect_attempts)
	check(h.ticks >= 249, "loop never blocked: reached the full tick budget", "ticks=" .. h.ticks)

	local announced = 0
	for _, m in ipairs(h.to_ui) do
		if m:find("reconnecting", 1, true) then announced = announced + 1 end
	end
	eq(announced, 1, "announced reconnecting exactly once per outage")
end

-- 8. A server that never reconnects still yields to the UI, once
print("\nprolonged outage notifies the UI exactly once")
do
	local h = run_thread({
		max_ticks = 3200, -- 160s, past RECONNECT_NOTIFY_AFTER (120s)
		on_tick = function(harness)
			if harness.ticks == 1 then harness.to_net[#harness.to_net + 1] = CONNECT end
			harness.connect_should_fail = harness.ticks > 5
			if harness.ticks == 10 and harness.current then harness.current.closed = true end
		end,
	})

	local gave_up = 0
	for _, m in ipairs(h.to_ui) do
		if m:find("disconnected", 1, true) then gave_up = gave_up + 1 end
	end
	eq(gave_up, 1, "pushed disconnected once, not on every failed attempt")
	check(h.connect_attempts > 5, "kept retrying in the background", "attempts=" .. h.connect_attempts)
end

-- 7. Server keepAlive is answered, and through the queue
print("\nserver keepAlive is acknowledged")
do
	local h = run_thread({
		max_ticks = 60,
		on_tick = function(harness)
			local s = harness.current
			if not s then
				harness.to_net[#harness.to_net + 1] = CONNECT
				return
			end
			if harness.ticks == 5 then s.inbox = s.inbox .. '{"action":"keepAlive"}\n' end
		end,
	})
	check(h.current.sent:find("keepAliveAck", 1, true) ~= nil, "replied with keepAliveAck")
end

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
