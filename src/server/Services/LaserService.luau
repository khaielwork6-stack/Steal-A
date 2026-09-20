--!strict
-- Static beams, server-owned posture, occupied-zone queries at 10 Hz. The
-- client sends only a crouch intent, never a hit/miss, beam or guardian id.
-- A trip wakes that room's guard at once and it chases whoever touched the
-- beam, carrying or not (GuardianService.alarm). The other trigger is
-- leaving the room with its loot (GuardianService, MUSEUM DOORWAYS).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local GuardianService = require(script.Parent.GuardianService)
local LootService = require(script.Parent.LootService)
-- The SERVER's record of a ragdoll, never Humanoid.PlatformStand (client-settable).
local RagdollService = require(script.Parent.RagdollService)

local LaserService = {}

--- THE ROOM ALARM. A broken beam rings where it was broken, for a few
--- seconds, for everyone nearby - a static beam or one of the vault's
--- rotating arms, which are the same trip as far as the room is concerned.
---
--- Parented to the tripping player's own root, so it travels the couple of
--- studs they move while it rings rather than hanging in the air behind
--- them, and destroyed on a timer: a looped Sound left behind becomes the
--- room tone. One at a time per player - a beam clipped three times in four
--- seconds is one alarm, not three on top of each other.
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
	task.delay(AudioConfig.ALARM_SECONDS, function()
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
local previous: { [Player]: Sample } = {}
local crouched: { [Player]: boolean } = {}
local cooldown: { [Player]: { [number]: number } } = {}
--- Studio test hook: players the detector ignores (see setExempt).
local exempt: { [Player]: boolean } = {}
--- The Laser Jammer gadget (gadgets-patrols area): os.clock until which the
--- detector ignores this player. Server-owned and time-limited, live and in
--- Studio alike - deliberately NOT the Studio-only `exempt` above.
local jammedUntil: { [Player]: number } = {}
local metrics = { queries = 0, narrowChecks = 0, trips = 0, lastStepMs = 0, maxStepMs = 0 }
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
		local height = if crouched[player] then 2.6 else 5.2
		local center = Vector3.new(root.Position.X, feet + height / 2, root.Position.Z)
		local half = Vector3.new(1.1, height / 2, 1.1)
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
		-- [vaults-crews] The rotating vault arms: the same trip as a static beam.
		for _, field in movingFields do
			if not field.inside(root.Position) then
				continue
			end
			local key = Layout.key(field.zoneIndex, field.roomIndex)
			local times = cooldown[player] or {}
			cooldown[player] = times
			if (times[key] or 0) > started then
				continue
			end
			for _, arm in field.arms do
				metrics.narrowChecks += 1
				if Geometry.sweptArmHit(arm, serverFrom, serverNow, from, center, half) then
					times[key] = started + 1.5
					metrics.trips += 1
					player:SetAttribute("LastLaserZone", field.zoneIndex)
					player:SetAttribute("LastLaserTrip", serverNow)
					player:SetAttribute("LastLaserRoom", field.roomIndex)
					GuardianService.alarm(field.zoneIndex, player, field.roomIndex)
					ringAlarm(player)
					break
				end
			end
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
			local key = (index - 1) * 2 + room
			local times = cooldown[player] or {}
			cooldown[player] = times
			if (times[key] or 0) > started then continue end
			metrics.narrowChecks += 1
			if Geometry.sweptBoxHit(a, b, from, center, half) then
				times[key] = started + 1.5
				metrics.trips += 1
				player:SetAttribute("LastLaserZone", index)
				player:SetAttribute("LastLaserTrip", workspace:GetServerTimeNow())
				player:SetAttribute("LastLaserRoom", room)
				GuardianService.alarm(index, player, room)
				ringAlarm(player)
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
	return out
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
		end
	end
	Remotes.get("CrouchRequest").OnServerEvent:Connect(function(player, wanted)
		if type(wanted) == "boolean" and limiter:consume(player) then LaserService.setCrouched(player, wanted) end
	end)
	local function watch(player: Player)
		player.CharacterAdded:Connect(function()
			local wasCrouched = crouched[player]
			previous[player], crouched[player], cooldown[player] = nil, nil, nil
			-- Nor does a jam: it belonged to the body that used it.
			if jammedUntil[player] then LaserService.clearJam(player) end
			-- A crouch does not survive a respawn, and neither may its speed cost.
			if wasCrouched then task.defer(LaserService.onPostureChanged, player) end
		end)
	end
	for _, player in Players:GetPlayers() do watch(player) end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player)
		previous[player], crouched[player], cooldown[player] = nil, nil, nil
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
