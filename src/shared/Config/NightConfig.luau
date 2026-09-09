--!strict
--[[
	NightConfig
	The server-wide Night cycle: the shared rhythm the whole server runs on.

	Every CYCLE_SECONDS the world closes for NIGHT_SECONDS. During that closure
	the zones are shut, every guardian is reset, every player is brought back to
	the lobby, every socket is re-rolled, placed items get a burst of growth
	credit, and the lighting turns to night. Then the zones reopen.

	NIGHT CHANGES NOTHING ABOUT WHAT SPAWNS. There is no rarity lean, no size
	lean, no mutation lean, no pity and no jackpot. The refresh that runs at
	Night uses exactly the tables a server-start fill uses, and the regression
	tests (EconomyTests) assert it. Night's only gameplay effects are the
	closure itself and the growth credit below.

	Everything a designer might want to retune lives here. NightService reads
	it on the server; NightController reads it on the client. Neither hard-codes
	a number from it.
]]

local NightConfig = {}

-- ==========================================================
-- SCHEDULE
-- ==========================================================

--- Full cycle, INCLUDING the Night closure. 270 = 260 seconds of play, then a
--- 10-second Night, then the next cycle. Twelve refreshes an hour; with five
--- sockets a zone that is sixty rolls per zone per hour.
NightConfig.CYCLE_SECONDS = 270
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
-- SPOTLIGHT ANNOUNCEMENTS
-- ==========================================================
--
-- ANNOUNCEMENT ONLY. The announcer inspects what was ACTUALLY generated and
-- never feeds back into a roll; a Secret is exactly as likely with the
-- spotlight on or off.

--- At most this many genuine spawns are called out after a refresh, best
--- first, with a gap between them so each one lands.
NightConfig.SPOTLIGHT_MAX = 2
--- How long BEFORE Night ends the "X spawned in Y" calls go out.
NightConfig.SPOTLIGHT_LEAD_SECONDS = 3
NightConfig.SPOTLIGHT_GAP_SECONDS = 2.5
--- What earns a spotlight: a rarity at or above this (Secret, Eternal,
--- Divine), or a size at or above this. Nothing else is announced.
NightConfig.SPOTLIGHT_MIN_RARITY = "Secret"
NightConfig.SPOTLIGHT_MIN_SIZE = "Titan"

-- ==========================================================
-- GROWTH DURING OWNERSHIP
-- ==========================================================
--
-- A placed item MATURES before it earns: its maturation time is its base
-- growth time times ScaleConfig.growthMultiplier(Scale), and it earns
-- nothing until its accrued growth seconds reach it. Growth affects WHEN an
-- item starts earning, never HOW MUCH - there is no income bonus for age.
--
-- Credit accrues one second per real second by day. During the ten-second
-- Night, NIGHT_GROWTH_CREDIT_SECONDS of credit are handed out in total,
-- spread evenly: 300 over 10 seconds is thirty per real second.

NightConfig.NIGHT_GROWTH_CREDIT_SECONDS = 300
--- How often the server advances growth.
NightConfig.GROWTH_TICK_SECONDS = 1

--- Credit granted per real second in each phase.
function NightConfig.growthCreditPerSecond(isNight: boolean): number
	if isNight then
		return NightConfig.NIGHT_GROWTH_CREDIT_SECONDS / NightConfig.NIGHT_SECONDS
	end
	return 1
end

-- ==========================================================
-- THE RETURN TO THE LOBBY
-- ==========================================================

--- Players are spread on a ring of this radius around the lobby spawn so they
--- do not stack inside one another.
NightConfig.LOBBY_RING_RADIUS = 12

--- The Night refresh runs this long after the closure begins, so the client
--- has finished its transition to night before the world changes under it.
NightConfig.REFRESH_DELAY_SECONDS = 1.5

return NightConfig
