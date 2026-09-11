--!strict
--[[
	StarterTaskController
	The three-task beginner checklist. Two presentations of the same server
	state:

	  DESKTOP  the original block in the bottom-right corner, above the
	           Nightfall pill: a heading and all three rows, each ticking as it
	           is done. Unchanged.
	  TOUCH    one compact card in the top strip, between Roblox's own buttons
	           and the Nightfall pill: "STARTER TASKS · X/3", the ONE task that
	           is next, and its reward. A finished task ticks in place and the
	           card slides to the next one.

	IT RENDERS `state.starter` AND NOTHING ELSE. The server decides what is
	done, pays for it, and stops sending the field once the checklist is
	finished for good - so this file has no completion logic, no local flags
	that could disagree with the profile, and nothing to persist. A task
	animates when the SERVER's answer for it changes from false to true.

	WHY TOUCH IS DIFFERENT
	A phone has no room for three rows anywhere that matters. The bottom-left
	is the movement thumbstick, the bottom-right is Jump and the shift lock,
	and the right edge holds the offer tiles. The one genuinely empty band is
	the top strip, and it is one line tall - so touch shows one task, not
	three. The checklist is still a single object with a single job: the
	number says how far along you are, the row says what to do next.

	NOTHING HERE EATS INPUT, on either device. Every Frame and label is
	non-Active and nothing is a button, so a finger or a click passes straight
	through to whatever is underneath.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local StarterTaskConfig = require(ReplicatedStorage.Shared.Config.StarterTaskConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local StarterTaskController = {}

local player = Players.LocalPlayer

local GOLD = Color3.fromRGB(255, 208, 96)
local INK = Color3.fromRGB(12, 10, 26)
local TEXT = Color3.fromRGB(238, 244, 255)
local TEXT_DONE = Color3.fromRGB(150, 164, 190)
local CASH = Color3.fromRGB(110, 240, 130)
local SPEED = Color3.fromRGB(110, 210, 255)
local TICK = Color3.fromRGB(126, 255, 160)

-- ==========================================================
-- SHARED
-- ==========================================================

local function outline(target: Instance, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = INK
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = target
	return stroke
end

--- EVERY LINE IS SIZED BY ITS OWN BOX, then capped.
---
--- A flat TextSize is a promise about pixels that a phone does not keep: the
--- same 13 that fits a row on one device overflowed it on another. TextScaled
--- makes the box the authority - the text can never be taller than the box it
--- is in - and the constraint stops a short word ballooning to fill a wide one.
local function fitText(label: TextLabel, maxSize: number)
	label.TextScaled = true
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 8
	limit.MaxTextSize = maxSize
	limit.Parent = label
end

local function doneCount(done: { [string]: boolean }): number
	local count = 0
	for _, task_ in StarterTaskConfig.Tasks do
		if done[task_.key] == true then
			count += 1
		end
	end
	return count
end

--- The first task not yet done, in the config's order, or nil when all are.
local function firstOpen(done: { [string]: boolean }): StarterTaskConfig.Task?
	for _, task_ in StarterTaskConfig.Tasks do
		if done[task_.key] ~= true then
			return task_
		end
	end
	return nil
end

-- ##########################################################
-- DESKTOP: THE ORIGINAL BOTTOM-RIGHT BLOCK
-- ##########################################################
--
-- Everything in this section is the desktop checklist exactly as it shipped:
-- the same position, metrics, rows and animations.

type Metrics = {
	width: number,
	heading: number,
	rowHeight: number,
	rowGap: number,
	marker: number,
	taskText: number,
	rewardText: number,
	--- FIXED PIXELS, not a share of the row, so the reward stays beside the
	--- task it belongs to at any block width.
	rewardWidth: number,
	margin: number,
}

local DESKTOP: Metrics = {
	width = 248,
	heading = 17,
	rowHeight = 27,
	rowGap = 3,
	marker = 17,
	taskText = 16,
	rewardText = 15,
	rewardWidth = 80,
	margin = 16,
}

type Row = {
	key: string,
	frame: Frame,
	marker: Frame,
	check: TextLabel,
	task: TextLabel,
	reward: TextLabel,
	done: boolean,
}

local gui: ScreenGui? = nil
local root: Frame? = nil
local heading: TextLabel? = nil
local rows: { Row } = {}
--- The completion flourish is playing. Cleared on every build, deliberately:
--- left set across a rebuild it would swallow the next completion AND block
--- the teardown, stranding a finished checklist on screen for the rest of the
--- session. What is on screen follows the server's answer, never a local latch.
local finishing = false

--- Things that share the checklist's bottom-right corner and that we can
--- actually see from here. Named rather than searched by class so a future
--- sibling does not silently start pushing the checklist around.
local function obstacles(): { GuiObject }
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return {}
	end
	local found: { GuiObject } = {}
	local mainUi = playerGui:FindFirstChild("MainUI")

	local night = mainUi and mainUi:FindFirstChild("NightTimer")
	if night and night:IsA("GuiObject") and night.Visible then
		table.insert(found, night)
	end
	local shiftUi = playerGui:FindFirstChild("ShiftLockUI")
	local shift = shiftUi and shiftUi:FindFirstChild("ShiftLock")
	if shift and shift:IsA("GuiObject") and shift.Visible then
		table.insert(found, shift)
	end
	return found
end

--- Pixels above the bottom of OUR OWN ScreenGui the checklist must start.
---
--- Measured in screen-absolute pixels on both sides and then expressed
--- relative to our own rect, which is the only way this is correct when the
--- thing being avoided lives in a ScreenGui with a different IgnoreGuiInset.
local function clearance(screen: ScreenGui, size: Metrics): number
	local floor = screen.AbsolutePosition.Y
	local height = screen.AbsoluteSize.Y
	local bottom = floor + height
	local lowest = size.margin
	if height > 0 then
		for _, thing in obstacles() do
			local top = thing.AbsolutePosition.Y
			-- Only what is genuinely low on the screen.
			if top + thing.AbsoluteSize.Y > floor + height * 0.55 then
				lowest = math.max(lowest, bottom - top + 10)
			end
		end
	end
	return lowest
end

local function reposition()
	local frame = root
	local screen = gui
	if not frame or not screen then
		return
	end
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Position = UDim2.new(1, -DESKTOP.margin, 1, -clearance(screen, DESKTOP))
end

local function buildRow(parent: Frame, task_: StarterTaskConfig.Task, order: number, size: Metrics): Row
	local frame = Instance.new("Frame")
	frame.Name = task_.key
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, size.rowHeight)
	frame.LayoutOrder = order
	frame.Parent = parent

	-- The marker: an empty ring that fills in when the row is done.
	local marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.AnchorPoint = Vector2.new(0, 0.5)
	marker.Position = UDim2.new(0, 0, 0.5, 0)
	marker.Size = UDim2.fromOffset(size.marker, size.marker)
	marker.BackgroundColor3 = Color3.fromRGB(18, 24, 44)
	marker.BackgroundTransparency = 0.25
	marker.BorderSizePixel = 0
	marker.Parent = frame
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = marker
	local ring = Instance.new("UIStroke")
	ring.Name = "Ring"
	ring.Thickness = 2
	ring.Color = Color3.fromRGB(122, 140, 176)
	ring.Parent = marker
	local markerScale = Instance.new("UIScale")
	markerScale.Parent = marker

	local check = Instance.new("TextLabel")
	check.Name = "Check"
	check.Size = UDim2.fromScale(1, 1)
	check.BackgroundTransparency = 1
	check.Font = Enum.Font.FredokaOne
	check.TextScaled = true
	check.TextColor3 = Color3.fromRGB(10, 26, 16)
	check.TextTransparency = 1
	check.Text = "✓"
	check.Parent = marker

	local reward = Instance.new("TextLabel")
	reward.Name = "Reward"
	reward.AnchorPoint = Vector2.new(1, 0.5)
	reward.Position = UDim2.new(1, 0, 0.5, 0)
	reward.Size = UDim2.new(0, size.rewardWidth, 1, 0)
	reward.BackgroundTransparency = 1
	reward.Font = Enum.Font.FredokaOne
	reward.TextXAlignment = Enum.TextXAlignment.Right
	reward.TextColor3 = if task_.kind == "cash" then CASH else SPEED
	reward.Text = task_.reward
	reward.Parent = frame
	fitText(reward, size.rewardText)
	outline(reward, 2)

	local text = Instance.new("TextLabel")
	text.Name = "Task"
	text.AnchorPoint = Vector2.new(0, 0.5)
	text.Position = UDim2.new(0, size.marker + 8, 0.5, 0)
	text.Size = UDim2.new(1, -(size.marker + 8) - size.rewardWidth - 6, 1, 0)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextColor3 = TEXT
	text.Text = task_.text
	text.Parent = frame
	fitText(text, size.taskText)
	outline(text, 2)

	return {
		key = task_.key,
		frame = frame,
		marker = marker,
		check = check,
		task = text,
		reward = reward,
		done = false,
	}
end

local function build()
	if gui then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local size = DESKTOP

	local screen = Instance.new("ScreenGui")
	screen.Name = "StarterTasksUI"
	screen.ResetOnSpawn = false
	-- Below the notification stack and the offer rail, above the world.
	screen.DisplayOrder = 7
	screen.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Checklist"
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.BackgroundTransparency = 1
	frame.Active = false
	frame.Size = UDim2.fromOffset(
		size.width,
		size.heading + 8 + #StarterTaskConfig.Tasks * (size.rowHeight + size.rowGap)
	)
	frame.Parent = screen
	local scale = Instance.new("UIScale")
	scale.Parent = frame

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, size.rowGap)
	list.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Heading"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, size.heading + 8)
	title.LayoutOrder = 0
	title.Font = Enum.Font.FredokaOne
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = GOLD
	title.Text = StarterTaskConfig.HEADING
	title.Parent = frame
	fitText(title, size.heading)
	outline(title, 2)

	table.clear(rows)
	for order, task_ in StarterTaskConfig.Tasks do
		table.insert(rows, buildRow(frame, task_, order, size))
	end

	gui = screen
	root = frame
	heading = title
	finishing = false
	-- Once now, and once more after a frame: a ScreenGui's AbsoluteSize is
	-- still zero on the frame it is created, so the first pass has nothing to
	-- measure against.
	reposition()
	task.defer(reposition)
	UIAnim.popIn(frame, 0.85)

	-- The Nightfall pill can appear after this panel does. One slow
	-- re-measure, tied to THIS panel's lifetime so it stops when it goes.
	task.spawn(function()
		while screen.Parent do
			task.wait(2)
			if root == frame then
				reposition()
			end
		end
	end)
end

--- Removes the checklist and forgets it. The one place the desktop panel is
--- destroyed, so a finished checklist and a retired one leave no remnants.
local function teardown()
	if gui then
		gui:Destroy()
	end
	gui = nil
	root = nil
	heading = nil
	table.clear(rows)
end

local function markDone(row: Row, animate: boolean)
	if row.done then
		return
	end
	row.done = true

	local ring = row.marker:FindFirstChild("Ring") :: UIStroke?
	row.marker.BackgroundColor3 = TICK
	row.marker.BackgroundTransparency = 0
	if ring then
		ring.Color = TICK
	end
	row.check.TextTransparency = 0
	row.task.TextColor3 = TEXT_DONE
	row.reward.TextColor3 = TEXT_DONE

	if not animate then
		return
	end

	-- The tick lands with a bounce, and the reward flashes its own colour once
	-- before settling grey - so the eye is told what was earned before the row
	-- goes quiet.
	local markerScale = UIAnim.scaleOf(row.marker)
	if markerScale then
		markerScale.Scale = 1.55
		TweenService:Create(markerScale, UIAnim.SPRING, { Scale = 1 }):Play()
	end
	UIAnim.punch(row.frame, 0.06)

	local flash = row.reward
	flash.TextColor3 = TICK
	TweenService:Create(flash, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextColor3 = TEXT_DONE,
	}):Play()
	local rewardScale = UIAnim.scaleOf(flash)
	if rewardScale then
		rewardScale.Scale = 1.18
		TweenService:Create(rewardScale, UIAnim.SPRING, { Scale = 1 }):Play()
	end
end

--- All three are ticked: one short flourish, and then the panel bows out.
---
--- It does NOT destroy itself. The server keeps sending the finished checklist
--- for a moment so this animation has something to play, and a panel that
--- destroyed itself first would simply be rebuilt by the next of those pushes.
--- Removal has exactly one owner: the push that says the checklist is retired.
local function finish()
	if finishing then
		return
	end
	finishing = true

	local frame, title = root, heading
	if title then
		title.Text = "ALL DONE!"
		title.TextColor3 = TICK
		UIAnim.punch(title, 0.3)
	end
	for index, row in rows do
		task.delay(index * 0.07, function()
			UIAnim.punch(row.frame, 0.12)
		end)
	end

	task.delay(1.1, function()
		if not frame then
			return
		end
		local scale = UIAnim.scaleOf(frame)
		if scale then
			TweenService:Create(scale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				Scale = 0,
			}):Play()
		end
		task.delay(0.5, function()
			if root == frame and gui then
				gui.Enabled = false
			end
		end)
	end)
end

local function applyDesktop(starter: any)
	-- Nil means the server has retired the checklist for good. The panel goes,
	-- even if the flourish is mid-play: the delay is only so the animation is
	-- not cut off, never a condition for removing it.
	if type(starter) ~= "table" or type(starter.done) ~= "table" then
		if gui then
			if finishing then
				task.delay(2, teardown)
			else
				teardown()
			end
		end
		return
	end

	local first = gui == nil
	build()

	for _, row in rows do
		if starter.done[row.key] == true then
			-- On the very first push the rows are painted, not animated: a
			-- player who completed one and rejoined before the checklist closed
			-- should find it already ticked, not watch it tick again.
			markDone(row, not first)
		end
	end

	if starter.complete == true then
		finish()
	end
end

-- ##########################################################
-- TOUCH: ONE TASK AT A TIME, IN THE TOP STRIP
-- ##########################################################

--- Card height: a small heading line and one task row. Sized to sit centred
--- on the Nightfall pill (32 tall) without reaching the stat card below.
local CARD_HEIGHT = 46
local CARD_MIN_WIDTH = 168
local CARD_MAX_WIDTH = 250
--- Breathing room from Roblox's buttons on the left and the pill on the right.
local CARD_GAP = 10
local CARD_PAD_X = 10
local HEADING_HEIGHT = 14
local ROW_HEIGHT = 22
local REWARD_WIDTH = 74

--- How long a ticked task holds before the card moves on, and how long the
--- move itself takes. Long enough to read what was earned, short enough that
--- the next objective is up while the player still cares.
local TICK_HOLD = 0.95
local SLIDE_TIME = 0.32

--- Matches the Nightfall pill (NightController), so the two read as one family
--- in the same strip rather than two unrelated widgets.
local CARD_BG = Color3.fromRGB(16, 22, 44)

type Slide = {
	key: string,
	group: CanvasGroup,
	marker: Frame,
	ring: UIStroke,
	check: TextLabel,
	task: TextLabel,
	reward: TextLabel,
}

local cGui: ScreenGui? = nil
local cCard: Frame? = nil
local cHeading: TextLabel? = nil
local cBody: Frame? = nil
local cSlide: Slide? = nil
--- The last `done` table this card has shown, so a push can be diffed into
--- "which tasks just finished" and each one ticked exactly once.
local cKnown: { [string]: boolean } = {}
--- The newest state to show, and whether a sequence is already playing it.
--- Pushes that land mid-animation only update `cLatest`; the running sequence
--- reads it when it finishes, so nothing is dropped and nothing overlaps.
local cLatest: any = nil
local cRunning = false
local cFinishing = false

local function mainUi(): Instance?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	return playerGui and playerGui:FindFirstChild("MainUI")
end

--- A HUD element's rect in THIS card's own coordinates, or nil if it is not
--- on screen.
---
--- TWO COORDINATE SPACES, and mixing them is a 58-pixel bug. Every
--- AbsolutePosition is measured from the bottom of Roblox's top bar - an
--- IgnoreGuiInset ScreenGui reports its own AbsolutePosition as (0, -58) - while
--- GuiService.TopbarInset is measured from the true top of the screen. The card
--- sits in an IgnoreGuiInset ScreenGui, whose local space IS the true screen,
--- so subtracting its AbsolutePosition turns any AbsolutePosition into the
--- same space as TopbarInset. Measured, not assumed: TopbarInset Min=(208,0),
--- a probe frame at (0,0) in an IgnoreGuiInset gui reads AbsolutePosition
--- (0,-58) on the same frame.
local function rectOf(screen: ScreenGui, name: string): (Vector2?, Vector2?)
	local ui = mainUi()
	local thing = ui and ui:FindFirstChild(name, true)
	if thing and thing:IsA("GuiObject") and thing.Visible and thing.AbsoluteSize.X > 0 then
		return thing.AbsolutePosition - screen.AbsolutePosition, thing.AbsoluteSize
	end
	return nil, nil
end

--- WHERE THE CARD GOES, MEASURED EVERY TIME.
---
--- Left edge: just right of Roblox's own menu and chat buttons, read from
--- GuiService.TopbarInset - the rect Roblox publishes as free for developer UI
--- in its top bar. Right edge: just left of the Nightfall pill. Vertically:
--- centred on the pill, so the card and the pill share one row.
---
--- If that strip is too narrow to be legible (a small phone in portrait, a
--- future pill that grows), the card drops to the line under the top bar,
--- right of the stat card, rather than squeezing to an unreadable width.
local function placeCompact()
	local card = cCard
	local screen = cGui
	if not card or not screen then
		return
	end
	-- Everything below is in the card's own local space, which for this
	-- IgnoreGuiInset ScreenGui is the true screen (see rectOf).
	local view = screen.AbsoluteSize
	if view.X <= 0 then
		return
	end

	local inset = GuiService.TopbarInset
	local left = if inset.Width > 0 then inset.Min.X + CARD_GAP else 120
	local right = if inset.Width > 0 then inset.Max.X - CARD_GAP else view.X - CARD_GAP
	local centreY = if inset.Height > 0 then inset.Min.Y + inset.Height / 2 else 30

	local pillPos, pillSize = rectOf(screen, "NightTimer")
	if pillPos and pillSize and pillPos.Y < view.Y * 0.25 then
		right = math.min(right, pillPos.X - CARD_GAP)
		centreY = pillPos.Y + pillSize.Y / 2
	end

	local top = centreY - CARD_HEIGHT / 2
	-- Never off the top edge of the screen.
	top = math.max(top, 4)

	-- Keep clear of the stat card below if the two would share any pixels.
	local statPos, statSize = rectOf(screen, "StatHUD")
	if statPos and statSize then
		local overlapsX = left < statPos.X + statSize.X and left + CARD_MIN_WIDTH > statPos.X
		if overlapsX and top + CARD_HEIGHT > statPos.Y - 4 then
			left = math.max(left, statPos.X + statSize.X + CARD_GAP)
		end
	end

	local room = right - left
	if room < CARD_MIN_WIDTH then
		-- The strip is too narrow. Next line down, right of the stat card.
		local below = (if inset.Height > 0 then inset.Max.Y else 58) + 6
		left = if statPos and statSize then statPos.X + statSize.X + CARD_GAP else CARD_GAP
		top = below
		room = view.X - left - CARD_GAP
	end

	local width = math.clamp(room, CARD_MIN_WIDTH, CARD_MAX_WIDTH)
	card.Position = UDim2.fromOffset(left, top)
	card.Size = UDim2.fromOffset(width, CARD_HEIGHT)
end

local function headingText(count: number): string
	return `{StarterTaskConfig.HEADING} · {count}/{#StarterTaskConfig.Tasks}`
end

--- One task, as a CanvasGroup so the whole row fades as a unit when it slides.
local function buildSlide(parent: Frame, task_: StarterTaskConfig.Task, done: boolean): Slide
	local group = Instance.new("CanvasGroup")
	group.Name = "Slide_" .. task_.key
	group.BackgroundTransparency = 1
	group.Size = UDim2.fromScale(1, 1)
	group.Position = UDim2.fromScale(0, 0)
	group.GroupTransparency = 0
	group.Parent = parent

	local markerSize = ROW_HEIGHT - 6
	local marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.AnchorPoint = Vector2.new(0, 0.5)
	marker.Position = UDim2.new(0, 0, 0.5, 0)
	marker.Size = UDim2.fromOffset(markerSize, markerSize)
	marker.BackgroundColor3 = Color3.fromRGB(18, 24, 44)
	marker.BackgroundTransparency = 0.25
	marker.BorderSizePixel = 0
	marker.Parent = group
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = marker
	local ring = Instance.new("UIStroke")
	ring.Name = "Ring"
	ring.Thickness = 2
	ring.Color = Color3.fromRGB(122, 140, 176)
	ring.Parent = marker
	local markerScale = Instance.new("UIScale")
	markerScale.Parent = marker

	local check = Instance.new("TextLabel")
	check.Name = "Check"
	check.Size = UDim2.fromScale(1, 1)
	check.BackgroundTransparency = 1
	check.Font = Enum.Font.FredokaOne
	check.TextScaled = true
	check.TextColor3 = Color3.fromRGB(10, 26, 16)
	check.TextTransparency = 1
	check.Text = "✓"
	check.Parent = marker

	local reward = Instance.new("TextLabel")
	reward.Name = "Reward"
	reward.AnchorPoint = Vector2.new(1, 0.5)
	reward.Position = UDim2.new(1, 0, 0.5, 0)
	reward.Size = UDim2.new(0, REWARD_WIDTH, 1, 0)
	reward.BackgroundTransparency = 1
	reward.Font = Enum.Font.FredokaOne
	reward.TextXAlignment = Enum.TextXAlignment.Right
	reward.TextColor3 = if task_.kind == "cash" then CASH else SPEED
	reward.Text = task_.reward
	reward.Parent = group
	fitText(reward, 15)
	outline(reward, 1.5)
	local rewardScale = Instance.new("UIScale")
	rewardScale.Parent = reward

	local text = Instance.new("TextLabel")
	text.Name = "Task"
	text.AnchorPoint = Vector2.new(0, 0.5)
	text.Position = UDim2.new(0, markerSize + 7, 0.5, 0)
	text.Size = UDim2.new(1, -(markerSize + 7) - REWARD_WIDTH - 6, 1, 0)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextColor3 = TEXT
	text.Text = task_.text
	text.Parent = group
	fitText(text, 16)
	outline(text, 1.5)

	local slide: Slide = {
		key = task_.key,
		group = group,
		marker = marker,
		ring = ring,
		check = check,
		task = text,
		reward = reward,
	}
	if done then
		marker.BackgroundColor3 = TICK
		marker.BackgroundTransparency = 0
		ring.Color = TICK
		check.TextTransparency = 0
		text.TextColor3 = TEXT_DONE
		reward.TextColor3 = TEXT_DONE
	end
	return slide
end

local function buildCompact()
	if cGui then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "StarterTasksUI"
	screen.ResetOnSpawn = false
	-- The top strip IS the inset band; draw in screen-absolute pixels so the
	-- positions measured from TopbarInset and the pill mean the same thing.
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 7
	screen.Parent = playerGui

	local card = Instance.new("Frame")
	card.Name = "Checklist"
	card.BackgroundColor3 = CARD_BG
	card.BackgroundTransparency = 0.1
	card.BorderSizePixel = 0
	card.Active = false
	card.Size = UDim2.fromOffset(CARD_MAX_WIDTH, CARD_HEIGHT)
	card.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0.2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card
	local scale = Instance.new("UIScale")
	scale.Parent = card

	local title = Instance.new("TextLabel")
	title.Name = "Heading"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(CARD_PAD_X, 4)
	title.Size = UDim2.new(1, -CARD_PAD_X * 2, 0, HEADING_HEIGHT)
	title.Font = Enum.Font.FredokaOne
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = GOLD
	title.Text = headingText(0)
	title.Parent = card
	fitText(title, 13)
	outline(title, 1.5)

	-- The row lives in a clipped body so a slide moving in or out is cut off
	-- at the card's edge rather than drawing over the pill or the stat card.
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.ClipsDescendants = true
	body.Position = UDim2.fromOffset(CARD_PAD_X, 4 + HEADING_HEIGHT + 2)
	body.Size = UDim2.new(1, -CARD_PAD_X * 2, 0, ROW_HEIGHT)
	body.Parent = card

	cGui = screen
	cCard = card
	cHeading = title
	cBody = body
	cSlide = nil
	cFinishing = false
	placeCompact()
	task.defer(placeCompact)
	UIAnim.popIn(card, 0.85)

	-- The pill and the stat card can land after this card does, and a phone
	-- can rotate without every device firing the viewport signal.
	task.spawn(function()
		while screen.Parent do
			task.wait(2)
			if cCard == card then
				placeCompact()
			end
		end
	end)
end

local function teardownCompact()
	if cGui then
		cGui:Destroy()
	end
	cGui = nil
	cCard = nil
	cHeading = nil
	cBody = nil
	cSlide = nil
	table.clear(cKnown)
	cRunning = false
	cFinishing = false
end

--- Swaps the visible task. With `animate`, the old row slides up and fades
--- while the new one rises from below; without, it is simply replaced. Yields
--- for the length of the slide when animating.
local function showTask(task_: StarterTaskConfig.Task, done: boolean, animate: boolean)
	local body = cBody
	if not body then
		return
	end
	if cSlide and cSlide.key == task_.key then
		return
	end

	local incoming = buildSlide(body, task_, done)
	local outgoing = cSlide
	cSlide = incoming

	if not animate or not outgoing then
		if outgoing then
			outgoing.group:Destroy()
		end
		return
	end

	local slideInfo = TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	incoming.group.Position = UDim2.fromScale(0, 1)
	incoming.group.GroupTransparency = 1
	TweenService:Create(outgoing.group, slideInfo, {
		Position = UDim2.fromScale(0, -1),
		GroupTransparency = 1,
	}):Play()
	TweenService:Create(incoming.group, slideInfo, {
		Position = UDim2.fromScale(0, 0),
		GroupTransparency = 0,
	}):Play()
	task.wait(SLIDE_TIME)
	outgoing.group:Destroy()
end

--- Ticks the visible task: the marker fills and springs, the reward flashes
--- green and swells, the whole card gives a small punch, and the heading's
--- count steps up. The same beat as a desktop row, on one row. Yields for the
--- hold so the next step starts only once this one has been seen.
local function tickTask(count: number)
	local slide = cSlide
	if not slide then
		return
	end
	slide.marker.BackgroundColor3 = TICK
	slide.marker.BackgroundTransparency = 0
	slide.ring.Color = TICK
	slide.check.TextTransparency = 0
	slide.task.TextColor3 = TEXT_DONE

	local markerScale = UIAnim.scaleOf(slide.marker)
	if markerScale then
		markerScale.Scale = 1.7
		TweenService:Create(markerScale, UIAnim.SPRING, { Scale = 1 }):Play()
	end

	slide.reward.TextColor3 = TICK
	TweenService:Create(slide.reward, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextColor3 = TEXT_DONE,
	}):Play()
	local rewardScale = UIAnim.scaleOf(slide.reward)
	if rewardScale then
		rewardScale.Scale = 1.28
		TweenService:Create(rewardScale, UIAnim.SPRING, { Scale = 1 }):Play()
	end

	if cCard then
		UIAnim.punch(cCard, 0.07)
	end
	local title = cHeading
	if title then
		title.Text = headingText(count)
		UIAnim.punch(title, 0.2)
	end
	task.wait(TICK_HOLD)
end

--- All three done: the heading turns green and reads ALL DONE!, the card
--- bounces, and then it shrinks away. Like the desktop panel it never destroys
--- itself - the push that retires the checklist does.
local function finishCompact()
	if cFinishing then
		return
	end
	cFinishing = true
	local card, title = cCard, cHeading
	if title then
		title.Text = "ALL DONE!"
		title.TextColor3 = TICK
		UIAnim.punch(title, 0.3)
	end
	if card then
		UIAnim.punch(card, 0.12)
	end
	task.delay(1.1, function()
		if not card or cCard ~= card then
			return
		end
		local scale = UIAnim.scaleOf(card)
		if scale then
			TweenService:Create(scale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				Scale = 0,
			}):Play()
		end
		task.delay(0.5, function()
			if cCard == card and cGui then
				cGui.Enabled = false
			end
		end)
	end)
end

--- Plays everything between what the card last showed and the newest push,
--- one step at a time. Runs until it has caught up with `cLatest`, so a push
--- landing mid-slide is picked up at the end rather than starting a second,
--- overlapping sequence.
local function runCompact()
	if cRunning then
		return
	end
	cRunning = true
	while cGui and cLatest do
		local starter = cLatest
		local done: { [string]: boolean } = starter.done

		-- THE CARD FOLLOWS THE SERVER BOTH WAYS. A task only ever goes back to
		-- not-done through a debug reset, but when it does the count and the
		-- shown task must follow it rather than keep a stale tick.
		local pruned = false
		for key in cKnown do
			if done[key] ~= true then
				cKnown[key] = nil
				pruned = true
			end
		end
		if pruned and cHeading then
			cHeading.Text = headingText(doneCount(cKnown))
			cHeading.TextColor3 = GOLD
		end

		-- Tasks that finished since the card last looked, in order. A task
		-- done out of order (training before the first reveal) is brought on
		-- screen and ticked too, so no reward is ever earned silently.
		local newly: { StarterTaskConfig.Task } = {}
		for _, task_ in StarterTaskConfig.Tasks do
			if done[task_.key] == true and cKnown[task_.key] ~= true then
				table.insert(newly, task_)
			end
		end

		if #newly == 0 then
			-- Nothing new: make sure the right task is up, and stop.
			local next_ = firstOpen(done)
			if next_ then
				showTask(next_, false, cSlide ~= nil)
			end
			if starter.complete == true then
				finishCompact()
			end
			if cLatest == starter then
				break
			end
			continue
		end

		for _, task_ in newly do
			showTask(task_, false, true)
			cKnown[task_.key] = true
			tickTask(doneCount(cKnown))
		end
	end
	cRunning = false
end

local function applyCompact(starter: any)
	if type(starter) ~= "table" or type(starter.done) ~= "table" then
		if cGui then
			cLatest = nil
			if cFinishing then
				task.delay(2, teardownCompact)
			else
				teardownCompact()
			end
		end
		return
	end

	if not cGui then
		-- THE FIRST PUSH IS PAINTED, NOT ANIMATED. A player who ticked a task
		-- and rejoined should find the card already at the right task and count,
		-- not watch it tick again.
		buildCompact()
		table.clear(cKnown)
		for key, value in starter.done do
			if value == true then
				cKnown[key] = true
			end
		end
		if cHeading then
			cHeading.Text = headingText(doneCount(cKnown))
		end
		local next_ = firstOpen(cKnown)
		if next_ then
			showTask(next_, false, false)
		elseif starter.complete == true then
			-- Everything was already done: show the last task ticked while the
			-- card says ALL DONE! and bows out.
			local last = StarterTaskConfig.Tasks[#StarterTaskConfig.Tasks]
			showTask(last, true, false)
			finishCompact()
		end
		cLatest = nil
		return
	end

	cLatest = starter
	task.spawn(runCompact)
end

-- ==========================================================
-- STATE
-- ==========================================================

function StarterTaskController.start()
	-- Decided once: a device does not stop being a phone mid-session, and a
	-- checklist that swapped presentations under the player would lose its
	-- place in the animation.
	local compact = Device.isTouch()

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		local starter = state and state.starter
		if compact then
			applyCompact(starter)
		else
			applyDesktop(starter)
		end
	end)

	-- A rotated phone or a resized window changes what the checklist has to
	-- clear. The slow re-check for everything else lives with the panel it
	-- measures - see `build` - so it dies with the panel.
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if compact then
				placeCompact()
			else
				reposition()
			end
		end)
	end
end

return StarterTaskController
