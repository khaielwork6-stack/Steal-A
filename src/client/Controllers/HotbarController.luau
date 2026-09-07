--!strict
--[[
	HotbarController
	The player's tools - the Bat, the Trap, whatever else they are holding - in
	the pack's own MenuButtons slots along the bottom of the screen, keyed 1-4.

	THE TEMPLATE IS THE OWNER'S. The MenuButtons frame was dropped into the
	place (now under ReplicatedStorage.UITemplates; the old spot in Workspace
	is still accepted). It is cloned into a ScreenGui of its own, cut to four
	slots, and driven from here. Roblox's default backpack bar is switched
	off so there is exactly one hotbar on screen.

	WHAT A SLOT SHOWS
	    Count   the key that equips it (1-4)
	    Icon    the tool itself, in a ViewportFrame, from its own Handle mesh
	    Earns   the tool's name
	An empty slot is dimmed with no icon. The equipped tool's slot wears a
	bright stroke and lifts a little.

	WHAT IT DOES
	Number keys and taps on a slot toggle the tool through the Humanoid
	(EquipTool / UnequipTools). The server still owns what the tools do;
	CombatController still owns the swing and the trap placement - this is
	only which tool is in the hand.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)

local HotbarController = {}

local player = Players.LocalPlayer

local SLOT_COUNT = 4
local SLOT_PIXELS = 66
local SLOT_GAP = 10
local BOTTOM_INSET = 14

--- Fixed keys for the two tools every player carries, so "1 is the Bat"
--- stays true for life; anything else fills the remaining slots by name.
local FIXED_SLOTS: { [string]: number } = { Bat = 1, Trap = 2 }
local KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
}

local STROKE_IDLE = Color3.fromRGB(0, 0, 0)
local STROKE_EQUIPPED = Color3.fromRGB(120, 255, 160)
local FACE_IDLE = Color3.fromRGB(255, 255, 255)
local FACE_EQUIPPED = Color3.fromRGB(190, 255, 210)
local LIFT = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local FOV = 36
local VIEW_DIRECTION = Vector3.new(1, 0.6, 1.2).Unit

type Slot = { button: TextButton, count: TextLabel?, name: TextLabel?, icon: ImageLabel?, viewport: ViewportFrame?, scale: UIScale, tool: Tool? }

local gui: ScreenGui? = nil
local slots: { Slot } = {}
--- Which tool each slot shows this frame, by slot index.
local assignment: { [number]: Tool } = {}

-- ==========================================================
-- TEMPLATE
-- ==========================================================

local function findTemplate(): Frame?
	local templates = ReplicatedStorage:FindFirstChild("UITemplates")
	local frame = templates and templates:FindFirstChild("MenuButtons")
	if not frame then
		frame = workspace:FindFirstChild("MenuButtons")
	end
	return if frame and frame:IsA("Frame") then frame else nil
end

local function labelIn(root: Instance, name: string): TextLabel?
	local found = root:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

local function viewportIn(icon: ImageLabel): ViewportFrame
	local existing = icon:FindFirstChild("Preview")
	if existing and existing:IsA("ViewportFrame") then
		return existing
	end
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview"
	viewport.BackgroundTransparency = 1
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.ZIndex = icon.ZIndex + 1
	viewport.Ambient = Color3.fromRGB(150, 150, 160)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.5, -1, -0.4)
	viewport.Parent = icon
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	return viewport
end

--- Puts a copy of the tool's handle in the slot's viewport, framed.
local function paintIcon(slot: Slot, tool: Tool?)
	local icon = slot.icon
	if not icon then
		return
	end
	icon.Image = ""
	icon.BackgroundTransparency = 1
	local viewport = viewportIn(icon)
	for _, child in viewport:GetChildren() do
		if child:IsA("BasePart") or child:IsA("Model") then
			child:Destroy()
		end
	end
	local handle = tool and tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		viewport.Visible = false
		return
	end
	viewport.Visible = true
	local copy = handle:Clone()
	for _, descendant in copy:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("Sound") or descendant:IsA("JointInstance") then
			descendant:Destroy()
		end
	end
	copy.Anchored = true
	copy.CanCollide = false
	-- Stood up: a bat lies along its Z as authored; on its end it reads as a
	-- bat in a slot rather than a stick seen from above.
	local size = copy.Size
	local longest = math.max(size.X, size.Y, size.Z)
	copy.CFrame = if longest == size.Z then CFrame.Angles(math.rad(-90), 0, math.rad(25)) else CFrame.Angles(0, 0, math.rad(15))
	copy.Parent = viewport
	local min, max = LootModel.worldExtents(copy)
	local camera = viewport.CurrentCamera
	if min and max and camera then
		local centre = (min + max) / 2
		local radius = math.max((max - min).Magnitude / 2, 0.3)
		local distance = radius / math.sin(math.rad(FOV) / 2) * 1.1
		camera.CFrame = CFrame.lookAt(centre + VIEW_DIRECTION * distance, centre)
	end
end

-- ==========================================================
-- TOOLS
-- ==========================================================

local function equippedTool(): Tool?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Tool") else nil
end

--- Every tool the player has, slotted: the fixed ones at their keys, the
--- rest into whatever is free, in name order, up to SLOT_COUNT.
local function gatherTools(): { [number]: Tool }
	local tools: { Tool } = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") then
				table.insert(tools, child)
			end
		end
	end
	local held = equippedTool()
	if held then
		table.insert(tools, held)
	end
	table.sort(tools, function(a, b)
		return a.Name < b.Name
	end)

	local placed: { [number]: Tool } = {}
	local rest: { Tool } = {}
	for _, tool in tools do
		local fixed = FIXED_SLOTS[tool.Name]
		if fixed and not placed[fixed] then
			placed[fixed] = tool
		else
			table.insert(rest, tool)
		end
	end
	local cursor = 1
	for _, tool in rest do
		while cursor <= SLOT_COUNT and placed[cursor] do
			cursor += 1
		end
		if cursor > SLOT_COUNT then
			break
		end
		placed[cursor] = tool
	end
	return placed
end

local function toggle(index: number)
	local tool = assignment[index]
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not tool or not humanoid or humanoid.Health <= 0 then
		return
	end
	if equippedTool() == tool then
		humanoid:UnequipTools()
	else
		humanoid:EquipTool(tool)
	end
end

-- ==========================================================
-- RENDER
-- ==========================================================

local function render()
	assignment = gatherTools()
	local held = equippedTool()
	for index, slot in slots do
		local tool = assignment[index]
		local changed = slot.tool ~= tool
		slot.tool = tool
		if changed then
			paintIcon(slot, tool)
			if slot.name then
				slot.name.Text = if tool then tool.Name else ""
			end
		end
		local equipped = tool ~= nil and tool == held
		-- COLOUR ONLY, never the thickness: the pack authors its strokes at a
		-- fraction of a pixel and a plain pixel value makes the engine draw the
		-- border as a filled slab the size of the screen (see ShopKit).
		local stroke = slot.button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if equipped then STROKE_EQUIPPED else STROKE_IDLE
		end
		slot.button.BackgroundColor3 = if equipped then FACE_EQUIPPED else FACE_IDLE
		slot.button.BackgroundTransparency = if tool then 0.25 else 0.6
		TweenService:Create(slot.scale, LIFT, { Scale = if equipped then 1.08 else 1 }):Play()
	end
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function build(): boolean
	local template = findTemplate()
	if not template then
		warn("[HotbarController] MenuButtons template not found - the hotbar is disabled.")
		return false
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "HotbarUI"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 5
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local bar = template:Clone()
	bar.Name = "Hotbar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -BOTTOM_INSET)
	bar.Size = UDim2.fromOffset(SLOT_COUNT * SLOT_PIXELS + (SLOT_COUNT - 1) * SLOT_GAP, SLOT_PIXELS + 8)
	bar.BackgroundTransparency = 1
	bar.Visible = true
	bar.Parent = screen

	local layout = bar:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout.Padding = UDim.new(0, SLOT_GAP)
		layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	end

	-- The template ships five identical slots; four are kept and renumbered.
	local buttons: { TextButton } = {}
	for _, child in bar:GetChildren() do
		if child:IsA("TextButton") then
			table.insert(buttons, child)
		end
	end
	for index, button in buttons do
		if index > SLOT_COUNT then
			button:Destroy()
			continue
		end
		button.Name = `Slot{index}`
		button.LayoutOrder = index
		button.Size = UDim2.fromOffset(SLOT_PIXELS, SLOT_PIXELS)
		button.Text = ""
		button.AutoButtonColor = false
		-- The pack ships its buttons with Active off (its own handler drives
		-- them); Activated never fires on an inactive button.
		button.Active = true
		button.Selectable = true
		local scale = button:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Parent = button

		local count = labelIn(button, "Count")
		if count then
			count.Text = tostring(index)
		end
		local name = labelIn(button, "Earns")
		if name then
			name.Text = ""
			local gradient = name:FindFirstChildOfClass("UIGradient")
			if gradient then
				gradient:Destroy()
			end
			name.TextColor3 = Color3.fromRGB(240, 244, 252)
		end
		local found = button:FindFirstChild("Icon", true)
		local icon = if found and found:IsA("ImageLabel") then found else nil

		local slot: Slot = { button = button, count = count, name = name, icon = icon, viewport = nil, scale = scale, tool = nil }
		slots[index] = slot
		if icon then
			paintIcon(slot, nil)
		end

		button.Activated:Connect(function()
			toggle(index)
		end)
	end

	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen
	return true
end

-- ==========================================================
-- START
-- ==========================================================

function HotbarController.start()
	if not build() then
		return
	end

	-- One hotbar. Roblox's own is retired; this replaces it fully, keys
	-- included. Retried because CoreGui can refuse for a moment at join.
	task.spawn(function()
		for _ = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end)
			if ok then
				return
			end
			task.wait(0.5)
		end
	end)

	local function watch(container: Instance)
		container.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				task.defer(render)
			end
		end)
		container.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				task.defer(render)
			end
		end)
	end

	local backpack = player:WaitForChild("Backpack")
	watch(backpack)
	local function onCharacter(character: Model)
		watch(character)
		task.delay(0.2, render)
	end
	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watch(child)
			task.defer(render)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local index = KEYS[input.KeyCode]
		if index then
			toggle(index)
		end
	end)

	render()
end

return HotbarController
