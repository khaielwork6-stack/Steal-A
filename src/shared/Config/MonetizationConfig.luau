--!strict
--[[
	MonetizationConfig
	EVERY Robux id in the game, in one place. Nothing else may hardcode one.

	== THE TWO PURCHASE TYPES ==

	GAMEPASSES are permanent ownership. Checked with UserOwnsGamePassAsync,
	prompted with PromptGamePassPurchase. Roblox is the source of truth; we cache
	the answer rather than storing it as the only record.

	DEVELOPER PRODUCTS are repeatable. Prompted with PromptProductPurchase and
	granted ONLY from MarketplaceService.ProcessReceipt. `PromptProductPurchaseFinished`
	reports that a dialog closed, not that Roblox took the money, and is
	deliberately not connected anywhere in this codebase.

	== THE THREE SPEED SYSTEMS ARE NOT THE SAME THING ==

	Architected separately on purpose, and they must never be collapsed:

	  A. SpeedMultiplierPasses - permanent gamepass tiers, 2x -> 1024x.
	     SEQUENTIAL: the shop only ever offers the next one up.
	     NON-STACKING: the highest owned tier IS the multiplier, it is not a
	     product or a sum of the ones below it.
	     Multiplies TREADMILL TRAINING GAIN only.

	  B. SpeedProducts - direct one-off grants of +150K / +1M / +10M / +1B.
	     Added to the saved stat verbatim. NEVER multiplied by A or C: they are
	     a quantity of Speed, not a rate.

	  C. Trails - the equipped trail's multiplier. Exactly one equipped at a
	     time, so tiers replace rather than add. Multiplies the effective Speed
	     used for MOVEMENT, not the saved stat and not training gain.

	Cash has the same split: `CashPass` (2x) multiplies GAMEPLAY EARNINGS only,
	while `CashProducts` grant their advertised amount untouched - doubling a
	purchased currency pack would be selling the player something they did not
	buy. (Since the 2026-09-17 monetization pass the advertised amount SCALES
	with the buyer's income - see CASH PACKS - but the shop shows that exact
	figure before the purchase, and the pass still never touches it.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local MonetizationConfig = {}

-- ==========================================================
-- GAMEPASSES
-- ==========================================================

export type PassTier = {
	key: string,
	gamePassId: number,
	robux: number, -- display fallback only; GetProductInfo is the authority
	multiplier: number,
	label: string,
}

--- A. Permanent treadmill-training multiplier, in ascending order. The ORDER IS
--- THE PROGRESSION - `nextSpeedTier` walks it - so never reorder or insert into
--- the middle without meaning to change what players are offered next.
MonetizationConfig.SpeedMultiplierPasses = {
	{ key = "Speed2x", gamePassId = 1967491456, robux = 3, multiplier = 2, label = "2x" },
	{ key = "Speed4x", gamePassId = 1968498983, robux = 9, multiplier = 4, label = "4x" },
	{ key = "Speed8x", gamePassId = 1969562880, robux = 24, multiplier = 8, label = "8x" },
	{ key = "Speed16x", gamePassId = 1967233457, robux = 39, multiplier = 16, label = "16x" },
	{ key = "Speed32x", gamePassId = 1969518915, robux = 79, multiplier = 32, label = "32x" },
	{ key = "Speed64x", gamePassId = 1967653417, robux = 129, multiplier = 64, label = "64x" },
	{ key = "Speed128x", gamePassId = 1969378923, robux = 199, multiplier = 128, label = "128x" },
	{ key = "Speed256x", gamePassId = 1967695187, robux = 299, multiplier = 256, label = "256x" },
	{ key = "Speed512x", gamePassId = 1969450870, robux = 499, multiplier = 512, label = "512x" },
	{ key = "Speed1024x", gamePassId = 1969656725, robux = 649, multiplier = 1024, label = "1,024x" },
} :: { PassTier }

--- 2x on gameplay-generated Cash. Never on purchased Cash packs.
MonetizationConfig.CashPass = {
	key = "Cash2x",
	gamePassId = 1969188928,
	robux = 339,
	multiplier = 2,
	label = "2x Cash",
}

-- ==========================================================
-- BASE GUARDIANS AND THE SLAP
-- ==========================================================

export type SimplePass = {
	key: string,
	gamePassId: number,
	--- Display fallback ONLY while the live price is still loading. The
	--- brief supplied 399 for the guardians and the pass listings said 299;
	--- neither is typed into any UI: MonetizationService.livePrices asks
	--- Roblox and every sign, card and prompt shows that answer.
	robux: number,
	label: string,
}

--- One permanent pass per animal. Which of the four is on sale right now is
--- BaseGuardianConfig.rotation's business; owning one is forever.
MonetizationConfig.GuardianPasses = {
	{ key = "Cat", gamePassId = 1969207802, robux = 399, label = "Cat Guardian" },
	{ key = "Dog", gamePassId = 1970751473, robux = 399, label = "Dog Guardian" },
	{ key = "Panda", gamePassId = 1970769517, robux = 399, label = "Panda Guardian" },
	{ key = "Tiger", gamePassId = 1970601554, robux = 399, label = "Tiger Guardian" },
} :: { SimplePass }

MonetizationConfig.GuardianPassByKey = {} :: { [string]: SimplePass }
for _, def in MonetizationConfig.GuardianPasses do
	MonetizationConfig.GuardianPassByKey[def.key] = def
end

--- The Slap weapon. A permanent pass, sold from the lobby cage and the
--- right-side offer, both through the same prompt.
MonetizationConfig.SlapPass = { key = "Slap", gamePassId = 1968935748, robux = 29, label = "Slap" } :: SimplePass

-- [retention-quests-pass] The season pass premium track. PLACEHOLDER id 0:
-- while it is 0 the premium row shows "COMING SOON", nothing on it can be
-- claimed and no purchase can be opened. The owner creates the pass on the
-- Creator Dashboard and pastes its id here. One pass per season: a new
-- season needs a NEW pass (and a new id here), or last season's buyers
-- would own the new premium track.
MonetizationConfig.SeasonPremiumPass = {
	key = "SeasonPremium",
	gamePassId = 1982246812,
	robux = 199,
	label = "Season Pass Premium",
} :: SimplePass

-- ==========================================================
-- TRAILS
-- ==========================================================

export type TrailDef = {
	key: string,
	name: string,
	rarity: string,
	multiplier: number,
	cash: number,
	gamePassId: number?, -- nil = cash-only (Grey)
	robux: number?,
	--- Painted card artwork asset id. Present only on trails that have moved to
	--- the PNG card workflow; absent means the pack-built card.
	image: number?,
	color: Color3,
	accent: Color3,
}

--- C. Cosmetic + a movement multiplier. Cash and Robux are ALTERNATIVE routes to
--- the same permanent unlock, not a two-step purchase.
---
--- `rarity` deliberately reuses the game's own ten-tier rarity vocabulary
--- (RarityConfig.Order) so trail cards inherit the colours and language the
--- player already reads on loot.
--- `image` is the painted card's IMAGE asset id (never a purchase id). Its
--- crop and button hitboxes live in PngUiConfig under `Trail_<key>`; a trail
--- without an image, or without a PngUiConfig entry, keeps the pack-built
--- card. Every trail has one now; the field stays optional for the next one.
MonetizationConfig.Trails = {
	{ key = "Grey", name = "Grey Trail", rarity = "Common", multiplier = 1.5, cash = 100,
		image = 127721075493076,
		color = Color3.fromRGB(206, 212, 222), accent = Color3.fromRGB(150, 158, 172) },
	{ key = "Green", name = "Green Trail", rarity = "Uncommon", multiplier = 2, cash = 5e3,
		gamePassId = 1970564658, robux = 14,
		image = 111545352261958,
		color = Color3.fromRGB(96, 220, 118), accent = Color3.fromRGB(46, 160, 70) },
	{ key = "Blue", name = "Blue Trail", rarity = "Rare", multiplier = 2.5, cash = 75e3,
		gamePassId = 1970224666, robux = 25,
		image = 104546791326408,
		color = Color3.fromRGB(74, 156, 255), accent = Color3.fromRGB(28, 92, 190) },
	{ key = "Purple", name = "Purple Trail", rarity = "Epic", multiplier = 3, cash = 1.5e6,
		gamePassId = 1970678645, robux = 39,
		image = 113372749804594,
		color = Color3.fromRGB(180, 106, 255), accent = Color3.fromRGB(112, 48, 190) },
	{ key = "Golden", name = "Golden Trail", rarity = "Legendary", multiplier = 3.5, cash = 30e6,
		gamePassId = 1967863183, robux = 59,
		image = 134326224195619,
		color = Color3.fromRGB(255, 200, 62), accent = Color3.fromRGB(196, 130, 16) },
	{ key = "Red", name = "Red Trail", rarity = "Mythic", multiplier = 4, cash = 750e6,
		gamePassId = 1968528982, robux = 89,
		image = 91087636120554,
		color = Color3.fromRGB(255, 78, 78), accent = Color3.fromRGB(176, 26, 32) },
	{ key = "Galaxy", name = "Galaxy Trail", rarity = "Cosmic", multiplier = 5, cash = 20e9,
		gamePassId = 1969586881, robux = 145,
		image = 80929775598758,
		color = Color3.fromRGB(72, 240, 226), accent = Color3.fromRGB(120, 60, 220) },
	{ key = "Secret", name = "Secret Trail", rarity = "Secret", multiplier = 7, cash = 500e9,
		gamePassId = 1969036894, robux = 255,
		image = 134542331964427,
		color = Color3.fromRGB(255, 74, 140), accent = Color3.fromRGB(60, 10, 48) },
	{ key = "Eternal", name = "Eternal Trail", rarity = "Eternal", multiplier = 10, cash = 12.5e12,
		gamePassId = 1966214537, robux = 435,
		image = 94938242410097,
		color = Color3.fromRGB(255, 238, 150), accent = Color3.fromRGB(120, 220, 255) },
	{ key = "Divine", name = "Divine Trail", rarity = "Divine", multiplier = 14, cash = 300e12,
		gamePassId = 1962656850, robux = 719,
		image = 133374673004187,
		color = Color3.fromRGB(255, 255, 255), accent = Color3.fromRGB(255, 214, 120) },
} :: { TrailDef }

-- ==========================================================
-- DEVELOPER PRODUCTS
-- ==========================================================

export type ProductDef = {
	key: string,
	productId: number,
	robux: number,
	--- What the grant handler does with it. `amount` is Cash or Speed depending
	--- on `kind`; a treadmill tier ignores it; a Steal delivers the reserved
	--- item in the matching INCOME band (HeistService) and carries no amount.
	kind: "Cash" | "Speed" | "TreadmillTier" | "Steal" | "Reveal" | "Gift",
	amount: number,
	label: string,
	--- Steal products only: the highest per-second income this tier covers.
	--- The cheapest tier whose ceiling covers the item is the one charged.
	maxIncome: number?,
	--- Steal products only: the rarity word this tier was NAMED after. It is
	--- a label for the shop and nothing else - the price is chosen by
	--- `maxIncome`, never by this (see STEAL PRODUCTS).
	rarity: string?,
	--- Reveal products only: the longest remaining wait, in seconds, this
	--- tier covers. The cheapest tier that covers the wait is the one offered.
	maxRemainingSeconds: number?,
	--- Cash products only: the pack pays at least this many minutes of the
	--- buyer's base income (see CASH PACKS). `amount` is the floor.
	incomeMinutes: number?,
	--- Gift products only: the key of the Cash or Speed pack this buys FOR
	--- another player (trading-gifting-boards pass; see GIFT PACKS).
	giftOf: string?,
	--- Gadget products only: the GadgetConfig key this refills, or "All" for
	--- the bundle. See GADGET REFILLS.
	gadgetKey: string?,
}

-- ==========================================================
-- GADGET REFILLS
-- ==========================================================
--
-- Gadgets are Cash consumables (GadgetConfig); these are the Robux route to
-- the same stock, for a player who would rather not grind for them. Each
-- product FILLS that gadget to its `maxCarried` rather than adding one, so
-- there is no reason to buy the same thing three times in a row, and the
-- bundle fills all three.
--
-- NOTHING HERE IS EXCLUSIVE. Every gadget is still buyable with Cash at the
-- stand and in the Shop; this only skips the earning. A refill bought while
-- already full is converted to Cash rather than swallowed (UNDELIVERABLE
-- RECEIPTS), and the buttons disable themselves at the limit anyway.
--
-- PLACEHOLDER IDS. `productId = 0` means "not created yet":
-- `isConfigured` is false, the buttons stay hidden and nothing can be
-- prompted or granted. The owner creates four Developer Products on the
-- Creator Dashboard and pastes the ids in.
MonetizationConfig.GadgetProducts = {
	{ key = "GadgetSmoke", productId = 0, robux = 15, kind = "Gadget", amount = 0, label = "Smoke Bombs", gadgetKey = "Smoke" },
	{ key = "GadgetJammer", productId = 0, robux = 25, kind = "Gadget", amount = 0, label = "Laser Jammers", gadgetKey = "Jammer" },
	{ key = "GadgetGrapple", productId = 0, robux = 19, kind = "Gadget", amount = 0, label = "Grappling Hooks", gadgetKey = "Grapple" },
	{ key = "GadgetBundle", productId = 0, robux = 45, kind = "Gadget", amount = 0, label = "Full Kit", gadgetKey = "All" },
} :: { ProductDef }

--- The refill product for one gadget key, or nil when there is none.
MonetizationConfig.GadgetProductByKey = {} :: { [string]: ProductDef }

--- INSTANT REVEAL, priced by how long is LEFT on the container - never by the
--- original wait. The server recomputes the remaining time at the moment of
--- the prompt and picks the cheapest tier whose ceiling covers it.
MonetizationConfig.RevealProducts = {
	{ key = "Reveal1m", productId = 3712073462, robux = 3, kind = "Reveal", amount = 0, label = "Instant Reveal", maxRemainingSeconds = 60 },
	{ key = "Reveal5m", productId = 3712073493, robux = 9, kind = "Reveal", amount = 0, label = "Instant Reveal", maxRemainingSeconds = 5 * 60 },
	{ key = "Reveal15m", productId = 3712073520, robux = 19, kind = "Reveal", amount = 0, label = "Instant Reveal", maxRemainingSeconds = 15 * 60 },
	{ key = "Reveal45m", productId = 3712073551, robux = 39, kind = "Reveal", amount = 0, label = "Instant Reveal", maxRemainingSeconds = 45 * 60 },
	{ key = "Reveal2h", productId = 3712073612, robux = 79, kind = "Reveal", amount = 0, label = "Instant Reveal", maxRemainingSeconds = 2 * 3600 },
	{ key = "Reveal6h", productId = 3712073649, robux = 149, kind = "Reveal", amount = 0, label = "Instant Reveal", maxRemainingSeconds = 6 * 3600 },
	{ key = "Reveal12h", productId = 3712073670, robux = 249, kind = "Reveal", amount = 0, label = "Instant Reveal", maxRemainingSeconds = 12 * 3600 },
} :: { ProductDef }

--- The cheapest Instant Reveal tier that covers `remainingSeconds`, or nil
--- when nothing is left to buy (the container is already ready).
function MonetizationConfig.revealProductFor(remainingSeconds: number): ProductDef?
	if remainingSeconds <= 0 then
		return nil
	end
	for _, product in MonetizationConfig.RevealProducts do
		if remainingSeconds <= (product.maxRemainingSeconds or 0) then
			return product
		end
	end
	-- Past the last ceiling (a clock skew, a corrupt stamp): the top tier
	-- still covers it rather than leaving the player with no way to reveal.
	return MonetizationConfig.RevealProducts[#MonetizationConfig.RevealProducts]
end

-- ==========================================================
-- STEAL PRODUCTS
-- ==========================================================
--
-- PRICED BY WHAT THE ITEM EARNS, NEVER BY ITS RARITY WORD.
--
-- These used to be indexed on the target's rarity, and that was a hole you
-- could drive a bus through. Rarity in this game is a PER-ZONE ladder
-- (RarityConfig.ZoneRarities): "Common" means "the cheapest of this zone's
-- eight items", not an absolute tier. Zone 12 is the only late zone whose
-- ladder restarts at Common, so its worst item - the Golden Pilot Badge, at
-- 387,000,000 a second - wore the cheapest label in the game and sold for
-- 7 R$. That made the 7 R$ product ELEVEN TIMES better value than the 599 R$
-- one (55.3M/sec per Robux against 5.0M), and 40,000x better than a 69 R$
-- Legendary. The cheapest thing on the shelf was the best deal on it.
--
-- Now the server bands the item's FinalIncome and charges the cheapest tier
-- whose ceiling covers it, so price rises with the prize everywhere, in every
-- zone, for every item that will ever be added. `rarity` survives as the name
-- each tier was born with; nothing reads it to decide a price.
--
-- THE CEILINGS ARE INCOME PER SECOND, and they are deliberately not clean
-- decades at the top: most of the catalogue sits between 1e2 and 1e9, so the
-- bands are tighter there and the last two carry the billion-a-second tail.
--
-- `robux` is the brief's intended price and a display fallback only - the live
-- PriceInRobux is what the prompt shows, and at handoff every one of these but
-- Common differed from the intended value (see HANDOFF §32), which is a
-- Creator Dashboard decision, not a code one.
MonetizationConfig.StealProducts = {
	{ key = "StealCommon", productId = 3711862263, robux = 7, kind = "Steal", amount = 0, label = "Common", rarity = "Common", maxIncome = 5 },
	{ key = "StealUncommon", productId = 3711862399, robux = 12, kind = "Steal", amount = 0, label = "Uncommon", rarity = "Uncommon", maxIncome = 20 },
	{ key = "StealRare", productId = 3711862419, robux = 24, kind = "Steal", amount = 0, label = "Rare", rarity = "Rare", maxIncome = 200 },
	{ key = "StealEpic", productId = 3711862431, robux = 39, kind = "Steal", amount = 0, label = "Epic", rarity = "Epic", maxIncome = 2.5e3 },
	{ key = "StealLegendary", productId = 3711862445, robux = 69, kind = "Steal", amount = 0, label = "Legendary", rarity = "Legendary", maxIncome = 100e3 },
	{ key = "StealMythic", productId = 3711862461, robux = 149, kind = "Steal", amount = 0, label = "Mythic", rarity = "Mythic", maxIncome = 600e3 },
	{ key = "StealCosmic", productId = 3711862478, robux = 199, kind = "Steal", amount = 0, label = "Cosmic", rarity = "Cosmic", maxIncome = 12e6 },
	{ key = "StealSecret", productId = 3711862490, robux = 249, kind = "Steal", amount = 0, label = "Secret", rarity = "Secret", maxIncome = 150e6 },
	{ key = "StealEternal", productId = 3711862508, robux = 399, kind = "Steal", amount = 0, label = "Eternal", rarity = "Eternal", maxIncome = 900e6 },
	--- The tail: everything above the Eternal ceiling.
	{ key = "StealDivine", productId = 3711862519, robux = 599, kind = "Steal", amount = 0, label = "Divine", rarity = "Divine", maxIncome = math.huge },
} :: { ProductDef }

--- The steal tier that covers an item earning `income` a second: the cheapest
--- one whose ceiling reaches it. THE ONE PLACE a steal price is decided - the
--- prompt, the receipt check and the tests all come through here, so a
--- client can never be charged one tier and handed another.
function MonetizationConfig.stealProductForIncome(income: number?): ProductDef
	local value = tonumber(income) or 0
	if value ~= value then -- NaN from a corrupt save
		value = 0
	end
	for _, product in MonetizationConfig.StealProducts do
		if value <= (product.maxIncome or math.huge) then
			return product
		end
	end
	-- Unreachable while the last ceiling is infinite; still never nil.
	return MonetizationConfig.StealProducts[#MonetizationConfig.StealProducts]
end

--- B. Direct Speed grants. Added verbatim - never scaled by a multiplier.
MonetizationConfig.SpeedProducts = {
	{ key = "Speed150K", productId = 3711390304, robux = 69, kind = "Speed", amount = 150e3, label = "150K" },
	{ key = "Speed1M", productId = 3711390417, robux = 215, kind = "Speed", amount = 1e6, label = "1M" },
	{ key = "Speed10M", productId = 3711390452, robux = 595, kind = "Speed", amount = 10e6, label = "10M" },
	{ key = "Speed1B", productId = 3711390523, robux = 2549, kind = "Speed", amount = 1e9, label = "1B" },
} :: { ProductDef }

-- ==========================================================
-- CASH PACKS (income-scaled; monetization pass 2026-09-17)
-- ==========================================================
--
-- WHY THEY SCALE. The packs used to be flat: $24K-$8M. Treadmill tier 5 costs
-- $120M and the late trails cost trillions, so after the first hour every
-- pack was worth nothing and the shop's whole Cash section was dead weight.
-- Each pack now pays
--
--     max( amount, baseIncome x incomeMinutes x 60 )
--
-- where `amount` is the floor a brand-new player (income ~0) still gets, and
-- `baseIncome` is MonetizationConfig.baseIncome - the player's $/s with the
-- 2x Cash pass and the temporary/server boosts DIVIDED BACK OUT. So:
--   * the 2x pass still never doubles a purchased pack (the rule in the
--     header), and
--   * a weekend earnings event does not make packs briefly twice as good
--     (and then "worse" the next day for the same Robux).
-- The income is read at RECEIPT time, which is also what the shop shows live
-- (StatePush `shop.cashPacks`, computed by the same function on the server).
--
-- VALUE PER ROBUX RISES WITH SIZE, in both regimes, so a bigger pack is never
-- the worse deal:
--     floor  $/R$ : 75K/45=1,667   200K/85=2,353   800K/215=3,721   4M/425=9,412   8M/679=11,782
--     income s/R$ : 600/45=13.3    1800/85=21.2    7200/215=33.5    21600/425=50.8 43200/679=63.6
-- The 24K floor was 533 $/R$ - a quarter of the 200K pack's value - and is
-- now 75K (validate pins the monotonic order). The painted card still prints
-- "24K"; the live ribbon ShopController lays over it shows the real figure,
-- and the art should be re-exported (see docs/handoff-parts/monetization.md).
-- Product ids and prices are unchanged: the ids exist on Roblox.

--- Cash packs. The 2x Cash pass does NOT touch these (see above).
MonetizationConfig.CashProducts = {
	-- 10 minutes of income, floor $75K (was a flat $24K).
	{ key = "Cash24K", productId = 3711390597, robux = 45, kind = "Cash", amount = 75e3, label = "75K", incomeMinutes = 10 },
	-- 30 minutes of income, floor $200K.
	{ key = "Cash200K", productId = 3711390623, robux = 85, kind = "Cash", amount = 200e3, label = "200K", incomeMinutes = 30 },
	-- 2 hours of income, floor $800K.
	{ key = "Cash800K", productId = 3711390659, robux = 215, kind = "Cash", amount = 800e3, label = "800K", incomeMinutes = 120 },
	-- 6 hours of income, floor $4M.
	{ key = "Cash4M", productId = 3711390692, robux = 425, kind = "Cash", amount = 4e6, label = "4M", incomeMinutes = 360 },
	-- 12 hours of income, floor $8M.
	{ key = "Cash8M", productId = 3711390722, robux = 679, kind = "Cash", amount = 8e6, label = "8M", incomeMinutes = 720 },
} :: { ProductDef }

--- The income every scaled grant is measured in: the live $/s with the 2x
--- Cash pass and the server/temporary earnings boosts divided back out.
--- `income` is EconomyService.getIncome, `cashMultiplier` the pass factor
--- (1 or 2). Shared by the Cash packs, the receipt fallback and the spin
--- wheel's Cash wedges, so all three read the same number.
function MonetizationConfig.baseIncome(income: number, cashMultiplier: number): number
	local boosts = GameConfig.SERVER_EARNINGS_BOOST * GameConfig.TEMPORARY_EARNINGS_BOOST
	local divisor = math.max(cashMultiplier, 1) * math.max(boosts, 1e-6)
	local value = (tonumber(income) or 0) / divisor
	if value ~= value or value == math.huge or value < 0 then
		return 0
	end
	return value
end

--- What a Cash pack pays a player whose base income is `baseIncome`. Whole
--- dollars; never below the pack's floor.
function MonetizationConfig.cashPackAmount(product: ProductDef, baseIncome: number): number
	local scaled = baseIncome * (product.incomeMinutes or 0) * 60
	return math.floor(math.max(product.amount, scaled))
end

-- ==========================================================
-- UNDELIVERABLE RECEIPTS
-- ==========================================================
--
-- A paid Steal / Reveal / Treadmill tier that can NEVER be delivered (the
-- item is gone for good, the treadmill is already maxed) used to be left
-- OPEN forever: Roblox kept the Robux and the player got nothing. It is now
-- converted to Cash and consumed. The conversion is deliberately a little
-- more generous than the Cash packs' small end - it is an apology:
--
--     fallback = max( robuxPaid x FALLBACK_CASH_PER_ROBUX,
--                     baseIncome x robuxPaid x FALLBACK_INCOME_SECONDS_PER_ROBUX )
--
-- i.e. a minute of base income per Robux (a 599 R$ Divine steal -> 10 hours,
-- next to the 679 R$ pack's 12), and never less than $2,500 per Robux (just
-- above the 200K pack's 2,353). `robuxPaid` is the receipt's CurrencySpent
-- when Roblox reports one, else the live price, else the config price.

MonetizationConfig.FALLBACK_CASH_PER_ROBUX = 2500
MonetizationConfig.FALLBACK_INCOME_SECONDS_PER_ROBUX = 60

function MonetizationConfig.fallbackCash(robuxPaid: number, baseIncome: number): number
	local robux = math.max(tonumber(robuxPaid) or 0, 0)
	return math.floor(math.max(
		robux * MonetizationConfig.FALLBACK_CASH_PER_ROBUX,
		baseIncome * robux * MonetizationConfig.FALLBACK_INCOME_SECONDS_PER_ROBUX
	))
end

--- The pre-existing treadmill TIER products (phase 11). Unchanged ids; they now
--- live in the same table as everything else so ProcessReceipt has exactly one
--- place to look a product up.
MonetizationConfig.TreadmillProducts = {
	{ key = "TreadmillTier2", productId = 3711354814, robux = 16, kind = "TreadmillTier", amount = 2, label = "Velocity" },
	{ key = "TreadmillTier3", productId = 3711354847, robux = 24, kind = "TreadmillTier", amount = 3, label = "Voltic" },
	{ key = "TreadmillTier4", productId = 3711354872, robux = 32, kind = "TreadmillTier", amount = 4, label = "Inferno" },
	{ key = "TreadmillTier5", productId = 3711354886, robux = 40, kind = "TreadmillTier", amount = 5, label = "Frostbite" },
	{ key = "TreadmillTier6", productId = 3711354896, robux = 56, kind = "TreadmillTier", amount = 6, label = "Midas" },
	{ key = "TreadmillTier7", productId = 3711354919, robux = 72, kind = "TreadmillTier", amount = 7, label = "Overclock" },
	{ key = "TreadmillTier8", productId = 3711354939, robux = 96, kind = "TreadmillTier", amount = 8, label = "Eclipse" },
	{ key = "TreadmillTier9", productId = 3711354965, robux = 120, kind = "TreadmillTier", amount = 9, label = "Ascendant" },
} :: { ProductDef }

-- ==========================================================
-- BOSS-LOSS OFFER
-- ==========================================================

--- The LARGEST Speed product a zone may offer after its guardian catches you.
--- The pack actually offered is `bossOfferFor` below: the cheapest pack up to
--- this ceiling that closes a meaningful share of the player's gap.
---
--- ZONE 12 IS DELIBERATELY ABSENT. Its value was not specified, and inventing a
--- price for real money is not a gap to fill with a guess - the offer simply
--- does not appear there until one is supplied.
MonetizationConfig.BossOfferByZone = {
	[1] = "Speed150K", [2] = "Speed150K", [3] = "Speed150K", [4] = "Speed150K",
	[5] = "Speed1M", [6] = "Speed1M",
	[7] = "Speed10M", [8] = "Speed10M",
	[9] = "Speed1B", [10] = "Speed1B", [11] = "Speed1B",
} :: { [number]: string }

--- "Meaningfully helps": the offered pack must cover at least this share of
--- the gap between the player's Speed and the caught zone's recommendation.
---
--- Before 2026-09-17 zones 9-11 could only ever offer the 2,549 R$ 1B pack,
--- even to a player 3M short of the Secret Lab. Now a player a little short
--- is offered the small pack that actually gets them there, and a player
--- hundreds of millions short still sees the 1B pack - nothing smaller would
--- help, and pretending otherwise is the worse sale. 10%: a pack worth less
--- than a tenth of the gap is not an answer to "you were too slow".
MonetizationConfig.BOSS_OFFER_GAP_FRACTION = 0.10

--- The Speed product to offer a player with `speedPower` who was caught in
--- `zoneIndex`, or nil when the zone has no offer (zone 12). Walks the Speed
--- packs cheapest first, never past the zone's ceiling:
---   * already at or above the gate (caught anyway): the cheapest pack;
---   * otherwise the cheapest pack whose amount >= GAP_FRACTION x gap;
---   * none big enough: the ceiling itself.
function MonetizationConfig.bossOfferFor(zoneIndex: number, speedPower: number): ProductDef?
	local ceilingKey = MonetizationConfig.BossOfferByZone[zoneIndex]
	local ceiling = if ceilingKey then MonetizationConfig.ProductByKey[ceilingKey] else nil
	if not ceiling then
		return nil
	end
	local zone = ZoneConfig.Zones[zoneIndex]
	local gate = if zone then zone.recommendedSpeed else 0
	local gap = gate - (tonumber(speedPower) or 0)

	local candidates: { ProductDef } = {}
	for _, product in MonetizationConfig.SpeedProducts do
		if product.robux <= ceiling.robux then
			table.insert(candidates, product)
		end
	end
	table.sort(candidates, function(a, b)
		return a.robux < b.robux
	end)
	if gap <= 0 then
		return candidates[1] or ceiling
	end
	local wanted = gap * MonetizationConfig.BOSS_OFFER_GAP_FRACTION
	for _, product in candidates do
		if product.amount >= wanted then
			return product
		end
	end
	return ceiling
end

--- Seconds before the same player can be shown another loss offer.
---
--- Was ZERO (every catch offered). A bad run is several catches a minute, and
--- a purchase card on every one of them reads as nagging at exactly the moment
--- the player is most annoyed - so one offer per 90 seconds (2026-09-17).
MonetizationConfig.BOSS_OFFER_COOLDOWN = 90

-- ==========================================================
-- LOOKUPS (built once at require time)
-- ==========================================================

MonetizationConfig.ProductByKey = {} :: { [string]: ProductDef }
MonetizationConfig.ProductById = {} :: { [number]: ProductDef }

for _, list in { MonetizationConfig.SpeedProducts, MonetizationConfig.CashProducts, MonetizationConfig.TreadmillProducts, MonetizationConfig.StealProducts, MonetizationConfig.RevealProducts, MonetizationConfig.GadgetProducts } do
	for _, product in list do
		MonetizationConfig.ProductByKey[product.key] = product
		-- An unconfigured product is id 0; registering it would make id 0
		-- resolve to a real row and let a broken prompt "succeed".
		if product.productId > 0 then
			MonetizationConfig.ProductById[product.productId] = product
		end
	end
end
for _, product in MonetizationConfig.GadgetProducts do
	if product.gadgetKey then
		MonetizationConfig.GadgetProductByKey[product.gadgetKey] = product
	end
end

-- ==========================================================
-- GIFT PACKS (trading-gifting-boards pass)
-- ==========================================================
--
-- One Developer Product per Cash / Speed pack, same price, bought FOR another
-- player in the server. `giftOf` names the pack the recipient receives; the
-- Cash amount is the RECIPIENT's scaled amount at receipt time (or, if they
-- have left, the amount the buyer was shown). Granted by GiftService through
-- ProcessReceipt only.
--
-- productId 0 = not created on the Creator Dashboard yet. Such a product is
-- in ProductByKey (so the shop can list it as "coming soon" / hide it) but
-- deliberately NOT in ProductById: every unset gift shares the id 0, and a
-- receipt can never carry it anyway. The Gift section of the shop stays
-- hidden until at least one id is set.
MonetizationConfig.GiftProducts = {
	{ key = "GiftCash24K", productId = 3713252836, robux = 45, kind = "Gift", amount = 75e3, label = "75K", giftOf = "Cash24K" },
	{ key = "GiftCash200K", productId = 3713252845, robux = 85, kind = "Gift", amount = 200e3, label = "200K", giftOf = "Cash200K" },
	{ key = "GiftCash800K", productId = 3713252847, robux = 215, kind = "Gift", amount = 800e3, label = "800K", giftOf = "Cash800K" },
	{ key = "GiftCash4M", productId = 3713252854, robux = 425, kind = "Gift", amount = 4e6, label = "4M", giftOf = "Cash4M" },
	{ key = "GiftCash8M", productId = 3713252859, robux = 679, kind = "Gift", amount = 8e6, label = "8M", giftOf = "Cash8M" },
	{ key = "GiftSpeed150K", productId = 3713252863, robux = 69, kind = "Gift", amount = 150e3, label = "150K", giftOf = "Speed150K" },
	{ key = "GiftSpeed1M", productId = 3713252865, robux = 215, kind = "Gift", amount = 1e6, label = "1M", giftOf = "Speed1M" },
	{ key = "GiftSpeed10M", productId = 3713252871, robux = 595, kind = "Gift", amount = 10e6, label = "10M", giftOf = "Speed10M" },
	{ key = "GiftSpeed1B", productId = 3713252877, robux = 2549, kind = "Gift", amount = 1e9, label = "1B", giftOf = "Speed1B" },
} :: { ProductDef }

for _, product in MonetizationConfig.GiftProducts do
	MonetizationConfig.ProductByKey[product.key] = product
	if product.productId > 0 then
		MonetizationConfig.ProductById[product.productId] = product
	end
end

--- The gift product that buys `packKey` for someone else, or nil.
function MonetizationConfig.giftFor(packKey: string): ProductDef?
	for _, product in MonetizationConfig.GiftProducts do
		if product.giftOf == packKey then
			return product
		end
	end
	return nil
end

--- Steal product by the rarity it pays for.
--- RETIRED: `StealProductByRarity`. Pricing a steal off the rarity WORD is
--- the bug this pass removed (see STEAL PRODUCTS); the lookup is gone so it
--- cannot come back by accident. Use `stealProductForIncome`.

MonetizationConfig.TrailByKey = {} :: { [string]: TrailDef }
MonetizationConfig.TrailOrder = {} :: { [string]: number }
for index, trail in MonetizationConfig.Trails do
	MonetizationConfig.TrailByKey[trail.key] = trail
	MonetizationConfig.TrailOrder[trail.key] = index
end

MonetizationConfig.SpeedPassByKey = {} :: { [string]: PassTier }
for _, tier in MonetizationConfig.SpeedMultiplierPasses do
	MonetizationConfig.SpeedPassByKey[tier.key] = tier
end

-- ==========================================================
-- DERIVED VIEWS
-- ==========================================================
--
-- The structured tables above are the source of truth. These are flat views
-- built from them, kept because the Upgrades panel and the debug bridge already
-- speak this shape - deriving them beats maintaining a second copy of the ids.

MonetizationConfig.Products = {} :: { [string]: number }
MonetizationConfig.ListedPriceRobux = {} :: { [string]: number }
for id, product in MonetizationConfig.ProductById do
	MonetizationConfig.Products[product.key] = id
	MonetizationConfig.ListedPriceRobux[product.key] = product.robux
end

--- True once a real id has been pasted in. A zero means "not configured yet",
--- and an unconfigured product must never be prompted or granted.
function MonetizationConfig.isConfigured(key: string): boolean
	local id = MonetizationConfig.Products[key]
	return id ~= nil and id > 0
end

--- The product id for a key, or nil when unset. Returning nil rather than 0
--- means a caller cannot accidentally prompt for product "0", which Roblox shows
--- the player as a broken purchase dialog.
function MonetizationConfig.productIdFor(key: string?): number?
	if not key then
		return nil
	end
	local id = MonetizationConfig.Products[key]
	return if id and id > 0 then id else nil
end

--- Reverse lookup so ProcessReceipt can map a purchased id back to its key.
function MonetizationConfig.keyForProductId(productId: number): string?
	local product = MonetizationConfig.ProductById[productId]
	return if product then product.key else nil
end

--- Every gamepass id the game cares about, for the ownership cache to warm.
function MonetizationConfig.allGamePassIds(): { number }
	local ids = { MonetizationConfig.CashPass.gamePassId }
	for _, tier in MonetizationConfig.SpeedMultiplierPasses do
		table.insert(ids, tier.gamePassId)
	end
	for _, trail in MonetizationConfig.Trails do
		if trail.gamePassId then
			table.insert(ids, trail.gamePassId)
		end
	end
	for _, pass in MonetizationConfig.GuardianPasses do
		table.insert(ids, pass.gamePassId)
	end
	table.insert(ids, MonetizationConfig.SlapPass.gamePassId)
	-- [fusion-autoreveal-bases] Auto Reveal and the Robux base themes. Only
	-- configured ids: a placeholder 0 is never sent to UserOwnsGamePassAsync.
	for _, pass in MonetizationConfig.featurePasses() do
		if pass.gamePassId > 0 then
			table.insert(ids, pass.gamePassId)
		end
	end
	-- [retention-quests-pass] Only once a real id exists: 0 is a placeholder.
	if MonetizationConfig.SeasonPremiumPass.gamePassId > 0 then
		table.insert(ids, MonetizationConfig.SeasonPremiumPass.gamePassId)
	end
	return ids
end

--- The tier a player at `ownedMultiplier` is next in line for, or nil at max.
--- Walks the list in order, which is what makes the progression sequential and
--- unskippable from the shop.
function MonetizationConfig.nextSpeedTier(ownedMultiplier: number): PassTier?
	for _, tier in MonetizationConfig.SpeedMultiplierPasses do
		if tier.multiplier > ownedMultiplier then
			return tier
		end
	end
	return nil
end

MonetizationConfig.MAX_SPEED_MULTIPLIER =
	MonetizationConfig.SpeedMultiplierPasses[#MonetizationConfig.SpeedMultiplierPasses].multiplier

-- ==========================================================
-- AUTO REVEAL AND BASE THEMES (fusion-autoreveal-bases)
-- ==========================================================
--
-- PLACEHOLDERS: every id here is 0 until the owner creates the Game Pass on
-- the Creator Dashboard and pastes its id in. While an id is 0 the feature
-- it unlocks is hidden (outside Studio) and never prompted. `robux` is the
-- SUGGESTED price, a display fallback only (see the handoff note).
--
-- Neither pass sells anything random: Auto Reveal only saves a click on a
-- reveal the player gets for free anyway, and a theme is a fixed cosmetic.
-- Item FUSION (which has a random mutation roll) is deliberately NOT here
-- and must never be sold for Robux.

--- Sealed containers reveal themselves when their timer ends while the
--- owner is online (AutoRevealService). Suggested 199 R$.
MonetizationConfig.AutoRevealPass = { key = "AutoReveal", gamePassId = 1985618401, robux = 199, label = "Auto Reveal" } :: SimplePass

--- Robux-exclusive base themes (BaseThemeConfig rows name these by key).
MonetizationConfig.ThemePasses = {
	-- Suggested 149 R$ each.
	{ key = "ThemeNeonNight", gamePassId = 1986506321, robux = 149, label = "Neon Night Theme" },
	{ key = "ThemeRoyalGold", gamePassId = 1985804347, robux = 149, label = "Royal Gold Theme" },
} :: { SimplePass }

MonetizationConfig.ThemePassByKey = {} :: { [string]: SimplePass }
for _, pass in MonetizationConfig.ThemePasses do
	MonetizationConfig.ThemePassByKey[pass.key] = pass
end

--- Every pass this area adds, for the ownership warm-up.
function MonetizationConfig.featurePasses(): { SimplePass }
	local out = { MonetizationConfig.AutoRevealPass }
	for _, pass in MonetizationConfig.ThemePasses do
		table.insert(out, pass)
	end
	return out
end

return MonetizationConfig
