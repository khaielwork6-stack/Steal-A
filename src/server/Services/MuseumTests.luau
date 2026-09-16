--!strict
-- Studio-only through DebugService, following EconomyTests' report convention.
-- Geometry cases are deterministic; run() also inspects the generated map.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)
local LootService = require(script.Parent.LootService)
local MuseumTests = {}

function MuseumTests.run(): any
	local report = { passed = 0, failed = {} :: { string } }
	local function check(ok: boolean, name: string)
		if ok then report.passed += 1 else table.insert(report.failed, name) end
	end
	local function crossing(y: number, height: number, feet: number, x: number): boolean
		return Geometry.sweptBoxHit(Vector3.new(-10, y, 0), Vector3.new(10, y, 0),
			Vector3.new(x, feet + height / 2, -12), Vector3.new(x, feet + height / 2, 12), Vector3.new(1.1, height / 2, 1.1))
	end
	check(crossing(4.5, 5.2, 0, 0), "standing crosses high beam between samples")
	check(not crossing(4.5, 2.6, 0, 0), "crouching clears high beam")
	check(crossing(0.8, 5.2, 0, 0), "walking hits ankle beam")
	check(not crossing(0.8, 5.2, 2, 0), "jump clears ankle beam")
	check(crossing(2.5, 2.6, 0, 0), "crouching does not clear middle beam")
	check(not crossing(2.5, 5.2, 0, 13), "walk around beam endpoint")
	check(Geometry.sweptBoxHit(Vector3.new(-8, 4, -8), Vector3.new(8, 0, 8), Vector3.new(0, 2, 0), Vector3.new(0, 2, 0), Vector3.one), "stationary diagonal overlap")
	check(not Geometry.sweptBoxHit(Vector3.new(-8, 4, -8), Vector3.new(8, 0, 8), Vector3.new(6, 2, -6), Vector3.new(6, 2, -6), Vector3.one), "diagonal broad-phase false positive rejected")
	local floors = RaycastParams.new()
	floors.FilterType, floors.FilterDescendantsInstances, floors.RespectCanCollide = Enum.RaycastFilterType.Include, { workspace.Map }, true
	for index, def in ZoneConfig.Zones do
		local zone = workspace.Map.Zones:FindFirstChild(def.id)
		check(zone ~= nil, `zone {index} exists`)
		if not zone then continue end
		for _, name in { "Floor", "Bounds", "Entrance", "SpawnSockets", "GuardianSpawns", "Gate", "Decorations" } do
			check(zone:FindFirstChild(name) ~= nil, `{def.id}.{name}`)
		end
		check(zone:GetAttribute("ZoneIndex") == index and zone:GetAttribute("ZoneLength") == MapConfig.zoneLength(index), `{def.id} band contract`)
		local floor = zone.Floor :: BasePart
		local template = game.ServerStorage.GameAssets.Template.ZoneFloors:FindFirstChild(`Zone {index}`) :: BasePart
		local expectedSize = Vector3.new(160, template.Size.Y, MapConfig.zoneLength(index))
		local expectedFrame = CFrame.new(0, -template.Size.Y / 2, MapConfig.zoneStartZ(index) + MapConfig.zoneLength(index) / 2)
		check((floor.Size - expectedSize).Magnitude < 0.01 and floor.CFrame:FuzzyEq(expectedFrame, 0.01), `{def.id} original kit floor geometry`)
		local checker = false
		for _, texture in floor:GetChildren() do
			if texture:IsA("Texture") and texture.Face == Enum.NormalId.Top and texture.Texture == "rbxassetid://6372755229" then
				checker = math.abs(texture.Transparency - 0.55) < 0.01 and texture.StudsPerTileU == 12 and texture.StudsPerTileV == 12
			end
		end
		check(checker and floor.Material ~= Enum.Material.Grass and floor.Material ~= Enum.Material.Sand, `{def.id} visible stone checker floor`)
		check(#zone.SpawnSockets:GetChildren() == 8, `{def.id} eight sockets`)
		check(#zone.GuardianSpawns:GetChildren() == 2, `{def.id} two guardian posts`)
		check(#zone.Rooms:GetChildren() == 2, `{def.id} left and right rooms`)
		local structural = RaycastParams.new()
		structural.FilterType, structural.RespectCanCollide = Enum.RaycastFilterType.Include, true
		structural.FilterDescendantsInstances = { zone.Rooms, zone.Structure }
		check(workspace:Raycast(Vector3.new(0, 3, MapConfig.zoneStartZ(index)), Vector3.new(0, 0, MapConfig.zoneLength(index)), structural) == nil, `{def.id} central corridor clear`)
		local totalParts = 0
		for roomIndex, name in { "Left", "Right" } do
			local room = zone.Rooms[name]
			local frame = Layout.frame(index, roomIndex)
			local width, depth = Layout.width(index), Layout.DEPTH
			local safeDecor = true
			for _, part in room.Decorations:GetDescendants() do
				if part:IsA("BasePart") then
					totalParts += 1
					safeDecor = safeDecor and part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch
				end
			end
			check(safeDecor, `{def.id} {name} safe decoration flags`)
			check(room:GetAttribute("DoorHeight") == Layout.doorHeight(index), `{def.id} {name} graduated doorway height`)
			check(#room.Structure:GetChildren() == 7, `{def.id} {name} enclosed walls and ceiling`)
			check(#room.Decorations.CollectionExhibits:GetChildren() == 2, `{def.id} {name} themed centrepiece and side exhibit`)
			for _, x in { -8, 0, 8 } do
				local from = frame:PointToWorldSpace(Vector3.new(x, 4, -10))
				local target = frame:PointToWorldSpace(Vector3.new(x, 4, 14))
				check(workspace:Raycast(from, target - from, structural) == nil, `{def.id} {name} permanent open doorway x{x}`)
			end
			for _, x in { -width / 2 + 7, width / 2 - 7 } do
				local from = frame:PointToWorldSpace(Vector3.new(x, 4, -10))
				check(workspace:Raycast(from, frame:VectorToWorldSpace(Vector3.new(0, 0, 20)), structural) ~= nil, `{def.id} {name} facade blocks side shortcut`)
			end
			-- Follow the steering waypoints in short segments. Every segment must
			-- clear the actual room walls in both directions and across the hall.
			local socketAt = Layout.socketFrame(index, (roomIndex - 1) * 4 + 1).Position
			local hall = Vector3.new(0, 3, MapConfig.zoneStartZ(index) + 6)
			local opposite = Layout.socketFrame(index, (2 - roomIndex) * 4 + 4).Position
			for routeIndex, route in { { socketAt, hall }, { hall, socketAt }, { socketAt, opposite } } do
				local from, goal = route[1], route[2]
				local clear = true
				for _ = 1, 800 do
					if (Vector3.new(from.X, 0, from.Z) - Vector3.new(goal.X, 0, goal.Z)).Magnitude < 1 then break end
					local waypoint = Layout.waypoint(from, goal)
					local delta = Vector3.new(waypoint.X - from.X, 0, waypoint.Z - from.Z)
					if delta.Magnitude < 0.01 then clear = false; break end
					local step = delta.Unit * math.min(1, delta.Magnitude)
					if workspace:Raycast(Vector3.new(from.X, 3, from.Z), step, structural) then clear = false; break end
					from += step
				end
				check(clear and (Vector3.new(from.X, 0, from.Z) - Vector3.new(goal.X, 0, goal.Z)).Magnitude < 1, `{def.id} {name} doorway route {routeIndex}`)
			end
			for column = 1, 4 do
				local n = (roomIndex - 1) * 4 + column
				local socket = LootService.getSocket(index, n)
				check(socket ~= nil and socket.loot ~= nil and socket.loot.state == "Spawned", `{def.id} socket {n} live loot`)
				check(socket ~= nil and socket.loot ~= nil and LootService.promptOf(socket.loot) ~= nil, `{def.id} socket {n} steal prompt`)
				local marker = zone.SpawnSockets[string.format("Socket%02d", n)]
				check(marker.CFrame:FuzzyEq(Layout.socketFrame(index, n), 0.01) and marker:GetAttribute("RoomIndex") == roomIndex, `{def.id} socket {n} remains in its room`)
				local case = room.Decorations[string.format("Socket%02dVitrine", n)]
				local plinth = case.StonePlinth
				local localAt = frame:PointToObjectSpace(plinth.Position)
				check(math.abs(localAt.X) + plinth.Size.Z / 2 < width / 2 - 2 and localAt.Z + plinth.Size.X / 2 < depth - 2, `{def.id} case {n} fits room`)
				check(case:FindFirstChild("Glass") ~= nil and case:FindFirstChild("GoldUpright") ~= nil, `{def.id} case {n} glass and gold frame`)
			end
			local count = 0
			for _, beam in zone.Lasers:GetChildren() do
				if beam:GetAttribute("RoomIndex") ~= roomIndex then continue end
				count += 1
				local a, b = beam:GetAttribute("A"), beam:GetAttribute("B")
				for _, point in { a, b } do
					local at = frame:PointToObjectSpace(point)
					check(math.abs(at.X) < width / 2 - 3 and at.Z > 5 and at.Z < depth - 15, `{def.id} {name} laser {count} inside room`)
				end
				check(not Geometry.sweptBoxHit(a, b, Vector3.new(0, 2.6, MapConfig.zoneStartZ(index)), Vector3.new(0, 2.6, MapConfig.zoneEndZ(index)), Vector3.new(8, 2.6, 2)), `{def.id} laser leaves corridor clear`)
			end
			check(count == Layout.BEAMS[index], `{def.id} {name} laser escalation`)
			for _, x in { 0, -width * 0.25, width * 0.25 } do
				local at = frame:PointToWorldSpace(Vector3.new(x, 6, depth / 2))
				local hit = workspace:Raycast(at, Vector3.new(0, -10, 0), floors)
				check(hit ~= nil and math.abs(hit.Position.Y) < 0.1, `{def.id} {name} kit floor at zero`)
			end
		end
		check(totalParts < 900, `{def.id} two-room decoration budget`)

	end
	return report
end

-- Explicit integration command, never an automatic startup test. Exercises
-- the real service instances, then restores the test's lifetime counter.
function MuseumTests.loops(player: Player): any
	assert(game:GetService("RunService"):IsStudio(), "Studio only")
	local Carry = require(script.Parent.CarryService)
	local Guardian = require(script.Parent.GuardianService)
	local Ragdoll = require(script.Parent.RagdollService)
	local Night = require(script.Parent.NightService)
	local Data = require(script.Parent.DataService)
	local profile = assert(Data.get(player))
	local character = assert(player.Character)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
	assert(not Carry.getCarried(player), "Finish current carry first")
	assert(not Night.isNight(), "Run during Day")
	local steals = profile.Lifetime.Steals
	local rows = {}
	local ok, err = pcall(function()
		Night.setDayRemaining(260)
		for index = 1, 12 do
			for room = 1, 2 do
				Guardian.resetAll()
				local socket = assert(LootService.getSocket(index, (room - 1) * 4 + 2))
				local loot = assert(socket.loot)
				local id, token, income = loot.id, loot.spawnToken, loot.finalIncome
				character:PivotTo(socket.part.CFrame + Vector3.new(0, 3, 5))
				root.AssemblyLinearVelocity = Vector3.zero
				Ragdoll.grantImmunity(player, 1.2) -- observe wake without a catch racing the assertion
				task.wait(0.15)
				local stolen = Carry.trySteal(player, loot)
				local waking = Guardian.inspect(index, room)
				local opposite = Guardian.inspect(index, 3 - room)
				task.wait(0.7)
				local chasing = Guardian.inspect(index, room)
				character:PivotTo(CFrame.new(0, 4, -16))
				root.AssemblyLinearVelocity = Vector3.zero
				task.wait(0.3)
				local escaped = Carry.getCarried(player) == loot and player:GetAttribute("Chased") ~= true
				Carry.reclaim(loot)
				task.wait(require(ReplicatedStorage.Shared.Config.GameConfig).GUARDIAN_RETURN_DELAY + 0.2)
				local same = socket.loot == loot and loot.id == id and loot.spawnToken == token and loot.finalIncome == income and loot.state == "Spawned"
				table.insert(rows, { zone = index, room = room, oppositeSleeping = opposite and opposite.state == "Sleeping", stolen = stolen, wake = waking and waking.state, chase = chasing and chasing.state, escaped = escaped, returnedSameRoll = same })
			end
		end
	end)
	local carried = Carry.getCarried(player)
	if carried then Carry.reclaim(carried) end
	Guardian.resetAll()
	profile.Lifetime.Steals = steals
	if not ok then return { error = tostring(err), zones = rows } end
	return { zones = rows }
end

function MuseumTests.scenarios(player: Player): any
	assert(game:GetService("RunService"):IsStudio(), "Studio only")
	local Carry = require(script.Parent.CarryService)
	local Guardian = require(script.Parent.GuardianService)
	local Ragdoll = require(script.Parent.RagdollService)
	local Night = require(script.Parent.NightService)
	local Data = require(script.Parent.DataService)
	local Base = require(script.Parent.BaseService)
	local Placement = require(script.Parent.PlacementService)
	local PvP = require(script.Parent.PvPService)
	local Laser = require(script.Parent.LaserService)
	local profile = assert(Data.get(player))
	local character = assert(player.Character)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
	assert(not Carry.getCarried(player), "Finish current carry first")
	assert(not Night.isNight(), "Run during Day")
	local saved = { steals = profile.Lifetime.Steals, secrets = profile.Lifetime.Secrets,
		highest = profile.HighestZoneReached, traps = profile.TrapCount, ready = profile.TrapReadyAt }
	local addedId: string? = nil
	local report: any = {}
	local function move(at: Vector3)
		character:PivotTo(CFrame.new(at))
		root.AssemblyLinearVelocity = Vector3.zero
	end
	local function take(index: number)
		Guardian.resetAll()
		local socket = assert(LootService.getSocket(index, 2))
		local loot = assert(socket.loot)
		move(socket.part.Position + Vector3.new(0, 3, 5))
		task.wait(0.15)
		assert(Carry.trySteal(player, loot), "steal refused")
		return loot
	end
	local ok, err = pcall(function()
		Night.setDayRemaining(260)
		local slot = assert(Base.freeSlots(player)[1], "Need one free display slot")
		local loot = take(1)
		local itemId, scale, mutation = loot.itemId, loot.scale, loot.mutation
		local plot = assert(Base.getPlot(player))
		local safe = plot:FindFirstChild("SafeZone") :: BasePart
		move(Vector3.new(safe.Position.X, 4, safe.Position.Z))
		task.wait(0.3)
		local placed, reason = Placement.place(player, slot)
		report.placed, report.placeReason = placed, reason
		if placed then
			for _, item in profile.DisplayItems do
				if item.SlotIndex == slot then
					addedId = item.InstanceId
					report.sealedSameRoll = item.Hatched == false and item.ItemId == itemId and item.Scale == scale and item.Mutation == mutation
				end
			end
			-- The tester may own only one free pad. Remove only this fixture
			-- before the next steal, so the ordinary BASE FULL gate stays real.
			for n = #profile.DisplayItems, 1, -1 do
				if profile.DisplayItems[n].InstanceId == addedId then table.remove(profile.DisplayItems, n) end
			end
			Base.rebuildDisplays(player)
			require(script.Parent.EconomyService).recalculate(player)
		end
		loot = take(2)
		Carry.forceDrop(loot)
		report.dropped = loot.state == "Dropped"
		Carry.reclaim(loot)
		task.wait(2.3)
		report.dropReturnedSame = LootService.getSocket(2, 2).loot == loot and loot.state == "Spawned"
		Guardian.resetAll()
		-- An actual placed trap, picked up by the real guardian polling loop.
		local at = Guardian.guardianPosition(3)
		assert(at, "guardian missing")
		move(Vector3.new(at.X + 10, 4, at.Z)) -- inside the unchanged 12-stud placement radius
		profile.TrapCount = math.max(1, profile.TrapCount)
		PvP.tryPlaceTrap(player, at)
		report.trapPlaced = PvP.activeTrapCount() > 0
		report.alarmWoke = Guardian.alarm(3, player)
		task.wait(0.3)
		local info = Guardian.inspect(3)
		report.trapRootedGuard = info and info.rooted
		report.rootedAlarmRejected = not Guardian.alarm(3, player)
		move(Vector3.new(at.X + 1, 3.2, at.Z))
		task.wait(0.7)
		report.rootedGuardDidNotCatch = not Ragdoll.isImmune(player) and player:GetAttribute("LaserChased") == true
		-- Night interrupts an alarm and crouch through the ordinary reset path.
		Laser.setCrouched(player, true)
		Night.forceNight()
		task.wait(0.5)
		report.nightClosed = LootService.isClosed()
		report.nightClearedAlarm = player:GetAttribute("Chased") ~= true and character:GetAttribute("LaserCrouched") ~= true
		report.nightMovedSafe = root.Position.Z < 0
		Night.forceDay()
		task.wait(0.5)
		report.dayReopened = not LootService.isClosed()
		report.afterNightOccupancy = LootService.occupancy()
		-- A real catch, not the direct reclaim used to clean up the loop test.
		local deadline = os.clock() + 15
		while Ragdoll.isImmune(player) and os.clock() < deadline do task.wait(0.1) end
		assert(not Ragdoll.isImmune(player), "Wait for recovery before catch test")
		loot = take(3)
		local id, token = loot.id, loot.spawnToken
		task.wait(0.65)
		local target = assert(Guardian.guardianPosition(3))
		move(Vector3.new(target.X, 3.2, target.Z))
		task.wait(0.25)
		report.caught = Carry.getCarried(player) == nil and Ragdoll.isImmune(player)
		task.wait(2.3)
		report.catchReturnedSameRoll = LootService.getSocket(3, 2).loot == loot and loot.state == "Spawned" and loot.id == id and loot.spawnToken == token
	end)
	local carried = Carry.getCarried(player)
	if carried then Carry.reclaim(carried) end
	Guardian.resetAll()
	if Night.isNight() then Night.forceDay() end
	profile.Lifetime.Steals, profile.Lifetime.Secrets = saved.steals, saved.secrets
	profile.HighestZoneReached, profile.TrapCount, profile.TrapReadyAt = saved.highest, saved.traps, saved.ready
	if addedId then
		for n = #profile.DisplayItems, 1, -1 do
			if profile.DisplayItems[n].InstanceId == addedId then table.remove(profile.DisplayItems, n) end
		end
		Base.rebuildDisplays(player)
		require(script.Parent.EconomyService).recalculate(player)
	end
	require(script.Parent.StateService).pushNow(player)
	if not ok then report.error = tostring(err) end
	return report
end

-- Real Humanoid navigation, distinct from the deterministic route checks.
function MuseumTests.paths(player: Player): any
	assert(game:GetService("RunService"):IsStudio(), "Studio only")
	local Guardian = require(script.Parent.GuardianService)
	local Ragdoll = require(script.Parent.RagdollService)
	local Night = require(script.Parent.NightService)
	local Laser = require(script.Parent.LaserService)
	local Carry = require(script.Parent.CarryService)
	assert(not Carry.getCarried(player), "Finish carry first")
	assert(not Night.isNight(), "Run during Day")
	local character = assert(player.Character)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
	local saved = root.CFrame
	local rows = {}
	local report: any = { rooms = rows }
	local function move(at: Vector3)
		character:PivotTo(CFrame.new(at))
		root.AssemblyLinearVelocity = Vector3.zero
	end
	local ok, err = pcall(function()
		Night.setDayRemaining(260)
		for _, index in { 1, 6, 12 } do
			for room = 1, 2 do
				Guardian.resetAll()
				while Ragdoll.isImmune(player) do task.wait(0.1) end
				local frame = Layout.frame(index, room)
				move(frame:PointToWorldSpace(Vector3.new(-Layout.width(index) * 0.2, 3.2, 42)))
				local woke = Guardian.alarm(index, player, room)
				local entered = false
				local deadline = os.clock() + 12
				while os.clock() < deadline do
					Ragdoll.grantImmunity(player, 0.4)
					local at = Guardian.guardianPosition(index, room)
					if at and frame:PointToObjectSpace(at).Z > 25 then entered = true; break end
					task.wait(0.1)
				end
				local opposite = Guardian.inspect(index, 3 - room)
				move(Vector3.new(0, 4, -16))
				deadline = os.clock() + 12
				local returned = false
				while os.clock() < deadline do
					local info = Guardian.inspect(index, room)
					if info and info.state == "Sleeping" then returned = true; break end
					task.wait(0.1)
				end
				table.insert(rows, { zone = index, room = room, woke = woke, enteredThroughDoor = entered,
					returnedThroughDoor = returned, oppositeSleeping = opposite and opposite.state == "Sleeping" })
			end
		end
		Guardian.resetAll()
		while Ragdoll.isImmune(player) do task.wait(0.1) end
		local zone = workspace.Map.Zones[ZoneConfig.Zones[3].id]
		local beam: BasePart? = nil
		for _, candidate in zone.Lasers:GetChildren() do
			if candidate:IsA("BasePart") and candidate:GetAttribute("RoomIndex") == 2 and candidate:GetAttribute("A").Y > 4 then beam = candidate; break end
		end
		assert(beam, "high beam missing")
		local at = (beam:GetAttribute("A") + beam:GetAttribute("B")) / 2
		move(Vector3.new(at.X - 6, 3.2, at.Z))
		Laser.setCrouched(player, true)
		task.wait(0.2)
		player:SetAttribute("LastLaserTrip", nil)
		move(Vector3.new(at.X, 3.2, at.Z))
		task.wait(0.3)
		report.crouchClearedHighBeam = player:GetAttribute("LastLaserTrip") == nil
		Laser.setCrouched(player, false)
		task.wait(0.2)
		local info = Guardian.inspect(3, 2)
		report.standingTrippedMatchingRoom = player:GetAttribute("LastLaserRoom") == 2 and player:GetAttribute("LastLaserZone") == 3
			and info ~= nil and (info.state == "Waking" or info.state == "Chasing")
		report.laserLeftOppositeSleeping = Guardian.inspect(3, 1).state == "Sleeping"
	end)
	Guardian.resetAll()
	Laser.setCrouched(player, false)
	character:PivotTo(saved)
	root.AssemblyLinearVelocity = Vector3.zero
	if not ok then report.error = tostring(err) end
	return report
end

return MuseumTests
