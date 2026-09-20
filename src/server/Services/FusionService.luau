--!strict
--[[
	FusionService
	Three stored copies of one item become one better copy (FusionConfig).

	ONE ATOMIC STEP. `fuse` validates everything first and then, with no yield
	anywhere between the checks and the writes, spends the Cash, removes the
	three inputs from Storage and inserts the result. A failed check changes
	nothing; there is no half-done fusion to repair.

	WHAT AN INPUT MUST BE
	  * three DISTINCT InstanceIds, all in THIS player's profile.Inventory
	    (Storage) - never on display, so never mid-robbery and never a sealed
	    container being revealed;
	  * all the same ItemId, the one the request names;
	  * revealed (Hatched ~= false);
	  * not locked by another system (`isLocked`, a hook for trading) and not
	    reserved by a base steal.

	THE RESULT is a fresh stored item. Its size and mutation are rolled HERE,
	on the server (FusionConfig); its income is never computed here - the
	item goes through DataService.reconcileItem, which rebuilds Size,
	FinalIncome and the rest from RarityConfig.finalIncome / ScaleConfig,
	exactly like every loaded item. Storage count drops by two, so capacity
	can never block a fusion.

	POLICY: Cash only. The mutation roll is random, so this is never sold for
	Robux and needs no PolicyService gate.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FusionConfig = require(ReplicatedStorage.Shared.Config.FusionConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local HatchService = require(script.Parent.HatchService)
local HeistService = require(script.Parent.HeistService)
local StateService = require(script.Parent.StateService)

local FusionService = {}

local limiter = RateLimiter.new(FusionConfig.REQUESTS_PER_SECOND)

--- A hook for other systems that hold a stored item (a future trade window):
--- return true to keep `instanceId` out of fusion. Injected, never required.
function FusionService.isLocked(_player: Player, _instanceId: string): boolean
	return false
end

--- Studio tests replace this to force a roll. `(kind)` -> [0, 1).
--- kind is "scale" or "mutation".
function FusionService.random(_kind: string): number
	return math.random()
end

export type Preview = {
	itemId: string,
	cost: number,
	targetClass: number,
	targetSize: string,
	floorMutation: string,
	outcomes: { { id: string, chance: number } },
}

local function findStored(profile: DataService.Profile, instanceId: string): (DataService.DisplayItem?, number?)
	for index, item in profile.Inventory do
		if item.InstanceId == instanceId then
			return item, index
		end
	end
	return nil, nil
end

--- The deterministic part of a fusion of `inputs`: price, size class and
--- the mutation floor. Shared by `fuse` and by the client-facing preview so
--- the price the panel shows is the price charged.
function FusionService.previewFor(itemId: string, inputs: { DataService.DisplayItem }): Preview?
	local def = LootConfig.ById[itemId]
	if not def or #inputs == 0 then
		return nil
	end
	local bestClass = 1
	local floor = "Normal"
	for _, item in inputs do
		bestClass = math.max(bestClass, FusionConfig.classOf(ScaleConfig.clampScale(item.Scale)))
		local mutation = RarityConfig.normaliseMutation(item.Mutation)
		if RarityConfig.mutationRank(mutation) > RarityConfig.mutationRank(floor) then
			floor = mutation
		end
	end
	local target = FusionConfig.targetClass(bestClass)
	local variant = ScaleConfig.Variants[target]
	return {
		itemId = itemId,
		cost = FusionConfig.costFor(def.income, target),
		targetClass = target,
		targetSize = if variant then variant.id else "Normal",
		floorMutation = floor,
		outcomes = FusionConfig.mutationOutcomes(floor),
	}
end

--- THE FUSION. Returns the new item on success, or nil plus a player-facing
--- reason. Never yields before the writes.
function FusionService.fuse(player: Player, itemId: string, instanceIds: { string }): (DataService.DisplayItem?, string?)
	local profile = DataService.get(player)
	if not profile then
		return nil, "Your data is still loading."
	end
	local def = LootConfig.ById[itemId]
	if not def then
		return nil, "That item can't be fused."
	end
	if #instanceIds ~= FusionConfig.INPUTS then
		return nil, `Pick {FusionConfig.INPUTS} copies to fuse.`
	end

	-- Every check first; nothing is written until all have passed.
	local inputs: { DataService.DisplayItem } = {}
	local seen: { [string]: boolean } = {}
	for _, instanceId in instanceIds do
		if seen[instanceId] then
			return nil, "Pick three different copies."
		end
		seen[instanceId] = true
		local item = findStored(profile, instanceId)
		if not item then
			-- Not in Storage: on display, sold, fused already, or not theirs.
			return nil, "Fusion only uses items in your Storage."
		end
		if item.ItemId ~= itemId then
			return nil, "All three copies must be the same item."
		end
		if item.Hatched == false then
			return nil, "Reveal it first!"
		end
		-- [hold-items] A held item is deliberately off-limits here - place it
		-- back on a pad first. Safest option: fusion DESTROYS its inputs, and
		-- a held item is the one Storage entry the player is actively looking
		-- at in their hands; silently consuming it out of their hand would be
		-- the single most surprising thing this feature could do.
		if item.Held then
			return nil, "Place it first!"
		end
		if item.RobbedBy or HeistService.isReserved(instanceId) or HatchService.isRevealing(instanceId) then
			return nil, "One of those copies is busy right now."
		end
		if FusionService.isLocked(player, instanceId) then
			return nil, "One of those copies is locked (in a trade?)."
		end
		table.insert(inputs, item)
	end

	local preview = FusionService.previewFor(itemId, inputs)
	if not preview then
		return nil, "That item can't be fused."
	end
	-- Spend first: `spend` is the atomic Cash check. From here to the end
	-- nothing yields, so the profile cannot change under the writes.
	if not EconomyService.spend(player, preview.cost) then
		return nil, `You need {NumberFormat.cash(preview.cost)} to fuse.`
	end

	-- THE ROLL, server-side.
	local bestScale = 0
	local protectedUntil: number? = nil
	for _, item in inputs do
		bestScale = math.max(bestScale, ScaleConfig.clampScale(item.Scale))
		local until_ = tonumber(item.ProtectedUntil)
		if until_ and (not protectedUntil or until_ > protectedUntil) then
			protectedUntil = until_
		end
	end
	local scale = FusionConfig.scaleFor(preview.targetClass, FusionService.random("scale"), bestScale)
	local mutation = FusionConfig.rollMutation(preview.floorMutation, FusionService.random("mutation"))
	local maturation = ScaleConfig.maturationSeconds(def.growthSeconds, scale)

	-- Remove the three inputs (highest index first so the others stay put).
	local indices: { number } = {}
	for _, item in inputs do
		local _, index = findStored(profile, item.InstanceId)
		if index then
			table.insert(indices, index)
		end
	end
	table.sort(indices, function(a, b)
		return a > b
	end)
	for _, index in indices do
		table.remove(profile.Inventory, index)
	end

	local result: DataService.DisplayItem = {
		InstanceId = HttpService:GenerateGUID(false),
		ItemId = itemId,
		ZoneId = def.zoneIndex,
		Rarity = def.rarity,
		Size = ScaleConfig.labelFor(scale),
		Mutation = mutation,
		BaseIncome = def.income,
		FinalIncome = 0, -- rebuilt by reconcileItem below
		SlotIndex = 0,
		Scale = scale,
		VisualScale = scale,
		SizeVisualVersion = RarityConfig.SIZE_VISUAL_VERSION,
		EconomyScaleVersion = ScaleConfig.ECONOMY_SCALE_VERSION,
		-- Grown already: the three copies it came from were the player's to
		-- mature, and a fused trophy that earned nothing for minutes would
		-- read as a downgrade.
		MaturationSeconds = maturation,
		GrowthSeconds = maturation,
		Hatched = true,
		-- A steal-protection stamp travels with the item, as through a store.
		ProtectedUntil = protectedUntil,
	}
	DataService.reconcileItem(result)
	table.insert(profile.Inventory, result)

	-- Stored items earn nothing, so income is unchanged; recalculated anyway
	-- in case a future rule reads Storage.
	EconomyService.recalculate(player)
	StateService.pushNow(player)
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return result, nil
end

local function summary(item: DataService.DisplayItem): { [string]: any }
	return {
		instanceId = item.InstanceId,
		itemId = item.ItemId,
		rarity = item.Rarity,
		size = item.Size,
		mutation = RarityConfig.normaliseMutation(item.Mutation),
		income = item.FinalIncome,
	}
end

function FusionService.start()
	Remotes.get("FusionRequest").OnServerEvent:Connect(function(player, action, itemId, ids)
		if not limiter:consume(player) then
			return
		end
		if action ~= "fuse" or type(itemId) ~= "string" or #itemId > 64 or type(ids) ~= "table" then
			return
		end
		-- Exactly INPUTS short strings, in array order; anything else is dropped.
		local instanceIds: { string } = {}
		for index = 1, FusionConfig.INPUTS do
			local id = (ids :: any)[index]
			if type(id) ~= "string" or #id == 0 or #id > 64 then
				return
			end
			table.insert(instanceIds, id)
		end
		if (ids :: any)[FusionConfig.INPUTS + 1] ~= nil then
			return
		end

		-- Snapshot what is about to be consumed, for the animation.
		local profile = DataService.get(player)
		local consumed: { { [string]: any } } = {}
		if profile then
			for _, id in instanceIds do
				local item = findStored(profile, id)
				if item then
					table.insert(consumed, summary(item))
				end
			end
		end

		local result, reason = FusionService.fuse(player, itemId, instanceIds)
		if not result then
			if reason then
				StateService.notify(player, "error", reason)
			end
			return
		end
		require(script.Parent.ProgressEvents).fire(player, "fused", 1, { rarity = result.Rarity }) -- [analytics-discord]
		Remotes.get("FusionResult"):FireClient(player, {
			consumed = consumed,
			result = summary(result),
		})
		local def = LootConfig.ById[result.ItemId]
		local tags = {}
		if result.Size ~= "Normal" then
			table.insert(tags, result.Size)
		end
		local mutation = RarityConfig.normaliseMutation(result.Mutation)
		if mutation ~= "Normal" then
			table.insert(tags, mutation)
		end
		StateService.notify(
			player,
			"success",
			`FUSED  {table.concat(tags, " ")} {if def then def.name else result.ItemId}  {NumberFormat.income(result.FinalIncome)}`
		)
		StateService.sound(player, "PlaceItem")
	end)

	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
	end)
end

return FusionService
