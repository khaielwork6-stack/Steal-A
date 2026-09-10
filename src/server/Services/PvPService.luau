--!strict
--[[
	PvPService
	The bat and the three-trap system (GDD section 12).

	PvP here is NOT about damage. Nobody loses health; the entire outcome is
	positional disruption plus forcing a carried item to drop. That is what makes
	steals contested without turning the game into a shooter.

	Everything is server-decided. The client may play its swing animation
	immediately for responsiveness, but it never picks the victim, never decides
	a hit landed, and never supplies a target.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Debris = game:GetService("Debris")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local PvPConfig = require(ReplicatedStorage.Shared.Config.PvPConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local GuardianService = require(script.Parent.GuardianService)
local MonetizationService = require(script.Parent.MonetizationService)
local RagdollService = require(script.Parent.RagdollService)
local StateService = require(script.Parent.StateService)

local PvPService = {}

local batLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.BatSwingRequest)
local trapLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.TrapPlaceRequest)
local weaponLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.WeaponRequest)

local lastSwing: { [Player]: number } = {}

type Trap = {
	owner: Player,
	part: BasePart,
	placedAt: number,
	armedForOwnerAt: number,
	triggered: boolean,
}

local traps: { Trap } = {}
local trapFolder: Folder

local function notify(player: Player, kind: string, message: string)
	StateService.notify(player, kind, message)
end

local function rootPartOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- ==========================================================
-- WEAPONS: WHICH ONE IS IN THE HAND
-- ==========================================================
--
-- The Bat is everyone's. The Slap is a Game Pass. The profile remembers
-- which of the two the player chose (EquippedWeapon); the server re-checks
-- the pass before it ever hands the Slap out, so a save that says "Slap"
-- on an account that does not own it simply gets the Bat.

function PvPService.ownsSlap(player: Player): boolean
	return MonetizationService.ownsPassCached(player, MonetizationConfig.SlapPass.gamePassId)
end

--- The weapon this player should be carrying: their choice, if they own it.
function PvPService.equippedWeapon(player: Player): string
	local profile = DataService.get(player)
	local wanted = if profile then profile.EquippedWeapon else PvPConfig.DEFAULT_WEAPON
	local def = PvPConfig.Weapons[wanted]
	if not def then
		return PvPConfig.DEFAULT_WEAPON
	end
	if def.gamePass and not PvPService.ownsSlap(player) then
		return PvPConfig.DEFAULT_WEAPON
	end
	return wanted
end

--- The weapon definition for the Tool actually in the attacker's hand. The
--- request names nothing; a Slap swing is a Slap swing because the Slap is
--- what they are holding.
local function heldWeapon(player: Player): PvPConfig.WeaponDef?
	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	return if tool then PvPConfig.Weapons[tool.Name] else nil
end

-- ==========================================================
-- THE SWING (Bat and Slap)
-- ==========================================================

--- A comic-book smack at the point of impact, for the Slap only: a burst of
--- sparks and a big yellow SLAP! that pops and fades. Built from parts and
--- the sparkle texture the game already uses; gone in under a second.
local function slapPop(at: Vector3)
	local host = Instance.new("Part")
	host.Name = "SlapPop"
	host.Size = Vector3.new(1, 1, 1)
	host.Transparency = 1
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.CFrame = CFrame.new(at + Vector3.new(0, 2.5, 0))
	host.Parent = workspace

	local attachment = Instance.new("Attachment")
	attachment.Parent = host
	local burst = Instance.new("ParticleEmitter")
	burst.Texture = "rbxassetid://241594419"
	burst.Color = ColorSequence.new(Color3.fromRGB(255, 226, 80), Color3.fromRGB(255, 120, 80))
	burst.LightEmission = 0.8
	burst.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	burst.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	burst.Lifetime = NumberRange.new(0.4, 0.7)
	burst.Speed = NumberRange.new(14, 22)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Rate = 0
	burst.Parent = attachment
	burst:Emit(26)

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(7, 3)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 160
	gui.Adornee = host
	gui.Parent = host
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = Color3.fromRGB(255, 226, 80)
	text.TextStrokeTransparency = 0
	text.TextStrokeColor3 = Color3.fromRGB(120, 30, 20)
	text.Rotation = -12
	text.Text = "SLAP!"
	text.Parent = gui

	Debris:AddItem(host, 0.9)
end

--- Server-side hit resolution. The attacker's own facing decides the arc, and
--- the server picks at most ONE victim from a spatial query. `weapon` is the
--- one in their hand (heldWeapon), never one the request named.
local function resolveSwing(attacker: Player, weapon: PvPConfig.WeaponDef)
	local attackerRoot = rootPartOf(attacker)
	if not attackerRoot then
		return
	end

	local origin = attackerRoot.Position
	local forward = attackerRoot.CFrame.LookVector

	local best: Player? = nil
	local bestDistance = math.huge

	for _, victim in Players:GetPlayers() do
		if victim == attacker or not isAlive(victim) then
			continue
		end

		local victimRoot = rootPartOf(victim)
		if not victimRoot then
			continue
		end

		local offset = victimRoot.Position - origin
		local distance = offset.Magnitude
		if distance > weapon.range then
			continue
		end

		-- Behind the attacker does not count.
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > 0.1 then
			local angle = math.deg(math.acos(math.clamp(flat.Unit:Dot(Vector3.new(forward.X, 0, forward.Z).Unit), -1, 1)))
			if angle > weapon.arcDegrees / 2 then
				continue
			end
		end

		-- Safe zones win: neither party can be hit inside one.
		if BaseService.isSafePosition(victimRoot.Position) then
			continue
		end

		if RagdollService.isImmune(victim) then
			continue
		end

		if distance < bestDistance then
			best, bestDistance = victim, distance
		end
	end

	if not best then
		return
	end

	local victim = best :: Player

	-- Positional, on the victim, so both players and any bystander hear the
	-- connect from the right place. Only ever on a hit that actually resolved.
	local victimCharacter = victim.Character
	local victimRoot = victimCharacter and victimCharacter:FindFirstChild("HumanoidRootPart")
	Audio.playAt(weapon.hitCue, victimRoot)
	if weapon.name == "Slap" and victimRoot and victimRoot:IsA("BasePart") then
		slapPop(victimRoot.Position)
	end

	-- Drop BEFORE the launch so the item lands where the victim was standing.
	local carried = CarryService.getCarried(victim)
	if carried then
		CarryService.forceDrop(carried)
		local profile = DataService.get(attacker)
		if profile then
			profile.Lifetime.PvPSteals += 1
		end
		notify(attacker, "success", `You knocked the {carried.name} loose!`)
	end
	-- No toast for a plain hit. The connect sound, the swing, the launch and
	-- the ragdoll are the feedback; a "Hit!" card on top was noise.

	RagdollService.launch(victim, origin, {
		knockback = weapon.knockback,
		lift = weapon.lift,
		stun = weapon.stun,
		immunity = weapon.stun + PvPConfig.POST_RAGDOLL_IMMUNITY,
	})
end

--- Returns whether the swing was accepted, plus the reason when it was not.
--- The reason is surfaced so refusals are testable and explainable rather than
--- silently doing nothing.
function PvPService.trySwing(player: Player): (boolean, string?)
	if not batLimiter:consume(player) then
		return false, "rate limited"
	end
	if not isAlive(player) then
		return false, "not alive"
	end

	-- The weapon is whatever is in the hand. No Tool, no swing - a client
	-- firing the remote with nothing equipped is asking for a hit it has no
	-- weapon to make.
	local weapon = heldWeapon(player)
	if not weapon then
		return false, "no weapon held"
	end

	local now = os.clock()
	if now - (lastSwing[player] or 0) < weapon.cooldown then
		return false, "cooldown"
	end

	local root = rootPartOf(player)
	if not root then
		return false, "no character"
	end

	-- An attacker standing in a safe zone cannot swing out of it.
	if BaseService.isSafePosition(root.Position) then
		notify(player, "error", "No fighting in the safe zone.")
		return false, "safe zone"
	end

	lastSwing[player] = now
	-- Resolved when the weapon ARRIVES, not when the button is pressed. The
	-- client's wind-up runs for the same delay, so the connect, the sound and
	-- the launch all happen on the frame the swing visually lands. The cooldown
	-- was stamped above, so a second press inside the delay is still refused.
	task.delay(weapon.strikeDelay, function()
		if player.Parent and isAlive(player) then
			resolveSwing(player, weapon)
		end
	end)
	return true
end

-- ==========================================================
-- ART
-- ==========================================================
--
-- The bat and the trap were supplied as two MeshParts named "Bat" and "Trap",
-- left floating in the workspace to be found. At start they are ADOPTED into
-- ServerStorage.GameAssets.PvP - out of the world, where a player cannot walk
-- into them and they cannot be stolen or swung - and cloned from there. If
-- either is missing the old primitive build is used, so the tools still exist.

local ART_FOLDER = "PvP"

local function artFolder(): Folder
	local assets = ServerStorage:FindFirstChild("GameAssets")
	if not assets then
		assets = Instance.new("Folder")
		assets.Name = "GameAssets"
		assets.Parent = ServerStorage
	end
	local folder = assets:FindFirstChild(ART_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = ART_FOLDER
		folder.Parent = assets
	end
	return folder :: Folder
end

--- Moves a supplied mesh out of the workspace and into the art folder, once.
local function adoptArt(name: string): MeshPart?
	local folder = artFolder()
	local held = folder:FindFirstChild(name)
	if held and held:IsA("MeshPart") then
		return held
	end
	local loose = workspace:FindFirstChild(name)
	if loose and loose:IsA("MeshPart") then
		loose.Anchored = true
		loose.Parent = folder
		return loose
	end
	return nil
end

local function batArt(): MeshPart?
	return adoptArt("Bat")
end

local function trapArt(): MeshPart?
	return adoptArt("Trap")
end

-- ==========================================================
-- TRAPS
-- ==========================================================

--- Footprint of the visible trap. The trigger radius stays what it is - that is
--- gameplay - and the art is scaled to sit inside it, so what you see is what
--- you must not step on.
local TRAP_VISUAL_WIDTH = 4.2

local function buildTrapPart(position: Vector3, owner: Player): BasePart
	-- THE HITBOX. Invisible, unqueryable, exactly the trigger radius. `stepTraps`
	-- measures against this part's position, so the art can be any shape at
	-- all without changing where a trap fires.
	local part = Instance.new("Part")
	part.Name = "Trap"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.6, PvPConfig.TRAP_TRIGGER_RADIUS * 2, PvPConfig.TRAP_TRIGGER_RADIUS * 2)
	part.CFrame = CFrame.new(position + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part:SetAttribute("OwnerUserId", owner.UserId)

	-- THE ART. The supplied trap mesh, scaled to the footprint and stood flat on
	-- the floor. Non-colliding and unqueryable, so its jaws can never snag a
	-- player or a raycast; it is a picture of the trap, the cylinder is the
	-- trap. Falls back to a flat neon disc if the mesh is not available.
	local art = trapArt()
	if art then
		local visual = art:Clone()
		visual.Name = "Visual"
		visual.Anchored = true
		visual.CanCollide = false
		visual.CanQuery = false
		visual.CanTouch = false
		visual.CastShadow = true
		local factor = TRAP_VISUAL_WIDTH / math.max(art.Size.X, art.Size.Z)
		visual.Size = art.Size * factor
		visual.CFrame = CFrame.new(position + Vector3.new(0, visual.Size.Y / 2, 0))
		visual.Parent = part
	else
		local disc = Instance.new("Part")
		disc.Name = "Visual"
		disc.Shape = Enum.PartType.Cylinder
		disc.Size = Vector3.new(0.3, TRAP_VISUAL_WIDTH, TRAP_VISUAL_WIDTH)
		disc.CFrame = CFrame.new(position + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
		disc.Anchored = true
		disc.CanCollide = false
		disc.CanQuery = false
		disc.CanTouch = false
		disc.Color = Color3.fromRGB(255, 96, 96)
		disc.Material = Enum.Material.Neon
		disc.Parent = part
	end

	-- A faint ring on the floor marking the real trigger radius, so the danger
	-- zone is honest: the art is smaller than the radius that fires.
	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.1, PvPConfig.TRAP_TRIGGER_RADIUS * 2, PvPConfig.TRAP_TRIGGER_RADIUS * 2)
	ring.CFrame = CFrame.new(position + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Color = Color3.fromRGB(255, 96, 96)
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.72
	ring.Parent = part

	part.Parent = trapFolder
	return part
end

--- Hands the whole clip back once the refill has elapsed. The ONE writer of
--- that transition, called by everything that reads the count, so there is no
--- state where the clock has passed and the traps have not come back.
---
--- Returns true when it actually refilled, so the caller can push.
local function refillTraps(profile: DataService.Profile): boolean
	if profile.TrapCount > 0 then
		return false
	end
	local due = tonumber(profile.TrapReadyAt) or 0
	if due <= 0 or os.time() < due then
		return false
	end
	profile.TrapCount = PvPConfig.TRAP_CAPACITY
	profile.TrapReadyAt = 0
	return true
end

--- Seconds until this player's traps come back, 0 when they have some. The ONE
--- reader of the stamp: the placement gate, the HUD and the tests all come
--- through here, so there is no second interpretation of the clock.
function PvPService.trapCooldownRemaining(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	refillTraps(profile)
	-- A player holding traps is not waiting for anything, whatever the stamp
	-- happens to say.
	if profile.TrapCount > 0 then
		return 0
	end
	return math.max(0, (tonumber(profile.TrapReadyAt) or 0) - os.time())
end

--- True when the player may place a trap right now: simply, that they have one.
function PvPService.canPlaceTrap(player: Player): boolean
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	refillTraps(profile)
	return profile.TrapCount > 0
end

function PvPService.tryPlaceTrap(player: Player, requested: Vector3?)
	if not trapLimiter:consume(player) then
		return
	end

	local profile = DataService.get(player)
	if not profile then
		return
	end
	-- THE CLIP IS THE GATE. Holding one is the whole condition; the refill
	-- clock only matters once the clip is empty, and `trapCooldownRemaining`
	-- hands the traps back itself the moment it has elapsed.
	local waiting = PvPService.trapCooldownRemaining(player)
	if profile.TrapCount <= 0 then
		notify(player, "error", `Out of traps - back in {math.ceil(waiting)}s`)
		return
	end
	if not isAlive(player) then
		return
	end

	local root = rootPartOf(player)
	if not root then
		return
	end

	-- The client asks for a spot; the server decides the real one. An out-of-
	-- range request is clamped rather than rejected, so lag never eats a trap.
	local target = requested or (root.Position + root.CFrame.LookVector * 8)
	local offset = target - root.Position
	if offset.Magnitude > PvPConfig.TRAP_PLACE_RADIUS then
		target = root.Position + offset.Unit * PvPConfig.TRAP_PLACE_RADIUS
	end

	-- Find the ground and check it is not a wall or a steep face.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, trapFolder, workspace:FindFirstChild("Guardians") }
	local hit = workspace:Raycast(target + Vector3.new(0, 12, 0), Vector3.new(0, -60, 0), params)
	if not hit then
		notify(player, "error", "You cannot place a trap there.")
		return
	end

	local slope = math.deg(math.acos(math.clamp(hit.Normal:Dot(Vector3.yAxis), -1, 1)))
	if slope > PvPConfig.TRAP_MAX_SLOPE then
		notify(player, "error", "That ground is too steep.")
		return
	end

	if BaseService.isSafePosition(hit.Position) then
		notify(player, "error", "You cannot trap a safe zone.")
		return
	end

	local active = 0
	for _, trap in traps do
		if trap.owner == player and not trap.triggered then
			active += 1
		end
		if (trap.part.Position - hit.Position).Magnitude < PvPConfig.TRAP_TRIGGER_RADIUS * 1.5 then
			notify(player, "error", "There is already a trap there.")
			return
		end
	end
	if active >= PvPConfig.TRAP_MAX_ACTIVE_PER_PLAYER then
		notify(player, "error", "Too many traps out.")
		return
	end

	-- SPEND ONE, and start the refill only if that was the last. Both happen
	-- BEFORE the trap is built, so nothing between here and the world object
	-- can spend the same charge twice.
	profile.TrapCount -= 1
	local emptied = profile.TrapCount <= 0
	if emptied then
		profile.TrapReadyAt = os.time() + PvPConfig.TRAP_REFILL
	end

	table.insert(traps, {
		owner = player,
		part = buildTrapPart(hit.Position, player),
		placedAt = os.clock(),
		armedForOwnerAt = os.clock() + PvPConfig.TRAP_OWNER_IMMUNITY,
		triggered = false,
	})

	StateService.pushNow(player)
	if emptied then
		notify(player, "success", `Trap placed - last one. All {PvPConfig.TRAP_CAPACITY} back in {PvPConfig.TRAP_REFILL // 60}m.`)
	else
		notify(player, "success", `Trap placed. {profile.TrapCount} left.`)
	end
end

local function triggerTrap(trap: Trap, victim: Player)
	trap.triggered = true
	trap.part:Destroy()

	-- Drop BEFORE rooting. forceDrop re-applies movement, so rooting first
	-- would have the root immediately undone by the drop.
	local carried = CarryService.getCarried(victim)
	if carried then
		CarryService.forceDrop(carried)
	end

	RagdollService.root(victim, PvPConfig.TRAP_ROOT_DURATION)
	RagdollService.grantImmunity(victim, PvPConfig.TRAP_ROOT_DURATION + PvPConfig.TRAP_VICTIM_IMMUNITY)

	notify(victim, "error", "TRAPPED!")
	if trap.owner.Parent then
		notify(trap.owner, "success", `Your trap caught {victim.Name}!`)
	end
end

--- Traps are polled rather than using Touched: the server stays authoritative
--- and a lagging client cannot avoid one by not reporting a touch.
local function stepTraps()
	local now = os.clock()

	for index = #traps, 1, -1 do
		local trap = traps[index]

		if trap.triggered or not trap.part.Parent then
			table.remove(traps, index)
			continue
		end

		if now - trap.placedAt >= PvPConfig.TRAP_LIFETIME then
			trap.part:Destroy()
			table.remove(traps, index)
			continue
		end

		local position = trap.part.Position

		-- Rival players.
		for _, player in Players:GetPlayers() do
			if trap.triggered then
				break
			end
			if player == trap.owner and now < trap.armedForOwnerAt then
				continue -- owner's placement grace
			end
			if not isAlive(player) or RagdollService.isImmune(player) then
				continue
			end
			local root = rootPartOf(player)
			if root and (root.Position - position).Magnitude <= PvPConfig.TRAP_TRIGGER_RADIUS then
				triggerTrap(trap, player)
			end
		end

		if trap.triggered then
			continue
		end

		-- Active guardians: rooted, but their chase state is left intact.
		for _, zoneIndex in GuardianService.activeChaseZones() do
			local guardianPosition = GuardianService.guardianPosition(zoneIndex)
			if guardianPosition and (guardianPosition - position).Magnitude <= PvPConfig.TRAP_TRIGGER_RADIUS then
				if GuardianService.rootGuardian(zoneIndex, PvPConfig.TRAP_ROOT_DURATION) then
					trap.triggered = true
					trap.part:Destroy()
					if trap.owner.Parent then
						notify(trap.owner, "success", "Your trap stopped the guard!")
					end
				end
				break
			end
		end
	end
end

-- ==========================================================
-- TOOLS
-- ==========================================================

local function buildBat(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Bat"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Knock loot out of other players"

	local art = batArt()
	if art then
		-- The supplied mesh IS the handle. Its long axis is Z; a Tool grips its
		-- Handle along the character's forearm with +Y as "up the tool", so the
		-- Grip is rotated to stand the bat up in the hand and pitch it forward
		-- a little, the way a bat is actually held rather than pointed at the
		-- ground.
		local handle = art:Clone()
		handle.Name = "Handle"
		handle.Anchored = false
		handle.CanCollide = false
		handle.CanQuery = false
		handle.CanTouch = false
		handle.Massless = true
		handle.CastShadow = true
		handle.Parent = tool

		local length = handle.Size.Z
		tool.Grip = CFrame.new(0, -0.15, length * 0.34) * CFrame.Angles(math.rad(-90), 0, 0)
		return tool
	end

	-- Fallback: the original primitive bat, so a missing asset never removes
	-- the weapon from the game.
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.8, 5, 0.8)
	handle.Color = Color3.fromRGB(168, 116, 64)
	handle.Material = Enum.Material.Wood
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.4, 2.2, 1.4)
	head.Color = Color3.fromRGB(196, 138, 78)
	head.Material = Enum.Material.Wood
	head.CanCollide = false
	head.Massless = true
	head.Parent = tool

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = head
	weld.Parent = handle
	head.CFrame = handle.CFrame * CFrame.new(0, 2.6, 0)

	return tool
end

-- ==========================================================
-- THE SLAP
-- ==========================================================
--
-- The art is the hand-on-a-stick inside the lobby cage (workspace.Slap.Item
-- with its Hand and Stick welded on). A copy lives in
-- ReplicatedStorage.GameAssets.Weapons.Slap - published there rather than
-- ServerStorage so the Storage card and the offer can draw the real thing -
-- and every Tool is built from that copy, scaled down to fit a fist.

local function weaponsFolder(): Folder
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	if not assets then
		assets = Instance.new("Folder")
		assets.Name = "GameAssets"
		assets.Parent = ReplicatedStorage
	end
	local folder = assets:FindFirstChild("Weapons")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Weapons"
		folder.Parent = assets
	end
	return folder :: Folder
end

--- The published Slap model, building it from the cage display if needed.
local function slapArt(): Model?
	local folder = weaponsFolder()
	local held = folder:FindFirstChild("Slap")
	if held and held:IsA("Model") and held.PrimaryPart then
		return held
	end
	local display = workspace:FindFirstChild("Slap")
	local item = display and display:FindFirstChild("Item")
	if not item or not item:IsA("BasePart") then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "Slap"
	local handle = item:Clone()
	handle.Name = "Handle"
	handle.Parent = model
	model.PrimaryPart = handle
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end
	model.Parent = folder
	return model
end

--- The Bat's preview copy, for the Weapons page. The mesh itself stays in
--- ServerStorage where PvP adopted it.
local function publishBatPreview()
	local folder = weaponsFolder()
	if folder:FindFirstChild("Bat") then
		return
	end
	local art = batArt()
	if not art then
		return
	end
	local model = Instance.new("Model")
	model.Name = "Bat"
	local copy = art:Clone()
	copy.Name = "Handle"
	copy.Anchored = true
	copy.CanCollide = false
	copy.Parent = model
	model.PrimaryPart = copy
	model.Parent = folder
end

local function buildSlap(): Tool?
	local art = slapArt()
	if not art then
		return nil
	end

	local tool = Instance.new("Tool")
	tool.Name = "Slap"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Slap players away"

	-- Scale as a model (the welds keep their relative offsets), then move
	-- the parts into the Tool. The WeldConstraints ride along with the parts.
	local copy = art:Clone()
	copy:ScaleTo(copy:GetScale() * PvPConfig.SLAP_TOOL_SCALE)
	local handle = copy:FindFirstChild("Handle") or copy.PrimaryPart
	for _, descendant in copy:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.CastShadow = true
			descendant.Parent = tool
		end
	end
	if handle and handle:IsA("BasePart") then
		handle.Name = "Handle"
	end
	copy:Destroy()

	-- The hand sits along the handle's local -Z (measured from the cage: the
	-- stick runs from the handle up to the palm). Pitched -90 about X, like
	-- the bat, that axis stands up out of the fist, gripped low on the stick.
	tool.Grip = CFrame.new(0, -0.1, -1.0) * CFrame.Angles(math.rad(-90), 0, 0)
	return tool
end

local function buildTrapTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Trap"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Place a trap to root a rival"

	-- The held trap is the same mesh that gets placed, scaled down to a hand,
	-- so what you are carrying is recognisably what you are about to put down.
	local art = trapArt()
	if art then
		local handle = art:Clone()
		handle.Name = "Handle"
		handle.Anchored = false
		handle.CanCollide = false
		handle.CanQuery = false
		handle.CanTouch = false
		handle.Massless = true
		local factor = 2.2 / math.max(art.Size.X, art.Size.Z)
		handle.Size = art.Size * factor
		handle.Parent = tool
		tool.Grip = CFrame.new(0, -0.4, 0) * CFrame.Angles(math.rad(-90), 0, 0)
		return tool
	end

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Shape = Enum.PartType.Cylinder
	handle.Size = Vector3.new(0.5, 2.4, 2.4)
	handle.Color = Color3.fromRGB(255, 96, 96)
	handle.Material = Enum.Material.Neon
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	return tool
end

--- The player's weapon (the Bat, or the Slap they own and chose) plus the
--- Trap. ONE weapon at a time: whichever of the two they did not choose is
--- taken out of the Backpack and the hand, so a respawn, a re-equip or an
--- ownership refresh can never leave both, and never a duplicate of either.
local function giveTools(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	local character = player.Character
	local wanted = PvPService.equippedWeapon(player)

	for _, name in PvPConfig.WeaponOrder do
		if name == wanted then
			continue
		end
		for _, container in { backpack :: Instance?, character :: Instance? } do
			local stale = if container then container:FindFirstChild(name) else nil
			if stale and stale:IsA("Tool") then
				stale:Destroy()
			end
		end
	end

	local has = backpack:FindFirstChild(wanted) or (character and character:FindFirstChild(wanted))
	if not has then
		local tool: Tool? = if wanted == "Slap" then buildSlap() else buildBat()
		if not tool then
			-- The Slap art is missing from the place: the Bat, never nothing.
			warn("[PvPService] no Slap art available - giving the Bat instead")
			tool = buildBat()
		end
		(tool :: Tool).Parent = backpack
	end
	if not backpack:FindFirstChild("Trap") and not (character and character:FindFirstChild("Trap")) then
		buildTrapTool().Parent = backpack
	end
end

--- Storage > WEAPONS: choose the Bat or the Slap. Replaces, never adds.
function PvPService.setWeapon(player: Player, name: string): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local def = PvPConfig.Weapons[name]
	if not def then
		return false, "That weapon does not exist."
	end
	if def.gamePass and not PvPService.ownsSlap(player) then
		return false, "You don't own the Slap yet."
	end
	if profile.EquippedWeapon == name and PvPService.equippedWeapon(player) == name then
		return true
	end

	-- If the old weapon was in the hand, the new one goes into it.
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	local wasHolding = false
	if character then
		for _, other in PvPConfig.WeaponOrder do
			if other ~= name and character:FindFirstChild(other) then
				wasHolding = true
			end
		end
	end

	profile.EquippedWeapon = name
	giveTools(player)
	if wasHolding and humanoid then
		local backpack = player:FindFirstChildOfClass("Backpack")
		local tool = backpack and backpack:FindFirstChild(name)
		if tool and tool:IsA("Tool") then
			humanoid:EquipTool(tool)
		end
	end
	StateService.pushNow(player)
	notify(player, "success", `{string.upper(name)} EQUIPPED!`)
	return true
end

--- What the Weapons page and the Slap offer render.
function PvPService.summarise(player: Player): { [string]: any }
	return {
		equipped = PvPService.equippedWeapon(player),
		owned = { Bat = true, Slap = PvPService.ownsSlap(player) },
		slapPrice = MonetizationService.livePassPrice(MonetizationConfig.SlapPass.gamePassId),
	}
end

--- Ownership was (re)checked: a Slap just bought appears in the Backpack at
--- once, and one no longer owned goes back to the Bat.
function PvPService.onOwnershipChanged(player: Player)
	if player.Parent and DataService.get(player) then
		giveTools(player)
	end
end

-- ==========================================================
-- START
-- ==========================================================

function PvPService.start()
	trapFolder = Instance.new("Folder")
	trapFolder.Name = "Traps"
	trapFolder.Parent = workspace

	-- Take the supplied art out of the world NOW, before a player can find a bat
	-- floating in the sky, rather than the first time a tool is built.
	if not batArt() then
		warn("[PvPService] no MeshPart named \"Bat\" found - using the primitive bat.")
	end
	if not trapArt() then
		warn("[PvPService] no MeshPart named \"Trap\" found - using the neon disc trap.")
	end
	-- The Weapons page draws the real models: publish the Bat and the Slap
	-- where a client can clone them.
	publishBatPreview()
	if not slapArt() then
		warn("[PvPService] no Slap art (workspace.Slap.Item or ReplicatedStorage.GameAssets.Weapons.Slap) - the Slap cannot be built.")
	end

	-- THE REFILL, once a second. `refillTraps` is idempotent and every reader
	-- calls it anyway, so this exists purely so the counter under the hotbar
	-- comes back on its own rather than at the next unrelated push.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				local profile = DataService.get(player)
				if profile and refillTraps(profile) then
					StateService.markDirty(player)
				end
			end
		end
	end)

	-- One remote for every swing; the weapon is read from the hand.
	Remotes.get("BatSwingRequest").OnServerEvent:Connect(function(player)
		PvPService.trySwing(player)
	end)

	Remotes.get("WeaponRequest").OnServerEvent:Connect(function(player, action, name)
		if not weaponLimiter:consume(player) then
			return
		end
		if action == "equip" and type(name) == "string" then
			local ok, reason = PvPService.setWeapon(player, name)
			if not ok and reason then
				notify(player, "error", reason)
			end
		end
	end)

	StateService.addProvider("weapons", PvPService.summarise)

	Remotes.get("TrapPlaceRequest").OnServerEvent:Connect(function(player, position)
		-- A Vector3 with a NaN component is still a Vector3; it would turn the
		-- clamp below into a NaN target and the ground raycast into garbage. A
		-- malformed hint simply falls back to "just ahead of the player".
		PvPService.tryPlaceTrap(player, Validate.vector3(position))
	end)

	local function onPlayer(player: Player)
		task.spawn(function()
			DataService.waitForProfile(player)
			giveTools(player)
		end)
		player.CharacterAdded:Connect(function()
			task.wait(0.4)
			giveTools(player)
		end)
	end

	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)

	Players.PlayerRemoving:Connect(function(player)
		batLimiter:release(player)
		trapLimiter:release(player)
		weaponLimiter:release(player)
		lastSwing[player] = nil
		-- Their traps leave with them: a live trap belonging to nobody cannot
		-- be triggered, credited or cleaned up later. This costs the player
		-- nothing now that the trap RECHARGES rather than being spent - the
		-- cooldown stamp on their profile is what they get back.
		for index = #traps, 1, -1 do
			if traps[index].owner == player then
				traps[index].part:Destroy()
				table.remove(traps, index)
			end
		end
	end)

	RunService.Heartbeat:Connect(stepTraps)

	print("[PvPService] bat and traps online")
end

--- Debug helper.
function PvPService.activeTrapCount(): number
	return #traps
end

--- Debug helper. Back-dates every live trap so the 300-second expiry can be
--- observed in a test without waiting five minutes. Studio only: it does
--- nothing at all in a real server.
function PvPService.debugAgeTraps(seconds: number): number
	if not RunService:IsStudio() then
		return 0
	end
	local aged = 0
	for _, trap in traps do
		trap.placedAt -= seconds
		aged += 1
	end
	return aged
end

return PvPService
