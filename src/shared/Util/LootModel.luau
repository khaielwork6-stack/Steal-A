--!strict
--[[
	LootModel
	Turns an authored art asset into a usable loot model. ONE resolver, used by
	both the world loot (LootService) and the base trophies (BaseService).

	WHY THIS EXISTS
	Both of those built their own copy of "find the asset, else make a
	placeholder", and both required the asset to be a `Model`. Imported art is
	very often NOT a Model - a single MeshPart, a Part, a union, or a legacy Hat -
	so a perfectly good import was silently ignored and the player got a coloured
	block. Everything below accepts whatever the artist actually dropped in.

	THE NAMING CONTRACT (unchanged)
	    ServerStorage.GameAssets.Loot.<ItemId>        e.g. Museum_AncientVase
	Drop art in under the item's id and it is picked up with no code change.

	SCALE IS NORMALISED HERE, NOT BY HAND
	Imports arrive at wildly different scales - the crown was 0.5 studs tall and
	the treasure map 14. Rather than asking whoever adds art to resize each one in
	Studio, every asset is scaled to a target height on build. That also fixes a
	real bug: `Model:ScaleTo` is ABSOLUTE, so applying a Big/Huge/Giant roll with
	`ScaleTo(1.35)` to an asset already saved at scale 0.22 made it six times
	larger than intended. Scaling is always relative here.

	THE BOUNDING BOX MUST BE A WORLD AABB
	`Model:GetBoundingBox()` returns a box aligned to the model's PIVOT, so its
	`size.Y` is not world height whenever the pivot is rotated - which is how an
	11-stud import once "shrank" to 20 studs. Height is measured from real part
	corners instead.
]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local LootModel = {}

--- How wide an asset may get relative to its target height. Scaling purely by
--- height turns a flat, wide object (a crown, a shield) into something far wider
--- than the pedestal it sits on, so whichever of the two limits binds first wins.
LootModel.MAX_WIDTH_RATIO = 1.5

-- ==========================================================
-- MEASUREMENT
-- ==========================================================

--- True world-axis-aligned bounding box of everything under `root`.
--- Returns nil when there is nothing to measure.
function LootModel.worldExtents(root: Instance): (Vector3?, Vector3?)
	local min: Vector3? = nil
	local max: Vector3? = nil

	local function consume(part: BasePart)
		local half = part.Size / 2
		-- All eight corners, because a rotated part's world extent is not its
		-- Size on any axis.
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local corner = part.CFrame * CFrame.new(half.X * x, half.Y * y, half.Z * z)
					local p = corner.Position
					min = if min then Vector3.new(math.min(min.X, p.X), math.min(min.Y, p.Y), math.min(min.Z, p.Z)) else p
					max = if max then Vector3.new(math.max(max.X, p.X), math.max(max.Y, p.Y), math.max(max.Z, p.Z)) else p
				end
			end
		end
	end

	if root:IsA("BasePart") then
		consume(root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			consume(descendant)
		end
	end

	if not min or not max then
		return nil, nil
	end
	return min, max
end

--- World height in studs, or nil when the asset has no parts.
function LootModel.worldHeight(root: Instance): number?
	local min, max = LootModel.worldExtents(root)
	if not min or not max then
		return nil
	end
	return max.Y - min.Y
end

-- ==========================================================
-- RESOLUTION
-- ==========================================================

--- The authored asset for an item id, whatever class it is. Recursive, because
--- imports keep their parts inside nested Models (the meteorite lives at
--- `Zone One Meteor > meteor > OldMeteor`) and a non-recursive lookup finds
--- nothing.
function LootModel.findSource(itemId: string): Instance?
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local folder = assets and assets:FindFirstChild("Loot")
	if not folder then
		return nil
	end
	return folder:FindFirstChild(itemId, true)
end

function LootModel.hasArt(itemId: string): boolean
	return LootModel.findSource(itemId) ~= nil
end

--- Wraps whatever the artist provided into a Model we own.
--- Returns nil when the source contains no parts at all.
local function adopt(source: Instance): Model?
	if source:IsA("Model") then
		local model = source:Clone()
		if not model.PrimaryPart then
			model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
		end
		return if model.PrimaryPart then model else nil
	end

	-- A bare Part / MeshPart / union, or a legacy Hat or Accessory (whose art is
	-- the Handle inside it). Either way we end up with one Model we control.
	local model = Instance.new("Model")

	if source:IsA("BasePart") then
		local part = source:Clone()
		part.Parent = model
		model.PrimaryPart = part
		return model
	end

	-- Accoutrement covers Accessory and the old Hat; a Tool is the third thing an
	-- artist hands over that is neither a Model nor a bare part, and it is shaped
	-- the same way - the art is the Handle. Both are unwrapped identically.
	if source:IsA("Accoutrement") or source:IsA("Tool") then
		-- EVERY part comes across, not just the Handle. The zone 6-12 imports
		-- include Tools built from several parts welded to a Handle (the Gym's
		-- barbell, the Bank's briefcases, the Lab's containment tank); keeping
		-- only the Handle left a bar with no plates. The parts are flattened
		-- into our Model and anchored by build(), so the welds that held them
		-- together are not needed and are stripped with the rest.
		local shell = source:Clone()
		for _, descendant in shell:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Parent = model
			end
		end
		shell:Destroy()
		-- A Handle carries attachments, welds and (on a Tool) scripts and grip
		-- data meant for a character. On a pedestal they do nothing but can
		-- re-parent the part or run code we never asked for.
		for _, child in model:GetDescendants() do
			if
				child:IsA("Attachment")
				or child:IsA("JointInstance")
				or child:IsA("WeldConstraint")
				or child:IsA("BaseScript")
			then
				child:Destroy()
			end
		end
		local handle = model:FindFirstChild("Handle") or model:FindFirstChildWhichIsA("BasePart")
		if handle and handle:IsA("BasePart") then
			model.PrimaryPart = handle
			return model
		end
	end

	model:Destroy()
	return nil
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- The widest a piece of world loot may get, in studs. The lane is 256 wide
--- and the sockets sit 72 studs off centre, so this is the largest thing that
--- still fits between a socket and the wall. HEIGHT IS NOT CAPPED: a Colossal
--- is meant to tower over the walls, and this only ever binds on something
--- both huge and flat.
LootModel.WORLD_MAX_FOOTPRINT = 110
--- The widest a trophy may get on its 20-stud display pad: it may be as tall
--- as it likes, but it must not swallow the neighbouring exhibits.
LootModel.TROPHY_MAX_FOOTPRINT = 18

export type BuildOptions = {
	itemId: string,
	rarity: string,
	targetHeight: number,
	--- The item's saved VisualScale (Big 1.35 ... Colossal 15-20), applied on
	--- top of the height normalisation. Exactly once, on this fresh clone.
	sizeScale: number?,
	--- Largest footprint (the wider of X and Z) this context can show. Only
	--- ever shrinks; never a universal cap.
	maxFootprint: number?,
	placeholderSize: Vector3?,
}

--- The one way to get a loot model. Always returns a Model with a PrimaryPart,
--- anchored, non-colliding, and scaled to `targetHeight` times any size roll.
function LootModel.build(options: BuildOptions): (Model, boolean)
	local source = LootModel.findSource(options.itemId)
	local model: Model? = if source then adopt(source) else nil
	local isReal = model ~= nil

	if not model then
		local made = Instance.new("Model")
		local part = Instance.new("Part")
		part.Name = "Placeholder"
		part.Size = options.placeholderSize or Vector3.new(6, 7, 6)
		part.Color = RarityConfig.Colors[options.rarity] or Color3.fromRGB(200, 200, 200)
		part.Material = Enum.Material.SmoothPlastic
		part.Parent = made
		made.PrimaryPart = part
		model = made
	end

	local built = model :: Model
	built.Name = options.itemId
	-- The client animates loot by moving the whole model. With streaming on,
	-- a model that streams in part by part would be pivoted while half here
	-- and torn apart when the rest arrived; atomic models arrive whole.
	built.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	for _, descendant in built:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CastShadow = false
			-- An import's throne is a working Seat; brushing past the pedestal
			-- would sit the player on the loot.
			if descendant:IsA("Seat") or descendant:IsA("VehicleSeat") then
				descendant.Disabled = true
			end
		elseif descendant:IsA("Humanoid") or descendant:IsA("BaseScript") then
			-- A character-shaped import brings a Humanoid (a floating name tag
			-- and a physics driver) and the odd script. Loot is scenery.
			descendant:Destroy()
		end
	end

	-- Only authored art needs normalising; a placeholder is already the size we
	-- asked for.
	local scale = options.sizeScale or 1
	local min, max = LootModel.worldExtents(built)
	if isReal and min and max then
		local size = max - min
		local fit = math.huge

		-- Height is the primary target...
		if size.Y > 0.01 then
			fit = options.targetHeight / size.Y
		end

		-- ...but a flat, wide object must not be blown up sideways to reach it.
		-- The crown is 1.25 wide by 0.51 tall as authored: matching its HEIGHT
		-- to 5 studs made it 12 studs across, wider than the pedestal.
		local widest = math.max(size.X, size.Z)
		if widest > 0.01 then
			fit = math.min(fit, (options.targetHeight * LootModel.MAX_WIDTH_RATIO) / widest)
		end

		if fit < math.huge then
			scale *= fit
		end
	end

	-- The context's footprint limit. Applied to the FINAL scale, size roll
	-- included, and only ever downward: a Colossal barrel is still a tower, a
	-- Colossal carpet is as wide as the lane allows.
	if options.maxFootprint and min and max then
		local widest = math.max(max.X - min.X, max.Z - min.Z) * scale
		if widest > options.maxFootprint and widest > 0.01 then
			scale *= options.maxFootprint / widest
		end
	end

	if math.abs(scale - 1) > 0.001 then
		-- RELATIVE. ScaleTo is absolute, and cloned assets often carry a scale
		-- of their own already.
		built:ScaleTo(built:GetScale() * scale)
	end
	-- What this build applied, so a later in-place adjustment (growth) can be
	-- expressed relative to it instead of compounding on an unknown base.
	built:SetAttribute("BuiltScale", built:GetScale())

	-- Hold the pieces together. A multi-part import (a throne, a barbell, the
	-- four-part plasma) is only ever anchored on a pedestal, but a CARRY
	-- unanchors it and welds the PrimaryPart alone to the player - so anything
	-- not welded to that part was left behind or fell through the floor.
	local primary = built.PrimaryPart
	if primary then
		for _, descendant in built:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= primary then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "LootWeld"
				weld.Part0 = primary
				weld.Part1 = descendant
				weld.Parent = primary
			end
		end
	end

	return built, isReal
end

-- ==========================================================
-- PREVIEWS (the Index and Storage thumbnails)
-- ==========================================================
--
-- The art lives in ServerStorage, which no client can read, so the server
-- publishes a sanitised copy of every item under ReplicatedStorage.LootPreviews
-- once at start. A client card then clones its item into a ViewportFrame and
-- draws the REAL model - the same mesh the player steals - instead of a colour
-- swatch. Scripts, sounds, prompts and humanoids are stripped; nothing in the
-- folder can run or make noise.

local PREVIEW_FOLDER = "LootPreviews"

--- Server only. Idempotent: a second call replaces the folder.
function LootModel.publishPreviews(): number
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local source = assets and assets:FindFirstChild("Loot")
	if not source then
		return 0
	end
	local existing = ReplicatedStorage:FindFirstChild(PREVIEW_FOLDER)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = PREVIEW_FOLDER

	local count = 0
	for _, item in source:GetChildren() do
		local model = adopt(item)
		if not model then
			continue
		end
		model.Name = item.Name
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
			elseif
				descendant:IsA("BaseScript")
				or descendant:IsA("Sound")
				or descendant:IsA("ProximityPrompt")
				or descendant:IsA("Humanoid")
				or descendant:IsA("BillboardGui")
				or descendant:IsA("SurfaceGui")
			then
				descendant:Destroy()
			end
		end
		model.Parent = folder
		count += 1
	end
	folder.Parent = ReplicatedStorage
	return count
end

--- The published preview for an item, or nil (no art, or not published yet).
function LootModel.previewSource(itemId: string): Model?
	local folder = ReplicatedStorage:FindFirstChild(PREVIEW_FOLDER)
	local found = folder and folder:FindFirstChild(itemId)
	return if found and found:IsA("Model") then found else nil
end

return LootModel
