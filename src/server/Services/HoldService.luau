--!strict
--[[
	HoldService  [hold-items]
	"Hold it in your hands": pick a revealed trophy up off your own display
	pad into your hands, carry it around small, place it back on any empty
	pad. See docs/handoff-parts/hold-items.md for the full design writeup.

	THE MODEL. A held item is NOT a new list and NOT a new kind of record - it
	is an ordinary profile.Inventory (Storage) entry with two extra optional
	fields (DataService.DisplayItem: Held, HeldOrder, HeldActive). That means,
	for free, everything Storage already guarantees keeps being true of a held
	item: it is real (no duplication - it is the exact same table that used to
	sit in DisplayItems), it still counts against storage capacity, it is
	saved on every profile save, and it survives a leave, a crash, a server
	hop or a death exactly as any other stored item does. Trading, fusion,
	selling and the Storage UI all already iterate profile.Inventory; see
	docs/handoff-parts/hold-items.md for exactly how each of those was made to
	either skip a held item or work with it safely.

	POSITIONS. Nothing renumbers on a pickup or a place. Each held item keeps
	a HeldOrder stamped once, when it was (most recently) picked up; its RANK
	among the currently held set (HeldLayout.rank, shared with the client) is
	its position. The hotbar is [tools + owned gadgets][held items] with no
	gaps, so the first HeldLayout.capacity(toolCount) ranks are on the hotbar
	and the rest live in the overflow inventory (backtick). Equipping a rank
	past the hotbar (or picking up / holding when the hotbar is full) swaps
	that item into the LAST hotbar position and pushes the least recently
	used hotbar item to the overflow (HeldOrder values re-dealt in order).
	There is no hand cap: only Storage capacity bounds the held set.
	HoldService.hold / holdMany take items already in Storage into the hands
	(Relic Roll's entry point).

	ATOMICITY / IDEMPOTENCY. pickup/place/equip each read the profile fresh,
	decide, and mutate - with no yield in between - so two requests for the
	same player can never interleave (Roblox runs one RemoteEvent handler to
	completion before the next queued one starts, as long as neither yields,
	and none of these do). A second, racing request simply sees the state the
	first one already produced and is refused on ordinary grounds ("Nothing to
	pick up there.", "You are not holding anything.") rather than double-moving
	anything. HoldItems.luau's `racePickup` debug command exercises this.

	WHY BASE STEALS CANNOT TOUCH A HELD ITEM. HeistService only ever looks at
	profile.DisplayItems (what is physically standing on a pad) - a held item
	has already been removed from that list by the time it is in someone's
	hands, exactly like a plain stored item. This is deliberate and stated
	here once for the record: an item in your hands is not on your base, so it
	is exactly as safe from a night raid or a bat thief as anything already in
	Storage - never safer, never less safe.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HoldConfig = require(ReplicatedStorage.Shared.Config.HoldConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local MutationVfx = require(ReplicatedStorage.Shared.Util.MutationVfx)
local HeldLayout = require(ReplicatedStorage.Shared.Util.HeldLayout)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local AnalyticsEvents = require(script.Parent.AnalyticsEvents)
local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local HatchService = require(script.Parent.HatchService)
local HeistService = require(script.Parent.HeistService)
local StateService = require(script.Parent.StateService)

local HoldService = {}

-- One bucket for every hold action, same reuse pattern as PlacementService's
-- placeLimiter (shared by both `place` and `equip`).
local holdLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.HoldRequest)

local function notify(player: Player, kind: string, message: string, detail: string?)
	StateService.notify(player, kind, message, detail)
end

-- ==========================================================
-- READING THE HELD SET
-- ==========================================================

--- The item EQUIPPED right now (in the hands) and its Inventory index, or
--- nil, nil. ONE THING IN THE HANDS AT A TIME (owner, 2026-09-20): a held item
--- is only "in hand" while the player has pressed its key; a Tool (Slap, Trap,
--- a gadget) being equipped puts it away, and equipping it puts the Tool away.
--- Items that are held but not equipped just sit on the hotbar. There is no
--- "newest one is always shown" fallback any more.
local function findActiveHeld(profile: DataService.Profile): (DataService.DisplayItem?, number?)
	for index, item in profile.Inventory do
		if item.Held and item.HeldActive then
			return item, index
		end
	end
	return nil, nil
end

--- Puts whatever Tool the player has equipped back in the Backpack. Used when
--- a held item is taken into the hands: the hands hold one thing.
local function unequipTools(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pcall(function()
			humanoid:UnequipTools()
		end)
	end
end

--- Puts the held item away (still held, still on the hotbar, just not in the
--- hands). True when something changed.
local function clearActive(profile: DataService.Profile): boolean
	local changed = false
	for _, item in profile.Inventory do
		if item.HeldActive then
			item.HeldActive = nil
			changed = true
		end
	end
	return changed
end

--- Every held item, oldest pickup first - rank N in this list IS held
--- position N. The order comes from HeldLayout, shared with the client
--- (HotbarController / HeldOverflowController) so both sides agree.
local function heldInOrder(profile: DataService.Profile): { DataService.DisplayItem }
	return HeldLayout.rank(profile.Inventory) :: any
end

--- How many hotbar positions tools and owned gadgets take right now: the
--- Tools the player has (Backpack plus the one in hand), the same set the
--- client's HotbarController lays out first. Read from the Tools themselves
--- so the server never has to know which gadgets a player owns.
local function toolCount(player: Player): number
	local count = 0
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") then
				count += 1
			end
		end
	end
	local character = player.Character
	if character then
		for _, child in character:GetChildren() do
			if child:IsA("Tool") then
				count += 1
			end
		end
	end
	return math.min(count, HoldConfig.HOTBAR_SLOTS)
end

-- "Least recently used" for the overflow swap. In memory only (a rejoin
-- starts every item at 0 = oldest, ties resolved by the lowest position),
-- so nothing new is saved and nothing here can outlive the player.
local lastUsed: { [Player]: { [string]: number } } = {}
local useClock = 0

--- Makes `item` (which must be a held Inventory entry) THE active held item.
--- If its rank is past the hotbar it takes the LAST hotbar position and the
--- least recently used hotbar item is pushed into the overflow (HeldOrder
--- values are re-dealt in the new sequence), so the equipped item is always
--- on the hotbar.
--- No yields, so it is atomic with whatever called it.
local function activate(player: Player, profile: DataService.Profile, item: DataService.DisplayItem)
	local held = heldInOrder(profile)
	for _, other in held do
		other.HeldActive = nil
	end
	item.HeldActive = true
	-- One thing in the hands: the item comes out, so the Tool goes away.
	unequipTools(player)

	local usage = lastUsed[player]
	if not usage then
		usage = {}
		lastUsed[player] = usage
	end
	useClock += 1
	usage[item.InstanceId] = useClock

	local capacity = HeldLayout.capacity(toolCount(player))
	local rank = table.find(held, item)
	if capacity > 0 and rank and rank > capacity then
		local victim: DataService.DisplayItem? = nil
		local oldest = math.huge
		for position = 1, capacity do
			local candidate = held[position]
			local used = usage[candidate.InstanceId] or 0
			if used < oldest then
				victim, oldest = candidate, used
			end
		end
		if victim then
			-- New sequence: the hotbar without the victim, the item appended
			-- as the LAST hotbar position; the overflow with the victim
			-- standing where the item was. Then the existing HeldOrder values
			-- are dealt out again in that sequence (the same multiset, so
			-- every order stays unique and nothing else in the game reads it).
			local orders: { number } = {}
			local sequence: { DataService.DisplayItem } = {}
			for position, candidate in held do
				table.insert(orders, tonumber(candidate.HeldOrder) or 0)
				if position <= capacity then
					if candidate ~= victim then
						table.insert(sequence, candidate)
					end
				end
			end
			table.insert(sequence, item)
			for position = capacity + 1, #held do
				local candidate = held[position]
				table.insert(sequence, if candidate == item then victim else candidate)
			end
			for position, candidate in sequence do
				candidate.HeldOrder = orders[position]
			end
		end
	end
end

--- The one internal path a pickup and hold() both take a Storage entry into
--- the hands: flag it, stamp the next HeldOrder, make it the active item. No
--- yields (see the header), so racing callers cannot double-hold.
local function markHeld(player: Player, profile: DataService.Profile, item: DataService.DisplayItem)
	local highestOrder = 0
	for _, other in profile.Inventory do
		if other.Held then
			highestOrder = math.max(highestOrder, tonumber(other.HeldOrder) or 0)
		end
	end
	item.Held = true
	item.HeldOrder = highestOrder + 1
	activate(player, profile, item)
end

--- How many items this player is currently holding.
function HoldService.heldCount(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	local count = 0
	for _, item in profile.Inventory do
		if item.Held then
			count += 1
		end
	end
	return count
end

function HoldService.isHolding(player: Player): boolean
	return HoldService.heldCount(player) > 0
end

--- The item shown small in the player's hands right now, or nil.
function HoldService.activeHeld(player: Player): DataService.DisplayItem?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local item = findActiveHeld(profile)
	return item
end

--- How many hotbar positions this player has for held items right now (10
--- minus their tools and gadgets); ranks past it are in the overflow.
function HoldService.hotbarCapacity(player: Player): number
	return HeldLayout.capacity(toolCount(player))
end

-- ==========================================================
-- THE HELD VISUAL
-- ==========================================================

local VISUAL_NAME = "HeldItemVisual"

--- Removes the local held-item model from a character, if any. Safe to call
--- whether or not one exists.
local function clearVisual(character: Instance)
	local existing = character:FindFirstChild(VISUAL_NAME)
	if existing then
		existing:Destroy()
	end
end

--- (Re)builds and welds the active held item onto `player`'s character, or
--- removes it if they are holding nothing. Called after every pickup, place
--- and equip, on every base rebuild (BaseService.onRebuilt - covers join and
--- capacity changes) and on every respawn, so the model can never go stale or
--- survive past a place.
function HoldService.refreshHeldVisual(player: Player)
	local character = player.Character
	if not character then
		return
	end
	clearVisual(character)

	local item = HoldService.activeHeld(player)
	if not item then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	-- ALWAYS TINY, regardless of the item's real placed Scale. sizeScale = 1
	-- and no footprint cap: build() itself only normalises to "Normal" size,
	-- so the model is re-measured and rescaled again right below to a fixed
	-- longest-side box. A Titan and a coin come out the same size in hand.
	local def = LootConfig.ById[item.ItemId]
	local model = LootModel.build({
		itemId = item.ItemId,
		rarity = item.Rarity,
		targetHeight = LootModel.NORMAL_HEIGHT,
		sizeScale = 1,
		placeholderSize = Vector3.new(2, 2, 2),
	})
	model.Name = VISUAL_NAME

	local primary = model.PrimaryPart
	if not primary then
		model:Destroy()
		return
	end

	local min, max = LootModel.visibleExtents(model)
	if min and max then
		local size = max - min
		local longest = math.max(size.X, size.Y, size.Z, HoldConfig.HELD_MIN_LONGEST_SIDE)
		local factor = HoldConfig.HELD_TARGET_LONGEST_SIDE / longest
		if math.abs(factor - 1) > 0.001 then
			model:ScaleTo(model:GetScale() * factor)
		end
	end

	-- The trophy keeps its mutation identity even tiny in the hand; no
	-- SizeAura here - that effect is authored around a pedestal-sized item
	-- and would swallow a two-stud trinket whole.
	MutationVfx.apply(model, item.Mutation)

	local highlight = Instance.new("Highlight")
	highlight.Name = "HeldOutline"
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = HoldConfig.HELD_OUTLINE_TRANSPARENCY
	highlight.OutlineColor = RarityConfig.Colors[item.Rarity] or Color3.new(1, 1, 1)
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = model
	highlight.Parent = model

	-- THE WHOLE MODEL, not its primary part. `primary.CFrame = ...` moved one
	-- part and left the rest of the item at the build position (the Studio
	-- test measured a "2 stud" trinket 89 studs across). Orient with the
	-- player, then translate so the model's CENTRE lands on the hand point -
	-- an import's pivot is wherever the artist left it (CarryService's rule).
	local target = root.CFrame * HoldConfig.HELD_OFFSET
	model:PivotTo(target)
	local boxCFrame = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + (target.Position - boxCFrame.Position))
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "HeldWeld"
	weld.Part0 = root
	weld.Part1 = primary
	weld.Parent = primary

	-- Read by the client's HeldItemFxController for the little info billboard
	-- (name, rarity, income/s) - built client-side, per viewer, so it can
	-- honour that viewer's own Effects / Low Graphics setting and MaxDistance
	-- rather than being baked identically for everyone by the server.
	model:SetAttribute("HeldItem", true)
	model:SetAttribute("HeldItemName", if def then def.name else item.ItemId)
	model:SetAttribute("HeldRarity", item.Rarity)
	-- What it EARNS ONCE PLACED (maturedRate), not its current rate (which is
	-- always zero while held) - a live zero is a less useful number on the
	-- billboard than the payoff waiting on the other end of pressing Place.
	model:SetAttribute("HeldIncomePerSec", EconomyService.maturedRate(player, item))

	model.Parent = character
end

-- ==========================================================
-- PICK UP
-- ==========================================================

--- Takes the revealed trophy on `slotIndex` into the player's hands. Real
--- guards shared with PlacementService.store: not mid-theft, not sealed.
function HoldService.pickup(player: Player, slotIndex: number): (boolean, string?)
	if not holdLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local found, foundAt = nil, nil
	for index, item in profile.DisplayItems do
		if item.SlotIndex == slotIndex then
			found, foundAt = item, index
			break
		end
	end
	if not found or not foundAt then
		return false, "Nothing to pick up there."
	end
	if found.RobbedBy then
		return false, "That item is being stolen - stop the thief!"
	end
	if HeistService.isReserved(found.InstanceId) then
		return false, "Someone is trying to steal that right now!"
	end
	if found.Hatched == false or HatchService.isRevealing(found.InstanceId) then
		return false, "Reveal it first!"
	end

	-- No hand limit: a held item is a Storage entry, so only Storage capacity
	-- bounds it.
	if #profile.Inventory >= StorageConfig.capacityForTier(profile.StorageTier) then
		return false, "Storage full - sell something first."
	end

	table.remove(profile.DisplayItems, foundAt)
	found.SlotIndex = 0
	table.insert(profile.Inventory, found)
	-- "You begin showing the newest item you picked up": HeldOrder next in
	-- line, every other held item loses the active flag, this one gets it.
	markHeld(player, profile, found)

	-- Redraws the now-empty pad, refreshes every prompt on the base (that pad
	-- can now show "Place"; nothing else on the base changed) and, through
	-- BaseService.onRebuilt, calls HoldService.refreshHeldVisual for us.
	BaseService.rebuildSlot(player, slotIndex)
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	-- No "Picked up ..." toast (owner, 2026-09-20): the item appearing on the
	-- hotbar is the feedback. Errors above still notify.
	StateService.sound(player, "StoredItem")

	AnalyticsEvents.custom(player, "ItemPickedUp", 1, { found.Rarity, `n{HoldService.heldCount(player)}` })

	return true
end

--- PUBLIC API (Relic Roll and any other service that hands a player an item
--- straight into their hands). Takes an item that is in profile.Inventory
--- (Storage) and NOT already held, holds it with the next HeldOrder and makes
--- it the active item, then refreshes the hand visual and the inventory push
--- exactly like a pickup. Never refuses for "hands full". Returns false plus a
--- short reason only for: no profile, item missing from Storage, already held.
--- Not rate-limited (a server-side call, not a client request).
function HoldService.hold(player: Player, instanceId: string): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local found: DataService.DisplayItem? = nil
	for _, item in profile.Inventory do
		if item.InstanceId == instanceId then
			found = item
			break
		end
	end
	if not found then
		return false, "That item is not in storage."
	end
	if found.Held then
		return false, "Already in your hands."
	end
	markHeld(player, profile, found)
	HoldService.refreshHeldVisual(player)
	StateService.pushNow(player)
	return true
end

--- Holds each id in the given order, leaving the LAST one that succeeded as
--- the active item, with one refresh at the end. An id that cannot be held
--- (missing, already held, repeated) is skipped; the first such reason is
--- returned with `false` after every holdable one was held.
function HoldService.holdMany(player: Player, instanceIds: { string }): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local firstReason: string? = nil
	local heldAny = false
	for _, instanceId in instanceIds do
		local found: DataService.DisplayItem? = nil
		for _, item in profile.Inventory do
			if item.InstanceId == instanceId then
				found = item
				break
			end
		end
		if not found then
			firstReason = firstReason or "That item is not in storage."
		elseif found.Held then
			firstReason = firstReason or "Already in your hands."
		else
			markHeld(player, profile, found)
			heldAny = true
		end
	end
	if heldAny then
		HoldService.refreshHeldVisual(player)
		StateService.pushNow(player)
	end
	return firstReason == nil, firstReason
end

-- ==========================================================
-- PLACE
-- ==========================================================

--- Puts the currently EQUIPPED held item down on `slotIndex` (must be
--- unlocked and empty). Every field the item was picked up with - Scale,
--- VisualScale, Mutation, GrowthSeconds, MaturationSeconds, income - travels
--- back untouched; only the three Held* fields and SlotIndex change.
function HoldService.place(player: Player, slotIndex: number): (boolean, string?)
	if not holdLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local unlocked = BaseService.unlockedSlots(player)
	if slotIndex < 1 or slotIndex > unlocked then
		return false, "That slot is locked."
	end
	for _, item in profile.DisplayItems do
		if item.SlotIndex == slotIndex then
			return false, "That slot is already full."
		end
	end

	local active, activeAt = findActiveHeld(profile)
	if not active or not activeAt then
		return false, if HoldService.heldCount(player) > 0
			then "Press an item's number to take it out first."
			else "You are not holding anything."
	end
	if active.Hatched == false then
		-- Defensive only: pickup() refuses a sealed container, so a held item
		-- reaching here unrevealed would mean a bug elsewhere, not a player
		-- action. Refused exactly like a normal equip-from-storage would be.
		return false, "Reveal it first!"
	end

	table.remove(profile.Inventory, activeAt)
	active.Held = nil
	active.HeldOrder = nil
	active.HeldActive = nil
	active.SlotIndex = slotIndex
	table.insert(profile.DisplayItems, active)

	-- The hands are EMPTY afterwards: the next held item is not pulled out on
	-- its own (owner, 2026-09-20) - its key does that.

	BaseService.rebuildSlot(player, slotIndex)
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	-- No "PLACED ..." toast (owner, 2026-09-20): the trophy standing on the
	-- pad, earning, is the feedback.
	StateService.sound(player, "PlaceItem")

	AnalyticsEvents.custom(player, "ItemPlaced", 1, { active.Rarity })

	return true
end

-- ==========================================================
-- EQUIP (switch which held item is shown)
-- ==========================================================

--- Makes the held item at position `rank` (1..HoldConfig.MAX_HELD_ITEMS, by
--- pickup order - see heldInOrder) the one shown small in the player's hands.
function HoldService.equip(player: Player, rank: number): (boolean, string?)
	if not holdLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local held = heldInOrder(profile)
	local target = held[rank]
	if not target then
		return false, "Nothing in that hand slot."
	end
	if target.HeldActive then
		-- Its key again PUTS IT AWAY (a toggle, like a Tool's key): still held,
		-- still on the hotbar, just not in the hands.
		target.HeldActive = nil
		HoldService.refreshHeldVisual(player)
		StateService.pushNow(player)
		return true
	end
	-- A rank on the hotbar just becomes the active item; a rank in the
	-- overflow swaps in for the least recently used hotbar item (activate).
	activate(player, profile, target)

	HoldService.refreshHeldVisual(player)
	StateService.pushNow(player)
	return true
end

-- ==========================================================
-- STORE (the hands go back into plain Storage)
-- ==========================================================

--- Stores the EQUIPPED held item: clears its Held flags, the entry itself
--- stays in Inventory (nothing is created or destroyed). The newest remaining
--- held item, if any, becomes the active one - the same rule `place` uses.
--- The client sends no item id; the server resolves the active item itself.
function HoldService.store(player: Player): (boolean, string?)
	if not holdLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local active = findActiveHeld(profile)
	if not active then
		return false, "You are not holding anything."
	end
	active.Held = nil
	active.HeldOrder = nil
	active.HeldActive = nil
	local usage = lastUsed[player]
	if usage then
		usage[active.InstanceId] = nil
	end

	-- Hands empty afterwards, as with place: the next item is not auto-equipped.

	HoldService.refreshHeldVisual(player)
	StateService.pushNow(player)
	StateService.sound(player, "StoredItem")
	return true
end

-- ==========================================================
-- START
-- ==========================================================

function HoldService.start()
	-- Fires on join (BaseService.assign) and after anything that redraws the
	-- base (capacity upgrades, heists, debug commands) - the one hook that
	-- keeps the held-item model in step without HoldService needing its own
	-- copy of "when did the base change".
	--- Each session starts with EMPTY hands: the first rebuild after a join
	--- clears whatever was equipped when the last session ended.
	local handsChecked: { [Player]: boolean } = {}
	BaseService.onRebuilt(function(player)
		if not handsChecked[player] then
			handsChecked[player] = true
			local profile = DataService.get(player)
			if profile and clearActive(profile) then
				StateService.pushNow(player)
			end
		end
		HoldService.refreshHeldVisual(player)
	end)

	Remotes.get("HoldRequest").OnServerEvent:Connect(function(player, action, argument)
		if type(action) ~= "string" then
			return
		end

		local ok, reason
		if action == "pickup" then
			local slot = Validate.integer(argument, 1, GameConfig.MAX_DISPLAY_SLOTS)
			if not slot then
				return
			end
			ok, reason = HoldService.pickup(player, slot)
		elseif action == "place" then
			local slot = Validate.integer(argument, 1, GameConfig.MAX_DISPLAY_SLOTS)
			if not slot then
				return
			end
			ok, reason = HoldService.place(player, slot)
		elseif action == "store" then
			-- No argument: the server stores whatever IS equipped.
			ok, reason = HoldService.store(player)
		elseif action == "equip" then
			local rank = Validate.integer(argument, 1, HoldConfig.MAX_HELD_ITEMS)
			if not rank then
				return
			end
			ok, reason = HoldService.equip(player, rank)
		else
			return
		end

		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	-- RESPAWN: the model lives on the character, so it is gone the instant
	-- the old one is; wait for the new rig's root part, then rebuild it.
	--
	-- ONE THING IN THE HANDS: a Tool arriving on the character (its key was
	-- pressed) puts the held item away. Watched on the SERVER, so it holds
	-- however the Tool was equipped. A new life starts with empty hands.
	local function onCharacter(player: Player, character: Model)
		character.ChildAdded:Connect(function(child)
			if not child:IsA("Tool") then
				return
			end
			local profile = DataService.get(player)
			if profile and clearActive(profile) then
				HoldService.refreshHeldVisual(player)
				StateService.pushNow(player)
			end
		end)
		task.defer(function()
			character:WaitForChild("HumanoidRootPart", 5)
			if not character.Parent then
				return
			end
			local profile = DataService.get(player)
			if profile and clearActive(profile) then
				StateService.pushNow(player)
			end
			HoldService.refreshHeldVisual(player)
		end)
	end

	for _, player in Players:GetPlayers() do
		if player.Character then
			onCharacter(player, player.Character)
		end
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
	end
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastUsed[player] = nil
		handsChecked[player] = nil
		holdLimiter:release(player)
	end)
end

return HoldService
