--!strict
--[[
	UpgradesController
	The Upgrades panel. One thing is for sale, so one thing fills the screen:
	the next treadmill tier, bought with Cash or with Robux.

	WHAT A TREADMILL LEVEL ACTUALLY CHANGES
	Exactly one number: `TreadmillConfig.Tiers[level].gainPerTick`, the SpeedPower
	added every 0.25s while you stand on your own treadmill (SpeedService). It
	does not touch income, walk speed, luck, capacity or PvP.

	Walk speed and zone access are downstream of SpeedPower, not of the treadmill
	- a level 9 treadmill and a level 1 treadmill move you at the same speed until
	the SpeedPower actually accumulates. So the only honest "before -> after" pair
	is the training rate, plus the time-to-next-zone that rate implies. Both are
	computed from real config; nothing here is invented.

	THE PURCHASE CONTRACT IS UNCHANGED
	This file only draws. It never names a product id and never calls
	PromptProductPurchase. Cash goes through TreadmillUpgradeRequest and Robux
	through PurchaseRequest("treadmill"); the server decides which tier and which
	product either of those means, and ProcessReceipt remains the only grant.

	PRICES ARE READ FROM ROBLOX, NOT FROM US
	GetProductInfo is the authority on what a product costs. MonetizationConfig's
	listed price is only a fallback for when that call fails, and a disagreement
	between the two is warned about rather than silently shown.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local UpgradesController = {}

local player = Players.LocalPlayer

local GOLD = Color3.fromRGB(255, 214, 64)
local GREEN = Color3.fromRGB(126, 255, 148)
local DIM = Color3.fromRGB(198, 210, 228)
local WHITE = Color3.fromRGB(255, 255, 255)

local panel: Frame? = nil
local body: Frame? = nil
local viewport: ViewportFrame? = nil
local unlockedLabel: TextLabel? = nil
local currentName: TextLabel? = nil
local nextName: TextLabel? = nil
local levelFrom: TextLabel? = nil
local levelTo: TextLabel? = nil
local statRows: { { label: TextLabel, from: TextLabel, to: TextLabel, arrow: GuiObject } } = {}
local moneyButton: TextButton? = nil
local robuxButton: TextButton? = nil
local maxBanner: TextLabel? = nil
local lockedHint: TextLabel? = nil

local latestState: any = nil
local lastLevel: number? = nil

-- Live Robux prices, fetched once per product.
local priceCache: { [number]: number } = {}

-- Guards overlapping fit passes when the viewport changes rapidly.
local fitToken = 0

-- ==========================================================
-- HELPERS
-- ==========================================================

local function labelIn(parent: Instance?, name: string): TextLabel?
	if not parent then
		return nil
	end
	local found = parent:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

--- The pack's currency buttons carry a strike-through cross-sell. We show one
--- price per button, so both go.
local function stripPromo(button: Instance)
	local inner = button:FindFirstChild("Frame")
	if not inner then
		return
	end
	for _, name in { "Promo", "Line" } do
		local extra = inner:FindFirstChild(name)
		if extra then
			extra:Destroy()
		end
	end
end

--- Keeps TextScaled from turning into either 4px or 90px across devices.
local function clampText(label: TextLabel, min: number, max: number)
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if not constraint then
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Parent = label
	end
	;(constraint :: UITextSizeConstraint).MinTextSize = min
	;(constraint :: UITextSizeConstraint).MaxTextSize = max
end

local function makeLabel(name: string, parent: Instance, size: UDim2, pos: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = pos
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = WHITE
	label.Parent = parent
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(16, 18, 26)
	stroke.Parent = label
	clampText(label, 8, 34)
	return label
end

--- Live price from Roblox, cross-checked against the id we shipped.
local function robuxPrice(productId: number, key: string?): number?
	local cached = priceCache[productId]
	if cached then
		return cached
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
	end)
	local live = if ok and type(info) == "table" then tonumber(info.PriceInRobux) else nil
	local listed = if key then MonetizationConfig.ListedPriceRobux[key] else nil

	if live then
		-- Roblox is the authority. A mismatch means the config is stale, which
		-- would otherwise quote a price the player is not actually charged.
		if listed and listed ~= live then
			warn(
				`[UpgradesController] {key} lists {listed} R$ but Roblox charges {live} R$ - `
					.. `update MonetizationConfig.ListedPriceRobux.`
			)
		end
		priceCache[productId] = live
		return live
	end

	-- GetProductInfo failed (offline, throttled, Studio). Fall back rather than
	-- showing nothing, and do not cache a guess as though it were confirmed.
	return listed
end

--- Seconds of standing on the treadmill to reach the next zone's gate.
local function secondsToNextZone(speedPower: number, gainPerSecond: number): number?
	if gainPerSecond <= 0 then
		return nil
	end
	for _, zone in ZoneConfig.Zones do
		if zone.recommendedSpeed > speedPower then
			return (zone.recommendedSpeed - speedPower) / gainPerSecond
		end
	end
	return nil -- every gate already passed
end

local function formatDuration(seconds: number?): string
	if not seconds then
		return "-"
	end
	if seconds < 1 then
		return "<1s"
	end
	if seconds < 60 then
		return `{math.floor(seconds)}s`
	end
	if seconds < 3600 then
		return `{math.floor(seconds / 60)}m {math.floor(seconds % 60)}s`
	end
	if seconds < 86400 then
		return `{math.floor(seconds / 3600)}h {math.floor((seconds % 3600) / 60)}m`
	end
	return `{math.floor(seconds / 86400)}d`
end

-- ==========================================================
-- TREADMILL PREVIEW
-- ==========================================================

--- Renders the player's ACTUAL treadmill in a ViewportFrame. It is built from
--- parts by MapBuilder, so a clone of those parts is a true preview rather than
--- borrowed art.
local function fillViewport(target: ViewportFrame)
	for _, child in target:GetChildren() do
		if not child:IsA("Camera") then
			child:Destroy()
		end
	end

	local bases = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Bases")
	local plot: Instance? = nil
	if bases then
		for _, candidate in bases:GetChildren() do
			if candidate:GetAttribute("OwnerUserId") == player.UserId then
				plot = candidate
			end
		end
	end
	local source = plot and plot:FindFirstChild("Treadmill")
	if not source then
		return
	end

	local holder = Instance.new("Model")
	holder.Name = "Preview"

	-- True world-axis extents from part corners. Model:GetBoundingBox returns a
	-- box ORIENTED to the pivot, which is not the size you can frame a camera
	-- against once the model is rotated.
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local count = 0
	for _, part in source:GetDescendants() do
		-- The training trigger is an invisible volume; it would box the preview.
		if part:IsA("BasePart") and part.Name ~= "TrainingTrigger" then
			local copy = part:Clone()
			copy.Anchored = true
			copy.CanCollide = false
			copy.CastShadow = false
			copy.Transparency = 0
			copy.Parent = holder
			count += 1

			local half = part.Size / 2
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local corner = (part.CFrame * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
						minV = minV:Min(corner)
						maxV = maxV:Max(corner)
					end
				end
			end
		end
	end
	if count == 0 then
		holder:Destroy()
		return
	end

	local centre = (minV + maxV) / 2
	local extent = maxV - minV
	-- Re-centre on the origin so the spin in start() turns about the model
	-- rather than swinging it around a distant map coordinate.
	holder:PivotTo(CFrame.new(-centre) * holder:GetPivot())
	holder.Parent = target

	local camera = target:FindFirstChildOfClass("Camera")
	if not camera then
		camera = Instance.new("Camera")
		camera.Parent = target
	end
	camera.FieldOfView = 45
	target.CurrentCamera = camera

	-- Fit the camera to the object instead of guessing a distance: back off far
	-- enough that the largest dimension spans the frame, with a little padding.
	-- The treadmill is long and low, so a fixed offset left it a speck.
	local radius = math.max(extent.X, extent.Y, extent.Z) * 0.5
	local distance = (radius / math.tan(math.rad(camera.FieldOfView) / 2)) * 1.5
	local direction = Vector3.new(0.62, 0.42, 0.66).Unit
	camera.CFrame = CFrame.lookAt(direction * distance, Vector3.zero)
end

-- ==========================================================
-- RENDER
-- ==========================================================

local function setButtonEnabled(button: TextButton, enabled: boolean)
	button.BackgroundTransparency = if enabled then 0 else 0.45
	local price = labelIn(button, "Price")
	if price then
		price.TextTransparency = if enabled then 0 else 0.45
	end
end

local function render(state: any)
	latestState = state
	if not panel or not state then
		return
	end

	local level = state.treadmillLevel or 0
	local tier = TreadmillConfig.tier(level)
	local nextTier = TreadmillConfig.nextTier(level)
	local maxed = nextTier == nil and level >= TreadmillConfig.MAX_LEVEL
	local locked = state.baseActivated ~= true

	if unlockedLabel then
		unlockedLabel.Text = `{math.max(level, 0)} / {TreadmillConfig.MAX_LEVEL} TREADMILLS UNLOCKED`
	end

	if currentName then
		currentName.Text = if tier then string.upper(tier.name) else "LOCKED"
	end
	if nextName then
		nextName.Text = if nextTier then string.upper(nextTier.name) else "MAX"
		nextName.TextColor3 = if nextTier then GOLD else GREEN
	end
	if levelFrom then
		levelFrom.Text = `Lvl {math.max(level, 0)}`
	end
	if levelTo then
		levelTo.Text = if nextTier then `Lvl {nextTier.level}` else "MAX"
	end

	-- ---------- the real stats ----------
	local nowRate = TreadmillConfig.gainPerSecond(level)
	local nextRate = if nextTier then TreadmillConfig.gainPerSecond(nextTier.level) else nowRate
	local speedPower = state.speedPower or 0

	local rows = {
		{
			label = "TRAINING",
			from = `+{NumberFormat.short(nowRate)}/s`,
			to = `+{NumberFormat.short(nextRate)}/s`,
		},
		{
			label = "NEXT ZONE IN",
			from = formatDuration(secondsToNextZone(speedPower, nowRate)),
			to = formatDuration(secondsToNextZone(speedPower, nextRate)),
		},
	}

	for index, row in statRows do
		local data = rows[index]
		local visible = data ~= nil
		row.label.Visible = visible
		row.from.Visible = visible
		row.to.Visible = visible and not maxed
		row.arrow.Visible = visible and not maxed
		if data then
			row.label.Text = data.label
			row.from.Text = data.from
			row.to.Text = data.to
		end
	end

	-- ---------- max state ----------
	if maxBanner then
		maxBanner.Visible = maxed
	end
	if lockedHint then
		lockedHint.Visible = locked and not maxed
	end
	if maxed then
		if moneyButton then
			moneyButton.Visible = false
		end
		if robuxButton then
			robuxButton.Visible = false
		end
		if levelTo then
			levelTo.TextColor3 = GREEN
		end
		return
	end
	if levelTo then
		levelTo.TextColor3 = GOLD
	end

	-- ---------- cash ----------
	if moneyButton and nextTier then
		moneyButton.Visible = not locked
		local price = labelIn(moneyButton, "Price")
		if price then
			price.Text = `{NumberFormat.cash(nextTier.cost)}`
		end
		setButtonEnabled(moneyButton, (state.cash or 0) >= nextTier.cost)
	end

	-- ---------- robux ----------
	if robuxButton and nextTier then
		local productId = MonetizationConfig.productIdFor(nextTier.robuxProductKey)
		robuxButton.Visible = productId ~= nil and not locked
		if productId then
			local price = labelIn(robuxButton, "Price")
			if price then
				local amount = robuxPrice(productId, nextTier.robuxProductKey)
				price.Text = if amount then `{amount} R$` else "ROBUX"
			end
			setButtonEnabled(robuxButton, true)
		end
	end

	-- A tier actually changed: punch the level readout so the upgrade lands.
	if lastLevel and level > lastLevel then
		if levelFrom then
			UIAnim.punch(levelFrom, 0.35)
		end
		if unlockedLabel then
			UIAnim.punch(unlockedLabel, 0.25)
			UIAnim.flashColor(unlockedLabel, GREEN)
		end
		if body then
			UIAnim.punch(body, 0.06)
		end
		fillViewport(viewport :: ViewportFrame)
	end
	lastLevel = level
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- Lays the big card out inside the pack's own card body, so every stud
--- overlay, gradient and stroke stays the pack's.
local function buildCard(card: Frame, scroll: ScrollingFrame)
	card.Name = "TreadmillUpgrade"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.97, 0.97)
	-- The pack card is a fixed-ratio strip; this one fills the panel instead.
	local ratio = card:FindFirstChildOfClass("UIAspectRatioConstraint")
	if ratio then
		ratio:Destroy()
	end

	local inner = card:FindFirstChild("Frame")
	if not inner or not inner:IsA("Frame") then
		return
	end
	body = inner
	inner.Size = UDim2.fromScale(1, 1)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.AnchorPoint = Vector2.new(0.5, 0.5)

	local boost = inner:FindFirstChild("Boost")
	local choose = inner:FindFirstChild("Choose")
	local packIcon = inner:FindFirstChild("Icon")
	local packTitle = labelIn(inner, "Title")

	-- The pack's money-pile icon cluster is demo art for a cash upgrade.
	if packIcon then
		packIcon:Destroy()
	end

	-- ---------- header: X / 9 unlocked ----------
	if packTitle then
		packTitle.Name = "Unlocked"
		packTitle.AnchorPoint = Vector2.new(0.5, 0.5)
		packTitle.Position = UDim2.fromScale(0.5, 0.075)
		packTitle.Size = UDim2.fromScale(0.9, 0.1)
		packTitle.TextColor3 = GOLD
		clampText(packTitle, 10, 30)
		local gradient = packTitle:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient:Destroy()
		end
		unlockedLabel = packTitle
	end

	-- ---------- treadmill preview ----------
	local view = Instance.new("ViewportFrame")
	view.Name = "Preview"
	view.AnchorPoint = Vector2.new(0.5, 0.5)
	view.Position = UDim2.fromScale(0.26, 0.31)
	view.Size = UDim2.fromScale(0.42, 0.31)
	view.BackgroundColor3 = Color3.fromRGB(34, 58, 34)
	view.BackgroundTransparency = 0.15
	view.BorderSizePixel = 0
	-- Bright ambient: a ViewportFrame gets no world lighting, so the default is
	-- a near-black silhouette.
	view.Ambient = Color3.fromRGB(226, 232, 240)
	view.LightColor = Color3.fromRGB(255, 255, 255)
	view.ZIndex = 3
	view.Parent = inner
	local viewCorner = Instance.new("UICorner")
	viewCorner.CornerRadius = UDim.new(0.08, 0)
	viewCorner.Parent = view
	local viewStroke = Instance.new("UIStroke")
	viewStroke.Thickness = 3
	viewStroke.Color = Color3.fromRGB(16, 26, 18)
	viewStroke.Parent = view
	viewport = view

	-- ---------- names + level ----------
	local names = Instance.new("Frame")
	names.Name = "Names"
	names.BackgroundTransparency = 1
	names.AnchorPoint = Vector2.new(0.5, 0.5)
	names.Position = UDim2.fromScale(0.72, 0.31)
	names.Size = UDim2.fromScale(0.5, 0.31)
	names.ZIndex = 3
	names.Parent = inner

	currentName = makeLabel("Current", names, UDim2.fromScale(1, 0.32), UDim2.fromScale(0.5, 0.18))
	;(currentName :: TextLabel).TextColor3 = DIM

	local arrowDown = makeLabel("Arrow", names, UDim2.fromScale(1, 0.2), UDim2.fromScale(0.5, 0.5))
	arrowDown.Text = "▼"
	arrowDown.TextColor3 = GOLD

	nextName = makeLabel("Next", names, UDim2.fromScale(1, 0.36), UDim2.fromScale(0.5, 0.82))
	;(nextName :: TextLabel).TextColor3 = GOLD

	-- The pack's Lvl N -> Lvl N+1 row, reused rather than redrawn.
	--
	-- It gets its OWN full-width row rather than living inside the names block:
	-- nested scale fractions compounded on a 678x339 phone until these labels
	-- rendered at 12x5 pixels.
	if boost and boost:IsA("Frame") then
		boost.AnchorPoint = Vector2.new(0.5, 0.5)
		boost.Position = UDim2.fromScale(0.5, 0.525)
		boost.Size = UDim2.fromScale(0.62, 0.1)
		boost.ZIndex = 4
		boost.Parent = inner
		levelFrom = labelIn(boost, "Multiplier1")
		levelTo = labelIn(boost, "Multiplier2")
		for _, label in { levelFrom, levelTo } do
			if label then
				clampText(label, 8, 26)
				local gradient = label:FindFirstChildOfClass("UIGradient")
				if gradient then
					gradient:Destroy()
				end
			end
		end
		if levelFrom then
			levelFrom.TextColor3 = DIM
		end
		if levelTo then
			levelTo.TextColor3 = GOLD
		end
	end

	-- ---------- stat rows ----------
	local stats = Instance.new("Frame")
	stats.Name = "Stats"
	stats.BackgroundColor3 = Color3.fromRGB(12, 24, 12)
	stats.BackgroundTransparency = 0.55
	stats.AnchorPoint = Vector2.new(0.5, 0.5)
	stats.Position = UDim2.fromScale(0.5, 0.675)
	stats.Size = UDim2.fromScale(0.92, 0.18)
	stats.ZIndex = 3
	stats.Parent = inner
	local statsCorner = Instance.new("UICorner")
	statsCorner.CornerRadius = UDim.new(0.14, 0)
	statsCorner.Parent = stats

	for index = 1, 2 do
		local y = if index == 1 then 0.28 else 0.72
		local label = makeLabel("StatLabel" .. index, stats, UDim2.fromScale(0.4, 0.36), UDim2.fromScale(0.25, y))
		label.TextColor3 = DIM
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 4
		clampText(label, 7, 20)

		local from = makeLabel("StatFrom" .. index, stats, UDim2.fromScale(0.2, 0.36), UDim2.fromScale(0.58, y))
		from.TextColor3 = WHITE
		from.ZIndex = 4
		clampText(from, 7, 20)

		local arrow = makeLabel("StatArrow" .. index, stats, UDim2.fromScale(0.06, 0.3), UDim2.fromScale(0.72, y))
		arrow.Text = "→"
		arrow.TextColor3 = GOLD
		arrow.ZIndex = 4
		clampText(arrow, 7, 20)

		local to = makeLabel("StatTo" .. index, stats, UDim2.fromScale(0.22, 0.36), UDim2.fromScale(0.87, y))
		to.TextColor3 = GREEN
		to.ZIndex = 4
		clampText(to, 7, 20)

		table.insert(statRows, { label = label, from = from, to = to, arrow = arrow })
	end

	-- ---------- locked hint ----------
	-- Before base activation there is nothing to buy, so the button row is empty.
	-- Saying why is better than leaving a hole.
	local hint = makeLabel("LockedHint", inner, UDim2.fromScale(0.86, 0.13), UDim2.fromScale(0.5, 0.87))
	hint.Text = "ACTIVATE YOUR BASE TO UNLOCK"
	hint.TextColor3 = DIM
	hint.ZIndex = 5
	hint.Visible = false
	clampText(hint, 9, 24)
	lockedHint = hint

	-- ---------- max banner ----------
	local banner = makeLabel("MaxBanner", inner, UDim2.fromScale(0.8, 0.16), UDim2.fromScale(0.5, 0.86))
	banner.Text = "MAX TREADMILL"
	banner.TextColor3 = GREEN
	banner.ZIndex = 5
	banner.Visible = false
	clampText(banner, 12, 40)
	maxBanner = banner

	-- ---------- buttons ----------
	if choose and choose:IsA("Frame") then
		choose.AnchorPoint = Vector2.new(0.5, 0.5)
		choose.Position = UDim2.fromScale(0.5, 0.885)
		choose.Size = UDim2.fromScale(0.94, 0.21)
		choose.ZIndex = 4
		local layout = choose:FindFirstChildOfClass("UIListLayout")
		if layout then
			-- Side by side and large, not stacked and tiny.
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.Padding = UDim.new(0.04, 0)
		end

		for _, name in { "Money", "Robux" } do
			local button = choose:FindFirstChild(name)
			if button and button:IsA("TextButton") then
				stripPromo(button)
				button.Size = UDim2.fromScale(0.46, 1)
				local buttonRatio = button:FindFirstChildOfClass("UIAspectRatioConstraint")
				if buttonRatio then
					buttonRatio:Destroy()
				end
				local price = labelIn(button, "Price")
				if price then
					clampText(price, 10, 30)
				end
				-- claimButton, not bindButton: pack buttons ship Active = false
				-- and already carry _UIHandlerSetup, so Activated never fires.
				UIAnim.claimButton(button)
			end
		end

		local money = choose:FindFirstChild("Money")
		if money and money:IsA("TextButton") then
			money.LayoutOrder = 1
			moneyButton = money
			money.Activated:Connect(function()
				Remotes.get("TreadmillUpgradeRequest"):FireServer()
			end)
		end

		local robux = choose:FindFirstChild("Robux")
		if robux and robux:IsA("TextButton") then
			robux.LayoutOrder = 2
			robux.Visible = false -- until a configured product proves otherwise
			robuxButton = robux
			robux.Activated:Connect(function()
				-- Intent only. The server picks the product and the tier.
				Remotes.get("PurchaseRequest"):FireServer("treadmill")
			end)
		end
	end

	card.Parent = scroll
end

local function buildPanel(ui: ScreenGui): boolean
	local frames = ui:FindFirstChild("Frames")
	local found = frames and frames:FindFirstChild("Upgrades")
	if not found or not found:IsA("Frame") then
		warn("[UpgradesController] Frames.Upgrades not found - the Upgrades panel is disabled.")
		return false
	end
	panel = found

	local scroll = found:FindFirstChild("ScrollingFrame")
	if not scroll or not scroll:IsA("ScrollingFrame") then
		warn("[UpgradesController] Upgrades panel has no ScrollingFrame.")
		return false
	end

	-- One item is for sale, so nothing scrolls; the card fills the area instead.
	scroll.ScrollBarThickness = 0
	scroll.CanvasSize = UDim2.new()
	scroll.ScrollingEnabled = false
	local scrollLayout = scroll:FindFirstChildOfClass("UIListLayout")
	if scrollLayout then
		scrollLayout:Destroy()
	end

	local kept: Frame? = nil
	for _, child in scroll:GetChildren() do
		if child:IsA("Frame") then
			if child.Name == "Upgrade1" and not kept then
				kept = child
			else
				child:Destroy()
			end
		end
	end
	if not kept then
		warn("[UpgradesController] no Upgrade1 card template in the pack.")
		return false
	end

	buildCard(kept, scroll)

	found:GetPropertyChangedSignal("Visible"):Connect(function()
		if found.Visible then
			fillViewport(viewport :: ViewportFrame)
			render(latestState)
			if body then
				UIAnim.popIn(body, 0.94)
			end
		end
	end)

	return true
end

--- The pack has no Upgrades button, so one is cloned from an existing menu
--- button. The pack pairs a button with the panel of the SAME NAME, which gives
--- us its slide + blur for free.
local function buildOpener(ui: ScreenGui)
	local buttons = ui:FindFirstChild("Buttons")
	local left = buttons and buttons:FindFirstChild("Left")
	local source = left and left:FindFirstChild("Index")
	if not left or not source or not source:IsA("TextButton") then
		warn("[UpgradesController] pack menu buttons not found - Upgrades opener not built.")
		return
	end
	if left:FindFirstChild("Upgrades") then
		return
	end

	local opener = source:Clone()
	opener.Name = "Upgrades"
	opener.LayoutOrder = 2

	-- The source is already stamped by the pack and a clone inherits it, which
	-- makes the pack skip our button: it animates but opens nothing.
	opener:SetAttribute("_UIHandlerSetup", nil)
	opener:SetAttribute("AnimBound", nil)
	local staleRipple = opener:FindFirstChild("_RippleContainer")
	if staleRipple then
		staleRipple:Destroy()
	end
	local scale = opener:FindFirstChildOfClass("UIScale")
	if scale then
		scale.Scale = 1
	end

	local label = opener:FindFirstChild("Title")
	if label and label:IsA("TextLabel") then
		label.Text = "Upgrades"
	end
	local inner = opener:FindFirstChild("Frame")
	local icon = inner and inner:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon.Image = "rbxassetid://102080723305863"
	end

	opener.Parent = left

	task.delay(2, function()
		if opener.Parent and opener:GetAttribute("_UIHandlerSetup") ~= true then
			warn("[UpgradesController] the pack did not bind the Upgrades button - it will not open.")
		end
	end)
end

function UpgradesController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		warn("[UpgradesController] MainUI not found - Upgrades disabled.")
		return
	end

	if not buildPanel(ui) then
		return
	end
	buildOpener(ui)

	-- HUDController scales the whole of MainUI down to 0.72 on narrow viewports
	-- so the side menu does not eat the play area. That is right for the HUD and
	-- wrong for a modal: on a 678x339 phone it shrank this panel until the level
	-- row rendered at 12x5 pixels. A modal wants MORE of a small screen, not
	-- less, so its own UIScale cancels the HUD's and then some, clamped so it
	-- never overflows a tall desktop.
	local panelScale = (panel :: Frame):FindFirstChildOfClass("UIScale")
	if not panelScale then
		panelScale = Instance.new("UIScale")
		panelScale.Parent = panel
	end

	local header = (panel :: Frame):FindFirstChild("Top")

	local function applyPanelScale()
		local camera = workspace.CurrentCamera
		local hudScale = ui:FindFirstChildOfClass("UIScale")
		if not camera or not panelScale then
			return
		end
		local undoHud = if hudScale and hudScale.Scale > 0 then 1 / hudScale.Scale else 1
		-- Short viewports get an extra nudge: height is what runs out first.
		local shortBoost = math.clamp(420 / math.max(camera.ViewportSize.Y, 1), 1, 1.3)
		local wanted = math.clamp(undoHud * shortBoost, 1, 1.75)
		;(panelScale :: UIScale).Scale = wanted

		-- Then shrink until it actually fits. The pack's header is anchored at
		-- 0.5,0.5 on the panel's top EDGE, so it deliberately overhangs upward -
		-- and MainUI's UIScale scales about the origin, which biases every
		-- centred panel toward the top of the screen. Rather than model both
		-- quirks, measure the result and step down until nothing is cut off.
		--
		-- Yields between steps: AbsolutePosition is only recomputed on the next
		-- frame, so reading it straight after writing Scale returns stale values.
		if not header or not header:IsA("GuiObject") then
			return
		end
		fitToken += 1
		local token = fitToken
		task.spawn(function()
			for _ = 1, 20 do
				task.wait()
				if token ~= fitToken or not panelScale or not panel then
					return
				end
				local top = header.AbsolutePosition.Y
				local bottom = (panel :: Frame).AbsolutePosition.Y + (panel :: Frame).AbsoluteSize.Y
				if (top >= 4 and bottom <= camera.ViewportSize.Y - 4) or (panelScale :: UIScale).Scale <= 0.85 then
					return
				end
				;(panelScale :: UIScale).Scale -= 0.05
			end
		end)
	end

	applyPanelScale()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyPanelScale)
	end
	local hudScale = ui:FindFirstChildOfClass("UIScale")
	if hudScale then
		hudScale:GetPropertyChangedSignal("Scale"):Connect(applyPanelScale)
	end

	-- Both purchase paths land here: Cash writes the profile directly and Robux
	-- writes it from ProcessReceipt, and either way the server pushes state. So
	-- there is one refresh path and the panel can never show a stale tier.
	Remotes.get("StatePush").OnClientEvent:Connect(render)

	-- Slowly turn the preview so the panel feels alive.
	RunService.RenderStepped:Connect(function(delta)
		local view = viewport
		if not view or not panel or not panel.Visible then
			return
		end
		local model = view:FindFirstChild("Preview")
		if model and model:IsA("Model") then
			model:PivotTo(model:GetPivot() * CFrame.Angles(0, delta * 0.5, 0))
		end
	end)
end

return UpgradesController
