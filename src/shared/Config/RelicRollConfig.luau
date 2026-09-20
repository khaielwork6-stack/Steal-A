--!strict
--[[
	RelicRollConfig
	[relic-roll] "MUSEUM RELICS [LIMITED]" gacha banner: the six-item pool, its
	odds, and which MonetizationConfig product keys sell rolls on it.

	EVERY ROBUX ID LIVES IN MONETIZATIONCONFIG, NOT HERE (its own header rule).
	This file only names the four product KEYS
	(MonetizationConfig.RelicRollProducts) so RelicRollService and the client
	never hardcode one.

	== ITEM POOL AND ODDS (owner's call: "you choose the items and the odds") ==
	Six EXISTING LootConfig items, ascending rarity, at the reference's
	39/25/20/10/5/1 (sums to 100). All six are Zone 1-2 items on purpose -
	OUT OF SCOPE says the Zone 8+ progression wall is not to be touched, and
	the safest way to guarantee that is to never sell a Zone 8-12 item here at
	all, however small the odds. The top prize (Pirate_CursedCoin, Cosmic) is
	Zone 2's own best item: a lucky pull is a HEAD START on content a player
	can already reach on foot, never a shortcut past a zone the owner fenced.

	EXPECTED VALUE (worked by hand, 2026-09-20; DebugCommands/RelicRoll's
	`relicDist` runs the real 10000-roll simulation with the live RNG):
	  Base incomes: Vase 1, Statue 8, PharaohMask 35, GoldenCrown 180,
	  Diamond 1800, CursedCoin 220,000 (all "Early" zone band, so they share
	  one average Scale-roll size factor of ~2.11, times the mutation table's
	  average multiplier of ~1.065 -> an average x~2.25 on the printed base).
	  Blended expected income/s per SINGLE roll ~= 0.39*2.25 + 0.25*18 +
	  0.20*79 + 0.10*405 + 0.05*4048 + 0.01*494,780 ~= $5,200/s, almost
	  entirely carried by the 1% slot.
	  SANITY CHECK against a GUARANTEED purchase at a similar price:
	  MonetizationConfig.StealProducts sell a guaranteed item up to a income
	  ceiling - 39 R$ guarantees up to $2,500/s, 69 R$ guarantees up to
	  $100,000/s. A Relic Roll at 52 R$ has a blended EV of "only" ~$5,200/s,
	  well BELOW the guaranteed 39-69 R$ band it sits between - the right side
	  to err on for a chance-based product, even before charging for the
	  packaging (the tease, the roulette, the collectible spread).
	  A worst-case pull (Colossal Scale + Corrupted mutation on the 1% slot)
	  can spike far above that average, but needs two independent low-odds
	  rolls to land together, so it is a rare delight, not the expected case.

	LIMITED PACK. `limited` is a display flag; `endsAt` (unix seconds, nil =
	always on) is read by the client to show a countdown under the banner
	title. Nothing here expires the SHOP LISTING itself - that is a manual
	edit to `endsAt` when the owner decides to end the promotion.
]]

local RelicRollConfig = {}

export type Tier = {
	--- LootConfig.ById key. Never renamed once shipped (ItemId is a save key).
	itemId: string,
	--- Raw weight; shares are weight / TOTAL_WEIGHT. Sums to TOTAL_WEIGHT.
	weight: number,
}

--- Ascending rarity, left-to-right on the banner exactly like the reference
--- (commonest first, rarest/largest last): 39 / 25 / 20 / 10 / 5 / 1.
RelicRollConfig.Tiers = {
	{ itemId = "Museum_AncientVase", weight = 39 },
	{ itemId = "Museum_GoldenStatue", weight = 25 },
	{ itemId = "Museum_PharaohMask", weight = 20 },
	{ itemId = "Museum_GoldenCrown", weight = 10 },
	{ itemId = "Museum_Diamond", weight = 5 },
	{ itemId = "Pirate_CursedCoin", weight = 1 },
} :: { Tier }

RelicRollConfig.TOTAL_WEIGHT = 100

--- The MonetizationConfig product keys the banner sells, in the reference's
--- own button order (biggest pack first, left-to-right: 50x, 10x, 3x, 1x).
RelicRollConfig.ProductKeys = { "RelicRoll50x", "RelicRoll10x", "RelicRoll3x", "RelicRoll1x" }

--- The single-roll key, for "was" price math (50x's crossed-out price is
--- honestly 50x this, never a made-up number).
RelicRollConfig.SINGLE_ROLL_KEY = "RelicRoll1x"
--- The bulk key whose "was" price is shown crossed out on its card.
RelicRollConfig.WAS_PRICE_KEY = "RelicRoll50x"
RelicRollConfig.WAS_PRICE_MULTIPLIER = 50

-- ==========================================================
-- THE ROULETTE (client, RelicRollRevealController)
-- ==========================================================

--- Seconds ONE roll's belt runs. The owner asked for 3-5 s (validate.luau
--- enforces the range). Reduced Effects uses REDUCED_ROLL_SECONDS instead.
RelicRollConfig.ROLL_SECONDS = 4.0
RelicRollConfig.REDUCED_ROLL_SECONDS = 0.6
--- Ease-out exponent: progress(u) = 1 - (1-u)^EASE_POWER. 3 (cubic) starts at
--- EASE_POWER*TRAVEL_CARDS/ROLL_SECONDS = 22.5 cards/s, is ~1.4 cards/s at
--- t = 3 s and creeps the last half card in the final second: fast first,
--- genuinely slow and readable at the end (Quint left the last second frozen).
RelicRollConfig.EASE_POWER = 3
--- How many cards the belt travels from its first centred card to the winner.
RelicRollConfig.TRAVEL_CARDS = 30
--- Seconds the item name + [Rarity] stays under the strip before the next roll
--- (tap to advance sooner).
RelicRollConfig.LANDING_HOLD_SECONDS = 1.2

--- Tick sound: a round-robin pool so ticks overlap instead of cutting off.
RelicRollConfig.TICK_POOL_SIZE = 8
--- PlaybackSpeed range. rate = MIN + (MAX-MIN) * (v / vPeak)^TICK_RATE_CURVE,
--- v = the belt's instantaneous cards/s, vPeak = its speed at t = 0.
RelicRollConfig.TICK_RATE_MIN = 0.8
RelicRollConfig.TICK_RATE_MAX = 1.5
RelicRollConfig.TICK_RATE_CURVE = 0.6
--- A tick within this many seconds of the previous one is skipped (only ever
--- possible near peak speed) - EXCEPT during the final TICK_PROTECT_CARDS
--- cards of travel, whose ticks must each be heard.
RelicRollConfig.TICK_MIN_GAP = 0.03
RelicRollConfig.TICK_PROTECT_CARDS = 8

RelicRollConfig.limited = true
--- Unix seconds; nil = always on. The banner's countdown is hidden while nil.
RelicRollConfig.endsAt = nil :: number?

RelicRollConfig.BANNER_TITLE = "MUSEUM RELICS"
RelicRollConfig.BANNER_TAG = "LIMITED"

--- ONE weighted pick across the six tiers. `rng` nil uses the global
--- generator - RelicRollService's real grant path always passes its own
--- Random (rule: RNG is server-side only, never the client).
function RelicRollConfig.rollTier(rng: Random?): Tier
	local roll = (if rng then rng:NextNumber() else math.random()) * RelicRollConfig.TOTAL_WEIGHT
	local cursor = 0
	for _, tier in RelicRollConfig.Tiers do
		cursor += tier.weight
		if roll <= cursor then
			return tier
		end
	end
	return RelicRollConfig.Tiers[#RelicRollConfig.Tiers]
end

--- The odds row the banner prints under each figure, in Tiers order.
function RelicRollConfig.oddsPercent(): { number }
	local out = {}
	for _, tier in RelicRollConfig.Tiers do
		table.insert(out, tier.weight)
	end
	return out
end

return RelicRollConfig
