--!strict
--[[
	HUDLayoutController
	The layout pass over the pack's HUD. Presentation only: nothing here changes
	what a button does, only where it sits, what colour it is and how much room
	it has.

	WHAT IT DOES
	  1. SETTINGS LEAVES THE RAIL. The big Settings tile is removed from
	     Buttons.Left and replaced by a small round black button with a white
	     gear, top-right beside BASE. It is still NAMED "Settings", so the pack's
	     own button script pairs it with Frames.Settings and opens the same panel
	     with the same slide and blur. Nothing about the panel changes.
	  2. THE RAIL BREATHES. Buttons.Left is inset from the screen edge and its
	     buttons are spaced out, in scale, so they stop reading as a stack jammed
	     into the corner.
	  3. EACH BUTTON GETS AN IDENTITY. Shop stays the pack's red/pink, Upgrades
	     goes green, Index blue/violet, Storage orange/gold. Every colour is
	     applied as the pack authors it - outer plate, inner gradient AND inner
	     stroke together - so no button ends up with a mismatched ring.
	  4. STATS BECOME A CARD. Cash, $/s and Speed move out of the loose text
	     under the rail into one compact framed card in the lower-left, each
	     with an icon, built from the pack's own button anatomy so it is visibly
	     the same kit. HUDController keeps writing to the SAME labels - they are
	     re-parented, not replaced - so no other controller notices.

	WHAT IT DOES NOT DO
	It never binds a button. The pack script owns hover, press, ripple and
	opening panels; a button we bound ourselves would be skipped by it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local HUDLayoutController = {}

local player = Players.LocalPlayer

--- Inset of the rail from the left edge and the gap between its buttons, as a
--- fraction of the rail's height. ~12-16px at desktop sizes.
local RAIL_INSET = UDim.new(0, 14)
local RAIL_GAP = UDim.new(0.06, 0)

--- Per-button identity. Plate = the TextButton's own fill (reads as the border),
--- top/bottom = the inner gradient, ring = the inner stroke.
type Accent = { plate: Color3, top: Color3, bottom: Color3, ring: Color3 }
local ACCENTS: { [string]: Accent } = {
	Shop = {
		plate = Color3.fromRGB(150, 26, 40),
		top = Color3.fromRGB(255, 96, 118),
		bottom = Color3.fromRGB(226, 42, 78),
		ring = Color3.fromRGB(255, 170, 186),
	},
	Upgrades = {
		plate = Color3.fromRGB(22, 120, 70),
		top = Color3.fromRGB(96, 240, 150),
		bottom = Color3.fromRGB(28, 190, 110),
		ring = Color3.fromRGB(180, 255, 210),
	},
	Index = {
		plate = Color3.fromRGB(46, 50, 150),
		top = Color3.fromRGB(120, 140, 255),
		bottom = Color3.fromRGB(70, 90, 230),
		ring = Color3.fromRGB(190, 200, 255),
	},
	Storage = {
		plate = Color3.fromRGB(160, 92, 10),
		top = Color3.fromRGB(255, 196, 80),
		bottom = Color3.fromRGB(240, 140, 30),
		ring = Color3.fromRGB(255, 226, 160),
	},
}

local STAT_ROWS = {
	{ key = "Cash", icon = "rbxassetid://112931960147028", color = Color3.fromRGB(110, 240, 130) },
	{ key = "Income", icon = "rbxassetid://112931960147028", color = Color3.fromRGB(180, 255, 190) },
	{ key = "Speed", icon = "rbxassetid://102080723305863", color = Color3.fromRGB(110, 210, 255) },
}

-- ==========================================================
-- COLOUR
-- ==========================================================

--- Recolours one rail button the way the pack authors colour: all three layers.
function HUDLayoutController.tint(button: GuiButton, accent: Accent)
	button.BackgroundColor3 = accent.plate
	local face = button:FindFirstChild("Frame")
	if not face then
		return
	end
	local gradient = face:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(accent.top, accent.bottom)
	end
	local ring = face:FindFirstChildOfClass("UIStroke")
	if ring then
		ring.Color = accent.ring
	end
end

local function tintRail(left: Instance)
	for name, accent in ACCENTS do
		local button = left:FindFirstChild(name)
		if button and button:IsA("GuiButton") then
			HUDLayoutController.tint(button, accent)
		end
	end
	-- Buttons cloned into the rail later (Upgrades, Storage) arrive after this
	-- pass; colour them as they land.
	left.ChildAdded:Connect(function(child)
		local accent = ACCENTS[child.Name]
		if accent and child:IsA("GuiButton") then
			task.defer(function()
				HUDLayoutController.tint(child, accent)
			end)
		end
	end)
end

-- ==========================================================
-- SETTINGS GEAR
-- ==========================================================

local function buildSettingsGear(ui: ScreenGui, oldButton: GuiButton?)
	if ui:FindFirstChild("SettingsGear") then
		return
	end
	local top = ui:FindFirstChild("Top")

	-- A holder that joins the top strip's OWN row as its first item. The strip is
	-- a right-aligned horizontal list (BASE, then GIFT), so LayoutOrder 0 puts
	-- the gear at the left end of the row and the list keeps it clear of both
	-- buttons however the row resizes - no measured offsets to go stale. Full
	-- row height, with the round button centred inside it.
	local holder = Instance.new("Frame")
	holder.Name = "SettingsGear"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0, 56, 1, 0)
	holder.LayoutOrder = 0
	holder.ZIndex = 5
	if top and top:IsA("GuiObject") then
		holder.Parent = top
	else
		holder.AnchorPoint = Vector2.new(1, 0)
		holder.Position = UDim2.new(1, -180, 0, 12)
		holder.Parent = ui
	end

	-- Named "Settings" so the pack opens Frames.Settings for it. Round, black,
	-- white gear: the reference's minimal direction.
	local button = Instance.new("ImageButton")
	button.Name = "Settings"
	button.Size = UDim2.fromOffset(44, 44)
	button.Position = UDim2.fromScale(0.5, 0.5)
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	button.BackgroundTransparency = 0.08
	button.AutoButtonColor = false
	button.Image = ""
	button.ZIndex = 6
	button.Parent = holder
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.75
	stroke.Parent = button

	local gear = Instance.new("ImageLabel")
	gear.Name = "Gear"
	gear.BackgroundTransparency = 1
	gear.Image = "rbxassetid://127441972943624" -- the pack's own gear icon
	gear.ImageColor3 = Color3.fromRGB(255, 255, 255)
	gear.Size = UDim2.fromScale(0.62, 0.62)
	gear.Position = UDim2.fromScale(0.5, 0.5)
	gear.AnchorPoint = Vector2.new(0.5, 0.5)
	gear.ZIndex = 7
	gear.Parent = button
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = gear

	-- Tooltip on hover, desktop only by nature (touch has no hover).
	local tip = Instance.new("TextLabel")
	tip.Name = "Tip"
	tip.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	tip.BackgroundTransparency = 0.15
	tip.Size = UDim2.fromOffset(74, 22)
	tip.Position = UDim2.new(0.5, 0, 1, 6)
	tip.AnchorPoint = Vector2.new(0.5, 0)
	tip.Font = Enum.Font.GothamBold
	tip.TextSize = 13
	tip.TextColor3 = Color3.fromRGB(255, 255, 255)
	tip.Text = "Settings"
	tip.Visible = false
	tip.ZIndex = 8
	tip.Parent = button
	local tipCorner = Instance.new("UICorner")
	tipCorner.CornerRadius = UDim.new(0, 6)
	tipCorner.Parent = tip
	button.MouseEnter:Connect(function()
		tip.Visible = true
	end)
	button.MouseLeave:Connect(function()
		tip.Visible = false
	end)

	-- The old tile goes. IndexController and the others look Index up by name,
	-- not by position, so removing Settings shifts nothing they depend on.
	if oldButton then
		oldButton:Destroy()
	end
end

-- ==========================================================
-- RAIL
-- ==========================================================

local function layoutRail(buttons: GuiObject, left: GuiObject)
	-- Off the edge. The rail was pinned at X = 0 with its buttons touching the
	-- border; an inset and a gap are the whole difference between "stacked" and
	-- "laid out".
	buttons.Position = UDim2.new(0, 0, 0.47, 0)
	-- Slightly shorter than the pack's 0.62 and lifted a touch, so the rail's
	-- last tile clears the stat card below it instead of touching it.
	buttons.Size = UDim2.new(buttons.Size.X.Scale, buttons.Size.X.Offset, 0.56, 0)
	local pad = buttons:FindFirstChildOfClass("UIPadding") or Instance.new("UIPadding")
	pad.PaddingLeft = RAIL_INSET
	pad.Parent = buttons

	local grid = left:FindFirstChildOfClass("UIGridLayout")
	if grid then
		grid.CellPadding = UDim2.new(0, 0, RAIL_GAP.Scale, RAIL_GAP.Offset)
	end
	local list = buttons:FindFirstChildOfClass("UIListLayout")
	if list then
		list.HorizontalAlignment = Enum.HorizontalAlignment.Left
	end
end

-- ==========================================================
-- STAT CARD
-- ==========================================================

--- One row of the stat card: an icon and the EXISTING amount label, moved in.
local function statRow(parent: Instance, spec: { key: string, icon: string, color: Color3 }, label: TextLabel?, order: number)
	local row = Instance.new("Frame")
	row.Name = spec.key
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 1 / #STAT_ROWS, 0)
	row.LayoutOrder = order
	row.Parent = parent

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Image = spec.icon
	icon.Size = UDim2.fromScale(0.8, 0.8)
	icon.Position = UDim2.fromScale(0.04, 0.5)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.ZIndex = 6
	icon.Parent = row
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = icon

	if label then
		label.Parent = row
		label.AnchorPoint = Vector2.new(0, 0.5)
		label.Position = UDim2.fromScale(0.26, 0.5)
		label.Size = UDim2.fromScale(0.72, 0.78)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextScaled = true
		label.TextColor3 = spec.color
		label.ZIndex = 6
		local limit = label:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
		limit.MinTextSize = 12
		limit.MaxTextSize = 30
		limit.Parent = label
	end
end

local function buildStatCard(ui: ScreenGui)
	if ui:FindFirstChild("StatHUD") then
		return
	end
	local bottom = ui:FindFirstChild("Bottom")
	local currencies = bottom and bottom:FindFirstChild("Currencies")
	if not currencies then
		return
	end

	-- The card: the pack's button anatomy at panel size - plate, inner face with
	-- studs and gradient - so it is unmistakably the same kit as the rail.
	local card = Instance.new("Frame")
	card.Name = "StatHUD"
	card.AnchorPoint = Vector2.new(0, 1)
	card.Position = UDim2.new(0, 14, 1, -14)
	card.Size = UDim2.fromScale(0.16, 0.155)
	card.BackgroundColor3 = Color3.fromRGB(16, 22, 44)
	card.BorderSizePixel = 0
	card.ZIndex = 4
	card.Parent = ui
	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = Vector2.new(170, 90)
	limit.MaxSize = Vector2.new(300, 112)
	limit.Parent = card
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = card
	local plateStroke = Instance.new("UIStroke")
	plateStroke.Thickness = 2
	plateStroke.Color = Color3.fromRGB(0, 0, 0)
	plateStroke.Parent = card

	local face = Instance.new("Frame")
	face.Name = "Frame"
	face.Size = UDim2.new(1, -6, 1, -6)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	face.BorderSizePixel = 0
	face.ZIndex = 5
	face.Parent = card
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, 10)
	faceCorner.Parent = face
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(44, 58, 104), Color3.fromRGB(24, 32, 64))
	gradient.Parent = face
	local studs = Instance.new("ImageLabel")
	studs.Name = "Studs"
	studs.BackgroundTransparency = 1
	studs.Image = "rbxassetid://76728843491214"
	studs.ImageTransparency = 0.82
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(28, 28)
	studs.Size = UDim2.fromScale(1, 1)
	studs.ZIndex = 5
	studs.Parent = face
	local studsCorner = Instance.new("UICorner")
	studsCorner.CornerRadius = UDim.new(0, 10)
	studsCorner.Parent = studs

	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.BackgroundTransparency = 1
	rows.Size = UDim2.new(1, -10, 1, -8)
	rows.Position = UDim2.fromScale(0.5, 0.5)
	rows.AnchorPoint = Vector2.new(0.5, 0.5)
	rows.ZIndex = 6
	rows.Parent = face
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = rows

	for order, spec in STAT_ROWS do
		local chip = currencies:FindFirstChild(spec.key)
		local label = chip and chip:FindFirstChild("Amount")
		statRow(rows, spec, if label and label:IsA("TextLabel") then label else nil, order)
	end

	-- The pack's Currencies strip is now empty of anything we show; hide it so
	-- its leftover layout cannot draw a stray chip. The DisplayCount label in
	-- Bottom stays where it is.
	(currencies :: GuiObject).Visible = false
end

-- ==========================================================
-- SCROLLING PANELS
-- ==========================================================

--- Every panel in Frames scrolls VERTICALLY and only vertically. The pack
--- shipped them XY with a canvas wider than the frame, so a touch drag
--- wandered sideways and the content drifted off the left edge. Buttons and
--- tabs inside a panel are unaffected: this is the canvas, not the content.
local function lockVerticalScroll(ui: ScreenGui)
	local frames = ui:FindFirstChild("Frames")
	if not frames then
		return
	end
	local function lock(list: Instance)
		if not list:IsA("ScrollingFrame") then
			return
		end
		list.ScrollingDirection = Enum.ScrollingDirection.Y
		list.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
		if list.CanvasSize.X.Scale ~= 0 or list.CanvasSize.X.Offset ~= 0 then
			list.CanvasSize = UDim2.new(0, 0, list.CanvasSize.Y.Scale, list.CanvasSize.Y.Offset)
		end
	end
	for _, panel in frames:GetChildren() do
		for _, child in panel:GetChildren() do
			lock(child)
		end
		panel.ChildAdded:Connect(lock)
	end
	-- Storage is built into Frames after this runs.
	frames.ChildAdded:Connect(function(panel)
		task.defer(function()
			for _, child in panel:GetChildren() do
				lock(child)
			end
			panel.ChildAdded:Connect(lock)
		end)
	end)
end

-- ==========================================================
-- TOUCH LAYOUT
-- ==========================================================
--
-- Phones and tablets get a different arrangement of the SAME elements: the
-- four menu buttons in a compact two-by-two block, the stats in a small card
-- at the top-left under Roblox's own buttons, the offer buttons pinned to the
-- right edge above the hold button, and every panel opened much larger.
-- Nothing is rebound or renamed; the pack's own handlers keep every button.

--- Menu tile size on touch, in pixels (before the HUD's UIScale).
local TOUCH_TILE = 60
local TOUCH_TILE_GAP = 8
--- Vertical gap between the two rows: room for the caption under each tile.
local TOUCH_TILE_LABEL_GAP = 26
--- Largest font any TextScaled label inside a panel may reach on touch, so a
--- short label in a tall row does not balloon.
local TOUCH_PANEL_MAX_TEXT = 26

local function layoutTouchRail(buttons: GuiObject, left: GuiObject)
	local width = TOUCH_TILE * 2 + TOUCH_TILE_GAP + RAIL_INSET.Offset
	buttons.AnchorPoint = Vector2.new(0, 0.5)
	buttons.Position = UDim2.new(0, 0, 0.56, 0)
	buttons.Size = UDim2.fromOffset(width, TOUCH_TILE * 2 + TOUCH_TILE_LABEL_GAP)
	left.Size = UDim2.fromScale(1, 1)
	local grid = left:FindFirstChildOfClass("UIGridLayout")
	if grid then
		grid.CellSize = UDim2.fromOffset(TOUCH_TILE, TOUCH_TILE)
		-- The row gap is the tile's own caption height: each tile's label
		-- hangs below its plate, and at a tighter gap the bottom row drew over
		-- the top row's words.
		grid.CellPadding = UDim2.fromOffset(TOUCH_TILE_GAP, TOUCH_TILE_LABEL_GAP)
		grid.FillDirection = Enum.FillDirection.Horizontal
		grid.FillDirectionMaxCells = 2
		grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
		grid.VerticalAlignment = Enum.VerticalAlignment.Center
		grid.StartCorner = Enum.StartCorner.TopLeft
	end
	-- Belt and braces on the layering: the TOP row draws over the bottom row,
	-- so a caption that still overhangs sits in front of the tile below it
	-- rather than being clipped behind it. Siblings sort by ZIndex here.
	local function layer(button: Instance)
		if not button:IsA("GuiObject") then
			return
		end
		local order = button.LayoutOrder
		button.ZIndex = if order <= 2 then 4 else 2
	end
	for _, button in left:GetChildren() do
		layer(button)
	end
	left.ChildAdded:Connect(function(child)
		task.defer(layer, child)
	end)
end

local function layoutTouchStats(ui: ScreenGui)
	local cardHud = ui:FindFirstChild("StatHUD")
	if not cardHud or not cardHud:IsA("GuiObject") then
		return
	end
	-- Top-left, under Roblox's menu and chat buttons, above the menu block.
	cardHud.AnchorPoint = Vector2.new(0, 0)
	cardHud.Position = UDim2.fromOffset(12, 50)
	cardHud.Size = UDim2.fromOffset(156, 70)
	local limit = cardHud:FindFirstChildOfClass("UISizeConstraint")
	if limit then
		limit.MinSize = Vector2.new(140, 64)
		limit.MaxSize = Vector2.new(170, 76)
	end
	for _, label in cardHud:GetDescendants() do
		if label:IsA("TextLabel") then
			local textLimit = label:FindFirstChildOfClass("UITextSizeConstraint")
			if textLimit then
				textLimit.MaxTextSize = 18
			end
		end
	end
end

local function layoutTouchPanels(ui: ScreenGui)
	local frames = ui:FindFirstChild("Frames")
	if not frames or not frames:IsA("GuiObject") then
		return
	end
	-- The container takes almost the whole viewport; each panel almost all of
	-- the container. Their aspect constraints (FitWithinMaxSize) keep every
	-- panel its authored shape, so this only ever grows them, never distorts.
	frames.Size = UDim2.fromScale(0.96, 1)

	local function grow(panel: Instance)
		if not panel:IsA("GuiObject") then
			return
		end
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.52)
		panel.Size = UDim2.fromScale(0.94, 0.9)
		-- Bounded text: everything in a panel scales, and a two-word label in
		-- a big row would otherwise outgrow the button beside it.
		for _, label in panel:GetDescendants() do
			if label:IsA("TextLabel") or label:IsA("TextButton") then
				if label.TextScaled and not label:FindFirstChildOfClass("UITextSizeConstraint") then
					local limit = Instance.new("UITextSizeConstraint")
					limit.MaxTextSize = TOUCH_PANEL_MAX_TEXT
					limit.Parent = label
				end
			end
		end
	end
	for _, panel in frames:GetChildren() do
		grow(panel)
	end
	frames.ChildAdded:Connect(function(panel)
		task.defer(grow, panel)
	end)
end

--- The Guardian / Slap offer buttons: pinned to the right safe edge, two
--- fixed-size tiles stacked under the top strip, clear of the hold button
--- and the jump button below them.
local function layoutTouchOffers(ui: ScreenGui)
	local rail: Frame? = nil
	for _, child in ui:GetChildren() do
		if child:IsA("Frame") and child.Name:upper():find("UI FOR ANIMAL", 1, true) then
			rail = child
			break
		end
	end
	if not rail then
		return
	end
	local tile = 64
	local gap = 8
	local aspect = rail:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then
		aspect:Destroy()
	end
	rail.AnchorPoint = Vector2.new(1, 0)
	rail.Position = UDim2.new(1, -10, 0, 74)
	rail.Size = UDim2.fromOffset(tile, tile * 2 + gap)
	local grid = rail:FindFirstChildOfClass("UIGridLayout")
	if grid then
		grid.CellSize = UDim2.fromOffset(tile, tile)
		grid.CellPadding = UDim2.fromOffset(gap, gap)
		grid.FillDirection = Enum.FillDirection.Vertical
		grid.FillDirectionMaxCells = 2
		grid.HorizontalAlignment = Enum.HorizontalAlignment.Right
		grid.VerticalAlignment = Enum.VerticalAlignment.Top
	end
end

local function applyTouchLayout(ui: ScreenGui)
	local buttons = ui:FindFirstChild("Buttons")
	local left = buttons and buttons:FindFirstChild("Left")
	if buttons and buttons:IsA("GuiObject") and left and left:IsA("GuiObject") then
		layoutTouchRail(buttons, left)
	end
	layoutTouchStats(ui)
	layoutTouchPanels(ui)
	layoutTouchOffers(ui)
end

-- ==========================================================
-- START
-- ==========================================================

function HUDLayoutController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		return
	end

	local buttons = ui:FindFirstChild("Buttons")
	local left = buttons and buttons:FindFirstChild("Left")
	if buttons and buttons:IsA("GuiObject") and left and left:IsA("GuiObject") then
		local oldSettings = left:FindFirstChild("Settings")
		buildSettingsGear(ui, if oldSettings and oldSettings:IsA("GuiButton") then oldSettings else nil)
		layoutRail(buttons, left)
		tintRail(left)
	end

	buildStatCard(ui)
	lockVerticalScroll(ui)

	if Device.isTouch() then
		applyTouchLayout(ui)
	end

	-- The gear pops in with the rest of the HUD rather than appearing.
	local gear = ui:FindFirstChild("SettingsGear", true)
	if gear and gear:IsA("GuiObject") then
		UIAnim.popIn(gear, 0.6)
	end
end

return HUDLayoutController
