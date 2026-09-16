--!strict
-- The galleries are dressing around the existing twelve bands, never another
-- corridor. No economy or reward information belongs in this module.
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
local HEIGHT = 72

-- Stone and wall are a deliberate pair, not a pale blend of the HUD colour.
-- These are appearance values only; the purchased floor part is retained.
local ROOM_PALETTES = {
	{ floor = Color3.fromRGB(226, 192, 188), wall = Color3.fromRGB(190, 142, 96), accent = Color3.fromRGB(114, 51, 51), material = Enum.Material.Marble },
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
	p.Color, p.Material = color, material or Enum.Material.SmoothPlastic
	p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery = true, false, false, false
	p.CastShadow = false
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Parent = parent
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
local function vitrine(decor: Instance, socket: BasePart, index: number, wallColor: Color3, accent: Color3)
	local holder = folder(socket.Name .. "Vitrine", decor)
	local scheduled = false
	local function fit()
		scheduled = false
		if not socket.Parent then return end
		local span, height = 12, 11
		for _, child in socket:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("LootId") then
				local low, high = LootModel.visibleExtents(child)
				if low and high then
					local size = high - low
					span = math.max(span, Vector2.new(size.X, size.Z).Magnitude + 3)
					height = math.max(height, size.Y + 3)
				end
			end
		end
		holder:ClearAllChildren()
		local at = socket.Position
		local top = at.Y + socket.Size.Y / 2
		-- The vitrine sits INSIDE this recess, including large rolls. Its side
		-- returns extend from the wall to the approach side of the case, with
		-- four-stud masonry reveals rather than thin panels behind the loot.
		local sign = if at.X > 0 then 1 else -1
		local frontX = math.max(6, math.abs(at.X) - span / 2 - 2)
		-- WORLD_MAX_FOOTPRINT rolls can put the rotating case right against
		-- the outer wall. Fit its masonry too, leaving the centre spine open.
		local backX = math.max(79, math.abs(at.X) + span / 2 + 2)
		local opening = math.max(24, span + 6)
		local nicheHeight = math.max(28, top + height + 2)
		for _, side in { -1, 1 } do
			part(holder, "AlcoveCheek", Vector3.new(backX - frontX, nicheHeight, 4), CFrame.new(sign * (frontX + backX) / 2, nicheHeight / 2, at.Z + side * (opening / 2 + 2)), wallColor, Enum.Material.Marble)
			part(holder, "AlcoveGold", Vector3.new(0.7, nicheHeight, 4.4), CFrame.new(sign * frontX, nicheHeight / 2, at.Z + side * (opening / 2 + 2)), GOLD, Enum.Material.Metal)
		end
		part(holder, "AlcoveBack", Vector3.new(1, nicheHeight, opening), CFrame.new(sign * (backX - 0.5), nicheHeight / 2, at.Z), accent)
		part(holder, "AlcoveCrown", Vector3.new(backX - frontX, 2, opening + 8), CFrame.new(sign * (frontX + backX) / 2, nicheHeight + 1, at.Z), wallColor, Enum.Material.Marble)
		part(holder, "StonePlinth", Vector3.new(span + 1, top, span + 1), CFrame.new(at.X, top / 2, at.Z), DARK, Enum.Material.Slate)
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

local function bench(parent: Instance, x: number, z: number)
	part(parent, "BenchSeat", Vector3.new(4, 0.6, 13), CFrame.new(x, 2.4, z), Color3.fromRGB(88, 46, 36), Enum.Material.Wood)
	for _, s in { -1, 1 } do
		part(parent, "BenchFoot", Vector3.new(3.5, 2.2, 0.5), CFrame.new(x, 1.1, z + s * 4.5), GOLD, Enum.Material.Metal)
	end
end

local function planter(parent: Instance, x: number, z: number, tint: Color3)
	part(parent, "Planter", Vector3.new(4, 3, 4), CFrame.new(x, 1.5, z), IVORY, Enum.Material.Marble)
	local bush = part(parent, "Topiary", Vector3.new(5, 5, 5), CFrame.new(x, 5, z), tint, Enum.Material.Grass)
	bush.Shape = Enum.PartType.Ball
end

local function statue(parent: Instance, x: number, z: number)
	part(parent, "StatuePlinth", Vector3.new(5, 4, 5), CFrame.new(x, 2, z), DARK, Enum.Material.Slate)
	part(parent, "GiltBust", Vector3.new(4.5, 4, 2.6), CFrame.new(x, 6, z), GOLD, Enum.Material.Metal)
	local head = part(parent, "GiltHead", Vector3.new(2.6, 3.1, 2.6), CFrame.new(x, 9, z), GOLD, Enum.Material.Metal)
	head.Shape = Enum.PartType.Ball
end

local function doorway(zone: Instance, index: number, z0: number, tint: Color3, accent: Color3)
	local portal = folder("Doorway", zone.Gate)
	local halfOpening = 28 -- 56 clear studs, centred on the unchanged runner
	local clearHeight = ({ 24, 24, 26, 26, 28, 30, 32, 34, 38, 40, 44, 46 })[index]
	portal:SetAttribute("ClearWidth", halfOpening * 2)
	portal:SetAttribute("ClearHeight", clearHeight)
	local sideWidth = MapConfig.LANE_HALF - halfOpening
	for _, s in { -1, 1 } do
		part(portal, "ReturnWall", Vector3.new(sideWidth, HEIGHT, 4), CFrame.new(s * (halfOpening + sideWidth / 2), HEIGHT / 2, z0 + 2), tint, Enum.Material.Marble)
		part(portal, "JambPilaster", Vector3.new(5, clearHeight, 6), CFrame.new(s * (halfOpening + 3), clearHeight / 2, z0 + 2), accent, Enum.Material.Marble)
		for _, y in { 1, clearHeight - 1 } do
			part(portal, "JambBand", Vector3.new(6, 2, 7), CFrame.new(s * (halfOpening + 3), y, z0 + 2), GOLD, Enum.Material.Metal)
		end
	end
	part(portal, "Header", Vector3.new(halfOpening * 2, HEIGHT - clearHeight, 4), CFrame.new(0, (HEIGHT + clearHeight) / 2, z0 + 2), tint, Enum.Material.Marble)
	part(portal, "HeaderGold", Vector3.new(halfOpening * 2, 0.7, 6), CFrame.new(0, clearHeight + 0.35, z0 + 2), GOLD, Enum.Material.Metal)
end

local function laser(parent: Instance, a: Vector3, b: Vector3, puck: boolean)
	local beam = bar(parent, "Beam", a, b, 0.14, Color3.fromRGB(255, 35, 49), Enum.Material.Neon)
	beam.CanQuery = true
	beam:SetAttribute("A", a)
	beam:SetAttribute("B", b)
	for _, at in { a, b } do
		if puck then
			local base = part(parent, "FloorEmitter", Vector3.new(0.35, 2.4, 2.4), CFrame.new(at.X, 0.25, at.Z) * CFrame.Angles(0, 0, math.pi / 2), DARK, Enum.Material.Metal)
			base.Shape = Enum.PartType.Cylinder
			local lens = part(parent, "TealLens", Vector3.new(0.12, 1.8, 1.8), base.CFrame + Vector3.new(0, 0.25, 0), TEAL, Enum.Material.Neon)
			lens.Shape = Enum.PartType.Cylinder
			if at.Y > 0.8 then bar(parent, "EmitterStem", Vector3.new(at.X, 0.4, at.Z), at, 0.3, DARK) end
		else
			part(parent, "WallEmitter", Vector3.new(1.2, 1.4, 1.4), CFrame.new(at), DARK, Enum.Material.Metal)
		end
	end
end

local function lasers(zone: Instance, index: number)
	local field = folder("Lasers", zone)
	if index < 3 then return end
	local z0 = MapConfig.zoneStartZ(index)
	if index <= 5 then
		-- The east bypass is always 18 studs wide. Staggering depth makes low,
		-- middle and high beams readable independently instead of a red wall.
		for n, y in { 0.8, 2.5, 4.5 } do
			local z = z0 + 18 + n * 8
			laser(field, Vector3.new(-77, y, z), Vector3.new(60, y, z), false)
		end
	else
		local count = if index <= 8 then 6 else 12
		for n = 1, count do
			local sign = if n % 2 == 0 then 1 else -1
			local row = math.ceil(n / 2)
			local z = z0 + MapConfig.zoneLength(index) * (0.18 + (row - 1) * 0.64 / math.max(count / 2 - 1, 1))
			local height = ({ 4.5, 0.8, 2.5 })[(row - 1) % 3 + 1]
			-- A twelve-stud spine remains free. Cases are outside it, so stealing
			-- still asks the player to negotiate the field on the way in and out.
			laser(field, Vector3.new(sign * 8, height, z - 9), Vector3.new(sign * 76, 0.65, z + 9), true)
		end
	end
end

function MuseumGallery.build(map: Instance)
	for _, run in map.Walls:GetChildren() do
		local index = tonumber(run.Name:match("^Zone(%d+)_")) or (if run.Name == "WorldEnd" then 12 else nil)
		if not index then continue end
		for _, p in run:GetDescendants() do
			if p:IsA("BasePart") and p.Name == "Cap" then
				p.Color, p.Material = GOLD, Enum.Material.Metal
			elseif p:IsA("BasePart") and p.Name == "Body" then
				p.Color = ROOM_PALETTES[index].wall
				for _, texture in p:GetChildren() do
					if texture:IsA("Texture") then texture.Transparency = 0.88 end
				end
			end
		end
	end
	for index, def in ZoneConfig.Zones do
		local zone = map.Zones:FindFirstChild(def.id)
		if not zone then continue end
		local decor = folder("Decorations", zone)
		local z0, length = MapConfig.zoneStartZ(index), MapConfig.zoneLength(index)
		local center = z0 + length / 2
		local palette = ROOM_PALETTES[index]
		local tint = palette.wall
		local floor = zone.Floor :: BasePart
		floor.Color, floor.Material = palette.floor, palette.material
		for _, texture in floor:GetChildren() do
			if texture:IsA("Texture") and texture.Face == Enum.NormalId.Top then
				texture.Transparency = 0.55
				texture.StudsPerTileU, texture.StudsPerTileV = 12, 12
			end
		end
		zone:SetAttribute("MuseumGallery", true)
		-- A surface treatment, not a raised walkway: the kit remains the only
		-- walkable floor, at Y=0 all the way from the lobby to the final hall.
		part(decor, "Runner", Vector3.new(20, 0.04, length), CFrame.new(0, 0.025, center), RED, Enum.Material.Fabric)
		for _, s in { -1, 1 } do
			part(decor, "RunnerGoldEdge", Vector3.new(0.35, 0.05, length), CFrame.new(s * 10.25, 0.03, center), GOLD)
			part(decor, "UpperWall", Vector3.new(1, HEIGHT - MapConfig.WALL_HEIGHT, length), CFrame.new(s * 80, (HEIGHT + MapConfig.WALL_HEIGHT) / 2, center), tint)
			part(decor, "Cornice", Vector3.new(2.5, 1.5, length), CFrame.new(s * 78.5, HEIGHT - 2, center), GOLD)
			part(decor, "Dado", Vector3.new(0.7, 1.2, length), CFrame.new(s * 79.2, 9, center), GOLD)
			part(decor, "CeilingWing", Vector3.new(52, 1, length), CFrame.new(s * 54, HEIGHT, center), tint)
			part(decor, "CollectionBackdrop", Vector3.new(1, 34, if index == 1 then 12 else 28), CFrame.new(s * 78.5, 18, center), palette.accent)
		end
		local bays = math.max(2, math.ceil(length / (82 - index * 3)))
		for bay = 0, bays do
			local z = z0 + 3 + (length - 6) * bay / bays
			part(decor, "CofferBeam", Vector3.new(158, 1.4, 1.3), CFrame.new(0, HEIGHT - 1, z), IVORY)
			if bay < bays then
				local light = part(decor, "Skylight", Vector3.new(53, 0.3, (length - 6) / bays - 2), CFrame.new(0, HEIGHT + 1, z + (length - 6) / bays / 2), Color3.fromRGB(218, 234, 242), Enum.Material.Glass)
				light.Transparency = 0.55
			end
			for _, s in { -1, 1 } do
				local x = s * 76
				part(decor, "Pilaster", Vector3.new(3, HEIGHT - 4, 3), CFrame.new(x, (HEIGHT - 4) / 2, z), tint, Enum.Material.Marble)
				for _, y in { 1, 12, HEIGHT - 5 } do part(decor, "ColumnBand", Vector3.new(4.4, 1, 4.4), CFrame.new(x, y, z), GOLD, Enum.Material.Metal) end
				part(decor, "SconceBack", Vector3.new(0.5, 5, 2), CFrame.new(x - s * 2, 17, z), GOLD, Enum.Material.Metal)
				local bulb = part(decor, "Sconce", Vector3.new(1, 2.8, 1), CFrame.new(x - s * 2.7, 17, z), Color3.fromRGB(255, 216, 146), Enum.Material.Neon)
				-- No shadow-casting lights. Every other bay is enough to colour the
				-- wall; skylights and the existing environment grade light the floor.
				if bay % 2 == 0 then
					local glow = Instance.new("PointLight")
					glow.Color, glow.Range, glow.Brightness, glow.Shadows = bulb.Color, 24, 0.7, false
					glow.Parent = bulb
				end
				local clearOfExhibits = math.abs(z - center) > 20
					and math.abs(z - (z0 + length * 0.25)) > 24 and math.abs(z - (z0 + length * 0.75)) > 24
				if bay > 0 and bay < bays and clearOfExhibits then
					if index >= 5 and bay % 3 == 0 then statue(decor, s * 70, z)
					elseif bay % 2 == 0 then bench(decor, s * 70, z)
					else planter(decor, s * 70, z, Color3.fromRGB(57, 104, 64):Lerp(def.color, 0.22)) end
				end
			end
		end
		for n = 1, 4 do
			local socket = zone.SpawnSockets:FindFirstChild(string.format("Socket%02d", n)) :: BasePart
			local sign = if n % 2 == 0 then 1 else -1
			local z = z0 + length * (if n <= 2 then 0.25 else 0.75)
			socket.CFrame = CFrame.new(sign * 44, 2.1, z)
			socket:SetAttribute("MuseumSocket", true)
			vitrine(decor, socket, n, tint, palette.accent)
			rope(decor, Vector3.new(sign * 63, 0, z - 12), Vector3.new(sign * 63, 0, z + 12))
		end
		doorway(zone, index, z0, tint, palette.accent)
		require(script.Parent.MuseumExhibits).build(decor, center, index, palette.accent)
		lasers(zone, index)
		if index == 12 then
			-- A terminal conservatory: a suspended aircraft, brass ribs, departure
			-- windows and runway inlays. All above/beside the original flat floor.
			local exhibit = folder("TerminalAtrium", decor)
			local at = Vector3.new(0, 53, center)
			local body = part(exhibit, "SuspendedAirliner", Vector3.new(8, 8, 72), CFrame.new(at), IVORY, Enum.Material.Metal)
			body.Shape = Enum.PartType.Cylinder
			body.CFrame *= CFrame.Angles(0, math.pi / 2, 0)
			body.Size = Vector3.new(136, 12, 12)
			part(exhibit, "Wings", Vector3.new(112, 1.5, 25), CFrame.new(at + Vector3.new(0, -1, 0)), GOLD, Enum.Material.Metal)
			part(exhibit, "Tailplane", Vector3.new(39, 1, 12), CFrame.new(at + Vector3.new(0, 1, 57)), IVORY)
			part(exhibit, "TailFin", Vector3.new(1, 11, 18), CFrame.new(at + Vector3.new(0, 6, 55)), def.color)
			part(exhibit, "Cockpit", Vector3.new(8, 3, 1), CFrame.new(at + Vector3.new(0, 2, -68)), TEAL, Enum.Material.Glass)
			for _, s in { -1, 1 } do
				local engine = part(exhibit, "Engine", Vector3.new(13, 7, 7), CFrame.new(at + Vector3.new(s * 30, -5, -5)) * CFrame.Angles(0, math.pi / 2, 0), IVORY, Enum.Material.Metal)
				engine.Shape = Enum.PartType.Cylinder
				bar(exhibit, "Suspension", at + Vector3.new(s * 27, 0, 0), Vector3.new(s * 27, HEIGHT, center), 0.25, GOLD)
			end
			for n = 1, 10 do
				local z = z0 + n * length / 11
				for _, s in { -1, 1 } do
					bar(exhibit, "TerminalRoofRib", Vector3.new(s * 76, 42, z), Vector3.new(0, HEIGHT - 2, z), 1.2, GOLD, Enum.Material.Metal)
					part(exhibit, "RunwayInset", Vector3.new(1, 0.06, 7), CFrame.new(s * 13, 0.04, z), TEAL, Enum.Material.Neon)
					local window = part(exhibit, "DepartureWindow", Vector3.new(0.3, 35, 27), CFrame.new(s * 79, 48, z), Color3.fromRGB(133, 199, 219), Enum.Material.Glass)
					window.Transparency = 0.3
				end
			end
			for _, s in { -1, 1 } do
				plaque(exhibit, CFrame.new(s * 54, 25, z0 + 105), Vector3.new(37, 14, 1), "DEPARTURES\n12  /  FINAL GALLERY\nSTEAL. RUN. ESCAPE.", GOLD)
			end
			plaque(exhibit, CFrame.new(0, 35, MapConfig.zoneEndZ(index) - 2), Vector3.new(70, 10, 1), "THE GRAND TERMINAL\nEND OF THE COLLECTION", GOLD)
		end
	end
end

return MuseumGallery
