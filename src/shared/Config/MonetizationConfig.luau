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
	buy.
]]

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
	--- item of the matching rarity (HeistService) and carries no amount.
	kind: "Cash" | "Speed" | "TreadmillTier" | "Steal" | "Reveal",
	amount: number,
	label: string,
	--- Steal products only: the rarity this product pays for.
	rarity: string?,
	--- Reveal products only: the longest remaining wait, in seconds, this
	--- tier covers. The cheapest tier that covers the wait is the one offered.
	maxRemainingSeconds: number?,
}

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

--- Player-to-player base stealing, one product per rarity. The server picks
--- the row from the REAL item's rarity in the victim's profile; a client can
--- never name one. `robux` is the brief's intended price and a display
--- fallback only - the live PriceInRobux is what the prompt shows, and at
--- handoff every one of these but Common differed from the intended value
--- (see HANDOFF §32), which is a Creator Dashboard decision, not a code one.
MonetizationConfig.StealProducts = {
	{ key = "StealCommon", productId = 3711862263, robux = 7, kind = "Steal", amount = 0, label = "Common", rarity = "Common" },
	{ key = "StealUncommon", productId = 3711862399, robux = 12, kind = "Steal", amount = 0, label = "Uncommon", rarity = "Uncommon" },
	{ key = "StealRare", productId = 3711862419, robux = 24, kind = "Steal", amount = 0, label = "Rare", rarity = "Rare" },
	{ key = "StealEpic", productId = 3711862431, robux = 39, kind = "Steal", amount = 0, label = "Epic", rarity = "Epic" },
	{ key = "StealLegendary", productId = 3711862445, robux = 69, kind = "Steal", amount = 0, label = "Legendary", rarity = "Legendary" },
	{ key = "StealMythic", productId = 3711862461, robux = 149, kind = "Steal", amount = 0, label = "Mythic", rarity = "Mythic" },
	{ key = "StealCosmic", productId = 3711862478, robux = 199, kind = "Steal", amount = 0, label = "Cosmic", rarity = "Cosmic" },
	{ key = "StealSecret", productId = 3711862490, robux = 249, kind = "Steal", amount = 0, label = "Secret", rarity = "Secret" },
	{ key = "StealEternal", productId = 3711862508, robux = 399, kind = "Steal", amount = 0, label = "Eternal", rarity = "Eternal" },
	{ key = "StealDivine", productId = 3711862519, robux = 599, kind = "Steal", amount = 0, label = "Divine", rarity = "Divine" },
} :: { ProductDef }

--- B. Direct Speed grants. Added verbatim - never scaled by a multiplier.
MonetizationConfig.SpeedProducts = {
	{ key = "Speed150K", productId = 3711390304, robux = 69, kind = "Speed", amount = 150e3, label = "150K" },
	{ key = "Speed1M", productId = 3711390417, robux = 215, kind = "Speed", amount = 1e6, label = "1M" },
	{ key = "Speed10M", productId = 3711390452, robux = 595, kind = "Speed", amount = 10e6, label = "10M" },
	{ key = "Speed1B", productId = 3711390523, robux = 2549, kind = "Speed", amount = 1e9, label = "1B" },
} :: { ProductDef }

--- Cash packs. Granted at face value; the 2x Cash pass does NOT touch these.
MonetizationConfig.CashProducts = {
	{ key = "Cash24K", productId = 3711390597, robux = 45, kind = "Cash", amount = 24e3, label = "24K" },
	{ key = "Cash200K", productId = 3711390623, robux = 85, kind = "Cash", amount = 200e3, label = "200K" },
	{ key = "Cash800K", productId = 3711390659, robux = 215, kind = "Cash", amount = 800e3, label = "800K" },
	{ key = "Cash4M", productId = 3711390692, robux = 425, kind = "Cash", amount = 4e6, label = "4M" },
	{ key = "Cash8M", productId = 3711390722, robux = 679, kind = "Cash", amount = 8e6, label = "8M" },
} :: { ProductDef }

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

--- Which Speed product a zone offers after its guardian catches you.
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

--- Seconds before the same player can be shown another loss offer.
---
--- ZERO ON PURPOSE: every catch shows the offer. The card is small, sits at the
--- top of the screen, blocks nothing and re-texts in place rather than stacking,
--- so a second loss re-punches the one card instead of piling up prompts. Raise
--- this if it ever starts to read as nagging.
MonetizationConfig.BOSS_OFFER_COOLDOWN = 0

-- ==========================================================
-- LOOKUPS (built once at require time)
-- ==========================================================

MonetizationConfig.ProductByKey = {} :: { [string]: ProductDef }
MonetizationConfig.ProductById = {} :: { [number]: ProductDef }

for _, list in { MonetizationConfig.SpeedProducts, MonetizationConfig.CashProducts, MonetizationConfig.TreadmillProducts, MonetizationConfig.StealProducts, MonetizationConfig.RevealProducts } do
	for _, product in list do
		MonetizationConfig.ProductByKey[product.key] = product
		MonetizationConfig.ProductById[product.productId] = product
	end
end

--- Steal product by the rarity it pays for.
MonetizationConfig.StealProductByRarity = {} :: { [string]: ProductDef }
for _, product in MonetizationConfig.StealProducts do
	if product.rarity then
		MonetizationConfig.StealProductByRarity[product.rarity] = product
	end
end

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

return MonetizationConfig
