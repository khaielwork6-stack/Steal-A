--!strict
--[[
	DebugCommands.Dev
	Studio-only test for DevService (the DEV panel's two tools).

	devToolsTest
	    grantCash: +1e6 lands exactly, and 0 / negative / "abc" / NaN / inf are
	    refused without changing the Cash. resetAll's engine (DataService.
	    devReset): the profile comes back as a brand-new player's (starting Cash
	    and Speed, empty Storage and displays) and is then RESTORED to exactly
	    what it was - the whole table, in place - so nothing of the tester's is
	    lost. It does NOT call DevService.resetAll, which also saves the reset
	    state; only the in-memory profile is touched, and it is put back before
	    this returns, error or not.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local Services = script.Parent.Parent
local BaseService = require(Services.BaseService)
local DataService = require(Services.DataService)
local DevService = require(Services.DevService)
local EconomyService = require(Services.EconomyService)
local SpeedService = require(Services.SpeedService)
local StateService = require(Services.StateService)

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: { [any]: any } do
		out[k] = copy(v)
	end
	return out
end

local commands: { [string]: (Player, ...any) -> any } = {}

commands.devToolsTest = function(player: Player)
	assert(RunService:IsStudio(), "Studio only")
	local profile = assert(DataService.get(player), "no profile")
	local saved = copy(profile)
	local report: { [string]: any } = {}

	local ok, err = pcall(function()
		-- GIVE CASH
		local before = EconomyService.getCash(player)
		local granted = DevService.grantCash(player, 1e6)
		report.grantExact = granted == true and EconomyService.getCash(player) == before + 1e6
		local afterGrant = EconomyService.getCash(player)
		local refused = 0
		for _, bad in { 0, -5, "abc", 0 / 0, math.huge, "" } do
			local good = DevService.grantCash(player, bad)
			if good == false then
				refused += 1
			end
		end
		report.badAmountsRefused = refused == 6 and EconomyService.getCash(player) == afterGrant
		report.textAmountAccepted = DevService.grantCash(player, "2e3") == true and EconomyService.getCash(player) == afterGrant + 2000

		-- RESET (the engine only)
		local same = profile
		local didReset = DataService.devReset(player)
		report.resetRan = didReset == true
		report.sameTable = DataService.get(player) == same
		report.startingCash = profile.Cash == GameConfig.STARTING_CASH
		report.startingSpeed = profile.SpeedPower == GameConfig.STARTING_SPEED_POWER
		report.emptyDisplays = #profile.DisplayItems == 0
		report.emptyStorage = #profile.Inventory == 0
		report.filmDueAgain = profile.TutorialFilmDone == false
	end)

	-- PUT EVERYTHING BACK, in place, even on error.
	for key in profile :: any do
		(profile :: any)[key] = nil
	end
	for key, value in saved :: any do
		(profile :: any)[key] = value
	end
	BaseService.rebuildDisplays(player)
	EconomyService.recalculate(player)
	pcall(function()
		SpeedService.applyMovement(player)
	end)
	StateService.pushNow(player, true)
	report.restoredCash = profile.Cash == saved.Cash and #profile.Inventory == #saved.Inventory and #profile.DisplayItems == #saved.DisplayItems

	if not ok then
		report.error = tostring(err)
	end
	report.pass = ok
		and report.grantExact == true
		and report.badAmountsRefused == true
		and report.textAmountAccepted == true
		and report.resetRan == true
		and report.sameTable == true
		and report.startingCash == true
		and report.startingSpeed == true
		and report.emptyDisplays == true
		and report.emptyStorage == true
		and report.restoredCash == true
	return report
end

return commands
