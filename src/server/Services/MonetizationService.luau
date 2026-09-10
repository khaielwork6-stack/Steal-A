--!strict
--[[
	MonetizationService
	Robux Developer Products: prompting them, and granting them exactly once
	(GDD section 21, phase 11).

	Treadmill tiers are Developer Products rather than Gamepasses because each
	purchase advances one tier and is therefore repeatable.

	THE FOUR RULES THIS FILE EXISTS TO ENFORCE

	1. ProcessReceipt is the ONLY authority for a grant.
	   PromptProductPurchaseFinished is deliberately not connected anywhere. It
	   fires on the client's say-so and reports that a purchase *dialog* closed,
	   not that Roblox took the money.

	2. A receipt must be safe to replay.
	   Roblox retries ProcessReceipt until it returns PurchaseGranted - across
	   rejoins and across servers. So the set of granted PurchaseIds lives in the
	   PROFILE, not in memory: an in-memory set would re-grant a receipt that
	   arrives again after a rejoin, handing out a free tier every retry.

	3. An unconfigured product grants nothing.
	   Every id defaults to 0. An unknown or unconfigured id is never guessed at,
	   and the receipt is left OPEN (NotProcessedYet) rather than consumed, so a
	   purchase made against a half-configured build is still granted once the id
	   is filled in. Losing a real purchase is worse than a retry.

	4. A purchase is never silently lost.
	   If the player has already advanced past the tier they bought - they earned
	   it with Cash while the receipt was in flight - they are granted their next
	   eligible tier instead of nothing.

	WHY THE GRANT IS SAVED BEFORE REPORTING SUCCESS
	Returning PurchaseGranted tells Roblox to consume the receipt permanently. If
	the grant is only in memory and the server dies before the autosave, the
	player paid and got nothing, with no receipt left to retry. So the grant is
	written, the profile is saved, and only a successful save reports success.
	A failed save returns NotProcessedYet, and the retry re-drives the save
	because rule 2 already recorded the grant.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local SpeedService = require(script.Parent.SpeedService)
local StateService = require(script.Parent.StateService)

local MonetizationService = {}

--- Receipts are only ever retried for a bounded time, but a player can buy many
--- tiers over a lifetime. Keeping the most recent ids caps profile growth while
--- comfortably covering any realistic retry window.
local RECEIPT_HISTORY = 100

local promptLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.PurchaseRequest)

-- ==========================================================
-- RECEIPT BOOKKEEPING
-- ==========================================================

local function alreadyGranted(profile: DataService.Profile, purchaseId: string): boolean
	for _, id in profile.ProcessedReceipts do
		if id == purchaseId then
			return true
		end
	end
	return false
end

local function rememberGrant(profile: DataService.Profile, purchaseId: string)
	table.insert(profile.ProcessedReceipts, purchaseId)
	while #profile.ProcessedReceipts > RECEIPT_HISTORY do
		table.remove(profile.ProcessedReceipts, 1)
	end
end

-- ==========================================================
-- GAMEPASS OWNERSHIP
-- ==========================================================
--
-- Roblox is the source of truth for a gamepass, but `UserOwnsGamePassAsync` is a
-- web call - it yields, it can throw, and it must never be put anywhere that
-- runs per frame or per training tick. So ownership is cached per player, warmed
-- once on join, and refreshed only when there is a reason to think it changed.
--
-- A FAILED LOOKUP IS NOT A "NO". A network error caches nothing and is retried,
-- because caching a false would silently strip a paying player of what they
-- bought until they rejoined.

local ownership: { [Player]: { [number]: boolean } } = {}

local function ownsCached(player: Player, gamePassId: number): boolean?
	local forPlayer = ownership[player]
	return if forPlayer then forPlayer[gamePassId] else nil
end

--- Blocking check with caching. Safe to call from anywhere that can yield.
function MonetizationService.ownsPass(player: Player, gamePassId: number): boolean
	local cached = ownsCached(player, gamePassId)
	if cached ~= nil then
		return cached
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	if not ok then
		warn(`[MonetizationService] ownership check failed for {player.Name} / {gamePassId}: {owns}`)
		return false -- NOT cached: a transient failure must not become permanent
	end

	local forPlayer = ownership[player]
	if not forPlayer then
		forPlayer = {}
		ownership[player] = forPlayer
	end
	forPlayer[gamePassId] = owns
	return owns
end

--- Non-yielding read for hot paths (the training tick, the movement formula).
--- Returns false for anything not yet warmed rather than blocking on a web call.
function MonetizationService.ownsPassCached(player: Player, gamePassId: number): boolean
	return ownsCached(player, gamePassId) == true
end

--- Re-checks every pass this game sells. Called on join and after a purchase.
function MonetizationService.refreshOwnership(player: Player)
	ownership[player] = ownership[player] or {}
	for _, id in MonetizationConfig.allGamePassIds() do
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
		end)
		if ok then
			ownership[player][id] = owns
		end
	end
	MonetizationService.onOwnershipChanged(player)
end

--- Overridden by init so this service does not have to require the things that
--- care (movement, training, the state push).
function MonetizationService.onOwnershipChanged(_player: Player) end

--- A Game Pass the player has JUST bought in this session, after ownership
--- was re-read from Roblox. Distinct from onOwnershipChanged, which also fires
--- on the join-time warm-up: a purchase is the only moment that should, for
--- example, auto-equip a freshly bought guardian. Overridden by init.
function MonetizationService.onGamePassPurchased(_player: Player, _gamePassId: number) end

--- STUDIO TESTING ONLY. Robux cannot be spent in Studio, so ownership has to be
--- faked to exercise the tier logic at all. Writes to the SERVER's cache, which
--- no client can reach; the debug bridge that calls it does not exist outside
--- Studio (DebugService is guarded by RunService:IsStudio).
function MonetizationService.setOwnedForTesting(player: Player, gamePassId: number, owned: boolean)
	ownership[player] = ownership[player] or {}
	ownership[player][gamePassId] = owned
	MonetizationService.onOwnershipChanged(player)
end

function MonetizationService.clearOwnedForTesting(player: Player)
	ownership[player] = {}
	MonetizationService.onOwnershipChanged(player)
end

-- ==========================================================
-- LIVE PRICES
-- ==========================================================
--
-- The Creator Dashboard is the only place a Robux price is decided. Every
-- guardian sign, offer card, storage card and steal prompt shows the
-- PriceInRobux Roblox returns for the pass or product - never a number
-- typed into a config. `robux` on the config rows is a display fallback for
-- the second or two before the first lookup lands, and what the debug
-- report compares against.
--
-- Fetched once at start and every PRICE_REFRESH seconds after, in pcall: a
-- failed lookup keeps the last good value (or the fallback) and nothing
-- else notices.

local livePrices: { [string]: number } = {}
local PRICE_REFRESH = 600

--- Called whenever a refresh changed at least one price. Wired by init to
--- re-text the world signs and prompts and re-push every client.
function MonetizationService.onPricesChanged() end

local function fetchPrice(id: number, infoType: Enum.InfoType): number?
	if id <= 0 then
		return nil
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(id, infoType)
	end)
	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
		return info.PriceInRobux
	end
	return nil
end

function MonetizationService.livePassPrice(gamePassId: number): number?
	return livePrices[`pass:{gamePassId}`]
end

function MonetizationService.liveProductPrice(productId: number): number?
	return livePrices[`product:{productId}`]
end

function MonetizationService.refreshLivePrices(): boolean
	local changed = false
	local function record(key: string, price: number?)
		if price ~= nil and livePrices[key] ~= price then
			livePrices[key] = price
			changed = true
		end
	end
	for _, pass in MonetizationConfig.GuardianPasses do
		record(`pass:{pass.gamePassId}`, fetchPrice(pass.gamePassId, Enum.InfoType.GamePass))
	end
	record(`pass:{MonetizationConfig.SlapPass.gamePassId}`, fetchPrice(MonetizationConfig.SlapPass.gamePassId, Enum.InfoType.GamePass))
	for _, product in MonetizationConfig.StealProducts do
		record(`product:{product.productId}`, fetchPrice(product.productId, Enum.InfoType.Product))
	end
	if changed then
		MonetizationService.onPricesChanged()
	end
	return changed
end

--- Every live price beside the price the brief intended, for the handoff
--- report and the debug bridge. A mismatch is a Creator Dashboard change,
--- never a code one.
function MonetizationService.livePriceReport(): { [string]: any }
	local rows = {}
	for _, pass in MonetizationConfig.GuardianPasses do
		rows[pass.key .. "Pass"] = { live = MonetizationService.livePassPrice(pass.gamePassId), intended = pass.robux }
	end
	rows.SlapPass = { live = MonetizationService.livePassPrice(MonetizationConfig.SlapPass.gamePassId), intended = MonetizationConfig.SlapPass.robux }
	for _, product in MonetizationConfig.StealProducts do
		rows[product.key] = { live = MonetizationService.liveProductPrice(product.productId), intended = product.robux }
	end
	return rows
end

-- ==========================================================
-- BASE GUARDIANS AND THE SLAP
-- ==========================================================

function MonetizationService.ownsGuardian(player: Player, key: string): boolean
	local pass = MonetizationConfig.GuardianPassByKey[key]
	return pass ~= nil and MonetizationService.ownsPassCached(player, pass.gamePassId)
end

function MonetizationService.ownsSlap(player: Player): boolean
	return MonetizationService.ownsPassCached(player, MonetizationConfig.SlapPass.gamePassId)
end

--- Delivers a `Steal` receipt against the exact reserved item; installed by
--- init (setStealHandler, below). Declared here because processReceipt,
--- further down, reads it.
local stealHandler: ((Player, DataService.Profile, MonetizationConfig.ProductDef, string) -> boolean)? = nil
local revealHandler: ((Player, DataService.Profile, MonetizationConfig.ProductDef, string) -> boolean)? = nil

-- ==========================================================
-- WHAT OWNERSHIP BUYS
-- ==========================================================

--- A. The permanent treadmill-training multiplier: the HIGHEST owned tier, not
--- the sum and not the product of the ones below it. Owning 2x, 4x and 8x is 8x.
function MonetizationService.speedMultiplier(player: Player): number
	local best = 1
	for _, tier in MonetizationConfig.SpeedMultiplierPasses do
		if MonetizationService.ownsPassCached(player, tier.gamePassId) then
			best = math.max(best, tier.multiplier)
		end
	end
	return best
end

--- The tier the shop should offer next, or nil once they own the top one.
function MonetizationService.nextSpeedTier(player: Player): MonetizationConfig.PassTier?
	return MonetizationConfig.nextSpeedTier(MonetizationService.speedMultiplier(player))
end

--- 2x on gameplay-generated Cash only.
function MonetizationService.cashMultiplier(player: Player): number
	return if MonetizationService.ownsPassCached(player, MonetizationConfig.CashPass.gamePassId)
		then MonetizationConfig.CashPass.multiplier
		else 1
end

--- Whether a trail is unlocked by its Robux gamepass. The cash route is stored
--- in the profile instead - see TrailService.
function MonetizationService.ownsTrailPass(player: Player, trailKey: string): boolean
	local trail = MonetizationConfig.TrailByKey[trailKey]
	if not trail or not trail.gamePassId then
		return false
	end
	return MonetizationService.ownsPassCached(player, trail.gamePassId)
end

-- ==========================================================
-- TREADMILL PRODUCTS
-- ==========================================================

--- The treadmill level a product key is meant to grant.
local function levelForProductKey(key: string): number?
	for _, tier in TreadmillConfig.Tiers do
		if tier.robuxProductKey == key then
			return tier.level
		end
	end
	return nil
end

--- Which level this purchase actually grants, given where the player is NOW.
---
--- The answer is always "the tier you are next in line for", never the tier
--- named on the product. That single rule covers every case:
---   * Normal purchase - the UI only ever sells the next tier, so they match.
---   * They earned the tier with Cash while the receipt was in flight: they get
---     the one after it instead of nothing (rule 4).
---   * A malformed or out-of-order purchase cannot skip tiers to jump ahead.
--- `intended` is therefore only used to prove the product maps to a real tier.
local function resolveGrantLevel(current: number): number?
	if current >= TreadmillConfig.MAX_LEVEL then
		return nil -- genuinely maxed; nothing left to give
	end
	return current + 1
end

--- The product a player would buy right now, or nil if there is nothing to sell
--- (maxed out, or that tier has no configured id).
function MonetizationService.nextTreadmillProduct(player: Player): (number?, string?, number?)
	local profile = DataService.get(player)
	if not profile then
		return nil, nil, nil
	end
	local tier = TreadmillConfig.nextTier(profile.TreadmillLevel)
	if not tier or not tier.robuxProductKey then
		return nil, nil, nil
	end
	local id = MonetizationConfig.productIdFor(tier.robuxProductKey)
	return id, tier.robuxProductKey, tier.level
end

-- ==========================================================
-- PROMPTING
-- ==========================================================

--- Opens the Robux dialog for the player's next treadmill tier.
---
--- The client asks for "the next tier" and never names a product id, so a
--- tampered client cannot make the game prompt for an arbitrary product; and an
--- unconfigured id prompts nothing at all rather than opening a broken dialog.
function MonetizationService.promptTreadmillUpgrade(player: Player): (boolean, string?)
	if not promptLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local productId, _, level = MonetizationService.nextTreadmillProduct(player)
	if not level then
		return false, "Your treadmill is fully upgraded!"
	end
	if not productId then
		-- Unconfigured. The button should already be hidden; this is the guard
		-- for a client that asked anyway.
		return false, "That upgrade is not available yet."
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId :: number)
	end)
	if not ok then
		warn(`[MonetizationService] PromptProductPurchase failed for {player.Name}: {err}`)
		return false, "Could not open the purchase."
	end
	return true
end

-- ==========================================================
-- PROCESS RECEIPT
-- ==========================================================

--- Public so the Studio debug bridge can deliver a synthetic receipt: a real
--- Robux purchase cannot be made in Studio, and the replay/unconfigured/
--- already-maxed paths are exactly the ones that must be proven.
function MonetizationService.processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local granted = Enum.ProductPurchaseDecision.PurchaseGranted
	local pending = Enum.ProductPurchaseDecision.NotProcessedYet

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- They left before it landed. Left open so it is granted on their next
		-- join rather than consumed while they are gone.
		return pending
	end

	local profile = DataService.get(player)
	if not profile then
		return pending -- still loading; retry shortly
	end

	local purchaseId = tostring(receiptInfo.PurchaseId)

	-- Rule 2. Also the path a save-retry takes: the grant is already applied, so
	-- all that is left is to get it persisted.
	if alreadyGranted(profile, purchaseId) then
		if not DataService.isPersistent() or DataService.save(player) then
			return granted
		end
		return pending
	end

	-- Rule 3. ONE lookup table for every product the game sells - Cash packs,
	-- direct Speed grants and treadmill tiers all arrive here.
	local product = MonetizationConfig.ProductById[receiptInfo.ProductId]
	if not product then
		warn(
			`[MonetizationService] product {receiptInfo.ProductId} is not in MonetizationConfig - `
				.. `receipt left OPEN for {player.Name}. Paste the id in and it will grant.`
		)
		return pending
	end

	-- The grant itself. Dispatched on the product's own `kind`, so adding a
	-- product is a config row rather than another branch in ProcessReceipt.
	if product.kind == "Cash" then
		-- FACE VALUE. The 2x Cash pass multiplies EARNINGS, never a purchased
		-- pack - doubling this would be handing the player something they did
		-- not buy, and halving the value of the pass they might buy later.
		EconomyService.award(player, product.amount, "product")
		rememberGrant(profile, purchaseId)
		StateService.notify(player, "success", `+{NumberFormat.short(product.amount)} CASH!`, "levelup")

	elseif product.kind == "Speed" then
		-- A DIRECT GRANT, not a rate. Never scaled by the permanent multiplier
		-- or by a trail: those multiply what you EARN, and this is a quantity.
		profile.SpeedPower += product.amount
		SpeedService.applyMovement(player)
		rememberGrant(profile, purchaseId)
		StateService.notify(player, "success", `+{NumberFormat.short(product.amount)} SPEED!`, "levelup")

	elseif product.kind == "TreadmillTier" then
		-- Rule 4: always the tier they are NEXT in line for, never the one named
		-- on the product, so a purchase in flight while they earned it with Cash
		-- still gives them something.
		local level = resolveGrantLevel(profile.TreadmillLevel)
		if not level then
			warn(
				`[MonetizationService] {player.Name} bought tier {product.amount} while already maxed. `
					.. `Receipt left OPEN rather than consumed.`
			)
			StateService.notify(player, "error", "You are already fully upgraded - contact support.")
			return pending
		end
		if not SpeedService.grantTreadmillTier(player, level) then
			warn(`[MonetizationService] grant of tier {level} refused for {player.Name} - receipt left open.`)
			return pending
		end
		rememberGrant(profile, purchaseId)
		local tier = TreadmillConfig.tier(level)
		StateService.notify(
			player,
			"success",
			`Treadmill {if tier then tier.name else level}! Thanks for the support.`,
			"levelup"
		)

	elseif product.kind == "Reveal" then
		-- Delivered only against the container the buyer selected. A receipt
		-- with nothing to deliver yet is left OPEN for Roblox to retry rather
		-- than consumed for nothing (HatchService.fulfil explains each case).
		if not revealHandler then
			warn(`[MonetizationService] reveal receipt from {player.Name} with no handler installed - left open.`)
			return pending
		end
		if not revealHandler(player, profile, product, purchaseId) then
			return pending
		end
		rememberGrant(profile, purchaseId)

	elseif product.kind == "Steal" then
		-- Delivered only against the exact item the buyer reserved. Anything
		-- less - target gone, wrong rarity, no reservation - leaves the receipt
		-- OPEN for Roblox to retry rather than consuming a paid purchase for
		-- nothing (HeistService.fulfil explains each case as it happens).
		if not stealHandler then
			warn(`[MonetizationService] steal receipt from {player.Name} with no handler installed - left open.`)
			return pending
		end
		if not stealHandler(player, profile, product, purchaseId) then
			return pending
		end
		rememberGrant(profile, purchaseId)

	else
		warn(`[MonetizationService] product "{product.key}" has unknown kind "{product.kind}" - receipt left open.`)
		return pending
	end

	StateService.pushNow(player)

	-- Tell the UI which card just paid off, so it can flash the right one. Sent
	-- only from here - the single path that actually granted something - so the
	-- animation cannot fire on a cancelled or failed purchase.
	Remotes.get("PurchaseFeedback"):FireClient(player, product.key)

	-- Only report success once the grant is durable.
	if not DataService.isPersistent() or DataService.save(player) then
		return granted
	end

	warn(`[MonetizationService] granted tier {level} to {player.Name} but the save failed; will retry.`)
	return pending
end

-- ==========================================================
-- PROMPTING
-- ==========================================================
--
-- THE CLIENT NEVER NAMES AN ID. Every one of these takes a KEY that the server
-- looks up in its own config, so a tampered client can ask to buy "Cash200K" but
-- cannot make the game prompt for an arbitrary product or gamepass.

--- A Cash or Speed Developer Product, by config key.
function MonetizationService.promptProduct(player: Player, key: string): (boolean, string?)
	if not promptLimiter:consume(player) then
		return false, "Slow down!"
	end
	local product = MonetizationConfig.ProductByKey[key]
	if not product or product.productId <= 0 then
		return false, "That item is not available yet."
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, product.productId)
	end)
	if not ok then
		warn(`[MonetizationService] PromptProductPurchase failed for {player.Name}: {err}`)
		return false, "Could not open the purchase."
	end
	return true
end

--- A gamepass, by id. Shared by the speed tiers, the cash pass and the trails.
local function promptPass(player: Player, gamePassId: number): (boolean, string?)
	if not promptLimiter:consume(player) then
		return false, "Slow down!"
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, gamePassId)
	end)
	if not ok then
		warn(`[MonetizationService] PromptGamePassPurchase failed for {player.Name}: {err}`)
		return false, "Could not open the purchase."
	end
	return true
end

--- The NEXT speed tier, and only that one. The server re-derives which tier that
--- is from live ownership, so a client asking for 1024x while owning nothing
--- gets prompted for 2x.
function MonetizationService.promptNextSpeedTier(player: Player): (boolean, string?)
	local tier = MonetizationService.nextSpeedTier(player)
	if not tier then
		return false, "You already own the maximum Speed multiplier!"
	end
	return promptPass(player, tier.gamePassId)
end

function MonetizationService.promptCashPass(player: Player): (boolean, string?)
	if MonetizationService.ownsPassCached(player, MonetizationConfig.CashPass.gamePassId) then
		return false, "You already own 2x Cash!"
	end
	return promptPass(player, MonetizationConfig.CashPass.gamePassId)
end

function MonetizationService.promptTrailPass(player: Player, trailKey: string): (boolean, string?)
	local trail = MonetizationConfig.TrailByKey[trailKey]
	if not trail or not trail.gamePassId then
		return false, "That trail has no Robux option."
	end
	if MonetizationService.ownsPassCached(player, trail.gamePassId) then
		return false, "You already own that trail."
	end
	return promptPass(player, trail.gamePassId)
end

--- The guardian ON SALE RIGHT NOW, and only that one: the server derives it
--- from the rotation clock, so a client cannot ask for a different animal.
--- WHICH GUARDIANS ARE ACTUALLY ON SALE. Injected by init from
--- GuardianShopService, which owns the pedestals; nil until it starts, and
--- the rotation is the fallback so the shop UI path keeps working either way.
local onSaleKeys: (() -> { string })? = nil

function MonetizationService.setGuardianSaleProvider(fn: () -> { string })
	onSaleKeys = fn
end

--- The guardian keys the pedestals are actually selling right now. Exposed so
--- a caller can PICK one rather than having to guess a key and be refused;
--- `promptGuardianPass` still re-checks whatever comes back, so this is a
--- convenience and never the authority. Empty until the shop has started.
function MonetizationService.guardiansOnSale(): { string }
	return if onSaleKeys then onSaleKeys() else {}
end

--- Opens the Robux dialog for a guardian on sale.
---
--- `key` comes from the PEDESTAL a player walked up to (a server-side
--- ProximityPrompt trigger), never from a client, and is checked against the
--- live on-sale list regardless - so an unlisted or stale key cannot open a
--- dialog even if some future caller passes one in. Omitting it keeps the
--- old behaviour of selling whatever the rotation says.
function MonetizationService.promptGuardianPass(player: Player, key: string?): (boolean, string?)
	local wanted = key or BaseGuardianConfig.rotation(workspace:GetServerTimeNow())
	if key and onSaleKeys then
		local allowed = false
		for _, onSale in onSaleKeys() do
			if onSale == key then
				allowed = true
				break
			end
		end
		if not allowed then
			return false, "That Guardian is not on sale right now."
		end
	end
	local pass = MonetizationConfig.GuardianPassByKey[wanted]
	if not pass or pass.gamePassId <= 0 then
		return false, "That Guardian is not available yet."
	end
	if MonetizationService.ownsPassCached(player, pass.gamePassId) then
		return false, `You already own the {pass.label}! Equip it in Storage.`
	end
	return promptPass(player, pass.gamePassId)
end

function MonetizationService.promptSlapPass(player: Player): (boolean, string?)
	local pass = MonetizationConfig.SlapPass
	if pass.gamePassId <= 0 then
		return false, "The Slap is not available yet."
	end
	if MonetizationService.ownsPassCached(player, pass.gamePassId) then
		return false, "You already own the Slap! Equip it in Storage > WEAPONS."
	end
	return promptPass(player, pass.gamePassId)
end

-- ==========================================================
-- BASE STEALING RECEIPTS
-- ==========================================================
--
-- A `Steal` product is delivered by HeistService, which knows which exact
-- item the buyer reserved. Injected from init rather than required, so this
-- service never depends on the base systems it sells into. (The handler
-- variable itself is declared up with the ownership helpers, ahead of
-- processReceipt, which reads it.)

function MonetizationService.setStealHandler(fn: (Player, DataService.Profile, MonetizationConfig.ProductDef, string) -> boolean)
	stealHandler = fn
end

--- A `Reveal` product is delivered by HatchService, which knows which exact
--- container the buyer selected. Injected for the same reason as the steal
--- handler.
function MonetizationService.setRevealHandler(fn: (Player, DataService.Profile, MonetizationConfig.ProductDef, string) -> boolean)
	revealHandler = fn
end

--- MarketplaceService.PromptProductPurchaseFinished, forwarded. NOTHING IS
--- GRANTED THROUGH THIS. It exists so a reservation can be released the
--- moment a player backs out of a steal dialog; see HeistService.
function MonetizationService.onProductPromptClosed(_player: Player, _productId: number, _purchased: boolean) end

-- ==========================================================
-- THE BOSS-LOSS OFFER
-- ==========================================================
--
-- Shown when a zone's guardian catches a thief mid-chase, and ONLY then.
--
-- It is driven from `GuardianService`'s catch handler - the one path that means
-- "you were carrying loot and the chase beat you". It is deliberately NOT hooked
-- to Humanoid.Died, to touching a guardian, to resetting, to falling, or to
-- dropping an item on purpose: none of those are the failure this offer answers,
-- and firing on them would turn a purchase prompt into noise.

local lastOfferAt: { [Player]: number } = {}

--- Fires the contextual offer for `zoneIndex`, if there is one and the player is
--- not still inside the cooldown.
function MonetizationService.offerAfterCatch(player: Player, zoneIndex: number)
	local key = MonetizationConfig.BossOfferByZone[zoneIndex]
	if not key then
		-- No configured offer for this zone. Zone 12 is deliberately in this
		-- state: no price was specified for it, and inventing one for real money
		-- is not a gap to fill with a guess.
		return
	end

	local product = MonetizationConfig.ProductByKey[key]
	if not product or product.productId <= 0 then
		return
	end

	local now = os.clock()
	local last = lastOfferAt[player]
	if last and now - last < MonetizationConfig.BOSS_OFFER_COOLDOWN then
		return -- caught again straight away; the offer is least welcome now
	end
	lastOfferAt[player] = now

	Remotes.get("BossOffer"):FireClient(player, {
		productKey = product.key,
		amount = product.amount,
		label = product.label,
		robux = product.robux,
		zoneIndex = zoneIndex,
	})
end

function MonetizationService.start()
	-- Deliberately the ONLY grant path for PRODUCTS. PromptProductPurchaseFinished
	-- is not connected: it reports a closed dialog, not a completed transaction.
	MarketplaceService.ProcessReceipt = MonetizationService.processReceipt

	-- Gamepasses are different, and this is NOT the same mistake. Nothing is
	-- granted here: the event only triggers a re-check, and the answer comes from
	-- UserOwnsGamePassAsync - Roblox - not from the client's claim.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, id, purchased)
		if purchased then
			task.spawn(function()
				MonetizationService.refreshOwnership(player)
				-- Only AFTER Roblox has confirmed ownership: whoever listens
				-- (the guardian auto-equip) re-checks ownsPassCached itself.
				MonetizationService.onGamePassPurchased(player, id)
			end)
		end
	end)

	-- Products: the dialog closing is forwarded and NOTHING is granted from
	-- it. The one consumer (HeistService) uses `purchased == false` to free a
	-- reserved item; a `true` is ignored there too, because ProcessReceipt
	-- is the only thing that knows Roblox took the money.
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		local player = Players:GetPlayerByUserId(userId)
		if player then
			MonetizationService.onProductPromptClosed(player, productId, purchased == true)
		end
	end)

	Remotes.get("PurchaseRequest").OnServerEvent:Connect(function(player, action, argument)
		if type(action) ~= "string" then
			return
		end

		local ok, reason
		if action == "treadmill" then
			ok, reason = MonetizationService.promptTreadmillUpgrade(player)
		elseif action == "speedTier" then
			ok, reason = MonetizationService.promptNextSpeedTier(player)
		elseif action == "cashPass" then
			ok, reason = MonetizationService.promptCashPass(player)
		elseif action == "product" and type(argument) == "string" then
			ok, reason = MonetizationService.promptProduct(player, argument)
		elseif action == "guardian" then
			ok, reason = MonetizationService.promptGuardianPass(player)
		elseif action == "slap" then
			ok, reason = MonetizationService.promptSlapPass(player)
		else
			return
		end

		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
	end)

	-- Warm ownership once per player rather than asking Roblox on demand.
	local function warm(player: Player)
		task.spawn(MonetizationService.refreshOwnership, player)
	end
	for _, player in Players:GetPlayers() do
		warm(player)
	end
	Players.PlayerAdded:Connect(warm)
	Players.PlayerRemoving:Connect(function(player)
		ownership[player] = nil
		lastOfferAt[player] = nil
		promptLimiter:release(player)
	end)

	-- Live prices: once now, then on a slow cadence. A web call, so never on
	-- the main path of anything.
	task.spawn(function()
		MonetizationService.refreshLivePrices()
		while true do
			task.wait(PRICE_REFRESH)
			MonetizationService.refreshLivePrices()
		end
	end)

	local configured = 0
	for key in MonetizationConfig.Products do
		if MonetizationConfig.isConfigured(key) then
			configured += 1
		end
	end
	print(`[MonetizationService] receipts online - {configured} product id(s) configured`)
end

return MonetizationService
