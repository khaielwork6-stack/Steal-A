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

local SCHEMA_VERSION = 2
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

	-- Future migrations chain here: if version < 3 then ... end

	return profile
end

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
