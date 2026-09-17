--!strict
--[[
	EventService  (polish-events-analytics pass)
	The free, time-based events in EventConfig: which are running, what they
	change, and what the HUD is told.

	ONE CLOCK. Every window is computed from os.time() (UTC), so every server
	agrees without talking. The service re-reads the clock every
	EventConfig.TICK_SECONDS; when the set of running events changes it
	re-pushes every player's state.

	WHAT EACH KIND CHANGES (and nothing else)
	  mutation   LootService.mutationTableFor -> a SCALED COPY of
	             RarityConfig.Mutations (EventConfig.scaledMutations): the
	             non-Normal chances times the multiplier, Normal the remainder,
	             total still 100. The locked base table is never edited, and a
	             container already rolled keeps its roll.
	  nightRush  NightService.daySecondsFor -> a shorter Day. NightService reads
	             it once per cycle, at dawn, so a window opening mid-Day never
	             moves the countdown on screen.
	  holiday    nothing on the server: the client tints decor lights and shows
	             the banner.

	STATE FIELD `events` (StateService provider), small and absolute:
	  { active = { {key, title, banner, kind, color, icon, endsAt}... },
	    upcoming = {key, title, startsAt}? }
	The client counts down from the timestamps itself.

	STUDIO OVERRIDE. `EventService.force(key, true | false | nil)` switches an
	event on or off regardless of the clock (nil = back to the clock). Refused
	outside Studio.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local StateService = require(script.Parent.StateService)

local EventService = {}

export type ActiveEvent = {
	key: string,
	title: string,
	banner: string,
	kind: string,
	color: Color3,
	icon: string,
	--- Unix seconds (UTC) the window closes. A forced event ends "never"
	--- (0) until the override is cleared.
	endsAt: number,
}

local overrides: { [string]: boolean } = {}
local active: { ActiveEvent } = {}
local activeByKey: { [string]: ActiveEvent } = {}
local upcoming: { key: string, title: string, startsAt: number }? = nil
local signature = ""

--- Seconds offset added to os.time() (Studio only), for testing a window.
local clockOffset = 0

local function now(): number
	return os.time() + clockOffset
end

local function recompute()
	local t = now()
	local nextActive: { ActiveEvent } = {}
	local nextUpcoming: { key: string, title: string, startsAt: number }? = nil
	for _, def in EventConfig.Events do
		local startsAt, endsAt = EventConfig.windowFor(def, t)
		local forced = overrides[def.key]
		local running = false
		if forced ~= nil then
			running = forced
		elseif def.enabled and startsAt and endsAt then
			running = t >= startsAt and t < endsAt
		end
		if running then
			table.insert(nextActive, {
				key = def.key,
				title = def.title,
				banner = def.banner,
				kind = def.kind :: string,
				color = def.color,
				icon = def.icon,
				endsAt = if forced == true then 0 else endsAt or 0,
			})
		elseif def.enabled and forced == nil and startsAt and startsAt > t then
			if startsAt - t <= EventConfig.UPCOMING_WINDOW_SECONDS and (nextUpcoming == nil or startsAt < nextUpcoming.startsAt) then
				nextUpcoming = { key = def.key, title = def.title, startsAt = startsAt }
			end
		end
	end

	local parts = {}
	for _, event in nextActive do
		table.insert(parts, `{event.key}@{event.endsAt}`)
	end
	local nextSignature = table.concat(parts, ",") .. "|" .. (if nextUpcoming then `{nextUpcoming.key}@{nextUpcoming.startsAt}` else "")

	active = nextActive
	table.clear(activeByKey)
	for _, event in nextActive do
		activeByKey[event.key] = event
	end
	upcoming = nextUpcoming

	if nextSignature ~= signature then
		local before = signature
		signature = nextSignature
		if before ~= "" or #nextActive > 0 then
			local names = {}
			for _, event in nextActive do
				table.insert(names, event.key)
			end
			print(`[EventService] running: {if #names > 0 then table.concat(names, ", ") else "none"}`)
		end
		for _, player in Players:GetPlayers() do
			StateService.markDirty(player)
		end
	end
end

-- ==========================================================
-- QUERIES
-- ==========================================================

function EventService.isActive(key: string): boolean
	return activeByKey[key] ~= nil
end

--- The strongest running multiplier for `kind`'s numeric field.
local function strongest(kind: string, field: string): number?
	local best: number? = nil
	for _, event in active do
		if event.kind == kind then
			local def = EventConfig.ByKey[event.key]
			local value = def and (def :: any)[field]
			if type(value) == "number" and (best == nil or value > best) then
				best = value
			end
		end
	end
	return best
end

local scaledCache: { [number]: { RarityConfig.Variant } } = {}

--- The mutation table world loot rolls from right now.
function EventService.mutationTable(): { RarityConfig.Variant }
	local factor = strongest("mutation", "mutationMultiplier")
	if not factor or factor == 1 then
		return RarityConfig.Mutations
	end
	local cached = scaledCache[factor]
	if not cached then
		cached = EventConfig.scaledMutations(RarityConfig.Mutations, factor) :: any
		scaledCache[factor] = cached :: any
	end
	return cached :: { RarityConfig.Variant }
end

--- The Day length for the cycle starting now.
function EventService.daySeconds(): number
	local normal = NightConfig.CYCLE_SECONDS - NightConfig.NIGHT_SECONDS
	local rush = nil
	for _, event in active do
		if event.kind == "nightRush" then
			local def = EventConfig.ByKey[event.key]
			local value = def and def.nightRushDaySeconds
			if type(value) == "number" and value > 0 and (rush == nil or value < rush) then
				rush = value
			end
		end
	end
	return if rush then math.min(normal, rush) else normal
end

function EventService.summarise(_player: Player): { [string]: any }
	return { active = active, upcoming = upcoming }
end

-- ==========================================================
-- STUDIO CONTROLS
-- ==========================================================

function EventService.force(key: string, on: boolean?): (boolean, string?)
	if not RunService:IsStudio() then
		return false, "Studio only"
	end
	if not EventConfig.ByKey[key] then
		return false, `unknown event "{key}"`
	end
	if on == nil then
		overrides[key] = nil
	else
		overrides[key] = on
	end
	recompute()
	return true
end

function EventService.clearOverrides()
	table.clear(overrides)
	clockOffset = 0
	recompute()
end

--- Studio only: pretends the UTC clock is `unix` (nil = the real clock).
function EventService.setClock(unix: number?): (boolean, string?)
	if not RunService:IsStudio() then
		return false, "Studio only"
	end
	clockOffset = if unix then unix - os.time() else 0
	recompute()
	return true
end

--- Every event's current or next window, for the debug command.
function EventService.schedule(): { any }
	local t = now()
	local rows = {}
	for _, def in EventConfig.Events do
		local startsAt, endsAt = EventConfig.windowFor(def, t)
		table.insert(rows, {
			key = def.key,
			kind = def.kind,
			enabled = def.enabled,
			override = overrides[def.key],
			active = activeByKey[def.key] ~= nil,
			startsUtc = if startsAt then os.date("!%Y-%m-%d %H:%M", startsAt) else nil,
			endsUtc = if endsAt then os.date("!%Y-%m-%d %H:%M", endsAt) else nil,
			startsInSeconds = if startsAt then startsAt - t else nil,
		})
	end
	return rows
end

function EventService.nowUtc(): string
	return os.date("!%Y-%m-%d %H:%M:%S (%a)", now())
end

function EventService.start()
	StateService.addProvider("events", EventService.summarise)
	recompute()
	task.spawn(function()
		while true do
			task.wait(EventConfig.TICK_SECONDS)
			local ok, err = pcall(function()
				recompute()
			end)
			if not ok then
				warn(`[EventService] tick failed: {err}`)
			end
		end
	end)
end

return EventService
