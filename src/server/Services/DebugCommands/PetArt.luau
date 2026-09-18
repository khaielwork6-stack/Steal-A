--!strict
-- Studio fixture only: exercises the real rig builder without reading or changing profiles.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuardianService = require(script.Parent.Parent.GuardianService)
local PetAnimationTracks = require(script.Parent.Parent.PetAnimationTracks)
local Config = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)

return {
	petArtTest = function(_player: Player)
		local fixture = Instance.new("Folder")
		fixture.Name = "PetArtTestFixture"
		fixture.Parent = workspace
		local controllers: { PetAnimationTracks.Player } = {}
		local ok, result = pcall(function()
			local floor = Instance.new("Part")
			floor.Size = Vector3.new(120, 1, 120)
			floor.CFrame = CFrame.new(0, 499.5, 0)
			floor.Anchored = true
			floor.Parent = fixture
			local reports = {}
			for index, def in Config.Guardians do
				local source = ReplicatedStorage.GameAssets.BaseGuardians:FindFirstChild(def.modelName)
				assert(source and source:GetAttribute("PetRig") == true, "Missing final pet rig")
				local rig = GuardianService.buildRigFrom(source, Config.HEIGHT, 1, def.key, CFrame.identity)
				rig.Parent = fixture
				rig:PivotTo(CFrame.new((index - 2.5) * 20, 505, 20))
				local root = rig.PrimaryPart :: BasePart
				root:SetNetworkOwner(nil)
				local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
				local controller = PetAnimationTracks.attach(rig, def.animations)
				assert(controller, "Missing animation controller")
				table.insert(controllers, controller)
				local deadline = os.clock() + 8
				repeat task.wait(0.1) until controller.update("Idle", 0, os.clock()) or os.clock() >= deadline
				assert(rig:GetAttribute("PetAnimationActive") == true, "Idle did not start")
				task.wait(0.5)
				local shell = rig:FindFirstChild("Shell") :: Model
				local motors = 0
				for _, joint in shell:GetDescendants() do
					if joint:IsA("Motor6D") then motors += 1 end
				end
				assert(motors == 7, "Rig builder discarded joints")
				humanoid.WalkSpeed = 12
				assert(controller.update("Returning", 12, os.clock()))
				local start = root.Position
				for _ = 1, 20 do
					humanoid:Move(Vector3.new(0, 0, -1))
					controller.update("Returning", 12, os.clock())
					task.wait(0.05)
				end
				local walked = (root.Position - start).Magnitude
				assert(walked > 3 and root.Position.Y > 499, "Pet could not walk on test floor")
				assert(root.CFrame.LookVector.Z < -0.8, "Pet walks backward")
				humanoid.WalkSpeed = 28
				assert(controller.update("Chasing", 28, os.clock()))
				for _ = 1, 10 do
					humanoid:Move(Vector3.new(0, 0, -1))
					task.wait(0.05)
				end
				humanoid:Move(Vector3.zero)
				controller.defend(os.clock())
				assert(controller.update("Idle", 0, os.clock()))
				task.wait(0.65)
				assert(controller.update("Idle", 0, os.clock()))
				local animator = (shell:FindFirstChildOfClass("Humanoid") :: Humanoid):FindFirstChildOfClass("Animator") :: Animator
				local celebrating = false
				for _, track in animator:GetPlayingAnimationTracks() do
					if def.animations and track.Animation.AnimationId == def.animations.celebrate then celebrating = true end
				end
				assert(celebrating, "Successful defence did not celebrate")
				table.insert(reports, { animal = def.key, motors = motors, walked = walked, celebrate = celebrating })
			end
			return { passed = #reports, reports = reports }
		end)
		for _, controller in controllers do controller.destroy() end
		fixture:Destroy()
		if not ok then error(result) end
		return result
	end,
}
