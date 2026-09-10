--!strict
--[[
	StarterTaskController
	The three-row beginner checklist in the bottom-right corner.

	IT RENDERS `state.starter` AND NOTHING ELSE. The server decides what is
	done, pays for it, and stops sending the field once the checklist is
	finished for good - so this file has no completion logic, no local flags
	that could disagree with the profile, and nothing to persist. A row
	animates when the SERVER's answer for it changes from false to true.

	NO PANEL, ON PURPOSE. The corner already holds the Nightfall pill, and on
	a phone it also holds Roblox's jump button and the shift lock. A card with
	a background there would read as a second HUD; a heading and three light
	rows read as a note. This is also why nothing here is a button - the
	checklist is never in the way, because there is nothing to hit.

	WHERE IT SITS IS MEASURED, NOT GUESSED. `clearance` reads the real
	AbsolutePosition of the things that share this corner and sits above the
	highest of them, re-checked as the viewport changes. The one thing it
	cannot measure is Roblox's own touch controls, which live in CoreGui - so
	touch gets a floor under it instead.
]]

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

--- Three sizes of the same layout, not one scaled down. Every line stays at a
--- size that can be read; shrinking the desktop block until it fits would put
--- 9px text in the corner of a phone, which is the failure this avoids.
---
--- `corner` is the part that is measured rather than chosen. See WHERE THIS
--- GOES below.
type Metrics = {
	corner: "bottom-right" | "top-left",
	width: number,
	heading: number,
	rowHeight: number,
	rowGap: number,
	marker: number,
	taskText: number,
	rewardText: number,
	margin: number,
	touchFloor: number,
}

local DESKTOP: Metrics = {
	corner = "bottom-right",
	width = 248,
	heading = 17,
	rowHeight = 27,
	rowGap = 3,
	marker = 17,
	taskText = 16,
	rewardText = 15,
	margin = 16,
	touchFloor = 0,
}

-- ==========================================================
-- WHERE THIS GOES
-- ==========================================================
--
-- Desktop and tablet: the bottom-right, above the Nightfall pill, exactly as
-- asked. `clearance` measures the pill rather than assuming its height.
--
-- A PHONE DOES NOT HAVE A BOTTOM-RIGHT TO PUT THIS IN, and that is a
-- measurement, not an opinion. On a landscape phone the right edge in pixels
-- from the top reads:
--
--     74 - 210   the Guardian / Slap offer tiles (HUDLayoutController)
--    h-160 - h-108   the shift lock button (ShiftLockController)
--    h-130 - h        Roblox's own jump button, in CoreGui
--
-- On a 390-tall screen that leaves a gap of about twenty pixels between the
-- offer tiles and the shift lock. Nothing legible fits in it, and "shift
-- upward" runs into the offer tiles.
--
-- The bottom-LEFT is worse, not better: that is where Roblox puts the
-- movement thumbstick.
--
-- So a phone gets the one genuinely empty band on the screen - the top strip
-- between the stat card (which ends at x=168) and the right-aligned gear and
-- GIFT buttons. It is still out of the way, still never over gameplay, and it
-- is somewhere the player can actually read it.
local PHONE: Metrics = {
	corner = "top-left",
	width = 200,
	heading = 14,
	rowHeight = 23,
	rowGap = 2,
	marker = 14,
	taskText = 13,
	rewardText = 12,
	-- Clear of the stat card's 12 + 156, with room to breathe.
	margin = 176,
	touchFloor = 0,
}

local TABLET: Metrics = {
	corner = "bottom-right",
	width = 224,
	heading = 15,
	rowHeight = 25,
	rowGap = 3,
	marker = 15,
	taskText = 14,
	rewardText = 13,
	margin = 12,
	-- Roblox's jump button and the shift lock own the bottom of this corner and
	-- neither can be measured from here (CoreGui, and a separate ScreenGui that
	-- may not exist yet). This is the floor they need.
	touchFloor = 176,
}

local function metrics(): Metrics
	if Device.isPhone() then
		return PHONE
	elseif Device.isTouch() then
		return TABLET
	end
	return DESKTOP
end

-- ==========================================================
-- STATE
-- ==========================================================

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
--- session. There is no "already closed" flag beside it for the same reason -
--- what is on screen follows the server's answer and never a local latch.
local finishing = false

-- ==========================================================
-- LAYOUT
-- ==========================================================

--- Things that share the bottom-right corner and that we can actually see
--- from here. Named rather than searched by class so a future sibling does
--- not silently start pushing the checklist around.
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
--- thing being avoided lives in a ScreenGui with a different IgnoreGuiInset -
--- the shift lock does. Using the camera's viewport instead looks right and
--- is quietly wrong by the height of the topbar inset.
local function clearance(screen: ScreenGui, size: Metrics): number
	local floor = screen.AbsolutePosition.Y
	local height = screen.AbsoluteSize.Y
	local bottom = floor + height
	local lowest = size.margin
	if height > 0 then
		for _, thing in obstacles() do
			local top = thing.AbsolutePosition.Y
			-- Only what is genuinely low on the screen: the Nightfall pill moves
			-- to the TOP strip on touch, and something up there must not push
			-- the checklist DOWN into the corner it is trying to avoid.
			if top + thing.AbsoluteSize.Y > floor + height * 0.55 then
				lowest = math.max(lowest, bottom - top + 10)
			end
		end
	end
	return math.max(lowest, size.touchFloor)
end

local function reposition()
	local frame = root
	local screen = gui
	if not frame or not screen then
		return
	end
	local size = metrics()
	if size.corner == "top-left" then
		-- The phone band: beside the stat card, under the top inset.
		frame.AnchorPoint = Vector2.new(0, 0)
		frame.Position = UDim2.fromOffset(size.margin, 12)
		return
	end
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Position = UDim2.new(1, -size.margin, 1, -clearance(screen, size))
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function outline(target: Instance, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = INK
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = target
	return stroke
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
	reward.Size = UDim2.new(0.42, 0, 1, 0)
	reward.BackgroundTransparency = 1
	reward.Font = Enum.Font.FredokaOne
	reward.TextSize = size.rewardText
	reward.TextXAlignment = Enum.TextXAlignment.Right
	reward.TextColor3 = if task_.kind == "cash" then CASH else SPEED
	reward.Text = task_.reward
	reward.Parent = frame
	outline(reward, 2)

	local text = Instance.new("TextLabel")
	text.Name = "Task"
	text.AnchorPoint = Vector2.new(0, 0.5)
	text.Position = UDim2.new(0, size.marker + 8, 0.5, 0)
	-- The reward column above owns the right 42% of the row; the task text
	-- takes the rest, less the marker it sits beside. In SCALE, so the two
	-- columns keep their proportions at any block width.
	text.Size = UDim2.new(0.56, -(size.marker + 8), 1, 0)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextSize = size.taskText
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextColor3 = TEXT
	text.Text = task_.text
	text.Parent = frame
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
	local size = metrics()

	local screen = Instance.new("ScreenGui")
	screen.Name = "StarterTasksUI"
	screen.ResetOnSpawn = false
	-- Below the notification stack and the offer rail, above the world.
	screen.DisplayOrder = 7
	screen.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Checklist"
	-- Corner and offsets are both `reposition`'s to decide, and it runs before
	-- the first paint.
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.BackgroundTransparency = 1
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
	title.TextSize = size.heading
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = GOLD
	title.Text = StarterTaskConfig.HEADING
	title.Parent = frame
	outline(title, 2)

	table.clear(rows)
	for order, task_ in StarterTaskConfig.Tasks do
		table.insert(rows, buildRow(frame, task_, order, size))
	end

	gui = screen
	root = frame
	heading = title
	-- A NEW panel is not finishing, whatever the last one was doing.
	finishing = false
	-- Once now, and once more after a frame: a ScreenGui's AbsoluteSize is
	-- still zero on the frame it is created, so the first pass has nothing to
	-- measure against.
	reposition()
	task.defer(reposition)
	UIAnim.popIn(frame, 0.85)

	-- The Nightfall pill can appear after this panel does, and a phone can be
	-- rotated without the viewport signal firing on some devices. One slow
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

-- ==========================================================
-- COMPLETION
-- ==========================================================

--- Removes the checklist and forgets it. The one place the panel is destroyed,
--- so a finished checklist and a retired one cannot leave different remnants.
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
	local restingSize = flash.TextSize
	flash.TextColor3 = TICK
	flash.TextSize = restingSize + 2
	TweenService:Create(flash, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextColor3 = TEXT_DONE,
		TextSize = restingSize,
	}):Play()
end

--- All three are ticked: one short flourish, and then the panel bows out.
---
--- It does NOT destroy itself. The server keeps sending the finished checklist
--- for a moment so this animation has something to play, and a panel that
--- destroyed itself first would simply be rebuilt by the next of those pushes
--- and finish all over again - a visible flicker. Removal has exactly one
--- owner: the push that says the checklist is retired.
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

-- ==========================================================
-- STATE
-- ==========================================================

local function apply(starter: any)
	-- Nil means the server has retired the checklist for good. The panel goes,
	-- and it goes even if the flourish is mid-play: the delay below is only so
	-- the animation is not cut off, never a condition for removing it. There
	-- is no local latch here on purpose - the state on screen is a function of
	-- the server's answer and nothing else, so this cannot get stuck in a mode
	-- the profile does not agree with.
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

function StarterTaskController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		apply(state and state.starter)
	end)

	-- A rotated phone or a resized window changes what this corner has to
	-- clear. The slow re-check for everything else lives with the panel it
	-- measures - see `build` - so it dies with the panel instead of ticking
	-- for the rest of the session.
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(reposition)
	end
end

return StarterTaskController
