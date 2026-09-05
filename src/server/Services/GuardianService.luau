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
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local Audio = require(ReplicatedStorage.Shared.Util.Audio)

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
	shellMotor: Weld?, -- drives the imported costume's pose; nil when unskinned
}

-- Tuning for the catch. Big and funny, but controlled: capped, single-shot, and
-- never enough to clear an 80-stud containment wall.
local WAKE_DELAY = 0.55 -- shocked beat before the chase actually starts

-- Run-cycle tuning. Deliberately over the top: this is the first chase a new
-- player ever sees and it should read as comedy, not as a walk.
local RUN_CYCLE_SPEED = 15 -- radians/sec; ~4.8 footfalls a second
local RUN_BOB = 0.85 -- studs of vertical pump per stride
local RUN_ROLL = math.rad(17) -- side-to-side rock
local RUN_YAW = math.rad(11) -- shoulder swing
local RUN_LEAN = math.rad(-24) -- pitched forward, chasing his own centre of mass
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

	-- Positional and server-owned, so every nearby player hears it from the right
	-- direction without any replication of ours. Idempotent: re-entering sleep
	-- does not start a second copy.
	Audio.startLoop("Snoring", guardian.root)
end

-- ==========================================================
-- RIG
-- ==========================================================

--- Dresses a functional rig in an imported model.
---
--- The imports are static props - 28 anchored parts, no Humanoid, no Motor6D -
--- so they cannot be animated by Roblox's animation system and cannot drive a
--- Humanoid themselves. Rather than rebuild the artist's model into a rig (which
--- risks breaking it), the model is welded on as a costume over the working
--- rig: physics and pathfinding stay with the invisible root, and the costume
--- is posed procedurally in animateShell().
--- Part names a Humanoid treats as its own body. A costume that uses them gets
--- ADOPTED by the rig's Humanoid once parented, which re-enables collision on
--- the torso and can rebind the root - so the guardian jams in place a few studs
--- from its target and never lands a catch.
local RESERVED_PART_NAMES = {
	HumanoidRootPart = true,
	Head = true,
	Torso = true,
	UpperTorso = true,
	LowerTorso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
}

local function dressRig(model: Model, root: BasePart, shell: Model)
	shell.Name = "Shell"
	shell:PivotTo(root.CFrame)

	-- A character-shaped import brings its own Humanoid and its own body-part
	-- names. Both have to go before it is parented: two Humanoids in one model
	-- is undefined, and the reserved names are what let the surviving Humanoid
	-- take the costume over. Purely decorative geometry from here on.
	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("Humanoid") then
			descendant:Destroy()
		end
	end

	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("BasePart") then
			if RESERVED_PART_NAMES[descendant.Name] then
				descendant.Name = `Shell_{descendant.Name}`
			end
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end

	-- A single pivot part the whole costume hangs off, so animateShell only has
	-- to move one thing and the model keeps its internal welds.
	local pivot = Instance.new("Part")
	pivot.Name = "ShellPivot"
	pivot.Size = Vector3.new(0.2, 0.2, 0.2)
	pivot.Transparency = 1
	pivot.CanCollide = false
	pivot.CanQuery = false
	pivot.CanTouch = false
	pivot.Massless = true
	pivot.CFrame = root.CFrame
	pivot.Parent = model

	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("BasePart") then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = pivot
			weld.Part1 = descendant
			weld.Parent = pivot
		end
	end

	shell.Parent = model

	-- Re-assert after parenting. The Humanoid only acts on parts once they are
	-- inside its model, so anything it would have re-collided is corrected here
	-- even if a future import uses a body-part name this list does not know.
	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Massless = true
		end
	end

	-- The pivot follows the root; animateShell drives this offset every frame.
	local motor = Instance.new("Weld")
	motor.Name = "ShellMotor"
	motor.Part0 = root
	motor.Part1 = pivot
	motor.C0 = CFrame.new()
	motor.Parent = root

	return motor
end

local function buildRig(zoneIndex: number): Model
	local zone = ZoneConfig.Zones[zoneIndex]
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local source = if assets and assets:FindFirstChild("Guardians")
		then assets.Guardians:FindFirstChild(`Zone{string.format("%02d", zoneIndex)}_{zone.guardian}`)
		else nil

	-- The HumanoidRootPart doubles as the COLLIDABLE body. A rig whose parts all
	-- have CanCollide off never leaves Freefall, and a Humanoid in Freefall
	-- silently ignores MoveTo.
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

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.HipHeight = 0
	humanoid.Parent = model

	model.PrimaryPart = root

	if source and source:IsA("Model") then
		-- Real art: the block body becomes an invisible physics proxy.
		root.Transparency = 1

		local shell = source:Clone()

		-- Normalise the costume to a consistent height. Imports arrive at whatever
		-- scale they were modelled at - the Pirate Captain is 21 studs tall as
		-- authored - and a guardian that dwarfs the containment walls reads as a
		-- bug. Measured from real part corners because GetBoundingBox is oriented
		-- to the pivot, and applied RELATIVE because ScaleTo is absolute.
		local height = LootModel.worldHeight(shell)
		if height and height > 0.01 then
			shell:ScaleTo(shell:GetScale() * (GameConfig.GUARDIAN_HEIGHT / height))
		end

		dressRig(model, root, shell)
		model:SetAttribute("HasShell", true)
	else
		-- No art for this zone yet: keep the readable placeholder body.
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
	end

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

	-- The snore has to stop the instant it wakes, not fade out over the chase.
	Audio.stopLoop("Snoring", guardian.root)

	-- Exactly one alert per chase: this function already returns early unless the
	-- guardian was Sleeping, so there is no second entry point to guard against.
	local zone = ZoneConfig.Zones[loot.zoneIndex]
	Audio.playAt(if zone and zone.isBoss then "BossAlert" else "PoliceWhistle", guardian.root)

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

--- Poses the imported costume. The models are static props with no skeleton, so
--- there is nothing to play an Animation on; instead the whole costume is
--- bobbed, leaned and rolled as one rigid piece.
---
--- That constraint is leaned into rather than hidden. A rigid body pumping up
--- and down while pitched forward and rocking side to side reads as a cartoon
--- sprint - closer to a Looney Tunes run cycle than to a jointed walk, and much
--- better than the stiff glide it would otherwise be.
local function animateShell(guardian: Guardian, now: number)
	local motor = guardian.shellMotor
	if not motor then
		return -- placeholder body, nothing to pose
	end

	local state = guardian.state

	if state == "Sleeping" then
		-- Slumped forward, breathing slowly.
		local breathe = math.sin(now * 1.5) * 0.07
		motor.C0 = CFrame.new(0, breathe, 0) * CFrame.Angles(math.rad(14), 0, 0)
		return
	end

	if state == "Waking" then
		-- Bolt upright and vibrate with outrage.
		local shake = math.sin(now * 46) * math.rad(7)
		motor.C0 = CFrame.new(0, 0.25, 0) * CFrame.Angles(math.rad(-8), shake, shake * 0.6)
		return
	end

	-- BOOKING IT.
	local t = now * RUN_CYCLE_SPEED
	-- abs(sin) gives two bounces per cycle: one per footfall.
	local bob = math.abs(math.sin(t)) * RUN_BOB
	local roll = math.sin(t * 0.5) * RUN_ROLL
	local yaw = math.sin(t * 0.5 + 1.1) * RUN_YAW
	motor.C0 = CFrame.new(0, bob, 0) * CFrame.Angles(RUN_LEAN, yaw, roll)
end

local function step()
	local now = os.clock()

	for _, guardian in guardians do
		animateShell(guardian, now)

		local state = guardian.state
		if state == "Sleeping" then
			continue -- idle guardians cost nothing beyond the pose above
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
			-- ONE hit cue, never both. A boss landing a hit plays the heavy
			-- reaction INSTEAD of the regular one, so they cannot stack.
			local zone = ZoneConfig.Zones[guardian.zoneIndex]
			Audio.playAt(if zone and zone.isBoss then "BossHit" else "NpcCatch", root)

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
		local motor = root:FindFirstChild("ShellMotor")
		guardian.shellMotor = if motor and motor:IsA("Weld") then motor else nil
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
