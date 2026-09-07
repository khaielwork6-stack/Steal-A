--!strict
--[[
	TrailCardPng
	A trail card whose entire LOOK is a painted PNG. This is the card that
	proved the method on the Green Trail; the general machinery it grew has
	since moved into PngCard, and this module is the trail-specific layer on
	top of it.

	THREE EXCLUSIVE STATES, one set of controls each:

	    not owned   the printed $ and R$ buttons, live (two purchases)
	    owned       ONE polished EQUIP button laid over both printed prices,
	                which hides them completely; pressing it equips
	    equipped    the same button reads ✓ EQUIPPED in green; pressing it
	                again unequips (it reads UNEQUIP under the pointer)

	The printed regions' invisible buttons are DISABLED whenever the toggle is
	shown, so no hidden control can intercept a tap, and nothing of the old
	purchase state is visible behind the new one. There is no "OWNED" tag any
	more: owning is implied by having an EQUIP button.

	THE CARD DECIDES NOTHING. It reports which control was pressed and what
	the server last said about ownership; the caller turns that into a
	TrailRequest, and the server decides whether anything is bought or worn.

	Geometry (crop, aspect, hitboxes) comes from PngUiConfig, measured off the
	asset's pixels. DEBUG_HITBOXES is PngCard's; it ships FALSE.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PngCard = require(ReplicatedStorage.Shared.Util.PngCard)
local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)

local TrailCardPng = {}

export type State = { owned: boolean, equipped: boolean }

export type Options = {
	layout: PngUiConfig.Layout,
	--- Cell aspect the art is fitted into. Defaults to the Trail family.
	familyAspect: number?,
	--- The trail's accent colour, worn by the EQUIP button's outline.
	accent: Color3?,
	--- Fired for the printed cash button while the trail is NOT owned.
	onCash: (State) -> (),
	--- Fired for the printed Robux button. Omit for a cash-only trail; the
	--- region then gets no button at all (and Grey's art has no such button).
	onRobux: ((State) -> ())?,
	--- Fired by the EQUIP / EQUIPPED toggle, with the state it was pressed in:
	--- equipped means "unequip me", otherwise "equip me".
	onToggle: (State) -> (),
}

export type Card = {
	frame: Frame,
	artwork: ImageLabel,
	setState: (State) -> (),
	destroy: () -> (),
}

local PLATE = Color3.fromRGB(16, 20, 32)
local PLATE_EQUIPPED = Color3.fromRGB(14, 34, 24)
local EQUIP_COLOR = Color3.fromRGB(255, 255, 255)
local EQUIPPED_COLOR = Color3.fromRGB(120, 255, 160)
local UNEQUIP_COLOR = Color3.fromRGB(255, 200, 120)

local HOVER = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS = TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local REBOUND = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
--- Two presses inside this window count as one, so a double-tap cannot
--- equip and unequip in the same breath.
local PRESS_LOCK = 0.35

local function touchOnly(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

--- The toggle spans both printed buttons (or the one, on a cash-only card),
--- padded like a state plate so nothing printed shows around it.
local function toggleRect(card: PngCard.Card): (UDim2, UDim2)
	local cashPosition, cashSize = card.rectFor("cash")
	local robuxPosition, robuxSize = card.rectFor("robux")
	local pad = PngCard.PILL_PAD
	local left = if cashPosition then cashPosition.X.Scale else 0.45
	local top = if cashPosition then cashPosition.Y.Scale else 0.62
	local bottom = if cashPosition and cashSize then top + cashSize.Y.Scale else top + 0.28
	local right = if cashPosition and cashSize then left + cashSize.X.Scale else 0.95
	if robuxPosition and robuxSize then
		right = math.max(right, robuxPosition.X.Scale + robuxSize.X.Scale)
		top = math.min(top, robuxPosition.Y.Scale)
		bottom = math.max(bottom, robuxPosition.Y.Scale + robuxSize.Y.Scale)
	end
	left = math.max(left - pad.X, 0)
	top = math.max(top - pad.Y, 0)
	right = math.min(right + pad.X, 1)
	bottom = math.min(bottom + pad.Y, 1)
	return UDim2.fromScale(left, top), UDim2.fromScale(right - left, bottom - top)
end

function TrailCardPng.build(options: Options): Card
	local layout = options.layout
	local state: State = { owned = false, equipped = false }

	local regions: { [string]: PngCard.RegionSpec } = {
		cash = { onActivated = function()
			options.onCash(state)
		end },
	}
	local hasRobux = options.onRobux ~= nil and layout.regions.robux ~= nil
	if hasRobux then
		regions.robux = { onActivated = function()
			(options.onRobux :: (State) -> ())(state)
		end }
	end

	local card = PngCard.build({
		name = "TrailCard",
		layout = layout,
		familyAspect = options.familyAspect,
		regions = regions,
	})

	-- THE TOGGLE. One button, one word, over the printed prices.
	local position, size = toggleRect(card)
	local toggle = Instance.new("TextButton")
	toggle.Name = "EquipToggle"
	toggle.Position = position
	toggle.Size = size
	toggle.BackgroundColor3 = PLATE
	toggle.BorderSizePixel = 0
	toggle.AutoButtonColor = false
	toggle.Font = Enum.Font.FredokaOne
	toggle.TextScaled = true
	toggle.Text = "EQUIP"
	toggle.TextColor3 = EQUIP_COLOR
	toggle.TextStrokeTransparency = 0.5
	toggle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	toggle.Visible = false
	toggle.ZIndex = 8
	toggle.Parent = card.artwork
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.3, 0)
	corner.Parent = toggle
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = options.accent or EQUIP_COLOR
	stroke.Transparency = 0.15
	stroke.Parent = toggle
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 176, 196))
	gradient.Parent = toggle
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.08, 0)
	pad.PaddingRight = UDim.new(0.08, 0)
	pad.PaddingTop = UDim.new(0.16, 0)
	pad.PaddingBottom = UDim.new(0.16, 0)
	pad.Parent = toggle
	local scale = Instance.new("UIScale")
	scale.Parent = toggle

	local function paint(hovering: boolean)
		if state.equipped then
			toggle.BackgroundColor3 = PLATE_EQUIPPED
			toggle.Text = if hovering then "UNEQUIP" else "✓ EQUIPPED"
			toggle.TextColor3 = if hovering then UNEQUIP_COLOR else EQUIPPED_COLOR
			stroke.Color = if hovering then UNEQUIP_COLOR else EQUIPPED_COLOR
		else
			toggle.BackgroundColor3 = PLATE
			toggle.Text = "EQUIP"
			toggle.TextColor3 = EQUIP_COLOR
			stroke.Color = options.accent or EQUIP_COLOR
		end
	end

	local hovering = false
	local lockedUntil = 0
	toggle.MouseEnter:Connect(function()
		hovering = true
		if touchOnly() then
			return
		end
		paint(true)
		TweenService:Create(scale, HOVER, { Scale = 1.05 }):Play()
	end)
	toggle.MouseLeave:Connect(function()
		hovering = false
		paint(false)
		TweenService:Create(scale, HOVER, { Scale = 1 }):Play()
	end)
	toggle.MouseButton1Down:Connect(function()
		TweenService:Create(scale, PRESS, { Scale = 0.95 }):Play()
	end)
	toggle.MouseButton1Up:Connect(function()
		TweenService:Create(scale, REBOUND, { Scale = if hovering and not touchOnly() then 1.05 else 1 }):Play()
	end)
	toggle.Activated:Connect(function()
		local now = os.clock()
		if now < lockedUntil or not state.owned then
			return
		end
		lockedUntil = now + PRESS_LOCK
		options.onToggle(state)
	end)

	local function setState(next: State)
		state = { owned = next.owned == true, equipped = next.equipped == true }
		-- Owned: the toggle stands in for both printed prices, whose hidden
		-- buttons go dead. Not owned: the toggle is gone and the prices are
		-- live. Never both.
		toggle.Visible = state.owned
		card.setRegionEnabled("cash", not state.owned)
		if hasRobux then
			card.setRegionEnabled("robux", not state.owned)
		end
		paint(hovering and not touchOnly())
	end

	return {
		frame = card.frame,
		artwork = card.artwork,
		setState = setState,
		destroy = card.destroy,
	}
end

return TrailCardPng
