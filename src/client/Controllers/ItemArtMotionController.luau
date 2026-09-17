--!strict
-- One local manager for mesh sub-elements. Server/carry assemblies retain
-- WeldConstraints; animated Welds are created only on revealed base trophies.
-- No animation is applied to Index cards, roulette silhouettes or carried loot.
--
-- There is no Heartbeat connection here: DisplayFxController calls step()
-- once per frame, after it has turned the trophies (see step()).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ready = require(ReplicatedStorage.Shared.Util.ItemArtReady)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local CULL_RADIUS = GameConfig.CLIENT_MOTION_CULL_RADIUS
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

-- Trophies seen under Map.Bases that are not registered yet. Registration can
-- be refused for a while (art still replicating, RevealHold, the
-- ProceduralItemArt attribute not set yet), so they are retried on the cull
-- pass. This replaces a bases:GetDescendants() rescan every half second.
local pending: {[Model]: boolean} = {}
local basesFolder: Instance? = nil
local lastCull = 0

local function forget(model: Model)
	pending[model] = nil
	entries[model] = nil
end

--- Driven by DisplayFxController's Heartbeat, AFTER it has moved every trophy
--- this frame: the joints are posed relative to the trophy's primary part, so
--- they must read this frame's primary CFrame. (Two independent Heartbeat
--- connections ran in an unspecified order and could leave the sub-parts one
--- frame behind the body.) Safe to call before start().
function Controller.step(now: number)
	local bases = basesFolder
	if not bases then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	local low = Effects.isLowGraphics()
	if now - lastCull >= 0.5 then
		lastCull = now
		for model in pending do
			if entries[model] or not model:IsDescendantOf(bases) then
				pending[model] = nil
			elseif model:GetAttribute("ProceduralItemArt") then
				register(model)
				if entries[model] then pending[model] = nil end
			end
		end
		local cameraPosition = camera.CFrame.Position
		for model, entry in entries do
			if not model:IsDescendantOf(bases) then forget(model); continue end
			entry.near = (model:GetPivot().Position - cameraPosition).Magnitude <= CULL_RADIUS
			-- Graphics LOW counts these sparkles as non-essential.
			for _, emitter in entry.particles do emitter.Enabled = entry.near and not reduced and not low end
		end
	end
	-- Graphics LOW freezes the sub-parts where they are, like the trophy turn.
	if reduced or low then return end
	for model, entry in entries do
		if not entry.near or not model.Parent or model:GetAttribute("RevealHold") then continue end
		for _, joint in entry.joints do pose(model, joint, now, true) end
	end
end

function Controller.start()
	if started then return end
	started = true
	local map = workspace:WaitForChild("Map", 30)
	local bases = map and map:WaitForChild("Bases", 15)
	if not bases then return end
	local function consider(item: Instance)
		if item:IsA("Model") and item.Name == "Trophy" then
			local model = item :: Model
			if not entries[model] then pending[model] = true end
		end
	end
	for _, item in bases:GetDescendants() do consider(item) end
	bases.DescendantAdded:Connect(consider)
	bases.DescendantRemoving:Connect(function(item: Instance)
		if item:IsA("Model") and item.Name == "Trophy" then forget(item :: Model) end
	end)
	-- Last: step() only runs once the registry is seeded.
	basesFolder = bases
end

return Controller
