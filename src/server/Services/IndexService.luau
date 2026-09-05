--!strict
--[[
	IndexService
	The Loot Index: discovery tracking, set completion and reward claiming
	(GDD section 13, phase 9).

	WHAT THIS SERVICE DOES NOT OWN
	Discovery itself. `Profile.Index[itemId]` is written by PlacementService the
	first time an item reaches a display slot, because carrying it home is the
	achievement - not touching it in the world. This service only reads that set,
	decides what it adds up to, and pays out.

	REPLICATION
	The 96-entry discovery map is pushed on its own remote rather than riding
	StatePush. StatePush fires up to four times a second while income ticks, and
	re-sending a 96-key table at that rate for seven players is pure waste when
	the set changes a few dozen times per session. StatePush instead carries a
	twelve-entry SUMMARY (counts and flags), which is what the HUD and the panel
	header need; the full map goes out only when it actually changes.

	The client also asks for a resync when it starts and when the panel opens.
	That is deliberate: a push at join races StarterPlayerScripts connecting, and
	a request-response is immune to that race in a way a timed re-push is not.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local IndexConfig = require(ReplicatedStorage.Shared.Config.IndexConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local StateService = require(script.Parent.StateService)

local IndexService = {}

local claimLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.IndexClaimRequest)

export type ZoneSummary = {
	index: number,
	discovered: number,
	total: number,
	complete: boolean,
	claimed: boolean,
	claimable: boolean,
}

export type Summary = {
	discovered: number,
	total: number,
	zones: { ZoneSummary },
	claimable: number,
	allComplete: boolean,
	allClaimed: boolean,
	incomeMultiplier: number,
}

-- ==========================================================
-- READING
-- ==========================================================

--- How many of a zone's eight items this profile has discovered.
local function zoneProgress(profile: any, zoneIndex: number): number
	local pool = LootConfig.Items[zoneIndex]
	if not pool then
		return 0
	end
	local found = 0
	for _, item in pool do
		if profile.Index[item.id] then
			found += 1
		end
	end
	return found
end

--- The compact per-zone rollup that rides StatePush. Cheap enough to rebuild on
--- every push, and contains no item ids.
function IndexService.summarise(player: Player): Summary?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end

	local zones: { ZoneSummary } = {}
	local discovered, claimable, completeCount, claimedCount = 0, 0, 0, 0

	for index = 1, ZoneConfig.COUNT do
		local found = zoneProgress(profile, index)
		local total = #(LootConfig.Items[index] or {})
		local complete = total > 0 and found >= total
		local claimed = profile.ClaimedIndexRewards[IndexConfig.zoneKey(index)] == true

		discovered += found
		if complete then
			completeCount += 1
		end
		if claimed then
			claimedCount += 1
		end
		if complete and not claimed then
			claimable += 1
		end

		table.insert(zones, {
			index = index,
			discovered = found,
			total = total,
			complete = complete,
			claimed = claimed,
			claimable = complete and not claimed,
		})
	end

	local allComplete = completeCount >= ZoneConfig.COUNT
	local allClaimed = profile.ClaimedIndexRewards[IndexConfig.ALL_ZONES_KEY] == true

	-- The completionist reward needs every zone finished AND every zone claimed:
	-- letting it be taken first would hand out the grand prize while twelve
	-- smaller ones were still outstanding.
	if allComplete and claimedCount >= ZoneConfig.COUNT and not allClaimed then
		claimable += 1
	end

	return {
		discovered = discovered,
		total = IndexConfig.TOTAL_ITEMS,
		zones = zones,
		claimable = claimable,
		allComplete = allComplete,
		allClaimed = allClaimed,
		incomeMultiplier = IndexConfig.incomeMultiplier(profile.ClaimedIndexRewards),
	}
end

-- ==========================================================
-- REPLICATION
-- ==========================================================

--- Sends the full discovery map. Only on change, on join, and on request.
function IndexService.push(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return
	end
	Remotes.get("IndexPush"):FireClient(player, {
		discovered = profile.Index,
		claimed = profile.ClaimedIndexRewards,
	})
end

--- Called by PlacementService when an item is discovered for the first time.
function IndexService.onDiscovered(player: Player, itemId: string)
	IndexService.push(player)
	StateService.markDirty(player)

	local zoneIndex = LootConfig.ZoneOf[itemId]
	if not zoneIndex then
		return
	end

	local profile = DataService.get(player)
	local pool = LootConfig.Items[zoneIndex]
	if not profile or not pool then
		return
	end

	-- Announce the set completing. The claim is still a deliberate button press;
	-- this is only the nudge that tells the player there is one waiting.
	if
		zoneProgress(profile, zoneIndex) >= #pool
		and not profile.ClaimedIndexRewards[IndexConfig.zoneKey(zoneIndex)]
	then
		local zone = ZoneConfig.Zones[zoneIndex]
		StateService.notify(
			player,
			"success",
			`{string.upper(zone.name)} SET COMPLETE - reward waiting in your Index`,
			"levelup"
		)
	end
end

-- ==========================================================
-- CLAIMING
-- ==========================================================

local function payOut(player: Player, reward: IndexConfig.Reward, label: string)
	local profile = DataService.get(player)
	if not profile then
		return
	end

	EconomyService.award(player, reward.cash)
	profile.SpeedPower += reward.speed

	-- The permanent multiplier is read straight off ClaimedIndexRewards, so this
	-- recalculate is what actually applies it. Order matters: the claim is
	-- already recorded by the time this runs.
	EconomyService.recalculate(player)
	StateService.pushNow(player)
	IndexService.push(player)

	local percent = math.floor(reward.incomeBonus * 100 + 0.5)
	StateService.notify(
		player,
		"success",
		`{label}  +{NumberFormat.cash(reward.cash)}  +{NumberFormat.short(reward.speed)} Speed  +{percent}% income`,
		"levelup"
	)
end

--- Claims one zone's set reward. Returns false plus a player-facing reason.
function IndexService.claimZone(player: Player, zoneIndex: number): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your save is still loading."
	end

	local zone = ZoneConfig.Zones[zoneIndex]
	local pool = LootConfig.Items[zoneIndex]
	if not zone or not pool then
		return false, "No such zone."
	end

	local key = IndexConfig.zoneKey(zoneIndex)
	if profile.ClaimedIndexRewards[key] then
		return false, "Already claimed."
	end

	local found = zoneProgress(profile, zoneIndex)
	if found < #pool then
		return false, `{zone.name}: {found}/{#pool} discovered.`
	end

	profile.ClaimedIndexRewards[key] = true
	payOut(player, IndexConfig.zoneReward(zoneIndex), `{string.upper(zone.name)} SET CLAIMED`)
	return true
end

--- Claims the all-96 reward. Requires every zone set to be claimed first.
function IndexService.claimAll(player: Player): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your save is still loading."
	end

	if profile.ClaimedIndexRewards[IndexConfig.ALL_ZONES_KEY] then
		return false, "Already claimed."
	end

	for index = 1, ZoneConfig.COUNT do
		local pool = LootConfig.Items[index] or {}
		if zoneProgress(profile, index) < #pool then
			return false, "The Index is not complete yet."
		end
		if not profile.ClaimedIndexRewards[IndexConfig.zoneKey(index)] then
			return false, "Claim every zone set first."
		end
	end

	profile.ClaimedIndexRewards[IndexConfig.ALL_ZONES_KEY] = true
	payOut(player, IndexConfig.completionistReward(), "INDEX COMPLETE")
	return true
end

-- ==========================================================
-- START
-- ==========================================================

function IndexService.start()
	-- One remote, tagged by action, matching InventoryRequest. "sync" exists so a
	-- client that missed the join push can ask again instead of guessing.
	Remotes.get("IndexClaimRequest").OnServerEvent:Connect(function(player, action, argument)
		if type(action) ~= "string" then
			return
		end
		if not claimLimiter:consume(player) then
			return
		end

		if action == "sync" then
			IndexService.push(player)
			StateService.markDirty(player)
			return
		end

		local ok, reason
		if action == "claim" and type(argument) == "number" then
			ok, reason = IndexService.claimZone(player, math.floor(argument))
		elseif action == "claimAll" then
			ok, reason = IndexService.claimAll(player)
		else
			return
		end

		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
	end)

	local function pushWhenLoaded(player: Player)
		task.spawn(function()
			if DataService.waitForProfile(player) then
				IndexService.push(player)
			end
		end)
	end

	-- Anyone already in the server matters in Studio solo, where the player can
	-- exist before this runs and would otherwise never get a push.
	for _, player in Players:GetPlayers() do
		pushWhenLoaded(player)
	end
	Players.PlayerAdded:Connect(pushWhenLoaded)
end

return IndexService
