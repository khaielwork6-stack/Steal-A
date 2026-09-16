--!strict
-- Two large collection silhouettes per room. These are scenery, not loot:
-- no prompts, rewards, physics, lights or per-frame work.
local Exhibits = {}
local GOLD = Color3.fromRGB(202, 157, 65)
local DARK = Color3.fromRGB(24, 29, 38)
local WHITE = Color3.fromRGB(226, 228, 217)
local WOOD = Color3.fromRGB(98, 58, 37)

function Exhibits.build(parent: Instance, roomFrame: CFrame, roomWidth: number, roomDepth: number, index: number, accent: Color3)
	local collection = Instance.new("Folder")
	collection.Name, collection.Parent = "CollectionExhibits", parent
	for side = 1, 2 do
		local model = Instance.new("Model")
		model.Name, model.Parent = "Exhibit" .. side, collection
		local frame = roomFrame * (if side == 1 then CFrame.new(0, 0, roomDepth - 11)
			else CFrame.new(roomWidth / 2 - 10, 0, 22) * CFrame.Angles(0, -math.pi / 2, 0))
		local function p(name: string, size: Vector3, cf: CFrame, color: Color3, shape: Enum.PartType?): Part
			local piece = Instance.new("Part")
			piece.Name, piece.Size, piece.CFrame = name, size * 0.65, frame * CFrame.new(cf.Position * 0.65) * cf.Rotation
			piece.Color, piece.Material = color, Enum.Material.Plastic
			piece.Anchored, piece.CanCollide, piece.CanTouch, piece.CanQuery, piece.CastShadow = true, false, false, false, false
			piece.TopSurface, piece.BottomSurface = Enum.SurfaceType.Studs, Enum.SurfaceType.Inlet
			piece.FrontSurface, piece.BackSurface = Enum.SurfaceType.Studs, Enum.SurfaceType.Studs
			if shape == Enum.PartType.Ball then
				-- A primitive Ball renders a sphere at the shortest dimension.
				-- A built-in sphere mesh preserves these ellipsoid silhouettes.
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType = Enum.MeshType.Sphere
				mesh.Parent = piece
			elseif shape then piece.Shape = shape end
			piece.Parent = model
			return piece
		end
		local function rod(name: string, a: Vector3, b: Vector3, width: number, color: Color3)
			return p(name, Vector3.new(width, width, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), color)
		end
		local function disk(name: string, diameter: number, depth: number, at: Vector3, color: Color3, upright: boolean?): Part
			return p(name, Vector3.new(depth, diameter, diameter), CFrame.new(at) * CFrame.Angles(0, if upright then math.pi / 2 else 0, if upright then 0 else math.pi / 2), color, Enum.PartType.Cylinder)
		end
		p("CollectionPlinth", Vector3.new(if index == 1 then 10 else 24, 2, if index == 1 then 8 else 16), CFrame.new(0, 1, 0), DARK).Material = Enum.Material.Slate
		if index == 1 then
			if side == 1 then
				model.Name = "WhiteMuseumStatue"
				p("StatuePedestal", Vector3.new(10, 5, 9), CFrame.new(0, 4, 0), WHITE)
				p("Torso", Vector3.new(6, 7, 3), CFrame.new(0, 14, 0), WHITE)
				p("Head", Vector3.new(4, 4, 4), CFrame.new(0, 20, 0), WHITE)
				for _, sign in { -1, 1 } do
					p("Leg", Vector3.new(2.5, 6, 3), CFrame.new(sign * 1.6, 8, 0), WHITE)
					p("Arm", Vector3.new(2, 7, 3), CFrame.new(sign * 4.2, 14, 0), WHITE)
				end
			else
				model.Name = "CarvedAntiquity"
				p("Stele", Vector3.new(9, 19, 5), CFrame.new(0, 11.5, 0), WOOD).Material = Enum.Material.Sandstone
				for n = 1, 4 do p("Inscription", Vector3.new(6, 0.7, 0.3), CFrame.new(0, 5 + n * 3, -2.6), GOLD) end
			end
		elseif index == 2 then
			if side == 1 then
				model.Name = "MaritimeSailingShip"
				p("Hull", Vector3.new(23, 7, 9), CFrame.new(0, 5.5, 0), WOOD, Enum.PartType.Ball)
				p("Deck", Vector3.new(21, 1, 8), CFrame.new(0, 8, 0), accent)
				p("Mast", Vector3.new(0.8, 23, 0.8), CFrame.new(0, 18, 0), WOOD)
				p("Canvas", Vector3.new(15, 13, 0.5), CFrame.new(0, 21, 0), WHITE)
				for _, s in { -1, 1 } do rod("Rigging", Vector3.new(0, 29, 0), Vector3.new(s * 10, 8, 0), 0.2, accent) end
			else
				model.Name = "AdmiraltyAnchor"
				p("Shank", Vector3.new(2, 21, 2), CFrame.new(0, 14, 0), DARK)
				p("Stock", Vector3.new(18, 2, 2), CFrame.new(0, 18, 0), accent)
				for _, s in { -1, 1 } do
					rod("Fluke", Vector3.new(0, 4, 0), Vector3.new(s * 8, 11, 0), 2.4, DARK)
					p("FlukeTip", Vector3.new(4, 3, 3), CFrame.new(s * 8, 11, 0), GOLD)
				end
				disk("AnchorEye", 5, 1, Vector3.new(0, 26, 0), GOLD, true)
			end
		elseif index == 3 then
			if side == 1 then
				model.Name = "RoyalThrone"
				p("VelvetBack", Vector3.new(13, 23, 3), CFrame.new(0, 15, 3), accent)
				p("Seat", Vector3.new(13, 3, 10), CFrame.new(0, 7, -1), accent)
				for _, s in { -1, 1 } do
					p("ThronePost", Vector3.new(1.4, 26, 1.4), CFrame.new(s * 7, 15, 3), GOLD)
					p("Armrest", Vector3.new(2, 2, 11), CFrame.new(s * 7, 11, -1), GOLD)
				end
			else
				model.Name = "SwordAndShield"
				p("Shield", Vector3.new(14, 19, 3), CFrame.new(0, 12, 1), accent, Enum.PartType.Ball)
				p("ShieldCross", Vector3.new(1, 15, 0.5), CFrame.new(0, 12, -0.6), GOLD)
				p("Blade", Vector3.new(2, 25, 1), CFrame.new(0, 16, -3) * CFrame.Angles(0, 0, -0.3), WHITE)
				p("SwordGuard", Vector3.new(11, 1.5, 2), CFrame.new(-2.4, 8, -3), GOLD)
			end
		elseif index == 4 then
			if side == 1 then
				model.Name = "RecoveredSaucer"
				disk("Saucer", 23, 3, Vector3.new(0, 14, 0), accent)
				p("Canopy", Vector3.new(11, 7, 11), CFrame.new(0, 17, 0), DARK, Enum.PartType.Ball)
				for _, s in { -1, 1 } do rod("LandingStrut", Vector3.new(s * 7, 13, 0), Vector3.new(s * 10, 3, 0), 1.2, WHITE) end
			else
				model.Name = "ListeningStation"
				p("Mast", Vector3.new(3, 18, 3), CFrame.new(0, 11, 0), DARK)
				p("RadarDish", Vector3.new(20, 20, 4), CFrame.new(0, 22, 0) * CFrame.Angles(-0.25, 0, 0), WHITE, Enum.PartType.Ball)
				rod("Receiver", Vector3.new(0, 22, -1), Vector3.new(0, 22, -8), 1, accent)
			end
		elseif index == 5 then
			if side == 1 then
				model.Name = "GlacialCrystals"
				for n = -1, 1 do p("IceMonolith", Vector3.new(6, 23 - math.abs(n) * 7, 7), CFrame.new(n * 6, 13 - math.abs(n) * 3, 0) * CFrame.Angles(0, 0, -n * 0.2), Color3.fromRGB(170, 230, 245)).Material = Enum.Material.Ice end
			else
				model.Name = "ArcticBear"
				p("Body", Vector3.new(14, 8, 7), CFrame.new(0, 10, 0), WHITE, Enum.PartType.Ball)
				p("Head", Vector3.new(6, 6, 6), CFrame.new(8, 12, 0), WHITE, Enum.PartType.Ball)
				p("Muzzle", Vector3.new(3, 2, 3), CFrame.new(11, 11, 0), DARK, Enum.PartType.Ball)
				for _, x in { -5, 5 } do for _, z in { -2, 2 } do p("Leg", Vector3.new(3, 6, 3), CFrame.new(x, 5, z), WHITE) end end
			end
		elseif index == 6 then
			if side == 1 then
				model.Name = "RoyalSarcophagus"
				p("GraniteCase", Vector3.new(13, 27, 6), CFrame.new(0, 15.5, 0), accent).Material = Enum.Material.Granite
				p("GoldEffigy", Vector3.new(9, 20, 1), CFrame.new(0, 14, -3.5), GOLD, Enum.PartType.Ball)
				p("Mask", Vector3.new(5, 6, 1), CFrame.new(0, 23, -4), GOLD, Enum.PartType.Ball)
				for _, s in { -1, 1 } do p("LapisHeaddress", Vector3.new(2, 8, 2), CFrame.new(s * 4, 22, -3.5), Color3.fromRGB(29, 65, 151)) end
			else
				model.Name = "SteppedPyramid"
				for n = 1, 5 do p("StoneCourse", Vector3.new(26 - n * 4, 3.5, 24 - n * 4), CFrame.new(0, 2 + (n - 0.5) * 3.5, 0), GOLD).Material = Enum.Material.Sandstone end
			end
		elseif index == 7 then
			if side == 1 then
				model.Name = "ChampionBarbell"
				p("Bar", Vector3.new(24, 1, 1), CFrame.new(0, 12, 0), accent).Material = Enum.Material.Metal
				for _, s in { -1, 1 } do p("Plate", Vector3.new(4, 15, 15), CFrame.new(s * 9, 12, 0), DARK, Enum.PartType.Cylinder) end
				for _, s in { -1, 1 } do p("Rack", Vector3.new(1, 10, 2), CFrame.new(s * 5, 7, 0), accent) end
			else
				model.Name = "VictoryCup"
				p("Cup", Vector3.new(14, 12, 9), CFrame.new(0, 20, 0), GOLD, Enum.PartType.Ball)
				p("Stem", Vector3.new(3, 10, 3), CFrame.new(0, 9, 0), GOLD)
				for _, s in { -1, 1 } do rod("CupHandle", Vector3.new(s * 5, 23, 0), Vector3.new(s * 10, 16, 0), 1.8, GOLD) end
			end
		elseif index == 8 then
			if side == 1 then
				model.Name = "HistoricVaultDoor"
				p("VaultFrame", Vector3.new(23, 25, 4), CFrame.new(0, 14.5, 0), DARK)
				disk("VaultDoor", 20, 2, Vector3.new(0, 14, -3), WHITE, true).Material = Enum.Material.Metal
				for n = 0, 3 do local a = n * math.pi / 2; rod("WheelSpoke", Vector3.new(0, 14, -5), Vector3.new(math.cos(a) * 6, 14 + math.sin(a) * 6, -5), 0.8, GOLD) end
			else
				model.Name = "BullionReserve"
				for row = 1, 3 do for n = 1, 4 - row do p("GoldIngot", Vector3.new(6, 4, 9), CFrame.new((n - (5 - row) / 2) * 7, row * 4, 0), GOLD).Material = Enum.Material.Metal end end
			end
		elseif index == 9 then
			if side == 1 then
				model.Name = "ContainmentChamber"
				local glass = disk("ContainmentGlass", 15, 22, Vector3.new(0, 15, 0), accent)
				glass.Material, glass.Transparency = Enum.Material.Glass, 0.65
				for _, y in { 3, 27 } do disk("ChamberCap", 18, 2, Vector3.new(0, y, 0), DARK) end
				p("Specimen", Vector3.new(7, 14, 7), CFrame.new(0, 15, 0), accent, Enum.PartType.Ball).Material = Enum.Material.Neon
			else
				model.Name = "MolecularStructure"
				local points = { Vector3.new(0, 12, 0), Vector3.new(-7, 22, 0), Vector3.new(8, 20, 2), Vector3.new(4, 6, -4) }
				for n, at in points do
					p("Atom", Vector3.one * 6, CFrame.new(at), if n % 2 == 0 then accent else WHITE, Enum.PartType.Ball)
					if n > 1 then rod("Bond", points[1], at, 1.5, DARK) end
				end
			end
		elseif index == 10 then
			if side == 1 then
				model.Name = "GrandfatherClock"
				p("WoodCase", Vector3.new(11, 28, 6), CFrame.new(0, 16, 0), WOOD).Material = Enum.Material.Wood
				disk("ClockFace", 9, 0.5, Vector3.new(0, 24, -3.5), WHITE, true)
				rod("MinuteHand", Vector3.new(0, 24, -4), Vector3.new(0, 27, -4), 0.5, DARK)
				rod("HourHand", Vector3.new(0, 24, -4), Vector3.new(3, 24, -4), 0.5, DARK)
				rod("PendulumRod", Vector3.new(0, 18, -3.5), Vector3.new(0, 8, -3.5), 0.4, GOLD)
				disk("Pendulum", 4, 0.5, Vector3.new(0, 8, -3.5), GOLD, true)
			else
				model.Name = "HeirloomTeapot"
				p("Porcelain", Vector3.new(15, 11, 11), CFrame.new(0, 7.5, 0), WHITE, Enum.PartType.Ball)
				disk("Lid", 9, 1, Vector3.new(0, 13.5, 0), accent)
				p("Knob", Vector3.one * 3, CFrame.new(0, 15.5, 0), GOLD, Enum.PartType.Ball)
				rod("Spout", Vector3.new(-5, 8, 0), Vector3.new(-11, 15, 0), 3, WHITE)
				rod("Handle", Vector3.new(6, 13, 0), Vector3.new(10, 6, 0), 2, GOLD)
			end
		elseif index == 11 then
			if side == 1 then
				model.Name = "TowerCrane"
				p("Tower", Vector3.new(3, 28, 3), CFrame.new(-5, 16, 0), accent)
				p("Jib", Vector3.new(26, 2, 3), CFrame.new(0, 29, 0), GOLD)
				rod("Cable", Vector3.new(10, 29, 0), Vector3.new(10, 12, 0), 0.3, DARK)
				p("SuspendedLoad", Vector3.new(7, 6, 7), CFrame.new(10, 9, 0), accent)
				rod("Brace", Vector3.new(-5, 17, 0), Vector3.new(5, 29, 0), 1, GOLD)
			else
				model.Name = "ConcreteMixer"
				p("Drum", Vector3.new(12, 13, 12), CFrame.new(0, 14, 0) * CFrame.Angles(0, 0, 0.5), GOLD, Enum.PartType.Cylinder)
				for _, s in { -1, 1 } do
					rod("Stand", Vector3.new(s * 5, 3, 0), Vector3.new(0, 12, 0), 1.5, accent)
					disk("Wheel", 5, 2, Vector3.new(s * 6, 4, -3), DARK, true)
				end
			end
		else
			model.Name = if side == 1 then "JetEngineCutaway" else "JetEngineFan"
			disk("EngineCasing", 18, 12, Vector3.new(0, 13, 0), WHITE, true).Material = Enum.Material.Metal
			disk("Intake", 14, 0.5, Vector3.new(0, 13, -6.5), DARK, true)
			for n = 0, 3 do p("FanBlade", Vector3.new(1, 12, 0.5), CFrame.new(0, 13, -7) * CFrame.Angles(0, 0, n * math.pi / 4), accent) end
		end
	end
end

return Exhibits
