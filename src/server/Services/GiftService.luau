--!strict
--[[
	GiftService
	Buying a Cash or Speed pack FOR another player in the server
	(trading-gifting-boards pass).

	THE FLOW
	  1. The buyer picks a recipient and a gift pack in the Shop. The client
	     sends GiftRequest(recipientUserId, giftKey).
	  2. This service checks the recipient (in this server, loaded, not the
	     buyer), REMEMBERS "buyer -> recipient, pack" for
	     TradeConfig.GIFT_INTENT_SECONDS, and only then opens the Robux dialog
	     (MonetizationService.promptGiftProduct).
	  3. Roblox calls ProcessReceipt on the BUYER. MonetizationService's Gift
	     branch calls `deliver` below, and records the receipt on the buyer's
	     profile like any other purchase.

	HOW THE GIFT IS DELIVERED
	  * With a remembered recipient: through MailboxService, ALWAYS - online
	    in this server, in another server, or gone. Mail is durable before
	    the buyer's receipt is consumed, and its id is fixed per purchase
	    ("gift_<PurchaseId>"), so a receipt replayed after a crash queues
	    nothing twice and the recipient's DeliveredMail makes the grant
	    exactly-once. A recipient in this server gets it within a moment
	    (MailboxService delivers immediately to online players).
	      Cash  = the RECIPIENT's scaled pack amount at receipt time
	              (MonetizationService.cashPackAmount) when they are still in
	              this server; otherwise the amount the buyer was shown when
	              they picked them.
	      Speed = the pack's amount.
	  * With no remembered recipient (the server restarted between the prompt
	    and the receipt, the intent lapsed, or the receipt is for another
	    pack): the pack goes to the BUYER, exactly like a normal purchase,
	    and the buyer is told why.

	POLICY: gift packs are plain Cash/Speed - not random, not tradable items -
	so they are offered wherever purchases are.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TradeConfig = require(ReplicatedStorage.Shared.Config.TradeConfig)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local MailboxService = require(script.Parent.MailboxService)
local MonetizationService = require(script.Parent.MonetizationService)
local SpeedService = require(script.Parent.SpeedService)
local StateService = require(script.Parent.StateService)

local GiftService = {}

export type Intent = {
	recipientUserId: number,
	recipientName: string,
	productKey: string,
	--- The Cash the buyer was shown for the recipient (0 for Speed).
	shownAmount: number,
	at: number,
}

--- buyer userId -> what they are buying and for whom. Keyed by user id, not
--- Player, so a receipt that lands after a quick rejoin to the SAME server
--- still finds it.
local intents: { [number]: Intent } = {}

local limiter = RateLimiter.new(TradeConfig.GIFT_PER_SECOND, TradeConfig.GIFT_BURST)

local function packOf(product: MonetizationConfig.ProductDef): MonetizationConfig.ProductDef?
	local key = product.giftOf
	local pack = if key then MonetizationConfig.ProductByKey[key] else nil
	if pack and (pack.kind == "Cash" or pack.kind == "Speed") then
		return pack
	end
	return nil
end

--- What `pack` pays `recipient` right now (their scaled Cash amount).
local function amountFor(pack: MonetizationConfig.ProductDef, recipient: Player?, fallback: number): number
	if pack.kind == "Cash" then
		if recipient and DataService.get(recipient) then
			return MonetizationService.cashPackAmount(recipient, pack)
		end
		return math.max(math.floor(fallback), pack.amount)
	end
	return pack.amount
end

--- The Shop's view: which gift packs exist and what each would give a
--- chosen recipient. Asked per recipient, so it is not on StatePush.
function GiftService.quote(recipient: Player): { [string]: number }
	local out: { [string]: number } = {}
	for _, product in MonetizationConfig.GiftProducts do
		local pack = packOf(product)
		if pack then
			out[product.key] = amountFor(pack, recipient, pack.amount)
		end
	end
	return out
end

--- Step 2: remember the recipient, then open the dialog.
function GiftService.request(buyer: Player, recipient: Player, productKey: string): (boolean, string?)
	local product = MonetizationConfig.ProductByKey[productKey]
	if not product or product.kind ~= "Gift" then
		return false, nil
	end
	local pack = packOf(product)
	if not pack then
		return false, "That gift isn't available."
	end
	if product.productId <= 0 then
		return false, "Gifting is coming soon!"
	end
	if recipient == buyer then
		return false, "Pick someone else to gift to."
	end
	if not DataService.get(buyer) then
		return false, "Your data is still loading."
	end
	if not recipient.Parent or not DataService.get(recipient) then
		return false, `{recipient.DisplayName} isn't ready to receive gifts yet.`
	end
	intents[buyer.UserId] = {
		recipientUserId = recipient.UserId,
		recipientName = recipient.DisplayName,
		productKey = product.key,
		shownAmount = amountFor(pack, recipient, pack.amount),
		at = os.time(),
	}
	return MonetizationService.promptGiftProduct(buyer, product.key)
end

--- The remembered recipient for this receipt, consumed. nil = none (or it
--- was for a different pack, or it lapsed).
local function takeIntent(buyer: Player, product: MonetizationConfig.ProductDef): Intent?
	local intent = intents[buyer.UserId]
	if not intent then
		return nil
	end
	if intent.productKey ~= product.key or os.time() - intent.at > TradeConfig.GIFT_INTENT_SECONDS then
		return nil
	end
	intents[buyer.UserId] = nil
	return intent
end

--- Step 3: MonetizationService's delivery handler. Contract: (delivered,
--- "retry"?). Never "undeliverable": with no recipient the buyer gets it.
function GiftService.deliver(buyer: Player, profile: DataService.Profile, product: MonetizationConfig.ProductDef, purchaseId: string): (boolean, string?)
	local pack = packOf(product)
	if not pack then
		warn(`[GiftService] {product.key} has no valid giftOf pack - receipt left open`)
		return false, "retry"
	end

	local found = takeIntent(buyer, product)
	local toSelf = found ~= nil and found.recipientUserId == buyer.UserId and not GiftService.allowSelfForTesting
	if found == nil or toSelf then
		-- NO RECIPIENT ON RECORD: the buyer keeps what they paid for. Granted
		-- the same way the ordinary pack is (the receipt id is recorded by
		-- the caller, so a replay cannot grant it twice).
		if pack.kind == "Cash" then
			local amount = MonetizationService.cashPackAmount(buyer, pack)
			EconomyService.award(buyer, amount, "product")
			StateService.notify(
				buyer,
				"success",
				`We couldn't tell who your gift was for, so you received {NumberFormat.cash(amount)} yourself.`,
				"levelup"
			)
		else
			profile.SpeedPower += pack.amount
			require(script.Parent.ProgressEvents).fire(buyer, "speedGain", pack.amount, { source = "product" }) -- [analytics-discord]
			SpeedService.applyMovement(buyer)
			StateService.notify(
				buyer,
				"success",
				`We couldn't tell who your gift was for, so you received +{NumberFormat.short(pack.amount)} Speed yourself.`,
				"levelup"
			)
		end
		return true, nil
	end

	local intent: Intent = found :: Intent
	local recipient = Players:GetPlayerByUserId(intent.recipientUserId)
	local amount = amountFor(pack, recipient, intent.shownAmount)
	local sent = MailboxService.send(intent.recipientUserId, {
		kind = if pack.kind == "Cash" then "cash" else "speed",
		amount = amount,
		source = "gift",
		note = `a gift from {buyer.DisplayName}`,
		id = `gift_{purchaseId}`,
	} :: any)
	if not sent then
		-- Put the intent back so the retry still knows the recipient.
		intents[buyer.UserId] = intent
		warn(`[GiftService] mail to {intent.recipientUserId} failed for receipt {purchaseId} - left open`)
		return false, "retry"
	end

	local what = if pack.kind == "Cash" then NumberFormat.cash(amount) else `+{NumberFormat.short(amount)} Speed`
	StateService.notify(buyer, "success", `Your gift of {what} was sent to {intent.recipientName}!`, "levelup")
	if not recipient then
		-- They left: it waits in their mailbox for their next join.
		StateService.notify(buyer, "info", `{intent.recipientName} left, so it will arrive when they next play.`)
	end
	return true, nil
end

--- Studio only: lets the debug command gift to its own caller (solo Studio
--- has nobody else) so the mailbox path can be exercised.
GiftService.allowSelfForTesting = false

--- Studio only: set or clear a buyer's intent directly.
function GiftService.debugSetIntent(buyer: Player, intent: Intent?)
	if intent then
		intents[buyer.UserId] = intent
	else
		intents[buyer.UserId] = nil
	end
end

function GiftService.debugIntent(buyer: Player): Intent?
	return intents[buyer.UserId]
end

function GiftService.anyConfigured(): boolean
	for _, product in MonetizationConfig.GiftProducts do
		if product.productId > 0 then
			return true
		end
	end
	return false
end

function GiftService.start()
	MonetizationService.setGiftHandler(GiftService.deliver)

	Remotes.get("GiftRequest").OnServerEvent:Connect(function(buyer, recipientUserId, productKey)
		if not limiter:consume(buyer) then
			return
		end
		local userId = Validate.integer(recipientUserId, 1, 2 ^ 53)
		if not userId or type(productKey) ~= "string" or #productKey > 64 then
			return
		end
		local recipient = Players:GetPlayerByUserId(userId)
		if not recipient then
			StateService.notify(buyer, "error", "That player isn't in this server any more.")
			return
		end
		local ok, reason = GiftService.request(buyer, recipient, productKey)
		if not ok and reason then
			StateService.notify(buyer, "error", reason)
		end
	end)

	-- One boolean on StatePush: whether the Shop should show its Gift
	-- section at all. The recipient's exact Cash amount is deliberately not
	-- pushed (it changes with THEIR income every second); the card says the
	-- pack scales with the recipient's income, and the buyer's toast names
	-- the figure that was sent.
	StateService.addProvider("gifts", function(_player: Player): any
		return { enabled = GiftService.anyConfigured() }
	end)

	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
		-- The intent is kept: a receipt may still land after a quick rejoin.
		-- Lapsed ones are pruned below.
	end)
	task.spawn(function()
		while true do
			task.wait(60)
			local cutoff = os.time() - TradeConfig.GIFT_INTENT_SECONDS
			for userId, intent in intents do
				if intent.at < cutoff then
					intents[userId] = nil
				end
			end
		end
	end)

	print(`[GiftService] gifting {if GiftService.anyConfigured() then "online" else "waiting for product ids"}`)
end

return GiftService
