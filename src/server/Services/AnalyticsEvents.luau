--!strict
--[[
	AnalyticsEvents  (polish-events-analytics pass)
	Everything the game reports to Roblox's AnalyticsService, from one module.

	WHAT IS LOGGED
	  Onboarding funnel (LogOnboardingFunnelStepEvent), NEW players only, each
	  step once per player (saved in Profile.AnalyticsOnboarding):
	    1 joined   2 first steal   3 first escape   4 first delivery
	    5 first reveal   6 first upgrade   7 first purchase view (shop opened)
	  "FirstPurchase" funnel (LogFunnelStepEvent), players with no product
	  receipt yet, one funnel session per shop visit:
	    1 shop opened   2 product prompted   3 purchased
	  Economy (LogEconomyEvent): every EconomyService.award (source) and
	  EconomyService.spend (sink), through EconomyService.onTransaction - the
	  one central place. The tag picks the transaction type (SOURCE_TYPES /
	  SINK_TYPES below). Passive income is summed per player and sent every
	  ANALYTICS_PASSIVE_FLUSH_SECONDS and on leave. "debug" is never sent.
	  Progression (LogProgressionEvent): path "MuseumZone", status Start,
	  level = the zone, when Profile.HighestZoneReached goes up (it goes up
	  when a container from a deeper zone is placed at home).

	SAFETY
	  * Every AnalyticsService call is spawned and pcall'd.
	  * Each category (funnel / economy / progression) has a token bucket at
	    Roblox's per-server budget (120 + 20 x players per minute) times
	    ANALYTICS_BUDGET_SAFETY; overflow is dropped and counted.
	  * Studio sends nothing unless the debug flag is on
	    (PolishConfig.ANALYTICS_DEBUG, or the `analyticsDebug` command); with
	    it on, every event is also printed. Either way the last
	    ANALYTICS_DUMP_SIZE events are kept for the `analyticsDump` command.
	  * The client can only name a funnel step from CLIENT_STEPS, through a
	    rate-limited remote; it can never name an amount or a player.

	PROGRESS BUS
	Steals, escapes, deliveries and reveals arrive through ProgressEvents
	(KINDS below). If the merged ProgressEvents uses other kind names, change
	KINDS - nothing else.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PolishConfig = require(ReplicatedStorage.Shared.Config.PolishConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ProgressEvents = require(script.Parent.ProgressEvents)
local StateService = require(script.Parent.StateService)

local AnalyticsEvents = {}

local IS_STUDIO = RunService:IsStudio()
local debugOn = PolishConfig.ANALYTICS_DEBUG == true

--- ProgressEvents kind names this module listens for.
AnalyticsEvents.KINDS = {
	steal = "steal",
	escape = "escape",
	deliver = "deliver",
	reveal = "reveal",
}

type Step = { key: string, step: number, name: string }

AnalyticsEvents.ONBOARDING = {
	{ key = "joined", step = 1, name = "Joined" },
	{ key = "firstSteal", step = 2, name = "First Steal" },
	{ key = "firstEscape", step = 3, name = "First Escape" },
	{ key = "firstDelivery", step = 4, name = "First Delivery" },
	{ key = "firstReveal", step = 5, name = "First Reveal" },
	{ key = "firstUpgrade", step = 6, name = "First Upgrade" },
	{ key = "firstPurchaseView", step = 7, name = "First Purchase View" },
} :: { Step }

local stepByKey: { [string]: Step } = {}
for _, step in AnalyticsEvents.ONBOARDING do
	stepByKey[step.key] = step
end

AnalyticsEvents.PURCHASE_FUNNEL = "FirstPurchase"

--- Funnel steps a CLIENT may report. Nothing else is accepted from it.
local CLIENT_STEPS: { [string]: true } = { shopOpened = true }

--- Award source tag -> Enum.AnalyticsEconomyTransactionType name.
--- Unknown tags (a mailbox entry's own source, a future "code") are Gameplay.
AnalyticsEvents.SOURCE_TYPES = {
	passive = "Gameplay",
	sell = "Gameplay",
	discovery = "Gameplay",
	index = "Gameplay",
	offline = "TimedReward",
	spin = "TimedReward",
	task = "Onboarding",
	product = "IAP",
	code = "Gameplay",
} :: { [string]: string }

--- Spend sink tag PREFIX (before the ":") -> transaction type name.
AnalyticsEvents.SINK_TYPES = {
	upgrade = "Shop",
	trail = "Shop",
	gadget = "Shop",
} :: { [string]: string }

--- Tags that are never reported.
local NEVER: { [string]: true } = { debug = true }

local CURRENCY = "Cash"

-- ==========================================================
-- SENDING
-- ==========================================================

type Bucket = { tokens: number, updated: number }
local buckets: { [string]: Bucket } = {}
local sentCount: { [string]: number } = {}
local droppedCount: { [string]: number } = {}
local failedCount = 0
local recent: { any } = {}

local function perMinute(): number
	return (PolishConfig.ANALYTICS_BUDGET_BASE + PolishConfig.ANALYTICS_BUDGET_PER_PLAYER * #Players:GetPlayers())
		* PolishConfig.ANALYTICS_BUDGET_SAFETY
end

local function take(category: string): boolean
	local now = os.clock()
	local capacity = perMinute()
	local bucket = buckets[category]
	if not bucket then
		bucket = { tokens = capacity, updated = now }
		buckets[category] = bucket
	end
	bucket.tokens = math.min(capacity, bucket.tokens + (now - bucket.updated) * capacity / 60)
	bucket.updated = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function remember(category: string, player: Player, description: string, sending: boolean)
	table.insert(recent, {
		at = os.time(),
		category = category,
		player = player.Name,
		event = description,
		sent = sending,
	})
	while #recent > PolishConfig.ANALYTICS_DUMP_SIZE do
		table.remove(recent, 1)
	end
end

--- True when this server really calls AnalyticsService.
local function live(): boolean
	return not IS_STUDIO or debugOn
end

local function send(category: string, player: Player, description: string, call: () -> ())
	local sending = live()
	remember(category, player, description, sending)
	if not sending then
		return
	end
	if not take(category) then
		droppedCount[category] = (droppedCount[category] or 0) + 1
		return
	end
	sentCount[category] = (sentCount[category] or 0) + 1
	if debugOn then
		print(`[Analytics] {category} {player.Name}: {description}`)
	end
	task.spawn(function()
		local ok, err = pcall(function()
			call()
		end)
		if not ok then
			failedCount += 1
			-- One line per failure is enough; the budget above bounds it.
			warn(`[AnalyticsEvents] {category} call failed: {err}`)
		end
	end)
end

local function transactionType(name: string): string
	local ok, item = pcall(function()
		return (Enum.AnalyticsEconomyTransactionType :: any)[name]
	end)
	if ok and typeof(item) == "EnumItem" then
		return (item :: EnumItem).Name
	end
	return name
end

-- ==========================================================
-- ONBOARDING FUNNEL
-- ==========================================================

--- Logs onboarding step `key` for `player` once in their life. A no-op for
--- players who existed before analytics (`legacy`).
function AnalyticsEvents.onboarding(player: Player, key: string)
	local step = stepByKey[key]
	local profile = DataService.get(player)
	if not step or not profile then
		return
	end
	local logged = profile.AnalyticsOnboarding
	if type(logged) ~= "table" or logged.legacy or logged[key] then
		return
	end
	-- Only marked when it is really sent: a Studio session with analytics
	-- off must not use up a step it never reported.
	if live() then
		logged[key] = true
	end
	send("funnel", player, `onboarding {step.step} {step.name}`, function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step.step, step.name)
	end)
end

-- ==========================================================
-- FIRST PURCHASE FUNNEL
-- ==========================================================

type FunnelSession = { id: string, reached: number, openedAt: number }
local funnelSessions: { [Player]: FunnelSession } = {}
--- A shop visit counts towards a purchase for this long.
local FUNNEL_SESSION_SECONDS = 15 * 60
local PURCHASE_STEP_NAMES = { "Shop Opened", "Product Prompted", "Purchased" }

local function neverPurchased(player: Player): boolean
	local profile = DataService.get(player)
	return profile ~= nil and #profile.ProcessedReceipts == 0
end

local function funnelStep(player: Player, step: number)
	local session = funnelSessions[player]
	if not session or session.reached >= step then
		return
	end
	if os.clock() - session.openedAt > FUNNEL_SESSION_SECONDS then
		funnelSessions[player] = nil
		return
	end
	-- Steps are in order: a purchase without a recorded prompt still
	-- records the prompt first, so the funnel never shows a gap.
	for index = session.reached + 1, step do
		local name = PURCHASE_STEP_NAMES[index]
		local id = session.id
		send("funnel", player, `{AnalyticsEvents.PURCHASE_FUNNEL} {index} {name}`, function()
			AnalyticsService:LogFunnelStepEvent(player, AnalyticsEvents.PURCHASE_FUNNEL, id, index, name)
		end)
	end
	session.reached = step
	if step >= #PURCHASE_STEP_NAMES then
		funnelSessions[player] = nil
	end
end

function AnalyticsEvents.shopOpened(player: Player)
	AnalyticsEvents.onboarding(player, "firstPurchaseView")
	if not neverPurchased(player) then
		return
	end
	local session = funnelSessions[player]
	-- Re-opening the shop inside a live session continues it.
	if session and os.clock() - session.openedAt <= FUNNEL_SESSION_SECONDS then
		session.openedAt = os.clock()
		return
	end
	funnelSessions[player] = { id = HttpService:GenerateGUID(false), reached = 0, openedAt = os.clock() }
	funnelStep(player, 1)
end

function AnalyticsEvents.productPrompted(player: Player)
	funnelStep(player, 2)
end

function AnalyticsEvents.purchased(player: Player)
	funnelStep(player, 3)
end

--- Wraps MonetizationService.processReceipt so a GRANTED receipt completes
--- the funnel. Must run before MonetizationService.start (which installs
--- processReceipt as the callback). The wrapper returns exactly what the
--- real handler returned, and analytics can never throw out of it.
function AnalyticsEvents.wrapReceipts(monetization: any)
	local inner = monetization.processReceipt
	if type(inner) ~= "function" then
		warn("[AnalyticsEvents] MonetizationService.processReceipt not found - purchase funnel incomplete")
		return
	end
	local seen: { [string]: true } = {}
	monetization.processReceipt = function(receiptInfo: any): Enum.ProductPurchaseDecision
		local decision = inner(receiptInfo)
		if decision == Enum.ProductPurchaseDecision.PurchaseGranted then
			pcall(function()
				local id = tostring(receiptInfo.PurchaseId)
				if seen[id] then
					return -- a replayed receipt
				end
				seen[id] = true
				local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
				if player then
					AnalyticsEvents.purchased(player)
				end
			end)
		end
		return decision
	end
end

-- ==========================================================
-- ECONOMY
-- ==========================================================

type Pending = { amount: number, balance: number }
local passive: { [Player]: Pending } = {}

local function logEconomy(player: Player, flow: string, amount: number, tag: string, balance: number)
	local prefix = string.match(tag, "^([^:]+)") or tag
	local typeName = if flow == "source"
		then (AnalyticsEvents.SOURCE_TYPES[tag] or "Gameplay")
		else (AnalyticsEvents.SINK_TYPES[prefix] or "Gameplay")
	local kind = transactionType(typeName)
	local flowType = if flow == "source" then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink
	local whole = math.floor(amount)
	local ending = math.floor(balance)
	if whole <= 0 then
		return
	end
	send("economy", player, `{flow} {CURRENCY} {whole} ({kind}, {tag}) -> {ending}`, function()
		AnalyticsService:LogEconomyEvent(player, flowType, CURRENCY, whole, ending, kind, tag)
	end)
end

local function flushPassive(player: Player)
	local pending = passive[player]
	passive[player] = nil
	if pending and pending.amount >= 1 then
		logEconomy(player, "source", pending.amount, "passive", pending.balance)
	end
end

local function onTransaction(player: Player, flow: string, amount: number, tag: string, balance: number)
	if NEVER[tag] then
		return
	end
	if flow == "sink" and string.sub(tag, 1, 8) == "upgrade:" then
		AnalyticsEvents.onboarding(player, "firstUpgrade")
	end
	if flow == "source" and tag == "passive" then
		local pending = passive[player]
		if not pending then
			pending = { amount = 0, balance = balance }
			passive[player] = pending
		end
		pending.amount += amount
		pending.balance = balance
		return
	end
	logEconomy(player, flow, amount, tag, balance)
end

-- ==========================================================
-- PROGRESSION
-- ==========================================================

local highestSeen: { [Player]: number } = {}

local function onPushed(player: Player, state: any)
	local zone = if type(state) == "table" then tonumber(state.highestZone) else nil
	if not zone then
		return
	end
	local previous = highestSeen[player]
	highestSeen[player] = math.max(zone, previous or 0)
	-- The first push is the baseline: a returning player is not "reaching"
	-- the zones they already had.
	if not previous or zone <= previous then
		return
	end
	for level = previous + 1, zone do
		local def = ZoneConfig.Zones[level]
		local name = if def then def.name else `Zone {level}`
		send("progression", player, `MuseumZone start {level} {name}`, function()
			AnalyticsService:LogProgressionEvent(player, "MuseumZone", Enum.AnalyticsProgressionType.Start, level, name)
		end)
	end
end

-- ==========================================================
-- DEBUG
-- ==========================================================

function AnalyticsEvents.setDebug(on: boolean)
	debugOn = on
end

function AnalyticsEvents.dump(): { [string]: any }
	return {
		studio = IS_STUDIO,
		debug = debugOn,
		sendingForReal = live(),
		budgetPerMinute = perMinute(),
		sent = table.clone(sentCount),
		dropped = table.clone(droppedCount),
		failed = failedCount,
		pendingPassive = (function()
			local out = {}
			for player, pending in passive do
				out[player.Name] = pending.amount
			end
			return out
		end)(),
		recent = table.clone(recent),
	}
end

--- Sends every player's summed passive income now (debug and leave).
function AnalyticsEvents.flushAll()
	for player in table.clone(passive) do
		flushPassive(player)
	end
end

-- ==========================================================
-- START
-- ==========================================================

function AnalyticsEvents.start()
	EconomyService.onTransaction(onTransaction)
	StateService.onPushed(onPushed)

	ProgressEvents.on(AnalyticsEvents.KINDS.steal, function(player)
		AnalyticsEvents.onboarding(player, "firstSteal")
	end)
	ProgressEvents.on(AnalyticsEvents.KINDS.escape, function(player)
		AnalyticsEvents.onboarding(player, "firstEscape")
	end)
	ProgressEvents.on(AnalyticsEvents.KINDS.deliver, function(player)
		AnalyticsEvents.onboarding(player, "firstDelivery")
	end)
	ProgressEvents.on(AnalyticsEvents.KINDS.reveal, function(player)
		AnalyticsEvents.onboarding(player, "firstReveal")
	end)

	-- The client's one funnel step. A key from CLIENT_STEPS, nothing else.
	local limiter = RateLimiter.new(PolishConfig.ANALYTICS_CLIENT_PER_SECOND, PolishConfig.ANALYTICS_CLIENT_BURST)
	Remotes.get("AnalyticsClientEvent").OnServerEvent:Connect(function(player, key)
		if type(key) ~= "string" or not CLIENT_STEPS[key] then
			return
		end
		if not limiter:consume(player) then
			return
		end
		if key == "shopOpened" then
			AnalyticsEvents.shopOpened(player)
		end
	end)

	-- "Product prompted": an observer on the purchase remote. Only the
	-- action names MonetizationService itself accepts count; the request is
	-- still validated and rate-limited there.
	local PROMPT_ACTIONS: { [string]: true } =
		{ treadmill = true, speedTier = true, cashPass = true, product = true, guardian = true, slap = true }
	Remotes.get("PurchaseRequest").OnServerEvent:Connect(function(player, action)
		if type(action) == "string" and PROMPT_ACTIONS[action] then
			AnalyticsEvents.productPrompted(player)
		end
	end)
	-- A gamepass bought through any prompt completes the funnel too
	-- (products complete it from the receipt wrapper).
	game:GetService("MarketplaceService").PromptGamePassPurchaseFinished:Connect(function(player, _id, purchased)
		if purchased then
			AnalyticsEvents.purchased(player)
		end
	end)

	local function onPlayer(player: Player)
		task.spawn(function()
			if DataService.waitForProfile(player) then
				AnalyticsEvents.onboarding(player, "joined")
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)

	-- The summed passive income goes out with the leave-save, while the
	-- profile (and its balance) is still there.
	DataService.onBeforeRelease(function(player)
		flushPassive(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		funnelSessions[player] = nil
		highestSeen[player] = nil
		limiter:release(player)
		-- onBeforeRelease normally flushed already; this only drops leftovers.
		task.delay(30, function()
			passive[player] = nil
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(PolishConfig.ANALYTICS_PASSIVE_FLUSH_SECONDS)
			local ok, err = pcall(function()
				AnalyticsEvents.flushAll()
			end)
			if not ok then
				warn(`[AnalyticsEvents] passive flush failed: {err}`)
			end
		end
	end)

	print(`[AnalyticsEvents] online ({if live() then "sending" else "Studio: recording only"})`)
end

return AnalyticsEvents
