--!strict
--[[
	TutorialService
	The persistent T0-T9 opening (GDD section 4).

	The single most important rule here: the stage is DERIVED from actual saved
	data - is the vase discovered, is the base activated, has Speed moved - and
	never merely trusted from a stale TutorialStage integer. That means a player
	who disconnects at any point, dies, gets caught, or rejoins on a different
	plot resumes at the right place automatically, and no recovery special-case
	is needed for each stage.

	A caught thief drops back to "go steal it again" without losing the rest of
	their tutorial progress.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local LootService = require(script.Parent.LootService)
local StateService = require(script.Parent.StateService)

local TutorialService = {}

-- Stage numbers. T1/T2 share one objective because "approach" and "steal" are
-- the same instruction to the player.
local STAGE = {
	STEAL = 1,
	ESCAPE = 3,
	PLACE = 4,
	INCOME = 5,
	ACTIVATE = 6,
	TRAIN = 7,
	NEXT_ZONE = 8,
	COMPLETE = 9,
}

export type TutorialState = {
	stage: number,
	objective: string,
	hint: string?,
	target: Vector3?,
}

local nextZoneShownAt: { [Player]: number } = {}
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

	-- Index discovery is the durable marker: it survives selling the vase, so a
	-- player cannot be knocked back to "place it" by cashing their first item in.
	local placedFirstItem = profile.Index[GameConfig.TUTORIAL_ITEM_ID] == true
	local trained = profile.SpeedPower > GameConfig.STARTING_SPEED_POWER

	if placedFirstItem and profile.BaseActivated and trained then
		return STAGE.NEXT_ZONE
	end
	if placedFirstItem and profile.BaseActivated then
		return STAGE.TRAIN
	end
	if placedFirstItem and profile.Cash >= BaseConfig.ACTIVATION_COST then
		return STAGE.ACTIVATE
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

local function buildState(player: Player, stage: number): TutorialState
	local profile = DataService.get(player)

	if stage == STAGE.STEAL then
		return {
			stage = stage,
			objective = "STEAL YOUR FIRST ITEM",
			hint = "Hold the prompt on the Ancient Vase. The guard is asleep.",
			target = tutorialSocketPosition(),
		}
	elseif stage == STAGE.ESCAPE then
		local home = plotPart(player, "Spawn") or plotPart(player, "Slab")
		return {
			stage = stage,
			objective = "GET BACK TO YOUR BASE!",
			hint = "Cross the red line - the guard cannot follow you past it.",
			target = if home then home.Position else nil,
		}
	elseif stage == STAGE.PLACE then
		local slot = firstEmptySlot(player)
		return {
			stage = stage,
			objective = "PLACE YOUR STOLEN ITEM",
			hint = "Stand on an empty display slot and interact.",
			target = if slot then slot.Position else nil,
		}
	elseif stage == STAGE.INCOME then
		local income = EconomyService.getIncome(player)
		return {
			stage = stage,
			objective = `EARNING {NumberFormat.income(income)}`,
			hint = "Displayed loot earns Cash every second.",
		}
	elseif stage == STAGE.ACTIVATE then
		local pad = plotPart(player, "BaseActivationPad")
		return {
			stage = stage,
			objective = `UPGRADE BASE - {NumberFormat.cash(BaseConfig.ACTIVATION_COST)}`,
			hint = "This unlocks your treadmill.",
			target = if pad then pad.Position else nil,
		}
	elseif stage == STAGE.TRAIN then
		local frame = plotPart(player, "Frame")
		return {
			stage = stage,
			objective = "TRAIN ON YOUR TREADMILL",
			hint = "Stand on it to gain Speed.",
			target = if frame then frame.Position else nil,
		}
	elseif stage == STAGE.NEXT_ZONE then
		local zone = ZoneConfig.Zones[2]
		return {
			stage = stage,
			objective = `NEXT: {zone.name}`,
			hint = `Recommended Speed {NumberFormat.short(zone.recommendedSpeed)}. Keep training!`,
			target = zoneTwoSignPosition(),
		}
	end

	-- COMPLETE: the tutorial is done and says nothing further. Zone requirements
	-- are communicated by the zone signs and the top progress bar, so a trailing
	-- "next goal" widget was pure duplication.
	return {
		stage = STAGE.COMPLETE,
		objective = "",
	}
end

--- Read by StateService each push.
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
	cached[player] = state

	if not previous
		or previous.stage ~= state.stage
		or previous.objective ~= state.objective
	then
		StateService.pushNow(player)
	end
end

--- Keeps the guaranteed Ancient Vase in its socket while anyone still needs it.
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
		return
	end

	LootService.forceSocket(
		GameConfig.TUTORIAL_ZONE,
		GameConfig.TUTORIAL_SOCKET,
		GameConfig.TUTORIAL_ITEM_ID,
		"Normal",
		"Normal"
	)
end

function TutorialService.start()
	StateService.setTutorialProvider(TutorialService.getState)

	Players.PlayerRemoving:Connect(function(player)
		cached[player] = nil
		nextZoneShownAt[player] = nil
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

return TutorialService
