--!strict
-- Intersect a laser segment with a moving axis-aligned body. Clipping the
-- (beam position, time) unit square tests the WHOLE sweep, including a fast
-- player who crosses a thin beam between samples. No rays or substeps.
local LaserGeometry = {}

function LaserGeometry.sweptBoxHit(a: Vector3, b: Vector3, from: Vector3, to: Vector3, half: Vector3): boolean
	local beam, travel, offset = b - a, to - from, a - from
	local polygon = { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(1, 1), Vector2.new(0, 1) }
	for _, axis in { "X", "Y", "Z" } do
		for _, sign in { -1, 1 } do
			local output: { Vector2 } = {}
			local function distance(p: Vector2): number
				return sign * (offset[axis] + beam[axis] * p.X - travel[axis] * p.Y) - half[axis] - 0.07
			end
			local previous = polygon[#polygon]
			local last = distance(previous)
			for _, point in polygon do
				local current = distance(point)
				if (current <= 0) ~= (last <= 0) then
					table.insert(output, previous:Lerp(point, last / (last - current)))
				end
				if current <= 0 then table.insert(output, point) end
				previous, last = point, current
			end
			if #output == 0 then return false end
			polygon = output
		end
	end
	return true
end

-- ==========================================================
-- MOVING BEAMS (vaults-crews)
-- ==========================================================
--
-- A rotating arm around a pivot, as a pure function of the SERVER clock
-- (workspace:GetServerTimeNow on both sides). The server tests it, every
-- client draws it, and nothing about its position is ever replicated.

export type SweepArm = {
	pivot: Vector3, -- floor-level centre it turns around
	inner: number, -- beam starts this far from the pivot
	outer: number, -- ...and ends this far
	height: number, -- above the pivot
	period: number, -- seconds per turn; negative turns the other way
	phase: number, -- radians at t = 0
	onSeconds: number?, -- lit for this long...
	offSeconds: number?, -- ...then dark for this long, repeating
}

--- The arm's angle at server time `t`. Reduced modulo the period first, so a
--- ~1.7e9 s clock never costs precision.
function LaserGeometry.sweepAngle(arm: SweepArm, t: number): number
	local period = math.abs(arm.period)
	if period < 1e-3 then
		return arm.phase
	end
	local turn = (t % period) / period * 2 * math.pi
	return arm.phase + (if arm.period < 0 then -turn else turn)
end

--- Whether the arm is lit at server time `t`.
function LaserGeometry.sweepLit(arm: SweepArm, t: number): boolean
	local on, off = arm.onSeconds, arm.offSeconds
	if not on or not off or off <= 0 then
		return true
	end
	return (t % (on + off)) < on
end

--- The arm's end points at server time `t`.
function LaserGeometry.sweepAt(arm: SweepArm, t: number): (Vector3, Vector3)
	local angle = LaserGeometry.sweepAngle(arm, t)
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local lift = Vector3.new(0, arm.height, 0)
	return arm.pivot + lift + direction * arm.inner, arm.pivot + lift + direction * arm.outer
end

--- Does a body moving from `from` to `to` between server times `t0` and `t1`
--- touch the (moving) arm? The interval is cut into sub-steps; in each the
--- arm is frozen at the sub-step's midpoint and the body's box is grown by
--- how far the arm's tip travels in half a sub-step, so a fast arm cannot
--- slip between two samples.
function LaserGeometry.sweptArmHit(arm: SweepArm, t0: number, t1: number, from: Vector3, to: Vector3, half: Vector3): boolean
	local span = math.max(t1 - t0, 0)
	local period = math.abs(arm.period)
	local tipSpeed = if period > 1e-3 then 2 * math.pi * arm.outer / period else 0
	-- About one stud of tip travel per sub-step, between 1 and 8 sub-steps.
	local steps = math.clamp(math.ceil(tipSpeed * span), 1, 8)
	local grow = tipSpeed * span / steps / 2
	local grown = half + Vector3.new(grow, 0, grow)
	for step = 1, steps do
		local mid = t0 + span * (step - 0.5) / steps
		if LaserGeometry.sweepLit(arm, mid) then
			local a, b = LaserGeometry.sweepAt(arm, mid)
			local p0 = from:Lerp(to, (step - 1) / steps)
			local p1 = from:Lerp(to, step / steps)
			if LaserGeometry.sweptBoxHit(a, b, p0, p1, grown) then
				return true
			end
		end
	end
	return false
end

-- ==========================================================
-- MOVING SEGMENTS (lasers-rework)
-- ==========================================================
--
-- The generic mover the museum ROOMS use: a beam whose two end points slide
-- together along `travel` and back (left-right, up-down, toward the door),
-- and/or blinks. Like the vault's arm above it is a pure function of the
-- SERVER clock, so LaserService tests it, LaserFxController draws it and the
-- fairness validator (shared/LaserPatterns) times it, all from the same
-- numbers and with nothing replicated but the part's attributes.
--
-- The scalar functions take plain numbers on purpose: LaserPatterns works in
-- room-local numbers and calls them without building a Vector3.

export type MovingSegment = {
	a: Vector3, -- rest end points (world)
	b: Vector3,
	travel: Vector3, -- both end points are offset by travel * moveFraction(t)
	period: number, -- seconds for there AND back; 0 = does not move
	phase: number, -- fraction of the period already elapsed at t = 0
	onSeconds: number?, -- lit for this long...
	offSeconds: number?, -- ...then dark for this long, repeating
	blinkPhase: number?, -- seconds into the blink cycle at t = 0
}

--- The share of each half-swing spent resting at an end. It is what gives a
--- timing window a flat "now" instead of a single instant.
LaserGeometry.MOVE_DWELL = 0.12

--- 0..1: how far along `travel` a mover is at server time `t`. An eased
--- there-and-back (a cosine, clipped to dwell at both ends).
function LaserGeometry.moveFraction(period: number, phase: number, t: number): number
	if period < 1e-3 then
		return 0
	end
	-- Reduced modulo the period first: a ~1.7e9 s clock keeps full precision.
	local u = ((t % period) / period + phase) % 1
	local raw = (1 - math.cos(2 * math.pi * u)) / 2
	local dwell = LaserGeometry.MOVE_DWELL
	return math.clamp((raw - dwell) / (1 - 2 * dwell), 0, 1)
end

--- The fastest moveFraction ever changes, per second.
function LaserGeometry.moveRate(period: number): number
	if period < 1e-3 then
		return 0
	end
	return math.pi / period / (1 - 2 * LaserGeometry.MOVE_DWELL)
end

--- Whether a blinking beam is lit at server time `t`.
function LaserGeometry.blinkLit(onSeconds: number?, offSeconds: number?, blinkPhase: number?, t: number): boolean
	if not onSeconds or not offSeconds or offSeconds <= 0 then
		return true
	end
	return ((t + (blinkPhase or 0)) % (onSeconds + offSeconds)) < onSeconds
end

function LaserGeometry.segmentLit(segment: MovingSegment, t: number): boolean
	return LaserGeometry.blinkLit(segment.onSeconds, segment.offSeconds, segment.blinkPhase, t)
end

--- The segment's end points at server time `t`.
function LaserGeometry.segmentAt(segment: MovingSegment, t: number): (Vector3, Vector3)
	local offset = segment.travel * LaserGeometry.moveFraction(segment.period, segment.phase, t)
	return segment.a + offset, segment.b + offset
end

--- Does a body moving from `from` to `to` between server times `t0` and `t1`
--- touch the moving segment? Same construction as sweptArmHit: sub-steps,
--- the beam frozen at each sub-step's midpoint, and the body's box grown by
--- how far the beam travels in half a sub-step (per axis), so a fast beam
--- cannot slip between two samples.
function LaserGeometry.sweptSegmentHit(segment: MovingSegment, t0: number, t1: number, from: Vector3, to: Vector3, half: Vector3): boolean
	local span = math.max(t1 - t0, 0)
	local reach = segment.travel * (LaserGeometry.moveRate(segment.period) * span)
	local distance = reach.Magnitude
	local steps = math.clamp(math.ceil(distance), 1, 8)
	local grown = half + Vector3.new(math.abs(reach.X), math.abs(reach.Y), math.abs(reach.Z)) / (steps * 2)
	for step = 1, steps do
		local mid = t0 + span * (step - 0.5) / steps
		if LaserGeometry.segmentLit(segment, mid) then
			local a, b = LaserGeometry.segmentAt(segment, mid)
			local p0 = from:Lerp(to, (step - 1) / steps)
			local p1 = from:Lerp(to, step / steps)
			if LaserGeometry.sweptBoxHit(a, b, p0, p1, grown) then
				return true
			end
		end
	end
	return false
end

return LaserGeometry
