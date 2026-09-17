--!strict
--[[
	DebugCommands.Trade
	Studio-only test commands for the trading-gifting-boards pass. Loaded by
	DebugService (Studio only); invoke through
	ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...).

	A REAL TRADE NEEDS TWO PLAYERS: use Studio's Test tab -> Clients and
	Servers -> 2 players (Team Test works too). Solo Play has one player, so
	`tradeSim` runs the SAME swap functions TradeService uses (TradeLogic)
	against the caller's real profile and a synthetic in-memory second
	profile, then puts the caller's Inventory and Cash back - even on error -
	and saves the restored profile. Nothing in the test yields between the
	swap and the restore, so no autosave can catch the half-way state.

	  tradeStatus                 availability, open windows, recent logs
	  tradeSim                    the swap + every refusal, solo (restores)
	  tradeSkipGrace [name]       skip the 30 s join grace for a player
	  tradeOpen <nameA> <nameB>   (2 players) skip both graces, A asks B, B
	                              accepts: the window opens on both screens
	  tradeLogs                   the last trade records this server wrote
	  giftSim [cash|speed] [path] a gift receipt through ProcessReceipt.
	                              path "self": the mailbox path, gifting to
	                              yourself; "none": no recipient remembered,
	                              so the buyer is granted; "all" (default):
	                              both. Takes back exactly what it paid.
	  boardStatus                 board placement, week, your scores
	  boardRefresh                submit + repaint now, then boardStatus
	  boardWeeklyTest             passive vs product Cash on the weekly
	                              count (restores Cash and the weekly count)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoardConfig = require(ReplicatedStorage.Shared.Config.BoardConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)

local Services = script.Parent.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local GiftService = require(Services.GiftService)
local LeaderboardService = require(Services.LeaderboardService)
local MailboxService = require(Services.MailboxService)
local MonetizationService = require(Services.MonetizationService)
local SpeedService = require(Services.SpeedService)
local StateService = require(Services.StateService)
local TradeLogic = require(Services.TradeLogic)
local TradeService = require(Services.TradeService)

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

--- A revealed stored item of `itemId`, reconciled like a load would.
local function makeItem(itemId: string, hatched: boolean?): any
	local def = LootConfig.ById[itemId]
	local item: any = {
		InstanceId = HttpService:GenerateGUID(false),
		ItemId = itemId,
		ZoneId = LootConfig.ZoneOf[itemId],
		Rarity = if def then def.rarity else "Common",
		Size = "Normal",
		Mutation = "Normal",
		BaseIncome = if def then def.income else 1,
		FinalIncome = if def then def.income else 1,
		SlotIndex = 0,
		Scale = 1,
		Hatched = true,
	}
	DataService.reconcileItem(item)
	if hatched == false then
		item.Hatched = false
		item.HatchEndsAt = os.time() + 60
	end
	return item
end

local function firstItemId(zone: number, position: number): string
	return LootConfig.pool(zone)[position].id
end

local function findPlayer(name: any): Player?
	if type(name) ~= "string" then
		return nil
	end
	for _, player in Players:GetPlayers() do
		if player.Name == name or player.DisplayName == name then
			return player
		end
	end
	return nil
end

local commands: { [string]: (Player, ...any) -> any } = {}

commands.tradeStatus = function(player: Player)
	return TradeService.status(player)
end

commands.tradeSkipGrace = function(player: Player, name: any)
	local target = findPlayer(name) or player
	TradeService.debugSkipJoinGrace(target)
	return TradeService.status(target)
end

commands.tradeLogs = function(_player: Player)
	return TradeService.recentLogs()
end

commands.tradeOpen = function(_player: Player, nameA: any, nameB: any)
	local a, b = findPlayer(nameA), findPlayer(nameB)
	if not a or not b or a == b then
		return {
			error = "pass two different player names in this server",
			note = "a real trade needs two players: Test tab -> Clients and Servers -> 2 players",
			players = #Players:GetPlayers(),
		}
	end
	TradeService.debugSkipJoinGrace(a)
	TradeService.debugSkipJoinGrace(b)
	local asked, askReason = TradeService.request(a, b)
	if not asked then
		return { asked = false, reason = askReason }
	end
	local accepted, acceptReason = TradeService.respond(b, a, "accept")
	return { asked = asked, accepted = accepted, reason = acceptReason, status = TradeService.status(a) }
end

--- THE SOLO SWAP TEST. See the header.
commands.tradeSim = function(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	local savedInventory = copy(profile.Inventory)
	local savedCash = profile.Cash
	local steps: { string } = {}
	local failures: { string } = {}
	local function expect(label: string, ok: boolean, detail: any?)
		local line = `{if ok then "PASS" else "FAIL"} {label}{if detail ~= nil then " (" .. tostring(detail) .. ")" else ""}`
		table.insert(steps, line)
		if not ok then
			table.insert(failures, line)
		end
	end

	-- Everything below runs without a yield, then the restore runs.
	local ran, err = pcall(function()
		-- The caller: two known items of their own plus a sealed container,
		-- and a fixed Cash balance, on top of whatever they store already.
		local mine = makeItem(firstItemId(1, 1))
		local mineToo = makeItem(firstItemId(1, 2))
		local sealed = makeItem(firstItemId(1, 3), false)
		-- Room for the test items even in a full storage: the capacity
		-- check is exercised separately on the synthetic side.
		while #profile.Inventory > StorageConfig.capacityForTier(profile.StorageTier) - 3 and #profile.Inventory > 0 do
			table.remove(profile.Inventory)
		end
		table.insert(profile.Inventory, mine)
		table.insert(profile.Inventory, mineToo)
		table.insert(profile.Inventory, sealed)
		profile.Cash = 1000

		-- The synthetic partner. Its item deliberately SHARES an InstanceId
		-- with the caller's second item, to prove the receiver re-ids it.
		local theirs = makeItem(firstItemId(2, 8))
		theirs.InstanceId = mineToo.InstanceId
		local partner: any = { Cash = 500, Inventory = { theirs }, DisplayItems = {}, StorageTier = 0 }

		local empty = TradeLogic.emptyOffer()
		local function offer(items: { string }, cash: number): TradeLogic.Offer
			return { items = items, cash = cash }
		end

		-- Refusals: nothing may change on any of these.
		local ok, why = TradeLogic.validate(profile :: any, offer({ sealed.InstanceId }, 0), partner, empty)
		expect("a sealed container is refused", not ok, why)
		ok, why = TradeLogic.validate(profile :: any, offer({ "not-an-item" }, 0), partner, empty)
		expect("an item you don't own is refused", not ok, why)
		ok, why = TradeLogic.validate(profile :: any, offer({ mine.InstanceId, mine.InstanceId }, 0), partner, empty)
		expect("the same item twice is refused", not ok, why)
		ok, why = TradeLogic.validate(profile :: any, offer({}, 1001), partner, empty)
		expect("more Cash than you have is refused", not ok, why)
		ok, why = TradeLogic.validate(profile :: any, offer({}, 0.5), partner, empty)
		expect("fractional Cash is refused", not ok, why)
		ok, why = TradeLogic.validate(profile :: any, empty, partner, empty)
		expect("an empty trade is refused", not ok, why)
		local seven = {}
		for _ = 1, 7 do
			table.insert(seven, mine.InstanceId)
		end
		ok, why = TradeLogic.validate(profile :: any, offer(seven, 0), partner, empty)
		expect("more than MAX_ITEMS is refused", not ok, why)

		-- Capacity: a partner with a full storage cannot take an extra item.
		local full: any = { Cash = 0, Inventory = {}, DisplayItems = {}, StorageTier = 0 }
		for _ = 1, StorageConfig.capacityForTier(0) do
			table.insert(full.Inventory, makeItem(firstItemId(1, 1)))
		end
		local before = #profile.Inventory
		local done, fullWhy = TradeLogic.execute(profile :: any, offer({ mine.InstanceId }, 0), full, empty)
		expect("a full partner storage is refused", not done, fullWhy)
		expect("a refused execute changes nothing", #profile.Inventory == before and profile.Cash == 1000 and #full.Inventory == StorageConfig.capacityForTier(0))
		-- ...but an even swap into a full storage is fine.
		local evenOk = TradeLogic.validate(profile :: any, offer({ mine.InstanceId }, 0), full, offer({ full.Inventory[1].InstanceId }, 0))
		expect("a one-for-one swap into a full storage is allowed", evenOk)

		-- Lopsided warning.
		expect("lopsided: 1000 for 10 warns", TradeLogic.lopsided(1000, 10))
		expect("lopsided: 100 for 90 does not", not TradeLogic.lopsided(100, 90))

		-- THE SWAP: caller gives `mine` + $100, partner gives `theirs` + $40.
		local swapped, swapWhy, result = TradeLogic.execute(profile :: any, offer({ mine.InstanceId }, 100), partner, offer({ theirs.InstanceId }, 40))
		expect("the swap executes", swapped, swapWhy)
		if swapped then
			expect("caller Cash is 1000 - 100 + 40", profile.Cash == 940, profile.Cash)
			expect("partner Cash is 500 - 40 + 100", partner.Cash == 560, partner.Cash)
			expect("caller no longer has the item given", TradeLogic.findStored(profile :: any, mine.InstanceId) == nil)
			expect("partner has the caller's item", TradeLogic.findStored(partner, mine.InstanceId) ~= nil)
			-- `execute` moves the very same table across.
			expect("caller received the partner's item", table.find(profile.Inventory, theirs) ~= nil)
			expect("a clashing InstanceId was replaced", theirs.InstanceId ~= mineToo.InstanceId)
			expect("the received item is stored, not displayed", theirs.SlotIndex == 0)
			expect("partner no longer has its item", #partner.Inventory == 1)
			expect("the result names both sides' items", result and #result.aGave == 1 and #result.bGave == 1)
		end
	end)

	-- RESTORE, whatever happened.
	profile.Inventory = savedInventory
	profile.Cash = savedCash
	StateService.pushNow(player)
	local saved = if DataService.isPersistent() then DataService.save(player) else "memory mode"

	if not ran then
		table.insert(failures, `ERROR {err}`)
	end
	return {
		passed = ran and #failures == 0,
		steps = steps,
		failures = failures,
		restored = true,
		savedAfterRestore = saved,
		note = "solo test of TradeLogic; a real two-player trade needs Clients and Servers -> 2 players (tradeOpen)",
	}
end

--- One synthetic gift receipt. `path`: "self" or "none".
local function giftOnce(player: Player, profile: DataService.Profile, product: MonetizationConfig.ProductDef, path: string): { [string]: any }
	local fakeId = -(910000 + math.random(1, 9999))
	local purchaseId = `debug-gift-{path}-{HttpService:GenerateGUID(false)}`
	local info = {
		PlayerId = player.UserId,
		ProductId = fakeId,
		PurchaseId = purchaseId,
		CurrencySpent = 0,
		CurrencyType = Enum.CurrencyType.Robux,
		PlaceIdWherePurchased = game.PlaceId,
	}
	local function tally(): number
		local bySource = EconomyService.awardedBySource(player)
		return (bySource.gift or 0) + (bySource.product or 0)
	end
	local cashBefore, speedBefore = tally(), profile.SpeedPower

	MonetizationConfig.ProductById[fakeId] = product
	if path == "self" then
		GiftService.allowSelfForTesting = true
		GiftService.debugSetIntent(player, {
			recipientUserId = player.UserId,
			recipientName = player.DisplayName,
			productKey = product.key,
			shownAmount = 0,
			at = os.time(),
		})
	else
		GiftService.debugSetIntent(player, nil)
	end

	local ok, decision = pcall(MonetizationService.processReceipt, info)
	-- The mailbox path delivers on its own thread: wait for it to land.
	if ok and path == "self" then
		local deadline = os.clock() + 15
		while tally() == cashBefore and profile.SpeedPower == speedBefore and os.clock() < deadline do
			MailboxService.deliver(player)
			task.wait(0.5)
		end
	end
	local paidCash = tally() - cashBefore
	local paidSpeed = profile.SpeedPower - speedBefore
	local replay = if ok then MonetizationService.processReceipt(info) else nil
	task.wait(1)
	local paidAgain = (tally() - cashBefore) ~= paidCash or (profile.SpeedPower - speedBefore) ~= paidSpeed

	MonetizationConfig.ProductById[fakeId] = nil
	GiftService.allowSelfForTesting = false
	GiftService.debugSetIntent(player, nil)

	-- Take back exactly what this receipt paid.
	local cashNow = tally() - cashBefore
	profile.Cash = math.max(0, profile.Cash - cashNow)
	profile.Lifetime.CashEarned = math.max(0, profile.Lifetime.CashEarned - cashNow)
	profile.SpeedPower = speedBefore
	local index = table.find(profile.ProcessedReceipts, purchaseId)
	if index then
		table.remove(profile.ProcessedReceipts, index)
	end
	SpeedService.applyMovement(player)

	return {
		path = path,
		product = product.key,
		decision = if ok then (decision :: Enum.ProductPurchaseDecision).Name else tostring(decision),
		paidCash = paidCash,
		paidSpeed = paidSpeed,
		receiptRecordedOnBuyer = index ~= nil,
		replayDecision = if replay then replay.Name else nil,
		replayPaidAgain = paidAgain,
		deliveredViaMail = path == "self" and table.find(profile.DeliveredMail, `gift_{purchaseId}`) ~= nil,
		expected = if path == "self"
			then "decision PurchaseGranted, paid > 0, deliveredViaMail, no replay payment"
			else "decision PurchaseGranted, paid > 0 to the buyer (with a 'couldn't tell who' toast), no replay payment",
	}
end

commands.giftSim = function(player: Player, kind: any, path: any)
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	local key = if kind == "speed" then "GiftSpeed150K" else "GiftCash24K"
	local product = MonetizationConfig.ProductByKey[key]
	if not product then
		return { error = `no {key} product` }
	end
	local wanted: { string } = if path == "self" or path == "none" then { path :: string } else { "self", "none" }
	local out: { [string]: any } = {}
	local ran, err = pcall(function()
		for _, name in wanted do
			out[name] = giftOnce(player, profile, product, name)
		end
	end)
	GiftService.allowSelfForTesting = false
	StateService.pushNow(player)
	out.savedAfterRestore = if DataService.isPersistent() then DataService.save(player) else "memory mode"
	if not ran then
		out.error = tostring(err)
	end
	out.note = "the gift's mail id stays in DeliveredMail on purpose (it is what stops a re-grant)"
	return out
end

commands.boardStatus = function(player: Player)
	return LeaderboardService.status(player)
end

commands.boardRefresh = function(player: Player)
	LeaderboardService.refreshNow()
	return LeaderboardService.status(player)
end

commands.boardWeeklyTest = function(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	local savedWeekly = copy(profile.WeeklyEarned)
	local cashBefore, earnedBefore = profile.Cash, profile.Lifetime.CashEarned
	local report: { [string]: any } = {}
	local ran, err = pcall(function()
		-- A save from an earlier week counts from 0 (the first award resets it).
		local sameWeek = type(profile.WeeklyEarned) == "table" and profile.WeeklyEarned.Week == BoardConfig.isoWeek(os.time())
		local start = if sameWeek then profile.WeeklyEarned.Amount else 0
		EconomyService.award(player, 100, "passive")
		report.afterPassive = profile.WeeklyEarned.Amount - start
		EconomyService.award(player, 100, "product")
		report.afterProduct = profile.WeeklyEarned.Amount - start
		report.week = profile.WeeklyEarned.Week
	end)
	-- Restore: the 200 test dollars and the weekly count. Income that landed
	-- meanwhile is kept (only the test amounts are removed).
	profile.Cash = math.max(0, profile.Cash - 200)
	profile.Lifetime.CashEarned = math.max(0, profile.Lifetime.CashEarned - 200)
	profile.WeeklyEarned = savedWeekly
	StateService.pushNow(player)
	if not ran then
		report.error = tostring(err)
	end
	report.passed = ran and report.afterPassive == 100 and report.afterProduct == 100
	-- Only passive income that landed during the test (normally 0-2 ticks).
	report.cashChangeDuringTest = profile.Cash - cashBefore
	report.earnedChangeDuringTest = profile.Lifetime.CashEarned - earnedBefore
	report.weeklyRestored = profile.WeeklyEarned
	return report
end

return commands
