--!strict
--[[
	HeistService
	Player-to-player base stealing: walk up to another player's trophy, hold
	E, pay the rarity's Developer Product, then ESCAPE with it and deposit it
	on your own display. The theft is only permanent once it is deposited.

	THE ONE RULE EVERYTHING BELOW SERVES: a Robux receipt is never consumed
	without delivering exactly the item it paid for, and an item is never in
	two profiles at once.

	  * The hold RESERVES the exact item (by InstanceId) before the prompt
	    opens. While reserved its owner cannot store or move it, and nobody
	    else can reserve it. Cancelling the prompt releases it.
	  * The receipt arrives in MarketplaceService.ProcessReceipt
	    (MonetizationService routes `kind == "Steal"` here). `fulfil` re-checks
	    the target - same owner, same InstanceId, same rarity as the product
	    - and only then flags the item RobbedBy and puts a live copy in the
	    thief's hands. If the target is gone the receipt is left OPEN
	    (NotProcessedYet) and Roblox retries; it is never swapped for another
	    item, another rarity, or nothing. A reservation is also written to
	    the buyer's profile (PendingSteal) so a receipt that lands after a
	    rejoin can still be matched.
	  * While carried, the item STAYS IN THE VICTIM'S PROFILE, flagged. It
	    earns nothing for anyone and its slot shows as robbed. Drop, death,
	    reset, disconnect, a trap, a bat, or the victim's Guardian all return
	    it: the flag clears and the display rebuilds. Nothing is ever cloned,
	    reconstructed from a name, or left on the floor for a third party.
	  * Deposit (PlacementService.place -> deposit) is the transfer: the SAME
	    saved record moves from the victim's DisplayItems to the thief's,
	    protected for HeistConfig.PROTECTION_SECONDS, and both incomes are
	    recalculated once. Never a duplicate, never double income.

	THE VICTIM LEAVING MID-ROBBERY. Their profile is about to be saved, and a
	robbery cannot be resolved into an offline save. The item is lifted OUT
	of their profile before that save (init wires `onPlayerLeaving` ahead of
	DataService's own save) and rides with the pending robbery: a deposit
	places it as normal, and a failed escape puts it in the thief's Storage
	rather than deleting it. A player who leaves during a paid robbery loses
	the item exactly as they would have if the thief had escaped; the thief,
	who paid, never loses it to a disconnect they did not cause.

	Robux cannot be refunded from a script. That is why every path above
	either delivers or leaves the receipt open - and why the reservation
	exists at all.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HeistConfig = require(ReplicatedStorage.Shared.Config.HeistConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local MutationVfx = require(ReplicatedStorage.Shared.Util.MutationVfx)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local SizeAura = require(ReplicatedStorage.Shared.Util.SizeAura)

local BaseGuardianService = require(script.Parent.BaseGuardianService)
local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local IndexService = require(script.Parent.IndexService)
local LootService = require(script.Parent.LootService)
local MonetizationService = require(script.Parent.MonetizationService)
local StateService = require(script.Parent.StateService)

local HeistService = {}

local PROMPT_NAME = "RobPrompt"

export type Pending = {
	buyer: Player,
	ownerUserId: number,
	ownerName: string,
	instanceId: string,
	slotIndex: number,
	rarity: string,
	itemName: string,
	productId: number,
	productKey: string,
	createdAt: number,
	state: "Prompted" | "Carried" | "Done",
	loot: LootService.LootInstance?,
	--- The item record itself once the victim has left mid-robbery: lifted
	--- out of their profile before their save, it now has no home but the
	--- thief's (deposit, or Storage on a failed escape).
	orphan: DataService.DisplayItem?,
	--- Why the carry ended, set by whoever ends it before the loss callback.
	lostReason: string?,
}

local pendingByBuyer: { [Player]: Pending } = {}
local reservedByInstance: { [string]: Pending } = {}
--- Victim UserId -> os.clock of their last successful robbery.
local lastRobbedAt: { [number]: number } = {}
local lastBeginAt: { [Player]: number } = {}

-- ==========================================================
-- HELPERS
-- ==========================================================

local function notify(player: Player, kind: string, message: string, detail: string?)
	if player.Parent then
		StateService.notify(player, kind, message, detail)
	end
end

local function nameOf(item: DataService.DisplayItem): string
	local def = LootConfig.ById[item.ItemId]
	return if def then def.name else item.ItemId
end

local function findItem(profile: DataService.Profile, instanceId: string): (DataService.DisplayItem?, number?)
	for index, item in profile.DisplayItems do
		if item.InstanceId == instanceId then
			return item, index
		end
	end
	return nil, nil
end

local function productFor(item: DataService.DisplayItem): MonetizationConfig.ProductDef?
	return MonetizationConfig.StealProductByRarity[RarityConfig.normaliseRarity(item.Rarity)]
end

--- The price a prompt shows: the live one from Roblox, else the row's own.
local function priceFor(product: MonetizationConfig.ProductDef): number
	return MonetizationService.liveProductPrice(product.productId) or product.robux
end

local function robux(amount: number): string
	return `R${amount}`
end

local function formatRemaining(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	if total >= 60 then
		return `{total // 60}m {total % 60}s`
	end
	return `{total}s`
end

--- Frees the live reservation. Leaves the buyer's saved PendingSteal alone:
--- callers that KNOW the purchase did not happen clear that themselves.
local function releaseLive(pending: Pending)
	if pendingByBuyer[pending.buyer] == pending then
		pendingByBuyer[pending.buyer] = nil
	end
	if reservedByInstance[pending.instanceId] == pending then
		reservedByInstance[pending.instanceId] = nil
	end
end

--- Frees everything, saved reservation included.
local function release(pending: Pending)
	releaseLive(pending)
	local profile = DataService.get(pending.buyer)
	if profile and type(profile.PendingSteal) == "table" and profile.PendingSteal.instanceId == pending.instanceId then
		profile.PendingSteal = nil
	end
end

local function compact(pending: Pending): any
	return {
		ownerUserId = pending.ownerUserId,
		ownerName = pending.ownerName,
		instanceId = pending.instanceId,
		slotIndex = pending.slotIndex,
		rarity = pending.rarity,
		itemName = pending.itemName,
		productId = pending.productId,
		productKey = pending.productKey,
		createdAt = os.time(),
	}
end

function HeistService.isReserved(instanceId: string): boolean
	return reservedByInstance[instanceId] ~= nil
end

-- ==========================================================
-- PROMPTS
-- ==========================================================
--
-- One RobPrompt per occupied slot on every owned plot, created disabled: the
-- CLIENT (RobPromptController) switches it on for everyone but the owner,
-- and off again while the item is protected. The server never trusts that -
-- `begin` re-checks every rule - so this is presentation, and the owner's
-- own SlotPrompt on the same pad is untouched.

local function dressPrompt(prompt: ProximityPrompt, item: DataService.DisplayItem, product: MonetizationConfig.ProductDef)
	prompt.ActionText = `STEAL FOR {robux(priceFor(product))}`
	prompt.ObjectText = nameOf(item)
	prompt:SetAttribute("InstanceId", item.InstanceId)
	prompt:SetAttribute("ProtectedUntil", tonumber(item.ProtectedUntil) or 0)
	prompt:SetAttribute("Price", priceFor(product))
	prompt:SetAttribute("Rarity", item.Rarity)
end

--- Rebuilds the steal prompts on `owner`'s plot from their profile. Called
--- after every display rebuild, so a placed, stored or stolen item is
--- reflected at once.
function HeistService.refreshPrompts(owner: Player)
	local plot = BaseService.getPlot(owner)
	local profile = DataService.get(owner)
	if not plot or not profile then
		return
	end
	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return
	end

	local occupied: { [number]: DataService.DisplayItem } = {}
	for _, item in profile.DisplayItems do
		occupied[item.SlotIndex] = item
	end

	for _, slot in slots:GetChildren() do
		if not slot:IsA("BasePart") then
			continue
		end
		local index = slot:GetAttribute("SlotIndex")
		local item = if type(index) == "number" then occupied[index] else nil
		-- A SEALED CONTAINER IS NOT ROBBABLE, and gets no prompt. This is a
		-- privacy rule before it is a gameplay one: dressPrompt writes the
		-- item's name into ObjectText and its rarity and Robux price into
		-- replicated attributes, so a prompt on an unhatched container would
		-- announce the reward to every client in range - including the
		-- owner's, defeating the whole point of the hatch.
		local sealed = item ~= nil and item.Hatched == false
		local product = if item and not item.RobbedBy and not sealed then productFor(item) else nil
		local existing = slot:FindFirstChild(PROMPT_NAME)

		if item and product then
			local prompt: ProximityPrompt
			if existing and existing:IsA("ProximityPrompt") then
				prompt = existing
			else
				if existing then
					existing:Destroy()
				end
				prompt = Instance.new("ProximityPrompt")
				prompt.Name = PROMPT_NAME
				prompt.HoldDuration = HeistConfig.HOLD_SECONDS
				prompt.MaxActivationDistance = HeistConfig.PROMPT_RANGE
				prompt.RequiresLineOfSight = false
				prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
				-- Off until a client that is not the owner turns it on.
				prompt.Enabled = false
				prompt.Parent = slot
			end
			dressPrompt(prompt, item, product)
		elseif existing then
			existing:Destroy()
		end
	end
end

--- Re-texts every prompt in the server. Called when live prices refresh.
function HeistService.retextPrompts()
	for _, player in Players:GetPlayers() do
		if BaseService.getPlot(player) then
			HeistService.refreshPrompts(player)
		end
	end
end

-- ==========================================================
-- BEGIN: the hold completed
-- ==========================================================

function HeistService.begin(player: Player, slot: BasePart)
	local now = os.clock()
	if now - (lastBeginAt[player] or 0) < HeistConfig.BEGIN_COOLDOWN then
		return
	end
	lastBeginAt[player] = now

	local slots = slot.Parent
	local plot = slots and slots.Parent
	if not plot then
		return
	end

	local owner = BaseService.getOwner(plot)
	if not owner then
		notify(player, "error", "Nobody owns that base.")
		return
	end
	if owner == player then
		notify(player, "error", "You can't steal your own item!")
		return
	end

	local profile = DataService.get(player)
	if not profile then
		notify(player, "error", "Your data is still loading.")
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		notify(player, "error", "You cannot steal right now.")
		return
	end
	if (root.Position - slot.Position).Magnitude > HeistConfig.PROMPT_RANGE * 1.8 then
		notify(player, "error", "Too far away.")
		return
	end

	if CarryService.getCarried(player) then
		notify(player, "error", "You're already carrying an item!")
		return
	end
	if BaseService.isFull(player) then
		notify(player, "error", "BASE FULL - store or sell something before you steal!")
		return
	end

	local existing = pendingByBuyer[player]
	if existing then
		if existing.state == "Carried" then
			notify(player, "error", "You're already carrying an item!")
			return
		end
		-- A prompt they never answered: a fresh hold supersedes it.
		release(existing)
	end

	local victimProfile = DataService.get(owner)
	if not victimProfile then
		notify(player, "error", "That player is still loading.")
		return
	end

	local index = slot:GetAttribute("SlotIndex")
	local item: DataService.DisplayItem? = nil
	for _, candidate in victimProfile.DisplayItems do
		if candidate.SlotIndex == index then
			item = candidate
			break
		end
	end
	if not item then
		notify(player, "error", "There's nothing on that slot.")
		return
	end
	local target = item :: DataService.DisplayItem

	if target.RobbedBy or reservedByInstance[target.InstanceId] then
		notify(player, "error", "Someone is already stealing that!")
		return
	end
	-- The prompt above is presentation and a client decides nothing, so the
	-- sealed rule is re-checked on the authoritative side too.
	if target.Hatched == false then
		notify(player, "error", "That one has not been revealed yet!")
		return
	end
	local protectedUntil = tonumber(target.ProtectedUntil) or 0
	if protectedUntil > os.time() then
		notify(player, "error", `That item is protected for {formatRemaining(protectedUntil - os.time())}!`)
		return
	end
	local robbedAt = lastRobbedAt[owner.UserId]
	if robbedAt and now - robbedAt < HeistConfig.ROBBERY_COOLDOWN then
		notify(player, "error", `That base was just robbed - try again in {formatRemaining(HeistConfig.ROBBERY_COOLDOWN - (now - robbedAt))}.`)
		return
	end

	-- The product comes from the REAL item's rarity, never from the client.
	local product = productFor(target)
	if not product or product.productId <= 0 then
		notify(player, "error", "That item can't be stolen right now.")
		return
	end

	local pending: Pending = {
		buyer = player,
		ownerUserId = owner.UserId,
		ownerName = owner.Name,
		instanceId = target.InstanceId,
		slotIndex = target.SlotIndex,
		rarity = RarityConfig.normaliseRarity(target.Rarity),
		itemName = nameOf(target),
		productId = product.productId,
		productKey = product.key,
		createdAt = now,
		state = "Prompted",
	}
	pendingByBuyer[player] = pending
	reservedByInstance[target.InstanceId] = pending
	profile.PendingSteal = compact(pending)

	notify(player, "info", `STEAL STARTED - pay, then ESCAPE and deposit the {pending.itemName} at YOUR base!`)

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, product.productId)
	end)
	if not ok then
		warn(`[HeistService] PromptProductPurchase failed for {player.Name}: {err}`)
		release(pending)
		notify(player, "error", "Could not open the purchase.")
		return
	end

	-- A prompt nobody answers must not lock the item forever. Only the LIVE
	-- reservation lapses; the saved one stays so a slow receipt still matches.
	task.delay(HeistConfig.RESERVATION_TIMEOUT, function()
		if pendingByBuyer[player] == pending and pending.state == "Prompted" then
			releaseLive(pending)
		end
	end)
end

--- MarketplaceService.PromptProductPurchaseFinished, via MonetizationService.
--- NOTHING IS GRANTED HERE. A closed dialog with `purchased == false` is the
--- one thing this event is trusted for: the player backed out, so the item
--- is released for its owner to move again. `purchased == true` is ignored
--- entirely; ProcessReceipt is the only authority for delivery.
function HeistService.onPromptClosed(player: Player, productId: number, purchased: boolean)
	local pending = pendingByBuyer[player]
	if not pending or pending.state ~= "Prompted" or pending.productId ~= productId then
		return
	end
	if purchased then
		return
	end
	release(pending)
	notify(player, "info", "Purchase cancelled - the item stays where it is.")
end

-- ==========================================================
-- FULFIL: the receipt landed
-- ==========================================================

--- A receipt with no live reservation (the server restarted, or the buyer
--- rejoined) is matched through the reservation saved on their profile, if
--- the victim and the very same item are here to be stolen from.
local function restore(player: Player, profile: DataService.Profile, product: MonetizationConfig.ProductDef): Pending?
	local saved = profile.PendingSteal
	if type(saved) ~= "table" or saved.productId ~= product.productId or type(saved.instanceId) ~= "string" then
		return nil
	end
	local victim = Players:GetPlayerByUserId(tonumber(saved.ownerUserId) or 0)
	local victimProfile = if victim then DataService.get(victim) else nil
	if not victim or not victimProfile then
		return nil
	end
	local item = findItem(victimProfile, saved.instanceId)
	if not item or item.RobbedBy or reservedByInstance[item.InstanceId] then
		return nil
	end
	local pending: Pending = {
		buyer = player,
		ownerUserId = victim.UserId,
		ownerName = victim.Name,
		instanceId = item.InstanceId,
		slotIndex = item.SlotIndex,
		rarity = RarityConfig.normaliseRarity(item.Rarity),
		itemName = nameOf(item),
		productId = product.productId,
		productKey = product.key,
		createdAt = os.clock(),
		state = "Prompted",
	}
	pendingByBuyer[player] = pending
	reservedByInstance[item.InstanceId] = pending
	return pending
end

--- The carried copy of the victim's trophy: the real art at the item's own
--- saved scale, mutation and size aura - everything the trophy showed, so
--- what the thief runs off with is visibly the thing that was on the pad.
local function buildLoot(pending: Pending, item: DataService.DisplayItem): LootService.LootInstance
	-- The item's DISPLAY scale (its legacy look if it has one, else its
	-- Scale): the thief carries exactly what stood on the pad.
	local visual = BaseService.displayScale(item)
	local scale = ScaleConfig.clampScale(item.Scale)
	local model = LootModel.build({
		itemId = item.ItemId,
		rarity = item.Rarity,
		targetHeight = GameConfig.LOOT_WORLD_HEIGHT,
		sizeScale = visual,
		maxFootprint = LootModel.WORLD_MAX_FOOTPRINT,
		placeholderSize = Vector3.new(6, 7, 6),
	})
	MutationVfx.apply(model, item.Mutation)
	SizeAura.apply(model, item.Size)
	model:SetAttribute("HeistInstanceId", item.InstanceId)
	model:SetAttribute("ItemId", item.ItemId)
	model:SetAttribute("Rarity", item.Rarity)
	model:SetAttribute("VisualScale", visual)
	model:SetAttribute("Scale", scale)
	model:SetAttribute("Size", item.Size)
	model:SetAttribute("Mutation", item.Mutation)
	model.Parent = workspace

	local loot: LootService.LootInstance = {
		id = "heist:" .. item.InstanceId,
		itemId = item.ItemId,
		name = nameOf(item),
		zoneIndex = 0,
		socketIndex = 0,
		rarity = item.Rarity,
		size = item.Size,
		mutation = item.Mutation,
		baseIncome = item.BaseIncome,
		finalIncome = item.FinalIncome,
		scale = scale,
		visualScale = visual,
		state = "Spawned",
		interactRange = GameConfig.STEAL_INTERACTION_RANGE,
		model = model,
		heist = true,
	}
	loot.onLost = function(reason: string)
		HeistService.fail(pending, pending.lostReason or reason)
	end
	return loot
end

--- Called by MonetizationService.processReceipt for every `kind == "Steal"`
--- product. Returns true only when the item is in the buyer's hands; false
--- leaves the receipt OPEN for Roblox to retry.
function HeistService.fulfil(player: Player, profile: DataService.Profile, product: MonetizationConfig.ProductDef, purchaseId: string): boolean
	local pending = pendingByBuyer[player]
	if not pending or pending.state ~= "Prompted" or pending.productId ~= product.productId then
		pending = restore(player, profile, product)
	end
	if not pending then
		warn(`[HeistService] receipt {purchaseId} ({product.key}) from {player.Name} matches no reserved item - left OPEN`)
		return false
	end

	local victim = Players:GetPlayerByUserId(pending.ownerUserId)
	local victimProfile = if victim then DataService.get(victim) else nil
	local item = if victimProfile then findItem(victimProfile, pending.instanceId) else nil
	if not victim or not victimProfile or not item or item.RobbedBy then
		warn(`[HeistService] receipt {purchaseId}: target {pending.itemName} of {pending.ownerName} is not available - left OPEN`)
		return false
	end
	local target = item :: DataService.DisplayItem
	-- Exactly the rarity that was paid for, or nothing.
	if RarityConfig.normaliseRarity(target.Rarity) ~= product.rarity then
		warn(`[HeistService] receipt {purchaseId}: {pending.itemName} is {target.Rarity}, product is {product.rarity} - left OPEN`)
		return false
	end
	if CarryService.getCarried(player) then
		notify(player, "error", "Drop what you're carrying - your paid steal is waiting!")
		return false
	end

	local loot = buildLoot(pending, target)
	if not CarryService.beginCarry(player, loot) then
		local model = loot.model
		if model then
			model:Destroy()
		end
		return false
	end

	target.RobbedBy = player.UserId
	pending.state = "Carried"
	pending.loot = loot
	pending.lostReason = nil
	-- The receipt is being remembered by MonetizationService; the saved
	-- reservation has done its job.
	profile.PendingSteal = nil

	BaseService.rebuildDisplays(victim)
	EconomyService.recalculate(victim)
	StateService.pushNow(victim)
	notify(victim, "error", `{player.DisplayName} IS STEALING YOUR {string.upper(pending.itemName)}!`)
	StateService.sound(victim, "Notification")

	-- The victim's own Guardian goes after them immediately.
	BaseGuardianService.hunt(victim, player)

	notify(player, "success", `STOLEN! Escape and deposit the {pending.itemName} at your base!`)
	return true
end

-- ==========================================================
-- LOSS: the item goes home
-- ==========================================================

function HeistService.fail(pending: Pending, reason: string)
	if pending.state ~= "Carried" then
		return
	end
	pending.state = "Done"

	local loot = pending.loot
	local model = if loot then loot.model else nil
	if model then
		model:Destroy()
	end
	if loot then
		loot.model = nil
	end

	local buyer = pending.buyer
	local name = pending.itemName
	local victim = Players:GetPlayerByUserId(pending.ownerUserId)
	local victimProfile = if victim then DataService.get(victim) else nil
	local item = if victimProfile then findItem(victimProfile, pending.instanceId) else nil

	local returned = false
	if victim and victimProfile and item then
		item.RobbedBy = nil
		BaseService.rebuildDisplays(victim)
		EconomyService.recalculate(victim)
		StateService.pushNow(victim)
		notify(victim, "success", `Your {name} is safe!`)
		returned = true
	elseif pending.orphan then
		-- The owner left during the robbery: the item has no other home.
		local orphan = pending.orphan :: DataService.DisplayItem
		local profile = DataService.get(buyer)
		if profile then
			orphan.RobbedBy = nil
			orphan.SlotIndex = 0
			table.insert(profile.Inventory, orphan)
			StateService.pushNow(buyer)
			notify(buyer, "info", `The {name} went to your Storage - its owner left.`)
		end
	end

	release(pending)
	BaseGuardianService.stopHunt(buyer)

	if returned and buyer.Parent then
		local message = if reason == "caught"
			then `The Guardian caught you! The {name} went back.`
			elseif reason == "dropped" then `You dropped the {name} - it went back to its owner.`
			else `The {name} returned to its owner.`
		notify(buyer, "error", message)
	end
end

--- The victim's base guardian landed a hit on a thief carrying their item.
function HeistService.onIntruderCaught(intruder: Player, ownerUserId: number)
	local pending = pendingByBuyer[intruder]
	if pending and pending.state == "Carried" and pending.ownerUserId == ownerUserId and pending.loot then
		pending.lostReason = "caught"
		CarryService.forceDrop(pending.loot)
	end
end

-- ==========================================================
-- DEPOSIT: the transfer
-- ==========================================================

--- From PlacementService.place, after it has checked the thief is home, the
--- slot is unlocked and the slot is empty. Moves the saved record.
function HeistService.deposit(player: Player, loot: LootService.LootInstance, slotIndex: number): (boolean, string?)
	local pending = pendingByBuyer[player]
	if not pending or pending.state ~= "Carried" or pending.loot ~= loot then
		return false, "That item can't be placed."
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local victim = Players:GetPlayerByUserId(pending.ownerUserId)
	local victimProfile = if victim then DataService.get(victim) else nil
	local record: DataService.DisplayItem? = nil
	if victimProfile then
		local item, index = findItem(victimProfile, pending.instanceId)
		if item and index then
			table.remove(victimProfile.DisplayItems, index)
			record = item
		end
	end
	if not record then
		record = pending.orphan
	end
	if not record then
		return false, "That item is gone."
	end
	local moved = record :: DataService.DisplayItem

	pending.state = "Done"
	local model = loot.model
	if model then
		model:Destroy()
	end
	loot.model = nil
	CarryService.consumeCarry(player)

	-- The SAME record: identity, size, mutation, scale and growth all travel.
	moved.RobbedBy = nil
	moved.SlotIndex = slotIndex
	moved.ProtectedUntil = os.time() + HeistConfig.PROTECTION_SECONDS
	table.insert(profile.DisplayItems, moved)

	local firstTime = not profile.Index[moved.ItemId]
	profile.Index[moved.ItemId] = true
	profile.Lifetime.PvPSteals += 1

	release(pending)
	BaseGuardianService.stopHunt(player)
	lastRobbedAt[pending.ownerUserId] = os.clock()

	BaseService.rebuildDisplays(player)
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	if victim and victimProfile then
		BaseService.rebuildDisplays(victim)
		EconomyService.recalculate(victim)
		StateService.pushNow(victim)
		notify(victim, "error", `{player.DisplayName} STOLE YOUR {string.upper(pending.itemName)}!`)
		if DataService.isPersistent() then
			task.spawn(DataService.save, victim)
		end
	end

	notify(
		player,
		"success",
		`DEPOSITED  {pending.itemName}  +{NumberFormat.income(moved.FinalIncome)}  ·  protected {HeistConfig.PROTECTION_SECONDS // 60}m`,
		"levelup"
	)
	StateService.sound(player, "Escape")
	if firstTime then
		IndexService.onDiscovered(player, moved.ItemId)
	end
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return true
end

-- ==========================================================
-- LEAVING
-- ==========================================================

--- Wired by init BEFORE DataService's own PlayerRemoving handler, so both
--- profiles below are still in memory and still about to be saved.
function HeistService.onPlayerLeaving(player: Player)
	-- As the thief: whatever they carried goes back (or, if its owner already
	-- left, into their Storage) before their profile is written.
	local mine = pendingByBuyer[player]
	if mine then
		if mine.state == "Carried" then
			mine.lostReason = "released"
			CarryService.releaseCarry(player)
		elseif mine.state == "Prompted" then
			-- The saved reservation stays: a paid receipt may still land after
			-- a rejoin. Only the live lock on the item is lifted.
			releaseLive(mine)
		end
	end

	-- As the victim: an item mid-robbery leaves with the robbery, not with
	-- the save (see the header).
	for buyer, pending in pendingByBuyer do
		if pending.ownerUserId ~= player.UserId then
			continue
		end
		if pending.state == "Carried" then
			local profile = DataService.get(player)
			if profile then
				local item, index = findItem(profile, pending.instanceId)
				if item and index then
					table.remove(profile.DisplayItems, index)
					pending.orphan = item
				end
			end
			notify(buyer, "info", `{player.DisplayName} left - deposit the {pending.itemName} to keep it!`)
		elseif pending.state == "Prompted" then
			releaseLive(pending)
		end
	end

	lastBeginAt[player] = nil
end

-- ==========================================================
-- DEBUG
-- ==========================================================

function HeistService.snapshot(player: Player): { [string]: any }
	local pending = pendingByBuyer[player]
	local reserved = 0
	for _ in reservedByInstance do
		reserved += 1
	end
	return {
		pending = if pending
			then { state = pending.state, item = pending.itemName, owner = pending.ownerName, product = pending.productKey, orphan = pending.orphan ~= nil }
			else nil,
		reservedItems = reserved,
	}
end

-- ==========================================================
-- START
-- ==========================================================

function HeistService.start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name ~= PROMPT_NAME then
			return
		end
		local slot = prompt.Parent
		if slot and slot:IsA("BasePart") then
			HeistService.begin(player, slot)
		end
	end)

	-- Prompts follow the displays: every rebuild (place, store, steal,
	-- return, capacity) re-derives them from the profile.
	BaseService.onRebuilt(function(player)
		HeistService.refreshPrompts(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastBeginAt[player] = nil
	end)

	print(`[HeistService] base stealing online - {#MonetizationConfig.StealProducts} rarities priced by Roblox`)
end

return HeistService
