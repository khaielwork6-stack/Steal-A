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

--- The swing. Purely cosmetic on this side; the server resolves the hit at
--- PvPConfig.BAT_STRIKE_DELAY regardless, so a client that skips this gains
--- nothing.
---
--- A REAL ANIMATION, NOT AN INVENTED ONE. This project has no uploaded swing
--- asset, and none is fabricated here. Roblox's own Animate script - the one
--- every avatar spawns with - ships a per-rig `toolslash` animation and plays it
--- whenever a StringValue named "toolanim" with the value "Slash" is added to
--- the equipped Tool (the mechanism the classic sword used, still honoured by
--- the current R15 and R6 scripts, verified on this rig). That gives a proper
--- arm-and-bat swing through the Animator, replicated to everyone, from an
--- animation Roblox owns.
---
--- The Animate script consumes the StringValue and only ever plays one slash
--- at a time, so hammering the button cannot stack tracks; the cooldown gate in
--- hookTool below stops the requests before that anyway.
---
--- FALLBACK: a character without an Animate script (a custom StarterCharacter,
--- say) gets the old grip-weld swing so the bat still visibly moves.
local WINDUP = 0.06
local SETTLE = 0.34

local function gripSwing(tool: Tool)
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end
	local character = player.Character
	local motor: Weld? = nil
	if character then
		for _, descendant in character:GetDescendants() do
			if (descendant:IsA("Weld") or descendant:IsA("Motor6D")) and (descendant :: any).Part1 == handle then
				motor = descendant :: any
				break
			end
		end
	end
	if not motor then
		return
	end
	local grip = motor :: Weld
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

local function playSwing(tool: Tool)
	local character = player.Character
	local animate = character and character:FindFirstChild("Animate")
	if animate and animate:FindFirstChild("toolslash") then
		-- Consumed by the Animate script on the next frame; it destroys it.
		local cue = Instance.new("StringValue")
		cue.Name = "toolanim"
		cue.Value = "Slash"
		cue.Parent = tool
		-- Belt and braces: if a modified Animate script ignores it, it must not
		-- pile up inside the tool.
		task.delay(0.5, function()
			if cue.Parent then
				cue:Destroy()
			end
		end)
		return
	end
	gripSwing(tool)
end

local function hookTool(tool: Tool)
	-- A Tool moves between Backpack and Character on every equip and unequip,
	-- and both containers are watched, so the same tool arrives here again and
	-- again. Hook it ONCE, or each equip would add another Activated connection
	-- and one click would swing - and request - several times.
	if tool:GetAttribute("_CombatHooked") then
		return
	end
	tool:SetAttribute("_CombatHooked", true)

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
