--!strict
--[[
	MapLandmarks
	One big recognisable silhouette per zone, plus a handful of supporting props.

	Rules this file follows, taken from the reference presentation:
	  * BIG SHAPES over lots of small detail. A zone gets ~5-8 objects, not 50.
	  * Landmarks hug the side walls and alternate left/right so the centre
	    sightline down the world is never blocked.
	  * Silhouettes are tall enough to peek over the walls from several zones
	    back, which is what pulls the player forward.
	  * Primitives only - no realistic geometry, no clutter.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local MapLandmarks = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- ==========================================================
-- PRIMITIVES
-- ==========================================================

type Ctx = {
	parent: Instance,
	origin: Vector3, -- zone centre on the floor plane
	frame: CFrame, -- placement frame; offsets below are relative to this
}

--- Derives a rotated sub-frame so a landmark can face across the lane instead of
-- down it. `yaw` is degrees; -90 faces world +X (used by left-side landmarks).
local function facing(ctx: Ctx, offset: Vector3, yaw: number): Ctx
	return {
		parent = ctx.parent,
		origin = ctx.origin,
		frame = ctx.frame * CFrame.new(offset) * CFrame.Angles(0, math.rad(yaw), 0),
	}
end

local function shape(
	ctx: Ctx,
	name: string,
	shapeType: Enum.PartType?,
	size: Vector3,
	offset: Vector3,
	color: Color3,
	material: Enum.Material?,
	rotation: CFrame?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Anchored = true
	p.CanCollide = true
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shapeType then
		p.Shape = shapeType
	end
	p.CFrame = ctx.frame * CFrame.new(offset) * (rotation or CFrame.identity)
	p.Parent = ctx.parent
	return p
end

local function box(ctx: Ctx, name: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material?, rot: CFrame?): Part
	return shape(ctx, name, Enum.PartType.Block, size, offset, color, material, rot)
end

local function cyl(ctx: Ctx, name: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material?, rot: CFrame?): Part
	return shape(ctx, name, Enum.PartType.Cylinder, size, offset, color, material, rot)
end

local function ball(ctx: Ctx, name: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material?): Part
	return shape(ctx, name, Enum.PartType.Ball, size, offset, color, material)
end

--- Upright cylinder (Roblox cylinders are built along X, so rotate them).
local function pillar(ctx: Ctx, name: string, diameter: number, height: number, offset: Vector3, color: Color3, material: Enum.Material?): Part
	return cyl(ctx, name, Vector3.new(height, diameter, diameter), offset, color, material, CFrame.Angles(0, 0, math.rad(90)))
end

local function wedge(ctx: Ctx, name: string, size: Vector3, offset: Vector3, color: Color3, rot: CFrame?): WedgePart
	local p = Instance.new("WedgePart")
	p.Name = name
	p.Size = size
	p.Anchored = true
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.CFrame = ctx.frame * CFrame.new(offset) * (rot or CFrame.identity)
	p.Parent = ctx.parent
	return p
end

--- Stepped pyramid / ziggurat, built from shrinking boxes.
local function stepped(ctx: Ctx, name: string, baseWidth: number, steps: number, stepHeight: number, offset: Vector3, color: Color3)
	for i = 0, steps - 1 do
		local w = baseWidth * (1 - i / steps)
		box(
			ctx,
			name .. "_" .. i,
			Vector3.new(w, stepHeight, w),
			offset + Vector3.new(0, stepHeight * (i + 0.5), 0),
			color,
			Enum.Material.Plastic
		)
	end
end

--- Colonnaded facade. The colonnade faces local -Z, which is the side the player
-- approaches from, so callers place these with `facing()` when they sit off-lane.
-- The pediment is a stepped triangle rather than a wedge: it reads as a gable from
-- every angle and keeps the chunky Roblox silhouette.
local function facade(ctx: Ctx, offset: Vector3, width: number, height: number, columns: number, stone: Color3, accent: Color3)
	local depth = 30
	box(ctx, "Podium", Vector3.new(width + 12, 6, depth + 10), offset + Vector3.new(0, 3, 0), stone, Enum.Material.Plastic)
	box(ctx, "Wall", Vector3.new(width, height, depth * 0.5), offset + Vector3.new(0, 6 + height / 2, depth * 0.25), stone)
	box(ctx, "Doorway", Vector3.new(width * 0.22, height * 0.6, 3), offset + Vector3.new(0, 6 + height * 0.3, depth * 0.02), accent)

	for i = 1, columns do
		local x = -width / 2 + width * (i - 0.5) / columns
		pillar(ctx, "Column" .. i, 9, height, offset + Vector3.new(x, 6 + height / 2, -depth * 0.32), stone)
	end

	box(ctx, "Entablature", Vector3.new(width + 8, 9, depth + 4), offset + Vector3.new(0, 6 + height + 4.5, 0), accent)

	local steps = 4
	for i = 0, steps - 1 do
		box(
			ctx,
			"Gable" .. i,
			Vector3.new(width * (1 - i / steps) + 6, 6, depth + 4),
			offset + Vector3.new(0, 6 + height + 12 + i * 6, 0),
			accent,
			Enum.Material.Plastic
		)
	end
end

-- ==========================================================
-- PER-ZONE LANDMARKS
-- ==========================================================

local STONE = rgb(238, 232, 214)
local GOLD = rgb(255, 198, 62)
local WOOD = rgb(146, 96, 54)
local DARK = rgb(58, 64, 82)

local builders: { (Ctx) -> () } = {

	-- 01 MUSEUM -- neoclassical facade against the left wall, facing the lane
	function(ctx)
		local m = facing(ctx, Vector3.new(-108, 0, 20), -90)
		facade(m, Vector3.new(0, 0, 0), 104, 44, 6, STONE, rgb(214, 205, 182))
		for _, sign in { -1, 1 } do
			box(m, "Plinth", Vector3.new(14, 14, 14), Vector3.new(sign * 66, 7, -34), STONE, Enum.Material.Plastic)
			ball(m, "Urn", Vector3.new(13, 13, 13), Vector3.new(sign * 66, 20, -34), rgb(120, 190, 220))
		end
		box(m, "Hedge", Vector3.new(78, 8, 6), Vector3.new(0, 4, -40), rgb(74, 170, 62), Enum.Material.Grass)
	end,

	-- 02 PIRATE ISLAND -- galleon, palms, treasure
	function(ctx)
		local hull = Vector3.new(-96, 0, 40)
		box(ctx, "Hull", Vector3.new(46, 26, 116), hull + Vector3.new(0, 13, 0), WOOD, Enum.Material.Wood)
		box(ctx, "Deck", Vector3.new(50, 4, 120), hull + Vector3.new(0, 27, 0), rgb(178, 132, 82), Enum.Material.Wood)
		box(ctx, "SternCastle", Vector3.new(42, 22, 30), hull + Vector3.new(0, 40, -42), WOOD, Enum.Material.Wood)
		pillar(ctx, "MainMast", 5, 92, hull + Vector3.new(0, 74, 6), rgb(120, 80, 46))
		box(ctx, "MainSail", Vector3.new(44, 46, 2), hull + Vector3.new(0, 82, 6), rgb(246, 244, 236))
		box(ctx, "TopSail", Vector3.new(30, 26, 2), hull + Vector3.new(0, 116, 6), rgb(246, 244, 236))

		for i, spot in { Vector3.new(112, 0, -60), Vector3.new(126, 0, 74) } do
			pillar(ctx, "PalmTrunk" .. i, 5, 46, spot + Vector3.new(0, 23, 0), rgb(154, 110, 64))
			for f = 0, 4 do
				box(
					ctx,
					"Frond" .. i .. "_" .. f,
					Vector3.new(30, 2, 9),
					spot + Vector3.new(0, 46, 0),
					rgb(70, 190, 84),
					Enum.Material.Plastic,
					CFrame.Angles(0, math.rad(f * 72), math.rad(-14)) * CFrame.new(14, 0, 0)
				)
			end
		end

		box(ctx, "Chest", Vector3.new(18, 12, 12), Vector3.new(86, 6, -8), WOOD, Enum.Material.Wood)
		box(ctx, "ChestLid", Vector3.new(18, 5, 12), Vector3.new(86, 14, -8), GOLD)
	end,

	-- 03 CASTLE -- twin towers and curtain wall
	function(ctx)
		local stone = rgb(196, 198, 206)
		box(ctx, "CurtainWall", Vector3.new(24, 46, 150), Vector3.new(-116, 23, 20), stone, Enum.Material.Plastic)
		for i = 0, 8 do
			box(ctx, "Merlon" .. i, Vector3.new(24, 8, 10), Vector3.new(-116, 50, -50 + i * 17), stone)
		end

		for i, z in { -46, 66 } do
			pillar(ctx, "Tower" .. i, 46, 92, Vector3.new(-116, 46, z), stone)
			pillar(ctx, "TowerCrown" .. i, 54, 8, Vector3.new(-116, 94, z), stone)
			shape(
				ctx,
				"TowerRoof" .. i,
				Enum.PartType.Ball,
				Vector3.new(50, 56, 50),
				Vector3.new(-116, 118, z),
				rgb(196, 62, 82)
			)
			box(ctx, "Banner" .. i, Vector3.new(2, 22, 14), Vector3.new(-92, 60, z), rgb(224, 62, 92))
		end
	end,

	-- 04 AREA 51 -- hangar, saucer, dish
	function(ctx)
		local metal = rgb(198, 204, 212)
		cyl(
			ctx,
			"Hangar",
			Vector3.new(120, 68, 68),
			Vector3.new(110, 22, 30),
			metal,
			Enum.Material.Metal,
			CFrame.Angles(0, math.rad(90), 0)
		)
		box(ctx, "HangarDoor", Vector3.new(60, 34, 3), Vector3.new(110, 17, -4), rgb(150, 158, 170), Enum.Material.Metal)

		cyl(ctx, "Saucer", Vector3.new(7, 76, 76), Vector3.new(-96, 62, 46), metal, Enum.Material.Metal, CFrame.Angles(0, 0, math.rad(90)))
		ball(ctx, "SaucerDome", Vector3.new(38, 38, 38), Vector3.new(-96, 70, 46), rgb(96, 232, 255), Enum.Material.Neon)
		pillar(ctx, "SaucerBeam", 30, 60, Vector3.new(-96, 31, 46), rgb(120, 240, 255), Enum.Material.ForceField)

		pillar(ctx, "DishMast", 5, 56, Vector3.new(-118, 28, -60), metal)
		cyl(ctx, "Dish", Vector3.new(4, 40, 40), Vector3.new(-118, 58, -60), metal, Enum.Material.Metal, CFrame.Angles(math.rad(35), 0, math.rad(90)))
		box(ctx, "Fence", Vector3.new(2, 12, 120), Vector3.new(-140, 6, 0), rgb(120, 128, 138), Enum.Material.Metal)
	end,

	-- 05 NORTH POLE -- giant tree, gifts, ice arch
	function(ctx)
		local tree = Vector3.new(-102, 0, 34)
		pillar(ctx, "Trunk", 12, 24, tree + Vector3.new(0, 12, 0), rgb(112, 72, 44))
		for i = 0, 3 do
			local w = 74 - i * 16
			shape(
				ctx,
				"Tier" .. i,
				Enum.PartType.Ball,
				Vector3.new(w, 34, w),
				tree + Vector3.new(0, 30 + i * 20, 0),
				rgb(36, 150, 76)
			)
		end
		ball(ctx, "Star", Vector3.new(14, 14, 14), tree + Vector3.new(0, 106, 0), rgb(255, 226, 96), Enum.Material.Neon)

		for i, spec in {
			{ p = Vector3.new(-62, 0, -18), c = rgb(226, 62, 78) },
			{ p = Vector3.new(-44, 0, 62), c = rgb(72, 128, 236) },
			{ p = Vector3.new(-84, 0, 86), c = rgb(255, 196, 62) },
		} do
			box(ctx, "Gift" .. i, Vector3.new(22, 22, 22), spec.p + Vector3.new(0, 11, 0), spec.c, Enum.Material.Plastic)
			box(ctx, "Ribbon" .. i, Vector3.new(23, 23, 4), spec.p + Vector3.new(0, 11, 0), rgb(250, 250, 250))
		end

		for _, sign in { -1, 1 } do
			pillar(ctx, "ArchLeg", 12, 54, Vector3.new(112, 27, sign * 40), rgb(180, 236, 255), Enum.Material.Ice)
		end
		box(ctx, "ArchTop", Vector3.new(16, 10, 92), Vector3.new(112, 58, 0), rgb(180, 236, 255), Enum.Material.Ice)
	end,

	-- 06 ANCIENT EGYPT -- pyramid, obelisk, sphinx block
	function(ctx)
		stepped(ctx, "Pyramid", 130, 9, 9, Vector3.new(104, 0, 24), rgb(232, 200, 140))
		box(ctx, "Capstone", Vector3.new(14, 12, 14), Vector3.new(104, 85, 24), GOLD)

		box(ctx, "ObeliskBase", Vector3.new(20, 6, 20), Vector3.new(-108, 3, -46), rgb(226, 196, 138))
		box(ctx, "Obelisk", Vector3.new(12, 64, 12), Vector3.new(-108, 38, -46), rgb(232, 204, 146), Enum.Material.Plastic)
		box(ctx, "ObeliskTip", Vector3.new(9, 10, 9), Vector3.new(-108, 75, -46), GOLD)

		box(ctx, "SphinxBody", Vector3.new(30, 20, 62), Vector3.new(-112, 10, 60), rgb(228, 198, 142))
		box(ctx, "SphinxHead", Vector3.new(24, 24, 22), Vector3.new(-112, 32, 84), rgb(232, 204, 150))
		box(ctx, "SphinxHeaddress", Vector3.new(30, 8, 26), Vector3.new(-112, 45, 82), rgb(72, 128, 208))

		for i, p in { Vector3.new(-40, 0, -70), Vector3.new(36, 0, 78) } do
			box(ctx, "CactusTrunk" .. i, Vector3.new(7, 26, 7), p + Vector3.new(0, 13, 0), rgb(76, 172, 88), Enum.Material.Plastic)
			box(ctx, "CactusArm" .. i, Vector3.new(16, 6, 6), p + Vector3.new(4, 20, 0), rgb(76, 172, 88))
		end
	end,

	-- 07 GYM -- colossal dumbbell and plate stack
	function(ctx)
		local d = Vector3.new(-98, 0, 30)
		pillar(ctx, "Bar", 12, 132, d + Vector3.new(0, 40, 0), rgb(206, 212, 222), Enum.Material.Metal, nil)
		for _, sign in { -1, 1 } do
			cyl(
				ctx,
				"Weight",
				Vector3.new(26, 66, 66),
				d + Vector3.new(0, 40, sign * 58),
				rgb(44, 48, 62),
				Enum.Material.Metal,
				CFrame.Angles(math.rad(90), 0, 0)
			)
		end

		for i = 0, 3 do
			cyl(
				ctx,
				"Plate" .. i,
				Vector3.new(10, 60 - i * 10, 60 - i * 10),
				Vector3.new(110, 6 + i * 11, -20),
				rgb(226, 74, 74),
				Enum.Material.Plastic,
				CFrame.Angles(0, 0, math.rad(90))
			)
		end

		box(ctx, "Bench", Vector3.new(24, 5, 58), Vector3.new(104, 16, 66), rgb(226, 62, 88))
		for _, sign in { -1, 1 } do
			box(ctx, "BenchLeg", Vector3.new(20, 14, 6), Vector3.new(104, 7, 66 + sign * 22), rgb(60, 64, 78), Enum.Material.Metal)
		end
	end,

	-- 08 BANK -- facade and exposed vault door
	function(ctx)
		facade(facing(ctx, Vector3.new(-108, 0, 30), -90), Vector3.new(0, 0, 0), 92, 40, 5, rgb(224, 222, 212), GOLD)
		pillar(ctx, "VaultFrame", 62, 12, Vector3.new(102, 31, 26), rgb(150, 156, 168), Enum.Material.Metal)
		cyl(ctx, "VaultDoor", Vector3.new(10, 52, 52), Vector3.new(102, 31, 34), rgb(198, 204, 214), Enum.Material.Metal, CFrame.Angles(0, 0, math.rad(90)))
		ball(ctx, "VaultWheel", Vector3.new(20, 20, 20), Vector3.new(102, 31, 40), GOLD, Enum.Material.Metal)
		box(ctx, "VaultBlock", Vector3.new(76, 62, 40), Vector3.new(102, 31, 4), rgb(210, 212, 220), Enum.Material.Plastic)

		for i, p in { Vector3.new(52, 0, 84), Vector3.new(-30, 0, 90) } do
			box(ctx, "Ingot" .. i, Vector3.new(20, 9, 12), p + Vector3.new(0, 4.5, 0), GOLD, Enum.Material.Metal)
		end
	end,

	-- 09 SECRET LAB -- reactor core and containment rings
	function(ctx)
		local core = Vector3.new(100, 0, 34)
		pillar(ctx, "ReactorBase", 82, 12, core + Vector3.new(0, 6, 0), rgb(150, 156, 172), Enum.Material.Metal)
		pillar(ctx, "ReactorColumn", 40, 78, core + Vector3.new(0, 50, 0), rgb(186, 192, 206), Enum.Material.Metal)
		ball(ctx, "Core", Vector3.new(48, 48, 48), core + Vector3.new(0, 92, 0), rgb(150, 96, 255), Enum.Material.Neon)
		for i = 0, 2 do
			cyl(
				ctx,
				"Ring" .. i,
				Vector3.new(4, 66 - i * 8, 66 - i * 8),
				core + Vector3.new(0, 36 + i * 24, 0),
				rgb(96, 240, 255),
				Enum.Material.Neon,
				CFrame.Angles(0, 0, math.rad(90))
			)
		end

		box(ctx, "LabBlock", Vector3.new(34, 40, 96), Vector3.new(-114, 20, 26), rgb(228, 232, 240), Enum.Material.Plastic)
		for i = 0, 3 do
			box(ctx, "LabWindow" .. i, Vector3.new(2, 12, 16), Vector3.new(-96, 26, -8 + i * 22), rgb(120, 236, 255), Enum.Material.Neon)
		end
		for i, p in { Vector3.new(-60, 0, -66), Vector3.new(-40, 0, 88) } do
			pillar(ctx, "Tank" .. i, 22, 34, p + Vector3.new(0, 17, 0), rgb(120, 236, 200), Enum.Material.Glass)
		end
	end,

	-- 10 GRANDMA'S HOUSE -- oversized cosy house
	function(ctx)
		local h = Vector3.new(-96, 0, 34)
		box(ctx, "House", Vector3.new(96, 46, 84), h + Vector3.new(0, 23, 0), rgb(248, 232, 206), Enum.Material.Plastic)
		for i = 0, 4 do
			box(
				ctx,
				"Roof" .. i,
				Vector3.new(102 - i * 20, 8, 90 - i * 4),
				h + Vector3.new(0, 50 + i * 8, 0),
				rgb(196, 84, 76),
				Enum.Material.Plastic
			)
		end
		box(ctx, "Chimney", Vector3.new(14, 34, 14), h + Vector3.new(30, 74, -22), rgb(180, 106, 88))
		box(ctx, "Door", Vector3.new(18, 30, 3), h + Vector3.new(0, 15, 43), rgb(150, 92, 58), Enum.Material.Wood)
		for _, sign in { -1, 1 } do
			box(ctx, "Window", Vector3.new(18, 18, 3), h + Vector3.new(sign * 32, 28, 43), rgb(140, 208, 240), Enum.Material.Glass)
		end

		box(ctx, "PicketFence", Vector3.new(112, 10, 2), Vector3.new(-96, 5, 88), rgb(250, 250, 246))
		for i, p in { Vector3.new(74, 0, 12), Vector3.new(98, 0, 70) } do
			pillar(ctx, "FlowerPot" .. i, 18, 12, p + Vector3.new(0, 6, 0), rgb(206, 112, 84))
			ball(ctx, "Blooms" .. i, Vector3.new(24, 18, 24), p + Vector3.new(0, 17, 0), rgb(236, 118, 176))
		end
	end,

	-- 11 CONSTRUCTION SITE -- tower crane
	function(ctx)
		local c = Vector3.new(104, 0, 20)
		local yellow = rgb(252, 196, 44)
		box(ctx, "CranePad", Vector3.new(34, 4, 34), c + Vector3.new(0, 2, 0), rgb(178, 178, 182), Enum.Material.Concrete)
		for i = 0, 5 do
			box(ctx, "Mast" .. i, Vector3.new(16, 16, 16), c + Vector3.new(0, 12 + i * 16, 0), yellow, Enum.Material.Metal)
		end
		box(ctx, "Jib", Vector3.new(9, 9, 130), c + Vector3.new(0, 110, 40), yellow, Enum.Material.Metal)
		box(ctx, "Counterweight", Vector3.new(14, 16, 22), c + Vector3.new(0, 110, -34), rgb(90, 94, 104), Enum.Material.Metal)
		box(ctx, "Cable", Vector3.new(1.5, 46, 1.5), c + Vector3.new(0, 84, 78), rgb(56, 58, 66))
		box(ctx, "Hook", Vector3.new(8, 8, 8), c + Vector3.new(0, 60, 78), rgb(70, 74, 84), Enum.Material.Metal)

		box(ctx, "Scaffold", Vector3.new(46, 44, 46), Vector3.new(-108, 22, 54), rgb(200, 200, 204), Enum.Material.Concrete)
		for i, p in { Vector3.new(-100, 0, -50), Vector3.new(-50, 0, -76) } do
			shape(ctx, "Cone" .. i, Enum.PartType.Ball, Vector3.new(10, 16, 10), p + Vector3.new(0, 8, 0), rgb(250, 118, 40))
			box(ctx, "ConeBase" .. i, Vector3.new(14, 2, 14), p + Vector3.new(0, 1, 0), rgb(250, 118, 40))
		end
		box(ctx, "PipeStack", Vector3.new(40, 10, 26), Vector3.new(-60, 5, 74), rgb(150, 152, 158), Enum.Material.Metal)
	end,

	-- 12 AIRPORT -- control tower and parked jet
	function(ctx)
		local t = Vector3.new(-104, 0, 44)
		pillar(ctx, "TowerShaft", 30, 92, t + Vector3.new(0, 46, 0), rgb(226, 228, 234), Enum.Material.Concrete)
		pillar(ctx, "TowerCollar", 52, 10, t + Vector3.new(0, 94, 0), rgb(198, 202, 210), Enum.Material.Metal)
		pillar(ctx, "TowerCab", 48, 20, t + Vector3.new(0, 106, 0), rgb(120, 220, 255), Enum.Material.Glass)
		pillar(ctx, "TowerRoof", 54, 6, t + Vector3.new(0, 119, 0), rgb(198, 202, 210), Enum.Material.Metal)
		box(ctx, "Antenna", Vector3.new(1.5, 26, 1.5), t + Vector3.new(0, 135, 0), rgb(220, 70, 70))

		local jet = Vector3.new(92, 0, 34)
		cyl(ctx, "Fuselage", Vector3.new(120, 26, 26), jet + Vector3.new(0, 18, 0), rgb(246, 246, 250), Enum.Material.Metal, CFrame.Angles(0, math.rad(90), 0))
		box(ctx, "Wings", Vector3.new(112, 4, 30), jet + Vector3.new(0, 16, -4), rgb(228, 230, 238), Enum.Material.Metal)
		box(ctx, "TailFin", Vector3.new(3, 34, 26), jet + Vector3.new(0, 38, -48), rgb(64, 132, 236))
		box(ctx, "Stabiliser", Vector3.new(46, 3, 16), jet + Vector3.new(0, 24, -52), rgb(228, 230, 238), Enum.Material.Metal)
		for _, sign in { -1, 1 } do
			cyl(ctx, "Engine", Vector3.new(26, 16, 16), jet + Vector3.new(sign * 34, 10, 2), rgb(90, 96, 108), Enum.Material.Metal, CFrame.Angles(0, math.rad(90), 0))
		end
		box(ctx, "RunwayStripe", Vector3.new(18, 0.3, 150), Vector3.new(0, 0.2, 0), rgb(250, 250, 250))
	end,
}

-- ==========================================================
-- ENTRY POINT
-- ==========================================================

function MapLandmarks.build(map: Instance)
	local zones = map:FindFirstChild("Zones")
	assert(zones, "MapLandmarks.build: Workspace.Map.Zones is missing - run MapBuilder.build() first")

	local total = 0

	for i, def in MapConfig.ZONES do
		local zone = zones:FindFirstChild(def.id)
		if not zone then
			continue
		end

		local existing = zone:FindFirstChild("Decorations")
		if existing then
			existing:Destroy()
		end

		local decorations = Instance.new("Folder")
		decorations.Name = "Decorations"
		decorations.Parent = zone

		local origin = Vector3.new(0, 0, MapConfig.zoneCenterZ(i))
		local ctx: Ctx = {
			parent = decorations,
			origin = origin,
			frame = CFrame.new(origin),
		}

		builders[i](ctx)

		-- Landmarks are scenery: never let them cast expensive shadows or block
		-- the loot sockets they sit beside.
		for _, d in decorations:GetDescendants() do
			if d:IsA("BasePart") then
				d.CastShadow = false
				total += 1
			end
		end
	end

	print(string.format("[MapLandmarks] %d decoration parts across %d zones", total, MapConfig.ZONE_COUNT))
end

return MapLandmarks
