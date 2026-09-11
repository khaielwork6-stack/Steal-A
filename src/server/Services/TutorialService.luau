--!strict
--[[
	TutorialService
	The persistent T0-T9 opening (GDD section 4).

	The single most important rule here: the stage is DERIVED from actual saved
	data - is the tutorial item discovered, has Speed moved - and
	never merely trusted from a stale TutorialStage integer. That means a player
	who disconnects at any point, dies, gets caught, or rejoins on a different
	plot resumes at the right place automatically, and no recovery special-case
	is needed for each stage.

	A caught thief drops back to "go steal it again" without losing the rest of
	their tutorial progress.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local LootService = require(script.Parent.LootService)
local StateService = require(script.Parent.StateService)

local TutorialService = {}

-- Stage numbers. T1/T2 share one objective because "approach" and "steal" are
-- the same instruction to the player.
--- The stage NUMBERS are persisted in `Profile.TutorialStage` and must stay
--- stable, so ACTIVATE keeps its slot even though nothing can reach it any more.
--- Removing the number would silently move every saved player.
---
--- ACTIVATE is retired: a base is claimed and active the moment it is assigned,
--- so there is nothing to buy and no objective to show. A profile saved at that
--- stage re-derives forward to TRAIN on its next load.
local STAGE = {
	STEAL = 1,
	ESCAPE = 3,
	PLACE = 4,
	INCOME = 5,
	ACTIVATE = 6, -- RETIRED, never returned by deriveStage
	TRAIN = 7,
	NEXT_ZONE = 8,
	COMPLETE = 9,
}

export type TutorialState = {
	stage: number,
	--- The world arrow's target. There are no stage banners any more: the
	--- pointer is the whole presentation of a stage.
	target: Vector3?,
	--- True on exactly one push in a player's life: the first-ever start. The
	--- client shows the single opening popup and nothing else.
	showIntro: boolean?,
}

local nextZoneShownAt: { [Player]: number } = {}
--- Player -> os.clock until which the opening popup flag rides every push.
--- The first push can land before the client has wired its controllers (the
--- profile loads faster than forty modules require), so a single-tick flag
--- was lost on a slow client. Sending it for a window is safe: the client
--- shows it once and ignores repeats, and the saved flag still stops it ever
--- returning after a rejoin.
local introUntil: { [Player]: number } = {}
local INTRO_WINDOW = 20
--- Player -> os.clock of the last push made only to carry the intro. Pushes
--- are otherwise event-driven, and a fresh idle profile has no events: the
--- join push was the only one, and a client still wiring its controllers
--- missed it for good. Inside the window this pushes once a second instead.
local lastIntroPushAt: { [Player]: number } = {}
local INTRO_PUSH_INTERVAL = 1
local incomeShownAt: { [Player]: number } = {}
local cached: { [Player]: TutorialState } = {}

-- ==========================================================
-- HELPERS
-- ==========================================================

local function isCarryingTutorialItem(player: Player): boolean
	local loot = CarryService.getCarried(player)
	return loot ~= nil and loot.itemId == GameConfig.TUTORIAL_ITEM_ID
end

local function tutorialSocketPosition(): Vector3?
	local socket = LootService.getSocket(GameConfig.TUTORIAL_ZONE, GameConfig.TUTORIAL_SOCKET)
	return if socket then socket.part.Position else nil
end

local function firstEmptySlot(player: Player): BasePart?
	local plot = BaseService.getPlot(player)
	if not plot then
		return nil
	end
	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return nil
	end
	local free = BaseService.freeSlots(player)
	if #free == 0 then
		return nil
	end
	local slot = slots:FindFirstChild(string.format("DisplaySlot%02d", free[1]))
	return if slot and slot:IsA("BasePart") then slot else nil
end

local function plotPart(player: Player, name: string): BasePart?
	local plot = BaseService.getPlot(player)
	if not plot then
		return nil
	end
	local found = plot:FindFirstChild(name, true)
	return if found and found:IsA("BasePart") then found else nil
end

local function zoneTwoSignPosition(): Vector3?
	local map = workspace:FindFirstChild("Map")
	local signs = map and map:FindFirstChild("ZoneSigns")
	local sign = signs and signs:FindFirstChild("Sign_" .. ZoneConfig.Zones[2].id)
	if not sign then
		return nil
	end
	local board = sign:FindFirstChild("Board")
	return if board and board:IsA("BasePart") then board.Position else nil
end

-- ==========================================================
-- STAGE DERIVATION
-- ==========================================================

--- Works out where the player actually is from durable state, not from the
--- stored stage number. Order runs latest-to-earliest so the furthest genuine
--- progress always wins.
local function deriveStage(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		return STAGE.STEAL
	end

	if profile.TutorialStage >= STAGE.COMPLETE then
		return STAGE.COMPLETE
	end

	-- Index discovery is the durable marker: it survives selling the first item,
	-- so a player cannot be knocked back to "place it" by cashing it in. An
	-- earlier tutorial item counts too - a player who placed the Vase before the
	-- tutorial switched to the Mask has done this step, and must not be sent
	-- back to steal a Mask they were never asked for.
	local placedFirstItem = profile.Index[GameConfig.TUTORIAL_ITEM_ID] == true
	if not placedFirstItem then
		for _, legacyId in GameConfig.TUTORIAL_LEGACY_ITEM_IDS do
			if profile.Index[legacyId] == true then
				placedFirstItem = true
				break
			end
		end
	end
	local trained = profile.SpeedPower > GameConfig.STARTING_SPEED_POWER

	-- The base is always active, so placing the first item leads straight to the
	-- treadmill. There is no ACTIVATE step between them any more; INCOME is a
	-- short "look what it earns" beat that `evaluate` times out into TRAIN.
	if placedFirstItem and trained then
		return STAGE.NEXT_ZONE
	end
	if placedFirstItem then
		return STAGE.INCOME
	end

	-- Not yet placed: the carry itself tells us where we are.
	if isCarryingTutorialItem(player) then
		return if BaseService.isInOwnSafeZone(player) then STAGE.PLACE else STAGE.ESCAPE
	end

	-- Caught, died or dropped it: back to the steal without losing anything else.
	return STAGE.STEAL
end

-- ==========================================================
-- PRESENTATION
-- ==========================================================

--- Where the world arrow points for a stage. That is ALL a stage presents:
--- the objective banners ("STEAL YOUR FIRST ITEM", "PLACE YOUR STOLEN ITEM",
--- "NEXT: Pirate Island") were removed as screen noise, and the one opening
--- popup replaces the lot.
local function buildState(player: Player, stage: number): TutorialState
	if stage == STAGE.STEAL then
		return { stage = stage, target = tutorialSocketPosition() }
	elseif stage == STAGE.ESCAPE then
		local home = plotPart(player, "Spawn") or plotPart(player, "Slab")
		return { stage = stage, target = if home then home.Position else nil }
	elseif stage == STAGE.PLACE then
		local slot = firstEmptySlot(player)
		return { stage = stage, target = if slot then slot.Position else nil }
	elseif stage == STAGE.INCOME then
		return { stage = stage }
	elseif stage == STAGE.TRAIN then
		local frame = plotPart(player, "Frame")
		return { stage = stage, target = if frame then frame.Position else nil }
	elseif stage == STAGE.NEXT_ZONE then
		return { stage = stage, target = zoneTwoSignPosition() }
	end
	return { stage = STAGE.COMPLETE }
end

--- Read by StateService each push.
--- A player who has not yet stolen anything. BaseService starts them on the
--- hub, a few seconds from the tutorial item, rather than at their plot.
function TutorialService.isAtStart(player: Player): boolean
	return deriveStage(player) == STAGE.STEAL
end

function TutorialService.getState(player: Player): TutorialState?
	return cached[player]
end

-- ==========================================================
-- TICK
-- ==========================================================

local function evaluate(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return
	end

	local stage = deriveStage(player)

	-- "EARNING $X/s" is a beat, not a task. It used to end when the player had
	-- banked enough for the base activation; with activation gone it needs its
	-- own dwell, or it would flash past in a single tick on the way to TRAIN.
	if stage == STAGE.INCOME then
		local shownAt = incomeShownAt[player]
		if not shownAt then
			incomeShownAt[player] = os.clock()
		elseif os.clock() - shownAt >= GameConfig.TUTORIAL_INCOME_DWELL then
			stage = STAGE.TRAIN
		end
	end

	-- The zone-2 pointer is the one stage that ends on a timer rather than on a
	-- player action, so the tutorial does not sit on screen forever.
	if stage == STAGE.NEXT_ZONE then
		local shownAt = nextZoneShownAt[player]
		if not shownAt then
			nextZoneShownAt[player] = os.clock()
		elseif os.clock() - shownAt >= GameConfig.TUTORIAL_FINISH_DELAY then
			stage = STAGE.COMPLETE
		end
	end

	-- Persist immediately after any irreversible step, and never move backwards
	-- in the saved value: recovery re-derives forwards on its own.
	if stage > profile.TutorialStage then
		profile.TutorialStage = stage
	end

	local previous = cached[player]
	local state = buildState(player, stage)

	-- THE ONE OPENING POPUP, on a first-ever start and never again. The flag
	-- is flipped and saved before the push goes out, so a respawn, a rejoin or
	-- a second server can never show it twice.
	if not profile.TutorialIntroSeen then
		profile.TutorialIntroSeen = true
		introUntil[player] = os.clock() + INTRO_WINDOW
		if DataService.isPersistent() then
			task.spawn(DataService.save, player)
		end
	end
	local window = introUntil[player]
	if window and os.clock() < window then
		state.showIntro = true
	elseif window then
		introUntil[player] = nil
	end
	cached[player] = state

	local introDue = state.showIntro == true and os.clock() - (lastIntroPushAt[player] or 0) >= INTRO_PUSH_INTERVAL
	-- One push when the window closes, so the client sees the flag stop and
	-- disarms; without it an idle profile would carry the armed state forever.
	local introClosed = previous ~= nil and previous.showIntro == true and state.showIntro ~= true
	if not previous or previous.stage ~= state.stage or introDue or introClosed then
		if state.showIntro then
			lastIntroPushAt[player] = os.clock()
		end
		StateService.pushNow(player)
	end
end

--- True while `player` still needs their guaranteed first item.
local function needsTutorialItem(player: Player): boolean
	local profile = DataService.get(player)
	return profile ~= nil and profile.TutorialStage < STAGE.INCOME
end

--- True for THE tutorial item in the hands of someone still doing the tutorial:
--- the pinned item, from the pinned socket, carried by a player who has not yet
--- reached the income stage. CarryService asks this before turning a drop into
--- a floor item; for this one case the drop sends the item straight home.
---
--- `tutorialPin` rather than the item id alone: a Pharaoh Mask that simply
--- rolled into this socket is an ordinary Mask, not the tutorial's.
function TutorialService.isTutorialLoot(player: Player, loot: LootService.LootInstance): boolean
	if not loot.tutorialPin or loot.itemId ~= GameConfig.TUTORIAL_ITEM_ID then
		return false
	end
	if loot.zoneIndex ~= GameConfig.TUTORIAL_ZONE or loot.socketIndex ~= GameConfig.TUTORIAL_SOCKET then
		return false
	end
	return needsTutorialItem(player)
end

--- Whether `player` may steal a pinned tutorial item at all. The pin exists for
--- new players; anyone past their first item is turned away from it, or a
--- server with one new player in it would re-pin a free Pharaoh Mask for
--- everybody else every half second. Ordinary loot answers true.
function TutorialService.mayTakeLoot(player: Player, loot: LootService.LootInstance): boolean
	if not loot.tutorialPin then
		return true
	end
	return needsTutorialItem(player)
end

--- The item this service last pinned. Held so the maintainer can tell "the
--- socket is empty because MY item is out being carried" from "the socket is
--- empty because that item is gone" - the two used to look identical, and the
--- first case was being answered with a brand-new one.
local pinnedItem: LootService.LootInstance? = nil

--- Keeps the guaranteed tutorial item in its socket while anyone still needs it.
local function maintainTutorialLoot()
	local needed = false
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if profile and profile.TutorialStage < STAGE.INCOME then
			needed = true
			break
		end
	end
	if not needed then
		-- NOBODY NEEDS IT ANY MORE: RELEASE IT. Left pinned, the last Mask would
		-- stay reserved for a new player who is no longer in the server - one
		-- of Zone 1's four sockets locked to everyone until the Night refresh.
		-- Released, it is an ordinary one-off Mask for whoever gets there first,
		-- and with no tutorial player left nothing re-pins it, so this can never
		-- become a supply.
		local leftover = pinnedItem
		if leftover then
			leftover.tutorialPin = nil
			pinnedItem = nil
		end
		return
	end

	-- ONE PIN. If the last pinned instance is still tracked and is anywhere but
	-- sitting in its socket - reserved, carried, dropped, on its way back - then
	-- it IS the tutorial item and the socket is empty on purpose. Re-pinning here
	-- is exactly how duplicates were minted. Only once it has been placed or
	-- retired (LootService forgets it) is a fresh one pinned.
	local pinned = pinnedItem
	if pinned and LootService.get(pinned.id) == pinned and pinned.state ~= "Spawned" then
		return
	end

	local result = LootService.forceSocket(
		GameConfig.TUTORIAL_ZONE,
		GameConfig.TUTORIAL_SOCKET,
		GameConfig.TUTORIAL_ITEM_ID,
		1, -- Scale 1: the reference-size item, a Normal by label
		"Normal"
	)
	if result then
		-- Flagged every pass, not just when minted: forceSocket hands back an
		-- instance that was already correct without rebuilding it.
		result.tutorialPin = true
		pinnedItem = result
	end
end

function TutorialService.start()
	StateService.setTutorialProvider(TutorialService.getState)

	Players.PlayerRemoving:Connect(function(player)
		cached[player] = nil
		nextZoneShownAt[player] = nil
		incomeShownAt[player] = nil
		introUntil[player] = nil
		lastIntroPushAt[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(0.5)
			maintainTutorialLoot()
			for _, player in Players:GetPlayers() do
				evaluate(player)
			end
		end
	end)

	print("[TutorialService] tutorial state machine online")
end

--- Exposed for the debug bridge.
TutorialService.STAGE = STAGE
TutorialService.deriveStage = deriveStage

--- Debug only: lets the opening popup be shown again for a test.
function TutorialService.resetIntro(player: Player)
	local profile = DataService.get(player)
	if profile then
		profile.TutorialIntroSeen = false
	end
	introUntil[player] = nil
	lastIntroPushAt[player] = nil
	cached[player] = nil
end

return TutorialService
