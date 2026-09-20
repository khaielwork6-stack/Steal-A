--!strict
--[[
	TutorialService
	The persisted T0-T9 stage machine (GDD section 4) and the guaranteed
	first-item mechanic.

	THE TUTORIAL-FILM PASS RETIRED THE PRESENTATION LAYER THIS SERVICE USED
	TO OWN: the objective line, the chevron trail and the target ring
	(TutorialController, deleted) are replaced by an in-engine short film
	(TutorialFilmService / TutorialFilmController). What is LEFT here is not
	that UI - it is real, non-cosmetic state other systems still read:

	  * Profile.TutorialStage, a persisted "how far in" signal FlyoverService
	    (the first-join camera tour), DailyRewardController (when to
	    auto-open) and AnalyticsSession (the QuitInTutorial bucket) all read
	    directly, independent of the film;
	  * the guaranteed first item - one Pharaoh Mask kept pinned in Zone 1's
	    own socket for any player who has not placed their first item yet
	    (`isTutorialLoot` / `mayTakeLoot`, used by CarryService).

	The single most important rule here, unchanged: the stage is DERIVED from
	actual saved data - is the tutorial item discovered, has Speed moved -
	and never merely trusted from a stale TutorialStage integer. That means a
	player who disconnects at any point, dies, gets caught, or rejoins on a
	different plot resumes at the right place automatically, and no recovery
	special-case is needed for each stage. A caught thief drops back to "go
	steal it again" without losing the rest of their progress.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local LootService = require(script.Parent.LootService)

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
	--- Persisted, monotonic, drives derivation. Never renumbered.
	stage: number,
	--- A short analytics label only (AnalyticsSession's QuitInTutorial
	--- bucket) - "steal", "escape", "place", "reveal", "income", "train",
	--- "nextZone", or nil at COMPLETE. NOT rendered anywhere any more; the
	--- film has its own copy (TutorialFilmConfig), unrelated to this.
	step: string?,
}

local nextZoneShownAt: { [Player]: number } = {}
local incomeShownAt: { [Player]: number } = {}
local cached: { [Player]: TutorialState } = {}

-- ==========================================================
-- HELPERS
-- ==========================================================

--- ANY item sitting SEALED on one of the player's pads: placed, not yet
--- revealed. This is the state the derivation used to fall through - see
--- THE SEALED WINDOW in deriveStage. Any item, not just the tutorial's
--- (owner, 2026-09-19): whatever the new player carried home is the one
--- they are about to open.
local function sealedTutorialItem(profile: DataService.Profile): DataService.DisplayItem?
	for _, item in profile.DisplayItems do
		if item.Hatched ~= true then
			return item
		end
	end
	return nil
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

	-- ANY ITEM COUNTS (owner, 2026-09-19). The derivation used to look for
	-- THE tutorial item - the pinned Mask, or the Vase before it - and only
	-- that: a new player who stole the crate next to it was still told
	-- "Steal your first treasure!" while carrying one. Every check below
	-- reads the player's real state instead: anything carried, anything
	-- sealed on a pad, anything ever revealed. The pinned item stays as a
	-- guarantee that SOMETHING is there to steal, not as the only thing that
	-- counts.
	--
	-- Index discovery is the durable marker: it survives selling the first
	-- item, so a player cannot be knocked back to "place it" by cashing it in.
	local placedFirstItem = next(profile.Index) ~= nil
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

	-- Not yet placed: the carry itself tells us where we are - ANY carry.
	if CarryService.getCarried(player) ~= nil then
		return if BaseService.isInOwnSafeZone(player) then STAGE.PLACE else STAGE.ESCAPE
	end

	-- THE SEALED WINDOW. Profile.Index[itemId] is written at the REVEAL
	-- (HatchService.commit, "DISCOVERY HAPPENS HERE"), not at placement. So a
	-- container placed on a pad but not yet opened is neither "carrying"
	-- (PLACE) nor "discovered" (INCOME), and this used to fall through to
	-- STEAL: a brand-new player who had just done the hardest part of the
	-- loop was told to go back to the museum and steal another one, for at
	-- least TUTORIAL_HATCH_SECONDS and in practice until they happened to find
	-- the Reveal prompt on their own. The sealed item IS the progress; it is
	-- emitted as PLACE (the persisted number is unchanged) and buildState
	-- tells the client it is the reveal beat.
	if sealedTutorialItem(profile) then
		return STAGE.PLACE
	end

	-- Caught, died or dropped it: back to the steal without losing anything else.
	return STAGE.STEAL
end

-- ==========================================================
-- ANALYTICS LABEL
-- ==========================================================

--- The step keyword for AnalyticsSession's QuitInTutorial bucket only - NOT
--- rendered anywhere. PLACE has two faces (walking to a pad while carrying,
--- vs. a container already sealed on one waiting to be opened), same
--- persisted stage number, different label.
local function stepFor(player: Player, stage: number): string?
	if stage == STAGE.STEAL then
		return "steal"
	elseif stage == STAGE.ESCAPE then
		return "escape"
	elseif stage == STAGE.PLACE then
		return if CarryService.getCarried(player) ~= nil then "place" else "reveal"
	elseif stage == STAGE.INCOME then
		return "income"
	elseif stage == STAGE.TRAIN then
		return "train"
	elseif stage == STAGE.NEXT_ZONE then
		return "nextZone"
	end
	return nil
end

--- A player who has not yet stolen anything.
function TutorialService.isAtStart(player: Player): boolean
	return deriveStage(player) == STAGE.STEAL
end

--- Read by AnalyticsSession for the QuitInTutorial bucket only.
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

	-- The zone-2 beat is the one stage that ends on a timer rather than on a
	-- player action, so the persisted stage does not sit below COMPLETE forever.
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

	cached[player] = { stage = stage, step = stepFor(player, stage) }
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
	Players.PlayerRemoving:Connect(function(player)
		cached[player] = nil
		nextZoneShownAt[player] = nil
		incomeShownAt[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(0.5)
			-- Each step protected: one bad socket or one bad profile must not
			-- end the tutorial for the whole server for the rest of its life.
			local maintained, maintainErr = pcall(function()
				maintainTutorialLoot()
			end)
			if not maintained then
				warn(`[TutorialService] tutorial loot upkeep failed: {maintainErr}`)
			end
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(function()
					evaluate(player)
				end)
				if not ok then
					warn(`[TutorialService] tutorial step failed for {player.Name}: {err}`)
				end
			end
		end
	end)

	print("[TutorialService] tutorial state machine online")
end

--- Exposed for the debug bridge.
TutorialService.STAGE = STAGE
TutorialService.deriveStage = deriveStage

return TutorialService
