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
	scale: number?, -- Model:ScaleTo factor, Size rolls only
	movePenalty: number?, -- fraction of WalkSpeed lost while carrying
}

RarityConfig.Sizes = {
	{ id = "Normal", chance = 70, multiplier = 1.00, scale = 1.00, movePenalty = 0.00 },
	{ id = "Big", chance = 20, multiplier = 1.35, scale = 1.35, movePenalty = 0.04 },
	{ id = "Huge", chance = 8, multiplier = 2.00, scale = 1.80, movePenalty = 0.10 },
	{ id = "Giant", chance = 2, multiplier = 3.50, scale = 2.60, movePenalty = 0.18 },
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
