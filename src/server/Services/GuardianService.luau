--!strict
--[[
	GuardianService
	EXACTLY ONE guardian per zone - twelve in the whole world. All four loot
	sockets in a zone share that single guardian.

	State loop:
	    SLEEPING (+ Zzz)
	      -> any item in the zone is successfully stolen
	    WAKING   (+ "!")
	      -> turns to the thief
	    CHASING  (that thief only, never a bystander)
	      -> A: thief crosses the red safe line  -> escape, guardian stops AT the
	            line, walks home, sleeps again
	      -> B: guardian catches the thief first -> ragdoll + launch, loot resets,
	            guardian walks home, sleeps again

	Hard rules:
	  * No aggro of any kind before a successful steal. Walking through the zone,
	    standing on the loot, brushing the guardian - none of it wakes anything.
	  * One chase per zone. A second steal in a busy zone is refused until the
	    guardian has fully reset.
	  * The red safe line is a real AI boundary, not a distance check. The
	    guardian never crosses it, never paths through it, and cannot touch a
	    player who is already behind it. Safe zone always wins.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local LootService = require(script.Parent.LootService)
local BaseService = require(script.Parent.BaseService)
local RagdollService = require(script.Parent.RagdollService)

local GuardianService = {}

export type GuardianState = "Sleeping" | "Waking" | "Chasing" | "Returning"

type Guardian = {
	zoneIndex: number,
	home: CFrame,
	state: GuardianState,
	model: Model?,
	humanoid: Humanoid?,
	root: BasePart?,
	target: Player?,
	lootId: string?,
	lastRepath: number,
	wakeAt: number?,
}

-- Tuning for the catch. Big and funny, but controlled: capped, single-shot, and
-- never enough to clear an 80-stud containment wall.
local WAKE_DELAY = 0.55 -- shocked beat before the chase actually starts
-- Tuned by measurement, not by feel: 110/72 threw the player 156 studs, which
-- launched them clean across the safe line and into the base plaza. These land
-- around 80-90 studs - clearly dramatic, still comfortably inside the lane.
local CATCH_KNOCKBACK = 72
local CATCH_LIFT = 62
local CATCH_STUN = 1.6
local CATCH_IMMUNITY = 2.5
local SAFE_LINE_MARGIN = 6 -- studs the guardian keeps on the danger side
local LEASH_DISTANCE = 900 -- never chase further than this from home

local guardians: { [number]: Guardian } = {}

local safeLineZ = 0

local onCatch: (LootService.LootInstance) -> () = function() end
local onEscape: (LootService.LootInstance, Player) -> () = function() end

--- Wired from init so this service never has to require CarryService back.
function GuardianService.setCatchHandler(fn: (LootService.LootInstance) -> ())
	onCatch = fn
end

function GuardianService.setEscapeHandler(fn: (LootService.LootInstance, Player) -> ())
	onEscape = fn
end

-- ==========================================================
-- SAFE LINE
-- ==========================================================

--- True when a position is on the SAFE side of the red line.
local function isBehindSafeLine(position: Vector3): boolean
	return position.Z < safeLineZ
end

--- Nearest point a guardian is allowed to occupy: never past the red line.
local function clampToDangerSide(position: Vector3): Vector3
	local limit = safeLineZ + SAFE_LINE_MARGIN
	if position.Z < limit then
		return Vector3.new(position.X, position.Y, limit)
	end
	return position
end

-- ==========================================================
-- PRESENTATION
-- ==========================================================

--- The client reads this attribute to drive the floating Zzz and the "!" pop.
--- Keeping the animation client-side means twelve looping effects cost the
--- server nothing.
local function publishState(guardian: Guardian)
	if guardian.model then
		guardian.model:SetAttribute("State", guardian.state)
	end
end

local function sleepPose(guardian: Guardian)
	local root = guardian.root
	if not root then
		return
	end
	-- Anchored while asleep: it cannot drift, cannot be shoved by a passing
	-- player, and costs no physics.
	root.Anchored = true
	root.CFrame = guardian.home * CFrame.Angles(math.rad(-20), 0, 0)
end

local function enterSleep(guardian: Guardian)
	guardian.state = "Sleeping"
	guardian.target = nil
	guardian.lootId = nil
	guardian.wakeAt = nil
	sleepPose(guardian)
	publishState(guardian)
end

-- ==========================================================
-- RIG
-- ==========================================================

local function buildRig(zoneIndex: number): Model
	local zone = ZoneConfig.Zones[zoneIndex]
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local source = if assets and assets:FindFirstChild("Guardians")
		then assets.Guardians:FindFirstChild(`Zone{string.format("%02d", zoneIndex)}_{zone.guardian}`)
		else nil

	if source and source:IsA("Model") then
		return source:Clone()
	end

	-- The HumanoidRootPart doubles as the visible, COLLIDABLE body. A rig whose
	-- parts all have CanCollide off never leaves Freefall, and a Humanoid in
	-- Freefall silently ignores MoveTo.
	local model = Instance.new("Model")
	model.Name = zone.guardian

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2.6, 4, 1.6)
	root.Color = Color3.fromRGB(52, 78, 168)
	root.Material = Enum.Material.SmoothPlastic
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.CanCollide = true
	root.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.7, 1.7, 1.7)
	head.Color = Color3.fromRGB(240, 204, 160)
	head.Material = Enum.Material.SmoothPlastic
	head.TopSurface = Enum.SurfaceType.Smooth
	head.BottomSurface = Enum.SurfaceType.Smooth
	head.CanCollide = false
	head.CFrame = root.CFrame * CFrame.new(0, 2.85, 0)
	head.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = head
	weld.Parent = root

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.HipHeight = 0
	humanoid.Parent = model

	model.PrimaryPart = root
	return model
end

local function guardianSpeed(zoneIndex: number): number
	local zone = ZoneConfig.Zones[zoneIndex]
	local matched = GameConfig.walkSpeedFromPower(math.max(zone.recommendedSpeed, GameConfig.STARTING_SPEED_POWER))
	return matched * ZoneConfig.GUARDIAN_SPEED_FACTOR
end

-- ==========================================================
-- CHASE CONTROL
-- ==========================================================

function GuardianService.isZoneBusy(zoneIndex: number): boolean
	local guardian = guardians[zoneIndex]
	if not guardian then
		return false
	end
	return guardian.state ~= "Sleeping"
end

local function goHome(guardian: Guardian)
	guardian.state = "Returning"
	guardian.target = nil
	guardian.lootId = nil
	publishState(guardian)

	local humanoid = guardian.humanoid
	if humanoid then
		humanoid:MoveTo(guardian.home.Position)
	end
end

--- Called the moment a zone's loot is successfully stolen.
function GuardianService.wake(loot: LootService.LootInstance, thief: Player)
	local guardian = guardians[loot.zoneIndex]
	if not guardian or not guardian.humanoid or not guardian.root then
		return
	end
	if guardian.state ~= "Sleeping" then
		return -- one chase per zone
	end

	guardian.state = "Waking"
	guardian.target = thief
	guardian.lootId = loot.id
	guardian.lastRepath = 0
	guardian.wakeAt = os.clock() + WAKE_DELAY

	-- Stand up and turn to face the thief.
	guardian.root.Anchored = false
	local character = thief.Character
	local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
	if targetRoot and targetRoot:IsA("BasePart") then
		local from = guardian.root.Position
		local look = Vector3.new(targetRoot.Position.X, from.Y, targetRoot.Position.Z)
		guardian.root.CFrame = CFrame.lookAt(from, look)
	end

	publishState(guardian)
end

function GuardianService.stopChaseFor(loot: LootService.LootInstance)
	local guardian = guardians[loot.zoneIndex]
	if guardian and guardian.lootId == loot.id and guardian.state ~= "Sleeping" then
		goHome(guardian)
	end
end

-- ==========================================================
-- CATCH
-- ==========================================================

local function ragdollAndLaunch(player: Player, fromPosition: Vector3)
	RagdollService.launch(player, fromPosition, {
		knockback = CATCH_KNOCKBACK,
		lift = CATCH_LIFT,
		stun = CATCH_STUN,
		immunity = CATCH_IMMUNITY,
	})
end

--- True while a player is mid-launch, so a guardian cannot re-hit them.
function GuardianService.isStunned(player: Player): boolean
	return RagdollService.isImmune(player)
end

-- ==========================================================
-- STEP
-- ==========================================================

local function step()
	local now = os.clock()

	for _, guardian in guardians do
		local state = guardian.state
		if state == "Sleeping" then
			continue -- idle guardians cost nothing
		end

		local humanoid = guardian.humanoid
		local root = guardian.root
		if not humanoid or not root then
			continue
		end

		-- Absolute boundary: even mid-physics the guardian may never end up on
		-- the safe side of the red line.
		if root.Position.Z < safeLineZ + SAFE_LINE_MARGIN then
			root.CFrame = CFrame.new(clampToDangerSide(root.Position)) * (root.CFrame - root.Position)
			root.AssemblyLinearVelocity = Vector3.zero
		end

		if state == "Returning" then
			if (root.Position - guardian.home.Position).Magnitude < 6 then
				enterSleep(guardian)
			elseif now - guardian.lastRepath >= ZoneConfig.GUARDIAN_REPATH_INTERVAL then
				guardian.lastRepath = now
				humanoid:MoveTo(guardian.home.Position)
			end
			continue
		end

		local target = guardian.target
		local lootId = guardian.lootId
		local loot = if lootId then LootService.get(lootId) else nil

		-- The chase is only valid while THIS thief still carries THIS item.
		if not target or not target.Parent or not loot or loot.state ~= "Carried" or loot.carrier ~= target then
			goHome(guardian)
			continue
		end

		local character = target.Character
		local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
		if not targetRoot or not targetRoot:IsA("BasePart") then
			goHome(guardian)
			continue
		end

		-- ESCAPE: crossing the red line, or reaching their own base, ends it.
		if isBehindSafeLine(targetRoot.Position) or BaseService.isInOwnSafeZone(target) then
			onEscape(loot, target)
			goHome(guardian)
			continue
		end

		if state == "Waking" then
			if now < (guardian.wakeAt or 0) then
				continue -- hold the shocked beat
			end
			guardian.state = "Chasing"
			publishState(guardian)
		end

		if (root.Position - guardian.home.Position).Magnitude > LEASH_DISTANCE then
			goHome(guardian)
			continue
		end

		-- CATCH
		local distance = (root.Position - targetRoot.Position).Magnitude
		if distance <= ZoneConfig.GUARDIAN_CATCH_RADIUS and not GuardianService.isStunned(target) then
			ragdollAndLaunch(target, root.Position)
			onCatch(loot)
			goHome(guardian)
			continue
		end

		if now - guardian.lastRepath >= ZoneConfig.GUARDIAN_REPATH_INTERVAL then
			guardian.lastRepath = now
			-- Never path THROUGH the line: the move goal is clamped too.
			humanoid:MoveTo(clampToDangerSide(targetRoot.Position))
		end
	end
end

-- ==========================================================
-- START
-- ==========================================================

function GuardianService.start()
	local map = workspace:WaitForChild("Map", 20)
	local zonesFolder = map:WaitForChild("Zones", 10)

	local line = map:FindFirstChild("SafeZone") and map.SafeZone:FindFirstChild("BoundaryLine")
	safeLineZ = if line and line:IsA("BasePart") then line.Position.Z else 0

	local holder = Instance.new("Folder")
	holder.Name = "Guardians"
	holder.Parent = workspace

	for zoneIndex, zoneDef in ZoneConfig.Zones do
		local zone = zonesFolder:FindFirstChild(zoneDef.id)
		local posts = zone and zone:FindFirstChild("GuardianSpawns")
		local post = posts and posts:FindFirstChild("GuardianPost")
		if not post or not post:IsA("BasePart") then
			warn(`[GuardianService] {zoneDef.id} has no GuardianPost - rebuild the map`)
			continue
		end

		local guardian: Guardian = {
			zoneIndex = zoneIndex,
			home = post.CFrame * CFrame.new(0, 2.2, 0),
			state = "Sleeping",
			lastRepath = 0,
		}

		local model = buildRig(zoneIndex)
		local humanoid = model:FindFirstChildWhichIsA("Humanoid")
		local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not root:IsA("BasePart") then
			warn(`[GuardianService] malformed rig for {zoneDef.id}`)
			model:Destroy()
			continue
		end

		humanoid.WalkSpeed = guardianSpeed(zoneIndex)
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

		model:PivotTo(guardian.home)
		model.Parent = holder

		guardian.model = model
		guardian.humanoid = humanoid
		guardian.root = root
		guardians[zoneIndex] = guardian

		model:SetAttribute("ZoneIndex", zoneIndex)
		enterSleep(guardian)
	end

	-- Wake ONLY on a real steal. Nothing about proximity or presence aggros.
	LootService.onStateChanged(function(loot, previous, next)
		if next == "Carried" and previous ~= "Dropped" and loot.carrier then
			GuardianService.wake(loot, loot.carrier)
		elseif next == "Returning" or next == "Placed" or next == "Spawned" then
			GuardianService.stopChaseFor(loot)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		for _, guardian in guardians do
			if guardian.target == player then
				goHome(guardian)
			end
		end
	end)

	RunService.Heartbeat:Connect(step)

	local count = 0
	for _ in guardians do
		count += 1
	end
	print(`[GuardianService] {count} guardians posted (one per zone), safe line at Z={safeLineZ}`)
end

--- Traps root a guardian without breaking its state machine: it keeps its
--- target and resumes the same chase when the root expires (GDD section 12).
function GuardianService.rootGuardian(zoneIndex: number, seconds: number): boolean
	local guardian = guardians[zoneIndex]
	local humanoid = guardian and guardian.humanoid
	if not guardian or not humanoid or guardian.state == "Sleeping" then
		return false
	end
	if humanoid:GetAttribute("Rooted") then
		return false -- already rooted; never stack
	end

	local restore = humanoid.WalkSpeed
	humanoid.WalkSpeed = 0
	humanoid:SetAttribute("Rooted", true)
	if guardian.model then
		guardian.model:SetAttribute("Rooted", true)
	end

	task.delay(seconds, function()
		if not humanoid.Parent then
			return
		end
		humanoid.WalkSpeed = restore
		humanoid:SetAttribute("Rooted", nil)
		if guardian.model then
			guardian.model:SetAttribute("Rooted", nil)
		end
	end)
	return true
end

--- The zone a guardian is currently chasing in, for trap targeting.
function GuardianService.activeChaseZones(): { number }
	local zones = {}
	for zoneIndex, guardian in guardians do
		if guardian.state == "Chasing" or guardian.state == "Waking" then
			table.insert(zones, zoneIndex)
		end
	end
	return zones
end

--- Position of a zone's guardian, or nil when it has no rig.
function GuardianService.guardianPosition(zoneIndex: number): Vector3?
	local guardian = guardians[zoneIndex]
	return if guardian and guardian.root then guardian.root.Position else nil
end

--- Debug/reporting helper.
function GuardianService.snapshot(): { [string]: any }
	local out = {}
	for zoneIndex, guardian in guardians do
		out[ZoneConfig.Zones[zoneIndex].id] = {
			state = guardian.state,
			target = if guardian.target then guardian.target.Name else nil,
			z = if guardian.root then math.floor(guardian.root.Position.Z) else nil,
		}
	end
	return out
end

return GuardianService
