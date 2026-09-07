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
MapConfig.BASE_COUNT = 7
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
MapConfig.LANE_WIDTH = 256 -- interior, wall face to wall face
MapConfig.ZONE_LENGTH = 154 -- depth of Zone 01; every later zone scales off this
MapConfig.TRANSITION_DEPTH = 28 -- blend strip between two zones
MapConfig.FLOOR_THICKNESS = 4

-- Progression escalation: each zone is slightly longer than the last so late-game
-- Speed has room to matter and chases get more dramatic. Zone 01 is LOCKED at 1.0.
-- Lane WIDTH deliberately stays constant so the world keeps its clean corridor read.
MapConfig.ZONE_LENGTH_SCALE = {
	1.00, -- 01 Museum (locked, beginner-sized)
	1.10, -- 02 Pirate Island
	1.15, -- 03 Castle
	1.20, -- 04 Area 51
	1.25, -- 05 North Pole
	1.30, -- 06 Ancient Egypt
	1.35, -- 07 Gym
	1.40, -- 08 Bank
	1.45, -- 09 Secret Lab
	1.50, -- 10 Grandma's House
	1.55, -- 11 Construction Site
	1.60, -- 12 Airport
}

-- Roblox clamps any Part axis at 2048 studs, so long runs are built in chunks.
MapConfig.MAX_PART_AXIS = 900

-- ==========================================================
-- CONTAINMENT WALLS
-- ==========================================================
MapConfig.WALL_HEIGHT = 80
MapConfig.WALL_THICKNESS = 10
MapConfig.WALL_CAP_HEIGHT = 8
MapConfig.WALL_CAP_OVERHANG = 2

-- ==========================================================
-- SAFE ZONE
-- ==========================================================
-- The apron between the plaza mouth and the red line IS the hub: spawn, the
-- trail booth, the event stand and the leaderboards all stand on it, so a new
-- player is never more than a few seconds from any of them or from Zone 01.
-- Compression pass 2: the apron was 64 deep with the hub furniture pushed out
-- to +-66, so a new player crossed an empty field to reach a shop. It is now
-- 52 deep with everything inside 40 studs of the spawn circle.
MapConfig.SAFE_ZONE_DEPTH = 52
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
MapConfig.PLAZA_CORRIDOR_WIDTH = 80
-- Sized from what a plot has to hold: two ranks of seven display pads
-- (DISPLAY_SLOT_SIZE) with room for a Giant trophy on each, a back inset, and
-- the porch at the front for the spawn, the upgrade pad and the signs.
-- Compression pass 2: three ranks of pads instead of two ranks of seven, so
-- the same 14 displays fit in 28 fewer studs of depth and the plaza loses 56
-- studs of width. Frontage came down 8 with the porch furniture re-spaced.
MapConfig.PLOT_DEPTH = 148 -- plot extent along its inward-facing axis
MapConfig.PLOT_WIDTH = 76 -- plot extent across its inward-facing axis
MapConfig.PLOT_GAP = 4 -- clear space between neighbouring side plots
MapConfig.PLOTS_PER_SIDE = 3 -- 3 left + 3 right + 1 head = 7
-- The head plot spans the WHOLE back of the plaza (set in the derived section
-- below, once PLAZA_WIDTH is known). At lane width it left a 60-stud pocket of
-- bare floor in each back corner - open space nobody used and nothing filled.
-- Its pads stay grouped in the middle: see HEAD_PLOT_RANK_SPAN.
MapConfig.HEAD_PLOT_WIDTH = 256 -- overwritten below; kept for readability
MapConfig.HEAD_PLOT_DEPTH = 84
--- How wide the head plot spreads its two rows of pads, whatever its floor is.
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
MapConfig.DISPLAY_SLOT_SIZE = Vector3.new(17, 1, 17)
MapConfig.DISPLAY_SLOT_COLS = 3 -- ranks across the plot width
MapConfig.DISPLAY_BACK_INSET = 14 -- first slot, measured from the plot back edge
MapConfig.DISPLAY_FRONT_RESERVE = 40 -- room kept clear at the front for the porch
-- The porch: a paved strip across the plot front carrying the spawn, the
-- upgrade pad and the signs, so the entrance reads as an entrance.
MapConfig.PORCH_DEPTH = 22

-- ==========================================================
-- WALL DETAIL AND ZONE GATES
-- ==========================================================
-- Pilasters break the long containment walls into bays; a trim band runs
-- between them. A gate - two pylons and a lintel carrying the zone's name -
-- marks every zone entrance, high enough that the tallest guardian passes
-- under it and nothing ever stands in the lane.
MapConfig.WALL_PILASTER_SPACING = 82
MapConfig.WALL_PILASTER_SIZE = Vector3.new(6, 80, 6)
MapConfig.WALL_TRIM_HEIGHT = 44
MapConfig.GATE_PYLON_SIZE = Vector3.new(9, 48, 9)
MapConfig.GATE_LINTEL_HEIGHT = 52
MapConfig.GATE_LINTEL_THICKNESS = 5
MapConfig.GATE_INSET = 10 -- pylon centre in from the wall face

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

MapConfig.PLAZA_WIDTH = MapConfig.PLAZA_CORRIDOR_WIDTH + 2 * MapConfig.PLOT_DEPTH
MapConfig.HEAD_PLOT_WIDTH = MapConfig.PLAZA_WIDTH

MapConfig.PLAZA_SIDE_RUN = MapConfig.PLOTS_PER_SIDE * MapConfig.PLOT_WIDTH
	+ (MapConfig.PLOTS_PER_SIDE - 1) * MapConfig.PLOT_GAP

MapConfig.BASE_AREA_DEPTH = MapConfig.PLAZA_SIDE_RUN + MapConfig.HEAD_PLOT_DEPTH

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
MapConfig.HUB = {
	spawn = Vector3.new(0, 0, -26),
	spawnPlazaDiameter = 26,
	trailBooth = CFrame.new(-38, 0, -32) * CFrame.Angles(0, math.rad(90), 0),
	eventStand = Vector3.new(38, 0, -32),
	leaderboards = {
		Money = Vector3.new(-44, 6.4, -10),
		Speed = Vector3.new(44, 6.4, -10),
	},
	-- The paved avenue from the spawn plaza back through the corridor. 20 is
	-- five avatars abreast: a street, not the runway 26 read as.
	avenueWidth = 20,
	-- The free-gift chest: front-left of the spawn circle, inside the first
	-- thing a player sees, clear of the avenue and of both leaderboards.
	giftChest = Vector3.new(-19, 0, -13),
}
MapConfig.PLAZA_BACK_Z = MapConfig.PLAZA_FRONT_Z - MapConfig.BASE_AREA_DEPTH

--- Depth of zone `index`, escalating with progression.
function MapConfig.zoneLength(index: number): number
	return MapConfig.ZONE_LENGTH * MapConfig.ZONE_LENGTH_SCALE[index]
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

--- Footprint + facing for every one of the seven plots.
-- Sides alternate left/right front-to-back; Base07 caps the head of the plaza.
function MapConfig.getPlotLayouts(): { PlotLayout }
	local layouts: { PlotLayout } = {}

	local sideCenterX = MapConfig.CORRIDOR_HALF + MapConfig.PLOT_DEPTH / 2

	for row = 1, MapConfig.PLOTS_PER_SIDE do
		local centerZ = MapConfig.PLAZA_FRONT_Z
			- (row - 1) * (MapConfig.PLOT_WIDTH + MapConfig.PLOT_GAP)
			- MapConfig.PLOT_WIDTH / 2

		for side = 0, 1 do
			local sign = if side == 0 then -1 else 1
			local index = (row - 1) * 2 + side + 1

			table.insert(layouts, {
				index = index,
				name = string.format("Base%02d", index),
				center = Vector3.new(sign * sideCenterX, 0, centerZ),
				inward = Vector3.new(-sign, 0, 0),
				width = MapConfig.PLOT_WIDTH,
				depth = MapConfig.PLOT_DEPTH,
			})
		end
	end

	-- Head plot closes the back of the plaza and faces straight down the world.
	table.insert(layouts, {
		index = MapConfig.BASE_COUNT,
		name = string.format("Base%02d", MapConfig.BASE_COUNT),
		center = Vector3.new(0, 0, MapConfig.PLAZA_BACK_Z + MapConfig.HEAD_PLOT_DEPTH / 2),
		inward = Vector3.new(0, 0, 1),
		width = MapConfig.HEAD_PLOT_WIDTH,
		depth = MapConfig.HEAD_PLOT_DEPTH,
	})

	return layouts
end

return MapConfig
