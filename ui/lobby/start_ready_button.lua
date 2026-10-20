local Disableable_Button = MP.UI.Disableable_Button

local function get_warnings()
	local warnings = {}

	-- Check the other players
	local cheating, locked = false, false
	for _, other_player in ipairs(MP.LOBBY.players) do
		if not other_player.is_self then
			cheating = cheating or other_player.cached == false
			locked = locked or (other_player.config and other_player.config.unlocked == false)
		end
	end

	if cheating then
		table.insert(warnings, { localize("k_warning_cheating1"), SMODS.Gradients.warning_text, 0.4 })
		table.insert(
			warnings,
			{ string.format(localize("k_warning_cheating2"), MP.UTILS.random_message()), SMODS.Gradients.warning_text }
		)
	end

	if locked then
		table.insert(warnings, {
			localize("k_warning_nemesis_unlock"),
			SMODS.Gradients.warning_text,
			0.25,
		})
	end

	local bothPlayersInLobby = MP.LOBBY.guest and MP.LOBBY.guest.config ~= nil

	-- Every guest's version of a mod, or the first one that differs from the host's
	local function guest_mod_version(mod)
		local hostVersion = MP.LOBBY.host and MP.LOBBY.host.config and MP.LOBBY.host.config.Mods[mod]
		for _, player in ipairs(MP.LOBBY.players) do
			local version = player.config and player.config.Mods[mod]
			if not player.is_host and version ~= hostVersion then return hostVersion, version end
		end
		return hostVersion, hostVersion
	end

	-- Content mod compatibility warnings (currently Extra Credit only)
	if bothPlayersInLobby then
		local hostExtraCreditVersion, guestExtraCreditVersion = guest_mod_version("extracredit")

		if hostExtraCreditVersion ~= guestExtraCreditVersion then
			table.insert(warnings, {
				"Extra Credit mismatch - players may see different jokers",
				SMODS.Gradients.warning_text,
			})
		elseif hostExtraCreditVersion ~= nil and hostExtraCreditVersion == guestExtraCreditVersion then
			table.insert(warnings, {
				"Extra Credit active - curated jokers replaced with full pool",
				G.C.GREEN,
				0.25,
			})
		end
	end

	if MP.LOBBY.ready_to_start or not MP.LOBBY.is_host then
		local hostSteamoddedVersion, guestSteamoddedVersion = guest_mod_version("Steamodded")

		if hostSteamoddedVersion ~= guestSteamoddedVersion then
			table.insert(warnings, {
				localize("k_steamodded_warning"),
				SMODS.Gradients.warning_text,
			})
		end
	end

	if MP.UTILS.mp_version_mismatch() then
		table.insert(warnings, {
			localize("k_mp_version_warning"),
			G.C.RED,
			0.4,
		})
	end

	local any_banned_mods = false
	for _, player in ipairs(MP.LOBBY.players) do
		if player.config and #MP.UTILS.get_banned_mods(player.config.Mods) > 0 then any_banned_mods = true end
	end

	if any_banned_mods then
		table.insert(warnings, {
			localize("k_warning_banned_mods"),
			G.C.RED,
			0.4,
		})
	end

	SMODS.Mods["Multiplayer"].config.unlocked = MP.UTILS.unlock_check()
	if not SMODS.Mods["Multiplayer"].config.unlocked then
		table.insert(warnings, {
			localize("k_warning_unlock_profile"),
			SMODS.Gradients.warning_text,
			0.25,
		})
	end

	if MP.LOBBY.username == "Guest" then table.insert(warnings, {
		localize("k_set_name"),
		G.C.UI.TEXT_LIGHT,
	}) end

	if #warnings == 0 then table.insert(warnings, {
		" ",
		G.C.UI.TEXT_LIGHT,
	}) end

	return warnings
end

function MP.UI.lobby_status_display()
	local warnings = get_warnings()

	local warning_texts = {}
	for k, v in pairs(warnings) do
		table.insert(
			warning_texts,
			MP.UI.UTILS.create_row({ align = "cm", padding = -0.25 }, {
				MP.UI.UTILS.create_text_node(v[1], {
					colour = v[2],
					scale = v[3] or 0.25,
				}),
			})
		)
	end

	return MP.UI.UTILS.create_row({ padding = 0.35, align = "cm" }, warning_texts)
end

-- Component for main start/ready button in lobby
function MP.UI.create_lobby_main_button(text_scale)
	if MP.LOBBY.is_host then
		return Disableable_Button({
			id = "lobby_menu_start",
			button = "lobby_start_game",
			colour = G.C.BLUE,
			minw = 3.65,
			minh = 1.55,
			label = { localize("b_start") },
			disabled_text = MP.LOBBY.guest.username and localize("b_wait_for_guest_ready")
				or localize("b_wait_for_players"),
			scale = text_scale * 2,
			col = true,
			enabled_ref_table = MP.LOBBY,
			enabled_ref_value = "ready_to_start",
		})
	else
		return UIBox_button({
			id = "lobby_menu_start",
			button = "lobby_ready_up",
			colour = MP.LOBBY.ready_to_start and G.C.GREEN or G.C.RED,
			minw = 3.65,
			minh = 1.55,
			label = { MP.LOBBY.ready_to_start and localize("b_unready") or localize("b_ready") },
			scale = text_scale * 2,
			col = true,
		})
	end
end
