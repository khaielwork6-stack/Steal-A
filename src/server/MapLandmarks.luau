--!strict
--[[
	MapLandmarks
	One big recognisable silhouette per zone, plus a handful of supporting props.

	Rules this file follows, taken from the reference presentation:
	  * BIG SHAPES over lots of small detail. A zone gets one landmark, a
	    handful of supporting props (`dressing`), and nothing else.
	  * THE LAYOUT IS COMPOSED HERE TOO. `MapLandmarks.layouts` gives every
	    zone the spots for its four loot plinths and its guardian post, chosen
	    against that zone's own landmark. MapBuilder.placeSockets reads them
	    and still nudges any spot that lands inside scenery. Offsets are in the
	    authored 320-wide lane space like every other number here: X across
	    the lane, Z along it, relative to the zone's centre.
	  * Landmarks hug the side walls and alternate left/right so the centre
	    sightline down the world is never blocked.
	  * Silhouettes are tall enough to peek over the walls from several zones
	    back, which is what pulls the player forward.
	  * Primitives only - no realistic geometry, no clutter.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local MapLandmarks = {}

-- Every size and offset below was authored against the original 320-wide lane.
-- Applying the config's scale at the leaf keeps silhouettes proportional and
-- inside the walls whenever the lane is resized, without retuning 400 numbers.
local S = MapConfig.LANDMARK_SCALE

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
		frame = ctx.frame * CFrame.new(offset * S) * CFrame.Angles(0, math.rad(yaw), 0),
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
	p.Size = size * S
	p.Anchored = true
	p.CanCollide = true
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shapeType then
		p.Shape = shapeType
	end
	p.CFrame = ctx.frame * CFrame.new(offset * S) * (rotation or CFrame.identity)
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
-- SUPPORTING PROPS
-- ==========================================================
--
-- Small, cheap, reused. Each is two or three parts at most; a cluster of them
-- beside a landmark or a plinth is what makes a zone read as inhabited.

local CRATE = rgb(176, 130, 78)
local CRATE_DARK = rgb(132, 94, 54)
local BARREL = rgb(120, 82, 48)
local ROCK = rgb(150, 150, 156)
local BUSH = rgb(88, 176, 92)
local CONE = rgb(250, 118, 40)
local IRON = rgb(70, 74, 84)

local function crate(ctx: Ctx, offset: Vector3, size: number?, yaw: number?)
	local s = size or 10
	local rot = CFrame.Angles(0, math.rad(yaw or 0), 0)
	box(ctx, "Crate", Vector3.new(s, s, s), offset + Vector3.new(0, s / 2, 0), CRATE, Enum.Material.WoodPlanks, rot)
	box(ctx, "CrateBand", Vector3.new(s + 0.6, s * 0.16, s + 0.6), offset + Vector3.new(0, s / 2, 0), CRATE_DARK, Enum.Material.Wood, rot)
end

local function barrel(ctx: Ctx, offset: Vector3)
	pillar(ctx, "Barrel", 9, 12, offset + Vector3.new(0, 6, 0), BARREL, Enum.Material.Wood)
	pillar(ctx, "BarrelHoop", 9.6, 1.4, offset + Vector3.new(0, 3, 0), IRON, Enum.Material.Metal)
	pillar(ctx, "BarrelHoop", 9.6, 1.4, offset + Vector3.new(0, 9, 0), IRON, Enum.Material.Metal)
end

local function rock(ctx: Ctx, offset: Vector3, size: number, color: Color3?)
	ball(ctx, "Rock", Vector3.new(size, size * 0.62, size * 0.86), offset + Vector3.new(0, size * 0.28, 0), color or ROCK, Enum.Material.Slate)
end

local function bush(ctx: Ctx, offset: Vector3, size: number, color: Color3?)
	ball(ctx, "Bush", Vector3.new(size, size * 0.8, size), offset + Vector3.new(0, size * 0.36, 0), color or BUSH, Enum.Material.Grass)
end

local function cone(ctx: Ctx, offset: Vector3)
	shape(ctx, "Cone", Enum.PartType.Ball, Vector3.new(7, 12, 7), offset + Vector3.new(0, 6, 0), CONE)
	box(ctx, "ConeBase", Vector3.new(10, 1.6, 10), offset + Vector3.new(0, 0.8, 0), CONE)
end

--- A park bench facing local -Z.
local function bench(ctx: Ctx, offset: Vector3, color: Color3)
	box(ctx, "Bench", Vector3.new(16, 2, 5), offset + Vector3.new(0, 4, 0), color, Enum.Material.WoodPlanks)
	box(ctx, "BenchBack", Vector3.new(16, 5, 1.2), offset + Vector3.new(0, 7, 2.4), color, Enum.Material.WoodPlanks)
	for _, sx in { -1, 1 } do
		box(ctx, "BenchLeg", Vector3.new(1.6, 3, 4.6), offset + Vector3.new(sx * 6.6, 1.5, 0), IRON, Enum.Material.Metal)
	end
end

--- A market stall: four posts, a counter and a pitched canopy. Faces local -Z;
--- `yaw` turns it. Offsets inside are authored-space like everything else.
local function stall(ctx: Ctx, offset: Vector3, canopy: Color3, yaw: number)
	local m = facing(ctx, offset, yaw)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			box(m, "StallPost", Vector3.new(1.6, 14, 1.6), Vector3.new(sx * 11, 7, sz * 7), rgb(120, 84, 50), Enum.Material.Wood)
		end
	end
	box(m, "StallCounter", Vector3.new(24, 4, 6), Vector3.new(0, 2, -6), rgb(146, 96, 54), Enum.Material.WoodPlanks)
	box(m, "StallCanopy", Vector3.new(28, 1.6, 20), Vector3.new(0, 15, 0), canopy, Enum.Material.Plastic, CFrame.Angles(math.rad(-8), 0, 0))
	box(m, "StallCanopyTrim", Vector3.new(28.4, 2.4, 1.2), Vector3.new(0, 13.4, -10), rgb(250, 250, 246))
end

--- A low striped barrier, the construction kind.
local function barrier(ctx: Ctx, offset: Vector3, yaw: number)
	local rot = CFrame.Angles(0, math.rad(yaw), 0)
	box(ctx, "BarrierBar", Vector3.new(22, 3, 1.6), offset + Vector3.new(0, 6, 0), rgb(252, 196, 44), Enum.Material.Plastic, rot)
	box(ctx, "BarrierStripe", Vector3.new(7, 3.2, 1.8), offset + Vector3.new(0, 6, 0), rgb(40, 42, 52), Enum.Material.Plastic, rot)
	for _, sx in { -1, 1 } do
		local leg = rot:VectorToWorldSpace(Vector3.new(sx * 9.5, 0, 0))
		box(ctx, "BarrierLeg", Vector3.new(1.6, 8, 4), offset + leg + Vector3.new(0, 4, 0), rgb(60, 64, 78), Enum.Material.Metal, rot)
	end
end

-- ==========================================================
-- PER-ZONE DRESSING (supporting clusters)
-- ==========================================================

local dressing: { (Ctx) -> () } = {
	-- 01 MUSEUM: garden benches and hedges on the lawn before the steps.
	function(ctx)
		bench(ctx, Vector3.new(-30, 0, -70), rgb(150, 100, 58))
		bench(ctx, Vector3.new(-30, 0, 90), rgb(150, 100, 58))
		bush(ctx, Vector3.new(96, 0, -70), 14)
		bush(ctx, Vector3.new(110, 0, -56), 10)
		bush(ctx, Vector3.new(100, 0, 90), 12, rgb(118, 200, 104))
	end,
	-- 02 PIRATE: cargo on the beach by the chest and the bow.
	function(ctx)
		crate(ctx, Vector3.new(96, 0, 14), 11, 20)
		crate(ctx, Vector3.new(108, 0, 4), 8, -15)
		barrel(ctx, Vector3.new(86, 0, 26))
		barrel(ctx, Vector3.new(-48, 0, -84))
		crate(ctx, Vector3.new(-36, 0, -96), 9, 35)
		rock(ctx, Vector3.new(30, 0, 96), 22, rgb(190, 176, 150))
		rock(ctx, Vector3.new(-14, 0, -100), 14, rgb(190, 176, 150))
	end,
	-- 03 CASTLE: a market stall and barrels under the curtain wall.
	function(ctx)
		stall(ctx, Vector3.new(72, 0, 84), rgb(224, 62, 92), 180)
		barrel(ctx, Vector3.new(-80, 0, 8))
		barrel(ctx, Vector3.new(-72, 0, 20))
		crate(ctx, Vector3.new(90, 0, -84), 10, 10)
		bush(ctx, Vector3.new(-70, 0, -90), 12)
	end,
	-- 04 AREA 51: crates and cones by the hangar door, rocks in the scrub.
	function(ctx)
		crate(ctx, Vector3.new(50, 0, -40), 10, 0)
		crate(ctx, Vector3.new(62, 0, -30), 8, 30)
		cone(ctx, Vector3.new(40, 0, -60))
		cone(ctx, Vector3.new(76, 0, -62))
		rock(ctx, Vector3.new(-40, 0, 100), 20)
		rock(ctx, Vector3.new(-20, 0, -96), 14)
		rock(ctx, Vector3.new(30, 0, 100), 12)
	end,
	-- 05 NORTH POLE: a snowman and candy poles by the arch.
	function(ctx)
		local s = Vector3.new(-20, 0, -80)
		ball(ctx, "SnowBase", Vector3.new(16, 16, 16), s + Vector3.new(0, 7, 0), rgb(250, 252, 255))
		ball(ctx, "SnowMid", Vector3.new(12, 12, 12), s + Vector3.new(0, 18, 0), rgb(250, 252, 255))
		ball(ctx, "SnowHead", Vector3.new(9, 9, 9), s + Vector3.new(0, 26, 0), rgb(250, 252, 255))
		box(ctx, "SnowHat", Vector3.new(7, 5, 7), s + Vector3.new(0, 32, 0), rgb(40, 42, 52))
		for _, z in { -60, 60 } do
			pillar(ctx, "CandyPole", 3, 22, Vector3.new(84, 11, z), rgb(226, 62, 78))
			pillar(ctx, "CandyStripe", 3.4, 4, Vector3.new(84, 6, z), rgb(250, 250, 250))
			pillar(ctx, "CandyStripe", 3.4, 4, Vector3.new(84, 16, z), rgb(250, 250, 250))
		end
		rock(ctx, Vector3.new(40, 0, 100), 16, rgb(226, 236, 250))
	end,
	-- 06 EGYPT: urns by the obelisk, a palm on the sand, a drift.
	function(ctx)
		for i, p in { Vector3.new(-70, 0, -20), Vector3.new(-60, 0, 30) } do
			pillar(ctx, "Urn" .. i, 8, 10, p + Vector3.new(0, 5, 0), rgb(200, 132, 80), Enum.Material.Plastic)
			ball(ctx, "UrnLip" .. i, Vector3.new(9, 3, 9), p + Vector3.new(0, 10.5, 0), rgb(170, 108, 64))
		end
		pillar(ctx, "PalmTrunk", 4, 40, Vector3.new(-30, 20, 100), rgb(154, 110, 64))
		for f = 0, 4 do
			box(ctx, "Frond" .. f, Vector3.new(26, 2, 8), Vector3.new(-30, 40, 100), rgb(70, 190, 84), Enum.Material.Plastic, CFrame.Angles(0, math.rad(f * 72), math.rad(-14)) * CFrame.new(12, 0, 0))
		end
		rock(ctx, Vector3.new(20, 0, -100), 18, rgb(230, 200, 140))
	end,
	-- 07 GYM: kettlebells and a water cooler.
	function(ctx)
		for i, p in { Vector3.new(30, 0, -60), Vector3.new(44, 0, -50), Vector3.new(-30, 0, 100) } do
			ball(ctx, "Kettlebell" .. i, Vector3.new(10, 10, 10), p + Vector3.new(0, 5, 0), rgb(44, 48, 62), Enum.Material.Metal)
			box(ctx, "KettleHandle" .. i, Vector3.new(6, 3, 2), p + Vector3.new(0, 11, 0), rgb(44, 48, 62), Enum.Material.Metal)
		end
		box(ctx, "Cooler", Vector3.new(8, 14, 8), Vector3.new(-50, 7, -90), rgb(226, 232, 240), Enum.Material.Plastic)
		pillar(ctx, "CoolerJug", 7, 8, Vector3.new(-50, 18, -90), rgb(120, 200, 240), Enum.Material.Glass)
	end,
	-- 08 BANK: bollards along the facade, an armoured cart.
	function(ctx)
		for i = 0, 3 do
			pillar(ctx, "Bollard" .. i, 2.4, 6, Vector3.new(-70, 3, -40 + i * 30), IRON, Enum.Material.Metal)
		end
		bush(ctx, Vector3.new(-40, 0, -96), 12)
		bush(ctx, Vector3.new(60, 0, 100), 12)
		box(ctx, "Cart", Vector3.new(16, 10, 26), Vector3.new(30, 8, -80), rgb(60, 64, 78), Enum.Material.Metal)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				cyl(ctx, "CartWheel", Vector3.new(3, 6, 6), Vector3.new(30 + sx * 8.5, 3, -80 + sz * 9), rgb(30, 32, 40), Enum.Material.Plastic)
			end
		end
	end,
	-- 09 SECRET LAB: drums and crates, a warning light.
	function(ctx)
		for i, p in { Vector3.new(-40, 0, -100), Vector3.new(-30, 0, -90), Vector3.new(40, 0, 100) } do
			pillar(ctx, "Drum" .. i, 8, 12, p + Vector3.new(0, 6, 0), rgb(120, 236, 200), Enum.Material.Metal)
			pillar(ctx, "DrumBand" .. i, 8.6, 2, p + Vector3.new(0, 6, 0), rgb(40, 42, 52), Enum.Material.Metal)
		end
		crate(ctx, Vector3.new(60, 0, -90), 10, 15)
		pillar(ctx, "WarnPost", 2, 20, Vector3.new(-70, 10, 100), rgb(60, 64, 78), Enum.Material.Metal)
		ball(ctx, "WarnLight", Vector3.new(5, 5, 5), Vector3.new(-70, 22, 100), rgb(255, 80, 60), Enum.Material.Neon)
	end,
	-- 10 GRANDMA: a bench, a mailbox and hedges around the yard.
	function(ctx)
		bench(ctx, Vector3.new(-40, 0, -50), rgb(226, 226, 220))
		pillar(ctx, "MailPost", 1.6, 8, Vector3.new(-20, 4, 100), rgb(120, 84, 50), Enum.Material.Wood)
		box(ctx, "Mailbox", Vector3.new(6, 4, 8), Vector3.new(-20, 10, 100), rgb(72, 128, 236), Enum.Material.Plastic)
		bush(ctx, Vector3.new(30, 0, -90), 12, rgb(236, 118, 176))
		bush(ctx, Vector3.new(50, 0, 100), 12, rgb(118, 200, 104))
		bush(ctx, Vector3.new(-60, 0, 110), 10, rgb(236, 118, 176))
	end,
	-- 11 CONSTRUCTION: barriers, cones and a pallet of blocks.
	function(ctx)
		barrier(ctx, Vector3.new(-40, 0, -20), 20)
		barrier(ctx, Vector3.new(20, 0, 100), -30)
		cone(ctx, Vector3.new(60, 0, -90))
		cone(ctx, Vector3.new(-20, 0, 110))
		box(ctx, "Pallet", Vector3.new(16, 2, 16), Vector3.new(50, 1, 100), rgb(146, 96, 54), Enum.Material.WoodPlanks)
		box(ctx, "Blocks", Vector3.new(14, 10, 14), Vector3.new(50, 7, 100), rgb(178, 178, 182), Enum.Material.Concrete)
	end,
	-- 12 AIRPORT: baggage carts and runway cones.
	function(ctx)
		for i, p in { Vector3.new(-40, 0, -90), Vector3.new(-20, 0, 110) } do
			box(ctx, "Cart" .. i, Vector3.new(14, 6, 10), p + Vector3.new(0, 5, 0), rgb(226, 228, 234), Enum.Material.Metal)
			box(ctx, "CartLoad" .. i, Vector3.new(10, 5, 8), p + Vector3.new(0, 10.5, 0), rgb(64, 132, 236), Enum.Material.Plastic)
			box(ctx, "CartLoad2" .. i, Vector3.new(8, 4, 6), p + Vector3.new(1, 15, 0), rgb(226, 62, 88), Enum.Material.Plastic)
		end
		cone(ctx, Vector3.new(30, 0, -110))
		cone(ctx, Vector3.new(-60, 0, 20))
		cone(ctx, Vector3.new(50, 0, 120))
	end,
}

-- ==========================================================
-- COMPOSED LAYOUTS: loot plinths and the guardian post, per zone
-- ==========================================================
--
-- Authored-space offsets from the zone centre (X across, Y along the lane).
-- Read by MapBuilder.placeSockets, which scales them and nudges anything that
-- lands inside scenery. Four sockets each; the guardian sleeps at `post`.

export type Layout = { sockets: { Vector2 }, post: Vector2 }

MapLandmarks.layouts = {
	-- 01 MUSEUM: exhibits on the lawn before the steps; the Cop by the door.
	{ sockets = { Vector2.new(-48, -40), Vector2.new(-48, 62), Vector2.new(72, -30), Vector2.new(60, 52) }, post = Vector2.new(10, 12) },
	-- 02 PIRATE: by the bow, by the chest, under the palms, beside the hull.
	{ sockets = { Vector2.new(-40, -62), Vector2.new(62, 10), Vector2.new(108, 36), Vector2.new(-32, 74) }, post = Vector2.new(20, -28) },
	-- 03 CASTLE: along the curtain wall, by the stall, on the open field.
	{ sockets = { Vector2.new(-70, -22), Vector2.new(-70, 50), Vector2.new(60, -62), Vector2.new(72, 44) }, post = Vector2.new(0, 0) },
	-- 04 AREA 51: under the saucer, by the dish, before the hangar door.
	{ sockets = { Vector2.new(-50, -22), Vector2.new(-40, 96), Vector2.new(40, -72), Vector2.new(40, 50) }, post = Vector2.new(0, 20) },
	-- 05 NORTH POLE: among the gifts, inside the ice arch.
	{ sockets = { Vector2.new(-22, -60), Vector2.new(-20, 40), Vector2.new(60, 0), Vector2.new(70, -82) }, post = Vector2.new(10, -20) },
	-- 06 EGYPT: between obelisk and sphinx, on the sand before the pyramid.
	{ sockets = { Vector2.new(-60, -12), Vector2.new(-50, 100), Vector2.new(0, -92), Vector2.new(-12, 62) }, post = Vector2.new(0, 10) },
	-- 07 GYM: the open floor between the dumbbell, the plates and the bench.
	{ sockets = { Vector2.new(-40, -72), Vector2.new(-30, 96), Vector2.new(50, 22), Vector2.new(40, -82) }, post = Vector2.new(0, 0) },
	-- 08 BANK: before the bank, by the ingots.
	{ sockets = { Vector2.new(-60, -42), Vector2.new(-50, 96), Vector2.new(62, 60), Vector2.new(30, -62) }, post = Vector2.new(0, 10) },
	-- 09 SECRET LAB: by the tanks and the drums, before the reactor.
	{ sockets = { Vector2.new(-30, -52), Vector2.new(-70, 50), Vector2.new(50, -72), Vector2.new(50, 102) }, post = Vector2.new(0, 10) },
	-- 10 GRANDMA: the front yard, the back garden, between the flower pots.
	{ sockets = { Vector2.new(-40, -62), Vector2.new(-20, 100), Vector2.new(60, -40), Vector2.new(52, 40) }, post = Vector2.new(10, 0) },
	-- 11 CONSTRUCTION: around the pipes, the crane pad and the pallet.
	{ sockets = { Vector2.new(-60, -22), Vector2.new(-20, 52), Vector2.new(62, -62), Vector2.new(70, 72) }, post = Vector2.new(0, 0) },
	-- 12 AIRPORT: under the tower, along the runway, behind the jet.
	{ sockets = { Vector2.new(-50, -62), Vector2.new(-50, 40), Vector2.new(40, -82), Vector2.new(40, 112) }, post = Vector2.new(0, -10) },
} :: { Layout }

-- ==========================================================
-- SOCKET DRESSING
-- ==========================================================
--
-- Loot should look like it BELONGS where it stands: a crate and a barrel
-- beside the pirate plinth, hedges around the museum's, cones around Area
-- 51's. Two or three small props per plinth, themed to the zone.
--
-- WHY IT IS NOT IN `dressing`: MapBuilder settles every socket against the
-- scenery first (a plinth never lands inside a landmark), so anything placed
-- near a socket beforehand would just push that socket somewhere else. These
-- run AFTER placement, against the socket's final world position, and land in
-- the zone's own Decorations folder - which `applyDecorCollision` makes
-- hollow, so nothing here can ever catch a running player or a guardian.
--
-- Offsets are authored-space like the rest of this file (x across, z along)
-- and are kept past 15 so they clear the plinth's 18-stud rim.

local function urn(ctx: Ctx, offset: Vector3, height: number)
	pillar(ctx, "Urn", height * 0.8, height, offset + Vector3.new(0, height / 2, 0), rgb(200, 132, 80), Enum.Material.Plastic)
	ball(ctx, "UrnLip", Vector3.new(height * 0.9, height * 0.3, height * 0.9), offset + Vector3.new(0, height, 0), rgb(170, 108, 64))
end

local socketDressing: { (Ctx) -> () } = {
	-- 01 MUSEUM
	function(ctx)
		bush(ctx, Vector3.new(-17, 0, -5), 9)
		bush(ctx, Vector3.new(17, 0, 6), 8, rgb(118, 200, 104))
	end,
	-- 02 PIRATE
	function(ctx)
		barrel(ctx, Vector3.new(-17, 0, -4))
		crate(ctx, Vector3.new(17, 0, 7), 8, 20)
	end,
	-- 03 CASTLE
	function(ctx)
		barrel(ctx, Vector3.new(17, 0, -5))
		bush(ctx, Vector3.new(-17, 0, 6), 9)
	end,
	-- 04 AREA 51
	function(ctx)
		cone(ctx, Vector3.new(-16, 0, -7))
		cone(ctx, Vector3.new(16, 0, 7))
		crate(ctx, Vector3.new(17, 0, -7), 7, 15)
	end,
	-- 05 NORTH POLE
	function(ctx)
		rock(ctx, Vector3.new(-17, 0, -5), 11, rgb(226, 236, 250))
		rock(ctx, Vector3.new(17, 0, 6), 9, rgb(240, 246, 252))
	end,
	-- 06 EGYPT
	function(ctx)
		urn(ctx, Vector3.new(-17, 0, -5), 9)
		urn(ctx, Vector3.new(17, 0, 6), 7)
	end,
	-- 07 GYM
	function(ctx)
		box(ctx, "Mat", Vector3.new(15, 0.8, 11), Vector3.new(18, 0.4, 6), rgb(70, 158, 210), Enum.Material.SmoothPlastic)
		pillar(ctx, "Weight", 9, 3, Vector3.new(-17, 1.5, -4), rgb(38, 42, 58), Enum.Material.Metal)
		pillar(ctx, "WeightBar", 2, 12, Vector3.new(-17, 3.4, -4), rgb(150, 154, 166), Enum.Material.Metal, CFrame.Angles(0, 0, math.rad(90)))
	end,
	-- 08 BANK
	function(ctx)
		box(ctx, "Cashbox", Vector3.new(9, 7, 9), Vector3.new(-17, 3.5, -5), rgb(58, 132, 90), Enum.Material.Metal)
		box(ctx, "CashboxLid", Vector3.new(9.6, 1.2, 9.6), Vector3.new(-17, 7.4, -5), rgb(44, 108, 72), Enum.Material.Metal)
		pillar(ctx, "Bollard", 4, 11, Vector3.new(17, 5.5, 6), rgb(200, 206, 218), Enum.Material.Metal)
	end,
	-- 09 SECRET LAB
	function(ctx)
		pillar(ctx, "Canister", 7, 13, Vector3.new(-17, 6.5, -5), rgb(96, 214, 255), Enum.Material.SmoothPlastic)
		pillar(ctx, "CanisterCap", 8, 2, Vector3.new(-17, 13.5, -5), rgb(48, 54, 78), Enum.Material.Metal)
		box(ctx, "LabCrate", Vector3.new(9, 8, 9), Vector3.new(17, 4, 6), rgb(206, 210, 224), Enum.Material.SmoothPlastic)
	end,
	-- 10 GRANDMA
	function(ctx)
		bush(ctx, Vector3.new(-17, 0, -5), 9, rgb(120, 190, 110))
		pillar(ctx, "FlowerPot", 8, 7, Vector3.new(17, 3.5, 6), rgb(196, 110, 86), Enum.Material.Plastic)
		ball(ctx, "Flowers", Vector3.new(9, 6, 9), Vector3.new(17, 8.5, 6), rgb(240, 150, 190))
	end,
	-- 11 CONSTRUCTION
	function(ctx)
		cone(ctx, Vector3.new(-16, 0, -6))
		crate(ctx, Vector3.new(17, 0, 6), 9, 25)
	end,
	-- 12 AIRPORT
	function(ctx)
		box(ctx, "Suitcase", Vector3.new(11, 8, 6), Vector3.new(-17, 4, -5), rgb(60, 80, 140), Enum.Material.SmoothPlastic, CFrame.Angles(0, math.rad(12), 0))
		box(ctx, "SuitcaseSmall", Vector3.new(8, 6, 5), Vector3.new(-17, 11, -5), rgb(196, 84, 84), Enum.Material.SmoothPlastic, CFrame.Angles(0, math.rad(-8), 0))
		cone(ctx, Vector3.new(17, 0, 6))
	end,
}

--- Called by MapBuilder once a socket has settled, with its FINAL world spot.
function MapLandmarks.dressSocket(zoneIndex: number, parent: Instance, position: Vector3)
	local fn = socketDressing[zoneIndex]
	if not fn or not parent then
		return
	end
	fn({ parent = parent, origin = position, frame = CFrame.new(position) })
end

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
		if dressing[i] then
			dressing[i](ctx)
		end

		-- Nudge each side's landmark inward as a group if anything overhangs the
		-- containment wall. Shifting per side rather than per part keeps a
		-- composite landmark (hull, masts, sails) aligned with itself.
		local limit = MapConfig.LANE_HALF - 3
		local overflow = { [-1] = 0, [1] = 0 }
		for _, p in decorations:GetDescendants() do
			if p:IsA("BasePart") then
				local cf, s = p.CFrame, p.Size
				local hx = math.abs(cf.RightVector.X) * s.X / 2
					+ math.abs(cf.UpVector.X) * s.Y / 2
					+ math.abs(cf.LookVector.X) * s.Z / 2
				local side = if p.Position.X < 0 then -1 else 1
				local over = math.abs(p.Position.X) + hx - limit
				if over > overflow[side] then
					overflow[side] = over
				end
			end
		end

		for _, p in decorations:GetDescendants() do
			if p:IsA("BasePart") then
				local side = if p.Position.X < 0 then -1 else 1
				if overflow[side] > 0 then
					p.CFrame = p.CFrame + Vector3.new(-side * overflow[side], 0, 0)
				end
				-- Landmarks are scenery: no expensive shadows.
				p.CastShadow = false
				total += 1
			end
		end
	end

	print(string.format("[MapLandmarks] %d decoration parts across %d zones", total, MapConfig.ZONE_COUNT))
end

return MapLandmarks
