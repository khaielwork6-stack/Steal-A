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

-- ==========================================================
-- FARMING FEEL (client-side presentation only)
-- ==========================================================
--
-- None of this touches the reward. SpeedService remains the only thing that
-- grants SpeedPower, on its own server tick, and every number shown to the
-- player is read back from real state rather than predicted.

--- How close to the belt centre a standing player is held, and how quickly.
--- The hold only applies while the player is giving NO movement input, so
--- walking off is always instant and never fights the controls.
TreadmillConfig.CENTRE_SNAP_SPEED = 9 -- studs/sec of correction
TreadmillConfig.CENTRE_TURN_SPEED = 10 -- radians/sec of turn toward forward
TreadmillConfig.CENTRE_DEADZONE = 0.05 -- studs; below this, stop correcting

--- Lateral correction is faster than longitudinal. Stepping onto a treadmill,
--- the thing that reads as wrong is standing off the SIDE of the belt; being a
--- little forward or back of centre looks fine and correcting it hard feels like
--- being sucked to a point. Splitting the two is what makes the connection look
--- deliberate rather than magnetic.
TreadmillConfig.CENTRE_LATERAL_MULTIPLIER = 2.2

--- Studs back from the deck centre the player settles, toward the rear of the
--- belt. A real runner stands behind the console, not inside it, and centring on
--- the deck exactly put the character's chest through the display on the taller
--- tiers.
TreadmillConfig.STANCE_OFFSET = 1.6

--- WHICH WAY A RUNNER FACES, as a multiplier on the deck's own LookVector.
---
--- THE PLAYER USED TO FACE BACKWARDS and this is the constant that fixes it.
--- The invisible deck is built by MapBuilder from the plot's frame, so its
--- LookVector points out toward the corridor. The art is aligned separately, and
--- for every one of the nine models the console ends up at the OPPOSITE end - so
--- turning the player to the deck's raw LookVector pointed them at the back of
--- their own treadmill.
---
--- Verified visually on the Rusty tier (the one every player starts on) and by
--- measuring where the model's console cluster sits relative to the deck. The
--- nine models are authored consistently, so ONE sign covers all of them -
--- flipping this turns the player on every tier at once, which is what you want
--- if a future import arrives the other way round.
TreadmillConfig.PLAYER_FACING_SIGN = -1

--- Playback rate of the borrowed run animation. Slightly above 1 reads as
--- effort without looking sped-up.
TreadmillConfig.RUN_ANIMATION_SPEED = 1.15

--- Floating "+N Speed" text.
TreadmillConfig.POPUP_MIN_INTERVAL = 0.35 -- seconds between popups; gains between are summed
TreadmillConfig.POPUP_RISE = 3.0 -- studs travelled upward
TreadmillConfig.POPUP_LIFETIME = 0.9 -- seconds from spawn to gone
TreadmillConfig.POPUP_MAX_CONCURRENT = 6 -- hard cap, so nothing can ever pile up
TreadmillConfig.POPUP_SIDE_OFFSET = 3.0 -- studs out to the side, clear of the treadmill label
TreadmillConfig.POPUP_START_HEIGHT = 0.6 -- studs above the root; the tier label lives far higher up

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
	-- +20/tick (~80/s), raised from the old +12. Tiers 3-9 are deliberately
	-- UNCHANGED: the Cash economy was the thing that was broken, and multiplying
	-- every Speed gain to "match" it would just create the same problem on the
	-- other axis. Only this one step was retuned.
	{ level = 2, name = "Velocity", cost = 15e3, robuxProductKey = "TreadmillTier2", gainPerTick = 20,
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
