--!strict
--[[
	MysterySpawnService
	Where the four mystery containers of a zone stand, and whether that zone's
	container model is usable at all.

	IT OWNS PLACEMENT, NOT LIFECYCLE. The socket lifecycle - rolling, filling,
	stealing, returning, refreshing - stays in LootService, which has always
	owned it. This module answers two narrower questions that LootService asks
	once at start-up:

	    "is zone N's container model present and sane?"      -> validate
	    "where do zone N's four sockets belong?"             -> layout

	WHY THE SOCKETS MOVE AT ALL
	The map is baked into the place file, and its sockets were laid out for the
	old exposed-loot design: two rows spread across the lane, nowhere near the
	guardian. Containers are supposed to read as the things the guardian is
	guarding, so they are re-seated at start-up into a shallow arc around its
	post - two in front, two behind, guardian in the middle, lane down the
	centre left clear to run. Doing it here rather than in MapBuilder means a
	place that is never rebuilt still gets the new layout.

	THE FIFTH SOCKET IS REMOVED, NOT HIDDEN. Socket05 (and anything past it) is
	destroyed on sight, every start-up, so the retired fifth spawn cannot come
	back from a stale baked map, a re-run of the old builder, or a saved place.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local MysteryConfig = require(ReplicatedStorage.Shared.Config.MysteryConfig)
local MysteryModel = require(ReplicatedStorage.Shared.Util.MysteryModel)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local MysterySpawnService = {}

--- Zones whose container model is missing or unusable. LootService refuses to
--- fill their sockets rather than showing another zone's container.
local blockedZones: { [number]: string } = {}

function MysterySpawnService.isZoneBlocked(zoneIndex: number): boolean
	return blockedZones[zoneIndex] ~= nil
end

function MysterySpawnService.blockedReason(zoneIndex: number): string?
	return blockedZones[zoneIndex]
end

-- ==========================================================
-- MODEL VALIDATION
-- ==========================================================

--- Checks all twelve container models and reports each failure BY THE NAME IT
--- LOOKED FOR. A zone that fails is recorded and spawns nothing; no zone ever
--- borrows another zone's model.
function MysterySpawnService.validateModels(): { MysteryModel.ModelReport }
	local reports = MysteryModel.check()
	blockedZones = {}

	local ok, missing = 0, {}
	for _, report in reports do
		if report.ok then
			ok += 1
			if report.problem then
				warn(`[MysterySpawn] zone {report.zone} model "{report.found}": {report.problem}`)
			end
		else
			blockedZones[report.zone] = report.problem or "unusable"
			table.insert(missing, `zone {report.zone} expected "{report.expected}" ({report.problem})`)
		end
	end

	if #missing > 0 then
		warn(`[MysterySpawn] {#missing} zone container model(s) UNUSABLE - those zones will spawn nothing:`)
		for _, line in missing do
			warn("  - " .. line)
		end
	end
	print(`[MysterySpawn] {ok}/12 zone container models validated`)
	return reports
end

-- ==========================================================
-- PLACEMENT
-- ==========================================================

--- The guardian's post in a zone: the marker its rig stands on. Everything is
--- laid out relative to this, so moving a post in Studio moves its containers.
local function guardianPost(zone: Instance): BasePart?
	local folder = zone:FindFirstChild("GuardianSpawns")
	if not folder then
		return nil
	end
	local post = folder:FindFirstChild("GuardianPost")
	if post and post:IsA("BasePart") then
		return post
	end
	return folder:FindFirstChildWhichIsA("BasePart")
end

--- Everything a container must not be placed inside: walls, gates, scenery,
--- the guardian's own post. Loot sockets are excluded - they are what we are
--- placing - and so is the guardian rig itself.
local function blockerParams(zone: Instance, sockets: Instance): RaycastParams
	local params = RaycastParams.new()
	-- ONLY SOLID GROUND COUNTS. Every zone carries an invisible, non-colliding
	-- `Bounds` volume roughly 39 studs tall that spans the whole zone, and a
	-- plain downward ray hits its LID first - which put all 48 sockets, and
	-- every container on them, 39 studs in the air. Respecting CanCollide
	-- skips it, the hollowed decor and every other trigger volume, and finds
	-- the floor the guardian is standing on.
	params.RespectCanCollide = true
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = { sockets }
	local guardians = workspace:FindFirstChild("Guardians")
	if guardians then
		table.insert(filter, guardians)
	end
	local carried = workspace:FindFirstChild("Map")
	carried = carried and carried:FindFirstChild("CarriedLoot")
	if carried then
		table.insert(filter, carried)
	end
	params.FilterDescendantsInstances = filter
	return params
end

--- How far above the guardian's own footing a surface may be and still be
--- believed. A container stands on the same ground its guardian patrols, so a
--- hit far above that is scenery, a roof or a trigger volume, not a floor.
local MAX_SURFACE_RISE = 6

--- Drops a spot onto the floor. Returns the surface Y, or the guardian's own
--- height when nothing believable is hit, so a container can never be left in
--- the air or pushed underground.
local function floorY(x: number, z: number, params: RaycastParams, fallback: number): number
	local result = workspace:Raycast(Vector3.new(x, fallback + 60, z), Vector3.new(0, -200, 0), params)
	if not result then
		return fallback
	end
	-- Belt and braces beside RespectCanCollide: a solid roof or a tall prop is
	-- a real surface and would still be hit, and standing a container on one
	-- is worse than standing it on the floor.
	if result.Position.Y > fallback + MAX_SURFACE_RISE then
		return fallback
	end
	return result.Position.Y
end

--- True when `spot` is far enough from every spot already taken. Colossal
--- containers are wide, so this is a generous centre-to-centre distance
--- rather than a bounding-box test that would depend on what happens to roll.
local function separated(taken: { Vector3 }, x: number, z: number): boolean
	for _, other in taken do
		local dx, dz = other.X - x, other.Z - z
		if math.sqrt(dx * dx + dz * dz) < MysteryConfig.SOCKET_MIN_SEPARATION then
			return false
		end
	end
	return true
end

--- Lays one zone's four sockets around its guardian and removes any extras.
--- Returns how many sockets the zone now has.
function MysterySpawnService.layoutZone(zoneIndex: number, zone: Instance): number
	local socketFolder = zone:FindFirstChild("SpawnSockets")
	if not socketFolder then
		return 0
	end

	-- THE FIFTH SPAWN, AND ANYTHING PAST IT, GOES. Named sockets beyond the
	-- configured count are destroyed outright - model, prompt, everything -
	-- so nothing can resurrect them.
	local removed = 0
	for _, child in socketFolder:GetChildren() do
		local index = tonumber(child.Name:match("^Socket(%d+)$"))
		if index and index > MysteryConfig.SOCKETS_PER_ZONE then
			child:Destroy()
			removed += 1
		end
	end

	local post = guardianPost(zone)
	local template: BasePart? = nil
	for _, child in socketFolder:GetChildren() do
		if child:IsA("BasePart") and child.Name:match("^Socket%d+$") then
			template = child
			break
		end
	end
	if not template then
		return 0
	end

	-- Without a guardian post there is nothing to arrange around: the zone
	-- keeps whatever layout the map gave it rather than being moved blindly.
	if not post then
		warn(`[MysterySpawn] zone {zoneIndex} has no GuardianPost - sockets left where the map put them`)
		return #socketFolder:GetChildren()
	end

	local params = blockerParams(zone, socketFolder)
	local baseY = post.Position.Y
	local laneHalf = MapConfig.LANE_HALF
	local minZ = MapConfig.zoneStartZ(zoneIndex) + 16
	local maxZ = MapConfig.zoneEndZ(zoneIndex) - 16

	local taken: { Vector3 } = {}
	for slot, offset in MysteryConfig.SocketOffsets do
		local name = offset.name
		local part = socketFolder:FindFirstChild(string.format("Socket%02d", slot))
		if not part or not part:IsA("BasePart") then
			part = template:Clone()
			part.Name = string.format("Socket%02d", slot)
			part.Parent = socketFolder
		end
		local socket = part :: BasePart
		socket:SetAttribute("SpawnName", name)

		-- Start from the guardian and step out to this slot's corner, then
		-- pull the spot back inside the lane and inside the zone.
		local x = math.clamp(post.Position.X + offset.x, -laneHalf + 14, laneHalf - 14)
		local z = math.clamp(post.Position.Z + offset.z, minZ, maxZ)

		-- Nudge along the lane until it is clear of its neighbours. Bounded:
		-- after SOCKET_MAX_SHIFT studs it takes the spot it has rather than
		-- wandering out of the zone.
		local shifted = 0
		while not separated(taken, x, z) and shifted < MysteryConfig.SOCKET_MAX_SHIFT do
			z = math.clamp(z + 8, minZ, maxZ)
			shifted += 8
		end

		local y = floorY(x, z, params, baseY)
		local seated = CFrame.new(x, y + socket.Size.Y / 2, z)
		-- THE RIM COMES TOO. It is a sibling-in-spirit but a CHILD part, and
		-- parts do not inherit a parent part's transform, so moving only the
		-- socket left every rim behind at the map's original layout - visible
		-- as a ring of pads with nothing on them.
		for _, child in socket:GetChildren() do
			if child:IsA("BasePart") then
				child.CFrame = seated * socket.CFrame:Inverse() * child.CFrame
			end
		end
		socket.CFrame = seated
		socket.Anchored = true
		-- The socket is a marker, never a thing to bump into.
		socket.CanCollide = false
		socket.CanQuery = false
		-- AND NEVER A THING TO SEE. The pad and its rim used to draw as a
		-- dark square under every crate. The parts stay - the crate is seated
		-- on the socket, the prompt anchor and the layout are measured from
		-- it - but they are fully transparent, so the crate simply stands on
		-- the zone floor.
		socket.Transparency = 1
		socket.CastShadow = false
		for _, child in socket:GetChildren() do
			if child:IsA("BasePart") then
				child.Transparency = 1
				child.CastShadow = false
				child.CanCollide = false
				child.CanQuery = false
			end
		end
		table.insert(taken, Vector3.new(x, y, z))
	end

	if removed > 0 then
		print(`[MysterySpawn] zone {zoneIndex}: removed {removed} retired socket(s)`)
	end
	return MysteryConfig.SOCKETS_PER_ZONE
end

--- Lays out every zone. Called by LootService.start before it reads sockets.
function MysterySpawnService.layoutAll(map: Instance)
	local zones = map:FindFirstChild("Zones")
	if not zones then
		return
	end
	local placed = 0
	for zoneIndex, def in ZoneConfig.Zones do
		local zone = zones:FindFirstChild(def.id)
		if zone then
			placed += MysterySpawnService.layoutZone(zoneIndex, zone)
		end
	end
	print(`[MysterySpawn] {placed} container sockets placed around {ZoneConfig.COUNT} guardians`)
end

return MysterySpawnService
