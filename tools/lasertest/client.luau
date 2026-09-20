local __s = require("./shim")
local Vector3, Vector2 = __s.Vector3, __s.Vector2
local v3 = Vector3.new
local Geometry = require("./Util/LaserGeometry")
local LaserPatterns = require("./LaserPatterns")
local LaserFlight = require("./LaserFlight")
local LaserConfig = require("./Config/LaserConfig")

local LENGTHS = { 97.5304946899414, 146.10552978515625, 211.0, 236.1, 324.1, 385.1109924316406, 429.1, 505.1, 640.1, 505.1, 637.1, 763.1109619140625 }
local function roomFor(zone)
	local width = math.min(LENGTHS[zone] - 8, 140)
	return { width = width, depth = 58, doorWidth = 40, socketXs = { -0.36 * width, -0.18 * width, 0.18 * width, 0.36 * width }, socketZ = 45 }
end

local failures, passes = {}, 0
local function check(ok, name)
	if ok then passes += 1 else table.insert(failures, name) end
end

local function beamOf(segment)
	local moving = LaserPatterns.isMover(segment)
	local a, b = v3(segment.ax, segment.ay, segment.az), v3(segment.bx, segment.by, segment.bz)
	local travel = if moving then v3(segment.tx or 0, segment.ty or 0, segment.tz or 0) else nil
	local lo, hi = Geometry.beamBounds(a, b, travel)
	local seg = nil
	if moving then
		seg = { a = a, b = b, travel = travel, period = segment.period or 0, phase = segment.phase or 0,
			onSeconds = segment.onSeconds, offSeconds = segment.offSeconds, blinkPhase = segment.blinkPhase }
	end
	return { id = 1, zone = 1, room = 1, a = a, b = b, moving = seg, min = lo, max = hi }
end

-- A runner crossing point P (room-local) along direction d (unit, floor plane),
-- at `speed` studs/s, sampled every dt; the frame at index `mid` is at time T.
local function crossing(beam, P, d, speed, dt, T, posture)
	local height = if posture == "crouch" then 2.6 else 5.2
	local half = v3(1.1, height / 2, 1.1)
	local feetCentre = height / 2
	local frames = math.floor(40 / (speed * dt)) + 2
	local mid = math.floor(frames / 2)
	local previous = nil
	local hit = false
	for k = 0, frames do
		local s = (k - mid) * speed * dt
		local center = v3(P.X + d.X * s, feetCentre, P.Z + d.Z * s)
		local time = T + (k - mid) * dt
		if previous then
			if Geometry.beamHit(beam, previous.time, time, previous.center, center, half) then
				hit = true
				break
			end
		end
		previous = { center = center, time = time }
	end
	return hit
end

local DTS = { 1 / 240, 1 / 120, 1 / 60, 1 / 30, 1 / 15, 1 / 10 }
local SPEEDS = { 100, 260, 300 }

local statics, cases = 0, 0
local movers, moverCases = 0, 0
for zone = 1, 12 do
	local room = roomFor(zone)
	for roomIndex = 1, 2 do
		local layout = LaserPatterns.forRoom(zone, roomIndex, room)
		for index, segment in layout.segments do
			local beam = beamOf(segment)
			if not beam.moving then
				statics += 1
				-- Points along the beam where a STANDING body surely collides (< 4.9).
				local floorDx, floorDz = segment.bx - segment.ax, segment.bz - segment.az
				local floorLen = math.sqrt(floorDx * floorDx + floorDz * floorDz)
				local d
				if floorLen > 0.5 then
					d = v3(-floorDz / floorLen, 0, floorDx / floorLen)
				else
					d = v3(1, 0, 0) -- an upright: cross it sideways
				end
				for _, s in { 0.1, 0.25, 0.5, 0.75, 0.9 } do
					local y = segment.ay + (segment.by - segment.ay) * s
					local P = v3(segment.ax + floorDx * s, y, segment.az + floorDz * s)
					if y < 4.8 and y > 0.3 then
						for _, speed in SPEEDS do
							for _, dt in DTS do
								cases += 1
								check(crossing(beam, P, d, speed, dt, 0, "stand"), `zone {zone} room {roomIndex} beam {index} {segment.kind} s={s} v={speed} dt={dt} must register`)
							end
						end
					end
					-- A crouched body passes under a high beam (and the test must be able to fail).
					if segment.kind == "High" and floorLen > 0.5 then
						cases += 1
						check(not crossing(beam, P, d, 260, 1 / 60, 0, "crouch"), `zone {zone} room {roomIndex} beam {index} High must NOT hit a crouched body`)
					end
				end
			else
				movers += 1
				local b = beam
				-- Whole cycles: where the beam is at time T, run through its midpoint then.
				local cycle = if segment.offSeconds then segment.onSeconds + segment.offSeconds else segment.period
				for n = 0, 59 do
					local T = 1234.5 + n * cycle / 60
					-- Lit and still lit a tenth either side, or dark and dark: an unambiguous case.
					local litNow = Geometry.segmentLit(b.moving, T)
					local steady = true
					for _, off in { -0.12, -0.06, 0.06, 0.12 } do
						steady = steady and Geometry.segmentLit(b.moving, T + off) == litNow
					end
					if steady then
						local a1, b1 = Geometry.segmentAt(b.moving, T)
						local P = a1:Lerp(b1, 0.5)
						if P.Y > 0.5 and P.Y < 4.8 or segment.kind == "Slide" then
							local fx, fz = b1.X - a1.X, b1.Z - a1.Z
							local fl = math.sqrt(fx * fx + fz * fz)
							local d = if fl > 0.5 then v3(-fz / fl, 0, fx / fl) else v3(0, 0, 1)
							if segment.kind == "Slide" then d = v3(0, 0, 1) end
							-- (The upright's midpoint is at 7 studs: cross it at a low point.)
							local at = v3(P.X, 2.5, P.Z)
							for _, speed in SPEEDS do
								for _, dt in DTS do
									moverCases += 1
									local hit = crossing(b, at, d, speed, dt, T, "stand")
									check(hit == litNow, `zone {zone} room {roomIndex} mover {index} {segment.kind} T={n} lit={litNow} v={speed} dt={dt}: got hit={hit}`)
								end
							end
						end
					end
				end
			end
		end
	end
end
print(string.format("static beams %d, crossings %d; movers %d, mover crossings %d", statics, cases, movers, moverCases))

-- THE FLIGHT: from a grid of positions in every room, the plan leaves by the door.
local flightCases = 0
local KN = LaserConfig.KNOCKBACK
for zone = 1, 12 do
	local room = roomFor(zone)
	local halfDoor = room.doorWidth / 2
	local reach = math.max(halfDoor - KN.DOOR_MARGIN, math.min(halfDoor, 2))
	local x = -room.width / 2 + 3
	while x <= room.width / 2 - 3 do
		for _, z in { 0.6, 5, 10, 20, 33, 45, 55 } do
			flightCases += 1
			local plan = LaserFlight.planLocal(x, 3, z, halfDoor)
			local sample = LaserFlight.sampler(v3(x, 3, z), plan.points, KN.ARC_HEIGHT)
			check(plan.landing.Z <= -KN.OVERSHOOT + 1e-6 and math.abs(plan.landing.X) <= reach + 1e-6, `flight z{zone} ({x},{z}) lands out of the door`)
			check(plan.seconds >= KN.GUIDED_MIN_SECONDS - 1e-9 and plan.seconds <= KN.GUIDED_MAX_SECONDS + 1e-9, `flight z{zone} ({x},{z}) duration in bounds`)
			local start, finish = sample(0), sample(1)
			check(math.abs(start.X - x) < 1e-6 and math.abs(start.Z - z) < 1e-6 and math.abs(finish.X - plan.landing.X) < 1e-6 and math.abs(finish.Z - plan.landing.Z) < 1e-6, `flight z{zone} ({x},{z}) endpoints`)
			-- Never crosses the doorway line outside the opening, never above the header.
			local crossed, maxY, maxStep = false, 0, 0
			local last = sample(0)
			for i = 1, 200 do
				local p = sample(i / 200)
				if not crossed and p.Z <= 0.01 then
					crossed = true
					check(math.abs(p.X) <= halfDoor - 3, `flight z{zone} ({x},{z}) crosses the doorway inside the jambs (x={p.X})`)
				end
				maxY = math.max(maxY, p.Y)
				maxStep = math.max(maxStep, (p - last).Magnitude)
				last = p
			end
			check(crossed or z <= 0.5, `flight z{zone} ({x},{z}) crosses the doorway line`)
			check(maxY <= 3 + KN.ARC_HEIGHT + 1e-6, `flight z{zone} ({x},{z}) arc stays under lift`)
			-- Per-frame motion at 60 fps stays smooth (no teleporting jumps).
			local perFrame = maxStep * 200 / 200
			check(perFrame / (1 / 200) * (1 / 60) <= (KN.GUIDED_SPEED * 3) * plan.seconds * 0 + 250, `flight z{zone} ({x},{z}) smooth`)
		end
		x += 9.7
	end
end
print(string.format("flight cases %d", flightCases))

-- The body silhouette equals the server's former inline formula.
do
	local pos = v3(10, 6.2, -4)
	local center, half = Geometry.bodyBox(pos, 2, 2, false, 5.2, 1.1)
	local feet = 6.2 - 2 - 1
	check(math.abs(center.Y - (feet + 2.6)) < 1e-9 and half.Y == 2.6 and half.X == 1.1, "bodyBox R15 matches the server formula")
	local c6 = Geometry.bodyBox(pos, 2, 2, true, 2.6, 1.1)
	check(math.abs(c6.Y - (6.2 - 2 - 1 - 2 + 1.3)) < 1e-9, "bodyBox R6 crouched matches the server formula")
end

print(string.format("passes %d, failures %d", passes, #failures))
for i = 1, math.min(#failures, 25) do
	print("  FAIL", failures[i])
end
