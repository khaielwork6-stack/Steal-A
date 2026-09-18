--!strict
--[[
	DebugCommands.Monetization
	Studio-only test commands for the 2026-09-17 monetization pass. Loaded by
	DebugService (which only runs in Studio); invoke through
	ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...).

	EVERY COMMAND THAT CHANGES A PROFILE PUTS IT BACK, EVEN ON ERROR. Studio
	with API access writes to the owner's REAL DataStore, and processReceipt
	saves as part of its contract - so each test snapshots what it touches,
	runs inside pcall, restores the snapshot whatever happened, and saves the
	restored profile again when saves are live. (EconomyService's per-session
	"awarded by source" tally is not restored: it is never saved.)

	  monPacks                     the caller's live Cash-pack amounts
	  monFallback [path] [mode]    the undeliverable-receipt conversion.
	                               path: "treadmill" | "steal" | "reveal" | "all"
	                               mode: "stub" (default) forces the handler to
	                               answer "undeliverable"; "real" uses the
	                               installed handler with no reservation (a
	                               fallback once HeistService/HatchService
	                               return the two-value contract, a left-open
	                               receipt before that)
	  monPrompt <key>              promptProduct for a key: Steal*/Reveal*/
	                               TreadmillTier* must be refused
	  monOffer [zone] [speed] [fire]
	                               which Speed pack the boss offer picks; with
	                               fire=true the cooldown is reset and it fires
	  monPolicy [restrict|allow|real]
	                               pin or re-fetch the PolicyService answer
	  monWheel                     the caller's live wedge labels vs the print
	  monActivity [idle|active|auto]
	                               pin the spin clock idle/active, or release it
	  monSpinCrash [index]         spend a spin without landing it, then run the
	                               reload path twice: must pay exactly once
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)

local DataService = require(script.Parent.Parent.DataService)
local MonetizationService = require(script.Parent.Parent.MonetizationService)
local SpinWheelService = require(script.Parent.Parent.SpinWheelService)
local StateService = require(script.Parent.Parent.StateService)

--- A deep copy of the plain-data parts of a profile a test may touch.
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

type Snapshot = { [string]: any }

local SNAPSHOT_FIELDS = {
	"Cash",
	"SpeedPower",
	"TreadmillLevel",
	"ProcessedReceipts",
	"PendingSteal",
	"PendingReveal",
	"PendingSpinPrize",
	"SpinProgress",
	"GuardiansWon",
	"EquippedGuardian",
	"Lifetime",
}

local function snapshot(profile: DataService.Profile): Snapshot
	local snap: Snapshot = {}
	for _, field in SNAPSHOT_FIELDS do
		snap[field] = copy((profile :: any)[field])
	end
	return snap
end

local function restore(player: Player, profile: DataService.Profile, snap: Snapshot)
	for _, field in SNAPSHOT_FIELDS do
		(profile :: any)[field] = copy(snap[field])
	end
	StateService.pushNow(player)
	if DataService.isPersistent() then
		DataService.save(player)
	end
end

--- Runs `body` against the caller's profile and ALWAYS restores it.
local function withRestore(player: Player, body: (DataService.Profile) -> any): any
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	local snap = snapshot(profile)
	local ok, result = pcall(body, profile)
	restore(player, profile, snap)
	if not ok then
		return { error = tostring(result), restored = true }
	end
	return result
end

local function receipt(player: Player, product: MonetizationConfig.ProductDef, tag: string): any
	return {
		PlayerId = player.UserId,
		ProductId = product.productId,
		PurchaseId = `debug-fallback-{tag}-{os.clock()}`,
		-- Zero: the conversion then falls back to the live/config price.
		CurrencySpent = 0,
		CurrencyType = Enum.CurrencyType.Robux,
		PlaceIdWherePurchased = game.PlaceId,
	}
end

--- One fallback path. Returns what the receipt decided and what it paid.
local function runFallback(player: Player, profile: DataService.Profile, path: string, mode: string): { [string]: any }
	local product: MonetizationConfig.ProductDef? = nil
	if path == "treadmill" then
		product = MonetizationConfig.ProductByKey["TreadmillTier9"]
		profile.TreadmillLevel = TreadmillConfig.MAX_LEVEL
	elseif path == "steal" then
		product = MonetizationConfig.StealProducts[1]
		profile.PendingSteal = nil
	elseif path == "reveal" then
		product = MonetizationConfig.RevealProducts[1]
		profile.PendingReveal = nil
	end
	if not product then
		return { error = `unknown path "{path}"` }
	end

	local realSteal, realReveal = MonetizationService.debugHandlers()
	local stub = function(...: any): (boolean, string)
		return false, "undeliverable"
	end
	if mode ~= "real" then
		if path == "steal" then
			MonetizationService.setStealHandler(stub)
		elseif path == "reveal" then
			MonetizationService.setRevealHandler(stub)
		end
	end

	local cashBefore = profile.Cash
	local info = receipt(player, product, path)
	local ok, decision = pcall(MonetizationService.processReceipt, info)

	-- The real handlers go back whatever happened.
	if realSteal then
		MonetizationService.setStealHandler(realSteal)
	end
	if realReveal then
		MonetizationService.setRevealHandler(realReveal)
	end
	if not ok then
		return { path = path, error = tostring(decision) }
	end

	-- Replay: the same receipt again must be granted without paying twice.
	local cashAfterFirst = profile.Cash
	local replay = MonetizationService.processReceipt(info)
	return {
		path = path,
		mode = mode,
		decision = (decision :: Enum.ProductPurchaseDecision).Name,
		paid = cashAfterFirst - cashBefore,
		expectedPaid = MonetizationConfig.fallbackCash(
			MonetizationService.liveProductPrice(product.productId) or product.robux,
			MonetizationService.baseIncome(player)
		),
		receiptRecorded = table.find(profile.ProcessedReceipts, info.PurchaseId) ~= nil,
		replayDecision = replay.Name,
		-- Passive income keeps ticking while the replay waits on its save, so a
		-- small delta is expected; a second payout would be at least the fallback.
		replayDelta = profile.Cash - cashAfterFirst,
		replayPaidAgain = profile.Cash - cashAfterFirst >= (cashAfterFirst - cashBefore) / 2,
	}
end

local commands: { [string]: (Player, ...any) -> any } = {}

commands.monPacks = function(player: Player)
	local rows = {}
	for _, product in MonetizationConfig.CashProducts do
		table.insert(rows, {
			key = product.key,
			robux = product.robux,
			printed = product.label,
			pays = product.amount,
			amountNow = MonetizationService.cashPackAmount(player, product),
		})
	end
	return {
		baseIncome = MonetizationService.baseIncome(player),
		cashMultiplier = MonetizationService.cashMultiplier(player),
		packs = rows,
	}
end

commands.monFallback = function(player: Player, path: any, mode: any)
	local wanted = if type(path) == "string" then path else "all"
	local how = if mode == "real" then "real" else "stub"
	return withRestore(player, function(profile)
		if wanted == "all" then
			local out = {}
			for _, name in { "treadmill", "steal", "reveal" } do
				out[name] = runFallback(player, profile, name, how)
			end
			return out
		end
		return runFallback(player, profile, wanted, how)
	end)
end

commands.monPrompt = function(player: Player, key: any)
	if type(key) ~= "string" then
		return { error = "pass a product key, e.g. StealCommon" }
	end
	local product = MonetizationConfig.ProductByKey[key]
	local ok, reason = MonetizationService.promptProduct(player, key)
	return {
		key = key,
		kind = if product then product.kind else nil,
		opened = ok,
		reason = reason,
		expectOpened = product ~= nil and (product.kind == "Cash" or product.kind == "Speed"),
	}
end

commands.monOffer = function(player: Player, zoneIndex: any, speed: any, fire: any)
	local profile = DataService.get(player)
	local zone = math.clamp(math.floor(tonumber(zoneIndex) or 1), 1, 12)
	local power = tonumber(speed) or (if profile then profile.SpeedPower else 0)
	local product = MonetizationConfig.bossOfferFor(zone, power)
	local fired = false
	if fire == true or fire == "fire" then
		MonetizationService.debugResetOfferCooldown(player)
		-- The live path reads the profile's own Speed, not `speed`.
		MonetizationService.offerAfterCatch(player, zone)
		fired = true
	end
	return {
		zone = zone,
		speed = power,
		offered = if product then product.key else "none",
		robux = if product then product.robux else nil,
		cooldown = MonetizationConfig.BOSS_OFFER_COOLDOWN,
		fired = fired,
	}
end

commands.monPolicy = function(player: Player, mode: any)
	if mode == "restrict" then
		MonetizationService.setPolicyForTesting(player, true)
	elseif mode == "allow" then
		MonetizationService.setPolicyForTesting(player, false)
	elseif mode == "real" then
		MonetizationService.setPolicyForTesting(player, nil)
	end
	local policy = MonetizationService.policy(player)
	return {
		known = policy.known,
		paidRandomRestricted = policy.paidRandomItemsRestricted,
		paidTradingAllowed = policy.paidItemTradingAllowed,
		raw = policy.raw,
	}
end

commands.monWheel = function(player: Player)
	return SpinWheelService.debugLabels(player)
end

commands.monActivity = function(player: Player, mode: any)
	return SpinWheelService.debugSetActivity(player, if type(mode) == "string" then mode else nil)
end

commands.monSpinCrash = function(player: Player, index: any)
	-- A Cash wedge by default: a guardian wedge would grant an animal, which
	-- the snapshot restores in the profile but not in the live bay.
	local wanted = math.clamp(math.floor(tonumber(index) or 1), 1, 12)
	return withRestore(player, function(profile)
		local cashBefore, speedBefore = profile.Cash, profile.SpeedPower
		local spent = SpinWheelService.debugSpendWithoutLanding(player, wanted)
		if spent.error then
			return spent
		end
		-- No yield between the spend and the reload path, so the clock tick
		-- cannot pay it first.
		local first = SpinWheelService.payLeftover(player)
		local second = SpinWheelService.payLeftover(player)
		return {
			saved = spent.saved,
			firstPayout = first,
			secondPayout = second,
			paidExactlyOnce = first ~= nil and second == nil,
			cashDelta = profile.Cash - cashBefore,
			speedDelta = profile.SpeedPower - speedBefore,
			pendingCleared = profile.PendingSpinPrize == nil,
		}
	end)
end

return commands
