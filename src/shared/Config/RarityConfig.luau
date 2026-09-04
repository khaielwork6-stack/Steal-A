--!strict
--[[
	RarityConfig
	Rarity weights, plus the Size and Mutation variant rolls (GDD section 6).

	Secret is LOCKED for zones 1-4 by design: their top-end chase is Legendary, so
	the first Secret in North Pole stays a real milestone.
]]

local RarityConfig = {}

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Secret"

RarityConfig.Order = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Secret" }

-- Weights are percentages and must total 100 for each band.
RarityConfig.Weights = {
	early = { -- zones 1-4, no Secret
		Common = 35,
		Uncommon = 27,
		Rare = 18,
		Epic = 11,
		Legendary = 9,
		Secret = 0,
	},
	late = { -- zones 5-12
		Common = 35,
		Uncommon = 27,
		Rare = 18,
		Epic = 11,
		Legendary = 7,
		Secret = 2,
	},
}

RarityConfig.SECRET_FIRST_ZONE = 5

--- Weight table for a zone.
function RarityConfig.weightsFor(zoneIndex: number)
	return if zoneIndex < RarityConfig.SECRET_FIRST_ZONE
		then RarityConfig.Weights.early
		else RarityConfig.Weights.late
end

-- Player-facing colours, also used for rarity beams and labels.
RarityConfig.Colors = {
	Common = Color3.fromRGB(198, 205, 216),
	Uncommon = Color3.fromRGB(96, 220, 118),
	Rare = Color3.fromRGB(74, 156, 255),
	Epic = Color3.fromRGB(180, 106, 255),
	Legendary = Color3.fromRGB(255, 178, 46),
	Secret = Color3.fromRGB(255, 74, 140),
}

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

--- FinalIncome = base * size * mutation. Rolled once, then frozen on the
--- instance: never reroll after a successful steal.
function RarityConfig.finalIncome(baseIncome: number, sizeId: string, mutationId: string): number
	local size = RarityConfig.SizeById[sizeId]
	local mutation = RarityConfig.MutationById[mutationId]
	if not size or not mutation then
		return baseIncome
	end
	return math.floor(baseIncome * size.multiplier * mutation.multiplier)
end

return RarityConfig
