--!strict
--[[
	TreadmillModel
	The one place a treadmill asset becomes a usable object. Used by the world
	(SpeedService dressing a plot) AND by the Upgrades panel preview, so a player
	never sees a treadmill in the shop that differs from the one they get.

	WHY THE DECORATIVE MESH IS NEVER THE COLLISION
	Each of the nine models is a single AI-generated MeshPart with `Default`
	collision fidelity, which is a crude hull rather than the real surface. Trusting
	it means players catching on handlebars, sinking into arches, or falling
	through a belt that isn't solid where it looks solid. So the mesh is made
	purely decorative - anchored, CanCollide off, CanQuery off, CanTouch off - and
	all gameplay runs off clean invisible Parts we control:

	    Treadmill/            (Folder on the plot, built by MapBuilder)
	      Frame               invisible collision deck - what you actually stand on
	      TrainingTrigger     invisible detection volume - what SpeedService reads
	      Belt                thin cosmetic strip, kept for the activation tint
	      Model/              the decorative mesh, swapped on upgrade

	ALIGNMENT
	Every model is scaled uniformly (never per-axis, so nothing deforms) so its
	long axis matches TreadmillConfig.STANDARD_LENGTH, then sunk by
	`deckHeight - STANDARD_DECK_HEIGHT` so its belt lands exactly on the invisible
	deck. The result: identical belt length, identical standing height, identical
	facing, whatever tier the player is on.

	Every model's pivot happens to sit at its own base, but nothing here relies on
	that - placement measures the true world AABB and positions from the bottom.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)

local TreadmillModel = {}

TreadmillModel.FOLDER_NAME = "Treadmills"
TreadmillModel.MODEL_NAME = "Model" -- the decorative child inside a plot's Treadmill

-- ==========================================================
-- MEASUREMENT
-- ==========================================================

--- True world-axis-aligned bounds. `Model:GetBoundingBox` is oriented to the
--- pivot, so its size is not what you can align or frame a camera against.
function TreadmillModel.worldExtents(root: Instance): (Vector3?, Vector3?)
	local min: Vector3? = nil
	local max: Vector3? = nil
	for _, part in root:GetDescendants() do
		if part:IsA("BasePart") then
			local half = part.Size / 2
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local corner = (part.CFrame * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
						min = if min then min:Min(corner) else corner
						max = if max then max:Max(corner) else corner
					end
				end
			end
		end
	end
	return min, max
end

-- ==========================================================
-- LIBRARY
-- ==========================================================

--- Deliberately in ReplicatedStorage, not ServerStorage: the Upgrades panel
--- renders these client-side.
function TreadmillModel.library(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local folder = assets and assets:FindFirstChild(TreadmillModel.FOLDER_NAME)
	return if folder and folder:IsA("Folder") then folder else nil
end

function TreadmillModel.source(modelKey: string): Model?
	local folder = TreadmillModel.library()
	local found = folder and folder:FindFirstChild(modelKey)
	return if found and found:IsA("Model") then found else nil
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- A decorative, correctly-scaled clone for `level`. Purely visual: it carries no
--- collision, no queries and no scripts, so it is equally safe in the world and
--- inside a ViewportFrame.
---
--- Returns nil when that tier has no art, so callers keep the placeholder rather
--- than crashing.
function TreadmillModel.build(level: number): Model?
	local tier = TreadmillConfig.tier(level)
	if not tier then
		return nil
	end
	local source = TreadmillModel.source(tier.modelKey)
	if not source then
		return nil
	end

	local model = source:Clone()
	model.Name = TreadmillModel.MODEL_NAME

	-- Uniform, and relative: ScaleTo is absolute and a cloned asset may already
	-- carry a scale of its own.
	if math.abs(tier.scale - 1) > 0.001 then
		model:ScaleTo(model:GetScale() * tier.scale)
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			-- Remember the authored look BEFORE anything tints it. The unactivated
			-- treadmill is greyed out, and without this the original colour would
			-- be lost the first time that happened and never come back.
			descendant:SetAttribute("LitColor", descendant.Color)
			descendant:SetAttribute("LitMaterial", descendant.Material.Name)
		elseif descendant:IsA("BaseScript") then
			-- Nothing authored inside an art asset should ever run - least of all
			-- inside a ViewportFrame.
			descendant:Destroy()
		end
	end

	model:SetAttribute("TreadmillLevel", level)
	model:SetAttribute("TreadmillKey", tier.modelKey)
	return model
end

--- Places a built model so its BELT lands exactly on `deckTop`, centred on
--- `deckCentre` in XZ and turned to `rotation`.
---
--- Orient FIRST, then translate by a measured delta. Rotating changes the world
--- AABB, so any offset computed before the turn is wrong afterwards - and these
--- models are not all authored facing the same way.
--- Extents measured in the DECK's frame rather than in world axes, so "long
--- axis" means "along the deck" no matter which way the plot faces.
local function localExtents(model: Model, frame: CFrame): (Vector3?, Vector3?)
	local min: Vector3? = nil
	local max: Vector3? = nil
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local half = part.Size / 2
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local world = (part.CFrame * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
						local corner = frame:PointToObjectSpace(world)
						min = if min then min:Min(corner) else corner
						max = if max then max:Max(corner) else corner
					end
				end
			end
		end
	end
	return min, max
end

--- Which end of the deck a treadmill's console should sit at.
---
--- MEASURED, AND IT DOES NOT CURRENTLY FIRE. Every one of the nine models is a
--- single MeshPart, so `tallestEndZ` below can only see the mesh's BOUNDING BOX,
--- whose corners are symmetric by definition. It therefore returns the same
--- value (-6.5, half the box depth) for all nine, the flip condition is never
--- met, and every model simply keeps the yaw the long-axis pass left it at.
---
--- That is fine in practice - the nine were authored consistently, so they all
--- end up the same way round - but do not believe this step is normalising
--- anything until the models stop being single meshes. It would start working
--- the moment a model arrives with real sub-parts.
---
--- The direction the PLAYER faces is deliberately NOT derived from here for the
--- same reason: see TreadmillConfig.PLAYER_FACING_SIGN.
TreadmillModel.FRONT_SIGN = -1

--- Where the model's highest point sits along the deck axis, measured from the
--- model's OWN centre. On a multi-part model a treadmill's tallest feature is
--- its console, arch or halo, which is what identifies the front. On a single
--- MeshPart it is only ever a bounding-box corner - see FRONT_SIGN.
---
--- Relative to the model's centre, NOT to the deck's origin: this runs before
--- the model has been moved onto the deck, so an absolute measurement would be
--- swamped by the distance between the two and the sign would be meaningless.
function TreadmillModel.tallestEndZ(model: Model, frame: CFrame): number
	local min, max = localExtents(model, frame)
	if not min or not max then
		return 0
	end
	local centreZ = (min.Z + max.Z) / 2

	local bestY, bestZ = -math.huge, 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local half = part.Size / 2
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local world = (part.CFrame * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
						if world.Y > bestY then
							bestY = world.Y
							bestZ = frame:PointToObjectSpace(world).Z
						end
					end
				end
			end
		end
	end
	return bestZ - centreZ
end

function TreadmillModel.align(model: Model, deckCentre: Vector3, deckTop: number, rotation: CFrame)
	local tier = TreadmillConfig.tier(model:GetAttribute("TreadmillLevel") or 0)
	local frame = rotation.Rotation + deckCentre

	-- 1. Adopt the deck's facing.
	local pivot = model:GetPivot()
	model:PivotTo(CFrame.new(pivot.Position) * frame.Rotation)

	-- 2. NORMALISE THE LONG AXIS. These models were authored at different yaws -
	--    some have their belt running along their own X, some along Z - so simply
	--    inheriting the deck's rotation leaves two thirds of them sideways across
	--    it. Measure in deck space and turn the ones that are crosswise.
	local min, max = localExtents(model, frame)
	if not min or not max then
		return
	end
	if (max.X - min.X) > (max.Z - min.Z) then
		model:PivotTo(model:GetPivot() * CFrame.Angles(0, math.pi / 2, 0))
		min, max = localExtents(model, frame)
		if not min or not max then
			return
		end
	end

	-- 2b. NORMALISE FRONT-TO-BACK. Matching the long axis still leaves a model
	--     free to sit backwards, and three of the nine did - console at one end,
	--     the other six at the opposite end. A treadmill's tallest feature is its
	--     console / arch / halo, so that end identifies the front, and any model
	--     pointing the wrong way is turned 180 degrees.
	if TreadmillModel.tallestEndZ(model, frame) * TreadmillModel.FRONT_SIGN < 0 then
		model:PivotTo(model:GetPivot() * CFrame.Angles(0, math.pi, 0))
		min, max = localExtents(model, frame)
		if not min or not max then
			return
		end
	end

	-- 3. One translation: centred on the deck, and sitting so the BELT lands on
	--    it. A model whose belt is higher than the standard therefore sinks
	--    slightly, which hides under the floor and always beats it hovering.
	local centre = (min + max) / 2
	local targetBottom = deckTop - (if tier then tier.deckHeight else 0)
	local worldMinY = select(1, TreadmillModel.worldExtents(model))

	model:PivotTo(
		model:GetPivot()
			+ frame:VectorToWorldSpace(Vector3.new(-centre.X, 0, -centre.Z))
			+ Vector3.new(0, targetBottom - (worldMinY :: Vector3).Y, 0)
	)
end

return TreadmillModel
