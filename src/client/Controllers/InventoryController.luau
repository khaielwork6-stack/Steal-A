--!strict
--[[
	InventoryController
	The Storage panel: unequipped loot, with DISPLAY and SELL per item.

	THIS IS A SKIN, NOT A SYSTEM
	Every button here calls the same InventoryRequest remote the old panel called.
	Storage capacity, upgrade pricing, item values, selling and equipping are all
	unchanged and still decided on the server. What changed is that none of the
	visuals are hand-built any more.

	WHERE THE VISUALS COME FROM
	The pack ships a "Sell" panel (MainUI.Frames.Sell) whose layout is exactly the
	shape Storage needs: a header with icon/title/action/close, and a scrolling
	list of cards with a thumbnail, three text rows and an action button. We clone
	that whole frame and repopulate it, so gradients, strokes, corners, studs
	overlays, fonts and proportions are the pack's, not ours.

	The template is MOVED OUT of Frames on startup. Anything in Frames is treated
	by the pack's own script as an openable panel, and a panel named "Sell" also
	means any button named "Sell" would open it - which is why the card action
	buttons below are named DisplayAction/SellAction rather than Display/Sell.

	OPENING AND CLOSING IS THE PACK'S JOB
	The panel lives in Frames and the opener button lives in Buttons, both named
	"Storage". The pack's script pairs a button with the frame of the same name
	and gives us its slide-up, blur, one-panel-at-a-time and close-button
	behaviour for free. We never animate the panel ourselves.
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

local panel: Frame? = nil
local scroll: ScrollingFrame? = nil
local cardTemplate: Frame? = nil
local titleLabel: TextLabel? = nil
local countLabel: TextLabel? = nil
local upgradeButton: TextButton? = nil
local upgradePrice: TextLabel? = nil
local openerBadge: TextLabel? = nil
local emptyState: Frame? = nil
local panelHome: UDim2 = UDim2.fromScale(0.5, 0.5)
local panelHomeTransparency = 0.4

local latestState: any = nil
local lastCapacity: number? = nil

-- ==========================================================
-- TEMPLATE HELPERS
-- ==========================================================

--- The pack names all three text rows of a card "Title" and distinguishes them
--- only by vertical position. Returns them top-to-bottom: name, variant, rarity.
local function cardRows(card: Frame): (TextLabel?, TextLabel?, TextLabel?)
	local body = card:FindFirstChild("Frame")
	if not body then
		return nil, nil, nil
	end
	local rows: { TextLabel } = {}
	for _, child in body:GetChildren() do
		if child:IsA("TextLabel") and child.Name == "Title" then
			table.insert(rows, child)
		end
	end
	table.sort(rows, function(a, b)
		return a.Position.Y.Scale < b.Position.Y.Scale
	end)
	return rows[1], rows[2], rows[3]
end

--- Strips a label's rainbow/demo gradient so a flat colour actually shows.
local function flatten(label: TextLabel?, color: Color3)
	if not label then
		return
	end
	local gradient = label:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient:Destroy()
	end
	label.TextColor3 = color
end

--- Recolours one of the pack's action buttons without rebuilding it, so the
--- stroke, studs overlay and proportions stay exactly as authored.
local function tintButton(button: TextButton, base: Color3, top: Color3, bottom: Color3)
	button.BackgroundColor3 = base
	local body = button:FindFirstChild("Frame")
	if body and body:IsA("GuiObject") then
		local gradient = body:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = ColorSequence.new(top, bottom)
		end
	end
end

--- The pack's action button carries a Robux cross-sell ("R$167" plus a
--- strike-through Line). Storage has no Robux path, so both go.
local function stripPromo(button: TextButton)
	local body = button:FindFirstChild("Frame")
	if not body then
		return
	end
	for _, name in { "Promo", "Line" } do
		local extra = body:FindFirstChild(name)
		if extra then
			extra:Destroy()
		end
	end
end

local function priceLabel(button: TextButton): TextLabel?
	local body = button:FindFirstChild("Frame")
	local label = body and body:FindFirstChild("Price")
	return if label and label:IsA("TextLabel") then label else nil
end

-- ==========================================================
-- CARDS
-- ==========================================================

local function buildCard(item: any, index: number): Frame?
	local template = cardTemplate
	if not template then
		return nil
	end

	local def = LootConfig.ById[item.ItemId]
	local rarity = item.Rarity or "Common"
	local rarityColor = RarityConfig.Colors[rarity] or Color3.fromRGB(198, 205, 216)

	local card = template:Clone()
	card.Name = item.InstanceId
	card.Visible = true
	card.LayoutOrder = index

	local nameRow, variantRow, rarityRow = cardRows(card)
	flatten(nameRow, Color3.fromRGB(255, 255, 255))
	flatten(variantRow, Color3.fromRGB(206, 216, 232))
	flatten(rarityRow, rarityColor)

	if nameRow then
		nameRow.Text = if def then def.name else item.ItemId
	end
	if rarityRow then
		rarityRow.Text = string.upper(rarity)
	end
	if variantRow then
		-- Only worth a row when the item actually rolled something unusual.
		local tags = {}
		if item.Size and item.Size ~= "Normal" then
			table.insert(tags, string.upper(item.Size))
		end
		if item.Mutation and item.Mutation ~= "Normal" then
			table.insert(tags, string.upper(item.Mutation))
		end
		variantRow.Text = if #tags > 0 then table.concat(tags, " - ") else "NORMAL"
	end

	local body = card:FindFirstChild("Frame")
	local thumbHolder = body and body:FindFirstChild("BrainrotFrame")
	local slot = thumbHolder and thumbHolder:FindFirstChild("1")
	if slot and slot:IsA("GuiObject") then
		local stroke = slot:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = rarityColor
			stroke.Thickness = 2
		end
		local inner = slot:FindFirstChild("Frame")

		-- The pack's thumbnail ships a demo creature. There is no per-item art in
		-- the project yet - loot and trophies are both a Placeholder part tinted
		-- by rarity (see LootService/BaseService) - so the swatch below shows the
		-- item's ACTUAL in-world colour rather than borrowed demo artwork. Drop
		-- real models in later and this is the one place to swap.
		local icon = inner and inner:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			icon.Image = ""
			icon.BackgroundTransparency = 0
			icon.BackgroundColor3 = rarityColor
			if not icon:FindFirstChildOfClass("UICorner") then
				local round = Instance.new("UICorner")
				round.CornerRadius = UDim.new(0.18, 0)
				round.Parent = icon
			end
			if not icon:FindFirstChildOfClass("UIStroke") then
				local edge = Instance.new("UIStroke")
				edge.Thickness = 2
				edge.Color = Color3.fromRGB(18, 20, 26)
				edge.Parent = icon
			end
		end

		local earns = inner and inner:FindFirstChild("Earns")
		if earns and earns:IsA("TextLabel") then
			local gradient = earns:FindFirstChildOfClass("UIGradient")
			if gradient then
				gradient:Destroy()
			end
			earns.TextColor3 = Color3.fromRGB(126, 255, 148)
			earns.Text = NumberFormat.income(item.FinalIncome)
		end
	end

	-- Two actions where the pack had one price button. Cloning it keeps the
	-- pack's stroke/gradient/studs treatment on both.
	local choose = body and body:FindFirstChild("Choose")
	local money = choose and choose:FindFirstChild("Money")
	if choose and money and money:IsA("TextButton") then
		local sell = money:Clone()

		-- Deliberately NOT "Display"/"Sell": the pack opens the panel in Frames
		-- whose name matches a clicked button, and a button named "Sell" would
		-- reopen the template panel.
		money.Name = "DisplayAction"
		money.LayoutOrder = 1
		stripPromo(money)
		tintButton(money, Color3.fromRGB(0, 158, 40), Color3.fromRGB(120, 240, 130), Color3.fromRGB(0, 150, 40))
		local displayText = priceLabel(money)
		if displayText then
			displayText.Text = "DISPLAY"
		end
		money.Activated:Connect(function()
			Remotes.get("InventoryRequest"):FireServer("equip", item.InstanceId)
		end)

		sell.Name = "SellAction"
		sell.LayoutOrder = 2
		sell.Parent = choose
		stripPromo(sell)
		tintButton(sell, Color3.fromRGB(168, 30, 38), Color3.fromRGB(255, 108, 112), Color3.fromRGB(170, 24, 32))
		local sellText = priceLabel(sell)
		if sellText then
			sellText.Text = "SELL"
		end
		sell.Activated:Connect(function()
			Remotes.get("InventoryRequest"):FireServer("sell", item.InstanceId)
		end)
	end

	return card
end

-- ==========================================================
-- REFRESH
-- ==========================================================

local function clearList()
	local list = scroll
	if not list then
		return
	end
	for _, child in list:GetChildren() do
		-- Keep the layout and the one empty-state frame; everything else in here
		-- is a generated card. Filtering on what to KEEP means a future change of
		-- row class cannot start leaking rows again.
		if not child:IsA("UILayout") and child ~= emptyState then
			child:Destroy()
		end
	end
end

local function refresh(state: any)
	latestState = state
	local frame = panel
	if not frame or not state then
		return
	end

	local used = state.storageUsed or 0
	local capacity = state.storageCapacity or 10

	if countLabel then
		UIAnim.countTo(countLabel, capacity, function(value: number)
			return `{used}/{math.floor(value + 0.5)}`
		end)
		if lastCapacity and capacity > lastCapacity then
			UIAnim.punch(countLabel, 0.25)
		end
	end
	lastCapacity = capacity

	if upgradeButton and upgradePrice then
		local cost = state.storageNextCost
		if cost then
			upgradeButton.Visible = true
			upgradePrice.Text = `+ STORAGE  {NumberFormat.cash(cost)}`
			-- Dim when unaffordable rather than hiding: the player should see the
			-- next tier exists and what it costs.
			local affordable = (state.cash or 0) >= cost
			upgradeButton.BackgroundTransparency = if affordable then 0 else 0.35
			if upgradePrice then
				upgradePrice.TextTransparency = if affordable then 0 else 0.35
			end
		else
			upgradeButton.Visible = false
		end
	end

	if not frame.Visible then
		return -- the pack owns visibility; do not build rows behind a closed panel
	end

	clearList()

	local inventory = state.inventory or {}
	for index, item in inventory do
		local card = buildCard(item, index)
		if card then
			card.Parent = scroll
		end
	end

	if emptyState then
		emptyState.Visible = #inventory == 0
	end
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- Moves the pack's Sell panel out of Frames and returns it. Anything left in
--- Frames is an openable panel as far as the pack is concerned, and this one is
--- a template.
local function takeTemplate(ui: ScreenGui): Frame?
	local frames = ui:FindFirstChild("Frames")
	if not frames then
		return nil
	end

	local templates = ui:FindFirstChild("Templates")
	if not templates then
		local folder = Instance.new("Folder")
		folder.Name = "Templates"
		folder.Parent = ui
		templates = folder
	end

	local sell = frames:FindFirstChild("Sell") or templates:FindFirstChild("Sell")
	if not sell or not sell:IsA("Frame") then
		return nil
	end
	sell.Visible = false
	sell.Parent = templates
	return sell
end

local function buildPanel(ui: ScreenGui, template: Frame)
	local frames = ui:FindFirstChild("Frames") :: Instance

	local built = template:Clone()
	built.Name = "Storage"
	built.Visible = false

	local top = built:FindFirstChild("Top")
	local header = top and top:FindFirstChild("Frame")
	local list = built:FindFirstChild("ScrollingFrame")
	if not header or not list or not list:IsA("ScrollingFrame") then
		warn("[InventoryController] Sell template hierarchy unexpected - Storage not built.")
		return
	end

	-- ---------- header ----------
	local title = header:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = "Storage"
		title.Size = UDim2.fromScale(0.26, 0.6)
		title.Position = UDim2.fromScale(0.30, 0.5)
		titleLabel = title

		-- Capacity gets its own label so it can animate independently, cloned
		-- from the title so it inherits the pack's font, stroke and sizing.
		local count = title:Clone()
		count.Name = "Count"
		count.Text = "0/10"
		count.Size = UDim2.fromScale(0.14, 0.5)
		count.Position = UDim2.fromScale(0.50, 0.5)
		count.Parent = header
		countLabel = count
	end

	local upgrade = header:FindFirstChild("SellAll")
	if upgrade and upgrade:IsA("TextButton") then
		upgrade.Name = "UpgradeStorage"
		-- Wider than SELL ALL was: it has to carry a formatted price.
		upgrade.Size = UDim2.fromScale(0.30, 0.75)
		upgrade.Position = UDim2.fromScale(0.70, 0.5)
		local aspect = upgrade:FindFirstChildOfClass("UIAspectRatioConstraint")
		if aspect then
			aspect:Destroy() -- the price text needs a free width
		end
		upgradeButton = upgrade
		upgradePrice = priceLabel(upgrade)
		if upgradePrice then
			upgradePrice.Text = "+ STORAGE"
		end
		upgrade.Activated:Connect(function()
			Remotes.get("InventoryRequest"):FireServer("upgradeStorage")
		end)
	end

	-- ---------- list ----------
	local layout = list:FindFirstChildOfClass("UIListLayout")

	-- The pack ships four demo cards; keep the first as our template and drop
	-- the rest along with the zero-size spacer.
	local kept: Frame? = nil
	for _, child in list:GetChildren() do
		if child:IsA("Frame") then
			if child.Name == "Brainrot" and not kept then
				kept = child
			else
				child:Destroy()
			end
		end
	end
	if kept then
		kept.Name = "CardTemplate"
		kept.Visible = false
		kept.Parent = ui:FindFirstChild("Templates")
		cardTemplate = kept
	end

	-- ---------- empty state ----------
	-- Built from the card's own body so it sits on the pack's panel rather than
	-- floating as bare text, but it is ONE frame that is shown or hidden - never
	-- one per unused slot.
	local empty = Instance.new("Frame")
	empty.Name = "EmptyState"
	empty.BackgroundTransparency = 1
	empty.Size = UDim2.fromScale(1, 0.28)
	empty.Visible = false
	empty.LayoutOrder = -1
	empty.Parent = list

	local emptyTitle = Instance.new("TextLabel")
	emptyTitle.BackgroundTransparency = 1
	emptyTitle.Size = UDim2.fromScale(0.9, 0.34)
	emptyTitle.Position = UDim2.fromScale(0.5, 0.34)
	emptyTitle.AnchorPoint = Vector2.new(0.5, 0.5)
	emptyTitle.Font = Enum.Font.FredokaOne
	emptyTitle.TextScaled = true
	emptyTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
	emptyTitle.Text = "Nothing Stored"
	emptyTitle.Parent = empty
	local emptyStroke = Instance.new("UIStroke")
	emptyStroke.Thickness = 2
	emptyStroke.Color = Color3.fromRGB(0, 0, 0)
	emptyStroke.Parent = emptyTitle

	local emptyHint = Instance.new("TextLabel")
	emptyHint.BackgroundTransparency = 1
	emptyHint.Size = UDim2.fromScale(0.86, 0.2)
	emptyHint.Position = UDim2.fromScale(0.5, 0.66)
	emptyHint.AnchorPoint = Vector2.new(0.5, 0.5)
	emptyHint.Font = Enum.Font.FredokaOne
	emptyHint.TextScaled = true
	emptyHint.TextWrapped = true
	emptyHint.TextColor3 = Color3.fromRGB(198, 214, 236)
	emptyHint.Text = "Store one of your displayed items to keep it here."
	emptyHint.Parent = empty
	emptyState = empty

	-- Canvas grows with the content. Measured in pixels from the layout, which
	-- stays correct with the pack's scale-sized cards at any item count.
	if layout then
		local function resize()
			list.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
		end
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize)
		resize()
	end
	list.ScrollBarThickness = 6
	scroll = list

	-- Rows are only built while open, so build them the moment the pack opens it.
	built:GetPropertyChangedSignal("Visible"):Connect(function()
		if built.Visible then
			refresh(latestState)
		end
	end)

	-- Remembered before the pack ever touches it, so the fallback opener below
	-- can restore exactly this resting state.
	panelHome = built.Position
	panelHomeTransparency = built.BackgroundTransparency

	built.Parent = frames
	panel = built
end

-- ==========================================================
-- FALLBACK OPEN / CLOSE
-- ==========================================================
-- Only used if the pack declines to adopt our button. The motion deliberately
-- mirrors the pack's own: slide up from below the screen with a Back ease, fade
-- the backdrop in, and blur the world behind.

local function screenBlur(): BlurEffect?
	local Lighting = game:GetService("Lighting")
	local existing = Lighting:FindFirstChild("UIBlur")
	return if existing and existing:IsA("BlurEffect") then existing else nil
end

local function slideOffset(frame: Frame): number
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize.Y else 1080
	local below = math.max(0, viewport - frame.AbsolutePosition.Y)
	return below + frame.AbsoluteSize.Y + 60
end

local function fallbackSetOpen(open: boolean)
	local frame = panel
	if not frame then
		return
	end
	local TweenService = game:GetService("TweenService")
	local blur = screenBlur()

	if open then
		if frame.Visible then
			return
		end
		frame.Visible = true
		frame.BackgroundTransparency = 1
		frame.Position = panelHome + UDim2.fromOffset(0, slideOffset(frame))
		TweenService:Create(frame, UIAnim.GROW, { Position = panelHome }):Play()
		TweenService:Create(
			frame,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = panelHomeTransparency }
		):Play()
		if blur then
			TweenService:Create(blur, TweenInfo.new(0.3), { Size = 18 }):Play()
		end
	else
		if not frame.Visible then
			return
		end
		local slide = TweenService:Create(
			frame,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = panelHome + UDim2.fromOffset(0, slideOffset(frame)), BackgroundTransparency = 1 }
		)
		slide:Play()
		slide.Completed:Once(function()
			frame.Visible = false
			frame.Position = panelHome
		end)
		if blur then
			TweenService:Create(blur, TweenInfo.new(0.25), { Size = 0 }):Play()
		end
	end
end

--- Binds our own open/close, but ONLY if the pack has not claimed the button.
--- Checked rather than assumed: the pack marks what it owns, and if it does own
--- the button then binding here as well would toggle the panel twice per click.
local function ensureOpenerWorks(opener: TextButton)
	task.delay(1.5, function()
		if not opener.Parent or opener:GetAttribute("_UIHandlerSetup") == true then
			return -- the pack adopted it; leave well alone
		end

		warn("[InventoryController] pack did not bind the Storage button - using the built-in opener.")
		UIAnim.bindButton(opener)
		opener.Activated:Connect(function()
			fallbackSetOpen(not (panel and panel.Visible))
		end)

		local frame = panel
		local top = frame and frame:FindFirstChild("Top")
		local header = top and top:FindFirstChild("Frame")
		local close = header and header:FindFirstChild("Close")
		if close and close:IsA("GuiButton") then
			close.Activated:Connect(function()
				fallbackSetOpen(false)
			end)
		end
	end)
end

--- The opener, cloned from a pack menu button so it matches Shop/Index/Settings
--- exactly. Named "Storage" so the pack pairs it with the panel automatically.
local function buildOpener(ui: ScreenGui)
	local buttons = ui:FindFirstChild("Buttons")
	local left = buttons and buttons:FindFirstChild("Left")
	-- Cloned from Index, not Shop. Every colour on these buttons is authored as a
	-- set - outer fill, inner gradient AND an inner UIStroke - and Shop's inner
	-- stroke is gold. Recolouring the fill alone left a yellow outline ringing
	-- the icon. Index is already the blue variant, so nothing needs recolouring.
	local source = left and left:FindFirstChild("Index")
	if not left or not source or not source:IsA("TextButton") then
		warn("[InventoryController] pack menu buttons not found - Storage opener not built.")
		return
	end

	if left:FindFirstChild("Storage") then
		return
	end

	local opener = source:Clone()
	opener.Name = "Storage"
	opener.LayoutOrder = 4

	-- CRITICAL: the pack stamps every button it wires with _UIHandlerSetup and
	-- skips anything already carrying it. We clone at client start, by which
	-- time the source button has been stamped, so the clone inherits it and the
	-- pack silently refuses to bind our button - it animates on hover but the
	-- click opens nothing. Clear both stamps so the pack adopts it as new.
	opener:SetAttribute("_UIHandlerSetup", nil)
	opener:SetAttribute("AnimBound", nil)
	-- A ripple container and a mid-animation scale can also come along for the
	-- ride if the source button was clicked before we cloned it.
	local staleRipple = opener:FindFirstChild("_RippleContainer")
	if staleRipple then
		staleRipple:Destroy()
	end
	local scale = opener:FindFirstChildOfClass("UIScale")
	if scale then
		scale.Scale = 1
	end

	local label = opener:FindFirstChild("Title")
	if label and label:IsA("TextLabel") then
		label.Text = "Storage"
	end

	local body = opener:FindFirstChild("Frame")
	local icon = body and body:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		-- Reuse the icon the pack already ships on this panel's header.
		icon.Image = "rbxassetid://112931960147028"
	end

	-- A count badge so a full storage is obvious without opening the panel.
	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, 4, 0, -4)
	badge.Size = UDim2.fromScale(0.42, 0.32)
	badge.BackgroundColor3 = Color3.fromRGB(255, 176, 46)
	badge.Font = Enum.Font.FredokaOne
	badge.TextScaled = true
	badge.TextColor3 = Color3.fromRGB(40, 28, 8)
	badge.Text = "0"
	badge.ZIndex = 6
	badge.Visible = false
	badge.Parent = opener
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0.35, 0)
	badgeCorner.Parent = badge
	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Thickness = 2
	badgeStroke.Color = Color3.fromRGB(20, 22, 30)
	badgeStroke.Parent = badge
	openerBadge = badge

	opener.Parent = left
	ensureOpenerWorks(opener)
end

function InventoryController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		warn("[InventoryController] MainUI not found - Storage disabled.")
		return
	end

	local template = takeTemplate(ui)
	if not template then
		warn("[InventoryController] Frames.Sell not found - Storage disabled.")
		return
	end

	-- Panel first: the pack matches a button to a frame by name when the button
	-- is registered, so the frame has to exist before the opener appears.
	buildPanel(ui, template)
	buildOpener(ui)

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		local previous = latestState and latestState.storageUsed
		refresh(state)

		if openerBadge then
			local used = state.storageUsed or 0
			local capacity = state.storageCapacity or 10
			-- Nothing stored means nothing to badge; an always-on "0" is just
			-- clutter sitting on the icon.
			openerBadge.Visible = used > 0
			openerBadge.Text = tostring(used)
			openerBadge.BackgroundColor3 = if used >= capacity
				then Color3.fromRGB(230, 76, 76)
				else Color3.fromRGB(255, 176, 46)
			if previous and used ~= previous and used > 0 then
				UIAnim.punch(openerBadge, 0.3)
			end
		end
	end)
end

return InventoryController
