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
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
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
local HatchService = require(script.Parent.HatchService)
local HeistService = require(script.Parent.HeistService)
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

	-- A base steal is not a new item: the very same saved record moves from
	-- the victim's base to this slot, protection stamped, once the thief is
	-- home. Every check above still applied; the transfer is HeistService's.
	if loot.heist then
		return HeistService.deposit(player, loot, slotIndex)
	end

	-- Scale and mutation were rolled when the item spawned and are never
	-- rerolled here; income is derived from them on every load.
	local def = LootConfig.ById[loot.itemId]
	local growthBase = if def then def.growthSeconds else LootConfig.DEFAULT_GROWTH_SECONDS
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
		-- THE economy Scale, and the look that goes with it.
		Scale = loot.scale,
		VisualScale = loot.visualScale,
		SizeVisualVersion = RarityConfig.SIZE_VISUAL_VERSION,
		EconomyScaleVersion = ScaleConfig.ECONOMY_SCALE_VERSION,
		-- MATURATION: the item earns nothing until its growth credit reaches
		-- its base growth time stretched by its Scale. Snapshotted here, at
		-- placement, exactly as the reference freezes GrowthDuration.
		MaturationSeconds = ScaleConfig.maturationSeconds(growthBase, loot.scale),
		GrowthSeconds = 0,
		-- IT ARRIVES SEALED. The escape is finished, but the reward is still
		-- hidden: the container sits on the pedestal and incubates, earns
		-- nothing, and shows nothing about itself until it is hatched.
		Hatched = false,
		SpawnToken = loot.spawnToken,
	})
	local placed = profile.DisplayItems[#profile.DisplayItems]
	-- THE TIMER STARTS HERE and nowhere else - the moment the base accepts it.
	HatchService.beginIncubation(player, placed)

	-- DISCOVERY IS DEFERRED. A sealed container must not add its item to the
	-- Index, announce a new find, or pay a discovery reward - all three would
	-- name the reward before the reveal. HatchService does it on the hatch.
	local firstTime = false
	-- Lifetime.Secrets counts the top-tier trophies brought home: Secret,
	-- Eternal and Divine (RarityConfig.ANNOUNCE_MIN_RARITY). The save key
	-- keeps its name so existing profiles carry over.
	if RarityConfig.rank(loot.rarity) >= RarityConfig.rank(RarityConfig.ANNOUNCE_MIN_RARITY) then
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

	-- No banner. The card over the container says how long the wait is, and
	-- the placement cue is the only feedback.
	StateService.sound(player, "PlaceItem")

	local _ = firstTime
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

	-- An item a thief has paid for, or is holding the purchase prompt open
	-- on, stays exactly where it is until that resolves: moving it would pull
	-- the target out from under a real Robux purchase.
	if found.RobbedBy then
		return false, "That item is being stolen - stop the thief!"
	end
	if HeistService.isReserved(found.InstanceId) then
		return false, "Someone is trying to steal that right now!"
	end
	-- A SEALED CONTAINER CANNOT BE STORED, and neither can one mid-reveal.
	-- Authoritative: the prompt never offers it, and a remote fired by hand
	-- lands here and is refused all the same.
	if found.Hatched == false or HatchService.isRevealing(found.InstanceId) then
		return false, "Reveal it first!"
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
	StateService.sound(player, "StoredItem")
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

			if item.Hatched == false then
				-- A sealed container (a save from before storing one was
				-- refused): it goes back on its pedestal to finish its wait,
				-- and nothing here may name what is inside it.
				HatchService.beginIncubation(player, item)
				return true
			end
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
			-- An unrevealed container has no price: nobody knows what it is,
			-- and pricing it would say. Reveal it first.
			if item.Hatched == false then
				return false, "Reveal it first!"
			end
			-- Server calculates the payout; the client never supplies a value.
			-- Priced from the item WITH ITS MUTATION STRIPPED (the reference
			-- game's verified rule) at moneyPass 1, for SELL_REFUND_SECONDS of
			-- that rate; `earn` applies the 2x Cash pass exactly once. The
			-- seconds figure is provisional - see GameConfig.SELL_STATUS.
			local def = LootConfig.ById[item.ItemId]
			local base = if def then def.income else item.BaseIncome
			local mutationForPrice = if GameConfig.SELL_STRIPS_MUTATION then "Normal" else item.Mutation
			local rate = RarityConfig.preBoostRate(base, ScaleConfig.clampScale(item.Scale), mutationForPrice, 1)
			local payout = math.floor(rate * GameConfig.SELL_REFUND_SECONDS)
			table.remove(profile.Inventory, index)

			-- Index discovery survives a sale (GDD section 13).
			EconomyService.earn(player, payout, "sell")
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

--- Which way the sign should face: INWARD, toward the plot's own centre. The
--- pad stands at the plot's outer front corner (MapBuilder.buildBase), so
--- facing the centre points the board at the porch, the spawn and the pads
--- at once - wherever the owner is when they look for it. Derived from the
--- slab rather than assumed, so every plot gets the same answer.
local function signFacing(plot: Instance, pad: BasePart): CFrame
	local target: Vector3? = nil
	local slab = BaseService.slabOf(plot)
	if slab then
		target = slab.Position
	else
		local spawn = plot:FindFirstChild("Spawn")
		if spawn and spawn:IsA("BasePart") then
			target = spawn.Position
		end
	end
	if target then
		local toward = target - pad.Position
		local flat = Vector3.new(toward.X, 0, toward.Z)
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

	-- The second way in: a click or tap on the board itself. Only the plot's
	-- owner is answered (requestUpgrade checks through upgradeCapacity), and
	-- the range is the sign's reading distance.
	local detector = Instance.new("ClickDetector")
	detector.Name = "UpgradeClick"
	detector.MaxActivationDistance = 40
	detector.CursorIcon = ""
	detector.Parent = board
	detector.MouseClick:Connect(function(player)
		if BaseService.getPlot(player) == plot then
			PlacementService.requestUpgrade(player)
		end
	end)

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

--- One physical press on the sign can arrive TWICE: the client's SurfaceGui
--- button sends the remote, and the ClickDetector on the same board fires on
--- the server for the same click. Both are kept - the button is what a gamepad
--- cursor and a touch tap reliably hit, the detector is what a plain mouse
--- click hits even when the GUI layer is not yet built - so the second arrival
--- of the same press is folded here. A tier costs real money; buying two for
--- one click is the "duplicate purchase" the sign must never make.
local PRESS_WINDOW = 0.35
local lastPress: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

--- A press on the sign, from either input path.
function PlacementService.requestUpgrade(player: Player)
	local now = os.clock()
	local last = lastPress[player]
	if last and now - last < PRESS_WINDOW then
		return
	end
	lastPress[player] = now

	local ok, reason = PlacementService.upgradeCapacity(player)
	if not ok and reason then
		notify(player, "error", reason)
	end
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
		-- Next level, and what it unlocks: the slot count the tier brings.
		progress.Text = `Level {profile.BaseCapacityTier + 1} > Level {next.tier + 1}  ·  {next.slots} slots`
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
	local profile = DataService.get(player)
	local occupiedBySlot: { [number]: DataService.DisplayItem } = {}
	if profile then
		for _, item in profile.DisplayItems do
			occupiedBySlot[item.SlotIndex] = item
		end
	end

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

		local isUnlocked = index <= unlocked
		local item = occupiedBySlot[index]

		-- The slot's LOOK (pad, neon frame, pedestal) is BaseService's: it is
		-- drawn from the profile in rebuildDisplays, which fires this refresh.
		-- Only the prompt is owned here.
		--
		-- ONE PROMPT, ONE ACTION PER STATE:
		--   empty slot            -> Place
		--   sealed, counting      -> Instant Reveal
		--   sealed, ready         -> Reveal
		--   revealing (animation) -> nothing at all
		--   revealed item         -> Store
		-- The client flips Instant Reveal to Reveal itself the second its own
		-- clock hits zero (RevealEndsAt), and the server re-derives the real
		-- state on every trigger, so the label is never the authority.
		local p = prompt :: ProximityPrompt
		local sealed = item ~= nil and item.Hatched == false
		local revealing = item ~= nil and HatchService.isRevealing(item.InstanceId)
		p:SetAttribute("ServerEnabled", isUnlocked and not revealing)
		p:SetAttribute("RevealEndsAt", if sealed and item then tonumber(item.HatchEndsAt) or 0 else nil)
		if not item then
			p.ActionText = "Place"
			p.HoldDuration = 0.35
		elseif sealed then
			p.ActionText = if HatchService.remaining(item) > 0 then "Instant Reveal" else "Reveal"
			p.HoldDuration = 0.4
		else
			-- Taking an item off display STORES it. Selling is a deliberate
			-- action taken later from the inventory panel, so a mis-click
			-- cannot destroy a rare trophy.
			p.ActionText = "Store"
			p.HoldDuration = 0.4
		end
		p.ObjectText = `Display Slot {index}`
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

		-- Dispatch on the item's REAL state, never on the label the client saw.
		local profile = DataService.get(player)
		local item: DataService.DisplayItem? = nil
		if profile then
			for _, candidate in profile.DisplayItems do
				if candidate.SlotIndex == index then
					item = candidate
					break
				end
			end
		end

		local ok, reason
		if not item then
			ok, reason = PlacementService.place(player, index)
		elseif item.Hatched == false then
			if HatchService.remaining(item) > 0 then
				ok, reason = HatchService.promptInstantReveal(player, item.InstanceId)
			else
				ok, reason = HatchService.commit(player, item.InstanceId)
			end
		else
			ok, reason = PlacementService.store(player, index)
		end

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

	-- ONE upgrade path, two ways in. The client's invisible button over the
	-- sign (BaseSignController) sends the remote; the ClickDetector on the
	-- board (ensureSign) answers a plain click or tap on the sign itself, so
	-- a device where SurfaceGui input misbehaves still buys. Both land in
	-- upgradeCapacity, which owns the ownership check, the price, the rate
	-- limit and the atomic spend - a double press is one purchase.
	Remotes.get("BaseUpgradeRequest").OnServerEvent:Connect(function(player)
		PlacementService.requestUpgrade(player)
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
