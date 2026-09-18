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

	CASH PACKS SHOW THIS PLAYER'S AMOUNT (monetization pass). A pack pays
	max(floor, minutes of the buyer's income) - MonetizationConfig CASH PACKS -
	so the printed "8M" is only true early on. The server sends the exact
	figure it would grant right now (StatePush `shop.cashPacks`), and every
	Cash card carries a ribbon with it, showing that figure and nothing else:
	"$4.1B". Pack cards without art put it in their title instead. The figure
	is the server's; nothing here computes an amount.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PngCard = require(ReplicatedStorage.Shared.Util.PngCard)
local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)
local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)

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
local cashPassCard: GuiObject? = nil
--- The painted 2x Cash card, when the pass has art: its OWNED pill and its
--- buttons are what ownership flips.
local cashPassPng: PngCard.Card? = nil
local cashPassOwnedBadge: Frame? = nil

--- The art's tint while the pass is owned: greyed, clearly spent, still
--- readable. White is the untouched print.
local ART_OWNED_TINT = Color3.fromRGB(118, 122, 134)
local ART_LIVE_TINT = Color3.fromRGB(255, 255, 255)

--- A small round green check in the art's top-right corner: the one mark
--- that says "you have this" once the card is greyed. Hidden until then.
local function buildOwnedBadge(artwork: ImageLabel): Frame
	local badge = Instance.new("Frame")
	badge.Name = "OwnedBadge"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.fromScale(0.985, 0.04)
	badge.Size = UDim2.fromScale(0.16, 0.16)
	badge.BackgroundColor3 = Color3.fromRGB(72, 200, 108)
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = 8
	badge.Parent = artwork
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = badge
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = badge
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(12, 40, 24)
	stroke.Parent = badge
	local check = Instance.new("TextLabel")
	check.BackgroundTransparency = 1
	check.Size = UDim2.fromScale(1, 1)
	check.Font = Enum.Font.FredokaOne
	check.TextScaled = true
	check.Text = "✓"
	check.TextColor3 = Color3.fromRGB(255, 255, 255)
	check.ZIndex = 9
	check.Parent = badge
	return badge
end
--- Product key -> its card, so a landed purchase can flash the right one.
local cardByKey: { [string]: GuiObject } = {}
local lastOwnsCashPass: boolean? = nil

-- ==========================================================
-- LIVE CASH-PACK AMOUNTS
-- ==========================================================

--- Where the ribbon sits on a painted Cash card, in fractions of the art.
--- Bottom-left, clear of the printed R$ button (which starts at x ~0.68).
--- An estimate until checked against the art in Studio - these two lines
--- are the only knobs.
local RIBBON_POSITION = UDim2.fromScale(0.035, 0.93)
local RIBBON_SIZE = UDim2.fromScale(0.6, 0.2)

--- Product key -> the thing that shows its live amount: a ribbon on a
--- painted card, or the pack card itself (its title is re-filled).
local ribbonByKey: { [string]: TextLabel } = {}
local packCardByKey: { [string]: Frame } = {}
--- Product key -> the amount currently shown, so a push repaints only what
--- changed (income ticks push several times a second).
local shownAmount: { [string]: number } = {}

local function buildRibbon(artwork: ImageLabel): TextLabel
	local ribbon = Instance.new("TextLabel")
	ribbon.Name = "LiveAmount"
	ribbon.AnchorPoint = Vector2.new(0, 1)
	ribbon.Position = RIBBON_POSITION
	ribbon.Size = RIBBON_SIZE
	ribbon.BackgroundColor3 = Color3.fromRGB(14, 40, 24)
	ribbon.BackgroundTransparency = 0.06
	ribbon.BorderSizePixel = 0
	ribbon.Font = Enum.Font.FredokaOne
	ribbon.TextScaled = true
	ribbon.TextColor3 = Color3.fromRGB(150, 255, 170)
	ribbon.Text = ""
	ribbon.Visible = false
	ribbon.ZIndex = 8
	ribbon.Parent = artwork
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.35, 0)
	corner.Parent = ribbon
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(8, 20, 12)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = ribbon
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.05, 0)
	pad.PaddingRight = UDim.new(0.05, 0)
	pad.PaddingTop = UDim.new(0.1, 0)
	pad.PaddingBottom = UDim.new(0.1, 0)
	pad.Parent = ribbon
	return ribbon
end

local function paintCashAmounts(shop: any)
	local packs = if type(shop) == "table" then shop.cashPacks else nil
	if type(packs) ~= "table" then
		return
	end
	for _, product in MonetizationConfig.CashProducts do
		local amount = tonumber(packs[product.key])
		if not amount or shownAmount[product.key] == amount then
			continue
		end
		shownAmount[product.key] = amount
		local ribbon = ribbonByKey[product.key]
		if ribbon then
			-- The figure ALONE. It used to read "YOU GET $4.1B" on a card whose
			-- art already says what the pack is, so the words were three-quarters
			-- of the ribbon and none of the information. The number is what the
			-- player is reading for, and on a painted card it is the only place
			-- the live amount appears at all - the printed figure goes stale.
			ribbon.Text = NumberFormat.cash(amount)
			ribbon.Visible = true
		end
		local card = packCardByKey[product.key]
		if card then
			ShopKit.fillCard(card, {
				title = NumberFormat.cash(amount),
				description = "",
				price = `R$ {NumberFormat.comma(product.robux)}`,
				icon = ShopKit.Icons.Cash,
				color = CASH_COLOR,
				accent = CASH_ACCENT,
			})
		end
	end
end

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
--- Cells are 47% of the scroller wide, two to a row, and as tall as their
--- section's card aspect says (pixels, see fitGrid).
local CELL_WIDTH = 0.47
--- Vertical gap between rows, in pixels.
local ROW_GAP = 8
--- The pack's product card is authored 2:1; that is the shape a section falls
--- back to when it has no painted art.
local PACK_CARD_ASPECT = 2

--- Every section grid with its row count and aspect, re-fitted whenever the
--- scroller changes size so the pixel cells keep tracking the panel.
local fitted: { { grid: Frame, count: number, aspect: number? } } = {}
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
	grid.Size = UDim2.new(1, 0, 0, 100) -- fitted to its rows by fitGrid
	grid.Parent = parent

	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.new(0.02, 0, 0, ROW_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = grid

	return grid
end

--- Sizes a grid's cells in PIXELS from the scroller's real width - two
--- columns at the section's card aspect - and the grid to exactly its rows,
--- so sections neither overlap nor leave holes, and every painted card in a
--- section comes out the same shape at any resolution. Re-run on resize.
local function fitGrid(grid: Frame, count: number, aspect: number?)
	local list = grid.Parent
	local layout = grid:FindFirstChildOfClass("UIGridLayout")
	if not list or not list:IsA("GuiObject") or not layout then
		return
	end
	local width = list.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local factor = ClipSafe.scaleChain(list)
	local columns = if width < 540 then 1 else 2
	local cellWidth = width * (if columns == 1 then 0.94 else CELL_WIDTH) / factor
	local cellHeight = math.max(190 / factor, cellWidth / (aspect or PACK_CARD_ASPECT))
	local rows = math.max(1, math.ceil(count / columns))
	layout.CellSize = UDim2.fromOffset(cellWidth, cellHeight)
	grid.Size = UDim2.new(1, 0, 0, rows * cellHeight + (rows - 1) * ROW_GAP)
end

local function trackGrid(grid: Frame, count: number, aspect: number?)
	table.insert(fitted, { grid = grid, count = count, aspect = aspect })
	fitGrid(grid, count, aspect)
end

--- A painted product card: the whole card buys (there is one price on it),
--- and the printed R$ button is the part that lights up under the pointer.
--- Purchases go through the same PurchaseRequest as the pack cards did.
local function buildPngProduct(grid: Frame, name: string, order: number, layout: PngUiConfig.Layout, onBuy: () -> ()): PngCard.Card
	local card = PngCard.build({
		name = name,
		layout = layout,
		familyAspect = PngUiConfig.aspectFor(layout),
		regions = { buy = {} },
		wholeCard = onBuy,
	})
	card.frame.LayoutOrder = order
	card.frame.Parent = grid
	return card
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
	if list.Parent and list.Parent:IsA("Frame") then PanelStyle.window(list.Parent, 960, 620) end

	-- Clear the pack's demo products, but keep its layout and scrollbar.
	for _, name in PACK_DEMO do
		local demo = list:FindFirstChild(name)
		if demo then
			demo:Destroy()
		end
	end

	local cards: { GuiObject } = {}

	-- PAINTED OR PACK. A product whose art is in PngUiConfig gets the painted
	-- card (whole card buys); anything without art keeps the pack card. Both
	-- send the same PurchaseRequest with the same key.

	-- PASSES ------------------------------------------------------------
	local passGrid = section(list, "Passes", 10)
	if passGrid then
		-- [fusion-autoreveal-bases] The Auto Reveal pass: its own module, one
		-- more card in this grid (0 while the pass id is unset outside Studio).
		local passCount = 1 + require(script.Parent.AutoRevealPassCard).build(passGrid, 2)
		local passLayout = PngUiConfig.card("Pass_Cash2x")
		if passLayout then
			local png = buildPngProduct(passGrid, "Card_Cash2x", 1, passLayout, function()
				Remotes.get("PurchaseRequest"):FireServer("cashPass")
			end)
			cashPassPng = png
			cashPassOwnedBadge = buildOwnedBadge(png.artwork)
			cashPassCard = png.frame
			table.insert(cards, png.frame)
			trackGrid(passGrid, passCount, PngUiConfig.aspectFor(passLayout))
		else
			local card = ShopKit.card()
			if card then
				PanelStyle.productCard(card)
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
			trackGrid(passGrid, passCount, nil)
		end
	end

	--- One developer-product section: painted where there is art, pack where
	--- there is not. The section's cell aspect is the family of its art.
	local function productSection(title: string, order: number, products: { MonetizationConfig.ProductDef }, color: Color3, accent: Color3, icon: string, titleOf: (MonetizationConfig.ProductDef) -> string)
		local grid = section(list, title, order)
		if not grid then
			return
		end
		local aspect: number? = nil
		for index, product in products do
			local layout = PngUiConfig.card(`Product_{product.key}`)
			if layout then
				local png = buildPngProduct(grid, `Card_{product.key}`, index, layout, function()
					Remotes.get("PurchaseRequest"):FireServer("product", product.key)
				end)
				cardByKey[product.key] = png.frame
				if product.kind == "Cash" then
					ribbonByKey[product.key] = buildRibbon(png.artwork)
				end
				table.insert(cards, png.frame)
				aspect = aspect or PngUiConfig.aspectFor(layout)
			else
				local card = ShopKit.card()
				if card then
					PanelStyle.productCard(card)
					card.Name = `Card_{product.key}`
					card.LayoutOrder = index
					card.Parent = grid
					ShopKit.fillCard(card, {
						title = titleOf(product),
						description = "",
						price = `R$ {NumberFormat.comma(product.robux)}`,
						icon = icon,
						color = color,
						accent = accent,
					})
					ShopKit.bindBuy(card, function()
						UIAnim.punch(card, 0.14)
						Remotes.get("PurchaseRequest"):FireServer("product", product.key)
					end)
					cardByKey[product.key] = card
					if product.kind == "Cash" then
						packCardByKey[product.key] = card
					end
					table.insert(cards, card)
				end
			end
		end
		trackGrid(grid, #products, aspect)
	end

	-- CASH --------------------------------------------------------------
	productSection("Cash", 20, MonetizationConfig.CashProducts, CASH_COLOR, CASH_ACCENT, ShopKit.Icons.Cash, function(product)
		return `${product.label}`
	end)

	-- SPEED -------------------------------------------------------------
	productSection("Speed", 30, MonetizationConfig.SpeedProducts, SPEED_COLOR, SPEED_ACCENT, ShopKit.Icons.Speed, function(product)
		return `+{product.label}`
	end)

	-- [trading-gifting-boards] GIFT: packs bought for another player. Its own
	-- module; hidden until a gift product id is configured.
	for _, card in require(script.Parent.GiftShopSection).build(list, 40) do
		table.insert(cards, card)
	end

	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.fromScale(0, 0)
	list.ScrollBarThickness = 6

	-- Pixel cells follow the panel: a resize, or the first real layout pass
	-- after a build while the panel was hidden, re-fits every section.
	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		for _, entry in fitted do
			fitGrid(entry.grid, entry.count, entry.aspect)
		end
	end)

	built = true
	ShopKit.cascadeIn(cards)
end

--- A card flashes when the thing it sells actually lands.
---
--- TOLD BY THE SERVER, NOT INFERRED FROM THE BALANCE.
--- The first attempt matched the size of the cash jump against the pack list,
--- which reads fine until you notice a late-game loot sale is comfortably worth
--- more than the small packs - the shop would have celebrated an ordinary sale
--- as a purchase. `PurchaseFeedback` is fired from inside ProcessReceipt, the one
--- path that actually granted something, and carries a key and nothing else.
local function celebrate(card: GuiObject?)
	if not card then
		return
	end
	ShopKit.shine(card)
	UIAnim.punch(card, 0.2)
end

--- The 2x Cash card becomes an OWNED state once they have it, rather than
--- continuing to sell something they cannot buy twice.
local function refreshOwnership(monetization: any)
	local card = cashPassCard
	if not card or not monetization then
		return
	end
	-- Painted card: once owned the whole print is greyed, a green check sits
	-- in its corner, and the card stops taking clicks. No text is laid over
	-- the art - the tint says "spent" on its own.
	local png = cashPassPng
	if png then
		local owns = monetization.ownsCashPass == true
		png.artwork.ImageColor3 = if owns then ART_OWNED_TINT else ART_LIVE_TINT
		if cashPassOwnedBadge then
			cashPassOwnedBadge.Visible = owns
		end
		png.setInteractive(not owns)
		return
	end
	if monetization.ownsCashPass and card:IsA("Frame") then
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
	require(script.Parent.Parent.StateStore).subscribe(function(state)
		buildShop()
		if not state then
			return
		end
		refreshOwnership(state.monetization)
		if built then
			paintCashAmounts(state.shop)
			require(script.Parent.GiftShopSection).update(state) -- [trading-gifting-boards]
		end

		-- Ownership is binary and permanent, so a false -> true flip is a real
		-- unlock and cannot be confused with anything else. No signal needed.
		local owns = state.monetization and state.monetization.ownsCashPass == true
		local wasOwned = lastOwnsCashPass
		lastOwnsCashPass = owns
		if wasOwned == false and owns then
			celebrate(cashPassCard)
		end
	end)

	Remotes.get("PurchaseFeedback").OnClientEvent:Connect(function(key)
		if type(key) == "string" then
			celebrate(cardByKey[key])
		end
	end)
end

return ShopController
