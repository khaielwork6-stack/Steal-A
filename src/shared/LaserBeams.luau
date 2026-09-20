--!strict
--[[
	LaserBeams (lasers-rework, client-side hits)
	Reads the museum rooms' beam PARTS (workspace.Map.Zones.<zone>.Lasers,
	built by MuseumGallery) into LaserGeometry.Beam data, indexed by room, and
	answers "which beam is number N of room R". The server (LaserService, for
	the fallback detector and for validating a client's claim) and the client
	(LaserHitController, for instant detection) both read beams through this
	one module, so a beam id means the same thing on both sides.

	A beam part carries: ZoneIndex, RoomIndex, BeamId (1..n within its room,
	the generator's segment order), Kind, and either A / B (static, world end
	points) or RestA / RestB / Travel / Period / Phase / OnSeconds / OffSeconds /
	BlinkPhase (moving; a pure function of the server clock).

	Instances are read once and cached; a moving beam's numbers never change.
]]


local Geometry = require(script.Parent.Util.LaserGeometry)
local Layout = require(script.Parent.MuseumLayout)

local LaserBeams = {}

export type Beam = Geometry.Beam

local rooms: { [number]: { Beam } } = {}
local ids: { [number]: { [number]: Beam } } = {}
local known: { [Instance]: boolean } = {}
local parts: { [Beam]: Instance } = {}

--- The part a beam was read from (the flash and the mover's pose live there).
function LaserBeams.partOf(beam: Beam): Instance?
	return parts[beam]
end

--- Reads one part. Nil when it is not a (complete) beam yet.
function LaserBeams.read(part: Instance): Beam?
	if not part:IsA("BasePart") then
		return nil
	end
	local zone, room, id = part:GetAttribute("ZoneIndex"), part:GetAttribute("RoomIndex"), part:GetAttribute("BeamId")
	if type(zone) ~= "number" or type(room) ~= "number" or type(id) ~= "number" then
		return nil
	end
	local a, b = part:GetAttribute("A"), part:GetAttribute("B")
	if typeof(a) == "Vector3" and typeof(b) == "Vector3" then
		local lo, hi = Geometry.beamBounds(a, b, nil)
		return { id = id, zone = zone, room = room, a = a, b = b, moving = nil, min = lo, max = hi }
	end
	local restA, restB, travel = part:GetAttribute("RestA"), part:GetAttribute("RestB"), part:GetAttribute("Travel")
	if typeof(restA) ~= "Vector3" or typeof(restB) ~= "Vector3" or typeof(travel) ~= "Vector3" then
		return nil
	end
	local lo, hi = Geometry.beamBounds(restA, restB, travel)
	return {
		id = id, zone = zone, room = room, a = restA, b = restB, min = lo, max = hi,
		moving = {
			a = restA, b = restB, travel = travel,
			period = tonumber(part:GetAttribute("Period")) or 0,
			phase = tonumber(part:GetAttribute("Phase")) or 0,
			onSeconds = tonumber(part:GetAttribute("OnSeconds")),
			offSeconds = tonumber(part:GetAttribute("OffSeconds")),
			blinkPhase = tonumber(part:GetAttribute("BlinkPhase")),
		},
	}
end

--- Adds a part (idempotent). Returns whether it is now a known beam.
function LaserBeams.add(part: Instance): boolean
	if known[part] then
		return true
	end
	local beam = LaserBeams.read(part)
	if not beam then
		return false
	end
	known[part] = true
	parts[beam] = part
	local key = Layout.key(beam.zone, beam.room)
	local list = rooms[key] or {}
	rooms[key] = list
	table.insert(list, beam)
	local byId = ids[key] or {}
	ids[key] = byId
	byId[beam.id] = beam
	return true
end

--- Reads every beam of a `Lasers` folder.
function LaserBeams.scan(folder: Instance)
	for _, part in folder:GetChildren() do
		LaserBeams.add(part)
	end
end

--- The beams of one room (empty until scanned).
function LaserBeams.room(zone: number, room: number): { Beam }
	return rooms[Layout.key(zone, room)] or {}
end

--- Beam number `id` of a room, or nil.
function LaserBeams.find(zone: number, room: number, id: number): Beam?
	local byId = ids[Layout.key(zone, room)]
	return if byId then byId[id] else nil
end

--- How far `point` is from the space a beam can ever occupy (studs; 0 inside
--- its bounds). Deliberately coarse: it is used for PLAUSIBILITY, not touch.
function LaserBeams.distance(beam: Beam, point: Vector3): number
	local dx = math.max(beam.min.X - point.X, 0, point.X - beam.max.X)
	local dy = math.max(beam.min.Y - point.Y, 0, point.Y - beam.max.Y)
	local dz = math.max(beam.min.Z - point.Z, 0, point.Z - beam.max.Z)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return LaserBeams
