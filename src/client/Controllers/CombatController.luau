--!strict
--[[
	CombatController
	Bat swings and trap placement input.

	The swing animation plays immediately on activation so the tool feels
	responsive, then a request goes to the server. The client never decides who
	was hit or whether the swing connected - it only reports intent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PvPConfig = require(ReplicatedStorage.Shared.Config.PvPConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local CombatController = {}

local player = Players.LocalPlayer

--- Local-only swing flourish. Purely cosmetic; the server is deciding the hit
--- in parallel, so a client that skips this gains nothing.
local function playSwing(tool: Tool)
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end

	local motor = handle:FindFirstChildWhichIsA("Weld") or handle:FindFirstChildWhichIsA("Motor6D")
	if not motor then
		return
	end

	local original = motor.C1
	local swung = original * CFrame.Angles(math.rad(-95), 0, 0)

	local out = TweenService:Create(motor, TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { C1 = swung })
	out:Play()
	out.Completed:Once(function()
		TweenService:Create(motor, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { C1 = original }):Play()
	end)
end

local function hookTool(tool: Tool)
	if tool.Name == "Bat" then
		local cooling = false
		tool.Activated:Connect(function()
			if cooling then
				return
			end
			cooling = true
			task.delay(PvPConfig.BAT_COOLDOWN, function()
				cooling = false
			end)

			playSwing(tool)
			Remotes.get("BatSwingRequest"):FireServer()
		end)
	elseif tool.Name == "Trap" then
		tool.Activated:Connect(function()
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root or not root:IsA("BasePart") then
				return
			end
			-- Suggest a spot just ahead; the server clamps and validates it.
			local target = root.Position + root.CFrame.LookVector * 8
			Remotes.get("TrapPlaceRequest"):FireServer(target)
		end)
	end
end

local function watchContainer(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			hookTool(child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			hookTool(child)
		end
	end)
end

function CombatController.start()
	local backpack = player:WaitForChild("Backpack")
	watchContainer(backpack)

	local function onCharacter(character: Model)
		watchContainer(character)
	end

	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
end

return CombatController
