--!strict
--[[
	DebugCommands.RelicRoll
	Studio-only test commands for the [relic-roll] "MUSEUM RELICS [LIMITED]"
	gacha banner. Loaded by DebugService; invoke through
	ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...).

	  relicRollState                the caller's live banner data (odds,
	                                 prices, restricted flag, pending reveal)
	  relicRoll [count]              rolls `count` (default 1, max 50) WITHOUT
	                                 Robux - the exact grant path a real
	                                 purchase uses - reports every item rolled
	                                 and where it went, then restores the
	                                 profile
	  relicRollFull [count]          the same, but Storage is first padded to
	                                 its cap so every rolled item is forced
	                                 through the Mailbox overflow path
	  relicRollReplay                grants one roll, confirms the replay
	                                 record survives a wrong ack and a
	                                 mismatched purchaseId, then confirms the
	                                 real ack clears it - all restored after
	  relicRollReveal [count]        plays a full N-roll reveal (default 3) on
	                                 the caller's client WITHOUT Robux, through
	                                 the real grant + state push + per-roll acks
	                                 (+ holds); the profile is restored once
	                                 the reveal has been acked / timed out
	  relicRollAckCheck              server-side check of the per-roll ack:
	                                 partial acks keep the record, an index is
	                                 honoured once, out-of-range ignored, 0
	                                 (Skip all) clears
	  relicRollDist [count]          a PURE statistics check (default 10000):
	                                 no player, no profile - simulates
	                                 `count` rolls with the live RNG functions
	                                 and reports observed vs configured odds
	                                 and the blended expected income/s

	EVERY COMMAND THAT TOUCHES A PROFILE RESTORES IT, EVEN ON ERROR (Studio
	with API access saves to the owner's REAL DataStore). The one exception,
	`relicRollFull`'s temporary padding, is undone in the same pass before
	the snapshot is restored, never left for a save.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local RelicRollConfig = require(ReplicatedStorage.Shared.Config.RelicRollConfig)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)

local Services = script.Parent.Parent
local DataService = require(Services.DataService)
local LootService = require(Services.LootService)
local RelicRollService = require(Services.RelicRollService)
local StateService = require(Services.StateService)

-- ==========================================================
-- SNAPSHOT / RESTORE (same pattern as DebugCommands.Monetization)
-- ==========================================================

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

type Snapshot = { [string]: any }
local SNAPSHOT_FIELDS = { "Inventory", "PendingRelicReveal", "StorageTier" }

local function snapshot(profile: DataService.Profile): Snapshot
	local snap: Snapshot = {}
	for _, field in SNAPSHOT_FIELDS do
		snap[field] = copy((profile :: any)[field])
	end
	return snap
end

local function restore(player: Player, profile: DataService.Profile, snap: Snapshot)
	for _, field in SNAPSHOT_FIELDS do
		(profile :: any)[field] = copy(snap[field])
	end
	StateService.pushNow(player)
	if DataService.isPersistent() then
		DataService.save(player)
	end
end

local function withRestore(player: Player, body: (DataService.Profile) -> any): any
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	local snap = snapshot(profile)
	local ok, result = pcall(body, profile)
	restore(player, profile, snap)
	if not ok then
		return { error = tostring(result), restored = true }
	end
	return result
end

local commands: { [string]: (Player, ...any) -> any } = {}

-- ==========================================================
-- STATE
-- ==========================================================

commands.relicRollState = function(player: Player)
	return RelicRollService.summarise(player)
end

-- ==========================================================
-- GRANT PATH (no Robux)
-- ==========================================================

commands.relicRoll = function(player: Player, countArg: any)
	local count = math.clamp(math.floor(tonumber(countArg) or 1), 1, 50)
	return withRestore(player, function(profile)
		local purchaseId = `debug-relicroll-{HttpService:GenerateGUID(false)}`
		local granted, why = RelicRollService.grant(player, count, purchaseId)
		if not granted then
			return { granted = false, why = why }
		end
		local pending = profile.PendingRelicReveal
		local items = if type(pending) == "table" then pending.items else {}
		local storedCount, overflowCount = 0, 0
		for _, item in items :: { any } do
			if item.overflow then
				overflowCount += 1
			else
				storedCount += 1
			end
		end
		return {
			granted = true,
			purchaseId = purchaseId,
			rolled = items,
			storedCount = storedCount,
			overflowCount = overflowCount,
			inventoryCountAfter = #profile.Inventory,
		}
	end)
end

commands.relicRollFull = function(player: Player, countArg: any)
	local count = math.clamp(math.floor(tonumber(countArg) or 3), 1, 50)
	return withRestore(player, function(profile)
		-- Pad Storage to its cap with a cheap, real item so every roll this
		-- test makes is forced through the Mailbox overflow path. Undone by
		-- the caller's restore() the moment this function returns.
		local capacity = StorageConfig.capacityForTier(profile.StorageTier)
		local fillerId = RelicRollConfig.Tiers[1].itemId
		while #profile.Inventory < capacity do
			table.insert(profile.Inventory, {
				InstanceId = HttpService:GenerateGUID(false),
				ItemId = fillerId,
				ZoneId = 1,
				Rarity = "Common",
				Size = "Normal",
				Mutation = "Normal",
				BaseIncome = 1,
				FinalIncome = 1,
				SlotIndex = 0,
				Scale = 1,
				Hatched = true,
			})
		end

		local purchaseId = `debug-relicroll-full-{HttpService:GenerateGUID(false)}`
		local granted, why = RelicRollService.grant(player, count, purchaseId)
		if not granted then
			return { granted = false, why = why }
		end
		local pending = profile.PendingRelicReveal
		local items = if type(pending) == "table" then pending.items else {}
		local overflowCount = 0
		for _, item in items :: { any } do
			if item.overflow then
				overflowCount += 1
			end
		end
		return {
			granted = true,
			capacityWas = capacity,
			rolledCount = #(items :: { any }),
			overflowCount = overflowCount,
			-- Every roll should have overflowed - Storage was already full.
			allOverflowed = overflowCount == #(items :: { any }),
		}
	end)
end

-- ==========================================================
-- REPLAY ON JOIN
-- ==========================================================

commands.relicRollReplay = function(player: Player)
	return withRestore(player, function(profile)
		local purchaseId = `debug-relicroll-replay-{HttpService:GenerateGUID(false)}`
		local granted, why = RelicRollService.grant(player, 1, purchaseId)
		if not granted then
			return { granted = false, why = why }
		end

		local afterGrant = profile.PendingRelicReveal
		local survivedGrant = type(afterGrant) == "table" and afterGrant.purchaseId == purchaseId

		-- A wrong id must NOT clear it - a client acking a stale purchase
		-- (or a tampered one) cannot dismiss the real reveal underneath it.
		RelicRollService.acknowledgeReveal(player, "not-the-real-id")
		local afterWrongAck = profile.PendingRelicReveal
		local survivedWrongAck = type(afterWrongAck) == "table" and afterWrongAck.purchaseId == purchaseId

		-- The state push a rejoining client would see: the replay record
		-- rides `relicRoll.pendingReveal` exactly like a live purchase.
		local seenInState = RelicRollService.summarise(player).pendingReveal

		-- The real ack clears it.
		RelicRollService.acknowledgeReveal(player, purchaseId)
		local clearedAfterRealAck = profile.PendingRelicReveal == nil

		return {
			granted = true,
			survivedGrant = survivedGrant,
			survivedWrongAck = survivedWrongAck,
			replayVisibleInState = type(seenInState) == "table" and seenInState.purchaseId == purchaseId,
			clearedAfterRealAck = clearedAfterRealAck,
		}
	end)
end

-- ==========================================================
-- PER-ROLL ACK (server-side only)
-- ==========================================================

commands.relicRollAckCheck = function(player: Player)
	return withRestore(player, function(profile)
		local purchaseId = `debug-relicroll-ack-{HttpService:GenerateGUID(false)}`
		local granted, why = RelicRollService.grant(player, 3, purchaseId)
		if not granted then
			return { granted = false, why = why }
		end
		local function record(): any
			return profile.PendingRelicReveal
		end
		local function ackedCount(): number
			local pending = record()
			return if type(pending) == "table" and type(pending.acked) == "table" then #pending.acked else -1
		end
		RelicRollService.acknowledgeReveal(player, purchaseId, 2)
		local afterOne = ackedCount()
		RelicRollService.acknowledgeReveal(player, purchaseId, 2) -- twice: honoured once
		local afterRepeat = ackedCount()
		RelicRollService.acknowledgeReveal(player, purchaseId, 99) -- out of range: ignored
		local afterBad = ackedCount()
		local survived = record() ~= nil
		RelicRollService.acknowledgeReveal(player, purchaseId, 0) -- Skip all
		return {
			granted = true,
			afterOneAck = afterOne, -- expect 1
			afterRepeatAck = afterRepeat, -- expect 1
			afterOutOfRange = afterBad, -- expect 1
			recordSurvivedPartialAcks = survived, -- expect true
			clearedBySkipAll = record() == nil, -- expect true
			heldNote = "held only if HoldService.hold exists (else items stay in Storage)",
		}
	end)
end

-- ==========================================================
-- FULL REVEAL ON THE CALLER'S CLIENT (no Robux)
-- ==========================================================

--- Plays a real N-roll reveal: the same grant path, state push, per-roll acks
--- and holds as a purchase. The profile is restored only AFTER the reveal has
--- been acked (the pending record clears) or a timeout, so the ack/hold flow
--- really runs; a restore also runs if the player leaves first.
commands.relicRollReveal = function(player: Player, countArg: any)
	local count = math.clamp(math.floor(tonumber(countArg) or 3), 1, 50)
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	local snap = snapshot(profile)
	local purchaseId = `debug-relicroll-reveal-{HttpService:GenerateGUID(false)}`
	local restored = false
	local function restoreOnce()
		if restored then
			return
		end
		restored = true
		restore(player, profile, snap)
	end

	local okGrant, granted, why = pcall(RelicRollService.grant, player, count, purchaseId)
	if not okGrant or not granted then
		restoreOnce()
		return { granted = false, why = if okGrant then why else granted }
	end

	local leaving = Players.PlayerRemoving:Connect(function(who: Player)
		if who == player then
			restoreOnce()
		end
	end)
	task.spawn(function()
		local limit = os.clock() + count * (RelicRollConfig.ROLL_SECONDS + RelicRollConfig.LANDING_HOLD_SECONDS + 1) + 30
		local function stillPending(): boolean
			local pending = profile.PendingRelicReveal
			return type(pending) == "table" and pending.purchaseId == purchaseId
		end
		while stillPending() and os.clock() < limit and player.Parent do
			task.wait(0.5)
		end
		task.wait(1) -- let the last ack's hold and save settle
		leaving:Disconnect()
		local ok: boolean, err: any = (pcall :: any)(restoreOnce)
		if not ok then
			warn(`[DebugCommands.RelicRoll] relicRollReveal restore failed: {err}`)
		end
	end)
	return {
		started = true,
		purchaseId = purchaseId,
		rolls = count,
		note = "the reveal plays on your client now; the profile is restored when it finishes",
	}
end

-- ==========================================================
-- DISTRIBUTION CHECK (pure statistics - no player, no profile)
-- ==========================================================

commands.relicRollDist = function(_player: Player, countArg: any)
	local count = math.clamp(math.floor(tonumber(countArg) or 10000), 100, 200000)
	local rng = Random.new()

	local tierCounts: { [string]: number } = {}
	for _, tier in RelicRollConfig.Tiers do
		tierCounts[tier.itemId] = 0
	end

	local incomeSum = 0
	local incomeByTier: { [string]: number } = {}
	for _, tier in RelicRollConfig.Tiers do
		incomeByTier[tier.itemId] = 0
	end

	for _ = 1, count do
		local tier = RelicRollConfig.rollTier(rng)
		tierCounts[tier.itemId] += 1
		local def = LootConfig.ById[tier.itemId]
		if def then
			local scale = LootService.rollScale(def.zoneIndex, rng)
			local mutation = LootService.rollMutationId(rng)
			local income = RarityConfig.finalIncome(def.income, scale, mutation)
			incomeSum += income
			incomeByTier[tier.itemId] += income
		end
	end

	local rows = {}
	for _, tier in RelicRollConfig.Tiers do
		local def = LootConfig.ById[tier.itemId]
		local observed = tierCounts[tier.itemId]
		table.insert(rows, {
			itemId = tier.itemId,
			rarity = if def then def.rarity else "?",
			configuredPercent = tier.weight,
			observedPercent = math.round(observed / count * 1000) / 10,
			observedCount = observed,
			averageIncome = if observed > 0 then math.round(incomeByTier[tier.itemId] / observed) else 0,
		})
	end

	return {
		rolls = count,
		rows = rows,
		blendedExpectedIncomePerRoll = math.round(incomeSum / count),
	}
end

return commands
