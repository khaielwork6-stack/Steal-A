--!strict
--[[
	Config validation.

	Confirms the shape of the economy rather than its taste: 12 zones x 8 items,
	four sockets per zone, no duplicate ItemIds, a complete and self-consistent
	rarity ladder, a normal weight table totalling 100, exactly one jackpot per
	zone that no ordinary roll can produce, and the handful of anchors the
	progression is actually pinned to.

	Deliberately does NOT assert every one of the 96 incomes - that would just be
	the table written twice. It asserts the structure the table has to have, plus
	the specific numbers a regression would be silent about.

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

	-- ==========================================================
	-- ZONES
	-- ==========================================================
	check(ZoneConfig.COUNT == 12, `expected 12 zones, got {ZoneConfig.COUNT}`)
	check(ZoneConfig.SOCKETS_PER_ZONE == 4, "expected 4 sockets per zone")
	check(#LootConfig.Items == 12, `expected 12 item pools, got {#LootConfig.Items}`)

	for _, zone in ZoneConfig.Zones do
		check(zone.id:match("^Zone%d%d_") ~= nil, `zone {zone.index}: malformed id "{zone.id}"`)
	end

	-- The Speed gates are the spine of the progression and must stay ascending.
	for index = 2, ZoneConfig.COUNT do
		check(
			ZoneConfig.Zones[index].recommendedSpeed > ZoneConfig.Zones[index - 1].recommendedSpeed,
			`zone {index}: recommended Speed must exceed zone {index - 1}`
		)
	end

	-- ==========================================================
	-- RARITY LADDER
	-- ==========================================================
	check(#RarityConfig.Order == 10, `expected 10 rarity tiers, got {#RarityConfig.Order}`)

	for _, rarity in RarityConfig.Order do
		check(RarityConfig.Colors[rarity] ~= nil, `rarity "{rarity}" has no colour`)
		check(RarityConfig.rank(rarity) > 0, `rarity "{rarity}" has no rank`)
	end

	local weightTotal = 0
	for rarity, weight in RarityConfig.NormalWeights do
		check(RarityConfig.Rank[rarity] ~= nil, `normal weight for unknown rarity "{rarity}"`)
		check(weight > 0, `normal weight for "{rarity}" must be positive or absent`)
		weightTotal += weight
	end
	check(
		math.abs(weightTotal - 100) < 0.001,
		`normal spawn weights total {weightTotal}, expected 100`
	)

	-- Every zone ladder must be eight long and made of known tiers.
	for zoneIndex = 1, ZoneConfig.COUNT do
		local ladder = RarityConfig.ladderFor(zoneIndex)
		check(#ladder == 8, `zone {zoneIndex}: ladder has {#ladder} entries, expected 8`)
		for position, rarity in ladder do
			check(
				RarityConfig.Rank[rarity] ~= nil,
				`zone {zoneIndex} position {position}: unknown rarity "{rarity}"`
			)
		end
	end

	-- The whole point of the jackpot: no ordinary socket roll can produce one.
	-- That is enforced structurally - LootConfig.normalPool excludes it - and
	-- checked per zone below, item by item.
	--
	-- Note it is the ITEM that is excluded, not necessarily its tier. Zones 1-4
	-- cap out at Cosmic on purpose (their jackpot IS the Cosmic item), so Cosmic
	-- still carries a normal weight for the zones where it sits at position 7.
	-- In zones 1-4 that weight simply has no eligible item and the roller
	-- renormalises across the six tiers that do - which keeps the same top-heavy
	-- shape without inventing an early-game Secret.
	for zoneIndex = 5, ZoneConfig.COUNT do
		local rarity = RarityConfig.jackpotRarityFor(zoneIndex)
		check(
			not RarityConfig.isNormallyRollable(rarity),
			`zone {zoneIndex}: jackpot tier "{rarity}" is in the normal weight table and would spawn from ordinary sockets`
		)
	end

	-- Ladders escalate: a later zone can never top out below an earlier one.
	for zoneIndex = 2, ZoneConfig.COUNT do
		check(
			RarityConfig.rank(RarityConfig.jackpotRarityFor(zoneIndex))
				>= RarityConfig.rank(RarityConfig.jackpotRarityFor(zoneIndex - 1)),
			`zone {zoneIndex}: top tier ranks below zone {zoneIndex - 1}`
		)
	end

	check(
		RarityConfig.SECRET_FIRST_ZONE == 5,
		`Secret should first appear in zone 5, got {RarityConfig.SECRET_FIRST_ZONE}`
	)

	-- ==========================================================
	-- ITEM POOLS
	-- ==========================================================
	local seen: { [string]: number } = {}
	for zoneIndex, pool in LootConfig.Items do
		check(#pool == 8, `zone {zoneIndex}: expected 8 item types, got {#pool}`)

		local jackpots = 0
		for position, item in pool do
			if seen[item.id] then
				table.insert(report.failed, `duplicate ItemId "{item.id}" in zones {seen[item.id]} and {zoneIndex}`)
			else
				seen[item.id] = zoneIndex
				report.passed += 1
			end

			check(item.income > 0, `{item.id}: income must be positive`)
			check(item.position == position, `{item.id}: position {item.position} out of place`)
			check(
				item.rarity == RarityConfig.rarityAt(zoneIndex, position),
				`{item.id}: rarity "{item.rarity}" disagrees with the zone ladder`
			)

			if item.jackpot then
				jackpots += 1
				check(
					position == LootConfig.JACKPOT_POSITION,
					`{item.id}: jackpot must sit at position {LootConfig.JACKPOT_POSITION}`
				)
			end
		end

		check(jackpots == 1, `zone {zoneIndex}: expected exactly 1 jackpot, got {jackpots}`)

		-- The normal pool is what an ordinary socket can roll, and it must be
		-- seven items - the eight types minus the jackpot.
		local normal = LootConfig.normalPool(zoneIndex)
		check(#normal == 7, `zone {zoneIndex}: normal pool has {#normal} items, expected 7`)
		for _, item in normal do
			check(
				RarityConfig.isNormallyRollable(item.rarity),
				`zone {zoneIndex}: "{item.id}" is in the normal pool but "{item.rarity}" has no normal weight`
			)
			check(
				not item.jackpot,
				`zone {zoneIndex}: jackpot "{item.id}" leaked into the normal pool`
			)
		end

		-- The jackpot must be a genuine jump, not the next step on a staircase.
		local jackpot = LootConfig.jackpotFor(zoneIndex)
		local best = 0
		for _, item in normal do
			best = math.max(best, item.income)
		end
		check(
			jackpot ~= nil and jackpot.income > best,
			`zone {zoneIndex}: the jackpot must out-earn every ordinary item in its zone`
		)
	end

	local total = 0
	for _ in seen do
		total += 1
	end
	check(total == 96, `expected 96 unique items, got {total}`)

	-- ==========================================================
	-- VARIANTS
	-- ==========================================================
	for label, list in { Size = RarityConfig.Sizes, Mutation = RarityConfig.Mutations } do
		local sum = 0
		for _, v in list do
			sum += v.chance
		end
		check(math.abs(sum - 100) < 0.001, `{label} chances total {sum}, expected 100`)
	end

	-- ==========================================================
	-- CAPACITY AND TREADMILL LADDERS
	-- ==========================================================
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
		check(
			TreadmillConfig.Tiers[i].cost > TreadmillConfig.Tiers[i - 1].cost,
			`treadmill level {i}: cost must increase`
		)
	end

	-- ==========================================================
	-- ANCHORS
	-- ==========================================================
	-- Each of these is a number a regression would change silently.
	check(
		LootConfig.ById["Museum_AncientVase"].income == 1,
		`the tutorial vase must be $1/s, got {LootConfig.ById["Museum_AncientVase"].income}`
	)
	check(LootConfig.ById["Museum_Diamond"].income == 1800, "Museum Diamond must be $1,800/s")
	check(LootConfig.ById["Pirate_CursedCoin"].income == 220e3, "Cursed Coin must be $220,000/s")
	-- The Bank's non-monotonic step is intentional and has been "corrected" by
	-- well-meaning passes before. Assert it so it stays broken on purpose.
	check(
		LootConfig.ById["Bank_BankersBriefcase"].income > LootConfig.ById["Bank_DiamondBriefcase"].income,
		"the Bank's $32M -> $25M step is intentional and must not be sorted"
	)
	check(
		LootConfig.ById["Museum_AncientVase"].rarity == "Common",
		"the tutorial vase must be Common"
	)
	check(
		LootConfig.jackpotFor(1) ~= nil and LootConfig.jackpotFor(1).id == "Museum_Diamond",
		"the Museum jackpot must be the Diamond"
	)

	check(GameConfig.STARTING_SPEED_POWER == 10, "starting Speed must be 10")
	check(GameConfig.STARTING_CASH == 0, "starting Cash must be 0")
	check(GameConfig.TUTORIAL_CASH_BRIDGE == 1000, "the tutorial bridge must top up to $1,000")
	check(BaseConfig.ACTIVATION_COST == 1000, "base activation must cost $1,000")
	check((GameConfig :: any).SOCKET_REFILL_DELAY == nil, "the per-socket refill delay must not come back")
	check(GameConfig.GLOBAL_REFRESH_INTERVAL == 300, "the global refresh must run every 300s")
	check(
		math.abs(GameConfig.JACKPOT_REFRESH_CHANCE - 0.10) < 1e-9,
		`the jackpot refresh chance must be 0.10, got {GameConfig.JACKPOT_REFRESH_CHANCE}`
	)

	check(TreadmillConfig.Tiers[1].gainPerTick == 2, "Basic treadmill must be +2/tick (~8/s)")
	check(TreadmillConfig.Tiers[2].gainPerTick == 20, "Tier 2 treadmill must be +20/tick (~80/s)")
	check(TreadmillConfig.Tiers[2].cost == 15e3, "the first Cash treadmill upgrade must be $15,000")
	check(TreadmillConfig.Tiers[3].cost == 250e3, "the second Cash treadmill upgrade must be $250,000")
	check(TreadmillConfig.Tiers[4].cost == 5e6, "the third Cash treadmill upgrade must be $5,000,000")
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
