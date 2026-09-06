--!strict
--[[
	TrailCardPng
	A trail card whose entire LOOK is a painted PNG, and whose entire BEHAVIOUR
	is Roblox: invisible real buttons laid over the printed ones, hover and press
	feedback, and a runtime state layer. The illusion holds because nothing here
	ever draws over the art except the two small state pills, and those only
	once the trail is owned.

	    VISUALS   = the PNG            (untouched, cropped to its art band)
	    INPUT     = TextButtons        (transparent, exactly over the print)
	    ANIMATION = UIScale tweens     (card lift, button press)
	    STATE     = overlays           (EQUIP / EQUIPPED / OWNED pills)

	ONE TEMPLATE, MANY TRAILS. Every painted card is authored on the same layout,
	so the crop and the two button rectangles live here ONCE as fractions of the
	art band, and a trail supplies only its image id. Measured, not guessed: the
	Green Trail asset was rendered at a known scale and the printed buttons read
	off the capture - see TEMPLATE below for the numbers and their provenance.

	THE CARD DECIDES NOTHING. It reports which printed button was pressed and
	what the server last said about ownership; the caller turns that into a
	TrailRequest, and the server decides whether anything is bought or worn.

	DEBUG_HITBOXES paints the cash region green and the Robux region blue so the
	alignment can be checked by eye. It ships FALSE.
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TrailCardPng = {}

--- Flip to true to see the invisible buttons. NEVER ship true.
TrailCardPng.DEBUG_HITBOXES = false

-- ==========================================================
-- THE TEMPLATE
-- ==========================================================
--
-- The uploaded asset is 1024x720 with the artwork sitting in a band across the
-- middle and transparent padding above and below. Only the band is shown, via
-- ImageRectOffset/Size, and the label showing it keeps the band's aspect, so
-- the art is never stretched and the button fractions below stay true at
-- every card size. Everything below is in fractions of that band.
--
-- Provenance: the PNG was drawn at 0.85 px per texel over a magenta backdrop
-- with 10% tick marks, and the band and both printed buttons were measured off
-- the capture. Two texels of margin are left on the band so the glow edge is
-- never clipped.

export type Rect = { x: number, y: number, w: number, h: number }

TrailCardPng.TEMPLATE = {
	--- Art band inside the 1024x720 asset, in texels.
	imageRectOffset = Vector2.new(52, 218),
	imageRectSize = Vector2.new(918, 300),
	--- Band aspect, width over height.
	aspect = 918 / 300,
	--- The printed "$5K" button.
	cash = { x = 0.4496, y = 0.638, w = 0.2525, h = 0.29 } :: Rect,
	--- The printed "R$ 14" button.
	robux = { x = 0.7187, y = 0.638, w = 0.255, h = 0.29 } :: Rect,
}

local HOVER_LIFT = 1.025
local HOVER = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SETTLE = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS = TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local REBOUND = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
--- Two presses inside this window count as one. The server rate-limits and
--- validates on top; this only stops an obvious double-tap.
local PRESS_LOCK = 0.5

local DEBUG_CASH = Color3.fromRGB(60, 255, 90)
local DEBUG_ROBUX = Color3.fromRGB(90, 120, 255)

export type State = { owned: boolean, equipped: boolean }

export type Options = {
	image: number,
	--- Fired for the printed cash button, with the last server-reported state,
	--- so the caller can turn "buy" into "equip" once the trail is owned.
	onCash: (State) -> (),
	--- Fired for the printed Robux button. Omit for a cash-only trail; the region
	--- then gets no button at all.
	onRobux: ((State) -> ())?,
	--- Optional cues. Leave nil where a global hook already sounds every button.
	onHoverSound: (() -> ())?,
	onPressSound: (() -> ())?,
}

export type Card = {
	--- The layout cell. Parent this; it fills whatever the layout gives it.
	frame: Frame,
	--- The art, aspect-locked and centred inside the cell. Buttons live in here.
	artwork: ImageLabel,
	setState: (State) -> (),
	destroy: () -> (),
}

-- ==========================================================
-- BUILD
-- ==========================================================

local function isPointer(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

--- One invisible button over a printed region, with its own highlight layer
--- (a soft white wash that brightens the print on hover) and a press scale on
--- the button itself, so the PNG underneath never deforms.
local function region(
	parent: GuiObject,
	name: string,
	rect: Rect,
	debugColor: Color3,
	getState: () -> State,
	onActivated: (State) -> (),
	sounds: { hover: (() -> ())?, press: (() -> ())? }
): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Position = UDim2.fromScale(rect.x, rect.y)
	button.Size = UDim2.fromScale(rect.w, rect.h)
	button.BackgroundColor3 = debugColor
	button.BackgroundTransparency = if TrailCardPng.DEBUG_HITBOXES then 0.55 else 1
	button.BorderSizePixel = 0
	button.Text = ""
	button.TextTransparency = 1
	button.AutoButtonColor = false
	button.Active = true
	button.ZIndex = 5
	button.Parent = parent

	-- Highlight: a rounded white wash matching the printed pill, invisible at
	-- rest. Sits INSIDE the button so it scales with the press.
	local wash = Instance.new("Frame")
	wash.Name = "Highlight"
	wash.Size = UDim2.fromScale(1, 1)
	wash.BackgroundColor3 = Color3.new(1, 1, 1)
	wash.BackgroundTransparency = 1
	wash.BorderSizePixel = 0
	wash.ZIndex = 4
	wash.Parent = button
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.22, 0)
	corner.Parent = wash

	local scale = Instance.new("UIScale")
	scale.Parent = button

	local hovering, pressed = false, false
	local lockedUntil = 0

	local function washTo(transparency: number)
		TweenService:Create(wash, HOVER, { BackgroundTransparency = transparency }):Play()
	end

	button.MouseEnter:Connect(function()
		hovering = true
		if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
			return
		end
		washTo(0.78)
		if sounds.hover then
			sounds.hover()
		end
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		washTo(1)
		if not pressed then
			TweenService:Create(scale, SETTLE, { Scale = 1 }):Play()
		end
	end)
	button.InputBegan:Connect(function(input)
		if isPointer(input) then
			pressed = true
			-- Immediate, so touch feels as responsive as a mouse.
			TweenService:Create(scale, PRESS, { Scale = 0.96 }):Play()
			wash.BackgroundTransparency = 0.7
		end
	end)
	button.InputEnded:Connect(function(input)
		if isPointer(input) then
			pressed = false
			-- 0.96 -> ~1.01 -> 1.0: Back easing gives the rebound in one tween.
			TweenService:Create(scale, REBOUND, { Scale = 1 }):Play()
			washTo(if hovering then 0.78 else 1)
		end
	end)
	button.Activated:Connect(function()
		local now = os.clock()
		if now < lockedUntil then
			return
		end
		lockedUntil = now + PRESS_LOCK
		if sounds.press then
			sounds.press()
		end
		-- The request never waits on the animation.
		onActivated(getState())
	end)

	return button
end

--- A small rounded pill with a label, used for the runtime state overlays.
--- Sized to the printed button it sits on, dark so it reads over any art.
--- Not Active, so clicks fall through to the button underneath.
local function pill(parent: GuiObject, name: string, rect: Rect, text: string, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Position = UDim2.fromScale(rect.x, rect.y)
	label.Size = UDim2.fromScale(rect.w, rect.h)
	label.BackgroundColor3 = Color3.fromRGB(14, 20, 30)
	label.BackgroundTransparency = 0.12
	label.BorderSizePixel = 0
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Active = false
	label.Visible = false
	label.ZIndex = 7
	label.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.22, 0)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = color
	stroke.Transparency = 0.35
	stroke.Parent = label
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.08, 0)
	pad.PaddingRight = UDim.new(0.08, 0)
	pad.PaddingTop = UDim.new(0.18, 0)
	pad.PaddingBottom = UDim.new(0.18, 0)
	pad.Parent = label
	return label
end

function TrailCardPng.build(options: Options): Card
	local template = TrailCardPng.TEMPLATE

	-- The cell: an invisible box the layout owns. It takes whatever size the
	-- grid hands out; the art inside decides its own shape.
	local frame = Instance.new("Frame")
	frame.Name = "PngCard"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0

	-- The art: cropped to its band, locked to the band's aspect and centred in
	-- the cell, so a wide cell letterboxes it rather than stretching it. Its
	-- UIScale carries the hover lift, and scales around the centre.
	local artwork = Instance.new("ImageLabel")
	artwork.Name = "Artwork"
	artwork.BackgroundTransparency = 1
	artwork.BorderSizePixel = 0
	artwork.Image = `rbxassetid://{options.image}`
	artwork.ImageRectOffset = template.imageRectOffset
	artwork.ImageRectSize = template.imageRectSize
	artwork.ScaleType = Enum.ScaleType.Stretch
	artwork.AnchorPoint = Vector2.new(0.5, 0.5)
	artwork.Position = UDim2.fromScale(0.5, 0.5)
	artwork.Size = UDim2.fromScale(1, 1)
	artwork.ZIndex = 2
	artwork.Parent = frame
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = template.aspect
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.Parent = artwork
	local lift = Instance.new("UIScale")
	lift.Parent = artwork

	local state: State = { owned = false, equipped = false }
	local function getState(): State
		return state
	end
	local sounds = { hover = options.onHoverSound, press = options.onPressSound }

	-- Buttons and pills are children of the ART, so their fractions are of the
	-- art band and not of the cell around it.
	region(artwork, "CashButton", template.cash, DEBUG_CASH, getState, options.onCash, sounds)
	local robuxButton: TextButton? = nil
	if options.onRobux then
		robuxButton = region(artwork, "RobuxButton", template.robux, DEBUG_ROBUX, getState, options.onRobux, sounds)
	end

	-- State overlays. Over the printed prices ONLY, and only once they stop
	-- being true: an owned trail's cash button becomes EQUIP / EQUIPPED, and its
	-- Robux button is retired under a small OWNED tag.
	local cashState = pill(artwork, "CashState", template.cash, "EQUIP", Color3.fromRGB(120, 255, 160))
	local robuxState = pill(artwork, "RobuxState", template.robux, "OWNED", Color3.fromRGB(200, 208, 220))

	-- Card hover: a 2.5% lift of the art. Desktop only by nature; touch has no
	-- hover, and the press feedback covers it there.
	frame.MouseEnter:Connect(function()
		TweenService:Create(lift, HOVER, { Scale = HOVER_LIFT }):Play()
	end)
	frame.MouseLeave:Connect(function()
		TweenService:Create(lift, SETTLE, { Scale = 1 }):Play()
	end)

	local function setState(next: State)
		state = { owned = next.owned == true, equipped = next.equipped == true }
		if state.equipped then
			cashState.Text = "✓ EQUIPPED"
			cashState.TextColor3 = Color3.fromRGB(120, 255, 160)
			cashState.Visible = true
		elseif state.owned then
			cashState.Text = "EQUIP"
			cashState.TextColor3 = Color3.fromRGB(255, 255, 255)
			cashState.Visible = true
		else
			cashState.Visible = false
		end
		robuxState.Visible = state.owned and robuxButton ~= nil
		if robuxButton then
			-- Owned by either route: the Robux button stops taking input.
			robuxButton.Active = not state.owned
			robuxButton.Visible = not state.owned
		end
	end

	return {
		frame = frame,
		artwork = artwork,
		setState = setState,
		destroy = function()
			frame:Destroy()
		end,
	}
end

return TrailCardPng
