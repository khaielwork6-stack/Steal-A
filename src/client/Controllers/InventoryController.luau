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
local UserInputService = game:GetService("UserInputService")

local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local ModelPreview = require(ReplicatedStorage.Shared.Util.ModelPreview)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local PvPConfig = require(ReplicatedStorage.Shared.Config.PvPConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local InventoryController = {}

local player = Players.LocalPlayer

--- Card geometry, as fractions of the row unless noted. The pack's demo row was
--- a 4:1 aspect-locked stamp that used about a fifth of the panel; these give it
--- the full width of the list with a thumbnail, a readable text column and a
--- proper button column. All of it is here so the row can be retuned in one
--- place rather than hunted through buildCard.
local CARD = {
	WIDTH = 0.96, -- of the ScrollingFrame
	HEIGHT = 0.30, -- of the ScrollingFrame: about three rows visible at once
	THUMB_LEFT = 0.025,
	THUMB_HEIGHT = 0.80,
	TEXT_LEFT = 0.24,
	TEXT_WIDTH = 0.40,
	ACTION_WIDTH = 0.30,
	NAME_TEXT = 20,
	SUB_TEXT = 14,
}

--- How a card's text rows size themselves. Desktop keeps the fixed sizes the
--- card was tuned at. On touch the panel is a fraction of that height, so a
--- fixed 20px name overflowed its row and every tag ended in "..." - the rows
--- scale to fit instead, bounded above by the same sizes.
local function fitRowText(row: TextLabel, size: number)
	if Device.isTouch() then
		row.TextScaled = true
		local limit = row:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
		limit.MinTextSize = 9
		limit.MaxTextSize = size
		limit.Parent = row
	else
		row.TextScaled = false
		row.TextSize = size
	end
end

--- Short forms of the card tags for a phone's narrow text column. Same
--- meaning, fewer characters; the desktop wording is untouched.
local function shortTag(long: string, short: string): string
	return if Device.isPhone() then short else long
end

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

--- THREE PAGES IN ONE WINDOW. ITEMS is the Storage that always existed:
--- limited capacity, DISPLAY and SELL. GUARDIANS and WEAPONS are permanent
--- collections - Game Pass unlocks and the Bat - with EQUIP only, never a
--- Sell, and they never count against the item capacity: buying a Guardian
--- must never turn 0/10 into 1/10.
type Tab = "Items" | "Guardians" | "Weapons"
local TABS: { Tab } = { "Items", "Guardians", "Weapons" }
local activeTab: Tab = "Items"
local tabButtons: { [string]: TextButton } = {}
local emptyTitleLabel: TextLabel? = nil
local emptyHintLabel: TextLabel? = nil

local EQUIPPED_GREEN = Color3.fromRGB(120, 255, 160)
local PLATE_COLOR = Color3.fromRGB(28, 32, 44)

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

--- Lays the pack's one price button out as a two-button column down the
--- right-hand third of a card and returns both, labelled, claimed and ready
--- to wire. Cloning keeps the pack's stroke/gradient/studs on both. The
--- names are deliberately not "Display"/"Sell": the pack opens the panel in
--- Frames whose name matches a clicked button, and a button named "Sell"
--- would reopen the template panel.
local function layoutActions(card: Frame, primaryLabel: string, secondaryLabel: string): (TextButton?, TextButton?)
	local body = card:FindFirstChild("Frame")
	local choose = body and body:FindFirstChild("Choose")
	local money = choose and choose:FindFirstChild("Money")
	if not choose or not money or not money:IsA("TextButton") then
		return nil, nil
	end
	local second = money:Clone()

	-- The pack's demo stacked two tiny buttons in the middle of the card. Give
	-- the pair a real column down the right-hand third instead.
	choose.AnchorPoint = Vector2.new(1, 0.5)
	choose.Position = UDim2.fromScale(0.975, 0.5)
	choose.Size = UDim2.fromScale(CARD.ACTION_WIDTH, 0.84)
	local chooseLayout = choose:FindFirstChildOfClass("UIListLayout")
	if chooseLayout then
		chooseLayout.FillDirection = Enum.FillDirection.Vertical
		chooseLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		chooseLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		chooseLayout.Padding = UDim.new(0.08, 0)
		chooseLayout.SortOrder = Enum.SortOrder.LayoutOrder
	end

	local function dressAction(button: TextButton, label: string, order: number)
		button.LayoutOrder = order
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Size = UDim2.fromScale(1, 0.44)
		-- The pack locked these to 3:1. In a full-width column that squashes
		-- them back to demo size, so the column decides the shape now.
		local aspect = button:FindFirstChildOfClass("UIAspectRatioConstraint")
		if aspect then
			aspect:Destroy()
		end
		stripPromo(button)
		local text = priceLabel(button)
		if text then
			text.Text = label
			text.Size = UDim2.fromScale(0.92, 0.62)
			text.TextScaled = true
		end
		-- The reason both of these did nothing: a pack button ships
		-- Active = false and pre-stamped, so Activated never fired and
		-- bindButton skipped it. See UIAnim.claimButton.
		UIAnim.claimButton(button)
	end

	money.Name = "PrimaryAction"
	dressAction(money, primaryLabel, 1)
	second.Name = "SecondaryAction"
	second.Parent = choose
	dressAction(second, secondaryLabel, 2)
	return money, second
end

--- A fresh, empty card in the list's geometry with its three text rows
--- flattened and placed. Returns the card and its rows: name, variant, tag.
local function blankCard(name: string, index: number): (Frame?, TextLabel?, TextLabel?, TextLabel?)
	local template = cardTemplate
	if not template then
		return nil, nil, nil, nil
	end
	local card = template:Clone()
	card.Name = name
	card.Visible = true
	card.LayoutOrder = index
	local cardAspect = card:FindFirstChildOfClass("UIAspectRatioConstraint")
	if cardAspect then
		cardAspect:Destroy()
	end
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Size = UDim2.fromScale(CARD.WIDTH, CARD.HEIGHT)

	local nameRow, variantRow, tagRow = cardRows(card)
	local function placeRow(row: TextLabel?, y: number, height: number, size: number)
		if not row then
			return
		end
		row.AnchorPoint = Vector2.new(0, 0.5)
		row.Position = UDim2.fromScale(CARD.TEXT_LEFT, y)
		row.Size = UDim2.fromScale(CARD.TEXT_WIDTH, height)
		row.TextXAlignment = Enum.TextXAlignment.Left
		fitRowText(row, size)
		row.TextTruncate = Enum.TextTruncate.AtEnd
		row.RichText = false
	end
	placeRow(nameRow, 0.27, 0.30, CARD.NAME_TEXT)
	placeRow(variantRow, 0.56, 0.24, CARD.SUB_TEXT)
	placeRow(tagRow, 0.80, 0.24, CARD.SUB_TEXT)
	return card, nameRow, variantRow, tagRow
end

--- The card's thumbnail as a dark plate with the REAL model turning inside
--- it (ModelPreview), edged in `stroke`. `earns` is the small caption the
--- pack prints under the thumbnail; nil hides it.
local function previewPlate(card: Frame, source: Model?, yaw: number, stroke: Color3, earns: string?)
	local body = card:FindFirstChild("Frame")
	local thumbHolder = body and body:FindFirstChild("BrainrotFrame")
	local slot = thumbHolder and thumbHolder:FindFirstChild("1")
	if not slot or not slot:IsA("GuiObject") then
		return
	end
	slot.AnchorPoint = Vector2.new(0, 0.5)
	slot.Position = UDim2.fromScale(CARD.THUMB_LEFT, 0.5)
	slot.Size = UDim2.fromScale(1, CARD.THUMB_HEIGHT)
	local slotAspect = slot:FindFirstChildOfClass("UIAspectRatioConstraint")
	if slotAspect then
		slotAspect.AspectRatio = 1
		slotAspect.DominantAxis = Enum.DominantAxis.Height
	end
	local edge = slot:FindFirstChildOfClass("UIStroke")
	if edge then
		edge.Color = stroke
		edge.Thickness = 2
	end
	local inner = slot:FindFirstChild("Frame")
	local icon = inner and inner:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon.Image = ""
		icon.ImageTransparency = 0
		icon.BackgroundTransparency = 0
		icon.BackgroundColor3 = PLATE_COLOR
		if not icon:FindFirstChildOfClass("UICorner") then
			local round = Instance.new("UICorner")
			round.CornerRadius = UDim.new(0.18, 0)
			round.Parent = icon
		end
		if source then
			ModelPreview.mount(icon, source, { faceYaw = yaw, fit = 1.1 })
		end
	end
	local caption = inner and inner:FindFirstChild("Earns")
	if caption and caption:IsA("TextLabel") then
		local gradient = caption:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient:Destroy()
		end
		caption.Visible = earns ~= nil
		caption.Text = earns or ""
		caption.TextColor3 = EQUIPPED_GREEN
	end
end

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

	-- The pack's demo row was locked to a 4:1 aspect and sized off its HEIGHT, so
	-- it collapsed to a stamp in the corner of a panel it should fill. Drop the
	-- lock and give the row the full width of the list.
	local cardAspect = card:FindFirstChildOfClass("UIAspectRatioConstraint")
	if cardAspect then
		cardAspect:Destroy()
	end
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Size = UDim2.fromScale(CARD.WIDTH, CARD.HEIGHT)

	local nameRow, variantRow, rarityRow = cardRows(card)
	flatten(nameRow, Color3.fromRGB(255, 255, 255))
	flatten(variantRow, Color3.fromRGB(206, 216, 232))
	flatten(rarityRow, rarityColor)

	-- One left-aligned text column between the thumbnail and the action buttons,
	-- rather than three half-width labels floating in the middle of the card.
	local function placeRow(row: TextLabel?, y: number, height: number, size: number)
		if not row then
			return
		end
		row.AnchorPoint = Vector2.new(0, 0.5)
		row.Position = UDim2.fromScale(CARD.TEXT_LEFT, y)
		row.Size = UDim2.fromScale(CARD.TEXT_WIDTH, height)
		row.TextXAlignment = Enum.TextXAlignment.Left
		fitRowText(row, size)
		row.TextTruncate = Enum.TextTruncate.AtEnd
		row.RichText = false
	end
	placeRow(nameRow, 0.27, 0.30, CARD.NAME_TEXT)
	placeRow(variantRow, 0.56, 0.24, CARD.SUB_TEXT)
	placeRow(rarityRow, 0.80, 0.24, CARD.SUB_TEXT)

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
		-- A square thumbnail pinned to the left edge, sized off the row height so
		-- it scales with the card rather than with the panel width.
		slot.AnchorPoint = Vector2.new(0, 0.5)
		slot.Position = UDim2.fromScale(CARD.THUMB_LEFT, 0.5)
		slot.Size = UDim2.fromScale(1, CARD.THUMB_HEIGHT)
		local slotAspect = slot:FindFirstChildOfClass("UIAspectRatioConstraint")
		if slotAspect then
			slotAspect.AspectRatio = 1
			slotAspect.DominantAxis = Enum.DominantAxis.Height
		end

		local stroke = slot:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = rarityColor
			stroke.Thickness = 2
		end
		local inner = slot:FindFirstChild("Frame")

		-- The pack's thumbnail ships a demo creature. ItemThumb owns what a card
		-- shows instead, and is the single swap point for real per-item art.
		local icon = inner and inner:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			ItemThumb.apply(icon, rarity, item.ItemId)
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

	-- Two actions where the pack had one price button: DISPLAY and SELL.
	local display, sell = layoutActions(card, "DISPLAY", "SELL")
	if display and sell then
		display.Name = "DisplayAction"
		tintButton(display, Color3.fromRGB(0, 158, 40), Color3.fromRGB(120, 240, 130), Color3.fromRGB(0, 150, 40))
		display.Activated:Connect(function()
			Remotes.get("InventoryRequest"):FireServer("equip", item.InstanceId)
		end)

		sell.Name = "SellAction"
		tintButton(sell, Color3.fromRGB(168, 30, 38), Color3.fromRGB(255, 108, 112), Color3.fromRGB(170, 24, 32))
		sell.Activated:Connect(function()
			Remotes.get("InventoryRequest"):FireServer("sell", item.InstanceId)
		end)
	end

	return card
end

--- EQUIP / EQUIPPED on the primary button, UNEQUIP on the second while the
--- thing is equipped. There is no Sell on either of these pages, anywhere.
local function wireEquip(card: Frame, equipped: boolean, canUnequip: boolean, onEquip: () -> (), onUnequip: (() -> ())?)
	local primary, secondary = layoutActions(card, if equipped then "EQUIPPED" else "EQUIP", "UNEQUIP")
	if not primary or not secondary then
		return
	end
	if equipped then
		-- Inert and quiet: the state is the label.
		tintButton(primary, Color3.fromRGB(70, 80, 100), Color3.fromRGB(160, 172, 196), Color3.fromRGB(96, 108, 136))
		primary.AutoButtonColor = false
	else
		tintButton(primary, Color3.fromRGB(0, 158, 40), Color3.fromRGB(120, 240, 130), Color3.fromRGB(0, 150, 40))
		primary.Activated:Connect(function()
			UIAnim.punch(card, 0.04)
			onEquip()
		end)
	end
	if equipped and canUnequip and onUnequip then
		tintButton(secondary, Color3.fromRGB(46, 70, 150), Color3.fromRGB(140, 170, 255), Color3.fromRGB(60, 90, 200))
		secondary.Activated:Connect(function()
			UIAnim.punch(card, 0.04)
			onUnequip()
		end)
	else
		secondary.Visible = false
	end
	local stroke = card:FindFirstChildOfClass("UIStroke")
	if stroke and equipped then
		-- Colour only, never the thickness (the pack's fractional-pixel
		-- stroke trap; see ShopKit).
		stroke.Color = EQUIPPED_GREEN
	end
end

local function guardianSource(def: BaseGuardianConfig.GuardianDef): Model?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local folder = assets and assets:FindFirstChild("BaseGuardians")
	local model = folder and folder:FindFirstChild(def.modelName)
	return if model and model:IsA("Model") then model else nil
end

local function weaponSource(name: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local folder = assets and assets:FindFirstChild("Weapons")
	local model = folder and folder:FindFirstChild(name)
	return if model and model:IsA("Model") then model else nil
end

--- One owned Guardian: the real animal turning on a plate, its name, and
--- EQUIP / EQUIPPED / UNEQUIP. Never a price, never a Sell.
local function buildGuardianCard(def: BaseGuardianConfig.GuardianDef, equipped: boolean, index: number): Frame?
	local card, nameRow, variantRow, tagRow = blankCard(`Guardian_{def.key}`, index)
	if not card then
		return nil
	end
	flatten(nameRow, Color3.fromRGB(255, 255, 255))
	flatten(variantRow, Color3.fromRGB(206, 216, 232))
	flatten(tagRow, if equipped then EQUIPPED_GREEN else def.color)
	if nameRow then
		nameRow.Text = `{string.upper(def.name)} GUARDIAN`
	end
	if variantRow then
		variantRow.Text = def.tagline
	end
	if tagRow then
		tagRow.Text = if equipped then shortTag("ON GUARD AT YOUR BASE", "ON GUARD") else shortTag("PERMANENT", "OWNED")
	end

	previewPlate(card, guardianSource(def), ModelPreview.yawFor(def.faceLocal), if equipped then EQUIPPED_GREEN else def.accent, if equipped then "EQUIPPED" else nil)

	wireEquip(card, equipped, true, function()
		Remotes.get("GuardianRequest"):FireServer("equip", def.key)
	end, function()
		Remotes.get("GuardianRequest"):FireServer("unequip")
	end)
	return card
end

--- One owned weapon (the Bat always, the Slap once bought). One of the two
--- is always equipped, so there is no UNEQUIP: choosing the other is the
--- way to put this one down.
local function buildWeaponCard(name: string, equipped: boolean, index: number): Frame?
	local def = PvPConfig.Weapons[name]
	local card, nameRow, variantRow, tagRow = blankCard(`Weapon_{name}`, index)
	if not card or not def then
		return nil
	end
	local accent = if name == "Slap" then Color3.fromRGB(255, 176, 92) else Color3.fromRGB(196, 150, 96)
	flatten(nameRow, Color3.fromRGB(255, 255, 255))
	flatten(variantRow, Color3.fromRGB(206, 216, 232))
	flatten(tagRow, if equipped then EQUIPPED_GREEN else accent)
	if nameRow then
		nameRow.Text = string.upper(name)
	end
	if variantRow then
		variantRow.Text = if name == "Slap" then "SLAP PLAYERS AWAY" else "KNOCK LOOT LOOSE"
	end
	if tagRow then
		tagRow.Text = if equipped
			then shortTag("IN YOUR HOTBAR", "EQUIPPED")
			else (if def.gamePass then shortTag("PERMANENT", "OWNED") else shortTag("STARTER WEAPON", "STARTER"))
	end

	previewPlate(card, weaponSource(name), 0, if equipped then EQUIPPED_GREEN else accent, if equipped then "EQUIPPED" else nil)

	wireEquip(card, equipped, false, function()
		Remotes.get("WeaponRequest"):FireServer("equip", name)
	end, nil)
	return card
end

-- ==========================================================
-- REFRESH
-- ==========================================================

--- What the row list was last built from. Anything that changes how a row is
--- drawn is in here; anything that is not (cash, capacity) is deliberately
--- left out so it cannot force a rebuild.
local builtSignature: string? = nil

-- ==========================================================
-- STABLE SLOTS
-- ==========================================================
--
-- WHY THE LIST USED TO JUMP. Every rebuild popped each card in through a
-- UIScale tween (0.85 -> 1 with an overshoot, staggered per card), and a
-- UIListLayout positions children from their live AbsoluteSize - which a
-- UIScale changes. So as each card swelled, every card below it slid, then
-- bounced back on the overshoot, thirty milliseconds apart down the column.
-- On top of that the whole list was torn down and re-cloned on any change,
-- so even the cards that had not changed flickered.
--
-- Now each card lives inside a CanvasGroup of FIXED size that the layout
-- positions. The card's entrance is a fade on the group - no scale, no
-- overshoot, nothing the layout can see. And cards are keyed by what they
-- show, so a refresh reuses the ones that are still there and only adds or
-- removes the ones that changed.

local slotsByKey: { [string]: CanvasGroup } = {}

local function fadeIn(group: CanvasGroup)
	group.GroupTransparency = 1
	game:GetService("TweenService"):Create(group, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		GroupTransparency = 0,
	}):Play()
end

--- Wraps a freshly built card in its fixed slot and parents it to the list.
local function mountCard(card: Frame, key: string, index: number): CanvasGroup
	local group = Instance.new("CanvasGroup")
	group.Name = "Slot_" .. key
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.AnchorPoint = Vector2.new(0.5, 0)
	group.Size = UDim2.fromScale(CARD.WIDTH, CARD.HEIGHT)
	group.LayoutOrder = index
	-- The card fills its slot exactly; the slot is what the layout sizes.
	card.AnchorPoint = Vector2.new(0, 0)
	card.Position = UDim2.fromScale(0, 0)
	card.Size = UDim2.fromScale(1, 1)
	local stray = card:FindFirstChildOfClass("UIScale")
	if stray then
		stray:Destroy()
	end
	card.Parent = group
	group.Parent = scroll
	slotsByKey[key] = group
	fadeIn(group)
	return group
end

local function inventorySignature(inventory: { any }): string
	local parts = table.create(#inventory)
	for index, item in inventory do
		parts[index] = `{item.InstanceId}:{item.ItemId}:{item.Rarity}:{item.Size}:{item.Mutation}:{item.FinalIncome}`
	end
	return table.concat(parts, "|")
end

local function clearList()
	builtSignature = nil
	table.clear(slotsByKey)
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

--- What the GUARDIANS page was last built from: the equipped key plus each
--- animal's ownership. WEAPONS likewise.
local function guardianSignature(guardians: any): string
	local parts = { "G", tostring(guardians.equipped) }
	for _, def in BaseGuardianConfig.Guardians do
		table.insert(parts, `{def.key}={tostring(guardians.owned and guardians.owned[def.key])}`)
	end
	return table.concat(parts, "|")
end

local function weaponSignature(weapons: any): string
	local parts = { "W", tostring(weapons.equipped) }
	for _, name in PvPConfig.WeaponOrder do
		table.insert(parts, `{name}={tostring(weapons.owned and weapons.owned[name])}`)
	end
	return table.concat(parts, "|")
end

local function setEmpty(visible: boolean, title: string, hint: string)
	if emptyState then
		emptyState.Visible = visible
	end
	if emptyTitleLabel then
		emptyTitleLabel.Text = title
	end
	if emptyHintLabel then
		emptyHintLabel.Text = hint
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
	local guardians = if type(state.guardians) == "table" then state.guardians else nil
	local weapons = if type(state.weapons) == "table" then state.weapons else nil

	-- THE HEADER COUNTER is the capacity on ITEMS and an OWNED tally on the
	-- other two. Guardians and weapons are permanent unlocks and never add
	-- to the 0/10.
	if countLabel then
		if activeTab == "Items" then
			UIAnim.countTo(countLabel, capacity, function(value: number)
				return `{used}/{math.floor(value + 0.5)}`
			end)
			if lastCapacity and capacity > lastCapacity then
				UIAnim.punch(countLabel, 0.25)
			end
		elseif activeTab == "Guardians" then
			local owned = 0
			for _, def in BaseGuardianConfig.Guardians do
				if guardians and guardians.owned and guardians.owned[def.key] then
					owned += 1
				end
			end
			countLabel:SetAttribute("_CountValue", nil)
			countLabel.Text = `OWNED: {owned}/{#BaseGuardianConfig.Guardians}`
		else
			local owned = 0
			for _, name in PvPConfig.WeaponOrder do
				if weapons and weapons.owned and weapons.owned[name] then
					owned += 1
				end
			end
			countLabel:SetAttribute("_CountValue", nil)
			countLabel.Text = `OWNED: {owned}/{#PvPConfig.WeaponOrder}`
		end
	end
	lastCapacity = capacity

	-- The storage upgrade belongs to ITEMS only.
	if upgradeButton and upgradePrice then
		local cost = state.storageNextCost
		if activeTab == "Items" and cost then
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

	-- Only rebuild the rows when what they SHOW changed. StatePush arrives
	-- every second from the income tick alone (and four times a second while
	-- training), and tearing the list down and re-cloning it on each one made
	-- every button under the cursor a brand-new instance: hover state
	-- vanished, a press that straddled the rebuild never became a click, and
	-- the whole panel visibly flickered. Cash and capacity changes are
	-- painted above without touching the rows.
	local signature: string
	if activeTab == "Items" then
		signature = "I|" .. inventorySignature(state.inventory or {})
	elseif activeTab == "Guardians" then
		signature = "G|" .. guardianSignature(guardians or {})
	else
		signature = "W|" .. weaponSignature(weapons or {})
	end
	if signature == builtSignature then
		return
	end
	local sameTab = builtSignature ~= nil and string.sub(builtSignature, 1, 2) == string.sub(signature, 1, 2)
	builtSignature = signature

	if activeTab == "Items" then
		if not sameTab then
			clearList()
			builtSignature = signature
		end
		-- DIFF, do not rebuild. A card whose item is still stored keeps its
		-- instance (and its hover state, and its position); only the ones
		-- that arrived are built and only the ones that left are removed.
		local inventory = state.inventory or {}
		local wanted: { [string]: boolean } = {}
		for index, item in inventory do
			local key = tostring(item.InstanceId)
			wanted[key] = true
			local existing = slotsByKey[key]
			if existing and existing.Parent then
				existing.LayoutOrder = index
			else
				local card = buildCard(item, index)
				if card then
					mountCard(card, key, index)
				end
			end
		end
		for key, group in slotsByKey do
			if not wanted[key] then
				slotsByKey[key] = nil
				group:Destroy()
			end
		end
		setEmpty(#inventory == 0, "Nothing Stored", "Store one of your displayed items to keep it here.")
	elseif activeTab == "Guardians" then
		clearList()
		builtSignature = signature
		local shown = 0
		for index, def in BaseGuardianConfig.Guardians do
			if guardians and guardians.owned and guardians.owned[def.key] then
				shown += 1
				local card = buildGuardianCard(def, guardians.equipped == def.key, index)
				if card then
					mountCard(card, "G_" .. def.key, index)
				end
			end
		end
		setEmpty(shown == 0, "No Guardians Owned", "Watch the rotating Guardian shop to unlock one!")
	else
		clearList()
		builtSignature = signature
		local shown = 0
		for index, name in PvPConfig.WeaponOrder do
			if weapons and weapons.owned and weapons.owned[name] then
				shown += 1
				local card = buildWeaponCard(name, weapons.equipped == name, index)
				if card then
					mountCard(card, "W_" .. name, index)
				end
			end
		end
		setEmpty(shown == 0, "No Weapons", "Every player carries the Bat.")
	end
end

-- ==========================================================
-- TABS
-- ==========================================================

local TAB_SELECTED = { plate = Color3.fromRGB(22, 120, 70), top = Color3.fromRGB(96, 240, 150), bottom = Color3.fromRGB(28, 190, 110) }
local TAB_IDLE = { plate = Color3.fromRGB(34, 44, 84), top = Color3.fromRGB(96, 112, 170), bottom = Color3.fromRGB(52, 66, 120) }

local function styleTabs()
	for name, button in tabButtons do
		local selected = name == activeTab
		local colors = if selected then TAB_SELECTED else TAB_IDLE
		tintButton(button, colors.plate, colors.top, colors.bottom)
		local label = priceLabel(button)
		if label then
			label.TextTransparency = if selected then 0 else 0.2
		end
		local scale = UIAnim.scaleOf(button)
		if scale then
			game:GetService("TweenService"):Create(scale, UIAnim.POP, { Scale = if selected then 1.05 else 1 }):Play()
		end
	end
end

local function selectTab(name: Tab)
	if activeTab == name then
		return
	end
	activeTab = name
	styleTabs()
	-- A fresh list, cascaded in (refresh) - the quick transition the switch
	-- is asked for, without a second animation system.
	builtSignature = nil
	local list = scroll
	if list then
		list.CanvasPosition = Vector2.zero
	end
	refresh(latestState)
end

--- Three tabs directly under the header, cloned from the pack's own header
--- button so they carry its gradient, stroke and studs; the list shrinks to
--- make room for them.
local function buildTabs(built: Frame, list: ScrollingFrame, source: TextButton?)
	list.AnchorPoint = Vector2.new(0.5, 1)
	list.Position = UDim2.fromScale(0.5, 0.99)
	list.Size = UDim2.fromScale(1, 0.70)

	local bar = Instance.new("Frame")
	bar.Name = "Tabs"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.fromScale(0.5, 0.19)
	bar.Size = UDim2.fromScale(0.94, 0.085)
	bar.BackgroundTransparency = 1
	bar.ZIndex = list.ZIndex + 1
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.02, 0)
	layout.Parent = bar

	for order, name in TABS do
		local button: TextButton
		if source then
			button = source:Clone()
			local aspect = button:FindFirstChildOfClass("UIAspectRatioConstraint")
			if aspect then
				aspect:Destroy()
			end
			local ripple = button:FindFirstChild("_RippleContainer")
			if ripple then
				ripple:Destroy()
			end
			stripPromo(button)
			local label = priceLabel(button)
			if label then
				label.Text = string.upper(name)
				label.Size = UDim2.fromScale(0.92, 0.66)
				label.Position = UDim2.fromScale(0.5, 0.5)
				label.AnchorPoint = Vector2.new(0.5, 0.5)
				label.TextScaled = true
			end
		else
			button = Instance.new("TextButton")
			button.Font = Enum.Font.FredokaOne
			button.TextScaled = true
			button.TextColor3 = Color3.fromRGB(255, 255, 255)
			button.Text = string.upper(name)
			local round = Instance.new("UICorner")
			round.CornerRadius = UDim.new(0.3, 0)
			round.Parent = button
		end
		button.Name = `Tab{name}`
		button.LayoutOrder = order
		button.AnchorPoint = Vector2.new(0, 0)
		button.Position = UDim2.fromScale(0, 0)
		button.Size = UDim2.fromScale(0.31, 1)
		button.ZIndex = bar.ZIndex
		UIAnim.claimButton(button)
		button.Activated:Connect(function()
			selectTab(name)
		end)
		button.Parent = bar
		tabButtons[name] = button
	end
	-- A second way in, for tests and for anything that wants to open the
	-- panel on a given page: set the bar's `Active` attribute to a tab name.
	bar:SetAttribute("Active", activeTab)
	bar:GetAttributeChangedSignal("Active"):Connect(function()
		local wanted = bar:GetAttribute("Active")
		if wanted == "Items" or wanted == "Guardians" or wanted == "Weapons" then
			selectTab(wanted :: Tab)
		end
	end)
	bar.Parent = built
	styleTabs()
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
		-- Reused straight out of the pack, so it carries the same Active = false
		-- and pre-stamped attributes that made the card buttons inert.
		UIAnim.claimButton(upgrade)
		upgrade.Activated:Connect(function()
			Remotes.get("InventoryRequest"):FireServer("upgradeStorage")
		end)
	end

	-- ---------- list ----------
	local layout = list:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout.Padding = UDim.new(0.025, 0)
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
	end

	-- Rows are now tall enough that ten of them overflow, so the canvas has to
	-- grow and the bar has to be visible.
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 6
	list.ScrollingDirection = Enum.ScrollingDirection.Y

	local listPadding = list:FindFirstChildOfClass("UIPadding")
	if not listPadding then
		listPadding = Instance.new("UIPadding")
		listPadding.Parent = list
	end
	listPadding.PaddingTop = UDim.new(0.02, 0)
	listPadding.PaddingBottom = UDim.new(0.02, 0)

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
	emptyTitleLabel = emptyTitle
	emptyHintLabel = emptyHint

	-- Canvas grows with the content through AutomaticCanvasSize (set above).
	-- A second, manual CanvasSize write on every AbsoluteContentSize change
	-- used to sit beside it; two owners of the canvas re-laid the scale-sized
	-- rows against each other on every push, which is the flicker touch
	-- scrolling showed. One owner now.
	list.ScrollBarThickness = 6
	scroll = list

	-- ITEMS / GUARDIANS / WEAPONS, under the header.
	buildTabs(built, list, upgradeButton)

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

--- A storage chest drawn from frames: lid, body, a strap and a latch, every
--- piece with the pack's thick dark outline. Fills `holder` (the button's
--- Icon slot) and keeps its aspect, so it sits exactly where the image did.
local function buildStorageGlyph(holder: GuiObject)
	local OUTLINE = Color3.fromRGB(28, 22, 12)
	local WOOD = Color3.fromRGB(255, 196, 80)
	local WOOD_DARK = Color3.fromRGB(226, 140, 34)
	local BRASS = Color3.fromRGB(255, 240, 170)

	local glyph = Instance.new("Frame")
	glyph.Name = "StorageGlyph"
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.52)
	glyph.Size = UDim2.fromScale(0.86, 0.86)
	glyph.BackgroundTransparency = 1
	glyph.ZIndex = holder.ZIndex + 1
	glyph.Parent = holder
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = glyph

	local function piece(name: string, x: number, y: number, w: number, h: number, color: Color3, radius: number, z: number): Frame
		local part = Instance.new("Frame")
		part.Name = name
		part.AnchorPoint = Vector2.new(0.5, 0.5)
		part.Position = UDim2.fromScale(x, y)
		part.Size = UDim2.fromScale(w, h)
		part.BackgroundColor3 = color
		part.BorderSizePixel = 0
		part.ZIndex = glyph.ZIndex + z
		part.Parent = glyph
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(radius, 0)
		round.Parent = part
		local edge = Instance.new("UIStroke")
		edge.Thickness = 2.5
		edge.Color = OUTLINE
		edge.LineJoinMode = Enum.LineJoinMode.Round
		edge.Parent = part
		return part
	end

	-- Body, then the lid over its top edge, a strap down the middle, a latch.
	local bodyPiece = piece("Body", 0.5, 0.64, 0.9, 0.5, WOOD, 0.14, 1)
	local bodyShade = Instance.new("UIGradient")
	bodyShade.Rotation = 90
	bodyShade.Color = ColorSequence.new(WOOD, WOOD_DARK)
	bodyShade.Parent = bodyPiece
	local lid = piece("Lid", 0.5, 0.33, 0.94, 0.3, WOOD, 0.35, 2)
	local lidShade = Instance.new("UIGradient")
	lidShade.Rotation = 90
	lidShade.Color = ColorSequence.new(Color3.fromRGB(255, 226, 140), WOOD)
	lidShade.Parent = lid
	piece("Strap", 0.5, 0.56, 0.2, 0.7, WOOD_DARK, 0.2, 3)
	piece("Latch", 0.5, 0.5, 0.26, 0.2, BRASS, 0.3, 4)
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
		-- A STORAGE icon, not the cash note the pack's header carried. The
		-- project ships no storage image, and no asset id is invented for one:
		-- the chest is drawn from the pack's own vocabulary - outlined shapes
		-- on the studded plate - so it matches the other three buttons.
		icon.Image = ""
		icon.BackgroundTransparency = 1
		buildStorageGlyph(icon)
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

--- Opens or closes the panel. Public so a keybind (and anything added later)
--- has one way in that matches what the button does.
function InventoryController.toggle()
	if not panel then
		return
	end
	fallbackSetOpen(not panel.Visible)
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

	-- BACKTICK TOGGLES STORAGE. `gameProcessedEvent` is the whole safety
	-- story: Roblox sets it when the keystroke has already been consumed by
	-- something with focus - the chat bar, a TextBox, a menu - so typing a
	-- backquote into chat never opens the panel behind it. Touch devices
	-- never send a keyboard InputBegan at all, so the on-screen button
	-- remains the only path there and nothing about mobile changes.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if input.KeyCode == Enum.KeyCode.Backquote then
			InventoryController.toggle()
		end
	end)

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
