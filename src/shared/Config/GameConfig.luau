--!strict
--[[
	GameConfig
	Global tuning constants. Every number a designer might want to change lives in
	a config module, never inline in a service (GDD operating rules).
]]

local GameConfig = {}

GameConfig.MAX_PLAYERS = 7

-- Fresh account state (GDD section 4).
GameConfig.STARTING_CASH = 0
GameConfig.STARTING_SPEED_POWER = 10
GameConfig.STARTING_TRAPS = 3
GameConfig.STARTING_DISPLAY_SLOTS = 7
GameConfig.MAX_DISPLAY_SLOTS = 14

-- ==========================================================
-- MOVEMENT
-- ==========================================================
--
-- SpeedPower spans 10 to twenty BILLION, so it cannot drive WalkSpeed directly.
-- It is compressed logarithmically, then a PROGRESSION BOOST is layered on top.
--
-- WHY THE BOOST EXISTS
-- Log compression alone is too flat at the top. A player at 20B Speed was moving
-- 85 studs/s against a beginner's 18 - technically five times faster, but the
-- last few orders of magnitude of progression bought almost nothing, because
-- each 10x of Speed only ever adds a fixed 7.5 studs/s. The late game did not
-- FEEL like the numbers said it should.
--
-- The boost scales that same log measure into a multiplier that starts at
-- exactly 1.0 (so a new player is untouched and does not spawn zooming) and
-- rises smoothly to MAX_BOOST at the top of the progression. It is linear in log
-- space, which means it has no breakpoints - 999K and 1M are imperceptibly
-- different, exactly as they should be.
--
-- Roughly what it produces, against the old curve:
--     Speed 10     18.3  ->  18.3   (x1.00, unchanged)
--     Speed 900    30.7  ->  33.5   (x1.09)
--     Speed 10K    38.5  ->  44.3   (x1.15)
--     Speed 170K   47.7  ->  58.1   (x1.22)
--     Speed 18M    62.9  ->  83.7   (x1.33)
--     Speed 2.5B   79.0  -> 114.5   (x1.45)
--     Speed 20B    85.8  -> 128.6   (x1.50)
--
-- THIS DOES NOT CHANGE THE DISPLAYED STAT. A player with 127K Speed still reads
-- 127K everywhere; only how far that carries them per second changes.

GameConfig.WALKSPEED_BASE = 16
GameConfig.WALKSPEED_COEFFICIENT = 7.5
GameConfig.WALKSPEED_MIN = 18
--- Raised from 90 to clear the top of the boosted curve (~129 at the Airport
--- gate). Still a hard bound, so a runaway Speed value cannot produce a
--- character the physics engine cannot keep on the ground.
GameConfig.WALKSPEED_MAX = 140

--- Multiplier at the very top of progression. 1.0 would be the old curve.
GameConfig.SPEED_BOOST_MAX = 1.5

--- The log-space window the boost ramps across: from a brand new player to the
--- last zone's recommended Speed. Both ends are derived, not typed, so moving
--- the starting Speed or the final gate re-fits the curve automatically.
GameConfig.SPEED_BOOST_FLOOR_POWER = 10 -- STARTING_SPEED_POWER
GameConfig.SPEED_BOOST_CEILING_POWER = 20e9 -- the Airport gate

--- The compressed log measure everything below is built from.
local function logMeasure(power: number): number
	return math.log10(1 + math.max(power, 0) / 10)
end

--- How far through the progression a Speed value sits, 0 to 1, in log space.
--- Exposed so the guardians and any UI can reason about it the same way.
function GameConfig.progressionAlpha(power: number): number
	local floor = logMeasure(GameConfig.SPEED_BOOST_FLOOR_POWER)
	local ceiling = logMeasure(GameConfig.SPEED_BOOST_CEILING_POWER)
	if ceiling <= floor then
		return 0
	end
	return math.clamp((logMeasure(power) - floor) / (ceiling - floor), 0, 1)
end

--- WalkSpeed for a SpeedPower value. The single conversion in the game: the
--- player, the guardians and every recommendation all go through this, which is
--- what makes a displayed "Recommended Speed" mean something in the chase.
function GameConfig.walkSpeedFromPower(power: number): number
	local compressed = GameConfig.WALKSPEED_BASE + GameConfig.WALKSPEED_COEFFICIENT * logMeasure(power)
	local boost = 1 + (GameConfig.SPEED_BOOST_MAX - 1) * GameConfig.progressionAlpha(power)
	return math.clamp(compressed * boost, GameConfig.WALKSPEED_MIN, GameConfig.WALKSPEED_MAX)
end

-- Economy cadence.
GameConfig.INCOME_TICK = 1 -- seconds between aggregate Cash grants
GameConfig.AUTOSAVE_INTERVAL = 60
GameConfig.SELL_REFUND_SECONDS = 60 -- selling pays this many seconds of income

-- Interaction.
GameConfig.STEAL_HOLD_DURATION = 1.0
GameConfig.STEAL_INTERACTION_RANGE = 14

-- Art normalisation. Imported models arrive at wildly different scales (a
-- 0.5-stud crown next to a 14-stud treasure map), so LootModel scales every
-- asset to these heights on build rather than asking an artist to resize each
-- one by hand in Studio. The Big/Huge/Giant size roll multiplies on top.
GameConfig.LOOT_WORLD_HEIGHT = 5 -- loose in a zone socket, must read at distance
GameConfig.LOOT_TROPHY_HEIGHT = 6 -- on a base pedestal, seen up close

-- Guardians grow zone by zone, so walking into a later zone reads as dangerous
-- before the player has read a single number. Zone 1's Cop is the baseline the
-- tutorial was tuned against and does not move.
GameConfig.GUARDIAN_HEIGHT = 7 -- zone 1
GameConfig.GUARDIAN_HEIGHT_GROWTH = 0.085 -- compounding, per zone past the first
GameConfig.GUARDIAN_HEIGHT_MAX = 15 -- hard ceiling; the containment walls are 22

--- Costume height for a zone's guardian. Compounding rather than linear so the
--- early steps stay subtle and the late ones land: zone 1 is 7 studs, zone 6 is
--- ~10.4, zone 12 is capped near 15 - imposing, and still comfortably under the
--- lane walls, which is what stops a guardian from reading as a broken import.
function GameConfig.guardianHeightFor(zoneIndex: number): number
	local steps = math.max(0, zoneIndex - 1)
	local height = GameConfig.GUARDIAN_HEIGHT * (1 + GameConfig.GUARDIAN_HEIGHT_GROWTH) ^ steps
	return math.min(height, GameConfig.GUARDIAN_HEIGHT_MAX)
end

-- ==========================================================
-- LOOT LIFECYCLE
-- ==========================================================
--
-- THERE IS NO PER-SOCKET REFILL TIMER. A socket emptied by a successful theft
-- stays empty until the next GLOBAL refresh. That is the core of the pacing:
-- the world is picked clean, everybody watches the countdown, and the refresh
-- is a shared event rather than a private slot machine.
--
-- The only paths that put an item back into its own socket early are a guardian
-- reclaim and an unclaimed PvP drop, and both return the SAME instance - they
-- never roll a new one.

GameConfig.GUARDIAN_RETURN_DELAY = 2 -- after a guardian reclaims
GameConfig.DROPPED_RECLAIM_WINDOW = 8 -- before a PvP drop returns to origin
GameConfig.GLOBAL_REFRESH_INTERVAL = 300 -- the world reroll cadence
GameConfig.GLOBAL_REFRESH_WARNING = 10 -- countdown shown before it lands

--- Chance that ONE jackpot item is injected somewhere in the world at a global
--- refresh. This is a single SERVER-LEVEL roll per refresh, never one roll per
--- socket: 40+ independent rolls at any sane percentage would print the top item
--- constantly, which is exactly what this economy exists to stop.
GameConfig.JACKPOT_REFRESH_CHANCE = 0.10

-- ==========================================================
-- TUTORIAL
-- ==========================================================
--
-- The first steal is guaranteed so a brand new player always meets the same,
-- winnable opening: a Normal/Normal Ancient Vase.

GameConfig.TUTORIAL_ITEM_ID = "Museum_AncientVase"
GameConfig.TUTORIAL_ZONE = 1
GameConfig.TUTORIAL_SOCKET = 1
GameConfig.TUTORIAL_FINISH_DELAY = 9 -- seconds the zone-2 pointer stays up
--- Seconds the "EARNING $X/s" beat holds before the tutorial moves the player
--- on to the treadmill. It is a moment to notice the payoff, not an objective.
GameConfig.TUTORIAL_INCOME_DWELL = 5

-- RETIRED: the one-time onboarding Cash bridge.
--
-- It existed for exactly one reason - a new player earning $1/s could not afford
-- the $1,000 base activation in any reasonable time - so it topped them up on
-- their first placement. Base activation is now automatic and free, so the
-- bridge had nothing left to pay for.
--
-- It is deliberately gone rather than reduced. A grant of a thousand dollars
-- landing the instant you place your first $1/s item is indistinguishable, from
-- the player's side, from the income system being broken - which is exactly how
-- it was reported. The only thing that moves Cash on its own now is the passive
-- income tick, and that pays precisely what the HUD says it will.

-- Anti-exploit: max accepted requests per player per second, per remote.
GameConfig.RATE_LIMITS = {
	StealRequest = 4,
	PlaceLootRequest = 4,
	SellLootRequest = 4,
	BaseUpgradeRequest = 2,
	TreadmillUpgradeRequest = 2,
	BatSwingRequest = 4,
	TrapPlaceRequest = 3,
	IndexClaimRequest = 4,
	PurchaseRequest = 2,
	DropLootRequest = 3,
}

return GameConfig
