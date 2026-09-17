--!strict
--[[
	DebugCommands/World
	Studio test commands for the generated museum (the "world-health" pass).
	Loaded by DebugService; call through ServerStorage.DebugInvoke or the
	DebugRequest attribute bridge, e.g.

	    DebugInvoke:Invoke("museumPartCount")
	    DebugInvoke:Invoke("museumCaseChurn", nil, 3, 2)   -- zone 3, socket 2

	museumPartCount   BaseParts per museum room (Structure + Decorations, with
	                  the four display cases and the laser beams broken out),
	                  per zone (rooms + zone-level corridor/facade), and totals.
	                  Before/after numbers for the part-budget work.
	museumCaseChurn   Takes one socket's container away and refills the socket
	                  (the steal -> refill path), then reports whether the
	                  display case's instances were destroyed or recreated.
	                  Expected since the fixed-size cases: 0 and 0.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)

local function countParts(root: Instance?): number
	if not root then
		return 0
	end
	local n = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

local function zoneFolder(index: number): Instance?
	local map = workspace:FindFirstChild("Map")
	local zones = map and map:FindFirstChild("Zones")
	local def = ZoneConfig.Zones[index]
	return if zones and def then zones:FindFirstChild(def.id) else nil
end

local function roomFolder(zone: Instance, roomIndex: number): Instance?
	local rooms = zone:FindFirstChild("Rooms")
	return rooms and rooms:FindFirstChild(if roomIndex == 1 then "Left" else "Right")
end

local World = {}

World.museumPartCount = function(_player: Player)
	local zonesOut = {}
	local grand = { rooms = 0, zoneLevel = 0, lasers = 0, instances = 0 }
	for index = 1, #ZoneConfig.Zones do
		local zone = zoneFolder(index)
		if not zone then
			continue
		end
		local row: any = { zone = index, rooms = {} }
		local roomTotal = 0
		for roomIndex = 1, Layout.ROOMS_PER_ZONE do
			local room = roomFolder(zone, roomIndex)
			if not room then
				continue
			end
			local decor = room:FindFirstChild("Decorations")
			local cases = 0
			if decor then
				for _, child in decor:GetChildren() do
					if child.Name:match("^Socket%d+Vitrine$") then
						cases += countParts(child)
					end
				end
			end
			local beams = 0
			local lasers = zone:FindFirstChild("Lasers")
			if lasers then
				for _, beam in lasers:GetChildren() do
					if beam:GetAttribute("RoomIndex") == roomIndex then
						beams += 1
					end
				end
			end
			local parts = countParts(room)
			roomTotal += parts
			grand.instances += #room:GetDescendants()
			table.insert(row.rooms, {
				room = roomIndex,
				parts = parts,
				structure = countParts(room:FindFirstChild("Structure")),
				decorations = countParts(decor),
				cases = cases,
				beams = beams,
			})
		end
		-- Zone-level dressing outside the rooms: corridor runner/ceiling/coffers
		-- and the facade extensions.
		local zoneLevel = countParts(zone:FindFirstChild("Decorations")) + countParts(zone:FindFirstChild("Structure"))
		local lasers = countParts(zone:FindFirstChild("Lasers"))
		row.roomParts = roomTotal
		row.zoneLevelParts = zoneLevel
		row.laserParts = lasers
		grand.rooms += roomTotal
		grand.zoneLevel += zoneLevel
		grand.lasers += lasers
		table.insert(zonesOut, row)
	end
	local lines = {}
	for _, row in zonesOut do
		for _, r in row.rooms do
			table.insert(
				lines,
				string.format(
					"Z%02d R%d parts=%d (structure %d, decor %d, cases %d) beams=%d",
					row.zone,
					r.room,
					r.parts,
					r.structure,
					r.decorations,
					r.cases,
					r.beams
				)
			)
		end
	end
	return {
		zones = zonesOut,
		lines = lines,
		totalRoomParts = grand.rooms,
		averagePerRoom = if #zonesOut > 0
			then math.floor(grand.rooms / (#zonesOut * Layout.ROOMS_PER_ZONE) + 0.5)
			else 0,
		totalZoneLevelParts = grand.zoneLevel,
		totalLaserParts = grand.lasers,
		totalRoomInstances = grand.instances,
	}
end

World.museumCaseChurn = function(_player: Player, zoneArg: any?, socketArg: any?)
	local LootService = require(script.Parent.Parent.LootService) :: any
	local zoneIndex = tonumber(zoneArg) or 1
	local socketIndex = tonumber(socketArg) or 1
	local zone = zoneFolder(zoneIndex)
	assert(zone, `zone {zoneIndex} missing`)
	local room = roomFolder(zone :: Instance, Layout.roomOfSocket(socketIndex))
	local decor = room and room:FindFirstChild("Decorations")
	local case = decor and decor:FindFirstChild(string.format("Socket%02dVitrine", socketIndex))
	assert(case, `case for socket {socketIndex} missing`)
	local socket = LootService.getSocket(zoneIndex, socketIndex)
	assert(socket, `socket {zoneIndex}/{socketIndex} missing`)

	local before: { [Instance]: boolean } = {}
	local beforeCount = 0
	for _, d in (case :: Instance):GetDescendants() do
		before[d] = true
		beforeCount += 1
	end
	local plinth = (case :: Instance):FindFirstChild("StonePlinth") :: BasePart?
	local sizeBefore = if plinth then plinth.Size else nil

	-- Steal-and-refill without a player: the placed-loot hand-off empties the
	-- socket (container destroyed), then the socket is filled with a fresh roll
	-- (container created). Both used to rebuild the whole case.
	local oldLoot = socket.loot
	if oldLoot then
		LootService.consume(oldLoot)
	end
	task.wait(0.1)
	local emptied = socket.loot == nil
	local refilled = LootService.fillSocket(socket)
	-- The old rebuild was deferred; give it well over a frame to show up.
	task.wait(0.3)

	local survived, created = 0, 0
	local seen: { [Instance]: boolean } = {}
	for _, d in (case :: Instance):GetDescendants() do
		seen[d] = true
		if before[d] then
			survived += 1
		else
			created += 1
		end
	end
	local destroyed = 0
	for d in before do
		if not seen[d] then
			destroyed += 1
		end
	end
	local sizeAfter = if plinth and plinth.Parent then plinth.Size else nil
	return {
		zone = zoneIndex,
		socket = socketIndex,
		hadLoot = oldLoot ~= nil,
		emptied = emptied,
		refilled = refilled ~= nil,
		caseFolderSame = case.Parent ~= nil,
		instancesBefore = beforeCount,
		survived = survived,
		destroyed = destroyed,
		created = created,
		sizeUnchanged = sizeBefore ~= nil and sizeAfter == sizeBefore,
		pass = oldLoot ~= nil and refilled ~= nil and destroyed == 0 and created == 0,
	}
end

return World
