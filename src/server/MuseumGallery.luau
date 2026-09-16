--!strict
-- Two enclosed, decorated side rooms around the unchanged progression lane.
-- Shared MuseumLayout owns the doors, display frames and navigation geometry.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)

local MuseumGallery = {}
local GOLD = Color3.fromRGB(202, 157, 65)
local DARK = Color3.fromRGB(24, 29, 38)
local IVORY = Color3.fromRGB(217, 209, 188)
local RED = Color3.fromRGB(128, 22, 37)
local TEAL = Color3.fromRGB(61, 234, 224)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local HEIGHT = Layout.HEIGHT

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

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name, f.Parent = name, parent
	return f
end

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name, p.Size, p.CFrame = name, size, cf
	p.Color, p.Material = color, material or Enum.Material.Plastic
	p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery = true, false, false, false
	p.CastShadow = false
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Studs, Enum.SurfaceType.Inlet
	p.Parent = parent
	if p.Material == Enum.Material.Plastic then
		p.FrontSurface, p.BackSurface = Enum.SurfaceType.Studs, Enum.SurfaceType.Studs
		p.LeftSurface, p.RightSurface = Enum.SurfaceType.Studs, Enum.SurfaceType.Studs
	end
	return p
end

local function bar(parent: Instance, name: string, a: Vector3, b: Vector3, width: number, color: Color3, material: Enum.Material?): Part
	return part(parent, name, Vector3.new(width, width, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), color, material)
end

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

local function rope(parent: Instance, a: Vector3, b: Vector3)
	for _, at in { a, b } do
		local base = part(parent, "StanchionFoot", Vector3.new(0.28, 2.2, 2.2), CFrame.new(at + Vector3.new(0, 0.14, 0)) * CFrame.Angles(0, 0, math.pi / 2), GOLD, Enum.Material.Metal)
		base.Shape = Enum.PartType.Cylinder
		part(parent, "Stanchion", Vector3.new(0.34, 3.3, 0.34), CFrame.new(at + Vector3.new(0, 1.9, 0)), GOLD, Enum.Material.Metal)
		local ball = part(parent, "Finial", Vector3.one * 0.8, CFrame.new(at + Vector3.new(0, 3.7, 0)), GOLD, Enum.Material.Metal)
		ball.Shape = Enum.PartType.Ball
	end
	local topA, topB = a + Vector3.new(0, 3.5, 0), b + Vector3.new(0, 3.5, 0)
	local mid = (topA + topB) / 2 - Vector3.new(0, 0.65, 0)
	bar(parent, "VelvetRope", topA, mid, 0.26, RED, Enum.Material.Fabric)
	bar(parent, "VelvetRope", mid, topB, 0.26, RED, Enum.Material.Fabric)
end

-- Only the case fits the roll. The loot's scale, pivot, prompt and contents
-- remain owned by LootService. A circular clearance fits its client idle turn.
local function vitrine(decor: Instance, socket: BasePart, index: number, wallColor: Color3)
	local holder = folder(socket.Name .. "Vitrine", decor)
	local scheduled = false
	local function fit()
		scheduled = false
		if not socket.Parent then return end
		local span, height = 12, 10
		for _, child in socket:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("LootId") then
				local low, high = LootModel.visibleExtents(child)
				if low and high then
					local size = high - low
					span = math.max(span, Vector2.new(size.X, size.Z).Magnitude + 2)
					height = math.max(height, size.Y + 3)
				end
			end
		end
		holder:ClearAllChildren()
		local at = socket.Position
		local top = at.Y + socket.Size.Y / 2
		part(holder, "StonePlinth", Vector3.new(span + 1, top, span + 1), CFrame.new(at.X, top / 2, at.Z), wallColor:Lerp(DARK, 0.25), Enum.Material.Plastic)
		part(holder, "PlinthLip", Vector3.new(span + 1.3, 0.18, span + 1.3), CFrame.new(at.X, top, at.Z), GOLD, Enum.Material.Metal)
		for _, y in { top + 0.25, top + height } do
			for _, s in { -1, 1 } do
				part(holder, "GoldFrame", Vector3.new(span, 0.2, 0.2), CFrame.new(at.X, y, at.Z + s * span / 2), GOLD, Enum.Material.Metal)
				part(holder, "GoldFrame", Vector3.new(0.2, 0.2, span), CFrame.new(at.X + s * span / 2, y, at.Z), GOLD, Enum.Material.Metal)
			end
		end
		for _, x in { -1, 1 } do
			for _, z in { -1, 1 } do
				part(holder, "GoldUpright", Vector3.new(0.2, height, 0.2), CFrame.new(at.X + x * span / 2, top + height / 2, at.Z + z * span / 2), GOLD, Enum.Material.Metal)
			end
			local pane = part(holder, "Glass", Vector3.new(0.1, height, span), CFrame.new(at.X + x * span / 2, top + height / 2, at.Z), Color3.fromRGB(195, 224, 230), Enum.Material.Glass)
			pane.Transparency = 0.88
		end
		-- Glass never participates in interaction rays or collisions. The
		-- unchanged prompt and sealed-container card remain visible through it.
		for _, side in { -1, 1 } do
			local glass = part(holder, "GlassEnd", Vector3.new(span, height, 0.1), CFrame.new(at.X, top + height / 2, at.Z + side * span / 2), IVORY, Enum.Material.Glass)
			glass.Transparency = 0.94
		end
		local lid = part(holder, "GlassLid", Vector3.new(span, 0.1, span), CFrame.new(at.X, top + height, at.Z), IVORY, Enum.Material.Glass)
		lid.Transparency = 0.94
		local front = if at.X > 0 then -1 else 1
		local labelCf = CFrame.new(at.X + front * (span / 2 + 0.25), 1.35, at.Z) * CFrame.Angles(0, -front * math.pi / 2, 0)
		plaque(holder, labelCf, Vector3.new(math.min(span - 1, 13), 1.25, 0.1), string.format("EXHIBIT %02d  /  SEALED", index), GOLD)
	end
	local function queue()
		if scheduled then return end
		scheduled = true
		task.defer(fit)
	end
	socket.ChildAdded:Connect(queue)
	socket.ChildRemoved:Connect(queue)
	fit()
end

local function buildRoom(zone: Instance, index: number, roomIndex: number)
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
				local light = Instance.new("PointLight")
				light.Color, light.Range, light.Brightness, light.Shadows = Color3.fromRGB(255, 246, 239), 45, 0.8, false
				light.Parent = bulb
			end
		end
		for n = 0, 2 do
			rope(decor, frame:PointToWorldSpace(Vector3.new(sign * (width / 2 - 6), 0, 7 + n * 11)), frame:PointToWorldSpace(Vector3.new(sign * (width / 2 - 6), 0, 18 + n * 11)))
		end
		p(decor, "Planter", Vector3.new(4, 3, 4), Vector3.new(sign * (width / 2 - 6), 1.5, depth - 7), trim)
		for n = 1, 3 do
			p(decor, "Topiary", Vector3.new(5 - n, 2.5, 5 - n), Vector3.new(sign * (width / 2 - 6), 3 + n * 1.2, depth - 7), Color3.fromRGB(64, 151, 63))
		end
	end
	p(structure, "DoorHeader", Vector3.new(Layout.DOOR_WIDTH, HEIGHT - doorHeight, 2), Vector3.new(0, (HEIGHT + doorHeight) / 2, 0), palette.wall, true)
	p(decor, "DoorEntablature", Vector3.new(Layout.DOOR_WIDTH + 10, 3, 6), Vector3.new(0, doorHeight + 1.5, -1), trim)
	plaque(decor, frame * CFrame.new(0, doorHeight + 7, -1.2), Vector3.new(Layout.DOOR_WIDTH + 8, 6, 0.3), string.upper(ZoneConfig.Zones[index].name), GOLD)
	p(structure, "Ceiling", Vector3.new(width, 1, depth), Vector3.new(0, HEIGHT, depth / 2), palette.floor, true)
	local bays = math.max(3, math.ceil(width / 24))
	for n = 0, bays do
		p(decor, "CofferRib", Vector3.new(1.5, 1.5, depth), Vector3.new(-width / 2 + n * width / bays, HEIGHT - 1, depth / 2), trim)
	end
	for n = 0, 3 do
		p(decor, "CofferCrossbeam", Vector3.new(width, 1.5, 1.5), Vector3.new(0, HEIGHT - 1, n * depth / 3), trim)
		if n < 3 then
			for bay = 1, bays do
				local panel = p(decor, "CeilingLight", Vector3.new(width / bays - 5, 0.1, depth / 3 - 5), Vector3.new(-width / 2 + (bay - 0.5) * width / bays, HEIGHT - 0.6, (n + 0.5) * depth / 3), Color3.fromRGB(253, 235, 191))
				panel.Material = Enum.Material.Neon
			end
		end
	end
	for n = 0, bays do
		p(decor, "RearPilaster", Vector3.new(2, HEIGHT - 3, 2), Vector3.new(-width / 2 + 3 + n * (width - 6) / bays, (HEIGHT - 3) / 2, depth - 2), trim)
	end
	p(decor, "RearGoldRail", Vector3.new(width - 4, 0.7, 0.3), Vector3.new(0, 8, depth - 2.3), GOLD)
	-- Flush inlays use the original kit floor beneath them for all collision.
	p(decor, "FloorBorder", Vector3.new(width - 10, 0.025, depth - 10), Vector3.new(0, 0.025, depth / 2), trim)
	p(decor, "FloorField", Vector3.new(width - 12, 0.025, depth - 12), Vector3.new(0, 0.04, depth / 2), palette.floor)
	p(decor, "MedallionBorder", Vector3.new(14, 0.035, 14), Vector3.new(0, 0.07, 22), trim)
	p(decor, "MedallionGold", Vector3.new(8, 0.04, 8), Vector3.new(0, 0.09, 22), GOLD)
	-- Transfer the purchased checker onto the flush decorative floor field.
	local field = decor.FloorField
	for _, texture in zone.Floor:GetChildren() do
		if texture:IsA("Texture") and texture.Face == Enum.NormalId.Top then texture:Clone().Parent = field end
	end
	for column = 1, Layout.ITEMS_PER_ROOM do
		local slot = (roomIndex - 1) * Layout.ITEMS_PER_ROOM + column
		local socket = zone.SpawnSockets:FindFirstChild(string.format("Socket%02d", slot)) :: BasePart?
		if not socket then
			socket = Instance.new("Part")
			socket.Name = string.format("Socket%02d", slot)
			socket.Parent = zone.SpawnSockets
		end
		socket:ClearAllChildren()
		socket.Size, socket.CFrame = Vector3.new(1, 0.2, 1), Layout.socketFrame(index, slot)
		socket.Anchored, socket.CanCollide, socket.CanTouch, socket.CanQuery, socket.Transparency = true, false, false, false, 1
		socket:SetAttribute("MuseumSocket", true)
		socket:SetAttribute("RoomIndex", roomIndex)
		vitrine(decor, socket, column, palette.wall)
	end
	local post = zone.GuardianSpawns:FindFirstChild(if roomIndex == 1 then "GuardianPost" else "GuardianPost02") :: BasePart?
	if not post then
		post = Instance.new("Part")
		post.Name, post.Parent = "GuardianPost02", zone.GuardianSpawns
	end
	-- Both guards sleep in the corridor on the far (+Z) side of their doorway, so
	-- a thief leaving the room always has the guard BEHIND them. The two room
	-- frames are mirrored (room 1 turns -90, room 2 +90), so local +X points to
	-- world +Z in room 1 and world -Z in room 2: the sign has to flip with it.
	-- The frame's look direction is out of the room, so the guard faces across
	-- the corridor with its back to its own room's wall, not into the wall.
	local deeper = if roomIndex == 1 then 1 else -1
	post.Size, post.CFrame = Vector3.new(1, 0.2, 1), frame * CFrame.new(deeper * (halfDoor + 8 + (index - 1)), 0.1, -7)
	post.Anchored, post.CanCollide, post.CanTouch, post.CanQuery, post.Transparency = true, false, false, false, 1
	post:SetAttribute("RoomIndex", roomIndex)
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
			bar(decor, "EmitterStand", Vector3.new(at.X, 0.3, at.Z), at, 0.25, DARK, Enum.Material.Metal)
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
		for room = 1, 2 do buildRoom(zone, index, room) end
	end
	map:SetAttribute("MuseumRevision", 3)
end

return MuseumGallery
