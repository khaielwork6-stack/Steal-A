--!strict
--[[
	LaserFlight (lasers-rework, client-side hits)
	The path a body flies when a laser hits it: through the room's doorway (when
	it is off to one side) and out into the corridor, on an arc. PURE geometry,
	shared by the two places that fly a body so they can never disagree:

	  * the player's own CLIENT (LaserHitController) - the normal case. The
	    client owns its character's physics, so it flies the body itself, every
	    frame, with no server writes and no network-ownership change: that is
	    what makes the throw smooth instead of a 20 Hz snapshot slideshow.
	  * the SERVER (RagdollService.launch `path`), only for a touch the client
	    never reported (LaserService's fallback detector).

	`plan` / `planLocal` say where to go and for how long; `sampler` turns that
	into a position for any fraction of the flight. Nothing here touches an
	instance except through the CFrame `plan` is given, and `planLocal` /
	`sampler` need nothing but Vector3 (so they run in the offline luau CLI).
]]

local LaserConfig = require(script.Parent.Config.LaserConfig)

local LaserFlight = {}

export type Plan = {
	--- Where to fly through, in order, ending at the landing spot.
	points: { Vector3 },
	--- How long the flight takes, end to end.
	seconds: number,
	landing: Vector3,
}

--- The plan for a body at ROOM-LOCAL (x, y, z) (0 = the middle of the doorway,
--- z into the room) in a room whose opening is `halfDoor` wide each side.
--- Points are room-local too.
function LaserFlight.planLocal(x: number, y: number, z: number, halfDoor: number): Plan
	local knock = LaserConfig.KNOCKBACK
	local reach = math.max(halfDoor - knock.DOOR_MARGIN, math.min(halfDoor, 2))
	local doorX = math.clamp(x, -reach, reach)
	local points: { Vector3 } = {}
	local length = 0
	local from = Vector3.new(x, y, z)
	-- Off to one side of the opening: fly to the doorway first, then out.
	if z > 0.5 and math.abs(x - doorX) > 1 then
		local door = Vector3.new(doorX, y, 0)
		table.insert(points, door)
		length += (door - from).Magnitude
		from = door
	end
	local landing = Vector3.new(doorX, y, math.min(from.Z, 0) - knock.OVERSHOOT)
	table.insert(points, landing)
	length += (landing - from).Magnitude
	return {
		points = points,
		seconds = math.clamp(length / knock.GUIDED_SPEED, knock.GUIDED_MIN_SECONDS, knock.GUIDED_MAX_SECONDS),
		landing = landing,
	}
end

--- The same, in WORLD space: `frame` is the room's (or vault's) frame from
--- MuseumLayout, `position` a world position.
function LaserFlight.plan(frame: CFrame, halfDoor: number, position: Vector3): Plan
	local at = frame:PointToObjectSpace(position)
	local inRoom = LaserFlight.planLocal(at.X, at.Y, at.Z, halfDoor)
	local points: { Vector3 } = {}
	for _, point in inRoom.points do
		table.insert(points, frame:PointToWorldSpace(point))
	end
	return { points = points, seconds = inRoom.seconds, landing = frame:PointToWorldSpace(inRoom.landing) }
end

--- A position along the flight for `t` in 0..1: constant speed along the
--- polyline start -> points, `lift` studs higher than the straight line at the
--- middle (a parabola), so it reads as an arc. Built once, called every frame.
function LaserFlight.sampler(start: Vector3, points: { Vector3 }, lift: number): (number) -> Vector3
	local all: { Vector3 } = { start }
	for _, point in points do
		table.insert(all, point)
	end
	local lengths: { number } = {}
	local total = 0
	for index = 2, #all do
		local length = (all[index] - all[index - 1]).Magnitude
		lengths[index - 1] = length
		total += length
	end
	local startY, endY = all[1].Y, all[#all].Y
	return function(t: number): Vector3
		t = math.clamp(t, 0, 1)
		local along = total * t
		local position = all[#all]
		for index = 1, #lengths do
			if along <= lengths[index] or index == #lengths then
				local fraction = if lengths[index] > 0 then math.clamp(along / lengths[index], 0, 1) else 1
				position = all[index]:Lerp(all[index + 1], fraction)
				break
			end
			along -= lengths[index]
		end
		return Vector3.new(position.X, startY + (endY - startY) * t + 4 * lift * t * (1 - t), position.Z)
	end
end

return LaserFlight
