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
	check(ZoneConfig.SOCKETS_PER_ZONE == 8, "expected two rooms with four containers each")
	check(MysteryConfig.SOCKETS_PER_ZONE == ZoneConfig.SOCKETS_PER_ZONE, "MysteryConfig and ZoneConfig must agree on the socket count")
	check(#MysteryConfig.SocketOffsets == 8, "there must be eight fallback socket offsets")
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
		check(left == 4 and right == 4, "balanced fallback layout across the lane")
		check(front == 4 and rear == 4, "balanced fallback depth")
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
		check(near(atLeastOnce, 1 - (1 - 0.0196872) ^ 2, 1e-6), `Blue Crystal at-least-once-in-8 must match two four-item rooms, got {atLeastOnce * 100}%`)
		local refreshesPerHour = 3600 / NightConfig.CYCLE_SECONDS
		check(near(refreshesPerHour, 3600 / 270, 1e-9), "refreshes per hour must follow the 270s cycle (13.33/h)")
		check(near(p * ZoneConfig.SOCKETS_PER_ZONE * 12, 0.47602176, 1e-7), "Blue Crystal expected occurrences/hour over 8 nests x 12 refreshes")
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

	-- DATA (session lock, save retries, mailbox). A stale window shorter than
	-- a few autosaves would let a second server steal a LIVE session.
	check(GameConfig.DATA_LOCK_STALE_SECONDS >= GameConfig.AUTOSAVE_INTERVAL * 5, "DATA_LOCK_STALE_SECONDS must be at least 5 autosaves")
	check(GameConfig.DATA_LOCK_WAIT_SECONDS > 0 and GameConfig.DATA_LOCK_RETRY_SECONDS > 0, "session lock wait and retry must be positive")
	check(GameConfig.DATA_LOCK_WAIT_SECONDS < GameConfig.DATA_LOCK_STALE_SECONDS, "DATA_LOCK_WAIT_SECONDS must be shorter than the stale window")
	check(GameConfig.DATA_RELEASE_SAVE_ATTEMPTS >= 1, "the leave-save needs at least one attempt")
	check(GameConfig.DATA_SHUTDOWN_WAIT_SECONDS > 0 and GameConfig.DATA_SHUTDOWN_WAIT_SECONDS < 30, "DATA_SHUTDOWN_WAIT_SECONDS must fit inside BindToClose's 30s")
	check(GameConfig.MAILBOX_CAPACITY >= 1 and GameConfig.MAILBOX_POLL_SECONDS > 0, "mailbox capacity and poll must be positive")
	check(GameConfig.MAILBOX_DELIVERED_MEMORY >= GameConfig.MAILBOX_CAPACITY, "MAILBOX_DELIVERED_MEMORY must cover a full mailbox")
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

		check(SpinWheelConfig.PLAY_SECONDS == 300, "the free spin must be earned every 5 minutes of play")
		check(SpinWheelConfig.WHEEL_IMAGE:match("^rbxassetid://%d+$") ~= nil, "the wheel image must be an rbxassetid")
		check(
			SpinWheelConfig.LOCK_SECONDS > SpinWheelConfig.SPIN_SECONDS + SpinWheelConfig.RESULT_SECONDS,
			"the server's spin lock must outlast the animation it is covering"
		)
		-- THE REVEAL WAITS FOR THE LANDING. The prize is named and paid only
		-- once the spin AND its settle are over, and it is paid while the wheel
		-- is still locked - so no second spin can start before the first has
		-- paid out.
		check(
			SpinWheelConfig.REVEAL_SECONDS >= SpinWheelConfig.SPIN_SECONDS + SpinWheelConfig.BOUNCE_SECONDS,
			"the prize must not be revealed before the wheel has landed and settled"
		)
		check(
			SpinWheelConfig.REVEAL_SECONDS + SpinWheelConfig.GRANT_LATENCY_ALLOWANCE < SpinWheelConfig.LOCK_SECONDS,
			"the prize must be paid before the wheel unlocks for another spin"
		)

		-- [monetization pass] THE RARE WEDGES STAY RARE. The jackpot and the
		-- two guardians (the Tiger is a 399 R$ pass) at their reduced odds,
		-- and never creeping back up unnoticed.
		for _, segment in segments do
			if segment.tier == "jackpot" then
				check(segment.weight <= 8, `the jackpot wedge must weigh at most 8/10000, weighs {segment.weight}`)
			elseif segment.guardianKey == "Tiger" then
				check(segment.weight <= 15, `the Tiger wedge must weigh at most 15/10000, weighs {segment.weight}`)
			elseif segment.guardianKey == "Panda" then
				check(segment.weight <= 50, `the Panda wedge must weigh at most 50/10000, weighs {segment.weight}`)
			end
		end

		-- THE AFK PAUSE. Pings must arrive well inside the idle window, and the
		-- server's own rate limit must not swallow an honest cadence.
		check(SpinWheelConfig.IDLE_SECONDS == 120, "the spin clock must pause after 120s without activity")
		check(
			SpinWheelConfig.ACTIVITY_PING_SECONDS * 2 <= SpinWheelConfig.IDLE_SECONDS,
			"two activity pings must fit inside the idle window"
		)
		check(
			SpinWheelConfig.ACTIVITY_PING_MIN_GAP < SpinWheelConfig.ACTIVITY_PING_SECONDS,
			"the server's ping rate limit must be shorter than the client's cadence"
		)
		check(SpinWheelConfig.MOVE_ACTIVITY_STUDS > 0, "movement activity needs a positive threshold")

		-- ZONE-SCALED PRIZES. The floors reproduce the printed art, a fresh
		-- player is paid exactly the floors (jackpot aside, whose print is 1B),
		-- and no wedge can ever out-pay the paid product it resembles.
		local fresh = { baseIncome = 0, highestZone = 1 }
		local rich = { baseIncome = 1e15, highestZone = ZoneConfig.COUNT }
		local cheapestSpeedPack = math.huge
		local speed1B = 0
		for _, product in MonetizationConfig.SpeedProducts do
			cheapestSpeedPack = math.min(cheapestSpeedPack, product.amount)
			speed1B = math.max(speed1B, product.amount)
		end
		for _, segment in segments do
			local floorAmount = SpinWheelConfig.amountFor(segment, fresh)
			local maxed = SpinWheelConfig.amountFor(segment, rich)
			if segment.kind == "guardian" then
				check(floorAmount == 0 and maxed == 0, `spin segment {segment.index} (guardian) must pay no amount`)
				continue
			end
			check(floorAmount == segment.amount, `spin segment {segment.index} must pay its floor to a new player, pays {floorAmount}`)
			check(maxed >= floorAmount, `spin segment {segment.index} must never scale below its floor`)
			if segment.tier ~= "jackpot" then
				local printed = SpinWheelConfig.labelFor(segment, segment.amount)
				check(printed == segment.label, `spin segment {segment.index}: floor label "{printed}" must match the print "{segment.label}"`)
			end
			if segment.kind == "speed" then
				check(segment.maxAmount ~= nil and (segment.gateFraction or 0) > 0, `spin segment {segment.index} must scale with a cap`)
				check(maxed <= speed1B, `spin segment {segment.index} must never pay more than the 1B Speed pack`)
				if segment.tier ~= "jackpot" then
					check(maxed < 10e6, `common Speed wedge {segment.index} must stay under the 10M pack, pays up to {maxed}`)
				end
			else
				check((segment.incomeSeconds or 0) > 0, `cash spin segment {segment.index} must scale with income`)
				check(
					(segment.incomeSeconds or 0) < (MonetizationConfig.CashProducts[1].incomeMinutes or 0) * 60,
					`cash spin segment {segment.index} must pay less income-time than the smallest Cash pack`
				)
			end
		end
		check(cheapestSpeedPack > 0, "the Speed packs must pay something")
		local jackpotLabel = SpinWheelConfig.labelFor(segments[12], 1e9)
		check(jackpotLabel == segments[12].label, `the jackpot's 1B label "{jackpotLabel}" must match its print`)
	end

	-- ==========================================================
	-- MONETIZATION (the 2026-09-17 pass)
	-- ==========================================================
	do
		-- CASH PACKS: same ids and prices, floors and income-minutes both
		-- rising faster than price, so a bigger pack is never the worse deal.
		local packs = MonetizationConfig.CashProducts
		check(#packs == 5, `there must be five Cash packs, found {#packs}`)
		local expectedPacks = {
			{ key = "Cash24K", id = 3711390597, robux = 45 },
			{ key = "Cash200K", id = 3711390623, robux = 85 },
			{ key = "Cash800K", id = 3711390659, robux = 215 },
			{ key = "Cash4M", id = 3711390692, robux = 425 },
			{ key = "Cash8M", id = 3711390722, robux = 679 },
		}
		for index, row in expectedPacks do
			local pack = packs[index]
			check(
				pack ~= nil and pack.key == row.key and pack.productId == row.id and pack.robux == row.robux,
				`Cash pack {index} must keep key {row.key}, id {row.id} and price {row.robux}`
			)
		end
		for index = 2, #packs do
			local a, b = packs[index - 1], packs[index]
			check(b.amount / b.robux > a.amount / a.robux, `{b.key}'s floor must be better value per Robux than {a.key}'s`)
			check(
				(b.incomeMinutes or 0) / b.robux > (a.incomeMinutes or 0) / a.robux,
				`{b.key}'s income-minutes must be better value per Robux than {a.key}'s`
			)
		end
		for _, pack in packs do
			check(MonetizationConfig.cashPackAmount(pack, 0) == pack.amount, `{pack.key} must pay its floor at zero income`)
			local minutes = pack.incomeMinutes or 0
			check(
				MonetizationConfig.cashPackAmount(pack, 1e6) == math.max(pack.amount, 1e6 * minutes * 60),
				`{pack.key} must pay max(floor, income x minutes)`
			)
		end
		-- The 2x pass and the boosts are divided OUT of the income basis.
		check(MonetizationConfig.baseIncome(200, 2) * 2 == MonetizationConfig.baseIncome(200, 1), "the 2x Cash pass must not scale purchased packs")
		check(MonetizationConfig.baseIncome(0 / 0, 1) == 0, "a NaN income must read as zero")

		-- THE RECEIPT FALLBACK is never nothing and grows with the price.
		check(MonetizationConfig.fallbackCash(7, 0) == 7 * MonetizationConfig.FALLBACK_CASH_PER_ROBUX, "fallback must pay the per-Robux floor at zero income")
		check(MonetizationConfig.fallbackCash(599, 1e9) > MonetizationConfig.fallbackCash(7, 1e9), "fallback must grow with the price paid")
		check(MonetizationConfig.fallbackCash(0, 1e9) == 0, "a zero-Robux receipt converts to nothing")

		-- THE BOSS OFFER: a cooldown, no Zone 12, and the cheapest helpful pack.
		check(MonetizationConfig.BOSS_OFFER_COOLDOWN >= 60, "the boss-loss offer must not show on every catch")
		check(MonetizationConfig.bossOfferFor(12, 0) == nil, "Zone 12 must not have a boss-loss offer")
		local nearGate = MonetizationConfig.bossOfferFor(9, ZoneConfig.Zones[9].recommendedSpeed - 1e6)
		check(nearGate ~= nil and nearGate.key == "Speed150K", "a player 1M short of Zone 9 must be offered the smallest Speed pack")
		local farFromGate = MonetizationConfig.bossOfferFor(9, 0)
		check(farFromGate ~= nil and farFromGate.key == "Speed1B", "a player far below Zone 9 may still be offered the 1B pack")
		local zone1 = MonetizationConfig.bossOfferFor(1, 0)
		check(zone1 ~= nil and zone1.key == "Speed150K", "Zone 1 must offer the 150K pack")
		for zoneIndex = 1, 11 do
			local ceiling = MonetizationConfig.ProductByKey[MonetizationConfig.BossOfferByZone[zoneIndex]]
			local offered = MonetizationConfig.bossOfferFor(zoneIndex, 0)
			check(
				ceiling ~= nil and offered ~= nil and offered.robux <= ceiling.robux,
				`zone {zoneIndex}'s offer must never exceed its ceiling pack`
			)
		end
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

	-- ==========================================================
	-- CLIENT MOTION (client performance pass)
	-- ==========================================================
	do
		local radius = GameConfig.CLIENT_MOTION_CULL_RADIUS
		local interval = GameConfig.CLIENT_FAR_MOTION_INTERVAL
		check(type(radius) == "number" and radius >= 60, "CLIENT_MOTION_CULL_RADIUS must be a number >= 60 studs")
		-- Past half a second a far trophy visibly steps as it turns.
		check(type(interval) == "number" and interval > 0 and interval <= 0.5, "CLIENT_FAR_MOTION_INTERVAL must be in (0, 0.5]")
	end

	-- ==========================================================
	-- SECURITY PASS (SecurityConfig; docs/handoff-parts/security-gameplay.md)
	-- ==========================================================
	do
		local SecurityConfig = require(script.Parent.SecurityConfig)
		check(type(SecurityConfig.MOVEMENT_ENABLED) == "boolean", "SecurityConfig.MOVEMENT_ENABLED must be a boolean")
		-- Below 1 the check would flag a player moving at exactly the speed
		-- the server gave them; the delivery timer likewise.
		check(SecurityConfig.MOVEMENT_SPEED_TOLERANCE >= 1, "movement tolerance must be at least 1")
		check(SecurityConfig.DELIVERY_SPEED_TOLERANCE >= 1, "delivery tolerance must be at least 1")
		check(
			SecurityConfig.MOVEMENT_SAMPLE_INTERVAL > 0 and SecurityConfig.MOVEMENT_SAMPLE_INTERVAL <= 0.5,
			"movement sample interval must be in (0, 0.5]"
		)
		-- The burst must cover more than one sample, or every sample is judged
		-- with no room for a late packet.
		check(
			SecurityConfig.MOVEMENT_BURST_SECONDS > SecurityConfig.MOVEMENT_SAMPLE_INTERVAL,
			"movement burst must be longer than one sample"
		)
		for _, key in {
			"MOVEMENT_SLACK_STUDS", "MOVEMENT_RISE_SPEED", "MOVEMENT_RISE_SLACK_STUDS", "MOVEMENT_STRIKE_STUDS",
			"MOVEMENT_STRIKE_LIMIT", "MOVEMENT_STRIKE_DECAY", "MOVEMENT_SPAWN_GRACE", "MOVEMENT_TELEPORT_GRACE",
			"MOVEMENT_SNAP_SETTLE", "SPEED_HISTORY_SECONDS", "DELIVERY_SLACK_SECONDS", "LASER_CHASE_TIMEOUT",
			"HEIST_PENDING_EXPIRY", "HEIST_DELIVERY_RANGE_FACTOR", "HEIST_PRUNE_INTERVAL",
			"TRAIL_SYNC_PER_SECOND", "SLOT_PROMPT_PER_SECOND",
		} do
			local value = (SecurityConfig :: any)[key]
			check(type(value) == "number" and value > 0, `SecurityConfig.{key} must be a positive number`)
		end
		check(
			SecurityConfig.MOVEMENT_DEFAULT_SPEED >= GameConfig.WALKSPEED_MIN,
			"the assumed default speed must not be below the slowest real WalkSpeed"
		)
		-- A jump (about 7.2 studs) must never cost a strike on its own.
		check(SecurityConfig.MOVEMENT_RISE_SLACK_STUDS >= 8, "the rise slack must cover a full jump")
		check(
			SecurityConfig.CROUCH_SPEED_MULTIPLIER > 0 and SecurityConfig.CROUCH_SPEED_MULTIPLIER <= 1,
			"the crouch speed multiplier must be in (0, 1]"
		)
		-- The saved steal reservation must outlive the live prompt it backs up.
		check(
			SecurityConfig.HEIST_PENDING_EXPIRY > require(script.Parent.HeistConfig).RESERVATION_TIMEOUT,
			"a saved steal reservation must outlive the live one"
		)
		check(SecurityConfig.HEIST_DELIVERY_RANGE_FACTOR >= 1.8, "the steal delivery range must not be tighter than the hold's own range")
		check(SecurityConfig.SPEED_HISTORY_SECONDS >= 60, "the speed history must cover a whole run")
	end

	-- ==========================================================
	-- POLISH / EVENTS / ANALYTICS (EventConfig, PolishConfig, LoadingConfig)
	-- ==========================================================
	do
		local EventConfig = require(script.Parent.EventConfig)
		local PolishConfig = require(script.Parent.PolishConfig)
		local function assetOk(value: any): boolean
			return type(value) == "string" and string.match(value, "^rbxassetid://%d+$") ~= nil
		end

		-- The UTC calendar the schedule is built on.
		check(EventConfig.utc(1970, 1, 1) == 0, "EventConfig.utc(1970-01-01) must be 0")
		check(EventConfig.utc(2024, 3, 1) == 1709251200, "EventConfig.utc must handle leap years")
		check(EventConfig.yearOf(EventConfig.utc(2027, 1, 1) - 1) == 2026, "EventConfig.yearOf must roll at New Year")

		local eventKeys: { [string]: boolean } = {}
		local normalDay = NightConfig.CYCLE_SECONDS - NightConfig.NIGHT_SECONDS
		for _, def in EventConfig.Events do
			check(not eventKeys[def.key], `event {def.key} is listed twice`)
			eventKeys[def.key] = true
			check(assetOk(def.icon), `event {def.key} icon must be an rbxassetid`)
			local weekly = def.weekly
			local yearly = def.from ~= nil and def.to ~= nil
			check((weekly ~= nil) ~= yearly, `event {def.key} needs exactly one of weekly / from+to`)
			if weekly then
				check(weekly.weekday >= 1 and weekly.weekday <= 7, `event {def.key} weekday must be 1-7`)
				check(weekly.hour >= 0 and weekly.hour <= 23, `event {def.key} hour must be 0-23`)
				check(weekly.durationHours > 0 and weekly.durationHours <= 7 * 24, `event {def.key} must last (0, 1 week]`)
			end
			-- Every window resolves, and the one after now starts in the future.
			local now = os.time()
			local startsAt, endsAt = EventConfig.windowFor(def, now)
			check(startsAt ~= nil and endsAt ~= nil and endsAt > startsAt, `event {def.key} has no valid window`)
			if def.kind == "mutation" then
				local factor = def.mutationMultiplier
				check(type(factor) == "number" and factor >= 1, `event {def.key} needs a mutation multiplier >= 1`)
				-- The scaled table: every chance a valid percentage, the same
				-- ids in the same order, still summing to the base total, and
				-- the base table untouched.
				local scaled = EventConfig.scaledMutations(RarityConfig.Mutations, factor or 1)
				local scaledTotal, baseTotal = 0, 0
				for index, row in scaled do
					local base = RarityConfig.Mutations[index]
					check(base ~= nil and base.id == row.id, `event {def.key} scaled mutation order changed`)
					check(row.chance >= 0 and row.chance <= 100, `event {def.key} {row.id} odds out of range`)
					scaledTotal += row.chance
				end
				for _, row in RarityConfig.Mutations do
					baseTotal += row.chance
				end
				check(near(scaledTotal, baseTotal, 1e-6), `event {def.key} scaled mutation odds must still sum to {baseTotal}`)
				check(near(RarityConfig.Mutations[1].chance, 90), "Mutation Weekend must not edit the locked mutation table")
				-- An absurd factor is capped, never negative.
				for _, row in EventConfig.scaledMutations(RarityConfig.Mutations, 1000) do
					check(row.chance >= 0, "an oversized mutation factor must cap at zero Normal, not go negative")
				end
			elseif def.kind == "nightRush" then
				local day = def.nightRushDaySeconds
				check(
					type(day) == "number" and day > NightConfig.WARNING_SECONDS and day < normalDay,
					`event {def.key} Day must be shorter than {normalDay}s and longer than the Night warning`
				)
			elseif def.kind == "holiday" then
				check(typeof(def.lightColor) == "Color3", `holiday {def.key} needs a lightColor`)
			end
		end
		check(EventConfig.HOLIDAY_LIGHT_BLEND >= 0 and EventConfig.HOLIDAY_LIGHT_BLEND <= 1, "holiday blend must be 0-1")

		-- The flyover and analytics switches.
		check(#PolishConfig.FLYOVER_SHOTS >= 1, "the flyover needs at least one shot")
		local flyoverSeconds = 0
		for _, shot in PolishConfig.FLYOVER_SHOTS do
			check(shot.zone >= 1 and shot.zone <= ZoneConfig.COUNT, "a flyover shot names a zone that does not exist")
			check(shot.caption ~= "", "every flyover shot needs a caption")
			flyoverSeconds += shot.travel + shot.hold
		end
		check(flyoverSeconds >= 5 and flyoverSeconds <= 9, `the flyover shots should total 5-9 s (6-8 s with the fades), got {flyoverSeconds}`)
		check(PolishConfig.ANALYTICS_BUDGET_SAFETY > 0 and PolishConfig.ANALYTICS_BUDGET_SAFETY <= 1, "analytics safety must be (0, 1]")
		check(PolishConfig.ANALYTICS_PASSIVE_FLUSH_SECONDS >= 60, "passive income must be batched at least a minute")

		-- The loading screen's config lives in ReplicatedFirst (src/first).
		local loadingModule = game:GetService("ReplicatedFirst"):FindFirstChild("LoadingConfig")
		check(loadingModule ~= nil and loadingModule:IsA("ModuleScript"), "ReplicatedFirst.LoadingConfig is missing")
		if loadingModule and loadingModule:IsA("ModuleScript") then
			local LoadingConfig = require(loadingModule) :: any
			check(type(LoadingConfig.TIPS) == "table" and #LoadingConfig.TIPS >= 10, "the loading screen needs 10+ tips")
			for _, tip in LoadingConfig.TIPS do
				check(type(tip.text) == "string" and #tip.text > 0 and #tip.text <= 110, "a loading tip is empty or too long")
				check(assetOk(tip.icon), "a loading tip icon must be an rbxassetid")
			end
			for _, key in { "BACKGROUND_WIDE", "BACKGROUND_TALL", "LOGO" } do
				check(assetOk(LoadingConfig[key]), `LoadingConfig.{key} must be an rbxassetid`)
			end
			check(LoadingConfig.SKIP_AFTER >= 1 and LoadingConfig.MAX_SECONDS > LoadingConfig.SKIP_AFTER, "loading screen timings are out of order")
		end
	end

	-- ==========================================================
	-- RETENTION: CODES + DAILY STREAK (retention-codes-daily)
	-- ==========================================================
	do
		local CodesConfig = require(script.Parent.CodesConfig)
		local DailyRewardConfig = require(script.Parent.DailyRewardConfig)
		-- A reward spec: known guardian, sane numbers, and every Speed scale
		-- capped so no code or day can move the Zone 8+ wall.
		local function checkSpec(spec: { [string]: any }, label: string)
			for _, key in { "cash", "cashMinutes", "cashFloor", "speed", "speedGateFraction", "speedFloor", "speedMax" } do
				local value = spec[key]
				check(value == nil or (type(value) == "number" and value == value and value >= 0 and value < math.huge), `{label}: {key} must be a finite number >= 0`)
			end
			if spec.guardianKey ~= nil then
				check(BaseGuardianConfig.ByKey[spec.guardianKey] ~= nil, `{label}: unknown guardian "{tostring(spec.guardianKey)}"`)
			end
			if (spec.speedGateFraction or 0) > 0 then
				check((spec.speedGateFraction or 0) <= 0.05, `{label}: speedGateFraction above 5% of the next gate`)
				check((spec.speedMax or 0) > 0 and (spec.speedMax or 0) <= 1e6, `{label}: a scaled Speed reward needs a speedMax in (0, 1M]`)
			end
		end
		local seen: { [string]: boolean } = {}
		for _, def in CodesConfig.Codes do
			local key = CodesConfig.normalise(def.code)
			check(key ~= nil and key == def.code, `code "{def.code}" must be upper-case letters/digits, at most {CodesConfig.MAX_LENGTH}`)
			if key then
				check(not seen[key], `code "{key}" is listed twice`)
				seen[key] = true
			end
			check(type(def.enabled) == "boolean", `code "{def.code}": enabled must be a boolean`)
			check(def.minZone == nil or (def.minZone >= 1 and def.minZone <= ZoneConfig.COUNT), `code "{def.code}": minZone out of range`)
			checkSpec(def.rewards :: any, `code "{def.code}"`)
		end
		check(CodesConfig.normalise("  museum ") == "MUSEUM", "codes must match trimmed and case-insensitive")
		check(CodesConfig.normalise("a b") == nil and CodesConfig.normalise(5) == nil, "codes must reject junk")
		check(CodesConfig.FAILURE_LIMIT >= 3 and CodesConfig.LOCKOUT_SECONDS > 0, "code lockout must allow a few typos and then lock")

		check(#DailyRewardConfig.Days == DailyRewardConfig.CYCLE_DAYS, "the daily streak needs one row per cycle day")
		for index, def in DailyRewardConfig.Days do
			check(def.day == index, `daily row {index} must be day {index}`)
			checkSpec(def :: any, `daily day {index}`)
			if def.duplicate then
				checkSpec(def.duplicate :: any, `daily day {index} duplicate`)
			end
			check(type(def.icon) == "string", `daily day {index}: icon must be a string`)
		end
		check(DailyRewardConfig.GRACE_DAYS >= 0 and DailyRewardConfig.GRACE_DAYS <= 2, "daily GRACE_DAYS must be 0-2")
		-- The streak rules, on fixed clocks.
		local day = 20000 * 86400
		local s = DailyRewardConfig.status
		check(s(0, 0, day).claimable and s(0, 0, day).day == 1, "a first claim is day 1")
		check(not s(3, 20000, day + 5).claimable, "one claim per UTC day")
		check(s(3, 19999, day).claimable and s(3, 19999, day).day == 4, "the next day continues the streak")
		check(s(7, 19999, day).day == 1, "day 7 wraps to day 1")
		local missed = 19999 - (DailyRewardConfig.GRACE_DAYS + 1)
		check(s(5, missed, day).nextStreak == 1, "missing a whole day (beyond grace) resets the streak")
		check(not s(3, 20001, day).claimable, "a claim day in the future must not pay")
	end

	-- ==========================================================
	-- SOCIAL PASS (SocialConfig, BadgeConfig)
	-- ==========================================================
	do
		local SocialConfig = require(script.Parent.SocialConfig)
		local BadgeConfig = require(script.Parent.BadgeConfig)
		for _, key in {
			"REFERRAL_MIN_PLAY_SECONDS", "REFERRAL_DAILY_CAP", "REFERRAL_CASH_MINUTES", "REFERRAL_CASH_FLOOR",
			"REFERRAL_SPEED_GATE_FRACTION", "REFERRAL_SPEED_FLOOR", "REFERRAL_TICK_SECONDS",
			"ANNOUNCE_BANNER_SECONDS", "ANNOUNCE_QUEUE_MAX", "NOTIFY_MIN_GAP_SECONDS", "NOTIFY_POLL_SECONDS",
			"NOTIFY_BATCH", "NOTIFY_MAX_LATE_SECONDS", "OWNER_COMMAND_COOLDOWN", "OWNER_NIGHT_COOLDOWN",
		} do
			local value = (SocialConfig :: any)[key]
			check(type(value) == "number" and value > 0 and value == value, `SocialConfig.{key} must be a positive number`)
		end
		check(SocialConfig.REFERRAL_CASH_MAX >= SocialConfig.REFERRAL_CASH_FLOOR, "the referral Cash ceiling must be above its floor")
		check(SocialConfig.REFERRAL_SPEED_MAX >= SocialConfig.REFERRAL_SPEED_FLOOR, "the referral Speed ceiling must be above its floor")
		-- A referral must stay a small nudge, never a way past a zone gate.
		check(SocialConfig.REFERRAL_SPEED_GATE_FRACTION <= 0.05, "a referral must pay at most 5% of the next zone gate")
		check(
			SocialConfig.FRIEND_BOOST_PER_FRIEND >= 0 and SocialConfig.FRIEND_BOOST_CAP >= 0 and SocialConfig.PREMIUM_BOOST >= 0,
			"social boosts must not be negative"
		)
		check(SocialConfig.multiplier(0, false) == 1, "no friends and no Premium must be exactly 1x")
		check(
			SocialConfig.multiplier(99, true) <= 1 + SocialConfig.FRIEND_BOOST_CAP + SocialConfig.PREMIUM_BOOST + 1e-9,
			"the friend boost must be capped"
		)
		check(RarityConfig.Rank[SocialConfig.ANNOUNCE_REVEAL_MIN_RARITY] ~= nil, "ANNOUNCE_REVEAL_MIN_RARITY must be a rarity")
		check(SocialConfig.NOTIFY_POLL_SECONDS >= 30, "the notification queue must not be polled faster than every 30s")
		for kind, id in SocialConfig.NOTIFICATION_TEMPLATES do
			check(type(id) == "string", `SocialConfig.NOTIFICATION_TEMPLATES.{kind} must be a string ("" = off)`)
		end

		check(#BadgeConfig.ZONE_BADGE_IDS == ZoneConfig.COUNT, "one zone badge per zone")
		local seenIds: { [number]: string } = {}
		for _, def in BadgeConfig.List do
			check(type(def.id) == "number" and def.id >= 0 and def.id % 1 == 0, `badge {def.key} id must be a whole number (0 = not created)`)
			if def.id ~= 0 then
				check(seenIds[def.id] == nil, `badge id {def.id} is used by both {seenIds[def.id]} and {def.key}`)
				seenIds[def.id] = def.key
			end
		end
		for _, key in { "FirstSteal", "FirstEscape", "FirstReveal", "FirstMythicReveal", "FirstSecretReveal", "IndexZoneComplete", "IndexComplete", "FirstHeist", "Streak7" } do
			check(BadgeConfig.ByKey[key] ~= nil, `BadgeConfig is missing {key}`)
		end
		for _, milestone in BadgeConfig.STEAL_MILESTONES do
			check(BadgeConfig.ByKey[milestone.key] ~= nil, `steal milestone badge {milestone.key} is missing`)
		end
	end

	-- ==========================================================
	-- GADGETS AND PATROLS (GadgetConfig, PatrolConfig;
	-- docs/handoff-parts/gadgets-patrols.md)
	-- ==========================================================
	do
		local GadgetConfig = require(script.Parent.GadgetConfig)
		local PatrolConfig = require(script.Parent.PatrolConfig)
		check(#GadgetConfig.ZONE_PRICE_MULTIPLIER == ZoneConfig.COUNT, "one gadget price multiplier per zone")
		local lastMultiplier = 0
		for zone, multiplier in GadgetConfig.ZONE_PRICE_MULTIPLIER do
			check(multiplier > 0 and multiplier >= lastMultiplier, `gadget price multiplier for zone {zone} must be positive and non-decreasing`)
			lastMultiplier = multiplier
		end
		local slots: { [number]: boolean } = {}
		for _, key in GadgetConfig.Order do
			local def = GadgetConfig.Gadgets[key]
			check(def ~= nil and def.key == key, `gadget {key} is defined under its own key`)
			if not def then
				continue
			end
			check(GadgetConfig.ByToolName[def.toolName] == def, `gadget {key} tool name is unique`)
			check(def.basePrice > 0 and def.maxCarried >= 1 and def.cooldown > 0, `gadget {key} price, stack and cooldown are positive`)
			check(def.hotbarSlot >= 3 and def.hotbarSlot <= 5 and not slots[def.hotbarSlot], `gadget {key} has its own hotbar slot 3-5`)
			slots[def.hotbarSlot] = true
			check(GadgetConfig.priceFor(key, 12) >= GadgetConfig.priceFor(key, 1), `gadget {key} price grows with the zone`)
		end
		check(#GadgetConfig.Order == 3, "three gadgets")
		check(GadgetConfig.SMOKE_CONFUSE_SECONDS > 0 and GadgetConfig.SMOKE_CONFUSE_SECONDS <= 5, "smoke confuse time is in (0, 5]")
		check(GadgetConfig.JAM_SECONDS > 0 and GadgetConfig.JAM_SECONDS <= 8, "laser jam time is in (0, 8]")
		check(GadgetConfig.GRAPPLE_RANGE > 0 and GadgetConfig.GRAPPLE_RANGE <= 60, "grapple range is in (0, 60]")
		check(GadgetConfig.GRAPPLE_PULL_SECONDS > 0 and GadgetConfig.GRAPPLE_PULL_SECONDS <= 1.5, "grapple pull is in (0, 1.5]")
		check(GadgetConfig.GRAPPLE_STANDOFF >= 0 and GadgetConfig.GRAPPLE_STANDOFF < GadgetConfig.GRAPPLE_RANGE, "grapple standoff is inside the range")
		check(GadgetConfig.GRAPPLE_TARGET_TOLERANCE > 0 and GadgetConfig.GRAPPLE_BURST_SLACK >= 0, "grapple tolerances are sane")
		check(GadgetConfig.SHARED_COOLDOWN >= 0 and GadgetConfig.USE_PER_SECOND > 0 and GadgetConfig.BUY_PER_SECOND > 0, "gadget limits are positive")
		check(type(PatrolConfig.ENABLED) == "boolean" and type(PatrolConfig.VISION_ENABLED) == "boolean", "patrol switches are booleans")
		check(PatrolConfig.MIN_ZONE >= 1 and PatrolConfig.MIN_ZONE <= ZoneConfig.COUNT + 1, "patrol start zone is a zone (or COUNT + 1 = none)")
		check(PatrolConfig.SPEED > 0 and PatrolConfig.SPEED <= 30, "patrol speed is slow and positive")
		check(PatrolConfig.ROUTE_NEAR_Z >= 8 and PatrolConfig.ROUTE_FAR_Z > PatrolConfig.ROUTE_NEAR_Z, "patrol loop starts clear of the doorway line")
		check(PatrolConfig.VISION_RANGE > 0 and PatrolConfig.VISION_ANGLE > 0 and PatrolConfig.VISION_ANGLE <= 180, "vision cone is sane")
		check(PatrolConfig.VISION_HZ > 0 and PatrolConfig.VISION_HZ <= 10, "vision checks are throttled (<= 10 Hz)")
		check(PatrolConfig.WAYPOINT_REACH > 0 and PatrolConfig.CORNER_PAUSE >= 0, "patrol arrival and pause are sane")
	end

	-- ==========================================================
	-- FUSION / AUTO REVEAL / BASE THEMES (fusion-autoreveal-bases)
	-- ==========================================================
	do
		local FusionConfig = require(script.Parent.FusionConfig)
		local BaseThemeConfig = require(script.Parent.BaseThemeConfig)
		check(FusionConfig.INPUTS == 3, "fusion takes exactly three copies")
		local oddsTotal = 0
		local lastRank = -1
		for _, row in FusionConfig.MutationOdds do
			check(RarityConfig.MutationById[row.id] ~= nil, `fusion odds name unknown mutation "{row.id}"`)
			check(row.chance >= 0, `fusion odds for {row.id} must not be negative`)
			local rank = RarityConfig.mutationRank(row.id)
			check(rank > lastRank, "fusion odds must list mutations weakest first, once each")
			lastRank = rank
			oddsTotal += row.chance
		end
		check(near(oddsTotal, 100, 1e-6), `fusion mutation odds must sum to 100, sum to {oddsTotal}`)
		-- The floor never downgrades, and the shown odds still sum to 100.
		for _, mutation in RarityConfig.Mutations do
			local shown = 0
			for _, row in FusionConfig.mutationOutcomes(mutation.id) do
				shown += row.chance
				check(RarityConfig.mutationRank(row.id) >= RarityConfig.mutationRank(mutation.id), "fusion outcomes must not fall below the floor")
			end
			check(near(shown, 100, 1e-6), `fusion outcomes above {mutation.id} must sum to 100`)
			check(RarityConfig.mutationRank(FusionConfig.rollMutation(mutation.id, 0)) >= RarityConfig.mutationRank(mutation.id), `a fusion roll must never drop below {mutation.id}`)
		end
		check(FusionConfig.targetClass(#ScaleConfig.Variants) == #ScaleConfig.Variants, "fusion must cap at the largest size")
		check(FusionConfig.targetClass(1) == 2, "fusion must step one size class up")
		check(FusionConfig.scaleFor(#ScaleConfig.Variants, 0, ScaleConfig.MAX_SCALE) == ScaleConfig.MAX_SCALE, "a capped fusion must never shrink the best input")
		check(FusionConfig.costFor(0, 1) >= FusionConfig.MIN_COST, "fusion must cost at least MIN_COST")
		check(FusionConfig.costFor(1e6, 3) > FusionConfig.costFor(10, 3), "fusion cost must follow income")
		check(FusionConfig.REQUESTS_PER_SECOND > 0 and BaseThemeConfig.REQUESTS_PER_SECOND > 0, "feature request budgets must be positive")

		-- Auto Reveal pacing.
		check(HatchConfig.QuickReveal.lock > HatchConfig.QuickReveal.swapAt, "the quick reveal lock must outlast its swap")
		check(HatchConfig.AUTO_REVEAL_POLL > 0 and HatchConfig.AUTO_REVEAL_NEAR_STUDS > 0, "auto reveal poll and range must be positive")
		check(HatchConfig.autoRevealSpacing("Divine", false) > HatchConfig.lockSeconds("Divine"), "auto reveals must not overlap the full sequence")
		check(MonetizationConfig.AutoRevealPass.gamePassId >= 0, "Auto Reveal pass id must be 0 (placeholder) or a real id")

		-- Themes and pedestals: one key namespace, known passes, a free default.
		local keys: { [string]: boolean } = {}
		local function unique(key: string)
			check(not keys[key], `base theme / pedestal key "{key}" is used twice`)
			keys[key] = true
		end
		check(BaseThemeConfig.ThemeByKey[BaseThemeConfig.DEFAULT_THEME] ~= nil, "the default theme must exist")
		check(BaseThemeConfig.PedestalByKey[BaseThemeConfig.DEFAULT_PEDESTAL] ~= nil, "the default pedestal must exist")
		for _, theme in BaseThemeConfig.Themes do
			unique(theme.key)
			check(theme.cash >= 0, `theme {theme.key} has a negative price`)
			if theme.passKey then
				check(MonetizationConfig.ThemePassByKey[theme.passKey] ~= nil, `theme {theme.key} names unknown pass {theme.passKey}`)
				check(theme.cash == 0, `Robux theme {theme.key} must not also have a Cash price`)
			end
		end
		for _, skin in BaseThemeConfig.Pedestals do
			unique(skin.key)
			check(skin.cash >= 0, `pedestal {skin.key} has a negative price`)
			if skin.passKey then
				check(MonetizationConfig.ThemePassByKey[skin.passKey] ~= nil, `pedestal {skin.key} names unknown pass {skin.passKey}`)
			end
		end
		local defaultTheme = BaseThemeConfig.ThemeByKey[BaseThemeConfig.DEFAULT_THEME]
		check(defaultTheme ~= nil and defaultTheme.cash == 0 and defaultTheme.passKey == nil, "the default theme must be free")
	end

	-- ==========================================================
	-- RETENTION: QUESTS + SEASON PASS (retention-quests-pass)
	-- ==========================================================
	do
		local QuestConfig = require(script.Parent.QuestConfig)
		local SeasonPassConfig = require(script.Parent.SeasonPassConfig)
		check(type(QuestConfig.ENABLED) == "boolean", "QuestConfig.ENABLED must be a boolean")
		check(type(SeasonPassConfig.ENABLED) == "boolean", "SeasonPassConfig.ENABLED must be a boolean")
		local ids: { [string]: boolean } = {}
		for period, pool in QuestConfig.Pools do
			local kinds: { [string]: boolean } = {}
			for _, t in pool do
				check(not ids[t.id], `quest id "{t.id}" appears twice`)
				ids[t.id] = true
				kinds[t.kind] = true
				check(QuestConfig.EVENT_FOR_KIND[t.kind] ~= nil, `quest "{t.id}" has unknown kind "{t.kind}"`)
				check(t.weight > 0 and t.min >= 1 and t.max >= t.min, `quest "{t.id}" has a bad weight or target range`)
				check(t.minRarity == nil or RarityConfig.rank(t.minRarity) > 0, `quest "{t.id}" has unknown rarity`)
				check(t.kind ~= "earn" or (t.earnMinutes or 0) > 0, `earn quest "{t.id}" needs earnMinutes`)
				check(string.find(QuestConfig.describe(t, t.min), "{", 1, true) == nil, `quest "{t.id}" text has an unfilled placeholder`)
			end
			-- One per kind per list, so the pool needs at least COUNT kinds.
			local distinct = 0
			for _ in kinds do
				distinct += 1
			end
			check(distinct >= QuestConfig.COUNTS[period], `the {period} pool has fewer kinds than quests per list`)
			-- Determinism: the same seed and context give the same list.
			local context = { highestZone = 1, baseIncome = 0, undiscovered = 96 }
			local a = QuestConfig.generate(pool, QuestConfig.COUNTS[period], 12345, context)
			local b = QuestConfig.generate(pool, QuestConfig.COUNTS[period], 12345, context)
			check(#a == QuestConfig.COUNTS[period], `a new player's {period} list is not full`)
			local same = #a == #b
			for i = 1, math.min(#a, #b) do
				same = same and a[i].id == b[i].id and a[i].target == b[i].target
			end
			check(same, `{period} quest generation is not deterministic`)
		end
		-- Calendar: a Monday 00:00 UTC is a weekly boundary, a Sunday is not.
		local monday = DateTime.fromUniversalTime(2026, 9, 14).UnixTimestamp
		check(QuestConfig.weekOf(monday) == QuestConfig.weekOf(monday - 1) + 1, "the weekly reset is not Monday 00:00 UTC")
		check(QuestConfig.resetAt("weekly", QuestConfig.weekOf(monday)) == monday + 7 * 86400, "weekly resetAt is wrong")
		check(QuestConfig.resetAt("daily", QuestConfig.dayOf(monday)) == monday + 86400, "daily resetAt is wrong")
		-- Rewards never exceed the spin wheel's Speed caps (the Zone 8+ wall).
		for period, scale in QuestConfig.Rewards do
			check(scale.speedCap <= 5e6, `{period} quest Speed cap is above the wheel's`)
			local _, speed = QuestConfig.rewardFor(period, nil, 0, 20e9)
			check(speed <= scale.speedCap, `{period} quest Speed reward ignores its cap`)
		end
		check(#SeasonPassConfig.Tiers == SeasonPassConfig.TIER_COUNT, "the season pass must define every tier")
		check(SeasonPassConfig.ENDS_AT > SeasonPassConfig.STARTS_AT, "the season must end after it starts")
		local last = 0
		for tier, def in SeasonPassConfig.Tiers do
			check(def.tier == tier, `season tier {tier} is out of order`)
			check(SeasonPassConfig.Thresholds[tier] > last, `season tier {tier} threshold does not increase`)
			last = SeasonPassConfig.Thresholds[tier]
			for _, reward in { def.free, def.premium } do
				if reward.kind == "speed" then
					check((reward.cap or math.huge) <= 5e6, `season tier {tier} Speed cap is above the wheel's`)
				elseif reward.kind == "guardian" then
					check(BaseGuardianConfig.ByKey[reward.guardianKey or ""] ~= nil, `season tier {tier} names an unknown guardian`)
				elseif reward.kind == "trail" then
					check(MonetizationConfig.TrailByKey[reward.trailKey or ""] ~= nil, `season tier {tier} names an unknown trail`)
				elseif reward.kind == "title" then
					check((reward.title or "") ~= "", `season tier {tier} has an empty title`)
				end
			end
		end
		check(SeasonPassConfig.tierFor(0) == 0, "0 XP must be tier 0")
		check(SeasonPassConfig.tierFor(last) == SeasonPassConfig.TIER_COUNT, "the last threshold must reach the last tier")
		check(MonetizationConfig.SeasonPremiumPass.gamePassId >= 0, "the season premium pass id must be 0 (placeholder) or real")
	end

	-- ==========================================================
	-- TRADING / GIFTING / BOARDS (TradeConfig, BoardConfig, gift packs)
	-- ==========================================================
	do
		local TradeConfig = require(script.Parent.TradeConfig)
		local BoardConfig = require(script.Parent.BoardConfig)
		for _, key in {
			"MAX_ITEMS", "COUNTDOWN_SECONDS", "SESSION_IDLE_SECONDS", "SESSION_CHECK_SECONDS", "MAX_CASH",
			"REQUEST_TIMEOUT", "REQUEST_COOLDOWN", "MAX_PENDING_PER_TARGET", "JOIN_GRACE_SECONDS",
			"TRADES_PER_WINDOW", "TRADE_WINDOW_SECONDS", "REMOTE_PER_SECOND", "REMOTE_BURST",
			"LOPSIDED_RATIO", "LOPSIDED_MIN_INCOME", "PROMPT_DISTANCE", "PROMPT_HOLD_SECONDS",
			"GIFT_INTENT_SECONDS", "GIFT_PER_SECOND", "GIFT_BURST", "TRADE_LOG_PER_USER",
		} do
			local value = (TradeConfig :: any)[key]
			check(type(value) == "number" and value > 0, `TradeConfig.{key} must be a positive number`)
		end
		check(TradeConfig.MAX_ITEMS == math.floor(TradeConfig.MAX_ITEMS) and TradeConfig.MAX_ITEMS <= 12, "trade item cap must be a whole number <= 12")
		check(TradeConfig.MAX_CASH <= 2 ^ 53, "trade Cash cap must stay an exact double")
		check(TradeConfig.SESSION_CHECK_SECONDS <= 1, "an open trade must be re-checked at least every second")
		check(TradeConfig.REQUEST_COOLDOWN < TradeConfig.REQUEST_TIMEOUT, "a request cooldown longer than its timeout would read as a dead button")
		check(TradeConfig.LOPSIDED_RATIO > 1, "the lopsided warning ratio must be above 1")
		-- A gift intent must outlive a slow Robux dialog.
		check(TradeConfig.GIFT_INTENT_SECONDS >= 120, "the gift recipient must be remembered for at least two minutes")

		-- One gift per Cash / Speed pack, same price, same amount, unique ids.
		local giftIds: { [number]: boolean } = {}
		local gifted: { [string]: boolean } = {}
		for _, gift in MonetizationConfig.GiftProducts do
			local pack = if gift.giftOf then MonetizationConfig.ProductByKey[gift.giftOf] else nil
			check(gift.kind == "Gift", `{gift.key} must be kind Gift`)
			check(pack ~= nil and (pack.kind == "Cash" or pack.kind == "Speed"), `{gift.key}.giftOf must name a Cash or Speed pack`)
			if pack then
				check(gift.robux == pack.robux, `{gift.key} must cost the same as {pack.key}`)
				check(gift.amount == pack.amount, `{gift.key} must show the same floor amount as {pack.key}`)
				gifted[pack.key] = true
			end
			if gift.productId > 0 then
				check(not giftIds[gift.productId], `{gift.key} reuses a gift product id`)
				check(MonetizationConfig.ProductById[gift.productId] == gift, `{gift.key}'s id collides with another product`)
				giftIds[gift.productId] = true
			end
		end
		for _, list in { MonetizationConfig.CashProducts, MonetizationConfig.SpeedProducts } do
			for _, pack in list do
				check(gifted[pack.key] == true, `{pack.key} has no gift product`)
			end
		end

		-- Boards.
		local keys: { [string]: boolean } = {}
		for _, def in BoardConfig.Boards do
			check(not keys[def.key], `board {def.key} is listed twice`)
			keys[def.key] = true
			check(def.besides == "Money" or def.besides == "Speed", `board {def.key} must stand beside Money or Speed`)
			check(def.side == 1 or def.side == -1, `board {def.key}.side must be 1 or -1`)
			check(def.slot >= 1, `board {def.key}.slot must be at least 1`)
			check(type(BoardConfig.STORE_KEYS[def.key]) == "string", `board {def.key} has no store name`)
		end
		for _, key in { "GAP", "EDGE_CLEARANCE", "PLAYTIME_TICK_SECONDS", "PLAYTIME_SUBMIT_SECONDS", "MIN_WRITE_BUDGET" } do
			local value = (BoardConfig :: any)[key]
			check(type(value) == "number" and value > 0, `BoardConfig.{key} must be a positive number`)
		end
		-- ISO weeks: 2026-09-17 is 2026-W38; 2021-01-01 belongs to 2020-W53;
		-- 2024-12-30 to 2025-W01.
		check(BoardConfig.isoWeek(1789646400) == "2026W38", "isoWeek(2026-09-17) must be 2026W38")
		check(BoardConfig.isoWeek(1609502400) == "2020W53", "isoWeek(2021-01-01) must be 2020W53")
		check(BoardConfig.isoWeek(1735560000) == "2025W01", "isoWeek(2024-12-30) must be 2025W01")
		check(BoardConfig.WEEKLY_SOURCES.product ~= true and BoardConfig.WEEKLY_SOURCES.debug ~= true, "purchases and debug grants must not count as weekly earnings")
	end

	-- ==========================================================
	-- VAULTS AND CREWS (VaultConfig, CrewConfig; docs/handoff-parts/vaults-crews.md)
	-- ==========================================================
	do
		local VaultConfig = require(script.Parent.VaultConfig)
		local CrewConfig = require(script.Parent.CrewConfig)
		check(type(VaultConfig.ENABLED) == "boolean" and type(VaultConfig.RESTOCK_AT_NIGHT) == "boolean", "VaultConfig switches must be booleans")
		for _, key in { "RESTOCK_SECONDS", "SPEED_GATE_FRACTION", "DOOR_OPEN_RADIUS", "DOOR_CHECK_INTERVAL", "DISPLAY_FOOTPRINT", "RING_GAP", "RING_WIDTH", "PEDESTAL_HEIGHT" } do
			local value = (VaultConfig :: any)[key]
			check(type(value) == "number" and value > 0, `VaultConfig.{key} must be a positive number`)
		end
		-- A 2.2-stud player must fit between the pedestal and the arms.
		check(VaultConfig.RING_GAP >= 2.5, "the vault ring gap must fit a standing player")
		local guard = VaultConfig.GUARDIAN
		check(guard.speedScale >= 1 and guard.wakeScale > 0 and guard.wakeScale <= 1 and guard.catchScale >= 1, "the Vault Guardian must be at least as tough as a room guard")
		check(guard.laserLeash >= require(script.Parent.SecurityConfig).LASER_CHASE_TIMEOUT and guard.maxHeight > 0 and guard.maxHeight < 20, "Vault Guardian leash and height (door is 20 studs)")
		for zoneIndex = 1, ZoneConfig.COUNT do
			local rows = VaultConfig.rollTable(zoneIndex)
			local sum, top = 0, VaultConfig.topRarities(zoneIndex)
			for _, row in rows do
				sum += row.chance
				check(row.item.rarity == top[1] or row.item.rarity == top[2], `zone {zoneIndex} vault rolls only its top two rarities`)
			end
			check(#rows > 0 and near(sum, 1, 1e-6), `zone {zoneIndex} vault roll table sums to 1`)
			check(#VaultConfig.beamsFor(zoneIndex) >= 2 and #VaultConfig.beamsFor(zoneIndex) <= 6, `zone {zoneIndex} vault has 2-6 laser arms`)
			local ring = VaultConfig.ring(zoneIndex)
			check(ring.outer - ring.inner >= 4, `zone {zoneIndex} vault laser ring is at least 4 studs wide`)
		end
		check(CrewConfig.MAX_MEMBERS >= 2 and CrewConfig.MAX_MEMBERS <= 8, "crew size must be 2-8")
		for _, key in { "INVITE_SECONDS", "MAX_OUTGOING_INVITES", "REQUESTS_PER_SECOND", "ASSIST_RADIUS", "CHASE_ASSIST_SECONDS", "PRESENCE_SECONDS", "BONUS_INCOME_SECONDS", "BONUS_FRACTION", "TRACK_INTERVAL", "NAMEPLATE_MAX_DISTANCE" } do
			local value = (CrewConfig :: any)[key]
			check(type(value) == "number" and value > 0, `CrewConfig.{key} must be a positive number`)
		end
		check(CrewConfig.BONUS_FRACTION <= 1, "the crew bonus is a fraction of the item's income")
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
