--!strict
--[[
	EventConfig
	The free, time-based events (polish-events-analytics pass). Read by
	EventService on the server and by EventController for the HUD pill.

	EVERY WINDOW IS UTC, COMPUTED FROM os.time(). Every server reads the same
	wall clock, so every server agrees on what is running without talking to
	each other. Nothing here is sold: a paid "server luck boost" is out of
	scope by the owner's decision.

	KINDS
	  mutation   world loot mutation chances x `mutationMultiplier` (the
	             non-Normal rows of RarityConfig.Mutations are scaled and Normal
	             takes the remainder; the base table is never edited).
	  nightRush  the Day part of the Night cycle is `nightRushDaySeconds` long
	             instead of CYCLE - NIGHT, so refreshes come round sooner. The
	             Night itself (the 10 s closure) is unchanged: growth credit and
	             the paid-steal Night wait are both sized to it.
	  holiday    cosmetic only: tints the museum decor lights and shows the
	             banner text.

	RECURRENCE
	  weekly  `weekday` (1 = Sunday ... 7 = Saturday, os.date("!*t").wday),
	          `hour` (0-23 UTC) and `durationHours`. A window may run past the
	          end of the week (Sat -> Mon).
	  yearly  `from` / `to` = { month, day } UTC dates, start inclusive at
	          00:00, end EXCLUSIVE at 00:00. A `to` earlier in the year than
	          `from` wraps into the next year (Dec 18 -> Jan 2).

	WHY DOUBLE NIGHT LOOT BECAME NIGHT RUSH
	"+1 rarity tier for the first Night refresh" needs a second item-roll path
	that leans the zone weights. The weights and the no-lean Night refresh are
	pinned by validate and the regression tests (NightService header, owner
	rule: no change to loot weights), so that event is not implemented; Night
	Rush changes only WHEN refreshes happen, never what they roll.
]]

export type Weekly = { weekday: number, hour: number, durationHours: number }
export type YearDate = { month: number, day: number }

export type EventDef = {
	key: string,
	kind: "mutation" | "nightRush" | "holiday",
	title: string,
	--- One short line under the title on the HUD pill / announcement.
	banner: string,
	--- The pill and announcement accent.
	color: Color3,
	--- Codex art (docs/codex-prompts/polish-events-analytics.md). 0 = text only.
	icon: string,
	--- A weekly or a yearly window; exactly one of the two.
	weekly: Weekly?,
	from: YearDate?,
	to: YearDate?,
	--- Master switch per event (false = never runs outside a Studio force).
	enabled: boolean,
	-- kind-specific
	mutationMultiplier: number?,
	nightRushDaySeconds: number?,
	--- Holiday decor light colour (blended with each light's own colour).
	lightColor: Color3?,
}

local EventConfig = {}

--- How often EventService re-reads the clock. Windows are hours long; a
--- second of lag at a boundary is invisible.
EventConfig.TICK_SECONDS = 1

--- How far ahead the HUD advertises the next event ("starts in 3h").
EventConfig.UPCOMING_WINDOW_SECONDS = 6 * 3600

--- How strongly a holiday tints each decor light (0 = untouched, 1 = the
--- holiday colour exactly).
EventConfig.HOLIDAY_LIGHT_BLEND = 0.6

EventConfig.Events = {
	{
		key = "MutationWeekend",
		kind = "mutation",
		title = "MUTATION WEEKEND",
		banner = "2x mutation chance on museum loot!",
		color = Color3.fromRGB(255, 120, 230),
		icon = "rbxassetid://0",
		-- Saturday 00:00 UTC for 48 hours -> Monday 00:00 UTC.
		weekly = { weekday = 7, hour = 0, durationHours = 48 },
		enabled = true,
		mutationMultiplier = 2,
	},
	{
		key = "NightRush",
		kind = "nightRush",
		title = "NIGHT RUSH",
		banner = "Faster loot refreshes!",
		color = Color3.fromRGB(150, 110, 255),
		icon = "rbxassetid://0",
		-- Friday 18:00 - 22:00 UTC (a weekday evening in Europe, afternoon in
		-- the Americas).
		weekly = { weekday = 6, hour = 18, durationHours = 4 },
		enabled = true,
		-- 200 s of Day instead of 260 (cycle 210 s instead of 270 s): about
		-- 29% more refreshes for four hours a week.
		nightRushDaySeconds = 200,
	},
	{
		key = "Halloween",
		kind = "holiday",
		title = "HALLOWEEN",
		banner = "The museum is haunted...",
		color = Color3.fromRGB(255, 140, 40),
		icon = "rbxassetid://0",
		from = { month = 10, day = 25 },
		to = { month = 11, day = 1 },
		enabled = true,
		lightColor = Color3.fromRGB(255, 120, 30),
	},
	{
		key = "Winter",
		kind = "holiday",
		title = "WINTER FESTIVAL",
		banner = "Happy holidays from the museum!",
		color = Color3.fromRGB(120, 210, 255),
		icon = "rbxassetid://0",
		from = { month = 12, day = 18 },
		to = { month = 1, day = 2 },
		enabled = true,
		lightColor = Color3.fromRGB(140, 200, 255),
	},
} :: { EventDef }

EventConfig.ByKey = {} :: { [string]: EventDef }
for _, def in EventConfig.Events do
	EventConfig.ByKey[def.key] = def
end

-- ==========================================================
-- UTC CALENDAR (no os.date tables, no time-zone assumptions)
-- ==========================================================

local DAY = 86400
local WEEK = 7 * DAY
--- 1970-01-04 00:00 UTC was a Sunday.
local FIRST_SUNDAY = 3 * DAY

--- Unix seconds of `year`-`month`-`day` 00:00 UTC (days-from-civil).
function EventConfig.utc(year: number, month: number, day: number): number
	local y = if month <= 2 then year - 1 else year
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (month + 9) % 12
	local doy = (153 * mp + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return (era * 146097 + doe - 719468) * DAY
end

--- The UTC calendar year of a unix time.
function EventConfig.yearOf(t: number): number
	local year = 1970 + t // (365.2425 * DAY)
	-- The estimate can be one off either way near New Year.
	if EventConfig.utc(year, 1, 1) > t then
		year -= 1
	elseif EventConfig.utc(year + 1, 1, 1) <= t then
		year += 1
	end
	return year
end

--- The window of `def` that contains `now`, or else the next one to start.
--- Returns (startsAt, endsAt); nil for a malformed entry.
function EventConfig.windowFor(def: EventDef, now: number): (number?, number?)
	local weekly = def.weekly
	if weekly then
		local duration = weekly.durationHours * 3600
		local weekStart = now - (now - FIRST_SUNDAY) % WEEK
		local offset = (weekly.weekday - 1) * DAY + weekly.hour * 3600
		-- This week's, and last week's (a window that runs past Saturday
		-- night is still open early in the next week).
		for _, start in { weekStart - WEEK + offset, weekStart + offset } do
			if now >= start and now < start + duration then
				return start, start + duration
			end
		end
		local start = weekStart + offset
		if start <= now then
			start += WEEK
		end
		return start, start + duration
	end
	local from, to = def.from, def.to
	if from and to then
		local year = EventConfig.yearOf(now)
		local wraps = to.month < from.month or (to.month == from.month and to.day <= from.day)
		local nextStart: number? = nil
		local nextEnd: number? = nil
		for _, y in { year - 1, year, year + 1 } do
			local start = EventConfig.utc(y, from.month, from.day)
			local finish = EventConfig.utc(if wraps then y + 1 else y, to.month, to.day)
			if now >= start and now < finish then
				return start, finish
			end
			if start > now and (nextStart == nil or start < nextStart) then
				nextStart, nextEnd = start, finish
			end
		end
		return nextStart, nextEnd
	end
	return nil, nil
end

--- The mutation table with every non-Normal chance multiplied by `factor`
--- and Normal taking the remainder, so the list still sums to 100. The
--- factor is capped so the non-Normal rows can never exceed 100 between
--- them. Returns a NEW table; `base` is not touched.
function EventConfig.scaledMutations(
	base: { { id: string, chance: number, multiplier: number } },
	factor: number
): { { id: string, chance: number, multiplier: number } }
	local rare = 0
	local total = 0
	for _, row in base do
		total += row.chance
		if row.id ~= "Normal" then
			rare += row.chance
		end
	end
	local cap = if rare > 0 then total / rare else 1
	local k = math.clamp(factor, 0, cap)
	local out: { { id: string, chance: number, multiplier: number } } = {}
	local scaledRare = 0
	for _, row in base do
		if row.id ~= "Normal" then
			local chance = row.chance * k
			scaledRare += chance
			table.insert(out, { id = row.id, chance = chance, multiplier = row.multiplier })
		else
			local id: string = row.id
			table.insert(out, { id = id, chance = 0, multiplier = row.multiplier })
		end
	end
	for _, row in out do
		if row.id == "Normal" then
			row.chance = math.max(0, total - scaledRare)
		end
	end
	return out
end

return EventConfig
