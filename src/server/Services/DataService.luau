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

local SCHEMA_VERSION = 6
local STORE_NAME = "PlayerProfiles_v1"

--- The longest a growth value may claim. NightService caps growth at
--- NightConfig.GROWTH_FULL_SECONDS; this is only the sanity bound a corrupt
--- save is clamped to on load.
local GROWTH_SECONDS_SANITY = 86400

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
	--- The exact visual scale rolled inside the Size tier when the instance
	--- spawned (v6). Absent on older saves; reconcile fills the tier's default.
	VisualScale: number?,
	--- Seconds of effective growth accrued while on display (v6). Capped by
	--- NightService; drives the maturity income/size bonus.
	GrowthSeconds: number?,
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
	--- The Settings panel. Volumes are 0-1 mixer levels; Shadows drives
	--- Lighting.GlobalShadows on the client; ReducedVFX is the Reduced Effects
	--- switch (no pop-ins, bobbing, breathing, sparkles or lighting tweens).
	Settings: {
		ReducedVFX: boolean,
		ScreenShake: boolean,
		MusicVolume: number?,
		SfxVolume: number?,
		Shadows: boolean?,
	},
	-- Robux purchase ids already granted. This MUST be durable: ProcessReceipt is
	-- retried across sessions and servers, so an in-memory set would re-grant a
	-- replayed receipt after a rejoin. Bounded - see MonetizationService.
	ProcessedReceipts: { string },
	-- The one-time onboarding Cash bridge (GameConfig.TUTORIAL_CASH_BRIDGE).
	-- Durable for the same reason as the receipt list: an in-memory flag would
	-- hand out another $1,000 on every rejoin.
	TutorialBridgeGranted: boolean,
	-- Trails bought with CASH. Robux trails are not listed here - Roblox owns
	-- that answer and MonetizationService asks it, so a refund or a revoke is
	-- reflected instead of being frozen into the save.
	TrailsOwned: { [string]: boolean },
	-- The equipped trail's key, or "" for none. Exactly one at a time.
	EquippedTrail: string,
	-- The one-time +10,000 Speed for joining the group. Durable for the same
	-- reason as the receipt list: an in-memory flag would pay out again on every
	-- rejoin. See GroupGiftService.
	GroupGiftClaimed: boolean,
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
		-- A base is ACTIVE from the moment it is assigned. There is no longer a
		-- separate "activate your base" purchase - being given a plot IS the
		-- activation. `reconcile` forces this true on every load, including for
		-- profiles saved back when it was something you had to buy.
		BaseActivated = true,
		BaseCapacityTier = 0,
		-- Level 1 comes with the base, for the same reason.
		TreadmillLevel = 1,
		TrapCount = GameConfig.STARTING_TRAPS,
		TutorialStage = 0,
		HighestZoneReached = 1,
		Index = {},
		ClaimedIndexRewards = {},
		DisplayItems = {},
		Inventory = {},
		StorageTier = 0,
		Lifetime = { Steals = 0, PvPSteals = 0, Secrets = 0, CashEarned = 0 },
		Settings = { ReducedVFX = false, ScreenShake = true, MusicVolume = 0.7, SfxVolume = 0.8, Shadows = true },
		ProcessedReceipts = {},
		TutorialBridgeGranted = false,
		TrailsOwned = {},
		EquippedTrail = "",
		GroupGiftClaimed = false,
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
		-- v4 is the economy rebalance.
		--
		-- The one-time tutorial Cash bridge used to be seeded here. It is now
		-- retired entirely (base activation is free, so there was nothing left
		-- for it to pay for) and `reconcile` marks every profile as having had
		-- it, so nothing can be granted retroactively.
		--
		-- Stored per-item income is NOT migrated here: `reconcile` recomputes
		--    BaseIncome, Rarity and FinalIncome from the live config on EVERY
		--    load, for every profile, at every version. Doing it as a one-shot
		--    migration would freeze today's numbers into the save and leave the
		--    next economy change with the same problem this one had.
		profile.SchemaVersion = 4
	end

	if version < 5 then
		-- v5 adds the group-join gift. Nobody has claimed it yet, so false is the
		-- only correct value; a nil here would be read as unclaimed anyway, but
		-- the field is written so the schema is explicit.
		if type(profile.GroupGiftClaimed) ~= "boolean" then
			profile.GroupGiftClaimed = false
		end
		profile.SchemaVersion = 5
	end

	if version < 6 then
		-- v6 adds the exact visual scale and the growth clock to every saved item.
		-- An old item never rolled a scale, so it gets its tier's low end (what it
		-- was shown at until now - no saved collection changes size), and starts
		-- its growth from zero. Additive: nothing else on the item is touched.
		for _, list in { profile.DisplayItems, profile.Inventory } do
			if type(list) == "table" then
				for _, item in list do
					if type(item) == "table" then
						if type(item.VisualScale) ~= "number" then
							item.VisualScale = RarityConfig.defaultVisualScale(item.Size)
						end
						if type(item.GrowthSeconds) ~= "number" then
							item.GrowthSeconds = 0
						end
					end
				end
			end
		end
		profile.SchemaVersion = 6
	end

	-- Future migrations chain here: if version < 7 then ... end

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

	-- The visual scale must be a finite number INSIDE its tier's range; a save
	-- cannot carry a 200x Normal. A missing value is the tier's low end.
	local visual = RarityConfig.clampVisualScale(item.Size, item.VisualScale)
	if item.VisualScale ~= visual then
		item.VisualScale = visual
		changed = true
	end

	-- Growth is seconds, finite, non-negative, and never absurd.
	local growth = tonumber(item.GrowthSeconds) or 0
	if growth ~= growth or growth == math.huge or growth == -math.huge then
		growth = 0
	end
	growth = math.clamp(growth, 0, GROWTH_SECONDS_SANITY)
	if item.GrowthSeconds ~= growth then
		item.GrowthSeconds = growth
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

	-- THE BASE IS ALWAYS ACTIVE. Forced here rather than only in the default
	-- profile, so a save written while activation was still a purchase loads as
	-- active too. Everything that gates on this - placement, storage, income,
	-- the treadmill, prompts, the tutorial - therefore initialises correctly on
	-- the very first push, with no separate unlock step to go wrong.
	profile.BaseActivated = true
	profile.TreadmillLevel = math.max(1, math.floor(tonumber(profile.TreadmillLevel) or 1))

	-- Deprecated. The one-time onboarding grant existed only to pay for the
	-- $1,000 base activation; with activation free it has nothing to buy, so it
	-- is no longer awarded. The field is kept so old saves still load cleanly.
	if type(profile.TutorialBridgeGranted) ~= "boolean" then
		profile.TutorialBridgeGranted = true
	end

	-- Settings: every field present, typed and in range, whatever the save says.
	if type(profile.Settings) ~= "table" then
		profile.Settings = defaults.Settings
	end
	local settings = profile.Settings
	local function level(value: any, fallback: number): number
		if type(value) ~= "number" or value ~= value then
			return fallback
		end
		return math.clamp(value, 0, 1)
	end
	settings.MusicVolume = level(settings.MusicVolume, 0.7)
	settings.SfxVolume = level(settings.SfxVolume, 0.8)
	if type(settings.Shadows) ~= "boolean" then
		settings.Shadows = true
	end
	if type(settings.ReducedVFX) ~= "boolean" then
		settings.ReducedVFX = false
	end
	if type(settings.ScreenShake) ~= "boolean" then
		settings.ScreenShake = true
	end

	-- Trails. Only CASH unlocks live here; Robux trails are answered by Roblox
	-- ownership so a refund is reflected rather than frozen into the save.
	if type(profile.TrailsOwned) ~= "table" then
		profile.TrailsOwned = {}
	end
	if type(profile.EquippedTrail) ~= "string" then
		profile.EquippedTrail = ""
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

	loading[player] = nil

	-- The read above yields, and a player can join and leave inside that window
	-- (a mis-click, a bad connection). PlayerRemoving has already fired for
	-- them, so `release` already ran and nothing will ever run it again: a
	-- profile stored now would sit in memory for the life of the server and be
	-- re-saved on every autosave, spending DataStore budget on a ghost.
	if not player.Parent then
		return
	end

	profiles[player] = reconcile(profile :: Profile)
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
