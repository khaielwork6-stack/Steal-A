--!strict
--[[
	MutationVfx
	Applies a mutation's particle effect to ANY loot model.

	One system, no per-item code. The artist authors an effect once per mutation
	in ReplicatedStorage.GameAssets.Mutations and every item in the game picks it
	up automatically - including items that do not exist yet.

	HOW THE AUTHORED ASSETS ARE SHAPED
	They are not uniform, and that is fine. Each one is a container holding some
	mix of ParticleEmitters, Attachments (with their own nested emitters), Beams,
	Trails and Lights:

	    Shiny      Model  -> Attachment -> 5 emitters
	    Golden     Model  -> emitters + nested Attachments
	    Flaming    Part   -> emitters + Attachment
	    Corrupted  Model  -> MainPart -> emitters + Attachments

	So rather than assuming a layout, this finds whichever instance actually
	holds the effect (a BasePart if there is one, otherwise the container itself)
	and copies its emitter/attachment children onto the target part. Attachments
	carry their children with them, so nested emitters come along for free.

	SIZING
	Effects were authored around a ~4 stud prop. A Giant Meteorite and a Pharaoh
	Mask are wildly different, so emitter Size and Speed are scaled by the
	target's actual size. Without this the small items vanish inside their own
	particles.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local MutationVfx = {}

-- The size the effects were authored against.
local REFERENCE_STUDS = 4
-- Beyond this an effect stops reading as an aura and starts hiding the item.
local MAX_SCALE = 2.5
local MIN_SCALE = 0.35

local EFFECT_CLASSES = { "ParticleEmitter", "Beam", "Trail", "PointLight", "SpotLight" }

local function isEffect(instance: Instance): boolean
	for _, className in EFFECT_CLASSES do
		if instance:IsA(className) then
			return true
		end
	end
	return false
end

--- Where the authored effect actually lives. A container Model may hold the
--- emitters directly, or wrap a part that holds them.
local function effectSource(template: Instance): Instance
	if template:IsA("BasePart") then
		return template
	end
	local part = template:FindFirstChildWhichIsA("BasePart")
	-- Only prefer the part if it is the one carrying the effect; some templates
	-- are a bare Model with the emitters parented straight to it.
	if part then
		for _, child in part:GetChildren() do
			if isEffect(child) or child:IsA("Attachment") then
				return part
			end
		end
	end
	return template
end

local function templatesFolder(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local folder = assets and assets:FindFirstChild("Mutations")
	return if folder and folder:IsA("Folder") then folder else nil
end

local function scaleEmitter(emitter: ParticleEmitter, scale: number)
	if scale == 1 then
		return
	end

	local sizeKeys = {}
	for _, key in emitter.Size.Keypoints do
		table.insert(sizeKeys, NumberSequenceKeypoint.new(key.Time, key.Value * scale, key.Envelope * scale))
	end
	emitter.Size = NumberSequence.new(sizeKeys)

	local speed = emitter.Speed
	emitter.Speed = NumberRange.new(speed.Min * scale, speed.Max * scale)
end

--- Largest world-space dimension of a model, used to size the effect.
local function spanOf(model: Model): number
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

--- Removes any previously applied mutation dressing. Safe to call on a clean
--- model; used so a model can be re-dressed without stacking effects.
function MutationVfx.clear(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:GetAttribute("MutationVfx") then
			descendant:Destroy()
		end
	end
	local glow = model:FindFirstChild("MutationGlow")
	if glow then
		glow:Destroy()
	end
end

--- Dresses `model` for `mutationId`. Normal (or an unknown id) leaves it bare.
--- Returns true when something was applied.
function MutationVfx.apply(model: Model, mutationId: string?): boolean
	local mutation = RarityConfig.normaliseMutation(mutationId)
	MutationVfx.clear(model)

	if mutation == "Normal" then
		return false
	end

	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		return false
	end

	-- A coloured glow reads at distance where particles do not, and is the
	-- fallback if an effect asset is missing.
	local tint = RarityConfig.MutationColors[mutation]
	if tint then
		local highlight = Instance.new("Highlight")
		highlight.Name = "MutationGlow"
		highlight.FillColor = tint
		highlight.OutlineColor = tint
		-- Escalate with the ladder: Shiny is a sheen, Corrupted is lurid.
		local rank = RarityConfig.mutationRank(mutation)
		highlight.FillTransparency = math.clamp(0.88 - rank * 0.06, 0.6, 0.95)
		highlight.OutlineTransparency = 0.25
		highlight.Adornee = model
		highlight.Parent = model
	end

	local folder = templatesFolder()
	local template = folder and folder:FindFirstChild(mutation)
	if not template then
		return tint ~= nil
	end

	local source = effectSource(template)
	local scale = math.clamp(spanOf(model) / REFERENCE_STUDS, MIN_SCALE, MAX_SCALE)

	local applied = false
	for _, child in source:GetChildren() do
		if isEffect(child) or child:IsA("Attachment") then
			local copy = child:Clone()
			-- Tagged so clear() can find every piece later without guessing.
			copy:SetAttribute("MutationVfx", true)

			if copy:IsA("ParticleEmitter") then
				copy.Enabled = true
				scaleEmitter(copy, scale)
			end
			for _, nested in copy:GetDescendants() do
				if nested:IsA("ParticleEmitter") then
					nested.Enabled = true
					scaleEmitter(nested, scale)
				end
			end

			copy.Parent = anchor
			applied = true
		end
	end

	return applied
end

return MutationVfx
