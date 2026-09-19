--!strict
--[[
	DebugCommands.Tutorial
	Studio-only test commands for the first-minute onboarding (the objective
	line, the chevron trail and the target ring). Loaded by DebugService;
	invoke through ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...)
	or the DebugRequest attribute bridge.

	PROFILE SAFETY. Studio with API access writes to the owner's REAL
	DataStore. `tutorialStep` touches nothing persisted - it only swaps which
	step's presentation is shown. The two commands that DO write the profile
	(`tutorialReset`, `tutorialSealed`) take a snapshot of every field they
	can touch first; a command that throws restores it on the spot, and
	`tutorialRestore` puts it back (and saves) when the test is over.

	  tutorialState                 derived stage, the pushed state, the
	                                profile's tutorial fields
	  tutorialStep <step|clear>     show one step's presentation (steal,
	                                escape, place, reveal, income, train,
	                                nextZone) regardless of the real one;
	                                "clear" puts the derived step back
	  tutorialReset                 back to stage 1 for this player: the
	                                tutorial item forgotten from the Index,
	                                so the derivation starts at "steal"
	  tutorialSealed                jump to the sealed-on-pad state: the
	                                newest tutorial item on the base is
	                                re-sealed with TUTORIAL_HATCH_SECONDS to
	                                run (place one first with steal/place)
	  tutorialRestore               put the snapshot back
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local BaseService = require(script.Parent.Parent.BaseService)
local DataService = require(script.Parent.Parent.DataService)
local StateService = require(script.Parent.Parent.StateService)
local TutorialService = require(script.Parent.Parent.TutorialService)

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

--- Everything these commands can change.
local SNAPSHOT_FIELDS = { "TutorialStage", "TutorialIntroSeen", "Index", "DisplayItems" }

local snapshots: { [Player]: { [string]: any } } = {}

local function snapshot(player: Player, profile: DataService.Profile)
	if snapshots[player] then
		return
	end
	local held = {}
	for _, field in SNAPSHOT_FIELDS do
		held[field] = copy((profile :: any)[field])
	end
	snapshots[player] = held
end

local function restore(player: Player): boolean
	local held = snapshots[player]
	local profile = DataService.get(player)
	if not held or not profile then
		return false
	end
	for field, value in held do
		(profile :: any)[field] = copy(value)
	end
	snapshots[player] = nil
	TutorialService.debugForceStep(player, nil)
	BaseService.rebuildDisplays(player)
	StateService.pushNow(player)
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return true
end

--- Runs `fn` with the profile snapshotted; a throw restores before it is
--- re-raised, so a half-applied test never reaches the DataStore.
local function guarded(player: Player, fn: (DataService.Profile) -> any): any
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	snapshot(player, profile)
	local ok, result = pcall(fn, profile)
	if not ok then
		restore(player)
		error(result)
	end
	return result
end

local function isTutorialItemId(itemId: string): boolean
	if itemId == GameConfig.TUTORIAL_ITEM_ID then
		return true
	end
	for _, legacyId in GameConfig.TUTORIAL_LEGACY_ITEM_IDS do
		if itemId == legacyId then
			return true
		end
	end
	return false
end

local commands = {}

commands.tutorialState = function(player: Player)
	local profile = DataService.get(player)
	local state = TutorialService.getState(player)
	local sealed = nil
	if profile then
		for _, item in profile.DisplayItems do
			if isTutorialItemId(item.ItemId) then
				sealed = { itemId = item.ItemId, slot = item.SlotIndex, hatched = item.Hatched, endsIn = (tonumber(item.HatchEndsAt) or 0) - os.time() }
			end
		end
	end
	return {
		derivedStage = TutorialService.deriveStage(player),
		state = state,
		-- A Vector3 does not survive the JSON bridge; the target as text does.
		targetText = if state and state.target then tostring(state.target) else nil,
		savedStage = profile and profile.TutorialStage,
		introSeen = profile and profile.TutorialIntroSeen,
		indexHasItem = profile and profile.Index[GameConfig.TUTORIAL_ITEM_ID] == true,
		tutorialItemOnBase = sealed,
		steps = TutorialService.debugSteps(),
		snapshotHeld = snapshots[player] ~= nil,
	}
end

commands.tutorialStep = function(player: Player, step: string?): any
	if step == nil or step == "clear" then
		TutorialService.debugForceStep(player, nil)
		return { forced = false }
	end
	if not TutorialService.debugForceStep(player, step) then
		return { error = `unknown step "{step}"`, steps = TutorialService.debugSteps() }
	end
	return { forced = step, note = "tutorialStep clear puts the derived step back" }
end

commands.tutorialReset = function(player: Player)
	return guarded(player, function(profile)
		profile.TutorialStage = TutorialService.STAGE.STEAL
		profile.Index[GameConfig.TUTORIAL_ITEM_ID] = nil
		for _, legacyId in GameConfig.TUTORIAL_LEGACY_ITEM_IDS do
			profile.Index[legacyId] = nil
		end
		TutorialService.debugForceStep(player, nil)
		StateService.pushNow(player)
		return {
			derivedStage = TutorialService.deriveStage(player),
			note = "the derivation now reads from the carry and the pads; tutorialRestore undoes this",
		}
	end)
end

commands.tutorialSealed = function(player: Player)
	return guarded(player, function(profile)
		local newest: DataService.DisplayItem? = nil
		for _, item in profile.DisplayItems do
			if isTutorialItemId(item.ItemId) then
				newest = item
			end
		end
		if not newest then
			return { error = "no tutorial item on the base - steal one and place it first (steal / place)" }
		end
		local item = newest :: DataService.DisplayItem
		item.Hatched = false
		item.HatchEndsAt = os.time() + GameConfig.TUTORIAL_HATCH_SECONDS
		profile.Index[GameConfig.TUTORIAL_ITEM_ID] = nil
		for _, legacyId in GameConfig.TUTORIAL_LEGACY_ITEM_IDS do
			profile.Index[legacyId] = nil
		end
		if profile.TutorialStage > TutorialService.STAGE.PLACE then
			profile.TutorialStage = TutorialService.STAGE.PLACE
		end
		TutorialService.debugForceStep(player, nil)
		BaseService.rebuildDisplays(player)
		StateService.pushNow(player)
		return {
			slot = item.SlotIndex,
			opensIn = GameConfig.TUTORIAL_HATCH_SECONDS,
			derivedStage = TutorialService.deriveStage(player),
			note = "expect step reveal: 'It's opening…' then 'Open it!' with the OPEN IT ring",
		}
	end)
end

commands.tutorialRestore = function(player: Player)
	return { restored = restore(player) }
end

return commands
