--!strict
--[[
	IndexConfig
	Reward tuning for the Loot Index (GDD section 13, phase 9).

	DISCOVERY is recorded on a successful PLACEMENT, not on a steal - carrying an
	item home is the achievement, and PlacementService already writes it.

	REWARDS ARE DERIVED, NOT TYPED.
	There are twelve zones whose incomes span five orders of magnitude, so a table
	of hand-written payouts would be twelve numbers to re-tune every time the
	economy moves. Instead each zone's reward is expressed as a ratio against
	numbers that already exist in LootConfig and ZoneConfig:

	  * cash  = CASH_SECONDS x (combined base income of that zone's eight items)
	            i.e. "a few minutes of owning the complete set"
	  * speed = SPEED_FRACTION x (the NEXT zone's recommended Speed)
	            i.e. a real push toward the next gate, never a way to skip it
	  * income bonus = a small permanent multiplier, the reason to finish a set
	                   long after its cash has stopped mattering

	Change the three ratios below and all twelve zones re-balance together.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local IndexConfig = {}

IndexConfig.TOTAL_ITEMS = 96
IndexConfig.ITEMS_PER_ZONE = 8

--- Seconds of the complete set's combined income, paid as a one-off on claim.
IndexConfig.CASH_SECONDS = 90

--- Share of the NEXT zone's recommended Speed granted on claim. Deliberately
--- well under 1: completing a set should shorten the next grind, not delete it.
IndexConfig.SPEED_FRACTION = 0.15

--- Permanent income multiplier added per CLAIMED zone set. Twelve zones -> +24%.
IndexConfig.INCOME_BONUS_PER_ZONE = 0.02

--- Completing all twelve is the long-tail goal, so it pays its own bonus on top:
--- these multiply the summed per-zone rewards.
IndexConfig.COMPLETIONIST_CASH_MULTIPLIER = 0.5
IndexConfig.COMPLETIONIST_SPEED_MULTIPLIER = 0.5
IndexConfig.COMPLETIONIST_INCOME_BONUS = 0.10

export type Reward = {
	cash: number,
	speed: number,
	incomeBonus: number,
}

--- Stable save keys. These are written into Profile.ClaimedIndexRewards and must
--- never be renamed - doing so would silently un-claim every existing player.
function IndexConfig.zoneKey(zoneIndex: number): string
	return `zone_{zoneIndex}`
end

IndexConfig.ALL_ZONES_KEY = "all"

--- Combined BASE income of a zone's eight items.
local function setIncome(zoneIndex: number): number
	local pool = LootConfig.Items[zoneIndex]
	if not pool then
		return 0
	end
	local total = 0
	for _, item in pool do
		total += item.income
	end
	return total
end

--- What finishing one zone's set pays.
function IndexConfig.zoneReward(zoneIndex: number): Reward
	local zone = ZoneConfig.Zones[zoneIndex]
	if not zone then
		return { cash = 0, speed = 0, incomeBonus = 0 }
	end

	-- The last zone has no "next gate" to aim at, so it measures against its own.
	local nextZone = ZoneConfig.Zones[zoneIndex + 1] or zone

	return {
		cash = math.floor(setIncome(zoneIndex) * IndexConfig.CASH_SECONDS),
		speed = math.floor(nextZone.recommendedSpeed * IndexConfig.SPEED_FRACTION),
		incomeBonus = IndexConfig.INCOME_BONUS_PER_ZONE,
	}
end

--- What finishing every zone pays, on top of the twelve individual claims.
function IndexConfig.completionistReward(): Reward
	local cash, speed = 0, 0
	for index = 1, ZoneConfig.COUNT do
		local reward = IndexConfig.zoneReward(index)
		cash += reward.cash
		speed += reward.speed
	end
	return {
		cash = math.floor(cash * IndexConfig.COMPLETIONIST_CASH_MULTIPLIER),
		speed = math.floor(speed * IndexConfig.COMPLETIONIST_SPEED_MULTIPLIER),
		incomeBonus = IndexConfig.COMPLETIONIST_INCOME_BONUS,
	}
end

--- Total permanent income multiplier earned from claimed sets. Returns 1.0 for a
--- player who has claimed nothing, so it is always safe to multiply by.
--- Reads CLAIMED rewards, not completed ones: the claim is the moment the player
--- sees and feels the reward, so it is also the moment it applies.
function IndexConfig.incomeMultiplier(claimed: { [string]: boolean }): number
	local bonus = 0
	for index = 1, ZoneConfig.COUNT do
		if claimed[IndexConfig.zoneKey(index)] then
			bonus += IndexConfig.INCOME_BONUS_PER_ZONE
		end
	end
	if claimed[IndexConfig.ALL_ZONES_KEY] then
		bonus += IndexConfig.COMPLETIONIST_INCOME_BONUS
	end
	return 1 + bonus
end

return IndexConfig
