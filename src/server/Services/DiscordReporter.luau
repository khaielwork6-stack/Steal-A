--!strict
--[[
	DiscordReporter  (analytics-discord)
	Posts what the owner wants to see without opening the dashboard to a
	Discord channel. See docs/handoff-parts/analytics-discord.md for the setup.

	WHAT IT POSTS (embeds, colour-coded):
	  * INSTANT: every Robux purchase (merged: purchases landing within
	    BURST_SECONDS are one embed), reveals of REVEAL_MIN_RARITY or better
	    (merged the same way), and server script errors (one post per
	    distinct message per ERROR_DEDUPE_SECONDS, with a repeat count).
	  * EVERY SUMMARY_SECONDS while the server has players: players now /
	    peak, sessions ended, average session, new players, the top quit
	    contexts, the top catch zones, purchases and Robux in the window.
	  * ONCE A DAY across ALL servers: every server adds its counters to the
	    DataStore DAILY_STORE (key = the UTC date, UpdateAsync, batched every
	    DAILY_FLUSH_SECONDS and on shutdown); after 00:05 UTC one server wins
	    the lock key "digest_<date>" (UpdateAsync that only writes when it is
	    empty) and posts yesterday's digest. The others see the lock and skip.
	  * THE ANALYTICS MIRROR (the owner's main ask): every event AnalyticsEvents
	    records - funnel steps, Cash and Speed economy events, progression,
	    every custom event with its fields - as "<GAME_NAME> analytics" CSV
	    batches (see ANALYTICS MIRROR below; switch MIRROR_ANALYTICS).
	  * Raw text for PerfFeed's "errors and spikes" CSV batches (postText).

	THE WEBHOOK NEVER APPEARS IN A LOG, AN ERROR OR A CLIENT. It is read from
	DiscordConfig.WEBHOOK (rewritten to the proxy), else the DISCORD_WEBHOOK
	secret (a Secret object: AddPrefix builds the URL without ever making it a
	readable string), else - Studio only - a ServerStorage attribute. Every
	logged string passes through `redact`. Nothing here replicates.

	LIMITS: one queue per server, at most MESSAGES_PER_MINUTE sends, 429s
	wait out Discord's retry_after, network / 5xx errors back off and retry
	up to MAX_ATTEMPTS, and past QUEUE_MAX the oldest message is dropped.
	`allowed_mentions` is empty on every message, so a username or an error
	text can never ping anyone.

	STUDIO posts nothing unless DiscordConfig.DEBUG / POST_FROM_STUDIO or the
	`discordDebug` command; `discordTest` may always post its one message.
	Privacy: Roblox usernames and user ids only.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local ServerStorage = game:GetService("ServerStorage")

local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local DiscordConfig = require(script.Parent.Parent.Config.DiscordConfig)
local AnalyticsEvents = require(script.Parent.AnalyticsEvents)
local AnalyticsSession = require(script.Parent.AnalyticsSession)

local DiscordReporter = {}

local IS_STUDIO = RunService:IsStudio()

local COLORS = {
	purchase = 0xF1C40F,
	reveal = 0x9B59B6,
	error = 0xE74C3C,
	summary = 0x3498DB,
	digest = 0x2ECC71,
	test = 0x95A5A6,
}

-- ==========================================================
-- STATE
-- ==========================================================

local started = false
local enabled = false
local reason = "not started"
local source = "none"
local studioOverride = false
--- The webhook: a string (config / Studio attribute) or a Secret. NEVER
--- printed, concatenated into a message, or returned by `status`.
local target: any = nil
local warned: { [string]: true } = {}

--- `low`: a feed batch (analytics mirror, errors and spikes). When the
--- queue is full, the oldest LOW message goes first, so a burst of feed
--- rows can never push out a purchase or an error embed.
type Message = { payload: string, title: string, attempts: number, notBefore: number, low: boolean }
local queue: { Message } = {}
local stats = {
	queued = 0,
	sent = 0,
	failed = 0,
	dropped = 0,
	skipped = 0,
	rateLimited = 0,
	lastStatus = 0,
	lastError = "",
}
local tokens = 0
local tokensAt = os.clock()

--- Anything that might carry a webhook path is cut before it is logged.
local function redact(text: string): string
	local out = string.gsub(text, "webhooks/[^%s\"']+", "webhooks/<redacted>")
	out = string.gsub(out, "https?://[^%s\"']*lewisakura[^%s\"']*", "<proxy>")
	return out
end

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn(`[DiscordReporter] {redact(message)}`)
end

local function studioAllowed(): boolean
	return not IS_STUDIO or DiscordConfig.DEBUG == true or DiscordConfig.POST_FROM_STUDIO == true or studioOverride
end

local function truncate(text: string, limit: number): string
	if #text <= limit then
		return text
	end
	return string.sub(text, 1, limit - 3) .. "..."
end

--- Text that goes inside a Discord code block.
local function codeSafe(text: string): string
	return (string.gsub(text, "```", "'''"))
end

-- ==========================================================
-- WEBHOOK
-- ==========================================================

--- "<id>/<token>" from a Discord or proxy webhook URL, or nil.
local function idToken(url: string): string?
	local trimmed = string.match(url, "^%s*(.-)%s*$") or url
	for _, pattern in {
		"^https://[%w%.]*discord%.com/api/v?%d*/?webhooks/(%d+/[%w_%-]+)",
		"^https://[%w%.]*discordapp%.com/api/v?%d*/?webhooks/(%d+/[%w_%-]+)",
		"^https://webhook%.lewisakura%.moe/api/webhooks/(%d+/[%w_%-]+)",
		"^(%d+/[%w_%-]+)$",
	} do
		local found = string.match(trimmed, pattern)
		if found then
			return found
		end
	end
	return nil
end

--- (target, where it came from) or (nil, why not).
local function resolveTarget(): (any, string)
	local configured = DiscordConfig.WEBHOOK
	if type(configured) == "string" and configured ~= "" then
		local pair = idToken(configured)
		if not pair then
			return nil, "DiscordConfig.WEBHOOK is set but is not a Discord webhook URL"
		end
		return DiscordConfig.PROXY_PREFIX .. pair, "DiscordConfig.WEBHOOK"
	end

	local okSecret, secret = pcall(function()
		return (HttpService :: any):GetSecret(DiscordConfig.SECRET_NAME)
	end)
	if okSecret and secret ~= nil then
		local okUrl, url = pcall(function()
			return (secret :: any):AddPrefix(DiscordConfig.PROXY_PREFIX)
		end)
		if okUrl and url ~= nil then
			return url, `secret {DiscordConfig.SECRET_NAME}`
		end
	end

	if IS_STUDIO then
		local attribute = ServerStorage:GetAttribute(DiscordConfig.STUDIO_ATTRIBUTE)
		if type(attribute) == "string" and attribute ~= "" then
			local pair = idToken(attribute)
			if pair then
				return DiscordConfig.PROXY_PREFIX .. pair, `Studio attribute ServerStorage.{DiscordConfig.STUDIO_ATTRIBUTE}`
			end
			return nil, `ServerStorage.{DiscordConfig.STUDIO_ATTRIBUTE} is not "<id>/<token>"`
		end
	end
	return nil, `no webhook: DiscordConfig.WEBHOOK is empty and the "{DiscordConfig.SECRET_NAME}" secret is not available`
end

--- Works out whether this server posts, warning ONCE about a real problem.
local function evaluate()
	target = nil
	local problems = DiscordConfig.problems()
	if #problems > 0 then
		enabled, reason = false, "config: " .. table.concat(problems, "; ")
		warnOnce("config", `DiscordConfig problems - reporting disabled: {table.concat(problems, "; ")}`)
		return
	end
	if not DiscordConfig.ENABLED then
		enabled, reason = false, "DiscordConfig.ENABLED is false"
		return
	end
	local httpOn = false
	pcall(function()
		httpOn = HttpService.HttpEnabled
	end)
	local resolved, where = resolveTarget()
	target = resolved
	source = if resolved then where else "none"
	if not httpOn then
		enabled, reason = false, "HTTP requests are off (Game Settings > Security > Allow HTTP Requests)"
		if studioAllowed() then
			warnOnce("http", "HTTP requests are off (Game Settings > Security > Allow HTTP Requests) - Discord reporting disabled.")
		end
		return
	end
	if not resolved then
		enabled, reason = false, where
		if studioAllowed() then
			warnOnce("webhook", `{where} - Discord reporting disabled. See docs/handoff-parts/analytics-discord.md.`)
		end
		return
	end
	if not studioAllowed() then
		enabled, reason = false, "Studio: posting is off (DiscordConfig.DEBUG / POST_FROM_STUDIO, or discordDebug true)"
		return
	end
	enabled, reason = true, `posting via {where}`
end

-- ==========================================================
-- QUEUE
-- ==========================================================

local function enqueue(title: string, payload: { [string]: any }, force: boolean?, low: boolean?): boolean
	if not enabled and not (force and target ~= nil) then
		stats.skipped += 1
		return false
	end
	payload.username = DiscordConfig.GAME_NAME
	payload.allowed_mentions = { parse = {} }
	local ok, body = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not ok or type(body) ~= "string" then
		stats.failed += 1
		stats.lastError = "could not encode a message"
		return false
	end
	if #queue >= DiscordConfig.QUEUE_MAX then
		local victim: number? = nil
		for index, waiting in queue do
			if waiting.low then
				victim = index
				break
			end
		end
		stats.dropped += 1
		if victim then
			table.remove(queue, victim)
		elseif low then
			return false -- a feed batch never displaces an embed
		else
			table.remove(queue, 1)
		end
	end
	table.insert(queue, { payload = body, title = title, attempts = 0, notBefore = 0, low = low == true })
	stats.queued += 1
	if DiscordConfig.DEBUG then
		print(`[DiscordReporter] queued: {title}`)
	end
	return true
end

local function retryAfter(response: any): number
	local seconds: number? = nil
	pcall(function()
		local decoded = HttpService:JSONDecode(response.Body)
		seconds = tonumber(decoded.retry_after)
	end)
	if not seconds and type(response.Headers) == "table" then
		seconds = tonumber(response.Headers["retry-after"] or response.Headers["Retry-After"])
	end
	return math.clamp(seconds or 5, 1, 60)
end

local function sendOne(message: Message)
	local now = os.clock()
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = target :: any,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = message.payload,
		})
	end)
	local function remove()
		local at = table.find(queue, message)
		if at then
			table.remove(queue, at)
		end
	end
	if ok and type(response) == "table" then
		local code = tonumber(response.StatusCode) or 0
		stats.lastStatus = code
		if response.Success then
			stats.sent += 1
			remove()
			return
		elseif code == 429 then
			stats.rateLimited += 1
			message.notBefore = now + retryAfter(response)
			return
		elseif code >= 400 and code < 500 then
			-- Our message is wrong or the webhook is gone: retrying cannot help.
			stats.failed += 1
			stats.lastError = `HTTP {code} on "{message.title}"`
			warnOnce(`http{code}`, `Discord answered HTTP {code} (first seen on "{message.title}"); message dropped.`)
			remove()
			return
		end
		stats.lastError = `HTTP {code}`
	else
		stats.lastError = redact(tostring(response))
	end
	message.attempts += 1
	if message.attempts >= DiscordConfig.MAX_ATTEMPTS then
		stats.failed += 1
		warnOnce("gaveup", `gave up on a message after {message.attempts} attempts: {stats.lastError}`)
		remove()
	else
		message.notBefore = now + 2 ^ message.attempts
	end
end

local function worker()
	while true do
		local message = queue[1]
		if not message or target == nil then
			task.wait(0.5)
			continue
		end
		local now = os.clock()
		local perSecond = DiscordConfig.MESSAGES_PER_MINUTE / 60
		tokens = math.min(DiscordConfig.MESSAGES_PER_MINUTE, tokens + (now - tokensAt) * perSecond)
		tokensAt = now
		if tokens < 1 or now < message.notBefore then
			task.wait(0.5)
			continue
		end
		tokens -= 1
		sendOne(message)
	end
end

-- ==========================================================
-- EMBEDS
-- ==========================================================

local function footer(): { text: string }
	local job = if game.JobId ~= "" then string.sub(game.JobId, 1, 8) else "studio"
	return { text = `{DiscordConfig.GAME_NAME} · server {job} · v{game.PlaceVersion}` }
end

local function embed(title: string, description: string?, color: number, fields: { any }?): { [string]: any }
	local out: { [string]: any } = {
		title = truncate(title, 250),
		color = color,
		footer = footer(),
	}
	pcall(function()
		out.timestamp = DateTime.now():ToIsoDate()
	end)
	if description and description ~= "" then
		out.description = truncate(description, 3900)
	end
	if fields and #fields > 0 then
		out.fields = fields
	end
	return out
end

local function field(name: string, value: string, inline: boolean?): { [string]: any }
	return { name = truncate(name, 250), value = truncate(if value == "" then "-" else value, 1000), inline = inline == true }
end

local function postEmbed(title: string, description: string?, color: number, fields: { any }?, force: boolean?): boolean
	return enqueue(title, { embeds = { embed(title, description, color, fields) } }, force)
end

--- Plain text (the CSV feed batches). Must already be under 2000 chars.
--- Low priority: see Message.
function DiscordReporter.postText(title: string, content: string): boolean
	return enqueue(title, { content = truncate(content, 1990) }, false, true)
end

function DiscordReporter.isEnabled(): boolean
	return enabled
end

local function who(player: Player?): string
	if not player then
		return "someone who left"
	end
	return `**{player.Name}** ({player.UserId})`
end

local function topList(map: { [string]: number }, count: number): string
	local rows: { { key: string, value: number } } = {}
	for key, value in map do
		table.insert(rows, { key = key, value = value })
	end
	table.sort(rows, function(a, b)
		return a.value > b.value
	end)
	local lines: { string } = {}
	for index = 1, math.min(count, #rows) do
		table.insert(lines, `{rows[index].key}: {rows[index].value}`)
	end
	return if #lines > 0 then table.concat(lines, "\n") else "-"
end

local function minutes(seconds: number): string
	if seconds < 60 then
		return `{math.floor(seconds)}s`
	elseif seconds < 3600 then
		return string.format("%.1f min", seconds / 60)
	end
	return string.format("%.1f h", seconds / 3600)
end

-- ==========================================================
-- INSTANT: PURCHASES AND BIG REVEALS (merged bursts)
-- ==========================================================

type Burst = { lines: { string }, robux: number, armed: boolean }
local purchases: Burst = { lines = {}, robux = 0, armed = false }
local reveals: Burst = { lines = {}, robux = 0, armed = false }

local function flushBurst(burst: Burst, kind: string)
	burst.armed = false
	local lines = burst.lines
	if #lines == 0 then
		return
	end
	burst.lines = {}
	local robux = burst.robux
	burst.robux = 0
	local shown = table.move(lines, 1, math.min(#lines, 15), 1, {})
	if #lines > 15 then
		table.insert(shown, `...and {#lines - 15} more`)
	end
	if kind == "purchase" then
		local title = if #lines == 1 then "Robux purchase" else `{#lines} Robux purchases`
		postEmbed(title, table.concat(shown, "\n"), COLORS.purchase, { field("Robux", `R$ {robux}`, true) })
	else
		local title = if #lines == 1 then "Big reveal" else `{#lines} big reveals`
		postEmbed(title, table.concat(shown, "\n"), COLORS.reveal)
	end
end

local function addToBurst(burst: Burst, kind: string, line: string, robux: number)
	table.insert(burst.lines, line)
	burst.robux += robux
	if not burst.armed then
		burst.armed = true
		task.delay(DiscordConfig.BURST_SECONDS, function()
			local ok: boolean, err: any = (pcall :: any)(flushBurst, burst, kind)
			if not ok then
				warn(`[DiscordReporter] burst post failed: {redact(tostring(err))}`)
			end
		end)
	end
end

-- ==========================================================
-- COUNTERS: the 30-minute window and the day
-- ==========================================================

type Window = {
	started: number,
	peak: number,
	sessionsEnded: number,
	sessionSeconds: number,
	newPlayers: number,
	quits: { [string]: number },
	catches: { [string]: number },
	purchases: number,
	robux: number,
}

local function newWindow(): Window
	return {
		started = os.time(),
		peak = #Players:GetPlayers(),
		sessionsEnded = 0,
		sessionSeconds = 0,
		newPlayers = 0,
		quits = {},
		catches = {},
		purchases = 0,
		robux = 0,
	}
end
local window = newWindow()

local DAY_NUMBERS = { "joins", "newPlayers", "sessions", "playSeconds", "d1Return", "purchases", "robux" }
local DAY_MAPS = { "quits", "catches", "reveals" }

--- Day key -> counters not yet merged into the DataStore.
local pendingDays: { [string]: { [string]: any } } = {}

local function dayKey(at: number?): string
	return os.date("!%Y-%m-%d", at or os.time())
end

local function newDay(): { [string]: any }
	local day: { [string]: any } = {}
	for _, name in DAY_NUMBERS do
		day[name] = 0
	end
	for _, name in DAY_MAPS do
		day[name] = {}
	end
	return day
end

local function today(): { [string]: any }
	local key = dayKey()
	local day = pendingDays[key]
	if not day then
		day = newDay()
		pendingDays[key] = day
	end
	return day
end

local function bump(map: { [string]: number }, key: string, amount: number?)
	map[key] = (map[key] or 0) + (amount or 1)
end

local function onFact(name: string, player: Player?, data: { [string]: any })
	if name == "SessionStart" then
		local day = today()
		day.joins += 1
		if data.new then
			day.newPlayers += 1
			window.newPlayers += 1
		end
		if data.d1 then
			day.d1Return += 1
		end
	elseif name == "SessionEnd" then
		local seconds = tonumber(data.seconds) or 0
		local context = tostring(data.context or "Unknown")
		window.sessionsEnded += 1
		window.sessionSeconds += seconds
		bump(window.quits, context)
		local day = today()
		day.sessions += 1
		day.playSeconds += seconds
		bump(day.quits, context)
	elseif name == "Caught" then
		local zone = tostring(data.zone or "None")
		bump(window.catches, zone)
		bump(today().catches, zone)
	elseif name == "Revealed" then
		local rarity = tostring(data.rarity or "Unknown")
		bump(today().reveals, rarity)
		if RarityConfig.rank(rarity) >= RarityConfig.rank(DiscordConfig.REVEAL_MIN_RARITY) then
			local def = LootConfig.ById[tostring(data.itemId)]
			local mutation = if type(data.mutation) == "string" and data.mutation ~= "Normal" and data.mutation ~= "" then `{data.mutation} ` else ""
			local itemName = if def then def.name else tostring(data.itemId)
			addToBurst(reveals, "reveal", `{who(player)} revealed a **{mutation}{rarity}** {itemName} ({data.zone})`, 0)
		end
	elseif name == "Purchase" then
		local robux = math.max(0, math.floor(tonumber(data.robux) or 0))
		window.purchases += 1
		window.robux += robux
		local day = today()
		day.purchases += 1
		day.robux += robux
		if DiscordConfig.POST_PURCHASES then
			local first = if data.first then "  ·  **FIRST PURCHASE**" else ""
			addToBurst(purchases, "purchase", `{who(player)} bought **{data.label}** ({data.kind}) for **R$ {robux}**{first}`, robux)
		end
	end
end

-- ==========================================================
-- SERVER ERRORS
-- ==========================================================

type Seen = { last: number, repeats: number }
local errorsSeen: { [string]: Seen } = {}

local function onError(message: string, trace: string, scriptInstance: Instance?)
	if not DiscordConfig.POST_ERRORS then
		return
	end
	local key = truncate(message, 200)
	local now = os.clock()
	local seen = errorsSeen[key]
	if seen and now - seen.last < DiscordConfig.ERROR_DEDUPE_SECONDS then
		seen.repeats += 1
		return
	end
	local repeats = if seen then seen.repeats else 0
	errorsSeen[key] = { last = now, repeats = 0 }
	local path = if scriptInstance then scriptInstance:GetFullName() else "?"
	local firstLine = string.match(trace or "", "^[^\n]+") or "?"
	postEmbed("Server error", "```\n" .. codeSafe(redact(truncate(message, 1500))) .. "\n```", COLORS.error, {
		field("Script", redact(path), false),
		field("At", redact(firstLine), false),
		field("Repeats since the last post", tostring(repeats), true),
		field("Players", tostring(#Players:GetPlayers()), true),
	})
end

-- ==========================================================
-- 30-MINUTE SUMMARY
-- ==========================================================

function DiscordReporter.postSummary(force: boolean?): boolean
	local w = window
	local players = #Players:GetPlayers()
	if w.peak <= 0 and players <= 0 and not force then
		window = newWindow()
		return false
	end
	window = newWindow()
	local average = if w.sessionsEnded > 0 then w.sessionSeconds / w.sessionsEnded else 0
	local span = math.max(1, os.time() - w.started)
	return postEmbed(`Server summary (last {math.floor(span / 60 + 0.5)} min)`, nil, COLORS.summary, {
		field("Players now / peak", `{players} / {math.max(w.peak, players)}`, true),
		field("Sessions ended", tostring(w.sessionsEnded), true),
		field("Average session", minutes(average), true),
		field("New players", tostring(w.newPlayers), true),
		field("Purchases", `{w.purchases} (R$ {w.robux})`, true),
		field("\u{200B}", "\u{200B}", true),
		field("Quits by context (top 3)", topList(w.quits, 3), true),
		field("Catches by zone (top 3)", topList(w.catches, 3), true),
		field("Analytics mirror", DiscordReporter.takeMirrorWindow(), false),
	}, force)
end

-- ==========================================================
-- DAILY DIGEST
-- ==========================================================

local store: DataStore? = nil

local function getStore(): DataStore?
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DiscordConfig.DAILY_STORE)
	end)
	if ok then
		store = result
	else
		warnOnce("store", `DataStore {DiscordConfig.DAILY_STORE} unavailable: {result}`)
	end
	return store
end

local function mergeInto(doc: { [string]: any }, day: { [string]: any })
	for _, name in DAY_NUMBERS do
		doc[name] = (tonumber(doc[name]) or 0) + (tonumber(day[name]) or 0)
	end
	for _, name in DAY_MAPS do
		local map = if type(doc[name]) == "table" then doc[name] else {}
		for key, value in day[name] :: { [string]: number } do
			map[key] = (tonumber(map[key]) or 0) + value
		end
		doc[name] = map
	end
end

local function isEmpty(day: { [string]: any }): boolean
	for _, name in DAY_NUMBERS do
		if (tonumber(day[name]) or 0) ~= 0 then
			return false
		end
	end
	for _, name in DAY_MAPS do
		if next(day[name]) ~= nil then
			return false
		end
	end
	return true
end

local lastDailyError = ""

--- Merges every pending day's counters into the store. A failed day is
--- kept and retried at the next flush.
function DiscordReporter.flushDaily()
	if not enabled or not DiscordConfig.DAILY_ENABLED then
		return
	end
	local dataStore = getStore()
	if not dataStore then
		return
	end
	local days = pendingDays
	pendingDays = {}
	for key, day in days do
		if isEmpty(day) then
			continue
		end
		local ok: boolean, err: any = (pcall :: any)(function()
			(dataStore :: DataStore):UpdateAsync(key, function(old: any)
				local doc = if type(old) == "table" then old else {}
				mergeInto(doc, day)
				return doc
			end)
		end)
		if not ok then
			lastDailyError = redact(tostring(err))
			local back = pendingDays[key]
			if back then
				mergeInto(back, day)
			else
				pendingDays[key] = day
			end
		end
	end
end

local digestHandled: { [string]: true } = {}
local lastDigest = ""

local function digestEmbed(date: string, doc: { [string]: any }, previous: { [string]: any }?): { [string]: any }
	local sessions = tonumber(doc.sessions) or 0
	local playSeconds = tonumber(doc.playSeconds) or 0
	local average = if sessions > 0 then playSeconds / sessions else 0
	local newBefore = if previous then tonumber(previous.newPlayers) or 0 else 0
	local d1 = tonumber(doc.d1Return) or 0
	local d1Text = if newBefore > 0 then string.format("%d of %d (%.0f%%)", d1, newBefore, d1 / newBefore * 100) else `{d1}`
	local reveals: { string } = {}
	local revealMap = if type(doc.reveals) == "table" then doc.reveals else {}
	for index = #RarityConfig.Order, 1, -1 do
		local rarity = RarityConfig.Order[index]
		local count = tonumber(revealMap[rarity])
		if count and count > 0 then
			table.insert(reveals, `{rarity}: {count}`)
		end
	end
	return embed(`Daily digest - {date} (UTC)`, nil, COLORS.digest, {
		field("Joins", tostring(doc.joins or 0), true),
		field("New players", tostring(doc.newPlayers or 0), true),
		field("D1 return", d1Text, true),
		field("Sessions", tostring(sessions), true),
		field("Average session", minutes(average), true),
		field("Total play", string.format("%.1f h", playSeconds / 3600), true),
		field("Purchases", `{doc.purchases or 0} (R$ {doc.robux or 0})`, true),
		field("\u{200B}", "\u{200B}", true),
		field("\u{200B}", "\u{200B}", true),
		field("Quits by context", topList(if type(doc.quits) == "table" then doc.quits else {}, 7), true),
		field("Catches by zone", topList(if type(doc.catches) == "table" then doc.catches else {}, 5), true),
		field("Reveals by rarity", if #reveals > 0 then table.concat(reveals, "\n") else "-", true),
	})
end

--- After DIGEST_AFTER_SECONDS past 00:00 UTC: claim yesterday's lock and,
--- if this server won it, post yesterday's digest.
local function maybeDigest()
	if not enabled or not DiscordConfig.DAILY_ENABLED then
		return
	end
	local now = os.time()
	if now % 86400 < DiscordConfig.DIGEST_AFTER_SECONDS then
		return
	end
	local yesterday = dayKey(now - 86400)
	if digestHandled[yesterday] then
		return
	end
	local dataStore = getStore()
	if not dataStore then
		return
	end
	digestHandled[yesterday] = true
	DiscordReporter.flushDaily()
	local token = HttpService:GenerateGUID(false)
	local ok, result = pcall(function()
		return (dataStore :: DataStore):UpdateAsync(`digest_{yesterday}`, function(old: any)
			if old ~= nil then
				return nil -- already claimed: leave it alone
			end
			return { by = token, at = now, job = game.JobId }
		end)
	end)
	if not ok then
		digestHandled[yesterday] = nil -- try again next minute
		lastDailyError = redact(tostring(result))
		return
	end
	if type(result) ~= "table" or result.by ~= token then
		lastDigest = `{yesterday}: claimed by another server`
		return
	end
	local okDoc, doc = pcall(function()
		return (dataStore :: DataStore):GetAsync(yesterday)
	end)
	local okPrev, previous = pcall(function()
		return (dataStore :: DataStore):GetAsync(dayKey(now - 2 * 86400))
	end)
	local data = if okDoc and type(doc) == "table" then doc else newDay()
	enqueue(`Daily digest {yesterday}`, { embeds = { digestEmbed(yesterday, data, if okPrev and type(previous) == "table" then previous else nil) } })
	lastDigest = `{yesterday}: posted by this server`
end

-- ==========================================================
-- ANALYTICS MIRROR ("Steal & Run! analytics" CSV feed)
-- ==========================================================
-- EVERY event AnalyticsEvents records - funnels, economy (Cash and Speed),
-- progression, custom - arrives here from its one send() path
-- (AnalyticsEvents.mirror) and is posted as CSV rows:
--
--     utc,type,event,player,sid,field1,field2,field3,value
--
-- Flushed every MIRROR_FLUSH_SECONDS, or early at MIRROR_BATCH_ROWS rows
-- (at most one early flush per MIRROR_MIN_GAP). At most
-- MIRROR_MESSAGES_PER_MINUTE messages; when a flush has more rows than that
-- budget holds, identical rows (same event, player and fields) are merged
-- into one with "xN" on the value, then the player is dropped from the key
-- ("*"), and only then are the oldest rows dropped. Counts go in the summary.

type MirrorEntry = {
	at: number,
	type: string,
	event: string,
	player: string,
	sid: string,
	f1: string,
	f2: string,
	f3: string,
	value: number,
	count: number,
}

local mirrorRows: { MirrorEntry } = {}
local mirrorRecent: { string } = {}
local mirrorStats = { rows = 0, aggregated = 0, dropped = 0, messages = 0 }
local mirrorWindow = { rows = 0, aggregated = 0, dropped = 0 }
local mirrorSentAt: { number } = {}
local lastMirrorFlush = 0

local MIRROR_HEADER = "utc,type,event,player,sid,field1,field2,field3,value"
--- Rows a 2000-character message holds, roughly (for the budget).
local ROWS_PER_MESSAGE = 16

local function csvCell(value: any, limit: number): string
	local text = tostring(if value == nil then "" else value)
	text = string.gsub(text, "[\r\n\t]", " ")
	text = string.gsub(text, ",", ";")
	text = string.gsub(text, "`", "'")
	if #text > limit then
		text = string.sub(text, 1, limit - 3) .. "..."
	end
	return text
end

local function valueText(value: number, count: number): string
	local shown = if value == math.floor(value) then tostring(value) else string.format("%.2f", value)
	return if count > 1 then `{shown} x{count}` else shown
end

local function mirrorLine(entry: MirrorEntry): string
	return table.concat({
		os.date("!%Y-%m-%d %H:%M:%S", entry.at),
		csvCell(entry.type, 12),
		csvCell(entry.event, 40),
		csvCell(entry.player, 24),
		csvCell(entry.sid, 12),
		csvCell(entry.f1, 40),
		csvCell(entry.f2, 40),
		csvCell(entry.f3, 40),
		valueText(entry.value, entry.count),
	}, ",")
end

--- Merges rows that share event and fields (and player, unless `anyone`).
local function aggregate(rows: { MirrorEntry }, anyone: boolean): { MirrorEntry }
	local out: { MirrorEntry } = {}
	local byKey: { [string]: MirrorEntry } = {}
	for _, entry in rows do
		local who_ = if anyone then "*" else entry.player
		local key = table.concat({ entry.type, entry.event, who_, entry.f1, entry.f2, entry.f3 }, "|")
		local existing = byKey[key]
		if existing then
			existing.value += entry.value
			existing.count += entry.count
			mirrorStats.aggregated += entry.count
			mirrorWindow.aggregated += entry.count
		else
			local copy = table.clone(entry)
			if anyone and copy.player ~= "*" then
				copy.player = "*"
				copy.sid = "*"
			end
			byKey[key] = copy
			table.insert(out, copy)
		end
	end
	return out
end

local function flushMirror()
	if #mirrorRows == 0 or not enabled then
		return
	end
	local now = os.clock()
	lastMirrorFlush = now
	for index = #mirrorSentAt, 1, -1 do
		if now - mirrorSentAt[index] > 60 then
			table.remove(mirrorSentAt, index)
		end
	end
	local budget = DiscordConfig.MIRROR_MESSAGES_PER_MINUTE - #mirrorSentAt
	if budget <= 0 then
		return -- the rows wait for the next flush (and are merged then)
	end
	local capacity = budget * ROWS_PER_MESSAGE
	local rows = mirrorRows
	mirrorRows = {}
	if #rows > capacity then
		rows = aggregate(rows, false)
	end
	if #rows > capacity then
		rows = aggregate(rows, true)
	end
	if #rows > capacity then
		local extra = #rows - capacity
		mirrorStats.dropped += extra
		mirrorWindow.dropped += extra
		rows = table.move(rows, extra + 1, #rows, 1, {})
	end

	local open = `**{DiscordConfig.GAME_NAME} analytics**\n` .. "```csv\n" .. MIRROR_HEADER .. "\n"
	local close = "```"
	local body = open
	local inBody = 0
	local function post()
		DiscordReporter.postText("analytics", body .. close)
		table.insert(mirrorSentAt, os.clock())
		mirrorStats.messages += 1
		body = open
		inBody = 0
	end
	for _, entry in rows do
		local line = mirrorLine(entry)
		if inBody > 0 and #body + #line + 1 + #close > 1950 then
			post()
		end
		body ..= line .. "\n"
		inBody += 1
	end
	if inBody > 0 then
		post()
	end
end

--- AnalyticsEvents.mirror: one recorded analytics event.
local function mirrorRow(player: Player, row: AnalyticsEvents.MirrorRow)
	if not DiscordConfig.MIRROR_ANALYTICS then
		return
	end
	local entry: MirrorEntry = {
		at = os.time(),
		type = row.type,
		event = row.event,
		player = player.Name,
		sid = AnalyticsSession.sid(player),
		f1 = row.f1 or "",
		f2 = row.f2 or "",
		f3 = row.f3 or "",
		value = tonumber(row.value) or 0,
		count = 1,
	}
	mirrorStats.rows += 1
	mirrorWindow.rows += 1
	table.insert(mirrorRecent, mirrorLine(entry))
	while #mirrorRecent > 15 do
		table.remove(mirrorRecent, 1)
	end
	if not enabled then
		return
	end
	table.insert(mirrorRows, entry)
	if #mirrorRows > DiscordConfig.MIRROR_BUFFER_MAX then
		-- Waiting on the budget: merge in place before anything is lost.
		mirrorRows = aggregate(mirrorRows, false)
		while #mirrorRows > DiscordConfig.MIRROR_BUFFER_MAX do
			table.remove(mirrorRows, 1)
			mirrorStats.dropped += 1
			mirrorWindow.dropped += 1
		end
	end
	if #mirrorRows >= DiscordConfig.MIRROR_BATCH_ROWS and os.clock() - lastMirrorFlush >= DiscordConfig.MIRROR_MIN_GAP then
		task.spawn(flushMirror)
	end
end

--- The mirror's counts since the last summary (and resets them).
function DiscordReporter.takeMirrorWindow(): string
	local text = `{mirrorWindow.rows} rows · {mirrorWindow.aggregated} merged into others · {mirrorWindow.dropped} dropped`
	mirrorWindow.rows, mirrorWindow.aggregated, mirrorWindow.dropped = 0, 0, 0
	return text
end

--- Studio: the mirror's counters and last rows.
function DiscordReporter.mirrorStatus(): { [string]: any }
	return {
		enabled = DiscordConfig.MIRROR_ANALYTICS,
		waiting = #mirrorRows,
		stats = table.clone(mirrorStats),
		recent = table.clone(mirrorRecent),
	}
end

-- ==========================================================
-- DEBUG
-- ==========================================================

function DiscordReporter.status(): { [string]: any }
	local pending = table.clone(pendingDays)
	local titles = {}
	for index, message in queue do
		titles[index] = `{message.title} (attempts {message.attempts})`
	end
	return {
		studio = IS_STUDIO,
		enabled = enabled,
		reason = reason,
		-- WHERE the webhook came from, never the webhook itself.
		webhookSource = source,
		hasWebhook = target ~= nil,
		studioOverride = studioOverride,
		queue = titles,
		stats = table.clone(stats),
		window = {
			startedMinutesAgo = math.floor((os.time() - window.started) / 60),
			peak = window.peak,
			sessionsEnded = window.sessionsEnded,
			newPlayers = window.newPlayers,
			purchases = window.purchases,
			robux = window.robux,
			quits = table.clone(window.quits),
			catches = table.clone(window.catches),
		},
		pendingDays = pending,
		lastDailyError = lastDailyError,
		lastDigest = lastDigest,
		mirror = DiscordReporter.mirrorStatus(),
	}
end

--- Studio: flush the analytics mirror now (still inside its budget).
function DiscordReporter.flushMirrorNow()
	flushMirror()
end

--- Studio: allow (or stop) posting from this Studio session.
function DiscordReporter.setDebug(on: boolean)
	studioOverride = on
	evaluate()
end

--- Posts ONE test embed, even in Studio with posting off, if a webhook is
--- available. Returns (queued, why not).
function DiscordReporter.test(player: Player?): (boolean, string?)
	if not started then
		return false, "DiscordReporter has not started"
	end
	evaluate()
	if target == nil then
		return false, reason
	end
	local ok = postEmbed("Test message", `Sent by the discordTest command{if player then " (" .. player.Name .. ")" else ""}. If you can read this, the webhook works.`, COLORS.test, {
		field("Webhook from", source, true),
		field("Studio", tostring(IS_STUDIO), true),
	}, true)
	return ok, if ok then nil else "could not queue"
end

--- Studio: the digest this server WOULD post for today's pending counters,
--- without touching the DataStore or the lock.
function DiscordReporter.previewDigest(): { [string]: any }
	local day = pendingDays[dayKey()] or newDay()
	return digestEmbed(dayKey() .. " (preview, this server only)", day, nil)
end

-- ==========================================================
-- START
-- ==========================================================

function DiscordReporter.start()
	if started then
		return
	end
	started = true
	evaluate()
	print(`[DiscordReporter] {if enabled then "online" else "off"} ({redact(reason)})`)

	AnalyticsEvents.observe(onFact)
	AnalyticsEvents.mirror = mirrorRow

	task.spawn(function()
		while true do
			task.wait(DiscordConfig.MIRROR_FLUSH_SECONDS)
			local ok: boolean, err: any = (pcall :: any)(flushMirror)
			if not ok then
				warnOnce("mirror", `analytics mirror flush failed: {err}`)
			end
		end
	end)

	ScriptContext.Error:Connect(function(message, trace, scriptInstance)
		if not enabled then
			return
		end
		local ok: boolean, err: any = (pcall :: any)(onError, message, trace, scriptInstance)
		if not ok then
			warnOnce("errorhook", `error hook failed: {err}`)
		end
	end)

	Players.PlayerAdded:Connect(function()
		window.peak = math.max(window.peak, #Players:GetPlayers())
	end)

	task.spawn(worker)

	task.spawn(function()
		while true do
			task.wait(DiscordConfig.SUMMARY_SECONDS)
			if enabled then
				local ok: boolean, err: any = (pcall :: any)(DiscordReporter.postSummary, false)
				if not ok then
					warnOnce("summary", `summary failed: {err}`)
				end
			else
				window = newWindow()
			end
		end
	end)

	task.spawn(function()
		local sinceFlush = 0
		while true do
			task.wait(60)
			sinceFlush += 60
			if sinceFlush >= DiscordConfig.DAILY_FLUSH_SECONDS then
				sinceFlush = 0
				local ok: boolean, err: any = (pcall :: any)(DiscordReporter.flushDaily)
				if not ok then
					lastDailyError = redact(tostring(err))
				end
			end
			local ok: boolean, err: any = (pcall :: any)(maybeDigest)
			if not ok then
				lastDailyError = redact(tostring(err))
			end
		end
	end)

	game:BindToClose(function()
		-- The leaving players' SessionEnd facts land on their own threads;
		-- give them a moment, then merge today's counters one last time.
		task.wait(1)
		pcall(function()
			flushBurst(purchases, "purchase")
			flushBurst(reveals, "reveal")
		end)
		pcall(flushMirror)
		pcall(DiscordReporter.flushDaily)
		-- A few seconds for the queue (the last bursts) to go out.
		local deadline = os.clock() + 5
		while #queue > 0 and target ~= nil and os.clock() < deadline do
			task.wait(0.25)
		end
	end)
end

return DiscordReporter
