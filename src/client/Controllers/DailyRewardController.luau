--!strict
--[[
	DailyRewardController
	The DAILY REWARDS calendar and its HUD button.

	THE PANEL IS A CLONE OF THE PACK'S INDEX PANEL
	Taken from the PRISTINE copy in StarterGui (IndexController empties the
	live one, and a live panel the pack has closed sits parked off-screen -
	see TrailShopController), renamed "Daily" and parented into
	MainUI.Frames. The pack pairs any button NAMED "Daily" with it, so the HUD
	button gets the pack's slide, blur, one-panel-at-a-time and the close X
	for free, and HUDLayoutController grows it on touch like every panel.
	Only the header bar (with its close X), UI modifiers and pure decoration
	survive the clone (QuestController's rule); everything under the header
	is ours, drawn with Util/RewardFx in the pack's look.

	THE CALENDAR (round3-ui-rewards redesign)
	  header   the pack bar recoloured gold, titled DAILY REWARDS; under it a
	           streak badge (flame + "3 DAY STREAK") and a 7-segment bar.
	  tiles    seven glossy tiles. One row when the panel is wide enough
	           (desktop); 4 + 3 on phones, where day 7 takes two columns.
	           Days 1-6 glow brighter each day; day 7 is the gold GRAND PRIZE
	           with spinning rays and a sheen. States: claimed (dimmed, green
	           check stamp), today (pulsing gold edge, gentle bob, CLAIM! -
	           the whole tile is the touch target), locked (dimmed art, a
	           padlock, "TOMORROW" / "IN n DAYS", amounts still readable).
	  footer   clock + countdown pill, and the big CLAIM button (grey with the
	           timer while there is nothing to claim).
	All tile geometry is computed from the tile area's size (layoutTiles)
	and every decoration sits inside a clipping frame, so nothing renders
	outside the panel at any resolution.

	THE CLAIM MOMENT
	CLAIM sends DailyRewardRequest("claim") and holds today's tile in its
	"claimable" look. When the server's DailyRewardPush confirms, the tile
	pops, rays flare and confetti flies behind it, coins (and speed arrows)
	fly into the HUD counters, "+$X" counts up, RevealPop plays, and the tile
	flips over to CLAIMED. Reduced Effects: no flight, burst or bob - the
	stamp fades in and the amount shows plainly. Decoration loops (RewardFx
	LoopSet) run only while the panel is open.

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

	STUDIO PREVIEW. RewardsUIPreview("daily", payload) (DebugCommands/
	RewardsUI) opens the panel on FAKE figures; a CLAIM press then plays the
	whole moment locally and sends nothing. Closing the panel drops the fake.

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
local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RewardFx = require(ReplicatedStorage.Shared.Util.RewardFx)
local RewardUiConfig = require(ReplicatedStorage.Shared.Config.RewardUiConfig)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local AudioController = require(script.Parent.AudioController)
local UIStateController = require(script.Parent.UIStateController)

local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)

local DailyRewardController = {}

local player = Players.LocalPlayer

local PANEL_NAME = "Daily"
local CLAIM_REASON = "daily"
--- The tutorial's last stage (TutorialService STAGE.COMPLETE).
local TUTORIAL_COMPLETE = 9
--- Seconds after the state first says "claimable" before the popup may open,
--- so the join's own pops (HUD, offline modal) land first.
local POPUP_SETTLE = 2.5
--- Our content sits above anything the pack clone kept.
local Z = 10
--- Tile width / height the layout aims for.
local TILE_ASPECT = 0.62
--- Pixels between a tile's cell and its plate: room for the glow stroke and
--- the bob, inside the clipping tile area.
local TILE_PAD = 6
local BOB_PIXELS = 3

--- Gradient (top, bottom) per reward kind, at full brightness.
local KIND_COLORS = {
	cash = { Color3.fromRGB(120, 255, 150), Color3.fromRGB(16, 150, 70) },
	speed = { Color3.fromRGB(120, 215, 255), Color3.fromRGB(28, 96, 225) },
	guardian = { Color3.fromRGB(225, 170, 255), Color3.fromRGB(120, 50, 205) },
	mixed = { Color3.fromRGB(255, 244, 140), Color3.fromRGB(255, 144, 18) },
}
local DARK = Color3.fromRGB(14, 18, 40)
local GOLD = RewardFx.GOLD
local WHITE = RewardFx.WHITE
local CASH_TEXT = Color3.fromRGB(150, 255, 150)
local SPEED_TEXT = Color3.fromRGB(150, 225, 255)
local DOT_RED = Color3.fromRGB(235, 52, 64)
local HUD_TOP = Color3.fromRGB(255, 210, 90)
local HUD_BOTTOM = Color3.fromRGB(240, 130, 30)
local CLAIM_TOP = Color3.fromRGB(110, 250, 150)
local CLAIM_BOTTOM = Color3.fromRGB(20, 175, 90)
local WAIT_TOP = Color3.fromRGB(150, 158, 178)
local WAIT_BOTTOM = Color3.fromRGB(92, 98, 120)
local BAR_TOP = Color3.fromRGB(255, 226, 90)
local BAR_BOTTOM = Color3.fromRGB(255, 136, 30)
local BACK_TOP = Color3.fromRGB(70, 120, 255)
local BACK_BOTTOM = Color3.fromRGB(110, 50, 200)

--- Fallback tile art when a day has no icon of its own (Codex fills
--- DailyRewardConfig.Days[n].icon).
local KIND_ICON = {
	cash = ShopKit.Icons.Cash,
	speed = ShopKit.Icons.Speed,
	mixed = ShopKit.Icons.Cash,
	guardian = ShopKit.Icons.Shop,
}

type Tile = {
	index: number,
	grand: boolean,
	root: Frame,
	card: Frame,
	face: Frame,
	gradient: UIGradient,
	glow: UIStroke,
	edge: UIStroke,
	ribbon: Frame,
	ribbonText: TextLabel,
	halo: Frame,
	rays: Frame?,
	icon: ImageLabel,
	subIcon: ImageLabel,
	amount: TextLabel,
	caption: TextLabel,
	status: TextLabel,
	dim: Frame,
	check: Frame,
	lock: Frame,
	claimTag: Frame,
	claimText: TextLabel,
	sheen: Frame,
	hit: TextButton,
}

local panel: Frame? = nil
local tilesArea: Frame? = nil
local fxLayer: Frame? = nil
local streakLabel: TextLabel? = nil
local flame: Frame? = nil
local segments: { Frame } = {}
local timerLabel: TextLabel? = nil
local claimButton: TextButton? = nil
local claimLabel: TextLabel? = nil
local claimGradient: UIGradient? = nil
local claimSheen: Frame? = nil
local hudDot: Frame? = nil
local hudButton: GuiButton? = nil
local tiles: { [number]: Tile } = {}

--- The last DailyRewardPush payload and the last StatePush `daily` field.
local preview: any = nil
local daily: any = nil
local latestState: any = nil
--- Studio preview figures (RewardsUIPreview), shown instead of the real ones
--- while the panel is open.
local fake: any = nil

local popupDone = false
local claimableSince: number? = nil
local openedByUs = false
local claiming = false
local claimSentAt: number? = nil
--- The day whose tile keeps its "claimable" look until the claim moment
--- flips it (set on press, cleared by the flip or a timeout).
local celebratingDay: number? = nil
--- Where the panel rests when open (captured once it has been laid out).
local home: UDim2? = nil

local loops = RewardFx.loopSet()

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

--- The HUD button's caption keeps its original, lighter style.
local function hudLabel(parent: Instance, name: string, text: string, color: Color3, max: number): TextLabel
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

local function mainScale(): number
	local ui = ShopKit.mainUi()
	local scale = ui and ui:FindFirstChildWhichIsA("UIScale")
	return if scale then math.max(scale.Scale, 0.1) else 1
end

--- Keeps a button >= 44 px tall on screen after MainUI's UIScale.
local function touchMin(button: GuiButton, minWidth: number)
	local limit = Instance.new("UISizeConstraint")
	limit.Parent = button
	local function apply()
		local scale = mainScale()
		limit.MinSize = Vector2.new(math.ceil(minWidth / scale), math.ceil(44 / scale))
	end
	apply()
	local ui = ShopKit.mainUi()
	local uiScale = ui and ui:FindFirstChildWhichIsA("UIScale")
	if uiScale then
		uiScale:GetPropertyChangedSignal("Scale"):Connect(apply)
	end
end

--- Which figures to draw: the Studio preview while it is up, else the
--- server's push, else the lighter StatePush field.
local function source(): any
	return fake or preview or daily
end

local function isClaimable(): boolean
	local state = fake or daily
	return type(state) == "table" and state.claimable == true
end

local function realClaimable(): boolean
	return type(daily) == "table" and daily.claimable == true
end

--- Which cycle day is "today" and how many of this cycle are done.
local function cycleView(): (number, number)
	local data = source()
	if type(data) ~= "table" then
		return 1, 0
	end
	local streak = tonumber(data.streak) or 0
	if data.claimedToday == true and streak > 0 then
		local today = DailyRewardConfig.cycleDay(streak)
		return today, today
	end
	local today = tonumber(data.day) or 1
	return today, today - 1
end

local function dayEntry(index: number): any
	local data = source()
	local days = if type(data) == "table" and type(data.days) == "table" then data.days else nil
	local entry = if days then days[index] else nil
	return if type(entry) == "table" then entry else { kind = if index == 7 then "mixed" else "cash", cash = 0, speed = 0 }
end

local function kindOf(entry: any): string
	return if type(entry.kind) == "string" and KIND_COLORS[entry.kind] then entry.kind else "cash"
end

local function plusCash(value: number): string
	return "+" .. NumberFormat.cash(value)
end

local function plusSpeed(value: number): string
	return `+{NumberFormat.short(value)} SPEED`
end

--- Big line, small line for a day.
local function rewardLines(entry: any): (string, string, Color3)
	local cash = tonumber(entry.cash) or 0
	local speed = tonumber(entry.speed) or 0
	if entry.kind == "guardian" then
		return string.upper(tostring(entry.text or "Guardian")), "GUARDIAN", WHITE
	end
	local owned = if entry.converted == true then " (OWNED)" else ""
	if cash > 0 and speed > 0 then
		return NumberFormat.cash(cash), plusSpeed(speed) .. owned, CASH_TEXT
	elseif speed > 0 then
		return `+{NumberFormat.short(speed)}`, "SPEED" .. owned, SPEED_TEXT
	elseif cash > 0 then
		return NumberFormat.cash(cash), "CASH", CASH_TEXT
	end
	return "...", "", WHITE
end

local function tint(color: Color3, index: number): Color3
	-- Days 1-6 brighten day by day: day 1 is pulled 30% toward the dark
	-- outline, day 6 is the full colour.
	local t = math.clamp((index - 1) / 5, 0, 1)
	return color:Lerp(DARK, 0.3 * (1 - t))
end

-- ==========================================================
-- TILES
-- ==========================================================

local function makeTile(area: Frame, index: number): Tile
	local grand = index == DailyRewardConfig.CYCLE_DAYS
	local root = RewardFx.box(area, `Day{index}`, Z + 2)
	root.LayoutOrder = index
	UIAnim.scaleOf(root)

	local card, face, gradient = RewardFx.plate(root, "Card", WHITE, WHITE, Z + 2, 14, 4)
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.new(1, -TILE_PAD * 2, 1, -TILE_PAD * 2)
	local glow = RewardFx.stroke(card, 2, WHITE)

	-- Decoration behind the art: glow disc, and for day 7 the rays, in a
	-- clip the size of the face (rays turn; the clip does not).
	local art = RewardFx.box(face, "ArtClip", Z + 3)
	art.ClipsDescendants = true
	local halo = RewardFx.glow(art, "Halo", WHITE, Z + 3, 0.45)
	RewardFx.place(halo, 0.5, 0.4, 0.95, 0.5)
	local rays: Frame? = nil
	if grand then
		local burst = RewardFx.rays(art, "Rays", Color3.fromRGB(255, 250, 200), Z + 3, 0.3)
		RewardFx.place(burst, 0.5, 0.4, 1.3, 0.9)
		rays = burst
	end

	local iconId = if grand and RewardUiConfig.hasArt(RewardUiConfig.GRAND_PRIZE_ICON) then RewardUiConfig.GRAND_PRIZE_ICON else ShopKit.Icons.Cash
	local icon = RewardFx.image(face, "Icon", iconId, Z + 4)
	RewardFx.place(icon, 0.5, 0.4, 0.7, 0.3)
	local subIcon = RewardFx.image(face, "SubIcon", ShopKit.Icons.Speed, Z + 4)
	RewardFx.place(subIcon, 0.72, 0.5, 0.34, 0.13)
	subIcon.Visible = false

	-- Dims the art for claimed / locked days; the text above stays readable.
	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.fromRGB(30, 34, 52)
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = Z + 5
	dim.Visible = false
	RewardFx.corner(dim, 11)
	dim.Parent = face

	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.BackgroundColor3 = WHITE
	ribbon.BorderSizePixel = 0
	ribbon.ZIndex = Z + 6
	RewardFx.place(ribbon, 0.5, 0.1, 0.88, 0.13)
	RewardFx.corner(ribbon, 8)
	RewardFx.gradient(ribbon, Color3.fromRGB(60, 66, 110), Color3.fromRGB(26, 30, 60))
	RewardFx.stroke(ribbon, 2)
	ribbon.Parent = face
	local ribbonText = RewardFx.label(ribbon, "Text", if grand then "DAY 7 - GRAND PRIZE" else `DAY {index}`, WHITE, 20, Z + 7)
	RewardFx.place(ribbonText, 0.5, 0.5, 0.92, 0.8)
	if grand then
		RewardFx.goldText(ribbonText)
	end

	local amount = RewardFx.label(face, "Amount", "", CASH_TEXT, if grand then 40 else 32, Z + 6)
	RewardFx.place(amount, 0.5, 0.64, 0.94, 0.15)
	local caption = RewardFx.label(face, "Caption", "", WHITE, 16, Z + 6)
	RewardFx.place(caption, 0.5, 0.755, 0.9, 0.075)
	local status = RewardFx.label(face, "Status", "", Color3.fromRGB(215, 222, 240), 16, Z + 6)
	RewardFx.place(status, 0.5, 0.885, 0.9, 0.08)

	local check = RewardFx.checkMark(face, Z + 8)
	RewardFx.place(check, 0.5, 0.4, 0.62, 0.34)
	check.Rotation = -10
	check.Visible = false

	local lock = RewardFx.lock(face, Z + 8)
	RewardFx.place(lock, if grand then 0.92 else 0.85, 0.245, 0.26, 0.13)
	lock.Visible = false

	-- The CLAIM! tag is a picture of a button; the real touch target is the
	-- whole tile (`hit`), which is never smaller than a finger.
	local claimTag = Instance.new("Frame")
	claimTag.Name = "ClaimTag"
	claimTag.BackgroundColor3 = WHITE
	claimTag.BorderSizePixel = 0
	claimTag.ZIndex = Z + 8
	RewardFx.place(claimTag, 0.5, 0.885, 0.86, 0.13)
	RewardFx.corner(claimTag, 9)
	RewardFx.gradient(claimTag, CLAIM_TOP, CLAIM_BOTTOM)
	RewardFx.stroke(claimTag, 2.5)
	claimTag.Visible = false
	claimTag.Parent = face
	local claimText = RewardFx.label(claimTag, "Text", "CLAIM!", WHITE, 26, Z + 9)
	RewardFx.place(claimText, 0.5, 0.5, 0.9, 0.78)

	local sheen = RewardFx.sheen(face, Z + 9)

	local edgeHolder = RewardFx.box(card, "TodayEdge", Z + 10)
	RewardFx.corner(edgeHolder, 14)
	local edge = RewardFx.stroke(edgeHolder, 3.5, GOLD)
	edge.Enabled = false

	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = Z + 11
	hit.Visible = false
	RewardFx.corner(hit, 14)
	hit.Parent = card
	UIAnim.claimButton(hit)

	return {
		index = index,
		grand = grand,
		root = root,
		card = card,
		face = face,
		gradient = gradient,
		glow = glow,
		edge = edge,
		ribbon = ribbon,
		ribbonText = ribbonText,
		halo = halo,
		rays = rays,
		icon = icon,
		subIcon = subIcon,
		amount = amount,
		caption = caption,
		status = status,
		dim = dim,
		check = check,
		lock = lock,
		claimTag = claimTag,
		claimText = claimText,
		sheen = sheen,
		hit = hit,
	}
end

local CARD_SIZE = UDim2.new(1, -TILE_PAD * 2, 1, -TILE_PAD * 2)

local function paintTile(index: number)
	local tile = tiles[index]
	if not tile then
		return
	end
	local today, done = cycleView()
	local entry = dayEntry(index)
	local kind = kindOf(entry)
	if tile.grand and kind ~= "guardian" then
		kind = "mixed" -- day 7 is always the gold tile
	end
	local celebrating = celebratingDay == index
	local claimed = index <= done and not celebrating
	local claimable = index == today and not claimed and (isClaimable() or celebrating)
	local locked = not claimed and not claimable

	local colors = KIND_COLORS[kind]
	local top = if tile.grand then colors[1] else tint(colors[1], index)
	local bottom = if tile.grand then colors[2] else tint(colors[2], index)
	tile.gradient.Color = ColorSequence.new(top, bottom)

	-- The "rarity" glow: brighter and thicker every day, gold on day 7.
	local t = math.clamp((index - 1) / 6, 0, 1)
	tile.glow.Color = if tile.grand then GOLD else top:Lerp(WHITE, 0.35 * t)
	tile.glow.Thickness = if tile.grand then 4 else 1.5 + 2 * t
	tile.glow.Transparency = if tile.grand then 0 else 0.6 - 0.5 * t
	tile.halo.BackgroundColor3 = if tile.grand then Color3.fromRGB(255, 250, 190) else top:Lerp(WHITE, 0.5)
	tile.halo.BackgroundTransparency = if locked then 0.7 else 0.35 - 0.25 * t
	tile.edge.Enabled = claimable
	tile.edge.Transparency = 0

	local iconId = if type(entry.icon) == "string" then entry.icon else nil
	if not iconId and tile.grand and RewardUiConfig.hasArt(RewardUiConfig.GRAND_PRIZE_ICON) then
		iconId = RewardUiConfig.GRAND_PRIZE_ICON
	end
	tile.icon.Image = iconId or KIND_ICON[kind] or ShopKit.Icons.Cash
	local cash = tonumber(entry.cash) or 0
	local speed = tonumber(entry.speed) or 0
	tile.subIcon.Visible = cash > 0 and speed > 0 and iconId == nil

	local big, small, color = rewardLines(entry)
	tile.amount.Text = big
	tile.amount.TextColor3 = if tile.grand then WHITE else color
	tile.caption.Text = small
	tile.amount.TextTransparency = if claimed then 0.25 else 0
	tile.caption.TextTransparency = if claimed then 0.25 else 0

	tile.dim.Visible = claimed or locked
	tile.dim.BackgroundTransparency = if claimed then 0.35 else 0.5
	tile.check.Visible = claimed
	tile.lock.Visible = locked
	tile.claimTag.Visible = claimable
	tile.claimText.Text = if celebrating then "..." else "CLAIM!"
	tile.hit.Visible = claimable and not celebrating

	tile.status.Visible = not claimable
	if claimed then
		tile.status.Text = "CLAIMED"
		tile.status.TextColor3 = Color3.fromRGB(140, 255, 160)
	else
		local ahead = index - today
		tile.status.Text = if ahead <= 1 then "TOMORROW" else `IN {ahead} DAYS`
		tile.status.TextColor3 = Color3.fromRGB(215, 222, 240)
	end

	if not celebrating then
		tile.card.Size = CARD_SIZE
	end
end

type LayoutRow = { { index: number, units: number } }

--- Places the tiles: one row when the panel is wide, 4 + 3 (day 7 double
--- width) when it is not. Pure geometry from the area's pixel size, written
--- back as scale so the tiles follow any later resize.
local function layoutTiles()
	local area = tilesArea
	if not area then
		return
	end
	local size = area.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	local gap = math.max(4, math.floor(size.X * 0.008))

	-- Tile width/height for a row of `units` columns in `rows` rows.
	local function fit(units: number, gaps: number, rows: number): (number, number)
		local width = (size.X - gap * gaps) / units
		local height = (size.Y - gap * (rows - 1)) / rows
		width = math.min(width, height * TILE_ASPECT)
		height = math.min(height, width / TILE_ASPECT * 1.12)
		return width, height
	end
	local oneW, oneH = fit(7.5, 6, 1)
	local twoW, twoH = fit(4, 3, 2)
	-- One row only when its tiles are genuinely big: at the pack panel's size
	-- one row made ~50 px tiles with clipped text (seen in Studio).
	local oneRow = (size.X / size.Y >= 2.8 and oneW >= 64)
		or (not Device.isPhone() and oneW >= 118 and oneW * oneH >= twoW * twoH)

	local rows: { LayoutRow }
	local unitW: number, tileH: number
	if oneRow then
		rows = { {} }
		for index = 1, DailyRewardConfig.CYCLE_DAYS do
			table.insert(rows[1], { index = index, units = if index == DailyRewardConfig.CYCLE_DAYS then 1.5 else 1 })
		end
		unitW, tileH = oneW, oneH
	else
		rows = { {}, {} }
		for index = 1, DailyRewardConfig.CYCLE_DAYS do
			local row = if index <= 4 then 1 else 2
			table.insert(rows[row], { index = index, units = if index == DailyRewardConfig.CYCLE_DAYS then 2 else 1 })
		end
		unitW, tileH = twoW, twoH
	end

	local totalH = tileH * #rows + gap * (#rows - 1)
	local y = (size.Y - totalH) / 2
	for _, row in rows do
		local units, count = 0, 0
		for _, cell in row do
			units += cell.units
			count += 1
		end
		-- A double-width tile also swallows the gap it spans.
		local rowW = unitW * units + gap * (count - 1)
		for _, cell in row do
			if cell.units == 2 then
				rowW += gap
			end
		end
		local x = (size.X - rowW) / 2
		for _, cell in row do
			local tile = tiles[cell.index]
			local w = unitW * cell.units + (if cell.units == 2 then gap else 0)
			if tile then
				tile.root.AnchorPoint = Vector2.zero
				tile.root.Position = UDim2.fromScale(x / size.X, y / size.Y)
				tile.root.Size = UDim2.fromScale(w / size.X, tileH / size.Y)
			end
			x += w + gap
		end
		y += tileH + gap
	end
end

-- ==========================================================
-- HEADER / FOOTER PAINT
-- ==========================================================

local function paintStreak()
	local today, done = cycleView()
	local data = source()
	local streak = if type(data) == "table" then tonumber(data.streak) or 0 else 0
	if streakLabel then
		streakLabel.Text = if streak > 0 then `{streak} DAY STREAK` else "START A STREAK!"
	end
	local claimable = isClaimable()
	for index, segment in segments do
		local filled = index <= done
		local isToday = index == today and claimable
		segment.BackgroundTransparency = if filled or isToday then 0 else 0.55
		local gradient = segment:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = if filled
				then ColorSequence.new(BAR_TOP, BAR_BOTTOM)
				elseif isToday then ColorSequence.new(Color3.fromRGB(255, 250, 200), GOLD)
				else ColorSequence.new(Color3.fromRGB(60, 66, 100), Color3.fromRGB(34, 38, 70))
		end
	end
end

local function paintCards()
	for index = 1, DailyRewardConfig.CYCLE_DAYS do
		paintTile(index)
	end
	paintStreak()
end

local function paintStatus()
	local data = source()
	local claimable = isClaimable()
	local nextResetAt = if type(data) == "table" then tonumber(data.nextResetAt) else nil
	local remaining = if nextResetAt then nextResetAt - serverNow() else 0

	if timerLabel then
		if type(data) ~= "table" then
			timerLabel.Text = "Loading..."
		elseif claimable then
			timerLabel.Text = "Today's reward is ready!"
		else
			timerLabel.Text = `Next reward in {clock(remaining)}`
		end
	end
	if claimLabel then
		if type(data) ~= "table" then
			claimLabel.Text = "LOADING..."
		elseif claimable then
			claimLabel.Text = if celebratingDay then "..." else "CLAIM"
		else
			claimLabel.Text = `COME BACK IN {clock(remaining)}`
		end
	end
	if claimGradient then
		claimGradient.Color = if claimable
			then ColorSequence.new(CLAIM_TOP, CLAIM_BOTTOM)
			else ColorSequence.new(WAIT_TOP, WAIT_BOTTOM)
	end
	if hudDot then
		hudDot.Visible = realClaimable()
	end
	-- Past midnight but the server has not said so yet: ask (rate limited
	-- server-side; the rollover loop would push within ~20 s anyway).
	if not fake and not claimable and nextResetAt and remaining <= -2 and remaining > -4 then
		Remotes.get("DailyRewardRequest"):FireServer("preview")
	end
end

-- ==========================================================
-- LOOPS (only while the panel is open)
-- ==========================================================

local function refreshLoops()
	loops.stop()
	local frame = panel
	if not frame or not frame.Visible or Effects.isReduced() then
		return
	end
	local today = cycleView()
	for index, tile in tiles do
		local card = tile.card
		if index == today and tile.hit.Visible then
			-- Today: a pulsing gold edge and a gentle bob.
			local edge = tile.edge
			loops.play(RewardFx.yoyo(edge, 0.55, { Transparency = 0.65 }), function()
				edge.Transparency = 0
			end)
			local rest = UDim2.fromScale(0.5, 0.5)
			card.Position = rest
			loops.play(RewardFx.yoyo(card, 0.6, { Position = rest - UDim2.fromOffset(0, BOB_PIXELS) }), function()
				card.Position = rest
			end)
			loops.every(2.2, function()
				RewardFx.sweep(tile.sheen, 0.55)
			end)
		end
		local rays = tile.rays
		if rays then
			loops.play(RewardFx.spin(rays, RewardUiConfig.RAYS_TURN_SECONDS), function()
				rays.Rotation = 0
			end)
			if index ~= today or not tile.hit.Visible then
				loops.every(3.2, function()
					RewardFx.sweep(tile.sheen, 0.7)
				end)
			end
		end
	end
	local fire = flame
	if fire then
		local scale = UIAnim.scaleOf(fire)
		if scale then
			loops.play(RewardFx.yoyo(scale, 0.42, { Scale = 1.1 }), function()
				scale.Scale = 1
			end)
		end
	end
	local button, sheen = claimButton, claimSheen
	if button and sheen and isClaimable() then
		loops.every(2.4, function()
			RewardFx.sweep(sheen, 0.6)
			UIAnim.punch(button, 0.04)
		end)
	end
	local todaySegment = segments[today]
	if todaySegment and isClaimable() then
		loops.play(RewardFx.yoyo(todaySegment, 0.5, { BackgroundTransparency = 0.5 }), function()
			todaySegment.BackgroundTransparency = 0
		end)
	end
end

-- ==========================================================
-- THE CLAIM MOMENT
-- ==========================================================

--- Where `target`'s centre sits in the fx layer, in scale.
local function fxPoint(target: GuiObject): (number, number)
	local layer = fxLayer
	if not layer then
		return 0.5, 0.5
	end
	local center = target.AbsolutePosition + target.AbsoluteSize / 2
	local origin, size = layer.AbsolutePosition, layer.AbsoluteSize
	return (center.X - origin.X) / math.max(size.X, 1), (center.Y - origin.Y) / math.max(size.Y, 1)
end

local function celebrate(index: number)
	local tile = tiles[index]
	local layer = fxLayer
	if not tile or not layer then
		celebratingDay = nil
		paintCards()
		refreshLoops()
		return
	end
	local entry = dayEntry(index)
	local cash = tonumber(entry.cash) or 0
	local speed = tonumber(entry.speed) or 0
	local x, y = fxPoint(tile.root)
	AudioController.play("RevealPop")
	if claimButton then
		UIAnim.punch(claimButton, 0.15)
	end

	if Effects.isReduced() then
		-- Simple fade: the stamp appears, the amount is shown plainly.
		celebratingDay = nil
		paintTile(index)
		paintStreak()
		local disc = tile.check:FindFirstChild("Disc")
		if disc and disc:IsA("Frame") then
			disc.BackgroundTransparency = 1
			TweenService:Create(disc, TweenInfo.new(0.3), { BackgroundTransparency = 0 }):Play()
		end
		if cash > 0 then
			RewardFx.risingAmount(layer, x, y, cash, plusCash, CASH_TEXT)
		elseif speed > 0 then
			RewardFx.risingAmount(layer, x, y, speed, plusSpeed, SPEED_TEXT)
		end
		refreshLoops()
		return
	end

	UIAnim.punch(tile.root, 0.22)
	task.spawn(RewardFx.sweep, tile.sheen, 0.45)
	RewardFx.flare(layer, x, y, 0.55, Color3.fromRGB(255, 244, 170))
	RewardFx.confetti(layer, x, y, RewardUiConfig.CONFETTI_COUNT)
	local from = RewardFx.screenCenter(tile.root)
	if cash > 0 then
		RewardFx.flyToHud(from, "Cash", RewardFx.coinImage(), RewardUiConfig.COIN_COUNT)
		RewardFx.risingAmount(layer, x, y - 0.04, cash, plusCash, CASH_TEXT)
	end
	if speed > 0 then
		task.delay(if cash > 0 then 0.18 else 0, function()
			RewardFx.flyToHud(from, "Speed", ShopKit.Icons.Speed, if cash > 0 then 6 else RewardUiConfig.COIN_COUNT)
			RewardFx.risingAmount(layer, x, if cash > 0 then y + 0.08 else y - 0.04, speed, plusSpeed, SPEED_TEXT)
		end)
	end

	-- The flip: squash to nothing, turn into CLAIMED, open back out.
	task.delay(0.5, function()
		local card = tile.card
		local closeFlip = TweenService:Create(card, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = UDim2.new(0, 0, 1, -TILE_PAD * 2),
		})
		closeFlip:Play()
		closeFlip.Completed:Wait()
		celebratingDay = nil
		paintTile(index)
		paintStreak()
		card.Size = UDim2.new(0, 0, 1, -TILE_PAD * 2)
		TweenService:Create(card, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = CARD_SIZE }):Play()
		local stamp = UIAnim.scaleOf(tile.check)
		if stamp then
			stamp.Scale = 1.6
			TweenService:Create(stamp, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		paintStatus()
		refreshLoops()
	end)
end

local function requestClaim(pressed: GuiObject?)
	if claiming or celebratingDay or not isClaimable() then
		if pressed then
			UIAnim.punch(pressed, 0.06)
		end
		return
	end
	local today = cycleView()
	if pressed then
		UIAnim.punch(pressed, 0.2)
	end
	celebratingDay = today
	loops.stop()
	paintTile(today)
	paintStatus()

	if fake then
		-- Studio preview: play the whole moment on the fake figures.
		fake.claimable = false
		fake.claimedToday = true
		fake.streak = (tonumber(fake.streak) or 0) + 1
		task.delay(0.25, celebrate, today)
		return
	end

	claiming = true
	claimSentAt = os.clock()
	Remotes.get("DailyRewardRequest"):FireServer("claim")
	task.delay(2, function()
		claiming = false
	end)
	-- Refused or lost: give the tile its normal look back.
	task.delay(4, function()
		if celebratingDay == today and claimSentAt ~= nil then
			claimSentAt = nil
			celebratingDay = nil
			paintCards()
			paintStatus()
			refreshLoops()
		end
	end)
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- The pack bar in gold: every gradient on the bar itself (not on its text
--- or its close X) takes the gold ramp.
local function restyleTop(top: Instance)
	for _, item in top:GetDescendants() do
		if item:IsA("UIGradient") then
			local parent = item.Parent
			local inClose = parent ~= nil and (parent.Name == "Close" or parent:FindFirstAncestor("Close") ~= nil)
			if parent and not inClose and not parent:IsA("TextLabel") and not parent:IsA("TextButton") then
				item.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 226, 90)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 40)),
				})
			end
		end
	end
	local title = top:FindFirstChild("Title", true)
	if title and title:IsA("TextLabel") then
		title.Text = "DAILY REWARDS"
	end
	-- The cloned Index header carries the Index BOOK icon; a calendar of
	-- streaks wants the flame instead.
	for _, item in top:GetDescendants() do
		if item:IsA("ImageLabel") and item.Visible and not (item.Name == "Close" or item:FindFirstAncestor("Close")) then
			local box = item.AbsoluteSize
			if box.X > 8 and math.abs(box.X - box.Y) <= math.max(box.X, box.Y) * 0.35 and item.Parent then
				item.ImageTransparency = 1
				local flame = RewardFx.flame(item, item.ZIndex + 1)
				flame.Size = UDim2.fromScale(0.9, 0.9)
				flame.AnchorPoint = Vector2.new(0.5, 0.5)
				flame.Position = UDim2.fromScale(0.5, 0.5)
				break
			end
		end
	end
end

local function buildHeader(frame: Frame)
	local row = RewardFx.box(frame, "StreakRow", Z + 1)
	RewardFx.place(row, 0.5, 0.225, 0.92, 0.075)

	-- The streak badge: flame + count on an orange pill.
	local badge = Instance.new("Frame")
	badge.Name = "StreakBadge"
	badge.BackgroundColor3 = WHITE
	badge.BorderSizePixel = 0
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.fromScale(0, 0.5)
	badge.Size = UDim2.fromScale(0.36, 1)
	badge.ZIndex = Z + 2
	RewardFx.round(badge)
	RewardFx.gradient(badge, Color3.fromRGB(255, 150, 60), Color3.fromRGB(220, 60, 30))
	RewardFx.stroke(badge, 3)
	badge.Parent = row
	local fire = RewardFx.flame(badge, Z + 3)
	fire.AnchorPoint = Vector2.new(0, 0.5)
	fire.Position = UDim2.fromScale(0.02, 0.42)
	fire.Size = UDim2.fromScale(0.3, 1.25)
	UIAnim.scaleOf(fire)
	flame = fire
	local count = RewardFx.label(badge, "Count", "", WHITE, 26, Z + 4)
	count.AnchorPoint = Vector2.new(0, 0.5)
	count.Position = UDim2.fromScale(0.25, 0.5)
	count.Size = UDim2.fromScale(0.7, 0.72)
	RewardFx.goldText(count)
	streakLabel = count

	-- The week bar: seven segments on a dark track.
	local track = Instance.new("Frame")
	track.Name = "WeekBar"
	track.BackgroundColor3 = Color3.fromRGB(20, 24, 50)
	track.BorderSizePixel = 0
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.fromScale(1, 0.5)
	track.Size = UDim2.fromScale(0.6, 0.5)
	track.ZIndex = Z + 2
	RewardFx.round(track)
	RewardFx.stroke(track, 3)
	track.Parent = row
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 4)
	pad.PaddingTop = UDim.new(0, 3)
	pad.PaddingBottom = UDim.new(0, 3)
	pad.Parent = track
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0.012, 0)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = track
	table.clear(segments)
	for index = 1, DailyRewardConfig.CYCLE_DAYS do
		local segment = Instance.new("Frame")
		segment.Name = `Segment{index}`
		segment.BackgroundColor3 = WHITE
		segment.BorderSizePixel = 0
		segment.LayoutOrder = index
		segment.Size = UDim2.fromScale(0.13, 1)
		segment.ZIndex = Z + 3
		RewardFx.round(segment)
		RewardFx.gradient(segment, BAR_TOP, BAR_BOTTOM)
		segment.Parent = track
		segments[index] = segment
	end
end

local function buildFooter(frame: Frame)
	local row = RewardFx.box(frame, "Footer", Z + 1)
	RewardFx.place(row, 0.5, 0.9, 0.92, 0.1)

	local pill = Instance.new("Frame")
	pill.Name = "Timer"
	pill.BackgroundColor3 = Color3.fromRGB(20, 24, 50)
	pill.BackgroundTransparency = 0.1
	pill.BorderSizePixel = 0
	pill.AnchorPoint = Vector2.new(0, 0.5)
	pill.Position = UDim2.fromScale(0, 0.5)
	pill.Size = UDim2.fromScale(0.46, 0.78)
	pill.ZIndex = Z + 2
	RewardFx.round(pill)
	RewardFx.stroke(pill, 3)
	pill.Parent = row
	local face = RewardFx.clock(pill, Z + 3)
	face.AnchorPoint = Vector2.new(0, 0.5)
	face.Position = UDim2.fromScale(0.03, 0.5)
	face.Size = UDim2.fromScale(0.2, 0.74)
	local text = RewardFx.label(pill, "Text", "", WHITE, 22, Z + 3)
	text.AnchorPoint = Vector2.new(0, 0.5)
	text.Position = UDim2.fromScale(0.2, 0.5)
	text.Size = UDim2.fromScale(0.76, 0.62)
	timerLabel = text

	local button = Instance.new("TextButton")
	button.Name = "ClaimDaily"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.fromScale(1, 0.5)
	button.Size = UDim2.fromScale(0.5, 1)
	button.BackgroundColor3 = RewardFx.OUTLINE
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.ZIndex = Z + 2
	RewardFx.corner(button, 14)
	RewardFx.stroke(button, 2)
	touchMin(button, 120)
	button.Parent = row

	local buttonFace = Instance.new("Frame")
	buttonFace.Name = "Face"
	buttonFace.AnchorPoint = Vector2.new(0.5, 0.5)
	buttonFace.Position = UDim2.fromScale(0.5, 0.5)
	buttonFace.Size = UDim2.new(1, -6, 1, -6)
	buttonFace.BackgroundColor3 = WHITE
	buttonFace.BorderSizePixel = 0
	buttonFace.ZIndex = Z + 3
	RewardFx.corner(buttonFace, 11)
	claimGradient = RewardFx.gradient(buttonFace, CLAIM_TOP, CLAIM_BOTTOM)
	buttonFace.Parent = button
	local gloss = Instance.new("Frame")
	gloss.Name = "Gloss"
	gloss.BackgroundColor3 = WHITE
	gloss.BackgroundTransparency = 0.72
	gloss.BorderSizePixel = 0
	gloss.Position = UDim2.fromScale(0.03, 0.08)
	gloss.Size = UDim2.fromScale(0.94, 0.36)
	gloss.ZIndex = Z + 4
	RewardFx.corner(gloss, 8)
	gloss.Parent = buttonFace
	claimSheen = RewardFx.sheen(buttonFace, Z + 4)
	local label = RewardFx.label(buttonFace, "Label", "CLAIM", WHITE, 32, Z + 5)
	RewardFx.place(label, 0.5, 0.5, 0.9, 0.7)
	claimLabel = label

	UIAnim.claimButton(button)
	button.Activated:Connect(function()
		requestClaim(button)
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
	local sourceFrame = pristineFrames and pristineFrames:FindFirstChild("Index")
	if not sourceFrame or not sourceFrame:IsA("Frame") then
		warn("[DailyRewardController] StarterGui.MainUI.Frames.Index not found - Daily panel disabled.")
		return false
	end

	local frame = sourceFrame:Clone()
	frame.Name = PANEL_NAME
	frame.Visible = false
	-- Keep the header bar (close X), UI modifiers and pure decoration.
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
	if top then
		restyleTop(top)
		-- The header bar (and its close X) always draws over our content,
		-- whatever height the pack gave it.
		if top:IsA("GuiObject") then
			top.ZIndex = Z + 30
		end
	end

	-- A bright backdrop under everything below the header.
	local backdrop = RewardFx.plate(frame, "Backdrop", BACK_TOP, BACK_BOTTOM, Z, 16, 4)
	RewardFx.place(backdrop, 0.5, 0.585, 0.96, 0.8)

	buildHeader(frame)

	local area = RewardFx.box(frame, "Tiles", Z + 1)
	RewardFx.place(area, 0.5, 0.555, 0.94, 0.53)
	area.ClipsDescendants = true
	tilesArea = area
	for index = 1, DailyRewardConfig.CYCLE_DAYS do
		local tile = makeTile(area, index)
		tiles[index] = tile
		tile.hit.Activated:Connect(function()
			requestClaim(tile.root)
		end)
	end
	area:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutTiles)
	Device.onTouchChanged(function()
		layoutTiles()
	end)

	buildFooter(frame)

	-- Bursts, confetti and the rising amount: over the content, clipped.
	local layer = RewardFx.box(frame, "Fx", Z + 20)
	RewardFx.place(layer, 0.5, 0.585, 0.96, 0.8)
	layer.ClipsDescendants = true
	layer.Active = false
	fxLayer = layer

	-- A cleaned clone may still carry pack stamps on its own buttons (the
	-- close X); the pack must adopt them fresh for this frame.
	for _, descendant in frame:GetDescendants() do
		if descendant:IsA("GuiButton") and descendant ~= claimButton and descendant.Name ~= "Hit" then
			descendant:SetAttribute("_UIHandlerSetup", nil)
			descendant:SetAttribute("AnimBound", nil)
		end
	end

	-- Opened by the pack (HUD button) or by us: fetch fresh amounts and
	-- paint. Hidden: stop the decoration, drop a Studio preview, release
	-- our HUD claim if we held one.
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			if not fake then
				Remotes.get("DailyRewardRequest"):FireServer("preview")
			end
			layoutTiles()
			paintCards()
			paintStatus()
			refreshLoops()
			if not Effects.isReduced() then
				local order: { GuiObject } = {}
				for index = 1, DailyRewardConfig.CYCLE_DAYS do
					local tile = tiles[index]
					if tile then
						table.insert(order, tile.root)
					end
				end
				ShopKit.cascadeIn(order, 0.04)
			end
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
		else
			loops.stop()
			if fake then
				fake = nil
				celebratingDay = nil
				paintCards()
				paintStatus()
			end
			if openedByUs then
				openedByUs = false
				UIStateController.release(CLAIM_REASON)
			end
		end
	end)

	frame.Parent = frames
	PanelStyle.window(frame, 980, 610)
	panel = frame
	-- Where it rests, once the pack and the touch layout have both had their
	-- deferred pass at it.
	task.spawn(function()
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		if not frame.Visible then
			home = frame.Position
		end
		layoutTiles()
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
		local mark = hudLabel(face, "Mark", "7", Color3.fromRGB(255, 255, 255), 30)
		mark.AnchorPoint = Vector2.new(0.5, 0.5)
		mark.Position = UDim2.fromScale(0.5, 0.46)
		mark.Size = UDim2.fromScale(0.7, 0.7)
		mark.ZIndex = 7
	end

	local caption = hudLabel(button, "Caption", "Daily", Color3.fromRGB(255, 255, 255), 14)
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
	if not realClaimable() then
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

--- Studio preview (DebugCommands/RewardsUI): fake figures, panel open.
local function showPreview(payload: any)
	if type(payload) ~= "table" then
		return
	end
	fake = table.clone(payload)
	celebratingDay = nil
	claimSentAt = nil
	paintCards()
	paintStatus()
	local frame = panel
	if frame and frame.Visible then
		refreshLoops()
	else
		openPanel()
	end
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
		-- Just claimed (by this client, a moment ago): the claim moment.
		-- StatePush lands before this push, so "was it claimable" cannot be
		-- read off the old preview.
		local justClaimed = claimSentAt ~= nil and os.clock() - (claimSentAt :: number) < 6
		if fake then
			return -- the Studio preview owns the panel until it closes
		end
		if justClaimed and payload.claimedToday == true then
			claimSentAt = nil
			local day = celebratingDay or (cycleView())
			paintCards()
			paintStatus()
			celebrate(day)
			return
		end
		paintCards()
		paintStatus()
		refreshLoops()
	end)

	Remotes.get("RewardsUIPreview").OnClientEvent:Connect(function(kind, payload)
		if kind == "daily" then
			showPreview(payload)
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
			if hudDot and realClaimable() and hudButton then
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
			if not fake then
				paintCards()
				if not celebratingDay then
					refreshLoops()
				end
			end
		end
		paintStatus()
	end)

	Effects.reducedChanged:Connect(function()
		refreshLoops()
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
