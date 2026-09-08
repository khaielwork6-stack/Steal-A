--!strict
--[[
	MapConfig
	Single source of truth for every world dimension in Steal Something.

	Coordinate convention
	---------------------
	  +Z  = forward progression (Zone 01 -> Zone 12)
	  X   = lateral (lane runs symmetric about X = 0)
	  Y   = up, all walkable floor surfaces have their TOP at Y = 0

	  Z =  0            the safe-zone boundary line (behind it = safe)
	  Z <  0            safe apron, then the base plaza
	  Z >  0            the 12-zone progression lane

	Nothing in the map generator may hardcode a dimension. Add it here.
]]

local MapConfig = {}

-- ==========================================================
-- COUNTS
-- ==========================================================
MapConfig.ZONE_COUNT = 12
-- FIVE bases. The purchased lobby is 438.5 studs wide and 174 deep; five
-- 82-wide plots stand along its back wall with room for their treadmills in
-- front. Seven do not fit without shrinking a plot below its fourteen pads.
-- Server Size in Game Settings must match (it is read-only to scripts).
MapConfig.BASE_COUNT = 5
MapConfig.SOCKETS_PER_ZONE = 4
MapConfig.DISPLAY_SLOTS_PER_BASE = 14
--- Head plot only: its pads run in rows ACROSS the back of the plaza.
MapConfig.DISPLAY_SLOT_ROWS = 2

-- ==========================================================
-- LANE (Zones 01-12)
-- ==========================================================
-- Reference zones read noticeably wider than they are deep; keep WIDTH/LENGTH
-- around 1.45 so each zone is a broad shallow band rather than a square room.
-- Gameplay compression pass: the world was correct visually but unplayable at
-- the starting Speed of 10 (~18.3 WalkSpeed). Zone dimensions are the previous
-- values x0.70; the Zone 01 -> Zone 12 escalation curve below is untouched, so
-- the whole curve simply moved down together.
-- THE TEMPLATE IS THE SOURCE OF TRUTH. Every number in this block was
-- measured off the purchased kit the owner imported, which the builder now
-- CLONES rather than approximates (ServerStorage.GameAssets.Template):
--
--   ZoneFloors/"Zone N"   one textured Part per zone. Its length along the
--                         lane is that zone's length, exactly. Widths came in
--                         between 154 and 165 studs from hand placement; the
--                         lane runs at their median, 160, so the walls run
--                         straight.
--   LobbyFloor            438.5 x 1 x 174, cloned whole, never resized.
--   WallSegment           8.56 thick, 36.94 tall plus a 2-stud grass cap,
--                         145.31 long, texture on its Left face.
--
MapConfig.LANE_WIDTH = 160 -- interior, wall face to wall face
MapConfig.TRANSITION_DEPTH = 0 -- the kit's zones abut; there are no blend strips
MapConfig.FLOOR_THICKNESS = 4 -- our own slabs (plot floors); zone floors keep the kit's

-- Each zone's length is its template floor's, to the decimal. The owner
-- authored the escalation by resizing the floors; this is that escalation.
MapConfig.ZONE_LENGTHS = {
	97.5304946899414, -- 01 Museum
	146.10552978515625, -- 02 Pirate Island
	211.0, -- 03 Castle
	236.1, -- 04 Area 51
	324.1, -- 05 North Pole
	385.1109924316406, -- 06 Ancient Egypt
	429.1, -- 07 Gym
	505.1, -- 08 Bank
	640.1, -- 09 Secret Lab
	505.1, -- 10 Grandma's House
	637.1, -- 11 Construction Site
	763.1109619140625, -- 12 Airport
}

-- Roblox clamps any Part axis at 2048 studs, so long runs are built in chunks.
MapConfig.MAX_PART_AXIS = 900

-- ==========================================================
-- CONTAINMENT WALLS
-- ==========================================================
-- The kit's wall segment, exactly. Height is the body plus its grass cap.
MapConfig.WALL_BODY_HEIGHT = 36.935028076171875
MapConfig.WALL_CAP_HEIGHT = 2
MapConfig.WALL_HEIGHT = MapConfig.WALL_BODY_HEIGHT + MapConfig.WALL_CAP_HEIGHT
MapConfig.WALL_THICKNESS = 8.560052871704102
MapConfig.WALL_SEGMENT_LENGTH = 145.3063201904297
MapConfig.WALL_CAP_OVERHANG = 0

-- ==========================================================
-- SAFE ZONE
-- ==========================================================
-- The apron between the plaza mouth and the red line IS the hub: spawn, the
-- trail booth, the event stand and the leaderboards all stand on it, so a new
-- player is never more than a few seconds from any of them or from Zone 01.
-- Compression pass 2: the apron was 64 deep with the hub furniture pushed out
-- to +-66, so a new player crossed an empty field to reach a shop. It is now
-- 52 deep with everything inside 40 studs of the spawn circle.
-- The lobby is the kit's LobbyFloor: 438.5 wide, 174 deep, one part. The
-- plots take the back 96 of that depth; the apron in front - spawn, the
-- feature wings, the treadmill row - is the rest.
MapConfig.LOBBY_WIDTH = 438.5028076171875
MapConfig.LOBBY_DEPTH = 173.99996948242188
MapConfig.SAFE_ZONE_DEPTH = 78
MapConfig.SAFE_LINE_WIDTH = 4 -- thickness of the painted boundary stripe

-- ==========================================================
-- BASE PLAZA
-- ==========================================================
-- The plaza is wider than the lane so seven plots fit without crowding the
-- central sightline. Corridor width is kept equal to LANE_WIDTH so a player
-- standing at the back of the plaza looks straight down the whole world.
-- Lobby compression: travel distance here was the worst offender, so the plaza
-- lost its empty depth rather than its usable plot area. Plots kept their room
-- by trading Z-frontage for X-depth (100 x 240 = 24k studs of floor each), and
-- the three rows per side now sit almost shoulder to shoulder.
-- The avenue between the two rows of plots. Wide enough for both sides'
-- treadmills (16 out from each plot, 12 deep) plus a clear 60-stud run down
-- the middle; the old 200 was an empty field.
-- Compression pass 2: 124 read as an airport runway from the player camera.
-- 80 is sized off what actually stands in it: a treadmill deck reaches 20
-- studs in from each plot edge, leaving a clear 40-stud street down the middle
-- (the paved avenue is 20 of that) - room for several players at full Speed.
MapConfig.PLAZA_CORRIDOR_WIDTH = 80 -- RETIRED: plots no longer face a corridor
-- Sized from what a plot has to hold: two ranks of seven display pads
-- (DISPLAY_SLOT_SIZE) with room for a Giant trophy on each, a back inset, and
-- the porch at the front for the spawn, the upgrade pad and the signs.
-- Compression pass 2: three ranks of pads instead of two ranks of seven, so
-- the same 14 displays fit in 28 fewer studs of depth and the plaza loses 56
-- studs of width. Frontage came down 8 with the porch furniture re-spaced.
-- Five plots in a row along the lobby's back wall, every one facing the lane.
-- 5 x 82 + 4 x 6 = 434 of the 438.5 available. Depth 96 holds fourteen
-- 15-stud pads in four ranks behind a 20-stud porch.
MapConfig.PLOT_DEPTH = 96 -- plot extent along its inward-facing axis
MapConfig.PLOT_WIDTH = 82 -- plot extent across its inward-facing axis
MapConfig.PLOT_GAP = 6 -- clear space between neighbouring plots
MapConfig.PLOTS_PER_SIDE = 0 -- RETIRED: see getPlotLayouts
-- The head plot spans the WHOLE back of the plaza (set in the derived section
-- below, once PLAZA_WIDTH is known). At lane width it left a 60-stud pocket of
-- bare floor in each back corner - open space nobody used and nothing filled.
-- Its pads stay grouped in the middle: see HEAD_PLOT_RANK_SPAN.
MapConfig.HEAD_PLOT_WIDTH = 0 -- RETIRED: there is no head plot in the kit's lobby
MapConfig.HEAD_PLOT_DEPTH = 0
MapConfig.HEAD_PLOT_RANK_SPAN = 232

-- Per-base furniture
-- Deliberately under the ~2-stud humanoid step height: players must be able to
-- walk straight onto the treadmill, and Base07's sits in the middle of the
-- corridor where everyone else walks past it.
MapConfig.TREADMILL_SIZE = Vector3.new(14, 1.6, 28)
MapConfig.TREADMILL_STANDOFF = 13 -- distance from plot edge out into the corridor
MapConfig.PAD_SIZE = Vector3.new(12, 1, 12)

-- Display slots run as two long ranks down the plot's deep axis, which both fits
-- the new footprint and shows a collection off better to anyone walking past.
MapConfig.DISPLAY_SLOT_SIZE = Vector3.new(15, 1, 15)
MapConfig.DISPLAY_SLOT_COLS = 4 -- ranks across the plot width
MapConfig.DISPLAY_BACK_INSET = 8 -- first slot, measured from the plot back edge
MapConfig.DISPLAY_FRONT_RESERVE = 30 -- room kept clear at the front for the porch
-- The porch: a paved strip across the plot front carrying the spawn, the
-- upgrade pad and the signs, so the entrance reads as an entrance.
MapConfig.PORCH_DEPTH = 20

-- ==========================================================
-- WALL DETAIL AND ZONE GATES
-- ==========================================================
-- Pilasters break the long containment walls into bays; a trim band runs
-- between them. A gate - two pylons and a lintel carrying the zone's name -
-- marks every zone entrance, high enough that the tallest guardian passes
-- under it and nothing ever stands in the lane.
MapConfig.WALL_PILASTER_SPACING = 82 -- RETIRED: the kit's wall carries its own detail
MapConfig.WALL_PILASTER_SIZE = Vector3.new(6, 80, 6)
MapConfig.WALL_TRIM_HEIGHT = 44
-- Under the 39-stud wall line, so the gate reads as a doorway in the wall.
MapConfig.GATE_PYLON_SIZE = Vector3.new(7, 29, 7) -- lintel top lands at 38, a stud under the wall cap
MapConfig.GATE_LINTEL_HEIGHT = 33
MapConfig.GATE_LINTEL_THICKNESS = 4
MapConfig.GATE_INSET = 6 -- pylon centre in from the wall face

MapConfig.SAFE_ZONE_HEIGHT = 60
MapConfig.SAFE_ZONE_CORRIDOR_BLEED = 50 -- how far the safe volume reaches past the plot

-- Loot socket / guardian placement, as fractions of the zone footprint. Kept in
-- config so shrinking a zone never leaves spawns at stale world coordinates.
MapConfig.SOCKET_INSET_X = 0.28 -- of LANE_WIDTH, either side of centre
MapConfig.SOCKET_ROW_FRACTIONS = { 0.25, 0.75 } -- of zone length
MapConfig.SOCKET_CLEARANCE = 18 -- studs of free space required around a socket
MapConfig.SOCKET_MIN_INSET_X = 0.12 -- how far inward a blocked socket may retreat
MapConfig.SOCKET_MAX_Z_SHIFT = 44 -- last resort: slide along the zone instead
MapConfig.GUARD_INSET_X = 0.36 -- of LANE_WIDTH
MapConfig.GUARD_ROW_OFFSET = -14 -- studs behind the socket it serves

-- ==========================================================
-- ZONES
-- ==========================================================
MapConfig.ZONES = {
	{ id = "Zone01_Museum", name = "Museum", guardian = "Cop" },
	{ id = "Zone02_Pirate", name = "Pirate Island", guardian = "PirateCaptain" },
	{ id = "Zone03_Castle", name = "Castle", guardian = "RoyalGuard" },
	{ id = "Zone04_Area51", name = "Area 51", guardian = "Agent" },
	{ id = "Zone05_NorthPole", name = "North Pole", guardian = "ElfGuard" },
	{ id = "Zone06_Egypt", name = "Ancient Egypt", guardian = "MummyGuardian" },
	{ id = "Zone07_Gym", name = "Gym", guardian = "Bodybuilder" },
	{ id = "Zone08_Bank", name = "Bank", guardian = "BankGuard" },
	{ id = "Zone09_SecretLab", name = "Secret Lab", guardian = "MadScientist" },
	{ id = "Zone10_Grandma", name = "Grandma's House", guardian = "Grandma" },
	{ id = "Zone11_Construction", name = "Construction Site", guardian = "Foreman" },
	{ id = "Zone12_Airport", name = "Airport", guardian = "AirportSecurity" },
}

-- ==========================================================
-- DERIVED GEOMETRY
-- ==========================================================
-- Landmarks were authored against a 320-wide lane. Scaling them by the width
-- ratio keeps every silhouette inside the walls after a lane resize.
MapConfig.LANDMARK_SCALE = MapConfig.LANE_WIDTH / 320

MapConfig.PLAZA_WIDTH = MapConfig.LOBBY_WIDTH
MapConfig.PLAZA_SIDE_RUN = 0
MapConfig.BASE_AREA_DEPTH = MapConfig.PLOT_DEPTH
assert(
	math.abs(MapConfig.SAFE_ZONE_DEPTH + MapConfig.BASE_AREA_DEPTH - MapConfig.LOBBY_DEPTH) < 0.01,
	"MapConfig: apron + plot depth must equal the template lobby's depth"
)

MapConfig.PLAZA_FRONT_Z = -MapConfig.SAFE_ZONE_DEPTH

-- ==========================================================
-- THE HUB (everything on the apron, in one place)
-- ==========================================================
-- Every service that stands something in the lobby reads its spot from here,
-- so the whole hub can be recomposed by editing one table. Z runs from the
-- plaza mouth (PLAZA_FRONT_Z) up to the red line at 0; X is across the lane.
--
--   spawn        centre of the apron, facing the Zone 01 gate
--   trailBooth   left of spawn, counter turned to face it
--   eventStand   right of spawn, board turned to face it
--   leaderboards flanking the gate, on the safe side, facing back at spawn
-- THESE ARE DEFAULTS, NOT THE LAYOUT. The layout lives in Studio as the
-- invisible parts under Workspace.LobbyMarkers (see LobbyLayout): move a
-- marker and its object follows at the next server start. The builder creates
-- any marker that is missing from the numbers here and never overwrites one
-- that exists.
--
-- The composition, in the kit's 438.5 x 174 lobby with the lane mouth (160
-- wide) centred on its front edge at Z = 0:
--   spawn        centre of the apron, facing the lane
--   -X wing      the feature area - Money board, trail booth, gift chest -
--                against the front wall, all facing the spawn. This is on the
--                player's RIGHT as they face the lane (facing +Z puts +X on
--                the left in Roblox).
--   +X wing      the event stand and the Speed board, likewise (player's left)
--   back wall    five plots, treadmills in a row in front of them
MapConfig.HUB = {
	spawn = Vector3.new(0, 0, -34),
	spawnPlazaDiameter = 24,
	trailBooth = CFrame.new(-146, 0, -12) * CFrame.Angles(0, math.rad(180), 0),
	-- Four studs off the shoulder wall's lobby face (Z = 0): EventStandService
	-- raycasts back from here and seats the board flat against that wall.
	eventStand = Vector3.new(128, 0, -4),
	leaderboards = {
		Money = Vector3.new(-192, 6.4, -12),
		Speed = Vector3.new(178, 6.4, -12),
	},
	avenueWidth = 20, -- RETIRED: the kit's lobby has no avenue
	giftChest = Vector3.new(-104, 0, -16),
	-- The rotating Guardian shop: the pedestal in the +X wing between the lane
	-- mouth and the Next Update board, turned to face the spawn circle.
	guardianShop = CFrame.lookAt(Vector3.new(104, 0, -24), Vector3.new(0, 0, -34)),
}
MapConfig.PLAZA_BACK_Z = MapConfig.PLAZA_FRONT_Z - MapConfig.BASE_AREA_DEPTH

--- Depth of zone `index`: its template floor's length.
function MapConfig.zoneLength(index: number): number
	return MapConfig.ZONE_LENGTHS[index]
end

-- Cumulative near-edge offsets, computed once so nothing recomputes the chain.
local zoneStarts: { number } = {}
do
	local cursor = 0
	for i = 1, MapConfig.ZONE_COUNT do
		zoneStarts[i] = cursor
		cursor += MapConfig.zoneLength(i) + MapConfig.TRANSITION_DEPTH
	end
	-- The final zone has no trailing transition strip.
	MapConfig.LANE_END_Z = cursor - MapConfig.TRANSITION_DEPTH
end

MapConfig.WORLD_LENGTH = MapConfig.LANE_END_Z - MapConfig.PLAZA_BACK_Z

-- Half-extents used constantly by the generator
MapConfig.LANE_HALF = MapConfig.LANE_WIDTH / 2
MapConfig.PLAZA_HALF = MapConfig.PLAZA_WIDTH / 2
MapConfig.CORRIDOR_HALF = MapConfig.PLAZA_CORRIDOR_WIDTH / 2

--- Z of the near edge of zone `index` (1-based).
function MapConfig.zoneStartZ(index: number): number
	return zoneStarts[index]
end

--- Z of the far edge of zone `index`.
function MapConfig.zoneEndZ(index: number): number
	return zoneStarts[index] + MapConfig.zoneLength(index)
end

--- Z of the centre of zone `index`.
function MapConfig.zoneCenterZ(index: number): number
	return zoneStarts[index] + MapConfig.zoneLength(index) / 2
end

export type PlotLayout = {
	index: number,
	name: string,
	center: Vector3,
	inward: Vector3, -- unit direction the plot faces (toward the corridor)
	width: number, -- extent across `inward`
	depth: number, -- extent along `inward`
}

--- Footprint + facing for every plot: a row of BASE_COUNT along the lobby's
--- back wall, centred, every one facing +Z toward the lane. Base01 is the
--- leftmost as the player looks from the spawn toward the back.
function MapConfig.getPlotLayouts(): { PlotLayout }
	local layouts: { PlotLayout } = {}
	local count = MapConfig.BASE_COUNT
	local pitch = MapConfig.PLOT_WIDTH + MapConfig.PLOT_GAP
	local rowWidth = count * MapConfig.PLOT_WIDTH + (count - 1) * MapConfig.PLOT_GAP
	local firstX = -rowWidth / 2 + MapConfig.PLOT_WIDTH / 2
	local centerZ = MapConfig.PLAZA_BACK_Z + MapConfig.PLOT_DEPTH / 2

	for index = 1, count do
		table.insert(layouts, {
			index = index,
			name = string.format("Base%02d", index),
			center = Vector3.new(firstX + (index - 1) * pitch, 0, centerZ),
			inward = Vector3.new(0, 0, 1),
			width = MapConfig.PLOT_WIDTH,
			depth = MapConfig.PLOT_DEPTH,
		})
	end

	return layouts
end

return MapConfig
