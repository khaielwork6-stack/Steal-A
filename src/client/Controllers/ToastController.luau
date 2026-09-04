--!strict
--[[
	ToastController
	The one and only path from a server Notify to something on screen.

	WHY THIS EXISTS
	The HUD used to show a notification by writing text into the pack's template
	frame and flipping its Visible flag. Two things went wrong with that:

	  1. The template is what the pack's own animation script CLONES from. Writing
	     our text into it meant our steal message leaked into unrelated popups.
	  2. Showing the template in place skips the pack's grow/spring/shrink
	     animation entirely, which is exactly why real game feedback looked dead
	     while the pack's leftover demo popups looked alive.

	So: never touch a template. Clone it, write into the CLONE, animate the
	clone, destroy the clone. The templates stay pristine and hidden forever.

	Stacking is handled by the pack's UIListLayout in Notifications - a new toast
	enters at height 0 and grows, which pushes older ones down on its own.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ToastController = {}

local player = Players.LocalPlayer

-- How long a toast sits at full size before it shrinks away.
local DISPLAY_TIME = 2.2
-- Identical text arriving inside this window is treated as a duplicate. Guards
-- against a server that legitimately fires the same message twice in a frame.
local DEDUPE_WINDOW = 0.4
-- Beyond this the stack starts eating the screen; oldest is retired early.
local MAX_ON_SCREEN = 4

--- Server "kind" -> which pack template carries the right colour treatment.
local TEMPLATE_FOR_KIND: { [string]: string } = {
	success = "Collected",
	error = "InventoryFull",
	info = "PickedUp",
	spawn = "Spawned",
}

local holder: Frame? = nil
local templates: { [string]: GuiObject } = {}
local live: { CanvasGroup } = {}
local layoutOrder = 0
local lastMessage = ""
local lastMessageAt = 0

local function findTitle(root: Instance): TextLabel?
	local direct = root:FindFirstChild("Title", true)
	if direct and direct:IsA("TextLabel") then
		return direct
	end
	return root:FindFirstChildWhichIsA("TextLabel", true)
end

local function retire(container: CanvasGroup)
	if not container.Parent then
		return
	end

	local index = table.find(live, container)
	if index then
		table.remove(live, index)
	end

	local width = container.Size.X
	local shrink = TweenService:Create(container, UIAnim.SHRINK, {
		Size = UDim2.new(width.Scale, width.Offset, 0, 0),
		GroupTransparency = 1,
	})
	shrink:Play()
	shrink.Completed:Once(function()
		container:Destroy()
	end)
end

--- Shows one toast. `kind` picks the pack frame; `message` is written to the
--- clone only.
function ToastController.show(kind: string, message: string)
	if not holder then
		return
	end

	local now = os.clock()
	if message == lastMessage and now - lastMessageAt < DEDUPE_WINDOW then
		return
	end
	lastMessage, lastMessageAt = message, now

	local template = templates[TEMPLATE_FOR_KIND[kind] or "PickedUp"] or templates["PickedUp"]
	if not template then
		return
	end

	while #live >= MAX_ON_SCREEN do
		retire(live[1])
	end

	local target = template.Size

	-- CanvasGroup drives the fade of the whole toast as one unit, and starting
	-- it at height 0 is what makes the list layout push the others down.
	local container = Instance.new("CanvasGroup")
	container.Name = "Toast"
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.GroupTransparency = 1
	container.Size = UDim2.new(target.X.Scale, target.X.Offset, 0, 0)
	layoutOrder -= 1
	container.LayoutOrder = layoutOrder -- newest on top
	container.Parent = holder

	local clone = template:Clone()
	clone.Visible = true
	clone.Position = UDim2.fromScale(0, 0)
	clone.Size = UDim2.fromScale(1, 1)
	clone.Parent = container

	local title = findTitle(clone)
	if title then
		title.Text = message
	end

	-- Content springs independently of the container's height growth, which is
	-- what gives the pack's notifications their bounce.
	local scale = Instance.new("UIScale")
	scale.Scale = 0.5
	scale.Parent = clone

	table.insert(live, container)

	TweenService:Create(container, UIAnim.GROW, { Size = target, GroupTransparency = 0 }):Play()
	TweenService:Create(scale, UIAnim.SPRING, { Scale = 1 }):Play()

	task.delay(DISPLAY_TIME, function()
		retire(container)
	end)
end

function ToastController.start(ui: ScreenGui)
	local found = ui:FindFirstChild("Notifications")
	if not found or not found:IsA("Frame") then
		warn("[ToastController] MainUI.Notifications missing - toasts disabled.")
		return
	end
	holder = found

	-- Catalogue the pack's frames as templates and make sure they never render
	-- themselves. The pack's own script does this too; doing it here as well
	-- means we do not depend on which script wins the race at load.
	for _, child in found:GetChildren() do
		if child:IsA("GuiObject") then
			templates[child.Name] = child
			child.Visible = false
		end
	end
end

return ToastController
