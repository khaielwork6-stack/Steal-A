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

	WHY ZONE TABS RATHER THAN ONE LONG SCROLL
	The grid is four cards wide, so a zone's eight items are exactly two rows. One
	tab per zone therefore fills the grid perfectly with no ragged rows, and it
	gives the per-zone claim button somewhere honest to live. The tabs are cloned
	from a real pack button so they inherit its art.

	The tabs are stamped `_UIHandlerSetup` on purpose. The pack skips any button
	already carrying that attribute, which is how we claim a button for our own
	binding - without it the pack would try to open a panel named "Zone1".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IndexConfig = require(ReplicatedStorage.Shared.Config.IndexConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local IndexController = {}

local player = Players.LocalPlayer

local LOCKED_TEXT = "???"
local DIM = Color3.fromRGB(86, 92, 104)
local CLAIMABLE = Color3.fromRGB(72, 200, 108)
local CLAIMED = Color3.fromRGB(96, 104, 122)
local INCOMPLETE = Color3.fromRGB(58, 64, 78)

local panel: Frame? = nil
local scroll: ScrollingFrame? = nil
local foundTemplate: Frame? = nil
local lockedTemplate: Frame? = nil
local counterLabel: TextLabel? = nil
local claimButton: TextButton? = nil
local claimLabel: TextLabel? = nil
local openerBadge: TextLabel? = nil
local tabs: { [number]: TextButton } = {}

local selectedZone = 1
local discovered: { [string]: boolean } = {}
local summary: any = nil
local lastDiscoveredCount: number? = nil

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

--- Claims a button for our own input handling. See UIAnim.claimButton for why
--- a cloned pack button is inert until both its Active flag and its handler
--- attributes are corrected.
local claimForUs = UIAnim.claimButton

-- ==========================================================
-- CARDS
-- ==========================================================

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

		local icon = body and body:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			ItemThumb.apply(icon, def.rarity)
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
		-- An unfound item shows a blank plate, never a dimmed rarity colour:
		-- that would leak how rare it is before the player has found it.
		local icon = body and body:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			ItemThumb.applyUnknown(icon)
		end
		local stroke = card:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = Color3.fromRGB(34, 37, 46)
		end
	end

	return card
end

-- ==========================================================
-- RENDER
-- ==========================================================

local function clearGrid()
	local list = scroll
	if not list then
		return
	end
	-- Filter on what to KEEP. Filtering on a row's class is what let the old
	-- Storage panel leak an empty-state label once per refresh.
	for _, child in list:GetChildren() do
		if not child:IsA("UILayout") then
			child:Destroy()
		end
	end
end

--- Repaints a zone tab from its summary row.
local function paintTab(index: number)
	local tab = tabs[index]
	if not tab then
		return
	end

	local row = summary and summary.zones and summary.zones[index]
	local selected = index == selectedZone

	local color = INCOMPLETE
	if row then
		if row.claimable then
			color = CLAIMABLE
		elseif row.claimed then
			color = CLAIMED
		end
	end

	tab.BackgroundColor3 = color
	tab.BackgroundTransparency = if selected then 0 else 0.45

	local title = labelIn(tab, "Title")
	if title then
		title.Text = tostring(index)
		title.TextColor3 = if selected then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(206, 212, 224)
	end

	local stroke = tab:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if selected then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(24, 26, 34)
		stroke.Transparency = if selected then 0 else 0.4
	end
end

--- The bottom bar. It only ever offers the SELECTED zone's reward, so the player
--- always knows exactly what they are claiming.
local function paintClaim()
	local button, label = claimButton, claimLabel
	if not button or not label then
		return
	end

	local row = summary and summary.zones and summary.zones[selectedZone]
	local zone = ZoneConfig.Zones[selectedZone]
	if not row or not zone then
		return
	end

	local reward = IndexConfig.zoneReward(selectedZone)
	local percent = math.floor(reward.incomeBonus * 100 + 0.5)

	-- `Active` is doing real work here, not just styling: with it false the
	-- button stops firing Activated at all, so an unclaimable bar is genuinely
	-- inert rather than merely looking it. The server re-checks regardless.
	button.Selectable = row.claimable

	if row.claimable then
		button.BackgroundColor3 = CLAIMABLE
		button.BackgroundTransparency = 0
		button.Active = true
		label.Text = `CLAIM  {NumberFormat.cash(reward.cash)}  +{NumberFormat.short(reward.speed)} SPEED  +{percent}%`
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
	elseif row.claimed then
		button.BackgroundColor3 = CLAIMED
		button.BackgroundTransparency = 0.25
		button.Active = false
		label.Text = `{string.upper(zone.name)} SET CLAIMED  -  +{percent}% INCOME`
		label.TextColor3 = Color3.fromRGB(214, 220, 232)
	else
		button.BackgroundColor3 = INCOMPLETE
		button.BackgroundTransparency = 0.25
		button.Active = false
		label.Text = `{row.discovered}/{row.total} FOUND  -  REWARD {NumberFormat.cash(reward.cash)}`
		label.TextColor3 = Color3.fromRGB(176, 184, 200)
	end
end

local function renderZone()
	local pool = LootConfig.Items[selectedZone]
	if not pool or not scroll then
		return
	end

	clearGrid()
	for order, def in pool do
		local card = buildCard(def, discovered[def.id] == true, order)
		if card then
			card.Parent = scroll
		end
	end

	for index = 1, ZoneConfig.COUNT do
		paintTab(index)
	end
	paintClaim()
end

--- Header counter. Owned here rather than in HUDController so the panel has a
--- single writer.
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

local function selectZone(index: number)
	selectedZone = math.clamp(index, 1, ZoneConfig.COUNT)
	renderZone()
	if scroll then
		scroll.CanvasPosition = Vector2.new(0, 0)
	end
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

local function buildTabs(frame: Frame, source: TextButton)
	local strip = Instance.new("Frame")
	strip.Name = "ZoneTabs"
	strip.AnchorPoint = Vector2.new(0.5, 0.5)
	strip.Position = UDim2.fromScale(0.5, 0.255)
	strip.Size = UDim2.fromScale(0.94, 0.075)
	strip.BackgroundTransparency = 1
	strip.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.008, 0)
	layout.Parent = strip

	for index = 1, ZoneConfig.COUNT do
		local tab = source:Clone()
		tab.Name = `ZoneTab{index}`
		tab.LayoutOrder = index
		tab.Size = UDim2.fromScale(0.072, 1)
		tab.Position = UDim2.fromScale(0, 0)
		tab.AnchorPoint = Vector2.new(0, 0)
		tab.Text = ""
		tab.AutoButtonColor = false

		-- The clone carries the source button's aspect lock and its icon; a
		-- numbered tab wants neither.
		local aspect = tab:FindFirstChildOfClass("UIAspectRatioConstraint")
		if aspect then
			aspect:Destroy()
		end
		local body = tab:FindFirstChild("Frame")
		if body then
			body:Destroy() -- the source's inner art is an icon plate, not a label
		end

		local title = labelIn(tab, "Title")
		if not title then
			local made = Instance.new("TextLabel")
			made.Name = "Title"
			made.BackgroundTransparency = 1
			made.Size = UDim2.fromScale(1, 1)
			made.Font = Enum.Font.GothamBold
			made.TextScaled = true
			made.Parent = tab
			title = made
		else
			title.Size = UDim2.fromScale(1, 1)
			title.Position = UDim2.fromScale(0.5, 0.5)
			title.AnchorPoint = Vector2.new(0.5, 0.5)
			title.TextScaled = true
		end
		flatten(title, Color3.fromRGB(230, 236, 248))

		claimForUs(tab)
		tab.Activated:Connect(function()
			selectZone(index)
		end)

		tab.Parent = strip
		tabs[index] = tab
	end
end

local function buildClaimBar(frame: Frame, source: TextButton)
	local button = source:Clone()
	button.Name = "ClaimSet"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.fromScale(0.5, 0.915)
	button.Size = UDim2.fromScale(0.86, 0.085)
	button.Text = ""
	button.AutoButtonColor = false

	local aspect = button:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then
		aspect:Destroy()
	end
	local body = button:FindFirstChild("Frame")
	if body then
		body:Destroy()
	end

	local label = labelIn(button, "Title")
	if not label then
		local made = Instance.new("TextLabel")
		made.Name = "Title"
		made.BackgroundTransparency = 1
		made.Parent = button
		label = made
	end
	label.Size = UDim2.fromScale(0.94, 0.7)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = ""
	flatten(label, Color3.fromRGB(255, 255, 255))

	claimForUs(button)
	button.Activated:Connect(function()
		local row = summary and summary.zones and summary.zones[selectedZone]
		if not row or not row.claimable then
			return
		end
		UIAnim.punch(button, 0.3)
		Remotes.get("IndexClaimRequest"):FireServer("claim", selectedZone)
	end)

	button.Parent = frame
	claimButton = button
	claimLabel = label
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

	-- Make room for the tab strip above and the claim bar below.
	list.AnchorPoint = Vector2.new(0.5, 0.5)
	list.Position = UDim2.fromScale(0.5, 0.585)
	list.Size = UDim2.fromScale(0.94, 0.56)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 4

	local grid = list:FindFirstChildOfClass("UIGridLayout")
	if grid then
		-- Four across, two rows: exactly one zone's eight items.
		grid.CellSize = UDim2.fromScale(0.225, 0.46)
		grid.CellPadding = UDim2.fromScale(0.03, 0.04)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	end

	local opener = ui:FindFirstChild("Buttons")
	local source = opener and opener:FindFirstChild("Left") and opener.Left:FindFirstChild("Index")
	if source and source:IsA("TextButton") then
		buildTabs(frame, source)
		buildClaimBar(frame, source)
	else
		warn("[IndexController] Buttons.Left.Index missing - tabs and claim bar not built.")
	end

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
		renderZone()
	end)

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if not state or not state.index then
			return
		end
		summary = state.index
		paintCounter()

		for index = 1, ZoneConfig.COUNT do
			paintTab(index)
		end
		paintClaim()

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
				renderZone()
			end
		end)
	end

	selectZone(1)
end

return IndexController
