--!strict
--[[
	PngCard
	One painted interface, made real. Grew out of the Green Trail card, which
	proved the idea: the PNG is the whole LOOK, and Roblox supplies everything
	that has to move or respond - invisible buttons laid exactly over the
	printed ones, hover and press feedback, hit-testing that follows the image
	as it scales, and small state overlays. Nothing here ever draws over the
	art unless a caller asks for a pill.

	    VISUALS   = the PNG (cropped to its body, never distorted past 4%)
	    INPUT     = TextButtons the size of the printed buttons
	    ANIMATION = UIScale tweens on the art and the buttons
	    STATE     = pills the caller places over a printed region

	GEOMETRY, ONCE. Every card is a Frame (the cell the layout owns) holding an
	ImageLabel (the art) that is aspect-locked and centred. Buttons and pills
	are children of the ART, positioned in SCALE fractions of it, so they stay
	pixel-on at any resolution and any card size. The numbers come from
	PngUiConfig; nothing is measured here.

	NORMALISATION. The card's family aspect (PngUiConfig.Families) is what the
	grid cell is shaped to. The art is drawn at its own measured body aspect,
	stretched by at most STRETCH_BUDGET towards the family aspect, and fitted
	inside the cell for whatever difference is left. That is what makes ten
	separately generated banners sit in one grid as one kit.

	TWO INTERACTION MODES.
	  * regions   - each printed button is its own TextButton with its own
	                feedback (a trail's $ and R$ are two different purchases).
	  * wholeCard - the entire art is one TextButton (a product with one
	                price); the printed button still lights up under hover.

	DEBUG_HITBOXES tints every hit region. It ships FALSE.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)

local PngCard = {}

--- Flip to true to see the invisible buttons. NEVER ship true.
PngCard.DEBUG_HITBOXES = false

--- Texels kept around the measured body so anti-aliased edges are not clipped.
PngCard.CROP_MARGIN = 2

--- Hit regions are grown by this much (fractions of the art) past the printed
--- pill, so a press on the pill's outline still counts.
PngCard.HIT_PAD = Vector2.new(0.006, 0.014)
--- State pills are grown a little further, so an OPAQUE pill covers the
--- printed button underneath completely - outline, shadow and all. The art is
--- one flat image, so the only way to "hide" a printed purchase button is to
--- paint over it; a translucent pill let the old "$" ghost through the new
--- word, which is the stacked-buttons look this exists to prevent.
PngCard.PILL_PAD = Vector2.new(0.03, 0.036)
--- The printed Robux buttons carry an icon just LEFT of the measured pill on
--- some cards (Golden, Red); the OWNED plate reaches further that way.
PngCard.PILL_EXTRA_LEFT = { robux = 0.03 } :: { [string]: number }

local HOVER_LIFT = 1.025
local HOVER = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SETTLE = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS = TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local REBOUND = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
--- Two presses inside this window count as one. The server rate-limits and
--- validates on top; this only stops an obvious double-tap from raising two
--- Marketplace prompts.
local PRESS_LOCK = 0.5
--- The hover wash over a printed button, and how far it darkens under a press.
local WASH_HOVER = 0.8
local WASH_PRESS = 0.7

local DEBUG_COLORS: { [string]: Color3 } = {
	cash = Color3.fromRGB(60, 255, 90),
	robux = Color3.fromRGB(90, 120, 255),
	buy = Color3.fromRGB(255, 80, 255),
	claim = Color3.fromRGB(60, 255, 90),
	close = Color3.fromRGB(255, 70, 70),
	join = Color3.fromRGB(80, 160, 255),
	whole = Color3.fromRGB(255, 220, 60),
}

export type Rect = PngUiConfig.Rect
export type Layout = PngUiConfig.Layout

export type RegionSpec = {
	onActivated: (() -> ())?,
}

export type Options = {
	name: string?,
	layout: Layout,
	--- Cell aspect the art is fitted into. Defaults to the layout's family.
	familyAspect: number?,
	--- Regions to make interactive, by layout region name. In wholeCard mode
	--- these become highlights only; the whole art is the button.
	regions: { [string]: RegionSpec }?,
	--- One action for the whole card.
	wholeCard: (() -> ())?,
	hoverLift: number?,
	pressLock: number?,
}

export type Region = {
	name: string,
	button: TextButton?,
	wash: Frame,
	scale: UIScale,
	enabled: boolean,
}

export type Card = {
	frame: Frame,
	artwork: ImageLabel,
	lift: UIScale,
	regions: { [string]: Region },
	wholeButton: TextButton?,
	--- Position and size (art fractions, padded) of a layout region, or nils.
	rectFor: (name: string) -> (UDim2?, UDim2?),
	--- A small dark pill with a label laid over a region, hidden until shown.
	pill: (name: string, text: string, color: Color3) -> TextLabel,
	setRegionEnabled: (name: string, enabled: boolean) -> (),
	--- Every button on or off at once (while closing, or once bought out).
	setInteractive: (enabled: boolean) -> (),
	--- Swap the art (and every region) for another layout of the same kind.
	retarget: (layout: Layout) -> (),
	destroy: () -> (),
}

-- ==========================================================
-- GEOMETRY
-- ==========================================================

local function cropOf(layout: Layout): (Vector2, Vector2)
	local m = PngCard.CROP_MARGIN
	local body = layout.body
	return Vector2.new(body.x - m, body.y - m), Vector2.new(body.w + 2 * m, body.h + 2 * m)
end

--- The aspect the art is drawn at: its own, pulled towards the family's by no
--- more than the stretch budget.
local function drawnAspect(layout: Layout, familyAspect: number): number
	local _, size = cropOf(layout)
	local own = size.X / size.Y
	local budget = PngUiConfig.STRETCH_BUDGET
	return math.clamp(familyAspect, own * (1 - budget), own * (1 + budget))
end

--- A body-fraction rect as art-fraction position and size, padded.
local function regionRect(layout: Layout, rect: Rect): (UDim2, UDim2)
	local m = PngCard.CROP_MARGIN
	local body = layout.body
	local cw, ch = body.w + 2 * m, body.h + 2 * m
	local x = (m + rect.x * body.w) / cw - PngCard.HIT_PAD.X
	local y = (m + rect.y * body.h) / ch - PngCard.HIT_PAD.Y
	local w = (rect.w * body.w) / cw + 2 * PngCard.HIT_PAD.X
	local h = (rect.h * body.h) / ch + 2 * PngCard.HIT_PAD.Y
	x = math.max(x, 0)
	y = math.max(y, 0)
	w = math.min(w, 1 - x)
	h = math.min(h, 1 - y)
	return UDim2.fromScale(x, y), UDim2.fromScale(w, h)
end

local function isPointer(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function touchOnly(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

-- ==========================================================
-- BUILD
-- ==========================================================

function PngCard.build(options: Options): Card
	local layout = options.layout
	local familyAspect = options.familyAspect or PngUiConfig.aspectFor(layout)
	local hoverLift = options.hoverLift or HOVER_LIFT
	local pressLock = options.pressLock or PRESS_LOCK

	-- The cell. Whatever the layout hands out, kept to the family shape.
	local frame = Instance.new("Frame")
	frame.Name = options.name or "PngCard"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	local familyRatio = Instance.new("UIAspectRatioConstraint")
	familyRatio.Name = "FamilyAspect"
	familyRatio.AspectRatio = familyAspect
	familyRatio.AspectType = Enum.AspectType.FitWithinMaxSize
	familyRatio.Parent = frame

	-- The art: cropped to its body, drawn at its own aspect (nudged towards the
	-- family's within budget), centred, letterboxed for whatever is left.
	local artwork = Instance.new("ImageLabel")
	artwork.Name = "Artwork"
	artwork.BackgroundTransparency = 1
	artwork.BorderSizePixel = 0
	artwork.ScaleType = Enum.ScaleType.Stretch
	artwork.AnchorPoint = Vector2.new(0.5, 0.5)
	artwork.Position = UDim2.fromScale(0.5, 0.5)
	artwork.Size = UDim2.fromScale(1, 1)
	artwork.ZIndex = 2
	artwork.Parent = frame
	local drawnRatio = Instance.new("UIAspectRatioConstraint")
	drawnRatio.Name = "DrawnAspect"
	drawnRatio.AspectType = Enum.AspectType.FitWithinMaxSize
	drawnRatio.Parent = artwork
	local lift = Instance.new("UIScale")
	lift.Name = "Lift"
	lift.Parent = artwork

	local function applyArt(target: Layout)
		local offset, size = cropOf(target)
		artwork.Image = `rbxassetid://{target.image}`
		artwork.ImageRectOffset = offset
		artwork.ImageRectSize = size
		drawnRatio.AspectRatio = drawnAspect(target, familyAspect)
	end
	applyArt(layout)

	local regions: { [string]: Region } = {}
	local pills: { [string]: TextLabel } = {}
	local wholeButton: TextButton? = nil

	local function washAll(transparency: number, info: TweenInfo)
		for _, region in regions do
			if region.enabled then
				TweenService:Create(region.wash, info, { BackgroundTransparency = transparency }):Play()
			end
		end
	end
	local function scaleAll(scale: number, info: TweenInfo)
		for _, region in regions do
			TweenService:Create(region.scale, info, { Scale = scale }):Play()
		end
	end

	-- A highlight layer over a printed button: a rounded white wash, invisible
	-- at rest, that brightens on hover and dips on press. In region mode it is
	-- inside that region's own button; in wholeCard mode it is a plain Frame
	-- driven by the one big button.
	local function makeWash(parent: GuiObject): (Frame, UIScale)
		local wash = Instance.new("Frame")
		wash.Name = "Highlight"
		wash.Size = UDim2.fromScale(1, 1)
		wash.BackgroundColor3 = Color3.new(1, 1, 1)
		wash.BackgroundTransparency = 1
		wash.BorderSizePixel = 0
		wash.ZIndex = parent.ZIndex - 1
		wash.Parent = parent
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.22, 0)
		corner.Parent = wash
		local scale = Instance.new("UIScale")
		scale.Parent = parent
		return wash, scale
	end

	local function debugPaint(target: GuiObject, name: string)
		target.BackgroundColor3 = DEBUG_COLORS[name] or Color3.fromRGB(255, 255, 255)
		target.BackgroundTransparency = if PngCard.DEBUG_HITBOXES then 0.55 else 1
	end

	local function buildRegionButton(name: string, spec: RegionSpec): Region
		local position, size = regionRect(layout, layout.regions[name])
		local button = Instance.new("TextButton")
		button.Name = name:sub(1, 1):upper() .. name:sub(2) .. "Button"
		button.Position = position
		button.Size = size
		button.BorderSizePixel = 0
		button.Text = ""
		button.TextTransparency = 1
		button.AutoButtonColor = false
		button.Active = true
		button.ZIndex = 5
		debugPaint(button, name)
		button.Parent = artwork
		local wash, scale = makeWash(button)
		local region: Region = { name = name, button = button, wash = wash, scale = scale, enabled = true }

		local hovering, pressed = false, false
		local lockedUntil = 0
		button.MouseEnter:Connect(function()
			hovering = true
			if touchOnly() or not region.enabled then
				return
			end
			TweenService:Create(wash, HOVER, { BackgroundTransparency = WASH_HOVER }):Play()
		end)
		button.MouseLeave:Connect(function()
			hovering = false
			TweenService:Create(wash, HOVER, { BackgroundTransparency = 1 }):Play()
			if not pressed then
				TweenService:Create(scale, SETTLE, { Scale = 1 }):Play()
			end
		end)
		button.InputBegan:Connect(function(input)
			if isPointer(input) and region.enabled then
				pressed = true
				TweenService:Create(scale, PRESS, { Scale = 0.96 }):Play()
				wash.BackgroundTransparency = WASH_PRESS
			end
		end)
		button.InputEnded:Connect(function(input)
			if isPointer(input) then
				pressed = false
				-- 0.96 -> ~1.01 -> 1.0 in one Back-eased tween.
				TweenService:Create(scale, REBOUND, { Scale = 1 }):Play()
				TweenService:Create(wash, HOVER, { BackgroundTransparency = if hovering and not touchOnly() then WASH_HOVER else 1 }):Play()
			end
		end)
		button.Activated:Connect(function()
			if not region.enabled then
				return
			end
			local now = os.clock()
			if now < lockedUntil then
				return
			end
			lockedUntil = now + pressLock
			if spec.onActivated then
				-- The request never waits on the animation.
				spec.onActivated()
			end
		end)
		return region
	end

	local function buildRegionHighlight(name: string): Region
		local position, size = regionRect(layout, layout.regions[name])
		local holder = Instance.new("Frame")
		holder.Name = name:sub(1, 1):upper() .. name:sub(2) .. "Focus"
		holder.Position = position
		holder.Size = size
		holder.BorderSizePixel = 0
		holder.Active = false
		holder.ZIndex = 5
		debugPaint(holder, name)
		holder.Parent = artwork
		local wash, scale = makeWash(holder)
		return { name = name, button = nil, wash = wash, scale = scale, enabled = true }
	end

	if options.wholeCard then
		-- ONE button the size of the art. The printed button regions are
		-- highlights that answer this button's hover and press.
		local button = Instance.new("TextButton")
		button.Name = "CardButton"
		button.Size = UDim2.fromScale(1, 1)
		button.BorderSizePixel = 0
		button.Text = ""
		button.TextTransparency = 1
		button.AutoButtonColor = false
		button.Active = true
		button.ZIndex = 4
		debugPaint(button, "whole")
		button.Parent = artwork
		wholeButton = button

		for name in options.regions or layout.regions do
			if layout.regions[name] then
				regions[name] = buildRegionHighlight(name)
			end
		end

		local pressed = false
		local lockedUntil = 0
		local onActivated = options.wholeCard
		button.MouseEnter:Connect(function()
			if touchOnly() or not button.Active then
				return
			end
			washAll(WASH_HOVER, HOVER)
		end)
		button.MouseLeave:Connect(function()
			washAll(1, HOVER)
			if not pressed then
				scaleAll(1, SETTLE)
			end
		end)
		button.InputBegan:Connect(function(input)
			if isPointer(input) and button.Active then
				pressed = true
				scaleAll(0.96, PRESS)
				TweenService:Create(lift, PRESS, { Scale = 0.985 }):Play()
			end
		end)
		button.InputEnded:Connect(function(input)
			if isPointer(input) then
				pressed = false
				scaleAll(1, REBOUND)
				-- A mouse is still hovering after release; a finger is gone.
				TweenService:Create(lift, REBOUND, { Scale = if touchOnly() then 1 else hoverLift }):Play()
				washAll(if touchOnly() then 1 else WASH_HOVER, HOVER)
			end
		end)
		button.Activated:Connect(function()
			if not button.Active then
				return
			end
			local now = os.clock()
			if now < lockedUntil then
				return
			end
			lockedUntil = now + pressLock
			onActivated()
		end)
	else
		for name, spec in options.regions or {} do
			if layout.regions[name] then
				regions[name] = buildRegionButton(name, spec)
			end
		end
	end

	-- Card hover: a small lift of the art. Desktop only by nature; touch has
	-- no hover, and the press feedback covers it there.
	frame.MouseEnter:Connect(function()
		if touchOnly() then
			return
		end
		TweenService:Create(lift, HOVER, { Scale = hoverLift }):Play()
	end)
	frame.MouseLeave:Connect(function()
		TweenService:Create(lift, SETTLE, { Scale = 1 }):Play()
	end)

	local function rectFor(name: string): (UDim2?, UDim2?)
		local rect = layout.regions[name]
		if not rect then
			return nil, nil
		end
		return regionRect(layout, rect)
	end

	--- A state pill: an OPAQUE plate over a printed region (grown by PILL_PAD
	--- so nothing of the printed button shows around it) carrying one word.
	--- Only one state layer exists per region and only the caller decides
	--- when it is visible, so a card can never show two states at once.
	local function pillRect(name: string, position: UDim2, size: UDim2): (UDim2, UDim2)
		local pad = PngCard.PILL_PAD
		local left = pad.X + (PngCard.PILL_EXTRA_LEFT[name] or 0)
		local x = math.max(position.X.Scale - left, 0)
		local right = math.min(position.X.Scale + size.X.Scale + pad.X, 1)
		-- Never over the neighbouring plate: on a card whose two printed
		-- buttons sit close together, the Robux plate stops at a small gutter
		-- from the cash plate's right edge instead of covering its last letter.
		if name == "robux" and layout.regions.cash then
			local cashPosition, cashSize = regionRect(layout, layout.regions.cash)
			x = math.max(x, cashPosition.X.Scale + cashSize.X.Scale + pad.X + 0.006)
		end
		local y = math.max(position.Y.Scale - pad.Y, 0)
		return UDim2.fromScale(x, y), UDim2.fromScale(math.max(right - x, 0.02), math.min(size.Y.Scale + 2 * pad.Y, 1 - y))
	end

	local function pill(name: string, text: string, color: Color3): TextLabel
		local position, size = rectFor(name)
		if position and size then
			position, size = pillRect(name, position, size)
		end
		local label = Instance.new("TextLabel")
		label.Name = name:sub(1, 1):upper() .. name:sub(2) .. "State"
		label.Position = position or UDim2.fromScale(0, 0)
		label.Size = size or UDim2.fromScale(0.3, 0.3)
		label.BackgroundColor3 = Color3.fromRGB(16, 20, 32)
		label.BackgroundTransparency = 0
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
		label.Parent = artwork
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
		pills[name] = label
		return label
	end

	local function setRegionEnabled(name: string, enabled: boolean)
		local region = regions[name]
		if not region then
			return
		end
		region.enabled = enabled
		if region.button then
			region.button.Active = enabled
			region.button.Visible = enabled
		else
			region.wash.Visible = enabled
		end
		if not enabled then
			region.wash.BackgroundTransparency = 1
			region.scale.Scale = 1
		end
	end

	local function setInteractive(enabled: boolean)
		if wholeButton then
			wholeButton.Active = enabled
		end
		for _, region in regions do
			if region.button then
				region.button.Active = enabled and region.enabled
			end
			if not enabled then
				region.wash.BackgroundTransparency = 1
				region.scale.Scale = 1
			end
		end
		if not enabled then
			lift.Scale = 1
		end
	end

	local function retarget(target: Layout)
		layout = target
		applyArt(target)
		for name, region in regions do
			local rect = target.regions[name]
			if rect then
				local position, size = regionRect(target, rect)
				local host = region.button or region.wash.Parent
				if host and host:IsA("GuiObject") then
					host.Position = position
					host.Size = size
				end
			end
		end
		for name, label in pills do
			local rect = target.regions[name]
			if rect then
				local position, size = regionRect(target, rect)
				label.Position, label.Size = pillRect(name, position, size)
			end
		end
	end

	return {
		frame = frame,
		artwork = artwork,
		lift = lift,
		regions = regions,
		wholeButton = wholeButton,
		rectFor = rectFor,
		pill = pill,
		setRegionEnabled = setRegionEnabled,
		setInteractive = setInteractive,
		retarget = retarget,
		destroy = function()
			frame:Destroy()
		end,
	}
end

-- ==========================================================
-- PRELOAD
-- ==========================================================

--- Warms the painted assets so a shop never opens on blank cards. Runs in its
--- own thread and never raises; it is a courtesy, not a gate.
function PngCard.preload(ids: { number })
	task.spawn(function()
		local list = {}
		for _, id in ids do
			table.insert(list, `rbxassetid://{id}`)
		end
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
	end)
end

return PngCard
