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

	if source:IsA("Accoutrement") then -- covers both Accessory and the old Hat
		local handle = source:FindFirstChild("Handle", true)
		if handle and handle:IsA("BasePart") then
			local part = handle:Clone()
			-- An accessory Handle carries attachments and welds meant for a
			-- character. On a pedestal they do nothing but can re-parent the part.
			for _, child in part:GetChildren() do
				if child:IsA("Attachment") or child:IsA("JointInstance") or child:IsA("WeldConstraint") then
					child:Destroy()
				end
			end
			part.Parent = model
			model.PrimaryPart = part
			return model
		end
	end

	model:Destroy()
	return nil
end

-- ==========================================================
-- BUILD
-- ==========================================================

export type BuildOptions = {
	itemId: string,
	rarity: string,
	targetHeight: number,
	sizeScale: number?, -- the Big/Huge/Giant roll, applied on top
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

	for _, descendant in built:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CastShadow = false
		end
	end

	-- Only authored art needs normalising; a placeholder is already the size we
	-- asked for.
	local scale = options.sizeScale or 1
	if isReal then
		local height = LootModel.worldHeight(built)
		if height and height > 0.01 then
			scale *= options.targetHeight / height
		end
	end

	if math.abs(scale - 1) > 0.001 then
		-- RELATIVE. ScaleTo is absolute, and cloned assets often carry a scale
		-- of their own already.
		built:ScaleTo(built:GetScale() * scale)
	end

	return built, isReal
end

return LootModel
