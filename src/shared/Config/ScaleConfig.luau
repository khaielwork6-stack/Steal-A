--!strict
--[[
	ScaleConfig
	The continuous item Scale: how it is rolled, what it earns, what it is
	called, how long it takes to mature, and how it is carried.

	ONE SAVED NUMBER. Every item saves a server-authoritative `Scale` (1.0 is
	the normalised baseline model). Everything else here is DERIVED from it on
	demand and never stored: the income factor, the six-word label, the
	container's physical size, the carried size. Retuning any curve below
	therefore restats every existing item on its next load - which is the point.

	THE ROLL IS LABEL-FIRST, AND ZONE-BIASED
	One weighted pick chooses the SIZE VARIANT (Normal ... Colossal) from the
	authoritative weights below, multiplied by the zone band's bias and then
	NORMALISED - so every roll returns exactly one variant and there is no
	"nothing happened" outcome. A Scale is then drawn uniformly inside that
	variant's own range. That keeps the label, the container's physical size,
	the hatch time and the income all reading off one decision.

	WHAT IS VERIFIED AND WHAT IS NOT
	  * `sizeFactor` and `growthMultiplier` are the reference game's live
	    formulas, traced from its code (COMPETITOR WEIGHT SYSTEM AUDIT §5, §6).
	  * The variant scale RANGES are the reference game's roll bands (§2).
	  * The variant WEIGHTS and the zone bias are THIS GAME'S OWN, supplied by
	    the brief. The reference place's size table had been modified four
	    times and its stock weights are not recoverable, so nothing is copied
	    from it. SIZE_ODDS_STATUS says so at runtime.
]]

local ScaleConfig = {}

--- Reported by the parity tool and the tests.
ScaleConfig.SIZE_ODDS_STATUS = "PROJECT_OWN_WEIGHTS"
ScaleConfig.SIZE_ODDS_NOTE = "Variant weights and zone bias are this project's own (supplied by the brief). "
	.. "The reference game's stock band weights were modified in the connected place and were not copied."

--- Bumped whenever the roll ranges or the income curve change meaning, so a
--- saved item can be told which ladder its Scale belongs to.
ScaleConfig.ECONOMY_SCALE_VERSION = 1

-- ==========================================================
-- THE SIZE VARIANTS
-- ==========================================================

export type Variant = {
	id: string,
	--- Raw weight. NOT a percentage: the six total 96, and the roller
	--- normalises after the zone bias is applied. Never a 4% no-result.
	weight: number,
	--- The Scale range this variant draws from, uniformly.
	min: number,
	max: number,
}

--- Weakest first; the ORDER is the hierarchy (RarityConfig.sizeRank reads the
--- same order). THE AUTHORITATIVE SIZE WEIGHTS.
ScaleConfig.Variants = {
	{ id = "Normal", weight = 60, min = 0.85, max = 1.05 },
	{ id = "Big", weight = 20, min = 1.45, max = 2.10 },
	{ id = "Huge", weight = 10, min = 2.85, max = 4.20 },
	{ id = "Giant", weight = 4, min = 5.80, max = 6.20 },
	{ id = "Titan", weight = 1.5, min = 9.50, max = 17.00 },
	{ id = "Colossal", weight = 0.5, min = 20.00, max = 35.00 },
} :: { Variant }

ScaleConfig.VariantById = {} :: { [string]: Variant }
for _, variant in ScaleConfig.Variants do
	ScaleConfig.VariantById[variant.id] = variant
end

--- The smallest and largest Scale the roll can produce, and the clamp for a
--- saved value. Derived from the variants so they cannot disagree.
ScaleConfig.MIN_SCALE = ScaleConfig.Variants[1].min
ScaleConfig.MAX_SCALE = ScaleConfig.Variants[#ScaleConfig.Variants].max

-- ==========================================================
-- ZONE BIAS
-- ==========================================================
--
-- Big variants were arriving too often in the first zones and not often
-- enough in the last. Each zone band multiplies the raw weights BEFORE
-- normalisation, so the shape shifts without any variant becoming impossible
-- (no multiplier here is zero).

export type ZoneBand = { id: string, maxZone: number, multipliers: { [string]: number } }

ScaleConfig.ZoneBands = {
	{
		id = "Early", -- zones 1-3
		maxZone = 3,
		multipliers = { Normal = 1.30, Big = 1.00, Huge = 0.55, Giant = 0.25, Titan = 0.08, Colossal = 0.03 },
	},
	{
		id = "Middle", -- zones 4-6
		maxZone = 6,
		multipliers = { Normal = 1.15, Big = 1.00, Huge = 0.75, Giant = 0.50, Titan = 0.25, Colossal = 0.10 },
	},
	{
		id = "Advanced", -- zones 7-9
		maxZone = 9,
		multipliers = { Normal = 1.00, Big = 1.00, Huge = 1.00, Giant = 1.00, Titan = 1.00, Colossal = 1.00 },
	},
	{
		id = "Endgame", -- zones 10-12
		maxZone = math.huge,
		multipliers = { Normal = 0.85, Big = 0.95, Huge = 1.20, Giant = 1.50, Titan = 2.00, Colossal = 2.50 },
	},
} :: { ZoneBand }

--- The band a zone sits in. A nil/unknown zone takes the neutral Advanced
--- band rather than an accidental bias.
function ScaleConfig.bandFor(zoneIndex: number?): ZoneBand
	if not zoneIndex then
		return ScaleConfig.ZoneBands[3]
	end
	for _, band in ScaleConfig.ZoneBands do
		if zoneIndex <= band.maxZone then
			return band
		end
	end
	return ScaleConfig.ZoneBands[#ScaleConfig.ZoneBands]
end

--- The NORMALISED probability of every variant in a zone: raw weight times the
--- band multiplier, divided by their total. Sums to exactly 1. Exposed so the
--- tests and the parity tool check the same numbers the roller uses.
function ScaleConfig.variantOdds(zoneIndex: number?): { [string]: number }
	local multipliers = ScaleConfig.bandFor(zoneIndex).multipliers
	local total = 0
	local weighted: { [string]: number } = {}
	for _, variant in ScaleConfig.Variants do
		local weight = variant.weight * (multipliers[variant.id] or 1)
		weighted[variant.id] = weight
		total += weight
	end
	if total <= 0 then
		-- Impossible with the tables above, and never left to chance: a zone
		-- with no weight at all rolls Normal rather than nothing.
		return { Normal = 1 }
	end
	for id, weight in weighted do
		weighted[id] = weight / total
	end
	return weighted
end

--- ONE variant pick. `rng` is a Random for deterministic tests; nil uses the
--- global generator. Always returns a variant - the cumulative walk ends on
--- the last one, so floating-point drift cannot produce a nil result.
function ScaleConfig.rollVariant(zoneIndex: number?, rng: Random?): Variant
	local multipliers = ScaleConfig.bandFor(zoneIndex).multipliers
	local total = 0
	for _, variant in ScaleConfig.Variants do
		total += variant.weight * (multipliers[variant.id] or 1)
	end
	if total <= 0 then
		return ScaleConfig.Variants[1]
	end
	local roll = (if rng then rng:NextNumber() else math.random()) * total
	local cursor = 0
	for _, variant in ScaleConfig.Variants do
		cursor += variant.weight * (multipliers[variant.id] or 1)
		if roll <= cursor then
			return variant
		end
	end
	return ScaleConfig.Variants[#ScaleConfig.Variants]
end

--- Saved to four decimals: stable across save/load, fine enough that two
--- items of the same variant still differ.
function ScaleConfig.roundScale(scale: number): number
	return math.floor(scale * 10000 + 0.5) / 10000
end

--- ONE Scale roll for a zone: pick the variant, then draw uniformly inside
--- its range. Server-authoritative; only the spawn path calls this.
function ScaleConfig.rollScale(zoneIndex: number?, rng: Random?): number
	local variant = ScaleConfig.rollVariant(zoneIndex, rng)
	local u = if rng then rng:NextNumber() else math.random()
	return ScaleConfig.roundScale(variant.min + u * (variant.max - variant.min))
end

--- A stored Scale made safe: finite and inside the roll's range. Nothing else
--- is changed - a value inside the range is trusted as saved.
function ScaleConfig.clampScale(value: any): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 1
	end
	return math.clamp(value, ScaleConfig.MIN_SCALE, ScaleConfig.MAX_SCALE)
end

-- ==========================================================
-- INCOME
-- ==========================================================

--- 5 ^ 1.85: the value that keeps the two halves of the curve continuous.
local KNEE_FACTOR = 19.637875755794113

--- The size factor on income (the reference game's sizeMult, verified):
---     scale <= 5 :  scale ^ 1.85
---     scale >  5 :  19.637875755794113 * (scale / 5) ^ 1.2
function ScaleConfig.sizeFactor(scale: number): number
	if scale <= 5 then
		return scale ^ 1.85
	end
	return KNEE_FACTOR * (scale / 5) ^ 1.2
end

--- The Scale whose sizeFactor equals `factor`: the inverse of the curve
--- above. Used ONCE, by the save migration, to give a legacy item the Scale
--- that preserves the income its old size multiplier gave it.
function ScaleConfig.inverseSizeFactor(factor: number): number
	if factor <= 0 then
		return ScaleConfig.MIN_SCALE
	end
	if factor <= KNEE_FACTOR then
		return factor ^ (1 / 1.85)
	end
	return 5 * (factor / KNEE_FACTOR) ^ (1 / 1.2)
end

-- ==========================================================
-- LABELS
-- ==========================================================
--
-- The six player-facing words, derived from Scale. The boundaries sit in the
-- gaps BETWEEN the variant ranges, so a Scale drawn from a variant always
-- reads back as that variant - the container's size, its label, its hatch
-- time and its income can never disagree. `labelBoundaries` derives them from
-- the ranges rather than repeating them.

local boundaries: { { label: string, below: number } } = {}
do
	for index, variant in ScaleConfig.Variants do
		local nextVariant = ScaleConfig.Variants[index + 1]
		local below = if nextVariant then (variant.max + nextVariant.min) / 2 else math.huge
		table.insert(boundaries, { label = variant.id, below = below })
	end
end
ScaleConfig.LabelThresholds = boundaries

function ScaleConfig.labelFor(scale: number): string
	for _, row in ScaleConfig.LabelThresholds do
		if scale < row.below then
			return row.label
		end
	end
	return ScaleConfig.Variants[#ScaleConfig.Variants].id
end

-- ==========================================================
-- MATURATION
-- ==========================================================

--- How much longer than its base time a bigger item takes to mature (the
--- reference game's growth curve, verified):
---     scale <= 2 : 1
---     scale <= 6 : (scale / 2) ^ 1.389
---     otherwise  : min((scale / 6) ^ 0.72 * 4.6, 20)
function ScaleConfig.growthMultiplier(scale: number): number
	if scale <= 2 then
		return 1
	end
	if scale <= 6 then
		return (scale / 2) ^ 1.389
	end
	return math.min((scale / 6) ^ 0.72 * 4.6, 20)
end

--- Seconds a newly placed item earns nothing: its base growth time times the
--- multiplier above. A base time of 0 means the item earns immediately.
--- RETAINED for legacy items; the mystery loop's own wait is the hatch timer
--- (HatchConfig), which is the one a player sees.
function ScaleConfig.maturationSeconds(baseGrowthSeconds: number, scale: number): number
	if baseGrowthSeconds <= 0 then
		return 0
	end
	return baseGrowthSeconds * ScaleConfig.growthMultiplier(scale)
end

-- ==========================================================
-- CARRY
-- ==========================================================

--- Above this a carried item or container is compressed and hoisted overhead
--- so the player can still see where they are running. Carry only: sockets,
--- pedestals and the world always show the full saved size.
ScaleConfig.CARRY_KNEE = 2.6

---     carry = min(v, 2.6 + sqrt(max(0, v - 2.6)))
--- Identity up to the knee, never larger than the true size, strictly
--- increasing so the visible order of sizes survives the compression.
function ScaleConfig.carryScale(displayScale: number): number
	local knee = ScaleConfig.CARRY_KNEE
	return math.min(displayScale, knee + math.sqrt(math.max(0, displayScale - knee)))
end

return ScaleConfig
