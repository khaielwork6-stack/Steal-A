--!strict
--[[
	LaserPatterns (lasers-rework, 2026-09-20)
	The museum rooms' laser layouts: a deterministic GENERATOR and the FAIRNESS
	VALIDATOR every generated room has to pass.

	EVERYTHING HERE IS ROOM-LOCAL NUMBERS (no Vector3, no instances): x across
	the room with 0 at the middle of the doorway, z into the room with 0 on the
	doorway line, y up - the frame MuseumLayout.frame gives a room. That keeps
	the module a pure function of (zone, room, room size): the server builds
	from it (MuseumGallery), MuseumTests and the debug commands re-run it and
	get the same answer, and it can be run outside Studio.

	THE GENERATOR (`generate`) lays a room out as ROWS of beams across the
	width, each row cut into SECTIONS, each section holding one pattern from
	the zone's weighted library (LaserConfig.zone):
	    Open           nothing
	    Low / High     jump it / crouch under it
	    Mid            waist height: neither - find another section
	    Slant          low at one end, high at the other (vertical plane)
	    FloorLow/High  a diagonal across the floor plane, row to row
	    Verticals      floor-to-ceiling uprights to sidestep between
	    Cross          an X: a wall with a way round each side
	    Ceiling        an inverted V fired down from a hanging emitter
	    Blink          a waist beam that goes dark for a moment      (mover)
	    Bob            a beam riding up and down: jump it or duck it (mover)
	    Slide          an upright sweeping left and right            (mover)
	plus beams ALONG the depth between two rows at a section boundary
	(dividers), so the strips between rows are not free corridors.

	THE VALIDATOR (`validate`) is a search over (cell, posture) on a 1-stud
	grid, with two kinds of "run" on top of plain walking:
	    a JUMP run   over cells only a low beam blocks, from a standing cell
	                 to a standing cell, no longer than the slowest jump;
	    a DASH run   through the cells ONE moving beam sweeps, from a cell
	                 no mover reaches to another, allowed only if that beam
	                 leaves those cells alone for a long enough window.
	It is conservative by construction (LaserConfig.VALIDATOR): clearances are
	kept on every side, a cell two movers can reach is a wall, and a window is
	measured with the beam padded by its own travel between time samples. A
	room passes when every loot socket's standing spot is reached from the
	doorway; every move is reversible, so "there" is also "and back".

	`forRoom` is what callers use: seed = f(zone, room), next seed until the
	validator passes, and - should a zone's numbers ever be tuned so hard that
	no seed passes - the layout is thinned one beam at a time until it does.
	A room can therefore never ship unfair; at worst it ships easier.
]]

local LaserConfig = require(script.Parent.Config.LaserConfig)
local Geometry = require(script.Parent.Util.LaserGeometry)

local LaserPatterns = {}

export type Segment = {
	kind: string,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
	--- Movers only (LaserGeometry.MovingSegment, in room-local numbers).
	tx: number?,
	ty: number?,
	tz: number?,
	period: number?,
	phase: number?,
	onSeconds: number?,
	offSeconds: number?,
	blinkPhase: number?,
}

export type Room = {
	width: number,
	depth: number,
	doorWidth: number,
	--- Room-local x of each loot socket, and their shared z.
	socketXs: { number },
	socketZ: number,
}

export type Report = {
	ok: boolean,
	reasons: { string },
	--- Per socket: reached from the doorway.
	sockets: { boolean },
	allowJump: boolean,
	segments: number,
	movers: number,
	--- The shortest timing window any accepted run relies on (seconds), or
	--- nil when no run crosses a moving beam.
	tightestWindow: number?,
	reachedCells: number,
}

export type Result = {
	segments: { Segment },
	seed: number,
	attempts: number,
	--- Beams removed by the last-resort thinning (0 in a healthy config).
	thinned: number,
	report: Report,
}

function LaserPatterns.isMover(segment: Segment): boolean
	return (segment.period ~= nil and segment.period > 0) or (segment.offSeconds ~= nil and segment.offSeconds > 0)
end

-- ==========================================================
-- DETERMINISTIC RANDOM
-- ==========================================================
--
-- Not Random.new: the same seed has to give the same room on every server,
-- in every test run and outside Studio. Park-Miller (48271 mod 2^31-1); the
-- product stays under 2^53, so it is exact in a double.

local function newRng(seed: number): () -> number
	local state = (math.floor(math.abs(seed)) % 2147483646) + 1
	local function nextUnit(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	for _ = 1, 4 do
		nextUnit()
	end
	return nextUnit
end

local function randomInt(rng: () -> number, low: number, high: number): number
	return low + math.floor(rng() * (high - low + 1))
end

local function randomRange(rng: () -> number, range: { number }): number
	return range[1] + (range[2] - range[1]) * rng()
end

--- A fixed order, so a weighted pick never depends on table iteration order.
local KIND_ORDER = { "Open", "Low", "High", "Mid", "Slant", "FloorDiagonal", "Verticals", "Cross", "Ceiling", "Blink", "Bob", "Slide" }

local function pickWeighted(rng: () -> number, weights: LaserConfig.Weights): string
	local total = 0
	for _, kind in KIND_ORDER do
		total += math.max(weights[kind] or 0, 0)
	end
	if total <= 0 then
		return "Open"
	end
	local roll = rng() * total
	for _, kind in KIND_ORDER do
		local weight = math.max(weights[kind] or 0, 0)
		if weight > 0 then
			roll -= weight
			if roll < 0 then
				return kind
			end
		end
	end
	return "Open"
end

-- ==========================================================
-- THE GENERATOR
-- ==========================================================

--- One candidate layout for a room. Deterministic in (zoneIndex, room, seed).
--- NOT validated - use forRoom.
function LaserPatterns.generate(zoneIndex: number, room: Room, seed: number): { Segment }
	local cfg = LaserConfig.zone(zoneIndex)
	local field = LaserConfig.FIELD
	local rng = newRng(seed)
	local wall = room.width / 2 - field.WALL_INSET
	local segments: { Segment } = {}

	local function add(kind: string, ax: number, ay: number, az: number, bx: number, by: number, bz: number): Segment
		local segment: Segment = { kind = kind, ax = ax, ay = ay, az = az, bx = bx, by = by, bz = bz }
		table.insert(segments, segment)
		return segment
	end

	-- ROWS. Whole-stud z, never closer than 5: the validator's cells are one
	-- stud, and two crossable rows need a free cell between their bands.
	local rows: { number } = {}
	local z = field.Z_MIN + 1
	for _ = 1, cfg.rows do
		if z > field.Z_MAX then
			local last = rows[#rows]
			if last and field.Z_MAX - last >= 5 then
				z = field.Z_MAX
			else
				break
			end
		end
		table.insert(rows, z)
		z += math.max(5, randomInt(rng, cfg.rowSpacing[1], cfg.rowSpacing[2]))
	end

	-- SECTIONS. One set of boundaries for the whole room, so neighbouring
	-- beams share an emitter post and the dividers have somewhere to stand.
	local count = math.max(2, math.floor(2 * wall / cfg.sectionWidth + 0.5))
	local step = 2 * wall / count
	local bounds: { number } = { -wall }
	for i = 1, count - 1 do
		bounds[i + 1] = math.floor(-wall + i * step + (rng() - 0.5) * step * 0.3 + 0.5)
	end
	bounds[count + 1] = wall

	-- WHAT EACH SECTION OF EACH ROW HOLDS.
	local kinds: { { string } } = {}
	for r = 1, #rows do
		kinds[r] = table.create(count, "")
	end
	for r = 1, #rows do
		for s = 1, count do
			if kinds[r][s] == "Taken" then
				continue
			end
			local kind = pickWeighted(rng, cfg.weights)
			if kind == "FloorDiagonal" then
				-- A floor diagonal runs from this row to the next and takes the
				-- next row's slot with it.
				if r < #rows and kinds[r + 1][s] == "" then
					kind = if rng() < 0.5 then "FloorLow" else "FloorHigh"
					kinds[r + 1][s] = "Taken"
				else
					kind = "High"
				end
			elseif kind == "Cross" and bounds[s + 1] - bounds[s] - 2 * field.CROSS_SIDE_GAP < 8 then
				kind = "Mid"
			end
			kinds[r][s] = kind
		end
	end

	-- MOVERS replace a section each (never half of a floor diagonal).
	if cfg.movers > 0 then
		local slots: { { number } } = {}
		for r = 1, #rows do
			for s = 1, count do
				local kind = kinds[r][s]
				if kind ~= "Taken" and kind ~= "FloorLow" and kind ~= "FloorHigh" then
					table.insert(slots, { r, s })
				end
			end
		end
		for _ = 1, math.min(cfg.movers, #slots) do
			local slot = table.remove(slots, randomInt(rng, 1, #slots)) :: { number }
			kinds[slot[1]][slot[2]] = pickWeighted(rng, cfg.moverWeights)
		end
	end

	-- EVERY ROW KEEPS A PLAIN WAY THROUGH. The validator is the judge; this
	-- only keeps most seeds from being thrown away.
	for r = 1, #rows do
		local passable = false
		for s = 1, count do
			local kind = kinds[r][s]
			if kind == "Open" or kind == "High" or kind == "FloorHigh" or (kind == "Low" and not cfg.requireNoJump) then
				passable = true
			end
			if kind == "Taken" and r > 1 and kinds[r - 1][s] == "FloorHigh" then
				passable = true
			end
		end
		if not passable then
			local candidates: { number } = {}
			for s = 1, count do
				local kind = kinds[r][s]
				if kind ~= "Taken" and kind ~= "FloorLow" and kind ~= "FloorHigh" then
					table.insert(candidates, s)
				end
			end
			if #candidates > 0 then
				local s = candidates[randomInt(rng, 1, #candidates)]
				kinds[r][s] = if cfg.requireNoJump then "High" else "Low"
			end
		end
	end

	-- THE BEAMS.
	for r = 1, #rows do
		local rowZ = rows[r]
		for s = 1, count do
			local kind = kinds[r][s]
			local x0, x1 = bounds[s], bounds[s + 1]
			if kind == "Low" then
				add("Low", x0, field.LOW_Y, rowZ, x1, field.LOW_Y, rowZ)
			elseif kind == "High" then
				add("High", x0, field.HIGH_Y, rowZ, x1, field.HIGH_Y, rowZ)
			elseif kind == "Mid" then
				add("Mid", x0, field.MID_Y, rowZ, x1, field.MID_Y, rowZ)
			elseif kind == "Slant" then
				if rng() < 0.5 then
					add("Slant", x0, field.SLANT_LOW_Y, rowZ, x1, field.SLANT_HIGH_Y, rowZ)
				else
					add("Slant", x0, field.SLANT_HIGH_Y, rowZ, x1, field.SLANT_LOW_Y, rowZ)
				end
			elseif kind == "FloorLow" or kind == "FloorHigh" then
				local y = if kind == "FloorLow" then field.LOW_Y else field.HIGH_Y
				local nextZ = rows[r + 1]
				if rng() < 0.5 then
					add(kind, x0, y, rowZ, x1, y, nextZ)
				else
					add(kind, x0, y, nextZ, x1, y, rowZ)
				end
			elseif kind == "Verticals" then
				local spacing = field.VERTICAL_SPACING
				local bars = math.max(1, math.floor((x1 - x0) / spacing))
				local first = x0 + ((x1 - x0) - (bars - 1) * spacing) / 2
				for n = 0, bars - 1 do
					local x = first + n * spacing
					add("Vertical", x, field.VERTICAL_FLOOR_Y, rowZ, x, field.VERTICAL_TOP_Y, rowZ)
				end
			elseif kind == "Cross" then
				local c0, c1 = x0 + field.CROSS_SIDE_GAP, x1 - field.CROSS_SIDE_GAP
				add("Cross", c0, field.SLANT_LOW_Y, rowZ, c1, field.CROSS_TOP_Y, rowZ)
				add("Cross", c0, field.CROSS_TOP_Y, rowZ, c1, field.SLANT_LOW_Y, rowZ)
			elseif kind == "Ceiling" then
				local middle = (x0 + x1) / 2
				add("Ceiling", middle, field.CEILING_MOUNT_Y, rowZ, x0 + 1, field.SLANT_LOW_Y, rowZ)
				add("Ceiling", middle, field.CEILING_MOUNT_Y, rowZ, x1 - 1, field.SLANT_LOW_Y, rowZ)
			elseif kind == "Blink" then
				local beam = add("Blink", x0, field.MID_Y, rowZ, x1, field.MID_Y, rowZ)
				beam.onSeconds = math.floor(randomRange(rng, cfg.blinkOn) * 10 + 0.5) / 10
				beam.offSeconds = math.floor(cfg.blinkOff * 10 + 0.5) / 10
				beam.blinkPhase = math.floor(rng() * ((beam.onSeconds :: number) + (beam.offSeconds :: number)) * 10) / 10
			elseif kind == "Bob" then
				local beam = add("Bob", x0, field.LOW_Y, rowZ, x1, field.LOW_Y, rowZ)
				beam.tx, beam.ty, beam.tz = 0, field.HIGH_Y - field.LOW_Y, 0
				beam.period = math.floor(randomRange(rng, cfg.moverPeriod) * 10 + 0.5) / 10
				beam.phase = math.floor(rng() * 100) / 100
			elseif kind == "Slide" then
				local travel = (x1 - x0) - 3
				local beam = add("Slide", x0 + 1.5, field.VERTICAL_FLOOR_Y, rowZ, x0 + 1.5, field.VERTICAL_TOP_Y, rowZ)
				beam.tx, beam.ty, beam.tz = travel, 0, 0
				-- The same tip speed whatever the section's width.
				beam.period = math.floor(randomRange(rng, cfg.moverPeriod) * math.max(1, travel / 18) * 10 + 0.5) / 10
				beam.phase = math.floor(rng() * 100) / 100
			end
		end
	end

	-- DIVIDERS: along the depth, between two rows, on a section boundary.
	if cfg.dividerChance > 0 then
		for r = 1, #rows - 1 do
			for boundary = 2, count do
				if rng() < cfg.dividerChance then
					-- Not through a floor diagonal that owns this strip.
					if kinds[r][boundary - 1]:sub(1, 5) == "Floor" or kinds[r][boundary]:sub(1, 5) == "Floor" then
						continue
					end
					local kind = pickWeighted(rng, cfg.dividerWeights)
					local y = if kind == "Low" then field.LOW_Y elseif kind == "High" then field.HIGH_Y else field.MID_Y
					local x = bounds[boundary]
					add(if kind == "Low" or kind == "High" then kind else "Mid", x, y, rows[r], x, y, rows[r + 1])
				end
			end
		end
	end

	-- THE PART BUDGET. Static beams go first; a mover is the last thing cut.
	while #segments > cfg.maxSegments do
		local statics: { number } = {}
		for index, segment in segments do
			if not LaserPatterns.isMover(segment) then
				table.insert(statics, index)
			end
		end
		if #statics > 0 then
			table.remove(segments, statics[randomInt(rng, 1, #statics)])
		else
			table.remove(segments, randomInt(rng, 1, #segments))
		end
	end
	return segments
end

-- ==========================================================
-- THE VALIDATOR
-- ==========================================================

local STAND, CROUCH, JUMP = 1, 2, 4

--- How far from a beam point at height `y` each posture has to stay:
--- (stand, crouch, jump) radii, 0 = that posture is not blocked by it.
local function radii(y: number): (number, number, number)
	local v = LaserConfig.VALIDATOR
	if y > v.OVERHEAD_Y then
		return 0, 0, 0
	elseif y <= v.LOW_MAX_Y then
		return v.CROSS_CLEARANCE, v.CROSS_CLEARANCE, 0
	elseif y < v.HIGH_MIN_Y then
		return v.SIDE_CLEARANCE, v.SIDE_CLEARANCE, v.SIDE_CLEARANCE
	elseif y <= v.STAND_CLEAR_Y then
		return v.CROSS_CLEARANCE, 0, v.CROSS_CLEARANCE
	end
	return 0, 0, v.CROSS_CLEARANCE
end

--- Checks that a standard character can get from the doorway to every
--- socket's standing spot (and so back). `allowJump = false` asks for a
--- route that never jumps.
function LaserPatterns.validate(room: Room, segments: { Segment }, allowJump: boolean): Report
	local v = LaserConfig.VALIDATOR
	local field = LaserConfig.FIELD
	local body = LaserConfig.BODY
	local cell = v.CELL
	local reasons: { string } = {}
	local report: Report = {
		ok = false, reasons = reasons, sockets = {}, allowJump = allowJump,
		segments = #segments, movers = 0, tightestWindow = nil, reachedCells = 0,
	}

	local innerHalf = room.width / 2 - field.WALL_FACE
	local nx = math.floor(2 * innerHalf / cell)
	local gridHalf = nx * cell / 2
	local standZ = room.socketZ - field.SOCKET_STAND_OFFSET
	local nz = math.floor((standZ + 2) / cell)
	local total = nx * nz
	local doorHalf = room.doorWidth / 2

	local function cellX(i: number): number
		return -gridHalf + (i - 0.5) * cell
	end
	local function cellZ(k: number): number
		return (k - 0.5) * cell
	end
	local function indexOf(i: number, k: number): number
		return (k - 1) * nx + i
	end

	-- STRUCTURE: the side walls, and the front wall either side of the door.
	local wallBlocked: { boolean } = table.create(total, false)
	for k = 1, nz do
		for i = 1, nx do
			local x, z = cellX(i), cellZ(k)
			if math.abs(x) > innerHalf - body.HALF_WIDTH - 0.4 or (z < 2.5 and math.abs(x) > doorHalf - 1.5) then
				wallBlocked[indexOf(i, k)] = true
			end
		end
	end

	local standBlocked: { boolean } = table.create(total, false)
	local crouchBlocked: { boolean } = table.create(total, false)
	local jumpBlocked: { boolean } = table.create(total, false)

	--- Visits every cell within `reach` (box distance) of a beam point.
	local function around(px: number, pz: number, reach: number, visit: (number, number) -> ())
		local iLow = math.max(1, math.ceil((px - reach + gridHalf) / cell + 0.5 - 1e-6))
		local iHigh = math.min(nx, math.floor((px + reach + gridHalf) / cell + 0.5 + 1e-6))
		local kLow = math.max(1, math.ceil((pz - reach) / cell + 0.5 - 1e-6))
		local kHigh = math.min(nz, math.floor((pz + reach) / cell + 0.5 + 1e-6))
		for k = kLow, kHigh do
			local dz = math.abs(cellZ(k) - pz)
			for i = iLow, iHigh do
				visit(indexOf(i, k), math.max(dz, math.abs(cellX(i) - px)))
			end
		end
	end

	-- BOUNDS, then the static beams.
	local wallReach = room.width / 2 - field.WALL_INSET + 0.05
	local movers: { Segment } = {}
	for index, segment in segments do
		local tx, tz, ty = segment.tx or 0, segment.tz or 0, segment.ty or 0
		for _, point in { { segment.ax, segment.ay, segment.az }, { segment.bx, segment.by, segment.bz } } do
			for _, swing in { 0, 1 } do
				local x, y, z = point[1] + tx * swing, point[2] + ty * swing, point[3] + tz * swing
				if math.abs(x) > wallReach or z < field.Z_MIN - 0.01 or z > field.Z_MAX + 0.01 or y < 0.2 or y > field.CEILING_MOUNT_Y + 0.01 then
					table.insert(reasons, `beam {index} ({segment.kind}) leaves the laser field`)
				end
			end
		end
		if LaserPatterns.isMover(segment) then
			table.insert(movers, segment)
			continue
		end
		local dx, dy, dz = segment.bx - segment.ax, segment.by - segment.ay, segment.bz - segment.az
		local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy + dz * dz) / 0.5))
		for n = 0, steps do
			local t = n / steps
			local rStand, rCrouch, rJump = radii(segment.ay + dy * t)
			local reach = math.max(rStand, rCrouch, rJump)
			if reach > 0 then
				around(segment.ax + dx * t, segment.az + dz * t, reach, function(at: number, distance: number)
					if distance <= rStand then standBlocked[at] = true end
					if distance <= rCrouch then crouchBlocked[at] = true end
					if distance <= rJump then jumpBlocked[at] = true end
				end)
			end
		end
	end
	report.movers = #movers

	-- THE MOVERS: per mover, per cell it ever reaches, which postures it
	-- blocks at each time sample of its cycle.
	local samples = v.TIME_SAMPLES
	local masks: { { [number]: { number } } } = {}
	local cycles: { number } = {}
	local timedBy: { [number]: { [number]: number } } = { [STAND] = {}, [CROUCH] = {}, [JUMP] = {} }
	for m, segment in movers do
		local moves = segment.period ~= nil and segment.period > 0
		local blinks = segment.offSeconds ~= nil and segment.offSeconds > 0
		if moves and blinks then
			table.insert(reasons, `mover {m} both moves and blinks (not timed by the validator)`)
		end
		local period = segment.period or 0
		local cycle = if blinks then (segment.onSeconds or 0) + (segment.offSeconds or 0) else period
		cycles[m] = cycle
		local cells: { [number]: { number } } = {}
		masks[m] = cells
		local tx, ty, tz = segment.tx or 0, segment.ty or 0, segment.tz or 0
		-- How far the beam can travel in half a time sample: it is padded by
		-- that much, so nothing slips between two samples.
		local drift = if moves then Geometry.moveRate(period) * (cycle / samples) / 2 else 0
		local padFlat = math.max(math.abs(tx), math.abs(tz)) * drift
		local padY = math.abs(ty) * drift
		local dx, dy, dz = segment.bx - segment.ax, segment.by - segment.ay, segment.bz - segment.az
		local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy + dz * dz) / 1))
		for j = 1, samples do
			local t = (j - 0.5) / samples * cycle
			if blinks and not Geometry.blinkLit(segment.onSeconds, segment.offSeconds, segment.blinkPhase, t) then
				continue
			end
			local along = if moves then Geometry.moveFraction(period, segment.phase or 0, t) else 0
			for n = 0, steps do
				local u = n / steps
				local y = segment.ay + dy * u + ty * along
				local s1, c1, j1 = radii(y - padY)
				local s2, c2, j2 = radii(y + padY)
				local rStand, rCrouch, rJump = math.max(s1, s2), math.max(c1, c2), math.max(j1, j2)
				local reach = math.max(rStand, rCrouch, rJump)
				if reach > 0 then
					around(segment.ax + dx * u + tx * along, segment.az + dz * u + tz * along, reach + padFlat, function(at: number, distance: number)
						local bits = 0
						if rStand > 0 and distance <= rStand + padFlat then bits += STAND end
						if rCrouch > 0 and distance <= rCrouch + padFlat then bits += CROUCH end
						if rJump > 0 and distance <= rJump + padFlat then bits += JUMP end
						if bits > 0 then
							local row = cells[at]
							if not row then
								row = table.create(samples, 0)
								cells[at] = row
							end
							row[j] = bit32.bor(row[j], bits)
						end
					end)
				end
			end
		end
		for at, row in cells do
			local seen = 0
			for j = 1, samples do
				seen = bit32.bor(seen, row[j])
			end
			for _, posture in { STAND, CROUCH, JUMP } do
				if bit32.band(seen, posture) ~= 0 then
					local owners = timedBy[posture]
					owners[at] = if owners[at] == nil then m else -1
				end
			end
		end
	end

	--- The longest stretch of its cycle (seconds) for which mover `m` leaves
	--- every one of `cells` alone for `posture`, less one sample.
	local function window(m: number, cells: { number }, posture: number): number
		local rows = masks[m]
		local busy: { boolean } = table.create(samples, false)
		local any = false
		for _, at in cells do
			local row = rows[at]
			if row then
				for j = 1, samples do
					if bit32.band(row[j], posture) ~= 0 then
						busy[j] = true
						any = true
					end
				end
			end
		end
		if not any then
			return math.huge
		end
		local best, run = 0, 0
		-- Twice round, so a free stretch that wraps the cycle is measured whole.
		for j = 1, samples * 2 do
			if busy[(j - 1) % samples + 1] then
				run = 0
			else
				run += 1
				best = math.max(best, run)
			end
		end
		best = math.min(best, samples)
		return math.max(0, best - 1) * cycles[m] / samples
	end

	local function staticFree(posture: number, at: number): boolean
		if wallBlocked[at] then
			return false
		end
		if posture == STAND then
			return not standBlocked[at]
		end
		return not crouchBlocked[at]
	end
	local function free(posture: number, at: number): boolean
		return staticFree(posture, at) and timedBy[posture][at] == nil
	end
	--- A cell a jump may start or end on: safe to stand in, nothing overhead.
	local function jumpEnd(at: number): boolean
		return free(STAND, at) and not jumpBlocked[at] and timedBy[JUMP][at] == nil
	end

	-- THE DOORWAY APRON must be plain floor: nobody is hit walking in.
	local apronClear = true
	for k = 1, math.min(nz, 6) do
		for i = 1, nx do
			if math.abs(cellX(i)) <= doorHalf - 2 and not free(STAND, indexOf(i, k)) then
				apronClear = false
			end
		end
	end
	if not apronClear then
		table.insert(reasons, "a beam reaches the doorway")
	end

	-- THE SEARCH. State = cell * 2 + (0 standing | 1 crouched).
	local visited: { boolean } = table.create(total * 2, false)
	local queue: { number } = {}
	local function visit(at: number, posture: number)
		local state = at * 2 + (if posture == STAND then 0 else 1)
		if not visited[state] then
			visited[state] = true
			table.insert(queue, state)
		end
	end
	for i = 1, nx do
		if math.abs(cellX(i)) <= doorHalf - 2 and free(STAND, indexOf(i, 1)) then
			visit(indexOf(i, 1), STAND)
		end
	end

	local tightest = math.huge
	local DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
	local head = 1
	while head <= #queue do
		local state = queue[head]
		head += 1
		local posture = if state % 2 == 0 then STAND else CROUCH
		local at = (state - state % 2) / 2
		local i = (at - 1) % nx + 1
		local k = (at - i) / nx + 1
		report.reachedCells += 1

		-- Stand up / crouch down on the spot.
		local other = if posture == STAND then CROUCH else STAND
		if free(other, at) then
			visit(at, other)
		end

		for _, direction in DIRECTIONS do
			local di, dk = direction[1], direction[2]
			local ni, nk = i + di, k + dk
			if ni < 1 or ni > nx or nk < 1 or nk > nz then
				continue
			end
			local nextAt = indexOf(ni, nk)
			if free(posture, nextAt) then
				-- A diagonal step may not cut a corner.
				if di == 0 or dk == 0 or (free(posture, indexOf(ni, k)) and free(posture, indexOf(i, nk))) then
					visit(nextAt, posture)
				end
				continue
			end
			local stride = cell * math.sqrt(di * di + dk * dk)

			-- A JUMP RUN over whatever only blocks the ground.
			if allowJump and posture == STAND and jumpEnd(at) then
				local crossed: { number } = {}
				local owner = 0
				local n = 1
				while n * stride <= v.JUMP_RUN do
					local ci, ck = i + di * n, k + dk * n
					if ci < 1 or ci > nx or ck < 1 or ck > nz then
						break
					end
					local c = indexOf(ci, ck)
					if wallBlocked[c] or jumpBlocked[c] then
						break
					end
					local timed = timedBy[JUMP][c]
					if timed ~= nil then
						if timed == -1 or (owner ~= 0 and owner ~= timed) then
							break
						end
						owner = timed
						table.insert(crossed, c)
					elseif n >= 2 and jumpEnd(c) then
						local open = if owner ~= 0 then window(owner, crossed, JUMP) else math.huge
						if open >= v.MIN_WINDOW then
							tightest = math.min(tightest, open)
							visit(c, STAND)
						end
					end
					n += 1
				end
			end

			-- A DASH RUN through the cells one mover sweeps.
			local owner = timedBy[posture][nextAt]
			if owner ~= nil and owner > 0 and staticFree(posture, nextAt) then
				local crossed: { number } = {}
				local n = 1
				while n * stride <= v.DASH_RUN do
					local ci, ck = i + di * n, k + dk * n
					if ci < 1 or ci > nx or ck < 1 or ck > nz then
						break
					end
					local c = indexOf(ci, ck)
					if not staticFree(posture, c) then
						break
					end
					local timed = timedBy[posture][c]
					if timed == nil then
						local speed = if posture == STAND then v.WALK_SPEED else v.CROUCH_SPEED
						local needed = math.max(v.MIN_WINDOW, n * stride / speed + v.WINDOW_SLACK)
						local open = window(owner, crossed, posture)
						if open >= needed then
							tightest = math.min(tightest, open)
							visit(c, posture)
						end
						break
					elseif timed ~= owner then
						break
					end
					table.insert(crossed, c)
					n += 1
				end
			end
		end
	end
	report.tightestWindow = if tightest < math.huge then tightest else nil

	-- EVERY SOCKET'S STANDING SPOT.
	for socket, x in room.socketXs do
		local i = math.clamp(math.floor((x + gridHalf) / cell) + 1, 1, nx)
		local k = math.clamp(math.floor(standZ / cell) + 1, 1, nz)
		local at = indexOf(i, k)
		local reached = visited[at * 2] == true
		report.sockets[socket] = reached
		if not free(STAND, at) then
			table.insert(reasons, `a beam covers socket {socket}'s standing spot`)
		elseif not reached then
			table.insert(reasons, `no {if allowJump then "" else "jump-free "}route to socket {socket}`)
		end
	end

	report.ok = #reasons == 0
	return report
end

-- ==========================================================
-- THE ROOM'S LAYOUT
-- ==========================================================

--- The first seed tried for a room. Attempt n uses seedFor + n.
function LaserPatterns.seedFor(zoneIndex: number, roomIndex: number): number
	return zoneIndex * 100000 + roomIndex * 10000
end

--- The check a zone's rooms must pass: from zone 3 a route with no jump in
--- it (which is also a route, so the plain check is implied).
function LaserPatterns.check(zoneIndex: number, room: Room, segments: { Segment }): Report
	return LaserPatterns.validate(room, segments, not LaserConfig.zone(zoneIndex).requireNoJump)
end

local cache: { [string]: Result } = {}

--- The validated layout of one room. Deterministic and cached: the builder,
--- the tests and the debug commands all get the same table.
function LaserPatterns.forRoom(zoneIndex: number, roomIndex: number, room: Room): Result
	local key = `{zoneIndex}:{roomIndex}:{room.width}:{room.socketZ}`
	local cached = cache[key]
	if cached then
		return cached
	end
	local base = LaserPatterns.seedFor(zoneIndex, roomIndex)
	local attempts = LaserConfig.VALIDATOR.MAX_ATTEMPTS
	local result: Result? = nil
	for attempt = 0, attempts - 1 do
		local segments = LaserPatterns.generate(zoneIndex, room, base + attempt)
		local report = LaserPatterns.check(zoneIndex, room, segments)
		if report.ok then
			result = { segments = segments, seed = base + attempt, attempts = attempt + 1, thinned = 0, report = report }
			break
		end
	end
	if not result then
		-- LAST RESORT: thin the first layout until it passes. An empty room
		-- always does, so this ends; the caller reports `thinned`.
		local segments = LaserPatterns.generate(zoneIndex, room, base)
		local rng = newRng(base + 77)
		local thinned = 0
		local report = LaserPatterns.check(zoneIndex, room, segments)
		while not report.ok and #segments > 0 do
			table.remove(segments, randomInt(rng, 1, #segments))
			thinned += 1
			report = LaserPatterns.check(zoneIndex, room, segments)
		end
		result = { segments = segments, seed = base, attempts = attempts, thinned = thinned, report = report }
	end
	cache[key] = result :: Result
	return result :: Result
end

--- TEST HELPER. A point (room-local x, z) on a STATIC beam of `kind` that
--- runs across the room (constant z and height), with no other beam of the
--- layout within `clear` studs of it on the floor plan - somewhere a test can
--- walk a character into exactly one known beam. Nil when there is none.
function LaserPatterns.isolatedPoint(segments: { Segment }, kind: string, clear: number): (number?, number?, number?)
	for index, segment in segments do
		if segment.kind ~= kind or LaserPatterns.isMover(segment) or segment.az ~= segment.bz or segment.ay ~= segment.by then
			continue
		end
		for _, t in { 0.5, 0.3, 0.7, 0.15, 0.85 } do
			local x, z = segment.ax + (segment.bx - segment.ax) * t, segment.az
			local alone = true
			for otherIndex, other in segments do
				if otherIndex == index then
					continue
				end
				local tx, tz = other.tx or 0, other.tz or 0
				local dx, dz = other.bx - other.ax, other.bz - other.az
				local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dz * dz)))
				for n = 0, steps do
					for _, swing in { 0, 0.5, 1 } do
						local ox, oz = other.ax + dx * n / steps + tx * swing, other.az + dz * n / steps + tz * swing
						if math.max(math.abs(ox - x), math.abs(oz - z)) < clear then
							alone = false
						end
					end
				end
			end
			if alone then
				return x, z, index
			end
		end
	end
	return nil, nil, nil
end

--- Beam counts by kind, for reports.
function LaserPatterns.describe(segments: { Segment }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, segment in segments do
		counts[segment.kind] = (counts[segment.kind] or 0) + 1
	end
	return counts
end

return LaserPatterns
