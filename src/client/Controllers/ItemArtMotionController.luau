--!strict
-- One local manager for mesh sub-elements. Server/carry assemblies retain
-- WeldConstraints; animated Welds are created only on revealed base trophies.
-- No animation is applied to Index cards, roulette silhouettes or carried loot.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ready = require(ReplicatedStorage.Shared.Util.ItemArtReady)
local Controller = {}
type Joint = {part: BasePart, weld: Weld, rest: CFrame, scale: number, mode: string, axis: string, speed: number, phase: number}
type Entry = {joints: {Joint}, particles: {ParticleEmitter}, near: boolean}
local entries: {[Model]: Entry} = {}
local reduced = false
local started = false

local function pose(model: Model, joint: Joint, now: number, moving: boolean)
	local primary = model.PrimaryPart
	if not primary or not joint.part.Parent or not joint.weld.Parent then return end
	local ratio = model:GetScale() / joint.scale
	local cf = CFrame.new(joint.rest.Position * ratio) * joint.rest.Rotation
	if moving then
		local angle = now * joint.speed + joint.phase
		if joint.mode == "Hover" then
			cf += Vector3.new(0, math.sin(angle) * 0.12 * ratio, 0)
		elseif joint.mode == "Orbit" then
			cf = CFrame.Angles(0, angle, 0) * cf
		elseif joint.mode == "Spin" then
			cf *= if joint.axis == "Z" then CFrame.Angles(0, 0, angle) else CFrame.Angles(0, angle, 0)
		elseif joint.mode == "Swing" then
			-- A pendulum swings from its top attachment, not its centre.
			local half=joint.part.Size.Y*0.5
			cf *= CFrame.new(0,half,0)*CFrame.Angles(0,0,math.sin(angle)*0.18)*CFrame.new(0,-half,0)
		end
	end
	joint.weld.C0 = cf
	-- Trophies are anchored by BaseService. Keep the rendered pose synchronized
	-- with C0 without changing physics or ownership of those anchored pieces.
	joint.part.CFrame = primary.CFrame * cf
end

function Controller.setReducedEffects(value: boolean)
	reduced = value
	for _, entry in entries do
		for _, emitter in entry.particles do
			emitter.Enabled = not value and entry.near
			if value then emitter:Clear() end
		end
	end
	if value then
		for model, entry in entries do
			for _, joint in entry.joints do pose(model, joint, 0, false) end
		end
	end
end

local function register(model: Model)
	if entries[model] or not Ready.check(model) or not model.PrimaryPart or model:GetAttribute("RevealHold") then return end
	local joints: {Joint} = {}
	local particles: {ParticleEmitter} = {}
	for _, part in model:GetDescendants() do
		if part:IsA("ParticleEmitter") and part:GetAttribute("ItemArtParticle") then
			part.Enabled = not reduced
			table.insert(particles, part)
		end
		if part:IsA("BasePart") and part ~= model.PrimaryPart then
			local mode = part:GetAttribute("ItemArtMotion")
			if type(mode) ~= "string" then continue end
			local rest = model.PrimaryPart.CFrame:ToObjectSpace(part.CFrame)
			for _, old in model.PrimaryPart:GetChildren() do
				if old:IsA("WeldConstraint") and old.Part1 == part then old:Destroy() end
			end
			local weld = Instance.new("Weld")
			weld.Name = "ItemArtMotionWeld"
			weld.Part0, weld.Part1, weld.C0 = model.PrimaryPart, part, rest
			weld:SetAttribute("ItemArtMotion", mode)
			weld.Parent = model.PrimaryPart
			table.insert(joints, {part=part, weld=weld, rest=rest, scale=model:GetScale(), mode=mode,
				axis=tostring(part:GetAttribute("ItemArtAxis") or "Y"),
				speed=tonumber(part:GetAttribute("ItemArtSpeed")) or 0.6,
				phase=tonumber(part:GetAttribute("ItemArtPhase")) or 0})
		end
	end
	entries[model] = {joints=joints, particles=particles, near=false}
end

function Controller.start()
	if started then return end
	started = true
	local map = workspace:WaitForChild("Map", 30)
	local bases = map and map:WaitForChild("Bases", 15)
	if not bases then return end
	local lastCull = 0
	-- Registered after DisplayFx: that manager owns the whole model's turn;
	-- this one updates only the joints relative to its final primary frame.
	RunService.Heartbeat:Connect(function()
		local camera = workspace.CurrentCamera
		if not camera then return end
		local now = os.clock()
		if now - lastCull >= 0.5 then
			lastCull = now
			for _, item in bases:GetDescendants() do
				if item:IsA("Model") and item.Name == "Trophy" and item:GetAttribute("ProceduralItemArt") then register(item) end
			end
			for model, entry in entries do
				if not model:IsDescendantOf(bases) then entries[model] = nil; continue end
				entry.near = (model:GetPivot().Position - camera.CFrame.Position).Magnitude <= 260
				for _, emitter in entry.particles do emitter.Enabled = entry.near and not reduced end
			end
		end
		if reduced then return end
		for model, entry in entries do
			if not entry.near or not model.Parent or model:GetAttribute("RevealHold") then continue end
			for _, joint in entry.joints do pose(model, joint, now, true) end
		end
	end)
end

return Controller
