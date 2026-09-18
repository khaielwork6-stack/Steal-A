--!strict
--[[
	IndexController
	The Loot Index panel: all 96 items, what you have found, and the set rewards.

	THIS PANEL IS NOT BUILT, IT IS FILLED IN
	MainUI.Frames.Index already exists in the pack, and Buttons.Left.Index already
	opens it - the pack pairs a button with the frame of the same name, so we get
	the slide-up, blur and one-panel-at-a-time behaviour for free and must never
	animate the panel ourselves.

	The pack also shipped its demo grid in two states, which happen to be exactly
	the two states an index needs:
	  * a DISCOVERED card - Icon + Rarity + Name
	  * a LOCKED card     - Icon + Count reading "???"
	Both are lifted out as templates on startup and the rest of the demo cards are
	destroyed. Nothing here re-authors a card.

	ONE PAGE, NOT TWELVE (owner, 2026-09-18)
	It used to be twelve pages behind twelve tiny tabs. The tabs carried no
	text - the pack button they were cloned from has no Title in that slot -
	eight cards never filled the frame, and finding anything meant guessing
	which numbered square to press.

	Now the scroll STACKS a section per zone: a header carrying the zone's
	emoji, name, accent bar, found count and its own claim button, then that
	zone's eight cards four across. The whole 96 reads as one collection you
	move down, every claim sits with the set it belongs to, and the list fills
	the panel edge to edge because there is no tab strip or bottom bar left to
	leave room for.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local IndexConfig = require(ReplicatedStorage.Shared.Config.IndexConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)
local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)

local IndexController = {}

local player = Players.LocalPlayer

local LOCKED_TEXT = "???"
local DIM = Color3.fromRGB(86, 92, 104)
local CLAIMABLE = Color3.fromRGB(72, 200, 108)
local CLAIMED = Color3.fromRGB(96, 104, 122)
local INCOMPLETE = Color3.fromRGB(58, 64, 78)
--- Gap between cards, and the room the scrollbar needs on the right.
local CARD_GAP = 8
local SCROLLBAR = 10

local panel: Frame? = nil
local scroll: ScrollingFrame? = nil
local foundTemplate: Frame? = nil
local lockedTemplate: Frame? = nil
local counterLabel: TextLabel? = nil
local openerBadge: TextLabel? = nil

local discovered: { [string]: boolean } = {}
local summary: any = nil
local lastDiscoveredCount: number? = nil
--- ONE PREVIEW PER CARD, BUILT WHEN THE CARD IS REACHED. Ninety-six cards
--- meant ninety-six ViewportFrames - each its own render pass, each holding a
--- cloned model - and the panel crawled. A card draws its plate right away;
--- the viewport behind it is built the first time the card scrolls near the
--- window and hidden again (not destroyed) once it scrolls away, so only the
--- dozen cells actually on screen cost anything to draw or to turn.
type Preview = {
	icon: ImageLabel,
	card: GuiObject,
	id: string,
	rarity: string,
	known: boolean,
	built: boolean,
	shown: boolean,
	model: Model?,
}
local previews: { Preview } = {}
--- How far outside the scroll's window a card still counts as near, so a
--- preview is ready by the time it is actually looked at.
local PREVIEW_MARGIN = 140
--- Viewports built per sweep. Building is the expensive half (a model clone
--- and a camera fit), so it is rationed rather than done in one burst.
local PREVIEW_BUDGET = 4
--- Seconds between sweeps. At PREVIEW_MARGIN, scrolling cannot outrun this.
local SWEEP_INTERVAL = 0.12
local sinceSweep = 0
--- Radians per second a discovered item turns in its card.
local TURN_RATE = 0.7
local HOVER_LIFT = 1.05
local HOVER_IN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ==========================================================
-- HELPERS
-- ==========================================================

local function labelIn(parent: Instance?, name: string): TextLabel?
	if not parent then
		return nil
	end
	local found = parent:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

--- Strips a demo rainbow gradient so a flat rarity colour actually shows.
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

-- ==========================================================
-- CARDS
-- ==========================================================

--- Notes a card's icon so the sweep can build, show, hide and turn it. The
--- viewport itself is NOT made here - that is the cost being deferred.
local function registerPreview(card: GuiObject, icon: ImageLabel, def: any, known: boolean)
	table.insert(previews, {
		icon = icon,
		card = card,
		id = def.id,
		rarity = def.rarity,
		known = known,
		built = false,
		shown = false,
		model = nil,
	})
end

--- One item cell. `def` is the LootConfig entry; `known` decides which of the
--- pack's two card variants gets cloned.
local function buildCard(def: any, known: boolean, order: number): Frame?
	local template = if known then foundTemplate else lockedTemplate
	if not template then
		return nil
	end

	local card = template:Clone()
	card.Name = def.id
	card.LayoutOrder = order
	card.Visible = true

	local body = card:FindFirstChild("Frame")
	local color = RarityConfig.Colors[def.rarity] or Color3.fromRGB(198, 205, 216)

	if known then
		flatten(labelIn(body, "Rarity"), color)
		local rarity = labelIn(body, "Rarity")
		if rarity then
			rarity.Text = string.upper(def.rarity)
		end
		local name = labelIn(body, "Name")
		if name then
			name.Text = string.upper(def.name)
			name.TextColor3 = Color3.fromRGB(240, 244, 252)
		end

		-- The plate right away; the turning model when the card is reached.
		local icon = body and body:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			ItemThumb.applyPlate(icon, def.rarity, true)
			registerPreview(card, icon, def, true)
		end
		local stroke = card:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = color
		end
	else
		local count = labelIn(card, "Count")
		if count then
			count.Text = LOCKED_TEXT
			flatten(count, DIM)
		end
		-- An unfound item is a black silhouette of the real thing on an unlit
		-- plate: the shape teases, the detail and the rarity stay hidden until
		-- the player has actually found it.
		local icon = body and body:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			ItemThumb.applyPlate(icon, def.rarity, false)
			registerPreview(card, icon, def, false)
		end
		local stroke = card:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = Color3.fromRGB(34, 37, 46)
		end
	end

	-- A small lift under the pointer, so the grid answers the hand.
	local lift = card:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	lift.Parent = card
	card.MouseEnter:Connect(function()
		TweenService:Create(lift, HOVER_IN, { Scale = HOVER_LIFT }):Play()
	end)
	card.MouseLeave:Connect(function()
		TweenService:Create(lift, HOVER_IN, { Scale = 1 }):Play()
	end)

	return card
end

-- ==========================================================
-- ZONE SECTIONS (one page, no tabs)
-- ==========================================================
--
-- The panel used to be twelve pages behind twelve tiny tabs: the tabs
-- carried no text (the pack button they were cloned from has no Title in
-- that slot), eight cards never filled the frame, and finding anything meant
-- guessing which numbered square to press. It is ONE scroll now, in zone
-- order, with a headed section per zone - so the whole 96 reads as a
-- collection you move down, and every zone's claim sits in its own header.

--- Per-zone widgets, so a repaint touches only what changed.
type Section = {
	header: Frame,
	title: TextLabel,
	count: TextLabel,
	claim: TextButton,
	claimLabel: TextLabel,
	grid: Frame,
}
local sections: { [number]: Section } = {}

--- The claim button in one zone's header: what it says, and whether it does
--- anything. Exactly the three states the old bottom bar had.
local function paintSection(index: number)
	local section = sections[index]
	local zone = ZoneConfig.Zones[index]
	if not section or not zone then
		return
	end
	local row = summary and summary.zones and summary.zones[index]
	local found = if row then row.discovered else 0
	local total = if row then row.total else #(LootConfig.Items[index] or {})
	local complete = total > 0 and found >= total

	section.count.Text = `{found}/{total}`
	section.count.TextColor3 = if complete then CLAIMABLE else Color3.fromRGB(176, 184, 200)

	local reward = IndexConfig.zoneReward(index)
	local claimable = row ~= nil and row.claimable == true
	local claimed = row ~= nil and row.claimed == true
	section.claim.Visible = reward ~= nil
	if not reward then
		return
	end
	section.claim.Active = claimable
	section.claim.Selectable = claimable
	-- A zone set pays SPEED, not cash (IndexConfig.zoneReward).
	local prize = `+{NumberFormat.short(reward.speed or 0)} SPEED`
	if claimed then
		section.claimLabel.Text = "CLAIMED"
		section.claim.BackgroundColor3 = CLAIMED
	elseif claimable then
		section.claimLabel.Text = `CLAIM {prize}`
		section.claim.BackgroundColor3 = CLAIMABLE
	else
		section.claimLabel.Text = prize
		section.claim.BackgroundColor3 = INCOMPLETE
	end
end

--- One zone's block: a header carrying the zone's name, its accent, its
--- found count and its claim button, then a grid of its eight cards.
local function buildSection(index: number, list: ScrollingFrame)
	local zone = ZoneConfig.Zones[index]
	local pool = LootConfig.Items[index]
	if not zone or not pool then
		return
	end

	local header = Instance.new("Frame")
	header.Name = `ZoneHeader_{index}`
	header.LayoutOrder = index * 10
	header.BackgroundColor3 = Color3.fromRGB(26, 30, 48)
	header.BorderSizePixel = 0
	header.Size = UDim2.new(1, 0, 0, 38)
	header.ZIndex = 5
	header.Parent = list
	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 10)
	headerCorner.Parent = header
	-- The zone's own colour, as a bar down the left edge: twelve sections
	-- scrolling past need something other than their words to tell them apart.
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.BackgroundColor3 = zone.color
	accent.BorderSizePixel = 0
	accent.Size = UDim2.new(0, 5, 0.7, 0)
	accent.Position = UDim2.new(0, 0, 0.15, 0)
	accent.ZIndex = 6
	accent.Parent = header
	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(1, 0)
	accentCorner.Parent = accent

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.new(0, 14, 0.5, 0)
	title.Size = UDim2.new(0.5, 0, 0.7, 0)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(240, 244, 252)
	title.Text = `{zone.emoji}  {string.upper(zone.name)}`
	title.ZIndex = 7
	title.Parent = header
	local titleLimit = Instance.new("UITextSizeConstraint")
	titleLimit.MaxTextSize = 20
	titleLimit.Parent = title

	local count = Instance.new("TextLabel")
	count.Name = "Count"
	count.BackgroundTransparency = 1
	count.AnchorPoint = Vector2.new(0, 0.5)
	count.Position = UDim2.new(0.5, 6, 0.5, 0)
	count.Size = UDim2.new(0.12, 0, 0.6, 0)
	count.Font = Enum.Font.GothamBold
	count.TextScaled = true
	count.TextXAlignment = Enum.TextXAlignment.Left
	count.TextColor3 = Color3.fromRGB(176, 184, 200)
	count.Text = ""
	count.ZIndex = 7
	count.Parent = header
	local countLimit = Instance.new("UITextSizeConstraint")
	countLimit.MaxTextSize = 15
	countLimit.Parent = count

	local claim = Instance.new("TextButton")
	claim.Name = "Claim"
	claim.Text = ""
	claim.AutoButtonColor = false
	claim.AnchorPoint = Vector2.new(1, 0.5)
	claim.Position = UDim2.new(1, -8, 0.5, 0)
	claim.Size = UDim2.new(0.34, 0, 0.72, 0)
	claim.BackgroundColor3 = INCOMPLETE
	claim.BorderSizePixel = 0
	claim.ZIndex = 7
	claim.Parent = header
	local claimCorner = Instance.new("UICorner")
	claimCorner.CornerRadius = UDim.new(0, 8)
	claimCorner.Parent = claim
	local claimEdge = Instance.new("UIStroke")
	claimEdge.Color = Color3.fromRGB(16, 18, 26)
	claimEdge.Thickness = 2
	claimEdge.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
	claimEdge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	claimEdge.Parent = claim
	local claimText = Instance.new("TextLabel")
	claimText.Name = "Label"
	claimText.BackgroundTransparency = 1
	claimText.AnchorPoint = Vector2.new(0.5, 0.5)
	claimText.Position = UDim2.fromScale(0.5, 0.5)
	claimText.Size = UDim2.fromScale(0.92, 0.7)
	claimText.Font = Enum.Font.FredokaOne
	claimText.TextScaled = true
	claimText.TextColor3 = Color3.fromRGB(255, 255, 255)
	claimText.TextStrokeColor3 = Color3.fromRGB(16, 18, 26)
	claimText.TextStrokeTransparency = 0.3
	claimText.Text = ""
	claimText.ZIndex = 8
	claimText.Parent = claim
	local claimLimit = Instance.new("UITextSizeConstraint")
	claimLimit.MaxTextSize = 14
	claimLimit.Parent = claimText
	UIAnim.claimButton(claim)
	claim.Activated:Connect(function()
		-- The server re-checks the set is complete and unclaimed; this only asks.
		Remotes.get("IndexClaimRequest"):FireServer(index)
		UIAnim.punch(claim, 0.12)
	end)

	local grid = Instance.new("Frame")
	grid.Name = `ZoneGrid_{index}`
	grid.LayoutOrder = index * 10 + 1
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, 120)
	grid.Parent = list
	local layout = Instance.new("UIGridLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = grid

	sections[index] = {
		header = header,
		title = title,
		count = count,
		claim = claim,
		claimLabel = claimText,
		grid = grid,
	}
end
--- Decides which cards are near enough to the scroll's window to be worth
--- drawing. Cards outside it keep their plate but lose their viewport, so a
--- ninety-six cell grid renders like a twelve cell one.
---
--- A card is never hidden outright: UIGridLayout skips invisible children, so
--- hiding one would close the gap and shuffle the whole grid. The VIEWPORT is
--- what gets hidden; the cell keeps its place.
local function sweepPreviews()
	local list = scroll
	if not list then
		return
	end
	local top = list.AbsolutePosition.Y - PREVIEW_MARGIN
	local bottom = list.AbsolutePosition.Y + list.AbsoluteSize.Y + PREVIEW_MARGIN
	local budget = PREVIEW_BUDGET
	for _, preview in previews do
		local card = preview.card
		if card.Parent then
			local cardTop = card.AbsolutePosition.Y
			local near = card.Visible and cardTop + card.AbsoluteSize.Y >= top and cardTop <= bottom
			if near and not preview.built and budget > 0 then
				budget -= 1
				preview.built = true
				preview.model = if preview.known
					then ItemThumb.apply(preview.icon, preview.rarity, preview.id)
					else ItemThumb.applyUnknown(preview.icon, preview.id)
			end
			local viewport = preview.icon:FindFirstChild("Preview")
			if viewport and viewport:IsA("ViewportFrame") then
				viewport.Visible = near
			end
			preview.shown = near and preview.built
		end
	end
end


--- The discovered set the grid was last BUILT from. A cell's template is
--- chosen by whether its item is discovered, so only a change to that set
--- needs a rebuild - and tearing down and re-cloning all ninety-six cells
--- cost a visible hitch that the panel was paying on every single open.
local rendered: { [string]: boolean }? = nil

local function gridIsCurrent(): boolean
	local last = rendered
	if not last then
		return false
	end
	for id in discovered do
		if not last[id] then
			return false
		end
	end
	for id in last do
		if not discovered[id] then
			return false
		end
	end
	return true
end

--- Fills every zone's grid. Called on the first push and whenever a new item
--- is discovered - a card changes template (locked -> found), so the cell is
--- rebuilt rather than repainted.
local function renderAll()
	local list = scroll
	if not list then
		return
	end
	if gridIsCurrent() then
		-- Nothing new found since the cells were made: they are still right,
		-- so only the section headers are repainted and the previews re-swept.
		for index = 1, ZoneConfig.COUNT do
			paintSection(index)
		end
		sinceSweep = SWEEP_INTERVAL
		return
	end
	rendered = table.clone(discovered)
	table.clear(previews)
	-- Sweep on the next frame, once the layout has placed the new cards.
	sinceSweep = SWEEP_INTERVAL
	local cards: { GuiObject } = {}
	for index = 1, ZoneConfig.COUNT do
		local section = sections[index]
		local pool = LootConfig.Items[index]
		if section and pool then
			for _, child in section.grid:GetChildren() do
				if not child:IsA("UILayout") then
					child:Destroy()
				end
			end
			for order, def in pool do
				local card = buildCard(def, discovered[def.id] == true, order)
				if card then
					card.Parent = section.grid
					table.insert(cards, card)
				end
			end
		end
		paintSection(index)
	end
	if panel and panel.Visible then
		ShopKit.cascadeIn(cards, 0.006)
	end
end
local function paintCounter()
	local label = counterLabel
	if not label or not summary then
		return
	end
	local total = summary.total or IndexConfig.TOTAL_ITEMS
	UIAnim.countTo(label, summary.discovered, function(value: number)
		return `{math.floor(value + 0.5)}/{total} Discovered`
	end)
	if lastDiscoveredCount and summary.discovered > lastDiscoveredCount then
		UIAnim.punch(label, 0.2)
	end
	lastDiscoveredCount = summary.discovered
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- Lifts the pack's two demo card variants out as templates and destroys the
--- rest of the demo grid.
local function takeCardTemplates(ui: ScreenGui, list: ScrollingFrame)
	local templates = ui:FindFirstChild("Templates")
	if not templates then
		local folder = Instance.new("Folder")
		folder.Name = "Templates"
		folder.Parent = ui
		templates = folder
	end

	for _, child in list:GetChildren() do
		if not child:IsA("Frame") then
			continue
		end
		-- The variants are told apart by content, not by name: every demo card is
		-- called "1". The one carrying a Name label is the discovered state.
		local isFound = child:FindFirstChild("Name", true) ~= nil
		if isFound and not foundTemplate then
			child.Name = "IndexCardFound"
			child.Visible = false
			child.Parent = templates
			foundTemplate = child
		elseif not isFound and not lockedTemplate then
			child.Name = "IndexCardLocked"
			child.Visible = false
			child.Parent = templates
			lockedTemplate = child
		else
			child:Destroy()
		end
	end
end

local function buildPanel(ui: ScreenGui): boolean
	local frames = ui:FindFirstChild("Frames")
	local frame = frames and frames:FindFirstChild("Index")
	if not frame or not frame:IsA("Frame") then
		warn("[IndexController] Frames.Index not found - the Index panel is disabled.")
		return false
	end
	panel = frame

	local list = frame:FindFirstChild("ScrollingFrame")
	if not list or not list:IsA("ScrollingFrame") then
		warn("[IndexController] Index.ScrollingFrame not found - the Index panel is disabled.")
		return false
	end
	scroll = list

	takeCardTemplates(ui, list)
	if not foundTemplate or not lockedTemplate then
		warn("[IndexController] the pack's two demo card states were not both found.")
		return false
	end

	-- Header title. The pack's demo read "Loot Index" already, so only the
	-- subtitle counter needs owning.
	local top = frame:FindFirstChild("Top")
	local title = labelIn(top and top:FindFirstChild("Frame"), "Title")
	if title then
		title.Text = "Loot Index"
	end
	counterLabel = labelIn(frame:FindFirstChild("Features"), "Title")
	if counterLabel then
		counterLabel.Text = `0/{IndexConfig.TOTAL_ITEMS} Discovered`
	end

	-- Make room for the tab strip and the zone header above, the claim bar below.
	list.AnchorPoint = Vector2.new(0.5, 0.5)
	list.Position = UDim2.fromScale(0.5, 0.607)
	list.Size = UDim2.fromScale(0.94, 0.515)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 4
	list.ScrollingDirection = Enum.ScrollingDirection.Y

	-- The scroll STACKS sections now, so the pack's grid layout on it has to
	-- go: each zone keeps its own grid, inside its own frame.
	local packGrid = list:FindFirstChildOfClass("UIGridLayout")
	if packGrid then
		packGrid:Destroy()
	end
	local stack = Instance.new("UIListLayout")
	stack.FillDirection = Enum.FillDirection.Vertical
	stack.SortOrder = Enum.SortOrder.LayoutOrder
	stack.HorizontalAlignment = Enum.HorizontalAlignment.Center
	stack.Padding = UDim.new(0, 6)
	stack.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.Parent = list

	-- ONE PAGE: a headed section per zone, stacked down the scroll. No tabs
	-- and no bottom bar - each zone's claim lives in its own header.
	for index = 1, ZoneConfig.COUNT do
		buildSection(index, list)
	end


	PanelStyle.window(frame, 900, 620)
	local function fitIndex()
		local factor = ClipSafe.scaleChain(frame)
		local h = frame.AbsoluteSize.Y / factor
		local topFrame = frame:FindFirstChild("Top")
		local headerHeight = if topFrame and topFrame:IsA("GuiObject") then topFrame.AbsoluteSize.Y / factor else 52 / factor
		local features = frame:FindFirstChild("Features")
		if features and features:IsA("GuiObject") then features.Visible = false end
		-- ONE SCROLL, edge to edge under the header. No tab strip, no zone
		-- title line and no bottom claim bar to leave room for, so the list
		-- gets all of it.
		list.AnchorPoint = Vector2.new(0.5, 0)
		list.Position = UDim2.new(0.5, 0, 0, headerHeight + 8 / factor)
		list.Size = UDim2.new(0.95, 0, 0, math.max(60 / factor, h - headerHeight - 20 / factor))
		list.ClipsDescendants = true

		-- Four cards across each zone's grid, sized from the list's real
		-- width so the cells stay square-ish at any panel size, and the grid
		-- is set to exactly its two rows (AutomaticSize cannot measure a
		-- UIGridLayout).
		local inner = list.AbsoluteSize.X / factor
		if inner > 0 then
			local cell = (inner - 3 * CARD_GAP - SCROLLBAR) / 4
			-- Cells are WIDER than tall: at 0.92 a zone was 400px of scroll and the
				-- page ran to 5,200. 0.62 keeps the art readable and halves that.
				local cellHeight = math.max(92 / factor, cell * 0.62)
			for index = 1, ZoneConfig.COUNT do
				local section = sections[index]
				if section then
					local layout = section.grid:FindFirstChildOfClass("UIGridLayout")
					if layout then
						layout.CellSize = UDim2.fromOffset(cell, cellHeight)
						layout.CellPadding = UDim2.fromOffset(CARD_GAP, CARD_GAP)
					end
					local rows = math.ceil(#(LootConfig.Items[index] or {}) / 4)
					section.grid.Size = UDim2.new(1, 0, 0, rows * cellHeight + (rows - 1) * CARD_GAP)
					section.header.Size = UDim2.new(1, 0, 0, math.max(34 / factor, 38 / factor))
				end
			end
		end
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitIndex)
	frame:GetPropertyChangedSignal("Visible"):Connect(fitIndex)
	task.defer(fitIndex)
	return true
end

--- A small count of unclaimed set rewards, on the Index button itself. Without
--- it a finished set is invisible until the player happens to open the panel.
local function buildOpenerBadge(ui: ScreenGui)
	local buttons = ui:FindFirstChild("Buttons")
	local opener = buttons and buttons:FindFirstChild("Left") and buttons.Left:FindFirstChild("Index")
	if not opener or not opener:IsA("GuiButton") then
		return
	end

	local badge = Instance.new("TextLabel")
	badge.Name = "IndexBadge"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.fromScale(1.02, -0.08)
	badge.Size = UDim2.fromScale(0.42, 0.42)
	badge.BackgroundColor3 = CLAIMABLE
	badge.Font = Enum.Font.GothamBold
	badge.TextColor3 = Color3.fromRGB(255, 255, 255)
	badge.TextScaled = true
	badge.Text = "0"
	badge.Visible = false
	badge.ZIndex = 5
	badge.Parent = opener

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.35, 0)
	corner.Parent = badge

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(20, 22, 30)
	stroke.Parent = badge

	openerBadge = badge
end

-- ==========================================================
-- START
-- ==========================================================

function IndexController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		warn("[IndexController] MainUI not found - the Index panel is disabled.")
		return
	end

	if not buildPanel(ui) then
		return
	end
	buildOpenerBadge(ui)

	Remotes.get("IndexPush").OnClientEvent:Connect(function(payload)
		discovered = (payload and payload.discovered) or {}
		renderAll()
	end)

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		if not state or not state.index then
			return
		end
		summary = state.index
		paintCounter()

		for index = 1, ZoneConfig.COUNT do
			paintSection(index)
		end

		if openerBadge then
			local waiting = summary.claimable or 0
			local wasVisible = openerBadge.Visible
			openerBadge.Visible = waiting > 0
			openerBadge.Text = tostring(waiting)
			if waiting > 0 and not wasVisible then
				UIAnim.punch(openerBadge, 0.35)
			end
		end
	end)

	-- The join push races StarterPlayerScripts connecting above, so ask once we
	-- are definitely listening. Also re-ask on open, which costs one small packet
	-- and removes any dependence on push timing.
	Remotes.get("IndexClaimRequest"):FireServer("sync")

	local frame = panel
	if frame then
		frame:GetPropertyChangedSignal("Visible"):Connect(function()
			if frame.Visible then
				Remotes.get("IndexClaimRequest"):FireServer("sync")
				renderAll()
			end
		end)
	end

	-- Only the previews actually on screen are built and turned, and the
	-- window they are measured against is only re-checked a few times a
	-- second - the turn itself is one pivot per visible model.
	RunService.Heartbeat:Connect(function(dt)
		if not frame or not frame.Visible or #previews == 0 then
			return
		end
		sinceSweep += dt
		if sinceSweep >= SWEEP_INTERVAL then
			sinceSweep = 0
			sweepPreviews()
		end
		for _, preview in previews do
			local model = preview.model
			if model and preview.shown then
				ItemThumb.turn(model, TURN_RATE * dt)
			end
		end
	end)

	renderAll()
end

return IndexController
