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
local RunService = game:GetService("RunService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local HUDLayoutController = {}

local player = Players.LocalPlayer

--- Inset of the rail from the left screen edge.
local RAIL_INSET = UDim.new(0, 12)

--- Per-button identity: ONE accent colour, drawn as the tile's single ring
--- (and a faint tint of its face). The tiles themselves are dark charcoal -
--- the owner's reference HUD - not the pack's full-colour gradients.
type Accent = { ring: Color3 }
local ACCENTS: { [string]: Accent } = {
	Shop = { ring = Color3.fromRGB(255, 92, 124) },
	Upgrades = { ring = Color3.fromRGB(86, 232, 140) },
	Index = { ring = Color3.fromRGB(96, 150, 255) },
	Storage = { ring = Color3.fromRGB(255, 170, 60) },
	-- [trading-gifting-boards] The Trade opener (TradeController).
	Trade = { ring = Color3.fromRGB(198, 112, 255) },
}

--- The tile: dark charcoal, top-lit.
local TILE_TOP = Color3.fromRGB(40, 43, 54)
local TILE_BOTTOM = Color3.fromRGB(24, 26, 34)
--- Corner radius and ring thickness of every tile.
local TILE_RADIUS = 14
local TILE_RING = 2.5
--- Desktop tile size and column gap; the touch layout derives its own.
local RAIL_TILE = 60
local RAIL_GAP = 10
--- Where the rail's top sits: under Roblox's own top-left buttons.
local RAIL_TOP = 58

local STAT_ROWS = {
	{ key = "Cash", icon = "rbxassetid://112931960147028", color = Color3.fromRGB(110, 240, 130) },
	{ key = "Income", icon = "rbxassetid://112931960147028", color = Color3.fromRGB(180, 255, 190) },
	{ key = "Speed", icon = "rbxassetid://102080723305863", color = Color3.fromRGB(110, 210, 255) },
}
--- The economy pill's height and figure size, desktop and touch.
local STAT_HEIGHT = 38
local STAT_TEXT = 16
local STAT_HEIGHT_TOUCH = 32
local STAT_TEXT_TOUCH = 14
local WHITE = Color3.fromRGB(255, 255, 255)

-- ==========================================================
-- COLOUR
-- ==========================================================

--- Restyles one rail tile to the owner's reference: a compact rounded square,
--- dark charcoal, ONE accent ring, the icon alone in the middle - no caption,
--- no studs, no rays, no plate lip. The pack's own click/hover script still
--- drives it (the button keeps its name and its stamps); this only changes
--- how it looks, and adds the hover glow and the click sound.
function HUDLayoutController.tint(button: GuiButton, accent: Accent)
	button.BackgroundColor3 = WHITE
	button.BackgroundTransparency = 0
	button.BorderSizePixel = 0
	local plateGradient = button:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	plateGradient.Rotation = 90
	plateGradient.Color = ColorSequence.new(TILE_TOP, TILE_BOTTOM)
	plateGradient.Parent = button
	local plateCorner = button:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(0, TILE_RADIUS)
	plateCorner.Parent = button
	local ring = button:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	ring.Color = accent.ring
	ring.Thickness = TILE_RING
	ring.Transparency = 0
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = button

	-- The pack's inset body: flattened into the tile and its own ring off.
	local face = button:FindFirstChild("Frame")
	if face and face:IsA("GuiObject") then
		face.AnchorPoint = Vector2.new(0.5, 0.5)
		face.Position = UDim2.fromScale(0.5, 0.5)
		face.Size = UDim2.fromScale(1, 1)
		face.BackgroundTransparency = 1
		local faceRing = face:FindFirstChildOfClass("UIStroke")
		if faceRing then
			faceRing.Enabled = false
		end
		for _, child in face:GetChildren() do
			if (child:IsA("ImageLabel") or child:IsA("CanvasGroup")) and child.Name ~= "Icon" then
				child.Visible = false
			end
		end
		local icon = face:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.5)
			icon.Size = UDim2.fromScale(0.64, 0.64)
			icon.ScaleType = Enum.ScaleType.Fit
			icon.Visible = true
		end
	end
	local title = button:FindFirstChild("Title")
	if title and title:IsA("GuiObject") then
		title.Visible = false
	end

	-- Hover glow and click sound, once per tile. The pack already scales it
	-- on hover and press; this adds the ring lighting up and the click.
	if not button:GetAttribute("RailStyled") then
		button:SetAttribute("RailStyled", true)
		button.MouseEnter:Connect(function()
			ring.Thickness = TILE_RING + 1
			plateGradient.Color = ColorSequence.new(TILE_TOP:Lerp(accent.ring, 0.16), TILE_BOTTOM:Lerp(accent.ring, 0.08))
		end)
		button.MouseLeave:Connect(function()
			ring.Thickness = TILE_RING
			plateGradient.Color = ColorSequence.new(TILE_TOP, TILE_BOTTOM)
		end)
		button.MouseButton1Click:Connect(function()
			Audio.play("UiClick")
		end)
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

--- The gear's visible disc, and the smallest on-screen touch target it may
--- have AFTER MainUI's UIScale (Apple / Google guidance: 44 px).
local GEAR_FACE = 44
local GEAR_MIN_TARGET = 44

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
	--
	-- TOUCH TARGET. MainUI carries a UIScale (0.85, or 0.72 on a phone - see
	-- HUDController.applyScale), so a 44 px button was really a 32 px target
	-- under a thumb. The BUTTON is now an invisible hit area sized so that it
	-- is still >= 44 px after that scale; the round face inside it keeps the
	-- old 44 px look.
	local button = Instance.new("ImageButton")
	button.Name = "Settings"
	button.Size = UDim2.fromOffset(GEAR_FACE, GEAR_FACE)
	button.Position = UDim2.fromScale(0.5, 0.5)
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Image = ""
	button.ZIndex = 6
	button.Parent = holder

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromOffset(GEAR_FACE, GEAR_FACE)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	face.BackgroundTransparency = 0.08
	face.Active = false
	face.ZIndex = 6
	face.Parent = button
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = face
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.75
	stroke.Parent = face

	local uiScale = ui:FindFirstChildWhichIsA("UIScale")
	local function sizeHitArea()
		local scale = if uiScale then math.max(uiScale.Scale, 0.1) else 1
		local side = math.max(GEAR_FACE, math.ceil(GEAR_MIN_TARGET / scale))
		button.Size = UDim2.fromOffset(side, side)
		holder.Size = UDim2.new(0, math.max(56, side + 4), 1, 0)
	end
	sizeHitArea()
	if uiScale then
		uiScale:GetPropertyChangedSignal("Scale"):Connect(sizeHitArea)
	end

	local gear = Instance.new("ImageLabel")
	gear.Name = "Gear"
	gear.BackgroundTransparency = 1
	gear.Image = "rbxassetid://127441972943624" -- the pack's own gear icon
	gear.ImageColor3 = Color3.fromRGB(255, 255, 255)
	gear.Size = UDim2.fromScale(0.62, 0.62)
	gear.Position = UDim2.fromScale(0.5, 0.5)
	gear.AnchorPoint = Vector2.new(0.5, 0.5)
	gear.ZIndex = 7
	gear.Parent = face
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

--- The five tiles, in the order the column must draw them. Set explicitly
--- rather than trusted to whoever created each button: Upgrades, Storage and
--- Trade are cloned in later by their own controllers, and the pack's Shop
--- and Index carry whatever LayoutOrder the pack shipped with.
local MENU_ORDER = { Shop = 1, Upgrades = 2, Index = 3, Storage = 4, Trade = 5 }

--- The rail as ONE column of fixed tiles, from a given tile size and gap:
--- top-left under Roblox's buttons, no panel behind it, no padding. Shared
--- by the desktop and touch layouts, which differ only in the numbers.
local function layoutColumn(buttons: GuiObject, left: GuiObject, tile: number, gap: number, top: number)
	local tiles = 0
	for _, child in left:GetChildren() do
		if MENU_ORDER[child.Name] and child:IsA("GuiObject") then
			tiles += 1
			child.LayoutOrder = MENU_ORDER[child.Name]
		end
	end
	tiles = math.max(tiles, 1)
	local pad = buttons:FindFirstChildOfClass("UIPadding")
	if pad then
		pad:Destroy()
	end
	buttons.AnchorPoint = Vector2.new(0, 0)
	buttons.Position = UDim2.fromOffset(RAIL_INSET.Offset, top)
	buttons.Size = UDim2.fromOffset(tile, tile * tiles + gap * (tiles - 1))
	left.AnchorPoint, left.Position, left.Size = Vector2.zero, UDim2.new(), UDim2.fromScale(1, 1)
	local grid = left:FindFirstChildOfClass("UIGridLayout")
	if grid then
		grid.CellSize = UDim2.fromOffset(tile, tile)
		grid.CellPadding = UDim2.fromOffset(0, gap)
		grid.FillDirection = Enum.FillDirection.Horizontal
		-- THE LINE THAT MAKES IT A COLUMN: one per row.
		grid.FillDirectionMaxCells = 1
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
		grid.VerticalAlignment = Enum.VerticalAlignment.Top
		grid.StartCorner = Enum.StartCorner.TopLeft
	end
	local list = buttons:FindFirstChildOfClass("UIListLayout")
	if list then
		list.HorizontalAlignment = Enum.HorizontalAlignment.Left
	end
end

local function layoutRail(buttons: GuiObject, left: GuiObject)
	layoutColumn(buttons, left, RAIL_TILE, RAIL_GAP, RAIL_TOP)
	-- Tiles added later (Upgrades, Storage, Trade arrive after this pass)
	-- grow the column.
	left.ChildAdded:Connect(function()
		task.defer(layoutColumn, buttons, left, RAIL_TILE, RAIL_GAP, RAIL_TOP)
	end)
end

-- ==========================================================
-- STAT CARD
-- ==========================================================

--- One item of the economy pill: an icon and the EXISTING amount label,
--- moved in, sized by its text. A thin divider separates it from the next.
local function statItem(parent: Instance, spec: { key: string, icon: string, color: Color3 }, label: TextLabel?, order: number, divider: boolean)
	local item = Instance.new("Frame")
	item.Name = spec.key
	item.BackgroundTransparency = 1
	item.AutomaticSize = Enum.AutomaticSize.X
	item.Size = UDim2.new(0, 0, 1, 0)
	item.LayoutOrder = order * 2
	item.Parent = parent
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.Padding = UDim.new(0, 6)
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = item

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Image = spec.icon
	icon.Size = UDim2.new(0.6, 0, 0.6, 0)
	icon.LayoutOrder = 1
	icon.ZIndex = 6
	icon.Parent = item
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = icon

	if label then
		local limit = label:FindFirstChildOfClass("UITextSizeConstraint")
		if limit then
			limit:Destroy()
		end
		label.Parent = item
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.new(0, 0, 1, 0)
		label.Position = UDim2.new()
		label.AnchorPoint = Vector2.zero
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextScaled = false
		label.Font = Enum.Font.GothamBold
		label.TextSize = STAT_TEXT
		label.TextColor3 = spec.color
		label.TextStrokeTransparency = 1
		label.LayoutOrder = 2
		label.ZIndex = 6
	end

	if divider then
		local line = Instance.new("Frame")
		line.Name = `Divider{order}`
		line.BackgroundColor3 = Color3.fromRGB(78, 84, 104)
		line.BorderSizePixel = 0
		line.Size = UDim2.new(0, 1, 0.55, 0)
		line.LayoutOrder = order * 2 + 1
		line.ZIndex = 6
		line.Parent = parent
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

	-- ONE PILL. Cash, Cash/s and Speed in a single compact horizontal pill,
	-- bottom-left: a dark translucent capsule, three icon + figure items with
	-- thin dividers, sized by its text. The owner's reference HUD. It keeps
	-- the name StatHUD so UIStateController still hides it during a carry.
	local card = Instance.new("Frame")
	card.Name = "StatHUD"
	card.AnchorPoint = Vector2.new(0, 1)
	card.Position = UDim2.new(0, 12, 1, -12)
	card.AutomaticSize = Enum.AutomaticSize.X
	card.Size = UDim2.fromOffset(0, STAT_HEIGHT)
	card.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	card.BackgroundTransparency = 0.22
	card.BorderSizePixel = 0
	card.ZIndex = 4
	card.Parent = ui
	local capsule = Instance.new("UICorner")
	capsule.CornerRadius = UDim.new(1, 0)
	capsule.Parent = card
	local edge = Instance.new("UIStroke")
	edge.Color = Color3.fromRGB(64, 70, 88)
	edge.Thickness = 1.5
	edge.Transparency = 0.15
	edge.Parent = card
	local inset = Instance.new("UIPadding")
	inset.PaddingLeft = UDim.new(0, 12)
	inset.PaddingRight = UDim.new(0, 12)
	inset.Parent = card

	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.BackgroundTransparency = 1
	rows.AutomaticSize = Enum.AutomaticSize.X
	rows.Size = UDim2.new(0, 0, 1, 0)
	rows.ZIndex = 6
	rows.Parent = card
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = rows

	for order, spec in STAT_ROWS do
		local chip = currencies:FindFirstChild(spec.key)
		local label = chip and chip:FindFirstChild("Amount")
		statItem(rows, spec, if label and label:IsA("TextLabel") then label else nil, order, order < #STAT_ROWS)
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

-- ==========================================================
-- THE MENU BLOCK: ALWAYS TWO BY TWO
-- ==========================================================
--
-- Shop and Upgrades on top, Index and Storage below, on every phone and
-- tablet, whatever its width or aspect ratio. Never one row of four.
--
-- THE SIZE IS MEASURED PER SCREEN. The block has to sit between two things:
-- the stat card above it, and Roblox's movement thumbstick below it. The
-- thumbstick is NOT a guess here - it lives in PlayerGui.TouchGui, so its
-- resting ring (ThumbstickStart) is read from the real layout on the real
-- device. From the PlayerModule's own source, that ring is 74px across and
-- sits 64-93px up from the bottom-left corner depending on which control style
-- Roblox serves, which is why no fixed fraction of the screen can be right.
--
-- ONE COLUMN of icon tiles (the owner's reference HUD): the tile is whatever
-- fits five between the Roblox buttons and the thumbstick, 44-60 px.

--- Menu tile size on touch, in pixels. The owner's size, used whenever it fits.
local TOUCH_TILE = 60
--- The smallest tile drawn before the block is shrunk as a whole instead.
local TOUCH_TILE_MIN = 44
local TOUCH_TILE_GAP = 8
--- Where the touch rail starts: under Roblox's top-left buttons.
local RAIL_TOP_TOUCH = 52
--- Clearance kept from the stat card above and the thumbstick ring below.
local TOUCH_BLOCK_MARGIN = 8
--- Largest font any TextScaled label inside a panel may reach on touch, so a
--- short label in a tall row does not balloon.
local TOUCH_PANEL_MAX_TEXT = 26

--- Top of Roblox's resting thumbstick ring, in `ui`'s local coordinates, or
--- nil when there is no thumbstick to measure (keyboard, gamepad, or the
--- touch controls not built yet).
local function thumbstickTop(ui: ScreenGui): number?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	local ring = touchGui and touchGui:FindFirstChild("ThumbstickStart", true)
	if ring and ring:IsA("GuiObject") and ring.AbsoluteSize.Y > 0 then
		-- AbsolutePosition shares one space across every ScreenGui, so taking
		-- away the HUD's own AbsolutePosition lands it in the HUD's coordinates.
		return ring.AbsolutePosition.Y - ui.AbsolutePosition.Y
	end
	return nil
end

--- Lays the four menu tiles out as a two-by-two block sized for THIS screen.
--- Safe to call again at any time: it recomputes from live measurements and
--- rewrites every property it owns.
local function fitTouchRail(ui: ScreenGui, buttons: GuiObject, left: GuiObject)
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize.Y < 500 then return end -- MobileHudLayout owns the landscape rail.
	local hudHeight = ui.AbsoluteSize.Y
	if hudHeight <= 0 then
		return
	end
	local hudScale = 1
	local hudUiScale = ui:FindFirstChildOfClass("UIScale")
	if hudUiScale and hudUiScale.Scale > 0 then
		hudScale = hudUiScale.Scale
	end

	-- ONE COLUMN of icon tiles under Roblox's top-left buttons, ending above
	-- the thumbstick's resting ring (or the economy pill when there is no
	-- ring yet). The tile is whatever fits five in that span, between the
	-- 44 px finger minimum and the desktop size. In the HUD's local pixels,
	-- before its UIScale.
	local tiles = 0
	for _, child in left:GetChildren() do
		if MENU_ORDER[child.Name] and child:IsA("GuiObject") then
			tiles += 1
		end
	end
	tiles = math.max(tiles, 1)
	local top = RAIL_TOP_TOUCH / hudScale
	local ringTop = thumbstickTop(ui)
	local floorY = ((ringTop or (hudHeight - 60)) - TOUCH_BLOCK_MARGIN) / hudScale
	local tile = math.clamp(math.floor((floorY - top - TOUCH_TILE_GAP * (tiles - 1)) / tiles), TOUCH_TILE_MIN, TOUCH_TILE)
	local fit = buttons:FindFirstChild("FitScale")
	if fit and fit:IsA("UIScale") then
		fit.Scale = 1
	end
	layoutColumn(buttons, left, tile, TOUCH_TILE_GAP, top)
	for _, button in left:GetChildren() do
		if MENU_ORDER[button.Name] and button:IsA("GuiObject") then
			button.ZIndex = 4
		end
	end
end

local function layoutTouchRail(ui: ScreenGui, buttons: GuiObject, left: GuiObject)
	fitTouchRail(ui, buttons, left)
	-- Again once the frame has laid out, now that the stat card's and the
	-- thumbstick's real positions can be read.
	task.spawn(function()
		RunService.Heartbeat:Wait()
		fitTouchRail(ui, buttons, left)
	end)
	-- Upgrades and Storage arrive after this pass; place them the moment they do.
	left.ChildAdded:Connect(function(child)
		if MENU_ORDER[child.Name] then
			task.defer(fitTouchRail, ui, buttons, left)
		end
	end)

	-- IT STAYS TWO BY TWO. If anything - the pack, a future controller, a
	-- stray tween - rewrites the grid, the block is rebuilt on the spot rather
	-- than left as a row of four. Guarded so our own rewrite does not recurse.
	local grid = left:FindFirstChildOfClass("UIGridLayout")
	if grid then
		local refitting = false
		local function guard()
			if refitting then
				return
			end
			if grid.FillDirectionMaxCells ~= 2 or grid.FillDirection ~= Enum.FillDirection.Horizontal then
				refitting = true
				fitTouchRail(ui, buttons, left)
				refitting = false
			end
		end
		grid:GetPropertyChangedSignal("FillDirectionMaxCells"):Connect(guard)
		grid:GetPropertyChangedSignal("FillDirection"):Connect(guard)
	end

	-- A rotation, a resize, or the stat card and thumbstick settling after we
	-- first measured: refit on the viewport signal, and once more a little
	-- later for whatever lands after start-up.
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			task.defer(fitTouchRail, ui, buttons, left)
		end)
	end
	task.delay(1.5, fitTouchRail, ui, buttons, left)
	task.delay(4, fitTouchRail, ui, buttons, left)
end

local function layoutTouchStats(ui: ScreenGui)
	local cardHud = ui:FindFirstChild("StatHUD")
	if not cardHud or not cardHud:IsA("GuiObject") then
		return
	end
	-- The same pill, a touch smaller, bottom-left.
	cardHud.AnchorPoint = Vector2.new(0, 1)
	cardHud.Position = UDim2.new(0, 10, 1, -10)
	cardHud.Size = UDim2.fromOffset(0, STAT_HEIGHT_TOUCH)
	for _, label in cardHud:GetDescendants() do
		if label:IsA("TextLabel") then
			label.TextSize = STAT_TEXT_TOUCH
		end
	end
end

local function layoutTouchPanels(ui: ScreenGui)
	local frames = ui:FindFirstChild("Frames")
	if not frames or not frames:IsA("GuiObject") then
		return
	end
	-- The container takes most of the viewport and each panel most of the
	-- container - but not all of either. At 0.94 x 0.9 a panel reached the
	-- phone's edges and covered the Roblox buttons, the jump button and the
	-- thumbstick; at 0.86 x 0.82 it reads as a window over the game with the
	-- controls still visible around it. Their aspect constraints
	-- (FitWithinMaxSize) keep every panel its authored shape.
	frames.Size = UDim2.fromScale(0.92, 1)

	local function grow(panel: Instance)
		if not panel:IsA("GuiObject") then
			return
		end
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.52)
		panel.Size = UDim2.fromScale(0.86, 0.82)
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
	-- The stat card first: the menu block is measured against where it ends.
	layoutTouchStats(ui)
	if buttons and buttons:IsA("GuiObject") and left and left:IsA("GuiObject") then
		layoutTouchRail(ui, buttons, left)
	end
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

	-- ONE BORDER PER ELEMENT, for the whole of MainUI and everything built into
	-- it later. The pack draws a border on an outer plate AND on the inset body
	-- inside it, so every card, nav button and header shipped with a thin second
	-- line hugging its edge. See PanelStyle.singleBorder. This runs here because
	-- the layout pass is already the one gated place that owns MainUI before any
	-- panel clones a component out of it.
	PanelStyle.watchBorders(ui)

	-- Once per session: applyTouchLayout wires its own refit listeners, so it
	-- must not be run twice. A session that BECOMES touch (the Studio emulator
	-- switched, a keyboard detached) gets it then. The reverse is not undone:
	-- the touch layout is usable with a mouse, and a live desktop re-layout
	-- would need every property it rewrote remembered.
	local touchApplied = false
	local function applyTouchOnce()
		if touchApplied then
			return
		end
		touchApplied = true
		applyTouchLayout(ui)
	end
	if Device.isTouch() then
		applyTouchOnce()
	end
	Device.onTouchChanged(function(touch)
		if touch then
			applyTouchOnce()
		end
	end)

	require(script.Parent.MobileHudLayout).start(ui)

	-- The gear pops in with the rest of the HUD rather than appearing.
	local gear = ui:FindFirstChild("SettingsGear", true)
	if gear and gear:IsA("GuiObject") then
		UIAnim.popIn(gear, 0.6)
	end
end

return HUDLayoutController
