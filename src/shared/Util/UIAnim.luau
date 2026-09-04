--!strict
--[[
	UIAnim
	One shared motion vocabulary for the whole HUD.

	Every popup, button and confirmation uses these, so the game has a single
	consistent "feel" instead of each controller inventing its own timings.

	Bias is FAST: nothing here runs longer than ~0.28s. UI motion should read as
	responsiveness, never as something the player waits through.
]]

local TweenService = game:GetService("TweenService")

local UIAnim = {}

-- Shared curves. Back-out is the "juice"; quad-out is for anything frequent
-- enough that a bounce would get annoying.
UIAnim.POP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
UIAnim.SNAP = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
UIAnim.FADE = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
UIAnim.SETTLE = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

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

--- Standard hover/press feedback for any button. Call once per button.
function UIAnim.bindButton(button: GuiButton)
	local scale = scaleOf(button)
	local resting = 1

	local function to(value: number, info: TweenInfo)
		TweenService:Create(scale, info, { Scale = value }):Play()
	end

	button.MouseEnter:Connect(function()
		to(resting * 1.07, UIAnim.SNAP)
	end)
	button.MouseLeave:Connect(function()
		to(resting, UIAnim.SNAP)
	end)
	button.MouseButton1Down:Connect(function()
		to(resting * 0.93, UIAnim.SNAP)
	end)
	button.MouseButton1Up:Connect(function()
		to(resting * 1.07, UIAnim.POP)
	end)
	button.Activated:Connect(function()
		to(resting, UIAnim.POP)
	end)
end

--- Applies bindButton to every descendant button, once.
function UIAnim.bindAllButtons(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiButton") and not descendant:GetAttribute("AnimBound") then
			descendant:SetAttribute("AnimBound", true)
			UIAnim.bindButton(descendant)
		end
	end
end

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
