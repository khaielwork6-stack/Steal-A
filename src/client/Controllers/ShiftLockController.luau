--!strict
--[[
	ShiftLockController
	A shift-lock button for touch players, bottom-right above Jump.

	HOW IT LOCKS
	Two layers:
	  1. UserGameSettings.RotationType = CameraRelative plus the desktop shift
	     lock's over-the-shoulder Humanoid.CameraOffset. This is what the
	     engine's own shift lock uses.
	  2. A FALLBACK that does not depend on (1): the default PlayerModule
	     camera recomputes RotationType from its own mouse-lock state, and on
	     touch that can put MovementRelative back every frame (HANDOFF 33.10:
	     untested on devices). So while the lock is on, Humanoid.AutoRotate is
	     off and a render step one priority after the Camera turns the
	     HumanoidRootPart to the camera's yaw itself.

	Vertical rotation is never forced (only yaw). The step stands aside -
	and touches nothing - whenever another system owns the character's facing:
	ragdoll / PlatformStand, sitting, dead, an anchored root, the "Rooted"
	attribute (guardian hits), and treadmill training (TreadmillController
	turns the runner to the console). Turning the lock off, or a respawn,
	restores AutoRotate and the offset.

	LAYOUT
	The button sits above the default Jump button, sized and placed from Jump's
	REAL rectangle (Device.jumpButton): a tablet's Jump is much bigger than a
	phone's, and fixed offsets overlapped it there. Before the touch controls
	exist it falls back to the old fixed spot.

	Touch only. Desktop keeps Shift. If the device stops being a touch layout
	(a keyboard appears) the lock is released and the button hidden; if a
	desktop session becomes touch, the button is built then.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local UserGameSettings = UserSettings():GetService("UserGameSettings")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local TreadmillController = require(script.Parent.TreadmillController)

local ShiftLockController = {}

local player = Players.LocalPlayer

--- The desktop shift lock's own shoulder offset.
local LOCK_OFFSET = Vector3.new(1.75, 0, 0)
--- Render step for the fallback yaw. After the Camera, so it reads the camera
--- of THIS frame.
local YAW_STEP = "ShiftLockYaw"
local YAW_PRIORITY = Enum.RenderPriority.Camera.Value + 1

--- Button size bounds (pixels). Deliberately UNDER the 44 px touch minimum:
--- this is a toggle a thumb visits once, not a control it works, and at 44
--- it crowded the jump button it now sits under.
local MIN_SIZE = 34
local MAX_SIZE = 48
--- Gap between the button and the bottom of Jump.
local GAP = 6
--- Where it sits before the touch controls exist (the old fixed spot).
local FALLBACK_POSITION = UDim2.new(1, -30, 1, -108)
local FALLBACK_SIZE = 52

local ON_COLOR = Color3.fromRGB(126, 236, 255)
local OFF_COLOR = Color3.fromRGB(44, 58, 104)
local ICON_ON = Color3.fromRGB(16, 22, 44)
local ICON_OFF = Color3.fromRGB(230, 236, 250)

local enabled = false
local training = false
local yawBound = false
local screen: ScreenGui? = nil
local button: ImageButton? = nil
local plate: Frame? = nil
local icon: TextLabel? = nil

local function humanoid(): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildWhichIsA("Humanoid") else nil
end

-- ==========================================================
-- THE FALLBACK YAW
-- ==========================================================

--- True while something else owns which way the character faces.
local function standAside(h: Humanoid, root: BasePart): boolean
	if training or h.Health <= 0 or h.PlatformStand or h.Sit or root.Anchored then
		return true
	end
	if h:GetAttribute("Rooted") then
		return true
	end
	local state = h:GetState()
	return state == Enum.HumanoidStateType.Dead
		or state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.Ragdoll
		or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.Seated
end

local function yawStep()
	local h = humanoid()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = workspace.CurrentCamera
	if not h or not root or not root:IsA("BasePart") or not camera then
		return
	end
	if standAside(h, root) then
		-- Let the ordinary controller turn the character while we stand aside.
		h.AutoRotate = true
		return
	end
	h.AutoRotate = false
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	local position = root.Position
	root.CFrame = CFrame.lookAt(position, position + flat.Unit)
end

local function bindYaw()
	if yawBound then
		return
	end
	yawBound = true
	RunService:BindToRenderStep(YAW_STEP, YAW_PRIORITY, yawStep)
end

local function unbindYaw()
	if not yawBound then
		return
	end
	yawBound = false
	RunService:UnbindFromRenderStep(YAW_STEP)
end

local function applyToCharacter()
	local h = humanoid()
	if h then
		h.CameraOffset = if enabled then LOCK_OFFSET else Vector3.zero
		-- AutoRotate is re-decided every frame by the yaw step while locked;
		-- unlocked, the character is the ordinary one, untouched.
		h.AutoRotate = true
	end
	if enabled then
		bindYaw()
	else
		unbindYaw()
	end
end

-- ==========================================================
-- BUTTON
-- ==========================================================

local function paint()
	if plate then
		TweenService:Create(plate, UIAnim.SNAP, { BackgroundColor3 = if enabled then ON_COLOR else OFF_COLOR }):Play()
	end
	if icon then
		icon.TextColor3 = if enabled then ICON_ON else ICON_OFF
		icon.Text = if enabled then "🔒" else "🔓"
	end
end

local function setEnabled(value: boolean)
	if enabled == value then
		return
	end
	enabled = value
	UserGameSettings.RotationType = if enabled then Enum.RotationType.CameraRelative else Enum.RotationType.MovementRelative
	applyToCharacter()
	paint()
	if button then
		UIAnim.punch(button, 0.16)
	end
end

--- Places the button above Jump, from Jump's real rectangle. Returns a
--- signature so the poll only touches the button when something moved.
local lastLayout = ""
local function layout()
	local made = button
	local gui = screen
	if not made or not gui then
		return
	end
	local jump, touchGui = Device.jumpButton()
	if not jump or not touchGui then
		if lastLayout ~= "fallback" then
			lastLayout = "fallback"
			made.AnchorPoint = Vector2.new(1, 1)
			made.Position = FALLBACK_POSITION
			made.Size = UDim2.fromOffset(FALLBACK_SIZE, FALLBACK_SIZE)
		end
		return
	end
	local position, size = jump.AbsolutePosition, jump.AbsoluteSize
	local signature = `{position.X},{position.Y},{size.X},{size.Y}`
	if signature == lastLayout then
		return
	end
	lastLayout = signature
	-- Same inset rules as the touch controls, so both AbsolutePositions are in
	-- one coordinate space and the numbers below can be used directly.
	gui.IgnoreGuiInset = touchGui.IgnoreGuiInset
	gui.ScreenInsets = touchGui.ScreenInsets
	-- BELOW Jump, and smaller (45% of it, 34-48 px), tucked into the corner
	-- where a thumb resting on Jump never lands. It used to sit ABOVE Jump at
	-- 60%, right in the path of a thumb sliding up to jump. When the screen
	-- bottom leaves no room under Jump, it goes to Jump's left instead,
	-- bottom-aligned, still out of the jump path.
	local side = math.clamp(math.floor(size.X * 0.45), MIN_SIZE, MAX_SIZE)
	made.Size = UDim2.fromOffset(side, side)
	local screenBottom = gui.AbsoluteSize.Y
	local below = position.Y + size.Y + GAP
	if screenBottom <= 0 or below + side <= screenBottom - 4 then
		made.AnchorPoint = Vector2.new(1, 0)
		made.Position = UDim2.fromOffset(position.X + size.X, below)
	else
		made.AnchorPoint = Vector2.new(1, 1)
		made.Position = UDim2.fromOffset(position.X - GAP, position.Y + size.Y)
	end
end

local function build()
	if button then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "ShiftLockUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 8
	gui.Parent = playerGui
	screen = gui

	local made = Instance.new("ImageButton")
	made.Name = "ShiftLock"
	made.AnchorPoint = Vector2.new(1, 1)
	made.Position = FALLBACK_POSITION
	made.Size = UDim2.fromOffset(FALLBACK_SIZE, FALLBACK_SIZE)
	made.BackgroundTransparency = 1
	made.Image = ""
	made.AutoButtonColor = false
	made.Parent = gui
	button = made

	local face = Instance.new("Frame")
	face.Name = "Plate"
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = OFF_COLOR
	face.BackgroundTransparency = 0.08
	face.BorderSizePixel = 0
	face.Parent = made
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = face
	local edge = Instance.new("UIStroke")
	edge.Thickness = 3
	edge.Color = Color3.fromRGB(0, 0, 0)
	edge.Parent = face
	plate = face

	local glyph = Instance.new("TextLabel")
	glyph.Name = "Icon"
	glyph.BackgroundTransparency = 1
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(0.62, 0.62)
	glyph.Font = Enum.Font.FredokaOne
	glyph.TextScaled = true
	glyph.TextColor3 = ICON_OFF
	glyph.Text = "🔓"
	glyph.Parent = face
	icon = glyph

	made.Activated:Connect(function()
		setEnabled(not enabled)
	end)
	-- Press feedback beyond the toggle punch: a squash while the finger is down.
	made.MouseButton1Down:Connect(function()
		local scale = UIAnim.scaleOf(made)
		if scale then
			TweenService:Create(scale, UIAnim.PRESS, { Scale = 0.9 }):Play()
		end
	end)
	made.MouseButton1Up:Connect(function()
		local scale = UIAnim.scaleOf(made)
		if scale then
			TweenService:Create(scale, UIAnim.RELEASE, { Scale = 1 }):Play()
		end
	end)

	paint()
	layout()
	UIAnim.popIn(made, 0.6)

	-- The touch controls are built late and resized on rotation; a cheap poll
	-- follows them without depending on when TouchGui appears.
	task.spawn(function()
		while made.Parent do
			layout()
			task.wait(0.5)
		end
	end)
end

function ShiftLockController.isEnabled(): boolean
	return enabled
end

local function becomeTouch()
	-- Landscape, held. Sensor so either landscape orientation works; a phone
	-- turned upright does not flip the HUD into a layout nothing was built for.
	local playerGui = player:WaitForChild("PlayerGui")
	if playerGui:IsA("PlayerGui") then
		playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end
	build()
	if screen then
		screen.Enabled = true
	end
end

function ShiftLockController.start()
	-- Training owns the runner's facing; the yaw step stands aside meanwhile.
	TreadmillController.onTrainingChanged(function(value)
		training = value
	end)

	-- Re-apply the lock to every new Humanoid (AutoRotate back on, offset
	-- re-set, the step re-bound if still locked).
	-- Only once the touch button exists: a desktop session's character is
	-- never touched by this controller.
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Humanoid", 10)
		if button then
			applyToCharacter()
		end
	end)

	-- A keyboard appearing hands control back to the ordinary Shift key rather
	-- than running two toggles; a session that becomes touch gets the button.
	Device.onTouchChanged(function(touch)
		if touch then
			becomeTouch()
		else
			setEnabled(false)
			if screen then
				screen.Enabled = false
			end
		end
	end)
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		if inputType == Enum.UserInputType.Keyboard and button then
			setEnabled(false)
		end
	end)

	if Device.isTouch() then
		becomeTouch()
	end
end

return ShiftLockController
