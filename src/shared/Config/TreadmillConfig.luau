--!strict
--[[
	TreadmillConfig
	Speed training tiers (GDD section 9).

	Training is server-authoritative on a fixed 0.25s tick while the player stands
	in their own treadmill trigger. Never detect animation footsteps, and never
	let client effects drive reward frequency. The UI may label `gainPerTick` as
	"per step".

	Level 0 = treadmill visible but dark; the $1,000 Base Activation moves the
	player to level 1.
]]

local TreadmillConfig = {}

TreadmillConfig.TICK_INTERVAL = 0.25

export type Tier = {
	level: number,
	name: string,
	cost: number, -- Cash price to reach this level
	robuxProductKey: string?, -- looked up in MonetizationConfig
	gainPerTick: number,
}

TreadmillConfig.Tiers = {
	{ level = 1, name = "Basic", cost = 0, gainPerTick = 2 }, -- granted by activation
	{ level = 2, name = "Tier 2", cost = 15e3, robuxProductKey = "TreadmillTier2", gainPerTick = 12 },
	{ level = 3, name = "Tier 3", cost = 250e3, robuxProductKey = "TreadmillTier3", gainPerTick = 60 },
	{ level = 4, name = "Tier 4", cost = 5e6, robuxProductKey = "TreadmillTier4", gainPerTick = 300 },
	{ level = 5, name = "Tier 5", cost = 100e6, robuxProductKey = "TreadmillTier5", gainPerTick = 1.5e3 },
	{ level = 6, name = "Tier 6", cost = 2.5e9, robuxProductKey = "TreadmillTier6", gainPerTick = 7.5e3 },
	{ level = 7, name = "Tier 7", cost = 75e9, robuxProductKey = "TreadmillTier7", gainPerTick = 40e3 },
	{ level = 8, name = "Tier 8", cost = 2.5e12, robuxProductKey = "TreadmillTier8", gainPerTick = 200e3 },
	{ level = 9, name = "Tier 9", cost = 100e12, robuxProductKey = "TreadmillTier9", gainPerTick = 1e6 },
} :: { Tier }

TreadmillConfig.MAX_LEVEL = #TreadmillConfig.Tiers

function TreadmillConfig.tier(level: number): Tier?
	return TreadmillConfig.Tiers[level]
end

--- The tier a player at `level` would buy next, or nil when maxed.
function TreadmillConfig.nextTier(level: number): Tier?
	return TreadmillConfig.Tiers[level + 1]
end

--- SpeedPower gained per second at a level, for UI display only.
function TreadmillConfig.gainPerSecond(level: number): number
	local tier = TreadmillConfig.Tiers[level]
	if not tier then
		return 0
	end
	return tier.gainPerTick / TreadmillConfig.TICK_INTERVAL
end

return TreadmillConfig
