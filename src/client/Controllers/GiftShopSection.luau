--!strict
--[[
	GiftShopSection
	The Shop's GIFT section (trading-gifting-boards pass): buy a Cash or
	Speed pack FOR another player in the server. Kept out of ShopController,
	which only calls `build` once and `update` on every state.

	  GIFT TO: [ Name  > ]   tap to cycle through the other players
	  one pack card per gift product (pack components from ShopKit)

	Pressing a card sends GiftRequest(recipientUserId, giftKey); the server
	remembers the recipient and opens the Robux dialog (GiftService). The
	whole section is hidden until the server says a gift product id exists
	(StatePush `gifts.enabled`), and when nobody else is in the server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local TradeConfig = require(ReplicatedStorage.Shared.Config.TradeConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local GiftShopSection = {}

local player = Players.LocalPlayer

local GIFT_COLOR = Color3.fromRGB(255, 120, 190)
local GIFT_ACCENT = Color3.fromRGB(176, 40, 120)
--- Same geometry rules as ShopController's grids: two 47%-wide cells per
--- row, 2:1 pack cards, 8 px between rows.
local CELL_WIDTH = 0.47
local CARD_ASPECT = 2
local ROW_GAP = 8

local header: Frame? = nil
local pickerRow: Frame? = nil
local pickerButton: TextButton? = nil
local grid: Frame? = nil
local recipient: Player? = nil
local enabled = false

local function others(): { Player }
	local list = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			table.insert(list, other)
		end
	end
	table.sort(list, function(a, b)
		return a.DisplayName:lower() < b.DisplayName:lower()
	end)
	return list
end

local function paintPicker()
	local b = pickerButton
	if not b then
		return
	end
	b.Text = if recipient then `GIFT TO:  {recipient.DisplayName}  >` else "GIFT TO:  nobody else is here"
end

local function refreshVisibility()
	local list = others()
	if recipient and (recipient.Parent == nil or not table.find(list, recipient)) then
		recipient = nil
	end
	if not recipient then
		recipient = list[1]
	end
	local show = enabled and recipient ~= nil
	for _, part in { header, pickerRow, grid } do
		if part then
			part.Visible = show
		end
	end
	paintPicker()
end

local function fit()
	local g = grid
	local list = g and g.Parent
	if not g or not list or not list:IsA("GuiObject") then
		return
	end
	local layout = g:FindFirstChildOfClass("UIGridLayout")
	local width = list.AbsoluteSize.X
	if not layout or width <= 0 then
		return
	end
	local cellWidth = width * CELL_WIDTH
	local cellHeight = cellWidth / CARD_ASPECT
	local rows = math.max(1, math.ceil(#MonetizationConfig.GiftProducts / 2))
	layout.CellSize = UDim2.fromOffset(cellWidth, cellHeight)
	g.Size = UDim2.new(1, 0, 0, rows * cellHeight + (rows - 1) * ROW_GAP)
end

--- Builds the section at the bottom of the Shop list. `order` is the
--- LayoutOrder to start from. Returns the cards for the Shop's cascade.
function GiftShopSection.build(list: ScrollingFrame, order: number): { GuiObject }
	local cards: { GuiObject } = {}

	local h = ShopKit.header()
	if h then
		h.Name = "Section_Gift"
		h.LayoutOrder = order
		h.Size = UDim2.fromScale(1, 0.075)
		local label = h:FindFirstChild("Title")
		if label and label:IsA("TextLabel") then
			label.Text = "GIFT A FRIEND"
		end
		h.Visible = false
		h.Parent = list
		header = h
	end

	local row = Instance.new("Frame")
	row.Name = "GiftRecipient"
	row.LayoutOrder = order + 1
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 52)
	row.Visible = false
	row.Parent = list
	pickerRow = row

	local b = Instance.new("TextButton")
	b.Name = "GiftPicker"
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.fromScale(0.5, 0.5)
	b.Size = UDim2.new(0.94, 0, 0, 46)
	b.BackgroundColor3 = GIFT_ACCENT
	b.AutoButtonColor = false
	b.Font = Enum.Font.FredokaOne
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.TextScaled = true
	b.TextStrokeTransparency = 0.3
	b.Parent = row
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = b
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 24
	limit.Parent = b
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.18, 0)
	pad.PaddingBottom = UDim.new(0.18, 0)
	pad.Parent = b
	if TradeConfig.hasIcon(TradeConfig.Icons.Gift) then
		local icon = Instance.new("ImageLabel")
		icon.Name = "GiftIcon"
		icon.BackgroundTransparency = 1
		icon.Image = TradeConfig.Icons.Gift
		icon.Size = UDim2.fromScale(1, 1.4)
		icon.Position = UDim2.fromScale(0.01, -0.2)
		icon.Parent = b
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.AspectRatio = 1
		ratio.Parent = icon
	end
	UIAnim.claimButton(b)
	b.Activated:Connect(function()
		local list_ = others()
		if #list_ == 0 then
			recipient = nil
		else
			local at = if recipient then table.find(list_, recipient) or 0 else 0
			recipient = list_[(at % #list_) + 1]
		end
		paintPicker()
	end)
	pickerButton = b

	local g = Instance.new("Frame")
	g.Name = "Grid_Gift"
	g.LayoutOrder = order + 2
	g.BackgroundTransparency = 1
	g.Size = UDim2.new(1, 0, 0, 100)
	g.Visible = false
	g.Parent = list
	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.new(0.02, 0, 0, ROW_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = g
	grid = g

	for index, product in MonetizationConfig.GiftProducts do
		local pack = if product.giftOf then MonetizationConfig.ProductByKey[product.giftOf] else nil
		local card = ShopKit.card()
		if not card or not pack then
			continue
		end
		card.Name = `Card_{product.key}`
		card.LayoutOrder = index
		card.Parent = g
		local isCash = pack.kind == "Cash"
		ShopKit.fillCard(card, {
			title = if isCash then `GIFT ${product.label}+` else `GIFT +{product.label} SPEED`,
			description = if isCash then "Scales with their income" else "",
			price = if product.productId > 0 then `R$ {NumberFormat.comma(product.robux)}` else "SOON",
			icon = if TradeConfig.hasIcon(TradeConfig.Icons.Gift)
				then TradeConfig.Icons.Gift
				elseif isCash then ShopKit.Icons.Cash
				else ShopKit.Icons.Speed,
			color = GIFT_COLOR,
			accent = GIFT_ACCENT,
		})
		local key = product.key
		ShopKit.bindBuy(card, function()
			local target = recipient
			if not target or not target.Parent then
				refreshVisibility()
				return
			end
			UIAnim.punch(card, 0.14)
			Remotes.get("GiftRequest"):FireServer(target.UserId, key)
		end)
		table.insert(cards, card)
	end

	fit()
	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	Players.PlayerAdded:Connect(refreshVisibility)
	Players.PlayerRemoving:Connect(function()
		task.defer(refreshVisibility)
	end)
	refreshVisibility()
	return cards
end

--- Every state: show or hide the section.
function GiftShopSection.update(state: any)
	local gifts = if type(state) == "table" then state.gifts else nil
	local now = type(gifts) == "table" and gifts.enabled == true
	if now ~= enabled then
		enabled = now
		refreshVisibility()
	end
end

return GiftShopSection
