--!strict
--[[
	BadgeAwardService
	Awards Roblox badges by KEY (BadgeConfig), once, safely.

	    BadgeAwardService.award(player, key) -> boolean   -- queued, never yields

	HOW
	  * An id of 0 (badge not created yet) is skipped: returns false and does
	    nothing else. The whole game runs with every id at 0.
	  * Each player's owned badges are cached for the session, so a repeated
	    trigger (every steal checks the steal milestones) costs nothing.
	  * The actual Roblox calls run on ONE worker thread, spaced out, under
	    pcall: UserHasBadgeAsync first (never re-award), then AwardBadge. A
	    failed call is retried with backoff up to MAX_ATTEMPTS; a player who
	    left is dropped from the queue.
	  * A badge that Roblox reports as disabled (GetBadgeInfoAsync) is
	    remembered and skipped.

	WHAT AWARDS BADGES
	  ProgressEvents (steal / escape / reveal / heist / streak), plus a
	  catch-up pass on join from the saved profile (first steal, steal
	  milestones, zones reached, Index sets), so a player who earned a badge
	  before it was created gets it the next time they join.

	REVEAL BADGES ARE NOT A SPOILER. The "reveal" event is fired at the swap
	moment (see init.server.luau), after the roulette has landed, so the
	Roblox badge toast can never name a rarity before the reveal does.
]]

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BadgeConfig = require(ReplicatedStorage.Shared.Config.BadgeConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local DataService = require(script.Parent.DataService)
local IndexService = require(script.Parent.IndexService)
local ProgressEvents = require(script.Parent.ProgressEvents)

local BadgeAwardService = {}

local MAX_ATTEMPTS = 5
--- Seconds between two Roblox badge calls from this server.
local CALL_SPACING = 0.25

type Job = { player: Player, key: string, id: number, attempts: number, notBefore: number }

--- userId -> badge id -> true once owned (checked or awarded).
local owned: { [number]: { [number]: boolean } } = {}
--- "userId:id" currently queued, so a burst of triggers queues it once.
local queued: { [string]: boolean } = {}
--- Badge ids Roblox reports as disabled.
local disabled: { [number]: boolean } = {}
local checkedInfo: { [number]: boolean } = {}
local queue: { Job } = {}
local wake = Instance.new("BindableEvent")

--- A log of what the service did, newest last, for the debug command.
local recent: { string } = {}
local function log(line: string)
	table.insert(recent, line)
	if #recent > 30 then
		table.remove(recent, 1)
	end
end

local function ownedSet(userId: number): { [number]: boolean }
	local set = owned[userId]
	if not set then
		set = {}
		owned[userId] = set
	end
	return set
end

--- Queues `key` for `player`. false when there is nothing to do (id 0,
--- already owned, already queued, unknown key).
function BadgeAwardService.award(player: Player, key: string): boolean
	local def = BadgeConfig.ByKey[key]
	if not def then
		warn(`[BadgeAwardService] unknown badge key "{key}"`)
		return false
	end
	local id = def.id
	if id == 0 then
		-- Not created yet: the normal state until the owner pastes ids.
		return false
	end
	if disabled[id] or ownedSet(player.UserId)[id] then
		return false
	end
	local tag = `{player.UserId}:{id}`
	if queued[tag] then
		return false
	end
	queued[tag] = true
	table.insert(queue, { player = player, key = key, id = id, attempts = 0, notBefore = 0 })
	wake:Fire()
	return true
end

--- True when the session cache knows `player` owns `key`.
function BadgeAwardService.knownOwned(player: Player, key: string): boolean
	local id = BadgeConfig.idFor(key)
	return id ~= 0 and ownedSet(player.UserId)[id] == true
end

function BadgeAwardService.recentLog(): { string }
	return table.clone(recent)
end

--- One Roblox round trip for one job. Returns "done" or "retry".
local function process(job: Job): "done" | "retry"
	local player = job.player
	if not player.Parent then
		return "done"
	end
	local userId = player.UserId
	local set = ownedSet(userId)
	if set[job.id] then
		return "done"
	end

	if not checkedInfo[job.id] then
		local ok, info = pcall(BadgeService.GetBadgeInfoAsync, BadgeService, job.id)
		if ok and type(info) == "table" then
			checkedInfo[job.id] = true
			if info.IsEnabled == false then
				disabled[job.id] = true
				log(`{job.key} ({job.id}) is disabled on Roblox - skipped`)
				return "done"
			end
		end
		-- A failed info call is not fatal: AwardBadge below reports the same.
	end

	local hasOk, has = pcall(BadgeService.UserHasBadgeAsync, BadgeService, userId, job.id)
	if not hasOk then
		return "retry"
	end
	if has then
		set[job.id] = true
		return "done"
	end

	local awardOk, awarded = pcall(BadgeService.AwardBadge, BadgeService, userId, job.id)
	if not awardOk then
		log(`{job.key} for {player.Name} failed: {awarded}`)
		return "retry"
	end
	if awarded then
		set[job.id] = true
		log(`{job.key} awarded to {player.Name}`)
	else
		-- false = Roblox refused (not awardable). Retrying would not help.
		log(`{job.key} for {player.Name}: AwardBadge returned false`)
	end
	return "done"
end

local function worker()
	while true do
		if #queue == 0 then
			wake.Event:Wait()
			continue
		end
		local now = os.clock()
		local index: number? = nil
		for i, job in queue do
			if job.notBefore <= now then
				index = i
				break
			end
		end
		if not index then
			task.wait(1)
			continue
		end
		local job = table.remove(queue, index) :: Job
		local ok, result = pcall(process, job)
		local outcome = if ok then result else "retry"
		if not ok then
			warn(`[BadgeAwardService] {job.key}: {result}`)
		end
		if outcome == "retry" and job.attempts + 1 < MAX_ATTEMPTS and job.player.Parent then
			job.attempts += 1
			job.notBefore = os.clock() + 2 ^ job.attempts
			table.insert(queue, job)
		else
			queued[`{job.player.UserId}:{job.id}`] = nil
		end
		task.wait(CALL_SPACING)
	end
end

-- ==========================================================
-- WHAT EARNS WHAT
-- ==========================================================

local function checkSteals(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return
	end
	local steals = tonumber(profile.Lifetime.Steals) or 0
	if steals >= 1 then
		BadgeAwardService.award(player, "FirstSteal")
	end
	for _, milestone in BadgeConfig.STEAL_MILESTONES do
		if steals >= milestone.count then
			BadgeAwardService.award(player, milestone.key)
		end
	end
end

local function checkZones(player: Player, zone: number?)
	local profile = DataService.get(player)
	local highest = if profile then profile.HighestZoneReached else 1
	local top = math.clamp(math.max(tonumber(zone) or 0, tonumber(highest) or 1), 1, ZoneConfig.COUNT)
	-- Every zone up to the furthest one: the lane is walked in order, so
	-- reaching Zone 7 means Zones 1-6 were crossed.
	for index = 1, top do
		BadgeAwardService.award(player, BadgeConfig.zoneKey(index))
	end
end

local function checkIndex(player: Player)
	local summary = IndexService.summarise(player)
	if not summary then
		return
	end
	for _, zone in summary.zones do
		if zone.complete then
			BadgeAwardService.award(player, "IndexZoneComplete")
			break
		end
	end
	if summary.allComplete then
		BadgeAwardService.award(player, "IndexComplete")
	end
end

local function streakDays(amount: number, info: { [string]: any }): number
	return math.max(tonumber(info.streak) or 0, tonumber(info.days) or 0, tonumber(amount) or 0)
end

--- The catch-up pass: everything derivable from the saved profile.
function BadgeAwardService.evaluate(player: Player)
	checkSteals(player)
	checkZones(player, nil)
	checkIndex(player)
end

function BadgeAwardService.start()
	task.spawn(worker)

	ProgressEvents.on("steal", function(player, _amount, info)
		checkSteals(player)
		checkZones(player, tonumber(info.zone))
	end)
	ProgressEvents.on("escape", function(player)
		BadgeAwardService.award(player, "FirstEscape")
	end)
	ProgressEvents.on("reveal", function(player, _amount, info)
		BadgeAwardService.award(player, "FirstReveal")
		local rank = RarityConfig.rank(if type(info.rarity) == "string" then info.rarity else nil)
		if rank >= RarityConfig.rank("Mythic") then
			BadgeAwardService.award(player, "FirstMythicReveal")
		end
		if rank >= RarityConfig.rank("Secret") then
			BadgeAwardService.award(player, "FirstSecretReveal")
		end
		checkIndex(player)
	end)
	ProgressEvents.on("heist", function(player)
		BadgeAwardService.award(player, "FirstHeist")
		checkIndex(player)
	end)
	-- The daily streak belongs to another feature; either kind name works.
	for _, kind in { "streak", "dailyStreak" } do
		ProgressEvents.on(kind, function(player, amount, info)
			if streakDays(amount, info) >= BadgeConfig.STREAK_DAYS then
				BadgeAwardService.award(player, "Streak7")
			end
		end)
	end

	local function onPlayer(player: Player)
		task.spawn(function()
			if DataService.waitForProfile(player) then
				BadgeAwardService.evaluate(player)
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function(player)
		owned[player.UserId] = nil
	end)
end

return BadgeAwardService
