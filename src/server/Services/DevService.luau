--!strict
--[[
	DevService  (STUDIO ONLY)
	The owner's quick dev tools for testing: give yourself Cash, and reset
	ALL your data back to a brand-new player. Driven by the DEV panel
	(DevToolsController). Nothing here exists on a live server: `start` returns
	at once outside Studio, so the remote has no handler there at all, and the
	client controller never builds the panel.

	STUDIO PLAYS ON THE REAL SAVE. A Studio session loads the owner's actual
	DataStore profile, so a reset wipes what the LIVE game would load too. Two
	things make that recoverable:
	  * the profile is SAVED FIRST, so the version being wiped is the newest
	    saved version and stays in DataStore's history (~30 days); it can be read
	    back with the profileHistory debug command;
	  * when this Studio session is only a GUEST on a save a live server owns
	    (DataService.isStudioGuest), nothing here is ever written at all.

	  DevRequest("grantCash", amount)   award `amount` Cash (no 2x pass)
	  DevRequest("resetAll", "RESET")   replace the profile with a new player's
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local HoldService = require(script.Parent.HoldService)
local SpeedService = require(script.Parent.SpeedService)
local StateService = require(script.Parent.StateService)

local DevService = {}

--- Far above anything the game can pay, far below where a double stops being
--- exact enough to show; a typo cannot break the economy's number formatting.
local MAX_GRANT = 1e24

function DevService.grantCash(player: Player, amount: any): (boolean, string)
	local value = tonumber(amount)
	if value == nil or value ~= value or value <= 0 or value == math.huge then
		return false, "Enter an amount above 0."
	end
	value = math.min(value, MAX_GRANT)
	EconomyService.award(player, value, "debug")
	StateService.pushNow(player)
	return true, `+{NumberFormat.cash(value)}`
end

function DevService.resetAll(player: Player): (boolean, string)
	if DataService.isStudioGuest(player) then
		-- A borrowed copy: nothing is saved, so this only affects this session.
		warn("[DevService] this Studio session is a guest on a live save: the reset is in memory only")
	end
	local ok = DataService.devReset(player)
	if not ok then
		return false, "No profile to reset."
	end
	-- Everything derived from the profile is rebuilt: the base, income, the
	-- walk speed, the held-item model, and the client's whole state.
	BaseService.rebuildDisplays(player)
	EconomyService.recalculate(player)
	pcall(function()
		SpeedService.applyMovement(player)
	end)
	HoldService.refreshHeldVisual(player)
	StateService.pushNow(player, true)
	DataService.save(player)
	return true, "All data reset to a new player."
end

function DevService.start()
	if not RunService:IsStudio() then
		return
	end
	local limiter = RateLimiter.new(2, 4)
	Remotes.get("DevRequest").OnServerEvent:Connect(function(player: Player, action: any, argument: any)
		if not limiter:consume(player) or type(action) ~= "string" then
			return
		end
		local ok, message
		if action == "grantCash" then
			ok, message = DevService.grantCash(player, argument)
		elseif action == "resetAll" and argument == "RESET" then
			ok, message = DevService.resetAll(player)
		else
			return
		end
		StateService.notify(player, if ok then "success" else "error", `DEV: {message}`)
	end)
	print("[DevService] Studio dev tools online (grant Cash, reset all data)")
end

return DevService
