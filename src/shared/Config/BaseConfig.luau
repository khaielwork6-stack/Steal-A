--!strict
--[[
	BaseConfig
	Display capacity levels, matching the reference progression's purchases.

	A player owns 7 display slots from the start. Level 1 costs $1,000 and
	grants no extra pad - it is the reference game's first, symbolic purchase
	and is kept for parity - Level 2 is the first that adds pads (7 -> 9).

	PHYSICAL PADS. A plot in the baked map carries fourteen pads; the builder
	now lays eighteen (MapConfig.DISPLAY_SLOTS_PER_BASE) for a rebuilt map.
	BaseService clamps the USABLE count to the pads a plot actually has, so a
	level that would exceed them can still be bought (the profile keeps the
	level) but its extra pads only appear once the plot has them.

	RETIRED: BaseConfig.ACTIVATION_COST. A base is claimed and ACTIVE from the
	moment it is assigned.
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
	{ tier = 1, slots = 7, cost = 1e3 },
	{ tier = 2, slots = 9, cost = 1e6 },
	{ tier = 3, slots = 10, cost = 75e6 },
	{ tier = 4, slots = 11, cost = 500e6 },
	{ tier = 5, slots = 12, cost = 1e9 },
	{ tier = 6, slots = 13, cost = 50e9 },
	{ tier = 7, slots = 14, cost = 500e9 },
	{ tier = 8, slots = 15, cost = 1e12 },
	{ tier = 9, slots = 16, cost = 25e12 },
	{ tier = 10, slots = 17, cost = 100e12 },
	{ tier = 11, slots = 18, cost = 500e12 },
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
