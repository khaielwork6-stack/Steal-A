--!strict
--[[
	Studio debug commands for the polish-events-analytics pass: the event
	schedule, event overrides, the analytics dump and the flyover replay.
	Loaded by DebugService in Studio only.

	SAFETY. Nothing here writes a lasting profile change:
	  * event overrides and the fake clock live in EventService's memory and
	    die with the server;
	  * flyoverReplay clears Profile.FlyoverSeen for one replay and
	    FlyoverService puts the original value back when the client reports
	    done - or before the leave-save if it never does.
]]

local Services = script.Parent.Parent
local AnalyticsEvents = require(Services.AnalyticsEvents)
local EventService = require(Services.EventService)
local FlyoverService = require(Services.FlyoverService)
local LootService = require(Services.LootService)
local NightService = require(Services.NightService)

local EventConfig = require(game:GetService("ReplicatedStorage").Shared.Config.EventConfig)

return {
	--- eventSchedule: the UTC clock, every event's current/next window, what
	--- is running and what the hooks return right now.
	eventSchedule = function(player: Player): any
		local mutations = {}
		for _, row in LootService.mutationTableFor() do
			table.insert(mutations, `{row.id} {row.chance}%`)
		end
		return {
			nowUtc = EventService.nowUtc(),
			schedule = EventService.schedule(),
			state = EventService.summarise(player),
			worldMutationTable = mutations,
			nextCycleDaySeconds = NightService.daySecondsFor(),
			night = NightService.status(),
		}
	end,

	--- eventForce <key> <on|off|clock>: Studio override for one event.
	--- "clock" hands it back to the schedule.
	eventForce = function(_player: Player, key: string?, mode: string?): any
		if type(key) ~= "string" or not EventConfig.ByKey[key] then
			local keys = {}
			for _, def in EventConfig.Events do
				table.insert(keys, def.key)
			end
			return { error = "usage: eventForce <key> <on|off|clock>", keys = keys }
		end
		local value: boolean? = if mode == "on" then true elseif mode == "off" then false else nil
		local ok, err = EventService.force(key, value)
		return {
			ok = ok,
			error = err,
			override = value,
			note = "Night Rush applies from the next dawn (forceDay starts one now)",
		}
	end,

	--- eventClock <unix | "YYYY-MM-DD" | nil>: pretends the UTC clock is
	--- that moment (overrides still win). No argument = the real clock.
	eventClock = function(_player: Player, at: any?): any
		local unix: number? = tonumber(at)
		if not unix and type(at) == "string" then
			local y, m, d = string.match(at, "^(%d+)-(%d+)-(%d+)")
			if y and m and d then
				unix = EventConfig.utc(tonumber(y) :: number, tonumber(m) :: number, tonumber(d) :: number)
			end
		end
		local ok, err = EventService.setClock(unix)
		return { ok = ok, error = err, nowUtc = EventService.nowUtc(), schedule = EventService.schedule() }
	end,

	--- eventReset: drop every override and the fake clock.
	eventReset = function(_player: Player): any
		EventService.clearOverrides()
		return { nowUtc = EventService.nowUtc(), schedule = EventService.schedule() }
	end,

	--- analyticsDump: what was (or, in Studio with debug off, would have
	--- been) sent, plus budgets, drops and the pending passive sums.
	--- [analytics-discord] Optional filter word, e.g. `analyticsDump Quit`.
	analyticsDump = function(_player: Player, filter: any?): any
		return AnalyticsEvents.dump(if type(filter) == "string" then filter else nil)
	end,

	--- analyticsDebug <true|false>: really send from Studio, and print each
	--- event. Off by default.
	analyticsDebug = function(_player: Player, on: any?): any
		local value = on == true or on == "true" or on == "on" or on == 1
		AnalyticsEvents.setDebug(value)
		return { debug = value }
	end,

	--- analyticsFlush: send the summed passive income now.
	analyticsFlush = function(_player: Player): any
		AnalyticsEvents.flushAll()
		return AnalyticsEvents.dump()
	end,

	--- flyoverReplay: plays the first-join flyover again for the caller. The
	--- saved flag is restored when it ends (or on leave).
	flyoverReplay = function(player: Player): any
		local ok, err = FlyoverService.debugReplay(player)
		return { ok = ok, error = err, state = FlyoverService.debugState(player) }
	end,

	--- flyoverState: the flag and why.
	flyoverState = function(player: Player): any
		return FlyoverService.debugState(player)
	end,
}
