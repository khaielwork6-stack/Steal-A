--!strict
--[[
	NightController
	Renders the Night cycle: the Nightfall timer, the reset barrier across the
	mouth of the lane, and the lighting change.

	EVERYTHING HERE IS DERIVED FROM SERVER TIMESTAMPS. NightService publishes the
	phase and the time it ends as attributes on ReplicatedStorage;
	workspace:GetServerTimeNow() is the same clock on every machine, so the
	remaining time is computed locally each frame with no per-second remote and
	no drift. A player who joins mid-cycle reads the same two attributes and is
	correct on their first frame.

	THE TIMER
	One persistent pill in the bottom-right corner, where the old Displays
	counter sat: "🌙 Nightfall in 3:50". In the final fifteen seconds it turns
	amber; in the final ten it breathes; each of the last five lands a punch.
	During Night it reads "Night Reset 8s" in the night colours. It never moves
	and never becomes a banner - the top of the screen belongs to the chase
	warning, the zone pop-up and the toasts.

	THE BARRIER
	At the moment Night begins, a wall the width of the lane rises just past
	the red line and blocks the view of the zones while the loot is rerolled
	behind it: pale, with the moon and the countdown on it, unmistakably a
	closure and not a glitch. It is a CLIENT-SIDE part, and SOLID while it stands:
	the local character is simulated on this client, so a collidable local part
	is a real wall to the player and nobody can walk, jump or glitch into the
	zones during the reset. The server's closure (LootService setClosed) is what
	refuses steals; the wall is the physical half of that. It goes back to
	walk-through the moment its fade-out starts, so it can never hold anyone
	after Night.

	THE LIGHT
	The day palette is whatever Lighting has when the client starts (the place's
	own grade), captured once. Night is a readable blue-hour: the clock rolls to
	midnight so the sky darkens and the moon rises, ambient and exposure come
	up so the map is still legible, atmosphere cools. Never pitch black, never a
	flash. Reduced Effects snaps instead of tweening.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local NightController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- TUNING
-- ==========================================================

--- Bottom-right, the slot the Displays counter used to occupy.
--- Bottom-right on desktop. On touch that corner belongs to Jump and the
--- shift lock, so the pill moves to the top strip, left of the settings
--- gear and offer tiles, where nothing else lives.
local TOUCH = require(ReplicatedStorage.Shared.Util.Device).isTouch()
local PILL_POSITION = if TOUCH then UDim2.new(1, -190, 0, 16) else UDim2.new(1, -16, 1, -12)
local PILL_ANCHOR = if TOUCH then Vector2.new(1, 0) else Vector2.new(1, 1)
local PILL_SIZE = if TOUCH then UDim2.fromOffset(176, 32) else UDim2.fromOffset(222, 38)

local COLOR_CALM = Color3.fromRGB(226, 232, 244)
local COLOR_WARN = Color3.fromRGB(255, 196, 92)
local COLOR_NIGHT = Color3.fromRGB(190, 168, 255)
local BG_CALM = Color3.fromRGB(16, 22, 44)
local BG_NIGHT = Color3.fromRGB(26, 18, 56)

local LIGHT_TWEEN = TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local BARRIER_IN = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BARRIER_OUT = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

--- The barrier: lane-wide plus the walls, taller than the walls, just past the
--- red line so it sits in front of the first zone from the lobby's side.
-- WIDE ENOUGH THAT THERE IS NO WAY ROUND IT. The lane is 160 studs across
-- and the old slab cleared it by forty either side, which is fine standing
-- in the middle of the lobby and useless from the corners: walk wide enough
-- and the first zone reappears past the edge. This spans the lobby rather
-- than the lane. It costs nothing - one invisible part that is only shown
-- for the ten seconds of Night - and the message on it is pinned to a fixed
-- centred block (see buildFace) so the extra width is plain gradient.
local BARRIER_WIDTH = MapConfig.LANE_WIDTH + 2 * MapConfig.WALL_THICKNESS + 420
local BARRIER_HEIGHT = 170
--- The message block, in studs, centred on the slab and independent of how
--- wide the slab is. Roughly the width of the lane, so it reads as a sign
--- across the entrance rather than as text stretched over the whole lobby.
local BARRIER_MESSAGE_WIDTH = 170
local BARRIER_MESSAGE_HEIGHT = 96
--- Just past the line: between the red stripe and the first zone's sign
--- boards, so nothing of the world stands in front of it. Four studs thick,
--- not one: a camera orbiting hard against a thin plane can end up on the far
--- side of it between two frames. Three studs is still more than the camera
--- popper steps through in a frame, and a curtain across the entrance should
--- read as a curtain rather than as a block of masonry.
local BARRIER_THICKNESS = 3
local BARRIER_STANDOFF = 0.8
--- How far the slab is buried below the floor. Without it a player looking up
--- from a crouch at the foot of the barrier sees the world under its bottom
--- edge, and a mobile camera dragged to ground level does the same.
local BARRIER_SKIRT = 24
--- Text on a SurfaceGui scales to at most 100 px, so the canvas is kept
--- coarse: at 2.5 px per stud a 100 px glyph is forty studs tall, readable
--- from the far end of the lobby.
local BARRIER_PIXELS_PER_STUD = 2.5
local BARRIER_TOP = Color3.fromRGB(246, 247, 253)
local BARRIER_BOTTOM = Color3.fromRGB(204, 210, 240)
local BARRIER_INK = Color3.fromRGB(58, 62, 84)

--- The night grade. Readable on purpose: ambient and exposure go UP as the
--- sun goes down, so the map darkens in colour rather than in visibility.
local NIGHT_LIGHTING = {
	ClockTime = 0.4,
	Brightness = 1.4,
	Ambient = Color3.fromRGB(78, 84, 122),
	OutdoorAmbient = Color3.fromRGB(96, 106, 150),
	ColorShift_Top = Color3.fromRGB(20, 28, 70),
	ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
	ExposureCompensation = 0.45,
}
local NIGHT_ATMOSPHERE = {
	Density = 0.32,
	Color = Color3.fromRGB(120, 140, 220),
	Decay = Color3.fromRGB(60, 74, 130),
	Glare = 0,
	Haze = 0.8,
}

-- ==========================================================
-- STATE
-- ==========================================================

local pill: Frame? = nil
local pillLabel: TextLabel? = nil
local pillIcon: TextLabel? = nil
local pillStroke: UIStroke? = nil
local pillScale: UIScale? = nil

local barrier: BasePart? = nil
local barrierGuis: { SurfaceGui } = {}
local barrierPanels: { Frame } = {}
local barrierLabels: { TextLabel } = {}
local barrierCountdowns: { TextLabel } = {}
local barrierShown = false
local barrierFadeToken = 0

local shownPhase: string? = nil
local lastWholeSecond = -1
local dayLighting: { [string]: any } = {}
local dayAtmosphere: { [string]: any } = {}
local reducedEffects = false

function NightController.setReducedEffects(value: boolean)
	reducedEffects = value
end

-- ==========================================================
-- READING THE CLOCK
-- ==========================================================

local function phase(): string
	local value = ReplicatedStorage:GetAttribute("NightPhase")
	return if type(value) == "string" then value else "Day"
end

local function remaining(): number
	local ends = ReplicatedStorage:GetAttribute("NightPhaseEndsAt")
	if type(ends) ~= "number" then
		return math.huge
	end
	return math.max(0, ends - workspace:GetServerTimeNow())
end

local function clock(seconds: number): string
	local whole = math.ceil(seconds)
	if whole >= 60 then
		return string.format("%d:%02d", whole // 60, whole % 60)
	end
	return `{whole}s`
end

-- ==========================================================
-- THE PILL
-- ==========================================================

local function buildPill(ui: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "NightTimer"
	frame.AnchorPoint = PILL_ANCHOR
	frame.Position = PILL_POSITION
	frame.Size = PILL_SIZE
	frame.BackgroundColor3 = BG_CALM
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.ZIndex = 5
	frame.Parent = ui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0.2
	stroke.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Parent = frame

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.new(0, 30, 1, 0)
	icon.Position = UDim2.new(0, 8, 0, 0)
	icon.Font = Enum.Font.FredokaOne
	icon.TextScaled = true
	icon.Text = "🌙"
	icon.TextColor3 = COLOR_CALM
	icon.ZIndex = 6
	icon.Parent = frame
	local iconLimit = Instance.new("UITextSizeConstraint")
	iconLimit.MaxTextSize = 22
	iconLimit.Parent = icon

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -50, 1, 0)
	label.Position = UDim2.new(0, 42, 0, 0)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = COLOR_CALM
	label.TextStrokeTransparency = 0.5
	label.Text = "Nightfall in —"
	label.ZIndex = 6
	label.Parent = frame
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 12
	limit.MaxTextSize = 22
	limit.Parent = label

	pill = frame
	pillLabel = label
	pillIcon = icon
	pillStroke = stroke
	pillScale = scale
end

--- Day and Night looks for the pill. Same place, same size; only the colours.
local function stylePill(night: boolean)
	local frame = pill
	if not frame then
		return
	end
	frame.BackgroundColor3 = if night then BG_NIGHT else BG_CALM
	if pillStroke then
		pillStroke.Color = if night then COLOR_NIGHT else Color3.fromRGB(0, 0, 0)
		pillStroke.Transparency = if night then 0.1 else 0.2
	end
	local color = if night then COLOR_NIGHT else COLOR_CALM
	if pillLabel then
		pillLabel.TextColor3 = color
	end
	if pillIcon then
		pillIcon.TextColor3 = color
	end
	if not reducedEffects then
		UIAnim.popIn(frame, 0.85)
	end
end

-- ==========================================================
-- THE BARRIER
-- ==========================================================

local function safeLineZ(): number
	local map = workspace:FindFirstChild("Map")
	local line = map and map:FindFirstChild("SafeZone") and map.SafeZone:FindFirstChild("BoundaryLine")
	return if line and line:IsA("BasePart") then line.Position.Z else 0
end

local function barrierLabel(parent: Instance, name: string, position: UDim2, size: UDim2, text: string, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = position
	label.Size = size
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color
	label.TextTransparency = 1
	label.TextStrokeTransparency = 1
	label.TextStrokeColor3 = Color3.fromRGB(20, 22, 36)
	label.Parent = parent
	table.insert(barrierLabels, label)
	return label
end

--- One face of the wall: gradient ground, moon, countdown, title, subtitle.
--- Faded element by element (background and text transparencies) rather than
--- through a CanvasGroup: a group's transparency is not honoured on every
--- SurfaceGui, and the wall must never be left half-visible in daylight.
local function buildFace(part: BasePart, face: Enum.NormalId)
	local gui = Instance.new("SurfaceGui")
	gui.Name = `Face{face.Name}`
	gui.Face = face
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = BARRIER_PIXELS_PER_STUD
	gui.Enabled = false
	gui.Parent = part

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = BARRIER_TOP
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(BARRIER_TOP, BARRIER_BOTTOM)
	gradient.Parent = panel

	-- THE MESSAGE IS A FIXED PHYSICAL SIZE, CENTRED. The slab is deliberately
	-- far wider than the lane so nobody can look past its edges, and the
	-- labels used to be laid out as fractions OF that slab - so every stud of
	-- extra width stretched the moon, the clock and the title with it until
	-- the countdown was spread across half the lobby. Sizing this block in
	-- studs (through the SurfaceGui's pixels-per-stud) instead pins the
	-- message to the middle of the entrance at a constant size, and widening
	-- the occluder only ever adds plain gradient either side of it.
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.AnchorPoint = Vector2.new(0.5, 0.5)
	content.Position = UDim2.fromScale(0.5, 0.5)
	content.Size = UDim2.fromOffset(
		BARRIER_MESSAGE_WIDTH * BARRIER_PIXELS_PER_STUD,
		BARRIER_MESSAGE_HEIGHT * BARRIER_PIXELS_PER_STUD
	)
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Parent = panel

	barrierLabel(content, "Moon", UDim2.fromScale(0.36, 0.4), UDim2.fromScale(0.22, 0.42), "🌙", BARRIER_INK)
	local countdown = barrierLabel(content, "Countdown", UDim2.fromScale(0.62, 0.4), UDim2.fromScale(0.28, 0.38), "10s", BARRIER_INK)
	countdown.TextXAlignment = Enum.TextXAlignment.Left
	barrierLabel(content, "Title", UDim2.fromScale(0.5, 0.72), UDim2.fromScale(0.86, 0.12), "NIGHT — LOOT REFRESHING", BARRIER_INK)
	barrierLabel(
		content,
		"Subtitle",
		UDim2.fromScale(0.5, 0.83),
		UDim2.fromScale(0.86, 0.06),
		"The zones are closed while every item is reset. Back soon.",
		Color3.fromRGB(104, 110, 140)
	)

	table.insert(barrierGuis, gui)
	table.insert(barrierPanels, panel)
	table.insert(barrierCountdowns, countdown)
end

local function buildBarrier()
	local part = Instance.new("Part")
	part.Name = "NightBarrier"
	-- The slab runs from below the floor to well over the wall caps, and wider
	-- than the lane plus both walls, so there is no gap over, under or around
	-- it to look through.
	part.Size = Vector3.new(BARRIER_WIDTH, BARRIER_HEIGHT + BARRIER_SKIRT, BARRIER_THICKNESS)
	-- Default part orientation: Front faces -Z, which is toward the lobby.
	part.CFrame = CFrame.new(0, BARRIER_HEIGHT / 2 - BARRIER_SKIRT / 2, safeLineZ() + BARRIER_STANDOFF)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	-- SOLID, not a pane of glass with writing on it. The slab used to be fully
	-- transparent with the white face painted by a SurfaceGui, so anything the
	-- GUI did not cover - and everything at an angle - was see-through. The
	-- part itself is now the wall and the SurfaceGuis are just the text on it.
	part.Transparency = 1
	part.Material = Enum.Material.SmoothPlastic
	part.Color = BARRIER_TOP
	buildFace(part, Enum.NormalId.Front)
	buildFace(part, Enum.NormalId.Back)
	part.Parent = workspace
	barrier = part
end

local function showBarrier(show: boolean)
	if barrierShown == show or not barrier then
		return
	end
	barrierShown = show
	barrierFadeToken += 1
	local token = barrierFadeToken
	local info = if show then BARRIER_IN else BARRIER_OUT
	local target = if show then 0 else 1

	-- SOLID while it stands. The local character is simulated on this client,
	-- so a collidable local part is a real wall to it: nobody walks, jumps or
	-- glitches into the zones while they are being reset. Off again the
	-- moment the fade-out starts, so it can never hold anyone after Night.
	barrier.CanCollide = show
	-- CanQuery is what the camera's occlusion popper raycasts against. With it
	-- off, the camera could be orbited straight through the barrier and look
	-- at the zones behind it; with it on, the popper stops at the wall like it
	-- does at any other solid. Only while the barrier is up, so it can never
	-- interfere with a prompt or a mouse ray during the day.
	barrier.CanQuery = show
	-- The slab fades with its own faces. Tweened alongside them, never set, so
	-- the wall does not blink out a frame before the writing on it.
	if reducedEffects then
		barrier.Transparency = target
	else
		TweenService:Create(barrier, info, { Transparency = target }):Play()
	end
	if show then
		for _, gui in barrierGuis do
			gui.Enabled = true
		end
	end
	for _, panel in barrierPanels do
		if reducedEffects then
			panel.BackgroundTransparency = target
		else
			TweenService:Create(panel, info, { BackgroundTransparency = target }):Play()
		end
	end
	for _, label in barrierLabels do
		local stroke = if show then (if label.Name == "Countdown" then 0.7 else 1) else 1
		if reducedEffects then
			label.TextTransparency = target
			label.TextStrokeTransparency = stroke
		else
			TweenService:Create(label, info, { TextTransparency = target, TextStrokeTransparency = stroke }):Play()
		end
	end
	if not show then
		-- Off entirely once the fade is done, so nothing of it can linger.
		task.delay(if reducedEffects then 0 else info.Time + 0.05, function()
			if barrierFadeToken == token and not barrierShown then
				for _, gui in barrierGuis do
					gui.Enabled = false
				end
			end
		end)
	end
end

local function paintBarrier(left: number)
	local text = if left == math.huge then "" else clock(left)
	for _, label in barrierCountdowns do
		label.Text = text
	end
end

-- ==========================================================
-- LIGHTING
-- ==========================================================

local function atmosphere(): Atmosphere?
	return Lighting:FindFirstChildOfClass("Atmosphere")
end

local function captureDay()
	for key in NIGHT_LIGHTING do
		dayLighting[key] = (Lighting :: any)[key]
	end
	local atmo = atmosphere()
	if atmo then
		for key in NIGHT_ATMOSPHERE do
			dayAtmosphere[key] = (atmo :: any)[key]
		end
	end
end

local function applyLighting(night: boolean)
	local targets = if night then NIGHT_LIGHTING else dayLighting
	local atmoTargets = if night then NIGHT_ATMOSPHERE else dayAtmosphere
	local atmo = atmosphere()

	if reducedEffects then
		for key, value in targets do
			(Lighting :: any)[key] = value
		end
		if atmo then
			for key, value in atmoTargets do
				(atmo :: any)[key] = value
			end
		end
		return
	end

	-- ClockTime is tweened the long way round at dusk so the sun actually sets
	-- (14 -> 24), and straight back at dawn. The wrap is why it is not simply
	-- included in the property table.
	local lightingGoals = table.clone(targets)
	local clockGoal = lightingGoals.ClockTime
	lightingGoals.ClockTime = nil
	if type(clockGoal) == "number" then
		local goal = if night then 24 + clockGoal else clockGoal
		if not night and Lighting.ClockTime < 6 then
			-- Coming back from just past midnight: run forward through dawn.
			goal = clockGoal
		end
		TweenService:Create(Lighting, LIGHT_TWEEN, { ClockTime = goal }):Play()
		if night then
			task.delay(LIGHT_TWEEN.Time + 0.05, function()
				if phase() == "Night" then
					Lighting.ClockTime = clockGoal
				end
			end)
		end
	end
	TweenService:Create(Lighting, LIGHT_TWEEN, lightingGoals):Play()
	if atmo then
		TweenService:Create(atmo, LIGHT_TWEEN, atmoTargets):Play()
	end
end

-- ==========================================================
-- RENDER
-- ==========================================================

local function render()
	local label = pillLabel
	if not label or not pill then
		return
	end

	local current = phase()
	local left = remaining()
	local night = current == "Night"

	if current ~= shownPhase then
		shownPhase = current
		lastWholeSecond = -1
		stylePill(night)
		applyLighting(night)
		showBarrier(night)
	end

	if night then
		paintBarrier(left)
	end

	if left == math.huge then
		label.Text = if night then "Night — Refreshing" else "Nightfall in —"
		return
	end

	local whole = math.ceil(left)
	if night then
		label.Text = `Night Reset {clock(left)}`
		if whole ~= lastWholeSecond then
			lastWholeSecond = whole
			if not reducedEffects and pillScale then
				UIAnim.punch(pill, 0.05)
			end
		end
		return
	end

	label.Text = `Nightfall in {clock(left)}`

	-- The last fifteen seconds turn amber; the last ten breathe; each of the
	-- last five lands a punch. All from the same clock, no server chatter.
	local warn = left <= NightConfig.WARNING_SECONDS
	label.TextColor3 = if warn then COLOR_WARN else COLOR_CALM
	if pillIcon then
		pillIcon.TextColor3 = if warn then COLOR_WARN else COLOR_CALM
	end
	if pillStroke then
		pillStroke.Color = if warn then COLOR_WARN else Color3.fromRGB(0, 0, 0)
		pillStroke.Transparency = if warn then 0.25 else 0.2
	end

	if reducedEffects or not pillScale then
		return
	end
	if left <= NightConfig.COUNTDOWN_SECONDS then
		if whole ~= lastWholeSecond then
			lastWholeSecond = whole
			UIAnim.punch(pill, 0.18)
		end
	elseif left <= NightConfig.WARNING_SOFT_SECONDS then
		pillScale.Scale = 1 + math.sin(os.clock() * 4) * 0.025
	elseif pillScale.Scale ~= 1 and not warn then
		pillScale.Scale = 1
	end
end

-- ==========================================================
-- START
-- ==========================================================

function NightController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		warn("[NightController] MainUI not found - the Night timer is disabled.")
		return
	end

	captureDay()
	buildPill(ui)
	buildBarrier()

	-- Ten times a second is plenty for a seconds timer; the per-second punch
	-- and the breathing are keyed off the same tick.
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.1 then
			return
		end
		accumulator = 0
		render()
	end)
	render()
end

return NightController
