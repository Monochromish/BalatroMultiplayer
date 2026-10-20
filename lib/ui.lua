function MP.UTILS.save_username(text)
	MP.ACTIONS.set_username(text)
	SMODS.Mods["Multiplayer"].config.username = text
end

function MP.UTILS.get_username()
	return SMODS.Mods["Multiplayer"].config.username
end

function MP.UTILS.save_blind_col(num)
	MP.ACTIONS.set_blind_col(num)
	SMODS.Mods["Multiplayer"].config.blind_col = num
end

function MP.UTILS.get_blind_col()
	return SMODS.Mods["Multiplayer"].config.blind_col
end

function MP.UTILS.blind_col_numtokey(num)
	local keys = {
		"tooth",
		"small",
		"big",
		"hook",
		"ox",
		"house",
		"wall",
		"wheel",
		"arm",
		"club",
		"fish",
		"psychic",
		"goad",
		"water",
		"window",
		"manacle",
		"eye",
		"mouth",
		"plant",
		"serpent",
		"pillar",
		"needle",
		"head",
		"flint",
		"mark",
	}
	return "bl_" .. keys[num]
end

-- Opponents still in a game of more than two players, in join order
function MP.UTILS.alive_opponents()
	local alive = {}
	for id, player in pairs(MP.GAME.players or {}) do
		if player.alive and id ~= MP.LOBBY.self_id then table.insert(alive, player) end
	end
	table.sort(alive, function(a, b)
		return a.id < b.id
	end)
	return alive
end

function MP.UTILS.update_nemesis_group()
	MP.GAME.nemesis_group = MP.GAME.nemesis_group or { blind_col = 1 }
	MP.GAME.nemesis_group.username =
		localize({ type = "variable", key = "k_mp_avg_opponents", vars = { #MP.UTILS.alive_opponents() } })
end

function MP.UTILS.player_name(id)
	local player = MP.GAME.players and MP.GAME.players[tonumber(id)]
	if player then return player.username end
	for _, lobby_player in ipairs(MP.LOBBY.players) do
		if lobby_player.id == tonumber(id) then return lobby_player.username end
	end
	return "?"
end

-- Whose board the end screen shows; the server picks the same player
function MP.UTILS.get_end_game_nemesis()
	if MP.GAME.multi and MP.GAME.players then
		local me = MP.GAME.players[MP.LOBBY.self_id]
		local others = {}
		for id, player in pairs(MP.GAME.players) do
			if id ~= MP.LOBBY.self_id then table.insert(others, player) end
		end
		table.sort(others, function(a, b)
			return a.id < b.id
		end)
		local best
		if me and me.alive then
			-- the last player knocked out
			for _, player in ipairs(others) do
				if player.place > 1 and (not best or player.place < best.place) then best = player end
			end
		end
		if not best then
			-- the leader: most lives, then the higher score
			local alive = MP.UTILS.alive_opponents()
			for _, player in ipairs(#alive > 0 and alive or others) do
				local score, best_score = player.score or MP.INSANE_INT.empty(), best and best.score or MP.INSANE_INT.empty()
				if
					not best
					or player.lives > best.lives
					or (player.lives == best.lives and MP.INSANE_INT.greater_than(score, best_score))
				then
					best = player
				end
			end
		end
		if best then return best end
	end
	return MP.LOBBY.is_host and MP.LOBBY.guest or MP.LOBBY.host
end

-- Who "the nemesis" is: your only opponent, or while more than one is left in a
-- bigger game, a stand-in for their average
function MP.UTILS.get_nemesis()
	if not MP.GAME.multi then return MP.LOBBY.is_host and MP.LOBBY.guest or MP.LOBBY.host end
	local alive = MP.UTILS.alive_opponents()
	if #alive == 1 then return alive[1] end
	if #alive == 0 then return MP.UTILS.get_end_game_nemesis() end
	MP.UTILS.update_nemesis_group()
	return MP.GAME.nemesis_group
end

function MP.UTILS.get_nemesis_name()
	if MP.GAME.multi then return MP.UTILS.get_nemesis().username end
	return MP.LOBBY.is_host and MP.LOBBY.guest.username or MP.LOBBY.host.username
end

-- Several opponents are being averaged right now
function MP.UTILS.facing_average()
	return MP.GAME.multi and #MP.UTILS.alive_opponents() > 1
end

function MP.UTILS.get_nemesis_key(own, nemesis) -- calling this function assumes the user is currently in a multiplayer game
	local num
	if MP.GAME.multi then
		num = (own and MP.LOBBY.blind_col or (nemesis or MP.UTILS.get_nemesis()).blind_col) or 1
	else
		num = ((not own) ~= (not MP.LOBBY.is_host) and MP.LOBBY.guest.blind_col or MP.LOBBY.host.blind_col) or 1 -- cryptic xor fuckery
	end
	local ret = MP.UTILS.blind_col_numtokey(num)
	if tonumber(MP.GAME.enemy.lives) <= 1 and tonumber(MP.GAME.lives) <= 1 and not MP.UTILS.facing_average() then
		if G.STATE ~= G.STATES.ROUND_EVAL then -- very messy fix that mostly works. breaks in a different way... but far harder to notice
			-- random ass showdown blind mapping because i can. surely one day this data will be organised better
			ret = ({
				"heart",
				"bell",
				"acorn",
				"heart",
				"heart",
				"bell",
				"vessel",
				"leaf",
				"vessel",
				"leaf",
				"bell",
				"acorn",
				"vessel",
				"bell",
				"acorn",
				"heart",
				"bell",
				"vessel",
				"leaf",
				"leaf",
				"acorn",
				"leaf",
				"vessel",
				"acorn",
				"heart",
			})[num]
			ret = "bl_final_" .. ret
		end
	end
	return ret
end

function MP.UTILS.save_preview(table)
	for k, v in pairs(table) do
		SMODS.Mods["Multiplayer"].config.preview[k] = v
	end
end

function MP.UTILS.get_preview_cfg(index)
	local ret = SMODS.Mods["Multiplayer"].config.preview[index]
	if not ret or #ret < 1 then
		if index == "text" then
			ret = "CALCULATING"
		else
			ret = "Calculate Score"
		end
	end
	return ret
end

function MP.UTILS.copy_to_clipboard(text)
	if G.F_LOCAL_CLIPBOARD then
		G.CLIPBOARD = text
	else
		love.system.setClipboardText(text)
	end
end

function MP.UTILS.get_from_clipboard()
	if G.F_LOCAL_CLIPBOARD then
		return G.F_LOCAL_CLIPBOARD
	else
		return love.system.getClipboardText()
	end
end

function MP.UTILS.random_message()
	local messages = {
		localize("k_message1"),
		localize("k_message2"),
		localize("k_message3"),
		localize("k_message4"),
		localize("k_message5"),
		localize("k_message6"),
		localize("k_message7"),
		localize("k_message8"),
		localize("k_message9"),
	}
	return messages[math.random(1, #messages)]
end

function MP.UTILS.add_nemesis_info(info_queue)
	if MP.LOBBY.code then
		info_queue[#info_queue + 1] = {
			set = "Other",
			key = "current_nemesis",
			vars = { MP.UTILS.get_nemesis_name() },
		}
	end
end
