--!strict
--[[
	LaserConfig (lasers-rework, 2026-09-20)
	Every tuning number of the museum room lasers: what a touch does (the
	knock-back toward the door), how hard each zone's pattern is, and the
	character model the fairness validator walks through a generated room.

	Pure data and arithmetic - no requires, no Roblox types - so
	shared/LaserPatterns (the generator and validator that read this) can be
	run outside Studio as well.

	NOT PART OF THE ZONE 8+ PROGRESSION WALL. Nothing here touches treadmill
	output, Speed gates, income or loot weights; it only lays beams out.
]]

local LaserConfig = {}

-- ==========================================================
-- THE BODY THE SERVER TESTS (LaserService silhouettes)
-- ==========================================================

LaserConfig.BODY = {
	--- Standing silhouette height, feet to head.
	STAND_HEIGHT = 5.2,
	--- Crouched silhouette height.
	CROUCH_HEIGHT = 2.6,
	--- Half the silhouette's width and depth.
	HALF_WIDTH = 1.1,
}

-- ==========================================================
-- THE TOUCH: KNOCKED BACK OUT OF THE DOOR
-- ==========================================================
--
-- A touch no longer wakes anybody. The player is ragdolled and thrown in an
-- arc AT THE ROOM'S DOORWAY (LaserService.exitAim), lands in the corridor,
-- lies there for GROUND_STUN and may walk straight back in. There is no
-- cooldown: whoever is standing in a beam when they get up is thrown again.

LaserConfig.KNOCKBACK = {
	--- Upward launch speed (studs/s). 30 lifts the body ~7 studs: a low arc
	--- like the reference video, far below any doorway header (24+).
	LIFT = 30,
	--- The horizontal speed is (distance to the landing point) / this. It is
	--- the measured-by-arithmetic airtime of the arc above: 0.2 s of push
	--- (RagdollService) plus the fall. Raise it and every throw gets shorter.
	FLIGHT_SECONDS = 0.6,
	--- Horizontal speed clamp (studs/s). The far corner of a 140-stud room is
	--- ~75 studs from its landing point; a guard's catch throws at 216.
	MIN_SPEED = 45,
	MAX_SPEED = 135,
	--- The landing point is this far past the doorway line, in the corridor
	--- (which is 44 studs across, so well short of the facing room).
	OVERSHOOT = 9,
	--- ...measured straight out from the doorway line. A throw that leaves the
	--- door at a shallow angle travels further past the line to get that
	--- deep, but never more than this (studs along its own path).
	OVERSHOOT_MAX = 30,
	--- The arc crosses the doorway line at least this far inside the jambs.
	DOOR_MARGIN = 5,
	--- Minimum airborne time before a landing is looked for.
	STUN = 0.35,
	--- Seconds on the floor after landing, then they stand up.
	GROUND_STUN = 1,
	--- Immunity granted AT the launch. Only long enough that the same beam
	--- cannot hit twice while the body is still leaving it; RagdollService
	--- extends it over the landing by itself, and LaserService skips anyone
	--- it has on record as ragdolled (RagdollService.isRagdolled).
	IMMUNITY = 0.4,
	--- The zap: how long the LaserAlarm cue rings at the touch (it used to
	--- ring AudioConfig.ALARM_SECONDS as a room alarm).
	ZAP_SECONDS = 1.1,
	--- A floor under how often one player can be processed as "hit", for the
	--- case where the launch itself is refused (a dead body): it stops a
	--- 10 Hz stream of zaps and attribute writes. Not a gameplay cooldown - a
	--- launched player is skipped for the whole flight anyway.
	RETRIGGER_GUARD = 0.25,
}

-- ==========================================================
-- THE FIELD: WHERE BEAMS MAY BE (room-local studs)
-- ==========================================================
--
-- Room-local frame, as MuseumLayout.frame: x across the room (0 = the middle
-- of the doorway), z into the room (0 = the doorway line), y up.

LaserConfig.FIELD = {
	--- First and last z a beam may touch. In front of it is the doorway apron
	--- (kept clear so nobody is hit walking in, and so a thrown body has
	--- somewhere to land short); behind it is the strip in front of the
	--- display cases where a thief stands to take a container.
	Z_MIN = 9,
	Z_MAX = 33,
	--- A wall-to-wall beam ends this far from the room's centre line short of
	--- the half width (on the skirting board).
	WALL_INSET = 2.4,
	--- The side walls' inner faces, from the half width.
	WALL_FACE = 2,
	--- Where a thief stands to reach a socket's prompt: this far in front of
	--- the socket (MuseumLayout.socketFrame), clear of the plinth.
	SOCKET_STAND_OFFSET = 8.5,
	--- The hanging "upside-down" emitters sit this high.
	CEILING_MOUNT_Y = 16,
	--- Beam heights.
	LOW_Y = 0.8,
	HIGH_Y = 4.5,
	MID_Y = 2.5,
	--- Floor-to-"ceiling" beams run from VERTICAL_FLOOR_Y up to VERTICAL_TOP_Y.
	VERTICAL_FLOOR_Y = 0.3,
	VERTICAL_TOP_Y = 14,
	--- Gap between the uprights of a vertical-bar section.
	VERTICAL_SPACING = 7.5,
	--- A slanted beam runs from SLANT_LOW_Y at one end to SLANT_HIGH_Y at the other.
	SLANT_LOW_Y = 0.4,
	SLANT_HIGH_Y = 8,
	--- An X is this much narrower than its section, so there is a way round.
	CROSS_SIDE_GAP = 6.5,
	CROSS_TOP_Y = 9,
}

-- ==========================================================
-- THE VALIDATOR'S CHARACTER
-- ==========================================================
--
-- A coarse but CONSERVATIVE model: every route it accepts is one a real
-- character can take with the stated margins; it may reject rooms a skilled
-- player could still clear. See LaserPatterns.validate.

LaserConfig.VALIDATOR = {
	--- Grid cell (studs).
	CELL = 1,
	--- Clearance kept from a beam that has to be walked AROUND: half width +
	--- 1.5 studs of margin either side.
	SIDE_CLEARANCE = 2.6,
	--- Clearance kept from a beam that is crossed by posture (jumped or
	--- crouched under): half width + 0.9.
	CROSS_CLEARANCE = 2,
	--- A beam point at or below this is jumped (feet apex: JumpPower 50 under
	--- gravity 196.2 = 6.37 studs; at 1.5 there are 0.43 s above it).
	LOW_MAX_Y = 1.5,
	--- ...and one at or above this is crouched under (crouched head 2.6).
	HIGH_MIN_Y = 3.5,
	--- ...and one above this is simply walked under (standing head 5.2).
	STAND_CLEAR_Y = 5.7,
	--- A jumping body reaches this high (7.2-stud JumpHeight + 5.2 + margin):
	--- no jump under anything lower.
	OVERHEAD_Y = 12.5,
	--- Longest run (studs) between a jump's take-off and landing cells. The
	--- slowest carrier (WalkSpeed 16 x 0.75) covers 6.1 studs in a jump's
	--- 0.51 s; both ends of the run are cell CENTRES, so 6.5 is that jump.
	JUMP_RUN = 6.5,
	--- Longest dash (studs) through the cells a moving beam sweeps.
	DASH_RUN = 8,
	--- Slowest expected walk / crouch-walk (studs/s): WalkSpeed 16 with the
	--- heaviest carry penalty, and the same under the crouch cost (x0.6).
	WALK_SPEED = 12,
	CROUCH_SPEED = 7,
	--- A timing window is never shorter than this...
	MIN_WINDOW = 1.2,
	--- ...nor than the time the dash takes at the slow speed plus this.
	WINDOW_SLACK = 0.5,
	--- Time samples per mover cycle.
	TIME_SAMPLES = 32,
	--- Seeds tried per room before the generator starts thinning a layout.
	MAX_ATTEMPTS = 24,
}

-- ==========================================================
-- DIFFICULTY BY ZONE
-- ==========================================================

export type Weights = { [string]: number }

export type ZoneDifficulty = {
	--- Rows of beams across the room. The first is at FIELD.Z_MIN + 1; each
	--- next one is rowSpacing[1]..rowSpacing[2] studs further in (integers,
	--- never under 5: a body has to fit between two rows).
	rows: number,
	rowSpacing: { number },
	--- Target width of one section of a row (studs).
	sectionWidth: number,
	--- Hard cap on beam parts in one room (performance: 24 rooms).
	maxSegments: number,
	--- Relative weights of what a section of a row holds.
	weights: Weights,
	--- Chance that the strip between two rows gets a beam along the depth at
	--- a section boundary, and what it is.
	dividerChance: number,
	dividerWeights: Weights,
	--- Moving beams in the room, their kinds, and the cycle range (seconds).
	movers: number,
	moverWeights: Weights,
	moverPeriod: { number },
	--- A blinking beam is lit for blinkOn[1]..blinkOn[2] seconds, then dark
	--- for blinkOff (the window to dash through; the validator insists on
	--- VALIDATOR.MIN_WINDOW of it being usable).
	blinkOn: { number },
	blinkOff: number,
	--- When true the room must ALSO be solvable without a single jump. From
	--- zone 3 the recommended WalkSpeed is 55+, a jump there carries 28+
	--- studs - further than the whole field is deep - so a route that needs
	--- one is not a route a player can control.
	requireNoJump: boolean,
}

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--- The difficulty row for zone 1..12. Written as one function rather than
--- twelve literal rows so the escalation reads as a curve; `validate` checks
--- all twelve results.
function LaserConfig.zone(index: number): ZoneDifficulty
	local zone = math.clamp(math.floor(index), 1, 12)
	if zone == 1 then
		-- Gentle: two or three low beams. Teaches "jump the red line".
		return {
			rows = 2, rowSpacing = { 12, 14 }, sectionWidth = 30, maxSegments = 3,
			weights = { Open = 2, Low = 3 },
			dividerChance = 0, dividerWeights = { Low = 1 },
			movers = 0, moverWeights = { Blink = 1 }, moverPeriod = { 6, 6 },
			blinkOn = { 2, 3 }, blinkOff = 2.2,
			requireNoJump = false,
		}
	elseif zone <= 4 then
		-- High beams arrive, then the first diagonals.
		local t = (zone - 2) / 2
		return {
			rows = 3, rowSpacing = { 9, 11 }, sectionWidth = 28, maxSegments = 6 + (zone - 2) * 3,
			weights = {
				Open = lerp(3, 2, t), Low = 3, High = 3,
				Slant = if zone >= 3 then 1.5 else 0,
				FloorDiagonal = if zone >= 3 then 1.5 else 0,
				Mid = if zone >= 4 then 0.7 else 0,
			},
			dividerChance = 0, dividerWeights = { Low = 1 },
			movers = 0, moverWeights = { Blink = 1 }, moverPeriod = { 6, 6 },
			blinkOn = { 2, 3 }, blinkOff = 2.2,
			requireNoJump = zone >= 3,
		}
	elseif zone <= 8 then
		-- Verticals, X crosses, ceiling emitters, the first slow movers.
		local t = (zone - 5) / 3
		return {
			rows = 4, rowSpacing = { 6, 8 }, sectionWidth = lerp(27, 24, t), maxSegments = 16 + (zone - 5) * 3,
			weights = {
				Open = lerp(2, 1.4, t), Low = 2, High = 3, Slant = 2, FloorDiagonal = 1.5,
				Mid = 1, Verticals = 2, Cross = 1, Ceiling = 1.5,
			},
			dividerChance = lerp(0.1, 0.25, t), dividerWeights = { Low = 2, High = 2, Mid = 1 },
			movers = if zone >= 7 then 2 else 1,
			moverWeights = { Blink = 2, Bob = 2, Slide = 1 },
			moverPeriod = { lerp(6.5, 5.5, t), lerp(7.5, 6.5, t) },
			blinkOn = { 2, 3 }, blinkOff = 2.1,
			requireNoJump = true,
		}
	end
	-- Dense mixes, faster movers, rows at the minimum spacing (a low row then a
	-- high one 5 studs on is the "jump, then crouch at once" gate).
	local t = (zone - 9) / 3
	return {
		rows = 5, rowSpacing = { 5, 6 }, sectionWidth = lerp(24, 21, t), maxSegments = 30 + math.floor((zone - 9) * 3.4),
		weights = {
			Open = lerp(1.2, 0.8, t), Low = 2, High = 3, Slant = 2, FloorDiagonal = 1.5,
			Mid = 1.5, Verticals = 2.5, Cross = 1.5, Ceiling = 2,
		},
		dividerChance = lerp(0.3, 0.45, t), dividerWeights = { Low = 2, High = 2, Mid = 2 },
		movers = if zone >= 11 then 4 else 3,
		moverWeights = { Blink = 2, Bob = 2, Slide = 2 },
		moverPeriod = { lerp(5, 4.6, t), lerp(6, 5.2, t) },
		blinkOn = { 2.4, 3.4 }, blinkOff = lerp(1.9, 1.7, t),
		requireNoJump = true,
	}
end

return LaserConfig
