--!strict
--[[
	TripGuardController
	Stops the local character from tripping.

	THE BUG. Speed in this game runs into the hundreds of millions, so the
	WalkSpeed the server sets is far past anything a Humanoid was tuned for.
	Roblox's own character physics treats a fast body meeting a wall as a
	stumble: the Humanoid drops into FallingDown, lies on the floor for its
	built-in recovery, tries GettingUp, and at these speeds often trips again
	the moment it stands - a player who touched a wall spent seconds "ragdolled"
	and stuck. Nothing in our code launched them; the engine did.

	THE FIX. FallingDown and Ragdoll are switched OFF on every character of
	ours. A wall is then just a wall: the body stops against it and keeps
	standing. This has to happen HERE, on the client, because the client
	simulates its own character and SetStateEnabled is not replicated - the
	server disables them too (init.server) for the moments it holds physics.

	WHAT IT DOES NOT TOUCH. The deliberate knock-downs (a guardian catch, a bat
	hit) go through RagdollService, which uses PlatformStand + the Physics
	state, never FallingDown or Ragdoll, so they still land the player exactly
	as before. Sitting, jumping, swimming and climbing are untouched.
]]

local Players = game:GetService("Players")

local TripGuardController = {}

local player = Players.LocalPlayer

local function guard(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	-- A state the engine is already in when the flag flips is not exited by
	-- the flag; stand the body up if it was mid-trip at spawn.
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.FallingDown or state == Enum.HumanoidStateType.Ragdoll then
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

function TripGuardController.start()
	player.CharacterAdded:Connect(guard)
	if player.Character then
		task.spawn(guard, player.Character)
	end
end

return TripGuardController
