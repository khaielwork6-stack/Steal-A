--!strict
--[[
	RarityConfig
	The rarity ladder, the per-zone rarity assignments, the size LABELS and the
	Mutation variant roll.

	WHAT LIVES HERE AND NOWHERE ELSE:

	1. `Order` - the ten global rarity tiers, weakest first. Nothing else in the
	   codebase enumerates rarity names.

	2. `ZoneRarities` - which rarity each of a zone's eight item slots wears,
	   per zone, matching the reference progression slot for slot (zones 1-11).
	   Rarity is a LABEL: it colours the item, names the Robux steal product,
	   and decides which spawns are announced. It does NOT drive spawn odds any
	   more - each item carries its own zone-specific spawn weight in
	   LootConfig, and every socket rolls from all eight items with those.

	3. `Sizes` - the six size WORDS (Normal ... Colossal) and their carry
	   penalties. A word is derived from the item's continuous Scale
	   (ScaleConfig.labelFor); there is no size roll here and no size income
	   multiplier here. Income is ScaleConfig.sizeFactor(Scale).

	4. `Mutations` - the mutation roll. LOCKED: names, odds, multipliers,
	   aliases and the one-mutation-per-item rule are unchanged and covered by
	   regression tests (EconomyTests).

	RETIRED, ON PURPOSE: the global 35/27/18/11/6/2.5/0.5 rarity weight table,
	the position-eight jackpot, and the discrete size multipliers. The legacy
	size multipliers survive only as `LegacySizeIncomeMultipliers`, which the
	save migration reads once to give each old item the Scale that preserves
	the income it already had.
]]

local ScaleConfig = require(script.Parent.ScaleConfig)

local RarityConfig = {}

export type Rarity =
	"Common" | "Uncommon" | "Rare" | "Epic" | "Legendary"
	| "Mythic" | "Cosmic" | "Secret" | "Eternal" | "Divine"

--- Weakest first. This order IS the hierarchy; anything that needs to compare
--- two rarities should use `RarityConfig.rank`.
RarityConfig.Order = {
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
	"Cosmic",
	"Secret",
	"Eternal",
	"Divine",
}

RarityConfig.Rank = {} :: { [string]: number }
for index, name in RarityConfig.Order do
	RarityConfig.Rank[name] = index
end

--- 0 for an unknown name, so a stale save can never crash a comparison.
function RarityConfig.rank(rarity: string?): number
	return if rarity then (RarityConfig.Rank[rarity] or 0) else 0
end

-- ==========================================================
-- ZONE RARITIES
-- ==========================================================
--
-- Eight entries per zone, one per item slot, in the zone's item order. Zones
-- 1-11 are the reference game's verified slot rarities. Zone 12 is this
-- game's own post-game extension (GameConfig.POSTGAME_EXTENSION); it keeps
-- the ladder it shipped with and takes no part in any parity claim.

export type Ladder = { string }

local C, U, R, E, L, M, Co, S, Et, D =
	"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine"

RarityConfig.ZoneRarities = {
	[1] = { C, C, U, R, R, E, E, L },
	[2] = { C, C, U, R, E, E, L, Co },
	[3] = { C, U, R, E, L, M, M, Co },
	[4] = { R, R, E, L, L, M, M, S },
	[5] = { R, E, L, M, M, Co, S, Et },
	[6] = { R, E, L, L, M, S, Et, Et },
	[7] = { R, E, L, M, Co, Co, S, Et },
	[8] = { R, L, M, Co, Co, S, S, Et },
	[9] = { E, L, M, Co, S, S, Et, D },
	[10] = { E, L, M, Co, Co, S, Et, D },
	[11] = { L, L, M, Co, Co, S, Et, D },
	-- Post-game (no reference equivalent): the ladder Zone 12 already had.
	[12] = { C, U, R, E, L, M, Co, D },
} :: { [number]: Ladder }

--- The eight-entry rarity ladder a zone uses.
function RarityConfig.ladderFor(zoneIndex: number): Ladder
	return RarityConfig.ZoneRarities[zoneIndex] or RarityConfig.ZoneRarities[#RarityConfig.ZoneRarities]
end

--- Rarity of slot `position` (1-8) in a zone.
function RarityConfig.rarityAt(zoneIndex: number, position: number): string
	local ladder = RarityConfig.ladderFor(zoneIndex)
	return ladder[position] or ladder[#ladder]
end

--- The highest rarity a zone can produce. Wears the zone-sign cap colour.
function RarityConfig.topRarityFor(zoneIndex: number): string
	local best = "Common"
	for _, rarity in RarityConfig.ladderFor(zoneIndex) do
		if RarityConfig.rank(rarity) > RarityConfig.rank(best) then
			best = rarity
		end
	end
	return best
end

--- First zone whose ladder can show Secret. Derived, never typed.
RarityConfig.SECRET_FIRST_ZONE = (function(): number
	for zoneIndex = 1, 12 do
		for _, rarity in RarityConfig.ladderFor(zoneIndex) do
			if rarity == "Secret" then
				return zoneIndex
			end
		end
	end
	return math.huge
end)()

--- Spawns at or above this rarity are called out when the zones reopen.
--- ANNOUNCEMENT ONLY: nothing here feeds back into a roll.
RarityConfig.ANNOUNCE_MIN_RARITY = "Secret"

-- Player-facing colours, also used for rarity beams, labels and zone-sign caps.
-- Every tier in `Order` MUST have one; validate.luau enforces it.
RarityConfig.Colors = {
	Common = Color3.fromRGB(198, 205, 216),
	Uncommon = Color3.fromRGB(96, 220, 118),
	Rare = Color3.fromRGB(74, 156, 255),
	Epic = Color3.fromRGB(180, 106, 255),
	Legendary = Color3.fromRGB(255, 178, 46),
	Mythic = Color3.fromRGB(255, 78, 78),
	Cosmic = Color3.fromRGB(72, 240, 226),
	Secret = Color3.fromRGB(255, 74, 140),
	Eternal = Color3.fromRGB(255, 238, 150),
	Divine = Color3.fromRGB(255, 255, 255),
}

--- Old rarity names that may sit in saved profiles. Every current name maps to
--- itself, so this is only ever consulted for genuinely retired ids. Saved
--- rarity is recomputed from LootConfig on load anyway (DataService.reconcile);
--- this exists so a display path reading a raw stored value cannot show a blank.
RarityConfig.RarityAliases = {} :: { [string]: string }

--- Always safe: returns a known tier name for any input.
function RarityConfig.normaliseRarity(rarity: string?): string
	if not rarity then
		return "Common"
	end
	local mapped = RarityConfig.RarityAliases[rarity] or rarity
	return if RarityConfig.Rank[mapped] then mapped else "Common"
end

-- ==========================================================
-- SIZE LABELS
-- ==========================================================

export type SizeLabel = {
	id: string,
	movePenalty: number, -- fraction of WalkSpeed lost while carrying
}

--- The six words, weakest first; the ORDER is the hierarchy (see sizeRank).
--- Which word an item wears comes from its Scale (ScaleConfig.labelFor).
--- No chance and no income multiplier live here any more.
RarityConfig.Sizes = {
	{ id = "Normal", movePenalty = 0.00 },
	{ id = "Big", movePenalty = 0.04 },
	{ id = "Huge", movePenalty = 0.10 },
	{ id = "Giant", movePenalty = 0.18 },
	{ id = "Titan", movePenalty = 0.22 },
	{ id = "Colossal", movePenalty = 0.25 },
} :: { SizeLabel }

RarityConfig.SizeById = {} :: { [string]: SizeLabel }
RarityConfig.SizeRank = {} :: { [string]: number }
for index, size in RarityConfig.Sizes do
	RarityConfig.SizeById[size.id] = size
	RarityConfig.SizeRank[size.id] = index
end

--- 0 for an unknown id, so a stale save can never crash a comparison.
function RarityConfig.sizeRank(id: string?): number
	return if id then (RarityConfig.SizeRank[id] or 0) else 0
end

--- The word for a Scale. One definition, shared by the world label, the
--- trophy, the inventory card and the announcer.
function RarityConfig.sizeLabelFor(scale: number): string
	return ScaleConfig.labelFor(scale)
end

--- The carried size for a display scale. Carry only; see ScaleConfig.
function RarityConfig.carryVisualScale(displayScale: number): number
	return ScaleConfig.carryScale(displayScale)
end

--- Above this display scale a carried item is hoisted overhead (CarryService)
--- and the client stops the idle hover. Mirrors ScaleConfig.CARRY_KNEE.
RarityConfig.CARRY_SCALE_KNEE = ScaleConfig.CARRY_KNEE

--- THE INCOME MULTIPLIERS THE SIX WORDS USED TO CARRY (1 / 1.35 / 2 / 3.5 /
--- 4.5 / 6). Read by the save migration ONLY: a legacy item's Scale is the
--- value whose sizeFactor equals the multiplier its word gave it, so the
--- income it earned before the rebuild is the income it earns after. Never
--- read by the roller or by the rate.
RarityConfig.LegacySizeIncomeMultipliers = {
	Normal = 1.00,
	Big = 1.35,
	Huge = 2.00,
	Giant = 3.50,
	Titan = 4.50,
	Colossal = 6.00,
} :: { [string]: number }

--- THE VISUAL LADDERS THE SIX WORDS USED TO ROLL INSIDE. Kept for the older
--- (v9) migration step, which still has to run for a save from before it.
--- Never read by the roller.
RarityConfig.LegacySizeRanges = {
	Normal = { 1.00, 1.00 },
	Big = { 1.35, 1.35 },
	Huge = { 1.80, 1.80 },
	Giant = { 2.60, 2.60 },
	Titan = { 6.00, 8.00 },
	Colossal = { 15.00, 20.00 },
} :: { [string]: { number } }

--- The v9 visual ladder the v9 migration maps INTO (1 / 1.6 / 2.5 / 4 /
--- 7-10 / 16-22). A legacy item keeps this as its display size
--- (LegacyVisualScale) so it looks exactly as it did.
RarityConfig.V9VisualRanges = {
	Normal = { 1.00, 1.00 },
	Big = { 1.60, 1.60 },
	Huge = { 2.50, 2.50 },
	Giant = { 4.00, 4.00 },
	Titan = { 7.00, 10.00 },
	Colossal = { 16.00, 22.00 },
} :: { [string]: { number } }

RarityConfig.SIZE_VISUAL_VERSION = 2

--- v9's one-time mapping of a pre-v9 visual scale into the v9 ranges, by
--- relative position. Still needed for saves that skipped v9.
function RarityConfig.migrateVisualScale(sizeId: string?, legacy: any): number
	local oldRange = if sizeId then RarityConfig.LegacySizeRanges[sizeId] else nil
	local newRange = if sizeId then RarityConfig.V9VisualRanges[sizeId] else nil
	if not oldRange or not newRange then
		return 1
	end
	local oldLow, oldHigh = oldRange[1], oldRange[2]
	local low, high = newRange[1], newRange[2]
	local value = if type(legacy) == "number" and legacy == legacy and legacy ~= math.huge and legacy ~= -math.huge
		then legacy
		else oldLow
	local t = if oldHigh > oldLow then math.clamp((value - oldLow) / (oldHigh - oldLow), 0, 1) else 0
	return math.floor((low + t * (high - low)) * 100 + 0.5) / 100
end

-- ==========================================================
-- MUTATIONS - LOCKED. Do not edit this section.
-- ==========================================================

export type Variant = {
	id: string,
	chance: number, -- percent
	multiplier: number,
}

-- Locked ladder, rarest and best last:
--   Normal -> Shiny -> Golden -> Flaming -> Corrupted
-- The order of this list IS the hierarchy; the VFX escalate along it.
RarityConfig.Mutations = {
	{ id = "Normal", chance = 90.0, multiplier = 1.00 },
	{ id = "Shiny", chance = 6.0, multiplier = 1.25 },
	{ id = "Golden", chance = 2.5, multiplier = 2.00 },
	{ id = "Flaming", chance = 1.0, multiplier = 2.50 },
	{ id = "Corrupted", chance = 0.5, multiplier = 3.00 },
} :: { Variant }

--- Pre-rename ids that may still exist in saved profiles. Mapped rather than
--- dropped so an old item keeps its tier instead of silently becoming Normal.
RarityConfig.MutationAliases = {
	Neon = "Flaming",
	Glitched = "Corrupted",
} :: { [string]: string }

--- Always run a stored mutation id through this before using it.
function RarityConfig.normaliseMutation(id: string?): string
	if not id then
		return "Normal"
	end
	return RarityConfig.MutationAliases[id] or id
end

--- Tint for the mutation glow, and the fallback when an item has no VFX asset.
RarityConfig.MutationColors = {
	Shiny = Color3.fromRGB(226, 244, 255),
	Golden = Color3.fromRGB(255, 205, 60),
	Flaming = Color3.fromRGB(255, 122, 36),
	Corrupted = Color3.fromRGB(168, 62, 255),
}

--- 0 for Normal, rising to 4 for Corrupted. Used to escalate intensity.
function RarityConfig.mutationRank(id: string): number
	for index, mutation in RarityConfig.Mutations do
		if mutation.id == id then
			return index - 1
		end
	end
	return 0
end

RarityConfig.MutationById = {} :: { [string]: Variant }
for _, mutation in RarityConfig.Mutations do
	RarityConfig.MutationById[mutation.id] = mutation
end

--- The mutation's income multiplier, 1 for Normal or an unknown id.
function RarityConfig.mutationMultiplier(mutationId: string?): number
	local mutation = RarityConfig.MutationById[RarityConfig.normaliseMutation(mutationId)]
	return if mutation then mutation.multiplier else 1
end

-- ==========================================================
-- INCOME
-- ==========================================================

--- THE PER-ITEM RATE, before server-wide boosts:
---     preBoostRate = max( round( base x sizeFactor(Scale) x mutation x moneyPass ), 1 )
--- `moneyPassFactor` is 2 for an owner with the 2x Cash pass, else 1 - it is
--- INSIDE the rounding, per item, exactly once. Rounded half away from zero
--- (math.round), floored at 1 so nothing a player owns earns nothing.
function RarityConfig.preBoostRate(baseIncome: number, scale: number, mutationId: string?, moneyPassFactor: number?): number
	local rate = baseIncome
		* ScaleConfig.sizeFactor(scale)
		* RarityConfig.mutationMultiplier(mutationId)
		* (moneyPassFactor or 1)
	return math.max(math.round(rate), 1)
end

--- The rate a saved item shows on its own card (no owner boosts): the
--- pre-boost rate at moneyPass 1. Recomputed from Scale on every load.
function RarityConfig.finalIncome(baseIncome: number, scale: number, mutationId: string?): number
	return RarityConfig.preBoostRate(baseIncome, scale, mutationId, 1)
end

return RarityConfig
