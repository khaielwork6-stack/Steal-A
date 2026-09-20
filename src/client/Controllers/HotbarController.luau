--!strict
--[[
	HotbarController
	The player's tools - the Slap, the Trap, the gadgets - and the items in
	their hands, in the pack's own MenuButtons slots along the bottom of the
	screen, keyed 1-9 and 0.

	THE TEMPLATE IS THE OWNER'S. The MenuButtons frame was dropped into the
	place (now under ReplicatedStorage.UITemplates; the old spot in Workspace
	is still accepted). It is cloned into a ScreenGui of its own and driven
	from here. Roblox's default backpack bar is switched off so there is
	exactly one hotbar on screen.

	POSITIONAL AND COMPACT (owner, 2026-09-20). Slots are numbered by
	POSITION with no gaps, and only occupied ones are drawn:

	    [1 Slap][2 Trap][owned gadgets in their fixed order][held items]

	A gadget's key is therefore its position (with no gadgets, the first held
	item is 3). At most HoldConfig.HOTBAR_SLOTS (10) are drawn: keys 1-9, and
	0 is the 10th. Held items that do not fit live in the overflow inventory
	(HeldOverflowController, opened with the backtick key); which side of the
	line an item falls on is decided by its rank alone (HeldLayout).

	EVERY SLOT IS THE SAME SLOT. Tools and held items share one template, one
	key-number style, one size, one equipped highlight/lift, and draw their
	icon the same way - a model in a ViewportFrame - with the name in the same
	place. Only WHAT is painted differs.

	WHAT A SLOT SHOWS
	    Count   its position (0 for the tenth)
	    Icon    the tool or the item, in a ViewportFrame
	    Earns   the tool's / item's name
	The equipped slot wears a bright stroke and lifts a little. Unchanged slots
	are never repainted or re-tweened when the list is rebuilt.

	WHAT IT DOES
	Number keys and taps on a slot toggle a tool through the Humanoid
	(EquipTool / UnequipTools), or make a held item the one in the hands
	(HoldRequest "equip"). The server still owns what everything does.

	WHILE CARRYING (round3-gameplay). During a carry only the gadget slots are
	shown, lifted above the DROP button, keeping their positional numbers, and
	pressing or tapping one USES the gadget directly
	(GadgetController.quickUse) instead of equipping its Tool. Held items are
	hidden then.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)
local HoldConfig = require(ReplicatedStorage.Shared.Config.HoldConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local HeldLayout = require(ReplicatedStorage.Shared.Util.HeldLayout)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local HotbarController = {}

local player = Players.LocalPlayer

local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)
local Device = require(ReplicatedStorage.Shared.Util.Device)

local SLOT_COUNT = HoldConfig.HOTBAR_SLOTS
--- 66 on desktop; a touch layout takes them ~12% smaller so the bar leaves
--- more of the play area and never crowds the jump button. A function, not a
--- constant decided at require time: the layout follows Device changes.
local function slotPixels(): number
	return if Device.isTouch() then 58 else 66
end
local SLOT_GAP = 10
local BOTTOM_INSET = 14

--- Where each known tool sorts. The Bat and the Slap share the first place
--- because the server only ever hands out one of them (Storage > WEAPONS picks
--- which); the Trap is next; gadgets follow in their fixed GadgetConfig order.
--- Anything else goes after, by name.
local TOOL_PRIORITY: { [string]: number } = { Bat = 1, Slap = 1, Trap = 2 }
for _, gadget in GadgetConfig.Gadgets do
	TOOL_PRIORITY[gadget.toolName] = gadget.hotbarSlot
end
local OTHER_PRIORITY = 1000

--- The server's word (StatePush `carrying`) that the player holds loot.
local carrying = false
local DEFAULT_POSITION = UDim2.new(0.5, 0, 1, -BOTTOM_INSET)
--- During a carry the bar's bottom edge sits this far above the DROP button
--- (measured once it has slid in), or at this screen fraction until then.
local CARRY_GAP = 8
local CARRY_FALLBACK_Y = 0.74
local placeToken = 0
local KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	-- Zero is the tenth position, like Roblox's own hotbar.
	[Enum.KeyCode.Zero] = 10,
}

local STROKE_IDLE = Color3.fromRGB(0, 0, 0)
local STROKE_EQUIPPED = Color3.fromRGB(120, 255, 160)
local FACE_IDLE = Color3.fromRGB(255, 255, 255)
local FACE_EQUIPPED = Color3.fromRGB(190, 255, 210)
local LIFT = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local FOV = 36
local VIEW_DIRECTION = Vector3.new(1, 0.6, 1.2).Unit

--- What one position shows this frame.
type Entry = {
	kind: string, -- "tool" | "held"
	id: string, -- identity of what is painted: only a change repaints the slot
	tool: Tool?,
	item: any?,
	rank: number?, -- held: 1-based rank among ALL held items (server order)
}

--- `id`: what the slot last painted (nil = nothing), so a render that shows
--- the same thing repaints nothing. `lifted` / `lift`: the equipped state the
--- slot's scale was last sent to, and the tween doing it, so a render that
--- changes nothing creates nothing.
type Slot = {
	button: TextButton,
	count: TextLabel?,
	name: TextLabel?,
	icon: ImageLabel?,
	scale: UIScale,
	id: string?,
	lifted: boolean?,
	lift: Tween?,
}

local barFrame: Frame? = nil
local slots: { Slot } = {}
--- What each position shows, rebuilt every render.
local entries: { Entry } = {}
--- How many slots are drawn right now (drives the bar's width).
local shownCount = 0
--- The player's HELD items (Inventory entries flagged Held), ranked oldest
--- pickup first (HeldLayout), and how many of them the hotbar has room for.
local heldItems: { any } = {}
local heldSignature = ""
local heldCapacity = 0
local layoutSignature = ""
local layoutListeners: { () -> () } = {}

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

--- Empties the slot's viewport and returns it (with the icon already stripped
--- of any image/plate), or nil when the slot has no icon.
local function clearIcon(slot: Slot): ViewportFrame?
	local icon = slot.icon
	if not icon then
		return nil
	end
	icon.Image = ""
	icon.BackgroundTransparency = 1
	local viewport = viewportIn(icon)
	for _, child in viewport:GetChildren() do
		if child:IsA("BasePart") or child:IsA("Model") then
			child:Destroy()
		end
	end
	return viewport
end

--- Frames `model` (already parented in the viewport) with the slot camera.
local function frameModel(viewport: ViewportFrame, model: Model)
	local min, max = LootModel.worldExtents(model)
	local camera = viewport.CurrentCamera
	if min and max and camera then
		local centre = (min + max) / 2
		local radius = math.max((max - min).Magnitude / 2, 0.3)
		local distance = radius / math.sin(math.rad(FOV) / 2) * 1.1
		camera.CFrame = CFrame.lookAt(centre + VIEW_DIRECTION * distance, centre)
	end
end

--- Puts a copy of the tool's handle in the slot's viewport, framed.
local function paintIcon(slot: Slot, tool: Tool?)
	local viewport = clearIcon(slot)
	if not viewport then
		return
	end
	local handle = tool and tool:FindFirstChild("Handle")
	if not tool or not handle or not handle:IsA("BasePart") then
		viewport.Visible = false
		return
	end
	viewport.Visible = true

	-- THE WHOLE TOOL, not just its Handle. The Bat is one part, so the two
	-- were the same thing; the Slap's Handle is a small grip and the hand
	-- and stick are separate parts welded to it - cloning the Handle alone
	-- put a stub in the slot instead of the Slap. Every part is copied at
	-- its offset from the Handle, so the icon is the tool as it is held.
	local copy = Instance.new("Model")
	copy.Name = tool.Name
	local anchor: BasePart? = nil
	for _, descendant in tool:GetDescendants() do
		if descendant:IsA("BasePart") then
			local part = descendant:Clone()
			for _, inner in part:GetDescendants() do
				if inner:IsA("BaseScript") or inner:IsA("Sound") or inner:IsA("JointInstance") or inner:IsA("Constraint") then
					inner:Destroy()
				end
			end
			part.Anchored = true
			part.CanCollide = false
			-- Relative to the Handle, so the pose is the authored one.
			part.CFrame = handle.CFrame:ToObjectSpace(descendant.CFrame)
			part.Parent = copy
			if descendant == handle then
				anchor = part
			end
		end
	end
	if not anchor then
		viewport.Visible = false
		copy:Destroy()
		return
	end
	copy.PrimaryPart = anchor
	-- Stood up: a bat lies along its Z as authored; on its end it reads as a
	-- bat in a slot rather than a stick seen from above. Measured on the whole
	-- tool, so the Slap (tall along Y already) keeps its hand upright.
	local _, size = copy:GetBoundingBox()
	local longest = math.max(size.X, size.Y, size.Z)
	copy:PivotTo(if longest == size.Z then CFrame.Angles(math.rad(-90), 0, math.rad(25)) else CFrame.Angles(0, 0, math.rad(15)))
	copy.Parent = viewport
	frameModel(viewport, copy)
end

--- Paints a HELD item the way a tool is painted: its real model (the same
--- published preview the Storage panel uses) in the slot's ViewportFrame on
--- the slot's own transparent icon - no plate, no stroke of its own, so the
--- slot looks exactly like a tool slot. The item fills the icon like a tool.
local function paintItemIcon(slot: Slot, item: any?)
	local viewport = clearIcon(slot)
	if not viewport then
		return
	end
	local source = if item then LootModel.previewSource(item.ItemId) else nil
	if not source then
		viewport.Visible = false
		return
	end
	viewport.Visible = true
	viewport.Ambient = Color3.fromRGB(150, 150, 160)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	local copy = source:Clone()
	copy.Name = "Item"
	copy:PivotTo(CFrame.new())
	copy.Parent = viewport
	frameModel(viewport, copy)
end

-- ==========================================================
-- TOOLS AND HELD ITEMS
-- ==========================================================

local function equippedTool(): Tool?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Tool") else nil
end

local function isGadgetTool(tool: Tool): boolean
	return type(tool:GetAttribute("Gadget")) == "string"
end

--- Every tool the player has, in position order: weapon, Trap, gadgets in
--- their fixed order, then anything else by name. No gaps by construction.
local function gatherTools(): { Tool }
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
		local pa, pb = TOOL_PRIORITY[a.Name] or OTHER_PRIORITY, TOOL_PRIORITY[b.Name] or OTHER_PRIORITY
		if pa ~= pb then
			return pa < pb
		end
		return a.Name < b.Name
	end)
	while #tools > SLOT_COUNT do
		table.remove(tools)
	end
	return tools
end

--- The slot caption: a tool's own `HotbarLabel` (the gadgets carry their
--- count there, "Smoke x2"), else its name.
local function labelOf(tool: Tool): string
	local label = tool:GetAttribute("HotbarLabel")
	return if type(label) == "string" then label else tool.Name
end

local function itemName(item: any): string
	local def = LootConfig.ById[item.ItemId]
	return if def then def.name else tostring(item.ItemId)
end

local function pulse(slot: Slot?)
	if not slot then
		return
	end
	local tween = TweenService:Create(slot.scale, LIFT, { Scale = 0.92 })
	tween:Play()
	tween.Completed:Once(function()
		slot.scale.Scale = if slot.lifted then 1.08 else 1
	end)
end

--- Asks the server to make the held item at `rank` (among ALL held items,
--- oldest first) the one in the hands. Also how the overflow panel swaps an
--- item in. Refused while carrying stolen loot.
function HotbarController.equipHeld(rank: number)
	if carrying then
		return
	end
	local item = heldItems[rank]
	if not item then
		return
	end
	-- A TOGGLE: the active item's key puts it away. Taking an item out puts
	-- the Tool away first, at once, without waiting for the server.
	if not item.HeldActive then
		local character = player.Character
		local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
		if humanoid then
			humanoid:UnequipTools()
		end
	end
	Remotes.get("HoldRequest"):FireServer("equip", rank)
end

--- `fromSlot`: the press was a tap/click on the slot rather than a key.
local function toggle(index: number, fromSlot: boolean?)
	local entry = entries[index]
	if not entry then
		return
	end
	if entry.kind == "held" then
		-- Hidden while carrying anyway; belt and braces for a key pressed a
		-- frame before the hide took effect (equipHeld checks it too).
		if entry.rank then
			pulse(slots[index])
			HotbarController.equipHeld(entry.rank)
		end
		return
	end

	local tool = entry.tool
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not tool or not humanoid or humanoid.Health <= 0 then
		return
	end
	-- Carrying: a gadget slot is a direct use, never an equip - by POSITION
	-- now, so pressing the key of the slot you can see uses that gadget.
	local gadget = tool:GetAttribute("Gadget")
	if carrying then
		if type(gadget) == "string" then
			pulse(slots[index])
			require(script.Parent.GadgetController).quickUse(gadget, fromSlot)
		end
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

local function fireLayoutChanged()
	for _, listener in layoutListeners do
		task.spawn(listener)
	end
end

--- Sizes the bar and its slots for the current device.
local function applySize()
	local bar = barFrame
	if not bar then
		return
	end
	local pixels = slotPixels()
	local count = math.max(shownCount, 1)
	bar.Size = UDim2.fromOffset(count * pixels + (count - 1) * SLOT_GAP, pixels + 8)
	for _, slot in slots do
		slot.button.Size = UDim2.fromOffset(pixels, pixels)
	end
end

local function render()
	local tools = gatherTools()
	local capacity = HeldLayout.capacity(#tools)
	heldCapacity = capacity

	local list: { Entry } = {}
	for _, tool in tools do
		table.insert(list, { kind = "tool", id = `t:{tool.Name}`, tool = tool })
	end
	for rank = 1, math.min(capacity, #heldItems) do
		local item = heldItems[rank]
		table.insert(list, { kind = "held", id = `h:{tostring(item.InstanceId)}`, item = item, rank = rank })
	end
	entries = list

	local inHand = equippedTool()
	local shown = 0
	for index, slot in slots do
		local entry = list[index]
		-- A carry keeps only the gadget slots; an unoccupied position is not
		-- drawn at all (no dark placeholders).
		local visible = entry ~= nil and (not carrying or (entry.tool ~= nil and isGadgetTool(entry.tool)))
		if visible then
			shown += 1
		end
		if slot.button.Visible ~= visible then
			slot.button.Visible = visible
		end

		local newId = if entry then entry.id else nil
		if slot.id ~= newId then
			slot.id = newId
			if entry and entry.kind == "held" then
				paintItemIcon(slot, entry.item)
			elseif entry then
				paintIcon(slot, entry.tool)
			else
				paintIcon(slot, nil)
			end
		end

		-- Every render, not only on a change: a gadget's count lives in its
		-- label and changes while the same Tool stays in the slot.
		if slot.name then
			local text = ""
			if entry then
				text = if entry.kind == "held" then itemName(entry.item) else labelOf(entry.tool :: Tool)
			end
			if slot.name.Text ~= text then
				slot.name.Text = text
			end
		end

		local equipped = false
		if entry then
			equipped = if entry.kind == "held" then (entry.item :: any).HeldActive == true else (entry.tool == inHand)
		end
		if not visible then
			-- Nothing to lift while it is not on screen; come back at rest.
			equipped = false
		end
		-- COLOUR ONLY, never the thickness: the pack authors its strokes at a
		-- fraction of a pixel and a plain pixel value makes the engine draw the
		-- border as a filled slab the size of the screen (see ShopKit).
		local stroke = slot.button:FindFirstChildOfClass("UIStroke")
		if stroke then
			local color = if equipped then STROKE_EQUIPPED else STROKE_IDLE
			if stroke.Color ~= color then
				stroke.Color = color
			end
		end
		local face = if equipped then FACE_EQUIPPED else FACE_IDLE
		if slot.button.BackgroundColor3 ~= face then
			slot.button.BackgroundColor3 = face
		end
		local transparency = if entry then 0.25 else 0.6
		if slot.button.BackgroundTransparency ~= transparency then
			slot.button.BackgroundTransparency = transparency
		end
		-- Only when the lift actually changes: every render used to start a
		-- fresh tween on every slot, equipped or not.
		if slot.lifted ~= equipped then
			slot.lifted = equipped
			if slot.lift then
				slot.lift:Cancel()
			end
			if visible then
				local tween = TweenService:Create(slot.scale, LIFT, { Scale = if equipped then 1.08 else 1 })
				slot.lift = tween
				tween:Play()
			else
				slot.scale.Scale = 1
			end
		end
	end

	-- NOTHING TO SHOW, NOTHING SHOWN (owner, 2026-09-19): a carry with no
	-- gadgets leaves the bar empty, so the whole bar goes.
	local bar = barFrame
	if bar and bar.Visible ~= (shown > 0) then
		bar.Visible = shown > 0
	end
	if shown ~= shownCount then
		shownCount = shown
		applySize()
	end

	local signature = `{heldSignature}#{capacity}`
	if signature ~= layoutSignature then
		layoutSignature = signature
		fireLayoutChanged()
	end
end

--- Coalesces render requests into ONE render at the end of the frame. An
--- equip is two events (the tool leaves the Backpack, then arrives in the
--- character) and used to render twice.
local renderQueued = false
local function queueRender()
	if renderQueued then
		return
	end
	renderQueued = true
	task.defer(function()
		renderQueued = false
		render()
	end)
end

--- A signature of just the Held subset of `inventory` (with its order and
--- active flag), so a StatePush that changed something else (income, an
--- unrelated stored item) never triggers a repaint.
local function heldSignatureOf(ranked: { any }): string
	local parts: { string } = {}
	for _, item in ranked do
		table.insert(parts, `{item.InstanceId}:{tostring(item.HeldOrder)}:{if item.HeldActive then 1 else 0}`)
	end
	return table.concat(parts, "|")
end

--- Rebuilds `heldItems` from the latest `inventory` field, but only when the
--- held subset actually changed - `inventory` rides every StatePush merge
--- regardless of whether IT changed (see StateStore), so this is the
--- cheap-diff gate.
local function setHeldItems(inventory: any)
	local ranked = HeldLayout.rank(inventory)
	local signature = heldSignatureOf(ranked)
	if signature == heldSignature then
		return
	end
	heldSignature = signature
	heldItems = ranked
	queueRender()
end

--- The DROP button while it is on screen, or nil. Its AbsolutePosition is
--- compared with the bar's own, never converted into either gui's space.
local function dropButton(): GuiObject?
	local playerGui = player:FindFirstChild("PlayerGui")
	local ui = playerGui and playerGui:FindFirstChild("MainUI")
	local drop = ui and ui:FindFirstChild("DROP BUTTON NEW", true)
	if not drop or not drop:IsA("GuiObject") or not drop.Visible or drop.AbsoluteSize.Y <= 0 then
		return nil
	end
	return drop
end

--- Where the bar sits: the bottom centre normally; during a carry, just above
--- the DROP button (which owns the bottom centre then), so the two never
--- overlap on a short phone screen.
local function place()
	local bar = barFrame
	if not bar then
		return
	end
	placeToken += 1
	if not carrying then
		bar.Position = DEFAULT_POSITION
		return
	end
	local token = placeToken
	bar.Position = UDim2.fromScale(0.5, CARRY_FALLBACK_Y)

	-- SETTLE ONTO THE DROP BUTTON BY MEASUREMENT, NOT ARITHMETIC. Two earlier
	-- versions computed the bar's offset from the button's position and both
	-- put it mid-screen on a phone: the two ScreenGuis disagree about the
	-- top-bar inset, and the phone's UIScale sits between gui pixels and
	-- screen pixels. AbsolutePosition and AbsoluteSize are the one space the
	-- two share, so the bar is nudged by the difference between where its
	-- bottom edge IS and where it should be - the button's top, less a gap -
	-- with only that nudge converted through the bar's own scale. Measured
	-- twice, because DropController slides the button in over ~0.3 s.
	local function settle()
		if token ~= placeToken or not carrying then
			return
		end
		local drop = dropButton()
		if not drop then
			return
		end
		local wantBottom = drop.AbsolutePosition.Y - CARRY_GAP
		local haveBottom = bar.AbsolutePosition.Y + bar.AbsoluteSize.Y
		local nudge = wantBottom - haveBottom
		if math.abs(nudge) < 1 then
			return
		end
		local factor = math.max(ClipSafe.scaleChain(bar), 0.1)
		bar.Position = bar.Position + UDim2.fromOffset(0, nudge / factor)
	end
	task.delay(0.5, settle)
	task.delay(1.4, settle)
end

local function setCarrying(now: boolean)
	if now == carrying then
		return
	end
	carrying = now
	-- Straight away, not deferred: the bar must not show a frame of the wrong
	-- layout. render() only touches what actually changed.
	render()
	place()
end

-- ==========================================================
-- PUBLIC (read by HeldOverflowController)
-- ==========================================================

--- The ranked held items (oldest first, all of them) and how many hotbar
--- positions there are for them: ranks 1..capacity are on the hotbar, the
--- rest are the overflow.
function HotbarController.getHeld(): ({ any }, number)
	return heldItems, heldCapacity
end

--- Runs `fn` whenever the held list or the hotbar's room for it changes.
function HotbarController.onHeldChanged(fn: () -> ())
	table.insert(layoutListeners, fn)
end

--- The hotbar's frame (for placing a button beside it), or nil before build.
function HotbarController.getBar(): Frame?
	return barFrame
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- Wires one slot button exactly the same way whatever it will show.
local function initSlot(button: TextButton, index: number): Slot
	button.Name = `Slot{index}`
	button.LayoutOrder = index
	button.Text = ""
	button.AutoButtonColor = false
	-- The pack ships its buttons with Active off (its own handler drives
	-- them); Activated never fires on an inactive button.
	button.Active = true
	button.Selectable = true
	button.Visible = false
	local scale = button:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = button

	local count = labelIn(button, "Count")
	if count then
		count.Text = tostring(index % 10) -- the key: 1-9, then 0 for the tenth
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

	local slot: Slot = { button = button, count = count, name = name, icon = icon, scale = scale, id = nil }
	if icon then
		paintIcon(slot, nil)
	end
	button.Activated:Connect(function()
		toggle(index, true)
	end)
	return slot
end

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
	bar.Position = DEFAULT_POSITION
	bar.BackgroundTransparency = 1
	barFrame = bar
	bar.Visible = false
	bar.Parent = screen

	local layout = bar:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout.Padding = UDim.new(0, SLOT_GAP)
		layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	end

	local buttons: { TextButton } = {}
	for _, child in bar:GetChildren() do
		if child:IsA("TextButton") then
			table.insert(buttons, child)
		end
	end
	if #buttons == 0 then
		warn("[HotbarController] MenuButtons template has no slot buttons - the hotbar is disabled.")
		screen:Destroy()
		return false
	end
	-- A pristine copy of the LAST template slot (the one the gadget slots
	-- have always used), taken BEFORE anything is painted or renamed, so the
	-- positions past the template's own five are the very same slot.
	local pristine = buttons[#buttons]:Clone()

	for index = 1, SLOT_COUNT do
		local button: TextButton
		local existing = buttons[index]
		if existing then
			button = existing
		else
			button = pristine:Clone()
			button.Parent = bar
		end
		slots[index] = initSlot(button, index)
	end
	pristine:Destroy()

	applySize()
	screen.Parent = player:WaitForChild("PlayerGui")
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

	-- A gadget's count changes its caption without moving the Tool. Hooked
	-- once per Tool (it travels Backpack <-> Character).
	local function hookLabel(tool: Tool)
		if not tool:GetAttribute("_HotbarLabelHooked") then
			tool:SetAttribute("_HotbarLabelHooked", true)
			tool:GetAttributeChangedSignal("HotbarLabel"):Connect(queueRender)
		end
	end

	local function watch(container: Instance)
		for _, child in container:GetChildren() do
			if child:IsA("Tool") then
				hookLabel(child)
			end
		end
		container.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				hookLabel(child)
				queueRender()
			end
		end)
		container.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				queueRender()
			end
		end)
	end

	local backpack = player:WaitForChild("Backpack")
	watch(backpack)
	local function onCharacter(character: Model)
		watch(character)
		task.delay(0.2, queueRender)
	end
	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watch(child)
			queueRender()
		end
	end)

	-- Slot size follows the device if it changes mid-session.
	Device.onTouchChanged(function()
		applySize()
		place()
	end)

	-- The carry layout (round3-gameplay): gadget slots only, above DROP.
	-- The same push carries `inventory`, which is where the held set lives
	-- (Storage entries flagged Held) - no separate remote needed.
	require(script.Parent.Parent.StateStore).subscribe(function(state)
		if type(state) == "table" then
			setCarrying(state.carrying ~= nil)
			setHeldItems(state.inventory)
		end
	end)
	player.CharacterAdded:Connect(function()
		-- A respawn ends any carry; StatePush confirms it shortly after.
		setCarrying(false)
	end)
	local function watchViewport()
		local camera = workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				if carrying then
					place()
				end
			end)
		end
	end
	watchViewport()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchViewport)

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
