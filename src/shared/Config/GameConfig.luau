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
GameConfig.MAX_DISPLAY_SLOTS = 18

-- ==========================================================
-- POST-GAME EXTENSION
-- ==========================================================
--
-- The reference progression has eleven comparable zones; the Airport is this
-- game's own twelfth. It keeps its assets, items and every save, but it is
-- fenced: it is excluded from every parity table, test and simulation, its
-- loot weights are provisional, and it can be switched off here without
-- touching a zone table. `enabled = false` leaves the zone standing with
-- empty sockets (nothing spawns, nothing is announced); owned Airport items
-- keep earning and stay in the Index either way.
GameConfig.POSTGAME_EXTENSION = {
	enabled = true,
	zones = { 12 },
}

--- True when zone `index` is post-game content.
function GameConfig.isPostgameZone(index: number): boolean
	for _, zone in GameConfig.POSTGAME_EXTENSION.zones do
		if zone == index then
			return true
		end
	end
	return false
end

--- True when a post-game zone should spawn loot right now.
function GameConfig.postgameSpawnsEnabled(): boolean
	return GameConfig.POSTGAME_EXTENSION.enabled == true
end

-- ==========================================================
-- MOVEMENT
-- ==========================================================
--
-- SpeedPower spans 10 to hundreds of BILLIONS, so it cannot drive WalkSpeed
-- directly. It is compressed in two stages:
--
--   1. LOG COMPRESSION. The excess over the starting Speed is squeezed with a
--      log base 1.15 into an internal "progression" domain of 10..300.
--   2. LINEAR REMAP. That domain is mapped straight onto the physical range
--      BASE_WALK_SPEED..MAX_WALK_SPEED (16..300).
--
-- So a brand new player moves at exactly Roblox's default (16), the curve has
-- no breakpoints, and it never exceeds 300 - the point past which the physics
-- engine stops keeping a character on the ground.
--
-- What it produces:
--     Speed 10      16.0
--     Speed 1K      28.8
--     Speed 10K     54.8
--     Speed 100K    86.3
--     Speed 1M     118.5
--     Speed 170M   190.5
--     Speed 225M   194.4
--     Speed ~427B  300 (cap)
--
-- THIS DOES NOT CHANGE THE DISPLAYED STAT. A player with 127K Speed still reads
-- 127K everywhere; only how far that carries them per second changes. Saved
-- SpeedPower is never migrated, divided or rescaled for this curve.

GameConfig.WALKSPEED_BASE = 16
GameConfig.WALKSPEED_MIN = 16
--- The hard physical ceiling. Also the top of the internal progression domain.
GameConfig.WALKSPEED_MAX = 300
--- Log base of the compression. 1.15 is what puts 225M Speed at ~194 WalkSpeed.
GameConfig.WALKSPEED_LOG_BASE = 1.15
--- How much raw Speed excess feeds one unit of the log argument.
GameConfig.WALKSPEED_RAW_SCALE = 0.0015
--- Progression-domain units gained per unit of the log measure.
GameConfig.WALKSPEED_PROGRESSION_STEP = 2

--- The internal progression speed (10..300) for a Speed value. Exposed because
--- the treadmill's own award-cadence and the run animation both want the
--- compressed measure rather than the raw stat.
function GameConfig.progressionSpeedFromPower(power: number): number
	local base = GameConfig.STARTING_SPEED_POWER
	local raw = math.max((tonumber(power) or 0) - base, 0)
	if raw <= 0 then
		return base
	end
	local measure = math.log(1 + GameConfig.WALKSPEED_RAW_SCALE * raw) / math.log(GameConfig.WALKSPEED_LOG_BASE)
	return math.clamp(base + GameConfig.WALKSPEED_PROGRESSION_STEP * measure, base, GameConfig.WALKSPEED_MAX)
end

--- 0 at the starting Speed, 1 at the physical cap. The same fraction the
--- remap below uses, so anything that wants "how far along" (the treadmill
--- run cycle, a UI bar) reads the curve the movement actually uses.
function GameConfig.progressionAlpha(power: number): number
	local base = GameConfig.STARTING_SPEED_POWER
	local span = GameConfig.WALKSPEED_MAX - base
	if span <= 0 then
		return 0
	end
	return math.clamp((GameConfig.progressionSpeedFromPower(power) - base) / span, 0, 1)
end

--- WalkSpeed for a SpeedPower value. THE single conversion in the game: the
--- player, the guardians and every recommendation all go through this, which is
--- what makes a displayed "Recommended Speed" mean something in the chase.
function GameConfig.walkSpeedFromPower(power: number): number
	local t = GameConfig.progressionAlpha(power)
	local speed = GameConfig.WALKSPEED_BASE + t * (GameConfig.WALKSPEED_MAX - GameConfig.WALKSPEED_BASE)
	return math.clamp(speed, GameConfig.WALKSPEED_MIN, GameConfig.WALKSPEED_MAX)
end

-- ==========================================================
-- THE PREVIOUS CURVE, KEPT FOR CALIBRATION ONLY
-- ==========================================================
--
-- The guardians were tuned against this curve and the chase felt right. When
-- the player curve above replaced it, the guardians were NOT retuned by hand:
-- each zone's guardian keeps the same RATIO to a player at that zone's
-- recommended Speed that it had under this curve (see guardianGateWalkSpeed).
-- Nothing else reads this. Do not use it for movement.

local LEGACY_BASE = 16
local LEGACY_COEFFICIENT = 7.5
local LEGACY_MIN = 18
local LEGACY_MAX = 140
local LEGACY_BOOST_MAX = 1.5
local LEGACY_FLOOR_POWER = 10
local LEGACY_CEILING_POWER = 20e9

local function legacyLogMeasure(power: number): number
	return math.log10(1 + math.max(power, 0) / 10)
end

function GameConfig.legacyWalkSpeedFromPower(power: number): number
	local floor = legacyLogMeasure(LEGACY_FLOOR_POWER)
	local ceiling = legacyLogMeasure(LEGACY_CEILING_POWER)
	local alpha = if ceiling > floor then math.clamp((legacyLogMeasure(power) - floor) / (ceiling - floor), 0, 1) else 0
	local compressed = LEGACY_BASE + LEGACY_COEFFICIENT * legacyLogMeasure(power)
	local boost = 1 + (LEGACY_BOOST_MAX - 1) * alpha
	return math.clamp(compressed * boost, LEGACY_MIN, LEGACY_MAX)
end

-- ==========================================================
-- GUARDIAN CALIBRATION
-- ==========================================================
--
-- A guardian's baseline pace is derived from the zone's recommended Speed so
-- the number on the sign is a real threshold. Under the old curve that was
-- "the at-gate player's WalkSpeed minus ZoneConfig.GUARDIAN_GATE_MARGIN".
--
-- The new curve moves a late-game player several times faster in studs, so
-- carrying a fixed 1.5 studs/s margin across would have turned a tense chase
-- into a stroll. Instead the OLD guardian/player ratio is preserved:
--
--     oldRatio          = oldGuardian / oldPlayerAtGate
--     newGuardian       = newPlayerAtGate * oldRatio
--
-- ...corrected for the head start. The guardian spends GUARDIAN_WAKE_DELAY
-- standing still after a steal, and a faster player covers more ground in
-- that beat. Over a run of `runDistance` studs that extra head start is worth
-- (newPlayer - oldPlayer) * wake / runDistance in ratio terms, so it is added
-- back to keep the separation at the line approximately what it was in studs.
--
-- The correction is CAPPED so a player who meets the recommendation is still
-- fractionally faster than the guardian - the sign must stay honest and the
-- "at the bar you escape, narrowly" rule must survive every zone.

--- The shocked beat between a steal and the chase (GuardianService.WAKE_DELAY).
GameConfig.GUARDIAN_WAKE_DELAY = 0.55
--- The least a guardian may trail an at-gate player by, in studs/s.
GameConfig.GUARDIAN_MIN_GATE_MARGIN = 0.5

function GameConfig.guardianGateWalkSpeed(recommended: number, gateMargin: number, runDistance: number?): number
	local power = math.max(recommended, GameConfig.STARTING_SPEED_POWER)
	local newPlayer = GameConfig.walkSpeedFromPower(power)
	local oldPlayer = GameConfig.legacyWalkSpeedFromPower(power)
	local oldGuardian = math.max(oldPlayer - gateMargin, LEGACY_MIN * 0.5)
	local ratio = oldGuardian / oldPlayer

	local guardian = newPlayer * ratio
	local distance = runDistance or 0
	if distance > 1 then
		guardian += newPlayer * (newPlayer - oldPlayer) * GameConfig.GUARDIAN_WAKE_DELAY / distance
	end

	return math.clamp(guardian, GameConfig.WALKSPEED_MIN * 0.5, newPlayer - GameConfig.GUARDIAN_MIN_GATE_MARGIN)
end

-- Economy cadence.
GameConfig.INCOME_TICK = 1 -- seconds between aggregate Cash grants
GameConfig.AUTOSAVE_INTERVAL = 60

-- ==========================================================
-- THE INCOME FUNNEL
-- ==========================================================
--
--   preBoostRate = max(round(base x sizeFactor(Scale) x mutation x moneyPass), 1)   per item
--   finalRate    = round(preBoostRate x SERVER_EARNINGS_BOOST x TEMPORARY_EARNINGS_BOOST)
--
-- The two boosts are the reference funnel's server-wide and timed factors.
-- This game has no live boost event yet, so both are 1: the hooks exist so a
-- future event multiplies in exactly one place and never in two.
GameConfig.SERVER_EARNINGS_BOOST = 1
GameConfig.TEMPORARY_EARNINGS_BOOST = 1

-- SELLING. Paid from Storage as SELL_REFUND_SECONDS of the item's rate. The
-- reference game prices a sale from the item WITH ITS MUTATIONS STRIPPED
-- (verified); the function it prices from and the 0.8 it applies were not
-- reachable from this project, so the seconds figure below is this game's
-- own and is NOT a parity value. SELL_STATUS says so at runtime.
GameConfig.SELL_REFUND_SECONDS = 60
GameConfig.SELL_STRIPS_MUTATION = true
GameConfig.SELL_STATUS = "PROVISIONAL_SELL_FORMULA"

-- TRAINING. One standard tick per second. Speed gained per tick is
-- TRAINING_BASE_GAIN x the treadmill's factor x (1 + trail bonus + Speed-pass
-- bonus), where the trail and the pass ADD above their base factor and the
-- treadmill factor applies separately (TreadmillConfig.gainPerSecond).
-- The reference game's base gain behind its x2 / x5 / x12 ... factors was
-- not reachable from this project; 4 is chosen so the free x2 treadmill
-- keeps this game's existing 8 Speed/s. NOT a parity value.
GameConfig.TRAINING_BASE_GAIN = 4
GameConfig.TRAINING_STATUS = "BLOCKED_TRAINING_BASE"

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
GameConfig.GUARDIAN_HEIGHT = 7 -- zone 1; every other zone is authored relative to this

--- VISUAL height of each zone's guardian, in studs. THE ONE PLACE boss size
--- lives - buildRig scales the imported costume to exactly this. Authored as a
--- table rather than a growth rate because the brief wants the jump to READ:
--- zones 1-5 ease up, 6-12 climb hard, and the Airport guard is meant to be
--- frightening. The containment walls are 80 studs, so even 40 stays framed.
GameConfig.GUARDIAN_HEIGHTS = {
	7, -- 1  Museum      normal
	7.8, -- 2  Pirate      slightly larger
	8.8, -- 3  Castle      larger
	10, -- 4  Area 51     clearly larger
	11.5, -- 5  North Pole  intimidating
	14, -- 6  Egypt       large
	17, -- 7  Gym         very large
	20.5, -- 8  Bank        huge
	24.5, -- 9  Secret Lab  imposing
	29, -- 10 Grandma     massive
	34, -- 11 Construction enormous
	40, -- 12 Airport     frighteningly huge
}

--- The PHYSICS body does not grow with the costume past this multiple of the
--- zone-1 body. A 40-stud costume on a 40-stud collider jams on every doorway
--- and reads as a wall coming at you; a big costume over a body capped at
--- roughly two players tall still chases, corners and catches exactly like the
--- early zones. Catch radius scales with THIS, not with the visual height.
GameConfig.GUARDIAN_PHYSICS_MAX_GROWTH = 2.0

--- Costume height for a zone's guardian. Compounding rather than linear so the
--- early steps stay subtle and the late ones land: zone 1 is 7 studs, zone 6 is
--- ~10.4, zone 12 is capped near 15 - imposing, and still comfortably under the
--- lane walls, which is what stops a guardian from reading as a broken import.
--- The costume height for a zone, straight from the table. A zone past the end
--- of the table (a future thirteenth) gets the last entry rather than an error.
function GameConfig.guardianHeightFor(zoneIndex: number): number
	local heights = GameConfig.GUARDIAN_HEIGHTS
	return heights[math.clamp(zoneIndex, 1, #heights)]
end

--- How much bigger than zone 1's the PHYSICS body may be. Follows the costume
--- up to the cap and then holds, so the late zones look enormous and still
--- play like guardians rather than like moving buildings.
function GameConfig.guardianPhysicsGrowthFor(zoneIndex: number): number
	local growth = GameConfig.guardianHeightFor(zoneIndex) / GameConfig.GUARDIAN_HEIGHT
	return math.min(growth, GameConfig.GUARDIAN_PHYSICS_MAX_GROWTH)
end

--- The stock Roblox walk cycles, exactly the ids the default Animate script
--- ships as `walk.WalkAnim` for each rig type. Played on guardian costumes that
--- have a standard skeleton so a boss walks like a Roblox character; costumes
--- with no skeleton keep the procedural run in GuardianService.animateShell.
--- These are Roblox's own assets, playable in any experience - nothing here
--- was uploaded or guessed.
GameConfig.GUARDIAN_WALK_ANIMATIONS = {
	R6 = "rbxassetid://180426354",
	R15 = "rbxassetid://913402848",
} :: { [string]: string }

--- The stock idle (`idle.Animation1` in the same Animate script), played on a
--- rigged costume while its guardian sleeps at its post, so it breathes and
--- shifts instead of standing frozen. Same provenance as the walk cycles.
GameConfig.GUARDIAN_IDLE_ANIMATIONS = {
	R6 = "rbxassetid://180435571",
	R15 = "rbxassetid://507766666",
} :: { [string]: string }

-- ==========================================================
-- LOOT LIFECYCLE
-- ==========================================================
--
-- THERE IS NO PER-SOCKET REFILL TIMER - EXCEPT IN ZONE 1. A socket emptied by
-- a successful theft stays empty until the next GLOBAL refresh. That is the core
-- of the pacing: the world is picked clean, everybody watches the countdown, and
-- the refresh is a shared event rather than a private slot machine.
--
-- The only paths that put an item back into its own socket early are a guardian
-- reclaim and an unclaimed PvP drop, and both return the SAME instance - they
-- never roll a new one.

--- ZONE 1 RESPAWNS ON ITS OWN, by owner decision (2026-09-11). A stolen Zone 1
--- container comes back after a random 60-90 seconds instead of waiting out
--- the 270s Night refresh.
---
--- WHY ZONE 1 AND ONLY ZONE 1. Seven players share Zone 1's four sockets, and
--- a simulation of the first fifteen minutes put a new player in a normal
--- server at 11.7 minutes with NOTHING to steal - the leading reason for early
--- quits. The "slot machine" argument against refill timers is real for the
--- map as a whole, and does not apply here: Zone 1's best item pays less than
--- most commons a few zones on, so a faster Zone 1 moves new players along
--- without printing anything that matters later. Zones 2-12 keep the shared
--- refresh untouched, and `validate` pins that this table names Zone 1 alone.
---
--- The Night refresh still rerolls Zone 1 with everything else; this only
--- decides how soon an EMPTIED socket fills in between.
GameConfig.ZONE_RESPAWN = {
	[1] = { min = 60, max = 90 },
} :: { [number]: { min: number, max: number } }

--- Fallback only: a reclaimed item the guardian cannot physically carry home
--- (no model) goes back to its socket after this instead.
GameConfig.GUARDIAN_RETURN_DELAY = 2
--- A drop the zone's guardian can walk to is fetched by the guardian and is
--- grabbable by anyone until it gets there. One it CANNOT walk to (dropped
--- behind the red line) returns to its socket after this window instead.
GameConfig.DROPPED_RECLAIM_WINDOW = 8
--- Hard floor under drop recovery: a drop still on the ground this long after
--- it fell goes home the instant way, guardian or no guardian.
GameConfig.DROPPED_ORPHAN_TIMEOUT = 75
--- The world reroll cadence IS the Night cycle now (NightConfig.CYCLE_SECONDS
--- owns it; NightService drives it). Mirrored here for anything that still
--- reads the old name; validate asserts the two agree.
GameConfig.GLOBAL_REFRESH_INTERVAL = 270
GameConfig.GLOBAL_REFRESH_WARNING = 10 -- retired: the Night countdown replaced it

-- RETIRED: the separate position-eight jackpot and JACKPOT_REFRESH_CHANCE.
-- Every item, Secret through Divine included, is an ordinary socket roll at
-- its own zone weight (LootConfig.ZoneWeights). There is no world-level
-- injection and no eligibility rule; validate asserts the constant is gone.

-- ==========================================================
-- TUTORIAL
-- ==========================================================
--
-- The first steal is guaranteed so a brand new player always meets the same,
-- winnable opening: a Normal/Normal Pharaoh Mask.
--
-- It was the Ancient Vase, the cheapest item in the game, which made the
-- tutorial's payoff beat read "EARNING $1/s". The Mask ($35/s) is the first
-- item that looks like progress. Only the TUTORIAL copy is special: the Mask's
-- own stats, weight and ordinary spawns are exactly as LootConfig says.

GameConfig.TUTORIAL_ITEM_ID = "Museum_PharaohMask"
--- Earlier tutorial items. A player part-way through the tutorial when the item
--- changed placed the OLD one, and the tutorial reads "have you placed the
--- tutorial item" from the Index - so without this they would be sent back to
--- step one to steal a Mask they were never asked for.
GameConfig.TUTORIAL_LEGACY_ITEM_IDS = { "Museum_AncientVase" }
--- The tutorial copy reveals this fast, whatever its rarity. The Mask is a Rare
--- (45s); the Vase it replaced was a Common (5s), and a 45-second wait on a new
--- player's very first reveal is exactly the dead time this change removes.
--- Applies to the pinned tutorial copy only - every other Mask waits 45s.
GameConfig.TUTORIAL_HATCH_SECONDS = 5
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
	TrailRequest = 4,
	GroupGiftRequest = 1,
	SettingsRequest = 4,
	GuardianRequest = 3,
	WeaponRequest = 3,
	OfflineClaimRequest = 2,
}

-- ==========================================================
-- OFFLINE EARNINGS
-- ==========================================================

--- The longest absence that pays. Exactly six hours, never more.
GameConfig.OFFLINE_EARNINGS_MAX_SECONDS = 6 * 60 * 60
--- The share of the live $/s paid per offline second (1 = the full online
--- rate). The reference game pays substantially less than its online rate
--- while away, but its exact coefficient was not reachable from this project
--- and is NOT guessed here: the field exists, the multiplication is wired
--- (OfflineService.settle), and parity is NOT claimed for offline income
--- until a traced value replaces this. OFFLINE_STATUS says so at runtime.
GameConfig.OFFLINE_EFFICIENCY = 1
GameConfig.OFFLINE_STATUS = "BLOCKED_OFFLINE_COEFFICIENT"
--- Below this the reward is not worth a modal; it is still paid, silently.
GameConfig.OFFLINE_EARNINGS_MIN_TO_SHOW = 1

-- ==========================================================
-- EVENTS
-- ==========================================================

--- The Creator Hub event the lobby stand asks players to follow (the "Next
--- Update" notification). A string: event ids are 64-bit and may become
--- UUIDs, and SocialService takes them as strings either way.
---
--- ROBLOX ONLY PROMPTS FOR AN EVENT THAT HAS NOT STARTED. Once this event's
--- start time passes, PromptRsvpToEventAsync refuses with "Event has
--- already started" and the stand can only report the standing answer.
--- Schedule the next event on the Creator Hub and paste its id here.
GameConfig.NEXT_UPDATE_EVENT_ID = "4257917435077853831"

--- The picture on the Next Update board's face: an IMAGE asset id (a decal
--- or image upload), or nil to draw the built-in "NEXT UPDATE" face. An
--- event id is not an image and cannot be shown here - Roblox exposes no
--- event thumbnail to a running game.
GameConfig.NEXT_UPDATE_IMAGE = 115680004637965 :: number?

return GameConfig
