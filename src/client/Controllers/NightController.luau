--!strict
--[[
	NightController
	Renders the Night cycle: the countdown pill, the NIGHT — LOOT REFRESHING
	state, and the lighting change.

	EVERYTHING HERE IS DERIVED FROM SERVER TIMESTAMPS. NightService publishes the
	phase and the time it ends as attributes on ReplicatedStorage;
	workspace:GetServerTimeNow() is the same clock on every machine, so the
	remaining time is computed locally each frame with no per-second remote and
	no drift. A player who joins mid-cycle reads the same two attributes and is
	correct on their first frame.

	THE PILL
	A compact timer at the top-left: "Night in 3:50". In the final fifteen
	seconds it turns amber; in the final ten it pulses gently; each of the last
	five seconds gets a clear punch. During Night it becomes a wide, centred
	NIGHT — LOOT REFRESHING banner with its own ten-second countdown, then
	returns to the corner.

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

local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local NightController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- TUNING
-- ==========================================================

local PILL_CORNER = UDim2.new(0, 14, 0, 12)
local PILL_SIZE = UDim2.fromOffset(168, 36)
local BANNER_POSITION = UDim2.new(0.5, 0, 0, 22)
local BANNER_SIZE = UDim2.fromOffset(360, 48)

local COLOR_CALM = Color3.fromRGB(226, 232, 244)
local COLOR_WARN = Color3.fromRGB(255, 196, 92)
local COLOR_NIGHT = Color3.fromRGB(190, 168, 255)
local BG_CALM = Color3.fromRGB(16, 22, 44)
local BG_NIGHT = Color3.fromRGB(26, 18, 56)

local LIGHT_TWEEN = TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

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
-- BUILD
-- ==========================================================

local function build(ui: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "NightTimer"
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = PILL_CORNER
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
	label.Size = UDim2.new(1, -48, 1, 0)
	label.Position = UDim2.new(0, 40, 0, 0)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = COLOR_CALM
	label.TextStrokeTransparency = 0.5
	label.Text = "Night in —"
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

local function toBanner()
	local frame = pill
	if not frame then
		return
	end
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = BANNER_POSITION
	frame.Size = BANNER_SIZE
	frame.BackgroundColor3 = BG_NIGHT
	if pillStroke then
		pillStroke.Color = COLOR_NIGHT
		pillStroke.Transparency = 0.1
	end
	if pillLabel then
		pillLabel.TextColor3 = COLOR_NIGHT
		pillLabel.TextXAlignment = Enum.TextXAlignment.Center
		pillLabel.Size = UDim2.new(1, -56, 1, 0)
		pillLabel.Position = UDim2.new(0, 48, 0, 0)
	end
	if pillIcon then
		pillIcon.TextColor3 = COLOR_NIGHT
		pillIcon.Position = UDim2.new(0, 12, 0, 0)
	end
	if not reducedEffects then
		UIAnim.popIn(frame, 0.8)
	end
end

local function toPill()
	local frame = pill
	if not frame then
		return
	end
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = PILL_CORNER
	frame.Size = PILL_SIZE
	frame.BackgroundColor3 = BG_CALM
	if pillStroke then
		pillStroke.Color = Color3.fromRGB(0, 0, 0)
		pillStroke.Transparency = 0.2
	end
	if pillLabel then
		pillLabel.TextColor3 = COLOR_CALM
		pillLabel.TextXAlignment = Enum.TextXAlignment.Left
		pillLabel.Size = UDim2.new(1, -48, 1, 0)
		pillLabel.Position = UDim2.new(0, 40, 0, 0)
	end
	if pillIcon then
		pillIcon.TextColor3 = COLOR_CALM
		pillIcon.Position = UDim2.new(0, 8, 0, 0)
	end
	if not reducedEffects then
		UIAnim.popIn(frame, 0.85)
	end
end

local function render()
	local label = pillLabel
	if not label or not pill then
		return
	end

	local current = phase()
	local left = remaining()

	if current ~= shownPhase then
		shownPhase = current
		lastWholeSecond = -1
		if current == "Night" then
			toBanner()
			applyLighting(true)
		else
			toPill()
			applyLighting(false)
		end
	end

	if left == math.huge then
		label.Text = if current == "Night" then "NIGHT — LOOT REFRESHING" else "Night in —"
		return
	end

	local whole = math.ceil(left)
	if current == "Night" then
		label.Text = `NIGHT — LOOT REFRESHING  {clock(left)}`
		if whole ~= lastWholeSecond then
			lastWholeSecond = whole
			if not reducedEffects and pillScale then
				UIAnim.punch(pill, 0.05)
			end
		end
		return
	end

	label.Text = `Night in {clock(left)}`

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
	build(ui)

	-- Four times a second is plenty for a seconds timer; the per-second punch
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
