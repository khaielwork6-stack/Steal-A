--!strict
--[[
	SettingsService
	The server side of the Settings panel: validates what the client asks for,
	writes it onto the profile, and pushes it back so the panel and the mixer
	agree with the save.

	The client applies its own settings locally the instant a control moves
	(volume, shadows, reduced effects are all client-side concerns); this exists
	so they SURVIVE a rejoin. Nothing here affects any other player or any
	gameplay number, which is why the whole validation is "right type, in
	range".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local DataService = require(script.Parent.DataService)
local StateService = require(script.Parent.StateService)

local SettingsService = {}

local limiter = RateLimiter.new(GameConfig.RATE_LIMITS.SettingsRequest)

local function level(value: any): number?
	if not Validate.finite(value) then
		return nil
	end
	return math.clamp(value, 0, 1)
end

--- Applies whichever known fields the request carries. Unknown keys and
--- malformed values are ignored, never an error: a bad packet changes nothing.
function SettingsService.apply(player: Player, request: any): boolean
	if type(request) ~= "table" then
		return false
	end
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	local settings = profile.Settings
	local changed = false

	local music = level(request.MusicVolume)
	if music ~= nil and music ~= settings.MusicVolume then
		settings.MusicVolume = music
		changed = true
	end
	local sfx = level(request.SfxVolume)
	if sfx ~= nil and sfx ~= settings.SfxVolume then
		settings.SfxVolume = sfx
		changed = true
	end
	if type(request.Shadows) == "boolean" and request.Shadows ~= settings.Shadows then
		settings.Shadows = request.Shadows
		changed = true
	end
	if type(request.ReducedVFX) == "boolean" and request.ReducedVFX ~= settings.ReducedVFX then
		settings.ReducedVFX = request.ReducedVFX
		changed = true
	end

	if changed then
		StateService.markDirty(player)
	end
	return changed
end

function SettingsService.start()
	Remotes.get("SettingsRequest").OnServerEvent:Connect(function(player, request)
		if not limiter:consume(player) then
			return
		end
		SettingsService.apply(player, request)
	end)

	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
	end)
end

return SettingsService
