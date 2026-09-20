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
	      holds HOTBAR_SLOTS + 4 items (one pickup off a pad, the rest hold()
	      from Storage): none may be refused - there is no "Hands full" any
	      more.
	  holdPositionTest
	      pure layout: 12 held items with 0 gadgets (tools = Slap + Trap, held
	      keys start at 3, 8 on the hotbar, 4 overflow) and with 2 gadgets
	      (held keys start at 5, 6 on the hotbar, 6 overflow).
	  holdOverflowTest
	      holdMany() past the hotbar: the active item is always ON the hotbar,
	      and equipping an overflow rank takes the last hotbar position.
	  holdFromStorageTest
	      HoldService.hold / holdMany from Storage: order, active flag,
	      "already held" / "missing" refusals, a racing second hold().
	  holdStoreTest
	      the "store" action: flags cleared, item stays in Inventory, the next
	      held item becomes active, an empty-handed store is refused.
	  holdNoToastTest
	      pickup + place fire NO StateService.notify at all.
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

local HeldLayout = require(ReplicatedStorage.Shared.Util.HeldLayout)
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
	-- START FROM EMPTY HANDS. Every test counts held items from zero, but a
	-- tester's real profile can already be holding some (the owner's was, from
	-- a live session: the suite failed on counts that were off by exactly
	-- those). The flags come off for the length of the test; the snapshot
	-- above puts them back.
	for _, item in profile.Inventory do
		item.Held, item.HeldOrder, item.HeldActive = nil, nil, nil
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
-- NO HAND CAP: past the hotbar's ten positions everything is overflow
-- ==========================================================

--- Adds `count` plain (not held) trophies to Storage and returns their ids.
local function injectStored(profile: DataService.Profile, itemId: string, count: number): { string }
	local ids: { string } = {}
	for _ = 1, count do
		local item = placedItem(itemId, 0, 1, "Normal")
		table.insert(profile.Inventory, item)
		table.insert(ids, item.InstanceId)
	end
	return ids
end

--- Position (1-based rank) of `instanceId` among the held items.
local function rankOf(profile: DataService.Profile, instanceId: string): number?
	for rank, item in HeldLayout.rank(profile.Inventory) do
		if item.InstanceId == instanceId then
			return rank
		end
	end
	return nil
end

Commands.holdFullTest = function(player: Player): any
	local itemId = defaultItemId()
	return withRestore(player, function(profile)
		local free = BaseService.freeSlots(player)
		local count = HoldConfig.HOTBAR_SLOTS + 4 -- well past the hotbar
		if not free[1] then
			return { error = "no free display slot on this base" }
		end
		-- One real pickup off a pad, then the rest from Storage: neither may be
		-- refused for "hands full" any more.
		table.insert(profile.DisplayItems, placedItem(itemId, free[1], 1, "Normal"))
		BaseService.rebuildDisplays(player)
		local okPickup, reasonPickup = HoldService.pickup(player, free[1])
		local ids = injectStored(profile, itemId, count - 1)
		local refusals: { string } = {}
		for _, id in ids do
			local ok, reason = HoldService.hold(player, id)
			if not ok then
				table.insert(refusals, tostring(reason))
			end
		end
		local held = HoldService.heldCount(player)
		return {
			pass = okPickup and #refusals == 0 and held == count and HoldConfig.MAX_HELD_ITEMS >= 90,
			pickupOk = okPickup,
			pickupReason = reasonPickup,
			refusals = refusals,
			heldCount = held,
			expected = count,
			maxHeldCeiling = HoldConfig.MAX_HELD_ITEMS,
		}
	end)
end

-- ==========================================================
-- POSITIONAL NUMBERING (pure layout: 0 gadgets vs 2 gadgets vs a full bar)
-- ==========================================================

Commands.holdPositionTest = function(_player: Player): any
	-- 12 held items with out-of-order HeldOrder values, to prove the rank
	-- comes from HeldOrder and nothing else.
	local inventory: { any } = {}
	local orders = { 7, 3, 12, 1, 9, 2, 11, 5, 4, 10, 6, 8 }
	for _, order in orders do
		table.insert(inventory, { InstanceId = `i{order}`, Held = true, HeldOrder = order })
	end
	table.insert(inventory, { InstanceId = "plain" }) -- stored, never held
	local ranked = HeldLayout.rank(inventory)

	local function layout(toolCount: number): { firstHeldKey: number, onHotbar: number, overflow: number, lastKey: number }
		local capacity = HeldLayout.capacity(toolCount)
		local onHotbar = math.min(capacity, #ranked)
		return {
			firstHeldKey = toolCount + 1, -- consecutive right after the tools
			onHotbar = onHotbar,
			overflow = #ranked - onHotbar,
			lastKey = toolCount + onHotbar,
		}
	end
	local none = layout(2) -- Slap, Trap only: no gadgets owned
	local two = layout(4) -- Slap, Trap and two gadgets
	local sorted = true
	for rank, item in ranked do
		sorted = sorted and item.HeldOrder == rank
	end
	return {
		pass = #ranked == 12
			and sorted
			and none.firstHeldKey == 3
			and none.onHotbar == 8
			and none.overflow == 4
			and none.lastKey == 10
			and two.firstHeldKey == 5
			and two.onHotbar == 6
			and two.overflow == 6
			and two.lastKey == 10
			and HeldLayout.capacity(12) == 0,
		zeroGadgets = none,
		twoGadgets = two,
		rankedByHeldOrder = sorted,
	}
end

-- ==========================================================
-- OVERFLOW SWAP: the equipped item is always on the hotbar
-- ==========================================================

Commands.holdOverflowTest = function(player: Player): any
	local itemId = defaultItemId()
	return withRestore(player, function(profile)
		local capacity = HoldService.hotbarCapacity(player)
		if capacity < 1 then
			return { error = "this player's tools already fill the hotbar; nothing to test" }
		end
		local total = capacity + 3
		local ids = injectStored(profile, itemId, total)
		local ok, reason = HoldService.holdMany(player, ids)
		if not ok then
			return { error = reason, stage = "holdMany" }
		end
		local lastId = ids[total]
		local lastRank = rankOf(profile, lastId)
		-- holdMany leaves the LAST as active and the active item must be on
		-- the hotbar even though it came last.
		local lastOnHotbar = lastRank ~= nil and lastRank <= capacity
		local active = HoldService.activeHeld(player)
		local lastIsActive = active ~= nil and active.InstanceId == lastId

		-- Equip an overflow item (whatever is at rank capacity + 1 now).
		local ranked = HeldLayout.rank(profile.Inventory)
		local target = ranked[capacity + 1]
		local rankBefore = capacity + 1
		local okEquip, reasonEquip = HoldService.equip(player, rankBefore)
		local rankAfter = rankOf(profile, target.InstanceId)
		local activeAfter = HoldService.activeHeld(player)
		local swappedIn = rankAfter ~= nil and rankAfter <= capacity and rankAfter == capacity
		return {
			pass = lastOnHotbar
				and lastIsActive
				and okEquip
				and swappedIn
				and activeAfter ~= nil
				and activeAfter.InstanceId == target.InstanceId
				and HoldService.heldCount(player) == total,
			capacity = capacity,
			lastRank = lastRank,
			lastOnHotbar = lastOnHotbar,
			equipOk = okEquip,
			equipReason = reasonEquip,
			rankAfterEquip = rankAfter,
			swappedIntoLastHotbarPosition = swappedIn,
			heldCount = HoldService.heldCount(player),
		}
	end)
end

-- ==========================================================
-- hold() / holdMany() FROM STORAGE (the Relic Roll entry point)
-- ==========================================================

Commands.holdFromStorageTest = function(player: Player): any
	local itemId = defaultItemId()
	return withRestore(player, function(profile)
		local ids = injectStored(profile, itemId, 3)
		local okOne, reasonOne = HoldService.hold(player, ids[1])
		local okAgain, reasonAgain = HoldService.hold(player, ids[1]) -- already held
		local okMissing, reasonMissing = HoldService.hold(player, "no-such-item")
		local okMany, reasonMany = HoldService.holdMany(player, { ids[2], ids[3] })
		local first = findHeld(profile, ids[1])
		local activeItem = HoldService.activeHeld(player)
		local order2, order3 = findHeld(profile, ids[2]), findHeld(profile, ids[3])

		-- Racing calls: the second sees the first's result, never a double hold.
		local more = injectStored(profile, itemId, 1)
		local race1 = HoldService.hold(player, more[1])
		local race2 = HoldService.hold(player, more[1])

		local activeCount = 0
		for _, item in profile.Inventory do
			if item.Held and item.HeldActive then
				activeCount += 1
			end
		end
		return {
			pass = okOne
				and not okAgain
				and reasonAgain ~= nil
				and not okMissing
				and reasonMissing ~= nil
				and okMany
				and first ~= nil
				and order2 ~= nil
				and order3 ~= nil
				and (first.HeldOrder :: number) < (order2.HeldOrder :: number)
				and (order2.HeldOrder :: number) < (order3.HeldOrder :: number)
				and race1 == true
				and race2 == false
				and activeCount == 1
				and HoldService.heldCount(player) == 4,
			holdOne = { ok = okOne, reason = reasonOne },
			holdAgain = { ok = okAgain, reason = reasonAgain },
			holdMissing = { ok = okMissing, reason = reasonMissing },
			holdMany = { ok = okMany, reason = reasonMany },
			exactlyOneActive = activeCount == 1,
			heldCount = HoldService.heldCount(player),
			lastHeldWasActiveBeforeRace = activeItem ~= nil,
		}
	end)
end

-- ==========================================================
-- STORE IT
-- ==========================================================

Commands.holdStoreTest = function(player: Player): any
	local itemId = defaultItemId()
	return withRestore(player, function(profile)
		local ids = injectStored(profile, itemId, 2)
		HoldService.holdMany(player, ids)
		local storedActive = ids[2] -- the last is the active one
		local okStore, reasonStore = HoldService.store(player)
		local stillInInventory = false
		for _, item in profile.Inventory do
			if item.InstanceId == storedActive then
				stillInInventory = item.Held == nil and item.HeldOrder == nil and item.HeldActive == nil
			end
		end
		local other = findHeld(profile, ids[1])
		local otherNowActive = other ~= nil and other.HeldActive == true
		local inventoryCount = #profile.Inventory
		-- The remote limiter is one shared bucket (4/s), so wait it out
		-- between the two store presses instead of tripping "Slow down!".
		task.wait(1.1)
		local okSecond = HoldService.store(player)
		task.wait(1.1)
		local okThird, reasonThird = HoldService.store(player) -- hands empty now
		return {
			pass = okStore
				and stillInInventory
				and otherNowActive
				and okSecond
				and not okThird
				and reasonThird == "You are not holding anything."
				and HoldService.heldCount(player) == 0
				and #profile.Inventory == inventoryCount,
			store = { ok = okStore, reason = reasonStore },
			itemStayedInStorageUnheld = stillInInventory,
			otherBecameActive = otherNowActive,
			secondStoreOk = okSecond,
			thirdStore = { ok = okThird, reason = reasonThird },
			inventoryUnchanged = #profile.Inventory == inventoryCount,
		}
	end)
end

-- ==========================================================
-- NO TOAST ON PICKUP / PLACE (errors still notify)
-- ==========================================================

Commands.holdNoToastTest = function(player: Player): any
	local itemId = defaultItemId()
	return withRestore(player, function(profile)
		local free = BaseService.freeSlots(player)
		if not free[1] or not free[2] then
			return { error = "need 2 free display slots on this base" }
		end
		table.insert(profile.DisplayItems, placedItem(itemId, free[1], 1, "Normal"))
		BaseService.rebuildDisplays(player)

		-- Count every notify() the two calls make. StateService.notify is what
		-- HoldService's toasts go through; restored in a pcall so a failure
		-- cannot leave it swapped out.
		local mutable = StateService :: any
		local original = mutable.notify
		local toasts = 0
		mutable.notify = function(_p: Player, _kind: string, _message: string, _detail: string?)
			toasts += 1
		end
		local ok, result = pcall(function()
			local pickedUp = HoldService.pickup(player, free[1])
			task.wait(0.3) -- past the shared rate-limit bucket
			local placed = HoldService.place(player, free[2])
			return { pickedUp = pickedUp, placed = placed }
		end)
		mutable.notify = original
		if not ok then
			return { error = tostring(result) }
		end
		return {
			pass = result.pickedUp == true and result.placed == true and toasts == 0,
			pickedUp = result.pickedUp,
			placed = result.placed,
			toasts = toasts,
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
				-- Either refusal is right: the pad is full now AND the hands are
				-- empty; which check answers first is not the point.
				and (reason4 == "You are not holding anything." or reason4 == "That slot is already full."),
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
	local order = {
		"holdPickupTest",
		"holdPlaceTest",
		"holdFullTest",
		"holdPositionTest",
		"holdOverflowTest",
		"holdFromStorageTest",
		"holdStoreTest",
		"holdNoToastTest",
		"holdRaceTest",
		"holdPersistTest",
		"holdTitanScaleTest",
	}
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
