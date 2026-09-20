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

	HAND-SLOT NUMBERING. Nothing renumbers on a pickup or a place. Each held
	item keeps a HeldOrder stamped once, when it was (most recently) picked
	up; the hand-slot number shown in the hotbar (1..HoldConfig.MAX_HELD_ITEMS)
	is just the RANK of a held item's HeldOrder among the currently held set,
	recomputed live by both this service (equip) and the client
	(HotbarController) from the same sorted list. That is what makes "pick up
	a second item and your hand becomes 1, 2" and "place slot 1 and slot 2
	slides down to 1" both true without ever rewriting a slot number by hand.

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
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
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

--- The active held item and its Inventory index, or nil, nil while holding
--- nothing. Prefers the item flagged HeldActive; falls back to the most
--- recently picked-up held item if none is flagged (a hand-edited save, or a
--- profile saved between HoldService versions) so the feature degrades to
--- "show something sensible" rather than "show nothing".
local function findActiveHeld(profile: DataService.Profile): (DataService.DisplayItem?, number?)
	local fallback, fallbackAt, fallbackOrder = nil, nil, -1
	for index, item in profile.Inventory do
		if item.Held then
			if item.HeldActive then
				return item, index
			end
			local order = tonumber(item.HeldOrder) or 0
			if order > fallbackOrder then
				fallback, fallbackAt, fallbackOrder = item, index, order
			end
		end
	end
	return fallback, fallbackAt
end

--- Every held item, oldest pickup first - index N+1 in this list IS hand-slot
--- N+1. Shared by `equip` (server) and, in spirit, HotbarController (client,
--- which sorts the same field out of the ordinary InventoryPush payload).
local function heldInOrder(profile: DataService.Profile): { DataService.DisplayItem }
	local held: { DataService.DisplayItem } = {}
	for _, item in profile.Inventory do
		if item.Held then
			table.insert(held, item)
		end
	end
	table.sort(held, function(a, b)
		return (tonumber(a.HeldOrder) or 0) < (tonumber(b.HeldOrder) or 0)
	end)
	return held
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

	primary.CFrame = root.CFrame * HoldConfig.HELD_OFFSET
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

	local heldCount, highestOrder = 0, 0
	for _, item in profile.Inventory do
		if item.Held then
			heldCount += 1
			highestOrder = math.max(highestOrder, tonumber(item.HeldOrder) or 0)
		end
	end
	if heldCount >= HoldConfig.MAX_HELD_ITEMS then
		return false, "Hands full - place something first."
	end
	if #profile.Inventory >= StorageConfig.capacityForTier(profile.StorageTier) then
		return false, "Storage full - sell something first."
	end

	table.remove(profile.DisplayItems, foundAt)
	found.SlotIndex = 0
	found.Held = true
	found.HeldOrder = highestOrder + 1
	-- "You begin showing the newest item you picked up": every other held
	-- item loses the active flag, this one gets it.
	for _, item in profile.Inventory do
		if item.Held then
			item.HeldActive = nil
		end
	end
	found.HeldActive = true
	table.insert(profile.Inventory, found)

	-- Redraws the now-empty pad, refreshes every prompt on the base (that pad
	-- can now show "Place"; nothing else on the base changed) and, through
	-- BaseService.onRebuilt, calls HoldService.refreshHeldVisual for us.
	BaseService.rebuildSlot(player, slotIndex)
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	local def = LootConfig.ById[found.ItemId]
	notify(player, "success", `Picked up {if def then def.name else found.ItemId}`)
	StateService.sound(player, "StoredItem")

	AnalyticsEvents.custom(player, "ItemPickedUp", 1, { found.Rarity, `n{heldCount + 1}` })

	return true
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
		return false, "You are not holding anything."
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

	-- Whichever remaining held item was picked up most recently becomes the
	-- new active one - same "newest" rule a fresh pickup uses.
	local newest, newestOrder = nil, -1
	for _, item in profile.Inventory do
		if item.Held then
			local order = tonumber(item.HeldOrder) or 0
			if order > newestOrder then
				newest, newestOrder = item, order
			end
		end
	end
	if newest then
		newest.HeldActive = true
	end

	BaseService.rebuildSlot(player, slotIndex)
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	local def = LootConfig.ById[active.ItemId]
	notify(
		player,
		"success",
		`PLACED  {if def then def.name else active.ItemId}  +{NumberFormat.income(active.FinalIncome)}`
	)
	StateService.sound(player, "PlaceItem")

	AnalyticsEvents.custom(player, "ItemPlaced", 1, { active.Rarity })

	return true
end

-- ==========================================================
-- EQUIP (switch which held item is shown)
-- ==========================================================

--- Makes the held item at hand-slot `rank` (1..HoldConfig.MAX_HELD_ITEMS, by
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
		-- Already the one shown - idempotent, not an error.
		return true
	end
	for _, item in held do
		item.HeldActive = nil
	end
	target.HeldActive = true

	HoldService.refreshHeldVisual(player)
	StateService.pushNow(player)
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
	BaseService.onRebuilt(function(player)
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
	local function onCharacter(player: Player, character: Model)
		task.defer(function()
			character:WaitForChild("HumanoidRootPart", 5)
			if character.Parent then
				HoldService.refreshHeldVisual(player)
			end
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
		holdLimiter:release(player)
	end)
end

return HoldService
