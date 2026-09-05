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

-- ==========================================================
-- NORMALISATION
-- ==========================================================
--
-- The nine treadmill models were AI-generated, so their raw scales, footprints
-- and deck heights disagree with each other. Every one is normalised against the
-- constants below so a player never upgrades into something half the size or
-- standing at a different height.
--
-- SCALING IS UNIFORM. The long axis is matched to STANDARD_LENGTH and the model
-- keeps its own proportions; no axis is stretched independently, so wings,
-- arches and handlebars stay undeformed.
--
-- THE DECK IS MEASURED, NOT GUESSED. `deckHeight` is where that model's actual
-- walkable belt surface sits above its base, found by raycasting a grid over the
-- mesh (a single MeshPart gives us no belt part to read). Each model is then
-- SUNK by `deckHeight - STANDARD_DECK_HEIGHT` so every belt lands on the same
-- plane. Regenerate these numbers with the debug command:
--     DebugInvoke:Invoke("treadmills", nil, "measure")

--- Belt length every model is scaled to. Eight of the nine were authored at
--- exactly this, so almost nothing is distorted; only Inferno scales up.
TreadmillConfig.STANDARD_LENGTH = 13.0

--- Height of the walking surface above the plot floor. Deliberately identical to
--- the old placeholder deck, so safe volumes, corridor clearance and the map
--- layout are all untouched - and it stays under humanoid step height, which is
--- what lets a player walk straight on without a ramp.
TreadmillConfig.STANDARD_DECK_HEIGHT = 1.6

--- Invisible collision deck and detection volume. Slightly wider and longer than
--- the widest model so there is a lip to step onto and no belt overhangs it.
TreadmillConfig.DECK_SIZE = Vector3.new(12, 1.6, 13.6)
TreadmillConfig.TRIGGER_SIZE = Vector3.new(12, 12, 13.6)

export type Tier = {
	level: number,
	name: string,
	cost: number, -- Cash price to reach this level
	robuxProductKey: string?, -- looked up in MonetizationConfig
	gainPerTick: number,
	--- Key under ReplicatedStorage.GameAssets.Treadmills.
	modelKey: string,
	--- Uniform scale that brings this model's long axis to STANDARD_LENGTH.
	scale: number,
	--- Measured belt height above the model's base, AFTER `scale`.
	deckHeight: number,
}

TreadmillConfig.Tiers = {
	{ level = 1, name = "Rusty", cost = 0, gainPerTick = 2, -- granted by activation
		modelKey = "Rusty", scale = 1.0000, deckHeight = 2.558 },
	{ level = 2, name = "Velocity", cost = 15e3, robuxProductKey = "TreadmillTier2", gainPerTick = 12,
		modelKey = "Velocity", scale = 1.0000, deckHeight = 2.279 },
	{ level = 3, name = "Voltic", cost = 250e3, robuxProductKey = "TreadmillTier3", gainPerTick = 60,
		modelKey = "Voltic", scale = 1.0000, deckHeight = 1.917 },
	{ level = 4, name = "Inferno", cost = 5e6, robuxProductKey = "TreadmillTier4", gainPerTick = 300,
		modelKey = "Inferno", scale = 1.7173, deckHeight = 1.937 },
	{ level = 5, name = "Frostbite", cost = 100e6, robuxProductKey = "TreadmillTier5", gainPerTick = 1.5e3,
		modelKey = "Frostbite", scale = 1.0000, deckHeight = 2.286 },
	{ level = 6, name = "Midas", cost = 2.5e9, robuxProductKey = "TreadmillTier6", gainPerTick = 7.5e3,
		modelKey = "Midas", scale = 1.0000, deckHeight = 2.442 },
	{ level = 7, name = "Overclock", cost = 75e9, robuxProductKey = "TreadmillTier7", gainPerTick = 40e3,
		modelKey = "Overclock", scale = 1.0000, deckHeight = 2.934 },
	{ level = 8, name = "Eclipse", cost = 2.5e12, robuxProductKey = "TreadmillTier8", gainPerTick = 200e3,
		modelKey = "Eclipse", scale = 1.0000, deckHeight = 1.984 },
	{ level = 9, name = "Ascendant", cost = 100e12, robuxProductKey = "TreadmillTier9", gainPerTick = 1e6,
		modelKey = "Ascendant", scale = 1.0000, deckHeight = 1.548 },
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
