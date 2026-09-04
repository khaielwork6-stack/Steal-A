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
MapConfig.DISPLAY_SLOT_ROWS = 2

-- ==========================================================
-- LANE (Zones 01-12)
-- ==========================================================
-- Reference zones read noticeably wider than they are deep; keep WIDTH/LENGTH
-- around 1.45 so each zone is a broad shallow band rather than a square room.
MapConfig.LANE_WIDTH = 320 -- interior, wall face to wall face
MapConfig.ZONE_LENGTH = 220 -- depth of Zone 01; every later zone scales off this
MapConfig.TRANSITION_DEPTH = 40 -- blend strip between two zones
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
MapConfig.SAFE_ZONE_DEPTH = 220 -- open apron between plaza mouth and the line
MapConfig.SAFE_LINE_WIDTH = 4 -- thickness of the painted boundary stripe

-- ==========================================================
-- BASE PLAZA
-- ==========================================================
-- The plaza is wider than the lane so seven plots fit without crowding the
-- central sightline. Corridor width is kept equal to LANE_WIDTH so a player
-- standing at the back of the plaza looks straight down the whole world.
MapConfig.PLAZA_CORRIDOR_WIDTH = 320
MapConfig.PLOT_DEPTH = 170 -- plot extent along its inward-facing axis
MapConfig.PLOT_WIDTH = 220 -- plot extent across its inward-facing axis
MapConfig.PLOT_GAP = 30 -- clear space between neighbouring side plots
MapConfig.PLOTS_PER_SIDE = 3 -- 3 left + 3 right + 1 head = 7
MapConfig.HEAD_PLOT_WIDTH = 320
MapConfig.HEAD_PLOT_DEPTH = 170

-- Per-base furniture
MapConfig.TREADMILL_SIZE = Vector3.new(16, 3, 34)
MapConfig.TREADMILL_STANDOFF = 30 -- distance from plot edge out into the corridor
MapConfig.PAD_SIZE = Vector3.new(14, 1, 14)
MapConfig.DISPLAY_SLOT_SIZE = Vector3.new(22, 1, 22)
MapConfig.DISPLAY_ROW_BACK_INSET = 35 -- first row, measured from plot back edge
MapConfig.DISPLAY_ROW_PITCH = 60 -- gap between the two display rows
MapConfig.SAFE_ZONE_HEIGHT = 60
MapConfig.SAFE_ZONE_CORRIDOR_BLEED = 70 -- how far the safe volume reaches past the plot

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
MapConfig.PLAZA_WIDTH = MapConfig.PLAZA_CORRIDOR_WIDTH + 2 * MapConfig.PLOT_DEPTH

MapConfig.PLAZA_SIDE_RUN = MapConfig.PLOTS_PER_SIDE * MapConfig.PLOT_WIDTH
	+ (MapConfig.PLOTS_PER_SIDE - 1) * MapConfig.PLOT_GAP

MapConfig.BASE_AREA_DEPTH = MapConfig.PLAZA_SIDE_RUN + MapConfig.HEAD_PLOT_DEPTH

MapConfig.PLAZA_FRONT_Z = -MapConfig.SAFE_ZONE_DEPTH
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
