--!strict
--[[
	GuardianService
	EXACTLY ONE guardian per zone - twelve in the whole world. All four loot
	sockets in a zone share that single guardian.

	State loop (see CHASE CONTROL for the full machine):
	    SLEEPING (+ Zzz)
	      -> any item in the zone is successfully stolen
	    WAKING   (+ "!")
	      -> turns to the thief
	    CHASING  (the nearest carrier of this zone's loot; never a bystander)
	      -> A: thief crosses the red safe line  -> escape, guardian stops AT the
	            line, takes the next job or walks home
	      -> B: guardian catches the thief first -> ragdoll + launch, the guardian
	            CARRIES the item back to the exact socket it came from
	    RECOVERING / RETURNING LOOT
	      -> loot of this zone dropped anywhere on the danger side is fetched
	         and put back in its socket by the guardian, then it walks home

	Hard rules:
	  * No aggro of any kind before a successful steal. Walking through the zone,
	    standing on the loot, brushing the guardian - none of it wakes anything.
	  * One TARGET at a time. Several thieves may carry a zone's loot at once;
	    the guardian chases the nearest and switches only when another is
	    clearly closer (hysteresis), so it never jitters between two.
	  * The red safe line is a real AI boundary, not a distance check. The
	    guardian never crosses it, never paths through it, and cannot touch a
	    player who is already behind it. Safe zone always wins.
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)

local LootService = require(script.Parent.LootService)
local RagdollService = require(script.Parent.RagdollService)
-- DataService is a leaf module (config only), so requiring it here creates no
-- cycle. The chase needs the thief's real SpeedPower to decide how hard to run.
local DataService = require(script.Parent.DataService)

local GuardianService = {}

export type GuardianState = "Sleeping" | "Waking" | "Chasing" | "Recovering" | "ReturningLoot" | "Returning"

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
	--- Roblox's own walk cycle on a rigged costume; nil for props and custom
	--- rigs, which keep the procedural run in animateShell.
	walkTrack: AnimationTrack?,
	--- The stock idle, played while a rigged costume sleeps at its post.
	idleTrack: AnimationTrack?,
	--- Studs per second this costume covers at walk-cycle playback rate 1:
	--- the Animate script's reference speed scaled by the costume's height,
	--- so a forty-stud boss takes long strides instead of blurring its feet.
	walkSpeedPerRate: number,
	--- Catch distance, scaled to this guardian's physical size (see buildRig).
	catchRadius: number,
	--- The pace this job is judged at: the zone baseline (walking home, fetching
	--- a drop) or the per-thief chase speed (speedForChase). The catch-up boost
	--- is applied ON TOP of this by paceFor, never baked into it.
	baseSpeed: number,
	--- What WalkSpeed actually is right now. Eased toward the frame's target by
	--- driveSpeed, so acceleration and deceleration are curves, never snaps.
	currentSpeed: number,
	--- The instance welded to this guardian while it carries loot home.
	escortLootId: string?,
	--- Next time (os.clock) the chase re-evaluates who the best target is.
	nextScanAt: number,
	--- When the current recovery / escort began, for the give-up timeouts.
	jobStartedAt: number,
	-- Stuck detection. A guardian steering straight at its target will
	-- occasionally jam on a prop or a wall corner; these let it notice and
	-- sidestep rather than grinding in place until the player is gone.
	lastPosition: Vector3?,
	stuckFor: number,
	sidestepUntil: number,
	sidestepSign: number,
	--- Arrival detection: the closest this guardian has got to the goal of the
	--- current job, and when it last improved on it. See `arrived`.
	bestDistance: number,
	bestAt: number,
}

-- Tuning for the catch. Big and funny, but controlled: capped, single-shot, and
-- never enough to clear an 80-stud containment wall.
local WAKE_DELAY = GameConfig.GUARDIAN_WAKE_DELAY -- shocked beat before the chase; shared with the speed calibration

-- Run-cycle tuning. Deliberately over the top: this is the first chase a new
-- player ever sees and it should read as comedy, not as a walk.
local RUN_CYCLE_SPEED = 15 -- radians/sec; ~4.8 footfalls a second
local RUN_BOB = 0.85 -- studs of vertical pump per stride
local RUN_ROLL = math.rad(17) -- side-to-side rock
local RUN_YAW = math.rad(11) -- shoulder swing
local RUN_LEAN = math.rad(-24) -- pitched forward, chasing his own centre of mass

-- Walk-cycle pacing for RIGGED costumes (see prepareWalk). Roblox's Animate
-- script plays the walk at rate 1 for a standard ~5-stud character covering
-- 14.5 (R6) or 16 (R15) studs/s. A costume N times that tall takes strides N
-- times longer, so its rate is divided by N; the clamp keeps a jammed or
-- just-launched guardian from freezing mid-stride or blurring.
local WALK_REFERENCE_SPEED: { [string]: number } = { R6 = 14.5, R15 = 16 }
local STANDARD_RIG_HEIGHT = 5
local WALK_RATE_MIN = 0.45
local WALK_RATE_MAX = 2.2
local WALK_LEAN = math.rad(-7) -- a slight forward lean while pursuing
-- Tuned by measurement, not by feel: 110/72 threw the player 156 studs, which
-- launched them clean across the safe line and into the base plaza. 72 landed
-- around 80-90 studs. The catch is now deliberately three times that push, by
-- request - a caught thief is thrown a long way back down the lane, which is
-- the point of being caught.
--
-- The stun is no longer a flat timer from the launch. At this knockback the
-- arc alone can outlast a 1.6s timer, so a thief used to stand up mid-flight.
-- CATCH_STUN is now only the minimum airborne time, and CATCH_GROUND_STUN is
-- the two seconds they stay down AFTER touching the ground; immunity is
-- extended from the landing rather than fixed here.
local CATCH_KNOCKBACK = 216
local CATCH_LIFT = 62
local CATCH_STUN = 0.35
local CATCH_GROUND_STUN = 2
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

--- Tells the thief's OWN client that a guardian is on them, for the RUN!! screen
--- warning. An attribute on the Player rather than a remote: it is a boolean
--- that flips a handful of times a run, it replicates on its own, and a client
--- that joins mid-state reads the current value instead of missing an event.
--- Set true when a guardian takes a target and false the moment it lets go, so
--- it can never outlive the chase.
local function setChased(player: Player?, on: boolean)
	if player and player.Parent then
		player:SetAttribute("Chased", on)
	end
end

local function sleepPose(guardian: Guardian)
	local root = guardian.root
	if not root then
		return
	end
	-- CANCEL THE WALK ORDER BEFORE ANCHORING. Humanoid:Move is a standing
	-- instruction, not a per-frame one: whatever direction the guardian was
	-- last told to run in survives being anchored, and the instant it stands
	-- up again it resumes running that way - which after a walk home is
	-- AWAY from the zone. That is the "moves off backwards for half a second"
	-- at the start of a chase.
	local humanoid = guardian.humanoid
	if humanoid then
		humanoid:Move(Vector3.zero, false)
		humanoid.WalkToPoint = root.Position
		humanoid.Jump = false
	end
	-- Anchored while asleep: it cannot drift, cannot be shoved by a passing
	-- player, and costs no physics.
	root.Anchored = true
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
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
--- Some imports are static props - 28 anchored parts, no Humanoid, no Motor6D -
--- and the later zones are full R6/R15 characters with clothing, body colours
--- and body meshes. Neither kind can drive the rig itself, so rather than
--- rebuild the artist's model (which risks breaking it), the model is welded
--- on as a COSTUME over the working rig: physics and pathfinding stay with the
--- invisible root. A costume with a standard skeleton keeps its Motor6Ds and
--- walks with Roblox's own walk cycle; a prop is posed procedurally. Both live
--- in animateShell().
---
--- THE COSTUME KEEPS ITS OWN HUMANOID, SWITCHED OFF. Shirts, pants,
--- CharacterMeshes and BodyColors only render for parts that sit beside a
--- Humanoid under their canonical names, so destroying the import's Humanoid
--- (as this once did) put every character-shaped guardian on duty in its
--- underwear - the Egyptian boss was a bare tan block under a pharaoh's hat.
--- EvaluateStateMachine = false makes that Humanoid a pure renderer: no state
--- machine, no forces, no standing up, no dying. The costume lives in its own
--- nested Model, so the rig's Humanoid never sees those parts as limbs.
---
--- Belt and braces, every costume part goes in a collision group that collides
--- with nothing. A Humanoid re-asserting CanCollide on a torso then still
--- cannot push the guardian around or jam it in a doorway - which is exactly
--- the failure the old rename-and-destroy approach was guarding against.
local SHELL_COLLISION_GROUP = "GuardianShell"
--- The invisible physics body every guardian (zone boss or base animal)
--- walks on. It collides with the world so the guardian stays on the floor
--- and corners like a character, and NOT with players: a thief runs straight
--- through a guardian instead of being body-blocked by it. The catch is the
--- server's distance test (stepChase), never a physical contact.
local BODY_COLLISION_GROUP = "GuardianBody"
--- Every player character part goes here, so the two rules above can be
--- expressed as groups rather than per-part CanCollide games.
local PLAYER_COLLISION_GROUP = "Players"
local shellGroupReady = false

local function ensureShellCollisionGroup()
	if shellGroupReady then
		return
	end
	shellGroupReady = true
	-- Registering an existing group is harmless, but a place could in theory
	-- ship the name already; never let that stop the guardians being built.
	for _, name in { SHELL_COLLISION_GROUP, BODY_COLLISION_GROUP, PLAYER_COLLISION_GROUP } do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
	end
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(SHELL_COLLISION_GROUP, "Default", false)
		PhysicsService:CollisionGroupSetCollidable(SHELL_COLLISION_GROUP, SHELL_COLLISION_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(SHELL_COLLISION_GROUP, PLAYER_COLLISION_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(SHELL_COLLISION_GROUP, BODY_COLLISION_GROUP, false)
		-- Bodies: world yes, players no, each other no (two guardians never
		-- meet, but a Night reset can pass them through one another).
		PhysicsService:CollisionGroupSetCollidable(BODY_COLLISION_GROUP, "Default", true)
		PhysicsService:CollisionGroupSetCollidable(BODY_COLLISION_GROUP, PLAYER_COLLISION_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(BODY_COLLISION_GROUP, BODY_COLLISION_GROUP, false)
		-- Players keep colliding with everything they always did.
		PhysicsService:CollisionGroupSetCollidable(PLAYER_COLLISION_GROUP, "Default", true)
		PhysicsService:CollisionGroupSetCollidable(PLAYER_COLLISION_GROUP, PLAYER_COLLISION_GROUP, true)
	end)
end

--- Files every part of a character under the player group, now and as the
--- character adds parts (accessories, tools, the carry weld's loot is not a
--- child of the character so it is unaffected).
local function assignPlayerCollision(character: Model)
	ensureShellCollisionGroup()
	local function file(instance: Instance)
		if instance:IsA("BasePart") then
			instance.CollisionGroup = PLAYER_COLLISION_GROUP
		end
	end
	for _, descendant in character:GetDescendants() do
		file(descendant)
	end
	character.DescendantAdded:Connect(file)
end

GuardianService.assignPlayerCollision = assignPlayerCollision

--- The part names a standard skeleton must have for Roblox's own walk cycle to
--- find its joints. An animation's poses are matched by PART name, so a rig
--- with a Humanoid but home-made limbs (the Grandma: one "feet" part) would
--- load the animation and move nothing - it is treated as a prop instead.
local RIG_SIGNATURES: { [string]: { string } } = {
	R6 = { "HumanoidRootPart", "Torso", "Left Leg", "Right Leg", "Left Arm", "Right Arm" },
	R15 = { "HumanoidRootPart", "LowerTorso", "UpperTorso", "LeftUpperLeg", "RightUpperLeg" },
}

--- The costume's own standard skeleton, if it has one: its Humanoid and the
--- HumanoidRootPart its joint tree hangs from. Nil for props and custom rigs.
local function shellSkeleton(shell: Model): (Humanoid?, BasePart?)
	local humanoid = shell:FindFirstChildWhichIsA("Humanoid", true)
	if not humanoid then
		return nil, nil
	end
	local signature = RIG_SIGNATURES[humanoid.RigType.Name]
	if not signature then
		return nil, nil
	end
	local rootPart: BasePart? = nil
	for _, name in signature do
		local part = shell:FindFirstChild(name, true)
		if not part or not part:IsA("BasePart") then
			return nil, nil
		end
		if name == "HumanoidRootPart" then
			rootPart = part
		end
	end
	local motors = 0
	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("Motor6D") then
			motors += 1
		end
	end
	if motors < #signature - 1 then
		return nil, nil -- named like a rig, jointed like a prop (the Elf Guard)
	end
	return humanoid, rootPart
end

--- Every part a rig carries through its own joints, welds and rigid
--- constraints, starting from its root. Accessories hang off the head by an
--- AccessoryWeld, a held prop off the arm by a Motor6D: all of it counts.
local function partsCarriedBy(rootPart: BasePart, shell: Model): { [BasePart]: boolean }
	local links: { [BasePart]: { BasePart } } = {}
	local function link(a: Instance?, b: Instance?)
		if a and b and a ~= b and a:IsA("BasePart") and b:IsA("BasePart") then
			links[a] = links[a] or {}
			links[b] = links[b] or {}
			table.insert(links[a], b)
			table.insert(links[b], a)
		end
	end
	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("JointInstance") or descendant:IsA("WeldConstraint") then
			link((descendant :: any).Part0, (descendant :: any).Part1)
		elseif descendant:IsA("RigidConstraint") then
			local a0, a1 = descendant.Attachment0, descendant.Attachment1
			link(if a0 then a0.Parent else nil, if a1 then a1.Parent else nil)
		end
	end

	local carried: { [BasePart]: boolean } = { [rootPart] = true }
	local queue = { rootPart }
	while #queue > 0 do
		local part = table.remove(queue) :: BasePart
		for _, other in links[part] or {} do
			if not carried[other] then
				carried[other] = true
				table.insert(queue, other)
			end
		end
	end
	return carried
end

local function dressRig(model: Model, root: BasePart, shell: Model, shellRotation: CFrame?)
	ensureShellCollisionGroup()
	shell.Name = "Shell"
	-- `shellRotation` turns a costume authored facing some other axis (the
	-- base guardians: a cat modelled looking down +X) so it faces the root's
	-- forward. Identity for the zone bosses, which are all character rigs.
	shell:PivotTo(root.CFrame * (shellRotation or CFrame.identity))

	-- A character-shaped import brings its own Humanoid. It stays, as a
	-- renderer only: the clothing, body meshes and colours hang off it.
	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("Humanoid") then
			descendant.EvaluateStateMachine = false
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			descendant.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			descendant.BreakJointsOnDeath = false
			descendant.RequiresNeck = false
			descendant.AutoRotate = false
		end
	end

	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.CollisionGroup = SHELL_COLLISION_GROUP
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

	-- What gets welded to the pivot depends on whether the costume has a
	-- skeleton. A rigged character hangs off ONE weld at its HumanoidRootPart
	-- and its limbs stay on their Motor6Ds, which is what lets an Animation
	-- move them - welding every part (as this did for every costume) froze the
	-- rig solid. A prop, or a rig with non-standard joints, is welded part by
	-- part exactly as before. Anything a rig does NOT carry through its own
	-- joints - a stray decoration with no weld - is pinned to the pivot too, so
	-- nothing can fall off.
	local skeletonHumanoid, skeletonRoot = shellSkeleton(shell)
	local carried = if skeletonRoot then partsCarriedBy(skeletonRoot, shell) else nil

	for _, descendant in shell:GetDescendants() do
		if descendant:IsA("BasePart") and (not carried or descendant == skeletonRoot or not carried[descendant]) then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = pivot
			weld.Part1 = descendant
			weld.Parent = pivot
		end
	end

	if skeletonHumanoid then
		-- Created on the server, before the model replicates, so every client
		-- receives the tracks the server plays on it.
		if not skeletonHumanoid:FindFirstChildOfClass("Animator") then
			local animator = Instance.new("Animator")
			animator.Parent = skeletonHumanoid
		end
		shell:SetAttribute("Rigged", true)
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

--- A working guardian rig dressed in `source`: an invisible collidable
--- body and Humanoid with the costume welded on. Shared by the zone bosses
--- (below) and the base guardians (BaseGuardianService), so the two kinds
--- of guardian are built, sized and animated by exactly the same code.
---
--- `growth` is how much bigger than the zone-1 body the PHYSICS is (1 for a
--- base guardian); `shellRotation` turns a costume authored facing some
--- other axis so it faces forward (see dressRig).
local function buildRigFrom(source: Instance?, targetHeight: number, growth: number, name: string, shellRotation: CFrame?): Model
	-- The HumanoidRootPart doubles as the COLLIDABLE body. A rig whose parts all
	-- have CanCollide off never leaves Freefall, and a Humanoid in Freefall
	-- silently refuses to move.
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = BASE_ROOT_SIZE * growth
	root.Color = Color3.fromRGB(52, 78, 168)
	root.Material = Enum.Material.SmoothPlastic
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.CanCollide = true
	-- World yes, players no: see BODY_COLLISION_GROUP.
	ensureShellCollisionGroup()
	root.CollisionGroup = BODY_COLLISION_GROUP
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

		local motor = dressRig(model, root, shell, shellRotation)

		-- FEET ON THE FLOOR. The costume is pivoted onto the root, but an import's
		-- pivot sits wherever it was authored - the Elf Guard's is at its head -
		-- so every shell was sinking into the ground by up to five studs, and a
		-- costume several times taller than its collider would bury itself. The
		-- shell's lowest corner is measured and the difference to the collider's
		-- underside is baked into the motor's C1 (C0 is what animateShell drives
		-- every frame, so it cannot carry a constant). The pose animation then
		-- bobs a correctly grounded costume.
		local lowest = LootModel.worldExtents(shell)
		if lowest then
			local rootBottom = root.Position.Y - root.Size.Y / 2
			local lift = rootBottom - lowest.Y
			motor.C1 = CFrame.new(0, -lift, 0)
		end
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
	return model
end

GuardianService.buildRigFrom = buildRigFrom

local function buildRig(zoneIndex: number): (Model, number)
	local zone = ZoneConfig.Zones[zoneIndex]
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local source = if assets and assets:FindFirstChild("Guardians")
		then assets.Guardians:FindFirstChild(`Zone{string.format("%02d", zoneIndex)}_{zone.guardian}`)
		else nil

	-- Guardians grow zone by zone so a later zone reads as dangerous on sight.
	--
	-- TWO SIZES, ON PURPOSE. `targetHeight` is what the costume is scaled to -
	-- the table in GameConfig, climbing to forty studs at the Airport. `growth`
	-- is what the PHYSICS body follows, and it stops at a cap: the invisible
	-- collider, the hip height, the step height and the catch radius all come
	-- from this, so a late-zone boss is a giant to look at and a guardian-sized
	-- thing to chase you - it corners, fits the lane and catches exactly like
	-- the early zones do. A collider that grew with the costume jammed on
	-- doorways it dwarfed and caught players from half a zone away.
	local targetHeight = GameConfig.guardianHeightFor(zoneIndex)
	local growth = GameConfig.guardianPhysicsGrowthFor(zoneIndex)
	return buildRigFrom(source, targetHeight, growth, zone.guardian), growth
end

--- A guardian's WalkSpeed, derived from the SAME recommendation the zone sign
--- shows the player and through the SAME conversion the player's own Speed uses.
---
--- The handicap is applied to the STAT and the result is then converted. Doing
--- it the other way round - converting first, then shaving the WalkSpeed - is
--- what made the recommendations meaningless, because WalkSpeed is logarithmic
--- in Speed and a couple of percent off it is a quarter off the stat. See
--- ZoneConfig.GUARDIAN_GATE_MARGIN.
--- Baseline: exactly GUARDIAN_GATE_MARGIN studs/s slower than a player who meets
--- the zone's recommendation, through the SAME conversion that player's own
--- Speed goes through. That is what makes the number on the sign a threshold.
---
--- CALIBRATED, NOT RETUNED. The player curve changed (GameConfig.MOVEMENT)
--- and the guardians were left exactly as they felt: each keeps the ratio to
--- an at-gate player it had under the old curve, with the head start a faster
--- player now gets during WAKE_DELAY folded back in over this zone's actual
--- run to the red line. See GameConfig.guardianGateWalkSpeed.
local function guardianSpeed(zoneIndex: number): number
	local zone = ZoneConfig.Zones[zoneIndex]
	local run = MapConfig.zoneCenterZ(zoneIndex)
	return GameConfig.guardianGateWalkSpeed(zone.recommendedSpeed, ZoneConfig.GUARDIAN_GATE_MARGIN, run)
end

GuardianService.speedForZone = guardianSpeed

--- The speed a guardian ACTUALLY runs at against a particular thief.
---
--- Baseline is the zone's own recommendation (above). On top of that it reacts
--- to how far SHORT of that recommendation the thief is: at or above it, the
--- guardian is fractionally slower and the thief escapes; below it, the guardian
--- runs them down harder the bigger the shortfall.
---
--- This is what makes the number on the zone sign mean something. The sign-space
--- fix alone left a 127K thief only 1.5 studs/s slower than a 170K guardian,
--- which over 894 studs of lane is not enough to overturn a head start - the
--- thief still escaped. Both halves are needed.
--- THE CARRY CORRECTION, and why the recommendations were lying.
---
--- `guardianSpeed` calibrates a zone's guardian against a player who is AT the
--- recommendation and running FREE - at zone 9 that is 210.29 studs/s for the
--- player against 209.79 for the guardian, the intended half-a-stud escape.
--- But a chased player is never running free: they are carrying, and the size
--- penalty (RarityConfig.Sizes.movePenalty, 4% to 25%) comes off THEIR speed
--- and nothing came off the guardian's. Measured at the Secret Lab:
---
---     power   free      carrying Huge   carrying Giant   carrying Colossal
---     700M    +0.50       -20.5           -37.4            -52.1
---     1B      +5.50       -16.0           -33.3            -48.3
---     3B     +20.89        -2.2           -20.6            -36.8
---
--- That is the whole "1B, 2B and even 3B still lose" report: the sign on the
--- Scientist says 700M, and a 3B thief carrying a Titan is thirty studs/s
--- slower than it. It was never the Scientist's number - the number is right
--- and the comparison was wrong, which is why every zone shares the fault and
--- why the fix belongs in this shared formula rather than in one zone's data.
---
--- So the guardian carries the same handicap the thief does. At the gate the
--- margin is the designed half-stud again for EVERY size, and above the gate
--- the thief pulls away as the sign promises:
---
---     700M + Colossal  ->  157.7 thief vs 157.3 guardian  (+0.4, narrow)
---     1B   + Colossal  ->  161.5 thief vs 157.3 guardian  (+4.2, escapes)
---     3B   + Colossal  ->  173.0 thief vs 157.3 guardian  (+15.7, clear)
---
--- Below the gate the deficit multiplier still runs them down, so a thief who
--- has not earned the zone is caught exactly as before.
function GuardianService.speedForChase(zoneIndex: number, thiefPower: number, carryPenalty: number?): number
	local zone = ZoneConfig.Zones[zoneIndex]
	local recommended = math.max(zone.recommendedSpeed, GameConfig.STARTING_SPEED_POWER)
	local base = guardianSpeed(zoneIndex)

	-- 0 when the thief meets or beats the recommendation, approaching 1 the
	-- further under it they are.
	local deficit = math.clamp(1 - (math.max(thiefPower, 0) / recommended), 0, 1)
	local chase = base * (1 + ZoneConfig.GUARDIAN_DEFICIT_CATCHUP * deficit)

	-- The thief's own load, applied to the chaser. Clamped so a future size
	-- with an extreme penalty can never stall a guardian outright.
	local penalty = math.clamp(carryPenalty or 0, 0, 0.5)
	return chase * (1 - penalty)
end

--- The movement penalty a thief is paying for what they are carrying. Read
--- off the loot instance the chase is already holding, from the SAME table
--- CarryService applies (RarityConfig.Sizes.movePenalty), so the two can
--- never disagree about what a size costs - and without this service having
--- to require CarryService back.
function GuardianService.carryPenaltyOf(loot: LootService.LootInstance?): number
	if not loot then
		return 0
	end
	local size = RarityConfig.SizeById[loot.size]
	return if size and size.movePenalty then size.movePenalty else 0
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
--
-- THE STATE MACHINE. One guardian per zone, and every state it can be in:
--
--   Sleeping       at its post. Nothing wakes it but a steal, or loot from
--                  its zone being dropped somewhere it can walk to.
--   Waking         the shocked beat after a steal (WAKE_DELAY), facing the thief.
--   Chasing        after ONE thief at a time - the nearest carrier of this
--                  zone's loot - re-evaluated every SCAN_INTERVAL. The pace
--                  rises with distance and settles back when close (paceFor).
--   Recovering     walking to a dropped item of its own zone to pick it up.
--   ReturningLoot  carrying an item (caught or recovered) back to the EXACT
--                  socket it was stolen from, then putting it back.
--   Returning      walking home to sleep again.
--
-- Every job ends through nextJob(): another carrier first, then a drop, then
-- home. Nothing here holds a stale reference: the target is re-validated from
-- LootService every frame (is that item still Carried, by that player, who
-- still has a character), so a death, a drop, a placement or a disconnect
-- ends the chase on the next frame without any event ordering to get right.

--- Studs beyond the catch radius at which the pace is back to base. Above it
--- the catch-up boost ramps in over FAR_BAND studs.
local NEAR_BAND = 10
local FAR_BAND = 70
--- Full catch-up boost, as a fraction of the base pace. It only ever brings a
--- guardian CLOSER; inside the near band it is exactly the base pace again, so
--- whether a thief at the zone's recommendation escapes is still decided by
--- the sign-space tuning in speedForChase, not by this.
local CATCHUP_BOOST = 0.35
--- Exponential approach rate of WalkSpeed toward its target, per second.
--- 2.4 closes ~90% of a gap in one second: visible, never a snap.
local SPEED_EASE = 2.4
--- How often a chasing guardian asks whether someone else should be its target.
local SCAN_INTERVAL = 0.4
--- A new carrier has to be this fraction of the current target's distance (and
--- at least SWITCH_MIN_GAIN studs closer) before the guardian switches. The
--- hysteresis is what stops two thieves at similar range ping-ponging it.
local SWITCH_MARGIN = 0.75
local SWITCH_MIN_GAIN = 12
--- Distance to a dropped item at which the guardian picks it up, on top of
--- its catch radius, and distance to the socket at which it puts loot back.
local PICKUP_REACH = 4
--- How close the guardian has to get to its own post before it lies down.
--- `sleepPose` snaps it exactly onto the post either way, so this is only
--- about where the walk stops looking like a walk.
local HOME_REACH = 6
local ESCORT_REACH = 7
--- A recovery or escort that has not finished in this long (jammed on
--- geometry, item somewhere unreachable) falls back to the instant return.
local JOB_TIMEOUT = 60

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
	guardian.bestDistance = math.huge
	guardian.bestAt = os.clock()
end

-- ==========================================================
-- ARRIVAL
-- ==========================================================
--
-- Arrival tuning. A guardian is "there" when it is inside the reach, OR when it
-- has stopped getting closer while already near.

--- Studs of improvement that count as making progress.
local ARRIVE_PROGRESS = 0.75
--- No progress for this long means this is as close as it is going to get.
local ARRIVE_STALL_SECONDS = 1.1
--- The stall test only applies within this multiple of the reach, so a
--- guardian halfway across the zone is never counted as having arrived.
local ARRIVE_STALL_REACH = 2.5

--- Has this guardian arrived at the goal it is steering to?
---
--- A PLAIN DISTANCE TEST IS NOT ENOUGH, and this is the bug it hid: a humanoid
--- running at speed toward a point it cannot physically reach - because its own
--- body, the item welded in front of it, the socket's own pedestal or a prop is
--- in the way - does not stop. It ORBITS, at whatever radius its momentum
--- allows, until the sixty-second job timeout gives up. A zone guardian doing
--- that is a zone with NO guardian in it, and it ignores fresh steals the whole
--- time, which is exactly how it was found: circling the socket while the thief
--- helped themselves to the rest of the zone.
---
--- So arrival is also "I have stopped getting closer, and I am already near".
--- Stopping early costs nothing at either call site: `sleepPose` snaps the
--- guardian onto its post, and `finishEscort` puts the item back in its own
--- socket wherever the guardian happens to be standing. The only thing an
--- early finish gives up is the orbit.
local function arrived(guardian: Guardian, distance: number, reach: number, now: number): boolean
	if distance <= reach then
		return true
	end
	if distance < guardian.bestDistance - ARRIVE_PROGRESS then
		guardian.bestDistance = distance
		guardian.bestAt = now
		return false
	end
	return distance <= reach * ARRIVE_STALL_REACH and now - guardian.bestAt >= ARRIVE_STALL_SECONDS
end

-- ----------------------------------------------------------
-- PACE
-- ----------------------------------------------------------

--- The WalkSpeed this frame wants: base pace inside the near band, rising
--- smoothly with distance to base x (1 + CATCHUP_BOOST) at the far band.
local function paceFor(guardian: Guardian, distance: number): number
	local near = guardian.catchRadius + NEAR_BAND
	local alpha = math.clamp((distance - near) / FAR_BAND, 0, 1)
	return guardian.baseSpeed * (1 + CATCHUP_BOOST * alpha)
end

--- Eases the humanoid toward `target`. THE ONLY WRITER OF WalkSpeed during a
--- job, so speed changes are curves. A rooted guardian (trap) is left at zero;
--- the root's expiry hands control back here.
local function driveSpeed(guardian: Guardian, humanoid: Humanoid, target: number, dt: number)
	if humanoid:GetAttribute("Rooted") then
		return
	end
	local alpha = 1 - math.exp(-SPEED_EASE * dt)
	local eased = guardian.currentSpeed + (target - guardian.currentSpeed) * alpha
	if math.abs(eased - target) < 0.05 then
		eased = target
	end
	guardian.currentSpeed = eased
	humanoid.WalkSpeed = eased
end

-- ----------------------------------------------------------
-- FINDING WORK
-- ----------------------------------------------------------

type Carrier = { player: Player, loot: LootService.LootInstance, root: BasePart, distance: number }

local function flatDistance(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

--- The loot's carrier as a chase candidate, or nil if it is not one: not
--- carried, carrier gone, no character, or already across the red line.
local function asCarrier(guardian: Guardian, loot: LootService.LootInstance): Carrier?
	local player = loot.carrier
	local root = guardian.root
	if loot.state ~= "Carried" or not player or not player.Parent or not root then
		return nil
	end
	local character = player.Character
	local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not targetRoot or not targetRoot:IsA("BasePart") then
		return nil
	end
	if isBehindSafeLine(targetRoot.Position) then
		return nil
	end
	return { player = player, loot = loot, root = targetRoot, distance = flatDistance(root.Position, targetRoot.Position) }
end

--- The nearest player currently carrying this zone's loot on the danger side,
--- optionally ignoring one player (the current target, when looking for a
--- better one).
local function nearestCarrier(guardian: Guardian, except: Player?): Carrier?
	local best: Carrier? = nil
	for _, loot in LootService.instancesInZone(guardian.zoneIndex) do
		if loot.state == "Carried" and loot.carrier ~= except then
			local candidate = asCarrier(guardian, loot)
			if candidate and (not best or candidate.distance < best.distance) then
				best = candidate
			end
		end
	end
	return best
end

--- Whether a dropped item is somewhere this zone's guardian may walk to: on
--- the danger side of the line, with a model to pick up.
function GuardianService.canRecover(loot: LootService.LootInstance): boolean
	local guardian = guardians[loot.zoneIndex]
	local model = loot.model
	if not guardian or not guardian.root or not model or not model.PrimaryPart then
		return false
	end
	return model.PrimaryPart.Position.Z > safeLineZ + SAFE_LINE_MARGIN + 1
end

local function nearestDrop(guardian: Guardian): LootService.LootInstance?
	local root = guardian.root
	if not root then
		return nil
	end
	local best: LootService.LootInstance? = nil
	local bestDistance = math.huge
	for _, loot in LootService.instancesInZone(guardian.zoneIndex) do
		if loot.state == "Dropped" and GuardianService.canRecover(loot) then
			local model = loot.model :: Model
			local distance = flatDistance(root.Position, (model.PrimaryPart :: BasePart).Position)
			if distance < bestDistance then
				best, bestDistance = loot, distance
			end
		end
	end
	return best
end

-- ----------------------------------------------------------
-- TRANSITIONS
-- ----------------------------------------------------------

--- Off the post: unanchored and simulated by the server.
local function standUp(guardian: Guardian)
	local root = guardian.root
	if not root then
		return
	end
	root.Anchored = false
	-- From a standstill, every time. An unanchored assembly keeps whatever the
	-- engine last gave it, and a leftover velocity is a visible lurch in the
	-- wrong direction on the first frame of the chase.
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	local humanoid = guardian.humanoid
	if humanoid then
		humanoid:Move(Vector3.zero, false)
	end
	-- PIN SIMULATION TO THE SERVER. Roblox hands network ownership of a loose
	-- unanchored assembly to the nearest player - which during a chase is always
	-- the thief. Their client then simulates the thing hunting them, and every
	-- server correction on top of that reads as a stutter or a snap backwards.
	-- Ownership can only be set while the part is unanchored, hence the position
	-- here, and it is pcall'd because a part that has already been reclaimed by
	-- the engine throws rather than returning.
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	Audio.stopLoop("Snoring", root)
end

local function releaseTarget(guardian: Guardian)
	setChased(guardian.target, false)
	guardian.target = nil
	guardian.lootId = nil
	guardian.wakeAt = nil
end

--- Takes a carrier as THE target. From sleep it is the shocked Waking beat
--- with the alert; mid-job it is an immediate switch with no second alert.
local function beginChase(guardian: Guardian, carrier: Carrier, fromSleep: boolean)
	local root = guardian.root
	if not root then
		return
	end
	if guardian.target ~= carrier.player then
		setChased(guardian.target, false)
	end
	guardian.target = carrier.player
	guardian.lootId = carrier.loot.id
	resetSteering(guardian)
	setChased(carrier.player, true)

	-- Speed is set PER CHASE, not once at spawn, because it depends on how far
	-- under the zone's recommendation this particular thief is. Read from the
	-- server's own profile, never from anything the client can influence.
	local profile = DataService.get(carrier.player)
	local power = if profile then profile.SpeedPower else GameConfig.STARTING_SPEED_POWER
	guardian.baseSpeed = GuardianService.speedForChase(
		guardian.zoneIndex,
		power,
		GuardianService.carryPenaltyOf(carrier.loot)
	)
	guardian.nextScanAt = os.clock() + SCAN_INTERVAL

	if fromSleep then
		guardian.state = "Waking"
		guardian.wakeAt = os.clock() + WAKE_DELAY
		-- From a standstill: the first strides are an acceleration, not a launch.
		guardian.currentSpeed = guardian.baseSpeed * 0.55
		if guardian.humanoid then
			guardian.humanoid.WalkSpeed = guardian.currentSpeed
		end
		-- Exactly one alert per wake. A switch mid-chase is silent.
		local zone = ZoneConfig.Zones[guardian.zoneIndex]
		Audio.playAt(if zone and zone.isBoss then "BossAlert" else "PoliceWhistle", root)
		-- Stand up and turn to face the thief.
		local from = root.Position
		local look = Vector3.new(carrier.root.Position.X, from.Y, carrier.root.Position.Z)
		root.CFrame = CFrame.lookAt(from, look)
	else
		guardian.state = "Chasing"
		guardian.wakeAt = nil
	end
	publishState(guardian)
end

--- Walks to a dropped item of this zone.
local function beginRecovery(guardian: Guardian, loot: LootService.LootInstance)
	releaseTarget(guardian)
	guardian.state = "Recovering"
	guardian.lootId = loot.id
	guardian.baseSpeed = guardianSpeed(guardian.zoneIndex)
	-- A fetch is a walk, never a sprint left over from the last chase.
	guardian.currentSpeed = math.min(guardian.currentSpeed, guardian.baseSpeed)
	guardian.jobStartedAt = os.clock()
	resetSteering(guardian)
	publishState(guardian)
end

--- Welds an item to the guardian, hoisted over its head, at the same
--- compressed presentation scale a player carry uses.
local function attachEscort(guardian: Guardian, loot: LootService.LootInstance): boolean
	local model = loot.model
	local root = guardian.root
	local rig = guardian.model
	if not model or not model.PrimaryPart or not root or not rig then
		return false
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
	local prompt = LootService.promptOf(loot)
	if prompt then
		prompt.Enabled = false
	end

	local shown = RarityConfig.carryVisualScale(loot.visualScale)
	local factor = if loot.visualScale > 0 then shown / loot.visualScale else 1
	if math.abs(factor - 1) > 0.001 then
		model:ScaleTo(model:GetScale() * factor)
		loot.carryScale = factor
	end

	-- IN THE WORLD, WELDED - not inside the rig. A Humanoid reads the parts of
	-- the model it lives in as its own body, and a stolen throne parked inside
	-- a guardian collapses it into FallingDown exactly the way it collapsed
	-- players (see the note in CarryService.attach). The escort weld below is
	-- what carries it.
	local map = workspace:FindFirstChild("Map") or workspace
	local holder = map:FindFirstChild("CarriedLoot")
	if not holder then
		holder = Instance.new("Folder")
		holder.Name = "CarriedLoot"
		holder.Parent = map
	end
	model.Parent = holder
	model:PivotTo(root.CFrame)
	local height = tonumber(rig:GetAttribute("Height")) or root.Size.Y
	local minCorner = select(1, LootModel.visibleExtents(model))
	local rootBottom = root.Position.Y - root.Size.Y / 2
	local lift = if minCorner then (rootBottom + height + 0.5) - minCorner.Y else height
	model:PivotTo(root.CFrame * CFrame.new(0, lift, 0))

	local weld = Instance.new("WeldConstraint")
	weld.Name = "EscortWeld"
	weld.Part0 = root
	weld.Part1 = model.PrimaryPart
	weld.Parent = model.PrimaryPart
	return true
end

--- Carries an Escorted item back to its socket.
local function beginEscort(guardian: Guardian, loot: LootService.LootInstance): boolean
	if loot.state ~= "Escorted" or not attachEscort(guardian, loot) then
		return false
	end
	releaseTarget(guardian)
	guardian.state = "ReturningLoot"
	guardian.escortLootId = loot.id
	guardian.baseSpeed = guardianSpeed(guardian.zoneIndex)
	guardian.jobStartedAt = os.clock()
	resetSteering(guardian)
	publishState(guardian)
	return true
end

--- Puts the carried item back. The SAME instance goes into the SAME socket
--- (LootService.returnToOrigin rebuilds it there from its own rolled values);
--- if the socket was refilled meanwhile the instance retires.
local function finishEscort(guardian: Guardian)
	local lootId = guardian.escortLootId
	guardian.escortLootId = nil
	local loot = if lootId then LootService.get(lootId) else nil
	if not loot then
		return
	end
	local model = loot.model
	local weld = model and model.PrimaryPart and model.PrimaryPart:FindFirstChild("EscortWeld")
	if weld then
		weld:Destroy()
	end
	loot.carryScale = nil
	if loot.state == "Escorted" then
		LootService.returnToOrigin(loot, 0)
	end
end

local function goHome(guardian: Guardian)
	-- Whatever ended the chase - catch, escape, a dropped item, the thief
	-- leaving - the warning on their screen ends here with it.
	releaseTarget(guardian)
	guardian.state = "Returning"
	guardian.baseSpeed = guardianSpeed(guardian.zoneIndex)
	resetSteering(guardian)
	publishState(guardian)
	-- No MoveTo. `step` steers home every frame, same as it chases.
end

--- What to do once a job ends: another carrier of this zone's loot, then a
--- dropped item to fetch, then home.
local function nextJob(guardian: Guardian)
	local carrier = nearestCarrier(guardian, nil)
	if carrier then
		beginChase(guardian, carrier, false)
		return
	end
	local drop = nearestDrop(guardian)
	if drop then
		beginRecovery(guardian, drop)
		return
	end
	goHome(guardian)
end

--- A steal (or a grab of a dropped item) in this zone.
---   Sleeping                      -> the Waking beat, then the chase
---   Returning / Recovering        -> straight into the chase (a live thief
---                                    outranks a drop; the drop is fetched after)
---   Waking / Chasing / ReturningLoot -> nothing now; the scan or nextJob picks
---                                    the new carrier up when it is the right one
function GuardianService.engage(loot: LootService.LootInstance, _thief: Player)
	local guardian = guardians[loot.zoneIndex]
	if not guardian or not guardian.humanoid or not guardian.root then
		return
	end
	local carrier = asCarrier(guardian, loot)
	if not carrier then
		return
	end
	local state = guardian.state
	if state == "Sleeping" then
		standUp(guardian)
		beginChase(guardian, carrier, true)
	elseif state == "Returning" or state == "Recovering" then
		beginChase(guardian, carrier, false)
	end
end

--- Kept under its old name for callers and tests.
GuardianService.wake = GuardianService.engage

--- Loot of this zone was dropped. A guardian with nothing better to do goes
--- and gets it; a busy one finds it through nextJob when its job ends.
function GuardianService.noticeDrop(loot: LootService.LootInstance)
	local guardian = guardians[loot.zoneIndex]
	if not guardian or not guardian.root or not GuardianService.canRecover(loot) then
		return
	end
	if guardian.state == "Sleeping" then
		standUp(guardian)
		beginRecovery(guardian, loot)
	elseif guardian.state == "Returning" then
		beginRecovery(guardian, loot)
	end
end

function GuardianService.stopChaseFor(loot: LootService.LootInstance)
	local guardian = guardians[loot.zoneIndex]
	if not guardian or guardian.lootId ~= loot.id then
		return
	end
	if guardian.state == "Waking" or guardian.state == "Chasing" then
		releaseTarget(guardian)
		nextJob(guardian)
	end
end

--- Night: every chase ends this instant and every guardian is back asleep on
--- its post - not walking home, HOME - with every thief's warning cleared.
--- Loot a guardian was carrying goes straight back to its socket.
function GuardianService.resetAll()
	for _, guardian in guardians do
		if guardian.state == "Sleeping" then
			continue
		end
		releaseTarget(guardian)
		if guardian.escortLootId then
			finishEscort(guardian)
		end
		resetSteering(guardian)
		if guardian.humanoid then
			guardian.humanoid:Move(Vector3.zero, false)
		end
		enterSleep(guardian)
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
		groundStun = CATCH_GROUND_STUN,
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

--- Loads Roblox's own walk cycle onto a rigged costume. Returns the track and
--- the studs per second that one unit of playback rate represents for a
--- costume of this height. Nil for props and custom rigs - those keep the
--- procedural run - and nil, loudly, if the animation cannot be loaded.
---
--- Called after the model is in workspace: LoadAnimation refuses a rig that is
--- not yet a descendant of the DataModel.
local function loadTrack(animator: Animator, id: string, priority: Enum.AnimationPriority, label: string): AnimationTrack?
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not ok or not track then
		warn(`[GuardianService] could not load the {label}: {track}`)
		return nil
	end
	track.Priority = priority
	track.Looped = true
	return track
end

local function prepareWalk(model: Model): (AnimationTrack?, AnimationTrack?, number)
	local shell = model:FindFirstChild("Shell")
	if not shell or shell:GetAttribute("Rigged") ~= true then
		return nil, nil, 1
	end
	local humanoid = shell:FindFirstChildWhichIsA("Humanoid", true)
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if not humanoid or not animator then
		return nil, nil, 1
	end

	local rigType = humanoid.RigType.Name
	local walkId = GameConfig.GUARDIAN_WALK_ANIMATIONS[rigType]
	if not walkId then
		return nil, nil, 1
	end

	local walk = loadTrack(animator, walkId, Enum.AnimationPriority.Movement, `{rigType} walk cycle for {model.Name}`)
	if not walk then
		return nil, nil, 1
	end
	local idleId = GameConfig.GUARDIAN_IDLE_ANIMATIONS[rigType]
	local idle = if idleId then loadTrack(animator, idleId, Enum.AnimationPriority.Idle, `{rigType} idle for {model.Name}`) else nil

	local height = tonumber(model:GetAttribute("Height")) or STANDARD_RIG_HEIGHT
	local reference = WALK_REFERENCE_SPEED[rigType] or 16
	return walk, idle, reference * math.max(height / STANDARD_RIG_HEIGHT, 0.5)
end

--- Shared with BaseGuardianService: the Dog is an R6 rig and walks with the
--- same Roblox cycle the rigged bosses use.
GuardianService.prepareWalk = prepareWalk
GuardianService.WALK_RATE_MIN = WALK_RATE_MIN
GuardianService.WALK_RATE_MAX = WALK_RATE_MAX

--- Poses the imported costume.
---
--- A RIGGED costume (a Humanoid over a standard R6/R15 skeleton, see dressRig)
--- walks with Roblox's own walk cycle, paced to the ground the guardian is
--- actually covering, with a slight forward lean. A prop with no skeleton, or
--- a rig with non-standard joints, has nothing an Animation can drive, so the
--- whole costume is bobbed, leaned and rolled as one rigid piece instead.
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
	local track = guardian.walkTrack
	local idle = guardian.idleTrack

	if state == "Sleeping" then
		if track and track.IsPlaying then
			track:Stop(0.25)
		end
		-- A rigged costume dozes with the stock idle under the slump, so it
		-- shifts its weight instead of standing frozen at its post.
		if idle and not idle.IsPlaying then
			idle:Play(0.4)
		end
		-- Slumped forward, breathing slowly.
		local breathe = math.sin(now * 1.5) * 0.07
		motor.C0 = CFrame.new(0, breathe, 0) * CFrame.Angles(math.rad(14), 0, 0)
		return
	end

	if idle and idle.IsPlaying then
		idle:Stop(0.15)
	end

	if state == "Waking" then
		if track and track.IsPlaying then
			track:Stop(0.1)
		end
		-- Bolt upright and vibrate with outrage.
		local shake = math.sin(now * 46) * math.rad(7)
		motor.C0 = CFrame.new(0, 0.25, 0) * CFrame.Angles(math.rad(-8), shake, shake * 0.6)
		return
	end

	if track then
		-- WALKING, the Roblox way. Paced from real velocity rather than from
		-- WalkSpeed, so a guardian jammed on a corner or easing into a turn
		-- strides at the pace it is actually moving.
		if not track.IsPlaying then
			track:Play(0.2)
		end
		local root = guardian.root
		local velocity = if root then root.AssemblyLinearVelocity else Vector3.zero
		local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		track:AdjustSpeed(math.clamp(speed / guardian.walkSpeedPerRate, WALK_RATE_MIN, WALK_RATE_MAX))
		motor.C0 = CFrame.Angles(WALK_LEAN, 0, 0)
		return
	end

	-- BOOKING IT, rigidly.
	local t = now * RUN_CYCLE_SPEED
	-- abs(sin) gives two bounces per cycle: one per footfall.
	local bob = math.abs(math.sin(t)) * RUN_BOB
	local roll = math.sin(t * 0.5) * RUN_ROLL
	local yaw = math.sin(t * 0.5 + 1.1) * RUN_YAW
	motor.C0 = CFrame.new(0, bob, 0) * CFrame.Angles(RUN_LEAN, yaw, roll)
end

--- One frame of the chase proper (Waking / Chasing). Returns after any
--- transition it makes; the caller moves on to the next guardian.
local function stepChase(guardian: Guardian, humanoid: Humanoid, root: BasePart, now: number, dt: number)
	local target = guardian.target
	local lootId = guardian.lootId
	local loot = if lootId then LootService.get(lootId) else nil

	-- The chase is only valid while THIS thief still carries THIS item.
	if not target or not target.Parent or not loot or loot.state ~= "Carried" or loot.carrier ~= target then
		releaseTarget(guardian)
		nextJob(guardian)
		return
	end

	local character = target.Character
	local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not targetRoot or not targetRoot:IsA("BasePart") then
		releaseTarget(guardian)
		nextJob(guardian)
		return
	end

	-- ESCAPE: crossing the red line. THE LINE IS THE ONLY THING THAT ENDS A
	-- CHASE IN THE THIEF'S FAVOUR. Distance from home, time elapsed and
	-- proximity to the base are all deliberately NOT conditions here: once a
	-- guardian is awake it pursues until the thief is across, is caught, or no
	-- longer has the item.
	if isBehindSafeLine(targetRoot.Position) then
		onEscape(loot, target)
		releaseTarget(guardian)
		nextJob(guardian)
		return
	end

	if guardian.state == "Waking" then
		if now < (guardian.wakeAt or 0) then
			-- HOLD THE BEAT, ACTIVELY. Returning here used to leave the last
			-- Move order in force for the whole 0.55s, so the guardian spent
			-- its shocked moment sliding wherever it had last been sent. It
			-- now stands still and turns to face the thief, so the first
			-- stride of the chase is already pointed the right way.
			humanoid:Move(Vector3.zero, false)
			local facing = Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
			if (facing - root.Position).Magnitude > 0.1 then
				root.CFrame = root.CFrame:Lerp(CFrame.lookAt(root.Position, facing), math.min(1, dt * 12))
			end
			return
		end
		guardian.state = "Chasing"
		guardian.wakeAt = nil
		publishState(guardian)
	end

	local distance = flatDistance(root.Position, targetRoot.Position)

	-- WHO TO CHASE. Every SCAN_INTERVAL: if another carrier of this zone's loot
	-- is clearly closer, switch to them. Clearly, with hysteresis - a thief
	-- has to be both a quarter closer and a dozen studs closer - so two thieves
	-- at similar range cannot ping-pong the guardian between them.
	if now >= guardian.nextScanAt then
		guardian.nextScanAt = now + SCAN_INTERVAL
		local other = nearestCarrier(guardian, target)
		if other and other.distance < distance * SWITCH_MARGIN and distance - other.distance >= SWITCH_MIN_GAIN then
			beginChase(guardian, other, false)
			return
		end
	end

	-- CATCH. The radius scales with the guardian, so a fifteen-stud boss is
	-- not required to bury its own model in the player before it registers.
	local reach = (root.Position - targetRoot.Position).Magnitude
	if reach <= guardian.catchRadius and not GuardianService.isStunned(target) then
		-- ONE hit cue, never two: this guardian's own catch sound (each of
		-- the twelve has one, see AudioConfig.GuardianHits), falling back
		-- to the boss / regular reaction if a zone has none.
		Audio.playAt(AudioConfig.guardianHitCue(guardian.zoneIndex), root)

		ragdollAndLaunch(target, root.Position)
		-- The catch handler takes the item off the thief and hands it over
		-- (loot.state becomes Escorted); the guardian then carries it home.
		onCatch(loot)
		releaseTarget(guardian)
		if not beginEscort(guardian, loot) then
			-- Nothing to carry (no model, or the handler sent it home itself).
			nextJob(guardian)
		end
		return
	end

	-- The pace: rising with the gap, settling as it closes. Then steered fresh
	-- at the thief's CURRENT position - no goal point, no arrival stop.
	driveSpeed(guardian, humanoid, paceFor(guardian, distance), dt)
	steer(guardian, humanoid, root, targetRoot.Position, now, dt)
end

--- Walking to a dropped item.
local function stepRecovery(guardian: Guardian, humanoid: Humanoid, root: BasePart, now: number, dt: number)
	local loot = if guardian.lootId then LootService.get(guardian.lootId) else nil
	local model = if loot then loot.model else nil
	if not loot or loot.state ~= "Dropped" or not model or not model.PrimaryPart then
		-- Grabbed by a player (engage will have switched us), returned by the
		-- fallback, or retired: whichever it was, find the next job.
		guardian.lootId = nil
		nextJob(guardian)
		return
	end

	if now - guardian.jobStartedAt > JOB_TIMEOUT then
		-- Jammed, or the item is somewhere it cannot reach. The old instant
		-- return is the floor under this feature: nothing is ever orphaned.
		guardian.lootId = nil
		LootService.returnToOrigin(loot)
		nextJob(guardian)
		return
	end

	local position = (model.PrimaryPart :: BasePart).Position
	local distance = flatDistance(root.Position, position)
	-- Same arrival test as the walk home and the escort: an item wedged
	-- against a wall or a prop is one a guardian can circle forever otherwise.
	if arrived(guardian, distance, guardian.catchRadius + PICKUP_REACH, now) then
		guardian.lootId = nil
		LootService.setState(loot, "Escorted")
		if not beginEscort(guardian, loot) then
			LootService.returnToOrigin(loot)
			nextJob(guardian)
		end
		return
	end

	driveSpeed(guardian, humanoid, guardian.baseSpeed, dt)
	steer(guardian, humanoid, root, position, now, dt)
end

--- Carrying an item back to its socket.
local function stepEscort(guardian: Guardian, humanoid: Humanoid, root: BasePart, now: number, dt: number)
	local loot = if guardian.escortLootId then LootService.get(guardian.escortLootId) else nil
	if not loot or loot.state ~= "Escorted" then
		guardian.escortLootId = nil
		nextJob(guardian)
		return
	end

	local socket = LootService.getSocket(loot.zoneIndex, loot.socketIndex)
	if not socket then
		finishEscort(guardian)
		nextJob(guardian)
		return
	end

	local distance = flatDistance(root.Position, socket.part.Position)
	if arrived(guardian, distance, ESCORT_REACH, now) or now - guardian.jobStartedAt > JOB_TIMEOUT then
		finishEscort(guardian)
		nextJob(guardian)
		return
	end

	driveSpeed(guardian, humanoid, guardian.baseSpeed, dt)
	steer(guardian, humanoid, root, socket.part.Position, now, dt)
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
			-- Something to do on the way home outranks going home.
			if now >= guardian.nextScanAt then
				guardian.nextScanAt = now + SCAN_INTERVAL
				local carrier = nearestCarrier(guardian, nil)
				if carrier then
					beginChase(guardian, carrier, false)
					continue
				end
				local drop = nearestDrop(guardian)
				if drop then
					beginRecovery(guardian, drop)
					continue
				end
			end
			driveSpeed(guardian, humanoid, guardian.baseSpeed, dt)
			local distance = steer(guardian, humanoid, root, guardian.home.Position, now, dt)
			if arrived(guardian, distance, HOME_REACH, now) then
				enterSleep(guardian)
			end
			continue
		end

		if state == "Recovering" then
			stepRecovery(guardian, humanoid, root, now, dt)
			continue
		end

		if state == "ReturningLoot" then
			stepEscort(guardian, humanoid, root, now, dt)
			continue
		end

		stepChase(guardian, humanoid, root, now, dt)
	end
end

-- ==========================================================
-- START
-- ==========================================================

function GuardianService.start()
	local map = workspace:WaitForChild("Map", 20)
	local zonesFolder = map:WaitForChild("Zones", 10)

	-- Every character into the player collision group, so guardians (and
	-- their costumes) are walk-through for players while still standing on
	-- the world. See BODY_COLLISION_GROUP.
	local function onPlayer(player: Player)
		if player.Character then
			assignPlayerCollision(player.Character)
		end
		player.CharacterAdded:Connect(assignPlayerCollision)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)

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
			baseSpeed = guardianSpeed(zoneIndex),
			currentSpeed = guardianSpeed(zoneIndex),
			nextScanAt = 0,
			jobStartedAt = 0,
			stuckFor = 0,
			sidestepUntil = 0,
			sidestepSign = 1,
			bestDistance = math.huge,
			bestAt = 0,
			walkSpeedPerRate = 1,
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
		-- Roblox's walk and idle cycles, on the costumes that have a skeleton.
		local walkTrack, idleTrack, walkSpeedPerRate = prepareWalk(model)
		guardian.walkTrack = walkTrack
		guardian.idleTrack = idleTrack
		guardian.walkSpeedPerRate = walkSpeedPerRate
		guardians[zoneIndex] = guardian

		model:SetAttribute("ZoneIndex", zoneIndex)
		enterSleep(guardian)
	end

	-- Wake ONLY on a real steal (or a grab of a dropped item - the guardian
	-- may have gone back to sleep meanwhile, and a free walk-off with the loot
	-- was the hole that left). Nothing about proximity or presence aggros.
	LootService.onStateChanged(function(loot, _previous, next)
		if next == "Carried" and loot.carrier then
			GuardianService.engage(loot, loot.carrier)
		elseif next == "Dropped" then
			GuardianService.noticeDrop(loot)
		elseif next == "Returning" or next == "Placed" or next == "Spawned" then
			GuardianService.stopChaseFor(loot)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		for _, guardian in guardians do
			if guardian.target == player then
				releaseTarget(guardian)
				nextJob(guardian)
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

	humanoid.WalkSpeed = 0
	humanoid:SetAttribute("Rooted", true)
	if guardian.model then
		guardian.model:SetAttribute("Rooted", true)
	end

	task.delay(seconds, function()
		if not humanoid.Parent then
			return
		end
		-- Back to whatever pace the job had reached; driveSpeed eases from
		-- here again on the next frame.
		humanoid.WalkSpeed = guardian.currentSpeed
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

--- Everything a test wants to know about one guardian, this frame.
function GuardianService.inspect(zoneIndex: number): { [string]: any }?
	local guardian = guardians[zoneIndex]
	if not guardian then
		return nil
	end
	local root = guardian.root
	local target = guardian.target
	local character = target and target.Character
	local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
	local distance = if root and targetRoot and targetRoot:IsA("BasePart")
		then flatDistance(root.Position, targetRoot.Position)
		else nil
	local velocity = if root then root.AssemblyLinearVelocity else Vector3.zero
	return {
		state = guardian.state,
		target = if target then target.Name else nil,
		lootId = guardian.lootId,
		escortLootId = guardian.escortLootId,
		baseSpeed = guardian.baseSpeed,
		currentSpeed = guardian.currentSpeed,
		walkSpeed = if guardian.humanoid then guardian.humanoid.WalkSpeed else nil,
		groundSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude,
		distance = distance,
		position = if root then root.Position else nil,
		rooted = guardian.humanoid and guardian.humanoid:GetAttribute("Rooted") == true,
	}
end

return GuardianService
