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

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local PvPConfig = require(ReplicatedStorage.Shared.Config.PvPConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

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
	resolveSwing(player)
	return true
end

-- ==========================================================
-- TRAPS
-- ==========================================================

local function buildTrapPart(position: Vector3, owner: Player): BasePart
	local part = Instance.new("Part")
	part.Name = "Trap"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.6, PvPConfig.TRAP_TRIGGER_RADIUS * 2, PvPConfig.TRAP_TRIGGER_RADIUS * 2)
	part.CFrame = CFrame.new(position + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Color = Color3.fromRGB(255, 96, 96)
	part.Material = Enum.Material.Neon
	part.Transparency = 0.35
	part:SetAttribute("OwnerUserId", owner.UserId)
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

	Remotes.get("BatSwingRequest").OnServerEvent:Connect(function(player)
		PvPService.trySwing(player)
	end)

	Remotes.get("TrapPlaceRequest").OnServerEvent:Connect(function(player, position)
		local requested: Vector3? = nil
		if typeof(position) == "Vector3" then
			requested = position
		end
		PvPService.tryPlaceTrap(player, requested)
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
