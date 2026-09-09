--!strict
--[[
	EconomyTests
	Deterministic regression suite for the economy rebuild. Studio-only in
	practice (DebugService "economyTests"); pure in form - it builds its own
	profiles and rolls its own seeded Randoms, touching no player and no
	socket.

	WHAT IT PROVES
	  1. Config validation (validate.luau) passes.
	  2. THE MUTATION SYSTEM IS UNTOUCHED: names, order, odds, multipliers,
	     aliases, colours and the VFX template names are identical to the
	     locked snapshot below; one mutation per item; the seeded roll lands
	     on 90 / 6 / 2.5 / 1 / 0.5.
	  3. NIGHT NEVER MODIFIES A ROLL: the refresh takes no lean, and the item,
	     Scale and mutation rollers are pure functions of their Random.
	  4. THE SAVE MIGRATION preserves every legacy item's pre-patch income by
	     the inverse Scale curve, keeps its look, and is idempotent.
	  5. THE INCOME FUNNEL rounds and floors exactly as specified.
	  6. THE ZONE 9 ASSERTION and the number formatter.
	  7. THE MYSTERY + HATCH SYSTEM: four sockets, the hatch-time table and
	     its modifiers, the 12h clamp, a sealed container earning nothing,
	     the v11 migration treating every existing item as already hatched,
	     and the zone-biased Scale roll landing on its configured odds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local IndexConfig = require(ReplicatedStorage.Shared.Config.IndexConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local HatchConfig = require(ReplicatedStorage.Shared.Config.HatchConfig)
local MysteryConfig = require(ReplicatedStorage.Shared.Config.MysteryConfig)
local PvPConfig = require(ReplicatedStorage.Shared.Config.PvPConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local validate = require(ReplicatedStorage.Shared.Config.validate)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local LootService = require(script.Parent.LootService)

local EconomyTests = {}

export type Report = { passed: number, failed: { string }, sections: { [string]: { passed: number, failed: number } } }

--- THE LOCKED MUTATION SNAPSHOT. If any of this ever needs to change, the
--- change is a deliberate design decision made here first, never a drift.
local MUTATION_SNAPSHOT = {
	rows = {
		{ id = "Normal", chance = 90.0, multiplier = 1.00 },
		{ id = "Shiny", chance = 6.0, multiplier = 1.25 },
		{ id = "Golden", chance = 2.5, multiplier = 2.00 },
		{ id = "Flaming", chance = 1.0, multiplier = 2.50 },
		{ id = "Corrupted", chance = 0.5, multiplier = 3.00 },
	},
	aliases = { Neon = "Flaming", Glitched = "Corrupted" },
	colors = {
		Shiny = Color3.fromRGB(226, 244, 255),
		Golden = Color3.fromRGB(255, 205, 60),
		Flaming = Color3.fromRGB(255, 122, 36),
		Corrupted = Color3.fromRGB(168, 62, 255),
	},
	--- The authored templates MutationVfx reads under
	--- ReplicatedStorage.GameAssets.Mutations, one per non-Normal mutation.
	vfxTemplates = { "Shiny", "Golden", "Flaming", "Corrupted" },
}

local function near(a: number, b: number, tolerance: number?): boolean
	return math.abs(a - b) <= (tolerance or 1e-9)
end

function EconomyTests.run(): Report
	local report: Report = { passed = 0, failed = {}, sections = {} }
	local section = "setup"

	local function check(condition: boolean, message: string)
		local bucket = report.sections[section]
		if not bucket then
			bucket = { passed = 0, failed = 0 }
			report.sections[section] = bucket
		end
		if condition then
			report.passed += 1
			bucket.passed += 1
		else
			table.insert(report.failed, `[{section}] {message}`)
			bucket.failed += 1
		end
	end

	-- ==========================================================
	-- 1. CONFIG VALIDATION
	-- ==========================================================
	section = "validate"
	do
		local result = validate()
		check(#result.failed == 0, `validate.luau reported {#result.failed} failure(s): {table.concat(result.failed, " | ")}`)
		report.passed += result.passed
	end

	-- ==========================================================
	-- 2. MUTATIONS - LOCKED
	-- ==========================================================
	section = "mutations"
	do
		check(#RarityConfig.Mutations == #MUTATION_SNAPSHOT.rows, "mutation count changed")
		for index, row in MUTATION_SNAPSHOT.rows do
			local live = RarityConfig.Mutations[index]
			check(live ~= nil and live.id == row.id, `mutation {index} name changed`)
			check(live ~= nil and near(live.chance, row.chance), `mutation {row.id} odds changed`)
			check(live ~= nil and near(live.multiplier, row.multiplier), `mutation {row.id} multiplier changed`)
			check(near(RarityConfig.mutationMultiplier(row.id), row.multiplier), `mutationMultiplier({row.id}) changed`)
		end
		for legacy, current in MUTATION_SNAPSHOT.aliases do
			check(RarityConfig.MutationAliases[legacy] == current, `alias {legacy} -> {current} changed`)
			check(RarityConfig.normaliseMutation(legacy) == current, `normaliseMutation({legacy}) changed`)
		end
		local aliasCount = 0
		for _ in RarityConfig.MutationAliases do
			aliasCount += 1
		end
		check(aliasCount == 2, "an alias was added or removed")
		for id, color in MUTATION_SNAPSHOT.colors do
			check(RarityConfig.MutationColors[id] == color, `mutation colour for {id} changed`)
		end
		-- VFX references: the template folder, when present, carries exactly
		-- the four authored effects, by the names MutationVfx looks up.
		local assets = ReplicatedStorage:FindFirstChild("GameAssets")
		local folder = assets and assets:FindFirstChild("Mutations")
		if folder then
			for _, name in MUTATION_SNAPSHOT.vfxTemplates do
				check(folder:FindFirstChild(name) ~= nil, `VFX template {name} missing from GameAssets.Mutations`)
			end
		end
		-- One mutation per item: the roll returns one id and the saved record
		-- carries one field.
		local rng = Random.new(7)
		local counts: { [string]: number } = {}
		local n = 200000
		for _ = 1, n do
			local id = LootService.rollMutationId(rng)
			check(type(id) == "string", "the mutation roll must return one id")
			counts[id] = (counts[id] or 0) + 1
			if type(id) ~= "string" then
				break
			end
		end
		for _, row in MUTATION_SNAPSHOT.rows do
			local observed = (counts[row.id] or 0) / n * 100
			check(math.abs(observed - row.chance) < 0.25, `seeded mutation roll for {row.id}: {observed}% vs {row.chance}%`)
		end
		local extra = 0
		for id in counts do
			if not RarityConfig.MutationById[id] then
				extra += 1
			end
		end
		check(extra == 0, "the roll produced an unknown mutation")
	end

	-- ==========================================================
	-- 3. NIGHT NEVER MODIFIES A ROLL
	-- ==========================================================
	section = "night"
	do
		check(debug.info(LootService.refreshAll, "a") == 0, "refreshAll must take no lean argument")
		check((NightConfig :: any).refreshBoosts == nil and (NightConfig :: any).NIGHTFALL_RARITY_BOOST == nil, "no Night lean may exist in config")
		check((LootService :: any).setRollBoosts == nil, "no roll-boost setter may exist")
		-- The rollers are pure functions of their Random: the same seed yields
		-- the same sequence whatever the world clock says.
		local function sequence(seed: number): string
			local rng = Random.new(seed)
			local parts = {}
			for _ = 1, 200 do
				local def = LootService.rollItem(9, rng)
				table.insert(parts, `{if def then def.id else "nil"}:{ScaleConfig.rollScale(9, rng)}:{LootService.rollMutationId(rng)}`)
			end
			return table.concat(parts, ",")
		end
		check(sequence(123) == sequence(123), "the rollers must be deterministic under a seed")
		check(sequence(123) ~= sequence(124), "different seeds must roll differently")
		-- Configured odds are exactly the weight shares, and the observed roll
		-- lands on them in every parity zone.
		local rng = Random.new(99)
		for zoneIndex = 1, ZoneConfig.PARITY_COUNT do
			local counts: { [string]: number } = {}
			local n = 100000
			for _ = 1, n do
				local def = LootService.rollItem(zoneIndex, rng)
				if def then
					counts[def.id] = (counts[def.id] or 0) + 1
				end
			end
			for _, item in LootConfig.pool(zoneIndex) do
				local expected = LootConfig.weightShare(item.id) * 100
				local observed = (counts[item.id] or 0) / n * 100
				check(math.abs(observed - expected) < math.max(0.5, expected * 0.15), `zone {zoneIndex} {item.id}: observed {observed}% vs {expected}%`)
			end
		end
	end

	-- ==========================================================
	-- 4. SAVE MIGRATION
	-- ==========================================================
	section = "migration"
	do
		local function legacyItem(size: string, visual: number, mutation: string, itemId: string): any
			local def = LootConfig.ById[itemId]
			local multiplier = RarityConfig.LegacySizeIncomeMultipliers[size]
			return {
				InstanceId = `test-{size}-{mutation}`,
				ItemId = itemId,
				ZoneId = def.zoneIndex,
				Rarity = def.rarity,
				Size = size,
				Mutation = mutation,
				BaseIncome = def.income,
				-- The pre-patch formula: floor(base x size x mutation).
				FinalIncome = math.floor(def.income * multiplier * RarityConfig.mutationMultiplier(mutation)),
				SlotIndex = 1,
				VisualScale = visual,
				SizeVisualVersion = 2,
				GrowthSeconds = 600,
				ProtectedUntil = os.time() + 3600,
			}
		end
		local profile: any = {
			SchemaVersion = 9,
			DisplayItems = {
				legacyItem("Normal", 1, "Normal", "Museum_AncientVase"),
				legacyItem("Titan", 8.5, "Golden", "SecretLab_MutationCrystal"),
				legacyItem("Colossal", 22, "Neon", "Grandma_CookieJar"),
				legacyItem("Huge", 2.5, "Corrupted", "Bank_GoldBar"),
			},
			Inventory = { legacyItem("Giant", 4, "Shiny", "Gym_Trophy") },
		}
		local before = {}
		for _, list in { profile.DisplayItems, profile.Inventory } do
			for _, item in list do
				before[item.InstanceId] = { income = item.FinalIncome, visual = item.VisualScale, size = item.Size, mutation = item.Mutation, growth = item.GrowthSeconds, protectedUntil = item.ProtectedUntil }
			end
		end

		local migrated = DataService.migrate(profile)
		check(migrated.SchemaVersion >= 10, "migration must reach schema 10")
		local snapshotAfterFirst = {}
		for _, list in { migrated.DisplayItems, migrated.Inventory } do
			for _, item in list do
				local was = before[item.InstanceId]
				local expectedScale = ScaleConfig.roundScale(ScaleConfig.inverseSizeFactor(RarityConfig.LegacySizeIncomeMultipliers[was.size]))
				check(near(item.Scale, expectedScale, 1e-9), `{item.InstanceId}: Scale must be the inverse of its old multiplier`)
				check(item.LegacyVisualScale == was.visual, `{item.InstanceId}: legacy look must be kept`)
				check(item.EconomyScaleVersion == ScaleConfig.ECONOMY_SCALE_VERSION, `{item.InstanceId}: must be stamped`)
				check(item.MaturationSeconds == 0, `{item.InstanceId}: a legacy item keeps earning`)
				check(item.Size == was.size and item.Mutation == was.mutation, `{item.InstanceId}: size word and mutation untouched by migrate`)
				check(item.GrowthSeconds == was.growth and item.ProtectedUntil == was.protectedUntil, `{item.InstanceId}: growth and protection untouched`)
				-- Income preserved: the new per-item rate at moneyPass 1 is within
				-- rounding of the old floor(base x size x mutation).
				DataService.reconcileItem(item)
				local mutation = RarityConfig.normaliseMutation(was.mutation)
				local newRate = RarityConfig.preBoostRate(item.BaseIncome, item.Scale, mutation, 1)
				local relative = math.abs(newRate - was.income) / math.max(was.income, 1)
				check(relative <= 1e-4 or math.abs(newRate - was.income) <= 1, `{item.InstanceId}: income {was.income} -> {newRate} not preserved`)
				check(item.FinalIncome == newRate, `{item.InstanceId}: reconcile must rebuild FinalIncome from Scale`)
				check(item.Mutation == mutation, `{item.InstanceId}: alias must normalise on reconcile`)
				snapshotAfterFirst[item.InstanceId] = { scale = item.Scale, visual = item.LegacyVisualScale, income = item.FinalIncome }
			end
		end
		-- Idempotent: a second pass through migrate + reconcile changes nothing.
		local again = DataService.migrate(migrated)
		for _, list in { again.DisplayItems, again.Inventory } do
			for _, item in list do
				local changed = DataService.reconcileItem(item)
				local first = snapshotAfterFirst[item.InstanceId]
				check(item.Scale == first.scale and item.LegacyVisualScale == first.visual and item.FinalIncome == first.income, `{item.InstanceId}: second migration moved the item`)
				check(changed == false, `{item.InstanceId}: reconcile must be idempotent`)
			end
		end
		-- A new item (no legacy look) takes its word from its Scale.
		local fresh: any = { InstanceId = "fresh", ItemId = "Museum_Ruby", ZoneId = 1, Rarity = "Rare", Size = "Normal", Mutation = "Normal", BaseIncome = 45, FinalIncome = 0, SlotIndex = 2, Scale = 12, VisualScale = 12, EconomyScaleVersion = 1, GrowthSeconds = 0 }
		DataService.reconcileItem(fresh)
		check(fresh.Size == "Titan", "a fresh Scale-12 item must read as Titan")
		check(fresh.FinalIncome == RarityConfig.preBoostRate(45, 12, "Normal", 1), "a fresh item's FinalIncome must follow its Scale")
	end

	-- ==========================================================
	-- 5. THE INCOME FUNNEL
	-- ==========================================================
	section = "funnel"
	do
		check(RarityConfig.preBoostRate(45e6, 1, "Normal", 1) == 45e6, "Scale 1, no mutation, no pass")
		check(RarityConfig.preBoostRate(45e6, 1, "Normal", 2) == 90e6, "the pass doubles inside the per-item rounding")
		check(RarityConfig.preBoostRate(45e6, 2, "Golden", 2) == math.round(45e6 * 2 ^ 1.85 * 2 * 2), "size, mutation and pass multiply once each")
		check(RarityConfig.preBoostRate(1, 0.1, "Normal", 1) == 1, "floor at 1")
		check(RarityConfig.preBoostRate(1, 1, "Shiny", 1) == 1, "1 x 1.25 rounds to 1")
		check(RarityConfig.preBoostRate(2, 1, "Shiny", 1) == 3, "2 x 1.25 = 2.5 rounds half away from zero to 3")
		check(GameConfig.SERVER_EARNINGS_BOOST == 1 and GameConfig.TEMPORARY_EARNINGS_BOOST == 1, "boost hooks default to 1")
		check(IndexConfig.incomeMultiplier({ zone_1 = true }) == 1, "no Index income percentage")
		check(ScaleConfig.maturationSeconds(0, 22) == 0, "no base growth time means immediate income")
		check(near(ScaleConfig.maturationSeconds(100, 4), 100 * (4 / 2) ^ 1.389), "maturation stretches with Scale")
		check(near(ScaleConfig.carryScale(22), 2.6 + math.sqrt(22 - 2.6)), "carry compression formula")
		check(RarityConfig.sizeLabelFor(1.0) == "Normal" and RarityConfig.sizeLabelFor(6) == "Giant" and RarityConfig.sizeLabelFor(20) == "Colossal", "labels")
	end

	-- ==========================================================
	-- 6. ZONE 9 AND FORMATTING
	-- ==========================================================
	section = "zone9"
	do
		local p = LootConfig.weightShare("SecretLab_MutationCrystal")
		local sockets = ZoneConfig.SOCKETS_PER_ZONE
		-- THE SOCKET COUNT CHANGED. The economy brief assumed five nests; the
		-- later mystery brief says "use exactly four active spawn positions
		-- per zone, remove the fifth spawn completely". Four wins, so the
		-- per-hour figures below are the four-socket restatement of the same
		-- per-socket probability, which is itself unchanged.
		check(sockets == 4, `the zone must have four sockets, not {sockets}`)
		check(near(p, 0.00495856, 1e-9), `per socket {p * 100}% must be 0.495856%`)
		check(near(1 - (1 - p) ^ sockets, 0.0196872, 1e-6), "at least once in 4 nests must be ~1.96872%")
		-- AND TWELVE REFRESHES AN HOUR WAS THE OTHER STALE INPUT. The live
		-- cycle is NightConfig's 270 seconds, so a zone refreshes 3600/270
		-- times an hour, not twelve. Derived from the config so the two
		-- numbers can never drift apart again.
		local refreshesPerHour = 3600 / NightConfig.CYCLE_SECONDS
		check(near(refreshesPerHour, 3600 / 270), `the cycle must refresh {3600 / 270} times an hour, not {refreshesPerHour}`)
		check(near(p * sockets * refreshesPerHour, 0.26445653, 1e-7), "expected occurrences/hour must be 0.26445653")
		-- The brief's own figure, kept as the record of what it assumed.
		check(near(p * 5 * 12, 0.2975136, 1e-7), "the retired five-nest, twelve-refresh figure was 0.2975136/hour")
		check(p * sockets * 12 < 1, "the Blue Crystal must no longer appear ~7.2 times an hour")
		-- The five-socket figures the economy brief asked for, kept as the
		-- record of what changed and why.
		check(near(1 - (1 - p) ^ 5, 0.024548, 5e-6), "the retired five-nest figure was ~2.4548%")
	end
	section = "format"
	do
		for _, row in { { 999e9, "999B" }, { 1e12, "1T" }, { 1.5e12, "1.5T" }, { 999e12, "999T" }, { 1e15, "1Qa" }, { 999.6e9, "1T" }, { 1_000_000_000_000, "1T" } } do
			check(NumberFormat.short(row[1]) == row[2], `{row[1]} -> {NumberFormat.short(row[1])}, expected {row[2]}`)
		end
	end

	-- ==========================================================
	-- 7. THE MYSTERY SPAWN AND HATCH SYSTEM
	-- ==========================================================
	section = "hatch"
	do
		-- The exact table from the brief: 5s, 15s, 45s, 2m, 5m, 15m, 45m, 2h,
		-- 6h, 12h, read through the public accessor so a reordering of the
		-- rarity ladder is caught here rather than in a live hatch.
		local expectedBase = { 5, 15, 45, 120, 300, 900, 2700, 7200, 21600, 43200 }
		check(#HatchConfig.RarityBaseSeconds == #expectedBase, "the base-time table must have one entry per rarity")
		for rank, seconds in expectedBase do
			local rarity = RarityConfig.Order[rank]
			check(HatchConfig.RarityBaseSeconds[rank] == seconds, `base time {rank} must be {seconds}s`)
			check(HatchConfig.rarityBaseSeconds(rarity) == seconds, `{rarity} must incubate {seconds}s at Normal/Normal`)
			check(HatchConfig.hatchSeconds(rarity, "Normal", "Normal") == seconds, `{rarity} Normal/Normal must be {seconds}s`)
		end

		-- Size modifiers: 1.00 / 1.08 / 1.20 / 1.35 / 1.60 / 2.00.
		local expectedSize = { Normal = 1.00, Big = 1.08, Huge = 1.20, Giant = 1.35, Titan = 1.60, Colossal = 2.00 }
		for _, size in RarityConfig.Sizes do
			check(near(HatchConfig.sizeFactor(size.id), expectedSize[size.id]), `hatch size factor {size.id}`)
		end
		check(HatchConfig.sizeFactor(nil) == 1, "an unknown size must not change the wait")

		-- Mutation modifiers: 1.00 / 1.05 / 1.10 / 1.20 / 1.35, by ORDER.
		local expectedMutation = { 1.00, 1.05, 1.10, 1.20, 1.35 }
		for rank, factor in expectedMutation do
			local mutation = RarityConfig.Mutations[rank]
			check(near(HatchConfig.mutationFactor(mutation.id), factor), `hatch mutation factor {mutation.id}`)
		end
		-- Aliases must not reset the wait to 1.00.
		check(near(HatchConfig.mutationFactor("Neon"), 1.20), "the Neon alias must cost what Flaming costs")
		check(near(HatchConfig.mutationFactor("Glitched"), 1.35), "the Glitched alias must cost what Corrupted costs")

		-- The product, the rounding and the floor.
		check(HatchConfig.hatchSeconds("Common", "Big", "Normal") == 5, "5 x 1.08 = 5.4 rounds to 5s")
		check(HatchConfig.hatchSeconds("Common", "Colossal", "Corrupted") == 14, "5 x 2.00 x 1.35 = 13.5 rounds to 14s")
		check(HatchConfig.hatchSeconds("Legendary", "Titan", "Golden") == 528, "300 x 1.60 x 1.10 = 528s")
		check(HatchConfig.hatchSeconds("Common", "Normal", "Normal") >= 1, "no hatch may be instant")

		-- THE 12-HOUR CLAMP, and that it actually binds on the worst case.
		check(HatchConfig.MAX_SECONDS == 12 * 60 * 60, "the cap must be twelve hours")
		local worst = HatchConfig.hatchSeconds("Divine", "Colossal", "Corrupted")
		check(worst == HatchConfig.MAX_SECONDS, `the worst case must clamp to 12h, got {worst}s`)
		check(43200 * 2.0 * 1.35 > HatchConfig.MAX_SECONDS, "the worst case must exceed the cap before clamping")
		for _, rarity in RarityConfig.Order do
			for _, size in RarityConfig.Sizes do
				for _, mutation in RarityConfig.Mutations do
					local seconds = HatchConfig.hatchSeconds(rarity, size.id, mutation.id)
					check(seconds >= 1 and seconds <= HatchConfig.MAX_SECONDS, `{rarity}/{size.id}/{mutation.id} must sit inside 1..12h`)
				end
			end
		end

		-- FOUR SOCKETS, and no fifth anywhere in the configuration.
		check(MysteryConfig.SOCKETS_PER_ZONE == 4, "the mystery layout must use four sockets")
		check(ZoneConfig.SOCKETS_PER_ZONE == 4, "the zone config must agree that there are four")
		check(#MysteryConfig.SocketOffsets == 4, "there must be exactly four socket offsets")
		local socketNames: { [string]: boolean } = {}
		for index, offset in MysteryConfig.SocketOffsets do
			check(offset.name == string.format("Spawn%02d", index), `socket {index} is named {offset.name}, out of order`)
			check(socketNames[offset.name] == nil, `socket name {offset.name} must be unique`)
			socketNames[offset.name] = true
		end
		check(socketNames["Spawn05"] == nil, "no fifth spawn may be configured")
		for a = 1, 4 do
			for b = a + 1, 4 do
				local first, second = MysteryConfig.SocketOffsets[a], MysteryConfig.SocketOffsets[b]
				local gap = math.sqrt((first.x - second.x) ^ 2 + (first.z - second.z) ^ 2)
				check(gap >= MysteryConfig.SOCKET_MIN_SEPARATION, `sockets {a} and {b} sit {gap} apart, under the minimum`)
			end
		end

		-- A SEALED CONTAINER EARNS NOTHING. The guard returns before the rate
		-- reads the owner, so it is exercised without a live player.
		local sealedItem: any = {
			InstanceId = "sealed", ItemId = "Museum_Ruby", Rarity = "Rare",
			Size = "Colossal", Mutation = "Corrupted", BaseIncome = 45,
			FinalIncome = 45, Scale = 30, SlotIndex = 1,
			GrowthSeconds = 0, MaturationSeconds = 0, Hatched = false,
		}
		check(EconomyService.itemRate(nil :: any, sealedItem) == 0, "an incubating container must pay nothing")
		sealedItem.HatchEndsAt = os.time() - 1
		check(EconomyService.itemRate(nil :: any, sealedItem) == 0, "a READY but unopened container must still pay nothing")

		-- TRAPS: 300 seconds each way, and the cooldown is a separate clock
		-- from the lifetime so neither can be read as the other.
		check(PvPConfig.TRAP_COOLDOWN == 300, "the trap cooldown must be 300s")
		check(PvPConfig.TRAP_LIFETIME == 300, "an unsprung trap must expire after 300s")
	end

	-- ==========================================================
	-- 8. THE v11 MIGRATION: NOBODY RE-HATCHES THEIR COLLECTION
	-- ==========================================================
	section = "hatchMigration"
	do
		local function legacy(id: string, itemId: string, slot: number): any
			local def = LootConfig.ById[itemId]
			return {
				InstanceId = id,
				ItemId = itemId,
				ZoneId = def.zoneIndex,
				Rarity = def.rarity,
				Size = "Normal",
				Mutation = "Normal",
				BaseIncome = def.income,
				FinalIncome = def.income,
				SlotIndex = slot,
				VisualScale = 1,
				GrowthSeconds = 0,
			}
		end
		local profile: any = {
			SchemaVersion = 10,
			DisplayItems = { legacy("old-1", "Museum_AncientVase", 1), legacy("old-2", "Bank_GoldBar", 2) },
			Inventory = { legacy("old-3", "Gym_Trophy", 1) },
		}
		local migrated = DataService.migrate(profile)
		check(migrated.SchemaVersion >= 11, "migration must reach schema 11")
		for _, list in { migrated.DisplayItems, migrated.Inventory } do
			for _, item in list do
				check(item.Hatched == true, `{item.InstanceId}: an existing item must arrive already hatched`)
				check(item.HatchEndsAt == nil, `{item.InstanceId}: an existing item must carry no timer`)
				DataService.reconcileItem(item)
				check(item.Hatched == true, `{item.InstanceId}: reconcile must not re-seal an existing item`)
				check(EconomyService.itemRate(nil :: any, item) > 0, `{item.InstanceId}: an existing item must keep earning`)
			end
		end
		check(type(migrated.TrapReadyAt) == "number", "the profile must gain a trap cooldown stamp")

		-- A CORRUPT hatch stamp must resolve toward READY, never toward a wait
		-- the player can never sit out.
		local broken: any = legacy("broken", "Museum_Ruby", 3)
		broken.Hatched = false
		broken.HatchEndsAt = os.time() + 400 * 24 * 3600
		DataService.reconcileItem(broken)
		check(
			(tonumber(broken.HatchEndsAt) or 0) <= os.time() + HatchConfig.MAX_SECONDS,
			"a far-future hatch stamp must be pulled back inside the cap"
		)
	end

	-- ==========================================================
	-- 9. THE ZONE-BIASED SCALE ROLL
	-- ==========================================================
	section = "scale"
	do
		-- The base weights are the brief's 60/20/10/4/1.5/0.5. They total 96,
		-- so they are RELATIVE and must be normalised: a roll may never come
		-- back empty.
		local expectedWeights = { Normal = 60, Big = 20, Huge = 10, Giant = 4, Titan = 1.5, Colossal = 0.5 }
		local weightTotal = 0
		for _, variant in ScaleConfig.Variants do
			check(near(variant.weight, expectedWeights[variant.id]), `base weight {variant.id} must be {expectedWeights[variant.id]}`)
			check(variant.min < variant.max, `{variant.id} must span a range`)
			weightTotal += variant.weight
		end
		check(near(weightTotal, 96), `the base weights must total 96, got {weightTotal}`)

		for zoneIndex = 1, ZoneConfig.COUNT do
			local odds = ScaleConfig.variantOdds(zoneIndex)
			local sum = 0
			for _, variant in ScaleConfig.Variants do
				local share = odds[variant.id] or 0
				check(share > 0, `zone {zoneIndex}: {variant.id} must be reachable`)
				sum += share
			end
			check(near(sum, 1, 1e-9), `zone {zoneIndex}: the odds must normalise to 1, got {sum}`)
		end

		-- The bias must climb with the zone, not merely differ.
		local bandZones = { 1, 5, 8, 11 }
		for i = 1, #bandZones - 1 do
			local low = ScaleConfig.variantOdds(bandZones[i])
			local high = ScaleConfig.variantOdds(bandZones[i + 1])
			check(high.Normal < low.Normal, `zone {bandZones[i + 1]} must roll Normal less often than zone {bandZones[i]}`)
			check(high.Colossal > low.Colossal, `zone {bandZones[i + 1]} must roll Colossal more often than zone {bandZones[i]}`)
		end

		-- The observed roll lands on those odds, and every Scale it produces
		-- reads back as its OWN variant. That property is what lets one saved
		-- number carry both the income and the size word.
		local rng = Random.new(4242)
		for _, zoneIndex in bandZones do
			local counts: { [string]: number } = {}
			local n = 60000
			for _ = 1, n do
				local label = RarityConfig.sizeLabelFor(ScaleConfig.rollScale(zoneIndex, rng))
				counts[label] = (counts[label] or 0) + 1
			end
			local odds = ScaleConfig.variantOdds(zoneIndex)
			local seen = 0
			for _, variant in ScaleConfig.Variants do
				local share = odds[variant.id]
				local observed = (counts[variant.id] or 0) / n
				seen += counts[variant.id] or 0
				-- FOUR SIGMA ON THE CELL, not a flat percentage. A flat 0.4pp
				-- band is roughly 2.4 sigma on the Big cell and hundreds of
				-- sigma on Colossal, so it failed on ordinary sampling noise
				-- at one end while proving nothing at the other. The floor of
				-- five counts keeps the rarest cells sane, where the normal
				-- approximation is weakest.
				local sigma = math.sqrt(share * (1 - share) / n)
				local tolerance = math.max(4 * sigma, 5 / n)
				check(
					math.abs(observed - share) <= tolerance,
					`zone {zoneIndex}: {variant.id} rolled {observed * 100}%, expected {share * 100}% (tolerance {tolerance * 100}pp)`
				)
			end
			check(seen == n, `zone {zoneIndex}: {n - seen} roll(s) produced no variant at all`)
		end

		-- Every variant's own range must read back as that variant, at both
		-- ends and in the middle.
		for _, variant in ScaleConfig.Variants do
			for _, scale in { variant.min, (variant.min + variant.max) / 2, variant.max } do
				check(RarityConfig.sizeLabelFor(scale) == variant.id, `Scale {scale} must read as {variant.id}`)
			end
		end
	end

	if #report.failed == 0 then
		print(`[EconomyTests] PASSED - {report.passed} checks`)
	else
		warn(`[EconomyTests] FAILED - {#report.failed} problem(s):`)
		for _, message in report.failed do
			warn("  - " .. message)
		end
	end
	return report
end

return EconomyTests
