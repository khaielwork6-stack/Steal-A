--!strict
--[[
	VaultBuilder
	Builds each zone's vault (vaults-crews area) into `Zones.<id>.Vault`. Called
	by MapBuilder right after MuseumGallery, before any service binds.

	WHERE. MuseumLayout (VAULTS) owns the geometry: a vault fills an unused wing
	behind the corridor facade (MuseumGallery leaves that stretch of facade to
	the vault's front wall). Zones 1 and 2 are housed in Zone 3's near wings;
	their folders still live under their own zone.

	WHAT. Placeholder art until the Codex assets land (docs/codex-prompts/
	vaults-crews.md): dark metal walls, a round door with gold trim, a pedestal
	inside a ring of rotating lasers.

	  Vault                      Folder, attributes: VaultZone, HostZone,
	                             RequiredSpeed, DoorOpen, RestockAt, Stocked
	    Structure                walls, ceiling, pedestal (collide, query)
	    Decorations              PartKit.decor parts only
	    Door                     Model the CLIENT slides aside (DoorOpen)
	    VaultBarrier             invisible part filling the doorway. It never
	                             collides on the server; VaultController makes
	                             it solid locally for a player the door refuses,
	                             and VaultService ejects anyone who gets past.
	    Lasers                   VaultBeam parts; the client turns them from
	                             their attributes (LaserGeometry.SweepArm)
	    SpawnSockets.Socket09    the pedestal's loot socket (LootService). The
	                             folder name lets WorldLootFxController idle the
	                             container like any case's.
	    GuardianPost             the Vault Guardian's post (GuardianService)
	    Sign                     plaque over the door; VaultController writes
	                             its status line

	PART BUDGET. About 50 parts per vault (limit 150), all anchored; every decor
	part is CanQuery/CanTouch/CanCollide/CastShadow false (PartKit.decor).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local VaultConfig = require(ReplicatedStorage.Shared.Config.VaultConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)
local PartKit = require(script.Parent.PartKit)

local VaultBuilder = {}

local GOLD = PartKit.GOLD
local DARK = PartKit.DARK
local METAL = Color3.fromRGB(58, 64, 74)
local STEEL = Color3.fromRGB(96, 104, 116)
local LASER = Color3.fromRGB(255, 35, 49)

local decor = PartKit.decor

--- The only non-decor parts: walls, ceiling and pedestal.
local function solid(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name, p.Size, p.CFrame = name, size, cf
	p.Color, p.Material = color, material or Enum.Material.Metal
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, true, true, false
	p.CastShadow = true
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- An invisible, inert service anchor (same shape as MuseumGallery's).
local function marker(parent: Instance, name: string, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size, p.CFrame = Vector3.new(1, 0.2, 1), cf
	p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery = true, false, false, false
	p.Transparency, p.CastShadow = 1, false
	p:SetAttribute("RoomIndex", Layout.VAULT_ROOM)
	p.Parent = parent
	return p
end

--- A disc lying flat (cylinder axis up).
local function disc(parent: Instance, name: string, center: Vector3, radius: number, thickness: number, color: Color3, material: Enum.Material?): Part
	local p = decor(parent, name, Vector3.new(thickness, radius * 2, radius * 2), CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2), color, material)
	p.Shape = Enum.PartType.Cylinder
	return p
end

--- The status plaque over the door. The client rewrites `Status`.
local function statusPlaque(parent: Instance, cf: CFrame, width: number, zoneIndex: number)
	local plate = decor(parent, "Sign", Vector3.new(width, 5, 0.3), cf, DARK, Enum.Material.Metal)
	local gui = Instance.new("SurfaceGui")
	gui.Face, gui.LightInfluence, gui.PixelsPerStud = Enum.NormalId.Front, 0, 24
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.Parent = plate
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency, title.Size, title.Position = 1, UDim2.fromScale(0.94, 0.5), UDim2.fromScale(0.03, 0.04)
	title.Font, title.TextScaled, title.TextColor3 = Enum.Font.FredokaOne, true, GOLD
	title.Text = string.upper(`Zone {zoneIndex} Vault`)
	title.Parent = gui
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency, status.Size, status.Position = 1, UDim2.fromScale(0.94, 0.38), UDim2.fromScale(0.03, 0.56)
	status.Font, status.TextScaled, status.TextColor3 = Enum.Font.GothamBold, true, Color3.fromRGB(235, 240, 250)
	local speed = ZoneConfig.Zones[zoneIndex].recommendedSpeed * VaultConfig.SPEED_GATE_FRACTION
	status.Text = if speed > 0 then `NEEDS {NumberFormat.short(speed)} SPEED` else "OPEN TO ALL"
	status.Parent = gui
end

--- The round door, as one Model the client can slide. Codex art, when it
--- exists (ServerStorage.GameAssets.Vault.<DoorModelName>), replaces the
--- placeholder disc; the model keeps the same name and pivot either way.
local function door(parent: Instance, frame: CFrame): Model
	local model = Instance.new("Model")
	model.Name = "Door"
	local center = frame * CFrame.new(0, Layout.VAULT_DOOR_HEIGHT / 2, 0)
	-- Cylinder axis (part X) along the frame's Z: the disc faces the corridor.
	local function faceOn(z: number): CFrame
		return center * CFrame.new(0, 0, z) * CFrame.Angles(0, math.pi / 2, 0)
	end
	local radius = 13
	local rim = decor(model, "DoorRim", Vector3.new(1.2, radius * 2 + 0.8, radius * 2 + 0.8), faceOn(-1.6), GOLD, Enum.Material.Metal)
	rim.Shape = Enum.PartType.Cylinder
	local plate = decor(model, "DoorDisk", Vector3.new(1.6, radius * 2, radius * 2), faceOn(-2.0), METAL, Enum.Material.DiamondPlate)
	plate.Shape = Enum.PartType.Cylinder
	local hub = decor(model, "DoorHub", Vector3.new(2.2, 6, 6), faceOn(-2.4), GOLD, Enum.Material.Metal)
	hub.Shape = Enum.PartType.Cylinder
	for n = 0, 2 do
		decor(model, "DoorSpoke", Vector3.new(16, 0.8, 0.8), center * CFrame.new(0, 0, -3.3) * CFrame.Angles(0, 0, n * math.pi / 3), GOLD, Enum.Material.Metal)
	end
	for n = 0, 7 do
		local angle = n * math.pi / 4
		local bolt = decor(model, "DoorBolt", Vector3.one * 1.1, center * CFrame.new(math.cos(angle) * (radius - 1.4), math.sin(angle) * (radius - 1.4), -2.9), STEEL, Enum.Material.Metal)
		bolt.Shape = Enum.PartType.Ball
	end
	model.PrimaryPart = plate
	-- Codex's door, if it has been made.
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local kit = assets and assets:FindFirstChild("Vault")
	local art = kit and kit:FindFirstChild(VaultConfig.Art.DoorModelName)
	if art and art:IsA("Model") then
		local copy = art:Clone()
		local _, size = copy:GetBoundingBox()
		local widest = math.max(size.X, size.Y, size.Z)
		if widest > 0.01 then
			copy:ScaleTo(copy:GetScale() * (radius * 2 / widest))
		end
		-- The art faces its own -Z; the frame's -Z is the corridor.
		copy:PivotTo(center * CFrame.new(0, 0, -2.0))
		for _, d in copy:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored, d.CanCollide, d.CanQuery, d.CanTouch, d.CastShadow = true, false, false, false, false
			end
		end
		copy.Name = "Art"
		copy.Parent = model
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child ~= plate then
				child:Destroy()
			end
		end
		plate.Transparency = 1
	end
	model:SetAttribute("SlideDistance", Layout.VAULT_DOOR_WIDTH / 2 + radius + 0.5)
	model.Parent = parent
	return model
end

local function buildVault(zone: Instance, zoneIndex: number)
	local old = zone:FindFirstChild("Vault")
	if old then
		old:Destroy()
	end
	local frame = Layout.vaultFrame(zoneIndex)
	local length, depth = Layout.vaultLength(zoneIndex), Layout.DEPTH
	local height, doorWidth, doorHeight = Layout.VAULT_HEIGHT, Layout.VAULT_DOOR_WIDTH, Layout.VAULT_DOOR_HEIGHT
	local host = Layout.vaultHost(zoneIndex)
	local ring = VaultConfig.ring(zoneIndex)

	local vault = PartKit.folder("Vault", zone)
	vault:SetAttribute("VaultZone", zoneIndex)
	vault:SetAttribute("HostZone", host)
	vault:SetAttribute("RequiredSpeed", ZoneConfig.Zones[zoneIndex].recommendedSpeed * VaultConfig.SPEED_GATE_FRACTION)
	vault:SetAttribute("DoorOpen", false)
	vault:SetAttribute("RestockAt", 0)
	vault:SetAttribute("Stocked", false)
	local structure = PartKit.folder("Structure", vault)
	local decorations = PartKit.folder("Decorations", vault)

	local function at(x: number, y: number, z: number): CFrame
		return frame * CFrame.new(x, y, z)
	end

	-- WALLS. The front wall is full museum height: it replaces the facade
	-- over this span, and hides the wing above the vault's lower ceiling.
	local fullHeight = Layout.HEIGHT
	local wing = length / 2 - doorWidth / 2
	for _, sign in { -1, 1 } do
		solid(structure, "FrontWall", Vector3.new(wing, fullHeight, 2), at(sign * (doorWidth / 2 + wing / 2), fullHeight / 2, 0), METAL)
		solid(structure, "SideWall", Vector3.new(2, height, depth - 2), at(sign * (length / 2 - 1), height / 2, depth / 2), METAL)
	end
	solid(structure, "FrontHeader", Vector3.new(doorWidth, fullHeight - doorHeight, 2), at(0, (fullHeight + doorHeight) / 2, 0), METAL)
	solid(structure, "RearWall", Vector3.new(length, height, 2), at(0, height / 2, depth - 1), METAL)
	solid(structure, "Ceiling", Vector3.new(length, 1, depth), at(0, height + 0.5, depth / 2), DARK)
	local pedestalHeight = VaultConfig.PEDESTAL_HEIGHT
	local pedestal = solid(structure, "Pedestal", Vector3.new(pedestalHeight, ring.pedestalRadius * 2, ring.pedestalRadius * 2),
		CFrame.new(ring.pivot + Vector3.new(0, pedestalHeight / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), DARK)
	pedestal.Shape = Enum.PartType.Cylinder

	-- THE DOORWAY: the barrier, the door and its gold jambs.
	local barrier = Instance.new("Part")
	barrier.Name = "VaultBarrier"
	barrier.Size, barrier.CFrame = Vector3.new(doorWidth, doorHeight, 2), at(0, doorHeight / 2, 0)
	barrier.Anchored, barrier.CanCollide, barrier.CanQuery, barrier.CanTouch = true, false, false, false
	barrier.Transparency, barrier.CastShadow = 1, false
	barrier.Parent = vault
	door(vault, frame)
	for _, sign in { -1, 1 } do
		decor(decorations, "DoorJamb", Vector3.new(0.8, doorHeight, 0.6), at(sign * (doorWidth / 2 + 0.4), doorHeight / 2, -1.3), GOLD, Enum.Material.Metal)
	end
	decor(decorations, "DoorLintel", Vector3.new(doorWidth + 1.6, 0.8, 0.6), at(0, doorHeight + 0.4, -1.3), GOLD, Enum.Material.Metal)
	-- Hazard stripes on the corridor floor in front of the door.
	decor(decorations, "DoorStep", Vector3.new(doorWidth + 4, 0.04, 5), at(0, 0.03, -3.5), Color3.fromRGB(230, 180, 40), Enum.Material.DiamondPlate)
	statusPlaque(decorations, at(0, doorHeight + 5, -1.2), math.min(length - 4, 30), zoneIndex)

	-- INTERIOR.
	decor(decorations, "VaultFloor", Vector3.new(length - 4, 0.03, depth - 4), at(0, 0.02, depth / 2), DARK, Enum.Material.DiamondPlate)
	disc(decorations, "RingTrack", ring.pivot + Vector3.new(0, 0.05, 0), ring.outer, 0.04, Color3.fromRGB(70, 22, 30), Enum.Material.Metal)
	disc(decorations, "SafeCircle", ring.pivot + Vector3.new(0, 0.08, 0), ring.inner, 0.04, GOLD, Enum.Material.Metal)
	disc(decorations, "PedestalCap", ring.pivot + Vector3.new(0, pedestalHeight + 0.05, 0), ring.pedestalRadius + 0.3, 0.3, GOLD, Enum.Material.Metal)
	for _, sign in { -1, 1 } do
		decor(decorations, "GoldRail", Vector3.new(0.3, 0.7, depth - 4), at(sign * (length / 2 - 2.2), 8, depth / 2), GOLD, Enum.Material.Metal)
		for n = 1, 3 do
			decor(decorations, "WallRib", Vector3.new(1.2, height - 1, 1.6), at(sign * (length / 2 - 2.5), (height - 1) / 2, n * depth / 4), STEEL, Enum.Material.Metal)
		end
		local strip = decor(decorations, "CeilingLight", Vector3.new(1.2, 0.1, depth - 10), at(sign * length / 5, height - 0.1, depth / 2), Color3.fromRGB(255, 226, 170))
		strip.Material = Enum.Material.Neon
	end
	decor(decorations, "GoldRail", Vector3.new(length - 4, 0.7, 0.3), at(0, 8, depth - 2.2), GOLD, Enum.Material.Metal)
	local glow = decor(decorations, "VaultGlow", Vector3.one * 0.2, CFrame.new(ring.pivot + Vector3.new(0, height - 6, 0)), GOLD)
	glow.Transparency = 1
	local light = Instance.new("PointLight")
	light.Color, light.Brightness, light.Range, light.Shadows = Color3.fromRGB(255, 214, 150), 1.2, 40, false
	light.Parent = glow

	-- Codex's interior set, if it has been made: dropped in on the vault frame.
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local kit = assets and assets:FindFirstChild("Vault")
	local set = kit and kit:FindFirstChild(VaultConfig.Art.DecorModelName)
	if set and set:IsA("Model") then
		local copy = set:Clone()
		copy:PivotTo(frame)
		for _, d in copy:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored, d.CanCollide, d.CanQuery, d.CanTouch, d.CastShadow = true, false, false, false, false
			end
		end
		copy.Parent = decorations
	end

	-- THE LASERS. Posed at build time for a client that never animates them.
	local lasers = PartKit.folder("Lasers", vault)
	local now = workspace:GetServerTimeNow()
	for index, arm in VaultConfig.beamsFor(zoneIndex) do
		local sweep = {
			pivot = ring.pivot,
			inner = ring.inner,
			outer = ring.outer,
			height = arm.height,
			period = arm.period,
			phase = arm.phase,
			onSeconds = arm.onSeconds,
			offSeconds = arm.offSeconds,
		}
		local a, b = Geometry.sweepAt(sweep, now)
		local beam = PartKit.bar(lasers, "VaultBeam", a, b, 0.16, LASER, Enum.Material.Neon)
		beam:SetAttribute("ArmIndex", index)
		beam:SetAttribute("Pivot", ring.pivot)
		beam:SetAttribute("Inner", ring.inner)
		beam:SetAttribute("Outer", ring.outer)
		beam:SetAttribute("Height", arm.height)
		beam:SetAttribute("Period", arm.period)
		beam:SetAttribute("Phase", arm.phase)
		if arm.onSeconds and arm.offSeconds then
			beam:SetAttribute("OnSeconds", arm.onSeconds)
			beam:SetAttribute("OffSeconds", arm.offSeconds)
		end
	end

	-- SERVICE ANCHORS.
	local sockets = PartKit.folder("SpawnSockets", vault)
	local socket = marker(sockets, string.format("Socket%02d", Layout.VAULT_SOCKET), CFrame.new(ring.pivot + Vector3.new(0, pedestalHeight - 0.1, 0)))
	socket:SetAttribute("VaultSocket", true)
	-- Asleep just inside, beside the door, facing the pedestal: a thief walks
	-- in behind it.
	marker(vault, "GuardianPost", at(length / 2 - 6, 0.1, 6) * CFrame.Angles(0, math.pi, 0))
end

--- Builds (or rebuilds) every zone's vault. `map` is Workspace.Map.
function VaultBuilder.build(map: Instance)
	local zones = map:FindFirstChild("Zones")
	if not zones then
		return
	end
	for index, def in ZoneConfig.Zones do
		local zone = zones:FindFirstChild(def.id)
		if zone then
			buildVault(zone, index)
		end
	end
end

--- BaseParts in one zone's vault (the part budget check).
function VaultBuilder.partCount(zone: Instance): number
	local vault = zone:FindFirstChild("Vault")
	local n = 0
	if vault then
		for _, d in vault:GetDescendants() do
			if d:IsA("BasePart") then
				n += 1
			end
		end
	end
	return n
end

return VaultBuilder
