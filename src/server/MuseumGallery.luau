--!strict
-- Two enclosed, decorated side rooms around the unchanged progression lane.
-- Shared MuseumLayout owns the doors, display frames and navigation geometry.
--
-- THIS MODULE OWNS THE MUSEUM'S SERVICE ANCHORS. Every zone's eight loot
-- sockets (SpawnSockets.Socket01-08, attributes MuseumSocket + RoomIndex) and
-- its two guardian posts (GuardianSpawns.GuardianPost / GuardianPost02) are
-- created here and nowhere else; MapBuilder only makes the empty folders.
-- LootService, MysterySpawnService, GuardianService and MuseumTests read them
-- by those names.
--
-- PART BUDGET. Everything here replicates to every client (streaming is off
-- on purpose), so a room is built from as few parts as reads the same: one
-- light strip per ceiling row, three stanchions per rope line, one glass shell
-- per case, and no parts that sit entirely inside a wall or another part.
-- `DebugInvoke("museumPartCount")` (DebugCommands/World) reports the totals.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local MysteryModel = require(ReplicatedStorage.Shared.Util.MysteryModel)
local PartKit = require(script.Parent.PartKit)

local MuseumGallery = {}
local GOLD = PartKit.GOLD
local DARK = PartKit.DARK
local IVORY = Color3.fromRGB(217, 209, 188)
local RED = Color3.fromRGB(128, 22, 37)
local TEAL = Color3.fromRGB(61, 234, 224)
local GLASS = Color3.fromRGB(195, 224, 230)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local HEIGHT = Layout.HEIGHT

--- Bumped whenever the generated museum geometry changes, so a Studio session
--- can tell which build it is looking at. Set once, by build(), below.
MuseumGallery.REVISION = 4

-- Stone and wall are a deliberate pair, not a pale blend of the HUD colour.
-- These are appearance values only; the purchased floor part is retained.
local ROOM_PALETTES = {
	{ floor = Color3.fromRGB(226, 192, 188), wall = Color3.fromRGB(213, 169, 169), accent = Color3.fromRGB(114, 51, 51), material = Enum.Material.Marble },
	{ floor = Color3.fromRGB(131, 145, 146), wall = Color3.fromRGB(42, 112, 105), accent = Color3.fromRGB(206, 177, 123), material = Enum.Material.Slate },
	{ floor = Color3.fromRGB(156, 135, 182), wall = Color3.fromRGB(87, 48, 132), accent = Color3.fromRGB(154, 39, 62), material = Enum.Material.Marble },
	{ floor = Color3.fromRGB(151, 160, 164), wall = Color3.fromRGB(91, 103, 62), accent = Color3.fromRGB(235, 120, 38), material = Enum.Material.Concrete },
	{ floor = Color3.fromRGB(210, 232, 240), wall = Color3.fromRGB(159, 205, 221), accent = Color3.fromRGB(160, 35, 56), material = Enum.Material.Marble },
	{ floor = Color3.fromRGB(208, 173, 104), wall = Color3.fromRGB(31, 63, 137), accent = Color3.fromRGB(28, 32, 43), material = Enum.Material.Sandstone },
	{ floor = Color3.fromRGB(64, 70, 82), wall = Color3.fromRGB(36, 91, 181), accent = Color3.fromRGB(193, 205, 214), material = Enum.Material.Slate },
	{ floor = Color3.fromRGB(189, 216, 193), wall = Color3.fromRGB(33, 94, 70), accent = GOLD, material = Enum.Material.Marble },
	{ floor = Color3.fromRGB(217, 231, 221), wall = Color3.fromRGB(85, 146, 57), accent = TEAL, material = Enum.Material.Marble },
	{ floor = Color3.fromRGB(193, 144, 142), wall = Color3.fromRGB(222, 200, 167), accent = Color3.fromRGB(130, 77, 66), material = Enum.Material.Marble },
	{ floor = Color3.fromRGB(141, 142, 135), wall = Color3.fromRGB(194, 147, 36), accent = Color3.fromRGB(72, 88, 104), material = Enum.Material.Concrete },
	{ floor = Color3.fromRGB(67, 87, 116), wall = Color3.fromRGB(39, 62, 76), accent = TEAL, material = Enum.Material.Granite },
}

local folder = PartKit.folder
local part = PartKit.decor
local bar = PartKit.bar

local function plaque(parent: Instance, cf: CFrame, size: Vector3, words: string, color: Color3)
	local plate = part(parent, "ExhibitPlaque", size, cf, DARK)
	local gui = Instance.new("SurfaceGui")
	gui.Face, gui.LightInfluence, gui.PixelsPerStud = Enum.NormalId.Front, 0, 18
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.Parent = plate
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency, text.Size = 1, UDim2.fromScale(0.94, 0.9)
	text.Position = UDim2.fromScale(0.03, 0.05)
	text.Font, text.TextScaled, text.TextColor3 = Enum.Font.GothamBold, true, color
	text.Text, text.Parent = words, gui
end

--- A velvet-rope line: one gold stanchion at each point and a sagging rope
--- between each neighbouring pair. Posts are shared between spans; the old
--- build gave every span its own two posts, which stood two identical posts
--- in the same spot at every joint.
local function ropeLine(parent: Instance, points: { Vector3 })
	for _, at in points do
		local base = part(parent, "StanchionFoot", Vector3.new(0.28, 2.2, 2.2), CFrame.new(at + Vector3.new(0, 0.14, 0)) * CFrame.Angles(0, 0, math.pi / 2), GOLD, Enum.Material.Metal)
		base.Shape = Enum.PartType.Cylinder
		part(parent, "Stanchion", Vector3.new(0.34, 3.3, 0.34), CFrame.new(at + Vector3.new(0, 1.9, 0)), GOLD, Enum.Material.Metal)
		local ball = part(parent, "Finial", Vector3.one * 0.8, CFrame.new(at + Vector3.new(0, 3.7, 0)), GOLD, Enum.Material.Metal)
		ball.Shape = Enum.PartType.Ball
	end
	for n = 1, #points - 1 do
		local topA, topB = points[n] + Vector3.new(0, 3.5, 0), points[n + 1] + Vector3.new(0, 3.5, 0)
		local mid = (topA + topB) / 2 - Vector3.new(0, 0.65, 0)
		bar(parent, "VelvetRope", topA, mid, 0.26, RED, Enum.Material.Fabric)
		bar(parent, "VelvetRope", mid, topB, 0.26, RED, Enum.Material.Fabric)
	end
end

--- The fixed case size for a zone: (span, height) in studs.
---
--- BUILT ONCE, SIZED FOR THE LARGEST CONTAINER. The case used to be torn down
--- and rebuilt (~20 parts and a SurfaceGui) every time a container was added
--- to or removed from its socket - every steal, return and Night refill - and
--- it shrank back to 12 studs the moment a big one was carried off. Now it is
--- sized once for anything the socket can hold:
---   span    LootService caps a socket container's widest side at
---           Layout.displayFootprint(zone) (<= 12). The client turns it on
---           the spot, so its square footprint sweeps a circle of diameter
---           footprint * sqrt(2); +2 is the old fit's clearance.
---   height  MysteryModel.tallestDisplayHeight: the zone's own container at
---           the largest roll under that same cap, +3 as before (seating
---           clearance and the client's idle bob). Held inside the room.
local function caseSize(index: number): (number, number)
	local footprint = Layout.displayFootprint(index)
	local span = math.max(12, footprint * math.sqrt(2) + 2)
	local height = 10
	local tallest = MysteryModel.tallestDisplayHeight(index, footprint)
	if tallest then
		height = math.max(height, tallest + 3)
	end
	-- The socket top is ~5 studs up and the coffers hang ~2 below the ceiling.
	return span, math.min(height, HEIGHT - 10)
end

-- The case around one socket. The loot's scale, pivot, prompt and contents
-- remain owned by LootService; nothing here listens to the socket.
local function vitrine(decor: Instance, socket: BasePart, column: number, wallColor: Color3, span: number, height: number)
	local holder = folder(socket.Name .. "Vitrine", decor)
	local at = socket.Position
	local top = at.Y + socket.Size.Y / 2
	part(holder, "StonePlinth", Vector3.new(span + 1, top, span + 1), CFrame.new(at.X, top / 2, at.Z), wallColor:Lerp(DARK, 0.25), Enum.Material.Plastic)
	part(holder, "PlinthLip", Vector3.new(span + 1.3, 0.18, span + 1.3), CFrame.new(at.X, top, at.Z), GOLD, Enum.Material.Metal)
	-- The gold frame: a ring at the lid and four uprights. (The matching ring
	-- at the base sat directly on the gold lip and is left out.)
	for _, s in { -1, 1 } do
		part(holder, "GoldFrame", Vector3.new(span, 0.2, 0.2), CFrame.new(at.X, top + height, at.Z + s * span / 2), GOLD, Enum.Material.Metal)
		part(holder, "GoldFrame", Vector3.new(0.2, 0.2, span), CFrame.new(at.X + s * span / 2, top + height, at.Z), GOLD, Enum.Material.Metal)
	end
	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			part(holder, "GoldUpright", Vector3.new(0.2, height, 0.2), CFrame.new(at.X + x * span / 2, top + height / 2, at.Z + z * span / 2), GOLD, Enum.Material.Metal)
		end
	end
	-- ONE GLASS SHELL: four walls and the lid in a single transparent part
	-- (it was five panes). It starts on the lip, so its hidden bottom face is
	-- never coplanar with the plinth. Glass never participates in interaction
	-- rays or collisions; the prompt and container remain visible through it.
	local glassHeight = height - 0.1
	local glass = part(holder, "Glass", Vector3.new(span, glassHeight, span), CFrame.new(at.X, top + 0.1 + glassHeight / 2, at.Z), GLASS, Enum.Material.Glass)
	glass.Transparency = 0.9
	-- The label sits proud of the plinth's corridor-facing side. (It used to be
	-- placed 0.25 studs INSIDE that face, so it never showed.)
	local front = if at.X > 0 then -1 else 1
	local labelCf = CFrame.new(at.X + front * ((span + 1) / 2 + 0.06), 1.35, at.Z) * CFrame.Angles(0, -front * math.pi / 2, 0)
	plaque(holder, labelCf, Vector3.new(math.min(span - 1, 13), 1.25, 0.1), string.format("EXHIBIT %02d  /  SEALED", column), GOLD)
end

--- A service anchor: an invisible, inert 1 x 0.2 x 1 marker. Any stale part of
--- the same name is replaced so a rebuild can never leave two.
local function marker(parent: Instance, name: string, cf: CFrame, roomIndex: number): Part
	local stale = parent:FindFirstChild(name)
	if stale then
		stale:Destroy()
	end
	local p = Instance.new("Part")
	p.Name = name
	p.Size, p.CFrame = Vector3.new(1, 0.2, 1), cf
	p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery = true, false, false, false
	p.Transparency, p.CastShadow = 1, false
	p:SetAttribute("RoomIndex", roomIndex)
	p.Parent = parent
	return p
end

local function buildRoom(zone: Instance, index: number, roomIndex: number, caseSpan: number, caseHeight: number)
	local palette = ROOM_PALETTES[index]
	local width, depth = Layout.width(index), Layout.DEPTH
	local doorHeight = Layout.doorHeight(index)
	local frame = Layout.frame(index, roomIndex)
	local room = folder(if roomIndex == 1 then "Left" else "Right", zone.Rooms)
	room:SetAttribute("RoomIndex", roomIndex)
	room:SetAttribute("Width", width)
	room:SetAttribute("Depth", depth)
	room:SetAttribute("DoorWidth", Layout.DOOR_WIDTH)
	room:SetAttribute("DoorHeight", doorHeight)
	local structure = folder("Structure", room)
	local decor = folder("Decorations", room)
	local trim = palette.wall:Lerp(DARK, 0.3)
	local function p(parent: Instance, name: string, size: Vector3, at: Vector3, color: Color3, solid: boolean?): Part
		local piece = part(parent, name, size, frame * CFrame.new(at), color)
		if solid then piece.CanCollide, piece.CanQuery, piece.CastShadow = true, true, true end
		return piece
	end
	-- A central fill covers the space between the side sconces in wider
	-- rooms; all lights are shadowless and statically owned by the room.
	local fill = p(decor, "RoomFill", Vector3.one * 0.2, Vector3.new(0, 24, depth * 0.55), IVORY)
	fill.Transparency = 1
	local light = Instance.new("PointLight")
	light.Color, light.Brightness, light.Range, light.Shadows = Color3.fromRGB(242, 246, 255), if index == 12 then 1.5 elseif index == 1 or index == 5 or index == 10 then 0.7 else 1, 60, false
	light.Parent = fill
	local halfDoor = Layout.DOOR_WIDTH / 2
	-- These are actual walls. Only the permanent open doorway connects the
	-- enclosed room to the corridor. Decorations remain non-queryable.
	-- MuseumTests expects exactly these 7 Structure children.
	p(structure, "RearWall", Vector3.new(width, HEIGHT, 2), Vector3.new(0, HEIGHT / 2, depth - 1), palette.wall, true)
	for _, sign in { -1, 1 } do
		p(structure, "SideWall", Vector3.new(2, HEIGHT, depth), Vector3.new(sign * (width / 2 - 1), HEIGHT / 2, depth / 2), palette.wall, true)
		local wing = width / 2 - halfDoor
		p(structure, "FrontWall", Vector3.new(wing, HEIGHT, 2), Vector3.new(sign * (halfDoor + wing / 2), HEIGHT / 2, 0), palette.wall, true)
		p(decor, "DoorPillar", Vector3.new(3, doorHeight, 4), Vector3.new(sign * (halfDoor + 1.5), doorHeight / 2, -0.5), trim)
		for _, y in { 1.5, 8, doorHeight - 1 } do
			p(decor, "DoorCapital", Vector3.new(4, 2, 5), Vector3.new(sign * (halfDoor + 1.5), y, -0.5), GOLD)
		end
		p(decor, "Dado", Vector3.new(0.3, 0.7, depth - 4), Vector3.new(sign * (width / 2 - 2.2), 8, depth / 2), GOLD)
		p(decor, "Skirting", Vector3.new(0.7, 3, depth - 4), Vector3.new(sign * (width / 2 - 2), 1.5, depth / 2), trim)
		for n = 1, 3 do
			local z = 5 + n * 13
			p(decor, "Pilaster", Vector3.new(2, HEIGHT - 3, 2), Vector3.new(sign * (width / 2 - 2), (HEIGHT - 3) / 2, z), trim)
			-- Gold bracket, elbow and broad downward lamp shade like the video.
			p(decor, "SconceBracket", Vector3.new(0.8, 4, 2), Vector3.new(sign * (width / 2 - 3), 21, z), GOLD)
			p(decor, "SconceArm", Vector3.new(4, 0.7, 0.7), Vector3.new(sign * (width / 2 - 5), 22, z), GOLD)
			p(decor, "SconceShade", Vector3.new(4, 1.2, 4), Vector3.new(sign * (width / 2 - 6), 20, z), GOLD)
			local bulb = p(decor, "SconceGlow", Vector3.new(3.3, 0.2, 3.3), Vector3.new(sign * (width / 2 - 6), 19.3, z), Color3.fromRGB(255, 233, 164))
			bulb.Material = Enum.Material.Neon
			if n == 2 then
				local sconceLight = Instance.new("PointLight")
				sconceLight.Color, sconceLight.Range, sconceLight.Brightness, sconceLight.Shadows = Color3.fromRGB(255, 246, 239), 45, 0.8, false
				sconceLight.Parent = bulb
			end
		end
		-- The rope still runs from z 7 to z 40 along the wall, now on three
		-- stanchions (it was six, two of each pair doubled up).
		local ropeX = sign * (width / 2 - 6)
		ropeLine(decor, {
			frame:PointToWorldSpace(Vector3.new(ropeX, 0, 7)),
			frame:PointToWorldSpace(Vector3.new(ropeX, 0, 23.5)),
			frame:PointToWorldSpace(Vector3.new(ropeX, 0, 40)),
		})
		p(decor, "Planter", Vector3.new(4, 3, 4), Vector3.new(sign * (width / 2 - 6), 1.5, depth - 7), trim)
		for n = 1, 3 do
			p(decor, "Topiary", Vector3.new(5 - n, 2.5, 5 - n), Vector3.new(sign * (width / 2 - 6), 3 + n * 1.2, depth - 7), Color3.fromRGB(64, 151, 63))
		end
	end
	p(structure, "DoorHeader", Vector3.new(Layout.DOOR_WIDTH, HEIGHT - doorHeight, 2), Vector3.new(0, (HEIGHT + doorHeight) / 2, 0), palette.wall, true)
	p(decor, "DoorEntablature", Vector3.new(Layout.DOOR_WIDTH + 10, 3, 6), Vector3.new(0, doorHeight + 1.5, -1), trim)
	plaque(decor, frame * CFrame.new(0, doorHeight + 7, -1.2), Vector3.new(Layout.DOOR_WIDTH + 8, 6, 0.3), string.upper(ZoneConfig.Zones[index].name), GOLD)
	p(structure, "Ceiling", Vector3.new(width, 1, depth), Vector3.new(0, HEIGHT, depth / 2), palette.floor, true)
	-- COFFERS. Ribs and crossbeams only where they can be seen: the outermost
	-- rib of each side lies inside its side wall and the first/last crossbeam
	-- inside the front/rear wall, so those four are not built.
	local bays = math.max(3, math.ceil(width / 24))
	for n = 1, bays - 1 do
		p(decor, "CofferRib", Vector3.new(1.5, 1.5, depth), Vector3.new(-width / 2 + n * width / bays, HEIGHT - 1, depth / 2), trim)
	end
	for n = 0, 2 do
		if n > 0 then
			p(decor, "CofferCrossbeam", Vector3.new(width, 1.5, 1.5), Vector3.new(0, HEIGHT - 1, n * depth / 3), trim)
		end
		-- One light strip per row spanning every bay (it was one panel per
		-- bay); the ribs cross it and still read as separate coffers.
		local strip = p(decor, "CeilingLight", Vector3.new(width - 5, 0.1, depth / 3 - 5), Vector3.new(0, HEIGHT - 0.6, (n + 0.5) * depth / 3), Color3.fromRGB(253, 235, 191))
		strip.Material = Enum.Material.Neon
	end
	for n = 0, bays do
		p(decor, "RearPilaster", Vector3.new(2, HEIGHT - 3, 2), Vector3.new(-width / 2 + 3 + n * (width - 6) / bays, (HEIGHT - 3) / 2, depth - 2), trim)
	end
	p(decor, "RearGoldRail", Vector3.new(width - 4, 0.7, 0.3), Vector3.new(0, 8, depth - 2.3), GOLD)
	-- Flush inlays use the original kit floor beneath them for all collision.
	p(decor, "FloorBorder", Vector3.new(width - 10, 0.025, depth - 10), Vector3.new(0, 0.025, depth / 2), trim)
	local field = p(decor, "FloorField", Vector3.new(width - 12, 0.025, depth - 12), Vector3.new(0, 0.04, depth / 2), palette.floor)
	p(decor, "MedallionBorder", Vector3.new(14, 0.035, 14), Vector3.new(0, 0.07, 22), trim)
	p(decor, "MedallionGold", Vector3.new(8, 0.04, 8), Vector3.new(0, 0.09, 22), GOLD)
	-- Transfer the purchased checker onto the flush decorative floor field.
	for _, texture in zone.Floor:GetChildren() do
		if texture:IsA("Texture") and texture.Face == Enum.NormalId.Top then texture:Clone().Parent = field end
	end
	-- THE SOCKETS. Name, frame and attributes are the contract LootService,
	-- MysterySpawnService and MuseumTests read.
	for column = 1, Layout.ITEMS_PER_ROOM do
		local slot = (roomIndex - 1) * Layout.ITEMS_PER_ROOM + column
		local socket = marker(zone.SpawnSockets, string.format("Socket%02d", slot), Layout.socketFrame(index, slot), roomIndex)
		socket:SetAttribute("MuseumSocket", true)
		vitrine(decor, socket, column, palette.wall, caseSpan, caseHeight)
	end
	-- Both guards sleep in the corridor on the far (+Z) side of their doorway, so
	-- a thief leaving the room always has the guard BEHIND them. The two room
	-- frames are mirrored (room 1 turns -90, room 2 +90), so local +X points to
	-- world +Z in room 1 and world -Z in room 2: the sign has to flip with it.
	-- The frame's look direction is out of the room, so the guard faces across
	-- the corridor with its back to its own room's wall, not into the wall.
	local deeper = if roomIndex == 1 then 1 else -1
	marker(
		zone.GuardianSpawns,
		if roomIndex == 1 then "GuardianPost" else "GuardianPost02",
		frame * CFrame.new(deeper * (halfDoor + 8 + (index - 1)), 0.1, -7),
		roomIndex
	)
	require(script.Parent.MuseumExhibits).build(decor, frame, width, depth, index, palette.accent)
	-- Separate low jump beams and high crouch beams in depth. Later rooms add
	-- alternating half-width diagonals. Every pattern retains endpoint routes.
	local count = Layout.BEAMS[index]
	local rows = math.ceil(count / 2)
	for n = 1, count do
		local row = math.ceil(n / 2)
		local z = 11 + (row - 1) * 24 / math.max(rows - 1, 1)
		local left = n % 2 == 1
		local gap = if index >= 3 then (if row % 2 == 0 then -1 else 1) * math.min(10, index) else 0
		local y = if row % 2 == 1 then 0.8 else 4.5
		local a = frame:PointToWorldSpace(Vector3.new(if left then -width / 2 + 10 else gap + 3, y, z))
		local b = frame:PointToWorldSpace(Vector3.new(if left then gap - 3 else width / 2 - 10, if index >= 6 and row % 3 == 0 then 2.5 else y, z + (if index >= 6 then 3 else 0)))
		local beam = bar(zone.Lasers, "Beam", a, b, 0.16, Color3.fromRGB(255, 35, 49), Enum.Material.Neon)
		beam.CanQuery = true
		beam:SetAttribute("A", a)
		beam:SetAttribute("B", b)
		beam:SetAttribute("ZoneIndex", index)
		beam:SetAttribute("RoomIndex", roomIndex)
		for _, at in { a, b } do
			part(decor, "LaserEmitter", Vector3.new(1, 1, 1), CFrame.new(at), DARK, Enum.Material.Metal)
			part(decor, "EmitterFoot", Vector3.new(1.8, 0.3, 1.8), CFrame.new(at.X, 0.15, at.Z), DARK, Enum.Material.Metal)
			-- The stand runs from the foot (0.3) up to the emitter's centre. For
			-- an emitter at 0.8 or lower that whole run is inside the 1-stud
			-- emitter cube, so the stand is only built where it shows. (Vector3
			-- is float32: 0.8 reads back as 0.80000001, hence the margin.)
			if at.Y > 0.8 + 0.01 then
				bar(decor, "EmitterStand", Vector3.new(at.X, 0.3, at.Z), at, 0.25, DARK, Enum.Material.Metal)
			end
		end
	end
	if index == 12 then
		local plane = folder("SuspendedAirliner", decor)
		p(plane, "Fuselage", Vector3.new(5, 5, 32), Vector3.new(0, 39, 27), IVORY)
		p(plane, "Wings", Vector3.new(38, 0.8, 8), Vector3.new(0, 38, 28), IVORY)
		p(plane, "Tail", Vector3.new(14, 0.8, 5), Vector3.new(0, 40, 40), palette.accent)
		p(plane, "TailFin", Vector3.new(0.8, 7, 6), Vector3.new(0, 43, 39), palette.accent)
		for _, sign in { -1, 1 } do
			p(plane, "Engine", Vector3.new(3, 3, 7), Vector3.new(sign * 10, 36, 28), trim)
			p(plane, "Suspension", Vector3.new(0.15, 24, 0.15), Vector3.new(sign * 10, 51, 28), GOLD)
		end
	end
end

function MuseumGallery.build(map: Instance)
	for index, def in ZoneConfig.Zones do
		local zone = map.Zones:FindFirstChild(def.id)
		if not zone then continue end
		local palette = ROOM_PALETTES[index]
		local length, center = MapConfig.zoneLength(index), MapConfig.zoneCenterZ(index)
		zone:SetAttribute("MuseumGallery", true)
		zone:SetAttribute("MuseumRooms", 2)
		local decor = folder("Decorations", zone)
		-- Keep the Gate anchor/sign, resize its old full-width outdoor lintel
		-- to the corridor and remove the pylons that intruded into the rooms.
		for _, child in zone.Gate:GetChildren() do
			if child:IsA("BasePart") and child.Name ~= "Lintel" then child:Destroy() end
		end
		local lintel = zone.Gate:FindFirstChild("Lintel") :: BasePart?
		if lintel then
			lintel.Size, lintel.CFrame = Vector3.new(44, 6, 2), CFrame.new(0, 53, MapConfig.zoneStartZ(index) + 1)
			lintel.CanQuery = false
			local face = lintel:FindFirstChild("Face")
			local band = face and face:FindFirstChild("Band")
			if band and band:IsA("Frame") then band.Size = UDim2.fromScale(0.9, 0.86) end
		end
		folder("Rooms", zone)
		folder("Lasers", zone)
		zone.Floor.Color, zone.Floor.Material = palette.floor, palette.material
		for _, texture in zone.Floor:GetChildren() do
			if texture:IsA("Texture") and texture.Face == Enum.NormalId.Top then
				texture.Transparency, texture.StudsPerTileU, texture.StudsPerTileV = 0.55, 12, 12
			end
		end
		part(decor, "Runner", Vector3.new(18, 0.035, length), CFrame.new(0, 0.025, center), RED, Enum.Material.Fabric)
		for _, sign in { -1, 1 } do
			part(decor, "RunnerGoldEdge", Vector3.new(0.3, 0.04, length), CFrame.new(sign * 9.2, 0.03, center), GOLD)
		end
		-- Longer zones retain their original travel distance. Facade extensions
		-- close the unused wings without turning the room into a 700-stud hall.
		local shell = folder("Structure", zone)
		local spare = (length - Layout.width(index)) / 2
		for _, side in { -1, 1 } do
			for _, endSign in { -1, 1 } do
				local wall = part(shell, "FacadeExtension", Vector3.new(2, HEIGHT, spare), CFrame.new(side * Layout.CORRIDOR_HALF, HEIGHT / 2, center + endSign * (Layout.width(index) / 2 + spare / 2)), palette.wall)
				wall.CanCollide, wall.CanQuery = true, true
			end
		end
		part(decor, "CorridorCeiling", Vector3.new(Layout.CORRIDOR_HALF * 2, 1, length), CFrame.new(0, HEIGHT, center), palette.floor)
		for n = 1, math.ceil(length / 50) do
			local z = MapConfig.zoneStartZ(index) + (n - 0.5) * length / math.ceil(length / 50)
			part(decor, "CorridorCoffer", Vector3.new(Layout.CORRIDOR_HALF * 2, 1.5, 2), CFrame.new(0, HEIGHT - 1, z), DARK)
		end
		-- Both rooms share one case size, fixed for the life of the server.
		local caseSpan, caseHeight = caseSize(index)
		for room = 1, 2 do buildRoom(zone, index, room, caseSpan, caseHeight) end
	end
	-- The one place the museum revision is recorded.
	map:SetAttribute("MuseumRevision", MuseumGallery.REVISION)
end

return MuseumGallery
