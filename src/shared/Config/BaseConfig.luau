--!strict
--[[
	BaseConfig
	Display capacity tiers.

	A player owns 7 display slots from the start; the first capacity upgrade
	takes them 7 -> 8 for $1M.

	RETIRED: BaseConfig.ACTIVATION_COST. A base is claimed and ACTIVE from the
	moment it is assigned, so there is nothing to activate and nothing to pay
	for. The first real Cash sink is now the $15,000 treadmill upgrade.
]]

local BaseConfig = {}

BaseConfig.PLOT_COUNT = 7

export type CapacityTier = {
	tier: number,
	slots: number,
	cost: number,
}

BaseConfig.CapacityTiers = {
	{ tier = 0, slots = 7, cost = 0 }, -- included
	{ tier = 1, slots = 8, cost = 1e6 },
	{ tier = 2, slots = 9, cost = 5e6 },
	{ tier = 3, slots = 10, cost = 25e6 },
	{ tier = 4, slots = 11, cost = 75e6 },
	{ tier = 5, slots = 12, cost = 250e6 },
	{ tier = 6, slots = 13, cost = 1e9 },
	{ tier = 7, slots = 14, cost = 5e9 },
} :: { CapacityTier }

BaseConfig.MAX_TIER = #BaseConfig.CapacityTiers - 1

--- Unlocked display slots at a capacity tier.
function BaseConfig.slotsForTier(tier: number): number
	local entry = BaseConfig.CapacityTiers[tier + 1]
	return if entry then entry.slots else BaseConfig.CapacityTiers[1].slots
end

--- Cost of moving from `tier` to `tier + 1`, or nil when maxed.
function BaseConfig.nextUpgrade(tier: number): CapacityTier?
	return BaseConfig.CapacityTiers[tier + 2]
end

return BaseConfig
