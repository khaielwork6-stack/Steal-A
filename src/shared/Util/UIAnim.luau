--!strict
--[[
	UIAnim
	One shared motion vocabulary for the whole game.

	WHERE THESE CURVES COME FROM
	The purchased UI pack ships its own animation LocalScript (StarterGui.MainUI.
	LocalScript) with a genuinely good feel: Back-out hovers, Sine presses,
	Elastic releases, ripple, rotation punch and a grow/pop/shrink notification
	stack. That feel was only ever applied to the pack's OWN demo widgets, which
	is why the leftover demo popups looked alive while our real HUD looked dead.

	The curves below are lifted from that script verbatim so every button and
	panel we build in code - and every pack button we bind - moves identically.
	Change a timing here and the whole game changes with it.

	Bias is FAST. Enters may overshoot; exits never dawdle.
]]

local TweenService = game:GetService("TweenService")

local UIAnim = {}

-- ==========================================================
-- CURVES  (values matched to the pack's LocalScript)
-- ==========================================================

UIAnim.POP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
UIAnim.SNAP = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
UIAnim.FADE = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
UIAnim.SETTLE = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

-- Button feel, straight from the pack.
UIAnim.HOVER = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
UIAnim.UNHOVER = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
UIAnim.PRESS = TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
UIAnim.RELEASE = TweenInfo.new(0.4, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

-- Notification stack feel, also from the pack.
UIAnim.GROW = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
UIAnim.SPRING = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
UIAnim.SHRINK = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

UIAnim.HOVER_SCALE = 1.1
UIAnim.CLICK_SCALE = 0.88
UIAnim.ROTATION_PUNCH = 6 -- degrees

-- ==========================================================
-- PRIMITIVES
-- ==========================================================

local function scaleOf(target: GuiObject): UIScale?
	if not target then
		return nil -- callers may pass a not-yet-built element; never hard error
	end
	local scale = target:FindFirstChildWhichIsA("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = target
	end
	return scale
end
UIAnim.scaleOf = scaleOf

--- Scale-in from nothing with a slight overshoot. Used for panels opening.
function UIAnim.popIn(target: GuiObject, from: number?)
	local scale = scaleOf(target)
	if not scale then
		return
	end
	scale.Scale = from or 0.82
	target.Visible = true
	TweenService:Create(scale, UIAnim.POP, { Scale = 1 }):Play()
end

--- Scale-out then hide. Returns immediately; hiding happens on completion.
function UIAnim.popOut(target: GuiObject)
	local scale = scaleOf(target)
	if not scale then
		return
	end
	local tween = TweenService:Create(scale, UIAnim.SNAP, { Scale = 0.85 })
	tween:Play()
	tween.Completed:Once(function()
		target.Visible = false
		scale.Scale = 1
	end)
end

--- A quick squash-and-recover on an existing element. This is the workhorse for
--- "something just happened here" - purchases, equips, counter changes.
function UIAnim.punch(target: GuiObject, strength: number?)
	local scale = scaleOf(target)
	if not scale then
		return
	end
	local amount = strength or 0.12
	scale.Scale = 1 + amount
	TweenService:Create(scale, UIAnim.POP, { Scale = 1 }):Play()
end

--- Small rotation kick that settles elastically. Lifted from the pack; used on
--- click so a button feels struck rather than merely resized.
function UIAnim.punchRotation(target: GuiObject, degrees: number?)
	if not target then
		return
	end
	local resting = target:GetAttribute("_RestRotation")
	if resting == nil then
		resting = target.Rotation
		target:SetAttribute("_RestRotation", resting)
	end

	local amount = degrees or UIAnim.ROTATION_PUNCH
	local direction = if math.random(0, 1) == 0 then -1 else 1

	local kick = TweenService:Create(
		target,
		TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Rotation = (resting :: number) + amount * direction }
	)
	kick:Play()
	kick.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed then
			TweenService:Create(target, UIAnim.RELEASE, { Rotation = resting }):Play()
		end
	end)
end

--- Flash a label toward a colour and back. Used for cash gains and errors.
function UIAnim.flashColor(label: TextLabel, color: Color3)
	local original = label.TextColor3
	label.TextColor3 = color
	TweenService:Create(label, UIAnim.SETTLE, { TextColor3 = original }):Play()
end

--- Slide + fade in from an offset. For toasts and the interact prompt.
function UIAnim.slideIn(target: GuiObject, offset: UDim2)
	local final = target.Position
	target.Position = final + offset
	target.Visible = true
	TweenService:Create(target, UIAnim.SETTLE, { Position = final }):Play()
	return final
end

-- ==========================================================
-- NUMBER COUNTING
-- ==========================================================

--- Tweens a label's NUMBER rather than snapping it, so "10 -> 11" storage and
--- cash gains read as an increase instead of a swap. `format` turns the running
--- value into display text.
---
--- Re-entrant: a second call on the same label cancels the first, so spamming a
--- purchase button can never leave two counters fighting over one label.
function UIAnim.countTo(label: TextLabel, to: number, format: ((number) -> string)?, duration: number?)
	if not label then
		return
	end

	local formatter = format or function(value: number)
		return tostring(math.floor(value + 0.5))
	end

	local from = label:GetAttribute("_CountValue")
	if type(from) ~= "number" then
		from = to -- first paint: no animation, just show the value
	end

	label:SetAttribute("_CountValue", to)

	if from == to then
		label.Text = formatter(to)
		return
	end

	-- Token guards against overlapping counts on the same label.
	local token = os.clock()
	label:SetAttribute("_CountToken", token)

	local span = duration or 0.35
	local start = os.clock()

	task.spawn(function()
		while true do
			if label.Parent == nil or label:GetAttribute("_CountToken") ~= token then
				return
			end
			local alpha = math.clamp((os.clock() - start) / span, 0, 1)
			-- Quad-out: fast first, eases into the final number.
			local eased = 1 - (1 - alpha) * (1 - alpha)
			label.Text = formatter((from :: number) + (to - (from :: number)) * eased)
			if alpha >= 1 then
				label.Text = formatter(to)
				return
			end
			task.wait()
		end
	end)
end

-- ==========================================================
-- RIPPLE  (extracted from the pack)
-- ==========================================================

--- A ripple needs its own clipped CanvasGroup, otherwise turning on
--- ClipsDescendants for the button itself cuts off badges and labels that
--- deliberately overhang its bounds.
local function rippleContainer(button: GuiButton): CanvasGroup
	local existing = button:FindFirstChild("_RippleContainer")
	if existing and existing:IsA("CanvasGroup") then
		return existing
	end

	local container = Instance.new("CanvasGroup")
	container.Name = "_RippleContainer"
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Size = UDim2.fromScale(1, 1)
	container.ZIndex = 0
	container.ClipsDescendants = true
	container.Parent = button

	local corner = button:FindFirstChildOfClass("UICorner")
	if corner then
		corner:Clone().Parent = container
	end

	return container
end

--- Expanding circle from the press point. Purely decorative; safe to no-op.
function UIAnim.ripple(button: GuiButton, at: Vector3?)
	local size = button.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end

	local container = rippleContainer(button)
	local origin = button.AbsolutePosition

	local x, y = 0.5, 0.5
	if at then
		x = (at.X - origin.X) / size.X
		y = (at.Y - origin.Y) / size.Y
	end

	local circle = Instance.new("Frame")
	circle.Name = "_Ripple"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.BackgroundColor3 = Color3.new(1, 1, 1)
	circle.BackgroundTransparency = 0.45
	circle.BorderSizePixel = 0
	circle.Position = UDim2.fromScale(x, y)
	circle.Size = UDim2.fromOffset(0, 0)
	circle.Parent = container

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = circle

	local reach = math.max(size.X, size.Y) * 1.6
	local tween = TweenService:Create(
		circle,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(reach, reach), BackgroundTransparency = 1 }
	)
	tween:Play()
	tween.Completed:Once(function()
		circle:Destroy()
	end)
end

-- ==========================================================
-- BUTTONS
-- ==========================================================

-- The pack's own animation LocalScript stamps this on every button it wires up.
-- We honour it, and stamp it ourselves, so exactly one of the two systems ever
-- drives a given button. Without that both bind: they share one UIScale (so the
-- scaling merely doubles up harmlessly) but each also spawns its own ripple and
-- its own rotation punch, and the two punches pick independent random
-- directions and fight over the Rotation property.
local PACK_BOUND_ATTRIBUTE = "_UIHandlerSetup"

--- Standard hover / press / release feedback for any button, matching the pack.
--- Idempotent, and a no-op on buttons the pack already owns.
---
--- InputBegan/InputEnded rather than MouseButton1Down/Up, because the mouse
--- events never fire on touch - mobile buttons would otherwise be dead.
function UIAnim.bindButton(button: GuiButton)
	if button:GetAttribute("AnimBound") or button:GetAttribute(PACK_BOUND_ATTRIBUTE) then
		return
	end
	button:SetAttribute("AnimBound", true)
	-- Claim it from the pack's scanner too, whichever of us runs first.
	button:SetAttribute(PACK_BOUND_ATTRIBUTE, true)

	local scale = scaleOf(button)
	if not scale then
		return
	end

	local hovering = false
	local pressed = false

	local function to(value: number, info: TweenInfo)
		TweenService:Create(scale, info, { Scale = value }):Play()
	end

	button.MouseEnter:Connect(function()
		hovering = true
		if not pressed then
			to(UIAnim.HOVER_SCALE, UIAnim.HOVER)
		end
	end)

	button.MouseLeave:Connect(function()
		hovering = false
		if not pressed then
			to(1, UIAnim.UNHOVER)
		end
	end)

	button.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			pressed = true
			to(UIAnim.CLICK_SCALE, UIAnim.PRESS)
			UIAnim.ripple(button, input.Position)
		end
	end)

	button.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			pressed = false
			to(if hovering then UIAnim.HOVER_SCALE else 1, UIAnim.RELEASE)
		end
	end)

	button.Activated:Connect(function()
		UIAnim.punchRotation(button)
	end)
end

--- Takes ownership of a button we drive ourselves, rather than the pack.
---
--- Use this on ANY button cloned from, or reused out of, the purchased pack.
--- Two things about those buttons silently produce a dead control:
---
--- 1. They ship with `Active = false`. The pack drives its own buttons from
---    InputBegan and MouseButton1Click, both of which still fire; `Activated`
---    does NOT fire while Active is false. Anything we wire with `Activated` -
---    which is everything we write - therefore has to switch it back on.
---
--- 2. They already carry `_UIHandlerSetup`, and bindButton deliberately bails on
---    that attribute so it never fights the pack. A clone inherits it, so the
---    button ends up claimed but with no hover, press or ripple at all. Both
---    attributes have to be cleared BEFORE binding; bindButton re-stamps
---    `_UIHandlerSetup` on its way out, which is what keeps the pack off it.
---
--- Both of these have bitten this project once each. Always route through here.
function UIAnim.claimButton(button: GuiButton)
	button:SetAttribute(PACK_BOUND_ATTRIBUTE, nil)
	button:SetAttribute("AnimBound", nil)
	UIAnim.bindButton(button)
	button.Active = true
	button.Selectable = true
end

--- Applies bindButton to every descendant button, once.
function UIAnim.bindAllButtons(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiButton") then
			UIAnim.bindButton(descendant)
		end
	end
end

-- ==========================================================
-- BARS
-- ==========================================================

--- Tween a bar's fill. Always anchored left so it grows left-to-right.
function UIAnim.setBarFill(bar: GuiObject, alpha: number, height: number?)
	bar.AnchorPoint = Vector2.new(0, 0.5)
	if bar.Position.X.Scale ~= 0 then
		bar.Position = UDim2.new(0, 0, 0.5, 0)
	end
	TweenService:Create(bar, UIAnim.SETTLE, {
		Size = UDim2.new(math.clamp(alpha, 0, 1), 0, height or bar.Size.Y.Scale, 0),
	}):Play()
end

return UIAnim
