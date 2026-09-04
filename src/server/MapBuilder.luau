--!strict
--[[
	MapBuilder
	Generates the entire Steal Something world as real, editable geometry under
	Workspace.Map, following the hierarchy contract in section 15 of the GDD.

	Run it from the command bar in Edit mode:
		require(game.ServerScriptService.Server.MapBuilder).build()

	It is idempotent: an existing Workspace.Map is destroyed and rebuilt, so the
	generator stays the source of truth while individual parts remain hand-editable.

	Checker surfaces are built as coarse overlay tiles (one slab per surface plus
	alternating plates) rather than per-stud parts, which keeps the whole world
	around 1,200 parts while still reading as real geometry up close.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local MapPalette = require(ReplicatedStorage.Shared.MapPalette)
local MapLandmarks = require(script.Parent.MapLandmarks)

local MapBuilder = {}

-- ==========================================================
-- HELPERS
-- ==========================================================

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

type PartOptions = {
	name: string,
	size: Vector3,
	cframe: CFrame,
	parent: Instance,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	canCollide: boolean?,
	castShadow: boolean?,
	topSurface: Enum.SurfaceType?,
}

local function makePart(o: PartOptions): Part
	local p = Instance.new("Part")
	p.Name = o.name
	p.Size = o.size
	p.CFrame = o.cframe
	p.Anchored = true
	p.TopSurface = o.topSurface or Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Color = o.color or Color3.fromRGB(200, 200, 200)
	p.Material = o.material or Enum.Material.SmoothPlastic
	p.Transparency = o.transparency or 0
	p.CanCollide = if o.canCollide == nil then true else o.canCollide
	p.CastShadow = if o.castShadow == nil then true else o.castShadow
	p.Parent = o.parent
	return p
end

--- Splits a run into segments no longer than MAX_PART_AXIS.
local function segmentRun(center: number, total: number): { { center: number, length: number } }
	local count = math.max(1, math.ceil(total / MapConfig.MAX_PART_AXIS))
	local each = total / count
	local start = center - total / 2
	local segments = {}
	for i = 1, count do
		table.insert(segments, { center = start + each * (i - 0.5), length = each })
	end
	return segments
end

--- Horizontal checkered floor whose walkable surface sits exactly at Y = 0.
-- One full-size slab in shade A, plus alternating thin plates in shade B.
local function makeCheckerFloor(
	name: string,
	width: number,
	depth: number,
	centerX: number,
	centerZ: number,
	surface: MapPalette.Surface,
	parent: Instance
): Folder
	local group = folder(name, parent)
	local t = MapConfig.FLOOR_THICKNESS
	local top = if surface.studded then Enum.SurfaceType.Studs else Enum.SurfaceType.Smooth
	-- Studs only render on Plastic; SmoothPlastic silently swallows the surface type.
	local mat = if surface.studded then Enum.Material.Plastic else Enum.Material.SmoothPlastic

	for _, seg in segmentRun(centerZ, depth) do
		makePart({
			name = "Slab",
			size = Vector3.new(width, t, seg.length),
			cframe = CFrame.new(centerX, -t / 2, seg.center),
			color = surface.a,
			parent = group,
			castShadow = false,
			topSurface = top,
			material = mat,
		})
	end

	-- Checker plates. Cell sizes are derived so the pattern divides the surface
	-- exactly and never leaves a sliver at the edge.
	local cols = math.max(1, math.round(width / surface.tile))
	local rows = math.max(1, math.round(depth / surface.tile))
	local cw, cd = width / cols, depth / rows
	local x0, z0 = centerX - width / 2, centerZ - depth / 2

	local tiles = folder("Checker", group)
	for col = 1, cols do
		for row = 1, rows do
			if (col + row) % 2 == 0 then
				makePart({
					name = "Tile",
					size = Vector3.new(cw, 1, cd),
					cframe = CFrame.new(x0 + cw * (col - 0.5), -0.48, z0 + cd * (row - 0.5)),
					color = surface.b,
					parent = tiles,
					canCollide = false,
					castShadow = false,
					topSurface = top,
					material = mat,
				})
			end
		end
	end

	return group
end

--- Vertical checker plating applied to one inward-facing wall surface.
-- `normalX` is +1 when the visible face points toward +X.
local function plateWallFace(
	parent: Instance,
	faceX: number,
	normalX: number,
	runCenterZ: number,
	runLength: number,
	surface: MapPalette.Surface
)
	local height = MapConfig.WALL_HEIGHT
	local rows = math.max(1, math.round(height / surface.tile))
	local cols = math.max(1, math.round(runLength / surface.tile))
	local ch, cw = height / rows, runLength / cols
	local z0 = runCenterZ - runLength / 2

	local tiles = folder("Checker", parent)
	for col = 1, cols do
		for row = 1, rows do
			if (col + row) % 2 == 0 then
				makePart({
					name = "Tile",
					size = Vector3.new(0.4, ch, cw),
					cframe = CFrame.new(faceX + normalX * 0.2, ch * (row - 0.5), z0 + cw * (col - 0.5)),
					color = surface.b,
					parent = tiles,
					canCollide = false,
					castShadow = false,
				})
			end
		end
	end
end

--- Containment wall plus its bright cap, bottom-aligned to Y = 0.
-- Long runs are chunked so no Part exceeds Roblox's 2048-stud axis cap.
-- `checkerNormal` (-1 / 0 / +1) says which side, if any, gets checker plating.
local function makeWall(
	name: string,
	width: number,
	depth: number,
	centerX: number,
	centerZ: number,
	parent: Instance,
	checkerNormal: number?
): Folder
	local h = MapConfig.WALL_HEIGHT
	local capH = MapConfig.WALL_CAP_HEIGHT
	local over = MapConfig.WALL_CAP_OVERHANG
	local surface = MapPalette.WallFace

	local group = folder(name, parent)

	local alongZ = depth >= width
	local runTotal = if alongZ then depth else width
	local runCenter = if alongZ then centerZ else centerX
	local segments = segmentRun(runCenter, runTotal)

	for i, seg in segments do
		local sx = if alongZ then width else seg.length
		local sz = if alongZ then seg.length else depth
		local cx = if alongZ then centerX else seg.center
		local cz = if alongZ then seg.center else centerZ
		local suffix = if #segments == 1 then "" else string.format("_%02d", i)

		makePart({
			name = "Face" .. suffix,
			size = Vector3.new(sx, h, sz),
			cframe = CFrame.new(cx, h / 2, cz),
			color = surface.a,
			parent = group,
		})

		makePart({
			name = "Cap" .. suffix,
			size = Vector3.new(
				if alongZ then sx + over * 2 else sx,
				capH,
				if alongZ then sz else sz + over * 2
			),
			cframe = CFrame.new(cx, h + capH / 2, cz),
			color = MapPalette.WallCap,
			parent = group,
			topSurface = Enum.SurfaceType.Studs,
			material = Enum.Material.Plastic,
		})
	end

	if checkerNormal and checkerNormal ~= 0 and alongZ then
		plateWallFace(group, centerX + checkerNormal * width / 2, checkerNormal, centerZ, depth, surface)
	end

	return group
end

--- Invisible, non-colliding trigger volume.
local function makeVolume(name: string, size: Vector3, cframe: CFrame, parent: Instance): Part
	return makePart({
		name = name,
		size = size,
		cframe = cframe,
		parent = parent,
		transparency = 1,
		canCollide = false,
		castShadow = false,
	})
end

--- Small visible marker used for sockets, guard posts and display slots.
local function makeMarker(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	return makePart({
		name = name,
		size = size,
		cframe = cframe,
		parent = parent,
		color = color,
		canCollide = false,
		castShadow = false,
		transparency = 0.4,
		material = Enum.Material.Neon,
	})
end

-- ==========================================================
-- LANE FLOORS
-- ==========================================================

local function buildLaneFloors(map: Instance)
	local floors = folder("LaneFloors", map)

	makeCheckerFloor(
		"PlazaFloor",
		MapConfig.PLAZA_WIDTH,
		MapConfig.BASE_AREA_DEPTH,
		0,
		MapConfig.PLAZA_BACK_Z + MapConfig.BASE_AREA_DEPTH / 2,
		MapPalette.Plaza,
		floors
	)

	makeCheckerFloor(
		"SafeApronFloor",
		MapConfig.LANE_WIDTH,
		MapConfig.SAFE_ZONE_DEPTH,
		0,
		MapConfig.PLAZA_FRONT_Z + MapConfig.SAFE_ZONE_DEPTH / 2,
		MapPalette.SafeApron,
		floors
	)
end

-- ==========================================================
-- WALLS
-- ==========================================================

local function buildWalls(map: Instance)
	local walls = folder("Walls", map)

	local t = MapConfig.WALL_THICKNESS
	local laneOuterX = MapConfig.LANE_HALF + t / 2
	local plazaOuterX = MapConfig.PLAZA_HALF + t / 2

	local laneRun = MapConfig.LANE_END_Z - MapConfig.PLAZA_FRONT_Z
	local laneCenterZ = MapConfig.PLAZA_FRONT_Z + laneRun / 2

	for _, sign in { -1, 1 } do
		local side = if sign < 0 then "Left" else "Right"

		-- Inward face is the one players see, so that is the side we plate.
		makeWall(side .. "Wall", t, laneRun, sign * laneOuterX, laneCenterZ, walls, -sign)
		makeWall(
			side .. "PlazaWall",
			t,
			MapConfig.BASE_AREA_DEPTH,
			sign * plazaOuterX,
			MapConfig.PLAZA_BACK_Z + MapConfig.BASE_AREA_DEPTH / 2,
			walls,
			-sign
		)

		local shoulderInner = MapConfig.LANE_HALF
		local shoulderOuter = MapConfig.PLAZA_HALF + t
		local shoulderWidth = shoulderOuter - shoulderInner
		makeWall(
			side .. "Shoulder",
			shoulderWidth,
			t,
			sign * (shoulderInner + shoulderWidth / 2),
			MapConfig.PLAZA_FRONT_Z - t / 2,
			walls
		)
	end

	makeWall("PlazaBackWall", MapConfig.PLAZA_WIDTH + t * 2, t, 0, MapConfig.PLAZA_BACK_Z - t / 2, walls)
	makeWall("WorldEndWall", MapConfig.LANE_WIDTH + t * 2, t, 0, MapConfig.LANE_END_Z + t / 2, walls)
end

-- ==========================================================
-- SAFE ZONE
-- ==========================================================

local function buildSafeZone(map: Instance)
	local safe = folder("SafeZone", map)

	makePart({
		name = "BoundaryLine",
		size = Vector3.new(MapConfig.LANE_WIDTH, 0.3, MapConfig.SAFE_LINE_WIDTH),
		cframe = CFrame.new(0, 0.15, 0),
		color = MapPalette.SafeLine,
		material = Enum.Material.Neon,
		parent = safe,
		canCollide = false,
		castShadow = false,
	})

	-- Chevron flashes either side of the line so the boundary reads at speed.
	for _, sign in { -1, 1 } do
		makePart({
			name = "BoundaryFlash",
			size = Vector3.new(46, 0.3, 14),
			cframe = CFrame.new(sign * (MapConfig.LANE_HALF - 30), 0.14, -12),
			color = MapPalette.SafeLine,
			material = Enum.Material.Neon,
			parent = safe,
			canCollide = false,
			castShadow = false,
			transparency = 0.35,
		})
	end

	local depth = MapConfig.SAFE_ZONE_DEPTH + MapConfig.BASE_AREA_DEPTH
	makeVolume(
		"SafeVolume",
		Vector3.new(MapConfig.PLAZA_WIDTH, MapConfig.SAFE_ZONE_HEIGHT, depth),
		CFrame.new(0, MapConfig.SAFE_ZONE_HEIGHT / 2, MapConfig.PLAZA_BACK_Z + depth / 2),
		safe
	)
end

-- ==========================================================
-- ZONES
-- ==========================================================

local function buildZones(map: Instance)
	local zones = folder("Zones", map)
	local transitions = folder("Transitions", map)

	for i, def in MapConfig.ZONES do
		local startZ = MapConfig.zoneStartZ(i)
		local centerZ = MapConfig.zoneCenterZ(i)
		local length = MapConfig.zoneLength(i)
		local surface = MapPalette.Zones[i]

		local zone = folder(def.id, zones)
		zone:SetAttribute("ZoneIndex", i)
		zone:SetAttribute("DisplayName", def.name)
		zone:SetAttribute("GuardianId", def.guardian)
		zone:SetAttribute("ZoneLength", length)

		makeCheckerFloor("Floor", MapConfig.LANE_WIDTH, length, 0, centerZ, surface, zone)

		makeVolume(
			"Bounds",
			Vector3.new(MapConfig.LANE_WIDTH, MapConfig.WALL_HEIGHT, length),
			CFrame.new(0, MapConfig.WALL_HEIGHT / 2, centerZ),
			zone
		)

		makeVolume("Entrance", Vector3.new(MapConfig.LANE_WIDTH, 20, 6), CFrame.new(0, 10, startZ), zone)

		local sockets = folder("SpawnSockets", zone)
		local guards = folder("GuardianSpawns", zone)

		local socketX = MapConfig.LANE_WIDTH * 0.26
		local guardX = MapConfig.LANE_HALF - 28
		local rowZ = { startZ + length * 0.29, startZ + length * 0.71 }

		local n = 0
		for _, z in rowZ do
			for _, sign in { -1, 1 } do
				n += 1
				makeMarker(
					string.format("Socket%02d", n),
					Vector3.new(16, 0.6, 16),
					CFrame.new(sign * socketX, 0.3, z),
					MapPalette.LootSocket,
					sockets
				)
				makeMarker(
					string.format("Guard%02d", n),
					Vector3.new(7, 0.6, 7),
					CFrame.new(sign * guardX, 0.3, z),
					MapPalette.SafeLine,
					guards
				)
			end
		end

		if i < MapConfig.ZONE_COUNT then
			local blend = MapPalette.transition(i)
			makeCheckerFloor(
				string.format("Transition%02d_%02d", i, i + 1),
				MapConfig.LANE_WIDTH,
				MapConfig.TRANSITION_DEPTH,
				0,
				MapConfig.zoneEndZ(i) + MapConfig.TRANSITION_DEPTH / 2,
				{ a = blend, b = blend:Lerp(Color3.new(0, 0, 0), 0.08), studded = surface.studded, tile = 40 },
				transitions
			)
		end
	end
end

-- ==========================================================
-- BASES
-- ==========================================================

local function buildBase(layout: MapConfig.PlotLayout, parent: Instance)
	local base = folder(layout.name, parent)
	base:SetAttribute("PlotIndex", layout.index)

	local plotCF = CFrame.lookAt(layout.center, layout.center + layout.inward)
	local halfW, halfD = layout.width / 2, layout.depth / 2

	local function at(x: number, y: number, z: number): CFrame
		return plotCF * CFrame.new(x, y, z)
	end

	-- Plot floor sits 0.6 studs proud so ownership boundaries read from a distance.
	local surface = MapPalette.PlotFloor
	local floorGroup = folder("PlotFloor", base)
	makePart({
		name = "Slab",
		size = Vector3.new(layout.width, 1.2, layout.depth),
		cframe = at(0, -0.6, 0),
		color = surface.a,
		parent = floorGroup,
		castShadow = false,
		topSurface = Enum.SurfaceType.Studs,
		material = Enum.Material.Plastic,
	})

	local cols = math.max(1, math.round(layout.width / surface.tile))
	local rows = math.max(1, math.round(layout.depth / surface.tile))
	local cw, cd = layout.width / cols, layout.depth / rows
	local tiles = folder("Checker", floorGroup)
	for col = 1, cols do
		for row = 1, rows do
			if (col + row) % 2 == 0 then
				makePart({
					name = "Tile",
					size = Vector3.new(cw, 1, cd),
					cframe = at(-halfW + cw * (col - 0.5), -0.48, -halfD + cd * (row - 0.5)),
					color = surface.b,
					parent = tiles,
					canCollide = false,
					castShadow = false,
					topSurface = Enum.SurfaceType.Studs,
					material = Enum.Material.Plastic,
				})
			end
		end
	end

	-- Post-and-rail fence on the three enclosed sides; the front stays open so
	-- players run straight out onto their treadmill and down the lane.
	local fence = folder("Fence", base)
	local postH, railY, spacing = 8, 6, 26

	local function fenceRun(fromX: number, fromZ: number, toX: number, toZ: number)
		local dx, dz = toX - fromX, toZ - fromZ
		local length = math.sqrt(dx * dx + dz * dz)
		local count = math.max(2, math.round(length / spacing) + 1)

		for i = 1, count do
			local t = (i - 1) / (count - 1)
			makePart({
				name = "Post",
				size = Vector3.new(2, postH, 2),
				cframe = at(fromX + dx * t, postH / 2, fromZ + dz * t),
				color = MapPalette.PlotBorder,
				parent = fence,
				canCollide = false,
			})
		end

		local horizontal = math.abs(dx) > math.abs(dz)
		makePart({
			name = "Rail",
			size = Vector3.new(if horizontal then length else 1.2, 1.2, if horizontal then 1.2 else length),
			cframe = at((fromX + toX) / 2, railY, (fromZ + toZ) / 2),
			color = MapPalette.PlotBorder,
			parent = fence,
			canCollide = false,
		})
	end

	fenceRun(-halfW, halfD, halfW, halfD)
	fenceRun(-halfW, halfD, -halfW, -halfD)
	fenceRun(halfW, halfD, halfW, -halfD)

	-- Display slots: two rows of seven, sized for Giant (x3.5) trophies.
	local slots = folder("DisplaySlots", base)
	local perRow = MapConfig.DISPLAY_SLOTS_PER_BASE // MapConfig.DISPLAY_SLOT_ROWS
	local n = 0
	for row = 1, MapConfig.DISPLAY_SLOT_ROWS do
		local localZ = halfD - MapConfig.DISPLAY_ROW_BACK_INSET - (row - 1) * MapConfig.DISPLAY_ROW_PITCH
		for col = 1, perRow do
			n += 1
			local slot = makeMarker(
				string.format("DisplaySlot%02d", n),
				MapConfig.DISPLAY_SLOT_SIZE,
				at(-halfW + layout.width * (col - 0.5) / perRow, 0.5, localZ),
				MapPalette.DisplaySlot,
				slots
			)
			slot:SetAttribute("SlotIndex", n)
		end
	end

	local frontZ = -halfD + 30
	makePart({
		name = "BaseActivationPad",
		size = MapConfig.PAD_SIZE,
		cframe = at(-layout.width / 5, 0.5, frontZ),
		color = MapPalette.PadActivate,
		material = Enum.Material.Neon,
		parent = base,
		castShadow = false,
	})
	makePart({
		name = "BaseUpgradePad",
		size = MapConfig.PAD_SIZE,
		cframe = at(layout.width / 5, 0.5, frontZ),
		color = MapPalette.PadUpgrade,
		material = Enum.Material.Neon,
		parent = base,
		castShadow = false,
	})

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = at(0, 0.5, frontZ + 20)
	spawn.Anchored = true
	spawn.CanCollide = false
	spawn.Transparency = 1
	spawn.Enabled = false -- BaseService enables the plot it assigns
	spawn.Neutral = true
	spawn.Parent = base

	-- Treadmill stands in the corridor directly in front of the plot.
	local treadmill = folder("Treadmill", base)
	local tSize = MapConfig.TREADMILL_SIZE
	local tZ = -halfD - MapConfig.TREADMILL_STANDOFF
	makePart({
		name = "Frame",
		size = tSize,
		cframe = at(0, tSize.Y / 2, tZ),
		color = MapPalette.Treadmill,
		parent = treadmill,
	})
	makePart({
		name = "Belt",
		size = Vector3.new(tSize.X - 4, 0.6, tSize.Z - 4),
		cframe = at(0, tSize.Y + 0.1, tZ),
		color = MapPalette.TreadmillBelt,
		parent = treadmill,
		canCollide = false,
	})
	for _, sign in { -1, 1 } do
		makePart({
			name = "Rail",
			size = Vector3.new(1.6, 9, tSize.Z - 6),
			cframe = at(sign * (tSize.X / 2 - 0.8), tSize.Y + 4.5, tZ),
			color = MapPalette.Treadmill,
			parent = treadmill,
			canCollide = false,
		})
	end
	makeVolume(
		"TrainingTrigger",
		Vector3.new(tSize.X, 12, tSize.Z),
		at(0, 8, tZ),
		treadmill
	)

	-- Per-base safe volume covers the plot and its treadmill (GDD section 10).
	local safeDepth = layout.depth + MapConfig.SAFE_ZONE_CORRIDOR_BLEED
	makeVolume(
		"SafeZone",
		Vector3.new(layout.width, MapConfig.SAFE_ZONE_HEIGHT, safeDepth),
		at(0, MapConfig.SAFE_ZONE_HEIGHT / 2, -(safeDepth - layout.depth) / 2),
		base
	)
end

local function buildBases(map: Instance)
	local bases = folder("Bases", map)
	for _, layout in MapConfig.getPlotLayouts() do
		buildBase(layout, bases)
	end
end

-- ==========================================================
-- SPAWNS
-- ==========================================================

local function buildSpawns(map: Instance)
	local spawns = folder("SpawnLocations", map)

	local s = Instance.new("SpawnLocation")
	s.Name = "LobbySpawn"
	s.Size = Vector3.new(24, 1, 24)
	s.CFrame = CFrame.new(0, 0.5, MapConfig.PLAZA_FRONT_Z - MapConfig.BASE_AREA_DEPTH * 0.3)
	s.Anchored = true
	s.CanCollide = false
	s.Transparency = 0.5
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Material = Enum.Material.Neon
	s.Neutral = true
	s.Parent = spawns
end

-- ==========================================================
-- ENTRY POINT
-- ==========================================================

function MapBuilder.build(): Folder
	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end

	local map = folder("Map", workspace)

	buildLaneFloors(map)
	buildZones(map)
	buildWalls(map)
	buildSafeZone(map)
	buildBases(map)
	buildSpawns(map)
	folder("Decorations", map)
	MapLandmarks.build(map)

	local parts = 0
	for _, d in map:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
		end
	end

	print(string.format(
		"[MapBuilder] %d parts | world %d studs | lane %d wide | walls %d tall | %d zones | %d bases",
		parts,
		MapConfig.WORLD_LENGTH,
		MapConfig.LANE_WIDTH,
		MapConfig.WALL_HEIGHT,
		MapConfig.ZONE_COUNT,
		MapConfig.BASE_COUNT
	))

	return map
end

return MapBuilder
