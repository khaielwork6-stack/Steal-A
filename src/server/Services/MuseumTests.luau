--!strict
-- Studio-only through DebugService, following EconomyTests' report convention.
-- Geometry cases are deterministic; run() also inspects the generated map.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
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
		local portal = zone.Gate:FindFirstChild("Doorway")
		local sides, clearLeft, clearRight = 0, -80, 80
		local safeDecor, partCount = true, 0
		for _, root in { zone.Decorations, portal } do
			if not root then continue end
			for _, p in root:GetDescendants() do
				if not p:IsA("BasePart") then continue end
				partCount += 1
				safeDecor = safeDecor and p.Anchored and not p.CanCollide and not p.CanTouch and not p.CanQuery
				if p.Name == "ReturnWall" then
					sides += 1
					if p.Position.X < 0 then clearLeft = p.Position.X + p.Size.X / 2
					else clearRight = p.Position.X - p.Size.X / 2 end
				end
			end
		end
		check(safeDecor, `{def.id} scenery cannot collide or intercept interaction/trap rays`)
		check(partCount <= 605, `{def.id} decoration and portal part budget`)
		check(sides == 2 and clearRight - clearLeft >= 40 and clearRight - clearLeft <= 56.01 and math.abs(clearRight + clearLeft) < 0.01, `{def.id} centred open doorway`)
		local header = portal and portal:FindFirstChild("Header") :: BasePart?
		check(header ~= nil and header.Position.Y - header.Size.Y / 2 >= 20 and header.Position.Y - header.Size.Y / 2 <= 46, `{def.id} overhead portal clearance`)
		local collection = zone.Decorations:FindFirstChild("CollectionExhibits")
		check(collection ~= nil and #collection:GetChildren() == 2, `{def.id} two collection silhouettes`)
		for n = 1, 4 do
			local case = zone.Decorations:FindFirstChild(string.format("Socket%02dVitrine", n))
			local plinth = case and case:FindFirstChild("StonePlinth") :: BasePart?
			local cheeks, contains = 0, plinth ~= nil
			if case and plinth then
				for _, cheek in case:GetChildren() do
					if cheek:IsA("BasePart") and cheek.Name == "AlcoveCheek" then
						cheeks += 1
						contains = contains and cheek.Size.Z >= 4 and cheek.Size.X >= 20
							and math.abs(plinth.Position.X - cheek.Position.X) + plinth.Size.X / 2 < cheek.Size.X / 2
							and math.abs(cheek.Position.Z - plinth.Position.Z) - cheek.Size.Z / 2 > plinth.Size.Z / 2
					end
				end
			end
			check(cheeks == 2 and contains, `{def.id} vitrine {n} inside masonry recess`)
		end
		check(#zone.SpawnSockets:GetChildren() == 4, `{def.id} four sockets`)
		for n = 1, 4 do
			local socket = LootService.getSocket(index, n)
			check(socket ~= nil and socket.loot ~= nil and socket.loot.state == "Spawned", `{def.id} socket {n} live loot`)
			check(socket ~= nil and socket.loot ~= nil and LootService.promptOf(socket.loot) ~= nil, `{def.id} socket {n} steal prompt`)
		end
		local beams = 0
		for _, beam in zone.Lasers:GetChildren() do
			local a, b = beam:GetAttribute("A"), beam:GetAttribute("B")
			if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then continue end
			beams += 1
			local x = if index <= 5 then 70 else 0
			check(not Geometry.sweptBoxHit(a, b, Vector3.new(x, 2.6, MapConfig.zoneStartZ(index)), Vector3.new(x, 2.6, MapConfig.zoneEndZ(index)), Vector3.new(2, 2.6, 2)), `{def.id} open bypass beam {beams}`)
		end
		check(beams == (if index < 3 then 0 elseif index <= 5 then 3 elseif index <= 8 then 6 else 12), `{def.id} laser escalation`)
		for _, fraction in { 0.001, 0.25, 0.5, 0.75, 0.999 } do
			local z = MapConfig.zoneStartZ(index) + MapConfig.zoneLength(index) * fraction
			for _, x in { 0, 70, -44, 44 } do
				local hit = workspace:Raycast(Vector3.new(x, 6, z), Vector3.new(0, -10, 0), floors)
				check(hit ~= nil and math.abs(hit.Position.Y) < 0.1, `{def.id} continuous floor x{x} z{fraction}`)
			end
		end
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
			Guardian.resetAll()
			local socket = assert(LootService.getSocket(index, 2))
			local loot = assert(socket.loot)
			local id, token, income = loot.id, loot.spawnToken, loot.finalIncome
			character:PivotTo(socket.part.CFrame + Vector3.new(0, 3, 5))
			root.AssemblyLinearVelocity = Vector3.zero
			Ragdoll.grantImmunity(player, 1.2) -- observe wake without a catch racing the assertion
			task.wait(0.15)
			local stolen = Carry.trySteal(player, loot)
			local waking = Guardian.inspect(index)
			task.wait(0.7)
			local chasing = Guardian.inspect(index)
			character:PivotTo(CFrame.new(0, 4, -16))
			root.AssemblyLinearVelocity = Vector3.zero
			task.wait(0.3)
			local escaped = Carry.getCarried(player) == loot and player:GetAttribute("Chased") ~= true
			Carry.reclaim(loot)
			task.wait(require(ReplicatedStorage.Shared.Config.GameConfig).GUARDIAN_RETURN_DELAY + 0.2)
			local same = socket.loot == loot and loot.id == id and loot.spawnToken == token and loot.finalIncome == income and loot.state == "Spawned"
			table.insert(rows, { zone = index, stolen = stolen, wake = waking and waking.state, chase = chasing and chasing.state, escaped = escaped, returnedSameRoll = same })
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

return MuseumTests
