--!strict
-- Input and pose only. LaserService validates the posture and tests the body.
-- No WalkSpeed, JumpPower, CameraOffset or saved setting is changed here.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CrouchController = {}
local player = Players.LocalPlayer
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

--- The posture the player asked for, the instant they asked (the server's
--- confirmation, `LaserCrouched`, arrives a network trip later). The client-side
--- laser hit test (LaserHitController) uses it so pressing crouch just before a
--- beam counts at once.
function CrouchController.isCrouched(): boolean
	return desired
end

function CrouchController.start()
	-- NO BUTTON. The on-screen CROUCH / STAND button is gone on every device
	-- (owner's call: it crowded the bottom-right with the jump button and the
	-- shift lock, and the pose is only ever needed under a laser). Crouching
	-- is the C key / R3; the pose and the server round-trip are unchanged.
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
		for _, other in Players:GetPlayers() do
			local character = other.Character
			if character then pose(character, character:GetAttribute("LaserCrouched") == true) end
		end
		for character in poses do if not character.Parent then poses[character] = nil end end
		-- Standing back up when the player leaves the lasers' half of the map.
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart") and root.Position.Z >= 0) then desired = false end
	end)
end

return CrouchController
