--!strict
--[[
	DiscordConfig  (analytics-discord)
	SERVER ONLY. Lives under ServerScriptService, which never replicates, so
	nothing here can reach a client. See docs/handoff-parts/analytics-discord.md.

	THE WEBHOOK - where DiscordReporter posts, first match wins:
	  1. WEBHOOK below, when it is not empty. The owner pastes the full Discord
	     webhook URL (https://discord.com/api/webhooks/<id>/<token>, or the
	     discordapp.com form) into it HIMSELF, in Studio, and never commits it.
	     It is rewritten to the webhook.lewisakura.moe proxy (Roblox blocks
	     discord.com). KEEP IT EMPTY IN THE REPO: anything written here is in
	     the place file and in git history.
	  2. The experience secret DISCORD_WEBHOOK (Creator Dashboard > Secrets),
	     holding ONLY "<id>/<token>", domain webhook.lewisakura.moe. The URL
	     is built from the Secret object and is never a readable string.
	  3. Studio only: a ServerStorage attribute DISCORD_WEBHOOK_STUDIO holding
	     "<id>/<token>". Ignored on live servers; remove it before publishing.

	STUDIO posts nothing unless DEBUG or POST_FROM_STUDIO is true (or the
	`discordDebug` command turned it on); `discordTest` always may.
]]

local DiscordConfig = {}

--- The full Discord webhook URL, or "" to use the DISCORD_WEBHOOK secret.
--- NEVER commit a real value.
DiscordConfig.WEBHOOK = ""

--- Master switch for everything this reporter posts.
DiscordConfig.ENABLED = true
--- Studio posts (and keeps the daily DataStore counters) only when one of
--- these is true. DEBUG also prints each queued message's title.
DiscordConfig.DEBUG = false
DiscordConfig.POST_FROM_STUDIO = false

--- The public proxy Roblox can reach. The secret's value is appended to it.
DiscordConfig.PROXY_PREFIX = "https://webhook.lewisakura.moe/api/webhooks/"
--- The experience secret's name.
DiscordConfig.SECRET_NAME = "DISCORD_WEBHOOK"
--- Studio-only fallback attribute on ServerStorage.
DiscordConfig.STUDIO_ATTRIBUTE = "DISCORD_WEBHOOK_STUDIO"

--- Shown as the webhook's author name and in every title.
DiscordConfig.GAME_NAME = "Steal & Run!"

-- ==========================================================
-- QUEUE AND RATE LIMITS
-- ==========================================================

--- Messages per minute this server sends (Discord allows about 30 per
--- minute per webhook; several servers share one).
DiscordConfig.MESSAGES_PER_MINUTE = 20
--- The queue drops its OLDEST message beyond this.
DiscordConfig.QUEUE_MAX = 50
--- Retries for a network error or a 5xx before a message is dropped.
DiscordConfig.MAX_ATTEMPTS = 4
--- Purchases (and big reveals) landing within this window become one embed.
DiscordConfig.BURST_SECONDS = 10

-- ==========================================================
-- WHAT IS POSTED
-- ==========================================================

DiscordConfig.POST_PURCHASES = true
--- Reveals at or above this rarity are posted as they happen.
DiscordConfig.REVEAL_MIN_RARITY = "Secret"
DiscordConfig.POST_ERRORS = true
--- One instant post per distinct error message per this many seconds.
DiscordConfig.ERROR_DEDUPE_SECONDS = 600
--- The per-server summary, while the server has players.
DiscordConfig.SUMMARY_SECONDS = 30 * 60

-- ==========================================================
-- ANALYTICS MIRROR (every Roblox Analytics event, as CSV rows)
-- ==========================================================

--- Every funnel step, economy event (Cash and Speed), progression event
--- and custom event is ALSO posted to Discord, as "<GAME_NAME> analytics"
--- CSV batches: utc,type,event,player,sid,field1,field2,field3,value.
DiscordConfig.MIRROR_ANALYTICS = true
DiscordConfig.MIRROR_FLUSH_SECONDS = 60
--- An early flush once this many rows wait (at most every MIRROR_MIN_GAP s).
DiscordConfig.MIRROR_BATCH_ROWS = 15
DiscordConfig.MIRROR_MIN_GAP = 6
--- The mirror's share of MESSAGES_PER_MINUTE. Past it, duplicate rows are
--- merged (value "N xCOUNT"), then merged across players ("*"), and only
--- then are the oldest dropped - all counted in the 30-minute summary.
DiscordConfig.MIRROR_MESSAGES_PER_MINUTE = 10
--- Rows kept waiting at most while over budget (merged first, then dropped).
DiscordConfig.MIRROR_BUFFER_MAX = 1500

-- ==========================================================
-- DAILY DIGEST (one post per UTC day across every server)
-- ==========================================================

DiscordConfig.DAILY_ENABLED = true
DiscordConfig.DAILY_STORE = "AnalyticsDaily_v1"
--- Each server's day counters are merged into the store this often (and on
--- shutdown).
DiscordConfig.DAILY_FLUSH_SECONDS = 120
--- Seconds after 00:00 UTC before yesterday's digest may be claimed.
DiscordConfig.DIGEST_AFTER_SECONDS = 5 * 60

-- ==========================================================
-- ERRORS AND SPIKES FEED (CSV rows, batched)
-- ==========================================================

DiscordConfig.PERF_FEED = true
--- A batch is posted this often, or as soon as PERF_BATCH_ROWS are waiting.
DiscordConfig.PERF_FLUSH_SECONDS = 90
DiscordConfig.PERF_BATCH_ROWS = 10
--- Rows kept waiting at most (the oldest go first).
DiscordConfig.PERF_BUFFER_MAX = 60
--- Server lag: average server FPS under this for SERVER_LAG_SECONDS.
DiscordConfig.SERVER_LAG_FPS = 40
DiscordConfig.SERVER_LAG_SECONDS = 5
DiscordConfig.SERVER_LAG_COOLDOWN = 300
--- A remote limiter refusing one player this many times inside
--- FLOOD_WINDOW seconds is one "remote-flood" row (then FLOOD_COOLDOWN).
DiscordConfig.FLOOD_REJECTS = 40
DiscordConfig.FLOOD_WINDOW = 10
DiscordConfig.FLOOD_COOLDOWN = 300
--- Server-side spike cooldown per player (the client has its own).
DiscordConfig.SPIKE_COOLDOWN = 45
--- Client errors: one row per distinct message per this many seconds.
DiscordConfig.CLIENT_ERROR_DEDUPE_SECONDS = 600

--- "cause" of an FPS drop: each measurement is divided by its threshold and
--- the largest ratio at or above 1 wins; none reaching 1 is "Unknown".
DiscordConfig.CAUSE_THRESHOLDS = {
	Network = { pingMs = 300, recvKbps = 400 },
	Players = { nearby = 5 },
	Guards = { guards = 3 },
	Particles = { particles = 40 },
	Effects = { effects = 30 },
	Geometry = { drawcalls = 3000, trisK = 1500 },
} :: { [string]: { [string]: number } }

--- Studs: "nearby" players and guards around a spiking player.
DiscordConfig.NEARBY_PLAYERS_RADIUS = 60
DiscordConfig.NEARBY_GUARDS_RADIUS = 80

--- A list of problems, empty when the config is usable. validate.luau and
--- DiscordReporter.start both call it.
function DiscordConfig.problems(): { string }
	local out: { string } = {}
	local function check(ok: boolean, message: string)
		if not ok then
			table.insert(out, message)
		end
	end
	check(type(DiscordConfig.WEBHOOK) == "string", "WEBHOOK must be a string")
	check(string.sub(DiscordConfig.PROXY_PREFIX, 1, 8) == "https://" and string.sub(DiscordConfig.PROXY_PREFIX, -1) == "/",
		"PROXY_PREFIX must be https and end with /")
	check(DiscordConfig.MESSAGES_PER_MINUTE >= 1 and DiscordConfig.MESSAGES_PER_MINUTE <= 30, "MESSAGES_PER_MINUTE must be 1-30")
	check(DiscordConfig.QUEUE_MAX >= 5, "QUEUE_MAX must be at least 5")
	check(DiscordConfig.MAX_ATTEMPTS >= 1, "MAX_ATTEMPTS must be at least 1")
	check(DiscordConfig.BURST_SECONDS >= 1 and DiscordConfig.BURST_SECONDS <= 60, "BURST_SECONDS must be 1-60")
	check(DiscordConfig.ERROR_DEDUPE_SECONDS >= 60, "ERROR_DEDUPE_SECONDS must be at least 60")
	check(DiscordConfig.SUMMARY_SECONDS >= 300, "SUMMARY_SECONDS must be at least 300")
	check(DiscordConfig.DAILY_FLUSH_SECONDS >= 30, "DAILY_FLUSH_SECONDS must be at least 30 (DataStore budget)")
	check(DiscordConfig.DIGEST_AFTER_SECONDS >= 0 and DiscordConfig.DIGEST_AFTER_SECONDS < 3600, "DIGEST_AFTER_SECONDS must be 0-3599")
	check(DiscordConfig.PERF_FLUSH_SECONDS >= 30, "PERF_FLUSH_SECONDS must be at least 30")
	check(DiscordConfig.PERF_BATCH_ROWS >= 1 and DiscordConfig.PERF_BATCH_ROWS <= DiscordConfig.PERF_BUFFER_MAX,
		"PERF_BATCH_ROWS must be 1..PERF_BUFFER_MAX")
	check(DiscordConfig.SERVER_LAG_FPS > 0 and DiscordConfig.SERVER_LAG_FPS < 60, "SERVER_LAG_FPS must be 1-59")
	check(DiscordConfig.FLOOD_REJECTS >= 5, "FLOOD_REJECTS must be at least 5")
	check(DiscordConfig.MIRROR_FLUSH_SECONDS >= 15, "MIRROR_FLUSH_SECONDS must be at least 15")
	check(DiscordConfig.MIRROR_BATCH_ROWS >= 1, "MIRROR_BATCH_ROWS must be at least 1")
	check(DiscordConfig.MIRROR_MIN_GAP >= 1, "MIRROR_MIN_GAP must be at least 1")
	check(DiscordConfig.MIRROR_MESSAGES_PER_MINUTE >= 1 and DiscordConfig.MIRROR_MESSAGES_PER_MINUTE < DiscordConfig.MESSAGES_PER_MINUTE,
		"MIRROR_MESSAGES_PER_MINUTE must be 1..MESSAGES_PER_MINUTE-1 (leave room for purchases and errors)")
	check(DiscordConfig.MIRROR_BUFFER_MAX >= 100, "MIRROR_BUFFER_MAX must be at least 100")
	for cause, limits in DiscordConfig.CAUSE_THRESHOLDS do
		for key, value in limits do
			check(type(value) == "number" and value > 0, `CAUSE_THRESHOLDS.{cause}.{key} must be positive`)
		end
	end
	return out
end

return DiscordConfig
