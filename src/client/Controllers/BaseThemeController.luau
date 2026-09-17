--!strict
--[[
	BaseThemeController
	The BASE tab of the Upgrades panel: plot themes and pedestal skins
	(BaseThemeConfig) as a grid of cards under a "currently equipped" banner.

	ATTACHED, NOT STARTED. UpgradesController builds its treadmill card and
	then calls `attach(panel, scroll, card, hooks)`. This adds the
	TREADMILL | BASE tab bar above the card and the BASE page in the same
	space; the treadmill card only moves down to make room for the bar.

	LAYOUT (round3-ui-base-settings redesign)
	  tab bar  two large pills with an icon each; the active one is lit green.
	  banner   fixed, NOT scrolled: a small turning 3D diorama of what is
	           equipped (or of the card last tapped - "PREVIEW", with BACK),
	           the theme name and the equipped pedestal. It stays out of the
	           scrolling list on purpose: a ViewportFrame does not belong
	           inside the list's CanvasGroup clip guard.
	  grid     a ScrollingFrame (AutomaticCanvasSize) wrapped by
	           ClipSafe.guard: THEMES cards (2 columns, 1 on a narrow panel)
	           then PEDESTAL SKINS cards (3 / 2 columns). Every card has ONE
	           full-width action: BUY $X / R$ X / EQUIP / EQUIPPED.
	While BASE is open the panel is scaled up a little (hooks.setBoost ->
	UpgradesController), still clamped to the screen by the panel's fit pass,
	so the cards read at a glance on a laptop and on a phone.

	WHY NOTHING HERE IS CLONED FROM THE PACK
	The first version cloned the treadmill card's Money button into each row.
	Those pack buttons escaped the list's clip and drew over the header and
	the world while scrolling (Shared.Util.ClipSafe explains why), and each
	dragged a UIScale, a ripple CanvasGroup and a rotation punch along. The
	cards and buttons below are plain Frames / TextButtons in the pack's own
	palette (dark plate + ink stroke + vertical gradient + studs texture,
	FredokaOne) with a light press feedback that never rotates, and every
	button is stamped so the pack's LocalScript leaves it alone.

	SENDS INTENT ONLY. Buy / equip / buy-pass go to BaseThemeRequest with a
	KEY; the server checks ownership and price and paints the plot. What is
	owned and equipped arrives as StatePush `baseTheme`.

	STUDIO ONLY
	  * Player attribute `BaseUiPreview` (DebugCommands/BasesUI
	    `baseUiPreview`): the page renders a fixed mix of every card state
	    from fake data and sends NOTHING, for screenshots.
	  * Player attribute `DebugUiAudit` (`uiAudit`): prints what, in the open
	    Upgrades / Settings panel, could still draw outside the panel.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local BaseThemeConfig = require(ReplicatedStorage.Shared.Config.BaseThemeConfig)
local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ToastController = require(script.Parent.ToastController)

local BaseThemeController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- LOOK
-- ==========================================================

local WHITE = Color3.fromRGB(255, 255, 255)
local BLACK = Color3.fromRGB(0, 0, 0)
local INK = Color3.fromRGB(10, 12, 20)
local DIM = Color3.fromRGB(190, 202, 224)
local GOLD = Color3.fromRGB(255, 214, 64)
local GREEN = Color3.fromRGB(110, 245, 140)
local RED_TEXT = Color3.fromRGB(255, 132, 132)
local PLATE = Color3.fromRGB(16, 22, 42)
local FACE_TOP = Color3.fromRGB(46, 60, 108)
local FACE_BOTTOM = Color3.fromRGB(24, 32, 64)
local STONE = Color3.fromRGB(196, 190, 176)
local ORB = Color3.fromRGB(180, 106, 255)

local EQUIP_BLUE = Color3.fromRGB(46, 116, 238)
local BUY_GREEN = Color3.fromRGB(16, 178, 70)
local ROBUX_GOLD = Color3.fromRGB(244, 168, 24)
local EQUIPPED_GREEN = Color3.fromRGB(36, 132, 72)
local DISABLED = Color3.fromRGB(78, 86, 108)
local OWNED_EDGE = Color3.fromRGB(80, 190, 120)
local TAB_ON_TOP = Color3.fromRGB(96, 232, 120)
local TAB_ON_BOTTOM = Color3.fromRGB(18, 150, 64)
local TAB_OFF_TOP = Color3.fromRGB(58, 72, 120)
local TAB_OFF_BOTTOM = Color3.fromRGB(30, 38, 74)

local STUDS = "rbxassetid://76728843491214" -- the pack's stud texture

--- Price tiers for the theme cards' tag (cheapest first).
local TIERS = {
	{ below = 1e6, word = "COMMON", color = Color3.fromRGB(96, 200, 96) },
	{ below = 1e8, word = "RARE", color = Color3.fromRGB(70, 150, 255) },
	{ below = 1e10, word = "EPIC", color = Color3.fromRGB(170, 96, 255) },
	{ below = math.huge, word = "LEGENDARY", color = Color3.fromRGB(255, 150, 40) },
}

-- ==========================================================
-- GEOMETRY  (Size offsets, i.e. before any UIScale;
-- ClipSafe.scaleChain converts to screen pixels)
-- ==========================================================

local PAD = 8 -- card edge to content
local GAP = 5 -- between stacked card parts
local CELL_GAP = 10 -- between cards
local SIDE_PAD = 6 -- list edge to cards
local NAME_H = 24
local DESC_H = 17
local TAG_H = 22
local SKIN_NAME_H = 22
local BUTTON_H = 46 -- >= 44 px on touch: the panel scale is >= 1 there
local SECTION_H = 36
--- Screen pixels of list width from which themes get 2 columns, skins 3.
local WIDE_LIST = 430
--- Panel scale-up while the BASE tab is open (see the header).
--- 1.45 after the Studio review: at 1.15 only one row of cards fitted and the
--- banner label was clipped. UpgradesController still clamps it on-screen.
local BASE_BOOST = 1.45

-- ==========================================================
-- STATE
-- ==========================================================

type Tab = { button: TextButton, gradient: UIGradient, stroke: UIStroke, label: TextLabel }

type Card = {
	key: string,
	isTheme: boolean,
	cash: number,
	passKey: string?,
	root: TextButton,
	plateStroke: UIStroke,
	tile: Frame,
	badge: Frame,
	button: TextButton,
	buttonGradient: UIGradient,
	caption: TextLabel,
	tagPill: Frame?,
	tagWord: TextLabel?,
	tagPrice: TextLabel?,
	action: (() -> ())?,
	equipped: boolean,
}

type Hooks = { setBoost: ((number) -> ())? }

local panelRef: Frame? = nil
local treadmillCard: Frame? = nil
local page: Frame? = nil
local list: ScrollingFrame? = nil
local themeGrid: UIGridLayout? = nil
local skinGrid: UIGridLayout? = nil
local themeCount: TextLabel? = nil
local skinCount: TextLabel? = nil
local bannerView: ViewportFrame? = nil
local bannerTitle: TextLabel? = nil
local bannerName: TextLabel? = nil
local bannerSub: TextLabel? = nil
local bannerBack: TextButton? = nil
local tabs: { [string]: Tab } = {}
local cards: { Card } = {}
local hooksRef: Hooks = {}

local activeTab = "Treadmill"
local previewKey: string? = nil
local latest: any = nil
local shownPreview: string? = nil
local layoutSignature = ""
local lastEquipped: { [string]: string } = {}
local lastOwned: { [string]: boolean }? = nil

-- ==========================================================
-- SMALL BUILDERS
-- ==========================================================

local function corner(parent: Instance, radius: UDim)
	local round = Instance.new("UICorner")
	round.CornerRadius = radius
	round.Parent = parent
end

local function edge(parent: Instance, thickness: number, color: Color3): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = color
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

local function shade(parent: Instance, top: Color3, bottom: Color3): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90 -- a UIGradient property, not the element's
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Parent = parent
	return gradient
end

local function text(parent: Instance, name: string, value: string, color: Color3, align: Enum.TextXAlignment?, maxSize: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = color
	label.TextXAlignment = align or Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = value
	label.ZIndex = 6
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 8
	limit.MaxTextSize = maxSize or 26
	limit.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = INK
	stroke.Parent = label
	label.Parent = parent
	return label
end

--- A Frame placed in the parent's scale space.
local function block(parent: Instance, x: number, y: number, w: number, h: number, color: Color3, z: number, transparency: number?): Frame
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency or 0
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(w, h)
	frame.ZIndex = z
	frame.Parent = parent
	return frame
end

--- A square dot centred on (x, y), `h` of the parent's height tall.
local function dot(parent: Instance, x: number, y: number, h: number, color: Color3, z: number, round: boolean): Frame
	local frame = block(parent, x, y, h, h, color, z)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.DominantAxis = Enum.DominantAxis.Height
	ratio.Parent = frame
	corner(frame, if round then UDim.new(1, 0) else UDim.new(0.25, 0))
	return frame
end

--- The pack's card body: dark plate, ink edge, gradient face, studs.
local function plate(root: GuiObject, radius: number): UIStroke
	root.BackgroundColor3 = PLATE
	root.BorderSizePixel = 0
	corner(root, UDim.new(0, radius))
	local stroke = edge(root, 2.5, INK)
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.BorderSizePixel = 0
	face.BackgroundColor3 = WHITE
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.new(1, -6, 1, -6)
	face.ZIndex = root.ZIndex
	face.Parent = root
	corner(face, UDim.new(0, math.max(radius - 2, 2)))
	shade(face, FACE_TOP, FACE_BOTTOM)
	local studs = Instance.new("ImageLabel")
	studs.Name = "Studs"
	studs.BackgroundTransparency = 1
	studs.Image = STUDS
	studs.ImageTransparency = 0.86
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(28, 28)
	studs.Size = UDim2.fromScale(1, 1)
	studs.ZIndex = root.ZIndex
	studs.Parent = face
	corner(studs, UDim.new(0, math.max(radius - 2, 2)))
	return stroke
end

--- Hover / press feedback for our own buttons: scale only, never rotation,
--- no ripple, and stamped so the pack's LocalScript does not bind it.
local function feedback(button: GuiButton, hover: number)
	button:SetAttribute("_UIHandlerSetup", true)
	button:SetAttribute("AnimBound", true)
	button:SetAttribute(ClipSafe.NO_ROTATION, true)
	button:SetAttribute(ClipSafe.NO_RIPPLE, true)
	button.AutoButtonColor = false
	button.Active = true
	local scale = Instance.new("UIScale")
	scale.Parent = button
	local hovering = false
	local function to(value: number, info: TweenInfo)
		if Effects.isReduced() then
			scale.Scale = 1
			return
		end
		TweenService:Create(scale, info, { Scale = value }):Play()
	end
	button.MouseEnter:Connect(function()
		hovering = true
		to(hover, UIAnim.HOVER)
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		to(1, UIAnim.UNHOVER)
	end)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			to(0.95, UIAnim.PRESS)
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			to(if hovering then hover else 1, UIAnim.RELEASE)
		end
	end)
end

local function split(value: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(value) == "string" and value ~= "" then
		for _, key in string.split(value, ",") do
			out[key] = true
		end
	end
	return out
end

local function isStudioPreview(): boolean
	return RunService:IsStudio() and player:GetAttribute("BaseUiPreview") ~= nil
end

-- ==========================================================
-- ART: DIORAMA TILES (Frames only - no rotation, no images)
-- ==========================================================

--- A plot corner in the theme's colours: accent sky, fence with neon caps
--- and rails, floor with a paved path, the museum pedestal and gate decor.
local function drawThemeTile(tile: Frame, theme: BaseThemeConfig.Theme)
	local accent = theme.accentColor or Color3.fromRGB(96, 214, 255)
	local floor = theme.floorColor or Color3.fromRGB(140, 216, 92)
	local paving = theme.pavingColor or floor:Lerp(WHITE, 0.25)
	local fence = theme.fenceColor or Color3.fromRGB(58, 64, 86)
	local rail = theme.railColor or Color3.fromRGB(246, 246, 240)
	local z = tile.ZIndex

	tile.BackgroundColor3 = WHITE
	shade(tile, accent:Lerp(BLACK, 0.45), accent:Lerp(BLACK, 0.82))

	-- Soft glow band behind the fence.
	block(tile, 0, 0.2, 1, 0.34, accent, z, 0.8)
	-- Fence: posts, two rails, neon caps.
	for _, x in { 0.07, 0.29, 0.5, 0.71, 0.93 } do
		block(tile, x - 0.022, 0.28, 0.044, 0.36, fence, z + 1)
		local cap = block(tile, x - 0.034, 0.25, 0.068, 0.05, accent, z + 2)
		corner(cap, UDim.new(0.3, 0))
	end
	block(tile, 0, 0.35, 1, 0.035, rail, z + 1)
	block(tile, 0, 0.48, 1, 0.035, rail, z + 1)
	-- Floor, lit from the back, with the paved path running to the viewer.
	local ground = block(tile, 0, 0.62, 1, 0.38, WHITE, z + 1)
	shade(ground, floor:Lerp(WHITE, 0.12), floor:Lerp(BLACK, 0.32))
	local path = block(tile, 0.36, 0.62, 0.28, 0.38, WHITE, z + 2)
	shade(path, paving:Lerp(WHITE, 0.1), paving:Lerp(BLACK, 0.25))
	block(tile, 0, 0.615, 1, 0.022, accent, z + 3)
	-- The pedestal with its gold ring and a mystery orb.
	block(tile, 0.43, 0.5, 0.14, 0.3, STONE, z + 4)
	block(tile, 0.405, 0.47, 0.19, 0.05, STONE:Lerp(WHITE, 0.25), z + 5)
	block(tile, 0.43, 0.53, 0.14, 0.02, GOLD, z + 5)
	dot(tile, 0.5, 0.38, 0.16, ORB, z + 6, true)
	-- Gate decor on the two end posts.
	local decor: { BaseThemeConfig.Decor } = theme.decor or {}
	for _, def in decor do
		if def.anchor == "gate" then
			for _, x in { 0.07, 0.93 } do
				local glow = def.material == Enum.Material.Neon
				if glow then
					dot(tile, x, 0.17, 0.2, def.color, z + 2, true).BackgroundTransparency = 0.6
				end
				dot(tile, x, 0.17, 0.12, def.color, z + 3, def.shape == "Ball")
			end
		end
	end
end

--- A pedestal under a spotlight in the skin's material colours.
local function drawSkinTile(tile: Frame, skin: BaseThemeConfig.PedestalSkin)
	local stone = skin.color or STONE
	local z = tile.ZIndex
	tile.BackgroundColor3 = WHITE
	shade(tile, Color3.fromRGB(44, 54, 90), Color3.fromRGB(18, 24, 44))
	block(tile, 0.26, 0, 0.48, 1, WHITE, z, 0.9) -- spotlight beam
	block(tile, 0, 0.84, 1, 0.16, Color3.fromRGB(52, 62, 96), z + 1)
	local column = block(tile, 0.36, 0.36, 0.28, 0.44, WHITE, z + 2, skin.transparency)
	local columnShade = Instance.new("UIGradient")
	columnShade.Color = ColorSequence.new(stone:Lerp(WHITE, 0.3), stone:Lerp(BLACK, 0.3))
	columnShade.Parent = column
	block(tile, 0.3, 0.78, 0.4, 0.07, stone:Lerp(BLACK, 0.15), z + 3)
	block(tile, 0.3, 0.31, 0.4, 0.07, stone:Lerp(WHITE, 0.12), z + 3, skin.transparency)
	if skin.trimColor then
		block(tile, 0.3, 0.38, 0.4, 0.035, skin.trimColor, z + 4)
	end
	dot(tile, 0.5, 0.2, 0.2, ORB, z + 4, true)
	local material = if skin.material then string.upper(skin.material.Name) else "STONE"
	local word = text(tile, "Material", material, DIM, Enum.TextXAlignment.Left, 12)
	word.Position = UDim2.new(0, 5, 1, -15)
	word.Size = UDim2.new(0.8, 0, 0, 12)
	word.ZIndex = z + 5
end

local function thumbnail(tile: Frame, image: string)
	local art = Instance.new("ImageLabel")
	art.Name = "Thumbnail"
	art.BackgroundTransparency = 1
	art.Image = image
	art.ScaleType = Enum.ScaleType.Crop
	art.Size = UDim2.fromScale(1, 1)
	art.ZIndex = tile.ZIndex + 1
	art.Parent = tile
end

--- The BASE tab's own placeholder icon: a tiny plot corner.
local function drawPlotIcon(holder: Frame)
	local z = holder.ZIndex
	holder.BackgroundColor3 = Color3.fromRGB(120, 210, 90)
	corner(holder, UDim.new(0.25, 0))
	edge(holder, 2, INK)
	block(holder, 0, 0, 1, 0.42, Color3.fromRGB(70, 180, 255), z)
	block(holder, 0.1, 0.18, 0.1, 0.4, Color3.fromRGB(58, 64, 86), z + 1)
	block(holder, 0.8, 0.18, 0.1, 0.4, Color3.fromRGB(58, 64, 86), z + 1)
	block(holder, 0, 0.3, 1, 0.08, WHITE, z + 1)
	block(holder, 0.38, 0.44, 0.24, 0.36, STONE, z + 2)
	dot(holder, 0.5, 0.36, 0.2, GOLD, z + 3, true)
end

local function iconOrPlaceholder(holder: Frame, image: string?, placeholder: (Frame) -> ())
	if image and BaseThemeConfig.hasImage(image) then
		holder.BackgroundTransparency = 1
		local art = Instance.new("ImageLabel")
		art.BackgroundTransparency = 1
		art.Image = image
		art.Size = UDim2.fromScale(1, 1)
		art.ZIndex = holder.ZIndex + 1
		art.Parent = holder
	else
		placeholder(holder)
	end
end

-- ==========================================================
-- 3D BANNER PREVIEW
-- ==========================================================

--- A tiny diorama of a plot corner: floor, two posts and a rail, a neon cap,
--- the pedestal skin and any gate decor primitive.
local function fillPreview(themeKey: string, skinKey: string)
	local view = bannerView
	local signature = `{themeKey}|{skinKey}`
	if not view or signature == shownPreview then
		return
	end
	shownPreview = signature
	for _, child in view:GetChildren() do
		if not child:IsA("Camera") then
			child:Destroy()
		end
	end
	local theme = BaseThemeConfig.ThemeByKey[themeKey] or BaseThemeConfig.ThemeByKey[BaseThemeConfig.DEFAULT_THEME]
	local skin = BaseThemeConfig.PedestalByKey[skinKey] or BaseThemeConfig.PedestalByKey[BaseThemeConfig.DEFAULT_PEDESTAL]

	local model = Instance.new("Model")
	model.Name = "Preview"
	local function part(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Anchored = true
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		if shape then
			p.Shape = shape
		end
		p.Parent = model
		return p
	end
	part(Vector3.new(16, 1, 16), CFrame.new(0, -0.5, 0), theme.floorColor or Color3.fromRGB(140, 216, 92), theme.floorMaterial)
	local fence = theme.fenceColor or Color3.fromRGB(58, 64, 86)
	local rail = theme.railColor or Color3.fromRGB(246, 246, 240)
	local decor: { BaseThemeConfig.Decor } = theme.decor or {}
	for _, x in { -7, 7 } do
		part(Vector3.new(1.4, 6, 1.4), CFrame.new(x, 3, 7), fence, theme.fenceMaterial)
		part(Vector3.new(2, 0.8, 2), CFrame.new(x, 6.4, 7), theme.accentColor or rail, if theme.accentColor then Enum.Material.Neon else nil)
		for _, def in decor do
			if def.anchor == "gate" then
				local shape = if def.shape == "Ball" then Enum.PartType.Ball elseif def.shape == "Cylinder" then Enum.PartType.Cylinder else Enum.PartType.Block
				local lift = if shape == Enum.PartType.Cylinder then def.size.X / 2 else def.size.Y / 2
				local turn = if shape == Enum.PartType.Cylinder then CFrame.Angles(0, 0, math.rad(90)) else CFrame.identity
				part(def.size * 0.7, CFrame.new(x, 6.8 + lift * 0.7, 7) * turn, def.color, def.material, shape)
			end
		end
	end
	for _, y in { 2, 4.2 } do
		part(Vector3.new(14, 0.6, 0.6), CFrame.new(0, y, 7), rail)
	end
	local upright = CFrame.Angles(0, 0, math.rad(90))
	local pedestal = part(Vector3.new(3.6, 5, 5), CFrame.new(0, 1.8, -1) * upright, skin.color or STONE, skin.material or Enum.Material.Slate, Enum.PartType.Cylinder)
	pedestal.Transparency = skin.transparency or 0
	if skin.trimColor then
		part(Vector3.new(0.3, 5.5, 5.5), CFrame.new(0, 0.15, -1) * upright, skin.trimColor, skin.trimMaterial, Enum.PartType.Cylinder)
	end
	part(Vector3.new(0.2, 3, 3), CFrame.new(0, 3.65, -1) * upright, GOLD, Enum.Material.Neon, Enum.PartType.Cylinder)
	part(Vector3.new(1.8, 1.8, 1.8), CFrame.new(0, 4.8, -1), ORB, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	model:PivotTo(CFrame.new())
	model.Parent = view

	local camera: Camera = view:FindFirstChildOfClass("Camera") or Instance.new("Camera")
	camera.Parent = view
	camera.FieldOfView = 40
	view.CurrentCamera = camera
	local direction = Vector3.new(0.7, 0.55, -0.9).Unit
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 2.5, 0) + direction * 30, Vector3.new(0, 2.5, 0))
	view.LightDirection = (-direction + Vector3.new(0, -0.4, 0)).Unit
end

-- ==========================================================
-- CARDS
-- ==========================================================

local function themeHeight(tileH: number): number
	return PAD * 2 + tileH + NAME_H + DESC_H + TAG_H + BUTTON_H + GAP * 4
end

local function skinHeight(tileH: number): number
	return PAD * 2 + tileH + SKIN_NAME_H + BUTTON_H + GAP * 2
end

local function tierOf(cash: number, passKey: string?): (string, Color3)
	if passKey then
		return "EXCLUSIVE", Color3.fromRGB(255, 80, 200)
	end
	if cash <= 0 then
		return "FREE", Color3.fromRGB(120, 132, 156)
	end
	for _, tier in TIERS do
		if cash < tier.below then
			return tier.word, tier.color
		end
	end
	return "LEGENDARY", Color3.fromRGB(255, 150, 40)
end

local function send(action: string, key: string)
	if isStudioPreview() then
		ToastController.show("info", "Preview mode: nothing was sent.")
		return
	end
	Remotes.get("BaseThemeRequest"):FireServer(action, key)
end

local function makeCard(parent: Instance, key: string, isTheme: boolean, order: number): Card
	local theme = if isTheme then BaseThemeConfig.ThemeByKey[key] else nil
	local skin = if isTheme then nil else BaseThemeConfig.PedestalByKey[key]
	local name = if theme then theme.name elseif skin then skin.name else key
	local image = if theme then theme.thumbnail elseif skin then skin.thumbnail else ""

	-- The whole card is a button: tapping it previews it on the banner.
	local root = Instance.new("TextButton")
	root.Name = `Card_{key}`
	root.Text = ""
	root.LayoutOrder = order
	-- ZIndex >= 4 throughout: the old rows used 4-6 and rendered above the
	-- pack panel even if MainUI's ZIndexBehavior is Global.
	root.ZIndex = 4
	local plateStroke = plate(root, 12)
	feedback(root, 1.02)
	root.Activated:Connect(function()
		previewKey = key
		BaseThemeController.refresh()
	end)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(PAD, PAD)
	content.Size = UDim2.new(1, -PAD * 2, 1, -PAD * 2)
	content.ZIndex = 5
	content.Parent = root
	local stack = Instance.new("UIListLayout")
	stack.SortOrder = Enum.SortOrder.LayoutOrder
	stack.Padding = UDim.new(0, GAP)
	stack.Parent = content

	local tile = Instance.new("Frame")
	tile.Name = "Tile"
	tile.BorderSizePixel = 0
	tile.ClipsDescendants = true
	tile.Size = UDim2.new(1, 0, 0, 80)
	tile.LayoutOrder = 1
	tile.ZIndex = 5
	tile.Parent = content
	corner(tile, UDim.new(0, 8))
	edge(tile, 2, INK)
	if BaseThemeConfig.hasImage(image) then
		tile.BackgroundColor3 = FACE_BOTTOM
		thumbnail(tile, image)
	elseif theme then
		drawThemeTile(tile, theme)
	elseif skin then
		drawSkinTile(tile, skin)
	end

	-- Owned: a green check badge in the tile's corner.
	local badge = Instance.new("Frame")
	badge.Name = "OwnedBadge"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, -4, 0, 4)
	badge.Size = UDim2.fromOffset(24, 24)
	badge.BackgroundColor3 = Color3.fromRGB(40, 190, 90)
	badge.ZIndex = 20
	badge.Visible = false
	badge.Parent = tile
	corner(badge, UDim.new(1, 0))
	edge(badge, 2, INK)
	local check = text(badge, "Check", "✓", WHITE, Enum.TextXAlignment.Center, 20)
	check.Size = UDim2.fromScale(1, 1)
	check.ZIndex = 21

	local title = text(content, "Name", string.upper(name), WHITE, Enum.TextXAlignment.Left, 24)
	title.Size = UDim2.new(1, 0, 0, if isTheme then NAME_H else SKIN_NAME_H)
	title.LayoutOrder = 2

	local tagPill: Frame? = nil
	local tagWord: TextLabel? = nil
	local tagPrice: TextLabel? = nil
	if theme then
		local blurb = text(content, "Blurb", theme.blurb, DIM, Enum.TextXAlignment.Left, 16)
		blurb.Size = UDim2.new(1, 0, 0, DESC_H)
		blurb.LayoutOrder = 3
		local row = Instance.new("Frame")
		row.Name = "Tag"
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, TAG_H)
		row.LayoutOrder = 4
		row.ZIndex = 5
		row.Parent = content
		local pill = Instance.new("Frame")
		pill.Name = "Tier"
		pill.Size = UDim2.fromScale(0.5, 1)
		pill.ZIndex = 6
		pill.Parent = row
		corner(pill, UDim.new(1, 0))
		edge(pill, 1.5, INK)
		local word = text(pill, "Word", "", WHITE, Enum.TextXAlignment.Center, 15)
		word.ZIndex = 7
		word.Size = UDim2.new(1, -8, 0.8, 0)
		word.Position = UDim2.new(0, 4, 0.1, 0)
		local price = text(row, "Price", "", WHITE, Enum.TextXAlignment.Right, 18)
		price.AnchorPoint = Vector2.new(1, 0)
		price.Position = UDim2.fromScale(1, 0)
		price.Size = UDim2.fromScale(0.48, 1)
		tagPill, tagWord, tagPrice = pill, word, price
	end

	local button = Instance.new("TextButton")
	button.Name = "Action"
	button.Text = ""
	button.BorderSizePixel = 0
	button.BackgroundColor3 = WHITE
	button.Size = UDim2.new(1, 0, 0, BUTTON_H)
	button.LayoutOrder = 5
	button.ZIndex = 6
	button.Parent = content
	corner(button, UDim.new(0, 10))
	edge(button, 2.5, INK)
	local buttonGradient = shade(button, BUY_GREEN:Lerp(WHITE, 0.3), BUY_GREEN)
	feedback(button, 1.03)
	local caption = text(button, "Caption", "", WHITE, Enum.TextXAlignment.Center, 24)
	caption.AnchorPoint = Vector2.new(0.5, 0.5)
	caption.Position = UDim2.fromScale(0.5, 0.5)
	caption.Size = UDim2.new(1, -12, 0.62, 0)
	caption.ZIndex = 8

	local card: Card = {
		key = key,
		isTheme = isTheme,
		cash = if theme then theme.cash elseif skin then skin.cash else 0,
		passKey = if theme then theme.passKey elseif skin then skin.passKey else nil,
		root = root,
		plateStroke = plateStroke,
		tile = tile,
		badge = badge,
		button = button,
		buttonGradient = buttonGradient,
		caption = caption,
		tagPill = tagPill,
		tagWord = tagWord,
		tagPrice = tagPrice,
		action = nil,
		equipped = false,
	}
	button.Activated:Connect(function()
		local act = card.action
		if act then
			act()
		end
	end)
	root.Parent = parent
	return card
end

local function setButton(card: Card, caption: string, color: Color3, look: string)
	-- look: "on" (tappable), "dim" (tappable, explains why not), "off" (inert)
	card.caption.Text = caption
	card.button.BackgroundColor3 = color
	card.buttonGradient.Color = ColorSequence.new(color:Lerp(WHITE, 0.3), color)
	card.button.BackgroundTransparency = if look == "on" then 0 elseif look == "dim" then 0.2 else 0.1
	card.caption.TextTransparency = if look == "on" then 0 else 0.2
	card.button.Active = look ~= "off"
end

local function paintCard(card: Card, owned: { [string]: boolean }, equipped: string, cash: number)
	local isEquipped = card.key == equipped
	local isOwned = owned[card.key] == true or (card.cash <= 0 and card.passKey == nil)
	card.badge.Visible = isOwned
	card.equipped = isEquipped
	if not isEquipped then
		card.plateStroke.Transparency = 0
	end

	-- Edge: glowing green when equipped, soft green when owned, gold for an
	-- exclusive still for sale.
	card.plateStroke.Thickness = if isEquipped then 3.5 else 2.5
	card.plateStroke.Color = if isEquipped then GREEN elseif isOwned then OWNED_EDGE elseif card.passKey then GOLD else INK
	card.root.BackgroundColor3 = if isEquipped then Color3.fromRGB(26, 110, 56) else PLATE

	if isEquipped then
		setButton(card, "✓ EQUIPPED", EQUIPPED_GREEN, "off")
		card.action = nil
	elseif isOwned then
		setButton(card, "EQUIP", EQUIP_BLUE, "on")
		card.action = function()
			send("equip", card.key)
		end
	elseif card.passKey then
		local pass = MonetizationConfig.ThemePassByKey[card.passKey]
		if pass and pass.gamePassId > 0 then
			setButton(card, `R$ {NumberFormat.comma(pass.robux)}`, ROBUX_GOLD, "on")
			card.action = function()
				previewKey = card.key
				BaseThemeController.refresh()
				send("buyPass", card.key)
			end
		else
			setButton(card, "NOT SET UP", DISABLED, "off")
			card.action = nil
		end
	else
		local affordable = cash >= card.cash
		setButton(card, `BUY {NumberFormat.cash(card.cash)}`, if affordable then BUY_GREEN else DISABLED, if affordable then "on" else "dim")
		card.action = function()
			if cash < card.cash then
				UIAnim.punch(card.root, 0.04)
				ToastController.show("error", `You need {NumberFormat.cash(card.cash - cash)} more.`)
				return
			end
			send("buy", card.key)
		end
	end

	local word, color = tierOf(card.cash, card.passKey)
	if card.tagPill and card.tagWord and card.tagPrice then
		card.tagPill.BackgroundColor3 = color
		card.tagWord.Text = word
		local price = card.tagPrice
		if isOwned then
			price.Text = "OWNED"
			price.TextColor3 = GREEN
		elseif card.passKey then
			local pass = MonetizationConfig.ThemePassByKey[card.passKey]
			price.Text = if pass then `R$ {NumberFormat.comma(pass.robux)}` else "ROBUX"
			price.TextColor3 = GOLD
		else
			price.Text = NumberFormat.cash(card.cash)
			price.TextColor3 = if cash >= card.cash then WHITE else RED_TEXT
		end
	end
end

-- ==========================================================
-- LAYOUT
-- ==========================================================

--- Cell sizes from the list's real width. Offsets are pre-UIScale, so the
--- width is divided by the UIScale chain first.
local function layoutGrid()
	local scroll = list
	local tGrid, sGrid = themeGrid, skinGrid
	if not scroll or not tGrid or not sGrid then
		return
	end
	local absolute = scroll.AbsoluteSize.X
	if absolute <= 0 then
		return
	end
	local factor = ClipSafe.scaleChain(scroll)
	local width = absolute / factor - SIDE_PAD * 2 - 10 -- 10: scroll bar
	local wide = absolute >= WIDE_LIST
	local themeCols = if wide then 2 else 1
	local skinCols = if wide then 3 else 2
	local themeW = math.floor((width - CELL_GAP * (themeCols - 1)) / themeCols)
	local skinW = math.floor((width - CELL_GAP * (skinCols - 1)) / skinCols)
	local themeTile = math.floor(math.clamp(themeW * (if wide then 0.42 else 0.36), 72, 132))
	local skinTile = math.floor(math.clamp(skinW * 0.55, 60, 104))
	local signature = `{themeW}|{skinW}|{themeTile}|{skinTile}`
	if signature == layoutSignature then
		return
	end
	layoutSignature = signature
	tGrid.CellSize = UDim2.fromOffset(themeW, themeHeight(themeTile))
	sGrid.CellSize = UDim2.fromOffset(skinW, skinHeight(skinTile))
	for _, card in cards do
		card.tile.Size = UDim2.new(1, 0, 0, if card.isTheme then themeTile else skinTile)
	end
end

local function sectionHeader(parent: Instance, name: string, caption: string, icon: string, order: number): TextLabel
	local holder = Instance.new("Frame")
	holder.Name = name
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, SECTION_H)
	holder.LayoutOrder = order
	holder.ZIndex = 5
	holder.Parent = parent
	local badge = Instance.new("Frame")
	badge.Name = "Icon"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 2, 0.5, 0)
	badge.Size = UDim2.fromOffset(28, 28)
	badge.ZIndex = 6
	badge.Parent = holder
	iconOrPlaceholder(badge, icon, function(frame)
		frame.BackgroundColor3 = GOLD
		corner(frame, UDim.new(0.3, 0))
		edge(frame, 2, INK)
		shade(frame, GOLD:Lerp(WHITE, 0.35), Color3.fromRGB(230, 150, 20))
		dot(frame, 0.5, 0.5, 0.42, WHITE, frame.ZIndex + 1, true)
	end)
	local title = text(holder, "Title", caption, GOLD, Enum.TextXAlignment.Left, 26)
	title.Position = UDim2.new(0, 38, 0.1, 0)
	title.Size = UDim2.new(0.62, -38, 0.8, 0)
	local count = text(holder, "Count", "", DIM, Enum.TextXAlignment.Right, 18)
	count.AnchorPoint = Vector2.new(1, 0)
	count.Position = UDim2.new(1, -2, 0.22, 0)
	count.Size = UDim2.fromScale(0.36, 0.56)
	-- A thin rule under the header.
	block(holder, 0, 0.96, 1, 0.04, GOLD, 6, 0.6)
	return count
end

local function gridHolder(parent: Instance, name: string, order: number): UIGridLayout
	local holder = Instance.new("Frame")
	holder.Name = name
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.LayoutOrder = order
	holder.ZIndex = 4
	holder.Parent = parent
	local layout = Instance.new("UIGridLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.CellPadding = UDim2.fromOffset(CELL_GAP, CELL_GAP)
	layout.CellSize = UDim2.fromOffset(200, 260)
	layout.Parent = holder
	return layout
end

-- ==========================================================
-- RENDER
-- ==========================================================

--- Fixed data for the Studio screenshot mode: every card state at once.
local PREVIEW_INFO = {
	owned = "Classic,Sunset,Midnight,NeonNight,Default,Marble",
	offered = "NeonNight,RoyalGold",
	theme = "Sunset",
	pedestal = "Marble",
}
local PREVIEW_CASH = 100e6 -- Jungle / Obsidian affordable, Frost / Gold not

local function update()
	local info: any = {}
	local cash = 0
	local real = true
	if isStudioPreview() then
		info, cash = PREVIEW_INFO, PREVIEW_CASH
	elseif latest and type(latest.baseTheme) == "table" then
		info = latest.baseTheme
		cash = tonumber(latest.cash) or 0
	else
		-- No state yet: paint defaults, but do not treat the first real
		-- state as "just unlocked" (no shine / punch storm).
		real = false
	end
	local owned = split(info.owned)
	local offered = split(info.offered)
	local equippedTheme = if type(info.theme) == "string" then info.theme else BaseThemeConfig.DEFAULT_THEME
	local equippedSkin = if type(info.pedestal) == "string" then info.pedestal else BaseThemeConfig.DEFAULT_PEDESTAL

	local counts = { themeOwned = 0, themeShown = 0, skinOwned = 0, skinShown = 0 }
	for _, card in cards do
		local visible = card.passKey == nil or offered[card.key] == true
		card.root.Visible = visible
		if visible then
			local equipped = if card.isTheme then equippedTheme else equippedSkin
			paintCard(card, owned, equipped, cash)
			local isOwned = owned[card.key] == true or (card.cash <= 0 and card.passKey == nil)
			if card.isTheme then
				counts.themeShown += 1
				counts.themeOwned += if isOwned then 1 else 0
			else
				counts.skinShown += 1
				counts.skinOwned += if isOwned then 1 else 0
			end
			-- Celebrate a change that just happened (not the first paint).
			if lastOwned and isOwned and not lastOwned[card.key] then
				ShopKit.shine(card.tile)
			end
			if isOwned then
				owned[card.key] = true
			end
		end
	end
	if lastEquipped.theme and lastEquipped.theme ~= equippedTheme then
		for _, card in cards do
			if card.key == equippedTheme then
				UIAnim.punch(card.root, 0.05)
			end
		end
	end
	if lastEquipped.skin and lastEquipped.skin ~= equippedSkin then
		for _, card in cards do
			if card.key == equippedSkin then
				UIAnim.punch(card.root, 0.05)
			end
		end
	end
	if real then
		lastEquipped.theme = equippedTheme
		lastEquipped.skin = equippedSkin
		lastOwned = owned
	else
		lastEquipped = {}
		lastOwned = nil
	end

	if themeCount then
		themeCount.Text = `{counts.themeOwned} / {counts.themeShown} OWNED`
	end
	if skinCount then
		skinCount.Text = `{counts.skinOwned} / {counts.skinShown} OWNED`
	end

	-- Banner: what is equipped, or the card last tapped.
	local showTheme, showSkin = equippedTheme, equippedSkin
	local peek = previewKey
	if peek and BaseThemeConfig.ThemeByKey[peek] then
		showTheme = peek
	elseif peek and BaseThemeConfig.PedestalByKey[peek] then
		showSkin = peek
	else
		peek = nil
	end
	local themeRow = BaseThemeConfig.ThemeByKey[showTheme] or BaseThemeConfig.ThemeByKey[BaseThemeConfig.DEFAULT_THEME]
	local skinRow = BaseThemeConfig.PedestalByKey[showSkin] or BaseThemeConfig.PedestalByKey[BaseThemeConfig.DEFAULT_PEDESTAL]
	if bannerTitle then
		bannerTitle.Text = if peek then "PREVIEW" else "CURRENTLY EQUIPPED"
		bannerTitle.TextColor3 = if peek then GOLD else GREEN
	end
	if bannerName then
		bannerName.Text = string.upper(themeRow.name)
	end
	if bannerSub then
		bannerSub.Text = `Pedestal: {skinRow.name}`
	end
	if bannerBack then
		bannerBack.Visible = peek ~= nil
	end
	fillPreview(themeRow.key, skinRow.key)
end

--- Repaints the page if it is on screen. Cheap: nothing is rebuilt.
function BaseThemeController.refresh()
	local current = page
	if current and current.Visible then
		update()
	end
end

local function onState(state: any)
	latest = state
	BaseThemeController.refresh()
end

-- ==========================================================
-- TABS
-- ==========================================================

local function paintTabs()
	for key, tab in tabs do
		local on = key == activeTab
		tab.gradient.Color = if on
			then ColorSequence.new(TAB_ON_TOP, TAB_ON_BOTTOM)
			else ColorSequence.new(TAB_OFF_TOP, TAB_OFF_BOTTOM)
		tab.stroke.Color = if on then WHITE else INK
		tab.stroke.Thickness = if on then 3 else 2.5
		tab.label.TextColor3 = if on then WHITE else DIM
	end
end

local function selectTab(name: string)
	activeTab = name
	local card = treadmillCard
	if card then
		card.Visible = name == "Treadmill"
	end
	local current = page
	if current then
		current.Visible = name == "Base"
	end
	if name == "Base" then
		previewKey = nil
		task.defer(layoutGrid)
		update()
	end
	paintTabs()
	local setBoost = hooksRef.setBoost
	if setBoost then
		setBoost(if name == "Base" then BASE_BOOST else 1)
	end
end

local function makeTab(parent: Instance, name: string, caption: string, order: number, icon: string?, placeholder: (Frame) -> ()): Tab
	local button = Instance.new("TextButton")
	button.Name = `Tab{name}`
	button.Text = ""
	button.BorderSizePixel = 0
	button.BackgroundColor3 = WHITE
	button.LayoutOrder = order
	button.Size = UDim2.fromScale(0.485, 1)
	button.ZIndex = 5
	button.Parent = parent
	corner(button, UDim.new(0, 14))
	local stroke = edge(button, 2.5, INK)
	local gradient = shade(button, TAB_OFF_TOP, TAB_OFF_BOTTOM)
	feedback(button, 1.04)

	local holder = Instance.new("Frame")
	holder.Name = "Icon"
	holder.AnchorPoint = Vector2.new(0, 0.5)
	holder.Position = UDim2.fromScale(0.06, 0.5)
	holder.Size = UDim2.fromScale(0.7, 0.7)
	holder.BackgroundTransparency = 0
	holder.BorderSizePixel = 0
	holder.ZIndex = 6
	holder.Parent = button
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.DominantAxis = Enum.DominantAxis.Height
	ratio.Parent = holder
	iconOrPlaceholder(holder, icon, placeholder)

	local label = text(button, "Label", caption, DIM, Enum.TextXAlignment.Center, 30)
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromScale(0.24, 0.5)
	label.Size = UDim2.fromScale(0.7, 0.56)
	label.ZIndex = 7

	button.Activated:Connect(function()
		if activeTab ~= name then
			selectTab(name)
			UIAnim.punch(button, 0.06)
		end
	end)
	return { button = button, gradient = gradient, stroke = stroke, label = label }
end

-- ==========================================================
-- STUDIO: UI BOUNDS AUDIT
-- ==========================================================

local function audit()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local ui = playerGui and playerGui:FindFirstChild("MainUI")
	local frames = ui and ui:FindFirstChild("Frames")
	for _, name in { "Upgrades", "Settings" } do
		local panel = frames and frames:FindFirstChild(name)
		if not panel or not panel:IsA("GuiObject") then
			print(`[UiAudit] {name}: panel not found`)
			continue
		end
		local lo = panel.AbsolutePosition
		local hi = lo + panel.AbsoluteSize
		local top = panel:FindFirstChild("Top")
		if top and top:IsA("GuiObject") then
			lo = Vector2.new(math.min(lo.X, top.AbsolutePosition.X), math.min(lo.Y, top.AbsolutePosition.Y))
			local topHi = top.AbsolutePosition + top.AbsoluteSize
			hi = Vector2.new(math.max(hi.X, topHi.X), math.max(hi.Y, topHi.Y))
		end
		local guards, rotated, outside = 0, {}, {}
		for _, d in panel:GetDescendants() do
			if d:IsA("CanvasGroup") and string.find(d.Name, "ClipGuard", 1, true) then
				guards += 1
			end
			if not d:IsA("GuiObject") then
				continue
			end
			local shown = d.Visible
			local guarded = false
			local node = d.Parent
			while shown and node and node ~= panel do
				if node:IsA("GuiObject") and not node.Visible then
					shown = false
				end
				if node:IsA("CanvasGroup") and string.find(node.Name, "ClipGuard", 1, true) then
					guarded = true
				end
				node = node.Parent
			end
			if not shown then
				continue
			end
			if d.Rotation ~= 0 and not (top and d:IsDescendantOf(top)) then
				table.insert(rotated, d:GetFullName())
			end
			local a = d.AbsolutePosition
			local b = a + d.AbsoluteSize
			if not guarded and (a.X < lo.X - 2 or a.Y < lo.Y - 2 or b.X > hi.X + 2 or b.Y > hi.Y + 2) then
				table.insert(outside, d:GetFullName())
			end
		end
		print(`[UiAudit] {name}: open={panel.Visible} clipGuards={guards} rotated={#rotated} outsidePanelUnguarded={#outside}`)
		for index = 1, math.min(#rotated, 8) do
			print(`  rotated: {rotated[index]}`)
		end
		for index = 1, math.min(#outside, 12) do
			print(`  outside: {outside[index]}`)
		end
	end
end

-- ==========================================================
-- ATTACH
-- ==========================================================

function BaseThemeController.attach(panel: Frame, scroll: ScrollingFrame, card: Frame, hooks: Hooks?)
	panelRef = panel
	treadmillCard = card
	hooksRef = hooks or {}

	-- Room for the tab bar: the treadmill card gives up its top slice.
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.fromScale(0.5, 0.14)
	card.Size = UDim2.fromScale(0.97, 0.85)

	-- ---------- tab bar ----------
	local bar = Instance.new("Frame")
	bar.Name = "UpgradeTabs"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.fromScale(0.5, 0.012)
	bar.Size = UDim2.fromScale(0.94, 0.115)
	bar.ZIndex = 5
	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(0, 40)
	minimum.Parent = bar
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.03, 0)
	layout.Parent = bar
	local treadmillIcon = BaseThemeConfig.UiIcons.TabTreadmill
	tabs.Treadmill = makeTab(bar, "Treadmill", "TREADMILL", 1, if BaseThemeConfig.hasImage(treadmillIcon) then treadmillIcon else ShopKit.Icons.Speed, function(frame)
		frame.BackgroundTransparency = 1
	end)
	tabs.Base = makeTab(bar, "Base", "BASE", 2, BaseThemeConfig.UiIcons.TabBase, drawPlotIcon)
	bar.Parent = scroll

	-- ---------- BASE page ----------
	local holder = Instance.new("Frame")
	holder.Name = "BasePage"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.fromScale(0.5, 0.14)
	holder.Size = UDim2.fromScale(0.97, 0.85)
	holder.ClipsDescendants = true
	holder.Visible = false
	holder.ZIndex = 3
	holder.Parent = scroll
	page = holder

	-- Banner (fixed).
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.Size = UDim2.fromScale(1, 0.27)
	banner.ZIndex = 4
	banner.Parent = holder
	plate(banner, 14)
	local view = Instance.new("ViewportFrame")
	view.Name = "Preview"
	view.AnchorPoint = Vector2.new(0, 0.5)
	view.Position = UDim2.new(0, 8, 0.5, 0)
	view.Size = UDim2.new(0.34, 0, 1, -14)
	view.BackgroundColor3 = Color3.fromRGB(40, 56, 92)
	view.BackgroundTransparency = 0.1
	view.Ambient = Color3.fromRGB(200, 206, 220)
	view.LightColor = WHITE
	view.ZIndex = 5
	view.Parent = banner
	local viewRatio = Instance.new("UIAspectRatioConstraint")
	viewRatio.AspectRatio = 1.45
	viewRatio.Parent = view
	corner(view, UDim.new(0, 10))
	edge(view, 2.5, INK)
	bannerView = view
	local title = text(banner, "Title", "CURRENTLY EQUIPPED", GREEN, Enum.TextXAlignment.Left, 18)
	title.Position = UDim2.fromScale(0.39, 0.1)
	title.Size = UDim2.fromScale(0.58, 0.2)
	bannerTitle = title
	local nameLabel = text(banner, "ThemeName", "", WHITE, Enum.TextXAlignment.Left, 34)
	nameLabel.Position = UDim2.fromScale(0.39, 0.32)
	nameLabel.Size = UDim2.fromScale(0.58, 0.32)
	bannerName = nameLabel
	local sub = text(banner, "Pedestal", "", DIM, Enum.TextXAlignment.Left, 18)
	sub.Position = UDim2.fromScale(0.39, 0.68)
	sub.Size = UDim2.fromScale(0.34, 0.2)
	bannerSub = sub
	local back = Instance.new("TextButton")
	back.Name = "Back"
	back.Text = ""
	back.AnchorPoint = Vector2.new(1, 1)
	back.Position = UDim2.new(1, -10, 1, -8)
	back.Size = UDim2.fromScale(0.22, 0.4)
	back.BorderSizePixel = 0
	back.BackgroundColor3 = WHITE
	back.Visible = false
	back.ZIndex = 6
	back.Parent = banner
	corner(back, UDim.new(0, 10))
	edge(back, 2, INK)
	shade(back, TAB_OFF_TOP:Lerp(WHITE, 0.2), TAB_OFF_BOTTOM)
	feedback(back, 1.05)
	local backCaption = text(back, "Caption", "BACK", WHITE, Enum.TextXAlignment.Center, 20)
	backCaption.AnchorPoint = Vector2.new(0.5, 0.5)
	backCaption.Position = UDim2.fromScale(0.5, 0.5)
	backCaption.Size = UDim2.fromScale(0.8, 0.6)
	backCaption.ZIndex = 7
	back.Activated:Connect(function()
		previewKey = nil
		update()
	end)
	bannerBack = back

	-- Grid (scrolls; wrapped in the clip guard below).
	local grid = Instance.new("ScrollingFrame")
	grid.Name = "BaseList"
	grid.Position = UDim2.fromScale(0, 0.29)
	grid.Size = UDim2.fromScale(1, 0.71)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ClipsDescendants = true
	grid.ScrollBarThickness = 8
	grid.ScrollBarImageColor3 = GOLD
	grid.ScrollingDirection = Enum.ScrollingDirection.Y
	grid.CanvasSize = UDim2.new()
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.ZIndex = 4
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Padding = UDim.new(0, 8)
	listLayout.Parent = grid
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 14)
	padding.PaddingLeft = UDim.new(0, SIDE_PAD)
	padding.PaddingRight = UDim.new(0, SIDE_PAD + 10)
	padding.Parent = grid
	grid.Parent = holder
	list = grid

	themeCount = sectionHeader(grid, "ThemesHeader", "THEMES", BaseThemeConfig.UiIcons.SectionThemes, 1)
	themeGrid = gridHolder(grid, "Themes", 2)
	skinCount = sectionHeader(grid, "PedestalsHeader", "PEDESTAL SKINS", BaseThemeConfig.UiIcons.SectionPedestals, 3)
	skinGrid = gridHolder(grid, "Pedestals", 4)
	local hint = text(grid, "Hint", "Tap a card to preview it at the top.", DIM, Enum.TextXAlignment.Center, 16)
	hint.Size = UDim2.new(1, 0, 0, 20)
	hint.LayoutOrder = 5

	local themeParent = (themeGrid :: UIGridLayout).Parent :: Instance
	for index, theme in BaseThemeConfig.Themes do
		table.insert(cards, makeCard(themeParent, theme.key, true, index))
	end
	local skinParent = (skinGrid :: UIGridLayout).Parent :: Instance
	for index, skin in BaseThemeConfig.Pedestals do
		table.insert(cards, makeCard(skinParent, skin.key, false, index))
	end

	-- Nothing inside the list may draw outside it (ClipSafe header).
	ClipSafe.guard(grid)
	ClipSafe.watch(grid)

	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		task.defer(layoutGrid)
	end)
	task.defer(layoutGrid)

	selectTab("Treadmill")

	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible and activeTab == "Base" then
			previewKey = nil
			update()
		end
	end)

	require(script.Parent.Parent.StateStore).subscribe(onState)

	if RunService:IsStudio() then
		player:GetAttributeChangedSignal("BaseUiPreview"):Connect(function()
			lastOwned = nil
			lastEquipped = {}
			BaseThemeController.refresh()
		end)
		player:GetAttributeChangedSignal("DebugUiAudit"):Connect(function()
			if player:GetAttribute("DebugUiAudit") ~= nil then
				audit()
			end
		end)
	end

	-- The banner model turns slowly and the equipped edge breathes while the
	-- page is on screen; both hold still under Reduced Effects.
	RunService.RenderStepped:Connect(function(delta: number)
		local open = panelRef
		if not open or not open.Visible or activeTab ~= "Base" or Effects.isReduced() then
			return
		end
		local model = view:FindFirstChild("Preview")
		if model and model:IsA("Model") then
			model:PivotTo(model:GetPivot() * CFrame.Angles(0, delta * 0.4, 0))
		end
		local glow = 0.5 + 0.5 * math.sin(os.clock() * 3)
		for _, entry in cards do
			if entry.equipped then
				entry.plateStroke.Transparency = 0.35 * glow
			end
		end
	end)
end

return BaseThemeController
