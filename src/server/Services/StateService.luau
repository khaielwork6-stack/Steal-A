--!strict
--[[
	StateService
	The single server -> client replication path.

	Clients render replicated state and never compute rewards or ownership
	(GDD section 16). Pushes are coalesced onto a short timer so a burst of
	income ticks cannot spam the network.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local BaseService = require(script.Parent.BaseService)

local PUSH_INTERVAL = 0.25

local StateService = {}

local dirty: { [Player]: boolean } = {}

--- TutorialService installs itself here rather than being required, so the two
--- services do not form a cycle (TutorialService needs pushNow).
local tutorialProvider: ((Player) -> any)? = nil

function StateService.setTutorialProvider(fn: (Player) -> any)
	tutorialProvider = fn
end

--- IndexService does the same, and for the same reason: it needs notify and
--- pushNow, so it cannot be required from here.
local indexProvider: ((Player) -> any)? = nil

function StateService.setIndexProvider(fn: (Player) -> any)
	indexProvider = fn
end

export type ClientState = {
	cash: number,
	income: number,
	speedPower: number,
	walkSpeed: number,
	baseActivated: boolean,
	treadmillLevel: number,
	treadmillNextCost: number?,
	capacityTier: number,
	slotsUnlocked: number,
	slotsUsed: number,
	slotsNextCost: number?,
	trapCount: number,
	tutorialStage: number,
	highestZone: number,
	indexCount: number,
	index: any?, -- IndexService.Summary: per-zone counts and claim flags only
	plotName: string?,
	tutorial: any?,
}

local function build(player: Player): ClientState?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end

	local discovered = 0
	for _ in profile.Index do
		discovered += 1
	end

	local nextTreadmill = TreadmillConfig.nextTier(profile.TreadmillLevel)
	local nextCapacity = BaseConfig.nextUpgrade(profile.BaseCapacityTier)
	local plot = BaseService.getPlot(player)

	return {
		cash = profile.Cash,
		income = EconomyService.getIncome(player),
		speedPower = profile.SpeedPower,
		walkSpeed = GameConfig.walkSpeedFromPower(profile.SpeedPower),
		baseActivated = profile.BaseActivated,
		treadmillLevel = profile.TreadmillLevel,
		treadmillNextCost = if nextTreadmill then nextTreadmill.cost else nil,
		capacityTier = profile.BaseCapacityTier,
		slotsUnlocked = BaseConfig.slotsForTier(profile.BaseCapacityTier),
		slotsUsed = #profile.DisplayItems,
		slotsNextCost = if nextCapacity then nextCapacity.cost else nil,
		trapCount = profile.TrapCount,
		tutorialStage = profile.TutorialStage,
		highestZone = profile.HighestZoneReached,
		indexCount = discovered,
		index = if indexProvider then indexProvider(player) else nil,
		plotName = if plot then plot.Name else nil,
		tutorial = if tutorialProvider then tutorialProvider(player) else nil,
		inventory = profile.Inventory,
		storageUsed = #profile.Inventory,
		storageCapacity = StorageConfig.capacityForTier(profile.StorageTier),
		storageNextCost = (function()
			local next = StorageConfig.nextUpgrade(profile.StorageTier)
			return if next then next.cost else nil
		end)(),
	}
end

--- Marks a player's state as needing replication on the next tick.
function StateService.markDirty(player: Player)
	dirty[player] = true
end

function StateService.pushNow(player: Player)
	local state = build(player)
	if state then
		Remotes.get("StatePush"):FireClient(player, state)
	end
	dirty[player] = nil
end

--- One-off toast / feedback message.
function StateService.notify(player: Player, kind: string, message: string, detail: any?)
	Remotes.get("Notify"):FireClient(player, kind, message, detail)
end

--- A personal sound cue, named from AudioConfig. Positional world sounds do NOT
--- come through here - the server parents those to the part they belong to and
--- lets them replicate, so bystanders hear them from the right direction.
function StateService.sound(player: Player, cue: string)
	Remotes.get("SoundCue"):FireClient(player, cue)
end

--- The same toast to everybody. Used for genuinely server-wide events - the loot
--- refresh countdown and a jackpot appearing - and deliberately not for anything
--- personal, so a broadcast always means "look up, something happened to the
--- world".
function StateService.announce(kind: string, message: string, detail: any?, cue: string?)
	local notifyRemote = Remotes.get("Notify")
	local soundRemote = if cue then Remotes.get("SoundCue") else nil
	for _, player in Players:GetPlayers() do
		notifyRemote:FireClient(player, kind, message, detail)
		if soundRemote and cue then
			soundRemote:FireClient(player, cue)
		end
	end
end

function StateService.start()
	EconomyService.onChanged(StateService.markDirty)

	Players.PlayerRemoving:Connect(function(player)
		dirty[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(PUSH_INTERVAL)
			for player in dirty do
				if player.Parent then
					StateService.pushNow(player)
				else
					dirty[player] = nil
				end
			end
		end
	end)
end

return StateService
