--!strict
--[[
	MapBuilder
	Generates the entire Steal Something world as real, editable geometry under
	Workspace.Map, following the hierarchy contract in section 15 of the GDD.

	Run it from the command bar in Edit mode:
		require(game.ServerScriptService.Server.MapBuilder).build()

	It is idempotent: an existing Workspace.Map is destroyed and rebuilt, so the
	generator stays the source of truth while individual parts remain hand-editable.

	WHAT THE WORLD IS MADE OF (the pre-release layout pass)
	  * THE HUB: the apron between the plaza and the red line. Spawn stands on
	    a paved circle in its middle facing the Zone 01 gate; the trail booth is
	    to its left, the event stand to its right, the leaderboards flank the
	    gate. Every destination is a few seconds' walk (MapConfig.HUB).
	  * THE PLAZA: a paved avenue runs from the hub back between two rows of
	    plots, each with its treadmill at the kerb. The plots are sized from
	    what they hold - two ranks of seven display pads and a porch - and no
	    more (MapConfig.PLOT_DEPTH / PLAZA_CORRIDOR_WIDTH).
	  * THE LANE: twelve zones, each with a GATE at its entrance (two pylons
	    and a lintel carrying the zone's name), a landmark, a composed layout
	    of four loot plinths and one guardian post (MapLandmarks.layouts), and
	    supporting scenery. Pilasters and a trim band break the long walls
	    into bays.
	  * FUNCTIONAL PARTS ARE DRESSED, NEVER REMOVED. Sockets, guardian posts,
	    slot pads, spawn pads and trigger volumes keep their names, sizes and
	    attributes; what changed is that a socket is a stone plinth instead of
	    a glowing yellow square and a guardian post is invisible.

	Checker surfaces are built as coarse overlay tiles (one slab per surface plus
	alternating plates) rather than per-stud parts, which keeps the whole world
	around 1,500 parts while still reading as real geometry up close.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local MapPalette = require(ReplicatedStorage.Shared.MapPalette)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
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
	shape: Enum.PartType?,
}

local function makePart(o: PartOptions): Part
	local p = Instance.new("Part")
	p.Name = o.name
	if o.shape then
		p.Shape = o.shape
	end
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

--- A paved surface laid ON a floor: a thin smooth slab sitting proud of the
--- ground by its own thickness, so it never shares a plane with the checker.
local function makePaving(name: string, size: Vector3, cframe: CFrame, parent: Instance, shape: Enum.PartType?): Part
	return makePart({
		name = name,
		size = size,
		cframe = cframe,
		parent = parent,
		color = MapPalette.Paving.a,
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		castShadow = false,
		shape = shape,
	})
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

--- Pilasters and a trim band along one inward-facing wall run. Non-colliding:
--- they are relief, and a shoulder or a guardian must never catch on them.
local function detailWallFace(parent: Instance, faceX: number, normalX: number, runCenterZ: number, runLength: number)
	local size = MapConfig.WALL_PILASTER_SIZE
	local spacing = MapConfig.WALL_PILASTER_SPACING
	local z0 = runCenterZ - runLength / 2
	local count = math.max(1, math.floor(runLength / spacing))
	local step = runLength / count

	local detail = folder("Detail", parent)
	for i = 0, count do
		local z = z0 + step * i
		makePart({
			name = "Pilaster",
			size = size,
			cframe = CFrame.new(faceX + normalX * size.X / 2, size.Y / 2, z),
			color = MapPalette.WallPilaster,
			parent = detail,
			canCollide = false,
			castShadow = false,
		})
	end
	for _, seg in segmentRun(runCenterZ, runLength) do
		makePart({
			name = "Trim",
			size = Vector3.new(0.8, 3, seg.length),
			cframe = CFrame.new(faceX + normalX * 0.4, MapConfig.WALL_TRIM_HEIGHT, seg.center),
			color = MapPalette.WallTrim,
			parent = detail,
			canCollide = false,
			castShadow = false,
		})
	end
end

--- Containment wall plus its bright cap, bottom-aligned to Y = 0.
-- Long runs are chunked so no Part exceeds Roblox's 2048-stud axis cap.
-- `checkerNormal` (-1 / 0 / +1) says which side, if any, gets checker plating
-- and wall detail.
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
		local faceX = centerX + checkerNormal * width / 2
		plateWallFace(group, faceX, checkerNormal, centerZ, depth, surface)
		detailWallFace(group, faceX, checkerNormal, centerZ, depth)
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

--- A loot socket: the part LootService measures against, dressed as a low
--- stone plinth with a lighter rim under it. The name, size and position are
--- the contract; the client draws the item's rarity ring on top.
local function makeSocket(name: string, cframe: CFrame, parent: Instance): Part
	local socket = makePart({
		name = name,
		size = Vector3.new(16, 0.6, 16),
		cframe = cframe,
		parent = parent,
		color = MapPalette.LootSocket,
		canCollide = false,
		castShadow = false,
	})
	makePart({
		name = "Rim",
		size = Vector3.new(18, 0.3, 18),
		cframe = cframe * CFrame.new(0, -0.2, 0),
		parent = socket,
		color = MapPalette.LootSocketRim,
		canCollide = false,
		castShadow = false,
	})
	return socket
end

--- The guardian's post: a marker the service reads and nothing a player sees.
--- The guardian itself stands on it.
local function makeGuardianPost(cframe: CFrame, parent: Instance): Part
	return makePart({
		name = "GuardianPost",
		size = Vector3.new(9, 0.6, 9),
		cframe = cframe,
		parent = parent,
		transparency = 1,
		canCollide = false,
		castShadow = false,
	})
end

--- Display slot pad. Matte and quiet, in the locked shade: BaseService restyles
--- every pad (locked / empty / occupied) the moment the server starts, and the
--- trophy standing on it is the thing that should draw the eye.
local function makeSlotPad(name: string, cframe: CFrame, parent: Instance): Part
	return makePart({
		name = name,
		size = MapConfig.DISPLAY_SLOT_SIZE,
		cframe = cframe,
		parent = parent,
		color = MapPalette.SlotPadLocked,
		canCollide = false,
		castShadow = false,
		material = Enum.Material.SmoothPlastic,
	})
end

-- ==========================================================
-- SMALL PROPS
-- ==========================================================

--- A planter box with a bush in it. Two parts, no collision.
local function makePlanter(name: string, cframe: CFrame, parent: Instance)
	makePart({
		name = name,
		size = Vector3.new(8, 3, 8),
		cframe = cframe * CFrame.new(0, 1.5, 0),
		parent = parent,
		color = MapPalette.Planter,
		material = Enum.Material.Plastic,
		canCollide = false,
		castShadow = false,
	})
	makePart({
		name = name .. "Bush",
		size = Vector3.new(9, 8, 9),
		cframe = cframe * CFrame.new(0, 6.5, 0),
		parent = parent,
		color = MapPalette.Bush,
		material = Enum.Material.Grass,
		canCollide = false,
		castShadow = false,
		shape = Enum.PartType.Ball,
	})
end

--- A lamp post: a dark post with a warm glowing head. No light source - the
--- neon head reads as lit without a PointLight per plot.
local function makeLamp(name: string, cframe: CFrame, parent: Instance)
	makePart({
		name = name,
		size = Vector3.new(0.9, 9, 0.9),
		cframe = cframe * CFrame.new(0, 4.5, 0),
		parent = parent,
		color = MapPalette.LampPost,
		canCollide = false,
		castShadow = false,
	})
	makePart({
		name = name .. "Glow",
		size = Vector3.new(2.4, 2.4, 2.4),
		cframe = cframe * CFrame.new(0, 9.8, 0),
		parent = parent,
		color = MapPalette.LampGlow,
		material = Enum.Material.Neon,
		canCollide = false,
		castShadow = false,
		shape = Enum.PartType.Ball,
	})
end

-- ==========================================================
-- LANE FLOORS AND THE HUB
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

	-- THE HUB PAVING. A circle under the spawn, and the avenue running from it
	-- back through the plaza to the head plot's porch. Paving sits 0.3 proud
	-- of the checker so it can never share a plane with it.
	local hub = MapConfig.HUB
	local paving = folder("Paving", map)
	local diameter = hub.spawnPlazaDiameter
	makePaving("SpawnPlazaEdge", Vector3.new(0.4, diameter + 4, diameter + 4), CFrame.new(hub.spawn.X, 0.2, hub.spawn.Z) * CFrame.Angles(0, 0, math.rad(90)), paving, Enum.PartType.Cylinder).Color =
		MapPalette.PavingEdge
	makePaving("SpawnPlaza", Vector3.new(0.6, diameter, diameter), CFrame.new(hub.spawn.X, 0.3, hub.spawn.Z) * CFrame.Angles(0, 0, math.rad(90)), paving, Enum.PartType.Cylinder)

	local avenueFrontZ = hub.spawn.Z - diameter / 2
	local avenueBackZ = MapConfig.PLAZA_BACK_Z + MapConfig.HEAD_PLOT_DEPTH
	local avenueLength = avenueFrontZ - avenueBackZ
	for _, seg in segmentRun((avenueFrontZ + avenueBackZ) / 2, avenueLength) do
		makePaving("Avenue", Vector3.new(hub.avenueWidth, 0.3, seg.length), CFrame.new(0, 0.15, seg.center), paving)
	end
	-- A short spur from the spawn circle up to the red line, so the way into
	-- the world is drawn on the ground.
	local spurFrontZ = hub.spawn.Z + diameter / 2
	makePaving("Spur", Vector3.new(hub.avenueWidth, 0.3, -6 - spurFrontZ), CFrame.new(0, 0.15, (spurFrontZ - 6) / 2), paving)

	-- Greenery and lamps ring the spawn circle so the hub reads as a place.
	-- Nothing stands on the circle's Z axis: that is the line a new player
	-- walks from the spawn to the gate, and the line they look along.
	local props = folder("Decorations", map)
	for _, sign in { -1, 1 } do
		local radius = diameter / 2 + 7
		makePlanter("HubPlanter", CFrame.new(hub.spawn.X + sign * radius, 0, hub.spawn.Z), props)
	end
	for i = 0, 3 do
		local angle = math.rad(45 + i * 90)
		local radius = diameter / 2 + 5
		local at = Vector3.new(hub.spawn.X + math.cos(angle) * radius, 0, hub.spawn.Z + math.sin(angle) * radius)
		makeLamp("HubLamp" .. i, CFrame.new(at), props)
	end
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
-- ZONES AND THEIR GATES
-- ==========================================================

--- The entrance to a zone: two pylons at the wall feet and a lintel across
--- the lane carrying the zone's name in its colour. Everything is above or
--- beside the running line; nothing stands in it.
local function buildGate(zone: Instance, index: number, startZ: number)
	local def = ZoneConfig.Zones[index]
	local pylon = MapConfig.GATE_PYLON_SIZE
	local inset = MapConfig.GATE_INSET
	local gate = folder("Gate", zone)
	local x = MapConfig.LANE_HALF - inset - pylon.X / 2
	local z = startZ - 6

	for _, sign in { -1, 1 } do
		makePart({
			name = "Pylon",
			size = pylon,
			cframe = CFrame.new(sign * x, pylon.Y / 2, z),
			color = MapPalette.GatePylon,
			parent = gate,
			canCollide = false,
			castShadow = false,
		})
		makePart({
			name = "PylonBand",
			size = Vector3.new(pylon.X + 0.6, 5, pylon.Z + 0.6),
			cframe = CFrame.new(sign * x, pylon.Y - 8, z),
			color = def.color,
			parent = gate,
			canCollide = false,
			castShadow = false,
		})
		makePart({
			name = "PylonCap",
			size = Vector3.new(pylon.X + 2, 2, pylon.Z + 2),
			cframe = CFrame.new(sign * x, pylon.Y + 1, z),
			color = MapPalette.GateLintel,
			parent = gate,
			canCollide = false,
			castShadow = false,
		})
	end

	local span = 2 * x + pylon.X
	local thickness = MapConfig.GATE_LINTEL_THICKNESS
	local lintelHeight = 7
	local lintel = makePart({
		name = "Lintel",
		size = Vector3.new(span, lintelHeight, thickness),
		cframe = CFrame.new(0, pylon.Y + 2 + lintelHeight / 2, z),
		color = MapPalette.GateLintel,
		parent = gate,
		canCollide = false,
		castShadow = false,
	})

	-- The zone's name on the lintel, facing the approach (-Z).
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 12
	gui.Parent = lintel

	local band = Instance.new("Frame")
	band.Name = "Band"
	band.AnchorPoint = Vector2.new(0.5, 0.5)
	band.Position = UDim2.fromScale(0.5, 0.5)
	band.Size = UDim2.fromScale(0.34, 0.86)
	band.BackgroundColor3 = def.color
	band.BackgroundTransparency = 0.1
	band.BorderSizePixel = 0
	band.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = band

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.5)
	title.Size = UDim2.fromScale(0.92, 0.78)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = `{def.emoji}  {string.upper(def.name)}`
	title.TextColor3 = Color3.fromRGB(20, 22, 36)
	title.Parent = band
end

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

		folder("SpawnSockets", zone)
		folder("GuardianSpawns", zone)
		buildGate(zone, i, startZ)

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
-- LOOT SOCKETS AND GUARDIAN POSTS
-- ==========================================================

--- True world-axis XZ half-extents of a part, rotation included.
local function footprintOf(p: BasePart): (number, number)
	local cf = p.CFrame
	local sx, sy, sz = p.Size.X / 2, p.Size.Y / 2, p.Size.Z / 2
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	local hx = math.abs(r.X) * sx + math.abs(u.X) * sy + math.abs(l.X) * sz
	local hz = math.abs(r.Z) * sx + math.abs(u.Z) * sy + math.abs(l.Z) * sz
	return hx, hz
end

type Footprint = { x: number, z: number, hx: number, hz: number, pad: number? }

--- Small props (a crate, a barrel, a bush) may sit close to a plinth - that
--- is the point of them; a landmark keeps the full clearance.
local SMALL_PROP_EXTENT = 14
local SMALL_PROP_CLEARANCE = 5

--- XZ footprints of everything a socket must stay clear of: the scenery and
--- the gate pylons.
local function blockerFootprints(zone: Instance): { Footprint }
	local out: { Footprint } = {}
	for _, container in { zone:FindFirstChild("Decorations"), zone:FindFirstChild("Gate") } do
		if container then
			for _, p in container:GetDescendants() do
				if p:IsA("BasePart") and p.Position.Y - p.Size.Y / 2 < 12 then
					-- Only things a player could bump into matter; a lintel or
					-- a sail overhead does not block the ground.
					local hx, hz = footprintOf(p)
					-- A small prop, or a thin strip (a hedge, a fence, a rail),
					-- keeps a short clearance; only a real landmark keeps the
					-- full one.
					local small = hx + hz < SMALL_PROP_EXTENT or math.min(hx, hz) < 4
					table.insert(out, {
						x = p.Position.X,
						z = p.Position.Z,
						hx = hx,
						hz = hz,
						pad = if small then SMALL_PROP_CLEARANCE else nil,
					})
				end
			end
		end
	end
	return out
end

local function isClear(footprints: { Footprint }, x: number, z: number, pad: number): boolean
	for _, f in footprints do
		local clearance = f.pad or pad
		if math.abs(x - f.x) < f.hx + clearance and math.abs(z - f.z) < f.hz + clearance then
			return false
		end
	end
	return true
end

--- Nudges a wanted spot toward the lane centre, then along the zone, until it
--- is clear of the blockers. Returns the spot it settled on.
local function settle(footprints: { Footprint }, x: number, z: number, pad: number, minZ: number, maxZ: number): (number, number)
	if isClear(footprints, x, z, pad) then
		return x, z
	end
	local side = if x < 0 then -1 else 1
	local trialX = math.abs(x)
	while trialX > 8 and not isClear(footprints, side * trialX, z, pad) do
		trialX -= 4
	end
	if isClear(footprints, side * trialX, z, pad) then
		return side * trialX, z
	end
	for shift = 8, MapConfig.SOCKET_MAX_Z_SHIFT, 8 do
		for _, dir in { 1, -1 } do
			local trialZ = math.clamp(z + dir * shift, minZ, maxZ)
			local tx = math.abs(x)
			while tx > 8 and not isClear(footprints, side * tx, trialZ, pad) do
				tx -= 4
			end
			if isClear(footprints, side * tx, trialZ, pad) then
				return side * tx, trialZ
			end
		end
	end
	return 0, z
end

--- Places the four loot sockets and the guardian post of every zone.
-- Runs AFTER landmarks so a socket can never end up buried inside a pyramid or
-- pressed against a wall. Each zone's layout comes from MapLandmarks.layouts -
-- composed against its own landmark - and falls back to the symmetric grid
-- for a zone that has none.
local function placeSockets(map: Instance)
	local zones = map.Zones
	local pad = MapConfig.SOCKET_CLEARANCE
	local S = MapConfig.LANDMARK_SCALE

	for i, def in MapConfig.ZONES do
		local zone = zones:FindFirstChild(def.id)
		if not zone then
			continue
		end

		local startZ = MapConfig.zoneStartZ(i)
		local length = MapConfig.zoneLength(i)
		local centerZ = MapConfig.zoneCenterZ(i)
		local sockets = zone.SpawnSockets
		local guards = zone.GuardianSpawns
		sockets:ClearAllChildren()
		guards:ClearAllChildren()

		local footprints = blockerFootprints(zone)
		local minZ, maxZ = startZ + 14, startZ + length - 14
		local layout = MapLandmarks.layouts[i]

		local wanted: { Vector2 } = {}
		if layout then
			for _, offset in layout.sockets do
				table.insert(wanted, Vector2.new(offset.X * S, centerZ + offset.Y * S))
			end
		else
			local maxX = MapConfig.LANE_WIDTH * MapConfig.SOCKET_INSET_X
			for _, frac in MapConfig.SOCKET_ROW_FRACTIONS do
				for _, sign in { -1, 1 } do
					table.insert(wanted, Vector2.new(sign * maxX, startZ + length * frac))
				end
			end
		end

		local placed: { Footprint } = {}
		for n, spot in wanted do
			local x, z = settle(footprints, spot.X, math.clamp(spot.Y, minZ, maxZ), pad, minZ, maxZ)
			-- Never on top of a socket already placed in this zone.
			local tries = 0
			while not isClear(placed, x, z, 12) and tries < 6 do
				z = math.clamp(z + 14, minZ, maxZ)
				tries += 1
			end
			makeSocket(string.format("Socket%02d", n), CFrame.new(x, 0.3, z), sockets)
			table.insert(placed, { x = x, z = z, hx = 10, hz = 10 })
			-- Themed props BESIDE the plinth, so the loot reads as part of the
			-- zone rather than dropped on a lawn. After settling on purpose:
			-- anything placed before this would have pushed the socket away.
			MapLandmarks.dressSocket(i, zone:FindFirstChild("Decorations"), Vector3.new(x, 0, z))
		end

		-- ONE guardian per zone, resting where its layout puts it. Validated
		-- against the scenery and the sockets it guards.
		local restX, restZ = 0, startZ + length * 0.5
		if layout then
			restX, restZ = layout.post.X * S, centerZ + layout.post.Y * S
		end
		local blockers = table.clone(footprints)
		for _, f in placed do
			table.insert(blockers, f)
		end
		if not isClear(blockers, restX, restZ, 8) then
			local found = false
			for _, dx in { 0, 26, -26, 52, -52 } do
				for _, dz in { 0, 22, -22, 44, -44 } do
					if not found and isClear(blockers, restX + dx, restZ + dz, 8) then
						restX, restZ = restX + dx, restZ + dz
						found = true
					end
				end
			end
		end
		makeGuardianPost(CFrame.new(restX, 0.3, math.clamp(restZ, minZ, maxZ)), guards)
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

	-- Plot floor sits 0.15 studs PROUD OF THE PLAZA. That gap is not styling:
	-- the plaza slab runs underneath every plot, and while both tops sat at
	-- Y = 0 the two surfaces z-fought across the whole footprint. 0.15 is well
	-- under a humanoid step, so the plot is still one continuous walk.
	local surface = MapPalette.PlotFloor
	local floorGroup = folder("PlotFloor", base)
	makePart({
		name = "Slab",
		size = Vector3.new(layout.width, 1.2, layout.depth),
		cframe = at(0, -0.45, 0),
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
					cframe = at(-halfW + cw * (col - 0.5), -0.33, -halfD + cd * (row - 0.5)),
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

	-- THE PORCH: a paved strip across the front carrying the spawn, the
	-- upgrade pad and the signs, and a path from it back between the ranks.
	local porch = MapConfig.PORCH_DEPTH
	local paving = folder("Paving", base)
	makePaving("Porch", Vector3.new(layout.width - 6, 0.3, porch), at(0, 0.15, -halfD + porch / 2 + 2), paving)
	-- Aisles run back from the porch BETWEEN the ranks of pads, not under them:
	-- with three ranks a single central path would have been buried by the
	-- middle rank. One aisle per boundary, so the walk to any pad is paved.
	local pathLength = layout.depth - porch - 8
	local aisles = if layout.depth >= layout.width then MapConfig.DISPLAY_SLOT_COLS - 1 else 1
	for i = 1, aisles do
		local offset = if aisles == 1 then 0 else -layout.width / 2 + layout.width * i / MapConfig.DISPLAY_SLOT_COLS
		makePaving("Path", Vector3.new(6, 0.3, pathLength), at(offset, 0.15, -halfD + porch + 2 + pathLength / 2), paving)
	end

	-- Post-and-two-rail fence on the three enclosed sides, in the reference's
	-- dark-post / white-rail language; the front stays open so players run
	-- straight out onto their treadmill and down the avenue. Non-colliding, so
	-- a player launched by a guardian can never be caught on it.
	local fence = folder("Fence", base)
	local postH, spacing = 7, 22

	local function fenceRun(fromX: number, fromZ: number, toX: number, toZ: number)
		local dx, dz = toX - fromX, toZ - fromZ
		local length = math.sqrt(dx * dx + dz * dz)
		local count = math.max(2, math.round(length / spacing) + 1)

		for i = 1, count do
			local t = (i - 1) / (count - 1)
			makePart({
				name = "Post",
				size = Vector3.new(1.8, postH, 1.8),
				cframe = at(fromX + dx * t, postH / 2, fromZ + dz * t),
				color = MapPalette.PlotBorder,
				parent = fence,
				canCollide = false,
				castShadow = false,
			})
		end

		local horizontal = math.abs(dx) > math.abs(dz)
		for _, railY in { 5.4, 3.0 } do
			makePart({
				name = "Rail",
				size = Vector3.new(if horizontal then length else 0.8, 0.8, if horizontal then 0.8 else length),
				cframe = at((fromX + toX) / 2, railY, (fromZ + toZ) / 2),
				color = MapPalette.FenceRail,
				parent = fence,
				canCollide = false,
				castShadow = false,
			})
		end
	end

	fenceRun(-halfW, halfD, halfW, halfD)
	fenceRun(-halfW, halfD, -halfW, -halfD)
	fenceRun(halfW, halfD, halfW, -halfD)

	-- Gate posts either side of the open front, a little taller and capped.
	for _, sign in { -1, 1 } do
		makePart({
			name = "GatePost",
			size = Vector3.new(2.4, 9, 2.4),
			cframe = at(sign * halfW, 4.5, -halfD),
			color = MapPalette.PlotBorder,
			parent = fence,
			canCollide = false,
			castShadow = false,
		})
		makePart({
			name = "GateCap",
			size = Vector3.new(3.2, 1, 3.2),
			cframe = at(sign * halfW, 9.5, -halfD),
			color = MapPalette.FenceRail,
			parent = fence,
			canCollide = false,
			castShadow = false,
		})
	end

	-- Planters in the two back corners; nothing else stands on the display
	-- floor, so the trophies stay the exhibit.
	local props = folder("Decorations", base)
	for _, sign in { -1, 1 } do
		makePlanter("Planter", at(sign * (halfW - 7), 0, halfD - 7), props)
		makeLamp("Lamp", at(sign * (halfW - 4), 0, -halfD + porch + 1), props)
	end

	-- DISPLAY SLOTS: two ranks of seven along the plot's LONG axis. On a side
	-- plot the long axis is its depth (in from the avenue); on the head plot it
	-- is its width, so the ranks run across the back of the plaza instead of
	-- piling seven pads into the few studs behind the porch.
	local slots = folder("DisplaySlots", base)
	local total = MapConfig.DISPLAY_SLOTS_PER_BASE
	local pad = MapConfig.DISPLAY_SLOT_SIZE.X
	local n = 0
	if layout.depth >= layout.width then
		-- THREE ranks down the plot, front to back. 14 does not divide by 3, so
		-- the ranks are 5/5/4 rather than a short rank of pads pushed off the
		-- floor: `perRank` is recomputed for each column from what is left.
		local cols = MapConfig.DISPLAY_SLOT_COLS
		local rankBack = halfD - MapConfig.DISPLAY_BACK_INSET
		local rankFront = -halfD + MapConfig.DISPLAY_FRONT_RESERVE
		local rankSpan = rankBack - rankFront
		-- ONE rank grid shared by every column, so the pads line up across the
		-- plot. 14 into 3 columns leaves the last column one short; that column
		-- simply stops early rather than re-spacing itself, which would have
		-- put its pads between the other columns rows.
		local ranks = math.ceil(total / cols)
		for col = 1, cols do
			local perRank = math.min(ranks, total - n)
			local localX = -halfW + layout.width * (col - 0.5) / cols
			for i = 1, perRank do
				n += 1
				local slot = makeSlotPad(
					string.format("DisplaySlot%02d", n),
					at(localX, 0.5, rankBack - rankSpan * (i - 1) / math.max(1, ranks - 1)),
					slots
				)
				slot:SetAttribute("SlotIndex", n)
			end
		end
	else
		-- The head plot is far wider than it is deep: its pads run in rows
		-- across the back of the plaza instead.
		local perRank = total // MapConfig.DISPLAY_SLOT_ROWS
		local backZ = halfD - MapConfig.DISPLAY_BACK_INSET - pad / 2
		local rowGap = pad + 6
		local usable = math.min(layout.width - 2 * MapConfig.DISPLAY_BACK_INSET - pad, MapConfig.HEAD_PLOT_RANK_SPAN)
		for row = 1, MapConfig.DISPLAY_SLOT_ROWS do
			local localZ = backZ - (row - 1) * rowGap
			for i = 1, perRank do
				n += 1
				local localX = -usable / 2 + usable * (i - 1) / (perRank - 1)
				local slot = makeSlotPad(string.format("DisplaySlot%02d", n), at(localX, 0.5, localZ), slots)
				slot:SetAttribute("SlotIndex", n)
			end
		end
	end

	-- The upgrade pad: the plinth the upgrade sign stands on, at the porch's
	-- left; the spawn beside it, facing out of the plot toward the avenue.
	local porchZ = -halfD + 12
	-- Porch furniture, left to right across a 76-stud frontage: the owner's
	-- nameplate at the corner (BaseService stands it 12 in), the upgrade pad
	-- 30 in, the spawn beside it. Any tighter and the two sign boards share
	-- the same studs.
	makePart({
		name = "BaseUpgradePad",
		size = MapConfig.PAD_SIZE,
		-- On the porch between the owner's nameplate (which BaseService stands
		-- at the front corner, 12 in from the side) and the spawn pad: the
		-- upgrade sign PlacementService raises here faces along the porch
		-- toward the spawn, so the owner reads it from where they appear, and
		-- an arriving player reads it walking down the avenue. Any closer to
		-- the corner and the two signs share the same studs.
		cframe = at(-halfW + 30, 0.5, porchZ),
		color = MapPalette.PadUpgrade,
		material = Enum.Material.SmoothPlastic,
		parent = base,
		castShadow = false,
	})

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = at(8, 0.5, porchZ)
	spawn.Anchored = true
	spawn.CanCollide = false
	spawn.Transparency = 1
	spawn.Enabled = false -- BaseService enables the plot it assigns
	spawn.Neutral = true
	spawn.Parent = base

	-- Treadmill stands in the avenue directly in front of the plot.
	--
	-- Only the INVISIBLE gameplay rig is built here. The decorative model is
	-- attached by SpeedService, which knows the player's tier - keeping this
	-- builder ignorant of progression means upgrading is a model swap against a
	-- fixed frame, and the player's standing position never moves.
	local treadmill = folder("Treadmill", base)
	local tSize = TreadmillConfig.DECK_SIZE
	local tZ = -halfD - MapConfig.TREADMILL_STANDOFF

	local deck = makePart({
		name = "Frame",
		size = tSize,
		cframe = at(0, tSize.Y / 2, tZ),
		color = MapPalette.Treadmill,
		parent = treadmill,
	})
	deck.Transparency = 1

	local belt = makePart({
		name = "Belt",
		size = Vector3.new(tSize.X - 4, 0.4, tSize.Z - 3),
		cframe = at(0, tSize.Y + 0.05, tZ),
		color = MapPalette.TreadmillBelt,
		parent = treadmill,
		canCollide = false,
	})
	belt.Transparency = 1

	makeVolume(
		"TrainingTrigger",
		TreadmillConfig.TRIGGER_SIZE,
		at(0, TreadmillConfig.TRIGGER_SIZE.Y / 2, tZ),
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
	local hub = MapConfig.HUB

	local s = Instance.new("SpawnLocation")
	s.Name = "LobbySpawn"
	s.Size = Vector3.new(24, 1, 24)
	-- On the hub's paved circle, FACING THE GATE: the first thing a new player
	-- sees is the red line, the Zone 01 sign and the Museum beyond it, with
	-- the booth and the stand at the edges of the view.
	s.CFrame = CFrame.lookAt(Vector3.new(hub.spawn.X, 0.7, hub.spawn.Z), Vector3.new(hub.spawn.X, 0.7, hub.spawn.Z + 40))
	s.Anchored = true
	s.CanCollide = false
	s.Transparency = 1
	s.Neutral = true
	s.Parent = spawns
end

-- ==========================================================
-- DECOR IS HOLLOW
-- ==========================================================
--
-- Every zone's scenery lives in one place: `Map.Zones.<zone>.Decorations`. That
-- container IS the categorisation, so nothing here has to guess at part names -
-- it flips collision on a folder and nothing else.
--
-- WHY: this is a game about running fast down a corridor. Catching a shoulder on
-- a decorative pillar at 120 studs/s, or watching a guardian jam on a cactus,
-- ruins the one thing the game is for. Scenery stays fully VISIBLE and stops
-- being solid.
--
-- WHAT IS DELIBERATELY NOT TOUCHED, because it is gameplay and not scenery:
--   Map.LaneFloors, Map.Zones.<zone>.Floor  the ground you run on
--   Map.Walls                               the containment the lane needs
--   Map.SafeZone                            the red line and its volumes
--   Map.Bases.*                             plot floors, treadmill decks,
--                                           training triggers, display slots
--   SpawnSockets                            already non-colliding; loot is
--                                           anchored and sits on them regardless
--
-- CanQuery is left ON. Only collision is removed, so anything that raycasts
-- against the world still sees the scenery.
function MapBuilder.applyDecorCollision(map: Instance?): number
	local target = map or workspace:FindFirstChild("Map")
	local zones = target and target:FindFirstChild("Zones")
	if not zones then
		return 0
	end

	local cleared = 0
	for _, zone in zones:GetChildren() do
		for _, name in { "Decorations", "Gate" } do
			local container = zone:FindFirstChild(name)
			if container then
				for _, part in container:GetDescendants() do
					if part:IsA("BasePart") and part.CanCollide then
						part.CanCollide = false
						cleared += 1
					end
				end
			end
		end
	end
	return cleared
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

	-- Landmarks first, then sockets, so loot spawns can be validated against the
	-- scenery that actually exists rather than against assumed clear ground.
	MapLandmarks.build(map)
	placeSockets(map)
	MapBuilder.applyDecorCollision(map)

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
