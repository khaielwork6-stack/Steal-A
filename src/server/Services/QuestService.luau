--!strict
--[[
	QuestService
	Three daily and three weekly quests per player (retention pass). Tuning
	and templates live in QuestConfig; the season pass is SeasonPassService.

	PROGRESS IS AN EVENT, NOT A POLL. Every quest advances only from
	ProgressEvents fired inside the gameplay services' success paths (see the
	table at the top of ProgressEvents). No client message advances anything.

	PROFILE: `Profile.Quests`
	    Daily  = { period = <UTC day>,  list = { Entry, Entry, Entry } }
	    Weekly = { period = <UTC week>, list = { ... } }
	    Entry  = { id, target, progress, claimed }
	A bucket whose `period` is not the current one is regenerated from the
	deterministic seed (QuestConfig.generate). Unclaimed rewards of an ended
	period are dropped with it - the panel shows the reset timer.

	CLAIMS PAY ONCE. `claimed` is set BEFORE the reward, with no yield in
	between, and the profile is saved straight after. The reward is read at
	claim time (QuestConfig.rewardFor) and includes season XP.

	REPLICATION
	  * QuestPush (own remote): the whole panel, sent only when its content
	    changed, at most once per QuestConfig.PUSH_INTERVAL, and on request.
	  * StatePush `retention = { claimable }`: the HUD red dot (the
	    provider is registered by init.server from `claimableCount`).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IndexConfig = require(ReplicatedStorage.Shared.Config.IndexConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ProgressEvents = require(script.Parent.ProgressEvents)
local SeasonPassService = require(script.Parent.SeasonPassService)

local QuestService = {}

--- The injected notify / push / movement hooks (see SeasonPassService.hooks;
--- init.server fills them). The StatePush `retention` provider is registered
--- by init.server too, from QuestService.claimableCount.
local hooks = SeasonPassService.hooks

type Period = QuestConfig.Period

export type Entry = { id: string, target: number, progress: number, claimed: boolean }
export type Bucket = { period: number, list: { Entry } }

local PERIODS: { Period } = { "daily", "weekly" }
local BUCKET_KEY: { [Period]: string } = { daily = "Daily", weekly = "Weekly" }

local claimLimiter = RateLimiter.new(QuestConfig.CLAIM_PER_SECOND, QuestConfig.CLAIM_BURST)
local syncLimiter = RateLimiter.new(QuestConfig.SYNC_PER_SECOND, QuestConfig.SYNC_BURST)

--- Players whose QuestPush content may have changed.
local dirty: { [Player]: boolean } = {}
--- The JSON of what each player was last sent (without the clock).
local lastSent: { [Player]: string } = {}
--- The last loot id that counted for an escape, per player: several guards can
--- see the same carrier cross the line.
local lastEscapeLoot: { [Player]: string } = {}
--- Studio only: whole periods added to the real calendar ("force a new day").
local periodOffset: { [Player]: { [Period]: number } } = {}
--- Buckets already sanitised this session.
local checked: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

function QuestService.markDirty(player: Player)
	dirty[player] = true
end

-- ==========================================================
-- BUCKETS
-- ==========================================================

local function realPeriod(kind: Period): number
	return QuestConfig.periodOf(kind, os.time())
end

local function periodFor(player: Player, kind: Period): number
	local offsets = periodOffset[player]
	return realPeriod(kind) + (if offsets then offsets[kind] or 0 else 0)
end

local function baseIncome(player: Player): number
	return MonetizationConfig.baseIncome(EconomyService.getIncome(player), EconomyService.cashMultiplierFor(player))
end

local function contextFor(player: Player, profile: DataService.Profile): QuestConfig.Context
	local found = 0
	for _ in profile.Index do
		found += 1
	end
	return {
		highestZone = profile.HighestZoneReached,
		baseIncome = baseIncome(player),
		undiscovered = math.max(0, IndexConfig.TOTAL_ITEMS - found),
	}
end

local function sanitise(bucket: any): Bucket
	local list: { Entry } = {}
	if type(bucket.list) == "table" then
		for _, raw in bucket.list do
			if type(raw) ~= "table" or type(raw.id) ~= "string" or not QuestConfig.ById[raw.id] then
				continue
			end
			-- No upper bound: a late-game "earn" target is legitimately huge.
			local target = Validate.integer(raw.target, 1) or 1
			local progress = if Validate.finite(raw.progress) then math.clamp(raw.progress, 0, target) else 0
			table.insert(list, { id = raw.id, target = target, progress = progress, claimed = raw.claimed == true })
		end
	end
	bucket.list = list
	return bucket :: Bucket
end

--- The player's current bucket for `kind`, regenerated when its period ended.
local function bucketFor(player: Player, profile: DataService.Profile, kind: Period): Bucket
	local quests = profile.Quests
	local key = BUCKET_KEY[kind]
	local period = periodFor(player, kind)
	local raw: any = quests[key]
	if type(raw) ~= "table" or raw.period ~= period then
		local entries = QuestConfig.generate(
			QuestConfig.Pools[kind],
			QuestConfig.COUNTS[kind],
			QuestConfig.seedFor(player.UserId, kind, period),
			contextFor(player, profile)
		)
		local list: { Entry } = {}
		for _, entry in entries do
			table.insert(list, { id = entry.id, target = entry.target, progress = 0, claimed = false })
		end
		local bucket: Bucket = { period = period, list = list }
		quests[key] = bucket
		checked[bucket] = true
		dirty[player] = true
		hooks.markStateDirty(player)
		return bucket
	end
	if not checked[raw] then
		sanitise(raw)
		checked[raw] = true
	end
	return raw :: Bucket
end

-- ==========================================================
-- PROGRESS
-- ==========================================================

local function onEvent(eventKind: string, player: Player, amount: number, info: { [string]: any })
	if not QuestConfig.ENABLED then
		return
	end
	-- The shared bus passes amounts through unchecked: never let a NaN, an
	-- infinity or a negative reach a counter.
	if not Validate.finite(amount) or amount <= 0 then
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return
	end
	if eventKind == QuestConfig.EVENT_FOR_KIND.escape then
		local lootId = tostring(info.lootId)
		if lastEscapeLoot[player] == lootId then
			return
		end
		lastEscapeLoot[player] = lootId
	end

	local changed = false
	for _, kind in PERIODS do
		local bucket = bucketFor(player, profile, kind)
		for _, entry in bucket.list do
			local template = QuestConfig.ById[entry.id]
			if not template or entry.claimed or entry.progress >= entry.target then
				continue
			end
			if QuestConfig.eventFor(template) ~= eventKind or not QuestConfig.accepts(template, info) then
				continue
			end
			local before = entry.progress
			entry.progress = math.min(entry.target, before + amount)
			changed = true
			if entry.progress >= entry.target then
				hooks.notify(
					player,
					"success",
					`QUEST COMPLETE: {QuestConfig.describe(template, entry.target)}  ·  claim it in Quests!`,
					"questComplete"
				)
				hooks.markStateDirty(player)
				ProgressEvents.fire(player, "questCompleted", 1, { period = kind, questId = entry.id })
			end
		end
	end
	if changed then
		dirty[player] = true
	end
end

-- ==========================================================
-- CLAIMS
-- ==========================================================

--- Claims one finished quest. Returns false plus an optional player-facing
--- reason. Idempotent: an already-claimed quest is a silent no-op.
function QuestService.claim(player: Player, kindArg: any, indexArg: any): (boolean, string?)
	if not QuestConfig.ENABLED then
		return false
	end
	if kindArg ~= "daily" and kindArg ~= "weekly" then
		return false
	end
	local kind: Period = kindArg
	local index = Validate.integer(indexArg, 1, QuestConfig.COUNTS[kind])
	if not index then
		return false
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local entry = bucketFor(player, profile, kind).list[index]
	if not entry then
		return false
	end
	local template = QuestConfig.ById[entry.id]
	if not template or entry.claimed then
		return false
	end
	if entry.progress < entry.target then
		return false, "That quest isn't finished yet!"
	end

	-- FLAG FIRST, no yield before it.
	entry.claimed = true
	local cash, speed = QuestConfig.rewardFor(kind, template, baseIncome(player), SpinWheelConfig.nextGate(profile.HighestZoneReached))
	local ok, err = pcall(function()
		EconomyService.award(player, cash, "quest")
		if speed > 0 then
			profile.SpeedPower += speed
			hooks.refreshMovement(player)
		end
		-- An explicit result so the pcall type-checks as (ok, value).
		return true
	end)
	if not ok then
		warn(`[QuestService] reward failed for {player.Name} ({entry.id}): {err}`)
	end
	local xp = SeasonPassService.addXp(player, QuestConfig.SEASON_XP[kind], kind)

	local parts = { NumberFormat.cash(cash) }
	if speed > 0 then
		table.insert(parts, `+{NumberFormat.short(speed)} Speed`)
	end
	if xp > 0 then
		table.insert(parts, `+{xp} Season XP`)
	end
	hooks.notify(player, "success", `QUEST CLAIMED  ·  {table.concat(parts, "  ·  ")}`, "questComplete")
	ProgressEvents.fire(player, "questClaimed", 1, { period = kind, questId = entry.id })

	dirty[player] = true
	hooks.pushState(player)
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return true
end

-- ==========================================================
-- REPLICATION
-- ==========================================================

local function questRows(player: Player, profile: DataService.Profile, kind: Period): ({ any }, number)
	local rows = {}
	local claimable = 0
	local income = baseIncome(player)
	local gate = SpinWheelConfig.nextGate(profile.HighestZoneReached)
	for index, entry in bucketFor(player, profile, kind).list do
		local template = QuestConfig.ById[entry.id]
		if not template then
			continue
		end
		local complete = entry.progress >= entry.target
		if complete and not entry.claimed then
			claimable += 1
		end
		local cash, speed = QuestConfig.rewardFor(kind, template, income, gate)
		table.insert(rows, {
			index = index,
			id = entry.id,
			kind = template.kind,
			text = QuestConfig.describe(template, entry.target),
			-- Whole units for the bar: income ticks add fractions.
			progress = math.floor(entry.progress),
			target = entry.target,
			progressText = QuestConfig.formatAmount(template, entry.progress),
			targetText = QuestConfig.formatAmount(template, entry.target),
			complete = complete,
			claimed = entry.claimed,
			cash = cash,
			speed = speed,
			xp = QuestConfig.SEASON_XP[kind],
		})
	end
	return rows, claimable
end

--- Rewards waiting to be claimed, quests and season together.
function QuestService.claimableCount(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	local count = SeasonPassService.claimableCount(player)
	if QuestConfig.ENABLED then
		for _, kind in PERIODS do
			for _, entry in bucketFor(player, profile, kind).list do
				if not entry.claimed and entry.progress >= entry.target then
					count += 1
				end
			end
		end
	end
	return count
end

--- The Quests panel payload, or nil before the profile has loaded.
function QuestService.summarise(player: Player): { [string]: any }?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local payload: { [string]: any } = { enabled = QuestConfig.ENABLED }
	local claimable = 0
	if QuestConfig.ENABLED then
		for _, kind in PERIODS do
			local rows, waiting = questRows(player, profile, kind)
			claimable += waiting
			payload[kind] = { quests = rows, resetAt = QuestConfig.resetAt(kind, realPeriod(kind)) }
		end
	end
	payload.season = SeasonPassService.summarise(player)
	payload.claimable = claimable + SeasonPassService.claimableCount(player)
	return payload
end

local function flush(player: Player, force: boolean)
	local ok, err = pcall(function()
		local payload = QuestService.summarise(player)
		if not payload then
			-- Not loaded yet: keep it dirty for the next pass.
			dirty[player] = true
			return false
		end
		local signature = HttpService:JSONEncode(payload)
		if not force and lastSent[player] == signature then
			return false
		end
		lastSent[player] = signature
		-- The server clock, so the client's reset timers agree with ours.
		payload.now = os.time()
		Remotes.get("QuestPush"):FireClient(player, payload)
		return true
	end)
	if not ok then
		warn(`[QuestService] push failed for {player.Name}: {err}`)
	end
end

function QuestService.pushNow(player: Player, force: boolean?)
	dirty[player] = nil
	flush(player, force == true)
end

-- ==========================================================
-- START
-- ==========================================================

function QuestService.start()
	SeasonPassService.onChanged = function(player: Player)
		dirty[player] = true
	end

	-- One subscription per event name. The values are unique, and "reveal"
	-- (in the list for reveal quests) also serves the rarity-filtered steal
	-- quests (QuestConfig.eventFor).
	for _, eventName in QuestConfig.EVENT_FOR_KIND do
		ProgressEvents.on(eventName, function(player, amount, info)
			onEvent(eventName, player, amount, info)
		end)
	end

	Remotes.get("QuestRequest").OnServerEvent:Connect(function(player, action, a, b)
		if type(action) ~= "string" then
			return
		end
		if action == "sync" then
			if syncLimiter:consume(player) then
				QuestService.pushNow(player, true)
			end
			return
		end
		if action ~= "claim" and action ~= "season" then
			return
		end
		if not claimLimiter:consume(player) then
			hooks.notify(player, "error", "Slow down!")
			return
		end
		local ok, reason
		if action == "claim" then
			ok, reason = QuestService.claim(player, a, b)
		else
			ok, reason = SeasonPassService.claim(player, a, b)
		end
		if not ok and reason then
			hooks.notify(player, "error", reason)
		end
		QuestService.pushNow(player)
	end)

	local function onPlayer(player: Player)
		task.spawn(function()
			if not DataService.waitForProfile(player) then
				return
			end
			QuestService.pushNow(player, true)
		end)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function(player)
		dirty[player] = nil
		lastSent[player] = nil
		lastEscapeLoot[player] = nil
		periodOffset[player] = nil
		claimLimiter:release(player)
		syncLimiter:release(player)
	end)

	-- The flush, and the midnight / Monday rollover: bucketFor regenerates an
	-- ended period (and marks the player dirty) the first time it is asked.
	task.spawn(function()
		while true do
			task.wait(QuestConfig.PUSH_INTERVAL)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(function()
					local profile = DataService.get(player)
					if profile and QuestConfig.ENABLED then
						for _, kind in PERIODS do
							bucketFor(player, profile, kind)
						end
					end
				end)
				if not ok then
					warn(`[QuestService] rollover check failed for {player.Name}: {err}`)
				end
				if dirty[player] then
					QuestService.pushNow(player)
				end
			end
		end
	end)

	if QuestConfig.ENABLED then
		print(`[QuestService] {#QuestConfig.Daily} daily / {#QuestConfig.Weekly} weekly quest templates online`)
	else
		print("[QuestService] quests DISABLED (QuestConfig.ENABLED = false)")
	end
end

-- ==========================================================
-- DEBUG (DebugCommands/Quests)
-- ==========================================================

--- Sets one quest's progress to its target.
function QuestService.debugComplete(player: Player, kind: Period, index: number): boolean
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	local entry = bucketFor(player, profile, kind).list[index]
	if not entry then
		return false
	end
	entry.progress = entry.target
	dirty[player] = true
	hooks.markStateDirty(player)
	return true
end

--- Moves this player's calendar for `kind` one period on, which regenerates
--- that list now. Session only; `debugResetCalendar` undoes it.
function QuestService.debugAdvance(player: Player, kind: Period): number
	local offsets = periodOffset[player]
	if not offsets then
		offsets = {}
		periodOffset[player] = offsets
	end
	offsets[kind] = (offsets[kind] or 0) + 1
	local profile = DataService.get(player)
	if profile then
		bucketFor(player, profile, kind)
	end
	return periodFor(player, kind)
end

function QuestService.debugResetCalendar(player: Player)
	periodOffset[player] = nil
	dirty[player] = true
end

function QuestService.inspect(player: Player): { [string]: any }?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local out: { [string]: any } = { claimable = QuestService.claimableCount(player) }
	for _, kind in PERIODS do
		local bucket = bucketFor(player, profile, kind)
		local rows = {}
		for index, entry in bucket.list do
			local template = QuestConfig.ById[entry.id]
			table.insert(rows, {
				index = index,
				id = entry.id,
				text = if template then QuestConfig.describe(template, entry.target) else "?",
				progress = entry.progress,
				target = entry.target,
				claimed = entry.claimed,
			})
		end
		out[kind] = {
			period = bucket.period,
			realPeriod = realPeriod(kind),
			resetAt = QuestConfig.resetAt(kind, realPeriod(kind)),
			quests = rows,
		}
	end
	return out
end

return QuestService
