--!strict
--[[
	ShopController
	Fills the pack's existing Shop panel with our actual monetization.

	IT UPGRADES THE SHOP, IT DOES NOT REPLACE IT.
	`MainUI.Frames.Shop` keeps its own header, close button, scroll frame, list
	layout, gradients and strokes. The pack's demo contents - OP Lucky Block, VIP,
	Server Luck, a grid of placeholder gamepasses - are cleared and OUR sections
	are built from the same components, so the result is the pack's shop with our
	products in it rather than a second shop in a different accent.

	The Shop button already opens this panel: the pack's own LocalScript opens the
	frame in `Frames` whose name matches the clicked button. Nothing here touches
	that, so opening and closing keep working exactly as they did.

	SECTIONS, IN THE ORDER THE REFERENCE USES
	    PASSES   the 2x Cash gamepass
	    CASH     five developer products
	    SPEED    four developer products
	Trails are deliberately NOT here - they are sold at the physical Trail Shop.
	Nor is the Speed multiplier ladder, which belongs on the treadmill.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ShopController = {}

local player = Players.LocalPlayer

--- Demo content shipped inside the pack's shop. Cleared once on build; anything
--- we create afterwards is named so it is never mistaken for one of these.
local PACK_DEMO = {
	"OPLuckyBlock", "Empty", "Features", "Offers",
	"LimitedGamepass", "ServerLuck", "VIP",
	"GamepassesTitle", "Gamepassees",
}

local CASH_COLOR = Color3.fromRGB(96, 220, 118)
local CASH_ACCENT = Color3.fromRGB(30, 140, 66)
local SPEED_COLOR = Color3.fromRGB(96, 216, 255)
local SPEED_ACCENT = Color3.fromRGB(24, 116, 190)
local PASS_COLOR = Color3.fromRGB(255, 206, 84)
local PASS_ACCENT = Color3.fromRGB(196, 130, 16)

local built = false
local cashPassCard: Frame? = nil

local function scroller(): ScrollingFrame?
	local ui = ShopKit.mainUi()
	local frames = ui and ui:FindFirstChild("Frames")
	local shop = frames and frames:FindFirstChild("Shop")
	local found = shop and shop:FindFirstChild("ScrollingFrame")
	return if found and found:IsA("ScrollingFrame") then found else nil
end

-- MEASURED FROM THE PACK'S OWN GAMEPASS GRID, not guessed. Its `Gamepassees`
-- frame is 0.26 of the scroller's height and holds three rows of two, and its
-- cards carry a UIAspectRatioConstraint of 2 - they are WIDE, not square. Square
-- cells fight that constraint and the cards overflow their row, which is exactly
-- how the first attempt came out clipped.
local ROW_HEIGHT = 0.30
local CELL_PADDING = UDim2.fromScale(0.02, 0.04)
--- The pack's own header is 0.02 tall, which is legible only because its text
--- scales. A little more room lets a section title actually read as one.
local HEADER_HEIGHT = 0.075

--- A section header + a grid to hang its cards on.
local function section(parent: ScrollingFrame, title: string, order: number): Frame?
	local header = ShopKit.header()
	if header then
		header.Name = `Section_{title}`
		header.LayoutOrder = order
		header.Size = UDim2.fromScale(1, HEADER_HEIGHT)
		local label = header:FindFirstChild("Title")
		if label and label:IsA("TextLabel") then
			label.Text = string.upper(title)
		end
		header.Parent = parent
	end

	local grid = Instance.new("Frame")
	grid.Name = `Grid_{title}`
	grid.LayoutOrder = order + 1
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromScale(1, ROW_HEIGHT)
	grid.Parent = parent

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromScale(0.47, 0.94)
	layout.CellPadding = CELL_PADDING
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = grid

	return grid
end

--- Sizes a grid to the rows it actually holds, so sections neither overlap each
--- other nor leave a hole. Two columns, so rows = ceil(n / 2).
local function fitGrid(grid: Frame, count: number)
	local rows = math.max(1, math.ceil(count / 2))
	grid.Size = UDim2.fromScale(1, ROW_HEIGHT * rows)
	-- Cell height is a fraction of the GRID, so it has to shrink as rows are
	-- added or every row would be a full grid tall and they would overlap.
	local layout = grid:FindFirstChildOfClass("UIGridLayout")
	if layout then
		layout.CellSize = UDim2.fromScale(0.47, 0.94 / rows)
	end
end

local function buildShop()
	if built then
		return
	end
	local list = scroller()
	if not list then
		return
	end

	-- LIFT THE TEMPLATES FIRST. The card template lives inside `Gamepassees`,
	-- which the very next loop destroys - reading it afterwards returns nil and
	-- the shop comes up as a header over an empty box.
	ShopKit.warm()

	-- Clear the pack's demo products, but keep its layout and scrollbar.
	for _, name in PACK_DEMO do
		local demo = list:FindFirstChild(name)
		if demo then
			demo:Destroy()
		end
	end

	local cards: { GuiObject } = {}

	-- PASSES ------------------------------------------------------------
	local passGrid = section(list, "Passes", 10)
	if passGrid then
		local card = ShopKit.card()
		if card then
			card.Name = "Card_Cash2x"
			card.Parent = passGrid
			ShopKit.fillCard(card, {
				title = MonetizationConfig.CashPass.label,
				description = "Doubles every dollar you earn. Forever.",
				price = `R$ {NumberFormat.comma(MonetizationConfig.CashPass.robux)}`,
				icon = ShopKit.Icons.Cash,
				color = PASS_COLOR,
				accent = PASS_ACCENT,
			})
			ShopKit.bindBuy(card, function()
				UIAnim.punch(card, 0.14)
				Remotes.get("PurchaseRequest"):FireServer("cashPass")
			end)
			cashPassCard = card
			table.insert(cards, card)
		end
		fitGrid(passGrid, 1)
	end

	-- CASH --------------------------------------------------------------
	local cashGrid = section(list, "Cash", 20)
	if cashGrid then
		for index, product in MonetizationConfig.CashProducts do
			local card = ShopKit.card()
			if card then
				card.Name = `Card_{product.key}`
				card.LayoutOrder = index
				card.Parent = cashGrid
				ShopKit.fillCard(card, {
					title = `${product.label}`,
					description = "",
					price = `R$ {NumberFormat.comma(product.robux)}`,
					icon = ShopKit.Icons.Cash,
					color = CASH_COLOR,
					accent = CASH_ACCENT,
				})
				ShopKit.bindBuy(card, function()
					UIAnim.punch(card, 0.14)
					Remotes.get("PurchaseRequest"):FireServer("product", product.key)
				end)
				table.insert(cards, card)
			end
		end
		fitGrid(cashGrid, #MonetizationConfig.CashProducts)
	end

	-- SPEED -------------------------------------------------------------
	local speedGrid = section(list, "Speed", 30)
	if speedGrid then
		for index, product in MonetizationConfig.SpeedProducts do
			local card = ShopKit.card()
			if card then
				card.Name = `Card_{product.key}`
				card.LayoutOrder = index
				card.Parent = speedGrid
				ShopKit.fillCard(card, {
					title = `+{product.label}`,
					description = "",
					price = `R$ {NumberFormat.comma(product.robux)}`,
					icon = ShopKit.Icons.Speed,
					color = SPEED_COLOR,
					accent = SPEED_ACCENT,
				})
				ShopKit.bindBuy(card, function()
					UIAnim.punch(card, 0.14)
					Remotes.get("PurchaseRequest"):FireServer("product", product.key)
				end)
				table.insert(cards, card)
			end
		end
		fitGrid(speedGrid, #MonetizationConfig.SpeedProducts)
	end

	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.fromScale(0, 0)
	list.ScrollBarThickness = 6

	built = true
	ShopKit.cascadeIn(cards)
end

--- The 2x Cash card becomes an OWNED state once they have it, rather than
--- continuing to sell something they cannot buy twice.
local function refreshOwnership(monetization: any)
	local card = cashPassCard
	if not card or not monetization then
		return
	end
	if monetization.ownsCashPass then
		ShopKit.fillCard(card, {
			title = "2X CASH",
			description = "OWNED - every dollar you earn is doubled.",
			price = "",
			icon = ShopKit.Icons.Cash,
			color = PASS_COLOR,
			accent = PASS_ACCENT,
			hidePrice = true,
		})
	end
end

function ShopController.start()
	-- Built lazily on the first push, so MainUI is certain to exist.
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		buildShop()
		if state then
			refreshOwnership(state.monetization)
		end
	end)
end

return ShopController
