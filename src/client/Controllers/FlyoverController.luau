--!strict
--[[
	FlyoverController  (polish-events-analytics pass)
	The first-join camera tour: a few seconds along the museum corridor,
	zones 1 -> 3, with one caption per shot, then the camera goes back to the
	player.

	WHO SEES IT
	Only a player the server flags with `firstSession` (StateStore): a
	profile that has never seen it and has not placed its first item yet.
	When it ends - finished or skipped - the client fires FlyoverDone and the
	server saves Profile.FlyoverSeen, so it never plays twice.

	WHEN
	After the client has finished starting (LocalPlayer `LoadingScreenDone`,
	or after PolishConfig.FLYOVER_LOADING_WAIT if that never comes) and once the
	character exists. While it plays, LocalPlayer's `FlyoverActive` attribute
	is true: TutorialController holds back the objective arrow and the event
	pill/cards wait, so the tour always comes before the first objective.

	THE CAMERA - the same rules as the reveal camera in HatchController:
	  * the player's own camera (type, CFrame, FOV) is saved once and given
	    back once; a Scriptable save is restored as Custom;
	  * one owner: a shot is written every frame from a CFrameValue that tweens
	    move, so a tween never fights the frame loop;
	  * A REVEAL ALWAYS WINS. HatchController.onRevealStarting tells this
	    controller before a reveal takes the camera; the flyover hands the
	    camera straight back (no fade) and stops, so the reveal saves the
	    player's real camera. The flyover never starts while a reveal holds it.

	REDUCED EFFECTS: straight cuts and holds, no drift.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local MuseumLayout = require(ReplicatedStorage.Shared.MuseumLayout)
local PolishConfig = require(ReplicatedStorage.Shared.Config.PolishConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local HatchController = require(script.Parent.HatchController)
local UIStateController = require(script.Parent.UIStateController)

local FlyoverController = {}

local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local CLAIM = "flyover"
local FREEZE_ACTION = "FlyoverFreeze"

type Saved = { cameraType: Enum.CameraType, cframe: CFrame, fov: number }

local played = false
local running = false
--- Bumped by every stop; a sequence step that sees a newer token quits.
local token = 0
local saved: Saved? = nil
local shot = Instance.new("CFrameValue")
local shotTween: Tween? = nil
local frameLoop: RBXScriptConnection? = nil
local gui: ScreenGui? = nil
local fade: Frame? = nil
local caption: TextLabel? = nil
local controlsDisabled = false

-- ==========================================================
-- SHOTS
-- ==========================================================

local function shotFor(def: PolishConfig.FlyoverShot): (CFrame, CFrame)
	if def.kind == "room" then
		local frame = MuseumLayout.frame(def.zone, def.room or 1)
		-- From the corridor, through the doorway, at the cases.
		local target = (frame * CFrame.new(0, 6, MuseumLayout.DEPTH - 13)).Position
		local from = (frame * CFrame.new(0, 11, -16)).Position
		local closer = (frame * CFrame.new(0, 9, -6)).Position
		return CFrame.lookAt(from, target), CFrame.lookAt(closer, target)
	end
	-- High over the lane, looking back towards the safe line and home.
	local z = MapConfig.zoneCenterZ(def.zone)
	local from = Vector3.new(0, 34, z)
	local target = Vector3.new(0, 4, 0)
	local closer = Vector3.new(0, 30, z - 14)
	return CFrame.lookAt(from, target), CFrame.lookAt(closer, target)
end

local function flyTo(to: CFrame, seconds: number, style: Enum.EasingStyle): Tween?
	if shotTween then
		shotTween:Cancel()
		shotTween = nil
	end
	if seconds <= 0 then
		shot.Value = to
		return nil
	end
	local tween = TweenService:Create(shot, TweenInfo.new(seconds, style, Enum.EasingDirection.InOut), { Value = to })
	shotTween = tween
	tween:Play()
	return tween
end

-- ==========================================================
-- CAMERA OWNERSHIP
-- ==========================================================

local function takeCamera(): boolean
	local camera = workspace.CurrentCamera
	if not camera or HatchController.cameraBusy() then
		return false
	end
	saved = { cameraType = camera.CameraType, cframe = camera.CFrame, fov = camera.FieldOfView }
	shot.Value = camera.CFrame
	camera.CameraType = Enum.CameraType.Scriptable
	frameLoop = RunService.RenderStepped:Connect(function()
		local current = workspace.CurrentCamera
		if current and saved then
			current.CameraType = Enum.CameraType.Scriptable
			current.CFrame = shot.Value
		end
	end)
	return true
end

local function releaseCamera()
	if shotTween then
		shotTween:Cancel()
		shotTween = nil
	end
	if frameLoop then
		frameLoop:Disconnect()
		frameLoop = nil
	end
	local was = saved
	saved = nil
	local camera = workspace.CurrentCamera
	if was and camera then
		camera.FieldOfView = was.fov
		camera.CFrame = was.cframe
		camera.CameraType = if was.cameraType == Enum.CameraType.Scriptable then Enum.CameraType.Custom else was.cameraType
	end
end

-- ==========================================================
-- CONTROLS
-- ==========================================================

local function playerControls(): any
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("PlayerModule")
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, playerModule = pcall(require, module)
	if not ok or type(playerModule) ~= "table" or type((playerModule :: any).GetControls) ~= "function" then
		return nil
	end
	local got, controls = pcall(function()
		return (playerModule :: any):GetControls()
	end)
	return if got then controls else nil
end

local function freeze(on: boolean)
	if on == controlsDisabled then
		return
	end
	controlsDisabled = on
	local controls = playerControls()
	if controls then
		pcall(function()
			if on then
				controls:Disable()
			else
				controls:Enable()
			end
		end)
	end
	if on then
		-- Belt and braces for keyboard/gamepad if the PlayerModule is custom.
		ContextActionService:BindActionAtPriority(FREEZE_ACTION, function()
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 50, Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward, Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight, Enum.PlayerActions.CharacterJump)
	else
		ContextActionService:UnbindAction(FREEZE_ACTION)
	end
end

-- ==========================================================
-- OVERLAY
-- ==========================================================

local function buildGui(onSkip: () -> ()): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "FlyoverUI"
	screen.IgnoreGuiInset = true
	screen.ScreenInsets = Enum.ScreenInsets.None
	screen.DisplayOrder = 900
	screen.ResetOnSpawn = false

	-- Letterbox bars.
	for _, top in { true, false } do
		local bar = Instance.new("Frame")
		bar.Name = if top then "BarTop" else "BarBottom"
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0, if top then 0 else 1)
		bar.Position = UDim2.fromScale(0, if top then 0 else 1)
		bar.Size = UDim2.fromScale(1, 0.1)
		bar.Parent = screen
	end

	local safe = Instance.new("Frame")
	safe.Name = "Safe"
	safe.BackgroundTransparency = 1
	safe.Size = UDim2.fromScale(1, 1)
	safe.Parent = screen

	local text = Instance.new("TextLabel")
	text.Name = "Caption"
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 1)
	text.Position = UDim2.fromScale(0.5, 0.88)
	text.Size = UDim2.fromScale(0.8, 0.09)
	text.Font = FONT
	text.TextScaled = true
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextTransparency = 1
	text.Text = ""
	text.Parent = safe
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(20, 14, 40)
	stroke.Parent = text
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 44
	limit.MinTextSize = 16
	limit.Parent = text

	-- SKIP: a fixed-size touch target, clear of the top bar and notch.
	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.AnchorPoint = Vector2.new(1, 0)
	skip.Position = UDim2.new(1, -24, 0.1, 12)
	skip.Size = UDim2.fromOffset(120, 48)
	skip.BackgroundColor3 = Color3.fromRGB(30, 24, 60)
	skip.BackgroundTransparency = 0.2
	skip.Font = FONT
	skip.Text = "SKIP"
	skip.TextSize = 24
	skip.TextColor3 = Color3.new(1, 1, 1)
	skip.Visible = false
	skip.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = skip
	local skipStroke = Instance.new("UIStroke")
	skipStroke.Thickness = 2
	skipStroke.Color = Color3.new(1, 1, 1)
	skipStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	skipStroke.Parent = skip
	skip.Activated:Connect(onSkip)
	task.delay(PolishConfig.FLYOVER_SKIP_AFTER, function()
		if skip.Parent then
			skip.Visible = true
		end
	end)

	local black = Instance.new("Frame")
	black.Name = "Fade"
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BackgroundTransparency = 1
	black.BorderSizePixel = 0
	black.Size = UDim2.fromScale(1, 1)
	black.ZIndex = 10
	black.Parent = screen

	screen.Parent = player:WaitForChild("PlayerGui")
	fade = black
	caption = text
	return screen
end

local function fadeTo(transparency: number, seconds: number)
	local black = fade
	if not black then
		return
	end
	if seconds <= 0 then
		black.BackgroundTransparency = transparency
		return
	end
	local tween = TweenService:Create(black, TweenInfo.new(seconds, Enum.EasingStyle.Quad), { BackgroundTransparency = transparency })
	tween:Play()
	tween.Completed:Wait()
end

local function setCaption(text: string)
	local label = caption
	if not label then
		return
	end
	if Effects.isReduced() then
		label.Text = text
		label.TextTransparency = 0
		return
	end
	local out = TweenService:Create(label, TweenInfo.new(0.15), { TextTransparency = 1 })
	out:Play()
	out.Completed:Wait()
	label.Text = text
	TweenService:Create(label, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
end

-- ==========================================================
-- RUN / STOP
-- ==========================================================

--- Ends the flyover. `instant` skips the fade (a reveal is taking over).
local function stop(instant: boolean)
	if not running then
		return
	end
	running = false
	token += 1
	local screen = gui
	gui = nil
	if not instant and screen and screen.Parent and not HatchController.cameraBusy() then
		fadeTo(0, PolishConfig.FLYOVER_FADE_SECONDS)
	end
	releaseCamera()
	freeze(false)
	UIStateController.release(CLAIM)
	player:SetAttribute("FlyoverActive", nil)
	if screen then
		if not instant then
			fadeTo(1, PolishConfig.FLYOVER_FADE_SECONDS)
		end
		screen:Destroy()
	end
	fade = nil
	caption = nil
	Remotes.get("FlyoverDone"):FireServer()
end

local function play()
	if running or played then
		return
	end
	if not takeCamera() then
		return
	end
	played = true
	running = true
	token += 1
	local mine = token
	player:SetAttribute("FlyoverActive", true)
	UIStateController.claim(CLAIM)
	freeze(true)
	gui = buildGui(function()
		task.spawn(stop, false)
	end)

	local reduced = Effects.isReduced()
	local function alive(): boolean
		return running and token == mine
	end

	-- In from black onto the first shot, so the camera never flies through
	-- the lobby to get there.
	fadeTo(0, PolishConfig.FLYOVER_FADE_SECONDS)
	for index, def in PolishConfig.FLYOVER_SHOTS do
		if not alive() then
			return
		end
		local from, closer = shotFor(def)
		if index == 1 or reduced then
			flyTo(from, 0, Enum.EasingStyle.Linear)
		else
			local travel = flyTo(from, def.travel, Enum.EasingStyle.Sine)
			if travel then
				travel.Completed:Wait()
			end
		end
		if not alive() then
			return
		end
		if index == 1 then
			fadeTo(1, PolishConfig.FLYOVER_FADE_SECONDS)
		end
		task.spawn(setCaption, def.caption)
		if not reduced then
			flyTo(closer, def.hold, Enum.EasingStyle.Linear)
		end
		task.wait(def.hold)
	end
	if alive() then
		stop(false)
	end
end

function FlyoverController.isPlaying(): boolean
	return running
end

function FlyoverController.start()
	if not PolishConfig.FLYOVER_ENABLED then
		return
	end

	-- A reveal takes the camera: hand it back now, without a fade.
	HatchController.onRevealStarting(function()
		if running then
			stop(true)
		end
	end)

	-- A respawn mid-flyover (a reset) ends it cleanly.
	player.CharacterAdded:Connect(function()
		if running then
			task.spawn(stop, true)
		end
	end)

	local StateStore = require(script.Parent.Parent.StateStore)
	local wanted = false
	local waiting = false

	local function tryPlay()
		if waiting or played or not wanted then
			return
		end
		waiting = true
		task.spawn(function()
			-- The client finishing its start-up first.
			local deadline = os.clock() + PolishConfig.FLYOVER_LOADING_WAIT
			while player:GetAttribute("LoadingScreenDone") ~= true and os.clock() < deadline do
				task.wait(0.25)
			end
			-- A character to hand the camera back to, and no reveal on screen.
			local character = player.Character or player.CharacterAdded:Wait()
			character:WaitForChild("HumanoidRootPart", 15)
			while HatchController.cameraBusy() do
				task.wait(0.5)
			end
			-- The world the shots look at.
			local map = workspace:WaitForChild("Map", 30)
			if map then
				map:WaitForChild("Zones", 15)
			end
			task.wait(0.5)
			waiting = false
			if wanted and not played then
				play()
			end
		end)
	end

	StateStore.onKeyChanged("firstSession", function(value)
		local was = wanted
		wanted = value == true
		-- The server only turns this back on for a Studio replay
		-- (FlyoverService.debugReplay): allow one more run.
		if wanted and not was and played and not running then
			played = false
		end
		tryPlay()
	end)
end

return FlyoverController
