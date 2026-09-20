--!strict
--[[
	RelicRollSection
	[relic-roll] The "MUSEUM RELICS [LIMITED]" gacha banner at the TOP of the
	Shop panel, above PASSES. Built and updated by ShopController exactly like
	GiftShopSection/AutoRevealPassCard: `build(list, order)` once, `update
	(state)` on every push.

	1:1 STRUCTURE FROM THE REFERENCE, OUR OWN ART/ITEMS/ODDS: a purple banner
	card, a "NEW" ribbon, the title, six item figures (rarer = bigger, left to
	right), each with its odds printed under it, four purchase buttons under
	that (50x/10x/3x/1x). No painted art exists for this pack yet (see
	docs/codex-prompts/relic-roll.md), so the banner and buttons are built
	from gradients/strokes in the pack's own accent colours rather than left
	blank - a Codex pass can drop real art in without touching this file's
	logic (see the ICONS/ART section).

	FIGURES REACT TO THE MOUSE (ViewportFrame models, Y-yaw + a little tilt,
	damped) while it is over the banner; idle sway on touch. Honours
	Effects.reduced - motion stops, the pose holds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)

local RelicRollSection = {}

-- ==========================================================
-- ART (placeholders - see docs/codex-prompts/relic-roll.md)
-- ==========================================================
-- "rbxassetid://0" = no art yet; the code below draws a clean placeholder
-- instead (a gradient card, no image) and skips the icon.
local BANNER_BG_IMAGE = "rbxassetid://0"
local RIBBON_IMAGE = "rbxassetid://0"
local ROBUX_ICON = "rbxassetid://0"

local PURPLE_TOP = Color3.fromRGB(120, 64, 200)
local PURPLE_BOTTOM = Color3.fromRGB(58, 22, 108)
local RIBBON_RED = Color3.fromRGB(214, 48, 58)
local TITLE_PINK = Color3.fromRGB(255, 92, 178)
local TITLE_OUTLINE = Color3.fromRGB(46, 10, 40)
local ODDS_OUTLINE = Color3.fromRGB(10, 10, 14)
local GREEN_TOP = Color3.fromRGB(120, 224, 108)
local GREEN_BOTTOM = Color3.fromRGB(40, 150, 58)
local GOLD_TOP = Color3.fromRGB(255, 232, 140)
local GOLD_MID = Color3.fromRGB(255, 176, 60)
local GOLD_BOTTOM = Color3.fromRGB(214, 120, 30)

-- ==========================================================
-- STATE
-- ==========================================================

local root: Frame? = nil
local countdownLabel: TextLabel? = nil
local tooltip: Frame? = nil
local tooltipRarity: TextLabel? = nil
local tooltipName: TextLabel? = nil
local tooltipIncome: TextLabel? = nil

type Figure = {
	button: ImageButton,
	model: Model?,
	basePos: Vector3,
	baseSize: number,
	currentYaw: number,
	targetYaw: number,
	currentTilt: number,
	swayPhase: number,
	itemId: string,
	rarity: string,
	name: string,
	income: number,
}

local figures: { Figure } = {}

type PriceButton = {
	frame: Frame,
	button: TextButton,
	priceLabel: TextLabel,
	shine: Frame?,
	bobBase: number,
}

local priceButtons: { [string]: PriceButton } = {}

local lastRestricted: boolean? = nil
local lastEndsAt: number? = nil

-- ==========================================================
-- LAYOUT HELPERS
-- ==========================================================

--- Six ascending heights (fractions of the banner's own figure-row height),
--- rarest (last) largest - matches the reference's "rarer = bigger" row.
local FIGURE_HEIGHT_FRACTIONS = { 0.46, 0.54, 0.63, 0.74, 0.87, 1.00 }

-- ==========================================================
-- TOOLTIP
-- ==========================================================

local function buildTooltip(parent: Frame)
	local frame = Instance.new("Frame")
	frame.Name = "Tooltip"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	frame.BackgroundTransparency = 0.08
	frame.Size = UDim2.fromOffset(190, 66)
	frame.Visible = false
	frame.ZIndex = 50
	frame.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(70, 70, 86)
	stroke.Parent = frame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = frame

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = frame

	local rarity = Instance.new("TextLabel")
	rarity.Name = "Rarity"
	rarity.BackgroundTransparency = 1
	rarity.Size = UDim2.new(1, 0, 0, 16)
	rarity.Font = Enum.Font.GothamBold
	rarity.TextSize = 13
	rarity.TextXAlignment = Enum.TextXAlignment.Left
	rarity.LayoutOrder = 1
	rarity.Parent = frame
	tooltipRarity = rarity

	local name = Instance.new("TextLabel")
	name.Name = "ItemName"
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, 18)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 15
	name.TextColor3 = Color3.fromRGB(255, 255, 255)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.LayoutOrder = 2
	name.Parent = frame
	tooltipName = name

	local income = Instance.new("TextLabel")
	income.Name = "Income"
	income.BackgroundTransparency = 1
	income.Size = UDim2.new(1, 0, 0, 16)
	income.Font = Enum.Font.Gotham
	income.TextSize = 13
	income.TextColor3 = Color3.fromRGB(140, 240, 160)
	income.TextXAlignment = Enum.TextXAlignment.Left
	income.LayoutOrder = 3
	income.Parent = frame
	tooltipIncome = income

	tooltip = frame
end

local function showTooltip(figure: Figure)
	local frame = tooltip
	if not frame then
		return
	end
	if tooltipRarity then
		tooltipRarity.Text = `[{figure.rarity}]`
		tooltipRarity.TextColor3 = RarityConfig.Colors[figure.rarity] or Color3.fromRGB(255, 255, 255)
	end
	if tooltipName then
		tooltipName.Text = figure.name
	end
	if tooltipIncome then
		tooltipIncome.Text = `{NumberFormat.income(figure.income)}/s`
	end
	-- Positioned relative to the figure's own slot, just above the figure.
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 0, -8)
	frame.Parent = figure.button.Parent
	frame.Visible = true
end

local function hideTooltip()
	if tooltip then
		tooltip.Visible = false
	end
end

-- ==========================================================
-- FIGURES (ViewportFrame models, mouse-follow / idle sway)
-- ==========================================================

local MAX_YAW = math.rad(38)
local MAX_TILT = math.rad(8)
local FOLLOW_DAMP = 6 -- higher = snappier
local SWAY_SPEED = 0.6
local SWAY_AMOUNT = math.rad(10)

local function applyFigureCFrame(figure: Figure)
	local model = figure.model
	if not model or not model.Parent then
		return
	end
	model:PivotTo(CFrame.new(figure.basePos) * CFrame.Angles(figure.currentTilt, figure.currentYaw, 0))
end

local function updateFigures(dt: number)
	if not root or not root.Visible then
		return
	end
	local reduced = Effects.isReduced()
	local touch = Device.isTouch()
	local mouse: Vector2? = nil
	if not touch and not reduced then
		local ok, pos = pcall(function()
			return UserInputService:GetMouseLocation()
		end)
		if ok then
			mouse = pos
		end
	end

	for _, figure in figures do
		if not figure.model then
			continue
		end
		if reduced then
			figure.currentYaw, figure.currentTilt = 0, 0
			applyFigureCFrame(figure)
			continue
		end
		if touch then
			-- Idle gentle sway: no cursor to chase on a touch device.
			figure.swayPhase += dt * SWAY_SPEED
			figure.targetYaw = math.sin(figure.swayPhase) * SWAY_AMOUNT
			figure.currentTilt = 0
		elseif mouse then
			local abs = figure.button.AbsolutePosition
			local size = figure.button.AbsoluteSize
			local center = abs + size / 2
			local overBanner = root and mouse.X >= root.AbsolutePosition.X and mouse.X <= root.AbsolutePosition.X + root.AbsoluteSize.X
				and mouse.Y >= root.AbsolutePosition.Y and mouse.Y <= root.AbsolutePosition.Y + root.AbsoluteSize.Y
			if overBanner then
				local dx = (mouse.X - center.X) / math.max(size.X, 1)
				local dy = (mouse.Y - center.Y) / math.max(size.Y, 1)
				figure.targetYaw = math.clamp(dx, -1.4, 1.4) * MAX_YAW
				figure.currentTilt = math.clamp(-dy, -1, 1) * MAX_TILT
			else
				figure.targetYaw = 0
				figure.currentTilt = 0
			end
		end
		local alpha = 1 - math.exp(-FOLLOW_DAMP * dt)
		figure.currentYaw += (figure.targetYaw - figure.currentYaw) * alpha
		applyFigureCFrame(figure)
	end
end

-- ==========================================================
-- BUTTONS (50x / 10x / 3x / 1x)
-- ==========================================================

--- Idle shine sweep across a button - a diagonal bright strip that slides
--- from one edge to the other and loops. Effects-aware: never built at all
--- under Reduced Effects.
local function addShine(button: GuiObject): Frame?
	if Effects.isReduced() then
		return nil
	end
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	shine.BackgroundTransparency = 0.55
	shine.BorderSizePixel = 0
	shine.Rotation = 18
	shine.Size = UDim2.fromScale(0.22, 1.6)
	shine.Position = UDim2.fromScale(-0.3, -0.3)
	shine.ZIndex = button.ZIndex + 2
	shine.Parent = button
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = shine

	task.spawn(function()
		while shine.Parent do
			shine.Position = UDim2.fromScale(-0.3, -0.3)
			local tween = TweenService:Create(shine, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Position = UDim2.fromScale(1.3, -0.3),
			})
			tween:Play()
			tween.Completed:Wait()
			task.wait(1.8)
			if Effects.isReduced() then
				shine.Visible = false
				repeat
					task.wait(1)
				until not Effects.isReduced() or not shine.Parent
				shine.Visible = true
			end
		end
	end)
	return shine
end

--- Subtle bob: a small looping vertical offset. Skips entirely on Reduced
--- Effects; a controller can call this again once effects are re-enabled.
local function addBob(frame: Frame, baseY: number)
	task.spawn(function()
		while frame.Parent do
			if Effects.isReduced() then
				frame.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 0, baseY)
				task.wait(1)
				continue
			end
			local up = TweenService:Create(frame, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 0, baseY - 3),
			})
			up:Play()
			up.Completed:Wait()
			if not frame.Parent then
				break
			end
			local down = TweenService:Create(frame, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 0, baseY),
			})
			down:Play()
			down.Completed:Wait()
		end
	end)
end

local function buildButton(parent: Frame, key: string, order: number, isBulk: boolean): PriceButton
	local frame = Instance.new("Frame")
	frame.Name = `Button_{key}`
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = order
	frame.Size = UDim2.fromScale(0.23, 1)
	frame.Parent = parent

	-- The crossed-out "was" price, 50x only. Roblox TextLabels have no
	-- strikethrough property, so the line is a thin Frame drawn over the text.
	if isBulk then
		local was = Instance.new("TextLabel")
		was.Name = "WasPrice"
		was.BackgroundTransparency = 1
		was.Size = UDim2.new(1, 0, 0, 16)
		was.Position = UDim2.fromScale(0, 0)
		was.Font = Enum.Font.GothamBold
		was.TextSize = 13
		was.TextColor3 = Color3.fromRGB(255, 110, 110)
		was.Text = ""
		was.Parent = frame
		local strike = Instance.new("Frame")
		strike.Name = "StrikeLine"
		strike.AnchorPoint = Vector2.new(0.5, 0.5)
		strike.Position = UDim2.fromScale(0.5, 0.5)
		strike.Size = UDim2.fromScale(0.9, 0.08)
		strike.BackgroundColor3 = Color3.fromRGB(255, 110, 110)
		strike.BorderSizePixel = 0
		strike.ZIndex = was.ZIndex + 1
		strike.Parent = was
	end

	local button = Instance.new("TextButton")
	button.Name = "Buy"
	button.AutoButtonColor = false
	button.Text = ""
	button.BackgroundColor3 = if isBulk then GOLD_MID else GREEN_BOTTOM
	button.Size = UDim2.new(1, 0, 1, if isBulk then -18 else 0)
	button.Position = UDim2.fromOffset(0, if isBulk then 18 else 0)
	button.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(12, 30, 16)
	stroke.Parent = button
	local gradient = Instance.new("UIGradient")
	gradient.Color = if isBulk
		then ColorSequence.new({
			ColorSequenceKeypoint.new(0, GOLD_TOP),
			ColorSequenceKeypoint.new(0.5, GOLD_MID),
			ColorSequenceKeypoint.new(1, GOLD_BOTTOM),
		})
		else ColorSequence.new({
			ColorSequenceKeypoint.new(0, GREEN_TOP),
			ColorSequenceKeypoint.new(1, GREEN_BOTTOM),
		})
	gradient.Rotation = 90
	gradient.Parent = button

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.Parent = button
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Parent = button

	if ROBUX_ICON ~= "rbxassetid://0" then
		local icon = Instance.new("ImageLabel")
		icon.Name = "RobuxIcon"
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromOffset(16, 16)
		icon.Image = ROBUX_ICON
		icon.LayoutOrder = 1
		icon.Parent = button
	end

	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.BackgroundTransparency = 1
	price.Size = UDim2.new(1, 0, 0, 20)
	price.Font = Enum.Font.FredokaOne
	price.TextScaled = true
	price.TextColor3 = Color3.fromRGB(255, 255, 255)
	price.TextStrokeTransparency = 0.3
	price.Text = "R$ --"
	price.LayoutOrder = 2
	price.Parent = button

	local label = Instance.new("TextLabel")
	label.Name = "RollLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 16)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.5
	label.Text = key
	label.LayoutOrder = 3
	label.Parent = button

	UIAnim.bindButton(button)
	local shine = if isBulk then addShine(button) else nil
	addBob(frame, frame.Position.Y.Offset)

	return {
		frame = frame,
		button = button,
		priceLabel = price,
		shine = shine,
		bobBase = 0,
	}
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- Builds the banner at the very top of the Shop list, above everything
--- else (`order` should be lower than the Passes section's).
function RelicRollSection.build(list: ScrollingFrame, order: number): { GuiObject }
	local frame = Instance.new("Frame")
	frame.Name = "Section_RelicRoll"
	frame.BackgroundColor3 = PURPLE_BOTTOM
	frame.LayoutOrder = order
	frame.ClipsDescendants = true
	frame.Size = UDim2.new(1, 0, 0, 360) -- re-fit by ShopController's resize hook
	frame.Parent = list
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(200, 150, 255)
	stroke.Parent = frame
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, PURPLE_TOP),
		ColorSequenceKeypoint.new(1, PURPLE_BOTTOM),
	})
	gradient.Rotation = 90
	gradient.Parent = frame

	if BANNER_BG_IMAGE ~= "rbxassetid://0" then
		local bg = Instance.new("ImageLabel")
		bg.Name = "BackgroundArt"
		bg.BackgroundTransparency = 1
		bg.Size = UDim2.fromScale(1, 1)
		bg.Image = BANNER_BG_IMAGE
		bg.ScaleType = Enum.ScaleType.Crop
		bg.ZIndex = 0
		bg.Parent = frame
	end

	-- "NEW" ribbon, top-left.
	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.AnchorPoint = Vector2.new(0, 0)
	ribbon.Position = UDim2.fromOffset(-28, 14)
	ribbon.Size = UDim2.fromOffset(120, 26)
	ribbon.Rotation = -40
	ribbon.BackgroundColor3 = RIBBON_RED
	ribbon.BorderSizePixel = 0
	ribbon.ZIndex = 5
	ribbon.Parent = frame
	if RIBBON_IMAGE == "rbxassetid://0" then
		local rStroke = Instance.new("UIStroke")
		rStroke.Thickness = 1
		rStroke.Color = Color3.fromRGB(90, 10, 14)
		rStroke.Parent = ribbon
		local rText = Instance.new("TextLabel")
		rText.BackgroundTransparency = 1
		rText.Size = UDim2.fromScale(1, 1)
		rText.Font = Enum.Font.FredokaOne
		rText.TextScaled = true
		rText.Text = "NEW"
		rText.TextColor3 = Color3.fromRGB(255, 255, 255)
		rText.ZIndex = 6
		rText.Parent = ribbon
	else
		ribbon.BackgroundTransparency = 1
		local rImg = Instance.new("ImageLabel")
		rImg.BackgroundTransparency = 1
		rImg.Size = UDim2.fromScale(1, 1)
		rImg.Image = RIBBON_IMAGE
		rImg.ZIndex = 6
		rImg.Parent = ribbon
	end

	-- Title.
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -20, 0, 34)
	title.Position = UDim2.fromOffset(0, 10)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = TITLE_PINK
	title.TextStrokeColor3 = TITLE_OUTLINE
	title.TextStrokeTransparency = 0
	title.Text = "MUSEUM RELICS  [LIMITED]"
	title.ZIndex = 3
	title.Parent = frame

	local countdown = Instance.new("TextLabel")
	countdown.Name = "Countdown"
	countdown.BackgroundTransparency = 1
	countdown.Size = UDim2.new(1, -20, 0, 16)
	countdown.Position = UDim2.fromOffset(0, 42)
	countdown.Font = Enum.Font.GothamBold
	countdown.TextSize = 13
	countdown.TextColor3 = Color3.fromRGB(255, 220, 220)
	countdown.Text = ""
	countdown.Visible = false
	countdown.ZIndex = 3
	countdown.Parent = frame
	countdownLabel = countdown

	-- Figures row.
	local figureRow = Instance.new("Frame")
	figureRow.Name = "Figures"
	figureRow.BackgroundTransparency = 1
	figureRow.Size = UDim2.new(1, -20, 0, 150)
	figureRow.Position = UDim2.fromOffset(10, 62)
	figureRow.ZIndex = 3
	figureRow.Parent = frame

	figures = {}
	local slotWidth = 1 / 6
	for index = 1, 6 do
		local heightFrac = FIGURE_HEIGHT_FRACTIONS[index] or 1
		local slot = Instance.new("Frame")
		slot.Name = `Slot{index}`
		slot.BackgroundTransparency = 1
		slot.AnchorPoint = Vector2.new(0, 1)
		slot.Position = UDim2.fromScale(slotWidth * (index - 1), 1)
		slot.Size = UDim2.fromScale(slotWidth, 1)
		slot.Parent = figureRow

		local button = Instance.new("ImageButton")
		button.Name = "Figure"
		button.AnchorPoint = Vector2.new(0.5, 1)
		button.Position = UDim2.fromScale(0.5, 1)
		button.Size = UDim2.fromScale(0.86, heightFrac)
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.Image = ""
		button.Parent = slot

		local oddsLabel = Instance.new("TextLabel")
		oddsLabel.Name = "Odds"
		oddsLabel.BackgroundTransparency = 1
		oddsLabel.AnchorPoint = Vector2.new(0.5, 1)
		oddsLabel.Position = UDim2.fromScale(0.5, 1.14)
		oddsLabel.Size = UDim2.new(1, 0, 0, 18)
		oddsLabel.Font = Enum.Font.FredokaOne
		oddsLabel.TextScaled = true
		oddsLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		oddsLabel.TextStrokeColor3 = ODDS_OUTLINE
		oddsLabel.TextStrokeTransparency = 0
		oddsLabel.Text = ""
		oddsLabel.Parent = slot

		local figure: Figure = {
			button = button,
			model = nil,
			basePos = Vector3.new(),
			baseSize = heightFrac,
			currentYaw = 0,
			targetYaw = 0,
			currentTilt = 0,
			swayPhase = index * 1.3,
			itemId = "",
			rarity = "Common",
			name = "",
			income = 0,
		}
		table.insert(figures, figure)

		button.MouseEnter:Connect(function()
			if not Device.isTouch() then
				showTooltip(figure)
			end
		end)
		button.MouseLeave:Connect(function()
			hideTooltip()
		end)
		button.Activated:Connect(function()
			if Device.isTouch() then
				showTooltip(figure)
				task.delay(2.2, function()
					hideTooltip()
				end)
			end
		end)
	end

	buildTooltip(frame)

	-- Buttons row: 50x / 10x / 3x / 1x, matching the reference's own order.
	local buttonRow = Instance.new("Frame")
	buttonRow.Name = "Buttons"
	buttonRow.BackgroundTransparency = 1
	buttonRow.Size = UDim2.new(1, -20, 0, 84)
	buttonRow.Position = UDim2.fromOffset(10, 236)
	buttonRow.ZIndex = 3
	buttonRow.Parent = frame
	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	-- Four 0.23-wide buttons across the row: the remaining 0.08 splits into
	-- three even gaps (no SpaceBetween in this enum - Roblox never added it).
	buttonLayout.Padding = UDim.new(0.0267, 0)
	buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonLayout.Parent = buttonRow

	local keysInOrder = { "RelicRoll50x", "RelicRoll10x", "RelicRoll3x", "RelicRoll1x" }
	for index, key in keysInOrder do
		local built = buildButton(buttonRow, key, index, key == "RelicRoll50x")
		priceButtons[key] = built
		built.button.Activated:Connect(function()
			UIAnim.punch(built.frame, 0.14)
			Remotes.get("PurchaseRequest"):FireServer("product", key)
		end)
	end

	root = frame

	if not RunService:IsRunning() then
		return { frame }
	end
	RunService.Heartbeat:Connect(function(dt)
		updateFigures(dt)
	end)

	return { frame }
end

-- ==========================================================
-- FIT (responsive: phone portrait/landscape, tablet, PC)
-- ==========================================================

function RelicRollSection.fit()
	local frame = root
	if not frame then
		return
	end
	local list = frame.Parent
	if not list or not list:IsA("GuiObject") then
		return
	end
	local factor = ClipSafe.scaleChain(list)
	local width = list.AbsoluteSize.X / math.max(factor, 0.01)
	-- The whole banner (title + figures + buttons) at a fixed aspect, floored
	-- so it never gets so short the buttons lose their touch target.
	local height = math.clamp(width * 0.72, 300, 420)
	frame.Size = UDim2.new(1, 0, 0, height)

	local figureRow = frame:FindFirstChild("Figures")
	if figureRow and figureRow:IsA("Frame") then
		figureRow.Size = UDim2.new(1, -20, 0, height * 0.42)
	end
	local buttonRow = frame:FindFirstChild("Buttons")
	if buttonRow and buttonRow:IsA("Frame") then
		buttonRow.Position = UDim2.fromOffset(10, height - 84 - 10)
		buttonRow.Size = UDim2.new(1, -20, 0, math.max(56, height * 0.2))
	end
end

-- ==========================================================
-- UPDATE (every StatePush)
-- ==========================================================

function RelicRollSection.update(state: { [string]: any }?)
	local frame = root
	if not frame then
		return
	end
	local data = if state then state.relicRoll else nil
	if type(data) ~= "table" then
		frame.Visible = false
		return
	end

	local restricted = data.restricted == true
	if restricted ~= lastRestricted then
		lastRestricted = restricted
		frame.Visible = not restricted
	end
	if restricted then
		return
	end

	-- Tiers: item name/rarity/income for the tooltip, and the odds row.
	local tiers = data.tiers
	if type(tiers) == "table" then
		for index, figure in figures do
			local tier = tiers[index]
			if type(tier) ~= "table" then
				continue
			end
			figure.itemId = tostring(tier.itemId or "")
			figure.rarity = tostring(tier.rarity or "Common")
			figure.name = tostring(tier.name or figure.itemId)
			figure.income = tonumber(tier.income) or 0

			local slot = figure.button.Parent
			local oddsLabel = slot and slot:FindFirstChild("Odds")
			if oddsLabel and oddsLabel:IsA("TextLabel") then
				local weight = tonumber(tier.weight) or 0
				oddsLabel.Text = `{weight}%`
			end

			if not figure.model or figure.model.Parent == nil then
				local model = ItemThumb.apply(figure.button :: any, figure.rarity, figure.itemId)
				figure.model = model
				if model then
					local min, max = LootModel.worldExtents(model)
					if min and max then
						figure.basePos = (min + max) / 2
					end
				end
				-- The rarest figure (last) gets a glow ring behind it.
				if index == #figures and figure.button.Parent then
					local existing = figure.button.Parent:FindFirstChild("Glow")
					if not existing then
						local glow = Instance.new("ImageLabel")
						glow.Name = "Glow"
						glow.AnchorPoint = Vector2.new(0.5, 1)
						glow.Position = UDim2.fromScale(0.5, 1.02)
						glow.Size = UDim2.fromScale(1.5, 1.5)
						glow.BackgroundTransparency = 1
						glow.Image = "rbxasset://textures/particles/sparkles_main.dds"
						glow.ImageColor3 = RarityConfig.Colors[figure.rarity] or Color3.fromRGB(255, 255, 255)
						glow.ImageTransparency = 0.55
						glow.ZIndex = figure.button.ZIndex - 1
						glow.Parent = figure.button.Parent
					end
				end
			end
		end
	end

	-- Prices.
	local prices = data.prices
	if type(prices) == "table" then
		for key, built in priceButtons do
			local row = prices[key]
			if type(row) ~= "table" then
				continue
			end
			local robux = tonumber(row.robux) or 0
			built.priceLabel.Text = `R$ {NumberFormat.comma(robux)}`
			local configured = row.configured ~= false
			built.button.Active = configured
			built.frame.Visible = true
			if key == "RelicRoll50x" then
				local single = prices["RelicRoll1x"]
				local singleRobux = if type(single) == "table" then tonumber(single.robux) or 0 else 0
				local wasLabel = built.frame:FindFirstChild("WasPrice")
				if wasLabel and wasLabel:IsA("TextLabel") and singleRobux > 0 then
					wasLabel.Text = `R$ {NumberFormat.comma(singleRobux * 50)}`
				end
			end
		end
	end

	-- Countdown, only when the config actually set an endsAt.
	local endsAt = tonumber(data.endsAt)
	if endsAt ~= lastEndsAt then
		lastEndsAt = endsAt
		if countdownLabel then
			countdownLabel.Visible = endsAt ~= nil
		end
	end
	if endsAt and countdownLabel then
		local remaining = math.max(0, math.floor(endsAt - os.time()))
		local hours = math.floor(remaining / 3600)
		local minutes = math.floor((remaining % 3600) / 60)
		countdownLabel.Text = if remaining > 0 then `Ends in {hours}h {minutes}m` else "Ended"
	end

	RelicRollSection.fit()
end

return RelicRollSection
