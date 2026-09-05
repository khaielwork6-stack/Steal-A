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
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local Audio = require(ReplicatedStorage.Shared.Util.Audio)

local LootService = require(script.Parent.LootService)
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
	wakeAt: number?,
	shellMotor: Weld?, -- drives the imported costume's pose; nil when unskinned
	--- Catch distance, scaled to this guardian's physical size (see buildRig).
	catchRadius: number,
	-- Stuck detection. A guardian steering straight at its target will
	-- occasionally jam on a prop or a wall corner; these let it notice and
	-- sidestep rather than grinding in place until the player is gone.
	lastPosition: Vector3?,
	stuckFor: number,
	sidestepUntil: number,
	sidestepSign: number,
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

-- ==========================================================
-- STUCK RECOVERY
-- ==========================================================
--
-- Steering straight at a target is fast and never backtracks, but it will jam on
-- a wall corner or a decoration. These let a guardian notice it has stopped
-- making ground and sidestep out of it, rather than grinding in place.

--- Fraction of its own top speed a guardian must be making to count as moving.
local STUCK_SPEED_FRACTION = 0.25
--- Seconds of that before a sidestep is triggered.
local STUCK_TRIGGER = 0.3
--- Seconds a sidestep lasts once triggered.
local SIDESTEP_DURATION = 0.45
--- How hard the sidestep steers, relative to the straight-line direction.
local SIDESTEP_STRENGTH = 1.1

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

--- Body proportions at GameConfig.GUARDIAN_HEIGHT. Everything scales off these,
--- so a bigger zone guardian gets a bigger physics body too rather than a huge
--- costume balanced on a small invisible box.
local BASE_ROOT_SIZE = Vector3.new(2.6, 4, 1.6)

local function buildRig(zoneIndex: number): (Model, number)
	local zone = ZoneConfig.Zones[zoneIndex]
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local source = if assets and assets:FindFirstChild("Guardians")
		then assets.Guardians:FindFirstChild(`Zone{string.format("%02d", zoneIndex)}_{zone.guardian}`)
		else nil

	-- Guardians grow zone by zone so a later zone reads as dangerous on sight.
	local targetHeight = GameConfig.guardianHeightFor(zoneIndex)
	local growth = targetHeight / GameConfig.GUARDIAN_HEIGHT

	-- The HumanoidRootPart doubles as the COLLIDABLE body. A rig whose parts all
	-- have CanCollide off never leaves Freefall, and a Humanoid in Freefall
	-- silently refuses to move.
	local model = Instance.new("Model")
	model.Name = zone.guardian

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = BASE_ROOT_SIZE * growth
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
	-- Step height scales with the body, so a big guardian steps over the same
	-- kerbs a small one does instead of being stopped by geometry it dwarfs.
	humanoid.Parent = model

	model.PrimaryPart = root

	if source and source:IsA("Model") then
		-- Real art: the block body becomes an invisible physics proxy.
		root.Transparency = 1

		local shell = source:Clone()

		-- Normalise the costume to this zone's height. Imports arrive at whatever
		-- scale they were modelled at - the Pirate Captain is 21 studs tall as
		-- authored - so a guardian that dwarfs the containment walls reads as a
		-- bug. Measured from real part corners because GetBoundingBox is oriented
		-- to the pivot, and applied RELATIVE because ScaleTo is absolute.
		local height = LootModel.worldHeight(shell)
		if height and height > 0.01 then
			shell:ScaleTo(shell:GetScale() * (targetHeight / height))
		end

		dressRig(model, root, shell)
		model:SetAttribute("HasShell", true)
	else
		-- No art for this zone yet: keep the readable placeholder body.
		local head = Instance.new("Part")
		head.Name = "Head"
		head.Size = Vector3.new(1.7, 1.7, 1.7) * growth
		head.Color = Color3.fromRGB(240, 204, 160)
		head.Material = Enum.Material.SmoothPlastic
		head.TopSurface = Enum.SurfaceType.Smooth
		head.BottomSurface = Enum.SurfaceType.Smooth
		head.CanCollide = false
		head.CFrame = root.CFrame * CFrame.new(0, 2.85 * growth, 0)
		head.Parent = model

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = head
		weld.Parent = root
	end

	model:SetAttribute("Height", targetHeight)
	return model, growth
end

local function guardianSpeed(zoneIndex: number): number
	local zone = ZoneConfig.Zones[zoneIndex]
	local matched = GameConfig.walkSpeedFromPower(math.max(zone.recommendedSpeed, GameConfig.STARTING_SPEED_POWER))
	return matched * ZoneConfig.GUARDIAN_SPEED_FACTOR
end

-- ==========================================================
-- STEERING
-- ==========================================================
--
-- THIS IS THE FIX FOR THE RUBBER-BANDING. Read before changing it.
--
-- The chase used to be `Humanoid:MoveTo(target)` re-issued every 0.4 seconds.
-- Three separate failures came out of that, and they compounded:
--
--   1. MoveTo walks to a FIXED POINT. For up to 0.4s the guardian was running at
--      where the player USED to be, so when the player ran past it, the guardian
--      visibly turned around and went backwards to a stale point before the next
--      repath turned it around again. That is the "pulled backward for half a
--      second" the chase was reported as doing.
--   2. MoveTo STOPS on arrival. Reaching a stale point parked the guardian dead
--      still until the next repath tick - the lost momentum.
--   3. Every repath restarted the walk, so at high speeds the guardian spent a
--      meaningful share of the chase accelerating from nothing.
--
-- `Humanoid:Move(direction)` has none of that: it sets a direction, there is no
-- goal to arrive at, nothing stops, and calling it every frame means the
-- direction is never stale. The guardian now runs a true pursuit curve.

--- Points a guardian at a world position for THIS frame.
---
--- Returns the horizontal distance to the goal. Never uses MoveTo, and never
--- pushes through the red line - the DIRECTION is clamped, so the guardian
--- slides along the boundary instead of being shoved back off it.
local function steer(guardian: Guardian, humanoid: Humanoid, root: BasePart, goal: Vector3, now: number, dt: number): number
	local from = root.Position
	local flat = Vector3.new(goal.X - from.X, 0, goal.Z - from.Z)
	local distance = flat.Magnitude

	if distance < 0.4 then
		humanoid:Move(Vector3.zero, false)
		return distance
	end

	local direction = flat / distance

	-- Sidestep out of whatever we are jammed on, if we are jammed on something.
	if now < guardian.sidestepUntil then
		local lateral = Vector3.new(-direction.Z, 0, direction.X) * (guardian.sidestepSign * SIDESTEP_STRENGTH)
		local blended = direction + lateral
		if blended.Magnitude > 0.001 then
			direction = blended.Unit
		end
	end

	-- The red line is an absolute boundary. Refusing to STEER across it is what
	-- keeps the guardian on the danger side; the old code let it walk over and
	-- then teleported it back with its velocity zeroed, which is a second, very
	-- literal source of the backward yank.
	if from.Z <= safeLineZ + SAFE_LINE_MARGIN and direction.Z < 0 then
		direction = Vector3.new(direction.X, 0, 0)
		direction = if direction.Magnitude > 0.001 then direction.Unit else Vector3.zero
	end

	humanoid:Move(direction, false)

	-- Stuck bookkeeping: compare ground actually covered against ground we should
	-- have covered at this guardian's own speed.
	local previous = guardian.lastPosition
	guardian.lastPosition = from
	if previous and dt > 0 then
		local moved = (Vector3.new(from.X, 0, from.Z) - Vector3.new(previous.X, 0, previous.Z)).Magnitude
		local expected = humanoid.WalkSpeed * dt
		if expected > 0 and moved < expected * STUCK_SPEED_FRACTION and direction.Magnitude > 0.001 then
			guardian.stuckFor += dt
			if guardian.stuckFor >= STUCK_TRIGGER and now >= guardian.sidestepUntil then
				guardian.stuckFor = 0
				guardian.sidestepSign = -guardian.sidestepSign
				guardian.sidestepUntil = now + SIDESTEP_DURATION
				-- A hop clears the kerbs and props a pure sidestep cannot.
				humanoid.Jump = true
			end
		else
			guardian.stuckFor = 0
		end
	end

	return distance
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

--- Clears the per-chase steering state. Anything that starts or ends a chase
--- must call this, or a sidestep from the last one leaks into the next.
local function resetSteering(guardian: Guardian)
	guardian.lastPosition = nil
	guardian.stuckFor = 0
	guardian.sidestepUntil = 0
end

local function goHome(guardian: Guardian)
	guardian.state = "Returning"
	guardian.target = nil
	guardian.lootId = nil
	resetSteering(guardian)
	publishState(guardian)
	-- No MoveTo. `step` steers home every frame, same as it chases.
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
	guardian.wakeAt = os.clock() + WAKE_DELAY
	resetSteering(guardian)

	-- The snore has to stop the instant it wakes, not fade out over the chase.
	Audio.stopLoop("Snoring", guardian.root)

	-- Exactly one alert per chase: this function already returns early unless the
	-- guardian was Sleeping, so there is no second entry point to guard against.
	local zone = ZoneConfig.Zones[loot.zoneIndex]
	Audio.playAt(if zone and zone.isBoss then "BossAlert" else "PoliceWhistle", guardian.root)

	-- Stand up and turn to face the thief.
	guardian.root.Anchored = false

	-- PIN SIMULATION TO THE SERVER. Roblox hands network ownership of a loose
	-- unanchored assembly to the nearest player - which during a chase is always
	-- the thief. Their client then simulates the thing hunting them, and every
	-- server correction on top of that reads as a stutter or a snap backwards.
	-- Ownership can only be set while the part is unanchored, hence the position
	-- here, and it is pcall'd because a part that has already been reclaimed by
	-- the engine throws rather than returning.
	pcall(function()
		(guardian.root :: BasePart):SetNetworkOwner(nil)
	end)

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

local function step(dt: number)
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

		-- Absolute boundary, and deliberately a LAST RESORT. `steer` refuses to
		-- push across the line at all, so this only ever fires if physics threw
		-- the guardian over it. It corrects the position and cancels only the
		-- component of velocity still carrying it inward - the old version ran
		-- every frame within six studs of the line and zeroed the ENTIRE
		-- velocity, which is exactly the backward yank the chase was accused of.
		if root.Position.Z < safeLineZ then
			root.CFrame = CFrame.new(clampToDangerSide(root.Position)) * (root.CFrame - root.Position)
			local velocity = root.AssemblyLinearVelocity
			if velocity.Z < 0 then
				root.AssemblyLinearVelocity = Vector3.new(velocity.X, velocity.Y, 0)
			end
		end

		if state == "Returning" then
			local distance = steer(guardian, humanoid, root, guardian.home.Position, now, dt)
			if distance < 6 then
				enterSleep(guardian)
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

		-- ESCAPE: crossing the red line. THE LINE IS THE ONLY THING THAT ENDS A
		-- CHASE. This used to also end on `BaseService.isInOwnSafeZone`, which is
		-- an intermediate checkpoint - getting near your own plot. Distance from
		-- home, time elapsed and proximity to the base are all deliberately NOT
		-- conditions here: once a guardian is awake it pursues until the thief is
		-- across, is caught, or no longer has the item.
		if isBehindSafeLine(targetRoot.Position) then
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

		-- CATCH. The radius scales with the guardian, so a fifteen-stud boss is
		-- not required to bury its own model in the player before it registers.
		local distance = (root.Position - targetRoot.Position).Magnitude
		if distance <= guardian.catchRadius and not GuardianService.isStunned(target) then
			-- ONE hit cue, never both. A boss landing a hit plays the heavy
			-- reaction INSTEAD of the regular one, so they cannot stack.
			local zone = ZoneConfig.Zones[guardian.zoneIndex]
			Audio.playAt(if zone and zone.isBoss then "BossHit" else "NpcCatch", root)

			ragdollAndLaunch(target, root.Position)
			onCatch(loot)
			goHome(guardian)
			continue
		end

		-- Steered fresh every frame at the thief's CURRENT position. No goal
		-- point, no arrival stop, nothing to go stale.
		steer(guardian, humanoid, root, targetRoot.Position, now, dt)
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

		local model, growth = buildRig(zoneIndex)
		local humanoid = model:FindFirstChildWhichIsA("Humanoid")
		local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not root:IsA("BasePart") then
			warn(`[GuardianService] malformed rig for {zoneDef.id}`)
			model:Destroy()
			continue
		end

		local guardian: Guardian = {
			zoneIndex = zoneIndex,
			-- Derived from the body rather than a fixed 2.2: a later zone's
			-- guardian is physically larger and a constant offset would bury it.
			home = post.CFrame * CFrame.new(0, (root :: BasePart).Size.Y / 2 + 0.2, 0),
			state = "Sleeping",
			catchRadius = ZoneConfig.GUARDIAN_CATCH_RADIUS * growth,
			stuckFor = 0,
			sidestepUntil = 0,
			sidestepSign = 1,
		}

		humanoid.WalkSpeed = guardianSpeed(zoneIndex)
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		-- A seated or platform-standing guardian silently stops responding to
		-- Move; neither state is ever wanted here.
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)

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

	-- Heartbeat, not a timer: the guardian is steered fresh every single frame.
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
