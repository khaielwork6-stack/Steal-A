--!strict
--[[
	DebugCommands/Security
	Studio test commands for the security pass (docs/handoff-parts/
	security-gameplay.md). Loaded by DebugService; invoke like any command:

	    ServerStorage.DebugInvoke:Invoke("secTeleportCarry")
	    ServerStorage.DebugInvoke:Invoke("secLegitTeleport")
	    ServerStorage.DebugInvoke:Invoke("secGrabFar")
	    ServerStorage.DebugInvoke:Invoke("secNightDrop")          -- fast timers
	    ServerStorage.DebugInvoke:Invoke("secNightDrop", nil, false) -- real 75s
	    ServerStorage.DebugInvoke:Invoke("secHeistFulfil")
	    ServerStorage.DebugInvoke:Invoke("secMovement")
	    ServerStorage.DebugInvoke:Invoke("secExempt", nil, true)

	STUDIO WRITES TO THE OWNER'S REAL DATASTORE. Every command that touches
	the profile (Lifetime.Steals, PendingSteal, PendingReveal, a display
	item's ProtectedUntil) saves the original first and puts it back in a
	cleanup that runs whether the body succeeded or threw.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local SecurityConfig = require(ReplicatedStorage.Shared.Config.SecurityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local Services = script.Parent.Parent
local BaseService = require(Services.BaseService)
local CarryService = require(Services.CarryService)
local DataService = require(Services.DataService)
local LootService = require(Services.LootService)
local MovementService = require(Services.MovementService)
-- Every command here pivots through rooms; a laser trip would start a chase
-- that has nothing to do with what is being measured.
local Laser = require(Services.LaserService)

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

--- A socket in `zoneIndex` holding a Spawned item this player may take.
local function stealableSocket(player: Player, zoneIndex: number): any
	for socketIndex = 1, ZoneConfig.SOCKETS_PER_ZONE do
		local socket = LootService.getSocket(zoneIndex, socketIndex)
		local loot = socket and socket.loot
		if loot and loot.state == "Spawned" and CarryService.mayTakeLoot(player, loot) then
			return socket
		end
	end
	return nil
end

--- Steals the first stealable item in the zone the way DebugService "steal"
--- does (server pivot next to it, then the real trySteal).
local function stealIn(player: Player, zoneIndex: number): (LootService.LootInstance?, string?)
	local socket = stealableSocket(player, zoneIndex)
	if not socket then
		return nil, `no stealable item in zone {zoneIndex}`
	end
	local character = player.Character
	if not character then
		return nil, "no character"
	end
	MovementService.allowTeleport(player)
	character:PivotTo(socket.part.CFrame * CFrame.new(0, 4, 6))
	task.wait(0.4)
	local loot = socket.loot
	if not loot or not CarryService.trySteal(player, loot) then
		return nil, "steal refused"
	end
	return loot, nil
end

--- Whatever the test left in the world goes home.
local function cleanUpLoot(player: Player, loot: LootService.LootInstance?)
	local carried = CarryService.getCarried(player)
	if carried then
		CarryService.reclaim(carried)
	end
	if loot and loot.state == "Dropped" then
		LootService.returnToOrigin(loot)
	end
end

local function violations(player: Player): number
	local snap = MovementService.snapshot(player)
	return if snap.player then snap.player.violations else 0
end

return {
	--- The movement record for this player: speed, strikes, budget, trusted
	--- position, and the server-wide counters (autoTrustedPivots must stay 0
	--- while a player simply walks - see the handoff note).
	secMovement = function(player: Player)
		return MovementService.snapshot(player)
	end,

	--- Studio only: switch the movement check off / on for this player.
	secExempt = function(player: Player, on: boolean?)
		MovementService.setExempt(player, on ~= false)
		return { exempt = MovementService.isExempt(player) }
	end,

	--- A CHEATING TELEPORT HOME WHILE CARRYING. Steals in `zoneIndex`
	--- (default 3), waits out the grace, then moves the character to its own
	--- spawn the way a client would. Expect: snapped back near the socket,
	--- carry gone, the item Dropped where the character was snapped to, one
	--- more violation.
	secTeleportCarry = function(player: Player, zoneIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		local profile = assert(DataService.get(player), "no profile")
		local spawn = assert(BaseService.homeSpawn(player), "no home spawn")
		local steals = profile.Lifetime.Steals
		local before = violations(player)
		local loot: LootService.LootInstance? = nil
		local report: { [string]: any } = {}
		Laser.setExempt(player, true)
		local ok, err = pcall(function()
			local stolen, why = stealIn(player, zoneIndex or 3)
			assert(stolen, why)
			loot = stolen
			local stolenAt = assert(rootOf(player)).Position
			task.wait(SecurityConfig.MOVEMENT_TELEPORT_GRACE + 0.3)
			local movedAt = os.clock()
			MovementService.debugSimulateClientMove(player, spawn.CFrame * CFrame.new(0, 4, 0))
			-- The state is read the moment the carry ends: a room guard may
			-- fetch the drop a second later, which is correct but not this test.
			while CarryService.getCarried(player) and os.clock() - movedAt < 2 do
				task.wait(0.03)
			end
			report.reactionSeconds = math.floor((os.clock() - movedAt) * 100) / 100
			report.lootStateAtDrop = stolen.state
			local root = assert(rootOf(player))
			report.distanceFromSteal = math.floor((root.Position - stolenAt).Magnitude)
			report.snappedBack = (root.Position - stolenAt).Magnitude < 40
			report.carryGone = CarryService.getCarried(player) == nil
			task.wait(0.6)
			report.newViolations = violations(player) - before
			report.stillHomeAfter = BaseService.isInOwnSafeZone(player)
			report.pass = report.snappedBack and report.carryGone and report.lootStateAtDrop == "Dropped"
				and report.newViolations >= 1 and not report.stillHomeAfter
		end)
		Laser.setExempt(player, false)
		cleanUpLoot(player, loot)
		profile.Lifetime.Steals = steals
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,

	--- A LEGITIMATE SERVER TELEPORT: BaseService.teleportHome with the Studio
	--- auto-trust switched OFF, so only its own allowTeleport call can keep it
	--- legal. Expect: no new violation, the trusted position at home. Also
	--- checks the BASE button refuses a carrier.
	secLegitTeleport = function(player: Player)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		local profile = assert(DataService.get(player), "no profile")
		local steals = profile.Lifetime.Steals
		local before = violations(player)
		local loot: LootService.LootInstance? = nil
		local report: { [string]: any } = {}
		local wasAuto = MovementService.debugAutoTrust()
		local ok, err = pcall(function()
			-- Somewhere away from home first, so the trip is a real jump.
			local character = assert(player.Character)
			MovementService.allowTeleport(player)
			character:PivotTo(CFrame.new(0, 4, 60))
			task.wait(SecurityConfig.MOVEMENT_TELEPORT_GRACE + 0.5)

			MovementService.debugSetAutoTrust(false)
			local moved, reason = BaseService.teleportHome(player)
			report.teleported, report.reason = moved, reason
			task.wait(2)
			local trusted = MovementService.trustedPosition(player)
			report.trustedAtHome = trusted ~= nil and BaseService.plotAt(trusted) == BaseService.getPlot(player)
			report.newViolations = violations(player) - before
			MovementService.debugSetAutoTrust(wasAuto)

			-- And the refusal: a carrier may not use the BASE button.
			task.wait(3.1) -- teleportHome's own cooldown
			local stolen, why = stealIn(player, 1)
			if stolen then
				loot = stolen
				local refused, refusal = BaseService.teleportHome(player)
				report.carrierRefused = refused == false
				report.carrierReason = refusal
			else
				report.carrierRefused = `not tested: {why}`
			end
			report.pass = moved and report.trustedAtHome and report.newViolations == 0 and report.carrierRefused == true
		end)
		MovementService.debugSetAutoTrust(wasAuto)
		cleanUpLoot(player, loot)
		profile.Lifetime.Steals = steals
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,

	--- GRABBING A DROP FROM FAR AWAY. Steals, carries it (server pivot) to
	--- the lobby side of the red line - where no guard may fetch it, so it
	--- lies still for DROPPED_RECLAIM_WINDOW - drops it, moves well out of
	--- reach and asks for the grab. Expect: refused. Then comes back and grabs
	--- it properly, which must be accepted.
	secGrabFar = function(player: Player, zoneIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		local profile = assert(DataService.get(player), "no profile")
		local steals = profile.Lifetime.Steals
		local loot: LootService.LootInstance? = nil
		local report: { [string]: any } = {}
		Laser.setExempt(player, true)
		local ok, err = pcall(function()
			local stolen, why = stealIn(player, zoneIndex or 2)
			assert(stolen, why)
			loot = stolen
			local character = assert(player.Character)
			local near = CFrame.new(0, 4, -10)
			MovementService.allowTeleport(player)
			character:PivotTo(near)
			task.wait(0.3)
			CarryService.forceDrop(stolen)
			report.dropped = stolen.state == "Dropped"
			-- Comfortably past the grab range (range x 1.6 in validatePickup),
			-- still inside the 78-stud lobby safe zone for a normal container.
			local away = math.max(40, stolen.interactRange * 1.6 + 15)
			report.awayStuds = math.floor(away)
			MovementService.allowTeleport(player)
			character:PivotTo(near * CFrame.new(0, 0, -away))
			task.wait(0.4)
			report.farRefused = CarryService.tryGrabDropped(player, stolen) == false
			MovementService.allowTeleport(player)
			character:PivotTo(near)
			task.wait(0.4)
			report.nearAccepted = stolen.state == "Dropped" and CarryService.tryGrabDropped(player, stolen) == true
			report.pass = report.dropped and report.farRefused and report.nearAccepted
		end)
		Laser.setExempt(player, false)
		cleanUpLoot(player, loot)
		profile.Lifetime.Steals = steals
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,

	--- THE NIGHT-DROP GHOST (passes B5/B6). The old bug, step by step:
	---   1. an item is dropped where no guard fetches it (the lobby side),
	---   2. the Night retires it and refills its socket,
	---   3. someone steals the refill, so the socket is EMPTY again,
	---   4. the old drop's timer fires and rebuilds the retired item into that
	---      empty socket - an untracked container no prompt can resolve.
	--- Expect: the old item stays Retired with no model, and the socket is
	--- either empty or holds a live, stealable container. `fast` (default
	--- true) shrinks the two drop timers for this one drop and restores them.
	--- Zone 2 by default: not Zone 1, whose own respawn would muddy step 4.
	secNightDrop = function(player: Player, fast: boolean?, zoneIndex: number?)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		local Night = require(Services.NightService)
		assert(not Night.isNight(), "run during the Day")
		local profile = assert(DataService.get(player), "no profile")
		local steals = profile.Lifetime.Steals
		local reclaim, orphan = GameConfig.DROPPED_RECLAIM_WINDOW, GameConfig.DROPPED_ORPHAN_TIMEOUT
		local loot: LootService.LootInstance? = nil
		local refill: LootService.LootInstance? = nil
		local report: { [string]: any } = {}
		Laser.setExempt(player, true)
		local ok, err = pcall(function()
			local zone = zoneIndex or 2
			local timers = if fast ~= false then { reclaim = 4, orphan = 6 } else { reclaim = reclaim, orphan = orphan }
			Night.setDayRemaining(260)
			local stolen, why = stealIn(player, zone)
			assert(stolen, why)
			loot = stolen
			local socket = assert(LootService.getSocket(stolen.zoneIndex, stolen.socketIndex))
			local character = assert(player.Character)
			MovementService.allowTeleport(player)
			character:PivotTo(CFrame.new(0, 4, -10))
			task.wait(0.3)
			-- The timers are read when the drop schedules them.
			GameConfig.DROPPED_RECLAIM_WINDOW, GameConfig.DROPPED_ORPHAN_TIMEOUT = timers.reclaim, timers.orphan
			local droppedAt = os.clock()
			CarryService.forceDrop(stolen)
			GameConfig.DROPPED_RECLAIM_WINDOW, GameConfig.DROPPED_ORPHAN_TIMEOUT = reclaim, orphan
			report.dropped = stolen.state == "Dropped"

			-- 2. The Night: forceDay runs the refresh if the timer has not.
			Night.forceNight()
			task.wait(0.5)
			Night.forceDay()
			report.retired = stolen.state == "Retired" and not LootService.isLive(stolen)

			-- 3. Empty the refilled socket before the first timer fires.
			local current = socket.loot
			if current and current.state == "Spawned" then
				-- trySteal checks range, so walk (pivot) to it first.
				MovementService.allowTeleport(player)
				character:PivotTo(socket.part.CFrame * CFrame.new(0, 4, 6))
				task.wait(0.4)
				if CarryService.trySteal(player, current) then
					refill = current
				end
			end
			report.socketEmptiedBeforeTimers = socket.loot == nil
			report.emptiedWithinWindow = os.clock() - droppedAt < timers.reclaim

			-- 4. Past both timers.
			task.wait(math.max(0, timers.orphan + 1 - (os.clock() - droppedAt)))
			report.stayedRetired = stolen.state == "Retired" and stolen.model == nil
			local now = socket.loot
			local prompt = if now then LootService.promptOf(now) else nil
			report.noGhostInSocket = now ~= stolen
			report.socketHealthy = now == nil
				or (LootService.isLive(now) and prompt ~= nil and LootService.fromDescendant(prompt) == now)
			report.pass = report.dropped and report.retired and report.stayedRetired
				and report.noGhostInSocket and report.socketHealthy
		end)
		GameConfig.DROPPED_RECLAIM_WINDOW, GameConfig.DROPPED_ORPHAN_TIMEOUT = reclaim, orphan
		if Night.isNight() then
			Night.forceDay()
		end
		Laser.setExempt(player, false)
		-- The refill goes back to its socket (the real catch path); the retired
		-- item is gone for good by design.
		cleanUpLoot(player, refill)
		cleanUpLoot(player, loot)
		profile.Lifetime.Steals = steals
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,

	--- THE RECEIPT CONTRACTS (passes B2 / B19). Solo Studio has no second
	--- player to rob, so this drives every branch that needs none, against
	--- the tester's own profile, and restores PendingSteal / PendingReveal,
	--- the robbery-cooldown stamp and any ProtectedUntil it touched.
	---   noPending  -> false, "undeliverable"
	---   expired    -> false, "undeliverable", record cleared
	---   victimAway -> false, "retry", record kept
	---   itemGone   -> false, "undeliverable" (victim = the tester)
	---   protected  -> false, "retry"
	---   cooldown   -> false, "retry"
	---   night      -> waits for dawn (forced after 1s), then "retry" (victim away)
	---   reveal     -> HatchService.fulfil with nothing pending: "undeliverable"
	secHeistFulfil = function(player: Player)
		assert(RunService:IsStudio(), "Studio only")
		assert(not CarryService.getCarried(player), "finish the current carry first")
		local Heist = require(Services.HeistService)
		local Hatch = require(Services.HatchService)
		local Night = require(Services.NightService)
		local profile = assert(DataService.get(player), "no profile")
		local product = assert(MonetizationConfig.StealProducts[1], "no steal product")
		local savedSteal, savedReveal = profile.PendingSteal, profile.PendingReveal
		local savedRobbed = Heist.debugRobbedAt(player.UserId)
		local touched: { item: DataService.DisplayItem, protectedUntil: any }? = nil
		local report: { [string]: any } = {}

		local function record(ownerUserId: number, instanceId: string, age: number): any
			return {
				ownerUserId = ownerUserId,
				ownerName = "SecurityTest",
				instanceId = instanceId,
				slotIndex = 1,
				rarity = product.rarity,
				itemName = "SecurityTest",
				productId = product.productId,
				productKey = product.key,
				createdAt = os.time() - age,
			}
		end
		local function run(label: string, pending: any): (boolean, any)
			profile.PendingSteal = pending
			local delivered, why = Heist.fulfil(player, profile, product, `sec-test-{label}`)
			report[label] = { delivered = delivered, result = why, recordKept = profile.PendingSteal ~= nil }
			return delivered, why
		end

		local ok, err = pcall(function()
			run("noPending", nil)
			run("expired", record(1, "sec-expired", SecurityConfig.HEIST_PENDING_EXPIRY + 60))
			run("victimAway", record(1, "sec-away", 5))
			run("itemGone", record(player.UserId, "sec-no-such-item", 5))

			-- A real, revealed item of the tester's, for the two rule checks.
			local own: DataService.DisplayItem? = nil
			for _, item in profile.DisplayItems do
				if item.Hatched ~= false and not item.RobbedBy then
					own = item
					break
				end
			end
			if own then
				local original = own.ProtectedUntil
				touched = { item = own, protectedUntil = original }
				own.ProtectedUntil = os.time() + 60
				run("protected", record(player.UserId, own.InstanceId, 5))
				own.ProtectedUntil = original
				Heist.debugRobbedAt(player.UserId, os.clock())
				run("cooldown", record(player.UserId, own.InstanceId, 5))
				Heist.debugRobbedAt(player.UserId, savedRobbed or -1)
			else
				report.protected = "not tested: no revealed display item"
				report.cooldown = "not tested: no revealed display item"
			end

			Night.setDayRemaining(260)
			Night.forceNight()
			task.delay(1, Night.forceDay)
			local started = os.clock()
			run("night", record(1, "sec-night", 5))
			report.night.waitedSeconds = math.floor((os.clock() - started) * 10) / 10

			profile.PendingReveal = nil
			local revealProduct = MonetizationConfig.revealProductFor(60)
			if revealProduct then
				local delivered, why = Hatch.fulfil(player, profile, revealProduct, "sec-test-reveal")
				report.reveal = { delivered = delivered, result = why }
			else
				report.reveal = "not tested: no reveal product"
			end

			local function is(label: string, want: string): boolean
				local row = report[label]
				return type(row) ~= "table" or (row.delivered == false and row.result == want)
			end
			report.pass = is("noPending", "undeliverable") and is("expired", "undeliverable")
				and report.expired.recordKept == false and is("victimAway", "retry")
				and is("itemGone", "undeliverable") and is("protected", "retry") and is("cooldown", "retry")
				and is("night", "retry") and report.night.waitedSeconds >= 0.9 and is("reveal", "undeliverable")
		end)
		if Night.isNight() then
			Night.forceDay()
		end
		if touched then
			touched.item.ProtectedUntil = touched.protectedUntil
		end
		Heist.debugRobbedAt(player.UserId, savedRobbed or -1)
		profile.PendingSteal, profile.PendingReveal = savedSteal, savedReveal
		if not ok then
			report.error = tostring(err)
		end
		return report
	end,
}
