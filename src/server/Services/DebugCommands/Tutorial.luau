--!strict
--[[
	DebugCommands.Tutorial
	Studio-only test commands for what is LEFT of TutorialService after the
	tutorial-film pass: the persisted stage machine and the guaranteed first
	item. The objective line / chevron trail / target ring presentation this
	file used to test (`tutorialStep`, `tutorialSteps`) is gone with
	TutorialController - see DebugCommands.TutorialFilm for the film's own
	commands. Loaded by DebugService; invoke through
	ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...) or the
	DebugRequest attribute bridge.

	PROFILE SAFETY. Studio with API access writes to the owner's REAL
	DataStore. The two commands that write the profile (`tutorialReset`,
	`tutorialSealed`) take a snapshot of every field they can touch first; a
	command that throws restores it on the spot, and `tutorialRestore` puts
	it back (and saves) when the test is over.

	  tutorialState                 derived stage, the analytics step label,
	                                the profile's tutorial fields
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

local commands = {}

commands.tutorialState = function(player: Player)
	local profile = DataService.get(player)
	local state = TutorialService.getState(player)
	local sealed = nil
	if profile then
		for _, item in profile.DisplayItems do
			if item.Hatched ~= true then
				sealed = { itemId = item.ItemId, slot = item.SlotIndex, hatched = item.Hatched, endsIn = (tonumber(item.HatchEndsAt) or 0) - os.time() }
			end
		end
	end
	return {
		derivedStage = TutorialService.deriveStage(player),
		step = state and state.step,
		savedStage = profile and profile.TutorialStage,
		indexHasItem = profile and profile.Index[GameConfig.TUTORIAL_ITEM_ID] == true,
		sealedOnBase = sealed,
		snapshotHeld = snapshots[player] ~= nil,
	}
end

commands.tutorialReset = function(player: Player)
	return guarded(player, function(profile)
		-- The derivation counts ANY discovery, so a reset clears the whole
		-- Index (snapshotted; tutorialRestore puts it back). Items still on
		-- the pads keep deriving to the reveal step - clear the base first
		-- (clearDisplays) for a true fresh start.
		profile.TutorialStage = TutorialService.STAGE.STEAL
		profile.Index = {}
		StateService.pushNow(player)
		return {
			derivedStage = TutorialService.deriveStage(player),
			note = "any carry, any sealed pad and any discovery count; tutorialRestore undoes this",
		}
	end)
end

commands.tutorialSealed = function(player: Player)
	return guarded(player, function(profile)
		-- Any item on the base: the derivation no longer cares which.
		local newest: DataService.DisplayItem? = nil
		for _, item in profile.DisplayItems do
			newest = item
		end
		if not newest then
			return { error = "nothing on the base - steal something and place it first (steal / place)" }
		end
		local item = newest :: DataService.DisplayItem
		item.Hatched = false
		item.HatchEndsAt = os.time() + GameConfig.TUTORIAL_HATCH_SECONDS
		profile.Index[item.ItemId] = nil
		if profile.TutorialStage > TutorialService.STAGE.PLACE then
			profile.TutorialStage = TutorialService.STAGE.PLACE
		end
		BaseService.rebuildDisplays(player)
		StateService.pushNow(player)
		return {
			slot = item.SlotIndex,
			opensIn = GameConfig.TUTORIAL_HATCH_SECONDS,
			derivedStage = TutorialService.deriveStage(player),
			note = "derives back to PLACE / step 'reveal' until it opens",
		}
	end)
end

commands.tutorialRestore = function(player: Player)
	return { restored = restore(player) }
end

return commands
