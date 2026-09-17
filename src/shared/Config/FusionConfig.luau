--!strict
--[[
	FusionConfig
	Item fusion: three stored copies of the SAME item become one better copy.

	THE RULE
	  * Inputs: exactly FusionConfig.INPUTS distinct stored instances of one
	    ItemId, all revealed (a sealed container is never an input - nobody
	    knows what it is yet). Size and mutation may differ.
	  * Size: the result is ONE SIZE CLASS above the best input (by the size
	    ladder in ScaleConfig.Variants), capped at the largest. Its Scale is
	    drawn uniformly inside that class's range; at the cap it is never
	    below the best input's own Scale. Fusion never shrinks anything.
	  * Mutation: one roll on `MutationOdds` below. The best input mutation is
	    a FLOOR: a roll under it lands on it instead, so fusion never
	    downgrades a mutation either. `mutationOutcomes` gives the effective
	    odds after that floor, which is exactly what the panel shows.
	  * Cost: Cash only, scaled by the item's income (see `costFor`).

	POLICY. The mutation roll is random, so fusion is NEVER sold for Robux:
	Cash only, which is why it is offered to every player regardless of
	PolicyService. Do not add a Robux path to it.

	Income is never stored here: the result's FinalIncome comes from
	RarityConfig.finalIncome through DataService.reconcileItem, the same
	path every loaded item takes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)

local FusionConfig = {}

--- Copies consumed per fusion.
FusionConfig.INPUTS = 3

--- The mutation roll, in percent, weakest first. Deliberately kinder than
--- the spawn roll (RarityConfig.Mutations, locked: 90 / 6 / 2.5 / 1 / 0.5):
--- spending three copies and Cash should feel like a chance at something.
--- Every id must exist in RarityConfig.Mutations; validate checks the sum.
FusionConfig.MutationOdds = {
	{ id = "Normal", chance = 62 },
	{ id = "Shiny", chance = 22 },
	{ id = "Golden", chance = 10 },
	{ id = "Flaming", chance = 4.5 },
	{ id = "Corrupted", chance = 1.5 },
} :: { { id: string, chance: number } }

--- COST = max(MIN_COST, COST_INCOME_SECONDS x the result's card rate at the
--- bottom of its size class with no mutation). Five minutes of what the
--- result will earn: cheap next to what three copies sell for early on,
--- meaningful at every stage because it follows the item's own income.
FusionConfig.COST_INCOME_SECONDS = 300
FusionConfig.MIN_COST = 250

--- The glowing fusion-machine art (docs/codex-prompts). "rbxassetid://0" =
--- not made yet; the popup then shows no icon.
FusionConfig.ICON = "rbxassetid://0"

--- Server request budget (FusionRequest), per player.
FusionConfig.REQUESTS_PER_SECOND = 2

--- The client's fusion animation (FusionController). Seconds.
FusionConfig.Animation = {
	--- The three thumbnails spin inward and merge.
	spin = 1.1,
	--- The flash on the merge.
	flash = 0.25,
	--- The result card holds before it can be dismissed by the timer.
	hold = 2.6,
	--- Reduced Effects: one short fade instead of the spin.
	reduced = 0.35,
}

-- ==========================================================
-- DERIVED
-- ==========================================================

--- The size-class index (1 = Normal ... #Variants) a Scale belongs to.
function FusionConfig.classOf(scale: number): number
	local label = ScaleConfig.labelFor(ScaleConfig.clampScale(scale))
	for index, variant in ScaleConfig.Variants do
		if variant.id == label then
			return index
		end
	end
	return 1
end

--- The class a fusion produces from the best input class: one up, capped.
function FusionConfig.targetClass(bestClass: number): number
	return math.clamp(bestClass + 1, 1, #ScaleConfig.Variants)
end

--- The result's Scale for a given target class and random draw `u` in
--- [0, 1). `floorScale` is the best input's Scale: at the cap the result is
--- never smaller than it.
function FusionConfig.scaleFor(targetClass: number, u: number, floorScale: number): number
	local variant = ScaleConfig.Variants[targetClass] or ScaleConfig.Variants[#ScaleConfig.Variants]
	local drawn = ScaleConfig.roundScale(variant.min + math.clamp(u, 0, 1) * (variant.max - variant.min))
	return ScaleConfig.clampScale(math.max(drawn, floorScale))
end

--- The effective mutation odds once `floorId` is applied: every outcome
--- below the floor is folded into the floor. Returns rows weakest first,
--- percentages summing to the table's total.
function FusionConfig.mutationOutcomes(floorId: string?): { { id: string, chance: number } }
	local floorRank = RarityConfig.mutationRank(RarityConfig.normaliseMutation(floorId))
	local out: { { id: string, chance: number } } = {}
	local folded = 0
	for _, row in FusionConfig.MutationOdds do
		if RarityConfig.mutationRank(row.id) <= floorRank then
			folded += row.chance
		else
			table.insert(out, { id = row.id, chance = row.chance })
		end
	end
	local floorName = RarityConfig.Mutations[floorRank + 1]
	table.insert(out, 1, { id = if floorName then floorName.id else "Normal", chance = folded })
	return out
end

--- ONE mutation roll with the floor applied. `roll` is a number in [0, 1).
function FusionConfig.rollMutation(floorId: string?, roll: number): string
	local total = 0
	for _, row in FusionConfig.MutationOdds do
		total += row.chance
	end
	local target = math.clamp(roll, 0, 1) * total
	local cursor = 0
	local picked = FusionConfig.MutationOdds[#FusionConfig.MutationOdds].id
	for _, row in FusionConfig.MutationOdds do
		cursor += row.chance
		if target < cursor then
			picked = row.id
			break
		end
	end
	local floor = RarityConfig.normaliseMutation(floorId)
	if RarityConfig.mutationRank(picked) < RarityConfig.mutationRank(floor) then
		return floor
	end
	return picked
end

--- What a fusion into `targetClass` of an item with base income `baseIncome`
--- costs. Whole dollars.
function FusionConfig.costFor(baseIncome: number, targetClass: number): number
	local variant = ScaleConfig.Variants[targetClass] or ScaleConfig.Variants[#ScaleConfig.Variants]
	local rate = RarityConfig.finalIncome(math.max(tonumber(baseIncome) or 0, 0), variant.min, "Normal")
	return math.floor(math.max(FusionConfig.MIN_COST, rate * FusionConfig.COST_INCOME_SECONDS))
end

return FusionConfig
