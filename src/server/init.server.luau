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
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local Services = script.Services
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local BaseService = require(Services.BaseService)
local StateService = require(Services.StateService)
local LootService = require(Services.LootService)
local CarryService = require(Services.CarryService)
local GuardianService = require(Services.GuardianService)
local IndexService = require(Services.IndexService)
local PlacementService = require(Services.PlacementService)
local SpeedService = require(Services.SpeedService)
local ZoneSignService = require(Services.ZoneSignService)
local TutorialService = require(Services.TutorialService)
local RagdollService = require(Services.RagdollService)
local PvPService = require(Services.PvPService)
local MonetizationService = require(Services.MonetizationService)
local DebugService = require(Services.DebugService)

Players.CharacterAutoLoads = true

DataService.start()
EconomyService.start()

-- The Index summary rides StatePush, so it has to be installed before the first
-- push goes out. Injected rather than required to keep the two services acyclic.
StateService.setIndexProvider(IndexService.summarise)
StateService.start()
IndexService.start()

-- Cross-service wiring is done here so the services themselves stay decoupled.
CarryService.setNotifier(function(player, kind, message)
	StateService.notify(player, kind, message)
end)

CarryService.setZoneBusyCheck(GuardianService.isZoneBusy)

-- The DROP button lives on StatePush, so a steal has to push immediately rather
-- than waiting for the next thing that happens to dirty the state.
StateService.setCarryProvider(CarryService.summariseCarry)
CarryService.setCarryChangedHandler(function(player)
	StateService.pushNow(player)
end)

-- A catch reclaims the loot; the launch itself is GuardianService's job.
GuardianService.setCatchHandler(function(loot)
	CarryService.reclaim(loot)
end)

-- Crossing the red line. Short and celebratory: the tutorial objective flips to
-- "PLACE YOUR STOLEN ITEM" on its own, so this must not repeat that instruction.
GuardianService.setEscapeHandler(function(loot, player)
	if not loot.escapeNotice then
		loot.escapeNotice = true
		StateService.notify(player, "success", "ESCAPED!")
		StateService.sound(player, "Escape")
	end
end)

CarryService.setDeliveredHandler(function(player, loot)
	-- Reaching your own safe zone permanently clears the guardian for this item.
	-- Placement itself is a deliberate player action, never automatic.
	if loot.state ~= "Carried" then
		return
	end
	GuardianService.stopChaseFor(loot)

	-- Deliberately quiet in the normal case. This fires on reaching your own safe
	-- zone, moments after the escape toast above, and it used to add a SECOND
	-- message repeating the "place it on a display slot" objective that is
	-- already on screen. The only case that still needs a word is a delivery
	-- with no chase behind it, where the escape toast never fired at all.
	if not loot.escapeNotice and not loot.deliveredNotice then
		loot.deliveredNotice = true
		loot.escapeNotice = true
		StateService.notify(player, "success", "SAFE!")
		StateService.sound(player, "Escape")
	end
end)

LootService.refreshWarning = function()
	StateService.announce("info", `LOOT REFRESH in {GameConfig.GLOBAL_REFRESH_WARNING}s`)
end

-- Which zones the global refresh may drop a jackpot into.
--
-- Installed here rather than inside LootService so that service keeps knowing
-- nothing about players or profiles. A jackpot in a zone nobody online can reach
-- is not an event, so eligibility is the furthest zone ANY current player has
-- either already looted or has the Speed for - whichever is further - and every
-- zone up to it is fair game.
LootService.eligibleJackpotZones = function(): { number }
	local reach = 1
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if profile then
			reach = math.max(reach, profile.HighestZoneReached)
			for _, zone in ZoneConfig.Zones do
				if profile.SpeedPower >= zone.recommendedSpeed then
					reach = math.max(reach, zone.index)
				end
			end
		end
	end

	local zones = {}
	for index = 1, math.min(reach, ZoneConfig.COUNT) do
		table.insert(zones, index)
	end
	return zones
end

-- A jackpot is a world event: everyone is told, everyone is told WHERE, and
-- nobody is given it. Players still have to go and steal it.
LootService.onJackpot = function(loot)
	local zone = ZoneConfig.Zones[loot.zoneIndex]
	local zoneName = if zone then string.upper(zone.name) else "THE WORLD"
	local variant = ""
	if loot.size ~= "Normal" then
		variant ..= ` {loot.size}`
	end
	if loot.mutation ~= "Normal" then
		variant ..= ` {loot.mutation}`
	end
	StateService.announce(
		"success",
		`{string.upper(loot.rarity)}!  {loot.name}{variant} has appeared in {zoneName}  ({NumberFormat.income(loot.finalIncome)})`,
		"levelup",
		"NewDiscovery"
	)
	print(`[Jackpot] {loot.itemId} [{loot.rarity}] {loot.size}/{loot.mutation} -> zone {loot.zoneIndex} socket {loot.socketIndex}`)
end

LootService.start()
CarryService.start()
GuardianService.start()
PlacementService.start()
SpeedService.start()
-- Must follow SpeedService: a receipt grants its tier through it.
MonetizationService.start()
ZoneSignService.start()
TutorialService.start()
RagdollService.start()
RagdollService.setMovementRefresher(function(player)
	SpeedService.applyMovement(player)
end)
PvPService.start()

-- BaseService goes LAST on purpose. Assigning a plot fires the rebuild hook that
-- creates a player's display-slot prompts, so every listener must already be
-- registered. Starting it early meant a player was assigned before
-- PlacementService existed, their prompts were never created, and they simply
-- could not place anything - invisible to tests that call place() directly.
BaseService.start()

-- HUD "BASE" button. Refused while carrying so it cannot skip an escape run.
require(ReplicatedStorage.Shared.Remotes).get("TeleportHomeRequest").OnServerEvent:Connect(function(player)
	if CarryService.getCarried(player) then
		StateService.notify(player, "error", "Not while carrying loot - run it home!")
		return
	end
	local ok, reason = BaseService.teleportHome(player)
	if not ok and reason then
		StateService.notify(player, "error", reason)
	end
end)

DebugService.start()

-- Movement is owned by SpeedService/CarryService so the compressed formula and
-- the carry penalty are applied in exactly one place.
local function onPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
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
		SpeedService.applyMovement(player)
		StateService.pushNow(player)

		-- The push above races the client: a profile that loads instantly (Studio
		-- solo, or a warm DataStore) fires it before StarterPlayerScripts have
		-- connected to StatePush, so the client drops its only snapshot. State is
		-- otherwise only sent on CHANGE, so a fresh account with $0 income and no
		-- actions could sit on default values indefinitely - every panel showing
		-- 0/10 storage and a blank HUD until the player happened to earn
		-- something. Re-mark for a short while so a late listener still gets one.
		for _ = 1, 12 do
			task.wait(0.5)
			if not player.Parent then
				return
			end
			StateService.markDirty(player)
		end
	end)
end

for _, player in Players:GetPlayers() do
	onPlayer(player)
end
Players.PlayerAdded:Connect(onPlayer)

print("[Server] Steal Something services started")
