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
local MapPalette = require(ReplicatedStorage.Shared.MapPalette)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local IndexService = require(script.Parent.IndexService)
local LootService = require(script.Parent.LootService)
local StateService = require(script.Parent.StateService)

local PlacementService = {}

local placeLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.PlaceLootRequest)
local sellLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.SellLootRequest)
local upgradeLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.BaseUpgradeRequest)

local function notify(player: Player, kind: string, message: string, detail: string?)
	StateService.notify(player, kind, message, detail)
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
	-- Lifetime.Secrets is the "I brought home a jackpot" counter. It used to test
	-- for the literal rarity "Secret", which under the current ladder exists in
	-- only four of the twelve zones - so a Cosmic Diamond or a Divine Diamond
	-- Hammer would not have counted. The jackpot flag is the real thing being
	-- measured; the save key keeps its name so existing profiles carry over.
	if loot.jackpot then
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
		`PLACED  {loot.name}  +{NumberFormat.income(loot.finalIncome)}`
			.. (if firstTime then "  (NEW!)" else "")
	)

	-- After the placement toast, so "NEW!" reads before any set-complete banner.
	if firstTime then
		IndexService.onDiscovered(player, loot.itemId)
	end

	return true
end

-- ==========================================================
-- SELL
-- ==========================================================

function PlacementService.storageCapacity(player: Player): number
	local profile = DataService.get(player)
	return if profile then StorageConfig.capacityForTier(profile.StorageTier) else StorageConfig.STARTING_CAPACITY
end

--- Takes a trophy OFF display and into storage. This is what clicking a placed
--- item does: it must never destroy the item. Selling is a separate, deliberate
--- choice made from the inventory panel.
function PlacementService.store(player: Player, slotIndex: number): (boolean, string?)
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
		return false, "Nothing on that slot."
	end

	if #profile.Inventory >= PlacementService.storageCapacity(player) then
		return false, "Storage full - sell something first."
	end

	table.remove(profile.DisplayItems, foundAt)
	found.SlotIndex = 0
	table.insert(profile.Inventory, found)

	BaseService.rebuildDisplays(player)
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	local def = LootConfig.ById[found.ItemId]
	notify(player, "info", `Stored {if def then def.name else found.ItemId}`)
	return true
end

--- Puts a stored item back onto the first free display slot.
function PlacementService.equip(player: Player, instanceId: string): (boolean, string?)
	if not placeLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local free = BaseService.freeSlots(player)
	if #free == 0 then
		return false, "No free display slots."
	end

	for index, item in profile.Inventory do
		if item.InstanceId == instanceId then
			table.remove(profile.Inventory, index)
			item.SlotIndex = free[1]
			table.insert(profile.DisplayItems, item)

			BaseService.rebuildDisplays(player)
			EconomyService.recalculate(player)
			StateService.pushNow(player)

			local def = LootConfig.ById[item.ItemId]
			-- Name AND the income it just started earning: placing a trophy is
			-- the payoff beat of the loop, so it should read as a gain.
			notify(
				player,
				"success",
				`PLACED  {if def then def.name else item.ItemId}  +{NumberFormat.income(item.FinalIncome)}`
			)
			return true
		end
	end
	return false, "That item is not in storage."
end

--- Sells a STORED item for SELL_REFUND_SECONDS of its income.
function PlacementService.sellStored(player: Player, instanceId: string): (boolean, string?)
	if not sellLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	for index, item in profile.Inventory do
		if item.InstanceId == instanceId then
			-- Server calculates the payout; the client never supplies a value.
			local payout = math.floor(item.FinalIncome * GameConfig.SELL_REFUND_SECONDS)
			local def = LootConfig.ById[item.ItemId]
			table.remove(profile.Inventory, index)

			-- Index discovery survives a sale (GDD section 13).
			EconomyService.earn(player, payout)
			StateService.pushNow(player)
			notify(
				player,
				"success",
				`Sold {if def then def.name else item.ItemId} for {NumberFormat.cash(payout)}`
			)
			StateService.sound(player, "Sell")
			return true
		end
	end
	return false, "That item is not in storage."
end

function PlacementService.upgradeStorage(player: Player): (boolean, string?)
	if not upgradeLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	local next = StorageConfig.nextUpgrade(profile.StorageTier)
	if not next then
		return false, "Storage is fully upgraded!"
	end
	if not EconomyService.spend(player, next.cost) then
		return false, `You need {NumberFormat.cash(next.cost)}.`
	end

	profile.StorageTier = next.tier
	StateService.pushNow(player)
	notify(player, "success", `Storage upgraded - {next.capacity} slots!`, "levelup")
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
	PlacementService.refreshUpgradeSign(player)
	StateService.pushNow(player)

	notify(player, "success", `Base upgraded — {next.slots} display slots!`, "levelup")
	return true
end

-- ==========================================================
-- THE UPGRADE SIGN
-- ==========================================================
--
-- A chunky physical sign standing on the upgrade pad, rather than text floating
-- over a part:
--
--         UPGRADE BASE          <- white, bold
--       Level 1 > Level 2       <- green progression
--     +---------------------+
--     |  [icon]      $1M    |   <- red purchase panel
--     +---------------------+
--
-- EVERY NUMBER IS READ FROM BaseConfig. There is no hardcoded cost anywhere in
-- here: the level pair and the price come from the same `nextUpgrade` the
-- purchase itself validates against, so the sign cannot advertise a price the
-- server will not honour.
--
-- Built once and then only re-TEXTED. Rebuilding parts on every state push would
-- churn instances under a player standing next to it.

local SIGN_NAME = "UpgradeSign"
local SIGN_WIDTH = 13
local SIGN_HEIGHT = 7.4
local SIGN_DEPTH = 0.9
local SIGN_LIFT = 7.2

--- Which way the sign should face: toward the plot's own spawn point, so it
--- greets a player walking out of their base. Derived rather than assumed,
--- because plots on opposite sides of the plaza face opposite ways.
local function signFacing(plot: Instance, pad: BasePart): CFrame
	local spawn = plot:FindFirstChild("Spawn")
	if spawn and spawn:IsA("BasePart") then
		local toSpawn = spawn.Position - pad.Position
		local flat = Vector3.new(toSpawn.X, 0, toSpawn.Z)
		if flat.Magnitude > 0.5 then
			return CFrame.lookAt(pad.Position, pad.Position + flat.Unit)
		end
	end
	return pad.CFrame
end

local function slab(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function label(parent: Instance, name: string, size: UDim2, pos: UDim2, color: Color3, stroke: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Size = size
	text.Position = pos
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = color
	text.TextStrokeTransparency = 0
	text.TextStrokeColor3 = Color3.fromRGB(12, 16, 32)
	text.ZIndex = stroke
	text.Parent = parent
	return text
end

--- Builds the sign if it is not there yet. Returns its SurfaceGui.
local function ensureSign(plot: Instance, pad: BasePart): SurfaceGui?
	local existing = plot:FindFirstChild(SIGN_NAME)
	if existing then
		local board = existing:FindFirstChild("Board")
		if board and board:IsA("BasePart") then
			-- Baked signs were built by an older `slab` with CanQuery off; the
			-- click layer needs the board to be hittable (see below).
			board.CanQuery = true
		end
		local gui = board and board:FindFirstChildOfClass("SurfaceGui")
		return gui :: SurfaceGui?
	end

	local model = Instance.new("Model")
	model.Name = SIGN_NAME

	local facing = signFacing(plot, pad)
	local base = facing * CFrame.new(0, SIGN_LIFT, 0)

	-- Post, then a dark edge slab, then the navy face a hair in front of it, so
	-- the sign reads as a solid object with a border rather than a decal.
	--
	-- The post stops at the BOARD'S BOTTOM EDGE and does not run up behind it.
	-- Sized to the full lift it passed straight through the red purchase panel
	-- and hid the price, which is the one thing on the sign that has to be
	-- readable.
	local postTop = SIGN_LIFT - SIGN_HEIGHT / 2
	slab("Post", Vector3.new(1.6, postTop, 1.6), facing * CFrame.new(0, postTop / 2, 0), MapPalette.SignPost, model)
	slab("Edge", Vector3.new(SIGN_WIDTH + 0.9, SIGN_HEIGHT + 0.9, SIGN_DEPTH), base, MapPalette.SignEdge, model)
	local board = slab("Board", Vector3.new(SIGN_WIDTH, SIGN_HEIGHT, SIGN_DEPTH + 0.12), base, MapPalette.SignBody, model)
	-- The board is the one sign part that must answer spatial queries: the
	-- client's click layer (BaseSignController) is a SurfaceGui adorned to it,
	-- and a SurfaceGui only receives input when the pointer ray can hit its
	-- part. `slab` turns CanQuery off for decor; this part is a button.
	board.CanQuery = true

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Adornee = board
	gui.Parent = board

	label(gui, "Title", UDim2.fromScale(0.94, 0.26), UDim2.fromScale(0.03, 0.05), MapPalette.SignTitle, 2)
	label(gui, "Progress", UDim2.fromScale(0.94, 0.19), UDim2.fromScale(0.03, 0.32), MapPalette.SignProgress, 2)

	-- The purchase panel, as its own framed block.
	local buttonEdge = Instance.new("Frame")
	buttonEdge.Name = "ButtonEdge"
	buttonEdge.Size = UDim2.fromScale(0.9, 0.35)
	buttonEdge.Position = UDim2.fromScale(0.05, 0.56)
	buttonEdge.BackgroundColor3 = MapPalette.SignButtonEdge
	buttonEdge.BorderSizePixel = 0
	buttonEdge.ZIndex = 2
	buttonEdge.Parent = gui
	local edgeCorner = Instance.new("UICorner")
	edgeCorner.CornerRadius = UDim.new(0, 10)
	edgeCorner.Parent = buttonEdge

	local button = Instance.new("Frame")
	button.Name = "Button"
	button.Size = UDim2.fromScale(0.94, 0.82)
	button.Position = UDim2.fromScale(0.03, 0.09)
	button.BackgroundColor3 = MapPalette.SignButton
	button.BorderSizePixel = 0
	button.ZIndex = 3
	button.Parent = buttonEdge
	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 8)
	buttonCorner.Parent = button

	-- A chunky chevron-up icon, drawn rather than an asset id so it can never
	-- come back "not approved for the requester" the way the lobby music did.
	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.Size = UDim2.fromScale(0.2, 0.8)
	icon.Position = UDim2.fromScale(0.04, 0.1)
	icon.BackgroundTransparency = 1
	icon.Font = Enum.Font.FredokaOne
	icon.TextScaled = true
	icon.Text = "▲"
	icon.TextColor3 = MapPalette.SignButtonText
	icon.TextStrokeTransparency = 0.4
	icon.TextStrokeColor3 = MapPalette.SignButtonEdge
	icon.ZIndex = 4
	icon.Parent = button

	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.Size = UDim2.fromScale(0.7, 0.8)
	price.Position = UDim2.fromScale(0.26, 0.1)
	price.BackgroundTransparency = 1
	price.Font = Enum.Font.FredokaOne
	price.TextScaled = true
	price.TextColor3 = MapPalette.SignButtonText
	price.TextStrokeTransparency = 0.35
	price.TextStrokeColor3 = MapPalette.SignButtonEdge
	price.ZIndex = 4
	price.Parent = button

	model.Parent = plot
	return gui
end

--- Repaints the sign for whatever the player's next upgrade actually is.
function PlacementService.refreshUpgradeSign(player: Player)
	local plot = BaseService.getPlot(player)
	local profile = DataService.get(player)
	if not plot or not profile then
		return
	end
	local pad = plot:FindFirstChild("BaseUpgradePad")
	if not pad or not pad:IsA("BasePart") then
		return
	end

	local gui = ensureSign(plot, pad)
	if not gui then
		return
	end

	local title = gui:FindFirstChild("Title") :: TextLabel?
	local progress = gui:FindFirstChild("Progress") :: TextLabel?
	local buttonEdge = gui:FindFirstChild("ButtonEdge")
	local button = buttonEdge and buttonEdge:FindFirstChild("Button")
	local price = button and button:FindFirstChild("Price") :: TextLabel?
	local icon = button and button:FindFirstChild("Icon") :: TextLabel?
	if not title or not progress or not price or not icon then
		return
	end

	title.Text = "UPGRADE BASE"

	-- Read straight from the same source the purchase validates against.
	local next = BaseConfig.nextUpgrade(profile.BaseCapacityTier)
	if next then
		progress.Text = `Level {profile.BaseCapacityTier + 1} > Level {next.tier + 1}`
		progress.TextColor3 = MapPalette.SignProgress
		price.Text = NumberFormat.cash(next.cost)
		icon.Text = "▲"
		if button then
			(button :: Frame).BackgroundColor3 = MapPalette.SignButton
		end
	else
		progress.Text = `Level {profile.BaseCapacityTier + 1} · {BaseConfig.slotsForTier(profile.BaseCapacityTier)} slots`
		progress.TextColor3 = MapPalette.SignMaxed
		price.Text = "MAX"
		icon.Text = "★"
		if button then
			(button :: Frame).BackgroundColor3 = MapPalette.SignButtonEdge
		end
	end
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
		local isUnlocked = index <= unlocked

		-- SLOT LOOK. These used to be near-white 20x20 pads at 0.55 transparency,
		-- fourteen per plot - a grid of blown-out white rectangles that washed the
		-- whole base out. Now a dark slate pad with a bright rim: still obviously
		-- a place to put something, without glowing. A locked slot is dimmer and
		-- greyed, so capacity reads at a glance.
		--
		-- Applied here rather than at map-build time because the map is baked into
		-- the place file; doing it at runtime restyles the plots already saved
		-- there without anybody having to rebuild the world.
		slot.Color = if isUnlocked then MapPalette.DisplaySlot else MapPalette.DisplaySlotLocked
		slot.Material = Enum.Material.SmoothPlastic
		slot.Transparency = if isUnlocked then 0.15 else 0.45
		slot.CastShadow = false

		local rim = slot:FindFirstChildOfClass("SelectionBox")
		if not rim then
			local created = Instance.new("SelectionBox")
			created.Name = "SlotRim"
			created.Adornee = slot
			created.LineThickness = 0.06
			created.SurfaceTransparency = 1
			created.Parent = slot
			rim = created
		end
		rim.Color3 = if isUnlocked then MapPalette.DisplaySlotRim else MapPalette.DisplaySlotLockedRim
		rim.Transparency = if isUnlocked then 0.15 else 0.6

		local p = prompt :: ProximityPrompt
		p:SetAttribute("ServerEnabled", isUnlocked)
		-- Taking an item off display STORES it. Selling is a deliberate action
		-- taken later from the inventory panel, so a mis-click cannot destroy
		-- a rare trophy.
		p.ActionText = if occupied then "Store" else "Place"
		-- Every interactable holds, so the prompt's fill animation always plays
		-- and the interaction reads the same everywhere. Placing is the lightest
		-- of them, so it gets the shortest hold.
		p.ObjectText = `Display Slot {index}`
		p.HoldDuration = if occupied then 0.4 else 0.35
	end
end

-- ==========================================================
-- START
-- ==========================================================

function PlacementService.start()
	BaseService.onRebuilt(function(player)
		PlacementService.refreshPrompts(player)
		PlacementService.refreshUpgradeSign(player)
	end)

	-- Capacity pad on every plot. The pads exist in the map already; this just
	-- makes them interactive.
	local bases = workspace:WaitForChild("Map", 20):WaitForChild("Bases", 10)
	for _, plot in bases:GetChildren() do
		local pad = plot:FindFirstChild("BaseUpgradePad")
		-- The pad used to be a slab of yellow neon under the sign. It is still the
		-- prompt's anchor and the sign's foot, but it no longer draws: the sign
		-- carries the whole message and the glow only read as noise.
		if pad and pad:IsA("BasePart") then
			pad.Transparency = 1
			pad.Material = Enum.Material.SmoothPlastic
			pad.CastShadow = false
		end
		-- No Hold-E prompt any more: the sign's own green bar is the button. The
		-- client (BaseSignController) lays a real button over it and fires
		-- BaseUpgradeRequest, which lands in the same upgradeCapacity with the
		-- same validation. A prompt still sitting on a baked pad from an older
		-- build is removed, so the two paths can never both be live.
		local stale = pad and pad:FindFirstChild("UpgradePrompt")
		if stale then
			stale:Destroy()
		end
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
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
			then PlacementService.store(player, index)
			else PlacementService.place(player, index)

		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	-- Same validated paths, reachable from UI once it exists.
	Remotes.get("PlaceLootRequest").OnServerEvent:Connect(function(player, slotIndex)
		-- Validate.integer, not type(): NaN is a number and passes every range
		-- test, and a NaN SlotIndex written into the profile makes every later
		-- save fail (DataStores cannot serialise it).
		local index = Validate.integer(slotIndex, 1, GameConfig.MAX_DISPLAY_SLOTS)
		if not index then
			return
		end
		local ok, reason = PlacementService.place(player, index)
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	-- Inventory actions all arrive on one remote, tagged by action, so adding a
	-- new one later does not mean adding a new RemoteEvent.
	Remotes.get("InventoryRequest").OnServerEvent:Connect(function(player, action, argument)
		if type(action) ~= "string" then
			return
		end

		local ok, reason
		if action == "sell" and type(argument) == "string" then
			ok, reason = PlacementService.sellStored(player, argument)
		elseif action == "equip" and type(argument) == "string" then
			ok, reason = PlacementService.equip(player, argument)
		elseif action == "store" and Validate.integer(argument, 1, GameConfig.MAX_DISPLAY_SLOTS) then
			ok, reason = PlacementService.store(player, Validate.integer(argument, 1, GameConfig.MAX_DISPLAY_SLOTS) :: number)
		elseif action == "upgradeStorage" then
			ok, reason = PlacementService.upgradeStorage(player)
		else
			return
		end

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

	-- Catch-up: if any player was already assigned a plot before this service
	-- started, build their prompts now rather than waiting for the next rebuild.
	for _, player in Players:GetPlayers() do
		if BaseService.getPlot(player) then
			PlacementService.refreshPrompts(player)
			PlacementService.refreshUpgradeSign(player)
		end
	end
end

return PlacementService
