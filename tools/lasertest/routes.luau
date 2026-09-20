local LaserPatterns = require("./LaserPatterns")
local LaserConfig = require("./Config/LaserConfig")

local LENGTHS = { 97.5304946899414, 146.10552978515625, 211.0, 236.1, 324.1, 385.1109924316406, 429.1, 505.1, 640.1, 505.1, 637.1, 763.1109619140625 }
local function roomFor(zone)
	local width = math.min(LENGTHS[zone] - 8, 140)
	return { width = width, depth = 58, doorWidth = 40, socketXs = { -0.36 * width, -0.18 * width, 0.18 * width, 0.36 * width }, socketZ = 45 }
end

local totalStart = os.clock()
local totalSegments = 0
for zone = 1, 12 do
	for roomIndex = 1, 2 do
		local room = roomFor(zone)
		local started = os.clock()
		local result = LaserPatterns.forRoom(zone, roomIndex, room)
		local ms = (os.clock() - started) * 1000
		local kinds = {}
		for kind, count in LaserPatterns.describe(result.segments) do
			table.insert(kinds, kind .. "=" .. count)
		end
		table.sort(kinds)
		totalSegments += #result.segments
		-- Also: does a jumping route exist / does a no-jump route exist?
		local withJump = LaserPatterns.validate(room, result.segments, true)
		local noJump = LaserPatterns.validate(room, result.segments, false)
		print(string.format("Z%02d R%d ok=%s seed=%d attempts=%d thinned=%d segs=%d movers=%d window=%s jump=%s nojump=%s %.0fms  %s",
			zone, roomIndex, tostring(result.report.ok), result.seed, result.attempts, result.thinned, #result.segments,
			result.report.movers, tostring(result.report.tightestWindow), tostring(withJump.ok), tostring(noJump.ok), ms, table.concat(kinds, " ")))
		if not result.report.ok then
			for _, reason in result.report.reasons do print("   ", reason) end
		end
	end
end
print(string.format("total %.0f ms, %d segments", (os.clock() - totalStart) * 1000, totalSegments))

-- ASCII dump of one room
local function dump(zone, roomIndex)
	local room = roomFor(zone)
	local result = LaserPatterns.forRoom(zone, roomIndex, room)
	print(("--- zone %d room %d ---"):format(zone, roomIndex))
	for _, s in result.segments do
		print(string.format("  %-10s (%.1f,%.1f,%.1f)->(%.1f,%.1f,%.1f) travel=(%s,%s,%s) period=%s phase=%s on=%s off=%s",
			s.kind, s.ax, s.ay, s.az, s.bx, s.by, s.bz, tostring(s.tx), tostring(s.ty), tostring(s.tz), tostring(s.period), tostring(s.phase), tostring(s.onSeconds), tostring(s.offSeconds)))
	end
end
dump(1, 1)
dump(3, 2)
dump(7, 1)
dump(12, 1)

-- Sanity: an impossible room must fail.
local room = roomFor(5)
local wall = room.width / 2 - 2.4
local blocked = LaserPatterns.validate(room, { { kind = "Mid", ax = -wall, ay = 2.5, az = 20, bx = wall, by = 2.5, bz = 20 } }, true)
print("full-width mid wall ok? (want false)", blocked.ok, blocked.reasons[1])
local lowOnly = { { kind = "Low", ax = -wall, ay = 0.8, az = 20, bx = wall, by = 0.8, bz = 20 } }
print("full-width low: jump ok (want true)", LaserPatterns.validate(room, lowOnly, true).ok, " nojump ok (want false)", LaserPatterns.validate(room, lowOnly, false).ok)
local highOnly = { { kind = "High", ax = -wall, ay = 4.5, az = 20, bx = wall, by = 4.5, bz = 20 } }
print("full-width high: nojump ok (want true)", LaserPatterns.validate(room, highOnly, false).ok)
local gate = { lowOnly[1], { kind = "High", ax = -wall, ay = 4.5, az = 25, bx = wall, by = 4.5, bz = 25 } }
print("gate low@20 high@25: jump ok (want true)", LaserPatterns.validate(room, gate, true).ok)
local tight = { lowOnly[1], { kind = "High", ax = -wall, ay = 4.5, az = 23, bx = wall, by = 4.5, bz = 23 } }
print("gate low@20 high@23: jump ok (want false)", LaserPatterns.validate(room, tight, true).ok)
local blink = { { kind = "Blink", ax = -wall, ay = 2.5, az = 20, bx = wall, by = 2.5, bz = 20, onSeconds = 2.5, offSeconds = 1.9, blinkPhase = 0 } }
local r = LaserPatterns.validate(room, blink, false)
print("full-width blink off 1.9: ok (want true)", r.ok, r.tightestWindow)
blink[1].offSeconds = 1.0
r = LaserPatterns.validate(room, blink, false)
print("full-width blink off 1.0: ok (want false)", r.ok, r.tightestWindow)
local bob = { { kind = "Bob", ax = -wall, ay = 0.8, az = 20, bx = wall, by = 0.8, bz = 20, tx = 0, ty = 3.7, tz = 0, period = 5, phase = 0 } }
r = LaserPatterns.validate(room, bob, false)
print("full-width bob P5: nojump ok (want true)", r.ok, r.tightestWindow)
bob[1].period = 2.5
r = LaserPatterns.validate(room, bob, true)
print("full-width bob P2.5: ok (want false)", r.ok, r.tightestWindow)
