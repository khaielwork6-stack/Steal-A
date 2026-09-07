--!strict
--[[
	SizeAura
	The authored aura that surrounds a big loot item.

	One system, no per-item code, and the same shape as MutationVfx: the artist
	authors one effect per SIZE TIER in ReplicatedStorage.GameAssets.Sizes and
	every item in the game picks it up automatically.

	    BigAura  HugeAura  GiantAura  TitanAura  ColossalAura

	HOW THE AUTHORED ASSETS ARE SHAPED
	Each is a 1.5-stud invisible Part holding two fast "spark" emitters, plus an
	Attachment carrying eight slow swirl emitters. The swirls are what read as
	the aura; the sparks are the burst that sells it. Nothing about that layout
	is assumed here - whatever emitters, beams, trails, lights and attachments
	the template holds are copied across.

	SIZING - THE PART THE BRIEF IS ABOUT
	The effect was authored around a small prop, and the item it has to dress
	can be anything from a 4-stud vase to a 70-stud Colossal. Scaling is done
	the way it has to be done for particles, which is NOT by multiplying every
	property by one number:

	  * Size keypoints scale with the item. This is the aura's radius.
	  * Speed scales with the item, so a spark still crosses the same fraction
	    of the item in the same time. Lifetime therefore stays untouched -
	    scaling both would make a big aura's particles live longer AND move
	    faster, which reads as slow motion.
	  * Rate, colour, texture, transparency, rotation, light emission and
	    acceleration are the artist's and are copied verbatim. Multiplying Rate
	    is how a server full of Colossals kills a phone.

	The attachment is re-seated on the item's BOUNDING-BOX CENTRE rather than
	on the anchor part's origin, because an import's PrimaryPart is often a
	handle at one end - hang the aura off that and it sits beside the item
	instead of around it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local SizeAura = {}

--- The span the templates were authored against, in studs.
local REFERENCE_STUDS = 6
--- Below Big there is no aura at all; these are the tiers that have one.
local TIERS: { [string]: string } = {
	Big = "BigAura",
	Huge = "HugeAura",
	Giant = "GiantAura",
	Titan = "TitanAura",
	Colossal = "ColossalAura",
}
--- A Colossal is up to twenty times its authored model, but an aura twenty
--- times the authored radius is a fog bank. It keeps growing, more slowly.
local MAX_SCALE = 8
local MIN_SCALE = 0.5
--- Marks every instance this module added, so clear() never has to guess.
local TAG = "SizeAura"

local EFFECT_CLASSES = { "ParticleEmitter", "Beam", "Trail", "PointLight", "SpotLight" }

local function isEffect(instance: Instance): boolean
	for _, className in EFFECT_CLASSES do
		if instance:IsA(className) then
			return true
		end
	end
	return false
end

local function templatesFolder(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	return assets and assets:FindFirstChild("Sizes")
end

--- Where the authored effect actually lives: the Part if it carries the
--- emitters, otherwise the container itself.
local function effectSource(template: Instance): Instance
	if template:IsA("BasePart") then
		return template
	end
	local part = template:FindFirstChildWhichIsA("BasePart")
	if part then
		for _, child in part:GetChildren() do
			if isEffect(child) or child:IsA("Attachment") then
				return part
			end
		end
	end
	return template
end

local function scaleEmitter(emitter: ParticleEmitter, scale: number)
	if math.abs(scale - 1) < 0.01 then
		return
	end

	local keys = {}
	for _, key in emitter.Size.Keypoints do
		table.insert(keys, NumberSequenceKeypoint.new(key.Time, key.Value * scale, key.Envelope * scale))
	end
	emitter.Size = NumberSequence.new(keys)

	local speed = emitter.Speed
	emitter.Speed = NumberRange.new(speed.Min * scale, speed.Max * scale)
	-- Acceleration is a world-space vector: a spark thrown twice as far needs
	-- the same proportional pull, or a big aura's particles hang in the air.
	emitter.Acceleration *= scale
end

--- The tier's template name, or nil for a size with no aura.
function SizeAura.templateName(sizeId: string?): string?
	if not sizeId or not RarityConfig.SizeById[sizeId] then
		return nil
	end
	return TIERS[sizeId]
end

--- Removes any aura this module applied. Safe on a clean model.
function SizeAura.clear(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:GetAttribute(TAG) then
			descendant:Destroy()
		end
	end
end

--- Dresses `model` with the aura for `sizeId`. Normal (or an unknown id)
--- leaves it bare. Returns true when something was applied.
function SizeAura.apply(model: Model, sizeId: string?): boolean
	SizeAura.clear(model)

	local templateName = SizeAura.templateName(sizeId)
	if not templateName then
		return false
	end

	local folder = templatesFolder()
	local template = folder and folder:FindFirstChild(templateName)
	if not template then
		return false
	end

	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		return false
	end

	-- The item's real extent, and where its middle is relative to the part the
	-- effect will hang from.
	local boxCFrame, boxSize = model:GetBoundingBox()
	local span = math.max(boxSize.X, boxSize.Y, boxSize.Z)
	local scale = math.clamp(span / REFERENCE_STUDS, MIN_SCALE, MAX_SCALE)
	local centreOffset = anchor.CFrame:PointToObjectSpace(boxCFrame.Position)

	local source = effectSource(template)
	local applied = false

	for _, child in source:GetChildren() do
		if isEffect(child) or child:IsA("Attachment") then
			local copy = child:Clone()
			copy:SetAttribute(TAG, true)

			if copy:IsA("Attachment") then
				-- Seat the swirl on the item's middle, not the handle's origin.
				copy.Position = centreOffset
			end
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

	if applied then
		model:SetAttribute("SizeAuraTier", templateName)
	end
	return applied
end

return SizeAura
