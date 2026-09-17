--!strict
--[[
	ClipSafe
	Keeps everything inside a scrolling list INSIDE it.

	THE BUG THIS EXISTS FOR (round3-ui-base-settings)
	Two panels showed controls floating outside their panel while the rows
	around them were clipped properly: the Upgrades > BASE list drew its
	EQUIP / price buttons above the header and below the panel, and Settings
	drew a green "ON" toggle over its own title. In both cases the escaping
	element was a PACK button (a clone of the treadmill card's Money button,
	and the Settings rows' ON / OFF buttons) - never our own plain rows.

	A ScrollingFrame's clip (and ClipsDescendants in general) is a
	screen-aligned scissor rectangle. Roblox does not apply it to rotated
	GuiObjects, and an unclipped high-ZIndex child (under a Global
	ZIndexBehavior) is drawn above the panel header. Pack buttons
	are exactly the elements that rotate: both the pack's LocalScript and
	UIAnim give every button a rotation "punch" on click, and the pack art can
	ship with a resting tilt. So the fix has two layers:

	  1. `sanitize` / `watch`: every GuiObject under the list is held at
	     Rotation 0, and buttons are marked so UIAnim skips its rotation punch
	     and ripple there. The pack's own punch (its connections on the
	     pack-authored rows cannot be removed) is snapped back as it happens.
	  2. `guard`: the list is wrapped in a CanvasGroup of the same rectangle.
	     A CanvasGroup renders its whole subtree into one texture of its own
	     size, so NOTHING inside it can draw outside it - rotated, high
	     ZIndex or otherwise. This is the belt to (1)'s braces, and does not
	     depend on knowing which pack detail caused the escape.

	Keep TextBoxes and ViewportFrames OUT of a guard (pin them above it):
	both are the two element kinds with a history of rendering quirks inside
	CanvasGroups. `ClipSafe.USE_CANVAS_GROUP = false` turns layer 2 off if a
	device ever renders the guarded list badly; layer 1 stays on.
]]

local ClipSafe = {}

--- Layer 2 switch (see the header).
ClipSafe.USE_CANVAS_GROUP = true

--- UIAnim reads these (punchRotation / ripple skip a marked button).
ClipSafe.NO_ROTATION = "_NoRotationPunch"
ClipSafe.NO_RIPPLE = "_NoRipple"

local WATCHED = "_ClipSafeWatched"

local function holdStill(object: GuiObject)
	if object.Rotation ~= 0 then
		object.Rotation = 0
	end
	if object:IsA("GuiButton") then
		object:SetAttribute(ClipSafe.NO_ROTATION, true)
		object:SetAttribute(ClipSafe.NO_RIPPLE, true)
		-- Both punch implementations settle back to these.
		object:SetAttribute("_RestRotation", 0)
		object:SetAttribute("_OrigRotation", 0)
		if not object:GetAttribute(WATCHED) then
			object:SetAttribute(WATCHED, true)
			-- The pack's own punch is connected to its authored buttons and
			-- cannot be disconnected; undo it the moment it writes.
			object:GetPropertyChangedSignal("Rotation"):Connect(function()
				if object.Rotation ~= 0 then
					object.Rotation = 0
				end
			end)
		end
	end
end

--- Zeroes rotation on `root` and every GuiObject below it, and marks buttons.
function ClipSafe.sanitize(root: Instance)
	if root:IsA("GuiObject") then
		holdStill(root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") then
			holdStill(descendant)
		end
	end
end

--- sanitize now, and again for anything added later (rows are rebuilt).
function ClipSafe.watch(root: Instance): RBXScriptConnection
	ClipSafe.sanitize(root)
	return root.DescendantAdded:Connect(function(descendant)
		-- Deferred: the builder sets Rotation-free properties after parenting.
		task.defer(function()
			if descendant.Parent and descendant:IsA("GuiObject") then
				ClipSafe.sanitize(descendant)
			end
		end)
	end)
end

--- Wraps `list` in a CanvasGroup occupying exactly its rectangle and returns
--- the group (or nil when layer 2 is off). Idempotent. Callers that look the
--- list up later by name must search inside the group (`findList`).
function ClipSafe.guard(list: GuiObject): CanvasGroup?
	if not ClipSafe.USE_CANVAS_GROUP then
		return nil
	end
	local parent = list.Parent
	if not parent then
		return nil
	end
	if parent:IsA("CanvasGroup") and parent.Name == `{list.Name}ClipGuard` then
		return parent
	end
	local group = Instance.new("CanvasGroup")
	group.Name = `{list.Name}ClipGuard`
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.AnchorPoint = list.AnchorPoint
	group.Position = list.Position
	group.Size = list.Size
	group.ZIndex = list.ZIndex
	group.LayoutOrder = list.LayoutOrder
	group.Visible = list.Visible
	group.ClipsDescendants = true
	group.Parent = parent
	list.AnchorPoint = Vector2.zero
	list.Position = UDim2.new()
	list.Size = UDim2.fromScale(1, 1)
	list.Visible = true
	list.Parent = group
	return group
end

--- The child named `name` of `parent`, looking through a ClipGuard too.
function ClipSafe.findList(parent: Instance, name: string): Instance?
	local direct = parent:FindFirstChild(name)
	if direct then
		return direct
	end
	local group = parent:FindFirstChild(`{name}ClipGuard`)
	return if group then group:FindFirstChild(name) else nil
end

--- Product of every UIScale from `object` up to its ScreenGui: the factor
--- between a Size offset written on `object`'s children and screen pixels.
function ClipSafe.scaleChain(object: Instance): number
	local factor = 1
	local node: Instance? = object
	while node do
		local scale = node:FindFirstChildOfClass("UIScale")
		if scale and scale.Scale > 0 then
			factor *= scale.Scale
		end
		if node:IsA("LayerCollector") then
			break
		end
		node = node.Parent
	end
	return if factor > 0 then factor else 1
end

return ClipSafe
