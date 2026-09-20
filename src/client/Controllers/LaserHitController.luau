--!strict
--[[
	LaserHitController (lasers-rework, client-side hits)
	Detects a laser touch on the player's OWN client, the frame it happens, and
	flies the player's own character out of the room. The server validates and
	records it (LaserService.claim); it does not fly the body.

	WHY. The first real playtest: "I always PASS it before it hits me" and "it
	seems like my FPS is dropping". The server tested at 10 Hz from replicated
	positions - a 260 stud/s runner covers 26 studs between samples, plus a
	network trip, so the touch was noticed after the body had gone past the
	beam - and then flew the body itself after taking its network ownership, so
	the client saw its own character as ~20 Hz snapshots. The client owns its
	character's physics; doing both here is instant and smooth, with no
	per-frame remote traffic and no server writes to the character.

	DETECTION. Every frame, before the camera: the swept body (previous frame's
	position -> this frame's, so a fast runner cannot tunnel) against the beams
	of the room the body is in. The silhouette and the beam test are the shared
	LaserGeometry.bodyBox / beamHit - the same code the server's fallback
	detector runs - and moving beams are pure functions of
	workspace:GetServerTimeNow(), like the drawn ones. The crouch used is the
	one the player asked for (CrouchController.isCrouched), so pressing crouch
	just before a beam counts at once.

	STANDS DOWN when: the Jammer is active (player attr GadgetJamUntil), it is
	Night, the museum is closed to the body (outside the lane), the server has
	the body immune / ragdolled (character attr RagdollImmuneUntil - a guard's
	catch, a bat hit, the tail of a flight), the humanoid is PlatformStanding or
	seated, Studio's setExempt is on (player attr LaserExempt), or the debug
	`LaserClientOff` attribute is set (laserTouchTest uses it to exercise the
	server's fallback).

	THE FLIGHT. shared/LaserFlight: the same path the server's guided launch
	flies - through the doorway when the body is off to one side, then out into
	the corridor, on an arc, tumbling - sampled once per frame and written to
	the root's CFrame with zero velocity (the Humanoid is PlatformStanding, so
	the limbs trail limply behind). Then a short ground stun, the stand-up and
	control back. No ownership change, no server write.

	REPORTING. One LaserHit(zone, room, beamId) at the moment of the touch. A
	rejected claim is silent; the flight has already happened. A body that
	touches a beam and never reports (a cheat client, a stalled one) is hit by
	the server's own detector a quarter of a second later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local LaserConfig = require(ReplicatedStorage.Shared.Config.LaserConfig)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)
local LaserBeams = require(ReplicatedStorage.Shared.LaserBeams)
local LaserFlight = require(ReplicatedStorage.Shared.LaserFlight)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CrouchController = require(script.Parent.CrouchController)
local LaserFxController = require(script.Parent.LaserFxController)

local LaserHitController = {}

local player = Players.LocalPlayer
local KNOCKBACK = LaserConfig.KNOCKBACK
local BODY = LaserConfig.BODY
local BINDING = "LaserHitStep"
--- Tumble, radians per second about each axis (a random sign each flight).
local TUMBLE = Vector3.new(7, 3, 7)
--- A room with no beams read yet is rescanned at most this often (seconds).
local RESCAN_SECONDS = 3

type Sample = { position: Vector3, time: number, serverTime: number, character: Model }
type Flight = {
	character: Model,
	root: BasePart,
	humanoid: Humanoid,
	began: number,
	seconds: number,
	at: (number) -> Vector3,
	rotation: CFrame,
	spin: Vector3,
	lastStep: number,
	last: Vector3, -- the direction of the last leg, for the slide
	origin: Vector3, -- where the flight began (the recovery net)
	standAt: number?, -- os.clock the ground stun ends, once landed
	zone: number,
}

local previous: Sample? = nil
local flight: Flight? = nil
local remote: RemoteEvent? = nil
local lasersFolders: { [number]: Instance } = {}
local rescanned: { [number]: number } = {}

-- ==========================================================
-- BEAMS
-- ==========================================================

local function addWithRetry(part: Instance, attempt: number)
	if LaserBeams.add(part) or attempt >= 4 then
		return
	end
	-- Attributes replicate with the part, but a beam that arrives half-built
	-- is tried again a moment later rather than silently never counting.
	task.delay(0.5, addWithRetry, part, attempt + 1)
end

local function watchFolder(zoneIndex: number, folder: Instance)
	lasersFolders[zoneIndex] = folder
	LaserBeams.scan(folder)
	folder.ChildAdded:Connect(function(child)
		addWithRetry(child, 1)
	end)
end

-- ==========================================================
-- THE FLIGHT
-- ==========================================================

local function endFlight(current: Flight, rescue: boolean)
	if flight ~= current then
		return
	end
	flight = nil
	previous = nil
	if not current.humanoid.Parent or current.humanoid.Health <= 0 then
		return
	end
	if rescue then
		-- The recovery net (as RagdollService's): somewhere with no floor
		-- under it goes back to where the flight began.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { current.character }
		local here = current.root.Position
		if here.Y < -60 or workspace:Raycast(here, Vector3.new(0, -LaserConfig.CLIENT.RESCUE_PROBE, 0), params) == nil then
			current.root.AssemblyLinearVelocity = Vector3.zero
			current.root.AssemblyAngularVelocity = Vector3.zero
			current.root.CFrame = CFrame.new(current.origin) * current.root.CFrame.Rotation
		end
	end
	current.humanoid.PlatformStand = false
	current.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
end

local function startFlight(character: Model, root: BasePart, humanoid: Humanoid, zoneIndex: number, roomIndex: number)
	local frame = Layout.frame(zoneIndex, roomIndex)
	local plan = LaserFlight.plan(frame, Layout.DOOR_WIDTH / 2, root.Position)
	local points = plan.points
	local before = if #points >= 2 then points[#points] - points[#points - 1] else points[#points] - root.Position
	local sign = function(): number
		return if math.random() < 0.5 then -1 else 1
	end
	local now = os.clock()
	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	flight = {
		character = character,
		root = root,
		humanoid = humanoid,
		began = now,
		seconds = plan.seconds,
		at = LaserFlight.sampler(root.Position, points, KNOCKBACK.ARC_HEIGHT),
		rotation = root.CFrame.Rotation,
		spin = Vector3.new(TUMBLE.X * sign(), TUMBLE.Y * sign(), TUMBLE.Z * sign()),
		lastStep = now,
		last = if before.Magnitude > 0.1 then before.Unit else Vector3.zero,
		origin = root.Position,
		standAt = nil,
		zone = zoneIndex,
	}
end

--- One frame of the flight: the root goes exactly where the shared sampler
--- says, at the frame's own time, so the motion is as smooth as the display.
local function stepFlight(current: Flight, now: number)
	local root = current.root
	if not root.Parent or current.humanoid.Health <= 0 or player.Character ~= current.character then
		flight = nil
		previous = nil
		return
	end
	local standAt = current.standAt
	if standAt then
		-- Landed: the body lies where it fell (limp, PlatformStanding) until
		-- the ground stun ends.
		if now >= standAt then
			endFlight(current, true)
		end
		return
	end
	local t = (now - current.began) / current.seconds
	local dt = math.min(now - current.lastStep, 0.1)
	current.lastStep = now
	current.rotation = current.rotation * CFrame.fromEulerAnglesXYZ(current.spin.X * dt, current.spin.Y * dt, current.spin.Z * dt)
	root.CFrame = CFrame.new(current.at(math.min(t, 1))) * current.rotation
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	if t >= 1 then
		-- Handed back to physics with a little of the travel left in it, so
		-- the body slides to a stop instead of freezing.
		root.AssemblyLinearVelocity = current.last * LaserConfig.CLIENT.SLIDE_SPEED
		current.standAt = now + KNOCKBACK.GROUND_STUN
	end
end

-- ==========================================================
-- DETECTION
-- ==========================================================

--- May the local body be hit right now? (The stand-down list in the header.)
local function armed(character: Model, root: BasePart, humanoid: Humanoid, serverNow: number): boolean
	if humanoid.Health <= 0 or humanoid.PlatformStand or humanoid.Sit then
		return false
	end
	if root.Position.Z < 0 or math.abs(root.Position.X) > MapConfig.LANE_HALF then
		return false
	end
	if player:GetAttribute("LaserExempt") == true or player:GetAttribute("LaserClientOff") == true then
		return false
	end
	if ReplicatedStorage:GetAttribute("NightPhase") == "Night" then
		return false
	end
	local jam = player:GetAttribute("GadgetJamUntil")
	if type(jam) == "number" and jam > serverNow then
		return false
	end
	local immune = character:GetAttribute("RagdollImmuneUntil")
	if type(immune) == "number" and immune > serverNow then
		return false
	end
	return true
end

local function detect(character: Model, root: BasePart, humanoid: Humanoid, now: number)
	local serverNow = workspace:GetServerTimeNow()
	if not armed(character, root, humanoid, serverNow) then
		previous = nil
		return
	end
	local position = root.Position
	local zoneHere, roomHere = Layout.locate(position)
	local old = previous
	previous = { position = position, time = now, serverTime = serverNow, character = character }
	if not zoneHere or not roomHere or roomHere > Layout.ROOMS_PER_ZONE then
		return
	end
	local beams = LaserBeams.room(zoneHere, roomHere)
	if #beams == 0 then
		-- Not read yet (late replication): look again, but not every frame.
		local folder = lasersFolders[zoneHere]
		if folder and now - (rescanned[zoneHere] or -math.huge) > RESCAN_SECONDS then
			rescanned[zoneHere] = now
			LaserBeams.scan(folder)
		end
		return
	end
	local height = if CrouchController.isCrouched() then BODY.CROUCH_HEIGHT else BODY.STAND_HEIGHT
	local center, half = Geometry.bodyBox(position, humanoid.HipHeight, root.Size.Y, humanoid.RigType == Enum.HumanoidRigType.R6, height, BODY.HALF_WIDTH)
	local from, t0 = center, serverNow - 1 / 60
	-- The sweep starts where the body was last frame - unless that is a
	-- teleport (a respawn, a Night return), which is never swept.
	if old and old.character == character then
		local elapsed = math.min(now - old.time, 0.5)
		if (position - old.position).Magnitude <= math.max(24, humanoid.WalkSpeed * elapsed * 2 + 8) then
			from = center + old.position - position
			t0 = math.max(old.serverTime, serverNow - 0.5)
		end
	end
	for _, beam in beams do
		if Geometry.beamHit(beam, t0, serverNow, from, center, half) then
			-- THE TOUCH. Fly first, tell the server second: the flight is the
			-- experience, the claim only makes it official.
			startFlight(character, root, humanoid, zoneHere, roomHere)
			LaserFxController.onLocalHit(LaserBeams.partOf(beam) :: BasePart?)
			if remote then
				remote:FireServer(zoneHere, roomHere, beam.id)
			end
			previous = nil
			return
		end
	end
end

local function step()
	local now = os.clock()
	local current = flight
	if current then
		stepFlight(current, now)
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid then
		previous = nil
		return
	end
	detect(character, root, humanoid, now)
end

function LaserHitController.start()
	remote = Remotes.get("LaserHit")
	player.CharacterAdded:Connect(function()
		flight = nil
		previous = nil
	end)
	task.spawn(function()
		local map = workspace:WaitForChild("Map", 60)
		local zones = map and map:WaitForChild("Zones", 30)
		if not zones then
			return
		end
		for _, zone in zones:GetChildren() do
			task.spawn(function()
				local index = zone:GetAttribute("ZoneIndex")
				local lasers = zone:WaitForChild("Lasers", 15)
				if lasers and type(index) == "number" then
					watchFolder(index, lasers)
				end
			end)
		end
		-- Before the camera places itself (Camera priority), so the body the
		-- camera follows is already where the flight put it THIS frame.
		RunService:BindToRenderStep(BINDING, Enum.RenderPriority.Camera.Value - 10, step)
	end)
end

return LaserHitController
