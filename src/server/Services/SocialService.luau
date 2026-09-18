--!strict
--[[
	SocialService
	Invites and referral rewards, the friend / Premium income boost, the
	one-time prompt flags, and the server-wide reveal announcement.

	REFERRALS
	  * `noteProfileLoaded` runs from init's join block BEFORE the offline
	    settle (which moves LastLeaveTimestamp). A profile whose
	    LastLeaveTimestamp is still 0 has never finished a session: that is
	    a NEW account for this game. Only then is Player:GetJoinData().
	    ReferredByPlayerId looked at, and only a different, positive UserId
	    is recorded (profile.ReferredBy, ReferralState = "pending").
	  * Every REFERRAL_TICK_SECONDS a pending referral accrues play time
	    (saved, so leaving early just resumes next session). At
	    REFERRAL_MIN_PLAY_SECONDS the inviter is paid:
	      1. ReferralState = "paid" and the invitee's profile is SAVED first -
	         at most once, whatever happens next;
	      2. one slot of the inviter's daily cap is claimed in DataStore
	         "SocialReferrals_v1" (key ref_<inviter>_<yyyymmdd>, UTC), so the
	         cap holds across every server; over the cap -> "capped";
	      3. Cash and Speed go to the inviter through MailboxService (works
	         whether they are here, in another server, or offline).
	  * Amounts: SocialConfig REFERRAL_CASH_* / REFERRAL_SPEED_*. The
	    inviter's income and furthest zone are read live when they are in
	    this server, else from their last SAVED profile (read-only GetAsync;
	    OfflineCashRate / HighestZoneReached). Unknown -> the floors.

	BOOSTS
	  Friends in this server (Player:IsFriendsWith, cached per pair, pcall)
	  and Premium (MembershipType, PlayerMembershipChanged). The multiplier
	  is injected into EconomyService.socialMultiplierFor and applied ONLY in
	  its income tick (see EconomyService "SOCIAL BOOST"). Friendships made
	  mid-session are picked up on the next join/leave in the server.

	STATE
	  StatePush field `social` (addProvider): the boost percentages for the
	  HUD pill and the two one-time prompt flags.

	ANNOUNCEMENTS
	  `onRevealCommitted` is called from HatchService's reveal cue. It waits
	  HatchConfig.swapAt(rarity) - the pop frame, when the revealer's own
	  roulette lands - and only then fires the "reveal" progress event and,
	  for ANNOUNCE_REVEAL_MIN_RARITY or better, RevealAnnounce to everyone.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HatchConfig = require(ReplicatedStorage.Shared.Config.HatchConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local MailboxService = require(script.Parent.MailboxService)
local ProgressEvents = require(script.Parent.ProgressEvents)
local StateService = require(script.Parent.StateService)

local SocialService = {}

--- DataService's store and key format, READ ONLY here (the inviter's last
--- saved income and zone). Kept in step with DataService.STORE_NAME / keyFor.
local PROFILE_STORE = "PlayerProfiles_v1"
local REFERRAL_STORE = "SocialReferrals_v1"
local SEND_ATTEMPTS = 3

local requestLimiter = RateLimiter.new(1, 3)

-- ==========================================================
-- BOOSTS
-- ==========================================================

--- "lowId:highId" -> are they friends. Friendship is symmetric.
local friendPairs: { [string]: boolean } = {}
local friendCount: { [Player]: number } = {}
local premium: { [Player]: boolean } = {}

local function pairKey(a: number, b: number): string
	return if a < b then `{a}:{b}` else `{b}:{a}`
end

local function isPremium(player: Player): boolean
	return player.MembershipType == Enum.MembershipType.Premium
end

--- Recounts every player's friends from the cache. Cheap (7 players).
local function recount()
	local players = Players:GetPlayers()
	for _, player in players do
		local count = 0
		for _, other in players do
			if other ~= player and friendPairs[pairKey(player.UserId, other.UserId)] then
				count += 1
			end
		end
		if friendCount[player] ~= count then
			friendCount[player] = count
			StateService.markDirty(player)
		end
	end
end

--- Asks Roblox about every pair involving `player` not asked yet.
local function refreshFriends(player: Player)
	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		local key = pairKey(player.UserId, other.UserId)
		if friendPairs[key] == nil then
			-- The member lookup is inside the pcall too: a missing method
			-- (an engine rename) must read as "unknown", not throw.
			local ok, result = pcall(function()
				return player:IsFriendsWithAsync(other.UserId)
			end)
			if ok then
				friendPairs[key] = result == true
			end
			-- A failed call stays unknown and is asked again on the next join.
		end
	end
	recount()
end

--- The social income multiplier (>= 1). Injected into EconomyService.
function SocialService.multiplierFor(player: Player): number
	return SocialConfig.multiplier(friendCount[player] or 0)
end

--- What the HUD pill shows, in whole percent. The Premium boost is gone
--- (SocialConfig FRIEND INCOME BOOST); `premium` stays on the row because
--- the referral and analytics paths still record whether a member is Premium,
--- but it buys nothing.
function SocialService.boosts(player: Player): { friends: number, friendBoost: number, premium: boolean, total: number }
	local friends = friendCount[player] or 0
	local friendPart = SocialConfig.multiplier(friends) - 1
	return {
		friends = friends,
		friendBoost = math.floor(friendPart * 100 + 0.5),
		premium = premium[player] == true,
		total = math.floor((SocialService.multiplierFor(player) - 1) * 100 + 0.5),
	}
end

--- STUDIO ONLY: pretend `player` has `friends` friends here / is Premium.
function SocialService.debugSetBoost(player: Player, friends: number?, isPrem: boolean?)
	if friends ~= nil then
		friendCount[player] = math.max(0, math.floor(friends))
	end
	if isPrem ~= nil then
		premium[player] = isPrem
	end
	StateService.markDirty(player)
end

--- STUDIO ONLY: back to the real answers.
function SocialService.debugResetBoost(player: Player)
	premium[player] = isPremium(player)
	friendCount[player] = nil
	recount()
	StateService.markDirty(player)
end

-- ==========================================================
-- STATE
-- ==========================================================

local function summarise(player: Player): any
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local boost = SocialService.boosts(player)
	return {
		friends = boost.friends,
		friendBoost = boost.friendBoost,
		favoritePrompted = profile.FavoritePrompted,
		notificationsPrompted = profile.NotificationsPrompted,
	}
end

-- ==========================================================
-- REFERRALS
-- ==========================================================

--- Players whose referral payout is running right now.
local paying: { [Player]: boolean } = {}
--- Studio memory mode: the daily counter, in memory.
local memoryDaily: { [string]: number } = {}
--- What the last payout did, for the debug command.
local lastPayout: { [number]: any } = {}

local function openStore(name: string): DataStore?
	local ok, store = pcall(DataStoreService.GetDataStore, DataStoreService, name)
	return if ok then store else nil
end

local function dayKey(referrerId: number): string
	return `ref_{referrerId}_{os.date("!%Y%m%d")}`
end

--- Claims one of today's paid slots for `referrerId`. true = claimed,
--- false = over the cap, nil = could not be decided (DataStore error).
local function claimDailySlot(referrerId: number, memoryOnly: boolean?): boolean?
	local key = dayKey(referrerId)
	if memoryOnly or DataService.isStudioMemoryMode() then
		local used = memoryDaily[key] or 0
		if used >= SocialConfig.REFERRAL_DAILY_CAP then
			return false
		end
		memoryDaily[key] = used + 1
		return true
	end
	local store = openStore(REFERRAL_STORE)
	if not store then
		return nil
	end
	for attempt = 1, SEND_ATTEMPTS do
		local allowed = false
		local ok = pcall(function()
			(store :: DataStore):UpdateAsync(key, function(old: any): any
				local used = tonumber(old) or 0
				if used >= SocialConfig.REFERRAL_DAILY_CAP then
					allowed = false
					return nil
				end
				allowed = true
				return used + 1
			end)
		end)
		if ok then
			return allowed
		end
		task.wait(attempt * 2)
	end
	return nil
end

--- The inviter's base income ($/s, no pass / boosts) and furthest zone.
local function referrerContext(referrerId: number): (number, number, string)
	local live = Players:GetPlayerByUserId(referrerId)
	local liveProfile = if live then DataService.get(live) else nil
	if live and liveProfile then
		local base = MonetizationConfig.baseIncome(EconomyService.getIncome(live), EconomyService.cashMultiplierFor(live))
		return base, liveProfile.HighestZoneReached, "live"
	end
	if DataService.isStudioMemoryMode() then
		return 0, 1, "floors (memory mode)"
	end
	local store = openStore(PROFILE_STORE)
	if not store then
		return 0, 1, "floors (no store)"
	end
	local ok, doc = pcall(function()
		return (store :: DataStore):GetAsync("player_" .. referrerId)
	end)
	if ok and type(doc) == "table" then
		-- The saved rate carries the 2x pass if they own it; it is not known
		-- here, so it is taken as-is (at most a 2x difference, still capped).
		local rate = tonumber(doc.OfflineCashRate) or 0
		local zone = math.clamp(math.floor(tonumber(doc.HighestZoneReached) or 1), 1, 12)
		return MonetizationConfig.baseIncome(rate, 1), zone, "saved profile"
	end
	return 0, 1, "floors (no saved profile)"
end

--- What an invite pays `referrerId`: Cash, Speed and where the basis came from.
function SocialService.referralReward(referrerId: number): (number, number, string)
	local base, zone, basis = referrerContext(referrerId)
	local cash = base * SocialConfig.REFERRAL_CASH_MINUTES * 60
	if cash ~= cash or cash == math.huge then
		cash = 0
	end
	cash = math.clamp(cash, SocialConfig.REFERRAL_CASH_FLOOR, SocialConfig.REFERRAL_CASH_MAX)
	local speed = SpinWheelConfig.nextGate(zone) * SocialConfig.REFERRAL_SPEED_GATE_FRACTION
	speed = math.clamp(speed, SocialConfig.REFERRAL_SPEED_FLOOR, SocialConfig.REFERRAL_SPEED_MAX)
	return math.floor(cash), math.floor(speed), basis
end

local function sendWithRetry(userId: number, entry: MailboxService.MailEntry): boolean
	for attempt = 1, SEND_ATTEMPTS do
		if MailboxService.send(userId, entry) then
			return true
		end
		task.wait(attempt * 3)
	end
	return false
end

export type PayOptions = {
	--- Compute and claim nothing real: no save, no DataStore counter, no mail.
	dryRun: boolean?,
}

--- Pays the inviter of `player` once, if their referral is pending and has
--- accrued enough play. Yields. Returns what happened.
function SocialService.payReferral(player: Player, options: PayOptions?): { [string]: any }
	local dryRun = options ~= nil and options.dryRun == true
	local profile = DataService.get(player)
	if not profile then
		return { outcome = "no profile" }
	end
	if profile.ReferralState ~= "pending" or profile.ReferredBy <= 0 then
		return { outcome = "not pending", state = profile.ReferralState }
	end
	if paying[player] then
		return { outcome = "already paying" }
	end
	paying[player] = true
	local referrerId = profile.ReferredBy
	local result: { [string]: any } = { referrerId = referrerId, dryRun = dryRun }

	local ok: boolean, err: any = (pcall :: any)(function()
		if not dryRun then
			-- AT MOST ONCE: the record is durable before anything is paid.
			profile.ReferralState = "paid"
			local durable = not DataService.isPersistent() or DataService.save(player)
			if not durable then
				profile.ReferralState = "pending"
				result.outcome = "save failed, will retry"
				return
			end
		end

		local allowed = claimDailySlot(referrerId, dryRun)
		result.slotClaimed = allowed
		if allowed ~= true then
			result.outcome = if allowed == false then "capped" else "cap check failed"
			if not dryRun then
				profile.ReferralState = if allowed == false then "capped" else "failed"
			end
			return
		end

		local cash, speed, basis = SocialService.referralReward(referrerId)
		result.cash = cash
		result.speed = speed
		result.basis = basis
		if dryRun then
			result.outcome = "dry run"
			return
		end
		local note = `{player.DisplayName} joined through your invite!`
		local cashSent = sendWithRetry(referrerId, { kind = "cash", amount = cash, source = "referral", note = note })
		local speedSent = sendWithRetry(referrerId, { kind = "speed", amount = speed, source = "referral", note = note })
		result.cashSent = cashSent
		result.speedSent = speedSent
		if not cashSent and not speedSent then
			profile.ReferralState = "failed"
			result.outcome = "mailbox refused"
		else
			result.outcome = "paid"
		end
		print(`[SocialService] referral: {player.Name} -> inviter {referrerId}: ${cash}, {speed} Speed ({basis}) {result.outcome}`)
	end)
	paying[player] = nil
	if not ok then
		warn(`[SocialService] referral payout for {player.Name} failed: {err}`)
		result.outcome = "error"
		result.error = tostring(err)
	end
	lastPayout[player.UserId] = result
	return result
end

--- Records a referral for a NEW account. Called from init's join block
--- right after the profile loads and BEFORE OfflineService.settle. Never
--- yields. `referrerOverride` is for the Studio test only.
function SocialService.noteProfileLoaded(player: Player, referrerOverride: number?)
	local profile = DataService.get(player)
	if not profile then
		return
	end
	-- Never finished a session in this game = a brand-new account.
	local isNew = profile.LastLeaveTimestamp == 0 and profile.ReferralState == ""
	if not isNew then
		return
	end
	local referrerId = referrerOverride
	if referrerId == nil then
		local ok, joinData = pcall(player.GetJoinData, player)
		if ok and type(joinData) == "table" then
			referrerId = tonumber((joinData :: any).ReferredByPlayerId)
		end
	end
	if referrerId == nil or referrerId ~= referrerId or referrerId <= 0 or referrerId % 1 ~= 0 then
		return
	end
	if referrerId == player.UserId then
		return
	end
	profile.ReferredBy = referrerId
	profile.ReferralState = "pending"
	profile.ReferralPlaySeconds = 0
	local inviter = Players:GetPlayerByUserId(referrerId)
	if inviter then
		StateService.notify(player, "success", `Welcome! {inviter.DisplayName} invited you.`)
		StateService.notify(inviter, "success", `{player.DisplayName} joined from your invite! Your reward arrives once they've played a few minutes.`)
	end
end

--- Studio: the last payout result for `player`.
function SocialService.lastPayout(player: Player): any
	return lastPayout[player.UserId]
end

local function referralTick()
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if not profile or profile.ReferralState ~= "pending" then
			continue
		end
		profile.ReferralPlaySeconds += SocialConfig.REFERRAL_TICK_SECONDS
		if profile.ReferralPlaySeconds >= SocialConfig.REFERRAL_MIN_PLAY_SECONDS and not paying[player] then
			task.spawn(SocialService.payReferral, player)
		end
	end
end

-- ==========================================================
-- ANNOUNCEMENTS
-- ==========================================================

--- Fires RevealAnnounce to every client. Display data only.
function SocialService.announceReveal(userId: number, displayName: string, itemId: string, rarity: string, mutation: string?)
	local def = LootConfig.ById[itemId]
	Remotes.get("RevealAnnounce"):FireAllClients({
		userId = userId,
		name = displayName,
		itemName = if def then def.name else itemId,
		rarity = rarity,
		mutation = RarityConfig.normaliseMutation(mutation),
	})
end

--- Called from the reveal cue (HatchService.onHatched, i.e. right after the
--- commit). Everything here waits for the SWAP so nothing is spoiled.
function SocialService.onRevealCommitted(player: Player, item: DataService.DisplayItem)
	local rarity = item.Rarity
	local itemId = item.ItemId
	local mutation = item.Mutation
	local userId = player.UserId
	local displayName = player.DisplayName
	task.delay(HatchConfig.swapAt(rarity), function()
		if player.Parent then
			ProgressEvents.fire(player, "reveal", 1, { rarity = rarity, itemId = itemId, mutation = mutation })
		end
		if RarityConfig.rank(rarity) >= RarityConfig.rank(SocialConfig.ANNOUNCE_REVEAL_MIN_RARITY) then
			SocialService.announceReveal(userId, displayName, itemId, rarity, mutation)
		end
	end)
end

-- ==========================================================
-- REQUESTS
-- ==========================================================

local function onRequest(player: Player, action: any, which: any)
	if not requestLimiter:consume(player) then
		return
	end
	if action ~= "prompted" or type(which) ~= "string" then
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return
	end
	-- Only ever sets a flag to true; there is nothing to gain by sending it.
	if which == "favorite" then
		profile.FavoritePrompted = true
	elseif which == "notifications" then
		profile.NotificationsPrompted = true
	else
		return
	end
	StateService.markDirty(player)
end

-- ==========================================================
-- START
-- ==========================================================

function SocialService.start()
	StateService.addProvider("social", summarise)
	Remotes.get("SocialRequest").OnServerEvent:Connect(onRequest)

	local function onPlayer(player: Player)
		premium[player] = isPremium(player)
		task.spawn(refreshFriends, player)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function(player)
		friendCount[player] = nil
		premium[player] = nil
		paying[player] = nil
		requestLimiter:release(player)
		-- Pair entries for the leaver are kept: a rejoin reuses them. They are
		-- tiny and bounded by the number of distinct pairs this server saw.
		task.defer(recount)
	end)
	Players.PlayerMembershipChanged:Connect(function(player)
		local now = isPremium(player)
		if premium[player] ~= now then
			premium[player] = now
			StateService.markDirty(player)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(SocialConfig.REFERRAL_TICK_SECONDS)
			local ok: boolean, err: any = (pcall :: any)(referralTick)
			if not ok then
				warn(`[SocialService] referral tick failed: {err}`)
			end
		end
	end)
end

return SocialService
