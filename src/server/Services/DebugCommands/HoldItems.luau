--!strict
--[[
	DebugCommands.HoldItems  [hold-items]
	Studio-only test commands for "hold it in your hands" (pick a trophy off
	your own pad, carry it small, place it back). Invoke through
	ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...).

	EVERY COMMAND THAT TOUCHES A PROFILE PUTS IT BACK, EVEN ON ERROR (Studio
	with API access writes to the owner's REAL DataStore): DisplayItems and
	Inventory are deep-copied first, the body runs in pcall, the copy is
	restored, the base is rebuilt (which also clears any stray held-item
	visual, through HoldService.refreshHeldVisual) and income is recalculated.

	  holdPickupTest [itemId]
	      places a Giant Shiny trophy on a free pad, snapshots its economy
	      fields, picks it up, and checks: it left DisplayItems, it is in
	      Inventory as Held + HeldActive, income dropped by its rate, and
	      every economy/visual field (Scale, VisualScale, Mutation,
	      BaseIncome, FinalIncome, GrowthSeconds, MaturationSeconds,
	      InstanceId) is byte-for-byte the same as before pickup.
	  holdPlaceTest [itemId]
	      does the above, then places it on a SECOND free pad and checks it
	      left the held set, landed with the right SlotIndex, and income
	      came back to exactly what it was before pickup.
	  holdFullTest
	      fills every hand slot (HoldConfig.MAX_HELD_ITEMS) from separate
	      pads, then tries one more: must be refused with the exact "Hands
	      full" message and must NOT have moved the item.
	  holdRaceTest [itemId]
	      fires pickup() twice back-to-back with no yield between them (the
	      shape a doubled remote/prompt trigger would take) and checks the
	      second call is refused cleanly rather than moving the item twice;
	      same for a doubled place().
	  holdPersistTest
	      round-trips a Held/HeldActive item and a deliberately-corrupted one
	      (Held on a DISPLAYED item; two items both HeldActive) through
	      DataService.reconcile - the same pass every load and every leave
	      /rejoin runs - and checks the held one survives untouched while the
	      corrupted states are cleaned up.
	  holdTitanScaleTest [itemId]
	      picks up a Colossal-scale copy of the item and measures the built
	      hand model: its longest side must be at
	      HoldConfig.HELD_TARGET_LONGEST_SIDE regardless of the trophy's real
	      (huge) placed size.
	  holdSuite [itemId]
	      runs all of the above in order and returns one pass/fail summary.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HoldConfig = require(ReplicatedStorage.Shared.Config.HoldConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)

local BaseService = require(script.Parent.Parent.BaseService)
local DataService = require(script.Parent.Parent.DataService)
local EconomyService = require(script.Parent.Parent.EconomyService)
local HoldService = require(script.Parent.Parent.HoldService)
local StateService = require(script.Parent.Parent.StateService)

local FIELDS = { "DisplayItems", "Inventory" }

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

--- Runs `body` against the caller's profile and ALWAYS restores DisplayItems
--- / Inventory, whether or not `body` throws. Same shape as
--- DebugCommands.Bases.withRestore.
local function withRestore(player: Player, body: (DataService.Profile) -> any): any
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	local snap: { [string]: any } = {}
	for _, field in FIELDS do
		snap[field] = copy((profile :: any)[field])
	end
	local ok, result = pcall(body, profile)
	for _, field in FIELDS do
		(profile :: any)[field] = copy(snap[field])
	end
	BaseService.rebuildDisplays(player) -- redraws every pad AND clears/rebuilds the held-item visual (BaseService.onRebuilt -> HoldService.refreshHeldVisual)
	EconomyService.recalculate(player)
	StateService.pushNow(player, true)
	if not ok then
		return { error = tostring(result), restored = true }
	end
	return result
end

local function defaultItemId(): string
	local pool = LootConfig.pool(1)
	return if pool[1] then pool[1].id else "unknown"
end

--- A revealed DISPLAYED item at `slotIndex`, of the given ScaleConfig variant
--- index and mutation, with a real (RarityConfig-derived) income so the
--- before/after income checks mean something.
local function placedItem(itemId: string, slotIndex: number, variantIndex: number, mutation: string): DataService.DisplayItem
	local def = LootConfig.ById[itemId]
	local variant = ScaleConfig.Variants[variantIndex] or ScaleConfig.Variants[1]
	local scale = variant.min
	local baseIncome = if def then def.income else 1
	return {
		InstanceId = HttpService:GenerateGUID(false),
		ItemId = itemId,
		ZoneId = if def then def.zoneIndex else 1,
		Rarity = if def then def.rarity else "Common",
		Size = variant.id,
		Mutation = mutation,
		BaseIncome = baseIncome,
		FinalIncome = RarityConfig.finalIncome(baseIncome, scale, mutation),
		SlotIndex = slotIndex,
		Scale = scale,
		VisualScale = scale,
		SizeVisualVersion = RarityConfig.SIZE_VISUAL_VERSION,
		EconomyScaleVersion = ScaleConfig.ECONOMY_SCALE_VERSION,
		MaturationSeconds = 0, -- earns immediately, so the income delta is visible right away
		GrowthSeconds = 0,
		Hatched = true,
	}
end

--- The handful of fields that MUST survive a pickup and a place-back
--- unchanged. `HttpService:JSONEncode` makes the comparison one line and
--- catches a dropped/renamed field the same as a changed value.
local PRESERVED_FIELDS = {
	"InstanceId", "ItemId", "Rarity", "Size", "Mutation", "BaseIncome", "FinalIncome",
	"Scale", "VisualScale", "GrowthSeconds", "MaturationSeconds", "Hatched",
}
local function fingerprint(item: DataService.DisplayItem): string
	local snap: { [string]: any } = {}
	for _, field in PRESERVED_FIELDS do
		snap[field] = (item :: any)[field]
	end
	return HttpService:JSONEncode(snap)
end

local function findHeld(profile: DataService.Profile, instanceId: string): DataService.DisplayItem?
	for _, item in profile.Inventory do
		if item.InstanceId == instanceId and item.Held then
			return item
		end
	end
	return nil
end

local function findDisplayed(profile: DataService.Profile, instanceId: string): DataService.DisplayItem?
	for _, item in profile.DisplayItems do
		if item.InstanceId == instanceId then
			return item
		end
	end
	return nil
end

local Commands = {}

-- ==========================================================
-- PICK UP
-- ==========================================================

Commands.holdPickupTest = function(player: Player, itemIdArg: any): any
	local itemId = if type(itemIdArg) == "string" and LootConfig.ById[itemIdArg] then itemIdArg else defaultItemId()
	return withRestore(player, function(profile)
		local free = BaseService.freeSlots(player)
		if not free[1] then
			return { error = "no free display slot on this base" }
		end
		local slot = free[1]
		local item = placedItem(itemId, slot, 3, "Shiny") -- Giant, Shiny
		table.insert(profile.DisplayItems, item)
		BaseService.rebuildDisplays(player)
		EconomyService.recalculate(player)
		local incomeBefore = EconomyService.getIncome(player)
		local before = fingerprint(item)

		local ok, reason = HoldService.pickup(player, slot)
		if not ok then
			return { error = reason, pickupFailed = true }
		end
		EconomyService.recalculate(player)
		local incomeAfter = EconomyService.getIncome(player)

		local stillDisplayed = findDisplayed(profile, item.InstanceId) ~= nil
		local held = findHeld(profile, item.InstanceId)
		local fieldsPreserved = held ~= nil and fingerprint(held) == before
		return {
			pass = not stillDisplayed
				and held ~= nil
				and held.HeldActive == true
				and held.HeldOrder ~= nil
				and held.SlotIndex == 0
				and incomeAfter < incomeBefore
				and fieldsPreserved,
			incomeBefore = incomeBefore,
			incomeAfter = incomeAfter,
			income_dropped_by = incomeBefore - incomeAfter,
			leftDisplay = not stillDisplayed,
			heldFlagged = held ~= nil,
			heldActive = held and held.HeldActive,
			heldOrder = held and held.HeldOrder,
			fieldsPreserved = fieldsPreserved,
			heldCount = HoldService.heldCount(player),
		}
	end)
end

-- ==========================================================
-- PLACE
-- ==========================================================

Commands.holdPlaceTest = function(player: Player, itemIdArg: any): any
	local itemId = if type(itemIdArg) == "string" and LootConfig.ById[itemIdArg] then itemIdArg else defaultItemId()
	return withRestore(player, function(profile)
		local free = BaseService.freeSlots(player)
		if not free[1] or not free[2] then
			return { error = "need 2 free display slots on this base" }
		end
		local slotA, slotB = free[1], free[2]
		local item = placedItem(itemId, slotA, 4, "Golden") -- Titan, Golden
		table.insert(profile.DisplayItems, item)
		BaseService.rebuildDisplays(player)
		EconomyService.recalculate(player)
		local incomeBefore = EconomyService.getIncome(player)
		local before = fingerprint(item)

		local pickedUp, pickupReason = HoldService.pickup(player, slotA)
		if not pickedUp then
			return { error = pickupReason, stage = "pickup" }
		end

		local placed, placeReason = HoldService.place(player, slotB)
		if not placed then
			return { error = placeReason, stage = "place" }
		end
		EconomyService.recalculate(player)
		local incomeAfter = EconomyService.getIncome(player)

		local nowDisplayed = findDisplayed(profile, item.InstanceId)
		local stillHeld = findHeld(profile, item.InstanceId) ~= nil
		local landedOnRequestedSlot = nowDisplayed ~= nil and nowDisplayed.SlotIndex == slotB
		local fieldsPreserved = nowDisplayed ~= nil and fingerprint(nowDisplayed) == before
		return {
			pass = landedOnRequestedSlot and not stillHeld and incomeAfter == incomeBefore and fieldsPreserved,
			incomeBefore = incomeBefore,
			incomeAfter = incomeAfter,
			incomeRestored = incomeAfter == incomeBefore,
			landedOnRequestedSlot = landedOnRequestedSlot,
			leftHeldSet = not stillHeld,
			fieldsPreserved = fieldsPreserved,
		}
	end)
end

-- ==========================================================
-- HANDS FULL
-- ==========================================================

Commands.holdFullTest = function(player: Player): any
	local itemId = defaultItemId()
	return withRestore(player, function(profile)
		local free = BaseService.freeSlots(player)
		if #free < HoldConfig.MAX_HELD_ITEMS + 1 then
			return { error = `need {HoldConfig.MAX_HELD_ITEMS + 1} free display slots on this base, have {#free}` }
		end
		for i = 1, HoldConfig.MAX_HELD_ITEMS + 1 do
			table.insert(profile.DisplayItems, placedItem(itemId, free[i], 1, "Normal"))
		end
		BaseService.rebuildDisplays(player)

		for i = 1, HoldConfig.MAX_HELD_ITEMS do
			local ok, reason = HoldService.pickup(player, free[i])
			if not ok then
				return { error = reason, failedAt = i, stage = "filling hands" }
			end
		end
		local overflowSlot = free[HoldConfig.MAX_HELD_ITEMS + 1]
		local ok, reason = HoldService.pickup(player, overflowSlot)
		local stillDisplayed = false
		for _, item in profile.DisplayItems do
			if item.SlotIndex == overflowSlot then
				stillDisplayed = true
			end
		end
		return {
			pass = ok == false and reason == "Hands full - place something first." and stillDisplayed,
			refused = ok == false,
			reason = reason,
			overflowItemStillOnPad = stillDisplayed,
			heldCount = HoldService.heldCount(player),
		}
	end)
end

-- ==========================================================
-- RACE: a doubled pickup and a doubled place, back-to-back, no yield
-- ==========================================================

Commands.holdRaceTest = function(player: Player, itemIdArg: any): any
	local itemId = if type(itemIdArg) == "string" and LootConfig.ById[itemIdArg] then itemIdArg else defaultItemId()
	return withRestore(player, function(profile)
		local free = BaseService.freeSlots(player)
		if not free[1] or not free[2] then
			return { error = "need 2 free display slots on this base" }
		end
		local slotA, slotB = free[1], free[2]
		table.insert(profile.DisplayItems, placedItem(itemId, slotA, 1, "Normal"))
		BaseService.rebuildDisplays(player)

		-- Two pickups for the SAME pad, fired one after the other with no
		-- yield in between - the shape a doubled ProximityPromptTriggered
		-- or a doubled HoldRequest fire would take. Only the first may
		-- succeed; the second must see "already gone", not double-move it.
		local ok1, reason1 = HoldService.pickup(player, slotA)
		local ok2, reason2 = HoldService.pickup(player, slotA)
		local exactlyOneHeld = HoldService.heldCount(player) == 1

		-- Two places for the same pad. Only one held item exists, so the
		-- first succeeds and the second must find nothing left to place.
		local ok3, reason3 = HoldService.place(player, slotB)
		local ok4, reason4 = HoldService.place(player, slotB)

		return {
			pass = ok1 == true
				and ok2 == false
				and reason2 == "Nothing to pick up there."
				and exactlyOneHeld
				and ok3 == true
				and ok4 == false
				and reason4 == "You are not holding anything.",
			pickup1 = { ok = ok1, reason = reason1 },
			pickup2 = { ok = ok2, reason = reason2 },
			exactlyOneHeldAfterDoublePickup = exactlyOneHeld,
			place1 = { ok = ok3, reason = reason3 },
			place2 = { ok = ok4, reason = reason4 },
		}
	end)
end

-- ==========================================================
-- PERSISTENCE (leave-and-rejoin simulation via DataService.reconcile)
-- ==========================================================

Commands.holdPersistTest = function(player: Player): any
	local itemId = defaultItemId()
	return withRestore(player, function(profile)
		local kept = placedItem(itemId, 0, 2, "Flaming")
		kept.Held = true
		kept.HeldOrder = 1
		kept.HeldActive = true
		table.insert(profile.Inventory, kept)

		-- Deliberately corrupted: a second "active" held item (only one may
		-- ever carry HeldActive)...
		local secondHeld = placedItem(itemId, 0, 1, "Normal")
		secondHeld.Held = true
		secondHeld.HeldOrder = 2
		secondHeld.HeldActive = true
		table.insert(profile.Inventory, secondHeld)

		-- ...and a DISPLAYED item wrongly flagged Held (should never
		-- happen, but reconcile must not trust that it can't).
		local free = BaseService.freeSlots(player)
		local corruptDisplayed: DataService.DisplayItem? = nil
		if free[1] then
			local built = placedItem(itemId, free[1], 1, "Normal")
			built.Held = true
			table.insert(profile.DisplayItems, built)
			corruptDisplayed = built
		end

		-- The exact pass a load, a rejoin, or a server hop runs.
		DataService.reconcile(profile)

		local keptAfter = findHeld(profile, kept.InstanceId)
		local activeCount = 0
		for _, item in profile.Inventory do
			if item.Held and item.HeldActive then
				activeCount += 1
			end
		end
		local displayedStillHeld = false
		if corruptDisplayed then
			for _, item in profile.DisplayItems do
				if item.InstanceId == corruptDisplayed.InstanceId and item.Held then
					displayedStillHeld = true
				end
			end
		end

		return {
			pass = keptAfter ~= nil
				and keptAfter.HeldActive == true
				and activeCount == 1
				and not displayedStillHeld,
			survivedTheRoundTrip = keptAfter ~= nil,
			stillActive = keptAfter and keptAfter.HeldActive,
			exactlyOneActiveAfterCleanup = activeCount == 1,
			corruptDisplayedItemCleaned = not displayedStillHeld,
		}
	end)
end

-- ==========================================================
-- TITAN NORMALISATION
-- ==========================================================

Commands.holdTitanScaleTest = function(player: Player, itemIdArg: any): any
	local itemId = if type(itemIdArg) == "string" and LootConfig.ById[itemIdArg] then itemIdArg else defaultItemId()
	return withRestore(player, function(profile)
		local free = BaseService.freeSlots(player)
		if not free[1] then
			return { error = "no free display slot on this base" }
		end
		local item = placedItem(itemId, free[1], 6, "Normal") -- Colossal: the biggest variant
		table.insert(profile.DisplayItems, item)
		BaseService.rebuildDisplays(player)

		local ok, reason = HoldService.pickup(player, free[1])
		if not ok then
			return { error = reason }
		end

		local character = player.Character
		local visual = character and character:FindFirstChild("HeldItemVisual")
		if not visual or not visual:IsA("Model") then
			return { error = "no character to attach the held visual to (must be run on a live, spawned test player)" }
		end
		local min, max = LootModel.visibleExtents(visual)
		if not min or not max then
			return { error = "held model has no measurable geometry" }
		end
		local size = max - min
		local longest = math.max(size.X, size.Y, size.Z)
		-- Placed (full) size for comparison, straight from BaseService's own rule.
		local placedScale = BaseService.displayScale(item)
		return {
			pass = longest <= HoldConfig.HELD_TARGET_LONGEST_SIDE * 1.05,
			colossalPlacedScale = placedScale,
			heldLongestSide = longest,
			targetLongestSide = HoldConfig.HELD_TARGET_LONGEST_SIDE,
			shrunkFromPlacedSize = longest < placedScale,
		}
	end)
end

-- ==========================================================
-- EVERYTHING
-- ==========================================================

Commands.holdSuite = function(player: Player, itemIdArg: any): any
	local order = { "holdPickupTest", "holdPlaceTest", "holdFullTest", "holdRaceTest", "holdPersistTest", "holdTitanScaleTest" }
	local results: { [string]: any } = {}
	local allPass = true
	for _, name in order do
		local result = (Commands :: { [string]: (Player, any) -> any })[name](player, itemIdArg)
		results[name] = result
		if type(result) ~= "table" or result.pass ~= true then
			allPass = false
		end
	end
	return { pass = allPass, results = results }
end

return Commands
