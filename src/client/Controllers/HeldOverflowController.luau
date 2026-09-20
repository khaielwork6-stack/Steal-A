--!strict
--[[
	HeldOverflowController  [hold-items]
	Everything about held items that does not fit on the hotbar's ten slots,
	plus the "Store it" button.

	OVERFLOW INVENTORY. Held items are ranked oldest-pickup-first (HeldLayout,
	the same order the server keeps). The hotbar has room for the first
	`capacity` ranks (10 minus the tools and gadgets); every later rank lives
	here, in a compact Roblox-backpack-style grid: the item's icon tile, its
	name under it, a rarity-coloured border. The backtick key opens and closes
	it (a small button beside the hotbar does the same on touch); Escape, or
	picking an item, closes it. Tapping a tile asks the server to equip that
	rank (HoldRequest "equip"): the server swaps it into the last hotbar
	position and pushes the least recently used hotbar item out here, so the
	equipped item is always on the hotbar. It holds up to 90 items and scrolls.

	"STORE IT". A small button on the right that only exists while a held item
	is the equipped one. It sends HoldRequest("store") - no item id; the server
	stores whatever it knows is equipped. It lives in its own ScreenGui, which
	UIStateController treats as HUD (HUD_SCREENS), so it hides by itself while
	carrying stolen loot and while any full-screen panel or reveal holds a
	claim; the open overflow panel closes when that happens too.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local HoldConfig = require(ReplicatedStorage.Shared.Config.HoldConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local HotbarController = require(script.Parent.HotbarController)

local HeldOverflowController = {}

local player = Players.LocalPlayer

local PANEL_FILL = Color3.fromRGB(24, 27, 38)
local PANEL_EDGE = Color3.fromRGB(96, 108, 140)
local TILE_FILL = Color3.fromRGB(34, 39, 54)
local TEXT = Color3.fromRGB(240, 244, 252)
local MUTED = Color3.fromRGB(170, 178, 198)
local ACCENT = Color3.fromRGB(120, 255, 160)
local TILE_W, TILE_H = 88, 112
local TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
--- How far off to the right the Store button waits while hidden.
local STORE_HIDE_OFFSET = 150
--- A press sent while the last one is this fresh is dropped locally (the
--- server rate-limits too).
local STORE_DEBOUNCE = 0.3

local gui: ScreenGui? = nil
local storeButton: TextButton? = nil
local bagButton: TextButton? = nil
local panel: Frame? = nil
local panelScale: UIScale? = nil
local scroller: ScrollingFrame? = nil
local emptyLabel: TextLabel? = nil
local countLabel: TextLabel? = nil

local panelOpen = false
local storeShown = false
local storeToken = 0
local lastStore = 0
--- InstanceId -> the tile drawn for it, and whether its viewport was made.
local tiles: { [string]: { frame: TextButton, icon: ImageLabel, painted: boolean } } = {}

-- ==========================================================
-- STATE
-- ==========================================================

--- The held items past the hotbar, oldest first, each with its true rank.
local function overflowList(): { { item: any, rank: number } }
	local held, capacity = HotbarController.getHeld()
	local out = {}
	for rank = capacity + 1, #held do
		table.insert(out, { item = held[rank], rank = rank })
	end
	return out
end

local function hasActiveHeld(): boolean
	local held = HotbarController.getHeld()
	for _, item in held do
		if item.HeldActive then
			return true
		end
	end
	return false
end

-- ==========================================================
-- STORE IT
-- ==========================================================

--- Where the button rests: mid-right. On a phone it sits LEFT of the offer
--- rail's column and above the event pills (both are centre-right there);
--- on desktop the right edge is free at mid-height.
local function storeRest(): UDim2
	if Device.isTouch() then
		return UDim2.new(1, -84, 0.5, -44)
	end
	return UDim2.new(1, -12, 0.5, 0)
end

local function applyStoreLayout()
	local button = storeButton
	if not button then
		return
	end
	local touch = Device.isTouch()
	-- 96 x 40 on desktop; a phone keeps a >= 44 px touch height (this gui is
	-- not under MainUI's UIScale, so pixels are pixels).
	button.Size = UDim2.fromOffset(96, if touch then 44 else 40)
	button.AnchorPoint = if touch then Vector2.new(1, 1) else Vector2.new(1, 0.5)
	if storeShown then
		button.Position = storeRest()
	else
		button.Position = storeRest() + UDim2.fromOffset(STORE_HIDE_OFFSET, 0)
	end
end

local function setStoreShown(show: boolean)
	local button = storeButton
	if not button or show == storeShown then
		return
	end
	storeShown = show
	storeToken += 1
	local token = storeToken
	local rest = storeRest()
	local away = rest + UDim2.fromOffset(STORE_HIDE_OFFSET, 0)
	if Effects.isReduced() then
		button.Position = if show then rest else away
		button.Visible = show
		return
	end
	if show then
		if not button.Visible then
			button.Position = away
			button.Visible = true
		end
		TweenService:Create(button, TWEEN, { Position = rest }):Play()
	else
		local tween = TweenService:Create(button, TWEEN, { Position = away })
		tween:Play()
		tween.Completed:Once(function()
			-- A show that arrived meanwhile owns the button again.
			if token == storeToken then
				button.Visible = false
			end
		end)
	end
end

-- ==========================================================
-- THE PANEL
-- ==========================================================

--- Makes the viewports only for tiles near the scroll window. Ninety live
--- ViewportFrames at once is ninety render passes (ItemThumb's own note), so a
--- tile is plate-only until it scrolls into view.
local function paintVisibleTiles()
	local list = scroller
	if not list or not panelOpen then
		return
	end
	local top = list.AbsolutePosition.Y - TILE_H
	local bottom = list.AbsolutePosition.Y + list.AbsoluteSize.Y + TILE_H
	for _, tile in tiles do
		if not tile.painted then
			local y = tile.frame.AbsolutePosition.Y
			if y >= top and y <= bottom then
				tile.painted = true
				local rarity = tile.frame:GetAttribute("Rarity")
				local itemId = tile.frame:GetAttribute("ItemId")
				ItemThumb.apply(
					tile.icon,
					if type(rarity) == "string" then rarity else nil,
					if type(itemId) == "string" then itemId else nil
				)
			end
		end
	end
end

local function closePanel()
	local frame = panel
	if not frame or not panelOpen then
		return
	end
	panelOpen = false
	if Effects.isReduced() or not panelScale then
		frame.Visible = false
		return
	end
	local tween = TweenService:Create(panelScale, TWEEN, { Scale = 0.92 })
	tween:Play()
	tween.Completed:Once(function()
		if not panelOpen then
			frame.Visible = false
		end
	end)
end

local function pick(instanceId: string)
	local held = HotbarController.getHeld()
	for rank, item in held do
		if item.InstanceId == instanceId then
			closePanel()
			HotbarController.equipHeld(rank)
			return
		end
	end
end

local function makeTile(item: any): { frame: TextButton, icon: ImageLabel, painted: boolean }
	local tile = Instance.new("TextButton")
	tile.Name = tostring(item.InstanceId)
	tile.Text = ""
	tile.AutoButtonColor = true
	tile.BackgroundColor3 = TILE_FILL
	tile.BorderSizePixel = 0
	tile.Size = UDim2.fromOffset(TILE_W, TILE_H)
	tile:SetAttribute("Rarity", item.Rarity)
	tile:SetAttribute("ItemId", item.ItemId)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = tile
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = RarityConfig.Colors[item.Rarity] or PANEL_EDGE
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = tile

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.new(1, -12, 0, TILE_W - 12)
	icon.Position = UDim2.fromOffset(6, 6)
	icon.Parent = tile
	-- The plate straight away (cheap); the model when it scrolls in.
	ItemThumb.applyPlate(icon, item.Rarity, true)

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(4, TILE_W - 4)
	name.Size = UDim2.new(1, -8, 0, TILE_H - TILE_W)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 12
	name.TextColor3 = TEXT
	name.TextWrapped = true
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.TextYAlignment = Enum.TextYAlignment.Top
	local def = LootConfig.ById[item.ItemId]
	name.Text = if def then def.name else tostring(item.ItemId)
	name.Parent = tile

	local id = tostring(item.InstanceId)
	tile.Activated:Connect(function()
		pick(id)
	end)
	return { frame = tile, icon = icon, painted = false }
end

--- Brings the tiles in step with the overflow list by InstanceId: only
--- missing ones are made, only gone ones destroyed, the rest are just given
--- their (possibly new) order - nothing that stays is rebuilt or re-tweened.
local function syncTiles()
	local list = scroller
	if not list then
		return
	end
	local wanted = overflowList()
	local keep: { [string]: boolean } = {}
	for order, entry in wanted do
		local id = tostring(entry.item.InstanceId)
		keep[id] = true
		local tile = tiles[id] or makeTile(entry.item)
		if not tiles[id] then
			tiles[id] = tile
			tile.frame.Parent = list
		end
		if tile.frame.LayoutOrder ~= order then
			tile.frame.LayoutOrder = order
		end
	end
	for id, tile in tiles do
		if not keep[id] then
			tile.frame:Destroy()
			tiles[id] = nil
		end
	end
	if emptyLabel then
		emptyLabel.Visible = #wanted == 0
	end
	if countLabel then
		local text = `{#wanted} more`
		if countLabel.Text ~= text then
			countLabel.Text = text
		end
	end
	task.defer(paintVisibleTiles)
end

local function openPanel()
	local frame = panel
	if not frame or panelOpen then
		return
	end
	local root = gui
	if not root or not root.Enabled then
		return -- hidden HUD (a carry, a full-screen panel): nothing to open
	end
	panelOpen = true
	syncTiles()
	frame.Visible = true
	if panelScale then
		if Effects.isReduced() then
			panelScale.Scale = 1
		else
			panelScale.Scale = 0.92
			TweenService:Create(panelScale, TWEEN, { Scale = 1 }):Play()
		end
	end
	task.delay(0.05, paintVisibleTiles)
end

local function togglePanel()
	if panelOpen then
		closePanel()
	else
		openPanel()
	end
end

-- ==========================================================
-- REFRESH
-- ==========================================================

--- The little "bag" button beside the hotbar, for touch: only while there is
--- something in the overflow, sitting just above the hotbar's right end.
local function placeBag()
	local button, bar = bagButton, HotbarController.getBar()
	if not button or not bar then
		return
	end
	local x = bar.AbsolutePosition.X + bar.AbsoluteSize.X
	local y = bar.AbsolutePosition.Y - 6
	button.Position = UDim2.fromOffset(x, y)
end

local function refresh()
	setStoreShown(hasActiveHeld())
	local extra = #overflowList()
	if bagButton then
		local show = Device.isTouch() and extra > 0
		if bagButton.Visible ~= show then
			bagButton.Visible = show
		end
		local text = if extra > 0 then `Bag +{extra}` else "Bag"
		if bagButton.Text ~= text then
			bagButton.Text = text
		end
		placeBag()
	end
	if panelOpen then
		syncTiles()
	end
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function styledButton(name: string, text: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = text
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.TextColor3 = TEXT
	button.AutoButtonColor = true
	button.BackgroundColor3 = PANEL_FILL
	button.BackgroundTransparency = 0.08
	button.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = ACCENT
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button
	return button
end

local function build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "HeldExtrasUI"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 6
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Store it.
	local store = styledButton("StoreIt", "Store it")
	store.Visible = false
	store.Parent = screen
	storeButton = store
	store.Activated:Connect(function()
		local now = os.clock()
		if now - lastStore < STORE_DEBOUNCE then
			return
		end
		lastStore = now
		-- No item id: the server stores whatever it knows is equipped.
		Remotes.get("HoldRequest"):FireServer("store")
	end)

	-- The touch button that opens the overflow.
	local bag = styledButton("OverflowBag", "Bag")
	bag.AnchorPoint = Vector2.new(1, 1)
	bag.Size = UDim2.fromOffset(88, 44)
	bag.TextSize = 15
	bag.Visible = false
	bag.Parent = screen
	bagButton = bag
	bag.Activated:Connect(togglePanel)

	-- The panel.
	local frame = Instance.new("Frame")
	frame.Name = "OverflowPanel"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.45)
	frame.Size = UDim2.fromScale(0.86, 0.66)
	frame.BackgroundColor3 = PANEL_FILL
	frame.BackgroundTransparency = 0.04
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screen
	panel = frame
	local size = Instance.new("UISizeConstraint")
	size.MinSize = Vector2.new(300, 240)
	size.MaxSize = Vector2.new(620, 460)
	size.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = frame
	local edge = Instance.new("UIStroke")
	edge.Thickness = 2
	edge.Color = PANEL_EDGE
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	panelScale = scale

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 8)
	title.Size = UDim2.new(0.5, 0, 0, 36)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = TEXT
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Inventory"
	title.Parent = frame

	local count = Instance.new("TextLabel")
	count.BackgroundTransparency = 1
	count.Position = UDim2.new(0.5, 0, 0, 8)
	count.Size = UDim2.new(0.5, -64, 0, 36)
	count.Font = Enum.Font.Gotham
	count.TextSize = 14
	count.TextColor3 = MUTED
	count.TextXAlignment = Enum.TextXAlignment.Right
	count.Text = ""
	count.Parent = frame
	countLabel = count

	local close = styledButton("Close", "X")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -10, 0, 6)
	close.Size = UDim2.fromOffset(44, 40)
	close.Activated:Connect(closePanel)
	close.Parent = frame

	local list = Instance.new("ScrollingFrame")
	list.Name = "Grid"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(12, 52)
	list.Size = UDim2.new(1, -24, 1, -64)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 6
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = frame
	scroller = list
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(TILE_W, TILE_H)
	grid.CellPadding = UDim2.fromOffset(10, 10)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = list
	list:GetPropertyChangedSignal("CanvasPosition"):Connect(paintVisibleTiles)

	local empty = Instance.new("TextLabel")
	empty.BackgroundTransparency = 1
	empty.Position = UDim2.fromScale(0.05, 0.3)
	empty.Size = UDim2.fromScale(0.9, 0.4)
	empty.Font = Enum.Font.Gotham
	empty.TextSize = 16
	empty.TextWrapped = true
	empty.TextColor3 = MUTED
	empty.Text = `Nothing extra yet. Items you pick up past {HoldConfig.HOTBAR_SLOTS} slots show up here.`
	-- On the panel, not in the grid (a grid would lay it out as a tile).
	empty.Parent = frame
	emptyLabel = empty

	-- The whole gui goes dark under a UIStateController claim (carry, a
	-- full-screen panel, a reveal): an open overflow closes with it.
	screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if not screen.Enabled then
			panelOpen = false
			frame.Visible = false
		end
	end)

	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen
	applyStoreLayout()
end

-- ==========================================================
-- START
-- ==========================================================

function HeldOverflowController.start()
	build()

	HotbarController.onHeldChanged(refresh)
	Device.onTouchChanged(function()
		applyStoreLayout()
		refresh()
	end)
	local bar = HotbarController.getBar()
	if bar then
		bar:GetPropertyChangedSignal("AbsolutePosition"):Connect(placeBag)
		bar:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeBag)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Escape then
			-- The engine's menu takes Escape too; closing ours is harmless.
			closePanel()
			return
		end
		if processed then
			return
		end
		if input.KeyCode == HoldConfig.OVERFLOW_KEY then
			togglePanel()
		end
	end)

	refresh()
end

return HeldOverflowController
