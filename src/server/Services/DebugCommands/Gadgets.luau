--!strict
--[[
	DebugCommands/Gadgets
	Studio test commands for the gadgets and the moving patrols
	(docs/handoff-parts/gadgets-patrols.md). Invoke like any command:

	    DebugInvoke:Invoke("gadgetState")
	    DebugInvoke:Invoke("gadgetGive", nil, 3, 120)   -- n each, auto-restore after 120 s
	    DebugInvoke:Invoke("gadgetRestore")
	    DebugInvoke:Invoke("gadgetUse", nil, "Smoke")    -- "Jammer", "Grapple" (+ optional Vector3)
	    DebugInvoke:Invoke("gadgetBuyTest")
	    DebugInvoke:Invoke("gadgetSmokeTest", nil, 2)
	    DebugInvoke:Invoke("gadgetJamTest")
	    DebugInvoke:Invoke("gadgetGrappleTest")
	    DebugInvoke:Invoke("gadgetPatrols")
	    DebugInvoke:Invoke("gadgetPatrolToggle", nil, 7, false)  -- nil = back to config
	    DebugInvoke:Invoke("gadgetPatrolTest", nil, 7)

	STUDIO WRITES TO THE OWNER'S REAL DATASTORE. Every command that changes
	the profile (Gadgets, Cash, Lifetime.Steals) saves the original first and
	puts it back in a cleanup that runs whether the body succeeded or threw.
	`gadgetGive` is the one deliberate exception - the counts must stay for
	manual play - so it restores on a timer, on `gadgetRestore`, and in a
	before-release hook if the tester leaves first.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local Services = script.Parent.Parent
local CarryService = require(Services.CarryService)
local DataService = require(Services.DataService)
local GadgetService = require(Services.GadgetService)
local GuardianService = require(Services.GuardianService)
local LaserService = require(Services.LaserService)
local LootService = require(Services.LootService)
local MovementService = require(Services.MovementService)
local NightService = require(Services.NightService)
local RagdollService = require(Services.RagdollService)
local StateService = require(Services.StateService)

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function move(player: Player, at: CFrame)
	local character = assert(player.Character, "no character")
	MovementService.allowTeleport(player)
	character:PivotTo(at)
	local root = rootOf(player)
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

local function counts(player: Player): { [string]: number }
	local out = {}
	for _, key in GadgetConfig.Order do
		out[key] = GadgetService.count(player, key)
	end
	return out
end

local function setCounts(player: Player, values: { [string]: number })
	for _, key in GadgetConfig.Order do
		GadgetService.debugSetCount(player, key, values[key] or 0)
	end
end

--- Steals from socket `socketIndex` of `zoneIndex` (server pivot + the real
--- trySteal). Returns the loot or an error string.
local function stealAt(player: Player, zoneIndex: number, socketIndex: number): (LootService.LootInstance?, string?)
	local socket = LootService.getSocket(zoneIndex, socketIndex)
	local loot = socket and socket.loot
	if not socket or not loot or loot.state ~= "Spawned" then
		return nil, `socket {zoneIndex}/{socketIndex} has nothing to steal`
	end
	move(player, socket.part.CFrame * CFrame.new(0, 4, 6))
	task.wait(0.4)
	if not CarryService.trySteal(player, loot) then
		return nil, "steal refused"
	end
	return loot, nil
end

local function cleanUpCarry(player: Player)
	local carried = CarryService.getCarried(player)
	if carried then
		CarryService.reclaim(carried)
	end
end

-- ==========================================================
-- GIVE / RESTORE
-- ==========================================================

--- Per player: the counts to put back, and the give that set them.
local pendingRestore: { [Player]: { counts: { [string]: number }, token: number } } = {}
local giveToken = 0
local releaseHooked = false

local function restore(player: Player): boolean
	local pending = pendingRestore[player]
	if not pending then
		return false
	end
	pendingRestore[player] = nil
	if DataService.get(player) then
		setCounts(player, pending.counts)
	end
	return true
end

return {
	--- Counts, this player's prices, jam / smoke / pull flags.
	gadgetState = function(player: Player)
		return {
			counts = counts(player),
			summary = GadgetService.summarise(player),
			jammed = LaserService.isJammed(player),
			confused = GuardianService.isConfused(player),
			pulling = GadgetService.isPulling(player),
			pendingRestore = pendingRestore[player] ~= nil,
		}
	end,

	--- Sets every gadget to `n` (default: its carry limit) for manual play,
	--- and puts the previous counts back after `seconds` (default 120), on
	--- gadgetRestore, or before the tester's profile is released.
	gadgetGive = function(player: Player, n: number?, seconds: number?)
		assert(RunService:IsStudio(), "Studio only")
		assert(DataService.get(player), "no profile")
		if not releaseHooked then
			releaseHooked = true
			DataService.onBeforeRelease(function(leaving)
				restore(leaving)
			end)
		end
		local previous = if pendingRestore[player] then (pendingRestore[player] :: any).counts else counts(player)
		giveToken += 1
		local token = giveToken
		pendingRestore[player] = { counts = previous, token = token }
		local given = {}
		for _, key in GadgetConfig.Order do
			given[key] = n or GadgetConfig.Gadgets[key].maxCarried
		end
		setCounts(player, given)
		GadgetService.debugResetCooldowns(player)
		local wait = math.clamp(tonumber(seconds) or 120, 5, 1800)
		task.delay(wait, function()
			local pending = pendingRestore[player]
			if pending and pending.token == token and player.Parent then
				restore(player)
			end
		end)
		return { given = counts(player), restoresIn = wait, willRestoreTo = previous }
	end,

	gadgetRestore = function(player: Player)
		local restored = restore(player)
		return { restored = restored, counts = counts(player) }
	end,

	--- The effect of one gadget on the caller, free (no count, no cooldown,
	--- no held tool). Grapple: `target` or a floor point 20 studs ahead.
	gadgetUse = function(player: Player, key: string, target: Vector3?)
		assert(RunService:IsStudio(), "Studio only")
		local aim = target
		if key == "Grapple" and not aim then
			local root = assert(rootOf(player), "no character")
			local ahead = root.Position + root.CFrame.LookVector * 20
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = { workspace.Map }
			params.RespectCanCollide = true
			local hit = workspace:Raycast(ahead + Vector3.new(0, 6, 0), Vector3.new(0, -30, 0), params)
			aim = if hit then hit.Position else nil
		end
		local ok, reason = GadgetService.debugApply(player, key, aim)
		return { ok = ok, reason = reason, aim = if aim then tostring(aim) else nil }
	end,

	--- The shop path with the real spend: one buy, then buys to the limit
	--- and one past it. Cash and counts are restored.
	gadgetBuyTest = function(player: Player, key: string?)
		assert(RunService:IsStudio(), "Studio only")
		local profile = assert(DataService.get(player), "no profile")
		local gadget = key or "Smoke"
		local def = assert(GadgetConfig.Gadgets[gadget], "unknown gadget")
		local savedCash, savedCounts = profile.Cash, counts(player)
		local report: { [string]: any } = {}
		local ok, err = pcall(function()
			setCounts(player, {})
			local price = GadgetService.priceFor(player, gadget)
			report.price = price
			profile.Cash = price * (def.maxCarried + 1)
			local bought, reason = GadgetService.buy(player, gadget)
			report.firstBuy, report.firstReason = bought, reason
			report.cashSpent = profile.Cash == price * def.maxCarried
			report.countIsOne = GadgetService.count(player, gadget) == 1
			report.toolGiven = (player:FindFirstChildOfClass("Backpack") :: Backpack):FindFirstChild(def.toolName) ~= nil
			for _ = 2, def.maxCarried do
				GadgetService.buy(player, gadget)
			end
			local over, overReason = GadgetService.buy(player, gadget)
			report.overLimitRefused = over == false
			report.overLimitReason = overReason
			report.cashKeptOnRefusal = profile.Cash == price
			profile.Cash = 0
			setCounts(player, {})
			local broke = GadgetService.buy(player, gadget)
			report.brokeRefused = broke == false
			report.pass = bought and report.cashSpent and report.countIsOne and report.toolGiven
				and report.overLimitRefused and report.cashKeptOnRefusal and report.brokeRefused
		end)
		profile.Cash = savedCash
		setCounts(player, savedCounts)
		StateService.pushNow(player)
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,

	--- A SMOKE BOMB DROPS AN ACTIVE CHASE. Steals in `zoneIndex` (default 2,
	--- a sleeping zone), leaves the room, waits out the doorway grace, then
	--- smokes. Expect: chasing before; Searching and RUN!! cleared after; not
	--- re-acquired once the smoke is over (only a new doorway exit or laser
	--- could). Catch immunity is held; laser and movement checks exempt.
	gadgetSmokeTest = function(player: Player, zoneIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		assert(not NightService.isNight(), "run during Day")
		local profile = assert(DataService.get(player), "no profile")
		local zone = zoneIndex or 2
		local steals = profile.Lifetime.Steals
		local report: { [string]: any } = { zone = zone }
		LaserService.setExempt(player, true)
		MovementService.setExempt(player, true)
		local ok, err = pcall(function()
			NightService.setDayRemaining(260)
			GuardianService.resetAll()
			local loot, why = stealAt(player, zone, 2) -- room 1
			assert(loot, why)
			RagdollService.grantImmunity(player, 12)
			-- Out into the corridor beside the room 1 door.
			move(player, CFrame.new(-8, 4, MapConfig.zoneCenterZ(zone)))
			task.wait(GameConfig.GUARDIAN_DOOR_GRACE + 0.5)
			local before = assert(GuardianService.inspect(zone, 1))
			report.chasingBefore = before.state == "Chasing" and before.target == player.Name
			report.chasedFlagBefore = player:GetAttribute("Chased") == true
			local applied, reason = GadgetService.debugApply(player, "Smoke")
			report.applied, report.applyReason = applied, reason
			task.wait(0.2)
			local during = assert(GuardianService.inspect(zone, 1))
			report.searching = during.state == "Searching" and during.target == nil
			report.chasedFlagCleared = player:GetAttribute("Chased") ~= true
			report.stillCarrying = CarryService.getCarried(player) == loot
			report.leftRoomCleared = not GuardianService.hasLeftRoom(loot)
			task.wait(GadgetConfig.SMOKE_CONFUSE_SECONDS + 1)
			local after = assert(GuardianService.inspect(zone, 1))
			report.stateAfter = after.state
			report.notReacquired = after.target ~= player.Name and player:GetAttribute("Chased") ~= true
			report.pass = report.chasingBefore and applied and report.searching and report.chasedFlagCleared
				and report.stillCarrying and report.leftRoomCleared and report.notReacquired
		end)
		cleanUpCarry(player)
		GuardianService.resetAll()
		LaserService.setExempt(player, false)
		MovementService.setExempt(player, false)
		profile.Lifetime.Steals = steals
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,

	--- THE JAMMER. Stands in a zone 3 beam while jammed (no trip, guard asleep),
	--- then again after the jam (trip).
	gadgetJamTest = function(player: Player)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		assert(not NightService.isNight(), "run during Day")
		local report: { [string]: any } = {}
		MovementService.setExempt(player, true)
		local ok, err = pcall(function()
			NightService.setDayRemaining(260)
			GuardianService.resetAll()
			local zone = workspace.Map.Zones[ZoneConfig.Zones[3].id]
			local beam: BasePart? = nil
			for _, candidate in zone.Lasers:GetChildren() do
				if candidate:IsA("BasePart") and candidate:GetAttribute("RoomIndex") == 2 then
					beam = candidate
					break
				end
			end
			assert(beam, "no beam in zone 3 room 2")
			local a, b = beam:GetAttribute("A"), beam:GetAttribute("B")
			local at = ((a :: Vector3) + (b :: Vector3)) / 2
			move(player, CFrame.new(at.X - 8, 3.2, at.Z))
			task.wait(0.3)
			report.jammed = GadgetService.debugApply(player, "Jammer")
			player:SetAttribute("LastLaserTrip", nil)
			move(player, CFrame.new(at.X, 3.2, at.Z))
			task.wait(0.5)
			report.noTripWhileJammed = player:GetAttribute("LastLaserTrip") == nil
			local guard = GuardianService.inspect(3, 2)
			report.guardStillIdle = guard ~= nil and (guard.state == "Sleeping" or guard.state == "Patrolling")
			report.jamAttribute = player:GetAttribute("GadgetJamUntil") ~= nil
			LaserService.clearJam(player)
			move(player, CFrame.new(at.X - 8, 3.2, at.Z))
			task.wait(0.3)
			-- This trip wakes the guard for real (catch immunity would also stop
			-- the detector, so none is held): read it and leave at once.
			move(player, CFrame.new(at.X, 3.2, at.Z))
			task.wait(0.35)
			report.tripAfterJam = player:GetAttribute("LastLaserTrip") ~= nil
			report.pass = report.jammed and report.noTripWhileJammed and report.guardStillIdle and report.tripAfterJam
		end)
		LaserService.clearJam(player)
		move(player, CFrame.new(0, 4, -16))
		task.wait(0.3)
		GuardianService.resetAll()
		task.delay(0.5, MovementService.setExempt, player, false)
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,

	--- THE GRAPPLE, with the movement check ON. Pulls 20 studs along the zone
	--- 2 corridor: expect moved, no new violation. Then with loot: refused.
	gadgetGrappleTest = function(player: Player)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		assert(not NightService.isNight(), "run during Day")
		local profile = assert(DataService.get(player), "no profile")
		local steals = profile.Lifetime.Steals
		local report: { [string]: any } = {}
		local ok, err = pcall(function()
			NightService.setDayRemaining(260)
			local startZ = MapConfig.zoneStartZ(2) + 10
			move(player, CFrame.new(0, 4, startZ))
			task.wait(2) -- past the teleport grace, so the pull is measured
			local before = MovementService.snapshot(player).player
			local from = assert(rootOf(player)).Position
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = { workspace.Map }
			params.RespectCanCollide = true
			local hit = assert(workspace:Raycast(Vector3.new(0, 6, startZ + 22), Vector3.new(0, -30, 0), params), "no floor ahead")
			local ok2, reason = GadgetService.debugApply(player, "Grapple", hit.Position)
			report.applied, report.reason = ok2, reason
			task.wait(GadgetConfig.GRAPPLE_PULL_SECONDS + 1)
			local to = assert(rootOf(player)).Position
			report.moved = math.floor((to - from).Magnitude)
			local after = MovementService.snapshot(player).player
			report.newViolations = (after and after.violations or 0) - (before and before.violations or 0)
			report.pullEnded = not GadgetService.isPulling(player)
			-- Too far is refused before anything moves.
			local far, farReason = GadgetService.debugApply(player, "Grapple", to + Vector3.new(0, 0, 200))
			report.farRefused = far == false
			report.farReason = farReason
			-- Carrying: refused (GRAPPLE_WHILE_CARRYING = false).
			local loot = stealAt(player, 2, 2)
			if loot then
				local carrying, carryReason = GadgetService.debugApply(player, "Grapple", hit.Position)
				report.carrierRefused = carrying == false
				report.carrierReason = carryReason
			else
				report.carrierRefused = "not tested: no loot"
			end
			report.pass = ok2 and report.moved >= 12 and report.newViolations == 0 and report.pullEnded
				and report.farRefused and report.carrierRefused == true
		end)
		cleanUpCarry(player)
		GuardianService.resetAll()
		profile.Lifetime.Steals = steals
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,

	--- Every guard: state, whether it patrols, its override, where it is.
	gadgetPatrols = function(_player: Player)
		return GuardianService.patrolSnapshot()
	end,

	--- Patrols on/off in one zone; `on` omitted (nil) returns it to PatrolConfig.
	gadgetPatrolToggle = function(_player: Player, zoneIndex: number, on: boolean?)
		assert(type(zoneIndex) == "number" and ZoneConfig.Zones[zoneIndex], "zoneIndex 1-12")
		GuardianService.setPatrolOverride(zoneIndex, on)
		local snap = GuardianService.patrolSnapshot()
		local id = ZoneConfig.Zones[zoneIndex].id
		return { room1 = snap[id .. "_Room1"], room2 = snap[id .. "_Room2"] }
	end,

	--- A PATROL MOVES, IGNORES A BYSTANDER, AND ITS VISION CONE ALERTS.
	--- Forces patrols on in `zoneIndex` (default 7), checks the room 1 guard
	--- walks, stands an empty-handed player in front of it (nothing), then a
	--- carrier of its own loot (the doorway alert: Waking). Immunity held.
	gadgetPatrolTest = function(player: Player, zoneIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		assert(not NightService.isNight(), "run during Day")
		local profile = assert(DataService.get(player), "no profile")
		local zone = zoneIndex or 7
		local id = ZoneConfig.Zones[zone].id
		local previousOverride = GuardianService.patrolSnapshot()[id .. "_Room1"].override
		local steals = profile.Lifetime.Steals
		local report: { [string]: any } = { zone = zone }
		LaserService.setExempt(player, true)
		MovementService.setExempt(player, true)
		local ok, err = pcall(function()
			NightService.setDayRemaining(260)
			GuardianService.setPatrolOverride(zone, true)
			GuardianService.resetAll()
			local start = assert(GuardianService.inspect(zone, 1))
			report.patrolling = start.state == "Patrolling" and start.patrolActive == true
			task.wait(3)
			local walked = assert(GuardianService.inspect(zone, 1))
			report.walked = math.floor(((walked.position :: Vector3) - (start.position :: Vector3)).Magnitude)
			report.walks = report.walked >= 5

			-- A bystander right in front of it: a patrol never chases on sight.
			local function inFront(distance: number): CFrame
				local guard = assert(workspace:FindFirstChild("Guardians"))
				for _, model in guard:GetChildren() do
					if model:IsA("Model") and model:GetAttribute("ZoneIndex") == zone and model:GetAttribute("RoomIndex") == 1 then
						local root = model.PrimaryPart :: BasePart
						local at = root.Position + root.CFrame.LookVector * distance
						return CFrame.new(at.X, 4, at.Z)
					end
				end
				error("room 1 guard not found")
			end
			RagdollService.grantImmunity(player, 15)
			move(player, inFront(8))
			task.wait(0.6)
			local bystander = assert(GuardianService.inspect(zone, 1))
			report.bystanderIgnored = bystander.state == "Patrolling"

			-- A carrier of its own loot, inside the room, in the cone.
			local loot, why = stealAt(player, zone, 2)
			assert(loot, why)
			task.wait(0.3)
			local zoneAt, roomAt = Layout.locate(inFront(8).Position)
			report.frontIsInRoom = zoneAt == zone and roomAt == 1
			move(player, inFront(8))
			task.wait(0.6)
			local seen = assert(GuardianService.inspect(zone, 1))
			report.stateAfterSeen = seen.state
			report.visionAlert = (seen.state == "Waking" or seen.state == "Chasing") and seen.target == player.Name
			report.markedAsLeft = GuardianService.hasLeftRoom(loot)
			report.pass = report.patrolling and report.walks and report.bystanderIgnored
				and report.visionAlert and report.markedAsLeft
		end)
		cleanUpCarry(player)
		GuardianService.setPatrolOverride(zone, previousOverride)
		GuardianService.resetAll()
		move(player, CFrame.new(0, 4, -16))
		LaserService.setExempt(player, false)
		task.delay(0.5, MovementService.setExempt, player, false)
		profile.Lifetime.Steals = steals
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,
}
