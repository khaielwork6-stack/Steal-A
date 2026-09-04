--!strict
--[[
	GuardianService
	One guardian per loot socket, chasing only its own thief (GDD section 10).

	Design rules this enforces:
	  * Target ownership: a guardian may ONLY target the player carrying the item
	    from its linked socket. It never retargets a random nearby player.
	  * Idle guardians have no per-frame heartbeat. Only active chases update.
	  * Guardians cannot cross the carrier's own base safe zone.
	  * Zone 1's Cop must be beatable at fresh-account SpeedPower 10.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local LootService = require(script.Parent.LootService)
local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)

local GuardianService = {}

type Guardian = {
	zoneIndex: number,
	socketIndex: number,
	home: CFrame,
	model: Model?,
	humanoid: Humanoid?,
	root: BasePart?,
	target: Player?,
	lootId: string?,
	lastRepath: number,
}

local guardians: { [string]: Guardian } = {}
local active: { [string]: Guardian } = {}

local function key(zoneIndex: number, socketIndex: number): string
	return `{zoneIndex}:{socketIndex}`
end

--- Guardian speed sits just under a player who meets the recommendation, so a
--- Normal-size item is a narrow win and heavier loot needs a Speed buffer.
local function guardianSpeed(zoneIndex: number): number
	local zone = ZoneConfig.Zones[zoneIndex]
	local matched = GameConfig.walkSpeedFromPower(math.max(zone.recommendedSpeed, GameConfig.STARTING_SPEED_POWER))
	return matched * ZoneConfig.GUARDIAN_SPEED_FACTOR
end

-- ==========================================================
-- RIG
-- ==========================================================

--- Real rigs live at ServerStorage.GameAssets.Guardians.<ZoneNN_Name>. Until
--- those exist a blocky placeholder humanoid keeps the chase fully testable.
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

	local headWeld = Instance.new("WeldConstraint")
	headWeld.Part0 = root
	headWeld.Part1 = head
	headWeld.Parent = root

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.HipHeight = 0
	humanoid.Parent = model

	model.PrimaryPart = root
	return model
end

local function spawnGuardian(guardian: Guardian)
	local model = buildRig(guardian.zoneIndex)
	local humanoid = model:FindFirstChildWhichIsA("Humanoid")
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root or not root:IsA("BasePart") then
		warn(`[GuardianService] malformed rig for zone {guardian.zoneIndex}`)
		model:Destroy()
		return
	end

	humanoid.WalkSpeed = guardianSpeed(guardian.zoneIndex)
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- Guardians must never be shoved around by players or carried loot.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

	model:PivotTo(guardian.home)
	model.Parent = workspace

	guardian.model = model
	guardian.humanoid = humanoid
	guardian.root = root
end

-- ==========================================================
-- CHASE
-- ==========================================================

local function alert(guardian: Guardian)
	local root = guardian.root
	if not root then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "Alert"
	gui.Size = UDim2.fromScale(3, 3)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = root
	gui.Parent = root

	local mark = Instance.new("TextLabel")
	mark.Size = UDim2.fromScale(1, 1)
	mark.BackgroundTransparency = 1
	mark.Font = Enum.Font.FredokaOne
	mark.TextScaled = true
	mark.TextColor3 = Color3.fromRGB(255, 72, 72)
	mark.TextStrokeTransparency = 0.2
	mark.Text = "!"
	mark.Parent = gui

	task.delay(1.5, function()
		gui:Destroy()
	end)
end

local function stopChase(guardian: Guardian)
	guardian.target = nil
	guardian.lootId = nil
	active[key(guardian.zoneIndex, guardian.socketIndex)] = nil

	local humanoid = guardian.humanoid
	if humanoid and guardian.model then
		humanoid:MoveTo(guardian.home.Position)
	end
end

function GuardianService.beginChase(loot: LootService.LootInstance, carrier: Player)
	local guardian = guardians[key(loot.zoneIndex, loot.socketIndex)]
	if not guardian or not guardian.humanoid then
		return
	end

	guardian.target = carrier
	guardian.lootId = loot.id
	guardian.lastRepath = 0
	active[key(loot.zoneIndex, loot.socketIndex)] = guardian

	alert(guardian)
end

function GuardianService.stopChaseFor(loot: LootService.LootInstance)
	local guardian = guardians[key(loot.zoneIndex, loot.socketIndex)]
	if guardian and guardian.lootId == loot.id then
		stopChase(guardian)
	end
end

--- Only active chases run. Idle guardians cost nothing per frame.
local function stepChases()
	local now = os.clock()

	for _, guardian in active do
		local humanoid = guardian.humanoid
		local root = guardian.root
		local target = guardian.target
		local lootId = guardian.lootId

		if not humanoid or not root or not target or not lootId then
			stopChase(guardian)
			continue
		end

		local loot = LootService.get(lootId)
		if not loot or loot.state ~= "Carried" or loot.carrier ~= target then
			stopChase(guardian)
			continue
		end

		local character = target.Character
		local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
		if not targetRoot or not targetRoot:IsA("BasePart") then
			stopChase(guardian)
			continue
		end

		-- Safe boundary: the guardian may not cross into the carrier's own base.
		if BaseService.isInOwnSafeZone(target) then
			stopChase(guardian)
			continue
		end

		local distance = (root.Position - targetRoot.Position).Magnitude

		if distance <= ZoneConfig.GUARDIAN_CATCH_RADIUS then
			CarryService.reclaim(loot)
			stopChase(guardian)
			continue
		end

		-- Direct MoveTo while the path is simple; repath on a controlled cadence
		-- rather than every frame.
		if now - guardian.lastRepath >= ZoneConfig.GUARDIAN_REPATH_INTERVAL then
			guardian.lastRepath = now
			humanoid:MoveTo(targetRoot.Position)
		end
	end
end

-- ==========================================================
-- START
-- ==========================================================

function GuardianService.start()
	local map = workspace:WaitForChild("Map", 20)
	local zonesFolder = map:WaitForChild("Zones", 10)

	local holder = Instance.new("Folder")
	holder.Name = "Guardians"
	holder.Parent = workspace

	for zoneIndex, zoneDef in ZoneConfig.Zones do
		local zone = zonesFolder:FindFirstChild(zoneDef.id)
		local posts = zone and zone:FindFirstChild("GuardianSpawns")
		if not posts then
			continue
		end

		for socketIndex = 1, ZoneConfig.SOCKETS_PER_ZONE do
			local post = posts:FindFirstChild(string.format("Guard%02d", socketIndex))
			if post and post:IsA("BasePart") then
				local guardian: Guardian = {
					zoneIndex = zoneIndex,
					socketIndex = socketIndex,
					home = post.CFrame * CFrame.new(0, 3, 0),
					lastRepath = 0,
				}
				guardians[key(zoneIndex, socketIndex)] = guardian
				spawnGuardian(guardian)
				if guardian.model then
					guardian.model.Parent = holder
				end
			end
		end
	end

	-- React to loot state rather than polling for thefts.
	LootService.onStateChanged(function(loot, previous, next)
		if next == "Carried" and previous ~= "Dropped" and loot.carrier then
			GuardianService.beginChase(loot, loot.carrier)
		elseif next == "Returning" or next == "Placed" or next == "Spawned" then
			GuardianService.stopChaseFor(loot)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		for _, guardian in active do
			if guardian.target == player then
				stopChase(guardian)
			end
		end
	end)

	RunService.Heartbeat:Connect(stepChases)

	local count = 0
	for _ in guardians do
		count += 1
	end
	print(`[GuardianService] {count} guardians posted`)
end

return GuardianService
