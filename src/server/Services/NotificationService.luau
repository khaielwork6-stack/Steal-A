--!strict
--[[
	NotificationService
	Roblox "experience notifications" sent from the game server through the
	Open Cloud User Notifications API:

	    POST https://apis.roblox.com/cloud/v2/users/{userId}/notifications
	    x-api-key: <HttpService:GetSecret(SocialConfig.NOTIFICATION_SECRET_NAME)>
	    {
	      "source":  { "universe": "universes/<game.GameId>" },
	      "payload": {
	        "message_id": "<notification string id from the Creator Dashboard>",
	        "type": "MOONSHOT",
	        "join_experience": { "launch_data": "notify:<kind>" },
	        "analytics_data":  { "category": "<kind>" }
	      }
	    }

	The API delivers immediately; it has NO scheduling. So a notification that
	is due later is written to a small DataStore queue when the player leaves,
	and whichever server polls the queue after the due time sends it:

	  * "SocialNotify_v1"    key u_<userId>: { pending = { [kind] = { dueAt,
	                         at } }, lastSentAt }
	  * "SocialNotifyDue_v1" (OrderedDataStore) key <kind>_<userId> = dueAt,
	                         the index a server scans with GetSortedAsync.
	  A server claims an entry with ONE UpdateAsync on the user document
	  (removes it from `pending` and stamps lastSentAt), so two servers can
	  never both send it; then it sends. At most once: a failed send after
	  retries is logged and dropped.

	TRIGGERS (scheduled on leave, cancelled when the player joins again)
	  containerReady  the earliest sealed container's HatchEndsAt, if it is at
	                  least NOTIFY_READY_MIN_DELAY away.
	  offlineFull     leave + GameConfig.OFFLINE_EARNINGS_MAX_SECONDS, if the
	                  player was earning.

	RATE LIMIT: at most one notification per user per NOTIFY_MIN_GAP_SECONDS
	(Roblox throttles per user on its side as well); entries more than
	NOTIFY_MAX_LATE_SECONDS late are dropped.

	DISABLED CLEANLY when: HttpService.HttpEnabled is false, the secret is
	missing (GetSecret errors), Studio has no DataStore, or a kind's template
	id is "". Nothing else in the game depends on this service.
	Owner setup: docs/handoff-parts/social.md.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)

local NotificationService = {}

local DOC_STORE = "SocialNotify_v1"
local DUE_STORE = "SocialNotifyDue_v1"
local SEND_ATTEMPTS = 3

local secret: any = nil
local disabledReason: string? = nil
local checked = false

local docStore: DataStore? = nil
local dueStore: OrderedDataStore? = nil

--- Recent activity for the debug command, newest last.
local recent: { string } = {}
local function log(line: string)
	table.insert(recent, line)
	if #recent > 40 then
		table.remove(recent, 1)
	end
end

-- ==========================================================
-- AVAILABILITY
-- ==========================================================

--- Why the service is off, or nil when it can send. Checked once.
function NotificationService.disabledReason(): string?
	if checked then
		return disabledReason
	end
	checked = true
	local httpOk, httpEnabled = pcall(function()
		return HttpService.HttpEnabled
	end)
	-- A property read that errors is "unknown", not "off": the request itself
	-- reports a disabled HttpService clearly enough.
	if httpOk and httpEnabled == false then
		disabledReason = "HttpService.HttpEnabled is off (Game Settings > Security > Allow HTTP Requests)"
	elseif DataService.isStudioMemoryMode() then
		disabledReason = "no DataStore in this session (Studio API access off)"
	else
		local ok, value = pcall(HttpService.GetSecret, HttpService, SocialConfig.NOTIFICATION_SECRET_NAME)
		if ok and value ~= nil then
			secret = value
		else
			disabledReason = `secret "{SocialConfig.NOTIFICATION_SECRET_NAME}" is not available ({value})`
		end
	end
	if disabledReason then
		print(`[NotificationService] disabled: {disabledReason}`)
	end
	return disabledReason
end

local function templateFor(kind: string): string
	local id = SocialConfig.NOTIFICATION_TEMPLATES[kind]
	return if type(id) == "string" then id else ""
end

--- True when `kind` can be sent at all.
function NotificationService.canSend(kind: string): boolean
	return templateFor(kind) ~= "" and NotificationService.disabledReason() == nil
end

local function anyKindEnabled(): boolean
	for kind in SocialConfig.NOTIFICATION_TEMPLATES do
		if templateFor(kind) ~= "" then
			return true
		end
	end
	return false
end

local function stores(): (DataStore?, OrderedDataStore?)
	if not docStore then
		local ok, value = pcall(DataStoreService.GetDataStore, DataStoreService, DOC_STORE)
		if ok then
			docStore = value
		end
	end
	if not dueStore then
		local ok, value = pcall(DataStoreService.GetOrderedDataStore, DataStoreService, DUE_STORE)
		if ok then
			dueStore = value
		end
	end
	return docStore, dueStore
end

-- ==========================================================
-- SENDING
-- ==========================================================

--- The exact request body for `kind`. Pure; used by the dry run too.
function NotificationService.buildPayload(kind: string): { [string]: any }
	return {
		source = { universe = `universes/{game.GameId}` },
		payload = {
			message_id = templateFor(kind),
			type = "MOONSHOT",
			join_experience = { launch_data = `notify:{kind}` },
			analytics_data = { category = kind },
		},
	}
end

function NotificationService.urlFor(userId: number): string
	return `https://apis.roblox.com/cloud/v2/users/{userId}/notifications`
end

--- One POST with retries on 429 / 5xx / transport errors. Yields.
local function send(userId: number, kind: string): (boolean, string)
	local body = HttpService:JSONEncode(NotificationService.buildPayload(kind))
	local last = "not attempted"
	for attempt = 1, SEND_ATTEMPTS do
		local ok, response = pcall(function()
			return HttpService:RequestAsync({
				Url = NotificationService.urlFor(userId),
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-api-key"] = secret,
				} :: any,
				Body = body,
			})
		end)
		if ok then
			local res = response :: any
			if res.Success then
				return true, `HTTP {res.StatusCode}`
			end
			last = `HTTP {res.StatusCode}: {string.sub(tostring(res.Body), 1, 200)}`
			-- Only throttling and server errors are worth another try.
			if res.StatusCode ~= 429 and res.StatusCode < 500 then
				return false, last
			end
		else
			last = tostring(response)
		end
		task.wait(attempt * 5)
	end
	return false, last
end

-- ==========================================================
-- THE QUEUE
-- ==========================================================

local function docKey(userId: number): string
	return `u_{userId}`
end

local function dueKey(kind: string, userId: number): string
	return `{kind}_{userId}`
end

--- Queues `kind` for `userId` at unix second `dueAt`. Yields.
function NotificationService.schedule(userId: number, kind: string, dueAt: number): boolean
	if not NotificationService.canSend(kind) then
		return false
	end
	local doc, due = stores()
	if not doc or not due then
		return false
	end
	local when = math.floor(dueAt)
	local ok, err = pcall(function()
		(doc :: DataStore):UpdateAsync(docKey(userId), function(old: any): any
			local value = if type(old) == "table" then old else {}
			value.pending = if type(value.pending) == "table" then value.pending else {}
			value.pending[kind] = { dueAt = when, at = os.time() }
			return value
		end);
		(due :: OrderedDataStore):SetAsync(dueKey(kind, userId), when)
	end)
	if not ok then
		warn(`[NotificationService] schedule {kind} for {userId} failed: {err}`)
		return false
	end
	log(`scheduled {kind} for {userId} at {when} (+{when - os.time()}s)`)
	return true
end

--- Drops everything queued for `userId` (they are back in the game).
function NotificationService.cancelAll(userId: number)
	local doc, due = stores()
	if not doc or not due then
		return
	end
	local removed: { string } = {}
	local ok, err = pcall(function()
		(doc :: DataStore):UpdateAsync(docKey(userId), function(old: any): any
			table.clear(removed)
			if type(old) ~= "table" or type(old.pending) ~= "table" or next(old.pending) == nil then
				return nil
			end
			for kind in old.pending do
				table.insert(removed, kind)
			end
			old.pending = {}
			return old
		end)
		for _, kind in removed do
			(due :: OrderedDataStore):RemoveAsync(dueKey(kind, userId))
		end
	end)
	if not ok then
		warn(`[NotificationService] cancel for {userId} failed: {err}`)
	elseif #removed > 0 then
		log(`cancelled {table.concat(removed, ",")} for {userId} (rejoined)`)
	end
end

type Claim = "send" | "drop" | "wait"

--- Claims one due entry. "send" = this server must send it now.
local function claim(userId: number, kind: string, now: number): (Claim, string)
	local doc = stores()
	local outcome: Claim = "drop"
	local why = "no pending entry"
	;(doc :: DataStore):UpdateAsync(docKey(userId), function(old: any): any
		outcome = "drop"
		why = "no pending entry"
		if type(old) ~= "table" or type(old.pending) ~= "table" then
			return nil
		end
		local entry = old.pending[kind]
		if type(entry) ~= "table" then
			return nil
		end
		local dueAt = tonumber(entry.dueAt) or 0
		if dueAt > now then
			-- Rescheduled later since the index was read.
			outcome = "wait"
			why = "not due yet"
			return nil
		end
		old.pending[kind] = nil
		local lastSent = tonumber(old.lastSentAt) or 0
		if now - dueAt > SocialConfig.NOTIFY_MAX_LATE_SECONDS then
			why = "too late"
		elseif now - lastSent < SocialConfig.NOTIFY_MIN_GAP_SECONDS then
			why = "rate limited"
		else
			outcome = "send"
			why = "claimed"
			old.lastSentAt = now
		end
		return old
	end)
	return outcome, why
end

local function processDue()
	local _, due = stores()
	if not due then
		return
	end
	local now = os.time()
	local ok, pages = pcall(function()
		return (due :: OrderedDataStore):GetSortedAsync(true, SocialConfig.NOTIFY_BATCH, 1, now)
	end)
	if not ok then
		warn(`[NotificationService] queue read failed: {pages}`)
		return
	end
	local page = (pages :: DataStorePages):GetCurrentPage()
	for _, row in page do
		local key = tostring(row.key)
		local kind, idText = string.match(key, "^(%w+)_(%d+)$")
		local userId = tonumber(idText)
		if not kind or not userId then
			pcall(due.RemoveAsync, due, key)
			continue
		end
		if Players:GetPlayerByUserId(userId) then
			-- Here right now: nothing to remind them of.
			NotificationService.cancelAll(userId)
			continue
		end
		local claimed, outcome, why = pcall(claim, userId, kind, now)
		if not claimed then
			warn(`[NotificationService] claim {key} failed: {outcome}`)
			continue
		end
		if outcome == "wait" then
			continue
		end
		-- Claimed or dropped: the index entry is done either way.
		pcall(due.RemoveAsync, due, key)
		if outcome == "send" then
			if NotificationService.canSend(kind) then
				local sent, detail = send(userId, kind)
				log(`{if sent then "sent" else "FAILED"} {kind} to {userId}: {detail}`)
			else
				log(`dropped {kind} for {userId}: template or secret missing`)
			end
		else
			log(`dropped {kind} for {userId}: {why}`)
		end
	end
end

-- ==========================================================
-- TRIGGERS
-- ==========================================================

--- What would be scheduled for this player if they left now.
function NotificationService.plannedFor(player: Player, profile: DataService.Profile?): { [string]: number }
	local plan: { [string]: number } = {}
	local now = os.time()
	local source = profile or DataService.get(player)
	if not source then
		return plan
	end
	local earliest: number? = nil
	for _, item in source.DisplayItems do
		local ends = tonumber(item.HatchEndsAt)
		if item.Hatched == false and ends and ends > now then
			earliest = if earliest then math.min(earliest, ends) else ends
		end
	end
	if earliest and earliest - now >= SocialConfig.NOTIFY_READY_MIN_DELAY then
		plan.containerReady = earliest
	end
	if EconomyService.getIncome(player) > 0 then
		plan.offlineFull = now + GameConfig.OFFLINE_EARNINGS_MAX_SECONDS
	end
	return plan
end

local function onLeaving(player: Player, profile: DataService.Profile)
	if not anyKindEnabled() then
		return
	end
	local plan = NotificationService.plannedFor(player, profile)
	local userId = player.UserId
	if next(plan) == nil then
		return
	end
	-- Off the release path: a slow DataStore must never hold the final save.
	task.spawn(function()
		for kind, dueAt in plan do
			NotificationService.schedule(userId, kind, dueAt)
		end
	end)
end

--- Studio: what a send would do, without sending.
function NotificationService.dryRun(userId: number, kind: string): { [string]: any }
	return {
		url = NotificationService.urlFor(userId),
		method = "POST",
		headers = { ["Content-Type"] = "application/json", ["x-api-key"] = `<secret {SocialConfig.NOTIFICATION_SECRET_NAME}>` },
		body = HttpService:JSONEncode(NotificationService.buildPayload(kind)),
		templateSet = templateFor(kind) ~= "",
		disabledReason = NotificationService.disabledReason(),
	}
end

function NotificationService.recentLog(): { string }
	return table.clone(recent)
end

function NotificationService.start()
	if not anyKindEnabled() then
		print("[NotificationService] no notification template ids set - notifications off")
		return
	end
	-- The leave hook is registered even if the check below fails later in
	-- the session; `schedule` re-checks.
	DataService.onBeforeRelease(onLeaving)

	task.spawn(function()
		if NotificationService.disabledReason() then
			return
		end
		local function onPlayer(player: Player)
			task.spawn(NotificationService.cancelAll, player.UserId)
		end
		for _, player in Players:GetPlayers() do
			onPlayer(player)
		end
		Players.PlayerAdded:Connect(onPlayer)

		while true do
			task.wait(SocialConfig.NOTIFY_POLL_SECONDS * (0.75 + math.random() * 0.5))
			local ok: boolean, err: any = (pcall :: any)(processDue)
			if not ok then
				warn(`[NotificationService] queue pass failed: {err}`)
			end
		end
	end)
end

return NotificationService
