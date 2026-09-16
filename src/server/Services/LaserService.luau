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
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)
local GuardianService = require(script.Parent.GuardianService)
local LootService = require(script.Parent.LootService)

local LaserService = {}
local INTERVAL = 0.1
local limiter = RateLimiter.new(8, 12)
type Sample = { position: Vector3, time: number, character: Model }
type Field = { index: number, startZ: number, endZ: number, folder: Instance }
local fields: { Field } = {}
local previous: { [Player]: Sample } = {}
local crouched: { [Player]: boolean } = {}
local cooldown: { [Player]: { [number]: number } } = {}
--- Studio test hook: players the detector ignores (see setExempt).
local exempt: { [Player]: boolean } = {}
local metrics = { queries = 0, narrowChecks = 0, trips = 0, lastStepMs = 0, maxStepMs = 0 }

local function validBody(player: Player): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then return nil, nil, nil end
	return character, root, humanoid
end

function LaserService.setCrouched(player: Player, wanted: boolean): boolean
	local character, root, humanoid = validBody(player)
	local allowed = character ~= nil and root ~= nil and humanoid ~= nil
		and root.Position.Z >= 0 and root.Position.Z <= MapConfig.LANE_END_Z
		and math.abs(root.Position.X) <= MapConfig.LANE_HALF and not LootService.isClosed()
		and not humanoid.Sit and not humanoid.PlatformStand and not humanoid:GetAttribute("Rooted")
		and not GuardianService.isStunned(player)
	local value = wanted and allowed
	crouched[player] = if value then true else nil
	if character and character:GetAttribute("LaserCrouched") ~= value then character:SetAttribute("LaserCrouched", value) end
	return value
end

local function step()
	local started = os.clock()
	local closed = LootService.isClosed()
	for _, player in Players:GetPlayers() do
		local character, root, humanoid = validBody(player)
		if not character or not root or not humanoid or closed or root.Position.Z < 0
			or math.abs(root.Position.X) > MapConfig.LANE_HALF or humanoid.PlatformStand or GuardianService.isStunned(player) then
			previous[player] = nil
			if crouched[player] then LaserService.setCrouched(player, false) end
			continue
		end
		if exempt[player] then previous[player] = nil; continue end
		if crouched[player] then LaserService.setCrouched(player, true) end
		-- Feet follow the actual rig, so jumping clears low beams. Crouching
		-- changes only this laser silhouette; movement/carry speed is untouched.
		local leg = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else 0
		local feet = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2 - leg
		local height = if crouched[player] then 2.6 else 5.2
		local center = Vector3.new(root.Position.X, feet + height / 2, root.Position.Z)
		local half = Vector3.new(1.1, height / 2, 1.1)
		local old = previous[player]
		local from = center
		-- Ignore a teleport sweep, never the destination overlap. The generous
		-- bound allows the existing maximum walk speed and network batching.
		if old and old.character == character then
			local elapsed = math.min(started - old.time, 0.5)
			if (root.Position - old.position).Magnitude <= math.max(24, humanoid.WalkSpeed * elapsed * 2 + 8) then
				from = center + old.position - root.Position
			end
		end
		previous[player] = { position = root.Position, character = character, time = started }
		local containers: { Instance } = {}
		for _, field in fields do
			if math.max(from.Z, center.Z) + half.Z >= field.startZ and math.min(from.Z, center.Z) - half.Z <= field.endZ then
				table.insert(containers, field.folder)
			end
		end
		if #containers == 0 then continue end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
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

function LaserService.snapshot(): any
	local out: any = table.clone(metrics)
	out.fields, out.hz = #fields, 1 / INTERVAL
	return out
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
		player.CharacterAdded:Connect(function() previous[player], crouched[player], cooldown[player] = nil, nil, nil end)
	end
	for _, player in Players:GetPlayers() do watch(player) end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player)
		previous[player], crouched[player], cooldown[player] = nil, nil, nil
		exempt[player] = nil
		limiter:release(player)
	end)
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated >= INTERVAL then accumulated = 0; step() end
	end)
end

return LaserService
