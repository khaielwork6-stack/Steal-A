--!strict
--[[
	MysteryModel
	Builds the sealed mystery container: one zone's authored model, normalised
	to a standard height, grown to the hidden size variant, dressed with the
	hidden mutation's effects, and given an invisible interaction hitbox.

	THE ONE RULE. Nothing this module puts on a container may identify what is
	inside it. It applies SIZE and MUTATION dressing - both of which the player
	is meant to read - and a rarity-NEUTRAL mystery sparkle. It never attaches
	a name, a rarity colour, an income figure or a BillboardGui.

	WHERE THE MODELS LIVE
	They shipped loose in Workspace, which puts twelve containers in the sky
	over the lobby. `adoptFolder` moves the folder into ServerStorage the first
	time anything asks for a template, so the world is clean whether or not the
	place is re-saved, and `templateFor` finds them in either place.

	SCALING IS NORMALISED, THEN GROWN, EXACTLY ONCE
	Each authored mesh arrives at its own scale (the twelve range from 2.9 to
	6.3 studs). Every one is brought to MysteryConfig.CONTAINER_HEIGHT first,
	so a Normal container is the same physical size in every zone, and the
	size variant multiplies on top of THAT. Both happen once, on a fresh clone;
	nothing that re-parents or re-seats a container scales it again.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local MutationVfx = require(ReplicatedStorage.Shared.Util.MutationVfx)
local MysteryConfig = require(ReplicatedStorage.Shared.Config.MysteryConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local SizeAura = require(ReplicatedStorage.Shared.Util.SizeAura)

local MysteryModel = {}

--- Marks every instance this module adds, so a rebuild never doubles them up.
local TAG = "MysteryDressing"
local HITBOX_NAME = "MysteryHitbox"

-- ==========================================================
-- FINDING THE TEMPLATES
-- ==========================================================

local function serviceByName(name: string): Instance?
	if name == "ServerStorage" then
		return if RunService:IsServer() then ServerStorage else nil
	elseif name == "ReplicatedStorage" then
		return ReplicatedStorage
	elseif name == "Workspace" then
		return workspace
	end
	return nil
end

local function resolve(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, step in path do
		if not current then
			return nil
		end
		current = current:FindFirstChild(step)
	end
	return current
end

--- The folder holding the twelve container models, wherever it is. On the
--- server, a folder found in Workspace is MOVED into ServerStorage.GameAssets
--- so the templates are not standing in the world; everything else is left
--- exactly where it is.
function MysteryModel.folder(): Instance?
	for _, entry in MysteryConfig.MODEL_SEARCH do
		local service = serviceByName(entry.service)
		local found = if service then resolve(service, entry.path) else nil
		if found then
			if entry.service == "Workspace" and RunService:IsServer() then
				local assets = ServerStorage:FindFirstChild("GameAssets")
				if assets then
					found.Parent = assets
					print(`[MysteryModel] moved {MysteryConfig.MODEL_FOLDER_NAME} out of Workspace into ServerStorage.GameAssets`)
				else
					found.Parent = ServerStorage
					print(`[MysteryModel] moved {MysteryConfig.MODEL_FOLDER_NAME} out of Workspace into ServerStorage`)
				end
			end
			return found
		end
	end
	return nil
end

--- A zone's authored container model, by any of its accepted names. Nil when
--- that zone has none - NEVER another zone's model.
function MysteryModel.templateFor(zoneIndex: number): Instance?
	local folder = MysteryModel.folder()
	local entry = MysteryConfig.ZoneModels[zoneIndex]
	if not folder or not entry then
		return nil
	end
	for _, alias in entry.aliases do
		local found = folder:FindFirstChild(alias)
		if found then
			return found
		end
	end
	-- Last resort: a case-insensitive match, so a rename that only changes
	-- capitalisation is not a missing model.
	local wanted = string.lower(entry.aliases[1])
	for _, child in folder:GetChildren() do
		if string.lower(child.Name) == wanted then
			return child
		end
	end
	return nil
end

export type ModelReport = {
	zone: number,
	expected: string,
	found: string?,
	ok: boolean,
	problem: string?,
}

--- Validates all twelve at start-up: present, a Model (or a part we can wrap),
--- has geometry, carries no scripts, and can be cloned. Reports each failure
--- BY THE NAME IT LOOKED FOR so a missing model is obvious, and never
--- substitutes one zone's model for another's.
function MysteryModel.check(): { ModelReport }
	local reports: { ModelReport } = {}
	for zoneIndex = 1, 12 do
		local entry = MysteryConfig.ZoneModels[zoneIndex]
		local expected = entry.aliases[1]
		local template = MysteryModel.templateFor(zoneIndex)
		local report: ModelReport = { zone = zoneIndex, expected = expected, found = nil, ok = false }

		if not template then
			report.problem = "missing"
		elseif not (template:IsA("Model") or template:IsA("BasePart")) then
			report.problem = `wrong class ({template.ClassName})`
		else
			report.found = template.Name
			local parts, scripts = 0, 0
			if template:IsA("BasePart") then
				parts = 1
			end
			for _, d in template:GetDescendants() do
				if d:IsA("BasePart") then
					parts += 1
				elseif d:IsA("BaseScript") then
					scripts += 1
				end
			end
			if parts == 0 then
				report.problem = "no parts"
			else
				report.ok = true
				if scripts > 0 then
					report.problem = `{scripts} script(s) present - stripped on build`
				end
			end
		end
		table.insert(reports, report)
	end
	return reports
end

-- ==========================================================
-- BUILDING
-- ==========================================================

--- Wraps whatever the artist supplied into a Model we own, with a PrimaryPart.
local function adopt(source: Instance): Model?
	if source:IsA("BasePart") then
		local model = Instance.new("Model")
		local part = source:Clone()
		part.Parent = model
		model.PrimaryPart = part
		return model
	end
	if source:IsA("Model") then
		local model = source:Clone()
		-- THE PIVOT IS THE PART'S FRAME, so the part is chosen for its frame
		-- and not for its position in the child list. The zone container art
		-- ships parts with mixed frames; taking the first one gave several
		-- zones a pivot lying on its side, and every PivotTo onto an upright
		-- socket then laid the container on its back. Same rule, same reason
		-- and the same helper as the loot models use.
		local anchor = LootModel.chooseAnchor(model)
		if anchor then
			model.PrimaryPart = anchor
		elseif not model.PrimaryPart then
			model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
		end
		return if model.PrimaryPart then model else nil
	end
	return nil
end

export type BuildOptions = {
	zoneIndex: number,
	--- The hidden size variant's Scale. The container is this many times the
	--- size a Scale-1 container would be.
	scale: number,
	--- The hidden mutation, dressed onto the container.
	mutation: string?,
	--- Largest footprint this context allows (world socket vs pedestal).
	maxFootprint: number?,
	--- Carrying compresses the visual, exactly like carried loot.
	carried: boolean?,
	--- Adds the invisible interaction hitbox. Off for the client's animation
	--- clone, which is never interacted with.
	hitbox: boolean?,
}

--- THE ONE WAY to get a container. Returns nil when the zone has no model -
--- callers must handle that rather than showing something else.
function MysteryModel.build(options: BuildOptions): Model?
	local template = MysteryModel.templateFor(options.zoneIndex)
	if not template then
		return nil
	end
	local model = adopt(template)
	if not model then
		return nil
	end
	model.Name = "MysteryContainer"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	-- SANITISE, exactly as loot art is sanitised: nothing in a container may
	-- run code, drive physics, seat a player or offer a second interaction.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			-- Visual geometry NEVER collides. An enormous container must not
			-- trap a player, shove them, or block the guardian's path.
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			if descendant:IsA("Seat") or descendant:IsA("VehicleSeat") then
				descendant.Disabled = true
			end
		elseif
			descendant:IsA("BaseScript")
			or descendant:IsA("Humanoid")
			or descendant:IsA("ProximityPrompt")
			or descendant:IsA("ClickDetector")
			or descendant:IsA("BodyMover")
			or descendant:IsA("Constraint")
			or descendant:IsA("JointInstance")
			or descendant:IsA("WeldConstraint")
		then
			descendant:Destroy()
		end
	end

	-- NORMALISE to a standard height, then GROW to the size variant. Both in
	-- one relative ScaleTo, so the model is scaled exactly once.
	local displayScale = if options.carried then ScaleConfig.carryScale(options.scale) else options.scale
	local factor = displayScale
	local min, max = LootModel.visibleExtents(model)
	if min and max then
		local size = max - min
		local fit = math.huge
		if size.Y > 0.01 then
			fit = MysteryConfig.CONTAINER_HEIGHT / size.Y
		end
		local widest = math.max(size.X, size.Z)
		if widest > 0.01 then
			fit = math.min(fit, (MysteryConfig.CONTAINER_HEIGHT * MysteryConfig.MAX_WIDTH_RATIO) / widest)
		end
		if fit < math.huge then
			factor *= fit
		end
		-- The context's footprint ceiling, applied to the FINAL scale and only
		-- ever downward.
		if options.maxFootprint then
			local finalWidest = widest * factor
			if finalWidest > options.maxFootprint and finalWidest > 0.01 then
				factor *= options.maxFootprint / finalWidest
			end
		end
	end
	if math.abs(factor - 1) > 0.001 then
		model:ScaleTo(model:GetScale() * factor)
	end

	-- Hold the pieces together: a carry unanchors the PrimaryPart and welds it
	-- to the player, so anything not welded to it would be left behind.
	local primary = model.PrimaryPart
	if primary then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= primary then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "ContainerWeld"
				weld.Part0 = primary
				weld.Part1 = descendant
				weld.Parent = primary
			end
		end
	end

	-- UNCONDITIONAL, even for the client's reveal clone. The box is one
	-- invisible, massless, non-colliding part, and it is what gives the model
	-- an upright pivot - so skipping it would tip the art over in the reveal
	-- animation exactly as it used to on the pads. The option now only says
	-- whether anything INTERACTS with it.
	local box = MysteryModel.ensureHitbox(model)
	if box and options.hitbox == false then
		box.CanQuery = false
		box.CanTouch = false
	end

	-- THE DRESSING. Mutation first (the artist's own effects, the same ones a
	-- revealed item wears), then the size aura, then the neutral sparkle.
	MysteryModel.dress(model, options.mutation, displayScale)

	model:SetAttribute("ContainerScale", options.scale)
	model:SetAttribute("ContainerDisplayScale", displayScale)
	return model
end

--- The invisible, non-colliding interaction hitbox. Constant size whatever the
--- container's visual scale, welded to the art, centred on the visible box -
--- so a Colossal is reached at its middle and a Normal is not fiddly.
function MysteryModel.ensureHitbox(model: Model): BasePart?
	local existing = model:FindFirstChild(HITBOX_NAME)
	if existing and existing:IsA("BasePart") then
		return existing
	end
	local primary = model.PrimaryPart
	if not primary then
		return nil
	end
	local min, max = LootModel.visibleExtents(model)
	local centre = if min and max then (min + max) / 2 else primary.Position

	local box = Instance.new("Part")
	box.Name = HITBOX_NAME
	box.Size = MysteryConfig.HITBOX_SIZE
	box.CFrame = CFrame.new(centre)
	box.Transparency = 1
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.CastShadow = false
	box.Massless = true
	box.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Name = "HitboxWeld"
	weld.Part0 = primary
	weld.Part1 = box
	weld.Parent = box

	-- AND THE BOX BECOMES THE PIVOT. This is the whole reason it is built
	-- axis-aligned.
	--
	-- Model:GetPivot() is the PrimaryPart's frame, and PivotTo(target) re-seats
	-- the model by target * pivot:Inverse() - so whatever tilt the pivot part
	-- carries is applied to the ART the moment anything places the container on
	-- an upright socket. Every zone container is authored upright, but their
	-- art parts carry assorted frames, and with the art as the pivot they were
	-- all laid on their backs on their pads.
	--
	-- This box is created level, at the model's own visible centre, so seating
	-- it upright leaves the art exactly as the artist built it. It is also the
	-- right thing for the carry to weld to and for the prompt to hang from: it
	-- is at the middle of the container rather than at whichever corner an
	-- imported mesh happens to call its origin. Every other part is already
	-- welded to the old primary and the box is welded to it too, so the
	-- assembly stays rigid.
	model.PrimaryPart = box
	return box
end

--- Applies the mutation effects and the size aura to a CONTAINER, scaled to
--- how big the container actually is. Reuses the existing MutationVfx and
--- SizeAura systems rather than duplicating them, so a new mutation asset
--- reaches containers with no code change here.
function MysteryModel.dress(model: Model, mutation: string?, displayScale: number)
	MutationVfx.apply(model, mutation)
	SizeAura.apply(model, ScaleConfig.labelFor(displayScale))
	MysteryModel.addMysterySparkle(model, displayScale)
end

--- Removes everything `dress` added. Called when the container is replaced by
--- the revealed item, so no effect outlives its container.
function MysteryModel.undress(model: Model)
	MutationVfx.clear(model)
	SizeAura.clear(model)
	for _, descendant in model:GetDescendants() do
		if descendant:GetAttribute(TAG) then
			descendant:Destroy()
		end
	end
end

--- The rarity-NEUTRAL sparkle every sealed container wears: the same on a
--- Common as on a Divine, so it can never hint at the reward. Its size and
--- speed follow the container; its RATE does not, so a server full of
--- Colossals cannot melt a phone.
function MysteryModel.addMysterySparkle(model: Model, displayScale: number)
	local primary = model.PrimaryPart
	if not primary then
		return
	end
	local min, max = LootModel.visibleExtents(model)
	local span = if min and max then math.max((max - min).X, (max - min).Y, (max - min).Z) else 5

	local attachment = Instance.new("Attachment")
	attachment.Name = "MysterySparkle"
	attachment.Position = primary.CFrame:PointToObjectSpace(if min and max then (min + max) / 2 else primary.Position)
	attachment:SetAttribute(TAG, true)
	attachment.Parent = primary

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "MysterySparkleEmitter"
	sparkle.Texture = MysteryConfig.MYSTERY_PARTICLE
	sparkle.Color = ColorSequence.new(MysteryConfig.MYSTERY_TINT)
	sparkle.LightEmission = 0.6
	sparkle.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, span * 0.04),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkle.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkle.Lifetime = NumberRange.new(1.1, 1.9)
	-- Rate is deliberately CONSTANT across sizes.
	sparkle.Rate = 5
	sparkle.Speed = NumberRange.new(span * 0.06, span * 0.13)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle:SetAttribute(TAG, true)
	sparkle.Parent = attachment
end

--- Seats a container so its LOWEST VISIBLE point rests `clearance` above a
--- surface. Never lets a big container sink through the floor or a pedestal.
function MysteryModel.seat(model: Model, position: Vector3, surfaceY: number, clearance: number?)
	model:PivotTo(CFrame.new(position.X, surfaceY, position.Z))
	local min = select(1, LootModel.visibleExtents(model))
	if min then
		model:PivotTo(model:GetPivot() + Vector3.new(0, surfaceY + (clearance or 0.2) - min.Y, 0))
	end
end

--- Interaction range for a container: grows with its footprint so the edge of
--- an enormous one is still reachable.
function MysteryModel.interactRange(model: Model): number
	local min, max = LootModel.visibleExtents(model)
	local footprint = if min and max then math.max((max - min).X, (max - min).Z) else 0
	return MysteryConfig.INTERACT_RANGE_MIN + footprint * MysteryConfig.INTERACT_RANGE_PER_STUD
end

return MysteryModel
