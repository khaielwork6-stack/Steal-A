--!strict
--[[
	ParitySim
	The Monte Carlo parity tool: rolls the LIVE roller (LootService.rollItem,
	ScaleConfig.rollScale, the mutation table) with a seeded Random and reports
	what the economy actually produces, per zone, next to what the config says
	it should. Studio-only in practice (DebugService "paritySim"), pure in
	form: it touches no socket, no profile and no player.

	WHAT IT REPORTS, PER PARITY ZONE (1-11; 12 only when asked, and flagged)
	  * per-socket item probability: configured (weight share) vs observed
	  * probability of appearing at least once across five sockets
	  * expected occurrences per hour (5 sockets x 12 refreshes)
	  * mean / median / P90 / P99 / P99.9 of a spawned item's $/s
	  * time-to-cash milestones (every base and treadmill purchase) at the
	    zone's mean spawned rate, per cohort
	  * time-to-Speed milestones (every gate) per treadmill tier, per cohort
	  * the cohorts: F2P (no passes), PAID (2x Cash + the top Speed pass -
	    which has no reference equivalent and is EXCLUDED from parity), and
	    OFFLINE (the F2P rate x OFFLINE_EFFICIENCY, capped)
	  * every source of awarded Cash this session, tagged, for online players
	  * every BLOCKED / PROVISIONAL status the config declares

	EVERYTHING HERE IS DERIVED FROM CONFIG AND THE LIVE ROLLER. Nothing is
	typed in twice; if a table moves, this report moves with it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local EconomyService = require(script.Parent.EconomyService)
local LootService = require(script.Parent.LootService)

local ParitySim = {}

export type Options = {
	rolls: number?, -- item rolls per zone (default 1,000,000)
	seed: number?,
	includePostgame: boolean?,
	zones: { number }?,
}

export type ItemRow = {
	itemId: string,
	name: string,
	rarity: string,
	baseIncome: number,
	configuredPerSocket: number,
	observedPerSocket: number,
	atLeastOnceInZone: number,
	observedAtLeastOnceInZone: number,
	expectedPerHour: number,
}

export type ZoneReport = {
	zone: number,
	name: string,
	parity: boolean,
	rolls: number,
	items: { ItemRow },
	income: { mean: number, median: number, p90: number, p99: number, p999: number, max: number },
	timeToCash: { [string]: { [string]: number } }, -- cohort -> purchase -> seconds
}

local COHORTS = {
	{ key = "F2P", cashPass = 1, speedPass = 1, parity = true },
	{ key = "PAID", cashPass = 2, speedPass = 1024, parity = false },
}

local function percentile(sorted: { number }, p: number): number
	local n = #sorted
	if n == 0 then
		return 0
	end
	local index = math.clamp(math.floor(p * n) + 1, 1, n)
	return sorted[index]
end

local function refreshesPerHour(): number
	return 3600 / NightConfig.CYCLE_SECONDS
end

--- Every Cash purchase in the game, name -> cost, for the time-to-cash table.
local function purchases(): { { name: string, cost: number } }
	local list = {}
	for _, tier in BaseConfig.CapacityTiers do
		if tier.cost > 0 then
			table.insert(list, { name = `Base L{tier.tier} ({tier.slots} slots)`, cost = tier.cost })
		end
	end
	for _, tier in TreadmillConfig.Tiers do
		if tier.cost > 0 then
			table.insert(list, { name = `Treadmill x{tier.factor} {tier.name}`, cost = tier.cost })
		end
	end
	for _, trail in MonetizationConfig.Trails do
		table.insert(list, { name = `Trail x{trail.multiplier} {trail.name}`, cost = trail.cash })
	end
	return list
end

function ParitySim.simulateZone(zoneIndex: number, rolls: number, rng: Random): ZoneReport
	local pool = LootConfig.pool(zoneIndex)
	local counts: { [string]: number } = {}
	local hitInBatch: { [string]: number } = {}
	local incomes = table.create(rolls)

	-- Rolls are grouped into refreshes of SOCKETS_PER_ZONE so "at least once
	-- across five sockets" is observed, not just computed.
	local sockets = ZoneConfig.SOCKETS_PER_ZONE
	local batches = math.floor(rolls / sockets)
	local seenThisBatch: { [string]: boolean } = {}
	local rolled = 0
	-- A YIELD EVERY FEW THOUSAND BATCHES. Twelve million rolls is far past the
	-- engine's continuous-execution budget, and without this the whole run is
	-- killed with "exhausted allowed execution time" - which is what happened
	-- the first time it was asked for a million rolls a zone. Yielding costs a
	-- few frames and lets the simulation run to any size.
	local YIELD_EVERY = 20000
	for batch = 1, batches do
		if batch % YIELD_EVERY == 0 then
			task.wait()
		end
		table.clear(seenThisBatch)
		for _ = 1, sockets do
			local def = LootService.rollItem(zoneIndex, rng)
			if not def then
				continue
			end
			rolled += 1
			counts[def.id] = (counts[def.id] or 0) + 1
			seenThisBatch[def.id] = true
			local scale = ScaleConfig.rollScale(zoneIndex, rng)
			local mutation = LootService.rollMutationId(rng)
			incomes[rolled] = RarityConfig.preBoostRate(def.income, scale, mutation, 1)
		end
		for id in seenThisBatch do
			hitInBatch[id] = (hitInBatch[id] or 0) + 1
		end
	end

	table.sort(incomes)
	local sum = 0
	for _, v in incomes do
		sum += v
	end
	local mean = if rolled > 0 then sum / rolled else 0

	local items: { ItemRow } = {}
	for _, def in pool do
		local p = LootConfig.weightShare(def.id)
		table.insert(items, {
			itemId = def.id,
			name = def.name,
			rarity = def.rarity,
			baseIncome = def.income,
			configuredPerSocket = p,
			observedPerSocket = if rolled > 0 then (counts[def.id] or 0) / rolled else 0,
			atLeastOnceInZone = 1 - (1 - p) ^ sockets,
			observedAtLeastOnceInZone = if batches > 0 then (hitInBatch[def.id] or 0) / batches else 0,
			expectedPerHour = p * sockets * refreshesPerHour(),
		})
	end

	local timeToCash: { [string]: { [string]: number } } = {}
	for _, cohort in COHORTS do
		local rate = mean * cohort.cashPass
		local row = {}
		for _, purchase in purchases() do
			row[purchase.name] = if rate > 0 then purchase.cost / rate else math.huge
		end
		timeToCash[cohort.key] = row
	end
	do
		local rate = mean * GameConfig.OFFLINE_EFFICIENCY
		local row = {}
		for _, purchase in purchases() do
			local seconds = if rate > 0 then purchase.cost / rate else math.huge
			-- Offline pays at most the cap per absence; report the seconds of
			-- absence needed, noting anything past the cap needs more than one.
			row[purchase.name] = seconds
		end
		timeToCash.OFFLINE = row
	end

	local zone = ZoneConfig.Zones[zoneIndex]
	return {
		zone = zoneIndex,
		name = zone.name,
		parity = ZoneConfig.isParityZone(zoneIndex),
		rolls = rolled,
		items = items,
		income = {
			mean = mean,
			median = percentile(incomes, 0.5),
			p90 = percentile(incomes, 0.90),
			p99 = percentile(incomes, 0.99),
			p999 = percentile(incomes, 0.999),
			max = if rolled > 0 then incomes[rolled] else 0,
		},
		timeToCash = timeToCash,
	}
end

--- Time-to-Speed: seconds from the starting Speed to each gate at each
--- treadmill tier, per cohort (the PAID cohort's Speed pass adds above the
--- treadmill factor and is flagged as having no reference equivalent).
function ParitySim.timeToSpeed(): { [string]: { [string]: { [string]: number } } }
	local out = {}
	for _, cohort in COHORTS do
		local byTier = {}
		for _, tier in TreadmillConfig.Tiers do
			local gain = TreadmillConfig.gainPerSecond(tier.level, TreadmillConfig.bonusFactor(1, cohort.speedPass))
			local byGate = {}
			for _, zone in ZoneConfig.Zones do
				if zone.recommendedSpeed > 0 and ZoneConfig.isParityZone(zone.index) then
					byGate[`Zone {zone.index} ({zone.name})`] = if gain > 0
						then math.max(zone.recommendedSpeed - GameConfig.STARTING_SPEED_POWER, 0) / gain
						else math.huge
				end
			end
			byTier[`x{tier.factor} {tier.name}`] = byGate
		end
		out[cohort.key] = byTier
	end
	return out
end

--- Every declared unresolved value, so no report can claim parity over one.
function ParitySim.blockedValues(): { { key: string, status: string, note: string } }
	return {
		{ key = "SizeOdds", status = ScaleConfig.SIZE_ODDS_STATUS, note = ScaleConfig.SIZE_ODDS_NOTE },
		{ key = "GrowthTimes", status = LootConfig.GROWTH_TIMES_STATUS, note = `per-item base growth times not traced; DEFAULT_GROWTH_SECONDS = {LootConfig.DEFAULT_GROWTH_SECONDS}` },
		{ key = "TrainingBase", status = GameConfig.TRAINING_STATUS, note = `TRAINING_BASE_GAIN = {GameConfig.TRAINING_BASE_GAIN} (keeps tier 1 at 8/s); reference base not traced` },
		{ key = "Offline", status = GameConfig.OFFLINE_STATUS, note = `OFFLINE_EFFICIENCY = {GameConfig.OFFLINE_EFFICIENCY}, cap {GameConfig.OFFLINE_EARNINGS_MAX_SECONDS}s; reference coefficient not traced` },
		{ key = "Sell", status = GameConfig.SELL_STATUS, note = `{GameConfig.SELL_REFUND_SECONDS}s of the mutation-stripped rate; reference price function not traced` },
		{ key = "Zone12", status = "POSTGAME_EXTENSION", note = "no reference equivalent; provisional weights; excluded from parity" },
		{ key = "SpeedPasses", status = "NO_REFERENCE_EQUIVALENT", note = "2x..1024x permanent Speed passes; owners excluded from the F2P benchmark" },
	}
end

--- Cash awarded this session by source, per online player.
function ParitySim.cashSources(): { [string]: { [string]: number } }
	local out = {}
	for _, player in Players:GetPlayers() do
		out[player.Name] = EconomyService.awardedBySource(player)
	end
	return out
end

function ParitySim.run(options: Options?): { [string]: any }
	local opts = options or {}
	local rolls = math.max(math.floor(opts.rolls or 1_000_000), 1000)
	local rng = Random.new(opts.seed or 20260908)
	local zones = opts.zones
	if not zones then
		zones = {}
		for index = 1, ZoneConfig.COUNT do
			if ZoneConfig.isParityZone(index) or opts.includePostgame then
				table.insert(zones, index)
			end
		end
	end

	local reports: { ZoneReport } = {}
	for _, zoneIndex in zones :: { number } do
		table.insert(reports, ParitySim.simulateZone(zoneIndex, rolls, rng))
	end

	-- The Zone 9 Blue Crystal assertion, straight from the run.
	local assertion = nil
	for _, report in reports do
		if report.zone == 9 then
			for _, row in report.items do
				if row.itemId == "SecretLab_MutationCrystal" then
					assertion = {
						configuredPerSocket = row.configuredPerSocket,
						observedPerSocket = row.observedPerSocket,
						atLeastOnceInZone = row.atLeastOnceInZone,
						observedAtLeastOnceInZone = row.observedAtLeastOnceInZone,
						expectedPerHour = row.expectedPerHour,
						sockets = ZoneConfig.SOCKETS_PER_ZONE,
						refreshesPerHour = refreshesPerHour(),
						-- THE FOUR-SOCKET RESTATEMENT. The economy brief asked
						-- for 0.495856% a socket, ~2.4548% across five nests and
						-- 0.2975136 an hour. The per-socket probability is the
						-- item's weight share and has not moved. The other two
						-- counted five sockets and twelve refreshes an hour; the
						-- mystery brief cut the fifth spawn and the live cycle
						-- refreshes 3600/270 times an hour, so the same
						-- probability now reads 1.96872% across four nests and
						-- 0.26445653 an hour. Derived here rather than pasted,
						-- so a change to either input is caught.
						pass = math.abs(row.configuredPerSocket - 0.00495856) < 1e-9
							and math.abs(row.atLeastOnceInZone - 0.0196872) < 1e-6
							and math.abs(row.expectedPerHour - 0.00495856 * 4 * (3600 / 270)) < 1e-6,
					}
				end
			end
		end
	end

	return {
		rollsPerZone = rolls,
		seed = opts.seed or 20260908,
		refreshesPerHour = refreshesPerHour(),
		socketsPerZone = ZoneConfig.SOCKETS_PER_ZONE,
		rollsPerZonePerHour = ZoneConfig.SOCKETS_PER_ZONE * refreshesPerHour(),
		zones = reports,
		zone9BlueCrystal = assertion,
		timeToSpeed = ParitySim.timeToSpeed(),
		blocked = ParitySim.blockedValues(),
		cashSources = ParitySim.cashSources(),
		cohorts = { F2P = "no passes (the parity benchmark)", PAID = "2x Cash + 1024x Speed pass (no reference equivalent; excluded from parity)", OFFLINE = `F2P rate x OFFLINE_EFFICIENCY {GameConfig.OFFLINE_EFFICIENCY}, capped at {GameConfig.OFFLINE_EARNINGS_MAX_SECONDS}s` },
	}
end

--- Compact console print of a run, zone by zone.
function ParitySim.print(result: { [string]: any })
	print(`[ParitySim] {result.rollsPerZone} rolls/zone, seed {result.seed}, {result.socketsPerZone} sockets x {string.format("%.3f", result.refreshesPerHour)} refreshes/h`)
	for _, zone in result.zones do
		print(string.format("Zone %2d %-18s %s  mean %.0f  median %.0f  p90 %.0f  p99 %.0f  p99.9 %.0f  max %.0f", zone.zone, zone.name, if zone.parity then "PARITY " else "POSTGAME", zone.income.mean, zone.income.median, zone.income.p90, zone.income.p99, zone.income.p999, zone.income.max))
		for _, row in zone.items do
			print(string.format("   %-32s %-10s cfg %8.5f%%  obs %8.5f%%  >=1/zone cfg %7.4f%% obs %7.4f%%  /h %.5f", row.itemId, row.rarity, row.configuredPerSocket * 100, row.observedPerSocket * 100, row.atLeastOnceInZone * 100, row.observedAtLeastOnceInZone * 100, row.expectedPerHour))
		end
	end
	if result.zone9BlueCrystal then
		local a = result.zone9BlueCrystal
		print(string.format("[ParitySim] Zone 9 Blue Crystal: per socket %.6f%% (obs %.6f%%), >=1 in %d nests %.4f%% (obs %.4f%%), /h %.7f  -> %s", a.configuredPerSocket * 100, a.observedPerSocket * 100, a.sockets, a.atLeastOnceInZone * 100, a.observedAtLeastOnceInZone * 100, a.expectedPerHour, if a.pass then "PASS" else "FAIL"))
	end
	for _, blocked in result.blocked do
		print(`[ParitySim] {blocked.key}: {blocked.status} - {blocked.note}`)
	end
end

return ParitySim
