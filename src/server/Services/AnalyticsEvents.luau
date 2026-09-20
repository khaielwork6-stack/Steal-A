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

	[analytics-discord] ADDED
	  * custom(): LogCustomEvent for a FIXED list of names (CUSTOM_EVENTS),
	    three short fields each. The session / quit / core-loop / feature
	    events are decided in AnalyticsSession and sent through here.
	  * Speed economy: currency "Speed", every SpeedPower grant fires
	    ProgressEvents "speedGain" { source }; treadmill ticks are summed.
	  * Per-product funnels Buy_* (shown -> prompted -> purchased), the
	    "BossOffer" funnel (shown -> clicked -> purchased) and the
	    PurchaseCancelled event, from the MarketplaceService dialog events.
	  * observe()/emit(): facts for DiscordReporter (purchases, sessions,
	    catches, reveals). mirror: EVERY recorded event, from send(), for
	    the Discord analytics mirror.
	  * dump(filter) for the Studio commands.

	PROGRESS BUS
	Steals, escapes, deliveries and reveals arrive through ProgressEvents
	(KINDS below). "steal" / "escape" are fired in init.server.luau and
	"reveal" by SocialService at the swap (social pass); "deliver" is fired
	by this pass in init's delivered handler.
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
	social = "Gameplay",
	daily = "TimedReward",
	sell = "Gameplay",
	discovery = "Gameplay",
	index = "Gameplay",
	offline = "TimedReward",
	spin = "TimedReward",
	task = "Onboarding",
	product = "IAP",
	code = "Gameplay",
	-- [analytics-discord] Speed sources (and the Cash ones that were
	-- falling through to the default).
	train = "Gameplay",
	quest = "Gameplay",
	season = "Gameplay",
	group = "Gameplay",
	crew = "Gameplay",
	referral = "Gameplay",
	mail = "Gameplay",
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

--- [analytics-discord] The same event as a row for the Discord mirror.
export type MirrorRow = { type: string, event: string, f1: string?, f2: string?, f3: string?, value: number? }

--- Set by DiscordReporter: every recorded event, as it is recorded (before
--- the budget, so the mirror sees what Roblox would have been sent).
AnalyticsEvents.mirror = nil :: ((Player, MirrorRow) -> ())?

local function send(category: string, player: Player, description: string, call: () -> (), row: MirrorRow?)
	local sending = live()
	remember(category, player, description, sending)
	local mirror = AnalyticsEvents.mirror
	if mirror and row then
		local ok: boolean, err: any = (pcall :: any)(mirror, player, row)
		if not ok then
			failedCount += 1
			warn(`[AnalyticsEvents] mirror failed: {err}`)
		end
	end
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
-- [analytics-discord] OBSERVERS
-- ==========================================================
-- DiscordReporter (and anything else that wants the same facts) listens
-- here instead of re-deriving them. Called for every RECORDED fact, sent or
-- not, so the Studio dump and the Discord counters agree. Observers run
-- under pcall on their own thread and can never break analytics.

export type Observer = (name: string, player: Player?, data: { [string]: any }) -> ()
local observers: { Observer } = {}

function AnalyticsEvents.observe(fn: Observer)
	table.insert(observers, fn)
end

function AnalyticsEvents.emit(name: string, player: Player?, data: { [string]: any })
	for _, fn in observers do
		task.spawn(function()
			local ok: boolean, err: any = (pcall :: any)(fn, name, player, data)
			if not ok then
				warn(`[AnalyticsEvents] observer failed on {name}: {err}`)
			end
		end)
	end
end

-- ==========================================================
-- [analytics-discord] CUSTOM EVENTS
-- ==========================================================
-- Roblox caps the number of DISTINCT custom event names, so every name is
-- from this fixed list and nothing else is ever sent. Each event carries at
-- most three custom fields (CustomField01..03), always short labels from
-- small fixed sets (buckets, zone labels, rarity names), never free text.

AnalyticsEvents.CUSTOM_EVENTS = {
	-- core loop
	"Caught", "LaserTouched", "Robbed", "StorageFullBlocked", "UnderSpeedAttempt",
	"Revealed", "RevealWait", "FirstEpicReveal", "TimeToFirstReveal",
	-- sessions and quits
	"SessionStart", "SessionEnd",
	"QuitInTutorial", "QuitAfterCatch", "QuitAfterRobbed", "QuitWhileCarrying", "QuitInPanel", "QuitIdle", "QuitActive",
	-- feature use
	"DailyClaim", "QuestClaim", "SeasonTier", "TradeCompleted", "Fusion", "GadgetUsed", "VaultSteal",
	"CrewAssist", "SpinUsed", "CodeRedeemed",
	-- purchases and performance
	"PurchaseCancelled", "PerfSpike",
	-- [tutorial-film] the short film that replaced the old objective-line
	-- tutorial. Low cardinality: one event per player per stage of the film,
	-- so the owner can see where new players drop off.
	"FilmStarted", "FilmSkipped", "FilmFinished",
} :: { string }

local customAllowed: { [string]: true } = {}
for _, name in AnalyticsEvents.CUSTOM_EVENTS do
	customAllowed[name] = true
end

local FIELD_KEYS: { string } = (function()
	local out: { string } = {}
	for index, fallback in { "CustomField01", "CustomField02", "CustomField03" } do
		local ok, item = pcall(function()
			return ((Enum :: any).AnalyticsCustomFieldKeys :: any)[fallback]
		end)
		out[index] = if ok and typeof(item) == "EnumItem" then (item :: EnumItem).Name else fallback
	end
	return out
end)()

local customCount: { [string]: number } = {}

--- Logs custom event `name` (from CUSTOM_EVENTS) with a numeric value and
--- up to three short labels. Unknown names are refused loudly in Studio and
--- silently live. Never yields, never throws.
function AnalyticsEvents.custom(player: Player, name: string, value: number?, fields: { string }?)
	if not customAllowed[name] then
		if IS_STUDIO then
			warn(`[AnalyticsEvents] custom event "{name}" is not in CUSTOM_EVENTS - not sent`)
		end
		return
	end
	local amount = tonumber(value) or 1
	if amount ~= amount or amount == math.huge or amount == -math.huge then
		amount = 0
	end
	local map: { [string]: string } = {}
	local shown: { string } = {}
	if fields then
		for index = 1, 3 do
			local label = fields[index]
			if label ~= nil then
				local text = string.sub(tostring(label), 1, 50)
				map[FIELD_KEYS[index]] = text
				table.insert(shown, text)
			end
		end
	end
	customCount[name] = (customCount[name] or 0) + 1
	send("custom", player, `{name} {amount} [{table.concat(shown, ", ")}]`, function()
		AnalyticsService:LogCustomEvent(player, name, amount, map)
	end, { type = "custom", event = name, f1 = shown[1], f2 = shown[2], f3 = shown[3], value = amount })
end

-- ==========================================================
-- [analytics-discord] SHARED LABELS
-- ==========================================================

--- "Z03" for a zone number; the label every event uses for a zone.
function AnalyticsEvents.zoneLabel(zone: any): string
	local n = tonumber(zone)
	if not n or n < 1 then
		return "None"
	end
	return string.format("Z%02d", math.floor(n))
end

--- First bucket whose upper bound (seconds) the value is under.
type Range = { under: number, label: string }

local DURATION_BUCKETS: { Range } = {
	{ under = 60, label = "<1m" }, { under = 180, label = "1-3m" }, { under = 600, label = "3-10m" },
	{ under = 1800, label = "10-30m" }, { under = 3600, label = "30-60m" }, { under = 7200, label = "1-2h" },
	{ under = 86400, label = "2-24h" },
}
function AnalyticsEvents.durationBucket(seconds: number): string
	for _, row in DURATION_BUCKETS do
		if seconds < row.under then
			return row.label
		end
	end
	return "1d+"
end

local WAIT_BUCKETS: { Range } = {
	{ under = 1, label = "0s" }, { under = 10, label = "1-10s" }, { under = 60, label = "10-60s" },
	{ under = 300, label = "1-5m" }, { under = 1800, label = "5-30m" }, { under = 7200, label = "30m-2h" },
	{ under = 86400, label = "2-24h" },
}
function AnalyticsEvents.waitBucket(seconds: number): string
	for _, row in WAIT_BUCKETS do
		if seconds < row.under then
			return row.label
		end
	end
	return "1d+"
end

function AnalyticsEvents.sessionBucket(number: number): string
	if number <= 3 then
		return `S{math.max(1, number)}`
	elseif number <= 5 then
		return "S4-5"
	elseif number <= 10 then
		return "S6-10"
	elseif number <= 20 then
		return "S11-20"
	end
	return "S21+"
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
	end, { type = "funnel", event = "Onboarding", f1 = tostring(step.step), f2 = step.name, value = step.step })
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
		end, { type = "funnel", event = AnalyticsEvents.PURCHASE_FUNNEL, f1 = tostring(index), f2 = name, value = index })
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
					-- [analytics-discord] The per-kind funnel, the catch
					-- offer and the Discord purchase post.
					AnalyticsEvents.productPurchased(player, tonumber(receiptInfo.ProductId) or 0, tonumber(receiptInfo.CurrencySpent))
				end
			end)
		end
		return decision
	end
end

-- ==========================================================
-- [analytics-discord] PURCHASE FUNNELS PER PRODUCT TYPE
-- ==========================================================
-- One funnel per kind: 1 shown -> 2 prompted -> 3 purchased.
--   shown      the client opened a panel that sells the kind (PANEL_SHOWS);
--              for the world prompts (Steal, Reveal) there is no separate
--              "shown" moment, so it is recorded together with "prompted".
--   prompted   Roblox closed a purchase dialog for it (PromptProduct/
--              GamePassPurchaseFinished) - every prompt ends in exactly one.
--   purchased  a GRANTED receipt (products) or a bought gamepass.
-- A dialog closed without buying is also a PurchaseCancelled custom event.
-- "BossOffer" is the post-catch Speed offer: shown -> clicked -> purchased.

AnalyticsEvents.KIND_FUNNELS = {
	Steal = "Buy_Steal",
	Reveal = "Buy_Reveal",
	Gadget = "Buy_Gadget",
	Pass = "Buy_Pass",
	Cash = "Buy_Pack",
	Speed = "Buy_Pack",
	TreadmillTier = "Buy_Pack",
	Gift = "Buy_Gift",
	Skip = "Buy_SeasonSkip",
} :: { [string]: string }

--- Which funnels a panel's opening counts as "shown" for.
local PANEL_SHOWS: { [string]: { string } } = {
	Shop = { "Buy_Pack", "Buy_Pass", "Buy_Gift" },
	Upgrades = { "Buy_Pack" },
	TrailShop = { "Buy_Pass" },
	GadgetStore = { "Buy_Gadget" },
	SeasonPass = { "Buy_SeasonSkip" },
}

local KIND_STEP_NAMES = { "Shown", "Prompted", "Purchased" }
local BOSS_STEP_NAMES = { "Shown", "Clicked", "Purchased" }
AnalyticsEvents.BOSS_FUNNEL = "BossOffer"

type ProductInfo = { key: string, kind: string, label: string, robux: number, pass: boolean }

--- Every product and pass id -> what it is, gifts included (they are not in
--- MonetizationConfig.ProductById). Built on first use.
local catalogue: { products: { [number]: ProductInfo }, passes: { [number]: ProductInfo } }? = nil

local function getCatalogue()
	if catalogue then
		return catalogue
	end
	local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig) :: any
	local products: { [number]: ProductInfo } = {}
	local passes: { [number]: ProductInfo } = {}
	local lists = {
		MonetizationConfig.SpeedProducts, MonetizationConfig.CashProducts, MonetizationConfig.TreadmillProducts,
		MonetizationConfig.StealProducts, MonetizationConfig.RevealProducts, MonetizationConfig.GadgetProducts,
		MonetizationConfig.SkipProducts, MonetizationConfig.GiftProducts,
	}
	for _, list in lists do
		for _, product in (list or {}) :: { any } do
			local id = tonumber(product.productId) or 0
			if id > 0 then
				products[id] = { key = product.key, kind = product.kind, label = product.label or product.key, robux = tonumber(product.robux) or 0, pass = false }
			end
		end
	end
	local function addPass(pass: any, label: string?)
		local id = if type(pass) == "table" then tonumber(pass.gamePassId) or 0 else 0
		if id > 0 then
			passes[id] = { key = pass.key or tostring(id), kind = "Pass", label = label or pass.label or pass.name or pass.key or tostring(id), robux = tonumber(pass.robux) or 0, pass = true }
		end
	end
	for _, tier in MonetizationConfig.SpeedMultiplierPasses or {} do
		addPass(tier, `Speed {tier.label} pass`)
	end
	addPass(MonetizationConfig.CashPass, "2x Cash pass")
	for _, pass in MonetizationConfig.GuardianPasses or {} do
		addPass(pass)
	end
	addPass(MonetizationConfig.SlapPass)
	addPass(MonetizationConfig.SeasonPremiumPass)
	for _, trail in MonetizationConfig.Trails or {} do
		addPass(trail)
	end
	if type(MonetizationConfig.featurePasses) == "function" then
		for _, pass in MonetizationConfig.featurePasses() do
			addPass(pass)
		end
	end
	local built = { products = products, passes = passes }
	catalogue = built
	return built
end

function AnalyticsEvents.productInfo(productId: number): ProductInfo?
	return getCatalogue().products[productId]
end

function AnalyticsEvents.passInfo(gamePassId: number): ProductInfo?
	return getCatalogue().passes[gamePassId]
end

type KindSession = { id: string, reached: number, at: number }
local kindSessions: { [Player]: { [string]: KindSession } } = {}

local function kindStep(player: Player, funnel: string, step: number, names: { string })
	local mine = kindSessions[player]
	if not mine then
		mine = {}
		kindSessions[player] = mine
	end
	local existing: KindSession? = mine[funnel]
	local now = os.clock()
	if existing and now - existing.at > FUNNEL_SESSION_SECONDS then
		existing = nil
	end
	if step == 1 and existing and existing.reached >= 1 then
		-- Shown again inside a live session: the same visit.
		existing.at = now
		return
	end
	local current: KindSession = existing or { id = HttpService:GenerateGUID(false), reached = 0, at = now }
	mine[funnel] = current
	if current.reached >= step then
		return
	end
	-- Earlier steps are filled in, so the funnel never shows a gap.
	for index = current.reached + 1, step do
		local name = names[index]
		local id = current.id
		send("funnel", player, `{funnel} {index} {name}`, function()
			AnalyticsService:LogFunnelStepEvent(player, funnel, id, index, name)
		end, { type = "funnel", event = funnel, f1 = tostring(index), f2 = name, value = index })
	end
	current.reached = step
	current.at = now
	if step >= #names then
		mine[funnel] = nil
	end
end

--- The client opened panel `panel` (already checked against the list).
function AnalyticsEvents.panelShown(player: Player, panel: string)
	local funnels = PANEL_SHOWS[panel]
	if funnels then
		for _, funnel in funnels do
			kindStep(player, funnel, 1, KIND_STEP_NAMES)
		end
	end
end

local function funnelOf(info: ProductInfo?): string?
	return if info then AnalyticsEvents.KIND_FUNNELS[info.kind] else nil
end

--- A purchase dialog closed (any product or pass).
local function dialogClosed(player: Player, info: ProductInfo?, purchased: boolean)
	local funnel = funnelOf(info)
	if funnel then
		kindStep(player, funnel, 2, KIND_STEP_NAMES)
	end
	if not purchased then
		local kind = if info then info.kind else "Unknown"
		AnalyticsEvents.custom(player, "PurchaseCancelled", 1, { kind, if info then info.key else "unknown" })
		AnalyticsEvents.emit("PurchaseCancelled", player, { kind = kind, key = if info then info.key else "unknown" })
	end
end

type BossSession = { key: string, at: number }
local bossOffers: { [Player]: BossSession } = {}

--- The post-catch Speed offer was sent to this player (MonetizationService).
function AnalyticsEvents.bossOfferShown(player: Player, productKey: string, zone: number?)
	bossOffers[player] = { key = productKey, at = os.clock() }
	-- A new offer is a new funnel session.
	local mine = kindSessions[player]
	if mine then
		mine[AnalyticsEvents.BOSS_FUNNEL] = nil
	end
	kindStep(player, AnalyticsEvents.BOSS_FUNNEL, 1, BOSS_STEP_NAMES)
	AnalyticsEvents.emit("BossOfferShown", player, { key = productKey, zone = zone })
end

local function bossLive(player: Player, key: string): boolean
	local offer = bossOffers[player]
	return offer ~= nil and offer.key == key and os.clock() - offer.at <= FUNNEL_SESSION_SECONDS
end

--- Robux actually spent, for a Discord post: the receipt's own figure, else
--- the live price, else the config's listed price.
--- Live Robux price of a product (or pass, `isPass`), nil when unknown.
--- Injected by init (MonetizationService's live-price cache).
function AnalyticsEvents.livePrice(_id: number, _isPass: boolean): number?
	return nil
end

--- The open MainUI panel reached the server. Set by AnalyticsSession.start.
function AnalyticsEvents.onPanel(_player: Player, _panel: string) end

local function robuxFor(info: ProductInfo?, id: number, spent: number?): number
	if spent and spent > 0 then
		return spent
	end
	local ok, price = pcall(AnalyticsEvents.livePrice, id, info ~= nil and info.pass)
	if ok and type(price) == "number" and price > 0 then
		return price
	end
	return if info then info.robux else 0
end

local function notePurchase(player: Player, info: ProductInfo?, id: number, spent: number?)
	local profile = DataService.get(player)
	local first = false
	if profile then
		local life = (profile :: any).AnalyticsLife
		local receipts = if type(profile.ProcessedReceipts) == "table" then #profile.ProcessedReceipts else 0
		if type(life) == "table" then
			-- A product's own receipt is already recorded by now.
			local before = if info and not info.pass then receipts - 1 else receipts
			first = (tonumber(life.Purchases) or 0) == 0 and before <= 0
			life.Purchases = (tonumber(life.Purchases) or 0) + 1
		end
	end
	AnalyticsEvents.emit("Purchase", player, {
		key = if info then info.key else tostring(id),
		label = if info then info.label else `#{id}`,
		kind = if info then info.kind else "Unknown",
		pass = info ~= nil and info.pass,
		robux = robuxFor(info, id, spent),
		first = first,
	})
end

--- A GRANTED product receipt (called from the receipt wrapper).
function AnalyticsEvents.productPurchased(player: Player, productId: number, spent: number?)
	local info = AnalyticsEvents.productInfo(productId)
	local funnel = funnelOf(info)
	if funnel then
		kindStep(player, funnel, 3, KIND_STEP_NAMES)
	end
	if info and bossLive(player, info.key) then
		kindStep(player, AnalyticsEvents.BOSS_FUNNEL, 3, BOSS_STEP_NAMES)
		bossOffers[player] = nil
	end
	notePurchase(player, info, productId, spent)
end

--- A gamepass bought through any prompt.
local function passPurchased(player: Player, gamePassId: number)
	local info = AnalyticsEvents.passInfo(gamePassId)
	kindStep(player, "Buy_Pass", 3, KIND_STEP_NAMES)
	notePurchase(player, info, gamePassId, nil)
end

-- ==========================================================
-- ECONOMY
-- ==========================================================

--- Sources paid on every income tick: summed per player and tag, sent in
--- batches ("social" is the friend / Premium boost's share of the tick).
local BATCHED: { [string]: true } = { passive = true, social = true }

type Pending = { amounts: { [string]: number }, balance: number }
local passive: { [Player]: Pending } = {}

local function logEconomy(player: Player, flow: string, amount: number, tag: string, balance: number, currency: string?)
	local prefix = string.match(tag, "^([^:]+)") or tag
	local typeName = if flow == "source"
		then (AnalyticsEvents.SOURCE_TYPES[tag] or "Gameplay")
		else (AnalyticsEvents.SINK_TYPES[prefix] or "Gameplay")
	local kind = transactionType(typeName)
	local flowType = if flow == "source" then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink
	local whole = math.floor(amount)
	local ending = math.floor(balance)
	local name = currency or CURRENCY
	if whole <= 0 then
		return
	end
	send("economy", player, `{flow} {name} {whole} ({kind}, {tag}) -> {ending}`, function()
		AnalyticsService:LogEconomyEvent(player, flowType, name, whole, ending, kind, tag)
	end, { type = "economy", event = name, f1 = `{flow}:{kind}`, f2 = tag, f3 = `bal={ending}`, value = whole })
end

-- ==========================================================
-- [analytics-discord] SPEED ECONOMY
-- ==========================================================
-- Every SpeedPower grant fires ProgressEvents "speedGain" (amount, info
-- { source = tag }) at the line that adds it - the one helper every Speed
-- source goes through. Treadmill ticks ("train") are summed like passive
-- Cash and sent with it; everything else is sent as it happens. The ending
-- balance is read from the profile when the listener runs.

AnalyticsEvents.SPEED_CURRENCY = "Speed"
AnalyticsEvents.SPEED_KIND = "speedGain"
local SPEED_BATCHED: { [string]: true } = { train = true }

type SpeedPending = { amounts: { [string]: number } }
local speedPending: { [Player]: SpeedPending } = {}

local function speedBalance(player: Player): number
	local profile = DataService.get(player)
	return if profile then tonumber(profile.SpeedPower) or 0 else 0
end

local function onSpeedGain(player: Player, amount: number, info: { [string]: any })
	if amount ~= amount or amount <= 0 or amount == math.huge then
		return
	end
	local tag = if type(info.source) == "string" then info.source else "other"
	if NEVER[tag] then
		return
	end
	if SPEED_BATCHED[tag] then
		local pending = speedPending[player]
		if not pending then
			pending = { amounts = {} }
			speedPending[player] = pending
		end
		pending.amounts[tag] = (pending.amounts[tag] or 0) + amount
		return
	end
	logEconomy(player, "source", amount, tag, speedBalance(player), AnalyticsEvents.SPEED_CURRENCY)
end

local function flushSpeed(player: Player)
	local pending = speedPending[player]
	speedPending[player] = nil
	if not pending then
		return
	end
	local balance = speedBalance(player)
	for tag, amount in pending.amounts do
		if amount >= 1 then
			logEconomy(player, "source", amount, tag, balance, AnalyticsEvents.SPEED_CURRENCY)
		end
	end
end

local function flushPassive(player: Player)
	local pending = passive[player]
	passive[player] = nil
	if not pending then
		return
	end
	for tag, amount in pending.amounts do
		if amount >= 1 then
			logEconomy(player, "source", amount, tag, pending.balance)
		end
	end
end

local function onTransaction(player: Player, flow: string, amount: number, tag: string, balance: number)
	if NEVER[tag] then
		return
	end
	if flow == "sink" and string.sub(tag, 1, 8) == "upgrade:" then
		AnalyticsEvents.onboarding(player, "firstUpgrade")
	end
	-- [analytics-discord] A crew assist is paid as "crew" Cash
	-- (CrewService.resolveAssist) - this is the one place that sees it.
	if flow == "source" and tag == "crew" then
		AnalyticsEvents.custom(player, "CrewAssist", math.floor(amount))
	end
	if flow == "source" and BATCHED[tag] then
		local pending = passive[player]
		if not pending then
			pending = { amounts = {}, balance = balance }
			passive[player] = pending
		end
		pending.amounts[tag] = (pending.amounts[tag] or 0) + amount
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
		end, { type = "progression", event = "MuseumZone", f1 = "Start", f2 = tostring(level), f3 = name, value = level })
	end
end

-- ==========================================================
-- DEBUG
-- ==========================================================

function AnalyticsEvents.setDebug(on: boolean)
	debugOn = on
end

--- `filter` (optional, [analytics-discord]): keep only recent events whose
--- text contains it, e.g. "Quit", "Speed", "Buy_", "custom".
function AnalyticsEvents.dump(filter: string?): { [string]: any }
	local shown = recent
	if type(filter) == "string" and filter ~= "" then
		shown = {}
		local needle = string.lower(filter)
		for _, row in recent do
			local text = string.lower(`{row.category} {row.event}`)
			if string.find(text, needle, 1, true) then
				table.insert(shown, row)
			end
		end
	end
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
				out[player.Name] = table.clone(pending.amounts)
			end
			return out
		end)(),
		-- [analytics-discord]
		pendingSpeed = (function()
			local out = {}
			for player, pending in speedPending do
				out[player.Name] = table.clone(pending.amounts)
			end
			return out
		end)(),
		customByName = table.clone(customCount),
		filter = filter,
		recent = table.clone(shown),
	}
end

--- Sends every player's summed passive income (and treadmill Speed) now
--- (debug and leave).
function AnalyticsEvents.flushAll()
	for player in table.clone(passive) do
		flushPassive(player)
	end
	for player in table.clone(speedPending) do
		flushSpeed(player)
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

	-- [analytics-discord] The Speed economy. (Sessions, the quit context and
	-- the core-loop events live in AnalyticsSession, which init starts
	-- right after this and which sets `onPanel`.)
	ProgressEvents.on(AnalyticsEvents.SPEED_KIND, onSpeedGain)

	-- The client's one funnel step. A key from CLIENT_STEPS, nothing else.
	-- [analytics-discord] Plus ("panel", name): the MainUI panel now open,
	-- a name from PolishConfig.ANALYTICS_PANELS, "Other" or "None", on its
	-- own limiter so panel flicking cannot starve the shop step.
	local limiter = RateLimiter.new(PolishConfig.ANALYTICS_CLIENT_PER_SECOND, PolishConfig.ANALYTICS_CLIENT_BURST)
	local panelLimiter = RateLimiter.new(PolishConfig.ANALYTICS_PANEL_PER_SECOND, PolishConfig.ANALYTICS_PANEL_BURST)
	local panelNames: { [string]: true } = { Other = true, None = true }
	for _, name in PolishConfig.ANALYTICS_PANELS do
		panelNames[name] = true
	end
	Remotes.get("AnalyticsClientEvent").OnServerEvent:Connect(function(player, key, argument)
		if key == "panel" then
			if type(argument) ~= "string" or not panelNames[argument] or not panelLimiter:consume(player) then
				return
			end
			AnalyticsEvents.onPanel(player, argument)
			if argument ~= "None" and argument ~= "Other" then
				AnalyticsEvents.panelShown(player, argument)
			end
			return
		end
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
	Remotes.get("PurchaseRequest").OnServerEvent:Connect(function(player, action, argument)
		if type(action) == "string" and PROMPT_ACTIONS[action] then
			AnalyticsEvents.productPrompted(player)
		end
		-- [analytics-discord] The catch offer's BUY press.
		if action == "product" and type(argument) == "string" and bossLive(player, argument) then
			kindStep(player, AnalyticsEvents.BOSS_FUNNEL, 2, BOSS_STEP_NAMES)
		end
	end)
	-- A gamepass bought through any prompt completes the funnel too
	-- (products complete it from the receipt wrapper).
	local MarketplaceService = game:GetService("MarketplaceService")
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, id, purchased)
		if purchased then
			AnalyticsEvents.purchased(player)
		end
		-- [analytics-discord] Per-kind funnel, cancellations, Discord.
		pcall(function()
			local passId = tonumber(id) or 0
			dialogClosed(player, AnalyticsEvents.passInfo(passId) or { key = tostring(passId), kind = "Pass", label = `pass {passId}`, robux = 0, pass = true }, purchased == true)
			if purchased then
				passPurchased(player, passId)
			end
		end)
	end)
	-- [analytics-discord] Every product dialog closing: "prompted" for its
	-- kind, and a PurchaseCancelled when nothing was bought. Grants nothing
	-- (ProcessReceipt is the only authority; see MonetizationService).
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		pcall(function()
			local player = Players:GetPlayerByUserId(userId)
			if player then
				dialogClosed(player, AnalyticsEvents.productInfo(tonumber(productId) or 0), purchased == true)
			end
		end)
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
		flushSpeed(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		funnelSessions[player] = nil
		highestSeen[player] = nil
		limiter:release(player)
		panelLimiter:release(player)
		kindSessions[player] = nil
		bossOffers[player] = nil
		-- onBeforeRelease normally flushed already; this only drops leftovers.
		task.delay(30, function()
			passive[player] = nil
			speedPending[player] = nil
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
