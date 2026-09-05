--!strict
--[[
	DataService
	Profile load / save / migration (GDD section 17).

	Single responsibility: owning the durable player profile. No gameplay logic
	lives here - other services read and mutate the profile table they are handed
	and DataService decides when it reaches the DataStore.

	Durability rules:
	  * Placed display items are the durable truth.
	  * World loot and in-progress carries are session state and are NEVER saved.
	    A player who disconnects mid-carry loses the carry; the item returns to
	    its origin socket.
	  * Autosave on an interval, on PlayerRemoving, and on BindToClose.
	  * Session locking is deliberately not attempted here; Roblox's own
	    single-server-per-user guarantee plus UpdateAsync is sufficient for v1.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local SCHEMA_VERSION = 4
local STORE_NAME = "PlayerProfiles_v1"

local DataService = {}

export type DisplayItem = {
	InstanceId: string,
	ItemId: string,
	ZoneId: number,
	Rarity: string,
	Size: string,
	Mutation: string,
	BaseIncome: number,
	FinalIncome: number,
	SlotIndex: number,
}

export type Profile = {
	SchemaVersion: number,
	Cash: number,
	SpeedPower: number,
	BaseActivated: boolean,
	BaseCapacityTier: number,
	TreadmillLevel: number,
	TrapCount: number,
	TutorialStage: number,
	HighestZoneReached: number,
	Index: { [string]: boolean },
	ClaimedIndexRewards: { [string]: boolean },
	DisplayItems: { DisplayItem },
	Inventory: { DisplayItem }, -- stored, not earning; SlotIndex is unused here
	StorageTier: number,
	Lifetime: { Steals: number, PvPSteals: number, Secrets: number, CashEarned: number },
	Settings: { ReducedVFX: boolean, ScreenShake: boolean },
	-- Robux purchase ids already granted. This MUST be durable: ProcessReceipt is
	-- retried across sessions and servers, so an in-memory set would re-grant a
	-- replayed receipt after a rejoin. Bounded - see MonetizationService.
	ProcessedReceipts: { string },
	-- The one-time onboarding Cash bridge (GameConfig.TUTORIAL_CASH_BRIDGE).
	-- Durable for the same reason as the receipt list: an in-memory flag would
	-- hand out another $1,000 on every rejoin.
	TutorialBridgeGranted: boolean,
}

local store: DataStore? = nil
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}

--- Studio without API access must still boot and be playable.
local useDataStore = false

local function defaultProfile(): Profile
	return {
		SchemaVersion = SCHEMA_VERSION,
		Cash = GameConfig.STARTING_CASH,
		SpeedPower = GameConfig.STARTING_SPEED_POWER,
		BaseActivated = false,
		BaseCapacityTier = 0,
		TreadmillLevel = 0,
		TrapCount = GameConfig.STARTING_TRAPS,
		TutorialStage = 0,
		HighestZoneReached = 1,
		Index = {},
		ClaimedIndexRewards = {},
		DisplayItems = {},
		Inventory = {},
		StorageTier = 0,
		Lifetime = { Steals = 0, PvPSteals = 0, Secrets = 0, CashEarned = 0 },
		Settings = { ReducedVFX = false, ScreenShake = true },
		ProcessedReceipts = {},
		TutorialBridgeGranted = false,
	}
end

--- Explicit, additive migrations. Never silently drop unknown fields.
local function migrate(profile: Profile): Profile
	local version = profile.SchemaVersion or 0

	if version < 1 then
		-- Pre-versioned saves: fill anything the schema expects.
		local defaults = defaultProfile()
		for key, value in defaults :: any do
			if (profile :: any)[key] == nil then
				(profile :: any)[key] = value
			end
		end
		profile.SchemaVersion = 1
	end

	if version < 2 then
		-- v2 introduced storage: taking an item off display now stores it rather
		-- than selling it, so existing saves need somewhere to put it.
		if type(profile.Inventory) ~= "table" then
			profile.Inventory = {}
		end
		if type(profile.StorageTier) ~= "number" then
			profile.StorageTier = 0
		end
		profile.SchemaVersion = 2
	end

	if version < 3 then
		-- v3 introduced Robux purchases. An existing player has never had a
		-- receipt granted, so an empty list is correct and cannot re-grant.
		if type(profile.ProcessedReceipts) ~= "table" then
			profile.ProcessedReceipts = {}
		end
		profile.SchemaVersion = 3
	end

	if version < 4 then
		-- v4 is the economy rebalance. Two things happen here.
		--
		-- 1. The one-time tutorial Cash bridge. A profile that already activated
		--    its base is past the point the bridge exists to get them to, so it
		--    is marked spent - otherwise every existing player would be handed a
		--    top-up they were never meant to receive.
		if type(profile.TutorialBridgeGranted) ~= "boolean" then
			profile.TutorialBridgeGranted = profile.BaseActivated == true
		end

		-- 2. Stored per-item income. NOT done here: `reconcile` recomputes
		--    BaseIncome, Rarity and FinalIncome from the live config on EVERY
		--    load, for every profile, at every version. Doing it as a one-shot
		--    migration would freeze today's numbers into the save and leave the
		--    next economy change with the same problem this one had.
		profile.SchemaVersion = 4
	end

	-- Future migrations chain here: if version < 5 then ... end

	return profile
end

--- Rebuilds one saved item's economy fields from the live configs.
---
--- The DURABLE identity of a trophy is ItemId + Size + Mutation (+ InstanceId and
--- SlotIndex for bookkeeping). Its income is NOT durable and is never trusted
--- from the save: a $967/s Ancient Vase in an old profile must become a $1/s
--- Ancient Vase the moment it loads, or the old economy simply carries on inside
--- existing accounts.
---
--- Deterministic and idempotent: the output depends only on the item's identity
--- and the current config, so repeated joins - and a join after a failed save -
--- converge on exactly the same numbers instead of drifting.
local function reconcileItem(item: DisplayItem): boolean
	local def = LootConfig.ById[item.ItemId]
	if not def then
		-- An id we no longer ship. Leave it completely alone rather than zeroing
		-- someone's trophy; it is still theirs and may come back.
		return false
	end

	local changed = false
	local mutation = RarityConfig.normaliseMutation(item.Mutation)
	if mutation ~= item.Mutation then
		item.Mutation = mutation
		changed = true
	end
	if type(item.Size) ~= "string" or not RarityConfig.SizeById[item.Size] then
		item.Size = "Normal"
		changed = true
	end

	local zoneId = LootConfig.ZoneOf[item.ItemId]
	if item.ZoneId ~= zoneId then
		item.ZoneId = zoneId
		changed = true
	end
	if item.Rarity ~= def.rarity then
		item.Rarity = def.rarity
		changed = true
	end
	if item.BaseIncome ~= def.income then
		item.BaseIncome = def.income
		changed = true
	end

	local final = RarityConfig.finalIncome(def.income, item.Size, item.Mutation)
	if item.FinalIncome ~= final then
		item.FinalIncome = final
		changed = true
	end

	return changed
end

DataService.reconcileItem = reconcileItem

--- Repairs a loaded profile so a corrupt or partial save cannot crash services.
local function reconcile(profile: Profile): Profile
	local defaults = defaultProfile()
	for key, value in defaults :: any do
		if (profile :: any)[key] == nil then
			(profile :: any)[key] = value
		end
	end

	profile.Cash = math.max(0, tonumber(profile.Cash) or 0)
	profile.SpeedPower = math.max(GameConfig.STARTING_SPEED_POWER, tonumber(profile.SpeedPower) or 0)
	profile.TrapCount = math.max(0, math.floor(tonumber(profile.TrapCount) or 0))
	profile.HighestZoneReached = math.clamp(math.floor(tonumber(profile.HighestZoneReached) or 1), 1, 12)

	if type(profile.DisplayItems) ~= "table" then
		profile.DisplayItems = {}
	end
	if type(profile.Inventory) ~= "table" then
		profile.Inventory = {}
	end
	profile.StorageTier = math.max(0, math.floor(tonumber(profile.StorageTier) or 0))

	-- A corrupt receipt list must never be silently replaced with an empty one:
	-- that would let every past receipt be granted a second time. Only repair it
	-- when it is not a table at all, which means there is nothing to lose.
	if type(profile.ProcessedReceipts) ~= "table" then
		profile.ProcessedReceipts = {}
	end

	if type(profile.TutorialBridgeGranted) ~= "boolean" then
		profile.TutorialBridgeGranted = profile.BaseActivated == true
	end

	-- Recompute every stored item's economy from the live config. Runs on EVERY
	-- load, deliberately: saved income is a cache of a config value, never a
	-- source of truth, so this is what stops an old economy living on inside
	-- existing accounts. Aggregate $/s is rebuilt by EconomyService.recalculate
	-- once the player is set up, from these repaired values.
	local repaired = 0
	for _, item in profile.DisplayItems do
		if reconcileItem(item) then
			repaired += 1
		end
	end
	for _, item in profile.Inventory do
		if reconcileItem(item) then
			repaired += 1
		end
	end
	if repaired > 0 then
		print(`[DataService] rebuilt income on {repaired} saved item(s) from the current economy`)
	end

	return profile
end

local function key(player: Player): string
	return "player_" .. player.UserId
end

--- Blocks until the profile is available. Returns nil if the player left first.
function DataService.waitForProfile(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 10)
	while not profiles[player] and os.clock() < deadline do
		if not player.Parent then
			return nil
		end
		task.wait(0.05)
	end
	return profiles[player]
end

function DataService.get(player: Player): Profile?
	return profiles[player]
end

--- True when saves actually reach a DataStore.
---
--- ProcessReceipt must only report a purchase granted once the grant is durable,
--- so it needs to distinguish "the save failed" from "there is no DataStore in
--- this environment". Studio without API access is the latter: nothing can be
--- persisted, and refusing every receipt there would make purchases untestable.
function DataService.isPersistent(): boolean
	return useDataStore and store ~= nil
end

function DataService.load(player: Player)
	if profiles[player] or loading[player] then
		return
	end
	loading[player] = true

	local profile: Profile? = nil

	if useDataStore and store then
		local attempts = 0
		while attempts < 4 and not profile do
			attempts += 1
			local target = store :: DataStore
			local ok, result = pcall(function()
				return target:GetAsync(key(player))
			end)
			if ok then
				profile = if result then migrate(result :: Profile) else defaultProfile()
			else
				warn(`[DataService] load attempt {attempts} failed for {player.Name}: {result}`)
				task.wait(2 ^ attempts)
			end
		end

		if not profile then
			-- Never hand out a fresh profile after a failed read: that would let
			-- a save overwrite real progress. Kick instead.
			warn(`[DataService] giving up loading {player.Name}; removing to protect their save`)
			loading[player] = nil
			player:Kick("Could not load your save. Please rejoin in a moment.")
			return
		end
	else
		profile = defaultProfile()
	end

	profiles[player] = reconcile(profile :: Profile)
	loading[player] = nil
end

function DataService.save(player: Player): boolean
	local profile = profiles[player]
	if not profile or not useDataStore or not store then
		return false
	end

	local target = store :: DataStore
	local ok, err = pcall(function()
		target:UpdateAsync(key(player), function()
			return profile
		end)
	end)

	if not ok then
		warn(`[DataService] save failed for {player.Name}: {err}`)
	end
	return ok
end

function DataService.release(player: Player)
	DataService.save(player)
	profiles[player] = nil
	loading[player] = nil
end

function DataService.start()
	if useDataStore == false then
		local ok = pcall(function()
			local opened = DataStoreService:GetDataStore(STORE_NAME)
			-- A cheap probe: in Studio without API access this throws.
			opened:GetAsync("__probe")
			store = opened
		end)
		useDataStore = ok
		if not ok then
			warn("[DataService] DataStores unavailable (Studio API access off) - running with in-memory profiles")
		end
	end

	for _, player in Players:GetPlayers() do
		task.spawn(DataService.load, player)
	end
	Players.PlayerAdded:Connect(function(player)
		DataService.load(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		DataService.release(player)
	end)

	task.spawn(function()
		while true do
			task.wait(GameConfig.AUTOSAVE_INTERVAL)
			for player in profiles do
				task.spawn(DataService.save, player)
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		for player in profiles do
			task.spawn(DataService.save, player)
		end
		task.wait(3)
	end)
end

return DataService
