--!strict
-- Input and pose only. LaserService validates the posture and tests the body.
-- No WalkSpeed, JumpPower, CameraOffset or saved setting is changed here.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local UIState = require(script.Parent.UIStateController)
local CrouchController = {}
local player = Players.LocalPlayer
local button: TextButton?
local desired = false
local poses: { [Model]: { { motor: Motor6D, rest: CFrame, crouch: CFrame } } } = {}

local function toggle()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or root.Position.Z < 0 then return end
	desired = not desired
	Remotes.get("CrouchRequest"):FireServer(desired)
end

local function pose(character: Model, on: boolean)
	if on and not poses[character] then
		local entries = {}
		for _, joint in character:GetDescendants() do
			if not joint:IsA("Motor6D") then continue end
			local change: CFrame? = nil
			if joint.Name == "Root" or joint.Name == "RootJoint" then
				-- C0 is a local frame on Part0; world-down is expressed in that
				-- part's frame, which also handles the stock R6 root orientation.
				change = CFrame.new(0, -1.1, 0) * joint.C0 * CFrame.Angles(math.rad(20), 0, 0)
			elseif joint.Name:find("Hip") then
				change = joint.C0 * CFrame.Angles(math.rad(-35), 0, 0)
			elseif joint.Name:find("Knee") then
				change = joint.C0 * CFrame.Angles(math.rad(65), 0, 0)
			end
			if change then table.insert(entries, { motor = joint, rest = joint.C0, crouch = change }) end
		end
		poses[character] = entries
		for _, entry in entries do entry.motor.C0 = entry.crouch end
	elseif not on and poses[character] then
		for _, entry in poses[character] do
			if entry.motor.Parent then entry.motor.C0 = entry.rest end
		end
		poses[character] = nil
	end
end

function CrouchController.start()
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset, gui.DisplayOrder = "CrouchUI", false, true, 8
	gui.Parent = player:WaitForChild("PlayerGui")
	local made = Instance.new("TextButton")
	made.Name, made.AnchorPoint = "Crouch", Vector2.new(1, 1)
	-- Touch: left of the shift-lock button, both above the default Jump
	-- button and placed from Jump's REAL rectangle (a tablet's Jump is far
	-- bigger than a phone's; the old fixed offsets overlapped it). The side
	-- matches ShiftLockController's (60% of Jump, 48-72 px). Before the touch
	-- controls exist, the old fixed spot. Re-run every 0.1 s by the loop below,
	-- and it only writes when the signature changes.
	local lastLayout = ""
	local function layout()
		local touch = Device.isTouch()
		if not touch then
			if lastLayout == "desktop" then return end
			lastLayout = "desktop"
			gui.IgnoreGuiInset = true
			made.AnchorPoint = Vector2.new(1, 1)
			made.Size = UDim2.fromOffset(124, 38)
			made.Position = UDim2.new(0.5, -160, 1, -20)
			return
		end
		local jump, touchGui = Device.jumpButton()
		if not jump or not touchGui then
			if lastLayout == "touch" then return end
			lastLayout = "touch"
			gui.IgnoreGuiInset = true
			made.AnchorPoint = Vector2.new(1, 1)
			made.Size = UDim2.fromOffset(66, 52)
			made.Position = UDim2.new(1, -96, 1, -108)
			return
		end
		local position, size = jump.AbsolutePosition, jump.AbsoluteSize
		local signature = `{position.X},{position.Y},{size.X},{size.Y}`
		if signature == lastLayout then return end
		lastLayout = signature
		-- Same inset rules as the touch controls, so the coordinates agree.
		gui.IgnoreGuiInset = touchGui.IgnoreGuiInset
		gui.ScreenInsets = touchGui.ScreenInsets
		local side = math.clamp(math.floor(size.X * 0.6), 48, 72)
		made.AnchorPoint = Vector2.new(1, 1)
		made.Size = UDim2.fromOffset(math.floor(side * 1.27), side)
		-- Right edge: Jump's right edge, minus the shift-lock button, minus a gap.
		made.Position = UDim2.fromOffset(position.X + size.X - side - 12, position.Y - 10)
	end
	layout()
	made.BackgroundColor3, made.TextColor3 = Color3.fromRGB(27, 35, 53), Color3.fromRGB(255, 226, 148)
	made.Font, made.TextSize, made.BorderSizePixel = Enum.Font.GothamBold, 12, 0
	made.Text, made.Visible, made.Parent = "CROUCH [C]", false, gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius, corner.Parent = UDim.new(0, 12), made
	local stroke = Instance.new("UIStroke")
	stroke.Color, stroke.Thickness, stroke.Parent = Color3.fromRGB(188, 147, 70), 2, made
	button = made
	made.Activated:Connect(toggle)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and (input.KeyCode == Enum.KeyCode.C or input.KeyCode == Enum.KeyCode.ButtonR3) then toggle() end
	end)
	local function watch(character: Model)
		desired = false
		character:GetAttributeChangedSignal("LaserCrouched"):Connect(function()
			desired = character:GetAttribute("LaserCrouched") == true
		end)
	end
	player.CharacterAdded:Connect(watch)
	if player.Character then watch(player.Character) end
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 0.1 then return end
		elapsed = 0
		layout()
		for _, other in Players:GetPlayers() do
			local character = other.Character
			if character then pose(character, character:GetAttribute("LaserCrouched") == true) end
		end
		for character in poses do if not character.Parent then poses[character] = nil end end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local on = character and character:GetAttribute("LaserCrouched") == true
		local visible = root ~= nil and root:IsA("BasePart") and root.Position.Z >= 0
			and (not UIState.isSuppressed() or UIState.hasClaim("carry"))
		made.Visible = visible
		made.BackgroundColor3 = if on then Color3.fromRGB(112, 39, 48) else Color3.fromRGB(27, 35, 53)
		made.Text = if Device.isTouch() then (if on then "STAND" else "CROUCH") else (if on then "STAND [C]" else "CROUCH [C]")
		if not visible then desired = false end
	end)
end

return CrouchController
