--!strict
--[[
	Config validation - Phase 1 acceptance test (GDD section 19).

	Confirms: 12 zones x 8 items, four sockets per zone, no duplicate ItemIds,
	Secret absent from zones 1-4, rarity weights totalling 100, and variant
	chances totalling 100.

	Run from the command bar:
		require(game.ReplicatedStorage.Shared.Config.validate)()
]]

local LootConfig = require(script.Parent.LootConfig)
local RarityConfig = require(script.Parent.RarityConfig)
local ZoneConfig = require(script.Parent.ZoneConfig)
local BaseConfig = require(script.Parent.BaseConfig)
local TreadmillConfig = require(script.Parent.TreadmillConfig)
local GameConfig = require(script.Parent.GameConfig)

type Report = { passed: number, failed: { string } }

return function(): Report
	local report: Report = { passed = 0, failed = {} }

	local function check(condition: boolean, message: string)
		if condition then
			report.passed += 1
		else
			table.insert(report.failed, message)
		end
	end

	-- Zones
	check(ZoneConfig.COUNT == 12, `expected 12 zones, got {ZoneConfig.COUNT}`)
	check(ZoneConfig.SOCKETS_PER_ZONE == 4, "expected 4 sockets per zone")
	check(#LootConfig.Items == 12, `expected 12 item pools, got {#LootConfig.Items}`)

	-- Item pools
	local seen: { [string]: number } = {}
	for zoneIndex, pool in LootConfig.Items do
		check(#pool == 8, `zone {zoneIndex}: expected 8 item types, got {#pool}`)

		local chanceTotal = 0
		for _, item in pool do
			if seen[item.id] then
				table.insert(report.failed, `duplicate ItemId "{item.id}" in zones {seen[item.id]} and {zoneIndex}`)
			else
				seen[item.id] = zoneIndex
				report.passed += 1
			end

			check(item.income > 0, `{item.id}: income must be positive`)
			check(
				RarityConfig.Colors[item.rarity] ~= nil,
				`{item.id}: unknown rarity "{item.rarity}"`
			)

			if item.rarity == "Secret" then
				check(
					zoneIndex >= RarityConfig.SECRET_FIRST_ZONE,
					`Secret item "{item.id}" appears in zone {zoneIndex}; Secret starts at zone {RarityConfig.SECRET_FIRST_ZONE}`
				)
			end

			chanceTotal += item.chance
		end

		check(
			math.abs(chanceTotal - 1) < 0.02,
			`zone {zoneIndex}: item chances total {string.format("%.3f", chanceTotal)}, expected ~1.0`
		)
	end

	local total = 0
	for _ in seen do
		total += 1
	end
	check(total == 96, `expected 96 unique items, got {total}`)

	-- Zone ids must match the generated map folders
	for _, zone in ZoneConfig.Zones do
		check(zone.id:match("^Zone%d%d_") ~= nil, `zone {zone.index}: malformed id "{zone.id}"`)
	end

	-- Rarity weights
	for band, weights in RarityConfig.Weights do
		local sum = 0
		for _, w in weights do
			sum += w
		end
		check(sum == 100, `rarity band "{band}" totals {sum}, expected 100`)
	end
	check(RarityConfig.Weights.early.Secret == 0, "Secret must be weight 0 in zones 1-4")

	-- Variants
	for label, list in { Size = RarityConfig.Sizes, Mutation = RarityConfig.Mutations } do
		local sum = 0
		for _, v in list do
			sum += v.chance
		end
		check(math.abs(sum - 100) < 0.001, `{label} chances total {sum}, expected 100`)
	end

	-- Capacity and treadmill ladders
	check(BaseConfig.slotsForTier(0) == GameConfig.STARTING_DISPLAY_SLOTS, "tier 0 must grant the starting slot count")
	check(
		BaseConfig.slotsForTier(BaseConfig.MAX_TIER) == GameConfig.MAX_DISPLAY_SLOTS,
		"max tier must reach 14 slots"
	)
	for i = 2, #BaseConfig.CapacityTiers do
		check(
			BaseConfig.CapacityTiers[i].cost > BaseConfig.CapacityTiers[i - 1].cost,
			`capacity tier {i - 1}: cost must increase`
		)
	end
	for i = 2, #TreadmillConfig.Tiers do
		check(
			TreadmillConfig.Tiers[i].gainPerTick > TreadmillConfig.Tiers[i - 1].gainPerTick,
			`treadmill level {i}: gain must increase`
		)
	end

	-- Anchors the GDD locks exactly
	check(LootConfig.ById["Museum_AncientVase"].income == 967, "tutorial vase must be exactly $967/s")
	check(TreadmillConfig.Tiers[1].gainPerTick == 2, "Basic treadmill must be +2/tick (~8/s)")
	check(TreadmillConfig.Tiers[2].gainPerTick == 12, "Tier 2 treadmill must be +12/tick (~48/s)")
	check(
		math.abs(GameConfig.walkSpeedFromPower(10) - 18.26) < 0.05,
		"Speed 10 must map to ~18.3 WalkSpeed"
	)

	if #report.failed == 0 then
		print(`[Config] validation PASSED - {report.passed} checks`)
	else
		warn(`[Config] validation FAILED - {#report.failed} problem(s):`)
		for _, message in report.failed do
			warn("  - " .. message)
		end
	end

	return report
end
