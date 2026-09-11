--!strict
--[[
	Config validation.

	Confirms the shape of the economy rather than its taste: 12 zones x 8 items,
	five sockets per zone, no duplicate ItemIds, the reference progression's
	per-zone rarity ladders and spawn weights pinned exactly for zones 1-11,
	the post-game zone fenced, the locked mutation table, the continuous Scale
	curves, the income funnel, the purchase ladders, and the handful of anchors
	the progression is actually pinned to.

	Deliberately does NOT assert every one of the 96 incomes - that would just be
	the table written twice. It asserts the structure the table has to have, plus
	the specific numbers a regression would be silent about.

	Run from the command bar:
		require(game.ReplicatedStorage.Shared.Config.validate)()
	or through the test runner (EconomyTests), which includes it.
]]

local LootConfig = require(script.Parent.LootConfig)
local RarityConfig = require(script.Parent.RarityConfig)
local ScaleConfig = require(script.Parent.ScaleConfig)
local ZoneConfig = require(script.Parent.ZoneConfig)
local BaseConfig = require(script.Parent.BaseConfig)
local TreadmillConfig = require(script.Parent.TreadmillConfig)
local GameConfig = require(script.Parent.GameConfig)
local NightConfig = require(script.Parent.NightConfig)
local IndexConfig = require(script.Parent.IndexConfig)
local MonetizationConfig = require(script.Parent.MonetizationConfig)
local HatchConfig = require(script.Parent.HatchConfig)
local MysteryConfig = require(script.Parent.MysteryConfig)
local PvPConfig = require(script.Parent.PvPConfig)
local BaseGuardianConfig = require(script.Parent.BaseGuardianConfig)
local SpinWheelConfig = require(script.Parent.SpinWheelConfig)
local StarterTaskConfig = require(script.Parent.StarterTaskConfig)
local NumberFormat = require(script.Parent.Parent.Util.NumberFormat)

type Report = { passed: number, failed: { string } }

local function near(a: number, b: number, tolerance: number?): boolean
	return math.abs(a - b) <= (tolerance or 1e-9)
end

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
	check(ZoneConfig.PARITY_COUNT == 11, "the parity baseline is zones 1-11")
	check(ZoneConfig.SOCKETS_PER_ZONE == 4, "expected 4 mystery containers per zone")
	check(MysteryConfig.SOCKETS_PER_ZONE == ZoneConfig.SOCKETS_PER_ZONE, "MysteryConfig and ZoneConfig must agree on the socket count")
	check(#MysteryConfig.SocketOffsets == 4, "there must be exactly four socket offsets around the guardian")
	do
		-- The four stand in an arc: two in front of the guardian, two behind,
		-- one pair either side of the lane centre. A layout that collapsed to
		-- one side would leave half the zone empty and block the run home.
		local left, right, front, rear = 0, 0, 0, 0
		for _, offset in MysteryConfig.SocketOffsets do
			if offset.x < 0 then left += 1 else right += 1 end
			if offset.z < 0 then front += 1 else rear += 1 end
			check(math.abs(offset.x) >= 12, "a container must stand clear of the guardian, not on it")
		end
		check(left == 2 and right == 2, "two containers either side of the guardian")
		check(front == 2 and rear == 2, "two containers in front of the guardian and two behind")
		check(MysteryConfig.SOCKET_MIN_SEPARATION > 0, "containers need a minimum separation")
	end
	do
		-- Every zone must name its own container model, and no two zones may
		-- name the same one - a zone with a missing model spawns NOTHING
		-- rather than borrowing another zone's container.
		local claimed: { [string]: number } = {}
		for zoneIndex = 1, ZoneConfig.COUNT do
			local entry = MysteryConfig.ZoneModels[zoneIndex]
			check(entry ~= nil and #entry.aliases > 0, `zone {zoneIndex} has no container model name`)
			if entry then
				local primary = entry.aliases[1]
				check(claimed[primary] == nil, `zone {zoneIndex} reuses zone {claimed[primary]}'s container model`)
				claimed[primary] = zoneIndex
			end
		end
	end
	check(#LootConfig.Items == 12, `expected 12 item pools, got {#LootConfig.Items}`)
	check(ZoneConfig.Zones[12].postgame == true, "zone 12 must be flagged post-game")
	check(ZoneConfig.isParityZone(11) and not ZoneConfig.isParityZone(12), "isParityZone must split 11 / 12")
	check(GameConfig.isPostgameZone(12) and not GameConfig.isPostgameZone(11), "GameConfig.POSTGAME_EXTENSION must name zone 12 only")
	check(LootConfig.isParityZone(11) and not LootConfig.isParityZone(12), "LootConfig must agree on the post-game zone")

	for _, zone in ZoneConfig.Zones do
		check(zone.id:match("^Zone%d%d_") ~= nil, `zone {zone.index}: malformed id "{zone.id}"`)
	end

	-- The Speed gates are the spine of the progression: the reference values,
	-- exactly, for zones 1-11, and ascending throughout.
	local gates = { 0, 900, 10e3, 40e3, 170e3, 700e3, 2.5e6, 18e6, 700e6, 2.5e9, 7e9 }
	for index, gate in gates do
		check(ZoneConfig.Zones[index].recommendedSpeed == gate, `zone {index}: recommended Speed must be {gate}`)
	end
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
	check((RarityConfig :: any).NormalWeights == nil, "the global rarity weight table must not come back")
	check((RarityConfig :: any).isNormallyRollable == nil, "the normal-weight roller must not come back")

	-- The reference progression's per-slot rarities, pinned for zones 1-11.
	local C, U, R, E, L, M, Co, S, Et, D =
		"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine"
	local expectedLadders = {
		{ C, C, U, R, R, E, E, L },
		{ C, C, U, R, E, E, L, Co },
		{ C, U, R, E, L, M, M, Co },
		{ R, R, E, L, L, M, M, S },
		{ R, E, L, M, M, Co, S, Et },
		{ R, E, L, L, M, S, Et, Et },
		{ R, E, L, M, Co, Co, S, Et },
		{ R, L, M, Co, Co, S, S, Et },
		{ E, L, M, Co, S, S, Et, D },
		{ E, L, M, Co, Co, S, Et, D },
		{ L, L, M, Co, Co, S, Et, D },
	}
	for zoneIndex, expected in expectedLadders do
		local ladder = RarityConfig.ladderFor(zoneIndex)
		check(#ladder == 8, `zone {zoneIndex}: ladder has {#ladder} entries, expected 8`)
		for position, rarity in expected do
			check(ladder[position] == rarity, `zone {zoneIndex} slot {position}: rarity must be {rarity}, got {ladder[position]}`)
		end
	end
	for position, rarity in RarityConfig.ladderFor(12) do
		check(RarityConfig.Rank[rarity] ~= nil, `zone 12 position {position}: unknown rarity "{rarity}"`)
	end
	check(RarityConfig.SECRET_FIRST_ZONE == 4, `Secret should first appear in zone 4, got {RarityConfig.SECRET_FIRST_ZONE}`)
	check(RarityConfig.topRarityFor(11) == "Divine" and RarityConfig.topRarityFor(1) == "Legendary", "topRarityFor must read the ladder")

	-- ==========================================================
	-- ITEM POOLS AND SPAWN WEIGHTS
	-- ==========================================================
	-- Zones 1-3 are this game's own early odds (owner decision, 2026-09-11);
	-- 4-11 are the reference game's. See LootConfig SPAWN WEIGHTS.
	local expectedWeights = {
		{ 23.448276, 16.551724, 25.000000, 11.764706, 8.235294, 7.714286, 4.285714, 3.000000 },
		{ 17.846154, 14.153846, 23.000000, 20.000000, 8.888889, 6.111111, 9.000000, 1.000000 },
		{ 15.000000, 15.000000, 20.000000, 17.000000, 14.000000, 9.379310, 7.620690, 2.000000 },
		{ 26.006779, 20.005214, 17.004432, 13.003389, 11.002868, 7.852047, 5.001304, 0.123968 },
		{ 29.444067, 21.570745, 18.335133, 14.020984, 11.863910, 4.171033, 0.371904, 0.222224 },
		{ 26.848869, 22.040116, 18.032822, 15.027352, 17.030999, 0.619840, 0.222224, 0.177779 },
		{ 34.755713, 24.665345, 19.059585, 14.574977, 3.412663, 2.616375, 0.826453, 0.088890 },
		{ 39.066058, 26.044039, 20.835231, 4.929402, 6.995959, 0.826453, 0.991743, 0.311113 },
		{ 39.869773, 34.387407, 19.618806, 4.550072, 0.495856, 0.743784, 0.311104, 0.023199 },
		{ 37.51, 26.27, 16.83, 13.96, 4.36, 0.74, 0.31, 0.02 },
		{ 37.51, 26.27, 16.83, 13.96, 4.36, 0.74, 0.31, 0.02 },
	}
	local seen: { [string]: number } = {}
	for zoneIndex, pool in LootConfig.Items do
		check(#pool == 8, `zone {zoneIndex}: expected 8 item types, got {#pool}`)
		local total = 0
		for position, item in pool do
			if seen[item.id] then
				table.insert(report.failed, `duplicate ItemId "{item.id}" in zones {seen[item.id]} and {zoneIndex}`)
			else
				seen[item.id] = zoneIndex
				report.passed += 1
			end
			check(item.income > 0, `{item.id}: income must be positive`)
			check(item.weight > 0, `{item.id}: spawn weight must be positive`)
			check(item.position == position, `{item.id}: position {item.position} out of place`)
			check(item.zoneIndex == zoneIndex, `{item.id}: zoneIndex must be {zoneIndex}`)
			check(item.rarity == RarityConfig.rarityAt(zoneIndex, position), `{item.id}: rarity "{item.rarity}" disagrees with the zone ladder`)
			check(item.postgame == (zoneIndex == 12), `{item.id}: postgame flag wrong`)
			check(item.growthSeconds >= 0, `{item.id}: growth seconds must be non-negative`)
			local expected = expectedWeights[zoneIndex]
			if expected then
				check(near(item.weight, expected[position]), `{item.id}: spawn weight must be {expected[position]}, got {item.weight}`)
			end
			total += item.weight
		end
		check(near(LootConfig.ZoneWeightTotal[zoneIndex], total), `zone {zoneIndex}: weight total cache disagrees`)
		check((pool[1] :: any).jackpot == nil, `zone {zoneIndex}: the jackpot flag must not come back`)
	end
	check((LootConfig :: any).jackpotFor == nil and (LootConfig :: any).normalPool == nil, "the jackpot pool helpers must not come back")
	local total = 0
	for _ in seen do
		total += 1
	end
	check(total == 96, `expected 96 unique items, got {total}`)
	-- Zone 12's weights are provisional: Zone 11's table, by declaration.
	for position = 1, 8 do
		check(near(LootConfig.ZoneWeights[12][position], LootConfig.ZoneWeights[11][position]), "zone 12 (post-game) must carry Zone 11's provisional weights")
	end

	-- THE ZONE 9 ASSERTION (the 45M/s Blue Crystal).
	do
		local p = LootConfig.weightShare("SecretLab_MutationCrystal")
		check(near(p, 0.00495856, 1e-9), `Blue Crystal per-socket probability must be 0.495856%, got {p * 100}%`)
		-- Four containers now, not five: the brief retired the fifth spawn, so
		-- the at-least-once figure is over FOUR independent nests.
		local atLeastOnce = 1 - (1 - p) ^ ZoneConfig.SOCKETS_PER_ZONE
		check(near(atLeastOnce, 0.0196872, 1e-6), `Blue Crystal at-least-once-in-4 must be ~1.9687%, got {atLeastOnce * 100}%`)
		local refreshesPerHour = 3600 / NightConfig.CYCLE_SECONDS
		check(near(refreshesPerHour, 3600 / 270, 1e-9), "refreshes per hour must follow the 270s cycle (13.33/h)")
		check(near(p * ZoneConfig.SOCKETS_PER_ZONE * 12, 0.23801088, 1e-7), "Blue Crystal expected occurrences/hour over 4 nests x 12 refreshes")
	end

	-- ==========================================================
	-- SCALE
	-- ==========================================================
	check(ScaleConfig.ECONOMY_SCALE_VERSION == 1, "ECONOMY_SCALE_VERSION must be 1")
	check(ScaleConfig.SIZE_ODDS_STATUS == "PROJECT_OWN_WEIGHTS", "SIZE_ODDS_STATUS must say the weights are this project's own")
	check(#ScaleConfig.Variants == 6, `expected 6 size variants, got {#ScaleConfig.Variants}`)
	do
		-- THE AUTHORITATIVE RAW WEIGHTS. They total 96, NOT 100, on purpose:
		-- they are relative weights that the roller normalises, so there is no
		-- 4% "nothing happened" outcome.
		local expectedWeights = { Normal = 60, Big = 20, Huge = 10, Giant = 4, Titan = 1.5, Colossal = 0.5 }
		local raw = 0
		local previousMax = 0
		for index, variant in ScaleConfig.Variants do
			check(near(variant.weight, expectedWeights[variant.id]), `variant {variant.id} weight must be {expectedWeights[variant.id]}`)
			check(variant.max >= variant.min and variant.min > 0, `variant {variant.id}: bad scale range`)
			check(variant.min > previousMax, `variant {variant.id} must start above the one below it`)
			check(RarityConfig.SizeById[variant.id] ~= nil, `variant {variant.id} has no size word`)
			-- A Scale drawn from a variant must read back as that variant, or
			-- the container's size, its label, its hatch time and its income
			-- would be describing different things.
			check(ScaleConfig.labelFor(variant.min) == variant.id, `variant {variant.id}: its own minimum reads as {ScaleConfig.labelFor(variant.min)}`)
			check(ScaleConfig.labelFor(variant.max) == variant.id, `variant {variant.id}: its own maximum reads as {ScaleConfig.labelFor(variant.max)}`)
			previousMax = variant.max
			raw += variant.weight
			local _ = index
		end
		check(near(raw, 96), `the raw variant weights must total 96, got {raw}`)

		-- NORMALISATION: every zone's odds sum to exactly 1, and no variant is
		-- ever impossible (no zone multiplier is zero).
		for zoneIndex = 1, ZoneConfig.COUNT do
			local odds = ScaleConfig.variantOdds(zoneIndex)
			local total = 0
			for _, variant in ScaleConfig.Variants do
				local share = odds[variant.id] or 0
				check(share > 0, `zone {zoneIndex}: {variant.id} became impossible`)
				total += share
			end
			check(near(total, 1, 1e-9), `zone {zoneIndex}: normalised odds total {total}, expected 1`)
		end

		-- THE ZONE BIAS, in the direction the brief asks for: the first zones
		-- must produce markedly fewer huge results than the last.
		local early = ScaleConfig.variantOdds(1)
		local endgame = ScaleConfig.variantOdds(11)
		check(early.Colossal < endgame.Colossal * 0.2, "zones 1-3 must be far less likely to produce a Colossal than 10-12")
		check(early.Titan < endgame.Titan * 0.2, "zones 1-3 must be far less likely to produce a Titan than 10-12")
		check(early.Normal > endgame.Normal, "the early zones must lean smaller than the endgame zones")
		check(ScaleConfig.bandFor(1).id == "Early" and ScaleConfig.bandFor(3).id == "Early", "zones 1-3 are the Early band")
		check(ScaleConfig.bandFor(4).id == "Middle" and ScaleConfig.bandFor(6).id == "Middle", "zones 4-6 are the Middle band")
		check(ScaleConfig.bandFor(7).id == "Advanced" and ScaleConfig.bandFor(9).id == "Advanced", "zones 7-9 are the Advanced band")
		check(ScaleConfig.bandFor(10).id == "Endgame" and ScaleConfig.bandFor(12).id == "Endgame", "zones 10-12 are the Endgame band")
	end
	-- The income curve: verified formula, continuous at the knee.
	check(near(ScaleConfig.sizeFactor(1), 1), "sizeFactor(1) must be 1")
	check(near(ScaleConfig.sizeFactor(5), 19.637875755794113, 1e-9), "sizeFactor(5) must be 5^1.85")
	check(near(ScaleConfig.sizeFactor(5 + 1e-9), 19.637875755794113, 1e-6), "sizeFactor must be continuous at 5")
	check(near(ScaleConfig.sizeFactor(2), 2 ^ 1.85), "sizeFactor(2) must be 2^1.85")
	check(near(ScaleConfig.sizeFactor(12), 19.637875755794113 * (12 / 5) ^ 1.2, 1e-9), "sizeFactor(12) must follow the upper branch")
	for _, multiplier in { 1, 1.35, 2, 3.5, 4.5, 6, 19.637875755794113, 25, 56.1498 } do
		local scale = ScaleConfig.inverseSizeFactor(multiplier)
		check(near(ScaleConfig.sizeFactor(scale), multiplier, 1e-6), `inverseSizeFactor must invert sizeFactor at x{multiplier}`)
	end
	-- The maturation curve: verified formula, continuous at both joints.
	check(near(ScaleConfig.growthMultiplier(2), 1), "growthMultiplier(2) must be 1")
	check(near(ScaleConfig.growthMultiplier(6), 3 ^ 1.389), "growthMultiplier(6) must be 3^1.389")
	check(near(ScaleConfig.growthMultiplier(6 + 1e-9), 4.6, 1e-6) and near(3 ^ 1.389, 4.6, 0.01), "growthMultiplier joins 3^1.389 (4.6045) to 4.6 at 6 - the reference curve, approximately continuous")
	check(near(ScaleConfig.growthMultiplier(1000), 20), "growthMultiplier must cap at 20")
	check(ScaleConfig.maturationSeconds(0, 35) == 0, "a zero base growth time must mean no maturation")
	-- Carry compression: never larger, strictly increasing, identity to the knee.
	do
		local previous = 0
		for _, v in { 0.5, 1, 1.6, 2.5, 2.6, 4, 7, 8.5, 10, 16, 19, 22, 35, 140 } do
			local carried = ScaleConfig.carryScale(v)
			check(carried <= v + 1e-9, `carry compression enlarged x{v}`)
			check(carried > previous, `carry compression must stay strictly increasing (x{v})`)
			if v <= 2.6 then
				check(near(carried, v), `a x{v} item must be carried at its true size`)
			end
			previous = carried
		end
	end
	-- Labels.
	check(ScaleConfig.labelFor(1) == "Normal" and ScaleConfig.labelFor(2) == "Big" and ScaleConfig.labelFor(4) == "Huge", "labels below Giant")
	check(ScaleConfig.labelFor(6) == "Giant" and ScaleConfig.labelFor(12) == "Titan" and ScaleConfig.labelFor(22) == "Colossal", "labels from Giant up")

	-- ==========================================================
	-- SIZE WORDS
	-- ==========================================================
	check(#RarityConfig.Sizes == 6, `expected 6 size words, got {#RarityConfig.Sizes}`)
	check(RarityConfig.Sizes[1].id == "Normal" and RarityConfig.Sizes[6].id == "Colossal", "size words must run Normal .. Colossal")
	for _, size in RarityConfig.Sizes do
		check((size :: any).chance == nil and (size :: any).multiplier == nil, `size word {size.id} must carry no roll chance and no income multiplier`)
		check((size.movePenalty or 0) <= 0.25, `size {size.id} move penalty must not exceed 25%`)
	end
	for word, multiplier in { Normal = 1, Big = 1.35, Huge = 2, Giant = 3.5, Titan = 4.5, Colossal = 6 } do
		check(near(RarityConfig.LegacySizeIncomeMultipliers[word], multiplier), `legacy multiplier for {word} must be x{multiplier} (the migration depends on it)`)
	end

	-- ==========================================================
	-- MUTATIONS - LOCKED
	-- ==========================================================
	do
		local expected = {
			{ id = "Normal", chance = 90.0, multiplier = 1.00 },
			{ id = "Shiny", chance = 6.0, multiplier = 1.25 },
			{ id = "Golden", chance = 2.5, multiplier = 2.00 },
			{ id = "Flaming", chance = 1.0, multiplier = 2.50 },
			{ id = "Corrupted", chance = 0.5, multiplier = 3.00 },
		}
		check(#RarityConfig.Mutations == #expected, "mutation count must not change")
		local sum = 0
		for index, row in expected do
			local live = RarityConfig.Mutations[index]
			check(live ~= nil and live.id == row.id, `mutation {index} must be {row.id}`)
			check(live ~= nil and near(live.chance, row.chance), `mutation {row.id} chance must be {row.chance}%`)
			check(live ~= nil and near(live.multiplier, row.multiplier), `mutation {row.id} multiplier must be x{row.multiplier}`)
			check(RarityConfig.MutationColors[row.id] ~= nil or row.id == "Normal", `mutation {row.id} must keep its colour`)
			sum += if live then live.chance else 0
		end
		check(near(sum, 100, 0.001), `mutation chances total {sum}, expected 100`)
		check(RarityConfig.normaliseMutation("Neon") == "Flaming", "Neon must map to Flaming")
		check(RarityConfig.normaliseMutation("Glitched") == "Corrupted", "Glitched must map to Corrupted")
		check(RarityConfig.normaliseMutation(nil) == "Normal", "a missing mutation is Normal")
		check(near(RarityConfig.mutationMultiplier("Neon"), 2.5), "the alias must carry Flaming's multiplier")
	end

	-- ==========================================================
	-- THE INCOME FUNNEL
	-- ==========================================================
	check(RarityConfig.preBoostRate(45e6, 1, "Normal", 1) == 45e6, "Blue Crystal at Scale 1 must be $45M/s")
	check(RarityConfig.preBoostRate(45e6, 2, "Normal", 1) == math.round(45e6 * 2 ^ 1.85), "Scale 2 must apply 2^1.85")
	check(RarityConfig.preBoostRate(45e6, 1, "Golden", 1) == 90e6, "Golden must double")
	check(RarityConfig.preBoostRate(45e6, 1, "Normal", 2) == 90e6, "the 2x Cash pass must double inside the per-item rate")
	check(RarityConfig.preBoostRate(1, 0.1, "Normal", 1) == 1, "the rate floors at 1")
	check(RarityConfig.preBoostRate(3, 1, "Shiny", 1) == 4, "3 x 1.25 = 3.75 rounds to 4 (half away from zero)")
	check(GameConfig.SERVER_EARNINGS_BOOST == 1 and GameConfig.TEMPORARY_EARNINGS_BOOST == 1, "no live server boost is configured")
	check(GameConfig.INCOME_TICK == 1, "the passive tick is one second")
	check((NightConfig :: any).GROWTH_INCOME_BONUS == nil and (NightConfig :: any).GROWTH_SCALE_BONUS == nil, "the growth income/size bonus must not come back")
	check(IndexConfig.incomeMultiplier({ zone_1 = true, all = true }) == 1, "the Index must not multiply recurring income")

	-- ==========================================================
	-- NIGHT
	-- ==========================================================
	check(NightConfig.CYCLE_SECONDS == 270, `the Night cycle must be 270s, got {NightConfig.CYCLE_SECONDS}`)
	check(NightConfig.NIGHT_SECONDS == 10, `the Night closure must be 10s, got {NightConfig.NIGHT_SECONDS}`)
	check(GameConfig.GLOBAL_REFRESH_INTERVAL == NightConfig.CYCLE_SECONDS, "GameConfig.GLOBAL_REFRESH_INTERVAL must mirror NightConfig.CYCLE_SECONDS")
	check((NightConfig :: any).NIGHTFALL_RARITY_BOOST == nil and (NightConfig :: any).refreshBoosts == nil and (NightConfig :: any).rarityBoost == nil, "the Night rarity lean must not come back")
	check((NightConfig :: any).REFRESH_SIZE_BOOST == nil and (NightConfig :: any).sizeBoost == nil, "the Night size lean must not come back")
	check((NightConfig :: any).PITY_ENABLED == nil or NightConfig.PITY_ENABLED == false, "there is no pity system")
	check(NightConfig.NIGHT_GROWTH_CREDIT_SECONDS == 300, "the Night must hand out 300 seconds of growth credit")
	check(near(NightConfig.growthCreditPerSecond(true), 30) and near(NightConfig.growthCreditPerSecond(false), 1), "growth credit must be 30/s at Night and 1/s by day")
	check(NightConfig.SPOTLIGHT_MIN_RARITY == "Secret", "spotlights start at Secret")
	check((GameConfig :: any).JACKPOT_REFRESH_CHANCE == nil, "JACKPOT_REFRESH_CHANCE must not come back")

	-- ==========================================================
	-- PURCHASES
	-- ==========================================================
	local expectedCapacity = {
		{ 0, 7, 0 }, { 1, 7, 1e3 }, { 2, 9, 1e6 }, { 3, 10, 75e6 }, { 4, 11, 500e6 }, { 5, 12, 1e9 },
		{ 6, 13, 50e9 }, { 7, 14, 500e9 }, { 8, 15, 1e12 }, { 9, 16, 25e12 }, { 10, 17, 100e12 }, { 11, 18, 500e12 },
	}
	check(#BaseConfig.CapacityTiers == #expectedCapacity, "twelve capacity levels")
	for index, row in expectedCapacity do
		local tier = BaseConfig.CapacityTiers[index]
		check(tier ~= nil and tier.tier == row[1] and tier.slots == row[2] and tier.cost == row[3], `capacity level {row[1]} must be {row[2]} slots for {row[3]}`)
	end
	check(BaseConfig.slotsForTier(0) == GameConfig.STARTING_DISPLAY_SLOTS, "tier 0 must grant the starting slot count")
	check(BaseConfig.slotsForTier(BaseConfig.MAX_TIER) == GameConfig.MAX_DISPLAY_SLOTS, "max tier must reach 18 slots")

	local expectedTreadmill = {
		{ 2, 0 }, { 5, 15e3 }, { 12, 250e3 }, { 30, 5e6 }, { 80, 120e6 }, { 100, 3e9 }, { 200, 75e9 }, { 500, 2e12 }, { 1000, 50e12 }, { 2000, 1e15 },
	}
	check(#TreadmillConfig.Tiers == #expectedTreadmill, "ten treadmill tiers")
	for index, row in expectedTreadmill do
		local tier = TreadmillConfig.Tiers[index]
		check(tier ~= nil and tier.factor == row[1] and tier.cost == row[2], `treadmill tier {index} must be x{row[1]} for {row[2]}`)
		check(tier ~= nil and (tier :: any).gainPerTick == nil, `treadmill tier {index} must carry a factor, not a gainPerTick`)
	end
	check(TreadmillConfig.TICK_INTERVAL == 1, "the training tick is one second")
	check(near(TreadmillConfig.gainPerTick(1), GameConfig.TRAINING_BASE_GAIN * 2), "tier 1 gain is base x2")
	check(near(TreadmillConfig.bonusFactor(1.5, 2), 2.5), "a x1.5 trail and a x2 pass add to x2.5, never x3")
	check(near(TreadmillConfig.bonusFactor(1, 1), 1), "no trail, no pass: x1")
	check(GameConfig.TRAINING_STATUS == "BLOCKED_TRAINING_BASE" or GameConfig.TRAINING_STATUS == "VERIFIED", "TRAINING_STATUS must be declared")

	local expectedTrails = { { 1.5, 100 }, { 2, 5e3 }, { 2.5, 75e3 }, { 3, 1.5e6 }, { 3.5, 30e6 }, { 4, 750e6 }, { 5, 20e9 }, { 7, 500e9 }, { 10, 12.5e12 }, { 14, 300e12 } }
	check(#MonetizationConfig.Trails == #expectedTrails, "ten trails")
	for index, row in expectedTrails do
		local trail = MonetizationConfig.Trails[index]
		check(trail ~= nil and near(trail.multiplier, row[1]) and trail.cash == row[2], `trail {index} must be x{row[1]} for {row[2]} Cash`)
	end

	check(IndexConfig.DISCOVERY_CASH_SECONDS == 100, "discovery pays 100 seconds of Scale-1 income")
	check(IndexConfig.discoveryReward("SecretLab_MutationCrystal") == 4.5e9, "discovering the Blue Crystal pays 100 x $45M")
	check(IndexConfig.discoveryReward("Museum_AncientVase") == 100, "discovering the vase pays $100")
	check(IndexConfig.zoneReward(1).cash == 0, "a set claim pays no Cash")

	check(GameConfig.OFFLINE_EFFICIENCY > 0 and GameConfig.OFFLINE_EFFICIENCY <= 1, "OFFLINE_EFFICIENCY must be in (0, 1]")
	check(GameConfig.OFFLINE_STATUS == "BLOCKED_OFFLINE_COEFFICIENT" or GameConfig.OFFLINE_STATUS == "VERIFIED", "OFFLINE_STATUS must be declared")
	check(GameConfig.SELL_STRIPS_MUTATION == true, "a sale prices the item with its mutation stripped")

	-- ==========================================================
	-- HATCHING
	-- ==========================================================
	check(#HatchConfig.RarityBaseSeconds == #RarityConfig.Order, "every rarity tier needs a base hatch time")
	do
		local previous = 0
		for index, seconds in HatchConfig.RarityBaseSeconds do
			check(seconds > previous, `hatch tier {index} must take longer than the one below it`)
			previous = seconds
		end
		-- The brief's ladder, pinned: 5s at Common through 12h at Divine.
		check(HatchConfig.RarityBaseSeconds[1] == 5, "Common hatches in 5s")
		check(HatchConfig.RarityBaseSeconds[5] == 300, "the fifth tier hatches in 5m")
		check(HatchConfig.RarityBaseSeconds[10] == 43200, "the tenth tier hatches in 12h")
		check(HatchConfig.MAX_SECONDS == 12 * 60 * 60, "the hatch clamp is 12 hours")

		local sizeFactors = { Normal = 1.00, Big = 1.08, Huge = 1.20, Giant = 1.35, Titan = 1.60, Colossal = 2.00 }
		for id, factor in sizeFactors do
			check(near(HatchConfig.sizeFactor(id), factor), `hatch size factor for {id} must be {factor}`)
		end
		local mutationFactors = { Normal = 1.00, Shiny = 1.05, Golden = 1.10, Flaming = 1.20, Corrupted = 1.35 }
		for id, factor in mutationFactors do
			check(near(HatchConfig.mutationFactor(id), factor), `hatch mutation factor for {id} must be {factor}`)
		end
		-- A retired mutation name still maps to its current tier's factor.
		check(near(HatchConfig.mutationFactor("Neon"), 1.20), "the Neon alias must take Flaming's hatch factor")

		-- The formula, end to end, and the clamp.
		check(HatchConfig.hatchSeconds("Common", "Normal", "Normal") == 5, "a Normal Common hatches in 5s")
		check(HatchConfig.hatchSeconds("Divine", "Colossal", "Corrupted") == HatchConfig.MAX_SECONDS, "the biggest hatch is clamped to 12h")
		check(
			HatchConfig.hatchSeconds("Legendary", "Colossal", "Normal") == math.floor(300 * 2.0 + 0.5),
			"a Colossal Legendary takes twice the base"
		)
		-- Hatch modifiers must NEVER touch economics: the size and mutation
		-- income paths are elsewhere and are asserted above.
		check(HatchConfig.SizeFactors.Colossal ~= (RarityConfig.LegacySizeIncomeMultipliers.Colossal or 0), "hatch factors are not income multipliers")
	end

	-- ==========================================================
	-- TRAPS
	-- ==========================================================
	-- THE TRAP CLIP. Three at a time, spent one per placement, and the whole
	-- set comes back two minutes after the last one is used - never one at a
	-- time, and never a cooldown between placements.
	check(PvPConfig.TRAP_CAPACITY == 3, `a player must hold 3 traps, got {PvPConfig.TRAP_CAPACITY}`)
	check(PvPConfig.TRAP_REFILL == 120, `the trap refill must be 120s, got {PvPConfig.TRAP_REFILL}`)
	check(PvPConfig.TRAP_COOLDOWN == PvPConfig.TRAP_REFILL, "the retired cooldown name must still be the refill")
	check(
		PvPConfig.TRAP_MAX_ACTIVE_PER_PLAYER >= PvPConfig.TRAP_CAPACITY,
		"a player must be able to have every trap they hold out at once"
	)
	check(PvPConfig.TRAP_LIFETIME == 300, `a placed trap must expire after 300s, got {PvPConfig.TRAP_LIFETIME}`)

	-- ==========================================================
	-- ANCHORS
	-- ==========================================================
	-- The owner's early-zone odds, stated the way they were specified: per
	-- rarity, not per slot. This is the check that reads like the spec.
	local earlyOdds = {
		[1] = { Common = 40, Uncommon = 25, Rare = 20, Epic = 12, Legendary = 3 },
		[2] = { Common = 32, Uncommon = 23, Rare = 20, Epic = 15, Legendary = 9, Cosmic = 1 },
		[3] = { Common = 15, Uncommon = 15, Rare = 20, Epic = 17, Legendary = 14, Mythic = 17, Cosmic = 2 },
	}
	for zoneIndex, wanted in earlyOdds do
		local byRarity: { [string]: number } = {}
		for _, item in LootConfig.pool(zoneIndex) do
			byRarity[item.rarity] = (byRarity[item.rarity] or 0) + LootConfig.weightShare(item.id) * 100
		end
		for rarity, share in wanted do
			check(near(byRarity[rarity] or 0, share, 1e-4), `zone {zoneIndex} {rarity} must be {share}%, got {byRarity[rarity] or 0}`)
		end
		for rarity in byRarity do
			check(wanted[rarity] ~= nil, `zone {zoneIndex} must not roll {rarity}`)
		end
	end

	-- ZONE 1 RESPAWNS ON ITS OWN; NO OTHER ZONE DOES. A global per-socket delay
	-- must still never come back, and the Zone 1 exception must not quietly
	-- spread to the zones whose pacing depends on the shared refresh.
	check((GameConfig :: any).SOCKET_REFILL_DELAY == nil, "the global per-socket refill delay must not come back")
	local respawnZones = 0
	for zoneIndex, window in GameConfig.ZONE_RESPAWN do
		respawnZones += 1
		check(zoneIndex == 1, `only Zone 1 may respawn between refreshes, found zone {zoneIndex}`)
		check(window.min == 60 and window.max == 90, `Zone 1 must respawn in 60-90s, got {window.min}-{window.max}`)
	end
	check(respawnZones == 1, `exactly one zone may respawn between refreshes, got {respawnZones}`)

	-- THE TUTORIAL ITEM. A Zone 1 item in the tutorial's own socket, pinned at
	-- the Common reveal speed so a new player's first reveal stays five seconds.
	local tutorialItem = LootConfig.ById[GameConfig.TUTORIAL_ITEM_ID]
	check(tutorialItem ~= nil, `the tutorial item {GameConfig.TUTORIAL_ITEM_ID} must exist`)
	check(GameConfig.TUTORIAL_ITEM_ID == "Museum_PharaohMask", "the tutorial item must be the Pharaoh Mask")
	check(tutorialItem ~= nil and tutorialItem.zoneIndex == GameConfig.TUTORIAL_ZONE, "the tutorial item must belong to the tutorial zone")
	check(
		GameConfig.TUTORIAL_HATCH_SECONDS == HatchConfig.hatchSeconds("Common", "Normal", "Normal"),
		"the tutorial item must reveal at the Common Normal/Normal speed"
	)
	for _, legacyId in GameConfig.TUTORIAL_LEGACY_ITEM_IDS do
		check(LootConfig.ById[legacyId] ~= nil, `legacy tutorial item {legacyId} must still exist`)
	end

	check(LootConfig.ById["Museum_AncientVase"].income == 1, "the Ancient Vase must be $1/s")
	check(LootConfig.ById["Museum_Diamond"].income == 1800, "Museum Diamond must be $1,800/s")
	check(LootConfig.ById["Pirate_CursedCoin"].income == 220e3, "Cursed Coin must be $220,000/s")
	check(LootConfig.ById["SecretLab_MutationCrystal"].income == 45e6, "Blue Crystal must be $45M/s")
	check(LootConfig.ById["Grandma_CookieJar"].income == 1.8e9, "Zone 10 slot 8 must be $1.8B/s")
	check(LootConfig.ById["Construction_MetalFence"].income == 11e6, "Zone 11 slot 4 must be $11M/s")
	check(LootConfig.ById["Construction_DiamondHammer"].income == 3e9, "Zone 11 slot 8 must be $3B/s")
	check(
		LootConfig.ById["Bank_BankersBriefcase"].income > LootConfig.ById["Bank_PlatinumBullionStack"].income,
		"the Bank's $32M -> $25M step is intentional and must not be sorted"
	)
	check(LootConfig.ById["Museum_AncientVase"].rarity == "Common", "the Ancient Vase must be Common")
	check(GameConfig.STARTING_SPEED_POWER == 10, "starting Speed must be 10")
	check(GameConfig.STARTING_CASH == 0, "starting Cash must be 0")
	check((GameConfig :: any).TUTORIAL_CASH_BRIDGE == nil, "the tutorial Cash bridge must not come back")
	check((BaseConfig :: any).ACTIVATION_COST == nil, "base activation must not come back")

	-- ==========================================================
	-- NUMBER FORMATTING
	-- ==========================================================
	for _, row in { { 999e9, "999B" }, { 1e12, "1T" }, { 1.5e12, "1.5T" }, { 999e12, "999T" }, { 1e15, "1Qa" }, { 999.6e9, "1T" }, { 1e18, "1Qi" }, { 250e3, "250K" } } do
		check(NumberFormat.short(row[1]) == row[2], `{row[1]} must format as {row[2]}, got {NumberFormat.short(row[1])}`)
	end

	-- ==========================================================
	-- SPEED CURVE
	-- ==========================================================
	check(near(GameConfig.walkSpeedFromPower(GameConfig.STARTING_SPEED_POWER), 16, 1e-6), "Speed 10 must map to exactly 16 WalkSpeed")
	do
		local previous = -1
		local ok = true
		for exponent = 1, 12 do
			local ws = GameConfig.walkSpeedFromPower(10 ^ exponent)
			if ws < previous then
				ok = false
			end
			previous = ws
		end
		check(ok, "walkSpeedFromPower must never decrease as Speed increases")
	end
	for _, anchor in { { 1e3, 28.8 }, { 10e3, 54.8 }, { 100e3, 86.3 }, { 1e6, 118.5 }, { 170e6, 190.5 }, { 225e6, 194.4 } } do
		local ws = GameConfig.walkSpeedFromPower(anchor[1])
		check(math.abs(ws - anchor[2]) < 0.15, `Speed {anchor[1]} must map to ~{anchor[2]} WalkSpeed, got {string.format("%.2f", ws)}`)
	end
	check(GameConfig.walkSpeedFromPower(1e15) <= GameConfig.WALKSPEED_MAX + 1e-6, "the curve must never exceed WALKSPEED_MAX")

	-- ==========================================================
	-- GUARDIANS MATCH THEIR OWN RECOMMENDATIONS
	-- ==========================================================
	local MapConfig = require(script.Parent.Parent.MapConfig)
	for index = 2, ZoneConfig.COUNT do
		local recommended = ZoneConfig.Zones[index].recommendedSpeed
		local run = MapConfig.zoneCenterZ(index)
		local baseline = GameConfig.guardianGateWalkSpeed(recommended, ZoneConfig.GUARDIAN_GATE_MARGIN, run)
		check(
			GameConfig.walkSpeedFromPower(recommended) - baseline >= GameConfig.GUARDIAN_MIN_GATE_MARGIN - 1e-6,
			`zone {index}: a player AT the recommended Speed does not clear the guardian`
		)
		check(baseline >= GameConfig.walkSpeedFromPower(recommended) * 0.9, `zone {index}: the calibrated guardian fell too far below the at-gate player`)
		local deficit = math.clamp(1 - 0.75, 0, 1)
		local chasing = baseline * (1 + ZoneConfig.GUARDIAN_DEFICIT_CATCHUP * deficit)
		check(GameConfig.walkSpeedFromPower(recommended * 0.75) < chasing, `zone {index}: a player at 75% of the recommendation still outruns its guardian`)
	end
	check(ZoneConfig.GUARDIAN_GATE_MARGIN > 0, "the gate margin must be positive")
	check(ZoneConfig.GUARDIAN_DEFICIT_CATCHUP > 0, "the deficit catch-up must be positive")
	check(math.abs(GameConfig.legacyWalkSpeedFromPower(10) - 18.26) < 0.05, "the legacy calibration curve must still map Speed 10 to ~18.3")

	-- ==========================================================
	-- THE SPIN WHEEL
	-- ==========================================================
	--
	-- The wheel is a PICTURE with twelve wedges and a table with twelve rows,
	-- and the two have to stay the same shape or the pointer lands on the
	-- wrong words. These are the checks a regression there would be silent
	-- about: a dropped row, a mistyped weight, a segment with no reward.
	do
		local segments = SpinWheelConfig.Segments
		check(#segments == 12, `the spin wheel must have 12 segments to match its art, has {#segments}`)
		local total = 0
		for index, segment in segments do
			total += segment.weight
			check(segment.index == index, `spin segment {index} carries index {segment.index}`)
			check(segment.weight > 0, `spin segment {index} ({segment.label}) has no weight`)
			check(segment.label ~= "" and segment.won ~= "", `spin segment {index} has no label`)
			if segment.kind == "guardian" then
				local key = segment.guardianKey
				check(
					key ~= nil and BaseGuardianConfig.ByKey[key :: string] ~= nil,
					`spin segment {index} names guardian "{tostring(key)}", which does not exist`
				)
				check(segment.amount == 0, `spin segment {index} is a guardian and must carry no amount`)
			else
				check(segment.amount > 0, `spin segment {index} ({segment.kind}) pays nothing`)
			end
			check(
				SpinWheelConfig.TierColors[segment.tier] ~= nil,
				`spin segment {index} has an unknown tier "{tostring(segment.tier)}"`
			)
		end
		check(
			total == SpinWheelConfig.TOTAL_WEIGHT,
			`spin weights must sum to exactly {SpinWheelConfig.TOTAL_WEIGHT}, sum to {total}`
		)

		-- THE ROLL MUST BE ABLE TO REACH EVERY SEGMENT. Walking the cumulative
		-- boundaries proves the mapping without needing a million samples: the
		-- first ticket of each band and the last must resolve to that band.
		--- A Random that always deals the ticket we want to test.
		local function pinned(ticket: number): any
			return {
				NextInteger = function(_self: any, _low: number, _high: number): number
					return ticket
				end,
			}
		end
		local running = 0
		local reachable = true
		for _, segment in segments do
			local first, last = running + 1, running + segment.weight
			running = last
			if
				SpinWheelConfig.roll(pinned(first)) ~= segment.index
				or SpinWheelConfig.roll(pinned(last)) ~= segment.index
			then
				reachable = false
			end
		end
		check(reachable, "every spin segment must be reachable at both ends of its weight band")

		-- The easing lands EXACTLY, or the pointer stops off the wedge.
		check(SpinWheelConfig.progress(0) == 0, "the spin curve must start at 0")
		check(SpinWheelConfig.progress(1) == 1, "the spin curve must end at exactly 1")
		local monotonic = true
		local previous = -1
		for step = 0, 100 do
			local value = SpinWheelConfig.progress(step / 100)
			if value < previous then
				monotonic = false
			end
			previous = value
		end
		check(monotonic, "the spin curve must never travel backwards")

		-- Twelve wedges of thirty degrees, each landing on its own CENTRE and
		-- never on the line it shares with its neighbour. The half-wedge is the
		-- part that is easy to lose in a refactor and impossible to spot in a
		-- log, so it is pinned here rather than left to the eye.
		check(math.abs(SpinWheelConfig.SEGMENT_ARC - 30) < 1e-9, "each spin wedge must be 30 degrees")
		local spacing = true
		for index = 2, 12 do
			local step = math.deg(SpinWheelConfig.angleFor(index) - SpinWheelConfig.angleFor(index - 1))
			if math.abs(step - SpinWheelConfig.SEGMENT_ARC) > 1e-6 then
				spacing = false
			end
		end
		check(spacing, "consecutive spin segments must be exactly one wedge apart")
		check(
			math.abs(math.deg(SpinWheelConfig.angleFor(1)) - 15) < 1e-6,
			"segment 1's centre must be half a wedge clockwise of the pointer"
		)
		check(
			math.abs((math.deg(SpinWheelConfig.angleFor(12)) % 360) - 345) < 1e-6,
			"segment 12's centre must be half a wedge anticlockwise of the pointer"
		)

		check(SpinWheelConfig.PLAY_SECONDS == 600, "the free spin must be earned every 10 minutes of play")
		check(SpinWheelConfig.WHEEL_IMAGE:match("^rbxassetid://%d+$") ~= nil, "the wheel image must be an rbxassetid")
		check(
			SpinWheelConfig.LOCK_SECONDS > SpinWheelConfig.SPIN_SECONDS + SpinWheelConfig.RESULT_SECONDS,
			"the server's spin lock must outlast the animation it is covering"
		)
	end

	-- ==========================================================
	-- THE BEGINNER CHECKLIST
	-- ==========================================================
	do
		-- A BOOLEAN, not a truthy string. `ENABLED = "false"` reads as true in
		-- Lua and would turn the checklist back on without anyone noticing.
		check(
			type(StarterTaskConfig.ENABLED) == "boolean",
			`StarterTaskConfig.ENABLED must be a boolean, is a {type(StarterTaskConfig.ENABLED)}`
		)
		check(#StarterTaskConfig.Tasks == 3, `the starter checklist must have 3 rows, has {#StarterTaskConfig.Tasks}`)
		local seen: { [string]: boolean } = {}
		for _, task in StarterTaskConfig.Tasks do
			check(not seen[task.key], `starter task key "{task.key}" appears twice`)
			seen[task.key] = true
			check(task.amount > 0, `starter task "{task.key}" pays nothing`)
			check(task.text ~= "" and task.reward ~= "", `starter task "{task.key}" has no wording`)
			check(StarterTaskConfig.ByKey[task.key] == task, `starter task "{task.key}" is missing from ByKey`)
		end
		check(not StarterTaskConfig.isComplete({}), "an empty checklist must not read as complete")
		check(StarterTaskConfig.isComplete(seen), "a checklist with every key must read as complete")
	end

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
