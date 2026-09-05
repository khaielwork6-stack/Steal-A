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

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)

local DataService = require(script.Parent.DataService)
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
	if not profile.BaseActivated then
		return false, "Activate your base first."
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

	-- Rule 3.
	local key = MonetizationConfig.keyForProductId(receiptInfo.ProductId)
	if not key then
		warn(
			`[MonetizationService] product {receiptInfo.ProductId} is not in MonetizationConfig - `
				.. `receipt left OPEN for {player.Name}. Paste the id in and it will grant.`
		)
		return pending
	end

	local intended = levelForProductKey(key)
	if not intended then
		warn(`[MonetizationService] product key "{key}" maps to no treadmill tier - receipt left open.`)
		return pending
	end

	-- Rule 4.
	local level = resolveGrantLevel(profile.TreadmillLevel)
	if not level then
		warn(
			`[MonetizationService] {player.Name} bought tier {intended} while already maxed. `
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

	-- Only report success once the grant is durable.
	if not DataService.isPersistent() or DataService.save(player) then
		return granted
	end

	warn(`[MonetizationService] granted tier {level} to {player.Name} but the save failed; will retry.`)
	return pending
end

function MonetizationService.start()
	-- Deliberately the ONLY grant path. PromptProductPurchaseFinished is not
	-- connected: it reports a closed dialog, not a completed transaction.
	MarketplaceService.ProcessReceipt = MonetizationService.processReceipt

	Remotes.get("PurchaseRequest").OnServerEvent:Connect(function(player, action)
		if action ~= "treadmill" then
			return
		end
		local ok, reason = MonetizationService.promptTreadmillUpgrade(player)
		if not ok and reason then
			StateService.notify(player, "error", reason)
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
