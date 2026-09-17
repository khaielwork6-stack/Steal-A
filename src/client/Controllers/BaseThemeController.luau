--!strict
--[[
	BaseThemeController
	The BASE section of the Upgrades panel: plot themes and pedestal skins
	(BaseThemeConfig), with a small turning 3D preview of whichever row was
	tapped last.

	ATTACHED, NOT STARTED. UpgradesController builds its treadmill card and
	then calls `attach(panel, scroll, card)`. This adds a two-tab bar
	(TREADMILL | BASE) above the card and a BASE page in the same space; the
	treadmill card itself is only shrunk a little to make room for the bar.

	SENDS INTENT ONLY. Buy / equip / buy-pass go to BaseThemeRequest with a
	KEY; the server checks ownership and price and paints the plot. What is
	owned and equipped arrives as StatePush `baseTheme`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BaseThemeConfig = require(ReplicatedStorage.Shared.Config.BaseThemeConfig)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local BaseThemeController = {}

local WHITE = Color3.fromRGB(255, 255, 255)
local DIM = Color3.fromRGB(198, 210, 228)
local GOLD = Color3.fromRGB(255, 214, 64)
local GREEN = Color3.fromRGB(126, 255, 148)
local ROW_BG = Color3.fromRGB(20, 28, 48)

--- Row geometry, in pixels (inside a ScrollingFrame, scale heights would
--- chase the canvas). The panel's own UIScale takes care of phones; the
--- button stays >= 44 px there because the panel scale is >= 1 on touch.
local ROW_HEIGHT = 66
local TITLE_HEIGHT = 30

local page: ScrollingFrame? = nil
local treadmillCard: Frame? = nil
local buttonTemplate: TextButton? = nil
local tabButtons: { [string]: TextButton } = {}
local activeTab = "Treadmill"
local preview: ViewportFrame? = nil
local previewKey: string? = nil
local latest: any = nil
local builtSignature: string? = nil

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

local function text(parent: Instance, value: string, size: UDim2, pos: UDim2, color: Color3, align: Enum.TextXAlignment?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = pos
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = color
	label.TextXAlignment = align or Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = value
	label.ZIndex = 6
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(10, 12, 20)
	stroke.Parent = label
	label.Parent = parent
	return label
end

--- A pack button (cloned from the treadmill card's Money button), claimed.
local function makeButton(parent: Instance, caption: string): TextButton
	local button: TextButton
	local template = buttonTemplate
	if template then
		button = template:Clone()
		for _, child in button:GetChildren() do
			if child:IsA("UIAspectRatioConstraint") or child.Name == "_RippleContainer" then
				child:Destroy()
			end
		end
		local scale = button:FindFirstChildOfClass("UIScale")
		if scale then
			scale.Scale = 1
		end
		local price = labelIn(button, "Price")
		if price then
			price.Text = caption
		else
			button.Text = caption
		end
	else
		button = Instance.new("TextButton")
		button.Font = Enum.Font.FredokaOne
		button.TextScaled = true
		button.TextColor3 = WHITE
		button.BackgroundColor3 = Color3.fromRGB(0, 158, 40)
		button.Text = caption
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0.3, 0)
		round.Parent = button
	end
	button.Visible = true
	button.LayoutOrder = 0
	button.Parent = parent
	UIAnim.claimButton(button)
	return button
end

local function setCaption(button: TextButton, caption: string)
	local price = labelIn(button, "Price")
	if price then
		price.Text = caption
	else
		button.Text = caption
	end
end

local function tint(button: TextButton, color: Color3, enabled: boolean)
	button.BackgroundColor3 = color
	button.BackgroundTransparency = if enabled then 0 else 0.45
	local body = button:FindFirstChild("Frame")
	local gradient = body and body:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(color:Lerp(WHITE, 0.35), color)
	end
end

local function split(list: string?): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(list) == "string" and list ~= "" then
		for _, key in string.split(list, ",") do
			out[key] = true
		end
	end
	return out
end

-- ==========================================================
-- PREVIEW
-- ==========================================================

--- A tiny diorama of a plot corner in the row's colours: floor, two posts
--- and a rail, a neon cap, a pedestal and any decor primitive.
local function fillPreview(key: string)
	local view = preview
	if not view then
		return
	end
	for _, child in view:GetChildren() do
		if not child:IsA("Camera") then
			child:Destroy()
		end
	end
	local theme = BaseThemeConfig.ThemeByKey[key]
	local skin = BaseThemeConfig.PedestalByKey[key]
	local equippedTheme = latest and latest.baseTheme and BaseThemeConfig.ThemeByKey[latest.baseTheme.theme]
	local shownTheme = theme or equippedTheme or BaseThemeConfig.ThemeByKey[BaseThemeConfig.DEFAULT_THEME]
	local shownSkin = skin
		or (latest and latest.baseTheme and BaseThemeConfig.PedestalByKey[latest.baseTheme.pedestal])
		or BaseThemeConfig.PedestalByKey[BaseThemeConfig.DEFAULT_PEDESTAL]

	local model = Instance.new("Model")
	model.Name = "Preview"
	local function block(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.CFrame = cf
		part.Color = color
		part.Material = material or Enum.Material.SmoothPlastic
		if shape then
			part.Shape = shape
		end
		part.Parent = model
		return part
	end
	block(Vector3.new(16, 1, 16), CFrame.new(0, -0.5, 0), shownTheme.floorColor or Color3.fromRGB(140, 216, 92), shownTheme.floorMaterial)
	local fence = shownTheme.fenceColor or Color3.fromRGB(58, 64, 86)
	local rail = shownTheme.railColor or Color3.fromRGB(246, 246, 240)
	for _, x in { -7, 7 } do
		block(Vector3.new(1.4, 6, 1.4), CFrame.new(x, 3, 7), fence, shownTheme.fenceMaterial)
		block(Vector3.new(2, 0.8, 2), CFrame.new(x, 6.4, 7), shownTheme.accentColor or rail, if shownTheme.accentColor then Enum.Material.Neon else nil)
		for _, def in shownTheme.decor or {} do
			if def.anchor == "gate" then
				local shape = if def.shape == "Ball" then Enum.PartType.Ball elseif def.shape == "Cylinder" then Enum.PartType.Cylinder else Enum.PartType.Block
				local lift = if shape == Enum.PartType.Cylinder then def.size.X / 2 else def.size.Y / 2
				local rotation = if shape == Enum.PartType.Cylinder then CFrame.Angles(0, 0, math.rad(90)) else CFrame.identity
				block(def.size * 0.7, CFrame.new(x, 6.8 + lift * 0.7, 7) * rotation, def.color, def.material, shape)
			end
		end
	end
	for _, y in { 2, 4.2 } do
		block(Vector3.new(14, 0.6, 0.6), CFrame.new(0, y, 7), rail)
	end
	local stoneColor = shownSkin.color or Color3.fromRGB(196, 190, 176)
	local pedestal = block(Vector3.new(3.6, 5, 5), CFrame.new(0, 1.8, -1) * CFrame.Angles(0, 0, math.rad(90)), stoneColor, shownSkin.material or Enum.Material.Slate, Enum.PartType.Cylinder)
	pedestal.Transparency = shownSkin.transparency or 0
	if shownSkin.trimColor then
		block(Vector3.new(0.3, 5.5, 5.5), CFrame.new(0, 0.15, -1) * CFrame.Angles(0, 0, math.rad(90)), shownSkin.trimColor, shownSkin.trimMaterial, Enum.PartType.Cylinder)
	end
	block(Vector3.new(0.2, 3, 3), CFrame.new(0, 3.65, -1) * CFrame.Angles(0, 0, math.rad(90)), GOLD, Enum.Material.Neon, Enum.PartType.Cylinder)
	block(Vector3.new(1.8, 1.8, 1.8), CFrame.new(0, 4.8, -1), Color3.fromRGB(180, 106, 255), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	model:PivotTo(CFrame.new())
	model.Parent = view

	local camera: Camera = view:FindFirstChildOfClass("Camera") or Instance.new("Camera")
	camera.Parent = view
	camera.FieldOfView = 40
	view.CurrentCamera = camera
	local direction = Vector3.new(0.7, 0.55, -0.9).Unit
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 2.5, 0) + direction * 30, Vector3.new(0, 2.5, 0))
	view.LightDirection = (-direction + Vector3.new(0, -0.4, 0)).Unit
	previewKey = key
end

-- ==========================================================
-- ROWS
-- ==========================================================

type RowDef = {
	key: string,
	name: string,
	blurb: string,
	cash: number,
	passKey: string?,
	swatches: { Color3 },
	thumbnail: string,
}

local function rowsFor(isTheme: boolean): { RowDef }
	local out: { RowDef } = {}
	if isTheme then
		for _, theme in BaseThemeConfig.Themes do
			table.insert(out, {
				key = theme.key,
				name = theme.name,
				blurb = theme.blurb,
				cash = theme.cash,
				passKey = theme.passKey,
				swatches = {
					theme.floorColor or Color3.fromRGB(140, 216, 92),
					theme.fenceColor or Color3.fromRGB(58, 64, 86),
					theme.accentColor or Color3.fromRGB(96, 214, 255),
				},
				thumbnail = theme.thumbnail,
			})
		end
	else
		for _, skin in BaseThemeConfig.Pedestals do
			table.insert(out, {
				key = skin.key,
				name = skin.name,
				blurb = if skin.trimColor then "With a trim ring." else "The museum's own stone.",
				cash = skin.cash,
				passKey = skin.passKey,
				swatches = { skin.color or Color3.fromRGB(196, 190, 176), skin.trimColor or Color3.fromRGB(196, 190, 176) },
				thumbnail = skin.thumbnail,
			})
		end
	end
	return out
end

local function sectionTitle(parent: Instance, caption: string, order: number)
	local holder = Instance.new("Frame")
	holder.Name = `Title_{caption}`
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0.96, 0, 0, TITLE_HEIGHT)
	holder.LayoutOrder = order
	holder.Parent = parent
	text(holder, caption, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), GOLD, Enum.TextXAlignment.Center)
end

local function buildRow(parent: Instance, def: RowDef, order: number, state: any, owned: { [string]: boolean }, offered: { [string]: boolean }, equipped: string)
	if def.passKey and not offered[def.key] then
		return
	end
	local row = Instance.new("TextButton")
	row.Name = `Row_{def.key}`
	row.Text = ""
	row.AutoButtonColor = false
	row.BackgroundColor3 = ROW_BG
	row.BackgroundTransparency = 0.15
	row.Size = UDim2.new(0.96, 0, 0, ROW_HEIGHT)
	row.LayoutOrder = order
	row.ZIndex = 4
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = if def.key == equipped then GREEN elseif def.passKey then GOLD else Color3.fromRGB(60, 70, 110)
	stroke.Parent = row
	row.Parent = parent
	-- Tapping the row (not its button) previews it.
	row.Activated:Connect(function()
		fillPreview(def.key)
	end)

	-- Thumbnail when the art exists, colour swatches otherwise.
	if BaseThemeConfig.hasImage(def.thumbnail) then
		local image = Instance.new("ImageLabel")
		image.BackgroundTransparency = 1
		image.Image = def.thumbnail
		image.Size = UDim2.fromOffset(ROW_HEIGHT - 12, ROW_HEIGHT - 12)
		image.Position = UDim2.fromOffset(6, 6)
		image.ZIndex = 5
		image.Parent = row
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0, 8)
		round.Parent = image
	else
		for index, color in def.swatches do
			local swatch = Instance.new("Frame")
			swatch.BackgroundColor3 = color
			swatch.Size = UDim2.fromOffset(16, ROW_HEIGHT - 20)
			swatch.Position = UDim2.fromOffset(8 + (index - 1) * 19, 10)
			swatch.ZIndex = 5
			swatch.Parent = row
			local round = Instance.new("UICorner")
			round.CornerRadius = UDim.new(0, 5)
			round.Parent = swatch
			local edge = Instance.new("UIStroke")
			edge.Thickness = 1.5
			edge.Color = Color3.fromRGB(8, 10, 16)
			edge.Parent = swatch
		end
	end

	local left = 70
	text(row, string.upper(def.name), UDim2.new(0.6, -left, 0.46, 0), UDim2.new(0, left, 0.08, 0), WHITE)
	local sub = def.blurb
	if def.passKey then
		sub = "ROBUX EXCLUSIVE - " .. sub
	end
	text(row, sub, UDim2.new(0.6, -left, 0.34, 0), UDim2.new(0, left, 0.56, 0), DIM)

	-- The one action.
	local actions = Instance.new("Frame")
	actions.BackgroundTransparency = 1
	actions.AnchorPoint = Vector2.new(1, 0.5)
	actions.Position = UDim2.new(1, -8, 0.5, 0)
	actions.Size = UDim2.new(0.36, 0, 0, math.max(ROW_HEIGHT - 16, 46))
	actions.ZIndex = 5
	actions.Parent = row
	local button = makeButton(actions, "")
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.fromScale(0.5, 0.5)
	button.Size = UDim2.fromScale(1, 1)
	button.ZIndex = 6

	local isOwned = owned[def.key] == true
	if def.key == equipped then
		setCaption(button, "EQUIPPED")
		tint(button, Color3.fromRGB(70, 80, 100), false)
		button.AutoButtonColor = false
	elseif isOwned then
		setCaption(button, "EQUIP")
		tint(button, Color3.fromRGB(46, 90, 200), true)
		button.Activated:Connect(function()
			Remotes.get("BaseThemeRequest"):FireServer("equip", def.key)
		end)
	elseif def.passKey then
		local pass = MonetizationConfig.ThemePassByKey[def.passKey]
		setCaption(button, if pass then `R$ {NumberFormat.comma(pass.robux)}` else "ROBUX")
		tint(button, Color3.fromRGB(30, 150, 60), pass ~= nil and pass.gamePassId > 0)
		button.Activated:Connect(function()
			fillPreview(def.key)
			Remotes.get("BaseThemeRequest"):FireServer("buyPass", def.key)
		end)
	else
		local affordable = (state.cash or 0) >= def.cash
		setCaption(button, NumberFormat.cash(def.cash))
		tint(button, Color3.fromRGB(0, 158, 40), affordable)
		button.Activated:Connect(function()
			if not affordable then
				UIAnim.punch(row, 0.04)
				return
			end
			Remotes.get("BaseThemeRequest"):FireServer("buy", def.key)
		end)
	end
end

local function signatureOf(state: any): string
	local info = state and state.baseTheme
	if type(info) ~= "table" then
		return "none"
	end
	local parts = { tostring(info.owned), tostring(info.offered), tostring(info.theme), tostring(info.pedestal) }
	local cash = state.cash or 0
	for _, row in BaseThemeConfig.Themes do
		table.insert(parts, if cash >= row.cash then "1" else "0")
	end
	for _, row in BaseThemeConfig.Pedestals do
		table.insert(parts, if cash >= row.cash then "1" else "0")
	end
	return table.concat(parts, "|")
end

local function render(state: any)
	latest = state
	local list = page
	if not list or not list.Visible or not state then
		return
	end
	local signature = signatureOf(state)
	if signature == builtSignature then
		return
	end
	builtSignature = signature
	local info = if type(state.baseTheme) == "table" then state.baseTheme else {}
	local owned = split(info.owned)
	local offered = split(info.offered)
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") and child.Name ~= "PreviewHolder" then
			child:Destroy()
		end
	end
	sectionTitle(list, "THEMES", 10)
	for index, def in rowsFor(true) do
		buildRow(list, def, 10 + index, state, owned, offered, info.theme or BaseThemeConfig.DEFAULT_THEME)
	end
	sectionTitle(list, "PEDESTALS", 100)
	for index, def in rowsFor(false) do
		buildRow(list, def, 100 + index, state, owned, offered, info.pedestal or BaseThemeConfig.DEFAULT_PEDESTAL)
	end
	if not previewKey then
		fillPreview(info.theme or BaseThemeConfig.DEFAULT_THEME)
	end
end

-- ==========================================================
-- TABS
-- ==========================================================

local function selectTab(name: string)
	activeTab = name
	local card = treadmillCard
	if card then
		card.Visible = name == "Treadmill"
	end
	if page then
		page.Visible = name == "Base"
		if name == "Base" then
			builtSignature = nil
			render(latest)
		end
	end
	for key, button in tabButtons do
		local selected = key == name
		tint(button, if selected then Color3.fromRGB(22, 120, 70) else Color3.fromRGB(34, 44, 84), true)
	end
end

-- ==========================================================
-- ATTACH
-- ==========================================================

function BaseThemeController.attach(panel: Frame, scroll: ScrollingFrame, card: Frame)
	treadmillCard = card
	local inner = card:FindFirstChild("Frame")
	local choose = inner and inner:FindFirstChild("Choose")
	local money = choose and choose:FindFirstChild("Money")
	if money and money:IsA("TextButton") then
		local template = money:Clone()
		template.Visible = true
		buttonTemplate = template
	end

	-- Room for the tab bar: the treadmill card gives up its top slice.
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.fromScale(0.5, 0.1)
	card.Size = UDim2.fromScale(0.97, 0.88)

	local bar = Instance.new("Frame")
	bar.Name = "UpgradeTabs"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.fromScale(0.5, 0.012)
	bar.Size = UDim2.fromScale(0.7, 0.078)
	bar.ZIndex = 5
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.04, 0)
	layout.Parent = bar
	for order, name in { "Treadmill", "Base" } do
		local button = makeButton(bar, string.upper(name))
		button.Name = `Tab{name}`
		button.LayoutOrder = order
		button.Size = UDim2.fromScale(0.46, 1)
		button.Activated:Connect(function()
			selectTab(name)
		end)
		tabButtons[name] = button
	end
	bar.Parent = scroll

	-- The BASE page: a scrolling list in the card's place, preview on top.
	local list = Instance.new("ScrollingFrame")
	list.Name = "BasePage"
	list.AnchorPoint = Vector2.new(0.5, 0)
	list.Position = UDim2.fromScale(0.5, 0.1)
	list.Size = UDim2.fromScale(0.97, 0.88)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = if Device.isTouch() then 8 else 6
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Visible = false
	list.ZIndex = 3
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = list
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.Parent = list

	local holder = Instance.new("Frame")
	holder.Name = "PreviewHolder"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0.96, 0, 0, 150)
	holder.LayoutOrder = 1
	holder.Parent = list
	local view = Instance.new("ViewportFrame")
	view.Name = "Preview"
	view.AnchorPoint = Vector2.new(0.5, 0)
	view.Position = UDim2.fromScale(0.5, 0)
	view.Size = UDim2.fromScale(0.6, 1)
	view.BackgroundColor3 = Color3.fromRGB(40, 56, 92)
	view.BackgroundTransparency = 0.1
	view.Ambient = Color3.fromRGB(200, 206, 220)
	view.LightColor = WHITE
	view.ZIndex = 4
	view.Parent = holder
	local viewCorner = Instance.new("UICorner")
	viewCorner.CornerRadius = UDim.new(0, 14)
	viewCorner.Parent = view
	local viewStroke = Instance.new("UIStroke")
	viewStroke.Thickness = 3
	viewStroke.Color = Color3.fromRGB(12, 16, 30)
	viewStroke.Parent = view
	text(holder, "TAP A ROW TO PREVIEW", UDim2.new(0.6, 0, 0, 18), UDim2.new(0.2, 0, 1, -20), DIM, Enum.TextXAlignment.Center)
	preview = view
	list.Parent = scroll
	page = list

	selectTab("Treadmill")

	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible and activeTab == "Base" then
			builtSignature = nil
			render(latest)
		end
	end)

	require(script.Parent.Parent.StateStore).subscribe(render)

	-- The preview turns slowly while it is on screen (held still under
	-- Reduced Effects).
	RunService.RenderStepped:Connect(function(delta: number)
		if not panel.Visible or activeTab ~= "Base" or Effects.isReduced() then
			return
		end
		local model = view:FindFirstChild("Preview")
		if model and model:IsA("Model") then
			model:PivotTo(model:GetPivot() * CFrame.Angles(0, delta * 0.4, 0))
		end
	end)
end

return BaseThemeController
