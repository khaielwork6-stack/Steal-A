--!strict
-- Generated mesh loot. Installed before LootService publishes previews.
-- Model assets preserve UV textures/alignment; mesh IDs below verify every piece.
-- The approved vase is the style reference. Primitives are small accents only.
local InsertService = game:GetService("InsertService")
local ServerStorage = game:GetService("ServerStorage")
local LootModel = require(game:GetService("ReplicatedStorage").Shared.Util.LootModel)
local Builder = {}
-- Bump when shared authoring changes; per-item revisions cover local changes.
local ART_VERSION = 2
local networkLoads = 0
local function loadAsset(assetId: number): Model
	networkLoads += 1
	return InsertService:LoadAsset(assetId)
end
local function versionFor(def: any): string
	local base=string.format("%d:%d:%d",ART_VERSION,def.asset,def.revision or 1)
	return if def.additionalAssets then base..":"..table.concat(def.additionalAssets,",") else base
end
local function isCurrent(model: Instance?, def: any): boolean
	if not model or not model:IsA("Model") or not model.PrimaryPart then return false end
	if model:GetAttribute("ProceduralItemArt")~=1 or model:GetAttribute("ItemArtVersion")~=versionFor(def) then return false end
	if model:GetAttribute("ItemArtAssetId")~=def.asset or model:GetAttribute("ItemArtFallback") then return false end
	local count=0
	for _,part in model:GetDescendants() do if part:IsA("BasePart") then count+=1 end end
	return count==model:GetAttribute("ItemArtPartCount")
end
-- Saved-place aliases remain intact. Unfinished replacements (or a transient
-- published-asset outage) retain this exact prior art under the durable ID.
local LEGACY_NAMES: {[string]: string} = {
	Museum_PharaohMask="Pharaohs Mask", NorthPole_NiceList="Toy Train",
	Area51_TopSecretFiles="Top Secret Files", Egypt_CanopicJar="Pharaoh’s Golden Scepter",
	Gym_Creatine="Boxing Gloves", Bank_CashBag="Money Print Machine",
	SecretLab_SecretFormula="Mutant Specimen", Grandma_CandyBowl="Grandmas Cookie",
	Airport_FirstClassTicket="Pilots Badge", Airport_VIPPassport="Airplane",
}
-- The asset/mesh id table lives in its own data module.
local Definitions = require(script.Parent.ItemAssetDefinitions)
type Definition = Definitions.Definition
local DEFINITIONS: {[string]: Definition} = Definitions

local function configure(part: BasePart, shadow: boolean)
	part.PivotOffset = CFrame.identity
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, false
	part.Massless, part.CastShadow = true, shadow
	part:SetAttribute("ItemArtShadow", shadow)
end

local function motion(part: BasePart, mode: string, speed: number, axis: string?)
	part:SetAttribute("ItemArtMotion", mode)
	part:SetAttribute("ItemArtSpeed", speed)
	part:SetAttribute("ItemArtAxis", axis or "Y")
end

local function neon(part: BasePart, color: Color3, clearTexture: boolean?)
	part.Material, part.Color = Enum.Material.Neon, color
	if clearTexture and part:IsA("MeshPart") then part.TextureID = "" end
end

local function accent(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Name, part.Size, part.CFrame = name, size, cf
	part.Shape = Enum.PartType.Ball
	configure(part, false)
	neon(part, color)
	part.Parent = model
	return part
end

-- Reusable generated halo accent from the Nemes Mask (Studio generate_mesh,
-- fc853e38 job / model 74512256472323); never a primitive replacement body.
local function generatedHalo(model: Model, name: string, cf: CFrame, size: Vector3): MeshPart
	local imported = loadAsset(74512256472323)
	local ring = imported:FindFirstChild("outer_halo_geom", true)
	assert(ring and ring:IsA("MeshPart") and ring.MeshId=="rbxassetid://100980557126559", "Generated halo mesh changed")
	ring.Parent = model
	imported:Destroy()
	ring.Name, ring.CFrame, ring.Size = name, cf, size
	for _,child in ring:GetChildren() do child:Destroy() end
	configure(ring,false)
	return ring
end

local function decorate(model: Model, id: string)
	local function mesh(name: string): MeshPart return model:FindFirstChild(name .. "_geom") :: MeshPart end
	local gold = Color3.fromRGB(255, 211, 112)
	local pearl = Color3.fromRGB(255, 248, 216)
	local purple = Color3.fromRGB(168, 65, 255)
	local cyan = Color3.fromRGB(131, 236, 255)
	if id == "Castle_GoldenGoblet" then
		local bowl, wine = mesh("goblet"), mesh("wine")
		-- Generation put the separate wine surface below the foot. Seat it
		-- inside the open bowl, just below the lip, without changing the mesh.
		wine.CFrame = CFrame.new(bowl.Position + Vector3.new(0, bowl.Size.Y * 0.455, 0))
	elseif id == "Pirate_CaptainsCutlass" then
		local grip = mesh("grip")
		accent(model, "RubyPommel", Vector3.one * 0.15, grip.CFrame * CFrame.new(0,-grip.Size.Y*0.5,0), Color3.fromRGB(255,55,65))
	elseif id == "Museum_Meteorite" then
		neon(mesh("fissures"), Color3.fromRGB(255, 112, 20))
		mesh("rock").Material = Enum.Material.Slate
	elseif id == "NorthPole_NiceList" then
		local train = mesh("train")
		accent(model, "WarmHeadlamp", Vector3.one * 0.18,
			train.CFrame * CFrame.new(0, -train.Size.Y * 0.1, train.Size.Z * 0.49), gold)
	elseif id == "NorthPole_ToyBlueprint" then
		local paper, projection = mesh("paper"), mesh("hologram")
		projection.CFrame = CFrame.new(paper.Position + Vector3.new(0,paper.Size.Y*0.5+projection.Size.Y*0.5+0.25,0)) * CFrame.Angles(0,math.pi/2,0)
	elseif id == "NorthPole_MagicSnowGlobe" then
		local base, glass = mesh("base"), mesh("glass")
		local cabin, pine, star = mesh("cabin"), mesh("pine"), mesh("star")
		cabin.Size *= 2.2
		pine.Size *= 2.3
		local floor = base.Position.Y + base.Size.Y * 0.5
		cabin.CFrame = CFrame.new(base.Position.X + 0.35, floor + cabin.Size.Y * 0.5, base.Position.Z + 0.2)
		pine.CFrame = CFrame.new(base.Position.X - 0.7, floor + pine.Size.Y * 0.5, base.Position.Z - 0.25)
		star.Size *= 1.8
		star.CFrame = CFrame.new(glass.Position + Vector3.new(glass.Size.X * 0.58, glass.Size.Y * 0.28, 0))
		pine.TextureID, pine.Color, pine.Material = "", Color3.fromRGB(22,105,61), Enum.Material.Grass
		for _, child in pine:GetChildren() do if child:IsA("SurfaceAppearance") then child:Destroy() end end
		for _,x in {-0.22,0.22} do
			local window=accent(model,"CabinWindow",Vector3.new(0.16,0.2,0.025),cabin.CFrame*CFrame.new(x,0.08,cabin.Size.Z*0.46),gold)
			window.Shape=Enum.PartType.Block
		end
		local snow = Instance.new("ParticleEmitter")
		snow.Name = "ItemArtSnow"
		snow:SetAttribute("ItemArtParticle", true)
		snow.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		snow.Color, snow.LightEmission = ColorSequence.new(Color3.new(1,1,1)), 0.1
		snow.Size = NumberSequence.new(0.045)
		snow.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,1),NumberSequenceKeypoint.new(0.15,0.1),NumberSequenceKeypoint.new(0.8,0.1),NumberSequenceKeypoint.new(1,1)})
		snow.Rate, snow.Lifetime, snow.Speed = 7, NumberRange.new(1.8,2.2), NumberRange.new(0.1,0.25)
		snow.Shape, snow.ShapeStyle = Enum.ParticleEmitterShape.Sphere, Enum.ParticleEmitterShapeStyle.Volume
		snow.EmissionDirection, snow.LockedToPart = Enum.NormalId.Bottom, true
		snow.Parent = mesh("glass")
	elseif id == "NorthPole_SantasGiftSack" then
		local light, sack = mesh("light"), mesh("sack")
		light.Size *= 0.6
		light.CFrame = CFrame.new(sack.Position + Vector3.new(0,sack.Size.Y*0.37,0))
		sack.TextureID, sack.Color = "", Color3.fromRGB(65,10,22)
		for _,child in sack:GetChildren() do if child:IsA("SurfaceAppearance") then child:Destroy() end end
	elseif id == "Egypt_NemesMask" then
		local face, outer = mesh("mask"), mesh("outer_halo")
		mesh("inner_halo"):Destroy()
		outer.Size = Vector3.new(face.Size.X*1.6,face.Size.Y*1.05,0.16)
		outer.CFrame = CFrame.new(face.Position + Vector3.new(0,0.05,-face.Size.Z*0.6))
		local inner=outer:Clone()
		inner.Name, inner.Size = "inner_halo_geom", outer.Size*Vector3.new(0.82,0.82,1)
		inner.CFrame=outer.CFrame*CFrame.new(0,0,0.08)
		inner.Parent=model
	elseif id == "Egypt_EgyptianPyramid" then
		local pyramid, cap, light=mesh("pyramid"),mesh("capstone"),mesh("light")
		mesh("halo"):Destroy()
		local diameter=pyramid.Size.X*1.35
		generatedHalo(model,"halo_geom",CFrame.new(pyramid.Position+Vector3.new(0,(diameter-pyramid.Size.Y)*0.5,-pyramid.Size.Z*0.65)),Vector3.new(diameter,diameter,0.12))
		cap.CFrame+=Vector3.new(0,0.5,0)
		light.Size=Vector3.new(0.18,0.5,0.18)
		light.CFrame=CFrame.new(pyramid.Position+Vector3.new(0,pyramid.Size.Y*0.5+0.25,0))
	elseif id == "Gym_CoachsWhistle" then
		local body,loop=mesh("whistle"),mesh("lanyard")
		local center=body.Position
		body.CFrame=CFrame.new(center)*CFrame.Angles(0,math.pi/2,0)
		loop.CFrame=CFrame.new(center+Vector3.new(0,(body.Size.Y+loop.Size.Z)*0.5,0))*CFrame.Angles(math.pi/2,0,0)
		accent(model,"WarmMouthGlow",Vector3.one*0.12,body.CFrame*CFrame.new(0,0,body.Size.Z*0.48),gold)
	elseif id == "Gym_GoldenDumbbell" then
		local left,right,plate=mesh("left_dumbbell"),mesh("right_dumbbell"),mesh("orbit_plate")
		local center=(left.Position+right.Position)*0.5
		-- The two generated meshes arrived parallel. Pose their long axes as
		-- the authored X; the definition supplies an upright invisible root.
		left.CFrame=CFrame.new(center+Vector3.new(0,0,0.35))*CFrame.Angles(0,0,math.pi/4)*CFrame.Angles(0,math.pi/2,0)
		right.CFrame=CFrame.new(center-Vector3.new(0,0,0.35))*CFrame.Angles(0,0,-math.pi/4)*CFrame.Angles(0,math.pi/2,0)
		plate.CFrame=CFrame.new(center+Vector3.new(left.Size.Z*0.65,0.2,0))
	elseif id == "Gym_Trophy" then
		local cup=mesh("cup")
		cup.TextureID=""
		for _,child in cup:GetChildren() do if child:IsA("SurfaceAppearance") then child:Destroy() end end
	elseif id == "Gym_GoldenBarbell" then
		local bar=mesh("barbell")
		local diameter=mesh("left_halo").Size.Y*1.35
		for i,name in {"left_halo","right_halo"} do
			local plate=mesh(name)
			local ring=generatedHalo(model,"EternalHalo"..i,CFrame.new(plate.Position+Vector3.new(0,0,-diameter*0.35)),Vector3.new(diameter,diameter,0.12))
			neon(ring,pearl,true)
			motion(ring,"Spin",if i==1 then 0.16 else -0.16,"Z")
		end
		for i=1,3 do
			local shaft=accent(model,"BarRadiance"..i,Vector3.new(0.08,0.08,0.8),CFrame.new(bar.Position+Vector3.new((i-2)*bar.Size.X*0.18,0.4,0.2)),pearl)
			shaft.Shape,shaft.Transparency=Enum.PartType.Block,0.55
		end
	elseif id == "Museum_GoldenCrown" then
		-- Tiny gem only: Epic has a faint accent, not a glowing crown body.
		neon(mesh("ruby_gems"), Color3.fromRGB(255, 85, 95))
	elseif id == "Museum_Diamond" then
		local gem = mesh("diamond")
		gem.Material, gem.Transparency = Enum.Material.Glass, 0.13
		accent(model, "DiamondHeart", Vector3.one * 0.32, gem.CFrame, cyan)
	elseif id == "Castle_RoyalScepter" then
		local gem = mesh("amethyst")
		neon(gem, purple)
		motion(gem, "Hover", 1.4)
	elseif id == "Castle_KingsCrown" then
		local crown = mesh("crown")
		local satellite = accent(model, "OrbitingAmethyst", Vector3.one * 0.32,
			CFrame.new(crown.Position + Vector3.new(crown.Size.X * 0.57, 0.35, 0)), purple)
		motion(satellite, "Orbit", 0.5)
	elseif id == "Area51_AlienArtifact" then
		local frame,core = mesh("outer_frame"),mesh("inverted_core")
		frame.TextureID=""
		for _,d in frame:GetChildren() do if d:IsA("SurfaceAppearance") then d:Destroy() end end
		frame.Color,frame.Material=Color3.fromRGB(12,15,19),Enum.Material.Metal
		neon(core,Color3.fromRGB(88,255,32),true)
		motion(core, "Spin", -0.4)
	elseif id == "NorthPole_ChristmasStar" then
		neon(mesh("inner_halo"), pearl, true)
		neon(mesh("outer_halo"), gold, true)
		motion(mesh("inner_halo"), "Spin", 0.2, "Z")
		motion(mesh("outer_halo"), "Spin", -0.16, "Z")
		local star = mesh("star")
		accent(model, "StarHeart", Vector3.one * 0.28, star.CFrame * CFrame.new(0, 0.2, star.Size.Z * 0.5), pearl)
	elseif id == "SecretLab_RadiationChamber" then
		local glass, core = mesh("glass"), mesh("core")
		glass.TextureID = ""
		glass.Material, glass.Color, glass.Transparency = Enum.Material.Glass, cyan, 0.78
		neon(core, pearl, true)
		motion(core, "Hover", 1.1)
		for i, name in {"inner_halo", "middle_halo", "outer_halo"} do
			local ring = mesh(name)
			-- Separate celestial planes make all three rings visible from the front.
			ring.CFrame = CFrame.new(core.Position + Vector3.new(0, 0.65, 0))
				* CFrame.Angles(math.rad(25 * (i - 2)), 0, math.rad(25 * (i - 2)))
			neon(ring, if i == 2 then gold else pearl, true)
			motion(ring, "Spin", (if i % 2 == 0 then -1 else 1) * 0.18)
		end
		for i=1,3 do
			local angle = i * math.pi * 2 / 3
			local shard = accent(model, "FloatingFragment" .. i, Vector3.new(0.22, 0.38, 0.22),
				CFrame.new(core.Position + Vector3.new(math.cos(angle)*2.2, 0.25, math.sin(angle)*2.2)), gold)
			shard.Shape = Enum.PartType.Block
			motion(shard, "Orbit", 0.25)
		end
	end
	if id == "NorthPole_ChristmasStar" or id == "SecretLab_RadiationChamber" then
		local cf, size = model:GetBoundingBox()
		for i=1,3 do
			-- Light shafts are modest translucent mesh accents, never Beams/Trails.
			local shaft = accent(model, "Radiance" .. i, Vector3.new(0.08, 0.9 + i*0.15, 0.08),
				CFrame.new(cf.Position + Vector3.new((i-2)*0.42, size.Y*0.42, 0)), pearl)
			shaft.Shape, shaft.Transparency = Enum.PartType.Cylinder, 0.65
			shaft.Size = Vector3.new(1 + i*0.15, 0.08, 0.08)
			shaft.CFrame *= CFrame.Angles(0, 0, math.pi/2)
		end
	end
end


-- Segmentation labels from generation are not geometry guarantees. These
-- reviewed accents are added after material recipes, without replacing bodies.
local function finalDetails(model: Model, id: string)
	local function mesh(name: string): MeshPart return model:FindFirstChild(name.."_geom") :: MeshPart end
	local gold,pearl=Color3.fromRGB(255,209,108),Color3.fromRGB(255,246,215)
	local function halo(name: string, center: Vector3, diameter: number, tilt: CFrame?, color: Color3?)
		local p=generatedHalo(model,name,CFrame.new(center)*(tilt or CFrame.identity),Vector3.new(diameter,diameter,0.10))
		neon(p,color or gold,true); motion(p,"Spin",0.12,"Z"); return p
	end
	local function shafts(center: Vector3, spread: number)
		for i=1,3 do
			local p=accent(model,"Radiance"..i,Vector3.new(0.06,0.8+i*0.12,0.06),CFrame.new(center+Vector3.new((i-2)*spread,0,0)),pearl)
			p.Shape=Enum.PartType.Block; p.Transparency=0.4
		end
	end

	if id=="Grandma_CandyBowl" then
		local cookies,plate=mesh("cookies"),mesh("plate")
		plate.Size=Vector3.new(cookies.Size.X*1.12,cookies.Size.Y*0.10,cookies.Size.X*1.12)
		plate.CFrame=CFrame.new(cookies.Position+Vector3.new(0,-cookies.Size.Y*0.5-plate.Size.Y*0.30,0))
		accent(model,"WarmSugarGlint",Vector3.one*0.12,CFrame.new(cookies.Position+Vector3.new(cookies.Size.X*0.15,cookies.Size.Y*0.49,cookies.Size.Z*0.15)),Color3.fromRGB(255,208,125))
	elseif id=="SecretLab_SecretFormula" then
		local jar,lid,creature=mesh("jar"),mesh("lid"),mesh("creature")
		jar.Size*=Vector3.new(1.25,0.70,1.25)
		lid.Size*=Vector3.new(1.25,0.85,1.25)
		lid.CFrame=CFrame.new(jar.Position+Vector3.new(0,jar.Size.Y*0.5+lid.Size.Y*0.15,0))
		local fit=math.min(jar.Size.X*0.66/creature.Size.X,jar.Size.Y*0.66/creature.Size.Y,jar.Size.Z*0.66/creature.Size.Z)
		creature.Size*=fit
		creature.CFrame=CFrame.new(jar.Position+Vector3.new(0,-jar.Size.Y*0.05,0))
		local fluid=accent(model,"SpecimenFluid",jar.Size*Vector3.new(0.82,0.68,0.82),CFrame.new(jar.Position+Vector3.new(0,-jar.Size.Y*0.08,0)),Color3.fromRGB(102,255,69))
		fluid.Material,fluid.Transparency=Enum.Material.Glass,0.86
		accent(model,"SpecimenBubble",Vector3.one*0.10,CFrame.new(creature.Position+Vector3.new(creature.Size.X*0.5,creature.Size.Y*0.35,0)),Color3.fromRGB(102,255,69))
	elseif id=="Bank_CashBag" then
		local body=mesh("slot")
		local p=accent(model,"PrintSlotGlow",Vector3.new(body.Size.X*0.5,0.09,0.08),CFrame.new(body.Position+Vector3.new(0,body.Size.Y*0.3,body.Size.Z*0.5)),Color3.fromRGB(90,255,145))
		p.Shape=Enum.PartType.Block
	elseif id=="Bank_VendingMachine" then
		local body=mesh("halos")
		halo("EternalRing1",body.Position+Vector3.new(0,0,-1.1),body.Size.Y*0.9)
		halo("EternalRing2",body.Position+Vector3.new(0,0,-1.15),body.Size.Y*1.02)
		shafts(body.Position+Vector3.new(0,body.Size.Y*0.35,0),0.4)
	elseif id=="SecretLab_EnergyCore" then
		local body=mesh("halos")
		for i=1,3 do halo("EternalRing"..i,body.Position+Vector3.new(0,(i-2)*0.65,0),body.Size.X*(1.5+0.15*i),CFrame.Angles(math.pi/2,0,0)) end
	elseif id=="Grandma_GoldenTeapot" then
		mesh("lid").CFrame+=Vector3.new(0,0.35,0)
	elseif id=="Grandma_LegendaryGiftBox" then
		local body=mesh("box")
		halo("EternalRing1",body.Position+Vector3.new(0,0,-2),body.Size.Y*1.35)
		halo("EternalRing2",body.Position+Vector3.new(0,0,-2.1),body.Size.Y*1.55)
		shafts(body.Position+Vector3.new(0,body.Size.Y*0.5,0),0.65)
	elseif id=="Grandma_CookieJar" then
		local lid=mesh("lid")
		for i=1,3 do halo("DivineRing"..i,lid.Position+Vector3.new(0,(i-2)*0.3,-0.3),lid.Size.X*(1.3+i*0.15),CFrame.Angles(math.rad(65),0,0),if i==2 then pearl else gold) end
		shafts(lid.Position+Vector3.new(0,0.6,0),0.5)
	elseif id=="Construction_Blueprints" then
		mesh("lines").Size*=1.015
	elseif id=="Construction_RareSafetyVest" then
		mesh("bands").Size*=1.025
	elseif id=="Construction_BossLadder" then
		local p=mesh("halos")
		for i=-1,1,2 do halo("HingeHalo"..i,p.Position+Vector3.new(i*1.1,0,0),1.2,CFrame.Angles(0,math.pi/4,0)) end
	elseif id=="Construction_DiamondHammer" then
		local head=mesh("head")
		for i=1,3 do halo("DivineRing"..i,head.Position+Vector3.new(0,0,-0.9-i*0.08),head.Size.X*(1.1+i*0.22),nil,if i==2 then pearl else gold) end
		shafts(head.Position+Vector3.new(0,1,0),0.45)
		local shard=accent(model,"OrbitingDiamond",Vector3.one*0.3,CFrame.new(head.Position+Vector3.new(2,0.3,0)),Color3.fromRGB(174,225,255))
		motion(shard,"Orbit",0.25)
	elseif id=="Airport_UnknownBriefcase" then
		local body=mesh("case")
		local glow=accent(model,"InnerAmber",Vector3.new(body.Size.X*0.75,0.10,body.Size.Z*0.65),CFrame.new(body.Position+Vector3.new(0,body.Size.Y*0.45,0)),gold)
		glow.Shape=Enum.PartType.Block
	elseif id=="Airport_PrivateJet" then
		local jet=mesh("jet")
		for i=1,3 do
			local position=jet.Position+Vector3.new((i-2)*1.0,0,(i-2)*1.0)
			halo("DivineRing"..i,position,5.5+i*0.8,CFrame.Angles(0,math.pi/4,0),if i==2 then pearl else gold)
		end
		shafts(jet.Position+Vector3.new(0,-1.8,0),1.2)
		local engine=mesh("engines")
		for i=-1,1,2 do
			accent(model,"EngineRadiance"..i,Vector3.one*0.35,CFrame.new(engine.Position+Vector3.new(i*0.5,0,0.5)),Color3.fromRGB(135,230,255))
		end
	end
end

local function construct(id: string, def: Definition): Model
	local imported = loadAsset(def.asset)
	local model = Instance.new("Model")
	model.Name = id
	model:SetAttribute("ProceduralItemArt", 1)
	model:SetAttribute("ItemArtAssetId", def.asset)
	model:SetAttribute("ItemArtVersion",versionFor(def))
	local ok, err = pcall(function()
		for _,assetId in def.additionalAssets or {} do
			local extra=loadAsset(assetId)
			for _,part in extra:GetDescendants() do
				if part:IsA("MeshPart") then
					-- A separately generated component supersedes a mislabeled main-package segment.
					local prior=imported:FindFirstChild(part.Name,true)
					if prior and prior:IsA("MeshPart") then prior:Destroy() end
					part.Parent=imported
				end
			end
			extra:Destroy()
		end
		for name, meshId in def.meshes do
			local part = imported:FindFirstChild(name, true)
			assert(part and part:IsA("MeshPart"), id .. " missing " .. name)
			assert(part.MeshId == meshId, id .. " changed mesh " .. name)
			for _, child in part:GetChildren() do
				if not child:IsA("SurfaceAppearance") then child:Destroy() end
			end
			configure(part, true)
			part.Material, part.Reflectance = Enum.Material.SmoothPlastic, 0
			part.Parent = model
		end
		local primary = model:FindFirstChild(def.primary) :: BasePart
		assert(primary and primary.CFrame.UpVector:Dot(Vector3.yAxis) > 0.9999, id .. " is not upright")
		if def.authorRotation then
			-- Some generated meshes arrive flat. Author their geometry upright here;
			-- an invisible upright pivot preserves the resolver's frame contract.
			local center = model:GetBoundingBox().Position
			for _, part in model:GetChildren() do
				if part:IsA("BasePart") then part.CFrame = CFrame.new(center) * def.authorRotation * (part.CFrame - center) end
			end
			local root = Instance.new("Part")
			root.Name, root.Size, root.Transparency = "ItemArtRoot", Vector3.one * 0.05, 1
			root.CFrame = CFrame.new(center)
			configure(root, false)
			root.Parent = model
			primary = root
		end
		model.PrimaryPart = primary
		-- First author the imported mesh at five studs, then fit accents as a unit.
		local _, size = model:GetBoundingBox()
		model:ScaleTo(model:GetScale() * 5 / size.Y)
		decorate(model, id)
		for name, finish in def.finishes or {} do
			local part = model:FindFirstChild(name)
			assert(part and part:IsA("MeshPart"), id .. " missing finish mesh " .. name)
			if finish.material then part.Material = finish.material end
			if finish.color then part.Color = finish.color end
			if finish.transparency then part.Transparency = finish.transparency end
			if finish.clearTexture then
				part.TextureID = ""
				for _, child in part:GetChildren() do if child:IsA("SurfaceAppearance") then child:Destroy() end end
			end
			if finish.glow then part.Material = Enum.Material.Neon end
			if finish.mode then motion(part, finish.mode, finish.speed or 0.5, finish.axis) end
		end
		finalDetails(model,id)
		local min, max = LootModel.visibleExtents(model)
		assert(min and max, id .. " has no visible art")
		local fit = LootModel.normalisationFor(max - min)
		model:ScaleTo(model:GetScale() * fit)
		min, max = LootModel.visibleExtents(model)
		assert(min and max)
		model:TranslateBy(Vector3.new(-(min.X+max.X)/2, -min.Y, -(min.Z+max.Z)/2))
		local count = 0
		for _, part in model:GetChildren() do
			if part:IsA("BasePart") then
				count += 1
				if part ~= primary then
					local weld = Instance.new("WeldConstraint")
					weld.Name, weld.Part0, weld.Part1 = "ItemArtWeld", primary, part
					weld.Parent = primary
				end
				part.Anchored = false
			end
		end
		assert(count <= 40, id .. " exceeds the art part budget")
		model:SetAttribute("ItemArtPartCount", count)
	end)
	imported:Destroy()
	if not ok then model:Destroy(); error(err) end
	return model
end

-- SUPERSEDED SAVED-PLACE ART LIVES BESIDE Loot, NOT INSIDE IT. It is kept
-- under the same item ids as the live art, and while it sat in
-- Loot._OriginalArt a recursive lookup could return the old copy depending on
-- child order. GameAssets.LootOriginals is outside every loot lookup.
local ORIGINALS_NAME = "LootOriginals"

--- The originals folder, moving an older place's Loot._OriginalArt into it
--- first. Never deletes: an id already present in LootOriginals keeps its copy
--- and the legacy duplicate stays where it is (LootModel.findSource skips
--- that folder by name). Run on every build, so a saved place that still has
--- the old layout is fixed at boot (and permanently once saved from Edit).
local function originalsFolder(assets: Instance, loot: Instance): Instance
	local originals = assets:FindFirstChild(ORIGINALS_NAME)
	local legacy = loot:FindFirstChild(LootModel.ORIGINALS_FOLDER)
	if legacy and not originals then
		legacy.Name = ORIGINALS_NAME
		legacy.Parent = assets
		return legacy
	end
	local target: Instance
	if originals then
		target = originals
	else
		local made = Instance.new("Folder")
		made.Name = ORIGINALS_NAME
		made.Parent = assets
		target = made
	end
	if legacy then
		local kept = 0
		for _, child in legacy:GetChildren() do
			if target:FindFirstChild(child.Name) then kept += 1 else child.Parent = target end
		end
		if kept == 0 then
			legacy:Destroy()
		else
			warn(`[ItemAssetBuilder] {kept} art backup(s) in Loot.{LootModel.ORIGINALS_FOLDER} duplicate {ORIGINALS_NAME} and were left in place`)
		end
	end
	return target
end

function Builder.build()
	local started = os.clock()
	networkLoads=0
	local cached=0
	local assets = ServerStorage:WaitForChild("GameAssets")
	local loot = assets:WaitForChild("Loot")
	local originals = originalsFolder(assets, loot)
	local ids: {string} = {}
	for id,def in DEFINITIONS do
		if isCurrent(loot:FindFirstChild(id),def) then cached+=1 else table.insert(ids,id) end
	end
	table.sort(ids)
	local built: {[string]: Model} = {}
	local failures: {string} = {}
	local retained: {string} = {}
	local function retain(id: string)
		local existing=loot:FindFirstChild(id)
		local alias=LEGACY_NAMES[id]
		local source=(alias and loot:FindFirstChild(alias)) or existing
		if source then
			if source~=existing then
				local copy=source:Clone()
				copy.Name=id
				if existing then existing:Destroy() end
				copy.Parent=loot
				source=copy
			end
			source:SetAttribute("ItemArtFallback",true)
		end
		table.insert(retained,id)
	end
	local nextIndex, finished = 0, 0
	-- Overlap network waits without flooding InsertService as the catalog grows.
	local workers = math.min(8, #ids)
	for _ = 1, workers do
		task.spawn(function()
			while true do
				nextIndex += 1
				local id = ids[nextIndex]
				if not id then break end
				local ok, result = pcall(construct, id, DEFINITIONS[id])
				if not ok then
					task.wait(0.5)
					ok,result=pcall(construct,id,DEFINITIONS[id])
				end
				if ok then built[id] = result else table.insert(failures, id .. ": " .. tostring(result)) end
			end
			finished += 1
		end)
	end
	-- No service may publish previews until every worker has finished.
	while finished < workers do task.wait() end
	if #failures > 0 then
		table.sort(failures)
		warn("[ItemAssetBuilder] Retaining previous art after mesh loading failed:\n" .. table.concat(failures, "\n"))
	end
	local installed=cached
	for _, id in ids do
		if built[id] then
			local previous = loot:FindFirstChild(id)
			if previous then
				-- Preserve the original saved-place art when baking in Edit mode.
				if not game:GetService("RunService"):IsRunning() and not previous:GetAttribute("ProceduralItemArt") then
					if originals:FindFirstChild(id) then previous:Destroy() else previous.Parent=originals end
				else previous:Destroy() end
			end
			built[id].Parent = loot
			installed+=1
		else retain(id) end
	end
	-- When generation has not succeeded, keep the old alias as a runtime copy;
	-- the saved-place original is never renamed or deleted.
	for id in LEGACY_NAMES do if not DEFINITIONS[id] then retain(id) end end
	local seconds = os.clock() - started
	loot:SetAttribute("ItemArtLoadSeconds", seconds)
	loot:SetAttribute("ItemArtCachedCount",cached)
	loot:SetAttribute("ItemArtNetworkLoads",networkLoads)
	loot:SetAttribute("ItemArtLoadedCount", installed)
	loot:SetAttribute("ItemArtLoadFailures", #failures)
	loot:SetAttribute("ItemArtRetainedIds",table.concat(retained,","))
	local result={installed=installed,cached=cached,networkLoads=networkLoads,failures=#failures,retained=retained,seconds=seconds}
	print(string.format("[ItemAssetBuilder] %d generated items ready (%d saved models reused, %d LoadAsset calls) in %.2fs; %d retained",installed,cached,networkLoads,seconds,#retained))
	return result
end

return Builder

