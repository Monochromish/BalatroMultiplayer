local function create_player_info_row(player, player_type, text_scale)
	if not player or not player.username then return nil end

	-- Who still has to ready up only matters once there are several guests
	local show_ready = #MP.LOBBY.players > 2 and not player.is_host
	return MP.UI.UTILS.create_row({ padding = 0.1, align = "cm" }, {
        MP.UI.UTILS.create_column({ align = "cm", maxw = 3 }, {
            MP.UI.UTILS.create_text_node(nil, {
                ref_table = player,
                ref_value = "username",
                scale = text_scale * 0.8,
                colour = show_ready and player.ready and G.C.GREEN or G.C.UI.TEXT_LIGHT,
                maxw = 3.5
            }),
        }),
		MP.UI.UTILS.create_blank(0.1, 0.1),
		player.hash and UIBox_button({
			id = player_type .. "_hash",
			button = "view_player_hash",
			ref_table = player,
			label = { player.hash },
			minw = 0.75,
			minh = 0.3,
			scale = 0.25,
			shadow = false,
			colour = G.C.PURPLE,
			col = true,
		}) or nil,
	})
end

function MP.UI.create_players_section(text_scale)
	local title = localize("k_connect_player")
	if #MP.LOBBY.players > 2 or (MP.LOBBY.max_players or 2) > 2 then
		title = title .. " " .. #MP.LOBBY.players .. "/" .. (MP.LOBBY.max_players or #MP.LOBBY.players)
	end

	-- Up to four rows per column so the lobby bar stays short
	local columns = {}
	for i, player in ipairs(MP.LOBBY.players) do
		local column = math.ceil(i / 4)
		columns[column] = columns[column] or {}
		table.insert(columns[column], create_player_info_row(player, "player_" .. i, text_scale))
	end
	local column_nodes = {}
	for _, rows in ipairs(columns) do
		table.insert(column_nodes, MP.UI.UTILS.create_column({ align = "tm" }, rows))
	end

	return MP.UI.UTILS.create_column({ align = "tm", minw = 2.65 }, {
		MP.UI.UTILS.create_row({ align = "cm", padding = 0.15 }, {
			MP.UI.UTILS.create_text_node(title, {
				scale = text_scale * 0.8,
				colour = G.C.UI.TEXT_LIGHT,
			}),
		}),
		MP.UI.UTILS.create_row({ align = "tm" }, column_nodes),
	})
end
