--!strict
-- Static beams, server-owned posture, occupied-zone queries at 10 Hz. The
-- client sends only a crouch intent, never a hit/miss, beam or guardian id.
--
-- A TOUCH THROWS YOU OUT OF THE ROOM (lasers-rework, 2026-09-20; owner: "when
-- you touch it, it kicks you backwards towards the exit. Every time you touch
-- it, even without cooldown"). It used to wake the room's guard
-- (GuardianService.alarm) - it no longer does, for a room's beams and a
-- vault's arms alike: the guard sleeps on, nobody is chased, nothing is
-- damaged. The player is ragdolled and thrown in an arc at the doorway
-- (`exitAim`), lands in the corridor, lies there a second and may walk back
-- in. Whatever they were carrying from the museum drops where they touched
-- the beam, through the ordinary CarryService.forceDrop - so the guard
-- fetches it, the thief may grab it back first, and the drop timers send it
-- home: never duplicated, never lost, never out of reach. The only thing
-- that still wakes a guard is leaving the room WITH its loot
-- (GuardianService, MUSEUM DOORWAYS).
--
-- NO COOLDOWN. A thrown player is skipped while the server has them on record
-- as ragdolled (RagdollService.isRagdolled / isImmune - its own tables, never
-- Humanoid.PlatformStand); the moment they are up, the next touch throws them
-- again, including the beam they may be lying in.
--
-- MOVING BEAMS. A room's sliding / bobbing / blinking beams (MuseumGallery
-- writes them as `MovingBeam` parts) are read once at start and tested from
-- the server clock with LaserGeometry.sweptSegmentHit, like the vault's arms.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local LaserConfig = require(ReplicatedStorage.Shared.Config.LaserConfig)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local GuardianService = require(script.Parent.GuardianService)
local LootService = require(script.Parent.LootService)
-- The SERVER's record of a ragdoll, never Humanoid.PlatformStand (client-settable).
local RagdollService = require(script.Parent.RagdollService)
-- No cycle: CarryService requires Loot/Base/Data/Movement only.
local CarryService = require(script.Parent.CarryService)

local LaserService = {}
local KNOCKBACK = LaserConfig.KNOCKBACK
local BODY = LaserConfig.BODY

--- THE ZAP. The LaserAlarm cue rings where the beam was touched, briefly
--- (KNOCKBACK.ZAP_SECONDS - it was a four-second room alarm while a touch
--- woke the guard), for everyone nearby - a static beam, a moving one or
--- one of the vault's rotating arms.
---
--- Parented to the touching player's own root, so it flies out of the room
--- with them, and destroyed on a timer: a looped Sound left behind becomes
--- the room tone. One at a time per player.
local ringing: { [Player]: Sound } = {}

local function ringAlarm(player: Player)
	local existing = ringing[player]
	if existing and existing.Parent then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local sound = Audio.playAt("LaserAlarm", root)
	if not sound then
		return
	end
	ringing[player] = sound
	task.delay(KNOCKBACK.ZAP_SECONDS, function()
		if ringing[player] == sound then
			ringing[player] = nil
		end
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
end
local INTERVAL = 0.1
local limiter = RateLimiter.new(8, 12)
type Sample = { position: Vector3, time: number, character: Model, serverTime: number }
type Field = { index: number, startZ: number, endZ: number, folder: Instance }
local fields: { Field } = {}
--- ROTATING VAULT BEAMS (vaults-crews). Not parts the overlap query can find:
--- the arms exist only as functions of the server clock, tested with
--- Geometry.sweptArmHit. `inside` says whether a position is in the field.
type MovingField = { zoneIndex: number, roomIndex: number, arms: { Geometry.SweepArm }, inside: (Vector3) -> boolean }
local movingFields: { MovingField } = {}
--- A ROOM'S MOVING BEAMS (lasers-rework), by Layout.key(zone, room). Read once
--- from the `MovingBeam` parts MuseumGallery built; the part is only the
--- carrier of the numbers (and what gets the hit flash) - the test is
--- Geometry.sweptSegmentHit against the server clock.
export type RoomMover = { segment: Geometry.MovingSegment, part: BasePart }
local roomMovers: { [number]: { RoomMover } } = {}
local previous: { [Player]: Sample } = {}
local crouched: { [Player]: boolean } = {}
--- os.clock before which a player is not processed as "hit" again
--- (KNOCKBACK.RETRIGGER_GUARD). NOT the old 1.5 s per-room cooldown: it only
--- matters when the launch itself was refused, and is a quarter of a second.
local hitGuard: { [Player]: number } = {}
--- Studio test hook: players the detector ignores (see setExempt).
local exempt: { [Player]: boolean } = {}
--- The Laser Jammer gadget (gadgets-patrols area): os.clock until which the
--- detector ignores this player. Server-owned and time-limited, live and in
--- Studio alike - deliberately NOT the Studio-only `exempt` above.
local jammedUntil: { [Player]: number } = {}
local metrics = { queries = 0, narrowChecks = 0, trips = 0, launches = 0, lastStepMs = 0, maxStepMs = 0 }
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include

local function validBody(player: Player): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then return nil, nil, nil end
	return character, root, humanoid
end

--- Re-derives the player's WalkSpeed after an accepted crouch changes.
--- Injected by init (SpeedService.applyMovement) to keep this file off the
--- movement chain; the crouch cost itself is applied there (security pass B13).
LaserService.onPostureChanged = function(_player: Player) end

--- Whether the server currently holds this player crouched.
function LaserService.isCrouched(player: Player): boolean
	return crouched[player] == true
end

function LaserService.setCrouched(player: Player, wanted: boolean): boolean
	local character, root, humanoid = validBody(player)
	local allowed = character ~= nil and root ~= nil and humanoid ~= nil
		and root.Position.Z >= 0 and root.Position.Z <= MapConfig.LANE_END_Z
		and math.abs(root.Position.X) <= MapConfig.LANE_HALF and not LootService.isClosed()
		and not humanoid.Sit and not humanoid.PlatformStand and not humanoid:GetAttribute("Rooted")
		and not GuardianService.isStunned(player)
	local value = wanted and allowed
	local was = crouched[player] == true
	crouched[player] = if value then true else nil
	if character and character:GetAttribute("LaserCrouched") ~= value then character:SetAttribute("LaserCrouched", value) end
	-- Only on a real change: `step` re-confirms a held crouch ten times a
	-- second, and each of those must not re-derive the speed.
	if was ~= value then
		local ok, err = pcall(function()
			LaserService.onPostureChanged(player)
			return true
		end)
		if not ok then warn(`[LaserService] posture refresh failed for {player.Name}: {err}`) end
	end
	return value
end

-- ==========================================================
-- THE THROW
-- ==========================================================

--- Where a touch in (zoneIndex, roomIndex) at `position` throws the body:
--- the world direction (flat, unit) and the horizontal launch speed.
---
--- AIMED, not "backwards". The arc crosses the doorway line inside the jambs
--- (the crossing point is the player's own x clamped into the opening, so a
--- throw from a far corner of a 140-stud room still goes through the door and
--- not into the front wall beside it) and is sized to land KNOCKBACK.OVERSHOOT
--- studs out in the corridor: speed = distance / KNOCKBACK.FLIGHT_SECONDS.
--- A vault is room VAULT_ROOM with its own, narrower door.
function LaserService.exitAim(zoneIndex: number, roomIndex: number, position: Vector3): (Vector3, number)
	local frame: CFrame, halfDoor: number
	if roomIndex == Layout.VAULT_ROOM then
		frame, halfDoor = Layout.vaultFrame(zoneIndex), Layout.VAULT_DOOR_WIDTH / 2
	else
		frame, halfDoor = Layout.frame(zoneIndex, roomIndex), Layout.DOOR_WIDTH / 2
	end
	local at = frame:PointToObjectSpace(position)
	local reach = math.max(halfDoor - KNOCKBACK.DOOR_MARGIN, math.min(halfDoor, 2))
	local toDoor = Vector3.new(math.clamp(at.X, -reach, reach) - at.X, 0, -at.Z)
	local distance = toDoor.Magnitude
	-- Already on (or past) the doorway line: straight out into the corridor.
	local direction = if at.Z > 0.5 and distance > 1 then toDoor.Unit else Vector3.new(0, 0, -1)
	local beyond = KNOCKBACK.OVERSHOOT
	if at.Z <= 0.5 then
		distance = 0
	elseif distance > 1 then
		-- OVERSHOOT is measured STRAIGHT OUT from the doorway line. A throw from
		-- far along the front wall leaves the door at a shallow angle, so it has
		-- to travel further past the line to end up that deep in the corridor
		-- (which runs the zone's whole length: sideways drift costs nothing).
		beyond = math.min(KNOCKBACK.OVERSHOOT * distance / math.max(at.Z, 1), KNOCKBACK.OVERSHOOT_MAX)
	end
	local speed = math.clamp((distance + beyond) / KNOCKBACK.FLIGHT_SECONDS, KNOCKBACK.MIN_SPEED, KNOCKBACK.MAX_SPEED)
	return frame:VectorToWorldSpace(direction), speed
end

--- THE FLIGHT PATH for a touch at `position`: world points to fly through
--- (the doorway, when the body is not already lined up with it, then the
--- landing spot KNOCKBACK.OVERSHOOT studs out in the corridor) and how long
--- the flight takes at KNOCKBACK.GUIDED_SPEED.
function LaserService.exitPath(zoneIndex: number, roomIndex: number, position: Vector3): ({ Vector3 }, number)
	local frame: CFrame, halfDoor: number
	if roomIndex == Layout.VAULT_ROOM then
		frame, halfDoor = Layout.vaultFrame(zoneIndex), Layout.VAULT_DOOR_WIDTH / 2
	else
		frame, halfDoor = Layout.frame(zoneIndex, roomIndex), Layout.DOOR_WIDTH / 2
	end
	local at = frame:PointToObjectSpace(position)
	local reach = math.max(halfDoor - KNOCKBACK.DOOR_MARGIN, math.min(halfDoor, 2))
	local doorX = math.clamp(at.X, -reach, reach)
	local points: { Vector3 } = {}
	local length = 0
	local from = at
	-- Off to one side of the opening: fly to the doorway first, then out.
	if at.Z > 0.5 and math.abs(at.X - doorX) > 1 then
		local door = Vector3.new(doorX, at.Y, 0)
		table.insert(points, frame:PointToWorldSpace(door))
		length += (door - from).Magnitude
		from = door
	end
	local landing = Vector3.new(doorX, at.Y, math.min(from.Z, 0) - KNOCKBACK.OVERSHOOT)
	table.insert(points, frame:PointToWorldSpace(landing))
	length += (landing - from).Magnitude
	return points, math.clamp(length / KNOCKBACK.GUIDED_SPEED, KNOCKBACK.GUIDED_MIN_SECONDS, KNOCKBACK.GUIDED_MAX_SECONDS)
end

--- One touch. `beam` is the part that gets the red flash on every client
--- (its `HitAt` attribute, server time; LaserFxController) - nil for a vault
--- arm, which has no part of its own on the server's side of the test.
local function hit(player: Player, root: BasePart, zoneIndex: number, roomIndex: number, beam: BasePart?, now: number)
	hitGuard[player] = now + KNOCKBACK.RETRIGGER_GUARD
	metrics.trips += 1
	-- AnalyticsSession watches LastLaserTrip ("LaserTouched"); ChaseWarning and
	-- the camera shake (LaserFxController) read it too. Same names as ever.
	player:SetAttribute("LastLaserZone", zoneIndex)
	player:SetAttribute("LastLaserRoom", roomIndex)
	player:SetAttribute("LastLaserTrip", workspace:GetServerTimeNow())
	if beam then
		beam:SetAttribute("HitAt", workspace:GetServerTimeNow())
	end

	-- THE CARRY DROPS WHERE THE BEAM WAS TOUCHED, before the launch (the same
	-- order as a bat hit), through the one drop path there is. Museum loot
	-- only: a stolen BASE item has no business with a museum beam, and
	-- forceDrop would hand it straight back to its owner.
	local carried = CarryService.getCarried(player)
	if carried and not carried.heist and carried.zoneIndex >= 1 then
		local ok, err = pcall(function()
			CarryService.forceDrop(carried)
			return true
		end)
		if not ok then
			warn(`[LaserService] drop failed for {player.Name}: {err}`)
		end
	end

	-- RagdollService.launch pushes AWAY from a point, so the point is put
	-- behind the body on the line to the door. It also takes network
	-- ownership, calls MovementService.allowTeleport either side of the
	-- flight, damps a point-blank wall and nets a body that leaves the map.
	local direction, speed = LaserService.exitAim(zoneIndex, roomIndex, root.Position)
	-- GUIDED, not thrown (2026-09-20): through the doorway and out into the
	-- corridor from ANYWHERE in the room. See RagdollService LaunchOptions.path.
	local path, seconds = LaserService.exitPath(zoneIndex, roomIndex, root.Position)
	local launched = RagdollService.launch(player, root.Position - direction * 10, {
		knockback = speed,
		lift = KNOCKBACK.ARC_HEIGHT,
		stun = seconds + 0.05,
		groundStun = KNOCKBACK.GROUND_STUN,
		immunity = KNOCKBACK.IMMUNITY + seconds,
		path = path,
		pathSeconds = seconds,
	})
	if launched then
		metrics.launches += 1
	end
	ringAlarm(player)
end

local function step()
	local started = os.clock()
	local closed = LootService.isClosed()
	for _, player in Players:GetPlayers() do
		local character, root, humanoid = validBody(player)
		if not character or not root or not humanoid or closed or root.Position.Z < 0
			or math.abs(root.Position.X) > MapConfig.LANE_HALF or RagdollService.isRagdolled(player) or GuardianService.isStunned(player) then
			previous[player] = nil
			if crouched[player] then LaserService.setCrouched(player, false) end
			continue
		end
		if exempt[player] then previous[player] = nil; continue end
		-- Jammed: no sample is kept either, so the first sample after the jam
		-- ends is a fresh one and never sweeps back across the jammed path.
		local jam = jammedUntil[player]
		if jam then
			if jam > started then previous[player] = nil; continue end
			jammedUntil[player] = nil
			player:SetAttribute("GadgetJamUntil", nil)
		end
		if crouched[player] then LaserService.setCrouched(player, true) end
		-- Feet follow the actual rig, so jumping clears low beams. Crouching
		-- changes this laser silhouette AND costs walk speed (applied through
		-- CarryService.applyMovement; SecurityConfig.CROUCH_SPEED_MULTIPLIER).
		local leg = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else 0
		local feet = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2 - leg
		-- The silhouettes are LaserConfig.BODY: the fairness validator walks the
		-- same body through every generated room (shared/LaserPatterns).
		local height = if crouched[player] then BODY.CROUCH_HEIGHT else BODY.STAND_HEIGHT
		local center = Vector3.new(root.Position.X, feet + height / 2, root.Position.Z)
		local half = Vector3.new(BODY.HALF_WIDTH, height / 2, BODY.HALF_WIDTH)
		local old = previous[player]
		local from = center
		local serverNow = workspace:GetServerTimeNow()
		local serverFrom = serverNow - INTERVAL
		-- Ignore a teleport sweep, never the destination overlap. The generous
		-- bound allows the existing maximum walk speed and network batching.
		if old and old.character == character then
			local elapsed = math.min(started - old.time, 0.5)
			if (root.Position - old.position).Magnitude <= math.max(24, humanoid.WalkSpeed * elapsed * 2 + 8) then
				from = center + old.position - root.Position
				serverFrom = math.max(old.serverTime, serverNow - 0.5)
			end
		end
		previous[player] = { position = root.Position, character = character, time = started, serverTime = serverNow }
		-- Only the refused-launch guard (see hitGuard): a thrown player never
		-- gets this far, they are skipped above for the whole flight.
		if (hitGuard[player] or 0) > started then
			continue
		end
		-- ONE TOUCH PER STEP. The first beam found throws the player; testing
		-- the rest against a body that is already leaving would be noise.
		local struck = false
		-- [vaults-crews] The rotating vault arms: the same touch as a static
		-- beam, thrown at the vault's own door. (VaultService's rules - the
		-- lock, the lockout, the pedestal reach - never depended on the alarm.)
		for _, field in movingFields do
			if not field.inside(root.Position) then
				continue
			end
			for _, arm in field.arms do
				metrics.narrowChecks += 1
				if Geometry.sweptArmHit(arm, serverFrom, serverNow, from, center, half) then
					hit(player, root, field.zoneIndex, field.roomIndex, nil, started)
					struck = true
					break
				end
			end
			if struck then
				break
			end
		end
		if struck then
			continue
		end
		-- [lasers-rework] The room's own moving beams, by the room the body is in
		-- (a body in the doorway strip counts: locate's rooms start at the facade).
		local zoneHere, roomHere = Layout.locate(root.Position)
		local movers = if zoneHere and roomHere then roomMovers[Layout.key(zoneHere, roomHere)] else nil
		if movers and zoneHere and roomHere then
			for _, mover in movers do
				metrics.narrowChecks += 1
				if Geometry.sweptSegmentHit(mover.segment, serverFrom, serverNow, from, center, half) then
					hit(player, root, zoneHere, roomHere, mover.part, started)
					struck = true
					break
				end
			end
		end
		if struck then
			continue
		end
		local containers: { Instance } = {}
		for _, field in fields do
			if math.max(from.Z, center.Z) + half.Z >= field.startZ and math.min(from.Z, center.Z) - half.Z <= field.endZ then
				table.insert(containers, field.folder)
			end
		end
		if #containers == 0 then continue end
		-- ONE OverlapParams, re-pointed per query (security pass B13b), rather
		-- than a fresh one for every player on every tick.
		local params = overlap
		params.FilterDescendantsInstances = containers
		local delta = center - from
		local size = Vector3.new(math.abs(delta.X), math.abs(delta.Y), math.abs(delta.Z)) + half * 2 + Vector3.one * 0.2
		local candidates = workspace:GetPartBoundsInBox(CFrame.new((from + center) / 2), size, params)
		metrics.queries += 1
		for _, beam in candidates do
			local a, b = beam:GetAttribute("A"), beam:GetAttribute("B")
			if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then continue end
			local index = beam:GetAttribute("ZoneIndex")
			local room = beam:GetAttribute("RoomIndex")
			if type(room) ~= "number" then continue end
			if type(index) ~= "number" then continue end
			metrics.narrowChecks += 1
			if Geometry.sweptBoxHit(a, b, from, center, half) then
				hit(player, root, index, room, beam, started)
				break
			end
		end
	end
	metrics.lastStepMs = (os.clock() - started) * 1000
	metrics.maxStepMs = math.max(metrics.maxStepMs, metrics.lastStepMs)
end

--- Studio only. Lets an audit drive a player through a room to measure the
--- doorway rule on its own, without its route tripping a beam. Ignored live.
function LaserService.setExempt(player: Player, on: boolean)
	if RunService:IsStudio() then
		exempt[player] = if on then true else nil
	end
end

--- The Laser Jammer. The detector ignores `player` for `seconds` (server
--- clock). A second jam extends, never shortens. The replicated
--- `GadgetJamUntil` attribute (server time) is presentation only: every
--- client draws the effect on the jammed player, and the jammed player's own
--- client flickers the beams (GadgetFxController).
function LaserService.jam(player: Player, seconds: number): boolean
	if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 then
		return false
	end
	local now = os.clock()
	local untilTime = math.max(jammedUntil[player] or 0, now + math.min(seconds, 30))
	jammedUntil[player] = untilTime
	player:SetAttribute("GadgetJamUntil", workspace:GetServerTimeNow() + (untilTime - now))
	return true
end

function LaserService.isJammed(player: Player): boolean
	return (jammedUntil[player] or 0) > os.clock()
end

--- Ends a jam at once (Night, debug cleanup).
function LaserService.clearJam(player: Player)
	jammedUntil[player] = nil
	player:SetAttribute("GadgetJamUntil", nil)
end

function LaserService.snapshot(): any
	local out: any = table.clone(metrics)
	out.fields, out.hz = #fields, 1 / INTERVAL
	out.movingFields = #movingFields
	local movers = 0
	for _, list in roomMovers do
		movers += #list
	end
	out.roomMovers = movers
	return out
end

--- The moving beams the detector tests in one room (debug: laserMoverSync).
function LaserService.moversIn(zoneIndex: number, roomIndex: number): { RoomMover }
	return roomMovers[Layout.key(zoneIndex, roomIndex)] or {}
end

--- Registers a field of rotating arms (vaults-crews: VaultService, one per
--- vault). A player whose root is `inside` it is swept against every arm on
--- each step; a touch wakes the guard of (zoneIndex, roomIndex).
function LaserService.addMovingField(zoneIndex: number, roomIndex: number, arms: { Geometry.SweepArm }, inside: (Vector3) -> boolean)
	table.insert(movingFields, { zoneIndex = zoneIndex, roomIndex = roomIndex, arms = arms, inside = inside })
end

function LaserService.start()
	for _, zone in workspace.Map.Zones:GetChildren() do
		local index = zone:GetAttribute("ZoneIndex")
		local field = zone:FindFirstChild("Lasers")
		if type(index) == "number" and index >= 1 and field then
			table.insert(fields, { index = index, startZ = MapConfig.zoneStartZ(index), endZ = MapConfig.zoneEndZ(index), folder = field })
			-- [lasers-rework] The room's moving beams: numbers off the part, once.
			for _, beam in field:GetChildren() do
				local restA, restB, travel = beam:GetAttribute("RestA"), beam:GetAttribute("RestB"), beam:GetAttribute("Travel")
				local room = beam:GetAttribute("RoomIndex")
				if not beam:IsA("BasePart") or typeof(restA) ~= "Vector3" or typeof(restB) ~= "Vector3" or typeof(travel) ~= "Vector3" or type(room) ~= "number" then
					continue
				end
				local key = Layout.key(index, room)
				local list = roomMovers[key] or {}
				roomMovers[key] = list
				table.insert(list, {
					part = beam,
					segment = {
						a = restA, b = restB, travel = travel,
						period = tonumber(beam:GetAttribute("Period")) or 0,
						phase = tonumber(beam:GetAttribute("Phase")) or 0,
						onSeconds = tonumber(beam:GetAttribute("OnSeconds")),
						offSeconds = tonumber(beam:GetAttribute("OffSeconds")),
						blinkPhase = tonumber(beam:GetAttribute("BlinkPhase")),
					},
				})
			end
		end
	end
	Remotes.get("CrouchRequest").OnServerEvent:Connect(function(player, wanted)
		if type(wanted) == "boolean" and limiter:consume(player) then LaserService.setCrouched(player, wanted) end
	end)
	local function watch(player: Player)
		player.CharacterAdded:Connect(function()
			local wasCrouched = crouched[player]
			previous[player], crouched[player], hitGuard[player] = nil, nil, nil
			-- Nor does a jam: it belonged to the body that used it.
			if jammedUntil[player] then LaserService.clearJam(player) end
			-- A crouch does not survive a respawn, and neither may its speed cost.
			if wasCrouched then task.defer(LaserService.onPostureChanged, player) end
		end)
	end
	for _, player in Players:GetPlayers() do watch(player) end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player)
		previous[player], crouched[player], hitGuard[player] = nil, nil, nil
		exempt[player] = nil
		jammedUntil[player] = nil
		limiter:release(player)
	end)
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated >= INTERVAL then accumulated = 0; step() end
	end)
end

return LaserService
