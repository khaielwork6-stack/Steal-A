--!strict
--[[
	LoadingScreen  (ReplicatedFirst; polish-events-analytics pass)
	The branded loading screen that replaces Roblox's default one.

	WHAT DRIVES THE BAR
	Three honest signals, in order, so it never sits at 100% while the game is
	still wiring itself:
	  1. ContentProvider.RequestQueueSize - assets still downloading (0-60%).
	  2. game:IsLoaded() - the initial DataModel snapshot is in (60-90%).
	  3. LocalPlayer's `ClientReady` attribute - set by init.client.luau once
	     every controller has been started (90-100%).
	A slow time-based creep keeps it moving on a stalled queue, and the bar
	never goes backwards. After MAX_SECONDS it fades out regardless: a stuck
	loading screen is worse than a half-dressed HUD.

	HAND-OFF
	When it has faded it sets LocalPlayer's `LoadingScreenDone` attribute.
	The first-join flyover (FlyoverController) waits for that.

	RUNS BEFORE EVERYTHING
	ReplicatedStorage has not replicated yet when this starts, so it only
	uses its sibling LoadingConfig and engine services. Reduced Effects is
	read from Roblox's own ReducedMotionEnabled and, once it exists, the
	game's Effects module (the saved setting usually arrives after this has
	gone, so the Roblox flag is the one that matters).
]]

local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local Config = require(script.Parent:WaitForChild("LoadingConfig") :: ModuleScript) :: any

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local started = os.clock()
local closing = false
local skipped = false

-- ==========================================================
-- REDUCED EFFECTS
-- ==========================================================

local effectsModule: any = nil

local function reduced(): boolean
	local ok, value = pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end)
	if ok and value == true then
		return true
	end
	if not effectsModule then
		-- Non-blocking: Shared may not have replicated yet.
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local util = shared and shared:FindFirstChild("Util")
		local module = util and util:FindFirstChild("Effects")
		if module and module:IsA("ModuleScript") then
			local loaded, result = pcall(require, module)
			if loaded then
				effectsModule = result
			end
		end
	end
	return effectsModule ~= nil and effectsModule.isReduced() == true
end

local function isSet(asset: string): boolean
	return asset ~= "" and asset ~= "rbxassetid://0"
end

-- ==========================================================
-- BUILD
-- ==========================================================

local FONT = Enum.Font.FredokaOne
local WHITE = Color3.new(1, 1, 1)
local DESIGN = Vector2.new(820, 460)

--- Full-bleed backdrop, under the notch and the home bar.
local backdropGui = Instance.new("ScreenGui")
backdropGui.Name = "LoadingBackdrop"
backdropGui.IgnoreGuiInset = true
backdropGui.ScreenInsets = Enum.ScreenInsets.None
backdropGui.DisplayOrder = 1000
backdropGui.ResetOnSpawn = false
backdropGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

--- Everything readable, inside the device safe area.
local contentGui = Instance.new("ScreenGui")
contentGui.Name = "LoadingContent"
contentGui.IgnoreGuiInset = true
contentGui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
contentGui.DisplayOrder = 1001
contentGui.ResetOnSpawn = false
contentGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = WHITE
backdrop.BorderSizePixel = 0
backdrop.Parent = backdropGui
local gradient = Instance.new("UIGradient")
gradient.Rotation = 90
gradient.Color = ColorSequence.new(Config.GRADIENT_TOP, Config.GRADIENT_BOTTOM)
gradient.Parent = backdrop

local art: ImageLabel? = nil
if isSet(Config.BACKGROUND_WIDE) or isSet(Config.BACKGROUND_TALL) then
	local image = Instance.new("ImageLabel")
	image.Name = "Art"
	image.Size = UDim2.fromScale(1, 1)
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Crop
	image.Parent = backdrop
	art = image
end

-- A soft darkening towards the bottom so the tip text stays readable on art.
local shade = Instance.new("Frame")
shade.Name = "Shade"
shade.Size = UDim2.fromScale(1, 1)
shade.BackgroundColor3 = Color3.new(0, 0, 0)
shade.BackgroundTransparency = 0.35
shade.BorderSizePixel = 0
shade.Parent = backdrop
local shadeGradient = Instance.new("UIGradient")
shadeGradient.Rotation = 90
shadeGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.55, 1),
	NumberSequenceKeypoint.new(1, 0.2),
})
shadeGradient.Parent = shade

local center = Instance.new("Frame")
center.Name = "Center"
center.AnchorPoint = Vector2.new(0.5, 0.5)
center.Position = UDim2.fromScale(0.5, 0.5)
center.Size = UDim2.fromOffset(DESIGN.X, DESIGN.Y)
center.BackgroundTransparency = 1
center.Parent = contentGui
local uiScale = Instance.new("UIScale")
uiScale.Parent = center

local function label(name: string, text: string, size: number, position: UDim2, extent: UDim2): TextLabel
	local out = Instance.new("TextLabel")
	out.Name = name
	out.BackgroundTransparency = 1
	out.AnchorPoint = Vector2.new(0.5, 0.5)
	out.Position = position
	out.Size = extent
	out.Font = FONT
	out.Text = text
	out.TextSize = size
	out.TextWrapped = true
	out.TextColor3 = WHITE
	out.Parent = center
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(2, size / 14)
	stroke.Color = Color3.fromRGB(20, 14, 40)
	stroke.Parent = out
	return out
end

-- Title: the logo when it exists, the name otherwise.
local titleHolder: GuiObject
if isSet(Config.LOGO) then
	local logo = Instance.new("ImageLabel")
	logo.Name = "Logo"
	logo.BackgroundTransparency = 1
	logo.AnchorPoint = Vector2.new(0.5, 0.5)
	logo.Position = UDim2.fromScale(0.5, 0.26)
	logo.Size = UDim2.fromOffset(560, 210)
	logo.ScaleType = Enum.ScaleType.Fit
	logo.Image = Config.LOGO
	logo.Parent = center
	titleHolder = logo
else
	local title = label("Title", Config.TITLE, 96, UDim2.fromScale(0.5, 0.24), UDim2.fromOffset(800, 120))
	title.TextColor3 = Config.ACCENT
	local titleGradient = Instance.new("UIGradient")
	titleGradient.Rotation = 90
	titleGradient.Color = ColorSequence.new(Color3.fromRGB(255, 240, 150), Color3.fromRGB(255, 160, 40))
	titleGradient.Parent = title
	titleHolder = title
end
local titleBase = titleHolder.Position
label("Subtitle", Config.SUBTITLE, 30, UDim2.fromScale(0.5, 0.47), UDim2.fromOffset(700, 40))

-- The bar.
local track = Instance.new("Frame")
track.Name = "Track"
track.AnchorPoint = Vector2.new(0.5, 0.5)
track.Position = UDim2.fromScale(0.5, 0.64)
track.Size = UDim2.fromOffset(640, 28)
track.BackgroundColor3 = Color3.fromRGB(20, 16, 44)
track.BackgroundTransparency = 0.15
track.BorderSizePixel = 0
track.Parent = center
local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = track
local trackStroke = Instance.new("UIStroke")
trackStroke.Thickness = 3
trackStroke.Color = WHITE
trackStroke.Parent = track

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0.02, 1)
fill.BackgroundColor3 = WHITE
fill.BorderSizePixel = 0
fill.Parent = track
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill
local fillGradient = Instance.new("UIGradient")
fillGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 170, 40)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 236, 130)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 170, 40)),
})
fillGradient.Parent = fill

local percent = label("Percent", "0%", 24, UDim2.fromScale(0.5, 0.72), UDim2.fromOffset(200, 30))

-- The tip row: optional icon, then the text.
local tipIcon = Instance.new("ImageLabel")
tipIcon.Name = "TipIcon"
tipIcon.BackgroundTransparency = 1
tipIcon.AnchorPoint = Vector2.new(0, 0.5)
tipIcon.Position = UDim2.new(0, 40, 0.87, 0)
tipIcon.Size = UDim2.fromOffset(64, 64)
tipIcon.ScaleType = Enum.ScaleType.Fit
tipIcon.Visible = false
tipIcon.Parent = center
local tipText = label("Tip", "", 26, UDim2.fromScale(0.5, 0.87), UDim2.fromOffset(740, 72))

-- SKIP: outside the UIScale on purpose, so it stays a full-size touch target
-- on the smallest phone.
local skip = Instance.new("TextButton")
skip.Name = "Skip"
skip.AnchorPoint = Vector2.new(1, 0)
skip.Position = UDim2.new(1, -16, 0, 16)
skip.Size = UDim2.fromOffset(120, 48)
skip.BackgroundColor3 = Color3.fromRGB(30, 24, 60)
skip.BackgroundTransparency = 0.2
skip.Font = FONT
skip.Text = "SKIP"
skip.TextSize = 24
skip.TextColor3 = WHITE
skip.Visible = false
skip.AutoButtonColor = true
skip.Parent = contentGui
local skipCorner = Instance.new("UICorner")
skipCorner.CornerRadius = UDim.new(0, 12)
skipCorner.Parent = skip
local skipStroke = Instance.new("UIStroke")
skipStroke.Thickness = 2
skipStroke.Color = WHITE
skipStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
skipStroke.Parent = skip
skip.Activated:Connect(function()
	skipped = true
end)

backdropGui.Parent = playerGui
contentGui.Parent = playerGui

-- ==========================================================
-- LAYOUT (UIScale + the right background for the aspect)
-- ==========================================================

local function layout()
	local camera = workspace.CurrentCamera
	local view = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local safe = contentGui.AbsoluteSize
	if safe.X <= 0 or safe.Y <= 0 then
		safe = view
	end
	uiScale.Scale = math.clamp(math.min(safe.X * 0.94 / DESIGN.X, safe.Y * 0.9 / DESIGN.Y), 0.4, 1.3)
	local image = art
	if image then
		local tall = view.Y > view.X
		local choice = if tall and isSet(Config.BACKGROUND_TALL) then Config.BACKGROUND_TALL else Config.BACKGROUND_WIDE
		if not isSet(choice) then
			choice = Config.BACKGROUND_TALL
		end
		image.Image = choice
	end
end
layout()
contentGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)

-- ==========================================================
-- PROGRESS
-- ==========================================================

local maxQueue = 1
local shown = 0.02

local function clientReady(): boolean
	return player:GetAttribute("ClientReady") == true
end

local function targetProgress(): number
	local queue = ContentProvider.RequestQueueSize
	maxQueue = math.max(maxQueue, queue)
	local assets = 1 - queue / maxQueue
	-- Creeps towards 55% over ~20 s so a stalled queue still looks alive.
	local creep = math.min(0.55, (os.clock() - started) / 36)
	if not game:IsLoaded() then
		return math.max(0.05 + 0.55 * assets, creep)
	end
	if not clientReady() then
		return math.max(0.6 + 0.3 * assets, creep)
	end
	return 1
end

local frameConnection = RunService.RenderStepped:Connect(function(dt: number)
	local target = if closing then 1 else targetProgress()
	-- Monotonic, eased.
	shown = math.max(shown, shown + (target - shown) * math.min(1, dt * 4))
	fill.Size = UDim2.fromScale(math.clamp(shown, 0.02, 1), 1)
	percent.Text = `{math.floor(shown * 100 + 0.5)}%`

	if reduced() then
		fillGradient.Offset = Vector2.zero
		titleHolder.Position = titleBase
		return
	end
	local t = os.clock()
	fillGradient.Offset = Vector2.new(((t * 0.6) % 2) - 1, 0)
	titleHolder.Position = titleBase + UDim2.fromOffset(0, math.sin(t * 2) * 6)
end)

-- ==========================================================
-- TIPS
-- ==========================================================

local tips = Config.TIPS :: { { text: string, icon: string } }

local function showTip(index: number)
	local tip = tips[index]
	if not tip then
		return
	end
	local function apply()
		tipText.Text = tip.text
		if isSet(tip.icon) then
			tipIcon.Image = tip.icon
			tipIcon.Visible = true
			tipText.Position = UDim2.new(0.5, 40, 0.87, 0)
			tipText.Size = UDim2.fromOffset(660, 72)
		else
			tipIcon.Visible = false
			tipText.Position = UDim2.fromScale(0.5, 0.87)
			tipText.Size = UDim2.fromOffset(740, 72)
		end
	end
	if reduced() or tipText.Text == "" then
		apply()
		return
	end
	local out = TweenService:Create(tipText, TweenInfo.new(0.25), { TextTransparency = 1 })
	out:Play()
	out.Completed:Wait()
	if closing then
		return
	end
	apply()
	TweenService:Create(tipText, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
end

task.spawn(function()
	if #tips == 0 then
		return
	end
	local index = math.random(1, #tips)
	while not closing do
		showTip(index)
		index = index % #tips + 1
		task.wait(Config.TIP_SECONDS)
	end
end)

task.delay(Config.SKIP_AFTER, function()
	if not closing then
		skip.Visible = true
	end
end)

-- ==========================================================
-- WAIT, THEN FADE
-- ==========================================================

while true do
	local elapsed = os.clock() - started
	if skipped or elapsed >= Config.MAX_SECONDS then
		break
	end
	if elapsed >= Config.MIN_SECONDS and game:IsLoaded() and clientReady() then
		break
	end
	task.wait(0.1)
end

closing = true
skip.Visible = false
-- Let the bar visibly reach the end unless the player skipped.
if not skipped then
	task.wait(0.35)
end

--- Fades every visible surface of both screens to nothing in one go.
local function fadeAll(seconds: number)
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local last: Tween? = nil
	for _, gui in { backdropGui, contentGui } do
		for _, object in gui:GetDescendants() do
			local goal: { [string]: any }? = nil
			if object:IsA("TextLabel") or object:IsA("TextButton") then
				goal = { TextTransparency = 1, BackgroundTransparency = 1 }
			elseif object:IsA("ImageLabel") then
				goal = { ImageTransparency = 1, BackgroundTransparency = 1 }
			elseif object:IsA("Frame") then
				goal = { BackgroundTransparency = 1 }
			elseif object:IsA("UIStroke") then
				goal = { Transparency = 1 }
			end
			if goal then
				local tween = TweenService:Create(object, info, goal)
				tween:Play()
				last = tween
			end
		end
	end
	if last then
		last.Completed:Wait()
	end
end

fadeAll(if reduced() then 0.15 else Config.FADE_SECONDS)
frameConnection:Disconnect()
backdropGui:Destroy()
contentGui:Destroy()
player:SetAttribute("LoadingScreenDone", true)
