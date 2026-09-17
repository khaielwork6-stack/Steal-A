--!strict
--[[
	TradeController
	Everything the player sees of trading (trading-gifting-boards pass). It
	renders what TradeService sends and sends intents; it decides nothing.

	FOUR PIECES
	  1. THE TRADE PANEL (MainUI.Frames.Trade) and its HUD opener
	     (Buttons.Left.Trade). The pack pairs the two by name, so opening,
	     closing, blur and one-panel-at-a-time are the pack's. It lists the
	     other players in the server with a TRADE button each, and says why
	     trading is unavailable when it is (StatePush `trade`).
	  2. THE WORLD PROMPT. A LOCAL ProximityPrompt "Trade" on every other
	     player's character, enabled only while both of you stand on the lobby
	     apron (between the plots and the red line) and you are not carrying,
	     so it never competes with steal, rob or display-slot prompts.
	     InteractController renders it like every other prompt.
	  3. THE REQUEST POPUP. Top-centre, one at a time (a queue behind it),
	     ACCEPT / DECLINE / BLOCK and a countdown to the server's expiry.
	  4. THE TRADE WINDOW. Its own ScreenGui (TradeUI) so it can open from a
	     server event: two columns (YOU GIVE / THEY GIVE) of up to six item
	     cards each, showing rarity, size, mutation and income on both sides;
	     a Cash box; your storage strip below (tap an item to offer it, tap an
	     offered card to take it back); READY, CONFIRM (after the countdown)
	     and CANCEL; and the server's lopsided-trade warning.

	PANEL LOOK. Both panels are a CLONE of the pack's Frames.Index skeleton,
	stripped to its header bar and styling (never the template itself), so
	they share the pack's plate, gradient, stroke, fonts and close button.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local TradeConfig = require(ReplicatedStorage.Shared.Config.TradeConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = require(script.Parent.UIStateController)

local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)

local TradeController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- LOOK
-- ==========================================================

local FONT = Enum.Font.FredokaOne
local WHITE = Color3.fromRGB(255, 255, 255)
local INK = Color3.fromRGB(16, 20, 34)
local PLATE = Color3.fromRGB(28, 32, 44)
local SLOT_EMPTY = Color3.fromRGB(44, 50, 66)
local GREEN = Color3.fromRGB(56, 196, 96)
local RED = Color3.fromRGB(214, 62, 72)
local BLUE = Color3.fromRGB(70, 140, 240)
local GREY = Color3.fromRGB(96, 102, 118)
local GOLD = Color3.fromRGB(255, 206, 84)
local WARN = Color3.fromRGB(255, 196, 70)
local PURPLE = Color3.fromRGB(156, 64, 226)

--- Touch targets: at least this tall on screen (MainUI's phone UIScale is
--- applied to the Frames panel, so its rows are sized with that in mind).
local MIN_TOUCH = 44

local function round(target: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 10)
	corner.Parent = target
end

local function outline(target: GuiObject, thickness: number?, color: Color3?)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness or 2
	stroke.Color = color or Color3.new(0, 0, 0)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = target
end

local function text(parent: Instance, name: string, value: string, size: UDim2, position: UDim2, maxSize: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Font = FONT
	label.Text = value
	label.TextColor3 = WHITE
	label.TextScaled = true
	label.TextStrokeTransparency = 0.4
	label.ZIndex = 12
	label.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxSize or 28
	limit.MinTextSize = 8
	limit.Parent = label
	return label
end

local function button(parent: Instance, name: string, caption: string, color: Color3, size: UDim2, position: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AutoButtonColor = false
	b.BackgroundColor3 = color
	b.Size = size
	b.Position = position
	b.Font = FONT
	b.Text = caption
	b.TextColor3 = WHITE
	b.TextScaled = true
	b.TextStrokeTransparency = 0.2
	b.ZIndex = 13
	b.Parent = parent
	round(b)
	outline(b, 2)
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 26
	limit.MinTextSize = 10
	limit.Parent = b
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.15, 0)
	pad.PaddingBottom = UDim.new(0.15, 0)
	pad.PaddingLeft = UDim.new(0.05, 0)
	pad.PaddingRight = UDim.new(0.05, 0)
	pad.Parent = b
	-- A pack-style button of our own: hover, press, ripple.
	UIAnim.claimButton(b)
	return b
end

local function setEnabled(b: TextButton, enabled: boolean, color: Color3)
	b.Active = enabled
	b.AutoButtonColor = false
	b.BackgroundColor3 = if enabled then color else GREY
	b.TextTransparency = if enabled then 0 else 0.35
end

-- ==========================================================
-- SKELETON (a stripped clone of the pack's Index panel)
-- ==========================================================

local skeleton: Frame? = nil

local KEEP_CLASSES = {
	UICorner = true,
	UIStroke = true,
	UIGradient = true,
	UIPadding = true,
}

--- Lifts the Index frame's shell once: its plate styling and its Top bar.
--- Everything else (the Index's own content, whatever IndexController has
--- already added) is removed from the copy.
local function takeSkeleton(ui: Instance)
	local frames = ui:FindFirstChild("Frames")
	local source = frames and frames:FindFirstChild("Index")
	if not source or not source:IsA("Frame") then
		return
	end
	local copy = source:Clone()
	for _, child in copy:GetChildren() do
		if child.Name ~= "Top" and not KEEP_CLASSES[child.ClassName] then
			child:Destroy()
		end
	end
	copy.Visible = false
	skeleton = copy
end

--- A fresh panel shell titled `title`, with its Close button (if any).
local function newPanel(name: string, title: string): (Frame, GuiButton?)
	local panel: Frame
	if skeleton then
		panel = skeleton:Clone()
	else
		-- No pack skeleton: a plain panel in the same palette.
		panel = Instance.new("Frame")
		panel.BackgroundColor3 = Color3.fromRGB(24, 30, 56)
		round(panel, 16)
		outline(panel, 3)
	end
	panel.Name = name
	panel.Visible = false
	local close: GuiButton? = nil
	local top = panel:FindFirstChild("Top")
	local bar = top and top:FindFirstChild("Frame")
	if bar then
		local label = bar:FindFirstChild("Title")
		if label and label:IsA("TextLabel") then
			label.Text = title
		end
		local found = bar:FindFirstChild("Close")
		if found and found:IsA("GuiButton") then
			close = found
		end
		local icon = bar:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") and TradeConfig.hasIcon(TradeConfig.Icons.TradeHeader) then
			icon.Image = TradeConfig.Icons.TradeHeader
		end
	else
		text(panel, "Title", title, UDim2.fromScale(0.8, 0.08), UDim2.fromScale(0.1, 0.02), 34)
	end
	return panel, close
end

-- ==========================================================
-- STATE
-- ==========================================================

local latestState: any = nil
local session: any = nil

local panelFrame: Frame? = nil
local panelStatus: TextLabel? = nil
local panelList: ScrollingFrame? = nil

local windowGui: ScreenGui? = nil
local window: Frame? = nil
local myColumn: Frame? = nil
local theirColumn: Frame? = nil
local myCashBox: TextBox? = nil
local theirCashLabel: TextLabel? = nil
local warningLabel: TextLabel? = nil
local picker: ScrollingFrame? = nil
local readyButton: TextButton? = nil
local confirmButton: TextButton? = nil
local cancelButton: TextButton? = nil
local countdownLabel: TextLabel? = nil
local phaseLabel: TextLabel? = nil

local popup: Frame? = nil
local popupTitle: TextLabel? = nil
type Incoming = { fromUserId: number, fromName: string, expiresAt: number }
local incoming: { Incoming } = {}

local function fire(action: string, a: any?, b: any?)
	Remotes.get("TradeRequest"):FireServer(action, a, b)
end

local function tradeInfo(): any
	return if latestState and type(latestState.trade) == "table" then latestState.trade else nil
end

-- ==========================================================
-- ITEM CARDS
-- ==========================================================

local function tagsOf(rarity: string, size: string, mutation: string): string
	local parts = { string.upper(rarity) }
	if size ~= "" and size ~= "Normal" then
		table.insert(parts, string.upper(size))
	end
	if mutation ~= "" and mutation ~= "Normal" then
		table.insert(parts, string.upper(mutation))
	end
	return table.concat(parts, " · ")
end

--- One item card. `onPress` makes the whole card a button.
local function itemCard(view: any, order: number, onPress: (() -> ())?, dim: boolean?): GuiObject
	local rarity = tostring(view.rarity or "Common")
	local color = RarityConfig.Colors[rarity] or Color3.fromRGB(198, 205, 216)
	local card: GuiObject
	if onPress then
		local b = Instance.new("TextButton")
		b.Text = ""
		b.AutoButtonColor = false
		card = b
	else
		card = Instance.new("Frame")
	end
	card.Name = `Item_{view.id}`
	card.LayoutOrder = order
	card.BackgroundColor3 = PLATE
	card.ZIndex = 11
	round(card, 8)
	outline(card, 2, color)

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(0.62, 0.5)
	icon.Position = UDim2.fromScale(0.19, 0.03)
	icon.ZIndex = 12
	icon.Parent = card
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = icon
	ItemThumb.apply(icon, rarity, view.itemId)

	local name = text(card, "Name", tostring(view.name), UDim2.fromScale(0.94, 0.15), UDim2.fromScale(0.03, 0.54), 16)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local tags = text(card, "Tags", tagsOf(rarity, tostring(view.size or ""), tostring(view.mutation or "")), UDim2.fromScale(0.94, 0.13), UDim2.fromScale(0.03, 0.7), 13)
	tags.TextColor3 = color
	local income = text(card, "Income", NumberFormat.income(tonumber(view.income) or 0), UDim2.fromScale(0.94, 0.14), UDim2.fromScale(0.03, 0.84), 14)
	income.TextColor3 = Color3.fromRGB(126, 255, 148)

	if dim then
		card.BackgroundTransparency = 0.5
		for _, child in card:GetDescendants() do
			if child:IsA("TextLabel") then
				child.TextTransparency = 0.5
			end
		end
	end
	if onPress and card:IsA("TextButton") then
		UIAnim.claimButton(card)
		card.Activated:Connect(onPress)
	end
	return card
end

--- A client-side view of a stored item (same shape the server sends).
local function viewOfStored(item: any): any
	local def = LootConfig.ById[item.ItemId]
	return {
		id = item.InstanceId,
		itemId = item.ItemId,
		name = if def then def.name else item.ItemId,
		rarity = item.Rarity,
		size = item.Size,
		mutation = item.Mutation,
		income = item.FinalIncome,
	}
end

local function clearCards(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- ==========================================================
-- THE TRADE WINDOW
-- ==========================================================

local function column(parent: Frame, name: string, heading: string, x: number): Frame
	local col = Instance.new("Frame")
	col.Name = name
	col.BackgroundColor3 = INK
	col.BackgroundTransparency = 0.25
	col.Position = UDim2.fromScale(x, 0.13)
	col.Size = UDim2.fromScale(0.47, 0.5)
	col.ZIndex = 10
	col.Parent = parent
	round(col, 12)
	outline(col, 2)

	-- The pack's section header when it can be had, else a label.
	local header = ShopKit.header()
	if header then
		header.Name = "Heading"
		header.Size = UDim2.fromScale(0.96, 0.13)
		header.Position = UDim2.fromScale(0.02, 0.01)
		header.ZIndex = 11
		local label = header:FindFirstChild("Title")
		if label and label:IsA("TextLabel") then
			label.Text = heading
		end
		header.Parent = col
	else
		text(col, "Heading", heading, UDim2.fromScale(0.96, 0.12), UDim2.fromScale(0.02, 0.01), 24)
	end

	local status = text(col, "Status", "", UDim2.fromScale(0.34, 0.1), UDim2.fromScale(0.64, 0.15), 18)
	status.TextXAlignment = Enum.TextXAlignment.Right

	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromScale(0.03, 0.27)
	grid.Size = UDim2.fromScale(0.94, 0.71)
	grid.ZIndex = 10
	grid.Parent = col
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromScale(0.31, 0.47)
	layout.CellPadding = UDim2.fromScale(0.025, 0.04)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = grid
	return col
end

--- Reads "1.5M", "250k", "12,000" into a whole number, or nil.
local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15 }
local function parseCash(raw: string): number?
	local cleaned = string.lower(raw):gsub("[%s,%$]", "")
	local digits, suffix = cleaned:match("^([%d%.]+)(%a*)$")
	local value = tonumber(digits)
	if not value then
		return nil
	end
	if suffix ~= "" then
		local multiplier = SUFFIX[suffix]
		if not multiplier then
			return nil
		end
		value *= multiplier
	end
	return math.clamp(math.floor(value), 0, TradeConfig.MAX_CASH)
end

local function closeWindow()
	if window then
		window.Visible = false
	end
	UIStateController.release("trade")
end

local function openWindow()
	local frame = window
	if not frame then
		return
	end
	if not frame.Visible then
		-- One modal at a time: whatever pack panel was open gives way.
		local closeAll = (_G :: any).CloseAllUIFrames
		if type(closeAll) == "function" then
			pcall(closeAll)
		end
		frame.Visible = true
		UIAnim.popIn(frame, 0.9)
		UIStateController.claim("trade")
	end
end

local function buildWindow()
	local gui = Instance.new("ScreenGui")
	gui.Name = "TradeUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	windowGui = gui

	local frame, close = newPanel("TradeWindow", "Trade")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.52)
	frame.Size = if Device.isTouch() then UDim2.fromScale(0.96, 0.9) else UDim2.fromScale(0.62, 0.8)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(960, 660)
	limit.Parent = frame
	frame.Parent = gui
	window = frame

	if close then
		UIAnim.claimButton(close)
		close.Activated:Connect(function()
			fire("cancel")
		end)
	end

	myColumn = column(frame, "Mine", "YOU GIVE", 0.02)
	theirColumn = column(frame, "Theirs", "THEY GIVE", 0.51)

	-- Your Cash offer: a box you type into.
	local mine = myColumn :: Frame
	local box = Instance.new("TextBox")
	box.Name = "CashBox"
	box.BackgroundColor3 = PLATE
	box.Position = UDim2.fromScale(0.03, 0.15)
	box.Size = UDim2.fromScale(0.58, 0.1)
	box.Font = FONT
	box.PlaceholderText = "$ Cash (e.g. 1.5M)"
	box.Text = ""
	box.TextColor3 = Color3.fromRGB(150, 255, 170)
	box.TextScaled = true
	box.ClearTextOnFocus = false
	box.ZIndex = 12
	box.Parent = mine
	round(box, 6)
	outline(box, 1.5)
	local boxLimit = Instance.new("UITextSizeConstraint")
	boxLimit.MaxTextSize = 20
	boxLimit.Parent = box
	box.FocusLost:Connect(function()
		local amount = if box.Text == "" then 0 else parseCash(box.Text)
		if amount == nil then
			box.Text = ""
			return
		end
		fire("cash", amount)
	end)
	myCashBox = box

	local theirs = theirColumn :: Frame
	local cashLabel = text(theirs, "Cash", "$0", UDim2.fromScale(0.58, 0.1), UDim2.fromScale(0.03, 0.15), 20)
	cashLabel.TextXAlignment = Enum.TextXAlignment.Left
	cashLabel.TextColor3 = Color3.fromRGB(150, 255, 170)
	theirCashLabel = cashLabel

	local warning = text(frame, "Warning", "", UDim2.fromScale(0.94, 0.05), UDim2.fromScale(0.03, 0.64), 20)
	warning.TextColor3 = WARN
	warningLabel = warning

	text(frame, "PickerTitle", "YOUR STORAGE - tap an item to offer it", UDim2.fromScale(0.94, 0.04), UDim2.fromScale(0.03, 0.69), 18)
	local strip = Instance.new("ScrollingFrame")
	strip.Name = "Picker"
	strip.BackgroundColor3 = INK
	strip.BackgroundTransparency = 0.35
	strip.Position = UDim2.fromScale(0.02, 0.735)
	strip.Size = UDim2.fromScale(0.96, 0.15)
	strip.ScrollingDirection = Enum.ScrollingDirection.X
	strip.AutomaticCanvasSize = Enum.AutomaticSize.X
	strip.CanvasSize = UDim2.new()
	strip.ScrollBarThickness = 5
	strip.ZIndex = 10
	strip.Parent = frame
	round(strip, 10)
	local stripLayout = Instance.new("UIListLayout")
	stripLayout.FillDirection = Enum.FillDirection.Horizontal
	stripLayout.Padding = UDim.new(0, 6)
	stripLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stripLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	stripLayout.Parent = strip
	local stripPad = Instance.new("UIPadding")
	stripPad.PaddingLeft = UDim.new(0, 6)
	stripPad.PaddingRight = UDim.new(0, 6)
	stripPad.Parent = strip
	picker = strip

	-- The action row. Each button is at least MIN_TOUCH tall.
	local row = Instance.new("Frame")
	row.Name = "Actions"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromScale(0.02, 0.895)
	row.Size = UDim2.fromScale(0.96, 0.095)
	row.ZIndex = 10
	row.Parent = frame
	local rowLimit = Instance.new("UISizeConstraint")
	rowLimit.MinSize = Vector2.new(0, MIN_TOUCH)
	rowLimit.Parent = row
	readyButton = button(row, "Ready", "READY", BLUE, UDim2.fromScale(0.3, 1), UDim2.fromScale(0, 0))
	confirmButton = button(row, "Confirm", "CONFIRM", GREEN, UDim2.fromScale(0.36, 1), UDim2.fromScale(0.32, 0))
	cancelButton = button(row, "CancelTrade", "CANCEL", RED, UDim2.fromScale(0.3, 1), UDim2.fromScale(0.7, 0))
	local readyB, confirmB, cancelB = readyButton :: TextButton, confirmButton :: TextButton, cancelButton :: TextButton
	readyB.Activated:Connect(function()
		if session and readyB.Active then
			fire("ready", not session.you.ready)
		end
	end)
	confirmB.Activated:Connect(function()
		if session and confirmB.Active then
			fire("confirm")
		end
	end)
	cancelB.Activated:Connect(function()
		fire("cancel")
	end)

	local count = text(frame, "Countdown", "", UDim2.fromScale(0.3, 0.05), UDim2.fromScale(0.35, 0.84), 26)
	count.TextColor3 = GOLD
	countdownLabel = count
	local phase = text(frame, "Phase", "", UDim2.fromScale(0.6, 0.04), UDim2.fromScale(0.2, 0.085), 18)
	phase.TextColor3 = Color3.fromRGB(206, 216, 232)
	phaseLabel = phase

	-- The countdown ticks locally from the server's end time.
	RunService.Heartbeat:Connect(function()
		if not frame.Visible or not session then
			return
		end
		local label = countdownLabel :: TextLabel
		local ends = tonumber(session.countdownEndsAt)
		if session.phase == "countdown" and ends then
			local left = ends - workspace:GetServerTimeNow()
			if left > 0 then
				label.Text = `CONFIRM IN {math.ceil(left)}`
			else
				label.Text = "WAITING..."
			end
		else
			label.Text = ""
		end
	end)

	gui.Enabled = true
end

local function paintSide(col: Frame, side: any, mine: boolean)
	local grid = col:FindFirstChild("Grid") :: Frame
	clearCards(grid)
	local items = if type(side.items) == "table" then side.items else {}
	for index = 1, (session and session.maxItems) or TradeConfig.MAX_ITEMS do
		local view = items[index]
		if view then
			local press: (() -> ())? = nil
			if mine then
				local id = view.id
				press = function()
					fire("remove", id)
				end
			end
			itemCard(view, index, press).Parent = grid
		else
			local slot = Instance.new("Frame")
			slot.Name = `Empty{index}`
			slot.LayoutOrder = index
			slot.BackgroundColor3 = SLOT_EMPTY
			slot.BackgroundTransparency = 0.3
			slot.ZIndex = 11
			round(slot, 8)
			slot.Parent = grid
		end
	end
	local status = col:FindFirstChild("Status")
	if status and status:IsA("TextLabel") then
		if side.confirmed then
			status.Text = "CONFIRMED ✓"
			status.TextColor3 = GREEN
		elseif side.ready then
			status.Text = "READY ✓"
			status.TextColor3 = Color3.fromRGB(120, 200, 255)
		else
			status.Text = "not ready"
			status.TextColor3 = GREY
		end
	end
end

local pickerSignature = ""

local function paintPicker()
	local strip = picker
	if not strip then
		return
	end
	local offered: { [string]: boolean } = {}
	local parts = {}
	if session and session.you and type(session.you.items) == "table" then
		for _, view in session.you.items do
			offered[view.id] = true
			table.insert(parts, view.id)
		end
	end
	local inventory = if latestState and type(latestState.inventory) == "table" then latestState.inventory else {}
	-- Income ticks push state every second; the strip's viewports are only
	-- rebuilt when the storage or the offer actually changed.
	table.insert(parts, "|")
	for _, item in inventory do
		if type(item) == "table" then
			table.insert(parts, `{item.InstanceId}:{item.Hatched}:{item.Mutation}:{item.FinalIncome}`)
		end
	end
	local signature = table.concat(parts, ",")
	if signature == pickerSignature then
		return
	end
	pickerSignature = signature
	clearCards(strip)
	local order = 0
	for _, item in inventory do
		if type(item) ~= "table" or offered[item.InstanceId] then
			continue
		end
		order += 1
		local sealed = item.Hatched == false
		local id = item.InstanceId
		local view = if sealed
			then { id = id, itemId = nil, name = "Sealed", rarity = "Common", size = "", mutation = "", income = 0 }
			else viewOfStored(item)
		local card = itemCard(view, order, if sealed then nil else function()
			fire("add", id)
		end, sealed)
		-- Square-ish cells sized off the strip's height.
		card.Size = UDim2.fromScale(0, 0.92)
		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 0.8
		aspect.DominantAxis = Enum.DominantAxis.Height
		aspect.Parent = card
		card.Parent = strip
	end
	if order == 0 then
		local empty = text(strip, "Empty", "Nothing in storage. Store a revealed item from your base to trade it.", UDim2.new(0, 480, 0.8, 0), UDim2.new(), 18)
		empty.TextColor3 = GREY
	end
end

local function paintWindow()
	if not session or not window then
		return
	end
	paintSide(myColumn :: Frame, session.you, true)
	paintSide(theirColumn :: Frame, session.them, false)
	local heading = (theirColumn :: Frame):FindFirstChild("Heading")
	local headingLabel = heading and (if heading:IsA("TextLabel") then heading else heading:FindFirstChild("Title"))
	if headingLabel and headingLabel:IsA("TextLabel") then
		headingLabel.Text = `{string.upper(tostring(session.them.name))} GIVES`
	end
	local box = myCashBox :: TextBox
	if not box:IsFocused() then
		local cash = tonumber(session.you.cash) or 0
		box.Text = if cash > 0 then NumberFormat.comma(cash) else ""
	end
	(theirCashLabel :: TextLabel).Text = `+ {NumberFormat.cash(tonumber(session.them.cash) or 0)}`
	(warningLabel :: TextLabel).Text = if type(session.warning) == "string" then "⚠ " .. session.warning else ""

	local phase = session.phase
	local readyB, confirmB = readyButton :: TextButton, confirmButton :: TextButton
	readyB.Text = if session.you.ready then "UNREADY" else "READY"
	setEnabled(readyB, not session.you.confirmed, if session.you.ready then WARN else BLUE)
	local canConfirm = phase == "confirm" and not session.you.confirmed
	setEnabled(confirmB, canConfirm, GREEN)
	confirmB.Text = if session.you.confirmed then "WAITING..." else "CONFIRM"
	local phaseText = {
		offer = "Add items, then both press READY. Any change un-readies both.",
		countdown = "Both ready - check the offer one last time!",
		confirm = "Press CONFIRM to trade.",
	}
	(phaseLabel :: TextLabel).Text = phaseText[phase] or ""
	paintPicker()
end

-- ==========================================================
-- THE TRADE PANEL (player list)
-- ==========================================================

--- The status line only; returns whether this player may trade now.
local function paintStatus(): boolean
	local status = panelStatus
	local info = tradeInfo()
	local allowed = info ~= nil and info.allowed == true
	if not status then
		return allowed
	end
	if not info then
		status.Text = "Loading..."
	elseif allowed then
		status.Text = if info.inTrade then "You're in a trade." else "Pick a player to trade with. Only stored, revealed items can be traded."
	else
		local reason = tostring(info.reason or "Trading is unavailable right now.")
		local readyAt = tonumber(info.readyAt)
		if readyAt then
			reason = `You can trade in {math.max(0, math.ceil(readyAt - workspace:GetServerTimeNow()))}s.`
		end
		status.Text = reason
	end
	status.TextColor3 = if allowed then WHITE else WARN
	return allowed
end

--- Rows are rebuilt only when who is here, or whether we may trade, changed.
local rowsSignature = ""

local function paintPanel()
	local list = panelList
	if not list then
		return
	end
	local allowed = paintStatus()
	local ids = {}
	for _, other in Players:GetPlayers() do
		table.insert(ids, `{other.UserId}`)
	end
	local signature = `{allowed}|{table.concat(ids, ",")}`
	if signature == rowsSignature then
		return
	end
	rowsSignature = signature

	clearCards(list)
	local order = 0
	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		order += 1
		local row = Instance.new("Frame")
		row.Name = `Player_{other.UserId}`
		row.LayoutOrder = order
		row.BackgroundColor3 = INK
		row.BackgroundTransparency = 0.25
		row.Size = UDim2.new(0.96, 0, 0, 56)
		row.ZIndex = 10
		row.Parent = list
		round(row, 10)
		local name = text(row, "Name", other.DisplayName, UDim2.fromScale(0.6, 0.6), UDim2.fromScale(0.04, 0.2), 24)
		name.TextXAlignment = Enum.TextXAlignment.Left
		local b = button(row, "TradeWith", "TRADE", if allowed then PURPLE else GREY, UDim2.fromScale(0.3, 0.8), UDim2.fromScale(0.67, 0.1))
		b.Active = allowed
		local userId = other.UserId
		b.Activated:Connect(function()
			if b.Active then
				fire("request", userId)
			end
		end)
	end
	if order == 0 then
		local empty = text(list, "Empty", "Nobody else is in this server yet.", UDim2.new(0.96, 0, 0, 40), UDim2.new(), 22)
		empty.TextColor3 = GREY
	end
end

local function buildPanel(ui: ScreenGui)
	local frames = ui:FindFirstChild("Frames")
	if not frames or frames:FindFirstChild("Trade") then
		return
	end
	local frame = newPanel("Trade", "Trade")
	-- Same place and size the Index panel has, so it opens where panels do.
	if skeleton then
		frame.Position = skeleton.Position
		frame.Size = skeleton.Size
		frame.AnchorPoint = skeleton.AnchorPoint
	else
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.Size = UDim2.fromScale(0.5, 0.7)
	end

	local status = text(frame, "Status", "", UDim2.fromScale(0.9, 0.1), UDim2.fromScale(0.05, 0.17), 24)
	status.TextWrapped = true
	panelStatus = status

	local list = Instance.new("ScrollingFrame")
	list.Name = "ScrollingFrame"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromScale(0.04, 0.29)
	list.Size = UDim2.fromScale(0.92, 0.66)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ScrollBarThickness = 5
	list.ZIndex = 10
	list.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = list
	panelList = list

	frame.Parent = frames
	PanelStyle.window(frame, 860, 560)
	panelFrame = frame
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			fire("sync")
			paintPanel()
		end
	end)
end

--- The HUD opener, cloned from the pack's Index button (the same recipe the
--- Upgrades and Storage openers use) and named "Trade" so the pack opens
--- Frames.Trade for it.
local function buildOpener(ui: ScreenGui)
	local buttons = ui:FindFirstChild("Buttons")
	local left = buttons and buttons:FindFirstChild("Left")
	local source = left and left:FindFirstChild("Index")
	if not left or not source or not source:IsA("TextButton") or left:FindFirstChild("Trade") then
		return
	end
	local opener = source:Clone()
	opener.Name = "Trade"
	opener.LayoutOrder = 5
	opener:SetAttribute("_UIHandlerSetup", nil)
	opener:SetAttribute("AnimBound", nil)
	local ripple = opener:FindFirstChild("_RippleContainer")
	if ripple then
		ripple:Destroy()
	end
	local scale = opener:FindFirstChildOfClass("UIScale")
	if scale then
		scale.Scale = 1
	end
	-- Badges IndexController hung on its button must not come along.
	for _, child in opener:GetChildren() do
		if child:IsA("TextLabel") and child.Name ~= "Title" then
			child:Destroy()
		end
	end
	local label = opener:FindFirstChild("Title")
	if label and label:IsA("TextLabel") then
		label.Text = "Trade"
	end
	local inner = opener:FindFirstChild("Frame")
	local icon = inner and inner:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		if TradeConfig.hasIcon(TradeConfig.Icons.Trade) then
			icon.Image = TradeConfig.Icons.Trade
		else
			-- No art yet: two arrows, in the pack's font, on the plate.
			icon.Image = ""
			local glyph = text(icon, "Glyph", "⇄", UDim2.fromScale(1, 1), UDim2.new(), 60)
			glyph.TextStrokeTransparency = 0
		end
	end
	opener.Parent = left
end

-- ==========================================================
-- THE REQUEST POPUP
-- ==========================================================

local function showNextRequest()
	local frame = popup
	if not frame then
		return
	end
	-- Lapsed ones first.
	local serverNow = workspace:GetServerTimeNow()
	for index = #incoming, 1, -1 do
		if incoming[index].expiresAt <= serverNow then
			table.remove(incoming, index)
		end
	end
	local current = incoming[1]
	if not current then
		frame.Visible = false
		return
	end
	(popupTitle :: TextLabel).Text = `{current.fromName} wants to trade!`
	if not frame.Visible then
		frame.Visible = true
		UIAnim.popIn(frame, 0.85)
	end
end

local function answer(response: string)
	local current = incoming[1]
	if not current then
		return
	end
	table.remove(incoming, 1)
	fire("respond", current.fromUserId, response)
	showNextRequest()
end

local function buildPopup()
	local gui = windowGui :: ScreenGui
	local frame = Instance.new("Frame")
	frame.Name = "TradeRequestPopup"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 70)
	frame.Size = if Device.isTouch() then UDim2.fromOffset(340, 132) else UDim2.fromOffset(400, 140)
	frame.BackgroundColor3 = Color3.fromRGB(24, 30, 56)
	frame.Visible = false
	frame.ZIndex = 30
	frame.Parent = gui
	round(frame, 14)
	outline(frame, 3)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(70, 60, 140), Color3.fromRGB(30, 26, 70))
	gradient.Parent = frame

	popupTitle = text(frame, "Title", "", UDim2.fromScale(0.92, 0.3), UDim2.fromScale(0.04, 0.06), 26)
	local timer = text(frame, "Timer", "", UDim2.fromScale(0.92, 0.16), UDim2.fromScale(0.04, 0.36), 18)
	timer.TextColor3 = Color3.fromRGB(206, 216, 232)

	local accept = button(frame, "Accept", "ACCEPT", GREEN, UDim2.fromScale(0.36, 0.34), UDim2.fromScale(0.03, 0.58))
	local decline = button(frame, "Decline", "DECLINE", RED, UDim2.fromScale(0.3, 0.34), UDim2.fromScale(0.41, 0.58))
	local block = button(frame, "Block", "BLOCK", GREY, UDim2.fromScale(0.24, 0.34), UDim2.fromScale(0.73, 0.58))
	for _, b in { accept, decline, block } do
		b.ZIndex = 31
	end
	accept.Activated:Connect(function()
		answer("accept")
	end)
	decline.Activated:Connect(function()
		answer("decline")
	end)
	block.Activated:Connect(function()
		answer("block")
	end)
	popup = frame

	RunService.Heartbeat:Connect(function()
		if not frame.Visible then
			return
		end
		local current = incoming[1]
		if not current then
			frame.Visible = false
			return
		end
		local left = current.expiresAt - workspace:GetServerTimeNow()
		if left <= 0 then
			showNextRequest()
			return
		end
		timer.Text = `Expires in {math.ceil(left)}s{if #incoming > 1 then `  (+{#incoming - 1} more)` else ""}`
	end)
end

-- ==========================================================
-- THE WORLD PROMPT
-- ==========================================================

local prompts: { [Player]: ProximityPrompt } = {}

local function onApron(position: Vector3): boolean
	return position.Z <= 0
		and position.Z >= MapConfig.PLAZA_FRONT_Z
		and math.abs(position.X) <= MapConfig.LOBBY_WIDTH / 2
end

local function attachPrompt(other: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root or not root:IsA("BasePart") then
		return
	end
	local old = prompts[other]
	if old then
		old:Destroy()
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TradePrompt"
	prompt.ActionText = "Trade"
	prompt.ObjectText = other.DisplayName
	prompt.KeyboardKeyCode = Enum.KeyCode.T
	prompt.HoldDuration = TradeConfig.PROMPT_HOLD_SECONDS
	prompt.MaxActivationDistance = TradeConfig.PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = root
	local userId = other.UserId
	prompt.Triggered:Connect(function(who)
		if who == player then
			fire("request", userId)
		end
	end)
	prompts[other] = prompt
end

local function watchPlayer(other: Player)
	if other == player then
		return
	end
	other.CharacterAdded:Connect(function(character)
		attachPrompt(other, character)
	end)
	if other.Character then
		task.spawn(attachPrompt, other, other.Character)
	end
end

--- Prompts on only where they cannot clash with anything else.
local function refreshPrompts()
	local found = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local myRoot = if found and found:IsA("BasePart") then found else nil
	local info = tradeInfo()
	local mayTrade = info ~= nil
		and info.allowed == true
		and not info.inTrade
		and not (latestState and latestState.carrying)
		and myRoot ~= nil
		and onApron(myRoot.Position)
	for other, prompt in prompts do
		local parent = prompt.Parent
		local root = if parent and parent:IsA("BasePart") then parent else nil
		prompt.Enabled = mayTrade == true and other.Parent ~= nil and root ~= nil and onApron(root.Position)
	end
end

-- ==========================================================
-- START
-- ==========================================================

local function onUpdate(kind: any, payload: any)
	if type(payload) ~= "table" then
		return
	end
	if kind == "request" then
		local fromUserId = tonumber(payload.fromUserId)
		local expiresAt = tonumber(payload.expiresAt)
		if not fromUserId or not expiresAt then
			return
		end
		for _, existing in incoming do
			if existing.fromUserId == fromUserId then
				existing.expiresAt = expiresAt
				return
			end
		end
		table.insert(incoming, { fromUserId = fromUserId, fromName = tostring(payload.fromName), expiresAt = expiresAt })
		showNextRequest()
	elseif kind == "requestGone" then
		for index = #incoming, 1, -1 do
			if incoming[index].fromUserId == payload.fromUserId then
				table.remove(incoming, index)
			end
		end
		showNextRequest()
	elseif kind == "session" then
		session = payload
		-- An open trade replaces any popup from the same player.
		openWindow()
		paintWindow()
	elseif kind == "closed" then
		session = nil
		closeWindow()
	end
end

function TradeController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		warn("[TradeController] MainUI not found - trading UI disabled.")
		return
	end
	takeSkeleton(ui)
	ShopKit.warm()

	buildWindow()
	buildPopup()
	buildPanel(ui)
	if TradeConfig.HUD_BUTTON then
		buildOpener(ui)
	end

	Remotes.get("TradeUpdate").OnClientEvent:Connect(onUpdate)

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		latestState = state
		if panelFrame and panelFrame.Visible then
			paintPanel()
		end
		if window and window.Visible then
			paintPicker()
		end
	end)

	for _, other in Players:GetPlayers() do
		watchPlayer(other)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(other)
		local prompt = prompts[other]
		if prompt then
			prompt:Destroy()
			prompts[other] = nil
		end
		if panelFrame and panelFrame.Visible then
			paintPanel()
		end
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			refreshPrompts()
			-- The join-grace countdown in the open panel.
			local info = tradeInfo()
			if panelFrame and panelFrame.Visible and info and info.readyAt then
				paintStatus()
			end
		end
	end)

	-- Anything already pending (a request sent before this client listened).
	fire("sync")
end

return TradeController
