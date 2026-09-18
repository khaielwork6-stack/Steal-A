-- Run in Studio Edit after group ownership verification. Does not replace pets.
local animal = "Cat"
local drafts = game.ServerStorage.Round3GenerationDrafts
local source = drafts[animal .. "PublishedDraft"]
assert(not drafts:FindFirstChild(animal .. "RigDraft"), "Rig already exists")
local model = Instance.new("Model")
model.Name = animal .. "RigDraft"
for _, part in source:GetDescendants() do
	if part:IsA("MeshPart") then
		local copy = part:Clone()
		for _, child in copy:GetChildren() do
			if child:IsA("LuaSourceContainer") or child:IsA("PackageLink") then child:Destroy() end
		end
		copy.Anchored = true
		copy.Parent = model
	end
end
model:ScaleTo(model:GetScale() * 6 / model:GetExtentsSize().Y)
local box, size = model:GetBoundingBox()
model:PivotTo(model:GetPivot() + Vector3.new(-box.X, size.Y / 2 - box.Y, -box.Z))
local torso = model:FindFirstChild("Torso")
local head = model:FindFirstChild("Head")
assert(torso and head and head.Position.Z < torso.Position.Z, "Pet must face negative Z")
local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.Size = Vector3.new(2, 2, 1)
root.CFrame = CFrame.new(torso.Position)
root.Transparency = 1
root.Anchored = true
root.CanCollide = false
root.CanTouch = false
root.CanQuery = false
root.Parent = model
model.PrimaryPart = root
local function motor(name, parent, child, position)
	local joint = Instance.new("Motor6D")
	joint.Name = name
	joint.Part0 = parent
	joint.Part1 = child
	local at = CFrame.new(position)
	joint.C0 = parent.CFrame:ToObjectSpace(at)
	joint.C1 = child.CFrame:ToObjectSpace(at)
	joint.Parent = parent
end
motor("Root", root, torso, torso.Position)
motor("Neck", torso, head, torso.Position:Lerp(head.Position, 0.6))
for _, name in { "FrontLeft", "FrontRight", "HindLeft", "HindRight" } do
	local leg = model:FindFirstChild(name)
	assert(leg, "Missing pet leg")
	motor(name .. "Joint", torso, leg, leg.Position + Vector3.new(0, leg.Size.Y * 0.42, 0))
end
local tail = model:FindFirstChild("Tail")
assert(tail, "Missing tail")
motor("TailJoint", torso, tail, tail.Position:Lerp(torso.Position, 0.5))
local humanoid = Instance.new("Humanoid")
humanoid.RequiresNeck = false
humanoid.RigType = Enum.HumanoidRigType.R15
humanoid.HipHeight = math.max(0, root.Position.Y - root.Size.Y / 2)
humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
humanoid.Parent = model
Instance.new("Animator", humanoid)
for _, part in model:GetDescendants() do
	if part:IsA("BasePart") and part ~= root then
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true
	end
end
model:SetAttribute("PetRig", true)
model.Parent = drafts
local spec = { name = animal, humanoid = true, hipHeight = humanoid.HipHeight, parts = {}, joints = {} }
local ordered = { root }
for _, part in model:GetChildren() do if part:IsA("MeshPart") then table.insert(ordered, part) end end
for _, part in ordered do
	local x, y, z = part.CFrame:ToEulerAnglesXYZ()
	local p = { name = part.Name, size = { part.Size.X, part.Size.Y, part.Size.Z },
		position = { part.Position.X, part.Position.Y, part.Position.Z },
		rotation = { math.deg(x), math.deg(y), math.deg(z) }, color = { 255, 255, 255 },
		material = "plastic", shape = "block", transparency = part.Transparency }
	if part:IsA("MeshPart") then
		local scale = part.Size / part.MeshSize
		p.mesh = { id = part.MeshId:match("%d+"), texture = part.TextureID:match("%d+"), scale = { scale.X, scale.Y, scale.Z } }
	end
	table.insert(spec.parts, p)
end
for _, joint in model:GetDescendants() do
	if joint:IsA("Motor6D") then table.insert(spec.joints, { name = joint.Name,
		parent = joint.Part0.Name, child = joint.Part1.Name,
		C0 = { joint.C0:GetComponents() }, C1 = { joint.C1:GetComponents() } }) end
end
return game:GetService("HttpService"):JSONEncode(spec)
