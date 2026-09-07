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
local EventStandService = require(Services.EventStandService)
local EnvironmentService = require(Services.EnvironmentService)
local TutorialService = require(Services.TutorialService)
local RagdollService = require(Services.RagdollService)
local PvPService = require(Services.PvPService)
local MonetizationService = require(Services.MonetizationService)
local TrailService = require(Services.TrailService)
local StatsService = require(Services.StatsService)
local GroupGiftService = require(Services.GroupGiftService)
local LeaderboardService = require(Services.LeaderboardService)
local NightService = require(Services.NightService)
local SettingsService = require(Services.SettingsService)
local DebugService = require(Services.DebugService)

Players.CharacterAutoLoads = true

EnvironmentService.start()
DataService.start()
EconomyService.start()

-- The Index summary rides StatePush, so it has to be installed before the first
-- push goes out. Injected rather than required to keep the two services acyclic.
StateService.setIndexProvider(IndexService.summarise)
StateService.start()
IndexService.start()

-- Roblox's own player list (Tab) shows Speed | Money. It is fed from the SAME
-- snapshot the client HUD gets, on the same push, so the two can never differ.
StatsService.start()
StateService.onPushed(function(player, state)
	StatsService.reflect(player, state.cash, state.speedPower)
end)

-- Cross-service wiring is done here so the services themselves stay decoupled.
CarryService.setNotifier(function(player, kind, message)
	StateService.notify(player, kind, message)
end)

-- A drop the guardian can walk to waits for the guardian; one it cannot reach
-- (behind the red line) goes home on the old timer.
CarryService.setRecoveryCheck(GuardianService.canRecover)

-- The tutorial vase goes straight back to its pedestal when dropped, instead of
-- lying on the floor while the tutorial pins a replacement into the socket -
-- which is how a new player could mint duplicates by stealing and dropping in a
-- loop. Every other item keeps the normal reclaimable drop.
CarryService.returnsHomeOnDrop = TutorialService.isTutorialLoot

-- A brand-new player starts on the hub facing the Zone 01 gate; everyone else
-- starts at their plot.
BaseService.spawnsAtHub = TutorialService.isAtStart

-- The DROP button lives on StatePush, so a steal has to push immediately rather
-- than waiting for the next thing that happens to dirty the state.
StateService.setCarryProvider(CarryService.summariseCarry)
CarryService.setCarryChangedHandler(function(player)
	StateService.pushNow(player)
end)

-- ==========================================================
-- MONETIZATION WIRING
-- ==========================================================
--
-- The three Speed systems and the Cash pass are injected here rather than
-- required, so the services that APPLY them never depend on the service that
-- SELLS them. Each multiplier lands in exactly one formula:
--
--   Speed gamepass tier -> SpeedService training gain
--   Equipped trail      -> CarryService movement conversion
--   2x Cash             -> EconomyService income rate AND one-off earnings
--
-- Nothing here touches a saved stat, so none of them can compound.
SpeedService.trainingMultiplier = function(player)
	return MonetizationService.speedMultiplier(player)
end
CarryService.trailMultiplierFor = function(player)
	return TrailService.multiplierFor(player)
end
EconomyService.cashMultiplierFor = function(player)
	return MonetizationService.cashMultiplier(player)
end
TrailService.refreshMovement = function(player)
	SpeedService.applyMovement(player)
end
GroupGiftService.refreshMovement = function(player)
	SpeedService.applyMovement(player)
end

-- The group gift's claimed/unclaimed state rides the push, so the popup shows
-- CLAIMED on a reconnect without asking.
StateService.setGroupGiftProvider(GroupGiftService.summarise)

-- What the shop UIs render. Derived server-side every push: the client is told
-- what it owns and what it may be offered next, and decides neither.
StateService.setMonetizationProvider(function(player)
	local nextTier = MonetizationService.nextSpeedTier(player)
	return {
		speedMultiplier = MonetizationService.speedMultiplier(player),
		cashMultiplier = MonetizationService.cashMultiplier(player),
		ownsCashPass = MonetizationService.cashMultiplier(player) > 1,
		-- nil once they own 1024x, which is what tells the treadmill card to
		-- render its MAXED state instead of another purchase.
		nextSpeedTier = if nextTier
			then { key = nextTier.key, label = nextTier.label, robux = nextTier.robux, multiplier = nextTier.multiplier }
			else nil,
		trails = TrailService.summarise(player),
	}
end)

-- Ownership is only known after an async check, so everything derived from it
-- has to be re-applied once the answer lands - otherwise a player who owns 2x
-- Cash sees the un-doubled rate until something else happens to dirty it.
MonetizationService.onOwnershipChanged = function(player)
	EconomyService.recalculate(player)
	SpeedService.applyMovement(player)
	TrailService.applyVisual(player)
	StateService.pushNow(player)
end

-- A catch reclaims the loot - hands it to the guardian, which carries it back
-- to its socket; the launch itself is GuardianService's job.
--
-- This is ALSO the one legitimate trigger for the contextual Speed offer: it
-- means "you were carrying loot and the chase beat you", which is precisely the
-- failure the offer answers. The carrier is read BEFORE `reclaim`, which clears
-- it. Deliberately not hooked to deaths, resets, falls or voluntary drops.
GuardianService.setCatchHandler(function(loot)
	local thief = loot.carrier
	local zoneIndex = loot.zoneIndex
	CarryService.reclaim(loot)
	if thief then
		MonetizationService.offerAfterCatch(thief, zoneIndex)
	end
end)

-- Crossing the red line. Short and celebratory: the tutorial objective flips to
-- "PLACE YOUR STOLEN ITEM" on its own, so this must not repeat that instruction.
GuardianService.setEscapeHandler(function(loot, player)
	if not loot.escapeNotice then
		loot.escapeNotice = true
		StateService.notify(player, "success", "ESCAPED!")
		-- The sting. The client stops the chase music, plays it, and follows
		-- with the safe-zone cue half a second later (ChaseAudioController).
		StateService.sound(player, "EscapeSting")
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
TrailService.start()
ZoneSignService.start()
EventStandService.start()
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

-- After BaseService: the group gift pushes state, and the world boards read
-- profiles, both of which want every earlier service in place.
GroupGiftService.start()
LeaderboardService.start()

-- The Night cycle owns the world refresh, the guardian reset and the return to
-- the lobby, so it starts once every one of those systems is up.
NightService.start()
SettingsService.start()

DebugService.start()

-- Scenery is visible but hollow: 186 decorative parts across the twelve zones
-- were solid, which is what makes a fast player catch on a pillar and a guardian
-- jam on a cactus. The map is baked into the place file, so this runs at startup
-- rather than only at build time. See MapBuilder.applyDecorCollision.
do
	local MapBuilder = require(script.MapBuilder)
	local cleared = MapBuilder.applyDecorCollision()
	print(`[MapBuilder] decor made hollow: {cleared} part(s) no longer collide`)
end

-- Movement is owned by SpeedService/CarryService so the compressed formula and
-- the carry penalty are applied in exactly one place.
local function onPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(function()
			-- Respawns land the player where BaseService says home is: the hub
			-- circle until their first steal, their own plot after. Before the
			-- plot is assigned (the very first character, profile still
			-- loading) `assign` does the placing itself.
			task.wait(0.2)
			if not BaseService.getPlot(player) then
				return
			end
			local spawn = BaseService.homeSpawn(player)
			if spawn then
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
