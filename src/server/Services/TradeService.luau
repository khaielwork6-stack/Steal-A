--!strict
--[[
	TradeService
	Player-to-player trading between two players in THIS server
	(trading-gifting-boards pass). The rules of the swap itself are
	TradeLogic's; this file owns requests, the trade window, the handshake,
	saving and the moderation log.

	THE FLOW
	  1. A asks B (TradeRequest "request"). B sees a popup for
	     TradeConfig.REQUEST_TIMEOUT seconds and accepts, declines or blocks
	     A for the rest of the session. If B had already asked A, A's request
	     simply opens the window.
	  2. The window. Each side adds up to MAX_ITEMS stored, revealed items and
	     some Cash. EVERY change to either offer un-readies both sides and
	     cancels any countdown.
	  3. Both press READY -> a COUNTDOWN_SECONDS countdown -> CONFIRM unlocks
	     -> both press CONFIRM.
	  4. The server re-validates everything (both still here, not carrying,
	     policy, every item still stored and revealed, storage room, Cash)
	     and swaps the offers in memory in ONE step (TradeLogic.execute).
	     Then it saves both profiles and writes the moderation log.

	WHO MAY TRADE (`availability`)
	  * Profile loaded; PolicyService says IsPaidItemTradingAllowed (anything
	    bought with Robux can end up in an offer, so where paid-item trading
	    is not allowed, trading is off entirely - and unknown = not allowed);
	  * TradeConfig.JOIN_GRACE_SECONDS after joining;
	  * not carrying loot (checked again every half second while the window
	    is open, and at the swap);
	  * fewer than TRADES_PER_WINDOW completed trades in the window.
	  Night does not matter. Why a player cannot trade rides StatePush as
	  `trade` so the Trade panel can say it.

	SAVING
	The swap is in memory and atomic; the two saves that follow run in
	parallel. There is no cross-key transaction in DataStores, so a server
	crash in the second or so between the swap and both saves landing can
	lose (never duplicate across servers - the session lock prevents that)
	one side's half. The log is written either way, so moderation can put it
	right.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TradeConfig = require(ReplicatedStorage.Shared.Config.TradeConfig)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local MonetizationService = require(script.Parent.MonetizationService)
local StateService = require(script.Parent.StateService)
local TradeLogic = require(script.Parent.TradeLogic)

local TradeService = {}

-- ==========================================================
-- STATE
-- ==========================================================

type Side = {
	player: Player,
	offer: TradeLogic.Offer,
	ready: boolean,
	confirmed: boolean,
}

type Session = {
	id: string,
	a: Side,
	b: Side,
	--- Server time (GetServerTimeNow) CONFIRM unlocks; nil = not both ready.
	countdownEndsAt: number?,
	--- os.clock of the last change, for the idle timeout.
	lastActivity: number,
	version: number,
	executing: boolean,
	closed: boolean,
}

type Request = {
	from: Player,
	--- Server time the request lapses (what the popup counts down to).
	expiresAt: number,
}

local sessions: { [Player]: Session } = {}
--- target -> requester -> request
local requests: { [Player]: { [Player]: Request } } = {}
--- asker -> asked userId -> os.clock of the last ask (or decline)
local lastAsked: { [Player]: { [number]: number } } = {}
--- player -> userIds whose requests they blocked this session
local blocked: { [Player]: { [number]: boolean } } = {}
local joinedAt: { [Player]: number } = {}
--- player -> os.clock of each completed trade inside the window
local completedAt: { [Player]: { number } } = {}

local limiter = RateLimiter.new(TradeConfig.REMOTE_PER_SECOND, TradeConfig.REMOTE_BURST)

--- Studio memory mode (and a DataStore outage) keeps the last few logs here
--- so the debug command can show them.
local recentLogs: { any } = {}
local logStore: DataStore? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function notify(player: Player, kind: string, message: string)
	if player.Parent then
		StateService.notify(player, kind, message)
	end
end

local function send(player: Player, kind: string, payload: any)
	if player.Parent then
		Remotes.get("TradeUpdate"):FireClient(player, kind, payload)
	end
end

-- ==========================================================
-- AVAILABILITY
-- ==========================================================

--- Overridable by tests. Carrying loot blocks trading.
--- True while `instanceId` sits in `player`'s side of an open trade. Other
--- systems that consume stored items (fusion) must refuse it until the
--- trade closes, or the swap would find the item gone.
function TradeService.isOffered(player: Player, instanceId: string): boolean
	local session = sessions[player]
	if not session or session.closed then
		return false
	end
	local side = if session.a.player == player then session.a else session.b
	return table.find(side.offer.items, instanceId) ~= nil
end

function TradeService.isCarrying(player: Player): boolean
	return CarryService.getCarried(player) ~= nil
end

local function recentTrades(player: Player): number
	local list = completedAt[player]
	if not list then
		return 0
	end
	local cutoff = os.clock() - TradeConfig.TRADE_WINDOW_SECONDS
	while list[1] and list[1] < cutoff do
		table.remove(list, 1)
	end
	return #list
end

--- Whether `player` may trade right now: (ok, reason, readyAt). `readyAt` is
--- the server time the join grace ends, when that is the only reason.
function TradeService.availability(player: Player): (boolean, string?, number?)
	if not DataService.get(player) then
		return false, "Your data is still loading.", nil
	end
	local policy = MonetizationService.policy(player)
	if not policy.known then
		return false, "Checking whether trading is available for your account...", nil
	end
	if not policy.paidItemTradingAllowed then
		return false, "Trading isn't available for your account in your region.", nil
	end
	local joined = joinedAt[player] or 0
	local waited = os.clock() - joined
	if waited < TradeConfig.JOIN_GRACE_SECONDS then
		local left = TradeConfig.JOIN_GRACE_SECONDS - waited
		return false, `You can trade {math.ceil(left)}s after joining.`, now() + left
	end
	if TradeService.isCarrying(player) then
		return false, "You can't trade while carrying loot.", nil
	end
	if recentTrades(player) >= TradeConfig.TRADES_PER_WINDOW then
		return false, "You've made a lot of trades - try again in a few minutes.", nil
	end
	return true, nil, nil
end

--- What the Trade panel needs, on StatePush as `trade`.
function TradeService.summarise(player: Player): { [string]: any }
	local ok, reason, readyAt = TradeService.availability(player)
	return {
		allowed = ok,
		reason = reason,
		readyAt = readyAt,
		inTrade = sessions[player] ~= nil,
	}
end

-- ==========================================================
-- THE WINDOW
-- ==========================================================

local function sideOf(session: Session, player: Player): (Side, Side)
	if session.a.player == player then
		return session.a, session.b
	end
	return session.b, session.a
end

local function phaseOf(session: Session): string
	local ends = session.countdownEndsAt
	if not ends then
		return "offer"
	end
	return if now() < ends then "countdown" else "confirm"
end

local function sideView(side: Side): { [string]: any }
	local profile = DataService.get(side.player)
	local items = {}
	if profile then
		for _, id in side.offer.items do
			local item = TradeLogic.findStored(profile, id)
			if item then
				table.insert(items, TradeLogic.view(item))
			end
		end
	end
	return {
		userId = side.player.UserId,
		name = side.player.DisplayName,
		items = items,
		cash = side.offer.cash,
		ready = side.ready,
		confirmed = side.confirmed,
	}
end

local function viewFor(session: Session, viewer: Player): { [string]: any }
	local mine, theirs = sideOf(session, viewer)
	local warning: string? = nil
	local myProfile = DataService.get(mine.player)
	local theirProfile = DataService.get(theirs.player)
	if myProfile and theirProfile then
		local gives = TradeLogic.offerIncome(myProfile, mine.offer)
		local gets = TradeLogic.offerIncome(theirProfile, theirs.offer)
		if TradeLogic.lopsided(gives, gets) then
			warning = `You're giving {NumberFormat.income(gives)} of income for {NumberFormat.income(gets)}. Check before you confirm!`
		end
	end
	return {
		id = session.id,
		version = session.version,
		phase = phaseOf(session),
		countdownEndsAt = session.countdownEndsAt,
		maxItems = TradeConfig.MAX_ITEMS,
		you = sideView(mine),
		them = sideView(theirs),
		warning = warning,
	}
end

local function pushSession(session: Session)
	if session.closed then
		return
	end
	send(session.a.player, "session", viewFor(session, session.a.player))
	send(session.b.player, "session", viewFor(session, session.b.player))
end

--- Any change to either offer: both sides must look again.
local function resetHandshake(session: Session)
	session.a.ready = false
	session.b.ready = false
	session.a.confirmed = false
	session.b.confirmed = false
	session.countdownEndsAt = nil
	session.version += 1
	session.lastActivity = os.clock()
end

local function closeSession(session: Session, reason: string, completed: boolean)
	if session.closed then
		return
	end
	session.closed = true
	for _, side in { session.a, session.b } do
		if sessions[side.player] == session then
			sessions[side.player] = nil
		end
		send(side.player, "closed", { reason = reason, completed = completed })
		StateService.markDirty(side.player)
	end
end

--- Drops a request and tells the target's popup it is gone.
local function dropRequest(target: Player, from: Player)
	local list = requests[target]
	if list and list[from] then
		list[from] = nil
		send(target, "requestGone", { fromUserId = from.UserId })
	end
end

--- Every request `player` has sent to anyone.
local function dropRequestsFrom(player: Player)
	for target, list in requests do
		if list[player] then
			dropRequest(target, player)
		end
	end
end

local function openSession(a: Player, b: Player)
	dropRequestsFrom(a)
	dropRequestsFrom(b)
	dropRequest(a, b)
	dropRequest(b, a)
	local session: Session = {
		id = HttpService:GenerateGUID(false),
		a = { player = a, offer = TradeLogic.emptyOffer(), ready = false, confirmed = false },
		b = { player = b, offer = TradeLogic.emptyOffer(), ready = false, confirmed = false },
		countdownEndsAt = nil,
		lastActivity = os.clock(),
		version = 0,
		executing = false,
		closed = false,
	}
	sessions[a] = session
	sessions[b] = session
	StateService.markDirty(a)
	StateService.markDirty(b)
	pushSession(session)
end

-- ==========================================================
-- REQUESTS
-- ==========================================================

function TradeService.request(from: Player, target: Player): (boolean, string?)
	if target == from then
		return false, "You can't trade with yourself."
	end
	local ok, reason = TradeService.availability(from)
	if not ok then
		return false, reason
	end
	if sessions[from] then
		return false, "Finish your current trade first."
	end
	local name = target.DisplayName
	if sessions[target] then
		return false, `{name} is already trading.`
	end
	if not TradeService.availability(target) then
		return false, `{name} can't trade right now.`
	end
	local theirBlocks = blocked[target]
	if theirBlocks and theirBlocks[from.UserId] then
		return false, `{name} isn't taking trade requests from you.`
	end

	-- They already asked us: asking back IS accepting.
	local mine = requests[from]
	if mine and mine[target] then
		openSession(target, from)
		return true, nil
	end

	local incoming = requests[target]
	if incoming and incoming[from] then
		return false, "Request already sent."
	end
	local asked = lastAsked[from]
	local last = asked and asked[target.UserId]
	if last and os.clock() - last < TradeConfig.REQUEST_COOLDOWN then
		return false, `Wait a moment before asking {name} again.`
	end
	local pending = 0
	if incoming then
		for _ in incoming do
			pending += 1
		end
	end
	if pending >= TradeConfig.MAX_PENDING_PER_TARGET then
		return false, `{name} has too many trade requests right now.`
	end

	local request: Request = { from = from, expiresAt = now() + TradeConfig.REQUEST_TIMEOUT }
	local list = requests[target] or {}
	requests[target] = list
	list[from] = request
	lastAsked[from] = asked or {}
	lastAsked[from][target.UserId] = os.clock()

	send(target, "request", { fromUserId = from.UserId, fromName = from.DisplayName, expiresAt = request.expiresAt })
	notify(target, "info", `{from.DisplayName} wants to trade with you!`)
	notify(from, "info", `Trade request sent to {name}.`)

	task.delay(TradeConfig.REQUEST_TIMEOUT, function()
		local still = requests[target]
		if still and still[from] == request then
			dropRequest(target, from)
			notify(from, "info", `{name} didn't answer your trade request.`)
		end
	end)
	return true, nil
end

function TradeService.respond(target: Player, from: Player, answer: string): (boolean, string?)
	local list = requests[target]
	local request = list and list[from]
	if not request then
		send(target, "requestGone", { fromUserId = from.UserId })
		return false, "That request has expired."
	end
	dropRequest(target, from)
	-- A decline also starts the requester's cooldown, so a refused player
	-- cannot re-ask instantly.
	local asked = lastAsked[from] or {}
	lastAsked[from] = asked
	asked[target.UserId] = os.clock()

	if answer == "decline" or answer == "block" then
		if answer == "block" then
			local mine = blocked[target] or {}
			blocked[target] = mine
			mine[from.UserId] = true
			notify(target, "info", `You won't get trade requests from {from.DisplayName} again this session.`)
		end
		-- The requester is never told about the block, only that it was a no.
		notify(from, "info", `{target.DisplayName} declined your trade.`)
		return true, nil
	end

	-- Accept: everything is checked again, both sides.
	if sessions[target] then
		return false, "Finish your current trade first."
	end
	if sessions[from] then
		return false, `{from.DisplayName} is already trading.`
	end
	local ok, reason = TradeService.availability(target)
	if not ok then
		return false, reason
	end
	if not TradeService.availability(from) then
		return false, `{from.DisplayName} can't trade right now.`
	end
	openSession(from, target)
	return true, nil
end

-- ==========================================================
-- OFFERS AND THE HANDSHAKE
-- ==========================================================

local function writeLog(record: { [string]: any })
	table.insert(recentLogs, record)
	while #recentLogs > 20 do
		table.remove(recentLogs, 1)
	end
	local target = logStore
	if not target then
		print(`[TradeService] trade {record.Id} logged in memory only (no DataStore)`)
		return
	end
	local key = `t_{record.At}_{record.Id}`
	local userIds = { record.A.UserId, record.B.UserId }
	local written = false
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			-- The user ids tag the entry for Roblox's right-to-erasure tooling.
			target:SetAsync(key, record, userIds)
		end)
		if ok then
			written = true
			break
		end
		warn(`[TradeService] trade log write {attempt}/3 failed: {err}`)
		task.wait(attempt * 2)
	end
	if not written then
		warn(`[TradeService] trade log LOST for {key}: {HttpService:JSONEncode(record)}`)
		return
	end
	-- Per-user index, newest last, so moderation can find a user's trades.
	for _, userId in userIds do
		pcall(function()
			target:UpdateAsync(`u_{userId}`, function(list: any): any
				local ids = if type(list) == "table" then list else {}
				table.insert(ids, key)
				while #ids > TradeConfig.TRADE_LOG_PER_USER do
					table.remove(ids, 1)
				end
				return ids
			end)
		end)
	end
end

local function saveBoth(a: Player, b: Player): (boolean, boolean)
	if not DataService.isPersistent() then
		return true, true
	end
	local results: { [Player]: boolean } = {}
	local remaining = 2
	for _, player in { a, b } do
		task.spawn(function()
			local ok, saved = pcall(DataService.save, player)
			results[player] = ok and saved == true
			remaining -= 1
		end)
	end
	local deadline = os.clock() + 30
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
	return results[a] == true, results[b] == true
end

local function finalize(session: Session)
	if session.executing or session.closed then
		return
	end
	session.executing = true
	local a, b = session.a.player, session.b.player
	local profileA = DataService.get(a)
	local profileB = DataService.get(b)
	if not profileA or not profileB or not a.Parent or not b.Parent then
		closeSession(session, "The other player left.", false)
		return
	end
	for _, player in { a, b } do
		local ok, reason = TradeService.availability(player)
		-- The trade-count limit is checked when the window opened; a limit
		-- reached by a DIFFERENT trade in the meantime is impossible (one
		-- window per player), so every remaining reason is a real stop.
		if not ok then
			closeSession(session, `Trade cancelled: {player.DisplayName} - {reason}`, false)
			return
		end
	end

	local ok, reason, result = TradeLogic.execute(profileA, session.a.offer, profileB, session.b.offer)
	if not ok then
		session.executing = false
		resetHandshake(session)
		notify(a, "error", `Trade not completed: {reason}`)
		notify(b, "error", `Trade not completed: {reason}`)
		pushSession(session)
		return
	end

	-- Swapped. Everything below is bookkeeping; the window closes first so
	-- nothing can touch the finished offers while the saves yield.
	for _, player in { a, b } do
		local list = completedAt[player] or {}
		completedAt[player] = list
		table.insert(list, os.clock())
	end
	closeSession(session, "Trade complete!", true)
	for _, player in { a, b } do
		StateService.pushNow(player)
		StateService.notify(player, "success", "Trade complete!", "levelup")
		require(script.Parent.ProgressEvents).fire(player, "tradeCompleted", 1, { items = #result.aGave + #result.bGave }) -- [analytics-discord]
	end

	local record = {
		Id = session.id,
		At = os.time(),
		JobId = game.JobId,
		PlaceId = game.PlaceId,
		A = { UserId = a.UserId, Name = a.Name, Cash = result.aCash, Items = {} },
		B = { UserId = b.UserId, Name = b.Name, Cash = result.bCash, Items = {} },
	}
	for _, item in result.aGave do
		table.insert(record.A.Items, TradeLogic.logItem(item))
	end
	for _, item in result.bGave do
		table.insert(record.B.Items, TradeLogic.logItem(item))
	end
	task.spawn(writeLog, record)

	local savedA, savedB = saveBoth(a, b)
	if not savedA or not savedB then
		warn(`[TradeService] trade {session.id} swapped but a save failed (A={savedA}, B={savedB}); the autosave will retry`)
	end
end

local function editOffer(player: Player, action: string, argument: any)
	local session = sessions[player]
	if not session then
		send(player, "closed", { reason = "", completed = false })
		return
	end
	if session.executing then
		return
	end
	local mine = sideOf(session, player)
	local profile = DataService.get(player)
	if not profile then
		return
	end

	if action == "add" then
		if #mine.offer.items >= TradeConfig.MAX_ITEMS then
			notify(player, "error", `At most {TradeConfig.MAX_ITEMS} items per trade.`)
			return
		end
		if table.find(mine.offer.items, argument) then
			return
		end
		local item = TradeLogic.findStored(profile, argument)
		local ok, reason = TradeLogic.itemTradable(item)
		if not ok then
			notify(player, "error", reason or "That item can't be traded.")
			return
		end
		table.insert(mine.offer.items, argument)
	elseif action == "remove" then
		local index = table.find(mine.offer.items, argument)
		if not index then
			return
		end
		table.remove(mine.offer.items, index)
	elseif action == "cash" then
		local amount = TradeLogic.cleanCash(argument)
		if amount == nil then
			return
		end
		if amount > profile.Cash then
			notify(player, "error", "You don't have that much Cash.")
			pushSession(session)
			return
		end
		if amount == mine.offer.cash then
			return
		end
		mine.offer.cash = amount
	else
		return
	end
	resetHandshake(session)
	pushSession(session)
end

local function setReady(player: Player, flag: boolean)
	local session = sessions[player]
	if not session or session.executing then
		return
	end
	local mine, theirs = sideOf(session, player)
	if flag == mine.ready then
		return
	end
	if flag then
		local profileA = DataService.get(session.a.player)
		local profileB = DataService.get(session.b.player)
		if not profileA or not profileB then
			return
		end
		local ok, reason = TradeLogic.validate(profileA, session.a.offer, profileB, session.b.offer)
		if not ok then
			notify(player, "error", reason or "This trade can't be made.")
			return
		end
	end
	mine.ready = flag
	mine.confirmed = false
	theirs.confirmed = false
	session.lastActivity = os.clock()
	session.version += 1
	if mine.ready and theirs.ready then
		session.countdownEndsAt = now() + TradeConfig.COUNTDOWN_SECONDS
		local version = session.version
		task.delay(TradeConfig.COUNTDOWN_SECONDS + 0.05, function()
			-- Tell both clients CONFIRM is open, unless anything changed.
			if not session.closed and session.version == version then
				pushSession(session)
			end
		end)
	else
		session.countdownEndsAt = nil
	end
	pushSession(session)
end

local function confirm(player: Player)
	local session = sessions[player]
	if not session or session.executing then
		return
	end
	if phaseOf(session) ~= "confirm" then
		return
	end
	local mine, theirs = sideOf(session, player)
	if not mine.ready or not theirs.ready then
		return
	end
	mine.confirmed = true
	session.lastActivity = os.clock()
	if mine.confirmed and theirs.confirmed then
		finalize(session)
	else
		pushSession(session)
	end
end

function TradeService.cancel(player: Player, reason: string?)
	local session = sessions[player]
	if not session or session.executing then
		return
	end
	closeSession(session, reason or `{player.DisplayName} cancelled the trade.`, false)
end

-- ==========================================================
-- THE WATCH
-- ==========================================================

--- Re-checks one open window: players, carrying, policy, items, Cash, idle.
local function watch(session: Session)
	if session.closed or session.executing then
		return
	end
	for _, side in { session.a, session.b } do
		local player = side.player
		if not player.Parent or not DataService.get(player) then
			closeSession(session, "The other player left.", false)
			return
		end
		if TradeService.isCarrying(player) then
			closeSession(session, `Trade cancelled: {player.DisplayName} picked up loot.`, false)
			return
		end
		if not MonetizationService.policy(player).paidItemTradingAllowed then
			closeSession(session, "Trade cancelled: trading isn't available for one of you.", false)
			return
		end
	end
	if os.clock() - session.lastActivity > TradeConfig.SESSION_IDLE_SECONDS then
		closeSession(session, "The trade timed out.", false)
		return
	end

	local changed = false
	for _, side in { session.a, session.b } do
		local profile = DataService.get(side.player)
		if not profile then
			continue
		end
		local kept = {}
		local dropped = false
		for _, id in side.offer.items do
			local item = TradeLogic.findStored(profile, id)
			if item and TradeLogic.itemTradable(item) then
				table.insert(kept, id)
			else
				dropped = true
			end
		end
		if dropped then
			side.offer.items = kept
			changed = true
			notify(side.player, "info", "An item left your storage, so it was taken out of the trade.")
		end
		if side.offer.cash > profile.Cash then
			side.offer.cash = 0
			changed = true
			notify(side.player, "info", "You no longer have the Cash you offered.")
		end
	end
	if changed then
		resetHandshake(session)
		pushSession(session)
	end
end

-- ==========================================================
-- REMOTE
-- ==========================================================

local function userFrom(value: any): Player?
	local userId = Validate.integer(value, 1, 2 ^ 53)
	return if userId then Players:GetPlayerByUserId(userId) else nil
end

local function idFrom(value: any): string?
	if type(value) == "string" and #value > 0 and #value <= 64 then
		return value
	end
	return nil
end

local function dispatch(player: Player, action: string, first: any, second: any)
	if action == "request" then
		local target = userFrom(first)
		if not target then
			notify(player, "error", "That player isn't in this server.")
			return
		end
		local ok, reason = TradeService.request(player, target)
		if not ok and reason then
			notify(player, "error", reason)
		end
	elseif action == "respond" then
		local from = userFrom(first)
		if not from then
			if Validate.integer(first, 1, 2 ^ 53) then
				send(player, "requestGone", { fromUserId = first })
			end
			return
		end
		if second ~= "accept" and second ~= "decline" and second ~= "block" then
			return
		end
		local ok, reason = TradeService.respond(player, from, second)
		if not ok and reason then
			notify(player, "error", reason)
		end
	elseif action == "add" or action == "remove" then
		local id = idFrom(first)
		if id then
			editOffer(player, action, id)
		end
	elseif action == "cash" then
		if Validate.finite(first) then
			editOffer(player, action, first)
		end
	elseif action == "ready" then
		if type(first) == "boolean" then
			setReady(player, first)
		end
	elseif action == "confirm" then
		confirm(player)
	elseif action == "cancel" then
		TradeService.cancel(player)
	elseif action == "sync" then
		local session = sessions[player]
		if session then
			send(player, "session", viewFor(session, player))
		end
		local incoming = requests[player]
		if incoming then
			for from, request in incoming do
				send(player, "request", { fromUserId = from.UserId, fromName = from.DisplayName, expiresAt = request.expiresAt })
			end
		end
		StateService.markDirty(player)
	end
end

-- ==========================================================
-- DEBUG / STATUS
-- ==========================================================

function TradeService.status(player: Player?): { [string]: any }
	local open = 0
	local seen: { [Session]: boolean } = {}
	for _, session in sessions do
		if not seen[session] then
			seen[session] = true
			open += 1
		end
	end
	local pending = 0
	for _, list in requests do
		for _ in list do
			pending += 1
		end
	end
	local out: { [string]: any } = {
		openSessions = open,
		pendingRequests = pending,
		logStore = if logStore then TradeConfig.TRADE_LOG_STORE else "memory",
		recentLogs = #recentLogs,
	}
	if player then
		local ok, reason, readyAt = TradeService.availability(player)
		out.you = {
			allowed = ok,
			reason = reason,
			readyAt = readyAt,
			inTrade = sessions[player] ~= nil,
			completedInWindow = recentTrades(player),
			policy = MonetizationService.policy(player),
		}
	end
	return out
end

function TradeService.recentLogs(): { any }
	return table.clone(recentLogs)
end

--- Studio only: forget the join time, as if the player joined long ago.
function TradeService.debugSkipJoinGrace(player: Player)
	joinedAt[player] = os.clock() - TradeConfig.JOIN_GRACE_SECONDS - 1
	StateService.markDirty(player)
end

-- ==========================================================
-- START
-- ==========================================================

function TradeService.start()
	if DataService.isPersistent() then
		local ok, opened = pcall(function()
			return DataStoreService:GetDataStore(TradeConfig.TRADE_LOG_STORE)
		end)
		if ok then
			logStore = opened
		end
	end

	local function joined(player: Player)
		joinedAt[player] = os.clock()
		-- The panel's "you can trade in Ns" turns into "ready" on its own.
		task.delay(TradeConfig.JOIN_GRACE_SECONDS + 0.2, function()
			if player.Parent then
				StateService.markDirty(player)
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		joined(player)
	end
	Players.PlayerAdded:Connect(joined)

	Players.PlayerRemoving:Connect(function(player)
		local session = sessions[player]
		if session then
			closeSession(session, `{player.DisplayName} left the server.`, false)
		end
		dropRequestsFrom(player)
		local incoming = requests[player]
		requests[player] = nil
		if incoming then
			for from in incoming do
				notify(from, "info", `{player.DisplayName} left before answering.`)
			end
		end
		lastAsked[player] = nil
		blocked[player] = nil
		joinedAt[player] = nil
		completedAt[player] = nil
		limiter:release(player)
	end)

	Remotes.get("TradeRequest").OnServerEvent:Connect(function(player, action, first, second)
		if type(action) ~= "string" or not limiter:consume(player) then
			return
		end
		local ok, err = (pcall :: any)(dispatch, player, action, first, second)
		if not ok then
			warn(`[TradeService] {action} from {player.Name} failed: {err}`)
		end
	end)

	StateService.addProvider("trade", TradeService.summarise)

	task.spawn(function()
		while true do
			task.wait(TradeConfig.SESSION_CHECK_SECONDS)
			-- Collected first: watching can close a session, which edits the map.
			local open: { Session } = {}
			for _, session in sessions do
				if not table.find(open, session) then
					table.insert(open, session)
				end
			end
			for _, session in open do
				local ok, err = (pcall :: any)(watch, session)
				if not ok then
					warn(`[TradeService] watch failed: {err}`)
				end
			end
		end
	end)

	print(`[TradeService] trading online (log: {if logStore then TradeConfig.TRADE_LOG_STORE else "memory"})`)
end

return TradeService
