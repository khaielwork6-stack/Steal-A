--!strict
--[[
	GadgetShopController
	A "GADGETS" section in the main Shop panel (gadgets-patrols area).

	THE LEAST INVASIVE PLACE. The Shop panel already opens from the HUD and
	ShopController already builds its sections from ShopKit; this adds one
	more section AFTER them (LayoutOrder 50/51, past Gift's 40/41/42) with the
	same header and card components, and never touches ShopController's own
	sections or its demo cleanup (the names used here are not in its list).

	Three cards, one per gadget: label, what it does, "have 2/3", and the
	price in Cash. Prices, counts and limits all come from StatePush
	`gadgets` (GadgetService.summarise) - the price depends on the player's
	highest zone and is the server's number. The Buy button sends
	("buy", key); a full stack shows FULL instead of a price.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)
local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)

local GadgetShopController = {}

local SECTION_ORDER = 50
local HEADER_HEIGHT = 0.075 -- ShopController's header height, for a matching look
local CELL_WIDTH = 0.47
local ROW_GAP = 8
local CARD_ASPECT = 2

local NO_ASSET = "rbxassetid://0"

local built = false
local grid: Frame? = nil
local cards: { [string]: Frame } = {}
--- The Robux refill box on each card, when its product is configured.
local robuxBoxes: { [string]: TextButton } = {}
--- What each card shows, so a push repaints only what changed (StatePush
--- fires several times a second while income ticks).
local shown: { [string]: string } = {}
local shownCount: { [string]: number } = {}

local function scroller(): ScrollingFrame?
	local ui = ShopKit.mainUi()
	local frames = ui and ui:FindFirstChild("Frames")
	local shop = frames and frames:FindFirstChild("Shop")
	local found = shop and shop:FindFirstChild("ScrollingFrame")
	return if found and found:IsA("ScrollingFrame") then found else nil
end

--- Two columns at the pack card's 2:1, sized in pixels from the scroller's
--- width (the same fit ShopController uses for its sections).
local function fit()
	local frame = grid
	local list = frame and frame.Parent
	local layout = frame and frame:FindFirstChildOfClass("UIGridLayout")
	if not frame or not list or not list:IsA("GuiObject") or not layout then
		return
	end
	local width = list.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local factor = ClipSafe.scaleChain(list)
	local columns = if width < 540 then 1 else 2
	local cellWidth = width * (if columns == 1 then 0.94 else CELL_WIDTH) / factor
	local cellHeight = math.max(190 / factor, cellWidth / CARD_ASPECT)
	local rows = math.max(1, math.ceil(#GadgetConfig.Order / columns))
	layout.CellSize = UDim2.fromOffset(cellWidth, cellHeight)
	frame.Size = UDim2.new(1, 0, 0, rows * cellHeight + (rows - 1) * ROW_GAP)
end

local function build(): boolean
	if built then
		return true
	end
	local list = scroller()
	if not list then
		return false
	end
	-- Lift the pack templates before ShopController clears its demo frames
	-- (idempotent: whichever controller gets here first caches them).
	ShopKit.warm()

	local header = ShopKit.header()
	if header then
		header.Name = "Section_Gadgets"
		header.LayoutOrder = SECTION_ORDER
		header.Size = UDim2.fromScale(1, HEADER_HEIGHT)
		local label = header:FindFirstChild("Title")
		if label and label:IsA("TextLabel") then
			label.Text = "GADGETS"
		end
		header.Parent = list
	end

	local holder = Instance.new("Frame")
	holder.Name = "Grid_Gadgets"
	holder.LayoutOrder = SECTION_ORDER + 1
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 100)
	holder.Parent = list
	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.new(0.02, 0, 0, ROW_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = holder
	grid = holder

	local made: { GuiObject } = {}
	for index, key in GadgetConfig.Order do
		local def = GadgetConfig.Gadgets[key]
		local card = ShopKit.card()
		if not card then
			continue
		end
		PanelStyle.productCard(card)
		card.Name = `Gadget_{key}`
		card.LayoutOrder = index
		card.Parent = holder
		ShopKit.fillCard(card, {
			title = def.label,
			description = def.description,
			price = "...",
			color = def.color,
			accent = def.accent,
			icon = if def.icon ~= NO_ASSET then def.icon else ShopKit.Icons.Shop,
		})
		ShopKit.bindBuy(card, function()
			UIAnim.punch(card, 0.14)
			Remotes.get("GadgetRequest"):FireServer("buy", key)
		end)
		robuxBoxes[key] = GadgetShopController.attachRobuxBox(card, key)
		cards[key] = card
		table.insert(made, card)
	end

	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	built = true
	ShopKit.cascadeIn(made)
	return true
end

-- ==========================================================
-- THE ROBUX BOX (gadget-robux)
-- ==========================================================
--
-- A SECOND way to buy the same gadget, never a replacement for the first:
-- the green Cash button keeps its place and shrinks, and a blue Robux box
-- sits beside it that FILLS the stack to its limit in one purchase.
--
-- Blue, not green, on purpose - two buttons the same colour a thumb's width
-- apart is how a player spends Robux they meant to spend Cash. It is also
-- Roblox's own currency colour, which is the association we want.
--
-- The box only exists once the owner has created the product: an id of 0
-- means `isConfigured` is false, and the card then looks exactly as it did
-- before this pass. Shared by BOTH surfaces (the Shop panel and the lobby
-- stand) so the two can never drift apart.

local ROBUX_BLUE = Color3.fromRGB(56, 152, 236)
local ROBUX_BLUE_DARK = Color3.fromRGB(24, 92, 164)
local ROBUX_FULL = Color3.fromRGB(96, 104, 124)

--- The Robux box on one gadget card, built once. Returns it so `paint` can
--- keep its label and its enabled state current.
function GadgetShopController.attachRobuxBox(card: Frame, key: string): TextButton?
	local product = MonetizationConfig.GadgetProductByKey[key]
	if not product or not MonetizationConfig.isConfigured(product.key) then
		return nil
	end
	local body = card:FindFirstChild("Frame")
	local choose = body and body:FindFirstChild("Choose")
	if not body or not choose or not choose:IsA("GuiObject") then
		return nil
	end
	local existing = body:FindFirstChild("RobuxBuy")
	if existing and existing:IsA("TextButton") then
		return existing
	end

	-- Make room: the Cash button gives up its right-hand third.
	choose.Size = UDim2.fromScale(choose.Size.X.Scale * 0.6, choose.Size.Y.Scale)

	local button = Instance.new("TextButton")
	button.Name = "RobuxBuy"
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundColor3 = ROBUX_BLUE
	button.BorderSizePixel = 0
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.fromScale(0.95, choose.Position.Y.Scale)
	button.Size = UDim2.fromScale(0.33, choose.Size.Y.Scale)
	button.ZIndex = 9
	button.Parent = body
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button
	local edge = Instance.new("UIStroke")
	edge.Color = ROBUX_BLUE_DARK
	edge.Thickness = 2
	edge.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = button
	local shade = Instance.new("UIGradient")
	shade.Rotation = 90
	shade.Color = ColorSequence.new(ROBUX_BLUE, ROBUX_BLUE_DARK)
	shade.Parent = button

	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.BackgroundTransparency = 1
	price.AnchorPoint = Vector2.new(0.5, 0.5)
	price.Position = UDim2.fromScale(0.5, 0.5)
	price.Size = UDim2.fromScale(0.92, 0.6)
	price.Font = Enum.Font.FredokaOne
	price.TextScaled = true
	price.TextColor3 = Color3.fromRGB(255, 255, 255)
	price.TextStrokeColor3 = Color3.fromRGB(10, 34, 62)
	price.TextStrokeTransparency = 0.2
	price.Text = `R$ {product.robux}`
	price.ZIndex = 10
	price.Parent = button
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 22
	limit.Parent = price

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.BackgroundTransparency = 1
	caption.AnchorPoint = Vector2.new(0.5, 1)
	caption.Position = UDim2.fromScale(0.5, 0.99)
	caption.Size = UDim2.fromScale(0.95, 0.28)
	caption.Font = Enum.Font.GothamBold
	caption.TextScaled = true
	caption.TextColor3 = Color3.fromRGB(210, 232, 255)
	caption.Text = "REFILL"
	caption.ZIndex = 10
	caption.Parent = button
	local capLimit = Instance.new("UITextSizeConstraint")
	capLimit.MaxTextSize = 11
	capLimit.Parent = caption

	UIAnim.claimButton(button)
	button.Activated:Connect(function()
		if button:GetAttribute("Full") == true then
			UIAnim.punch(button, 0.05)
			return
		end
		UIAnim.punch(button, 0.12)
		-- The SERVER opens the dialog and the receipt grants it; this only asks.
		Remotes.get("PurchaseRequest"):FireServer("product", product.key)
	end)
	return button
end

--- Greys the box out at the limit, so the one thing it buys is never sold to
--- a player who cannot receive it.
function GadgetShopController.paintRobuxBox(button: TextButton?, full: boolean)
	if not button then
		return
	end
	button:SetAttribute("Full", full)
	button.BackgroundColor3 = if full then ROBUX_FULL else ROBUX_BLUE
	local shade = button:FindFirstChildOfClass("UIGradient")
	if shade then
		shade.Color = if full
			then ColorSequence.new(ROBUX_FULL, ROBUX_FULL)
			else ColorSequence.new(ROBUX_BLUE, ROBUX_BLUE_DARK)
	end
	local caption = button:FindFirstChild("Caption")
	if caption and caption:IsA("TextLabel") then
		caption.Text = if full then "FULL" else "REFILL"
	end
end

--- What one gadget card shows for StatePush `gadgets` (shared with the lobby
--- stand's panel, GadgetStoreController): the ShopKit options, how many the
--- player holds, and a signature that changes only when the card must repaint.
function GadgetShopController.cardFor(key: string, gadgets: any): (ShopKit.CardOptions, number, string)
	local def = GadgetConfig.Gadgets[key]
	local data = if type(gadgets) == "table" then gadgets else {}
	local counts = if type(data.counts) == "table" then data.counts else {}
	local prices = if type(data.prices) == "table" then data.prices else {}
	local limits = if type(data.max) == "table" then data.max else {}
	local have = tonumber(counts[key]) or 0
	local limit = tonumber(limits[key]) or def.maxCarried
	local price = tonumber(prices[key])
	local full = have >= limit
	local priceText = if full then "FULL" elseif price then NumberFormat.cash(price) else "..."
	local description = `{def.description}  (have {have}/{limit})`
	local options: ShopKit.CardOptions = {
		title = def.label,
		description = description,
		price = priceText,
		color = def.color,
		accent = def.accent,
	}
	return options, have, priceText .. "|" .. description
end

local function paint(gadgets: any)
	if type(gadgets) ~= "table" then
		return
	end
	for key, card in cards do
		local options, have, signature = GadgetShopController.cardFor(key, gadgets)
		if shown[key] == signature then
			continue
		end
		-- A purchase landed (the count went up since the last paint).
		local before = shownCount[key]
		local grew = before ~= nil and have > before
		shown[key] = signature
		shownCount[key] = have
		ShopKit.fillCard(card, options)
		-- fillCard rebuilds the pack card's own parts; the Robux box is ours
		-- and survives it, so it only needs its state refreshed.
		local limit = GadgetConfig.Gadgets[key].maxCarried
		GadgetShopController.paintRobuxBox(robuxBoxes[key], have >= limit)
		if grew then
			ShopKit.shine(card)
		end
	end
end

function GadgetShopController.start()
	require(script.Parent.Parent.StateStore).subscribe(function(state)
		if not build() or not state then
			return
		end
		paint(state.gadgets)
	end)
end

return GadgetShopController
