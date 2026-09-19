--!strict
--[[
	Studio debug commands for the analytics-discord pass. Loaded by
	DebugService in Studio only. See docs/handoff-parts/analytics-discord.md.

	SAFETY. Nothing here writes a lasting profile change:
	  * analyticsSimulate fires progress facts that only feed analytics
	    (catch, storage full, robbed, a Speed "gain" that is NOT added to the
	    profile, gadget, code, quest, spin) - no reveal, so the saved
	    once-in-a-life marks (FirstReveal / FirstEpic) are never used up;
	  * analyticsQuitTest logs the quit event the caller WOULD send, without
	    ending the session;
	  * the Discord commands post only when a webhook is configured, and
	    discordTest / perfSpikeTest never touch a DataStore.
]]

local Services = script.Parent.Parent
local AnalyticsEvents = require(Services.AnalyticsEvents)
local AnalyticsSession = require(Services.AnalyticsSession)
local DiscordReporter = require(Services.DiscordReporter)
local PerfFeed = require(Services.PerfFeed)
local ProgressEvents = require(Services.ProgressEvents)

local function truthy(value: any): boolean
	return value == true or value == "true" or value == "on" or value == 1 or value == "1"
end

return {
	--- analyticsEvents [filter]: the recorded events (sent or, in Studio
	--- with debug off, would-have-been-sent), filtered by a word, e.g.
	--- "Quit", "Speed", "Buy_", "custom", "Caught". Counts per custom name.
	analyticsEvents = function(_player: Player, filter: any?): any
		return AnalyticsEvents.dump(if type(filter) == "string" then filter else nil)
	end,

	--- analyticsSession: every live session - where, carrying, tutorial step,
	--- open panel, idle time, last catch / robbery, the quit event it would
	--- log now - plus the last 20 session ends.
	analyticsSession = function(_player: Player): any
		return AnalyticsSession.snapshot()
	end,

	--- analyticsQuitTest: logs the caller's quit event as if they left now
	--- (the session goes on). Then `analyticsEvents Quit`.
	analyticsQuitTest = function(player: Player): any
		return AnalyticsSession.debugQuit(player)
	end,

	--- analyticsSimulate: one of each analytics-only fact for the caller, so
	--- every new event name shows up in `analyticsEvents custom`.
	analyticsSimulate = function(player: Player): any
		ProgressEvents.fire(player, "caught", 1, { zone = 2, cause = "laser", carrying = true })
		ProgressEvents.fire(player, "storageFull", 1, { where = "steal", zone = 2 })
		ProgressEvents.fire(player, "robbed", 1, { rarity = "Epic" })
		-- Not a "steal" fire: badges and quests listen to that one.
		AnalyticsEvents.custom(player, "VaultSteal", 12, { "Z12" })
		AnalyticsEvents.custom(player, "UnderSpeedAttempt", 12, { "Z12", "stole", "<25%" })
		-- Analytics only: the profile's SpeedPower is not changed.
		ProgressEvents.fire(player, "speedGain", 100, { source = "spin" })
		ProgressEvents.fire(player, "speedGain", 50, { source = "train" })
		ProgressEvents.fire(player, "gadgetUsed", 1, { gadget = "Smoke" })
		ProgressEvents.fire(player, "codeRedeemed", 1, { code = "TESTCODE" })
		ProgressEvents.fire(player, "fused", 1, { rarity = "Rare" })
		ProgressEvents.fire(player, "tradeCompleted", 1, { items = 2 })
		AnalyticsEvents.custom(player, "SpinUsed", 1)
		AnalyticsEvents.custom(player, "QuestClaim", 1, { "Daily" })
		AnalyticsEvents.custom(player, "DailyClaim", 3, { "D3", "3" })
		AnalyticsEvents.custom(player, "SeasonTier", 4, { "T4", "free" })
		AnalyticsEvents.custom(player, "Revealed", 1, { "Rare", "Z01", "manual" })
		AnalyticsEvents.custom(player, "RevealWait", 42, { AnalyticsEvents.waitBucket(42), "manual", "Rare" })
		AnalyticsEvents.custom(player, "LaserTouched", 1, { "Z02", "R1" })
		AnalyticsEvents.panelShown(player, "Shop")
		task.wait(0.5)
		AnalyticsEvents.flushAll()
		return AnalyticsEvents.dump("custom")
	end,

	--- discordStatus: whether this server posts and why, where the webhook
	--- came from (never the webhook), the queue, the 30-minute window, the
	--- pending day counters, the analytics mirror and the spikes feed.
	discordStatus = function(_player: Player): any
		local status = DiscordReporter.status()
		status.perf = PerfFeed.status()
		return status
	end,

	--- discordDebug <true|false>: let this Studio session post (and keep the
	--- daily DataStore counters). Off again with false.
	discordDebug = function(_player: Player, on: any?): any
		DiscordReporter.setDebug(truthy(on))
		return DiscordReporter.status()
	end,

	--- discordTest: posts ONE test embed if a webhook is configured
	--- (DiscordConfig.WEBHOOK, the secret, or the Studio attribute), even
	--- with Studio posting off.
	discordTest = function(player: Player): any
		local ok, why = DiscordReporter.test(player)
		return { queued = ok, reason = why, status = DiscordReporter.status() }
	end,

	--- discordSummaryNow: posts the 30-minute server summary now (needs
	--- posting on: discordDebug true).
	discordSummaryNow = function(_player: Player): any
		return { queued = DiscordReporter.postSummary(true), status = DiscordReporter.status() }
	end,

	--- discordDigestPreview: the daily digest embed built from THIS server's
	--- unsaved counters for today. Posts nothing, touches no DataStore.
	discordDigestPreview = function(_player: Player): any
		return DiscordReporter.previewDigest()
	end,

	--- discordFlush: sends the waiting analytics-mirror and spikes rows now.
	discordFlush = function(_player: Player): any
		DiscordReporter.flushMirrorNow()
		PerfFeed.flushNow()
		return DiscordReporter.status()
	end,

	--- perfSpikeTest [fps]: injects a fake fps-drop row for the caller (as if
	--- their client had reported it; cooldowns bypassed) and returns it.
	perfSpikeTest = function(player: Player, fps: any?): any
		local row = PerfFeed.spike(player, {
			fps = tonumber(fps) or 17,
			device = "Phone",
			fx = "Reduced",
			pingMs = 458,
			recvKbps = 120,
			particles = 24,
			effects = 9,
			cpuMs = 21.2,
			gpuMs = 18.5,
			drawcalls = 1600,
			tris = 15000,
			top = "Render",
		}, true)
		return { row = row, perf = PerfFeed.status() }
	end,

	--- perfErrorTest: a fake server-error row (not a real error).
	perfErrorTest = function(_player: Player): any
		PerfFeed.addRow("error", "server:ServerScriptService.Server.Test", "Test error, please ignore (perfErrorTest)", nil, nil, nil, nil, "n/a")
		return PerfFeed.status()
	end,
}
