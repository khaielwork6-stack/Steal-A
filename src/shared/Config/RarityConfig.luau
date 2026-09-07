--!strict
--[[
	RarityConfig
	The rarity ladder, the normal spawn weights, and the Size / Mutation variant
	rolls.

	THREE THINGS LIVE HERE AND NOWHERE ELSE:

	1. `Order` - the ten global rarity tiers, weakest first. Adding a tier means
	   adding a colour and (if it should spawn normally) a weight. Nothing else in
	   the codebase enumerates rarity names.

	2. `NormalWeights` - the per-socket roller. Deliberately top-heavy: most loot
	   in a zone should be mediocre, so that the rare thing feels enormous. These
	   seven tiers sum to 100 and are the ONLY tiers an ordinary socket can roll.

	3. `ZoneLadders` - which rarity each of a zone's eight item slots wears.
	   Position 8 is the zone's JACKPOT and is deliberately given a tier that
	   carries NO normal weight, so it can never fall out of an ordinary socket
	   roll. It arrives only through the global refresh jackpot event
	   (LootService.rollJackpot).

	Early zones top out at Cosmic; Secret becomes possible at the North Pole,
	Eternal in the Secret Lab, Divine on the Construction Site. Meeting the
	strongest labels stays a progression event rather than a first-hour accident.
]]

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
-- NORMAL SPAWN WEIGHTS
-- ==========================================================
--
-- Percentages, totalling 100. Every ordinary socket roll - on server start and
-- at every global refresh - draws from exactly this table.
--
-- Tiers absent from this table (Secret, Eternal, Divine) have no normal spawn
-- path at all. That is the whole point: the top item in a zone is a world event,
-- not a 1-in-50 socket.

RarityConfig.NormalWeights = {
	Common = 35,
	Uncommon = 27,
	Rare = 18,
	Epic = 11,
	Legendary = 6,
	Mythic = 2.5,
	Cosmic = 0.5,
} :: { [string]: number }

--- True when a tier can appear from an ordinary socket roll.
function RarityConfig.isNormallyRollable(rarity: string): boolean
	return (RarityConfig.NormalWeights[rarity] or 0) > 0
end

-- ==========================================================
-- ZONE LADDERS
-- ==========================================================
--
-- Eight entries, one per item slot, in the zone's own income order (which is
-- NOT always ascending - see the Bank). Position 8 is the jackpot.
--
-- To retune which zones can host which top tier, edit ONLY this table.

export type Ladder = { string }

-- zones 1-4: the chase tops out at Cosmic. Two Commons because the first two
-- items in these zones are both deliberate garbage.
local EARLY: Ladder =
	{ "Common", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic" }
-- zones 5-8: Secret becomes possible
local MID: Ladder =
	{ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret" }
-- zones 9-10: Eternal
local LATE: Ladder =
	{ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Eternal" }
-- zones 11-12: Divine
local APEX: Ladder =
	{ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Divine" }

--- Highest zone index each ladder covers, ascending. Read by `ladderFor`.
RarityConfig.ZoneLadders = {
	{ maxZone = 4, ladder = EARLY },
	{ maxZone = 8, ladder = MID },
	{ maxZone = 10, ladder = LATE },
	{ maxZone = math.huge, ladder = APEX },
}

--- The eight-entry rarity ladder a zone uses.
function RarityConfig.ladderFor(zoneIndex: number): Ladder
	for _, band in RarityConfig.ZoneLadders do
		if zoneIndex <= band.maxZone then
			return band.ladder
		end
	end
	return APEX
end

--- Rarity of slot `position` (1-8) in a zone.
function RarityConfig.rarityAt(zoneIndex: number, position: number): string
	local ladder = RarityConfig.ladderFor(zoneIndex)
	return ladder[position] or ladder[#ladder]
end

--- The slot that carries a zone's jackpot. One number, deliberately not scattered.
RarityConfig.JACKPOT_POSITION = 8

--- The tier a zone's jackpot wears.
function RarityConfig.jackpotRarityFor(zoneIndex: number): string
	return RarityConfig.rarityAt(zoneIndex, RarityConfig.JACKPOT_POSITION)
end

--- First zone whose ladder can show Secret. Derived, not typed, so moving a band
--- boundary above cannot leave a stale constant behind.
RarityConfig.SECRET_FIRST_ZONE = (function(): number
	for zoneIndex = 1, 12 do
		if RarityConfig.jackpotRarityFor(zoneIndex) == "Secret" then
			return zoneIndex
		end
	end
	return math.huge
end)()

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
-- VARIANTS
-- ==========================================================

export type Variant = {
	id: string,
	chance: number, -- percent
	multiplier: number,
	scale: number?, -- Model:ScaleTo factor, Size rolls only: the LOW end of the visual range
	scaleMax: number?, -- Size rolls only: the HIGH end of the visual range; nil = fixed
	movePenalty: number?, -- fraction of WalkSpeed lost while carrying
}

-- Sizes. Weakest first; the ORDER is the hierarchy (see sizeRank). Chances
-- total 100. The old 2% Giant is split three ways, so an "exceptional giant"
-- is still 2% overall - but the top of that 2% is now absurd on purpose: a
-- Colossal is fifteen to twenty times the authored model, and a Common can
-- roll it just as a Divine can roll Normal.
--
-- `scale` / `scaleMax` are the VISUAL range for the tier. A tier with a range
-- rolls ONE value inside it when the instance is created and that value is
-- saved on the item (VisualScale) - a model is never rerolled on render, so
-- the same Colossal is the same size in the world, in the hand and on the
-- pedestal, and after a rejoin. `multiplier` is income, and deliberately does
-- NOT track the visual: a 20x model earns 6x, not 20x.
RarityConfig.Sizes = {
	{ id = "Normal", chance = 70, multiplier = 1.00, scale = 1.00, movePenalty = 0.00 },
	{ id = "Big", chance = 20, multiplier = 1.35, scale = 1.35, movePenalty = 0.04 },
	{ id = "Huge", chance = 8, multiplier = 2.00, scale = 1.80, movePenalty = 0.10 },
	{ id = "Giant", chance = 1.5, multiplier = 3.50, scale = 2.60, movePenalty = 0.18 },
	{ id = "Titan", chance = 0.4, multiplier = 4.50, scale = 6.00, scaleMax = 8.00, movePenalty = 0.22 },
	{ id = "Colossal", chance = 0.1, multiplier = 6.00, scale = 15.00, scaleMax = 20.00, movePenalty = 0.25 },
} :: { Variant }

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

--- Index a variant list by id.
local function byId(list: { Variant }): { [string]: Variant }
	local map = {}
	for _, v in list do
		map[v.id] = v
	end
	return map
end

RarityConfig.SizeById = byId(RarityConfig.Sizes)
RarityConfig.MutationById = byId(RarityConfig.Mutations)

-- ==========================================================
-- SIZE HELPERS
-- ==========================================================

--- 1 for Normal, rising to 6 for Colossal. The list order IS the hierarchy.
RarityConfig.SizeRank = {} :: { [string]: number }
for index, size in RarityConfig.Sizes do
	RarityConfig.SizeRank[size.id] = index
end

--- 0 for an unknown id, so a stale save can never crash a comparison.
function RarityConfig.sizeRank(id: string?): number
	return if id then (RarityConfig.SizeRank[id] or 0) else 0
end

--- The low end of a tier's visual range: what an item of that size shows when
--- no exact scale was ever rolled for it (every save from before ranges
--- existed). 1 for an unknown id.
function RarityConfig.defaultVisualScale(sizeId: string?): number
	local size = if sizeId then RarityConfig.SizeById[sizeId] else nil
	return if size then (size.scale or 1) else 1
end

--- ONE visual scale for a freshly created instance: uniform inside the tier's
--- range, or the tier's fixed value. Rounded so the saved number is stable.
function RarityConfig.rollVisualScale(sizeId: string): number
	local size = RarityConfig.SizeById[sizeId]
	if not size then
		return 1
	end
	local low = size.scale or 1
	local high = size.scaleMax or low
	if high <= low then
		return low
	end
	return math.floor((low + math.random() * (high - low)) * 100 + 0.5) / 100
end

--- A stored visual scale, made safe: it must be a finite number inside the
--- tier's own range, otherwise the tier's default. A save cannot carry a 200x
--- item, and a legacy item without the field simply gets the tier's low end.
function RarityConfig.clampVisualScale(sizeId: string?, value: any): number
	local fallback = RarityConfig.defaultVisualScale(sizeId)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	local size = if sizeId then RarityConfig.SizeById[sizeId] else nil
	if not size then
		return fallback
	end
	local low = size.scale or 1
	local high = size.scaleMax or low
	return math.clamp(value, low, high)
end

--- Up to Giant a carried item is shown at its true size. Above that the
--- visual is compressed - a twenty-times statue welded to a player's chest
--- covers the camera and makes the run home unplayable - while keeping the
--- ordering: a Colossal in the hand is still visibly bigger than a Titan,
--- which is bigger than a Giant. Income, penalty and the saved size are
--- untouched by this; it is presentation only.
RarityConfig.CARRY_SCALE_KNEE = 2.6

function RarityConfig.carryVisualScale(visualScale: number): number
	local knee = RarityConfig.CARRY_SCALE_KNEE
	if visualScale <= knee then
		return visualScale
	end
	return knee + math.sqrt(visualScale - knee)
end

--- FinalIncome = base * size * mutation.
---
--- Rolled once when the instance spawns and then frozen ON THE INSTANCE - never
--- rerolled after a successful steal. It is, however, RECOMPUTED from the
--- authoritative config whenever a profile loads, so an economy change reaches
--- every saved trophy instead of leaving old numbers earning forever.
function RarityConfig.finalIncome(baseIncome: number, sizeId: string, mutationId: string): number
	local size = RarityConfig.SizeById[sizeId]
	local mutation = RarityConfig.MutationById[RarityConfig.normaliseMutation(mutationId)]
	if not size or not mutation then
		return baseIncome
	end
	return math.floor(baseIncome * size.multiplier * mutation.multiplier)
end

return RarityConfig
