--!strict
--[[
	GadgetShopController
	A "GADGETS" section in the main Shop panel (gadgets-patrols area).

	THE LEAST INVASIVE PLACE. The Shop panel already opens from the HUD and
	ShopController already builds its sections from ShopKit; this adds one
	more section AFTER them (LayoutOrder 40/41, past Speed's 30/31) with the
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
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local GadgetShopController = {}

local SECTION_ORDER = 40
local HEADER_HEIGHT = 0.075 -- ShopController's header height, for a matching look
local CELL_WIDTH = 0.47
local ROW_GAP = 8
local CARD_ASPECT = 2

local NO_ASSET = "rbxassetid://0"

local built = false
local grid: Frame? = nil
local cards: { [string]: Frame } = {}
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
	local cellWidth = width * CELL_WIDTH
	local cellHeight = cellWidth / CARD_ASPECT
	local rows = math.max(1, math.ceil(#GadgetConfig.Order / 2))
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
		cards[key] = card
		table.insert(made, card)
	end

	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	built = true
	ShopKit.cascadeIn(made)
	return true
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
