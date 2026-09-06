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

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local PvPConfig = require(ReplicatedStorage.Shared.Config.PvPConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local GuardianService = require(script.Parent.GuardianService)
local RagdollService = require(script.Parent.RagdollService)
local StateService = require(script.Parent.StateService)

local PvPService = {}

local batLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.BatSwingRequest)
local trapLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.TrapPlaceRequest)

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
-- BAT
-- ==========================================================

--- Server-side hit resolution. The attacker's own facing decides the arc, and
--- the server picks at most ONE victim from a spatial query.
local function resolveSwing(attacker: Player)
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
		if distance > PvPConfig.BAT_RANGE then
			continue
		end

		-- Behind the attacker does not count.
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > 0.1 then
			local angle = math.deg(math.acos(math.clamp(flat.Unit:Dot(Vector3.new(forward.X, 0, forward.Z).Unit), -1, 1)))
			if angle > PvPConfig.BAT_ARC_DEGREES / 2 then
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
	Audio.playAt("BatHit", victimCharacter and victimCharacter:FindFirstChild("HumanoidRootPart"))

	-- Drop BEFORE the launch so the item lands where the victim was standing.
	local carried = CarryService.getCarried(victim)
	if carried then
		CarryService.forceDrop(carried)
		local profile = DataService.get(attacker)
		if profile then
			profile.Lifetime.PvPSteals += 1
		end
		notify(attacker, "success", `You knocked the {carried.name} loose!`)
	else
		notify(attacker, "info", "Hit!")
	end

	RagdollService.launch(victim, origin, {
		knockback = PvPConfig.KNOCKBACK_SPEED,
		lift = PvPConfig.KNOCKBACK_LIFT,
		stun = PvPConfig.RAGDOLL_DURATION,
		immunity = PvPConfig.RAGDOLL_DURATION + PvPConfig.POST_RAGDOLL_IMMUNITY,
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

	local now = os.clock()
	if now - (lastSwing[player] or 0) < PvPConfig.BAT_COOLDOWN then
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
	-- Resolved when the bat ARRIVES, not when the button is pressed. The client's
	-- wind-up runs for the same delay, so the connect, the sound and the launch
	-- all happen on the frame the swing visually lands. The cooldown was stamped
	-- above, so a second press inside the delay is still refused.
	task.delay(PvPConfig.BAT_STRIKE_DELAY, function()
		if player.Parent and isAlive(player) then
			resolveSwing(player)
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

function PvPService.tryPlaceTrap(player: Player, requested: Vector3?)
	if not trapLimiter:consume(player) then
		return
	end

	local profile = DataService.get(player)
	if not profile then
		return
	end
	if profile.TrapCount <= 0 then
		notify(player, "error", "You have no traps left.")
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

	-- Consume first: the count is saved, so resetting or rejoining can never
	-- hand a player free traps.
	profile.TrapCount -= 1

	table.insert(traps, {
		owner = player,
		part = buildTrapPart(hit.Position, player),
		placedAt = os.clock(),
		armedForOwnerAt = os.clock() + PvPConfig.TRAP_OWNER_IMMUNITY,
		triggered = false,
	})

	StateService.pushNow(player)
	notify(player, "success", `Trap placed. {profile.TrapCount} left.`)
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

local function giveTools(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	if not backpack:FindFirstChild("Bat") and not (player.Character and player.Character:FindFirstChild("Bat")) then
		buildBat().Parent = backpack
	end
	if not backpack:FindFirstChild("Trap") and not (player.Character and player.Character:FindFirstChild("Trap")) then
		buildTrapTool().Parent = backpack
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

	Remotes.get("BatSwingRequest").OnServerEvent:Connect(function(player)
		PvPService.trySwing(player)
	end)

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
		lastSwing[player] = nil
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

return PvPService
