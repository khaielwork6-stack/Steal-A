--!strict
--[[
	QuestController
	TWO panels (retention pass; split 2026-09-18): Frames.Quests holds the
	daily/weekly quests, Frames.SeasonPass holds the season track, and each
	has its own HUD opener. The Quests button keeps its red dot.

	THIS FILE ONLY DRAWS. Progress, rewards, completion and ownership all come
	from the server (QuestPush for the panel, StatePush `retention` for the
	dot). Every button sends intent through QuestRequest / PurchaseRequest and
	the server re-checks everything.

	HOW THE PANEL IS BUILT
	Frames.Index is CLONED (never mutated) into Frames.Quests: its header bar,
	close button, plate and decoration stay, its content is removed. The pack's
	own script pairs the HUD button named "Quests" with that frame, so slide,
	blur and one-panel-at-a-time come for free (place/StarterGui/MainUI/
	LocalScript). Quest rows are ShopKit product cards; section headers are
	ShopKit headers; the tabs are cloned from the pack's Index button the same
	way IndexController builds its zone tabs.

	WHERE THE HUD BUTTON GOES
	In MainUI.Top, cloned from the BASE button (GroupGiftController's pattern),
	not in Buttons.Left: on touch that rail is forced into an exact two-by-two
	block (HUDLayoutController.fitTouchRail) and a fifth tile would push it
	into the thumbstick.

	MOBILE: the panel carries its own UIScale that undoes MainUI's phone scale
	(UpgradesController's approach), every tappable thing is at least 44 px
	after scaling, and each season tier cell is one whole button.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SeasonPassConfig = require(ReplicatedStorage.Shared.Config.SeasonPassConfig)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)
local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)

local QuestController = {}

local player = Players.LocalPlayer

local PANEL_NAME = "Quests"
--- [quests-season-split] The season track is its own window now. The pack
--- pairs a button with the Frame of the same name, so this string is both.
local SEASON_PANEL_NAME = "SeasonPass"
local NO_ART = "rbxassetid://0"
local MIN_TOUCH = 48

local WHITE = Color3.fromRGB(255, 255, 255)
local DIM_TEXT = Color3.fromRGB(190, 198, 214)
local CLAIM_GREEN = Color3.fromRGB(72, 200, 108)
local CLAIM_GREEN_DARK = Color3.fromRGB(30, 130, 60)
local CLAIMED_GREY = Color3.fromRGB(96, 104, 122)
local CLAIMED_GREY_DARK = Color3.fromRGB(56, 60, 72)
local DAILY_COLOR = Color3.fromRGB(96, 150, 255)
local DAILY_ACCENT = Color3.fromRGB(40, 70, 170)
local WEEKLY_COLOR = Color3.fromRGB(255, 190, 70)
local WEEKLY_ACCENT = Color3.fromRGB(170, 100, 20)
local PREMIUM_COLOR = Color3.fromRGB(190, 110, 255)
local PREMIUM_DARK = Color3.fromRGB(70, 30, 110)
local LOCKED_COLOR = Color3.fromRGB(44, 48, 62)
local DOT_RED = Color3.fromRGB(235, 52, 64)
local BUTTON_COLOR = Color3.fromRGB(150, 70, 230)
local BUTTON_ACCENT = Color3.fromRGB(80, 30, 140)

local ui: ScreenGui? = nil
local panel: Frame? = nil
local questsPage: Frame? = nil
local passPage: Frame? = nil
local questList: ScrollingFrame? = nil
local track: ScrollingFrame? = nil
local dot: Frame? = nil
local dotLabel: TextLabel? = nil
local opener: GuiButton? = nil
local seasonPanel: Frame? = nil
local seasonOpener: GuiButton? = nil

local latest: any = nil

-- Quest rows, keyed "daily:1" etc.
type QuestRow = { card: Frame, fill: Frame, signature: string }
local questRows: { [string]: QuestRow } = {}
local sectionGrids: { [string]: Frame } = {}
local timerLabels: { [string]: TextLabel } = {}

-- Season widgets.
type TierCell = { button: TextButton, label: TextLabel, state: TextLabel, icon: ImageLabel, glyph: TextLabel }
type TierColumn = { frame: Frame, number: TextLabel, stroke: UIStroke, free: TierCell, premium: TierCell }
local columns: { TierColumn } = {}
local bannerTimer: TextLabel? = nil
local tierLabel: TextLabel? = nil
local xpFill: Frame? = nil
local xpText: TextLabel? = nil
local premiumButton: TextButton? = nil
local premiumLabel: TextLabel? = nil

-- ==========================================================
-- SMALL HELPERS
-- ==========================================================

local function hudScale(): number
	local scale = if ui then ui:FindFirstChildOfClass("UIScale") else nil
	return if scale and scale.Scale > 0 then scale.Scale else 1
end

--- A minimum pixel size that is still MIN_TOUCH on screen after every
--- UIScale above it (MainUI's and the panel's own).
local function touchFloor(): number
	local panelScale = if panel then panel:FindFirstChildOfClass("UIScale") else nil
	local total = hudScale() * (if panelScale and panelScale.Scale > 0 then panelScale.Scale else 1)
	return math.ceil(MIN_TOUCH / math.max(total, 0.1))
end

local function minHeight(target: GuiObject)
	local limit = target:FindFirstChildOfClass("UISizeConstraint") or Instance.new("UISizeConstraint")
	limit.MinSize = Vector2.new(0, touchFloor())
	limit.Parent = target
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function label(name: string, parent: Instance, size: UDim2, position: UDim2, text: string?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Size = size
	l.Position = position
	l.Font = Enum.Font.FredokaOne
	l.TextScaled = true
	l.TextColor3 = WHITE
	l.Text = text or ""
	l.ZIndex = 6
	local outline = Instance.new("UIStroke")
	outline.Thickness = 1.5
	outline.Color = Color3.fromRGB(20, 20, 30)
	outline.Parent = l
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 30
	limit.MinTextSize = 8
	limit.Parent = l
	l.Parent = parent
	return l
end

local function gradient(parent: Instance, top: Color3, bottom: Color3): UIGradient
	local g = parent:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(top, bottom)
	g.Parent = parent
	return g
end

--- A button of our own in the pack's style. Stamped through UIAnim so the
--- pack's scanner leaves it alone (it would otherwise look for a panel with
--- the button's name).
local function makeButton(name: string, parent: Instance, text: string, color: Color3, accent: Color3): (TextButton, TextLabel)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AutoButtonColor = false
	button.Text = ""
	button.BackgroundColor3 = WHITE
	button.ZIndex = 6
	corner(button, 0.25)
	gradient(button, color, accent)
	stroke(button, Color3.fromRGB(20, 20, 30), 2)
	local caption = label("Caption", button, UDim2.fromScale(0.9, 0.7), UDim2.fromScale(0.5, 0.5), text)
	caption.ZIndex = 7
	UIAnim.bindButton(button)
	button.Parent = parent
	return button, caption
end

local function formatLeft(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local days = s // 86400
	local hours = (s % 86400) // 3600
	local minutes = (s % 3600) // 60
	if days > 0 then
		return `{days}d {hours}h`
	elseif hours > 0 then
		return `{hours}h {minutes}m`
	end
	return string.format("%dm %02ds", minutes, s % 60)
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function punch(target: GuiObject)
	if not Effects.isReduced() then
		UIAnim.punch(target, 0.2)
	end
end

-- ==========================================================
-- PANEL SKELETON
-- ==========================================================

--- Clones Frames.Index and removes its content, keeping the header bar (with
--- its close button), UI modifiers and pure decoration images.
--- One empty panel shell, titled, from the pack's Index frame. Called TWICE
--- now: Quests and Season Pass are separate windows.
local function clonePanel(frames: Instance, name: string, title: string): Frame?
	local source = frames:FindFirstChild("Index")
	if not source or not source:IsA("Frame") then
		warn(`[QuestController] Frames.Index not found - {name} is disabled.`)
		return nil
	end
	local frame = source:Clone()
	frame.Name = name
	frame.Visible = false
	for _, child in frame:GetChildren() do
		if child.Name == "Top" or child:IsA("UIComponent") then
			continue
		end
		local decorative = child:IsA("ImageLabel") and child:FindFirstChildWhichIsA("GuiObject", true) == nil
		if not decorative then
			child:Destroy()
		end
	end
	local top = frame:FindFirstChild("Top")
	local heading = top and top:FindFirstChild("Title", true)
	if heading and heading:IsA("TextLabel") then
		heading.Text = title
	end
	return frame
end


local function makePage(frame: Frame, name: string): Frame
	local page = Instance.new("Frame")
	page.Name = name
	page.BackgroundTransparency = 1
	page.AnchorPoint = Vector2.new(0.5, 0)
	-- Starts right under the header: the 0.26 it used to start at was room
	-- for the tab strip, and there are no tabs any more.
	page.Position = UDim2.fromScale(0.5, 0.14)
	page.Size = UDim2.fromScale(0.94, 0.83)
	page.ZIndex = 5
	page.Parent = frame
	return page
end

-- ==========================================================
-- QUESTS TAB
-- ==========================================================

local CELL_WIDTH = 0.47
local ROW_GAP = 8
local CARD_ASPECT = 2

local function fitSection(grid: Frame, count: number)
	local list = questList
	local layout = grid:FindFirstChildOfClass("UIGridLayout")
	if not list or not layout then
		return
	end
	local width = list.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local factor = ClipSafe.scaleChain(list)
	local cols = if width < 540 then 1 else 2
	local cellWidth = width * (if cols == 1 then 0.94 else CELL_WIDTH) / factor
	local cellHeight = math.max(190 / factor, cellWidth / CARD_ASPECT)
	local rows = math.max(1, math.ceil(count / cols))
	layout.CellSize = UDim2.fromOffset(cellWidth, cellHeight)
	grid.Size = UDim2.new(1, 0, 0, rows * cellHeight + (rows - 1) * ROW_GAP)
end

local function buildSection(list: ScrollingFrame, period: string, title: string, order: number)
	local header = ShopKit.header()
	local headerFrame: Frame
	if header then
		headerFrame = header
		local text = header:FindFirstChild("Title")
		if text and text:IsA("TextLabel") then
			text.Text = title
			text.AnchorPoint = Vector2.new(0, 0.5)
			text.Position = UDim2.fromScale(0.02, 0.5)
			text.Size = UDim2.fromScale(0.54, 0.78)
			text.TextXAlignment = Enum.TextXAlignment.Left
		end
	else
		headerFrame = Instance.new("Frame")
		headerFrame.BackgroundTransparency = 1
		label("Title", headerFrame, UDim2.fromScale(0.6, 0.9), UDim2.fromScale(0.3, 0.5), title)
	end
	headerFrame.Name = `Section_{period}`
	headerFrame.LayoutOrder = order
	headerFrame.Size = UDim2.new(1, 0, 0, 34)
	headerFrame.Parent = list

	-- The reset countdown, right-aligned on the header.
	local timer = label("ResetTimer", headerFrame, UDim2.fromScale(0.4, 0.8), UDim2.fromScale(0.78, 0.5), "")
	timer.TextXAlignment = Enum.TextXAlignment.Right
	timer.TextColor3 = DIM_TEXT
	timer.ZIndex = 8
	timerLabels[period] = timer

	local grid = Instance.new("Frame")
	grid.Name = `Grid_{period}`
	grid.LayoutOrder = order + 1
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, 100)
	grid.Parent = list
	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.new(0.02, 0, 0, ROW_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = grid
	sectionGrids[period] = grid
end

local function buildQuestsPage(frame: Frame)
	local page = makePage(frame, "QuestsPage")
	questsPage = page

	local list = Instance.new("ScrollingFrame")
	list.Name = "QuestList"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Size = UDim2.fromScale(1, 1)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ScrollBarThickness = 6
	list.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	list.ZIndex = 5
	list.Parent = page
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = list
	questList = list

	buildSection(list, "daily", "DAILY QUESTS", 10)
	buildSection(list, "weekly", "WEEKLY QUESTS", 20)

	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		for period, grid in sectionGrids do
			local rows = latest and latest[period] and latest[period].quests
			fitSection(grid, if rows then #rows else QuestConfig.COUNTS[period])
		end
	end)
	for period, grid in sectionGrids do
		fitSection(grid, QuestConfig.COUNTS[period])
	end
end

local function iconFor(kind: string): string
	local art = QuestConfig.Icons[kind]
	if art and art ~= NO_ART then
		return art
	end
	if kind == "earn" then
		return ShopKit.Icons.Cash
	elseif kind == "train" or kind == "escape" then
		return ShopKit.Icons.Speed
	end
	return ShopKit.Icons.Shop
end

local function buildQuestCard(period: string, row: any): QuestRow?
	local grid = sectionGrids[period]
	local card = ShopKit.card()
	if not grid or not card then
		return nil
	end
	PanelStyle.productCard(card)
	card.Name = `Quest_{period}_{row.index}`
	card.LayoutOrder = row.index
	card.Parent = grid

	-- The progress bar along the bottom edge of the card.
	local bar = Instance.new("Frame")
	bar.Name = "Progress"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -4)
	bar.Size = UDim2.new(0.92, 0, 0, 8)
	bar.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
	bar.BackgroundTransparency = 0.2
	bar.BorderSizePixel = 0
	bar.ZIndex = 20
	bar.Parent = card
	corner(bar, 1)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = CLAIM_GREEN
	fill.BorderSizePixel = 0
	fill.ZIndex = 21
	fill.Parent = bar
	corner(fill, 1)

	local buy = ShopKit.bindBuy(card, function()
		local rows = latest and latest[period] and latest[period].quests
		local current = if rows then rows[row.index] else nil
		if current and current.complete and not current.claimed then
			punch(card)
			Remotes.get("QuestRequest"):FireServer("claim", period, row.index)
		end
	end)
	if buy then
		minHeight(buy)
	end
	return { card = card, fill = fill, signature = "" }
end

--- THE REWARD, AS ICONS AND FIGURES (owner, 2026-09-18).
---
--- It used to be a sentence: "Reward: $23.4M" on one line and "+ 500K Speed"
--- on the next, in the same grey as the progress count above it. Three lines
--- of text of equal weight, and the one thing the player is reading the card
--- FOR - what do I get - looked like a footnote.
---
--- Each reward is now its own row: the game's OWN cash and speed icons (the
--- same two the HUD shows a balance beside, so the icon needs no learning)
--- against the figure, in the colour that currency is everywhere else.
---
--- CASH IS EXACT, with thousands separators, because "$23.4M" is a rounding
--- of the number about to land in a balance the player watches to the dollar.
--- Speed keeps its short form: its figures are already round.
---
--- The strip lives INSIDE the Description label and is sized as a fraction of
--- it, so it needs no measurement of the card and moves with it if the pack's
--- layout ever changes. The label keeps the progress line, top-aligned.
local REWARD_CASH = Color3.fromRGB(126, 240, 146)
local REWARD_SPEED = Color3.fromRGB(122, 208, 255)
local PROGRESS_SHARE = 0.36

local function rewardRow(strip: Frame, name: string, order: number, icon: string, text: string, color: Color3)
	local row = strip:FindFirstChild(name)
	if not row or not row:IsA("Frame") then
		row = Instance.new("Frame")
		local made = row :: Frame
		made.Name = name
		made.BackgroundTransparency = 1
		made.Size = UDim2.fromScale(1, 0.5)
		made.Parent = strip
		local line = Instance.new("UIListLayout")
		line.FillDirection = Enum.FillDirection.Horizontal
		line.SortOrder = Enum.SortOrder.LayoutOrder
		line.VerticalAlignment = Enum.VerticalAlignment.Center
		line.HorizontalAlignment = Enum.HorizontalAlignment.Center
		line.Padding = UDim.new(0, 4)
		line.Parent = made

		local badge = Instance.new("ImageLabel")
		badge.Name = "Icon"
		badge.LayoutOrder = 1
		badge.BackgroundTransparency = 1
		badge.ScaleType = Enum.ScaleType.Fit
		badge.Size = UDim2.fromScale(1, 1)
		badge.Parent = made
		local square = Instance.new("UIAspectRatioConstraint")
		square.AspectRatio = 1
		square.Parent = badge

		local figure = Instance.new("TextLabel")
		figure.Name = "Figure"
		figure.LayoutOrder = 2
		figure.BackgroundTransparency = 1
		figure.Font = Enum.Font.FredokaOne
		figure.TextScaled = true
		figure.TextXAlignment = Enum.TextXAlignment.Left
		figure.Size = UDim2.fromScale(0.86, 1)
		figure.Parent = made
		local edge = Instance.new("UIStroke")
		edge.Thickness = 1.4
		edge.Color = Color3.fromRGB(12, 16, 24)
		edge.Parent = figure
	end
	local made = row :: Frame
	made.LayoutOrder = order
	made.Visible = true
	local badge = made:FindFirstChild("Icon")
	if badge and badge:IsA("ImageLabel") then
		badge.Image = icon
		badge.ImageColor3 = color
	end
	local figure = made:FindFirstChild("Figure")
	if figure and figure:IsA("TextLabel") then
		figure.Text = text
		figure.TextColor3 = color
	end
end

local function paintReward(card: Frame, cash: number, speed: number)
	local body = card:FindFirstChild("Frame")
	local description = if body then body:FindFirstChild("Description", true) else nil
	if not description or not description:IsA("TextLabel") then
		return
	end
	description.TextYAlignment = Enum.TextYAlignment.Top
	-- THE LABEL IS TextScaled, so with only "0 / 3" left in it the progress
	-- count ballooned to the full height of the box and swallowed the reward
	-- rows underneath. Cap it so the text keeps to the top band the strip
	-- leaves free.
	local cap = description:FindFirstChildOfClass("UITextSizeConstraint")
		or (function()
			local made = Instance.new("UITextSizeConstraint")
			made.Parent = description
			return made
		end)()
	cap.MaxTextSize = math.max(10, math.floor(description.AbsoluteSize.Y * PROGRESS_SHARE))

	local strip = description:FindFirstChild("RewardStrip")
	if not strip or not strip:IsA("Frame") then
		local made = Instance.new("Frame")
		made.Name = "RewardStrip"
		made.BackgroundTransparency = 1
		made.Position = UDim2.fromScale(0, PROGRESS_SHARE)
		made.Size = UDim2.fromScale(1, 1 - PROGRESS_SHARE)
		made.ZIndex = description.ZIndex + 1
		made.Parent = description
		local stack = Instance.new("UIListLayout")
		stack.FillDirection = Enum.FillDirection.Vertical
		stack.SortOrder = Enum.SortOrder.LayoutOrder
		stack.HorizontalAlignment = Enum.HorizontalAlignment.Center
		stack.VerticalAlignment = Enum.VerticalAlignment.Top
		stack.Padding = UDim.new(0, 1)
		stack.Parent = made
		strip = made
	end
	local made = strip :: Frame

	local rows = if speed > 0 then 2 else 1
	for _, child in made:GetChildren() do
		if child:IsA("Frame") then
			child.Size = UDim2.fromScale(1, 1 / rows)
		end
	end
	rewardRow(made, "Cash", 1, ShopKit.Icons.Cash, `${NumberFormat.comma(cash)}`, REWARD_CASH)
	local speedRow = made:FindFirstChild("Speed")
	if speed > 0 then
		rewardRow(made, "Speed", 2, ShopKit.Icons.Speed, `+{NumberFormat.short(speed)}`, REWARD_SPEED)
	elseif speedRow and speedRow:IsA("GuiObject") then
		speedRow.Visible = false
	end
end

local function paintQuest(period: string, row: any)
	local key = `{period}:{row.index}`
	local entry: QuestRow? = questRows[key]
	local signature = `{row.id}:{row.targetText}`
	local stale = questRows[key]
	if stale and stale.signature ~= signature then
		stale.card:Destroy()
		questRows[key] = nil
		entry = nil
	end
	if not entry then
		local built = buildQuestCard(period, row)
		if not built then
			return
		end
		built.signature = signature
		questRows[key] = built
		entry = built
	end
	local card = (entry :: QuestRow).card

	local color, accent
	local price
	if row.claimed then
		color, accent, price = CLAIMED_GREY, CLAIMED_GREY_DARK, "CLAIMED"
	elseif row.complete then
		color, accent, price = CLAIM_GREEN, CLAIM_GREEN_DARK, "CLAIM!"
	else
		local percent = if row.target > 0 then math.floor(row.progress / row.target * 100) else 0
		price = `{percent}%`
		if period == "daily" then
			color, accent = DAILY_COLOR, DAILY_ACCENT
		else
			color, accent = WEEKLY_COLOR, WEEKLY_ACCENT
		end
	end
	-- THE PROGRESS LINE ONLY. The reward used to be two more lines of the same
	-- grey text under it ("Reward: $23.4M" / "+ 500K Speed"), which put the
	-- thing the card exists to advertise in the same voice as the counter
	-- above it. paintReward draws it as icons and figures instead.
	--
	-- XP is not here either. It is not a prize this quest pays - it is
	-- progress on the season track, which has its own labelled bar at the top
	-- of this panel.
	ShopKit.fillCard(card, {
		title = row.text,
		description = `{row.progressText} / {row.targetText}`,
		price = price,
		icon = iconFor(row.kind),
		color = color,
		accent = accent,
	})
	paintReward(card, row.cash or 0, row.speed or 0)

	local alpha = if row.target > 0 then math.clamp(row.progress / row.target, 0, 1) else 0
	local fill = (entry :: QuestRow).fill
	if Effects.isReduced() then
		fill.Size = UDim2.fromScale(alpha, 1)
	else
		TweenService:Create(fill, UIAnim.SETTLE, { Size = UDim2.fromScale(alpha, 1) }):Play()
	end
	fill.BackgroundColor3 = if row.claimed then CLAIMED_GREY else CLAIM_GREEN
end

local function renderQuests()
	for _, period in { "daily", "weekly" } do
		local block = latest and latest[period]
		local rows = if block then block.quests else nil
		local seen: { [string]: boolean } = {}
		if rows then
			for _, row in rows do
				paintQuest(period, row)
				seen[`{period}:{row.index}`] = true
			end
		end
		for key, entry in questRows do
			if string.sub(key, 1, #period + 1) == `{period}:` and not seen[key] then
				entry.card:Destroy()
				questRows[key] = nil
			end
		end
		local grid = sectionGrids[period]
		if grid then
			fitSection(grid, if rows then #rows else 0)
		end
	end
end

-- ==========================================================
-- SEASON PASS TAB
-- ==========================================================

local function rewardText(reward: SeasonPassConfig.Reward, amount: number): (string, string?)
	if reward.kind == "cash" then
		return NumberFormat.cash(amount), ShopKit.Icons.Cash
	elseif reward.kind == "speed" then
		return `+{NumberFormat.short(amount)} SPEED`, ShopKit.Icons.Speed
	elseif reward.kind == "guardian" then
		return `{string.upper(reward.guardianKey or "?")} GUARDIAN`, nil
	elseif reward.kind == "trail" then
		return "SEASON TRAIL", nil
	elseif reward.kind == "title" then
		return `TITLE: "{reward.title or ""}"`, nil
	end
	return "", nil
end

local GLYPHS: { [string]: string } = { guardian = "PET", trail = "TRAIL", title = "TITLE", cash = "$", speed = "SPD" }

local function buildCell(column: Frame, name: string, tier: number, track_: string, y: number): TierCell
	local button = Instance.new("TextButton")
	button.Name = name
	button.AutoButtonColor = false
	button.Text = ""
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Position = UDim2.fromScale(0.5, y)
	button.Size = UDim2.fromScale(0.94, 0.4)
	button.BackgroundColor3 = WHITE
	button.ZIndex = 6
	corner(button, 0.12)
	gradient(button, LOCKED_COLOR, LOCKED_COLOR)
	stroke(button, Color3.fromRGB(20, 20, 30), 2)
	minHeight(button)

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.3)
	icon.Size = UDim2.fromScale(0.42, 0.42)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 7
	icon.Parent = button
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = icon
	local glyph = label("Glyph", button, UDim2.fromScale(0.8, 0.3), UDim2.fromScale(0.5, 0.3), "")
	glyph.ZIndex = 8

	local text = label("Reward", button, UDim2.fromScale(0.92, 0.24), UDim2.fromScale(0.5, 0.64), "")
	local state = label("State", button, UDim2.fromScale(0.92, 0.2), UDim2.fromScale(0.5, 0.87), "")
	UIAnim.bindButton(button)
	button.Parent = column
	button.Activated:Connect(function()
		local s = latest and latest.season
		if not s then
			return
		end
		if track_ == "premium" and not s.premiumOwned then
			if s.premiumAvailable then
				Remotes.get("PurchaseRequest"):FireServer("seasonPremium")
			end
			return
		end
		local claimed = if track_ == "free" then s.claimedFree else s.claimedPremium
		if (s.tier or 0) >= tier and not (claimed and claimed[tier]) then
			punch(button)
			Remotes.get("QuestRequest"):FireServer("season", tier, track_)
		end
	end)
	return { button = button, label = text, state = state, icon = icon, glyph = glyph }
end

local function fitColumns()
	local scroller = track
	if not scroller then
		return
	end
	local height = scroller.AbsoluteSize.Y
	if height <= 0 then
		return
	end
	-- Column width follows the track's height, never below a thumb's width.
	local width = math.max(math.floor(height * 0.62), touchFloor() + 8)
	for _, column in columns do
		column.frame.Size = UDim2.new(0, width, 1, -6)
	end
end

local function buildPassPage(frame: Frame)
	local page = makePage(frame, "PassPage")
	passPage = page

	-- BANNER: art when Codex has made it, else the pack-style gradient plate.
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.BackgroundColor3 = WHITE
	banner.Size = UDim2.fromScale(1, 0.3)
	banner.ZIndex = 5
	banner.Parent = page
	corner(banner, 0.12)
	gradient(banner, Color3.fromRGB(120, 70, 200), Color3.fromRGB(40, 24, 90))
	stroke(banner, Color3.fromRGB(20, 20, 30), 2)
	if SeasonPassConfig.BANNER_IMAGE ~= NO_ART then
		local art = Instance.new("ImageLabel")
		art.Name = "Art"
		art.BackgroundTransparency = 1
		art.Image = SeasonPassConfig.BANNER_IMAGE
		art.ScaleType = Enum.ScaleType.Crop
		art.Size = UDim2.fromScale(1, 1)
		art.ZIndex = 5
		art.Parent = banner
		corner(art, 0.12)
	end
	local titleLabel = label(
		"SeasonTitle",
		banner,
		UDim2.fromScale(0.6, 0.3),
		UDim2.fromScale(0.33, 0.22),
		`SEASON {SeasonPassConfig.SEASON_NUMBER}: {string.upper(SeasonPassConfig.SEASON_NAME)}`
	)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	local timerLabel = label("SeasonTimer", banner, UDim2.fromScale(0.6, 0.2), UDim2.fromScale(0.33, 0.47), "")
	timerLabel.TextXAlignment = Enum.TextXAlignment.Left
	timerLabel.TextColor3 = DIM_TEXT
	bannerTimer = timerLabel
	tierLabel = label("Tier", banner, UDim2.fromScale(0.16, 0.26), UDim2.fromScale(0.1, 0.78), "TIER 0")

	local xpBar = Instance.new("Frame")
	xpBar.Name = "XpBar"
	xpBar.AnchorPoint = Vector2.new(0, 0.5)
	xpBar.Position = UDim2.fromScale(0.2, 0.78)
	xpBar.Size = UDim2.fromScale(0.44, 0.2)
	xpBar.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
	xpBar.BorderSizePixel = 0
	xpBar.ZIndex = 6
	xpBar.Parent = banner
	corner(xpBar, 1)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(255, 214, 64)
	fill.BorderSizePixel = 0
	fill.ZIndex = 7
	fill.Parent = xpBar
	corner(fill, 1)
	xpFill = fill
	local xpLabel = label("XpText", xpBar, UDim2.fromScale(0.96, 0.9), UDim2.fromScale(0.5, 0.5), "")
	xpLabel.ZIndex = 8
	xpText = xpLabel

	local buy, buyLabel = makeButton("BuyPremium", banner, "PREMIUM COMING SOON", PREMIUM_COLOR, PREMIUM_DARK)
	buy.AnchorPoint = Vector2.new(1, 0.5)
	buy.Position = UDim2.new(1, -10, 0.5, 0)
	buy.Size = UDim2.fromScale(0.3, 0.62)
	minHeight(buy)
	buy.Activated:Connect(function()
		local s = latest and latest.season
		if s and s.premiumAvailable and not s.premiumOwned then
			punch(buy)
			Remotes.get("PurchaseRequest"):FireServer("seasonPremium")
		end
	end)
	premiumButton = buy
	premiumLabel = buyLabel
	if SeasonPassConfig.PREMIUM_BADGE_IMAGE ~= NO_ART then
		local badge = Instance.new("ImageLabel")
		badge.Name = "PremiumBadge"
		badge.BackgroundTransparency = 1
		badge.Image = SeasonPassConfig.PREMIUM_BADGE_IMAGE
		badge.AnchorPoint = Vector2.new(0.5, 0.5)
		badge.Position = UDim2.fromScale(0, 0.5)
		badge.Size = UDim2.fromScale(0.5, 1.2)
		badge.ZIndex = 9
		badge.Parent = buy
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.Parent = badge
	end

	-- TRACK: row captions on the left, the tiers scrolling horizontally.
	local captions = Instance.new("Frame")
	captions.Name = "TrackCaptions"
	captions.BackgroundTransparency = 1
	captions.Position = UDim2.fromScale(0, 0.33)
	captions.Size = UDim2.fromScale(0.12, 0.67)
	captions.Parent = page
	local freeCaption = label("Free", captions, UDim2.fromScale(0.95, 0.2), UDim2.fromScale(0.5, 0.36), "FREE")
	freeCaption.TextColor3 = CLAIM_GREEN
	local premiumCaption = label("Premium", captions, UDim2.fromScale(0.95, 0.2), UDim2.fromScale(0.5, 0.78), "PREMIUM")
	premiumCaption.TextColor3 = PREMIUM_COLOR

	-- Nested inside the page on purpose: HUDLayoutController forces every
	-- DIRECT child ScrollingFrame of a panel to scroll vertically only.
	local scroller = Instance.new("ScrollingFrame")
	scroller.Name = "Track"
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.Position = UDim2.fromScale(0.13, 0.33)
	scroller.Size = UDim2.fromScale(0.87, 0.67)
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.X
	scroller.ScrollingDirection = Enum.ScrollingDirection.X
	scroller.ScrollBarThickness = 6
	scroller.VerticalScrollBarInset = Enum.ScrollBarInset.None
	scroller.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroller.ZIndex = 5
	scroller.Parent = page
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Parent = scroller
	track = scroller

	for tier = 1, SeasonPassConfig.TIER_COUNT do
		local column = Instance.new("Frame")
		column.Name = `Tier{tier}`
		column.LayoutOrder = tier
		column.BackgroundColor3 = Color3.fromRGB(26, 30, 46)
		column.BackgroundTransparency = 0.2
		column.Size = UDim2.new(0, 80, 1, -6)
		column.ZIndex = 5
		column.Parent = scroller
		corner(column, 0.08)
		local columnStroke = stroke(column, Color3.fromRGB(20, 20, 30), 2)
		local number = label("Number", column, UDim2.fromScale(0.9, 0.12), UDim2.fromScale(0.5, 0.08), `TIER {tier}`)
		local free = buildCell(column, "Free", tier, "free", 0.16)
		local premium = buildCell(column, "Premium", tier, "premium", 0.58)
		columns[tier] = { frame = column, number = number, stroke = columnStroke, free = free, premium = premium }
	end
	scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitColumns)
	fitColumns()
end

local function paintCell(cell: TierCell, reward: SeasonPassConfig.Reward, amount: number, tier: number, isPremium: boolean, s: any)
	local text, packIcon = rewardText(reward, amount)
	cell.label.Text = text
	local art = if reward.icon ~= NO_ART then reward.icon else packIcon
	cell.icon.Image = art or ""
	cell.icon.Visible = art ~= nil
	cell.glyph.Text = if art then "" else (GLYPHS[reward.kind] or "")

	local claimedList = if isPremium then s.claimedPremium else s.claimedFree
	local claimed = claimedList and claimedList[tier] == true
	local reached = (s.tier or 0) >= tier
	local top, bottom, state
	if claimed then
		top, bottom, state = CLAIMED_GREY, CLAIMED_GREY_DARK, "CLAIMED"
	elseif isPremium and not s.premiumAvailable then
		top, bottom, state = PREMIUM_DARK, LOCKED_COLOR, "SOON"
	elseif isPremium and not s.premiumOwned then
		top, bottom, state = PREMIUM_DARK, LOCKED_COLOR, "LOCKED"
	elseif reached then
		top, bottom, state = CLAIM_GREEN, CLAIM_GREEN_DARK, "CLAIM!"
	else
		top = if isPremium then PREMIUM_DARK else LOCKED_COLOR
		bottom, state = LOCKED_COLOR, `TIER {tier}`
	end
	gradient(cell.button, top, bottom)
	cell.state.Text = state
	cell.state.TextColor3 = if state == "CLAIM!" then Color3.fromRGB(255, 255, 160) else DIM_TEXT
	-- The lock icon, when Codex has made one, sits over a locked premium cell.
	local lock = cell.button:FindFirstChild("Lock")
	local locked = isPremium and not claimed and not s.premiumOwned and SeasonPassConfig.LOCK_IMAGE ~= NO_ART
	if locked and not lock then
		local image = Instance.new("ImageLabel")
		image.Name = "Lock"
		image.BackgroundTransparency = 1
		image.Image = SeasonPassConfig.LOCK_IMAGE
		image.AnchorPoint = Vector2.new(1, 0)
		image.Position = UDim2.fromScale(0.98, 0.02)
		image.Size = UDim2.fromScale(0.3, 0.3)
		image.ZIndex = 9
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.Parent = image
		image.Parent = cell.button
	elseif lock and not locked then
		lock:Destroy()
	end
end

local function renderSeason()
	local s = latest and latest.season
	-- No season running: the opener and its window go away entirely rather
	-- than offering an empty track.
	if seasonOpener then
		local holder = seasonOpener.Parent
		if holder and holder:IsA("GuiObject") then
			holder.Visible = s ~= nil
		end
	end
	if not s then
		if seasonPanel then
			seasonPanel.Visible = false
		end
		return
	end
	local tier = s.tier or 0
	if tierLabel then
		tierLabel.Text = `TIER {tier}`
	end
	local thresholds = SeasonPassConfig.Thresholds
	local floorXp = if tier > 0 then thresholds[tier] else 0
	local nextXp = thresholds[math.min(tier + 1, SeasonPassConfig.TIER_COUNT)]
	local xp = s.xp or 0
	if xpText and xpFill then
		if tier >= SeasonPassConfig.TIER_COUNT then
			xpText.Text = `MAX  ·  {NumberFormat.comma(xp)} XP`
			xpFill.Size = UDim2.fromScale(1, 1)
		else
			local span = math.max(1, nextXp - floorXp)
			xpText.Text = `{NumberFormat.comma(xp - floorXp)} / {NumberFormat.comma(span)} XP`
			xpFill.Size = UDim2.fromScale(math.clamp((xp - floorXp) / span, 0, 1), 1)
		end
	end
	if premiumButton and premiumLabel then
		if s.premiumOwned then
			premiumLabel.Text = "PREMIUM ACTIVE"
			gradient(premiumButton, CLAIM_GREEN, CLAIM_GREEN_DARK)
		elseif s.premiumAvailable then
			premiumLabel.Text = "BUY PREMIUM"
			gradient(premiumButton, PREMIUM_COLOR, PREMIUM_DARK)
		else
			premiumLabel.Text = "PREMIUM COMING SOON"
			gradient(premiumButton, LOCKED_COLOR, PREMIUM_DARK)
		end
	end
	for index, def in SeasonPassConfig.Tiers do
		local column = columns[index]
		if not column then
			continue
		end
		paintCell(column.free, def.free, (s.freeAmounts and s.freeAmounts[index]) or 0, index, false, s)
		paintCell(column.premium, def.premium, (s.premiumAmounts and s.premiumAmounts[index]) or 0, index, true, s)
		local current = index == math.min(tier + 1, SeasonPassConfig.TIER_COUNT)
		column.stroke.Color = if index <= tier
			then CLAIM_GREEN
			elseif current then Color3.fromRGB(255, 214, 64)
			else Color3.fromRGB(20, 20, 30)
		column.number.TextColor3 = if index <= tier then CLAIM_GREEN else WHITE
	end
end

-- ==========================================================
-- TIMERS
-- ==========================================================

local function tickTimers()
	if not latest then
		return
	end
	local now = serverNow()
	for _, period in { "daily", "weekly" } do
		local labelFor = timerLabels[period]
		local block = latest[period]
		if labelFor and block and block.resetAt then
			labelFor.Text = `NEW QUESTS IN {formatLeft(block.resetAt - now)}`
		end
	end
	local s = latest.season
	if bannerTimer and s then
		if now < (s.startsAt or 0) then
			bannerTimer.Text = `STARTS IN {formatLeft(s.startsAt - now)}`
		elseif now < (s.endsAt or 0) then
			bannerTimer.Text = `ENDS IN {formatLeft(s.endsAt - now)}`
		else
			bannerTimer.Text = "SEASON OVER - claim what you have earned!"
		end
	end
end

-- ==========================================================
-- HUD BUTTON
-- ==========================================================

local function setDot(count: number)
	local d, text = dot, dotLabel
	if not d or not text then
		return
	end
	local wasVisible = d.Visible
	d.Visible = count > 0
	text.Text = if count > 9 then "9+" else tostring(count)
	if count > 0 and not wasVisible then
		punch(d)
	end
end

--- Binds our own open/close only if the pack did not adopt the button (the
--- InventoryController pattern): binding both would toggle twice per click.
local function ensureOpenerWorks(button: GuiButton)
	task.delay(1.5, function()
		if not button.Parent or button:GetAttribute("_UIHandlerSetup") == true then
			return
		end
		warn("[QuestController] the pack did not bind the Quests button - using the built-in opener.")
		UIAnim.claimButton(button)
		button.Activated:Connect(function()
			if panel then
				panel.Visible = not panel.Visible
			end
		end)
		local top = panel and panel:FindFirstChild("Top")
		local close = top and top:FindFirstChild("Close", true)
		if close and close:IsA("GuiButton") then
			close.Activated:Connect(function()
				if panel then
					panel.Visible = false
				end
			end)
		end
	end)
end

local function buildOpener(screen: ScreenGui)
	local top = screen:FindFirstChild("Top")
	local source = top and top:FindFirstChild("Base")
	local button: GuiButton
	if source and source:IsA("TextButton") then
		local clone = source:Clone()
		clone:SetAttribute("_UIHandlerSetup", nil)
		clone:SetAttribute("AnimBound", nil)
		for _, extra in clone:GetChildren() do
			if extra.Name == "_RippleContainer" or extra:IsA("UIScale") then
				extra:Destroy()
			end
		end
		local title = clone:FindFirstChild("Title")
		if title and title:IsA("TextLabel") then
			title.Text = "QUESTS"
		end
		clone.BackgroundColor3 = BUTTON_ACCENT
		local face = clone:FindFirstChild("Frame")
		local faceGradient = face and face:FindFirstChildOfClass("UIGradient")
		if faceGradient then
			faceGradient.Color = ColorSequence.new(BUTTON_COLOR, BUTTON_ACCENT)
		end
		local faceStroke = face and face:FindFirstChildOfClass("UIStroke")
		if faceStroke then
			faceStroke.Color = Color3.fromRGB(230, 200, 255)
		end
		clone.LayoutOrder = 3
		button = clone
	else
		-- No BASE button to copy: a plain pack-coloured button under the top
		-- strip, top-right.
		local made = Instance.new("TextButton")
		made.AutoButtonColor = false
		made.Text = ""
		made.BackgroundColor3 = WHITE
		made.AnchorPoint = Vector2.new(1, 0)
		made.Position = UDim2.new(1, -12, 0, 64)
		made.Size = UDim2.fromOffset(110, 44)
		corner(made, 0.25)
		gradient(made, BUTTON_COLOR, BUTTON_ACCENT)
		stroke(made, Color3.fromRGB(20, 20, 30), 2)
		label("Title", made, UDim2.fromScale(0.9, 0.7), UDim2.fromScale(0.5, 0.5), "QUESTS")
		button = made
	end
	button.Name = PANEL_NAME
	if Device.isTouch() then
		minHeight(button)
	end

	-- Optional art (Codex): QuestConfig.HUD_ICON; 0 keeps the BASE button's art.
	local art = QuestConfig.HUD_ICON
	if art ~= NO_ART then
		local icon = button:FindFirstChild("Icon", true)
		if icon and icon:IsA("ImageLabel") then
			icon.Image = art
		end
	end

	local badge = Instance.new("Frame")
	badge.Name = "QuestDot"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.fromScale(0.95, 0.08)
	badge.Size = UDim2.fromOffset(22, 22)
	badge.BackgroundColor3 = DOT_RED
	badge.Visible = false
	badge.ZIndex = 20
	corner(badge, 1)
	stroke(badge, WHITE, 2)
	local count = label("Count", badge, UDim2.fromScale(0.8, 0.8), UDim2.fromScale(0.5, 0.5), "")
	count.ZIndex = 21
	badge.Parent = button
	dot = badge
	dotLabel = count

	if source and source:IsA("TextButton") then
		button.Parent = top
	else
		button.Parent = screen
	end
	opener = button
	ensureOpenerWorks(button)
end

-- ==========================================================
-- PANEL SCALE (UpgradesController's approach, simplified)
-- ==========================================================

-- PanelStyle handles screen fitting; keep touch floors in sync with HUD scaling.
local function applyPanelScale()
	local frame = panel
	if not frame then return end
	local scale = frame:FindFirstChildOfClass("UIScale")
	if scale then scale.Scale = 1 end
	local strip = frame:FindFirstChild("QuestTabs")
	local factor = hudScale()
	local camera = workspace.CurrentCamera
	local short = camera ~= nil and camera.ViewportSize.Y < 500
	local header = if short then 52 else 64
	if strip and strip:IsA("GuiObject") then
		minHeight(strip)
		strip.AnchorPoint = Vector2.new(0.5, 0)
		strip.Position, strip.Size = UDim2.new(0.5, 0, 0, header / factor), UDim2.new(0.7, 0, 0, 48 / factor)
	end
	for _, page in { questsPage, passPage } do
		if page then
			page.Position = UDim2.new(0.5, 0, 0, (header + 52) / factor)
			page.Size = UDim2.new(0.94, 0, 1, -(header + 60) / factor)
		end
	end
	if passPage then
		local banner = passPage:FindFirstChild("Banner") :: Frame
		local captions = passPage:FindFirstChild("TrackCaptions") :: Frame
		local h = if short then 56 else 96
		banner.Size = UDim2.new(1, 0, 0, h / factor)
		for _, part in { captions, track } do
			if part then
				part.Position = UDim2.new(if part == track then 0.13 else 0, 0, 0, (h + 4) / factor)
				part.Size = UDim2.new(if part == track then 0.87 else 0.12, 0, 1, -(h + 4) / factor)
			end
		end
	end
	for _, column in columns do
		minHeight(column.free.button)
		minHeight(column.premium.button)
	end
	fitColumns()
end


--- [quests-season-split] The Season Pass opener: a small round button in the
--- top strip beside Daily, NAMED "SeasonPass" so the pack pairs it with
--- Frames.SeasonPass and opens it with the same slide and blur as every
--- other panel. Deliberately the Daily button's shape rather than the wide
--- QUESTS plate: it is a second entry point, not a second headline.
local SEASON_FACE = 44

local function buildSeasonOpener(screen: ScreenGui)
	if screen:FindFirstChild("SeasonPassButton", true) then
		return
	end
	local top = screen:FindFirstChild("Top")

	local holder = Instance.new("Frame")
	holder.Name = "SeasonPassButton"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0, 56, 1, 0)
	-- Just left of Daily (-1), which is itself left of the gear (0).
	holder.LayoutOrder = -2
	holder.ZIndex = 5
	if top and top:IsA("GuiObject") then
		holder.Parent = top
	else
		holder.AnchorPoint = Vector2.new(1, 0)
		holder.Position = UDim2.new(1, -300, 0, 12)
		holder.Parent = screen
	end

	local button = Instance.new("ImageButton")
	button.Name = SEASON_PANEL_NAME
	button.Size = UDim2.fromOffset(SEASON_FACE, SEASON_FACE)
	button.Position = UDim2.fromScale(0.5, 0.5)
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Image = ""
	button.ZIndex = 6

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromOffset(SEASON_FACE, SEASON_FACE)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.BackgroundColor3 = WHITE
	face.Active = false
	face.ZIndex = 6
	face.Parent = button
	corner(face, 1)
	gradient(face, PREMIUM_COLOR, PREMIUM_DARK)
	stroke(face, Color3.fromRGB(24, 10, 40), 2.5)

	local art = SeasonPassConfig.HUD_ICON
	if art and art ~= NO_ART then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.Image = art
		icon.Size = UDim2.fromScale(0.74, 0.74)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.ZIndex = 7
		icon.Parent = face
	else
		-- No art yet: a crown-ish star mark, in the pack's font.
		local mark = label("Mark", face, UDim2.fromScale(0.7, 0.7), UDim2.fromScale(0.5, 0.46), "★")
		mark.ZIndex = 7
	end

	local caption = label("Caption", button, UDim2.new(1.5, 0, 0, 14), UDim2.new(0.5, 0, 1, -4), "Season")
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.ZIndex = 8

	-- >= 44 px on screen after MainUI's UIScale, like the gear and Daily.
	local uiScale = screen:FindFirstChildWhichIsA("UIScale")
	local function sizeHitArea()
		local scale = if uiScale then math.max(uiScale.Scale, 0.1) else 1
		local side = math.max(SEASON_FACE, math.ceil(SEASON_FACE / scale))
		button.Size = UDim2.fromOffset(side, side)
		holder.Size = UDim2.new(0, math.max(56, side + 4), 1, 0)
	end
	sizeHitArea()
	if uiScale then
		uiScale:GetPropertyChangedSignal("Scale"):Connect(sizeHitArea)
	end

	-- Parented LAST: the pack pairs a button with its frame when it first
	-- sees the button, and Frames.SeasonPass must already exist.
	button.Parent = holder
	seasonOpener = button
	ensureOpenerWorks(button)
end
-- ==========================================================
-- START
-- ==========================================================

local function render()
	if not panel then
		return
	end
	renderQuests()
	renderSeason()
	tickTimers()
end

function QuestController.start()
	if not QuestConfig.ENABLED and not SeasonPassConfig.ENABLED then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = playerGui:WaitForChild("MainUI", 20)
	if not screen or not screen:IsA("ScreenGui") then
		warn("[QuestController] MainUI not found - Quests disabled.")
		return
	end
	ui = screen
	local frames = screen:FindFirstChild("Frames")
	if not frames or frames:FindFirstChild(PANEL_NAME) then
		return
	end
	-- Lift the card templates before anything clears the Shop.
	ShopKit.warm()

	local frame = clonePanel(frames, PANEL_NAME, "Quests")
	if not frame then
		return
	end
	panel = frame
	buildQuestsPage(frame)
	-- Panel FIRST: the pack pairs a button with the frame of the same name
	-- when the button is registered.
	frame.Parent = frames
	PanelStyle.window(frame, 960, 610)
	buildOpener(screen)

	-- [quests-season-split] THE SECOND WINDOW. The season track was a tab
	-- inside this panel; it is its own panel now, with its own opener in the
	-- top strip beside Daily, and the tab strip is gone. Built only when a
	-- season can run at all.
	if SeasonPassConfig.ENABLED then
		local seasonFrame = clonePanel(frames, SEASON_PANEL_NAME, "Season Pass")
		if seasonFrame then
			seasonPanel = seasonFrame
			buildPassPage(seasonFrame)
			seasonFrame.Parent = frames
			PanelStyle.window(seasonFrame, 960, 610)
			buildSeasonOpener(screen)
			seasonFrame:GetPropertyChangedSignal("Visible"):Connect(function()
				if seasonFrame.Visible then
					Remotes.get("QuestRequest"):FireServer("sync")
					render()
				end
			end)
		end
	end

	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyPanelScale)
	applyPanelScale()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyPanelScale)
	end
	local scale = screen:FindFirstChildOfClass("UIScale")
	if scale then
		scale:GetPropertyChangedSignal("Scale"):Connect(applyPanelScale)
	end

	local request = Remotes.get("QuestRequest")
	Remotes.get("QuestPush").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		latest = payload
		render()
		if type(payload.claimable) == "number" then
			setDot(payload.claimable)
		end
	end)

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		local retention = state and state.retention
		if retention and type(retention.claimable) == "number" then
			setDot(retention.claimable)
		end
	end)

	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			-- No popIn here: it would drive the panel's UIScale, which is the
			-- phone-size correction (applyPanelScale). The pack slides it in.
			request:FireServer("sync")
			render()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			if frame.Visible then
				tickTimers()
			end
		end
	end)

	request:FireServer("sync")
	local _ = opener
end

return QuestController
