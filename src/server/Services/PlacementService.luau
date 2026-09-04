--!strict
--[[
	PlacementService
	Turning a carried item into a permanent base trophy, selling one back, and
	buying display capacity (GDD sections 8 and 11).

	Placement is always a deliberate player action. Reaching your safe zone makes
	the item safe; it never auto-places (GDD tutorial step T4).

	Every entry point is validated server-side and is reachable from BOTH a
	ProximityPrompt (which gives desktop/mobile/gamepad input for free) and the
	matching RemoteEvent, so the eventual UI needs no new server code.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local LootService = require(script.Parent.LootService)
local StateService = require(script.Parent.StateService)

local PlacementService = {}

local placeLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.PlaceLootRequest)
local sellLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.SellLootRequest)
local upgradeLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.BaseUpgradeRequest)

local function notify(player: Player, kind: string, message: string)
	StateService.notify(player, kind, message)
end

-- ==========================================================
-- PLACE
-- ==========================================================

--- Places the carried item into `slotIndex`. Returns false plus a reason.
function PlacementService.place(player: Player, slotIndex: number): (boolean, string?)
	if not placeLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local loot = CarryService.getCarried(player)
	if not loot then
		return false, "You are not carrying anything."
	end

	-- Must be home. The safe zone is what makes a steal a success.
	if not BaseService.isInOwnSafeZone(player) then
		return false, "Get back to your base first!"
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

	-- Size and mutation were rolled when the item spawned and are never
	-- rerolled here; income is simply carried across.
	table.insert(profile.DisplayItems, {
		InstanceId = HttpService:GenerateGUID(false),
		ItemId = loot.itemId,
		ZoneId = loot.zoneIndex,
		Rarity = loot.rarity,
		Size = loot.size,
		Mutation = loot.mutation,
		BaseIncome = loot.baseIncome,
		FinalIncome = loot.finalIncome,
		SlotIndex = slotIndex,
	})

	-- Discovery fires only on a successful placement (GDD section 13).
	local firstTime = not profile.Index[loot.itemId]
	profile.Index[loot.itemId] = true
	if loot.rarity == "Secret" then
		profile.Lifetime.Secrets += 1
	end
	if loot.zoneIndex > profile.HighestZoneReached then
		profile.HighestZoneReached = loot.zoneIndex
	end

	-- Hand the world instance over: this clears the carry and refills the socket.
	CarryService.consumeCarry(player)
	LootService.consume(loot)

	BaseService.rebuildDisplays(player)
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	notify(
		player,
		"success",
		`Placed {loot.name} · +{NumberFormat.income(loot.finalIncome)}` .. (if firstTime then "  (NEW!)" else "")
	)
	return true
end

-- ==========================================================
-- SELL
-- ==========================================================

--- Sells the trophy in `slotIndex` for SELL_REFUND_SECONDS of its income.
function PlacementService.sell(player: Player, slotIndex: number): (boolean, string?)
	if not sellLimiter:consume(player) then
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
		return false, "Nothing to sell there."
	end

	-- Server calculates the payout; the client never supplies a value.
	local payout = math.floor(found.FinalIncome * GameConfig.SELL_REFUND_SECONDS)
	local def = LootConfig.ById[found.ItemId]
	local displayName = if def then def.name else found.ItemId

	table.remove(profile.DisplayItems, foundAt)

	-- Index discovery survives a sale (GDD section 13).
	EconomyService.award(player, payout)
	BaseService.rebuildDisplays(player)
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	notify(player, "success", `Sold {displayName} for {NumberFormat.cash(payout)}`)
	return true
end

-- ==========================================================
-- CAPACITY
-- ==========================================================

function PlacementService.upgradeCapacity(player: Player): (boolean, string?)
	if not upgradeLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	if not profile.BaseActivated then
		return false, "Activate your base first."
	end

	local next = BaseConfig.nextUpgrade(profile.BaseCapacityTier)
	if not next then
		return false, "Your base is fully upgraded!"
	end

	-- Atomic: spend first, and only grant if the spend actually succeeded.
	if not EconomyService.spend(player, next.cost) then
		return false, `You need {NumberFormat.cash(next.cost)}.`
	end

	profile.BaseCapacityTier = next.tier
	BaseService.rebuildDisplays(player)
	PlacementService.refreshPrompts(player)
	StateService.pushNow(player)

	notify(player, "success", `Base upgraded — {next.slots} display slots!`)
	return true
end

-- ==========================================================
-- PROMPTS
-- ==========================================================

--- Keeps each slot's prompt in step with capacity and occupancy.
function PlacementService.refreshPrompts(player: Player)
	local plot = BaseService.getPlot(player)
	if not plot then
		return
	end
	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return
	end

	local unlocked = BaseService.unlockedSlots(player)

	for _, slot in slots:GetChildren() do
		local index = slot:GetAttribute("SlotIndex") :: number?
		if not index or not slot:IsA("BasePart") then
			continue
		end

		local prompt = slot:FindFirstChild("SlotPrompt") :: ProximityPrompt?
		if not prompt then
			local created = Instance.new("ProximityPrompt")
			created.Name = "SlotPrompt"
			created.MaxActivationDistance = 12
			created.RequiresLineOfSight = false
			-- Hidden by default. BasePromptController turns it on for the owner
			-- only; the server never touches Enabled again, so the two cannot
			-- fight over the property.
			created.Enabled = false
			created.Parent = slot
			prompt = created
		end

		local occupied = slot:FindFirstChild("Trophy") ~= nil
		local p = prompt :: ProximityPrompt
		p:SetAttribute("ServerEnabled", index <= unlocked)
		p.ActionText = if occupied then "Sell" else "Place"
		p.ObjectText = `Slot {index}`
		p.HoldDuration = if occupied then 0.6 else 0
	end
end

-- ==========================================================
-- START
-- ==========================================================

function PlacementService.start()
	BaseService.onRebuilt(function(player)
		PlacementService.refreshPrompts(player)
	end)

	-- Capacity pad on every plot. The pads exist in the map already; this just
	-- makes them interactive.
	local bases = workspace:WaitForChild("Map", 20):WaitForChild("Bases", 10)
	for _, plot in bases:GetChildren() do
		local pad = plot:FindFirstChild("BaseUpgradePad")
		if pad and pad:IsA("BasePart") and not pad:FindFirstChild("UpgradePrompt") then
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "UpgradePrompt"
			prompt.ActionText = "Upgrade Base"
			prompt.ObjectText = "Display Slots"
			prompt.HoldDuration = 0.5
			prompt.MaxActivationDistance = 12
			prompt.RequiresLineOfSight = false
			prompt.Enabled = false -- owner-only, enabled client-side
			prompt:SetAttribute("ServerEnabled", true)
			prompt.Parent = pad
		end
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name == "UpgradePrompt" then
			local plot = prompt.Parent and prompt.Parent.Parent
			if BaseService.getPlot(player) ~= plot then
				notify(player, "error", "That is not your base.")
				return
			end
			local ok, reason = PlacementService.upgradeCapacity(player)
			if not ok and reason then
				notify(player, "error", reason)
			end
			return
		end

		if prompt.Name ~= "SlotPrompt" then
			return
		end

		local slot = prompt.Parent
		if not slot or not slot:IsA("BasePart") then
			return
		end

		-- Ownership: the prompt lives on a plot, and only its owner may use it.
		local plot = slot.Parent and slot.Parent.Parent
		if not plot or BaseService.getPlot(player) ~= plot then
			notify(player, "error", "That is not your base.")
			return
		end

		local index = slot:GetAttribute("SlotIndex") :: number?
		if not index then
			return
		end

		local occupied = slot:FindFirstChild("Trophy") ~= nil
		local ok, reason = if occupied
			then PlacementService.sell(player, index)
			else PlacementService.place(player, index)

		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	-- Same validated paths, reachable from UI once it exists.
	Remotes.get("PlaceLootRequest").OnServerEvent:Connect(function(player, slotIndex)
		if type(slotIndex) ~= "number" then
			return
		end
		local ok, reason = PlacementService.place(player, math.floor(slotIndex))
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	Remotes.get("SellLootRequest").OnServerEvent:Connect(function(player, slotIndex)
		if type(slotIndex) ~= "number" then
			return
		end
		local ok, reason = PlacementService.sell(player, math.floor(slotIndex))
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	Remotes.get("BaseUpgradeRequest").OnServerEvent:Connect(function(player)
		local ok, reason = PlacementService.upgradeCapacity(player)
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		placeLimiter:release(player)
		sellLimiter:release(player)
		upgradeLimiter:release(player)
	end)
end

return PlacementService
