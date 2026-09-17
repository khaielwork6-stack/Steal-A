--!strict
--[[
	DebugCommands.BasesUI
	Studio-only commands for screenshotting and checking the Upgrades > BASE
	cards and the Settings panel (docs/handoff-parts/round3-ui-base-settings.md).
	Invoke through ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...).

	  baseUiPreview [on|off]
	      CASH-FREE, PROFILE-FREE preview. Sets the player attribute
	      BaseUiPreview; BaseThemeController then paints the BASE page from a
	      fixed mix (Sunset + White Marble equipped; Classic, Midnight,
	      Neon Night, Museum Stone owned; Jungle / Obsidian affordable, Frost,
	      Lava, Solid Gold, Crystal not; Royal Gold for Robux) and sends
	      NOTHING when a button is pressed. Nothing on the server changes.
	  baseUiLive [on|off]
	      LIVE test of the Robux cards. `on` remembers the profile's BaseTheme
	      and turns on the Studio ownership override for every theme pass, so
	      the exclusive cards show EQUIP and can really be equipped. `off`
	      (always run it) clears the overrides and puts the remembered
	      equipped theme / pedestal back, then repaints, pushes and saves.
	      Themes bought with real Cash in between stay owned (the Cash was
	      really spent); only what is equipped is restored.
	  uiAudit
	      asks the client to print, for the Upgrades and Settings panels,
	      how many clip guards exist, any rotated elements, and any visible
	      element outside the panel that is not inside a clip guard. Open the
	      panel (and the BASE tab) first; read the CLIENT output.
]]

local Players = game:GetService("Players")

local MonetizationConfig = require(game:GetService("ReplicatedStorage").Shared.Config.MonetizationConfig)

local BaseThemeService = require(script.Parent.Parent.BaseThemeService)
local DataService = require(script.Parent.Parent.DataService)
local StateService = require(script.Parent.Parent.StateService)

type Snapshot = { equippedTheme: string, equippedPedestal: string }

local liveSnapshots: { [Player]: Snapshot } = {}

local function onOff(value: any, default: boolean): boolean
	if value == "off" or value == false then
		return false
	elseif value == "on" or value == true then
		return true
	end
	return default
end

local function setPassOverrides(player: Player, value: boolean?)
	for _, pass in MonetizationConfig.ThemePasses do
		BaseThemeService.setPassOwnedForTesting(player, pass.key, value)
	end
end

--- Puts back what `baseUiLive on` remembered. Safe to call twice.
local function restoreLive(player: Player): { [string]: any }
	local snapshot = liveSnapshots[player]
	liveSnapshots[player] = nil
	local ok, err = pcall(function()
		setPassOverrides(player, nil)
		local profile = DataService.get(player)
		if profile and snapshot then
			profile.BaseTheme.equippedTheme = snapshot.equippedTheme
			profile.BaseTheme.equippedPedestal = snapshot.equippedPedestal
		end
		BaseThemeService.apply(player)
		StateService.pushNow(player, true)
		if profile and DataService.isPersistent() then
			DataService.save(player)
		end
	end)
	return { restored = snapshot ~= nil, error = if ok then nil else tostring(err) }
end

-- A tester who leaves without `off` still gets the equipped keys back
-- in memory (the overrides die with the session anyway).
Players.PlayerRemoving:Connect(function(player)
	local snapshot = liveSnapshots[player]
	liveSnapshots[player] = nil
	local profile = DataService.get(player)
	if snapshot and profile then
		profile.BaseTheme.equippedTheme = snapshot.equippedTheme
		profile.BaseTheme.equippedPedestal = snapshot.equippedPedestal
	end
end)

return {
	baseUiPreview = function(player: Player, mode: any): any
		local on = onOff(mode, true)
		player:SetAttribute("BaseUiPreview", if on then "mixed" else nil)
		return {
			preview = on,
			note = if on
				then "Open Upgrades > BASE. Buttons send nothing. Run `baseUiPreview off` when done."
				else "Preview off - the page shows your real profile again.",
		}
	end,

	baseUiLive = function(player: Player, mode: any): any
		local on = onOff(mode, true)
		if not on then
			return restoreLive(player)
		end
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		if not liveSnapshots[player] then
			liveSnapshots[player] = {
				equippedTheme = profile.BaseTheme.equippedTheme,
				equippedPedestal = profile.BaseTheme.equippedPedestal,
			}
		end
		local ok, err = pcall(function()
			setPassOverrides(player, true)
			StateService.pushNow(player, true)
		end)
		if not ok then
			local restored = restoreLive(player)
			return { error = tostring(err), restored = restored.restored }
		end
		return {
			live = true,
			remembered = liveSnapshots[player],
			note = "Exclusive themes now show EQUIP. Run `baseUiLive off` to restore.",
		}
	end,

	uiAudit = function(player: Player): any
		player:SetAttribute("DebugUiAudit", os.clock())
		return { note = "See the CLIENT output for [UiAudit] lines (open the panel first)." }
	end,
}
