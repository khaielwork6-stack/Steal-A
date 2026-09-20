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

	WHILE CARRYING (round3-gameplay). The carry HUD claim no longer hides this
	bar (UIStateController.SCREEN_KEEP). During a carry only the gadget slots
	(3-5) are shown, lifted above the DROP button, and pressing or tapping one
	USES the gadget directly (GadgetController.quickUse) instead of equipping
	its Tool, so nothing about the carry or the hand changes.

	HELD ITEMS [hold-items]. After the tool slots (1..SLOT_COUNT) come up to
	HoldConfig.MAX_HELD_ITEMS more slots, one per item currently held in the
	hands (server: HoldService). They ride the ordinary `inventory` field
	already pushed for the Storage panel - filtered to Held items, ranked by
	HeldOrder ascending, so "pick up a second item and the hand becomes 1, 2"
	needs no renumbering here or on the server: rank IS the slot number.
	Keys 6-9 and 0 equip hand slots 1-4; the (rare) 5th and 6th are tap-only.
	Tapping a hand slot does not equip a Tool - it fires HoldRequest("equip",
	rank), the same as pressing its key. These slots are hidden while
	carrying stolen loot, same rule as the gadget slots.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local HoldConfig = require(ReplicatedStorage.Shared.Config.HoldConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local HotbarController = {}

local player = Players.LocalPlayer

local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)
local Device = require(ReplicatedStorage.Shared.Util.Device)

--- Five since the gadgets (gadgets-patrols area): weapon, trap, and the three
--- gadgets on 3-5. The pack's MenuButtons template ships exactly five slots;
--- a template with fewer simply shows fewer (see `slotCount`).
local SLOT_COUNT = 5
--- 66 on desktop; a touch layout takes them ~12% smaller so the bar leaves
--- more of the play area and never crowds the jump button. A function, not a
--- constant decided at require time: the layout follows Device changes.
local function slotPixels(): number
	return if Device.isTouch() then 58 else 66
end
local SLOT_GAP = 10
local BOTTOM_INSET = 14

--- Fixed keys, so "1 is my weapon" and "2 is the Trap" stay true for life.
--- The Bat and the Slap share slot 1 because the server only ever hands out
--- one of them (Storage > WEAPONS picks which); anything else fills the
--- remaining slots by name.
local FIXED_SLOTS: { [string]: number } = { Bat = 1, Slap = 1, Trap = 2 }
--- The slot indices that belong to gadgets (shown during a carry).
local GADGET_SLOTS: { [number]: boolean } = {}
-- Gadgets keep their own keys (GadgetConfig.hotbarSlot), so "3 is smoke"
-- stays true whether or not the player holds the other two.
for _, gadget in require(ReplicatedStorage.Shared.Config.GadgetConfig).Gadgets do
	FIXED_SLOTS[gadget.toolName] = gadget.hotbarSlot
	GADGET_SLOTS[gadget.hotbarSlot] = true
end

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
	-- [hold-items] Hand slots continue the numbering (SLOT_COUNT + rank).
	-- Five number-row keys are left (6, 7, 8, 9, 0): hand ranks 1-5 get a
	-- key each; if HoldConfig.MAX_HELD_ITEMS's 6th slot is ever filled it is
	-- still shown, numbered 11, but is tap/click-only (no key left to bind).
	[Enum.KeyCode.Six] = SLOT_COUNT + 1,
	[Enum.KeyCode.Seven] = SLOT_COUNT + 2,
	[Enum.KeyCode.Eight] = SLOT_COUNT + 3,
	[Enum.KeyCode.Nine] = SLOT_COUNT + 4,
	[Enum.KeyCode.Zero] = SLOT_COUNT + 5,
}

local STROKE_IDLE = Color3.fromRGB(0, 0, 0)
local STROKE_EQUIPPED = Color3.fromRGB(120, 255, 160)
local FACE_IDLE = Color3.fromRGB(255, 255, 255)
local FACE_EQUIPPED = Color3.fromRGB(190, 255, 210)
local LIFT = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local FOV = 36
local VIEW_DIRECTION = Vector3.new(1, 0.6, 1.2).Unit

--- `lifted` / `lift`: the equipped state the slot's scale was last sent to,
--- and the tween doing it, so a render that changes nothing creates nothing.
--- `heldId`: [hold-items] the InstanceId a HAND slot last painted, so a
--- render that shows the same held item repaints nothing (tool: field is
--- always nil for a hand slot; heldId is always nil for a tool slot).
type Slot = {
	button: TextButton,
	count: TextLabel?,
	name: TextLabel?,
	icon: ImageLabel?,
	viewport: ViewportFrame?,
	scale: UIScale,
	tool: Tool?,
	heldId: string?,
	lifted: boolean?,
	lift: Tween?,
}

local gui: ScreenGui? = nil
local barFrame: Frame? = nil
local slots: { Slot } = {}
--- Which tool each slot shows this frame, by slot index.
local assignment: { [number]: Tool } = {}
--- [hold-items] How many of `slots` are real tool slots (<= SLOT_COUNT); the
--- rest are hand slots. Set once in build() - never `#slots`, which after
--- the hand slots are appended would let gatherTools() spill a Backpack tool
--- into a hand slot's index.
local builtToolSlots = 0
--- [hold-items] The player's currently HELD items (profile.Inventory
--- entries with Held == true), ranked by HeldOrder ascending - rank N is
--- hand slot N. Rebuilt from StateStore's `inventory` field whenever its
--- held subset actually changes.
local heldItems: { any } = {}
local heldSignature = ""

--- True if slot `index` refers to a HAND slot rather than a tool slot.
local function isHeldSlot(index: number): boolean
	return index > SLOT_COUNT
end

--- The 1-based hand rank a hand slot's index maps to.
local function heldRankOf(index: number): number
	return index - SLOT_COUNT
end

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
-- HELD ITEMS [hold-items]
-- ==========================================================

--- Paints (or clears) a HAND slot's icon with the real item's model, the
--- same ViewportFrame-on-a-rarity-plate the Storage panel uses (ItemThumb) -
--- so a held trophy looks the same in the hotbar as it does in Storage.
local function paintHeldIcon(slot: Slot, item: any?)
	local icon = slot.icon
	if not icon then
		return
	end
	if not item then
		local preview = icon:FindFirstChild("Preview")
		if preview and preview:IsA("GuiObject") then
			preview.Visible = false
		end
		return
	end
	ItemThumb.apply(icon, item.Rarity, item.ItemId)
end

--- A signature of just the Held subset of `inventory`, so a StatePush that
--- changed something else (income, an unrelated stored item) never triggers
--- a hand-slot repaint.
local function heldSignatureOf(inventory: any): string
	if type(inventory) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	for _, item in inventory do
		if type(item) == "table" and item.Held then
			table.insert(parts, `{item.InstanceId}:{tostring(item.HeldOrder)}:{if item.HeldActive then 1 else 0}`)
		end
	end
	table.sort(parts)
	return table.concat(parts, "|")
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

	-- The TOOL slots actually built (a template may ship fewer than
	-- SLOT_COUNT). NOT #slots - [hold-items] appends more entries to `slots`
	-- for the hand slots, and a Backpack tool must never spill into one.
	local limit = if builtToolSlots > 0 then builtToolSlots else SLOT_COUNT
	local placed: { [number]: Tool } = {}
	local rest: { Tool } = {}
	for _, tool in tools do
		local fixed = FIXED_SLOTS[tool.Name]
		if fixed and fixed <= limit and not placed[fixed] then
			placed[fixed] = tool
		else
			table.insert(rest, tool)
		end
	end
	local cursor = 1
	for _, tool in rest do
		while cursor <= limit and placed[cursor] do
			cursor += 1
		end
		if cursor > limit then
			break
		end
		placed[cursor] = tool
	end
	return placed
end

--- The slot caption: a tool's own `HotbarLabel` (the gadgets carry their
--- count there, "Smoke x2"), else its name.
local function labelOf(tool: Tool): string
	local label = tool:GetAttribute("HotbarLabel")
	return if type(label) == "string" then label else tool.Name
end

--- `fromSlot`: the press was a tap/click on the slot rather than a key.
--- [hold-items] A key press or a tap on a HAND slot: pulse it and ask the
--- server to make that held item the one shown small in the hands. Never an
--- equip of anything Tool-shaped, and refused outright while carrying stolen
--- loot (the slot is hidden then anyway - this is the belt-and-braces check
--- for a key pressed a frame before the hide took effect).
local function toggleHeld(index: number)
	if carrying then
		return
	end
	local item = heldItems[heldRankOf(index)]
	if not item or item.HeldActive then
		return
	end
	local slot = slots[index]
	if slot then
		local pulse = TweenService:Create(slot.scale, LIFT, { Scale = 0.92 })
		pulse:Play()
		pulse.Completed:Once(function()
			slot.scale.Scale = if slot.lifted then 1.08 else 1
		end)
	end
	Remotes.get("HoldRequest"):FireServer("equip", heldRankOf(index))
end

local function toggle(index: number, fromSlot: boolean?)
	if isHeldSlot(index) then
		toggleHeld(index)
		return
	end
	local tool = assignment[index]
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not tool or not humanoid or humanoid.Health <= 0 then
		return
	end
	-- Carrying: a gadget slot is a direct use, never an equip.
	local gadget = tool:GetAttribute("Gadget")
	if carrying and GADGET_SLOTS[index] and type(gadget) == "string" then
		local slot = slots[index]
		if slot then
			local pulse = TweenService:Create(slot.scale, LIFT, { Scale = 0.92 })
			pulse:Play()
			pulse.Completed:Once(function()
				slot.scale.Scale = if slot.lifted then 1.08 else 1
			end)
		end
		require(script.Parent.GadgetController).quickUse(gadget, fromSlot)
		return
	end
	if carrying and GADGET_SLOTS[index] then
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
	-- NOTHING TO SHOW, NOTHING SHOWN (owner, 2026-09-19). A carry keeps only
	-- the gadget slots, and a player with no gadgets was left holding three
	-- empty squares in the middle of the screen. A gadget's Tool exists only
	-- while its count is above zero, so "no Tool in any gadget slot" IS
	-- "owns no gadgets": the whole bar goes.
	local bar = barFrame
	if bar then
		local anyGadget = false
		for index in GADGET_SLOTS do
			if assignment[index] then
				anyGadget = true
				break
			end
		end
		local show = not carrying or anyGadget
		if bar.Visible ~= show then
			bar.Visible = show
		end
	end
	for index, slot in slots do
		local isHeld = isHeldSlot(index)
		local tool = if isHeld then nil else assignment[index]
		local heldItem = if isHeld then heldItems[heldRankOf(index)] else nil
		-- A carry shows only the gadget slots; a hand slot with nothing in
		-- it is left invisible too (see the header - "nothing to show").
		local visible = if isHeld then (not carrying and heldItem ~= nil) else (not carrying or GADGET_SLOTS[index] == true)
		if slot.button.Visible ~= visible then
			slot.button.Visible = visible
		end
		if isHeld then
			local heldId = heldItem and heldItem.InstanceId
			if slot.heldId ~= heldId then
				slot.heldId = heldId
				paintHeldIcon(slot, heldItem)
			end
		else
			local changed = slot.tool ~= tool
			slot.tool = tool
			if changed then
				paintIcon(slot, tool)
			end
		end
		-- Every render, not only on a change of tool: a gadget's count lives
		-- in its label and changes while the same Tool stays in the slot.
		if slot.name then
			local text
			if isHeld then
				if heldItem then
					local def = LootConfig.ById[heldItem.ItemId]
					text = if def then def.name else heldItem.ItemId
				else
					text = ""
				end
			else
				text = if tool then labelOf(tool) else ""
			end
			if slot.name.Text ~= text then
				slot.name.Text = text
			end
		end
		local equipped = if isHeld then (heldItem ~= nil and heldItem.HeldActive == true) else (tool ~= nil and tool == held)
		-- COLOUR ONLY, never the thickness: the pack authors its strokes at a
		-- fraction of a pixel and a plain pixel value makes the engine draw the
		-- border as a filled slab the size of the screen (see ShopKit).
		local stroke = slot.button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if equipped then STROKE_EQUIPPED else STROKE_IDLE
		end
		slot.button.BackgroundColor3 = if equipped then FACE_EQUIPPED else FACE_IDLE
		slot.button.BackgroundTransparency = if (tool or heldItem) then 0.25 else 0.6
		-- Only when the lift actually changes: every render used to start a
		-- fresh tween on all four slots, equipped or not.
		if slot.lifted ~= equipped then
			slot.lifted = equipped
			if slot.lift then
				slot.lift:Cancel()
			end
			local tween = TweenService:Create(slot.scale, LIFT, { Scale = if equipped then 1.08 else 1 })
			slot.lift = tween
			tween:Play()
		end
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

--- Sizes the bar and its slots for the current device.
local function applySize()
	local bar = barFrame
	if not bar then
		return
	end
	local pixels = slotPixels()
	local shown = 0
	for index in slots do
		-- [hold-items] A hand slot only counts toward the bar's width while
		-- it actually holds something; an empty one is never shown (see
		-- render()'s visibility rule, mirrored here).
		local counts = if isHeldSlot(index)
			then (not carrying and heldItems[heldRankOf(index)] ~= nil)
			else (not carrying or GADGET_SLOTS[index] == true)
		if counts then
			shown += 1
		end
	end
	local count = math.max(shown, 1)
	bar.Size = UDim2.fromOffset(count * pixels + (count - 1) * SLOT_GAP, pixels + 8)
	for _, slot in slots do
		slot.button.Size = UDim2.fromOffset(pixels, pixels)
	end
end

--- [hold-items] Rebuilds `heldItems` (ranked, HeldOrder ascending) from the
--- latest `inventory` field and re-renders, but only when the held subset
--- actually changed - `inventory` rides every StatePush merge regardless of
--- whether IT changed (see StateStore), so this is the cheap-diff gate.
local function setHeldItems(inventory: any)
	local signature = heldSignatureOf(inventory)
	if signature == heldSignature then
		return
	end
	heldSignature = signature
	local list: { any } = {}
	if type(inventory) == "table" then
		for _, item in inventory do
			if type(item) == "table" and item.Held then
				table.insert(list, item)
			end
		end
	end
	table.sort(list, function(a, b)
		return (tonumber(a.HeldOrder) or 0) < (tonumber(b.HeldOrder) or 0)
	end)
	heldItems = list
	applySize()
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
	applySize()
	place()
	queueRender()
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
	bar.BackgroundTransparency = 1
	barFrame = bar
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
	-- [hold-items] A pristine copy of one slot, taken BEFORE the loop below
	-- paints or renames anything, so the hand slots appended after it start
	-- from the same clean template rather than a tool-icon-primed leftover.
	local heldTemplateButton = if buttons[1] then buttons[1]:Clone() else nil
	builtToolSlots = math.min(#buttons, SLOT_COUNT)
	for index, button in buttons do
		if index > SLOT_COUNT then
			button:Destroy()
			continue
		end
		button.Name = `Slot{index}`
		button.LayoutOrder = index
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

		local slot: Slot = { button = button, count = count, name = name, icon = icon, viewport = nil, scale = scale, tool = nil, heldId = nil }
		slots[index] = slot
		if icon then
			paintIcon(slot, nil)
		end

		button.Activated:Connect(function()
			toggle(index, true)
		end)
	end

	-- [hold-items] Up to HoldConfig.MAX_HELD_ITEMS more slots, appended after
	-- the tool slots (same LayoutOrder scheme, so the UIListLayout just
	-- keeps going along the bar) - one per possible held item. Empty ones
	-- are built but left invisible; render() shows only the ones in use.
	if heldTemplateButton then
		for rank = 1, HoldConfig.MAX_HELD_ITEMS do
			local index = SLOT_COUNT + rank
			local button = heldTemplateButton:Clone()
			button.Name = `Slot{index}`
			button.LayoutOrder = index
			button.Text = ""
			button.AutoButtonColor = false
			button.Active = true
			button.Selectable = true
			button.Visible = false
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

			local slot: Slot = { button = button, count = count, name = name, icon = icon, viewport = nil, scale = scale, tool = nil, heldId = nil }
			slots[index] = slot

			button.Activated:Connect(function()
				toggle(index, true)
			end)
			button.Parent = bar
		end
	end

	applySize()
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
	-- [hold-items] Same push carries `inventory`, which is where the held
	-- set lives (Storage entries flagged Held) - no separate remote needed.
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
