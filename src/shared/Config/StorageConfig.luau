--!strict
--[[
	StorageConfig
	Inventory (unequipped/stored loot) capacity.

	Storage is separate from DISPLAY capacity: display slots are what earn Cash,
	storage is where an item waits while the player decides to sell it or swap it
	back in. Taking an item off display should never destroy it, which is why
	clicking a trophy stores it rather than selling it.
]]

local StorageConfig = {}

StorageConfig.STARTING_CAPACITY = 10

export type Tier = {
	tier: number,
	capacity: number,
	cost: number,
}

StorageConfig.Tiers = {
	{ tier = 0, capacity = 10, cost = 0 },
	{ tier = 1, capacity = 15, cost = 500e3 },
	{ tier = 2, capacity = 20, cost = 5e6 },
	{ tier = 3, capacity = 30, cost = 50e6 },
	{ tier = 4, capacity = 45, cost = 500e6 },
	{ tier = 5, capacity = 65, cost = 5e9 },
	{ tier = 6, capacity = 90, cost = 50e9 },
} :: { Tier }

StorageConfig.MAX_TIER = #StorageConfig.Tiers - 1

function StorageConfig.capacityForTier(tier: number): number
	local entry = StorageConfig.Tiers[tier + 1]
	return if entry then entry.capacity else StorageConfig.STARTING_CAPACITY
end

--- Cost of moving from `tier` to `tier + 1`, or nil when maxed.
function StorageConfig.nextUpgrade(tier: number): Tier?
	return StorageConfig.Tiers[tier + 2]
end

return StorageConfig
