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

--- Local-only swing. Purely cosmetic; the server is deciding the hit in
--- parallel, so a client that skips this gains nothing.
---
--- THREE BEATS, TIMED TO THE SERVER. A short pull BACK, a fast snap THROUGH
--- that arrives exactly at PvPConfig.BAT_STRIKE_DELAY - the frame the server
--- resolves the hit and plays the connect sound - and an elastic settle back to
--- the grip. The strike lands where the eye expects it to, which is what makes
--- a hit read as "I connected" rather than "something happened near me".
---
--- Driven through the tool's own grip weld (the RightGrip Roblox creates on
--- equip) rather than an uploaded animation, so it needs no asset and works on
--- every rig the avatar system produces.
local WINDUP = 0.06
local SETTLE = 0.34

local function playSwing(tool: Tool)
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end

	-- The grip weld lives on the right hand/arm, with Part1 = Handle.
	local character = player.Character
	local motor: Motor6D | Weld | nil = nil
	if character then
		for _, descendant in character:GetDescendants() do
			if (descendant:IsA("Weld") or descendant:IsA("Motor6D")) and descendant.Part1 == handle then
				motor = descendant :: any
				break
			end
		end
	end
	if not motor then
		motor = (handle:FindFirstChildWhichIsA("Weld") or handle:FindFirstChildWhichIsA("Motor6D")) :: any
	end
	if not motor then
		return
	end
	local grip = motor :: Weld

	-- Never restart from a half-finished swing's C1: the rest pose is remembered
	-- once, so rapid swings cannot walk the bat out of the hand.
	local rest = grip:GetAttribute("_RestC1") :: CFrame?
	if not rest then
		rest = grip.C1
		grip:SetAttribute("_RestC1", rest)
	end
	local restC1 = rest :: CFrame

	local back = restC1 * CFrame.Angles(math.rad(35), math.rad(-20), 0)
	local through = restC1 * CFrame.Angles(math.rad(-110), math.rad(25), 0)
	local strikeTime = math.max(0.02, PvPConfig.BAT_STRIKE_DELAY - WINDUP)

	grip.C1 = restC1
	local windup = TweenService:Create(grip, TweenInfo.new(WINDUP, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { C1 = back })
	windup:Play()
	windup.Completed:Once(function()
		local snap = TweenService:Create(grip, TweenInfo.new(strikeTime, Enum.EasingStyle.Quart, Enum.EasingDirection.In), { C1 = through })
		snap:Play()
		snap.Completed:Once(function()
			TweenService:Create(grip, TweenInfo.new(SETTLE, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { C1 = restC1 }):Play()
		end)
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
