--!strict
--[[
	ShiftLockController
	A shift-lock button for touch players, bottom-right beside Jump.

	HOW IT LOCKS
	Roblox's own camera and character code already implement shift lock: the
	engine turns the character to face the camera's yaw whenever
	UserGameSettings.RotationType is CameraRelative, and the default camera
	scripts follow the same setting. So the toggle sets exactly that, plus the
	over-the-shoulder Humanoid.CameraOffset the desktop shift lock uses. No
	competing camera script, no RenderStepped, nothing to fight the
	PlayerModule - and turning it off puts both back.

	Vertical rotation is never forced (the engine only yaws the character), the
	offset is re-applied to each new Humanoid on respawn, and every state the
	game puts the character in (ragdoll, carry, treadmill lock, guardian hits)
	keeps working because none of them are touched.

	Touch only. Desktop keeps Shift.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local UserGameSettings = UserSettings():GetService("UserGameSettings")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ShiftLockController = {}

local player = Players.LocalPlayer

--- The desktop shift lock's own shoulder offset.
local LOCK_OFFSET = Vector3.new(1.75, 0, 0)

local ON_COLOR = Color3.fromRGB(126, 236, 255)
local OFF_COLOR = Color3.fromRGB(44, 58, 104)
local ICON_ON = Color3.fromRGB(16, 22, 44)
local ICON_OFF = Color3.fromRGB(230, 236, 250)

local enabled = false
local button: ImageButton? = nil
local plate: Frame? = nil
local icon: TextLabel? = nil

local function humanoid(): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildWhichIsA("Humanoid") else nil
end

local function applyToCharacter()
	local h = humanoid()
	if not h then
		return
	end
	h.CameraOffset = if enabled then LOCK_OFFSET else Vector3.zero
	-- The engine yaws the character for us under CameraRelative; AutoRotate
	-- stays on so the OFF state is the ordinary character, untouched.
	h.AutoRotate = true
end

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

local function build()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "ShiftLockUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 8
	gui.Parent = playerGui

	-- The far bottom-right, stacked ABOVE the Jump button on the same right
	-- inset: the corner is Jump's, this sits over it, and the Night timer
	-- moved to the top strip so nothing shares the corner with either.
	local made = Instance.new("ImageButton")
	made.Name = "ShiftLock"
	made.AnchorPoint = Vector2.new(1, 1)
	made.Position = UDim2.new(1, -30, 1, -108)
	made.Size = UDim2.fromOffset(52, 52)
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
	UIAnim.popIn(made, 0.6)
end

function ShiftLockController.isEnabled(): boolean
	return enabled
end

function ShiftLockController.start()
	if not Device.isTouch() then
		return
	end
	-- Landscape, held. Sensor so either landscape orientation works; a phone
	-- turned upright does not flip the HUD into a layout nothing was built for.
	local playerGui = player:WaitForChild("PlayerGui")
	if playerGui:IsA("PlayerGui") then
		playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end

	build()

	-- Re-apply the shoulder offset to every new Humanoid; the setting itself
	-- lives in UserGameSettings and survives the respawn on its own.
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Humanoid", 10)
		applyToCharacter()
	end)
	if player.Character then
		applyToCharacter()
	end

	-- If the device somehow gains a keyboard mid-session, hand control back
	-- to the ordinary Shift key rather than running two toggles.
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		if inputType == Enum.UserInputType.Keyboard and button then
			setEnabled(false)
		end
	end)
end

return ShiftLockController
