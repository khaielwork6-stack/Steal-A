--!strict
--[[
	DailyRewardController
	The DAILY REWARDS panel and its HUD button.

	THE PANEL IS A CLONE OF THE PACK'S INDEX PANEL
	Taken from the PRISTINE copy in StarterGui (IndexController empties the
	live one, and a live panel the pack has closed sits parked off-screen -
	see TrailShopController), renamed "Daily" and parented into
	MainUI.Frames. The pack pairs any button NAMED "Daily" with it, so the HUD
	button gets the pack's slide, blur, one-panel-at-a-time and the close X
	for free, and HUDLayoutController grows it on touch like every panel.
	Its demo grid is cleared and refilled with seven ShopKit product cards.

	THE HUD BUTTON
	A round button in the top strip, left of the Settings gear (the rail and
	the phone 2x2 block are full - HUDLayoutController lays out exactly four
	tiles). Same construction as the gear: an invisible hit area that stays
	>= 44 px after MainUI's UIScale, a round face inside it. A red dot shows
	while today's reward is claimable.

	THE ONCE-A-SESSION POPUP
	When StatePush `daily.claimable` is true (the server only sends `daily`
	once the join has settled - DailyRewardService READY) the panel opens by
	itself, once per session, and only when nothing else is on screen: not
	while the offline-earnings modal is up, while any MainUI panel is open,
	while UIStateController holds a claim (carrying, treadmill, gift, trail
	shop), or before the tutorial is finished. The pack's open is local to its
	script, so this open mirrors it (slide up from below, blur) and holds a
	"daily" UIStateController claim to hide the HUD; the pack's close X still
	closes it, and the claim is released when the panel hides.

	DRAWS ONLY. Amounts come from DailyRewardPush (the server's own figures);
	CLAIM sends DailyRewardRequest("claim") with nothing else.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local DailyRewardConfig = require(ReplicatedStorage.Shared.Config.DailyRewardConfig)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = require(script.Parent.UIStateController)

local DailyRewardController = {}

local player = Players.LocalPlayer

local PANEL_NAME = "Daily"
local CLAIM_REASON = "daily"
--- The tutorial's last stage (TutorialService STAGE.COMPLETE).
local TUTORIAL_COMPLETE = 9
--- Seconds after the state first says "claimable" before the popup may open,
--- so the join's own pops (HUD, offline modal) land first.
local POPUP_SETTLE = 2.5

local COLORS = {
	cash = { Color3.fromRGB(96, 240, 150), Color3.fromRGB(22, 120, 70) },
	speed = { Color3.fromRGB(120, 200, 255), Color3.fromRGB(30, 90, 190) },
	mixed = { Color3.fromRGB(120, 230, 210), Color3.fromRGB(26, 110, 120) },
	guardian = { Color3.fromRGB(215, 160, 255), Color3.fromRGB(110, 50, 190) },
}
local TODAY_EDGE = Color3.fromRGB(255, 214, 64)
local CLAIMED_TINT = Color3.fromRGB(70, 76, 92)
local DOT_RED = Color3.fromRGB(235, 52, 64)
local HUD_TOP = Color3.fromRGB(255, 210, 90)
local HUD_BOTTOM = Color3.fromRGB(240, 130, 30)
local CLAIM_TOP = Color3.fromRGB(96, 240, 150)
local CLAIM_BOTTOM = Color3.fromRGB(28, 190, 110)
local WAIT_TOP = Color3.fromRGB(120, 128, 146)
local WAIT_BOTTOM = Color3.fromRGB(80, 86, 104)

--- Fallback card art when a day has no icon of its own (Codex fills
--- DailyRewardConfig.Days[n].icon).
local KIND_ICON = {
	cash = ShopKit.Icons.Cash,
	speed = ShopKit.Icons.Speed,
	mixed = ShopKit.Icons.Cash,
	guardian = ShopKit.Icons.Shop,
}

local panel: Frame? = nil
local grid: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local claimButton: TextButton? = nil
local claimLabel: TextLabel? = nil
local claimGradient: UIGradient? = nil
local hudDot: Frame? = nil
local hudButton: GuiButton? = nil
local cards: { [number]: Frame } = {}

--- The last DailyRewardPush payload and the last StatePush `daily` field.
local preview: any = nil
local daily: any = nil
local latestState: any = nil

local popupDone = false
local claimableSince: number? = nil
local openedByUs = false
local claiming = false
local claimSentAt: number? = nil
--- Where the panel rests when open (captured once it has been laid out).
local home: UDim2? = nil

-- ==========================================================
-- HELPERS
-- ==========================================================

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60)
end

local function label(parent: Instance, name: string, text: string, color: Color3, max: number): TextLabel
	local item = Instance.new("TextLabel")
	item.Name = name
	item.BackgroundTransparency = 1
	item.Font = Enum.Font.FredokaOne
	item.Text = text
	item.TextColor3 = color
	item.TextScaled = true
	item.TextStrokeTransparency = 0.35
	item.TextStrokeColor3 = Color3.fromRGB(8, 12, 28)
	item.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 9
	limit.MaxTextSize = max
	limit.Parent = item
	return item
end

local function findText(root: Instance?, name: string): TextLabel?
	if not root then
		return nil
	end
	local found = root:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

--- What a day's card says, from the server's own figures.
local function rewardText(entry: any): string
	local cash = tonumber(entry.cash) or 0
	local speed = tonumber(entry.speed) or 0
	if entry.kind == "guardian" then
		return tostring(entry.text or "Guardian")
	end
	local parts = {}
	if cash > 0 then
		table.insert(parts, NumberFormat.cash(cash))
	end
	if speed > 0 then
		table.insert(parts, `+{NumberFormat.short(speed)} Speed`)
	end
	return table.concat(parts, " + ")
end

--- Which cycle day is "today" and how many of this cycle are done.
local function cycleView(): (number, number)
	local source = preview or daily
	if type(source) ~= "table" then
		return 1, 0
	end
	local streak = tonumber(source.streak) or 0
	if source.claimedToday == true and streak > 0 then
		local today = DailyRewardConfig.cycleDay(streak)
		return today, today
	end
	local today = tonumber(source.day) or 1
	return today, today - 1
end

local function isClaimable(): boolean
	return type(daily) == "table" and daily.claimable == true
end

-- ==========================================================
-- CARDS
-- ==========================================================

--- A plain card for when the pack's product card cannot be cloned.
local function fallbackCard(): Frame
	local card = Instance.new("Frame")
	card.BackgroundColor3 = Color3.fromRGB(16, 22, 44)
	card.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = card
	local body = Instance.new("Frame")
	body.Name = "Frame"
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.5)
	body.Size = UDim2.new(1, -6, 1, -6)
	body.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	body.BorderSizePixel = 0
	body.Parent = card
	local bodyCorner = Instance.new("UICorner")
	bodyCorner.CornerRadius = UDim.new(0, 10)
	bodyCorner.Parent = body
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Parent = body
	local title = label(body, "Title", "", Color3.fromRGB(255, 255, 255), 22)
	title.Position = UDim2.fromScale(0.05, 0.04)
	title.Size = UDim2.fromScale(0.9, 0.22)
	local description = label(body, "Description", "", Color3.fromRGB(240, 244, 255), 18)
	description.Position = UDim2.fromScale(0.05, 0.72)
	description.Size = UDim2.fromScale(0.9, 0.22)
	local iconGroup = Instance.new("Frame")
	iconGroup.Name = "Icon"
	iconGroup.BackgroundTransparency = 1
	iconGroup.AnchorPoint = Vector2.new(0.5, 0.5)
	iconGroup.Position = UDim2.fromScale(0.5, 0.48)
	iconGroup.Size = UDim2.fromScale(0.42, 0.42)
	iconGroup.Parent = body
	local image = Instance.new("ImageLabel")
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromScale(1, 1)
	image.ScaleType = Enum.ScaleType.Fit
	image.Parent = iconGroup
	return card
end

local function makeCard(dayIndex: number): Frame
	local card = ShopKit.card() or fallbackCard()
	card.Name = `Day{dayIndex}`
	card.LayoutOrder = dayIndex
	card.Visible = true

	-- The TODAY ribbon and the CLAIMED stamp, drawn over the card and shown
	-- by paint().
	-- Inside the card's top-right corner: the grid is a ScrollingFrame, which
	-- clips anything hanging over a card's edge.
	local ribbon = label(card, "Today", "TODAY", Color3.fromRGB(40, 28, 8), 16)
	ribbon.BackgroundTransparency = 0
	ribbon.BackgroundColor3 = TODAY_EDGE
	ribbon.TextStrokeTransparency = 1
	ribbon.AnchorPoint = Vector2.new(1, 0)
	ribbon.Position = UDim2.fromScale(0.97, 0.04)
	ribbon.Size = UDim2.fromScale(0.4, 0.15)
	ribbon.ZIndex = 30
	ribbon.Visible = false
	local ribbonCorner = Instance.new("UICorner")
	ribbonCorner.CornerRadius = UDim.new(0.4, 0)
	ribbonCorner.Parent = ribbon

	local stamp = label(card, "Claimed", "CLAIMED", Color3.fromRGB(160, 255, 170), 22)
	stamp.AnchorPoint = Vector2.new(0.5, 0.5)
	stamp.Position = UDim2.fromScale(0.5, 0.5)
	stamp.Size = UDim2.fromScale(0.8, 0.26)
	stamp.Rotation = -12
	stamp.ZIndex = 30
	stamp.Visible = false

	-- The gold "today" outline lives on its own overlay: ShopKit.fillCard
	-- recolours the card's first UIStroke, which would otherwise be this one.
	local outline = Instance.new("Frame")
	outline.Name = "TodayOutline"
	outline.BackgroundTransparency = 1
	outline.Size = UDim2.fromScale(1, 1)
	outline.ZIndex = 29
	outline.Visible = false
	outline.Parent = card
	local outlineCorner = Instance.new("UICorner")
	outlineCorner.CornerRadius = UDim.new(0, 12)
	outlineCorner.Parent = outline
	local edge = Instance.new("UIStroke")
	edge.Thickness = 3
	edge.Color = TODAY_EDGE
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = outline
	return card
end

local function paintCards()
	local list = grid
	if not list then
		return
	end
	local today, done = cycleView()
	local days = if type(preview) == "table" and type(preview.days) == "table" then preview.days else {}
	for index = 1, DailyRewardConfig.CYCLE_DAYS do
		local existing: Frame? = cards[index]
		local card: Frame = existing or makeCard(index)
		if not existing then
			cards[index] = card
			card.Parent = list
		end
		local entry = days[index] or { kind = "cash", cash = 0, speed = 0 }
		local kind = if COLORS[entry.kind] then entry.kind else "cash"
		local claimed = index <= done
		local isToday = index == today
		local colors = COLORS[kind]
		local text = rewardText(entry)
		if entry.converted == true then
			text ..= " (owned)"
		end
		ShopKit.fillCard(card, {
			title = `Day {index}`,
			description = if text ~= "" then text else "...",
			price = "",
			color = if claimed then CLAIMED_TINT else colors[1],
			accent = if claimed then CLAIMED_TINT else colors[2],
			icon = if type(entry.icon) == "string" then entry.icon else KIND_ICON[kind],
			hidePrice = true,
		})
		local ribbon = card:FindFirstChild("Today")
		if ribbon and ribbon:IsA("GuiObject") then
			ribbon.Visible = isToday
			if ribbon:IsA("TextLabel") then
				ribbon.Text = if isToday and claimed then "DONE TODAY" else "TODAY"
			end
		end
		local stamp = card:FindFirstChild("Claimed")
		if stamp and stamp:IsA("GuiObject") then
			stamp.Visible = claimed
		end
		local outline = card:FindFirstChild("TodayOutline")
		if outline and outline:IsA("GuiObject") then
			outline.Visible = isToday
		end
		local scale = UIAnim.scaleOf(card)
		if scale then
			scale.Scale = if isToday and not claimed then 1.04 else 1
		end
	end
end

-- ==========================================================
-- STATUS LINE + CLAIM BUTTON + HUD DOT
-- ==========================================================

local function paintStatus()
	local source = preview or daily
	local claimable = isClaimable()
	local nextResetAt = if type(source) == "table" then tonumber(source.nextResetAt) else nil
	local remaining = if nextResetAt then nextResetAt - serverNow() else 0
	local streak = if type(source) == "table" then tonumber(source.streak) or 0 else 0

	if statusLabel then
		local streakText = if streak > 0 then `Streak: {streak} day{if streak == 1 then "" else "s"}` else "Log in every day for bigger rewards!"
		if type(source) ~= "table" then
			statusLabel.Text = streakText
		elseif claimable then
			statusLabel.Text = `{streakText}  ·  Today's reward is ready!`
		else
			statusLabel.Text = `{streakText}  ·  Next reward in {clock(remaining)}`
		end
	end
	if claimLabel then
		if type(source) ~= "table" then
			claimLabel.Text = "LOADING..."
		else
			claimLabel.Text = if claimable then "CLAIM" else `COME BACK IN {clock(remaining)}`
		end
	end
	if claimGradient then
		claimGradient.Color = if claimable
			then ColorSequence.new(CLAIM_TOP, CLAIM_BOTTOM)
			else ColorSequence.new(WAIT_TOP, WAIT_BOTTOM)
	end
	if hudDot then
		hudDot.Visible = claimable
	end
	-- Past midnight but the server has not said so yet: ask (rate limited
	-- server-side; the rollover loop would push within ~20 s anyway).
	if not claimable and nextResetAt and remaining <= -2 and remaining > -4 then
		Remotes.get("DailyRewardRequest"):FireServer("preview")
	end
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function buildClaim(frame: Frame)
	local button = Instance.new("TextButton")
	button.Name = "ClaimDaily"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.fromScale(0.5, 0.905)
	button.Size = UDim2.fromScale(0.6, 0.1)
	button.BackgroundColor3 = Color3.fromRGB(22, 60, 50)
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.ZIndex = 20
	button.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = button
	local edge = Instance.new("UIStroke")
	edge.Thickness = 2.5
	edge.Color = Color3.fromRGB(0, 0, 0)
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = button
	-- Never shorter than a finger on a phone.
	local size = Instance.new("UISizeConstraint")
	size.MinSize = Vector2.new(160, 44)
	size.Parent = button

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.new(1, -6, 1, -6)
	face.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	face.BorderSizePixel = 0
	face.ZIndex = 21
	face.Parent = button
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, 11)
	faceCorner.Parent = face
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(CLAIM_TOP, CLAIM_BOTTOM)
	gradient.Parent = face
	claimGradient = gradient

	local text = label(face, "Label", "CLAIM", Color3.fromRGB(255, 255, 255), 30)
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.5)
	text.Size = UDim2.fromScale(0.9, 0.72)
	text.ZIndex = 22
	claimLabel = text

	UIAnim.claimButton(button)
	button.Activated:Connect(function()
		if claiming or not isClaimable() then
			UIAnim.punch(button, 0.06)
			return
		end
		claiming = true
		claimSentAt = os.clock()
		UIAnim.punch(button, 0.2)
		Remotes.get("DailyRewardRequest"):FireServer("claim")
		task.delay(2, function()
			claiming = false
		end)
	end)
	claimButton = button
end

local function buildPanel(ui: ScreenGui): boolean
	local frames = ui:FindFirstChild("Frames")
	if not frames then
		return false
	end
	if frames:FindFirstChild(PANEL_NAME) then
		return false -- another copy of this controller already built it
	end
	local pristine = StarterGui:FindFirstChild("MainUI")
	local pristineFrames = pristine and pristine:FindFirstChild("Frames")
	local source = pristineFrames and pristineFrames:FindFirstChild("Index")
	if not source or not source:IsA("Frame") then
		warn("[DailyRewardController] StarterGui.MainUI.Frames.Index not found - Daily panel disabled.")
		return false
	end

	local frame = source:Clone()
	frame.Name = PANEL_NAME
	frame.Visible = false

	local list = frame:FindFirstChild("ScrollingFrame")
	if not list or not list:IsA("ScrollingFrame") then
		frame:Destroy()
		warn("[DailyRewardController] Index skeleton has no ScrollingFrame - Daily panel disabled.")
		return false
	end
	-- The Index demo cards go; the layout objects stay and are retuned.
	for _, child in list:GetChildren() do
		if not child:IsA("UIGridLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	list.AnchorPoint = Vector2.new(0.5, 0.5)
	list.Position = UDim2.fromScale(0.5, 0.55)
	list.Size = UDim2.fromScale(0.94, 0.56)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.None
	list.ScrollingEnabled = false
	list.ScrollBarThickness = 0
	local layout = list:FindFirstChildOfClass("UIGridLayout")
	if not layout then
		local made = Instance.new("UIGridLayout")
		made.Parent = list
		layout = made
	end
	local gridLayout = layout :: UIGridLayout
	-- Four on top, three centred below: the week at a glance, no scrolling.
	gridLayout.CellSize = UDim2.fromScale(0.23, 0.46)
	gridLayout.CellPadding = UDim2.fromScale(0.02, 0.06)
	gridLayout.FillDirection = Enum.FillDirection.Horizontal
	gridLayout.FillDirectionMaxCells = 4
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	gridLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	grid = list

	local top = frame:FindFirstChild("Top")
	local title = findText(top and top:FindFirstChild("Frame"), "Title")
	if title then
		title.Text = "Daily Rewards"
	end
	-- The Index's "0/96 Discovered" line becomes the streak / countdown line.
	statusLabel = findText(frame:FindFirstChild("Features"), "Title")
	if not statusLabel then
		local made = label(frame, "DailyStatus", "", Color3.fromRGB(236, 240, 250), 24)
		made.AnchorPoint = Vector2.new(0.5, 0.5)
		made.Position = UDim2.fromScale(0.5, 0.22)
		made.Size = UDim2.fromScale(0.9, 0.06)
		made.ZIndex = 5
		statusLabel = made
	end

	buildClaim(frame)

	-- A cleaned clone may still carry pack stamps on its own buttons (the
	-- close X); the pack must adopt them fresh for this frame.
	for _, descendant in frame:GetDescendants() do
		if descendant:IsA("GuiButton") and descendant ~= claimButton then
			descendant:SetAttribute("_UIHandlerSetup", nil)
			descendant:SetAttribute("AnimBound", nil)
		end
	end

	-- Opened by the pack (HUD button) or by us: fetch fresh amounts and
	-- paint. Hidden: release our HUD claim if we held one.
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			Remotes.get("DailyRewardRequest"):FireServer("preview")
			paintCards()
			paintStatus()
			-- Opened by the pack: once its slide has settled, the panel sits
			-- exactly where the pack rests it. That is the position our own
			-- open must use (the pack parks a closed panel off-screen).
			if not openedByUs then
				task.delay(0.6, function()
					if frame.Visible and not openedByUs then
						home = frame.Position
					end
				end)
			end
		elseif openedByUs then
			openedByUs = false
			UIStateController.release(CLAIM_REASON)
		end
	end)

	frame.Parent = frames
	panel = frame
	-- Where it rests, once the pack and the touch layout have both had their
	-- deferred pass at it.
	task.spawn(function()
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		if not frame.Visible then
			home = frame.Position
		end
	end)
	paintCards()
	return true
end

--- The HUD button: top strip, left of the gear. Named "Daily" so the pack
--- opens Frames.Daily for it.
local HUD_FACE = 44
local HUD_MIN_TARGET = 44

local function buildHudButton(ui: ScreenGui)
	if ui:FindFirstChild("DailyButton", true) then
		return
	end
	local top = ui:FindFirstChild("Top")

	local holder = Instance.new("Frame")
	holder.Name = "DailyButton"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0, 56, 1, 0)
	-- The gear is LayoutOrder 0 at the left end of the right-aligned row.
	holder.LayoutOrder = -1
	holder.ZIndex = 5
	if top and top:IsA("GuiObject") then
		holder.Parent = top
	else
		holder.AnchorPoint = Vector2.new(1, 0)
		holder.Position = UDim2.new(1, -240, 0, 12)
		holder.Parent = ui
	end

	local button = Instance.new("ImageButton")
	button.Name = PANEL_NAME
	button.Size = UDim2.fromOffset(HUD_FACE, HUD_FACE)
	button.Position = UDim2.fromScale(0.5, 0.5)
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Image = ""
	button.ZIndex = 6

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromOffset(HUD_FACE, HUD_FACE)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	face.Active = false
	face.ZIndex = 6
	face.Parent = button
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = face
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(HUD_TOP, HUD_BOTTOM)
	gradient.Parent = face
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(20, 14, 6)
	stroke.Parent = face

	if DailyRewardConfig.HUD_ICON ~= DailyRewardConfig.NO_ICON then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.Image = DailyRewardConfig.HUD_ICON
		icon.Size = UDim2.fromScale(0.78, 0.78)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.ZIndex = 7
		icon.Parent = face
	else
		-- No art yet: a bold "7" calendar mark in the pack's font.
		local mark = label(face, "Mark", "7", Color3.fromRGB(255, 255, 255), 30)
		mark.AnchorPoint = Vector2.new(0.5, 0.5)
		mark.Position = UDim2.fromScale(0.5, 0.46)
		mark.Size = UDim2.fromScale(0.7, 0.7)
		mark.ZIndex = 7
	end

	local caption = label(button, "Caption", "Daily", Color3.fromRGB(255, 255, 255), 14)
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.new(0.5, 0, 1, -6)
	caption.Size = UDim2.new(1.4, 0, 0, 14)
	caption.ZIndex = 8

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.new(0.5, math.floor(HUD_FACE * 0.36), 0.5, -math.floor(HUD_FACE * 0.36))
	dot.Size = UDim2.fromOffset(14, 14)
	dot.BackgroundColor3 = DOT_RED
	dot.Visible = false
	dot.ZIndex = 9
	dot.Parent = button
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot
	local dotStroke = Instance.new("UIStroke")
	dotStroke.Thickness = 2
	dotStroke.Color = Color3.fromRGB(255, 255, 255)
	dotStroke.Parent = dot
	hudDot = dot

	-- The hit area stays >= 44 px after MainUI's UIScale (see the gear).
	local uiScale = ui:FindFirstChildWhichIsA("UIScale")
	local function sizeHitArea()
		local scale = if uiScale then math.max(uiScale.Scale, 0.1) else 1
		local side = math.max(HUD_FACE, math.ceil(HUD_MIN_TARGET / scale))
		button.Size = UDim2.fromOffset(side, side)
		holder.Size = UDim2.new(0, math.max(56, side + 4), 1, 0)
	end
	sizeHitArea()
	if uiScale then
		uiScale:GetPropertyChangedSignal("Scale"):Connect(sizeHitArea)
	end

	-- Parented LAST, after the panel exists in Frames: the pack pairs a
	-- button with its frame when it first sees the button.
	button.Parent = holder
	hudButton = button
	UIAnim.popIn(holder, 0.6)
end

-- ==========================================================
-- THE POPUP
-- ==========================================================

--- True when nothing else is on screen that the popup would stack on.
local function screenIsFree(ui: ScreenGui): boolean
	if UIStateController.isSuppressed() then
		return false
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local offline = playerGui and playerGui:FindFirstChild("OfflineEarningsUI")
	if offline and offline:IsA("ScreenGui") and offline.Enabled then
		return false
	end
	local frames = ui:FindFirstChild("Frames")
	if frames then
		for _, child in frames:GetChildren() do
			if child:IsA("GuiObject") and child.Visible then
				return false
			end
		end
	end
	-- The trail shop / gift panels live beside Frames, in their own layer.
	local layer = ui:FindFirstChild("TrailShopLayer")
	if layer then
		for _, child in layer:GetChildren() do
			if child:IsA("GuiObject") and child.Visible then
				return false
			end
		end
	end
	local state = latestState
	if type(state) == "table" then
		local tutorial = state.tutorial
		local stage = if type(tutorial) == "table" then tonumber(tutorial.stage) else tonumber(state.tutorialStage)
		if (stage or 0) < TUTORIAL_COMPLETE then
			return false
		end
		if state.carrying ~= nil then
			return false
		end
	end
	return true
end

--- Opens the panel the way the pack does (slide up from below, blur) and
--- hides the HUD through UIStateController for as long as it is open.
local function openPanel()
	local frame = panel
	if not frame or frame.Visible then
		return
	end
	local rest = home or frame.Position
	openedByUs = true
	UIStateController.claim(CLAIM_REASON)
	frame.Visible = true
	if Effects.isReduced() then
		frame.Position = rest
	else
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize.Y else 1080
		frame.Position = rest + UDim2.fromOffset(0, viewport + 60)
		TweenService:Create(frame, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = rest }):Play()
	end
	local blur = Lighting:FindFirstChild("UIBlur")
	if blur and blur:IsA("BlurEffect") then
		TweenService:Create(blur, TweenInfo.new(0.3), { Size = 18 }):Play()
	end
end

local function tryPopup(ui: ScreenGui)
	if popupDone or not panel then
		return
	end
	if not isClaimable() then
		claimableSince = nil
		return
	end
	local now = os.clock()
	if not claimableSince then
		claimableSince = now
		return
	end
	if now - claimableSince < POPUP_SETTLE or not screenIsFree(ui) then
		return
	end
	popupDone = true
	openPanel()
end

-- ==========================================================
-- START
-- ==========================================================

function DailyRewardController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		warn("[DailyRewardController] MainUI not found - Daily rewards disabled.")
		return
	end
	-- Lift the product-card template before anything clears the Shop.
	ShopKit.warm()

	if not buildPanel(ui) then
		return
	end
	buildHudButton(ui)

	Remotes.get("DailyRewardPush").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		preview = payload
		paintCards()
		paintStatus()
		-- Just claimed (by this client, a moment ago): a little celebration
		-- on today's card. StatePush lands before this push, so "was it
		-- claimable" cannot be read off the old preview.
		local justClaimed = claimSentAt ~= nil and os.clock() - (claimSentAt :: number) < 6
		if justClaimed and payload.claimedToday == true then
			claimSentAt = nil
			local today = cycleView()
			local card = cards[today]
			if card then
				ShopKit.shine(card)
				UIAnim.punch(card, 0.15)
			end
			if claimButton then
				UIAnim.punch(claimButton, 0.15)
			end
		end
	end)

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		if type(state) ~= "table" then
			return
		end
		latestState = state
		local nextDaily = state.daily
		local changed = type(nextDaily) == "table"
			and (type(daily) ~= "table" or nextDaily.claimable ~= daily.claimable or nextDaily.streak ~= daily.streak)
		daily = nextDaily
		if changed then
			if hudDot and isClaimable() and hudButton then
				UIAnim.punch(hudButton, 0.2)
			end
			-- The preview's own flags lag a claim by one push at most; keep
			-- the cards honest with the newest state until it lands.
			if type(preview) == "table" and type(daily) == "table" then
				preview.claimable = daily.claimable
				preview.claimedToday = daily.claimedToday
				preview.streak = daily.streak
				preview.day = daily.day
				preview.nextResetAt = daily.nextResetAt
			end
			paintCards()
		end
		paintStatus()
	end)

	-- One clock for the countdown, the dot and the popup check.
	task.spawn(function()
		while true do
			task.wait(1)
			paintStatus()
			tryPopup(ui)
		end
	end)
end

return DailyRewardController
