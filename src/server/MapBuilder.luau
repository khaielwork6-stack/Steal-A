--!strict
--[[
	MapBuilder
	Generates the entire Steal Something world as real, editable geometry under
	Workspace.Map, following the hierarchy contract in section 15 of the GDD.

	Run it from the command bar in Edit mode:
		require(game.ServerScriptService.Server.MapBuilder).build()

	It is idempotent: an existing Workspace.Map is destroyed and rebuilt, so the
	generator stays the source of truth while individual parts remain hand-editable.

	WHAT THE WORLD IS MADE OF (the template rebuild)
	  * THE KIT. The owner bought a map kit; its floor, zone floors and wall
	    segment are parked under ServerStorage.GameAssets.Template and this
	    builder CLONES them. Their sizes are the world's sizes (MapConfig
	    carries the measured numbers; the builder warns if a kit part and the
	    config ever disagree).
	  * THE LOBBY: the kit's LobbyFloor, whole - 438.5 x 174. Five plots stand
	    along its back wall, treadmills in a row in front of them; the spawn
	    circle is in the middle of the apron facing the lane; the trail booth,
	    gift chest and Money board are the feature wing on the left of the lane
	    mouth, the event stand and Speed board on the right. Every one of those
	    stands on a MARKER the owner can move in Studio (LobbyLayout).
	  * THE LANE: 160 wide, twelve zones, each floor a clone of its kit part at
	    its kit length, tinted the zone's colour. A gate at each entrance, one
	    sign on the left, an even grid of four plinths and a guardian post,
	    rain over zones 9-12 - and nothing else on the floor.
	  * THE WALLS: the kit segment tiled end to end around the lobby and down
	    both sides of the lane, textured face inward, the lobby in the kit's
	    clay and every zone's run tinted toward that zone's colour. Corners are
	    owned by one run each, so nothing overlaps and nothing is open.
	  * FUNCTIONAL PARTS ARE DRESSED, NEVER REMOVED. Sockets, guardian posts,
	    slot pads, spawn pads and trigger volumes keep their names, sizes and
	    attributes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local MapPalette = require(ReplicatedStorage.Shared.MapPalette)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local LobbyLayout = require(ReplicatedStorage.Shared.LobbyLayout)
local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)

--- The Guardian Bay's footprint, shared with BaseGuardianService so the pad
--- the builder lays and the platform the service raises on it agree.
local BAY_PAD_SIZE = BaseGuardianConfig.BAY_SIZE
local ServerStorage = game:GetService("ServerStorage")

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

-- ==========================================================
-- LANE FLOORS AND THE HUB
-- ==========================================================

-- ==========================================================
-- THE TEMPLATE KIT
-- ==========================================================
--
-- The owner bought a map kit and imported it; it is parked, by name, under
-- ServerStorage.GameAssets.Template:
--
--   LobbyFloor          one textured Part, 438.5 x 1 x 174. The lobby IS this
--                       part, cloned whole - its size is the lobby's size.
--   ZoneFloors/"Zone N" one textured Part per zone, a thick slab. Its length
--                       is that zone's length; the lane is 160 wide (their
--                       median) so the walls run straight.
--   WallSegment         a body and a grass cap, 8.56 thick, 38.9 tall,
--                       145.3 long, texture on the body's LEFT face.
--   Weather/ZoneNN      the rain / snow / dust emitter parts for zones 9-12.
--
-- Everything visual is CLONED from those. Nothing here draws a checker with
-- parts any more; the kit's 8-stud texture is the checker. Colours are the
-- one thing changed: zone floors and zone walls take their zone's identity,
-- the lobby keeps the kit's own.

local function templateKit(): Instance
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local kit = assets and assets:FindFirstChild("Template")
	assert(kit, "MapBuilder: ServerStorage.GameAssets.Template is missing - park the imported kit there")
	return kit :: Instance
end

local function zoneFloorTemplate(index: number): BasePart
	local floors = templateKit():FindFirstChild("ZoneFloors")
	local part = floors and floors:FindFirstChild("Zone " .. index)
	assert(part and part:IsA("BasePart"), `MapBuilder: Template.ZoneFloors."Zone {index}" is missing`)
	return part :: BasePart
end

local function lobbyFloorTemplate(): BasePart
	local part = templateKit():FindFirstChild("LobbyFloor")
	assert(part and part:IsA("BasePart"), "MapBuilder: Template.LobbyFloor is missing")
	return part :: BasePart
end

--- The wall kit's two parts, told apart by shape: the tall one is the body.
local function wallSegmentTemplate(): (BasePart, BasePart)
	local seg = templateKit():FindFirstChild("WallSegment")
	assert(seg, "MapBuilder: Template.WallSegment is missing")
	local body: BasePart? = nil
	local cap: BasePart? = nil
	for _, child in seg:GetChildren() do
		if child:IsA("BasePart") then
			if child.Size.Y > 10 then
				body = child
			else
				cap = child
			end
		end
	end
	assert(body and cap, "MapBuilder: Template.WallSegment needs a body part and a cap part")
	return body :: BasePart, cap :: BasePart
end

local function weatherTemplate(index: number): BasePart?
	local weather = templateKit():FindFirstChild("Weather")
	local part = weather and weather:FindFirstChild(string.format("Zone%02d", index))
	return if part and part:IsA("BasePart") then part else nil
end

--- A zone's wall colour: the kit's own clay pulled halfway toward the zone's
--- identity colour (the one its gate band and pop-up already wear). Halfway
--- keeps it reading as the same wall kit all the way down the world while
--- the hue turns with the zones; the texture is untouched.
local function zoneWallColor(index: number, kitColor: Color3): Color3
	local def = ZoneConfig.Zones[index]
	return kitColor:Lerp(def.color, 0.5)
end

--- One straight run of wall from `from` to `to`, built from clones of the
--- kit segment laid end to end, the last one cut to the remainder, with the
--- textured face turned along `inward`. `zoneIndex` tints the body; nil
--- keeps the kit's colour (the lobby).
local function tileWall(name: string, parent: Instance, from: Vector3, to: Vector3, inward: Vector3, zoneIndex: number?)
	local run = folder(name, parent)
	local body, cap = wallSegmentTemplate()
	local thickness = MapConfig.WALL_THICKNESS
	local bodyH = MapConfig.WALL_BODY_HEIGHT
	local capH = MapConfig.WALL_CAP_HEIGHT
	local segLen = MapConfig.WALL_SEGMENT_LENGTH

	local span = to - from
	local length = span.Magnitude
	if length < 0.01 then
		return run
	end
	local dir = span.Unit
	local up = Vector3.yAxis
	-- Local +X is the untextured side, so local -X (the kit's textured Left
	-- face) points inward. Local +Z, the segment's long axis, follows.
	local right = -inward
	local back = right:Cross(up)

	local tint = if zoneIndex then zoneWallColor(zoneIndex, body.Color) else body.Color
	local count = math.max(1, math.ceil(length / segLen - 0.001))
	for i = 1, count do
		local offset = (i - 1) * segLen
		local len = math.min(segLen, length - offset)
		local centre = from + dir * (offset + len / 2)
		local frame = CFrame.fromMatrix(centre + up * (bodyH / 2), right, up, back)

		local b = body:Clone()
		b.Name = "Body"
		b.Size = Vector3.new(thickness, bodyH, len)
		b.CFrame = frame
		b.Anchored = true
		b.CanCollide = true
		b.CanQuery = true
		b.CanTouch = false
		b.Color = tint
		b.Parent = run

		local c = cap:Clone()
		c.Name = "Cap"
		c.Size = Vector3.new(thickness, capH, len)
		c.CFrame = frame + up * (bodyH / 2 + capH / 2)
		c.Anchored = true
		c.CanCollide = true
		c.CanQuery = true
		c.CanTouch = false
		c.Parent = run
	end
	return run
end

local function buildLaneFloors(map: Instance)
	local floors = folder("LaneFloors", map)

	-- THE LOBBY IS THE KIT'S PART. Cloned whole and never resized: its 438.5 x
	-- 174 is what MapConfig.LOBBY_WIDTH / LOBBY_DEPTH were measured from, and
	-- if the two ever disagree the part wins on screen and the assert below
	-- says so in the output.
	local template = lobbyFloorTemplate()
	local lobby = template:Clone()
	lobby.Name = "LobbyFloor"
	lobby.Anchored = true
	lobby.CanCollide = true
	lobby.CanQuery = true
	lobby.CFrame = CFrame.new(0, -lobby.Size.Y / 2, MapConfig.PLAZA_BACK_Z + MapConfig.LOBBY_DEPTH / 2)
	lobby.Parent = floors
	if math.abs(lobby.Size.X - MapConfig.LOBBY_WIDTH) > 0.05 or math.abs(lobby.Size.Z - MapConfig.LOBBY_DEPTH) > 0.05 then
		warn(string.format(
			"[MapBuilder] Template.LobbyFloor is %.1f x %.1f but MapConfig says %.1f x %.1f - update MapConfig.LOBBY_*",
			lobby.Size.X, lobby.Size.Z, MapConfig.LOBBY_WIDTH, MapConfig.LOBBY_DEPTH
		))
	end

	-- The spawn circle, under the Spawn marker. The one piece of paving left:
	-- it tells a new player where they are standing and which way is forward.
	local hub = MapConfig.HUB
	local spawnAt = LobbyLayout.position("Spawn", hub.spawn)
	local paving = folder("Paving", map)
	local diameter = hub.spawnPlazaDiameter
	makePaving("SpawnPlazaEdge", Vector3.new(0.4, diameter + 4, diameter + 4), CFrame.new(spawnAt.X, 0.2, spawnAt.Z) * CFrame.Angles(0, 0, math.rad(90)), paving, Enum.PartType.Cylinder).Color =
		MapPalette.PavingEdge
	makePaving("SpawnPlaza", Vector3.new(0.6, diameter, diameter), CFrame.new(spawnAt.X, 0.3, spawnAt.Z) * CFrame.Angles(0, 0, math.rad(90)), paving, Enum.PartType.Cylinder)
end

-- ==========================================================
-- WALLS
-- ==========================================================

local function buildWalls(map: Instance)
	local walls = folder("Walls", map)
	local t = MapConfig.WALL_THICKNESS
	local half = MapConfig.LANE_HALF
	local lobbyHalf = MapConfig.PLAZA_HALF
	local backZ = MapConfig.PLAZA_BACK_Z
	local endZ = MapConfig.LANE_END_Z

	-- CORNERS ARE OWNED, NOT OVERLAPPED. Every corner block of wall belongs to
	-- exactly one run, and the run meeting it stops flush against its face -
	-- so no two segments share a plane anywhere (no z-fighting at the tops or
	-- the caps) and no corner is open.
	--
	-- Lane sides, one run per zone so each takes its zone's colour, and the
	-- segment boundaries fall on the zone boundaries.
	for i = 1, MapConfig.ZONE_COUNT do
		local z0 = MapConfig.zoneStartZ(i)
		local z1 = MapConfig.zoneEndZ(i)
		for _, sign in { -1, 1 } do
			local x = sign * (half + t / 2)
			tileWall(
				string.format("Zone%02d_%s", i, if sign < 0 then "Left" else "Right"),
				walls,
				Vector3.new(x, 0, z0),
				Vector3.new(x, 0, z1),
				Vector3.new(-sign, 0, 0),
				i
			)
		end
	end
	-- The end of the world, across the lane, owning both far corners.
	tileWall("WorldEnd", walls, Vector3.new(-(half + t), 0, endZ + t / 2), Vector3.new(half + t, 0, endZ + t / 2), Vector3.new(0, 0, -1), MapConfig.ZONE_COUNT)

	-- The lobby, in the kit's own colour. The back wall owns the two back
	-- corners; the shoulders own the two front corners and stop flush against
	-- the lane walls' outer faces.
	tileWall("LobbyBack", walls, Vector3.new(-(lobbyHalf + t), 0, backZ - t / 2), Vector3.new(lobbyHalf + t, 0, backZ - t / 2), Vector3.new(0, 0, 1))
	for _, sign in { -1, 1 } do
		local side = if sign < 0 then "Left" else "Right"
		local x = sign * (lobbyHalf + t / 2)
		tileWall("Lobby" .. side, walls, Vector3.new(x, 0, backZ), Vector3.new(x, 0, 0), Vector3.new(-sign, 0, 0))
		tileWall(
			"Shoulder" .. side,
			walls,
			Vector3.new(sign * (half + t), 0, t / 2),
			Vector3.new(sign * (lobbyHalf + t), 0, t / 2),
			Vector3.new(0, 0, -1)
		)
	end
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

		-- THE KIT FLOOR. Its length is the zone's length (that is where
		-- MapConfig.ZONE_LENGTHS came from); its width is set to the lane's
		-- 160 so the walls run straight; its thickness, texture and material
		-- are the kit's. Only the colour is ours: the zone's own light tone,
		-- which the kit's 8-stud checker overlay darkens on alternate tiles.
		local template = zoneFloorTemplate(i)
		local floor = template:Clone()
		floor.Name = "Floor"
		floor.Size = Vector3.new(MapConfig.LANE_WIDTH, template.Size.Y, length)
		floor.CFrame = CFrame.new(0, -template.Size.Y / 2, centerZ)
		floor.Anchored = true
		floor.CanCollide = true
		floor.CanQuery = true
		floor.Color = surface.a
		floor.Parent = zone
		if math.abs(math.max(template.Size.X, template.Size.Z) - length) > 0.05 then
			warn(string.format("[MapBuilder] Template.ZoneFloors.\"Zone %d\" is %.1f long but MapConfig.ZONE_LENGTHS says %.1f", i, math.max(template.Size.X, template.Size.Z), length))
		end

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

	end
end

-- ==========================================================
-- WEATHER
-- ==========================================================

--- Rain over the zones the kit supplied it for. The emitter is the kit's own
--- part stretched to the zone: its emitters are Box/Volume shaped, so the
--- part's footprint IS the emission area, and a 160 x length part rains on
--- the whole zone and nowhere else. Rate is scaled with the area up to a cap,
--- so a big zone is not a drizzle but a phone is not asked to draw a storm.
local WEATHER_HEIGHT = 30
-- 6x the kit's authored rate is about 1,000 particles a second over the
-- biggest zone: reads as weather from the ground, and a phone still draws it.
-- 12x looked better and cost 2,100/s in Zone 9 alone.
local WEATHER_RATE_CAP = 6

local function buildWeather(map: Instance)
	local zones = map:FindFirstChild("Zones")
	if not zones then
		return
	end
	for i, def in MapConfig.ZONES do
		local template = weatherTemplate(i)
		local zone = zones:FindFirstChild(def.id)
		if not template or not zone then
			continue
		end
		local length = MapConfig.zoneLength(i)
		local weather = template:Clone()
		weather.Name = "Weather"
		weather.Size = Vector3.new(MapConfig.LANE_WIDTH, template.Size.Y, length)
		weather.CFrame = CFrame.new(0, WEATHER_HEIGHT, MapConfig.zoneCenterZ(i))
		weather.Anchored = true
		weather.CanCollide = false
		weather.CanQuery = false
		weather.CanTouch = false
		weather.CastShadow = false
		weather.Transparency = 1
		local factor = math.clamp((MapConfig.LANE_WIDTH * length) / (template.Size.X * template.Size.Z), 1, WEATHER_RATE_CAP)
		for _, d in weather:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				d.Rate = d.Rate * factor
				d.Enabled = true
			end
		end
		weather.Parent = zone
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
-- pressed against a wall. Each zone's layout is the even grid below -
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
		-- No landmarks any more (the kit's zones are open floor), so no
		-- authored layout: the even grid below is the layout.
		local layout = nil

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
	-- The plot floor is a piece of the SAME kit floor as the lobby - same
	-- texture, same 8-stud checker - one step lighter so ownership reads,
	-- named Slab because BaseService measures the plot from it.
	local floorGroup = folder("PlotFloor", base)
	local slab = lobbyFloorTemplate():Clone()
	slab.Name = "Slab"
	slab.Size = Vector3.new(layout.width, 1.2, layout.depth)
	slab.CFrame = at(0, -0.45, 0)
	slab.Anchored = true
	slab.CanCollide = true
	slab.CanQuery = true
	slab.Color = MapPalette.PlotFloor.a
	slab.Parent = floorGroup

	-- THE PORCH: a paved strip across the front carrying the spawn, the
	-- upgrade pad and the signs, and a path from it back between the ranks.
	local porch = MapConfig.PORCH_DEPTH
	local paving = folder("Paving", base)
	makePaving("Porch", Vector3.new(layout.width - 6, 0.3, porch), at(0, 0.15, -halfD + porch / 2 + 2), paving)

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

	-- DISPLAY SLOTS: two ranks of seven along the plot's LONG axis. On a side
	-- plot the long axis is its depth (in from the avenue); on the head plot it
	-- is its width, so the ranks run across the back of the plaza instead of
	-- piling seven pads into the few studs behind the porch.
	local slots = folder("DisplaySlots", base)
	local total = MapConfig.DISPLAY_SLOTS_PER_BASE
	local pad = MapConfig.DISPLAY_SLOT_SIZE.X
	local n = 0
	if layout.depth >= layout.width then
		-- FOUR ranks of four, filled FRONT TO BACK, left to right. 14 pads in a
		-- 16-cell grid leaves two cells empty, and filling from the front puts
		-- both of them in the BACK rank, side by side at the corner: that strip
		-- is the Guardian Bay (BaseGuardianService builds it on the pad below).
		-- Slot 1 is the front-left pad, nearest the porch, so a new player's
		-- first trophy lands where they can see it from the spawn.
		local cols = MapConfig.DISPLAY_SLOT_COLS
		local rankBack = halfD - MapConfig.DISPLAY_BACK_INSET
		local rankFront = -halfD + MapConfig.DISPLAY_FRONT_RESERVE
		local rankSpan = rankBack - rankFront
		local ranks = math.ceil(total / cols)
		local function rankZ(rank: number): number
			return rankFront + rankSpan * (rank - 1) / math.max(1, ranks - 1)
		end
		local function colX(col: number): number
			return -halfW + layout.width * (col - 0.5) / cols
		end
		for rank = 1, ranks do
			for col = 1, cols do
				if n >= total then
					break
				end
				n += 1
				local slot = makeSlotPad(string.format("DisplaySlot%02d", n), at(colX(col), 0.5, rankZ(rank)), slots)
				slot:SetAttribute("SlotIndex", n)
			end
		end

		-- THE GUARDIAN BAY PAD: the anchor for the bay, centred on the empty
		-- cells of the back rank. An invisible marker like BaseUpgradePad; the
		-- platform, pillars and label are built on it at runtime so the look
		-- can change without a map rebuild. `BayFacing` is the plot's front.
		local emptyCells = ranks * cols - total
		if emptyCells > 0 then
			local firstEmptyCol = cols - emptyCells + 1
			local bayX = (colX(firstEmptyCol) + colX(cols)) / 2
			local bay = makePart({
				name = "GuardianBayPad",
				size = Vector3.new(BAY_PAD_SIZE, 1, BAY_PAD_SIZE),
				cframe = at(bayX, 0.5, rankZ(ranks)),
				color = MapPalette.PadUpgrade,
				material = Enum.Material.SmoothPlastic,
				parent = base,
				canCollide = false,
				castShadow = false,
			})
			bay.Transparency = 1
			bay.CanQuery = false
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

	-- The upgrade pad: the plinth the upgrade sign stands on, at the OUTER
	-- FRONT CORNER of the plot, just inside the gate post, facing the plot's
	-- centre. Out of the porch, off the treadmill line, clear of every pad
	-- and of the bay at the back; PlacementService turns the sign it raises
	-- here toward the slab's centre, so the owner reads it from the porch and
	-- from inside the base alike. The spawn keeps its place on the porch.
	local porchZ = -halfD + 12
	makePart({
		name = "BaseUpgradePad",
		size = MapConfig.PAD_SIZE,
		cframe = at(-halfW + 9, 0.5, -halfD + 7),
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
	-- Where the Spawn MARKER is, facing the way it faces (Workspace.LobbyMarkers
	-- .Spawn - move it in Studio and this follows). The default faces the lane.
	local marker = LobbyLayout.frame("Spawn", CFrame.lookAt(hub.spawn, hub.spawn + Vector3.new(0, 0, 40)))
	local look = marker.LookVector
	local flatLook = if Vector3.new(look.X, 0, look.Z).Magnitude > 0.01 then Vector3.new(look.X, 0, look.Z).Unit else Vector3.zAxis
	local at = Vector3.new(marker.Position.X, 0.7, marker.Position.Z)
	s.CFrame = CFrame.lookAt(at, at + flatLook * 40)
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

	-- The owner's placements, outside the map so this rebuild never touches
	-- them. Created from MapConfig.HUB only where missing.
	LobbyLayout.ensureMarkers()

	local map = folder("Map", workspace)

	buildLaneFloors(map)
	buildZones(map)
	buildWeather(map)
	buildWalls(map)
	buildSafeZone(map)
	buildBases(map)
	buildSpawns(map)

	-- No landmarks and no dressing: the kit's zones are open floor with the
	-- loot, the guardian, the gate and the sign on it, which is the brief.
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
