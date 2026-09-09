--!strict
--[[
	IndexConfig
	Reward tuning for the Loot Index.

	DISCOVERY is recorded on a successful PLACEMENT, not on a steal - carrying an
	item home is the achievement, and PlacementService already writes it.

	TWO KINDS OF REWARD, BOTH ONE-TIME:
	  * DISCOVERY - paid the first time an item reaches a display slot: Cash
	    equal to DISCOVERY_CASH_SECONDS x that item's Scale-1, unmutated,
	    rounded base income. Ninety-six of these, one per item.
	  * SET CLAIM - the Speed reward for finishing a zone's eight, claimed
	    from the Index panel: SPEED_FRACTION of the NEXT zone's gate, so a
	    completed set shortens the next grind without deleting it.

	NO PERMANENT INCOME PERCENTAGE. The old +2%-per-zone / +10%-completionist
	income multiplier is retired: recurring income is item income and nothing
	else. `incomeMultiplier` still exists and always returns 1, so a client
	that reads it keeps rendering.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local IndexConfig = {}

IndexConfig.TOTAL_ITEMS = 96
IndexConfig.ITEMS_PER_ZONE = 8

--- Seconds of the item's Scale-1 unmutated income, paid once on discovery.
IndexConfig.DISCOVERY_CASH_SECONDS = 100

--- Share of the NEXT zone's recommended Speed granted on a set claim.
IndexConfig.SPEED_FRACTION = 0.15

--- Completing all twelve pays a further Speed bonus: this multiplies the
--- summed per-zone Speed rewards.
IndexConfig.COMPLETIONIST_SPEED_MULTIPLIER = 0.5

export type Reward = {
	cash: number,
	speed: number,
}

--- Stable save keys. These are written into Profile.ClaimedIndexRewards and must
--- never be renamed - doing so would silently un-claim every existing player.
function IndexConfig.zoneKey(zoneIndex: number): string
	return `zone_{zoneIndex}`
end

IndexConfig.ALL_ZONES_KEY = "all"

--- What discovering one item pays: 100 x its Scale-1, unmutated, rounded
--- base income. Zero for an unknown id.
function IndexConfig.discoveryReward(itemId: string): number
	local item = LootConfig.ById[itemId]
	if not item then
		return 0
	end
	local baseRate = RarityConfig.preBoostRate(item.income, 1, "Normal", 1)
	return math.floor(baseRate * IndexConfig.DISCOVERY_CASH_SECONDS)
end

--- What finishing one zone's set pays: Speed only.
function IndexConfig.zoneReward(zoneIndex: number): Reward
	local zone = ZoneConfig.Zones[zoneIndex]
	if not zone then
		return { cash = 0, speed = 0 }
	end
	-- The last zone has no "next gate" to aim at, so it measures against its own.
	local nextZone = ZoneConfig.Zones[zoneIndex + 1] or zone
	return {
		cash = 0,
		speed = math.floor(nextZone.recommendedSpeed * IndexConfig.SPEED_FRACTION),
	}
end

--- What finishing every zone pays, on top of the twelve individual claims.
function IndexConfig.completionistReward(): Reward
	local speed = 0
	for index = 1, ZoneConfig.COUNT do
		speed += IndexConfig.zoneReward(index).speed
	end
	return {
		cash = 0,
		speed = math.floor(speed * IndexConfig.COMPLETIONIST_SPEED_MULTIPLIER),
	}
end

--- Always 1. Kept so existing readers of the summary need no change; the
--- Index no longer multiplies recurring income.
function IndexConfig.incomeMultiplier(_claimed: { [string]: boolean }): number
	return 1
end

return IndexConfig
