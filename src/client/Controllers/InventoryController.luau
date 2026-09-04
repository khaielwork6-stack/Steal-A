--!strict
--[[
	InventoryController
	Storage panel for unequipped loot, plus the right-side button that opens it.

	Flow this supports (deliberately different from a straight sell button):
	    displayed trophy -> STORE -> inventory -> DISPLAY again, or SELL
	A mis-click can never destroy a rare item, because selling only happens here,
	from a card the player is looking at, with the payout shown.

	Built in code rather than in the pack, because the rows are data-driven: one
	card per stored item, each carrying its own name, income, rarity and variant.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local InventoryController = {}

local player = Players.LocalPlayer

local panel: Frame
local listFrame: ScrollingFrame
local headerLabel: TextLabel
local upgradeButton: TextButton
local openButton: TextButton
local isOpen = false
local latestState: any = nil

local DARK = Color3.fromRGB(38, 42, 54)
local DARKER = Color3.fromRGB(26, 29, 38)

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number, color: Color3)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color
	s.Parent = parent
	return s
end

--- Chunky pill button in the pack's visual language.
local function makeButton(text: string, color: Color3, parent: Instance): TextButton
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = color
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Text = text
	button.AutoButtonColor = false
	button.Parent = parent
	corner(button, 8)
	stroke(button, 3, Color3.fromRGB(16, 18, 24))
	local label = Instance.new("UIPadding")
	label.PaddingLeft = UDim.new(0, 6)
	label.PaddingRight = UDim.new(0, 6)
	label.Parent = button
	UIAnim.bindButton(button)
	return button
end

-- ==========================================================
-- CARDS
-- ==========================================================

local function buildCard(item, index: number): Frame
	local def = LootConfig.ById[item.ItemId]
	local rarityColor = RarityConfig.Colors[item.Rarity] or Color3.fromRGB(200, 200, 200)

	local card = Instance.new("Frame")
	card.Name = item.InstanceId
	card.Size = UDim2.new(1, -12, 0, 62)
	card.BackgroundColor3 = DARK
	card.LayoutOrder = index
	corner(card, 10)
	stroke(card, 3, DARKER)

	-- Rarity is a colour bar rather than a word, so it reads instantly.
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(0, 8, 1, -12)
	bar.Position = UDim2.new(0, 6, 0, 6)
	bar.BackgroundColor3 = rarityColor
	bar.BorderSizePixel = 0
	bar.Parent = card
	corner(bar, 4)

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Position = UDim2.new(0, 22, 0, 6)
	name.Size = UDim2.new(0.52, 0, 0, 26)
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = Color3.fromRGB(255, 255, 255)
	name.Text = if def then def.name else item.ItemId
	name.Parent = card

	local detail = Instance.new("TextLabel")
	detail.BackgroundTransparency = 1
	detail.Position = UDim2.new(0, 22, 0, 32)
	detail.Size = UDim2.new(0.52, 0, 0, 22)
	detail.Font = Enum.Font.FredokaOne
	detail.TextScaled = true
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextColor3 = Color3.fromRGB(126, 255, 148)

	local tags = NumberFormat.income(item.FinalIncome)
	if item.Size ~= "Normal" then
		tags ..= "  " .. item.Size
	end
	if item.Mutation ~= "Normal" then
		tags ..= "  " .. item.Mutation
	end
	detail.Text = tags
	detail.Parent = card

	local display = makeButton("DISPLAY", Color3.fromRGB(64, 190, 84), card)
	display.AnchorPoint = Vector2.new(1, 0.5)
	display.Position = UDim2.new(1, -96, 0.5, 0)
	display.Size = UDim2.fromOffset(88, 38)
	display.Activated:Connect(function()
		Remotes.get("InventoryRequest"):FireServer("equip", item.InstanceId)
	end)

	local sell = makeButton("SELL", Color3.fromRGB(214, 62, 72), card)
	sell.AnchorPoint = Vector2.new(1, 0.5)
	sell.Position = UDim2.new(1, -6, 0.5, 0)
	sell.Size = UDim2.fromOffset(84, 38)
	sell.Activated:Connect(function()
		Remotes.get("InventoryRequest"):FireServer("sell", item.InstanceId)
	end)

	return card
end

local function refresh(state)
	latestState = state
	if not panel then
		return
	end

	headerLabel.Text = `{state.storageUsed}/{state.storageCapacity} Stored`

	if state.storageNextCost then
		upgradeButton.Visible = true
		upgradeButton.Text = `+ STORAGE  {NumberFormat.cash(state.storageNextCost)}`
	else
		upgradeButton.Visible = false
	end

	if not isOpen then
		return -- do not rebuild rows behind a closed panel
	end

	for _, child in listFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local inventory = state.inventory or {}
	for index, item in inventory do
		buildCard(item, index).Parent = listFrame
	end

	if #inventory == 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "Empty"
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.new(1, 0, 0, 60)
		empty.Font = Enum.Font.FredokaOne
		empty.TextScaled = true
		empty.TextColor3 = Color3.fromRGB(150, 158, 174)
		empty.Text = "Nothing stored.\nStore a displayed item to keep it here."
		empty.Parent = listFrame
	end

	listFrame.CanvasSize = UDim2.new(0, 0, 0, #inventory * 68 + 12)
end

-- ==========================================================
-- PANEL
-- ==========================================================

local function build(parent: ScreenGui)
	panel = Instance.new("Frame")
	panel.Name = "InventoryPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(560, 470)
	panel.BackgroundColor3 = DARKER
	panel.Visible = false
	panel.Parent = parent
	corner(panel, 16)
	stroke(panel, 4, Color3.fromRGB(12, 14, 18))

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 62)
	header.BackgroundColor3 = Color3.fromRGB(52, 58, 74)
	header.Parent = panel
	corner(header, 16)

	headerLabel = Instance.new("TextLabel")
	headerLabel.BackgroundTransparency = 1
	headerLabel.Position = UDim2.new(0, 16, 0, 0)
	headerLabel.Size = UDim2.new(0.4, 0, 1, 0)
	headerLabel.Font = Enum.Font.FredokaOne
	headerLabel.TextScaled = true
	headerLabel.TextXAlignment = Enum.TextXAlignment.Left
	headerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	headerLabel.Text = "0/10 Stored"
	headerLabel.Parent = header

	upgradeButton = makeButton("+ STORAGE", Color3.fromRGB(64, 190, 84), header)
	upgradeButton.AnchorPoint = Vector2.new(1, 0.5)
	upgradeButton.Position = UDim2.new(1, -58, 0.5, 0)
	upgradeButton.Size = UDim2.fromOffset(186, 42)
	upgradeButton.Activated:Connect(function()
		Remotes.get("InventoryRequest"):FireServer("upgradeStorage")
		UIAnim.punch(upgradeButton, 0.18)
	end)

	local close = makeButton("X", Color3.fromRGB(214, 62, 72), header)
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -10, 0.5, 0)
	close.Size = UDim2.fromOffset(40, 40)
	close.Activated:Connect(function()
		InventoryController.setOpen(false)
	end)

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "List"
	listFrame.Position = UDim2.new(0, 8, 0, 70)
	listFrame.Size = UDim2.new(1, -16, 1, -78)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 6
	listFrame.CanvasSize = UDim2.new()
	listFrame.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = listFrame
end

--- Right-side opener. Placed opposite the left menu so the two read as a pair.
local function buildOpenButton(parent: ScreenGui)
	local holder = Instance.new("Frame")
	holder.Name = "RightMenu"
	holder.AnchorPoint = Vector2.new(1, 0.5)
	holder.Position = UDim2.new(1, -14, 0.5, 0)
	holder.Size = UDim2.fromOffset(86, 108)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	openButton = Instance.new("TextButton")
	openButton.Name = "InventoryButton"
	openButton.Size = UDim2.fromOffset(82, 82)
	openButton.BackgroundColor3 = Color3.fromRGB(94, 140, 255)
	openButton.Font = Enum.Font.FredokaOne
	openButton.Text = ""
	openButton.AutoButtonColor = false
	openButton.Parent = holder
	corner(openButton, 14)
	stroke(openButton, 4, Color3.fromRGB(16, 18, 24))

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Color3.fromRGB(140, 178, 255), Color3.fromRGB(70, 112, 226))
	gradient.Rotation = 90
	gradient.Parent = openButton

	local icon = Instance.new("TextLabel")
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(1, 0.72)
	icon.Font = Enum.Font.FredokaOne
	icon.TextScaled = true
	icon.TextColor3 = Color3.fromRGB(255, 255, 255)
	icon.Text = "🎒"
	icon.Parent = openButton

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 1)
	title.Position = UDim2.new(0.5, 0, 1, 20)
	title.Size = UDim2.new(1.3, 0, 0, 18)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Text = "Storage"
	title.Parent = openButton
	stroke(title, 3, Color3.fromRGB(20, 22, 30))

	-- Count badge so a full storage is obvious without opening the panel.
	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, 6, 0, -6)
	badge.Size = UDim2.fromOffset(34, 26)
	badge.BackgroundColor3 = Color3.fromRGB(255, 176, 46)
	badge.Font = Enum.Font.FredokaOne
	badge.TextScaled = true
	badge.TextColor3 = Color3.fromRGB(40, 28, 8)
	badge.Text = "0"
	badge.Parent = openButton
	corner(badge, 8)
	stroke(badge, 3, Color3.fromRGB(20, 22, 30))

	UIAnim.bindButton(openButton)
	openButton.Activated:Connect(function()
		InventoryController.setOpen(not isOpen)
	end)

	return badge
end

function InventoryController.setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open

	if open then
		refresh(latestState or { storageUsed = 0, storageCapacity = 10, inventory = {} })
		UIAnim.popIn(panel, 0.86)
	else
		UIAnim.popOut(panel)
	end
end

function InventoryController.start()
	local playerGui = player:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "Inventory"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 5
	screen.Parent = playerGui

	build(screen)
	local badge = buildOpenButton(screen)

	-- Keyboard shortcut, and an attribute other systems (or a tutorial step) can
	-- flip to open storage without reaching into this module.
	local UserInputService = game:GetService("UserInputService")
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.B then
			InventoryController.setOpen(not isOpen)
		end
	end)

	screen:GetAttributeChangedSignal("Open"):Connect(function()
		InventoryController.setOpen(screen:GetAttribute("Open") == true)
	end)

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		local previous = latestState and latestState.storageUsed
		refresh(state)
		badge.Text = tostring(state.storageUsed or 0)
		badge.BackgroundColor3 = if (state.storageUsed or 0) >= (state.storageCapacity or 10)
			then Color3.fromRGB(230, 76, 76)
			else Color3.fromRGB(255, 176, 46)
		if previous and state.storageUsed ~= previous then
			UIAnim.punch(badge, 0.3)
		end
	end)
end

return InventoryController
