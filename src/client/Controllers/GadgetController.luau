--!strict
--[[
	GadgetController
	Input for the three Cash gadgets (gadgets-patrols area). The tools arrive
	in the Backpack from GadgetService and sit on hotbar keys 3-5; activating
	one sends ("use", key[, aim point]) and nothing else. The server decides
	whether it happened, and every refusal comes back as an ordinary toast.

	THE GRAPPLE AIM is a raycast from the camera through the pointer (the last
	touch on a phone) against the same thing the server will check: map
	geometry that collides. The point is only a hint - the server re-casts
	from the player's verified position and refuses anything that does not
	match within GadgetConfig.GRAPPLE_TARGET_TOLERANCE.

	THE PULL ITSELF is a server-made AlignPosition on this character's root
	(replicated, simulated here because the client owns the character). The
	one thing only this side can do is take the Humanoid out of its grounded
	state, so ground friction does not fight the rope: that happens the moment
	the constraint appears.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local GadgetController = {}

local player = Players.LocalPlayer

--- A local debounce only for feel; the server's cooldowns are the real ones.
local LOCAL_DEBOUNCE = 0.3
--- How far along the pointer ray to look for a surface. The server enforces
--- the real range from the player, not from the camera.
local AIM_DISTANCE = 300

local aimParams: RaycastParams? = nil

local function aimPoint(): Vector3?
	local camera = workspace.CurrentCamera
	local map = workspace:FindFirstChild("Map")
	if not camera or not map then
		return nil
	end
	local params = aimParams
	if not params then
		local built = RaycastParams.new()
		built.FilterType = Enum.RaycastFilterType.Include
		built.FilterDescendantsInstances = { map }
		built.RespectCanCollide = true
		aimParams = built
		params = built
	end
	local mouse = player:GetMouse()
	local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * AIM_DISTANCE, params)
	return if hit then hit.Position else nil
end

local function hookTool(tool: Tool)
	local key = tool:GetAttribute("Gadget")
	local def = if type(key) == "string" then GadgetConfig.Gadgets[key] else nil
	if not def or tool:GetAttribute("_GadgetHooked") then
		return
	end
	-- Tools move between Backpack and Character on every equip: hook ONCE.
	tool:SetAttribute("_GadgetHooked", true)
	local lastPress = 0
	tool.Activated:Connect(function()
		local now = os.clock()
		if now - lastPress < LOCAL_DEBOUNCE then
			return
		end
		lastPress = now
		if def.key == "Grapple" then
			local point = aimPoint()
			if not point then
				return -- aimed at the sky: nothing to send
			end
			Remotes.get("GadgetRequest"):FireServer("use", def.key, point)
		else
			Remotes.get("GadgetRequest"):FireServer("use", def.key)
		end
	end)
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

--- The server hung a GadgetGrapple constraint on our root: go airborne so the
--- Humanoid's grounded movement does not drag against the pull.
local function watchPull(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end
	root.ChildAdded:Connect(function(child)
		if child.Name == "GadgetGrapple" and child:IsA("AlignPosition") and humanoid.Health > 0 then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			task.defer(function()
				if child.Parent and humanoid.Health > 0 then
					humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
				end
			end)
		end
	end)
end

function GadgetController.start()
	watchContainer(player:WaitForChild("Backpack"))
	local function onCharacter(character: Model)
		watchContainer(character)
		task.spawn(watchPull, character)
	end
	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
	-- A fresh Backpack comes with every respawn.
	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watchContainer(child)
		end
	end)
end

return GadgetController
