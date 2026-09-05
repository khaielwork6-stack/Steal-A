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

-- Movement compression (GDD section 5). Huge SpeedPower stays exciting without
-- handing the Humanoid billions of studs/second.
GameConfig.WALKSPEED_BASE = 16
GameConfig.WALKSPEED_COEFFICIENT = 7.5
GameConfig.WALKSPEED_MIN = 18
GameConfig.WALKSPEED_MAX = 90

--- RealWalkSpeed = clamp(16 + 7.5 * log10(1 + SpeedPower / 10), 18, 90)
function GameConfig.walkSpeedFromPower(power: number): number
	local raw = GameConfig.WALKSPEED_BASE
		+ GameConfig.WALKSPEED_COEFFICIENT * math.log10(1 + power / 10)
	return math.clamp(raw, GameConfig.WALKSPEED_MIN, GameConfig.WALKSPEED_MAX)
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

--- One-time onboarding bridge. The Ancient Vase earns $1/s, so a fresh player
--- would otherwise stand still for a thousand seconds to afford the $1,000 base
--- activation. On their FIRST successful placement they are topped up to exactly
--- this balance - `max(0, TUTORIAL_CASH_BRIDGE - cash)`, so it is a floor and
--- never a bonus - and the flag that records it is persisted, which is what
--- makes it unfarmable by resetting, selling, rejoining or spamming the remote.
---
--- This exists so onboarding stays fast WITHOUT the worst item in the game
--- printing a real income forever.
GameConfig.TUTORIAL_CASH_BRIDGE = 1000

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
