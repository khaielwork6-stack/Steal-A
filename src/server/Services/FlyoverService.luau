--!strict
--[[
	FlyoverService  (polish-events-analytics pass)
	The server half of the first-join camera flyover (FlyoverController).

	  * StatePush field `firstSession`: true while the flyover is still owed -
	    PolishConfig.FLYOVER_ENABLED, Profile.FlyoverSeen false and the saved
	    tutorial stage below FLYOVER_MAX_TUTORIAL_STAGE.
	  * FlyoverDone (client, carries nothing, rate-limited): flips
	    Profile.FlyoverSeen. Finishing and skipping are the same thing.

	DEBUG REPLAY (Studio). `debugReplay(player)` shows the flyover again to a
	player whose profile has already seen it: the saved flag is cleared for
	the replay only and put back when the client reports done, or before the
	leave-save if it never does.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PolishConfig = require(ReplicatedStorage.Shared.Config.PolishConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DataService = require(script.Parent.DataService)
local StateService = require(script.Parent.StateService)

local FlyoverService = {}

--- Player -> the FlyoverSeen value to put back after a debug replay.
local replaying: { [Player]: boolean } = {}

local function restore(player: Player, profile: DataService.Profile?)
	local original = replaying[player]
	if original == nil then
		return
	end
	replaying[player] = nil
	if profile then
		profile.FlyoverSeen = original
	end
end

function FlyoverService.isFirstSession(player: Player): boolean
	local profile = DataService.get(player)
	if not PolishConfig.FLYOVER_ENABLED or not profile or profile.FlyoverSeen then
		return false
	end
	return replaying[player] ~= nil or profile.TutorialStage < PolishConfig.FLYOVER_MAX_TUTORIAL_STAGE
end

--- Studio only: plays the flyover for `player` once more.
function FlyoverService.debugReplay(player: Player): (boolean, string?)
	if not RunService:IsStudio() then
		return false, "Studio only"
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "profile not loaded"
	end
	if replaying[player] == nil then
		replaying[player] = profile.FlyoverSeen
	end
	profile.FlyoverSeen = false
	StateService.markDirty(player)
	return true
end

function FlyoverService.debugState(player: Player): { [string]: any }
	local profile = DataService.get(player)
	return {
		firstSession = FlyoverService.isFirstSession(player),
		flyoverSeen = if profile then profile.FlyoverSeen else nil,
		tutorialStage = if profile then profile.TutorialStage else nil,
		replaying = replaying[player] ~= nil,
		willRestoreTo = replaying[player],
	}
end

function FlyoverService.start()
	StateService.addProvider("firstSession", FlyoverService.isFirstSession)

	local limiter = RateLimiter.new(0.2, 2)
	Remotes.get("FlyoverDone").OnServerEvent:Connect(function(player)
		if not limiter:consume(player) then
			return
		end
		local profile = DataService.get(player)
		if not profile then
			return
		end
		if replaying[player] ~= nil then
			restore(player, profile)
		else
			profile.FlyoverSeen = true
		end
		StateService.markDirty(player)
	end)

	-- A replay that never finished must not be saved as unseen.
	DataService.onBeforeRelease(function(player, profile)
		restore(player, profile)
	end)
	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
	end)
end

return FlyoverService
