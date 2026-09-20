--!strict
--[[
	DebugCommands/Lasers (lasers-rework) - Studio only.

	    laserRoutes                 the fairness validator for all 24 rooms:
	                                per room ok / seed / attempts / thinned /
	                                beams by kind / tightest mover window, and
	                                whether a route exists with and without jumps.
	    laserLayout <zone> <room>   the generated beams of one room, room-local.
	    laserTouchTest [zone] [room]
	                                walks the runner into one known beam, with
	                                the movement check ON: launched, guard NOT
	                                woken, landed at / outside the door, a second
	                                touch launches again at once, and a carried
	                                container is dropped at the beam (not lost,
	                                not duplicated) and goes home.
	    laserMoverSync [zone] [room]
	                                every moving beam the detector tests against
	                                the generator's formula at several times.

	laserTouchTest steals a container, so it changes Lifetime.Steals and
	HighestZoneReached on the tester's REAL profile; both are restored however
	it ends. It needs Day, no carry and a base that is not full.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LaserConfig = require(ReplicatedStorage.Shared.Config.LaserConfig)
local LaserPatterns = require(ReplicatedStorage.Shared.LaserPatterns)
local LaserBeams = require(ReplicatedStorage.Shared.LaserBeams)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local Services = script.Parent.Parent
local CarryService = require(Services.CarryService)
local DataService = require(Services.DataService)
local GuardianService = require(Services.GuardianService)
local LaserService = require(Services.LaserService)
local LootService = require(Services.LootService)
local MovementService = require(Services.MovementService)
local NightService = require(Services.NightService)
local RagdollService = require(Services.RagdollService)
local StateService = require(Services.StateService)

local function rootOf(player: Player): BasePart
	local character = assert(player.Character, "no character")
	local root = character:FindFirstChild("HumanoidRootPart")
	assert(root and root:IsA("BasePart"), "no root part")
	return root
end

--- A server move of the runner, declared as one (MovementService stays ON).
local function move(player: Player, at: Vector3)
	local character = assert(player.Character, "no character")
	MovementService.allowTeleport(player)
	character:PivotTo(CFrame.new(at))
	rootOf(player).AssemblyLinearVelocity = Vector3.zero
end

local function waitUntil(seconds: number, done: () -> boolean): boolean
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		if done() then
			return true
		end
		task.wait(0.05)
	end
	return done()
end

local function round(value: number, places: number?): number
	local scale = 10 ^ (places or 2)
	return math.floor(value * scale + 0.5) / scale
end

local function kindsOf(segments: { LaserPatterns.Segment }): string
	local list: { string } = {}
	for kind, count in LaserPatterns.describe(segments) do
		table.insert(list, `{kind}={count}`)
	end
	table.sort(list)
	return table.concat(list, " ")
end

return {
	laserRoutes = function(_player: Player)
		assert(RunService:IsStudio(), "Studio only")
		local rows: { any } = {}
		local lines: { string } = {}
		local failed, beams = 0, 0
		for zone = 1, 12 do
			local room = Layout.laserRoom(zone)
			for roomIndex = 1, Layout.ROOMS_PER_ZONE do
				local started = os.clock()
				local layout = LaserPatterns.forRoom(zone, roomIndex, room)
				local withJump = LaserPatterns.validate(room, layout.segments, true)
				local noJump = LaserPatterns.validate(room, layout.segments, false)
				local required = LaserConfig.zone(zone).requireNoJump
				local ok = layout.report.ok and layout.thinned == 0 and withJump.ok and (noJump.ok or not required)
				if not ok then
					failed += 1
				end
				beams += #layout.segments
				table.insert(rows, {
					zone = zone, room = roomIndex, ok = ok, seed = layout.seed, attempts = layout.attempts, thinned = layout.thinned,
					beams = #layout.segments, movers = layout.report.movers, tightestWindow = layout.report.tightestWindow,
					routeWithJumps = withJump.ok, routeWithoutJumps = noJump.ok, noJumpRequired = required,
					sockets = layout.report.sockets, reasons = layout.report.reasons, kinds = LaserPatterns.describe(layout.segments),
				})
				table.insert(lines, string.format("%s Z%02d R%d beams=%d movers=%d seed=%d attempts=%d thinned=%d window=%s jump=%s nojump=%s%s (%.0f ms)  %s",
					if ok then "PASS" else "FAIL", zone, roomIndex, #layout.segments, layout.report.movers, layout.seed, layout.attempts, layout.thinned,
					if layout.report.tightestWindow then tostring(round(layout.report.tightestWindow)) else "-", tostring(withJump.ok), tostring(noJump.ok),
					if required then "*" else "", (os.clock() - started) * 1000, kindsOf(layout.segments)))
				if #layout.report.reasons > 0 then
					table.insert(lines, "      " .. table.concat(layout.report.reasons, "; "))
				end
			end
		end
		return { pass = failed == 0, failedRooms = failed, totalBeams = beams, lines = lines, rooms = rows }
	end,

	--- LaserService's counters: claimsAccepted / claimsRejected / claimsSnapped
	--- (the client's LaserHit reports), serverApplied (touches the server had
	--- to apply itself), launches, trips, hz, lastStepMs / maxStepMs.
	laserState = function(player: Player)
		return {
			snapshot = LaserService.snapshot(),
			pending = LaserService.hasPending(player),
			ragdolled = RagdollService.isRagdolled(player),
			immune = RagdollService.isImmune(player),
			clientOff = player:GetAttribute("LaserClientOff"),
		}
	end,

	laserLayout = function(_player: Player, zone: number?, roomIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		local z, r = math.clamp(math.floor(tonumber(zone) or 1), 1, 12), math.clamp(math.floor(tonumber(roomIndex) or 1), 1, 2)
		local layout = LaserPatterns.forRoom(z, r, Layout.laserRoom(z))
		local lines: { string } = {}
		for index, s in layout.segments do
			table.insert(lines, string.format("%2d %-10s (%.1f, %.1f, %.1f) -> (%.1f, %.1f, %.1f)%s%s", index, s.kind, s.ax, s.ay, s.az, s.bx, s.by, s.bz,
				if s.period then string.format("  travel (%.1f, %.1f, %.1f) period %.1f phase %.2f", s.tx or 0, s.ty or 0, s.tz or 0, s.period, s.phase or 0) else "",
				if s.offSeconds then string.format("  on %.1f off %.1f", s.onSeconds or 0, s.offSeconds) else ""))
		end
		return { zone = z, room = r, seed = layout.seed, ok = layout.report.ok, kinds = LaserPatterns.describe(layout.segments), lines = lines }
	end,

	laserTouchTest = function(player: Player, zone: number?, roomIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		assert(not NightService.isNight(), "run during Day")
		local z, r = math.clamp(math.floor(tonumber(zone) or 3), 1, 12), math.clamp(math.floor(tonumber(roomIndex) or 2), 1, 2)
		local profile = assert(DataService.get(player), "no profile")
		local saved = { steals = profile.Lifetime.Steals, highest = profile.HighestZoneReached }
		local report: { [string]: any } = { zone = z, room = r }
		local stolen: LootService.LootInstance? = nil
		GuardianService.suspendPatrols(true) -- "the guard did not wake" needs it asleep to start with
		-- The FALLBACK path: a real client would detect and claim the touch itself
		-- (LaserHitController), so it is told to stand down for this test.
		player:SetAttribute("LaserClientOff", true)
		local ok, err = pcall(function()
			NightService.setDayRemaining(260)
			GuardianService.resetAll()
			assert(waitUntil(12, function() return not RagdollService.isImmune(player) and not RagdollService.isRagdolled(player) end), "runner still recovering")

			local layout = LaserPatterns.forRoom(z, r, Layout.laserRoom(z))
			local kind = "Low"
			local lx, lz = LaserPatterns.isolatedPoint(layout.segments, kind, 8)
			if not lx then
				kind = "High"
				lx, lz = LaserPatterns.isolatedPoint(layout.segments, kind, 8)
			end
			assert(lx and lz, "no isolated low or high beam in this room - try another")
			report.beam = `{kind} at local ({round(lx, 1)}, {round(lz, 1)})`
			local frame = Layout.frame(z, r)
			local onBeam = frame:PointToWorldSpace(Vector3.new(lx, 3.2, lz))
			local short = frame:PointToWorldSpace(Vector3.new(lx, 3.2, lz - 4))
			local violationsBefore = MovementService.snapshot(player).player.violations

			local function touch(): boolean
				move(player, short)
				task.wait(0.3)
				move(player, onBeam)
				return waitUntil(1.2, function() return RagdollService.isRagdolled(player) end)
			end
			local function landing(): number
				waitUntil(10, function() return not RagdollService.isRagdolled(player) end)
				return frame:PointToObjectSpace(rootOf(player).Position).Z
			end

			-- 1. EMPTY-HANDED TOUCH.
			player:SetAttribute("LastLaserTrip", nil)
			report.launched = touch()
			report.touchRecorded = player:GetAttribute("LastLaserZone") == z and player:GetAttribute("LastLaserRoom") == r and player:GetAttribute("LastLaserTrip") ~= nil
			local guard = GuardianService.inspect(z, r)
			report.guardStateAfterTouch = guard and guard.state
			report.guardDidNotWake = guard ~= nil and guard.state == "Sleeping" and player:GetAttribute("Chased") ~= true and player:GetAttribute("LaserChased") ~= true
			local landedZ = landing()
			report.landedLocalZ = round(landedZ, 1)
			-- "Outside or near the door": past the doorway line, or on the apron.
			report.landedAtOrOutsideDoor = landedZ < LaserConfig.FIELD.Z_MIN - LaserConfig.VALIDATOR.SIDE_CLEARANCE
			report.stillAlive = (player.Character :: Model):FindFirstChildOfClass("Humanoid") ~= nil and ((player.Character :: Model):FindFirstChildOfClass("Humanoid") :: Humanoid).Health > 0

			-- 2. NO COOLDOWN: as soon as they are up, the next touch throws again.
			assert(waitUntil(5, function() return not RagdollService.isImmune(player) end), "never recovered")
			local upAt = os.clock()
			report.secondTouchLaunched = touch()
			report.secondsFromStandingToSecondLaunch = round(os.clock() - upAt)
			landing()
			assert(waitUntil(5, function() return not RagdollService.isImmune(player) end), "never recovered")

			-- 3. CARRYING: the container drops at the beam and goes home.
			local socket = assert(LootService.getSocket(z, (r - 1) * Layout.ITEMS_PER_ROOM + 2), "no socket")
			local loot = assert(socket.loot, "socket is empty")
			local id, token = loot.id, loot.spawnToken
			move(player, socket.part.Position + Vector3.new(0, 3, 5))
			task.wait(0.2)
			assert(CarryService.trySteal(player, loot), "steal refused (base full?)")
			stolen = loot
			task.wait(0.2)
			report.carriedLaunched = touch()
			report.carryDropped = CarryService.getCarried(player) == nil and loot.state == "Dropped"
			local model = loot.model
			if model then
				local offset = model:GetPivot().Position - onBeam
				report.dropDistanceFromBeam = round(Vector3.new(offset.X, 0, offset.Z).Magnitude, 1)
			end
			report.droppedAtTheBeam = (report.dropDistanceFromBeam or math.huge) < 8
			report.playerNotChasedForIt = player:GetAttribute("Chased") ~= true
			landing()
			-- Home by the ordinary path (the guard's fetch and the drop timers do
			-- this in play; the test does not wait for them).
			if loot.state == "Dropped" then
				LootService.returnToOrigin(loot)
			end
			report.lootBackInSocket = waitUntil(GameConfig.GUARDIAN_RETURN_DELAY + 3, function()
				return socket.loot == loot and loot.state == "Spawned"
			end)
			report.sameLootNotDuplicated = loot.id == id and loot.spawnToken == token
			stolen = nil

			task.wait(2) -- past the stand-up grace: a real violation would show by now
			report.newViolations = MovementService.snapshot(player).player.violations - violationsBefore
			report.pass = report.launched and report.touchRecorded and report.guardDidNotWake and report.landedAtOrOutsideDoor
				and report.secondTouchLaunched and report.carriedLaunched and report.carryDropped and report.droppedAtTheBeam
				and report.playerNotChasedForIt and report.lootBackInSocket and report.sameLootNotDuplicated and report.newViolations == 0
		end)
		-- CLEAN UP, however it ended.
		pcall(function()
			local carried = CarryService.getCarried(player)
			if carried then
				CarryService.reclaim(carried)
			elseif stolen and (stolen :: LootService.LootInstance).state == "Dropped" then
				LootService.returnToOrigin(stolen :: LootService.LootInstance)
			end
		end)
		profile.Lifetime.Steals, profile.HighestZoneReached = saved.steals, saved.highest
		pcall(function()
			waitUntil(10, function() return not RagdollService.isRagdolled(player) end)
			move(player, Vector3.new(0, 4, -16))
		end)
		GuardianService.resetAll()
		GuardianService.suspendPatrols(false)
		player:SetAttribute("LaserClientOff", nil)
		pcall(StateService.pushNow, player)
		report.restoredSteals = profile.Lifetime.Steals == saved.steals
		if not ok then
			report.pass = false
			report.error = tostring(err)
		end
		return report
	end,

	--- THE CLIENT'S CLAIM, without a client. Fires the very entry point the
	--- LaserHit remote calls (LaserService.claim) with synthetic claims:
	---   malformed / absent beam / far away  -> rejected
	---   a real beam the runner stands next to -> accepted: stamped ragdolled
	---     and immune, LastLaser* set, guard asleep, no server launch
	---   a second claim while down            -> rejected
	---   a burst of claims                    -> rate limited
	---   the server detector already holding the same touch, then the claim ->
	---     applied ONCE (by the claim), the server never applies it as well
	--- Nothing flies the body (that is the client's job), so the runner stays
	--- put; the landing check may put it on the landing spot afterwards.
	laserClientClaimTest = function(player: Player, zone: number?, roomIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		assert(not NightService.isNight(), "run during Day")
		local z, r = math.clamp(math.floor(tonumber(zone) or 3), 1, 12), math.clamp(math.floor(tonumber(roomIndex) or 2), 1, 2)
		local report: { [string]: any } = { zone = z, room = r }
		GuardianService.suspendPatrols(true)
		-- The client must not ALSO detect and claim: this is the server's half.
		player:SetAttribute("LaserClientOff", true)
		local ok, err = pcall(function()
			NightService.setDayRemaining(260)
			GuardianService.resetAll()
			assert(waitUntil(12, function() return not RagdollService.isImmune(player) and not RagdollService.isRagdolled(player) end), "runner still recovering")
			local layout = LaserPatterns.forRoom(z, r, Layout.laserRoom(z))
			local lx, lz, id = LaserPatterns.isolatedPoint(layout.segments, "Low", 8)
			if not lx then
				lx, lz, id = LaserPatterns.isolatedPoint(layout.segments, "High", 8)
			end
			assert(lx and lz and id, "no isolated low or high beam in this room - try another")
			local frame = Layout.frame(z, r)
			local onBeam = frame:PointToWorldSpace(Vector3.new(lx, 3.2, lz))
			local beside = frame:PointToWorldSpace(Vector3.new(lx, 3.2, lz - 4))
			report.beamId = id

			-- REJECTED: malformed, absent, far.
			report.malformedRejected = not (LaserService.claim(player, "3", r, id))
			report.fractionRejected = not (LaserService.claim(player, z, r, 1.5))
			move(player, beside)
			task.wait(0.2)
			local okAbsent, whyAbsent = LaserService.claim(player, z, r, 199)
			report.absentBeamRejected = not okAbsent and whyAbsent == "no such beam"
			move(player, Vector3.new(0, 4, MapConfig.zoneCenterZ(if z == 12 then 1 else 12)))
			task.wait(0.3)
			local okFar, whyFar = LaserService.claim(player, z, r, id)
			report.farRejected = not okFar and whyFar == "too far from that beam"
			report.rejectionsChangedNothing = not RagdollService.isRagdolled(player) and player:GetAttribute("LastLaserTrip") == nil

			-- ACCEPTED: next to the beam.
			move(player, beside)
			task.wait(0.4)
			local before = LaserService.snapshot()
			player:SetAttribute("LastLaserTrip", nil)
			local accepted, why = LaserService.claim(player, z, r, id)
			report.accepted, report.acceptedReason = accepted, why
			report.stamped = RagdollService.isRagdolled(player) and RagdollService.isImmune(player)
			report.attributes = player:GetAttribute("LastLaserZone") == z and player:GetAttribute("LastLaserRoom") == r and player:GetAttribute("LastLaserTrip") ~= nil
			local guard = GuardianService.inspect(z, r)
			report.guardStayedAsleep = guard ~= nil and guard.state == "Sleeping"
			local after = LaserService.snapshot()
			report.claimCounted = after.claimsAccepted - before.claimsAccepted == 1
			report.noServerLaunch = after.launches == before.launches
			-- ...and while down, another claim is refused (no second apply).
			local okAgain, whyAgain = LaserService.claim(player, z, r, id)
			report.secondClaimRejected = not okAgain and whyAgain == "already down"

			-- RATE LIMIT: a burst of well-formed claims.
			local limited = 0
			for _ = 1, 12 do
				local _, reason = LaserService.claim(player, z, r, 198)
				if reason == "rate limited" then
					limited += 1
				end
			end
			report.rateLimited = limited > 0
			report.rateLimitedCount = limited

			-- NO DOUBLE APPLY: the server detector finds the same touch, and the
			-- claim beats its grace period.
			assert(waitUntil(10, function() return not RagdollService.isImmune(player) and not RagdollService.isRagdolled(player) end), "runner still down")
			task.wait(1.5) -- the limiter refills
			move(player, beside)
			task.wait(0.4)
			local mid = LaserService.snapshot()
			move(player, onBeam)
			report.serverHeldTheTouch = waitUntil(0.6, function() return LaserService.hasPending(player) or RagdollService.isRagdolled(player) end)
			local claimed, claimWhy = LaserService.claim(player, z, r, id)
			report.claimBeatTheGrace = claimed
			report.claimReason = claimWhy
			task.wait(LaserConfig.CLIENT.CLAIM_GRACE + 0.5)
			local last = LaserService.snapshot()
			report.serverDidNotApplyToo = last.serverApplied == mid.serverApplied and last.launches == mid.launches
			report.pendingCleared = not LaserService.hasPending(player)
			report.pass = report.malformedRejected and report.fractionRejected and report.absentBeamRejected and report.farRejected
				and report.rejectionsChangedNothing and report.accepted and report.stamped and report.attributes and report.guardStayedAsleep
				and report.claimCounted and report.noServerLaunch and report.secondClaimRejected and report.rateLimited
				and report.claimBeatTheGrace and report.serverDidNotApplyToo and report.pendingCleared
		end)
		pcall(function()
			waitUntil(10, function() return not RagdollService.isRagdolled(player) end)
			move(player, Vector3.new(0, 4, -16))
		end)
		player:SetAttribute("LaserClientOff", nil)
		GuardianService.resetAll()
		GuardianService.suspendPatrols(false)
		if not ok then
			report.pass = false
			report.error = tostring(err)
		end
		return report
	end,

	laserMoverSync = function(_player: Player, zone: number?, roomIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		local rows: { any } = {}
		local worst, checked, missing = 0, 0, 0
		local now = workspace:GetServerTimeNow()
		for z = 1, 12 do
			for r = 1, Layout.ROOMS_PER_ZONE do
				if (zone and z ~= zone) or (roomIndex and r ~= roomIndex) then
					continue
				end
				local frame = Layout.frame(z, r)
				-- The beams the detector (and the client) test: shared/LaserBeams,
				-- found by the id the generator's segment order gave them.
				local layout = LaserPatterns.forRoom(z, r, Layout.laserRoom(z))
				for segmentIndex, segment in layout.segments do
					if not LaserPatterns.isMover(segment) then
						continue
					end
					local restA = frame:PointToWorldSpace(Vector3.new(segment.ax, segment.ay, segment.az))
					local travel = frame:VectorToWorldSpace(Vector3.new(segment.tx or 0, segment.ty or 0, segment.tz or 0))
					local match = LaserBeams.find(z, r, segmentIndex)
					local liveSegment = match and match.moving
					if not match or not liveSegment or (match.a - restA).Magnitude > 0.05 then
						missing += 1
						table.insert(rows, { zone = z, room = r, kind = segment.kind, error = "the detector has no such mover" })
						continue
					end
					local maxError, litAgrees = 0, true
					for _, ahead in { 0, 0.37, 1.1, 2.9, 7.3, 61.7 } do
						local t = now + ahead
						local serverA = Geometry.segmentAt(liveSegment, t)
						local formulaA = restA + travel * Geometry.moveFraction(segment.period or 0, segment.phase or 0, t)
						maxError = math.max(maxError, (serverA - formulaA).Magnitude)
						litAgrees = litAgrees and Geometry.segmentLit(liveSegment, t) == Geometry.blinkLit(segment.onSeconds, segment.offSeconds, segment.blinkPhase, t)
					end
					-- The server never moves the part: it is where it was built.
					local livePart = LaserBeams.partOf(match)
					local partStill = livePart ~= nil and livePart:IsA("BasePart") and (livePart.Position - (liveSegment.a + liveSegment.b) / 2).Magnitude < 0.05
					checked += 1
					worst = math.max(worst, maxError)
					table.insert(rows, { zone = z, room = r, kind = segment.kind, maxError = round(maxError, 4), litAgrees = litAgrees, partNeverMovedOnServer = partStill,
						pass = maxError < 0.01 and litAgrees and partStill })
				end
			end
		end
		local pass = missing == 0 and checked > 0
		for _, row in rows do
			pass = pass and row.pass == true
		end
		return { pass = pass, checked = checked, missing = missing, worstError = round(worst, 4), movers = rows }
	end,
}
