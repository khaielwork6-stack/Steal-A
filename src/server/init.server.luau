--!strict
--[[
	Server bootstrap.

	Starts services in dependency order. Each service owns exactly one concern -
	there is deliberately no god script here (GDD section 16).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Creates ReplicatedStorage.Remotes before any client tries to wait on it.
require(ReplicatedStorage.Shared.Remotes)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local Services = script.Services
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local BaseService = require(Services.BaseService)
local StateService = require(Services.StateService)
local LootService = require(Services.LootService)
local CarryService = require(Services.CarryService)
local GuardianService = require(Services.GuardianService)
local DebugService = require(Services.DebugService)

Players.CharacterAutoLoads = true

DataService.start()
EconomyService.start()
BaseService.start()
StateService.start()

-- Cross-service wiring is done here so the services themselves stay decoupled.
CarryService.setNotifier(function(player, kind, message)
	StateService.notify(player, kind, message)
end)

CarryService.setZoneBusyCheck(GuardianService.isZoneBusy)

-- A catch reclaims the loot; the launch itself is GuardianService's job.
GuardianService.setCatchHandler(function(loot)
	CarryService.reclaim(loot)
end)

GuardianService.setEscapeHandler(function(loot, player)
	if not loot.escapeNotice then
		loot.escapeNotice = true
		StateService.notify(player, "success", `You escaped with the {loot.name}!`)
	end
end)

CarryService.setDeliveredHandler(function(player, loot)
	-- Reaching your own safe zone permanently clears the guardian for this item.
	-- Placement itself is a deliberate player action, never automatic.
	if loot.state ~= "Carried" then
		return
	end
	GuardianService.stopChaseFor(loot)
	if not loot.deliveredNotice then
		loot.deliveredNotice = true
		StateService.notify(player, "success", `Safe! Place the {loot.name} on a display slot.`)
	end
end)

LootService.refreshWarning = function()
	for _, player in Players:GetPlayers() do
		StateService.notify(player, "info", "LOOT REFRESH in 10s")
	end
end

LootService.start()
CarryService.start()
GuardianService.start()
DebugService.start()

--- Applies the compressed movement formula. SpeedPower is never assigned to
--- WalkSpeed directly (GDD section 9).
local function applyMovement(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	local profile = DataService.waitForProfile(player)
	if not profile then
		return
	end
	humanoid.WalkSpeed = GameConfig.walkSpeedFromPower(profile.SpeedPower)
end

local function onPlayer(player: Player)
	if player.Character then
		task.spawn(applyMovement, player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		task.spawn(applyMovement, player, character)
		task.spawn(function()
			-- Respawns should land the player back on their own plot.
			task.wait(0.2)
			local plot = BaseService.getPlot(player)
			local spawn = plot and plot:FindFirstChild("Spawn")
			if spawn and spawn:IsA("BasePart") then
				character:PivotTo(spawn.CFrame * CFrame.new(0, 4, 0))
			end
		end)
	end)

	task.spawn(function()
		DataService.waitForProfile(player)
		EconomyService.recalculate(player)
		StateService.pushNow(player)
	end)
end

for _, player in Players:GetPlayers() do
	onPlayer(player)
end
Players.PlayerAdded:Connect(onPlayer)

print("[Server] Steal Something services started")
