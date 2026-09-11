--!strict
--[[
	Server bootstrap.

	Starts services in dependency order. Each service owns exactly one concern -
	there is deliberately no god script here (GDD section 16).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Creates ReplicatedStorage.Remotes before any client tries to wait on it.
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
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
local GiftChestService = require(Services.GiftChestService)
local GroupGiftService = require(Services.GroupGiftService)
local LeaderboardService = require(Services.LeaderboardService)
local NightService = require(Services.NightService)
local SettingsService = require(Services.SettingsService)
local BaseGuardianService = require(Services.BaseGuardianService)
local HeistService = require(Services.HeistService)
local GuardianShopService = require(Services.GuardianShopService)
local SlapDisplayService = require(Services.SlapDisplayService)
local PortalService = require(Services.PortalService)
local HatchService = require(Services.HatchService)
local MysterySpawnService = require(Services.MysterySpawnService)
local OfflineService = require(Services.OfflineService)
local SpinWheelService = require(Services.SpinWheelService)
local StarterTaskService = require(Services.StarterTaskService)
local DebugService = require(Services.DebugService)

Players.CharacterAutoLoads = true

-- BEFORE DataService.start(): PlayerRemoving handlers fire in the order they
-- were connected, and a base robbery has to be resolved while BOTH profiles
-- are still in memory and still about to be saved. This one connection is
-- made first and hands off to HeistService once it exists.
local heistLeaveHook: (Player) -> () = function() end
Players.PlayerRemoving:Connect(function(player)
	heistLeaveHook(player)
end)

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

-- ==========================================================
-- THE BEGINNER CHECKLIST
-- ==========================================================
--
-- Three rows, each completed by the ONE service that already knows the real
-- thing happened. Wired here so StarterTaskService is not a dependency of any
-- of the three - and so the whole of "what completes a row" is one paragraph
-- rather than three lines buried in three files.
--
-- Every hook fires only from a path the SERVER has already committed to: a
-- carry that is live, a reveal that is flipped, a treadmill tick that has
-- paid. There is no client message anywhere in this.
CarryService.setStolenHandler(function(player)
	StarterTaskService.complete(player, "steal")
end)
SpeedService.onTrained = function(player)
	StarterTaskService.complete(player, "train")
end

-- The tutorial vase goes straight back to its pedestal when dropped, instead of
-- lying on the floor while the tutorial pins a replacement into the socket -
-- which is how a new player could mint duplicates by stealing and dropping in a
-- loop. Every other item keeps the normal reclaimable drop.
CarryService.returnsHomeOnDrop = TutorialService.isTutorialLoot
-- The pinned tutorial item is for new players only. It is re-pinned every half
-- second while anyone in the server still needs it, so without this every other
-- player could take a free Pharaoh Mask from that socket on a loop.
CarryService.mayTakeLoot = TutorialService.mayTakeLoot

-- A brand-new player starts on the hub facing the Zone 01 gate; everyone else
-- starts at their plot.
-- SPAWN AT YOUR OWN BASE, always. This used to be wired to
-- TutorialService.isAtStart so a brand-new player appeared on the hub circle
-- facing Zone 01; onboarding now claims a random plot and puts every player on
-- its porch, facing the avenue, with their displays already restored. The hook
-- stays because the hub spawn is still the right answer for a player with no
-- plot at all.
BaseService.spawnsAtHub = function(player: Player): boolean
	return BaseService.getPlot(player) == nil
end

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
	-- A guardian pass just bought (or confirmed on join) puts the equipped
	-- animal in the bay; the Slap appears in the Backpack the same way.
	BaseGuardianService.sync(player)
	PvPService.onOwnershipChanged(player)
	StateService.pushNow(player)
end

-- A guardian pass bought THIS session: if the bay is empty the new animal is
-- put on guard through the same equip path Storage uses (saved, validated
-- against ownership, pushed). An occupied bay is left alone.
MonetizationService.onGamePassPurchased = function(player, gamePassId)
	BaseGuardianService.autoEquipAfterPurchase(player, gamePassId)
end

-- ==========================================================
-- BASE STEALING AND BASE GUARDIANS
-- ==========================================================
--
-- A Steal receipt is delivered by HeistService against the exact reserved
-- item; a closed steal dialog frees the reservation and grants nothing; a
-- base guardian's hit on a thief carrying its owner's item sends it home.
-- The guardian pedestals own what is on sale; the purchase path checks a key
-- against them before opening any dialog.
MonetizationService.setGuardianSaleProvider(GuardianShopService.onSaleKeys)
MonetizationService.setStealHandler(HeistService.fulfil)
MonetizationService.setRevealHandler(HatchService.fulfil)
HatchService.onLockLifted = PlacementService.refreshPrompts
-- Both services only ever use a CANCELLED dialog to release what they were
-- holding; a completed one is ignored by both, because ProcessReceipt is the
-- only authority for delivery.
MonetizationService.onProductPromptClosed = function(player, productId, purchased)
	HeistService.onPromptClosed(player, productId, purchased)
	HatchService.onPromptClosed(player, productId, purchased)
end
BaseGuardianService.onIntruderCaught = HeistService.onIntruderCaught
heistLeaveHook = HeistService.onPlayerLeaving

-- Live Robux prices landed or changed: repaint every sign and prompt that
-- shows one, and re-push every client so the cards follow.
MonetizationService.onPricesChanged = function()
	HeistService.retextPrompts()
	GuardianShopService.retext()
	SlapDisplayService.retext()
	for _, player in Players:GetPlayers() do
		-- The treadmill board's Robux button shows the live price.
		SpeedService.refreshTreadmill(player)
		StateService.markDirty(player)
	end
end

-- The treadmill upgrade board: its Robux button and price come from
-- MonetizationService, which requires SpeedService, so both are injected.
SpeedService.robuxPriceFor = function(productKey)
	local id = MonetizationConfig.productIdFor(productKey)
	local live = if id then MonetizationService.liveProductPrice(id) else nil
	if live then
		return live
	end
	local product = MonetizationConfig.ProductByKey[productKey]
	return if product then product.robux else nil
end
SpeedService.promptRobuxUpgrade = function(player)
	return MonetizationService.promptTreadmillUpgrade(player)
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
		-- ONE sound for the escape. The client stops the chase music on this
		-- cue (ChaseAudioController) and AudioController plays it; the old
		-- sting-then-cue pair is gone.
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

-- RETIRED: the jackpot eligibility and announcement hooks. Every item is an
-- ordinary socket roll at its zone weight; Secret-and-above spawns are called
-- out by NightService's spotlight after each refresh, which reads what was
-- rolled and never feeds back into a roll.

-- The hatch reveal payload. Deliberately thin: the pedestal to animate and
-- the two colours the burst uses. No income, no odds, nothing the client
-- could have used before the commit - by then the trophy is already on the
-- base and every client can see it anyway.
HatchService.onHatched = function(player, item)
	-- The checklist's "Reveal 1 Item", first: this runs from inside
	-- HatchService.commit AFTER the flag is flipped, so the reveal is already
	-- real and irreversible by the time the row is ticked.
	StarterTaskService.complete(player, "reveal")

	local plot = BaseService.getPlot(player)
	local slots = plot and plot:FindFirstChild("DisplaySlots")
	local slot = slots and slots:FindFirstChild(string.format("DisplaySlot%02d", item.SlotIndex))
	-- WHAT THE PRIZE IS, sent only now. This fires from HatchService.commit,
	-- AFTER the flag is flipped and the income has started, so the reward is
	-- already the player's and already banked: the client is being told what
	-- it won so it can draw it, not being asked what it should win. The
	-- silhouette roulette reads its last frame from itemId and cannot reach
	-- anything that decides a reward.
	local def = LootConfig.ById[item.ItemId]
	Remotes.get("HatchReveal"):FireClient(player, {
		slot = slot,
		instanceId = item.InstanceId,
		itemId = item.ItemId,
		itemName = if def then def.name else item.ItemId,
		rarity = item.Rarity,
		zoneIndex = item.ZoneId,
		size = item.Size,
		mutation = RarityConfig.normaliseMutation(item.Mutation),
		rarityColor = RarityConfig.Colors[item.Rarity] or Color3.new(1, 1, 1),
		mutationColor = RarityConfig.MutationColors[RarityConfig.normaliseMutation(item.Mutation)]
			or Color3.fromRGB(226, 236, 255),
	})
end

LootService.start()
CarryService.start()
GuardianService.start()
PlacementService.start()
SpeedService.start()
-- After BaseService and EconomyService: a commit rebuilds the base and
-- recalculates income through both of them.
HatchService.start()
-- Must follow SpeedService: a receipt grants its tier through it.
MonetizationService.start()
TrailService.start()
ZoneSignService.start()
EventStandService.start()
TutorialService.start()
-- Registers its StatePush provider, so it must be up before the first push a
-- joining player gets - which is what draws the checklist on their first frame.
StarterTaskService.start()
RagdollService.start()
RagdollService.setMovementRefresher(function(player)
	SpeedService.applyMovement(player)
end)
PvPService.start()

-- Both listen for the plot rebuild that assignment fires, so they must be
-- registered before BaseService hands out a single plot.
BaseGuardianService.start()
HeistService.start()
-- Also listens for the plot rebuild: a wheel belongs to whoever holds the plot
-- it stands on, so it has to be registered before the first plot is handed out.
SpinWheelService.start()

-- BaseService goes LAST on purpose. Assigning a plot fires the rebuild hook that
-- creates a player's display-slot prompts, so every listener must already be
-- registered. Starting it early meant a player was assigned before
-- PlacementService existed, their prompts were never created, and they simply
-- could not place anything - invisible to tests that call place() directly.
BaseService.start()

-- After BaseService: the group gift pushes state, and the world boards read
-- profiles, both of which want every earlier service in place.
GroupGiftService.start()
GiftChestService.start()
LeaderboardService.start()
GuardianShopService.start()
SlapDisplayService.start()
PortalService.start()

-- The Night cycle owns the world refresh, the guardian reset and the return to
-- the lobby, so it starts once every one of those systems is up.
NightService.start()
SettingsService.start()

-- Offline earnings ride DataService's save hook and StatePush, both of which
-- exist by now; the absence itself is settled per player below, once the
-- income has been rebuilt from the loaded profile.
OfflineService.start()

DebugService.start()

-- Scenery is visible but hollow: 186 decorative parts across the twelve zones
-- were solid, which is what makes a fast player catch on a pillar and a guardian
-- jam on a cactus. The map is baked into the place file, so this runs at startup
-- rather than only at build time. See MapBuilder.applyDecorCollision.
do
	local MapBuilder = require(script.MapBuilder)
	local cleared = MapBuilder.applyDecorCollision()
	print(`[MapBuilder] decor made hollow: {cleared} part(s) no longer collide`)
	-- The kit's snow was baked over the Secret Lab; it belongs to the North
	-- Pole. Moved (once) at start, sized and rated for zone 5.
	if MapBuilder.relocateWeather(9, 5) then
		print("[MapBuilder] snow moved from the Secret Lab to the North Pole")
	end
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
		-- AFTER the income is rebuilt: the absence is measured once, banked as
		-- a pending claim, and the claim modal rides the first push below.
		OfflineService.settle(player)
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
