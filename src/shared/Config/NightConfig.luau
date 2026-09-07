--!strict
--[[
	NightConfig
	The server-wide Night cycle: the shared rhythm the whole server runs on.

	Every CYCLE_SECONDS the world closes for NIGHT_SECONDS. During that closure
	the zones are shut, every guardian is reset, every player is brought back to
	the lobby, the unclaimed world loot is rerolled (with a modest lean toward the
	exciting outcomes), owned trophies grow faster, and the lighting turns to
	night. Then the zones reopen and the race starts again.

	Everything a designer might want to retune lives here. NightService reads
	it on the server; NightController reads it on the client. Neither hard-codes
	a number from it.
]]

local RarityConfig = require(script.Parent.RarityConfig)

local NightConfig = {}

-- ==========================================================
-- SCHEDULE
-- ==========================================================

--- Full cycle, INCLUDING the Night closure. 240 = 230 seconds of play, then a
--- 10-second Night, then the next cycle.
NightConfig.CYCLE_SECONDS = 240
--- How long the zones stay closed.
NightConfig.NIGHT_SECONDS = 10

--- The timer becomes more noticeable this far before Night.
NightConfig.WARNING_SECONDS = 15
--- A subtle warning begins here (the server says it once; the client renders
--- the rest from the authoritative timestamps).
NightConfig.WARNING_SOFT_SECONDS = 10
--- The last few seconds get clear per-second countdown feedback.
NightConfig.COUNTDOWN_SECONDS = 5

-- ==========================================================
-- REFRESH LEAN
-- ==========================================================
--
-- Applied ONLY while the Night refresh is generating, then removed. Weights are
-- multiplied and then renormalised by the roller, so a 2% tier never becomes
-- 150% - it becomes 3% with everything else shrinking to make room.

--- Multiplier on the spawn weight of every rarity at or above
--- REFRESH_RARITY_BOOST_MIN. Tiers with no normal weight (Secret, Eternal,
--- Divine) still have none: the jackpot path is untouched.
NightConfig.REFRESH_RARITY_BOOST = 1.5
NightConfig.REFRESH_RARITY_BOOST_MIN = "Legendary"

--- Multiplier on the roll weight of every size at or above
--- REFRESH_SIZE_BOOST_MIN (Huge, Giant, Titan, Colossal).
NightConfig.REFRESH_SIZE_BOOST = 1.5
NightConfig.REFRESH_SIZE_BOOST_MIN = "Huge"

-- ==========================================================
-- SPOTLIGHT ANNOUNCEMENTS
-- ==========================================================

--- At most this many genuine spawns are called out after a refresh, best
--- first, with a gap between them so each one lands.
NightConfig.SPOTLIGHT_MAX = 2
NightConfig.SPOTLIGHT_GAP_SECONDS = 2.5
--- What earns a spotlight: a rarity at or above this, a size at or above this,
--- or a jackpot. Nothing else is announced - no fabricated excitement.
NightConfig.SPOTLIGHT_MIN_RARITY = "Legendary"
NightConfig.SPOTLIGHT_MIN_SIZE = "Titan"

--- Anti-drought pity. Deliberately OFF until the baseline has been played and
--- measured; see NightService for what it would do when on.
NightConfig.PITY_ENABLED = false

-- ==========================================================
-- GROWTH DURING OWNERSHIP
-- ==========================================================
--
-- A placed trophy matures. It is a small, capped bonus - never a replacement
-- for the size roll - and it is saved as SECONDS OF EFFECTIVE GROWTH on the
-- item, so it can never be applied twice to the same model.

--- Seconds of effective growth to reach full maturity (20 minutes).
NightConfig.GROWTH_FULL_SECONDS = 1200
--- Income and visual bonus at full maturity.
NightConfig.GROWTH_INCOME_BONUS = 0.10
NightConfig.GROWTH_SCALE_BONUS = 0.08
--- Growth runs this many times faster while it is Night.
NightConfig.GROWTH_NIGHT_MULTIPLIER = 5
--- How often the server advances growth. Income is recalculated only when an
--- item crosses a GROWTH_STEPS boundary, so the loop stays cheap.
NightConfig.GROWTH_TICK_SECONDS = 5
NightConfig.GROWTH_STEPS = 10

-- ==========================================================
-- THE RETURN TO THE LOBBY
-- ==========================================================

--- Players are spread on a ring of this radius around the lobby spawn so they
--- do not stack inside one another.
NightConfig.LOBBY_RING_RADIUS = 12

--- The Night refresh runs this long after the closure begins, so the client
--- has finished its transition to night before the world changes under it.
NightConfig.REFRESH_DELAY_SECONDS = 1.5

-- ==========================================================
-- THE LEAN, AS FUNCTIONS
-- ==========================================================
--
-- One definition, used by the real refresh and by the debug simulation, so the
-- two cannot disagree about what "boosted" means.

function NightConfig.rarityBoost(rarity: string): number
	return if RarityConfig.rank(rarity) >= RarityConfig.rank(NightConfig.REFRESH_RARITY_BOOST_MIN)
		then NightConfig.REFRESH_RARITY_BOOST
		else 1
end

function NightConfig.sizeBoost(sizeId: string): number
	return if RarityConfig.sizeRank(sizeId) >= RarityConfig.sizeRank(NightConfig.REFRESH_SIZE_BOOST_MIN)
		then NightConfig.REFRESH_SIZE_BOOST
		else 1
end

--- The boost table LootService.refreshAll takes for a Night refresh.
function NightConfig.refreshBoosts(): { rarity: (string) -> number, size: (string) -> number }
	return { rarity = NightConfig.rarityBoost, size = NightConfig.sizeBoost }
end

return NightConfig
