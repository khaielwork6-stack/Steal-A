--!strict
-- Generated mesh loot. Installed before LootService publishes previews.
-- Model assets preserve UV textures/alignment; mesh IDs below verify every piece.
-- The approved vase is the style reference. Primitives are small accents only.
local InsertService = game:GetService("InsertService")
local ServerStorage = game:GetService("ServerStorage")
local LootModel = require(game:GetService("ReplicatedStorage").Shared.Util.LootModel)
local Builder = {}
type Definition = {asset: number, primary: string, meshes: {[string]: string}}
local DEFINITIONS: {[string]: Definition} = {
	-- Studio MCP generate_mesh, 46882e4a-22d2-473e-9e7f-09f43b62d399 (2026-09-16).
	-- Owner-approved terracotta amphora: generated finish retained unchanged.
	Museum_AncientVase = {asset=106158589587145, primary="body_geom", meshes={
		body_geom="rbxassetid://114004149110400", left_handle_geom="rbxassetid://117879231551896",
		right_handle_geom="rbxassetid://108369417536629", rim_geom="rbxassetid://140346615857141",
		foot_geom="rbxassetid://82833103487770",
	}},
	-- Studio MCP generate_mesh, 3254299f-599b-4606-be29-23ec5f4a6cda (2026-09-16).
	Museum_RarePainting = { asset = 90670151553303, primary = "easel_geom", meshes = {
		["easel_geom"] = "rbxassetid://108186797864133",
		["canvas_geom"] = "rbxassetid://108764449525864",
		["frame_geom"] = "rbxassetid://101575797827345",
	} },
	-- Studio MCP generate_mesh, 4d62742f-a704-4653-98c0-64063f57715f (2026-09-16).
	Museum_GoldenStatue = { asset = 125354881690116, primary = "figure_geom", meshes = {
		["plinth_geom"] = "rbxassetid://110630974368288",
		["figure_geom"] = "rbxassetid://99667071802035",
	} },
	-- Studio MCP generate_mesh, de82d845-409c-4df3-9c52-e0eb87de5b39 (2026-09-16).
	Museum_Ruby = { asset = 123291712722573, primary = "mount_geom", meshes = {
		["mount_geom"] = "rbxassetid://122394596161850",
		["ruby_geom"] = "rbxassetid://88260739872272",
	} },
	-- Studio MCP generate_mesh, 7947e4ff-c826-485f-970e-8e0f983e0ef5 (2026-09-16).
	Museum_GoldenCrown = { asset = 120902358714621, primary = "crown_geom", meshes = {
		["emerald_gems_geom"] = "rbxassetid://136682853450078",
		["ruby_gems_geom"] = "rbxassetid://124295457415348",
		["crown_geom"] = "rbxassetid://97778721025012",
	} },
	-- Studio MCP generate_mesh, c4ba9d55-5838-46a3-983a-5900b2444bbf (2026-09-16).
	Museum_Diamond = { asset = 93040689758284, primary = "spindle_geom", meshes = {
		["spindle_geom"] = "rbxassetid://94865240930454",
		["diamond_geom"] = "rbxassetid://73162842162507",
	} },
	-- Studio MCP generate_mesh, 176ab40e-3ae2-4c8a-9d21-0d88ce7afebe (2026-09-16).
	Castle_RoyalScepter = { asset = 94738435141116, primary = "scepter_geom", meshes = {
		["amethyst_geom"] = "rbxassetid://110396797148832",
		["scepter_geom"] = "rbxassetid://83732358900251",
	} },
	-- Studio MCP generate_mesh, affed5eb-2431-45ed-9bc9-4ff65000bf7a (2026-09-16).
	Castle_KingsCrown = { asset = 138544191331746, primary = "crown_geom", meshes = {
		["amethyst_geom"] = "rbxassetid://82181228045148",
		["crown_geom"] = "rbxassetid://90848254590877",
	} },
	-- Studio MCP generate_mesh, 5ceb5209-8f30-482d-973a-cb57135cf284 (2026-09-16).
	Area51_AlienArtifact = { asset = 84840189777251, primary = "outer_frame_geom", meshes = {
		["inverted_core_geom"] = "rbxassetid://113141367053240",
		["outer_frame_geom"] = "rbxassetid://125908590874969",
	} },
	-- Studio MCP generate_mesh, c97c4c2e-90eb-40a7-af5d-f66ca931bd60 (2026-09-16).
	NorthPole_ChristmasStar = { asset = 106540347467449, primary = "star_geom", meshes = {
		["outer_halo_geom"] = "rbxassetid://102091055751199",
		["inner_halo_geom"] = "rbxassetid://128368172677649",
		["star_geom"] = "rbxassetid://81830565004789",
	} },
	-- Studio MCP generate_mesh, 92bd5ea4-d75d-4c99-9847-a4d66bb925d0 (2026-09-16).
	SecretLab_RadiationChamber = { asset = 81410628544205, primary = "frame_geom", meshes = {
		["outer_halo_geom"] = "rbxassetid://119527315595471",
		["middle_halo_geom"] = "rbxassetid://132790692073369",
		["inner_halo_geom"] = "rbxassetid://87925417840466",
		["core_geom"] = "rbxassetid://114006579392706",
		["glass_geom"] = "rbxassetid://71772340824896",
		["frame_geom"] = "rbxassetid://111535486753816",
	} },
}

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

local function decorate(model: Model, id: string)
	local function mesh(name: string): MeshPart return model:FindFirstChild(name .. "_geom") :: MeshPart end
	local gold = Color3.fromRGB(255, 211, 112)
	local pearl = Color3.fromRGB(255, 248, 216)
	local purple = Color3.fromRGB(168, 65, 255)
	local cyan = Color3.fromRGB(131, 236, 255)
	if id == "Museum_GoldenCrown" then
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
		local core = mesh("inverted_core")
		neon(core, Color3.fromRGB(88, 255, 32))
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

local function construct(id: string, def: Definition): Model
	local imported = InsertService:LoadAsset(def.asset)
	local model = Instance.new("Model")
	model.Name = id
	model:SetAttribute("ProceduralItemArt", 1)
	model:SetAttribute("ItemArtAssetId", def.asset)
	local ok, err = pcall(function()
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
		model.PrimaryPart = primary
		-- First author the imported mesh at five studs, then fit accents as a unit.
		local _, size = model:GetBoundingBox()
		model:ScaleTo(model:GetScale() * 5 / size.Y)
		decorate(model, id)
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

function Builder.build()
	local started = os.clock()
	local loot = ServerStorage:WaitForChild("GameAssets"):WaitForChild("Loot")
	local ids: {string} = {}
	for id in DEFINITIONS do table.insert(ids, id) end
	table.sort(ids)
	local built: {[string]: Model} = {}
	local failures: {string} = {}
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
				if ok then built[id] = result else table.insert(failures, id .. ": " .. tostring(result)) end
			end
			finished += 1
		end)
	end
	-- No service may publish previews until every worker has finished.
	while finished < workers do task.wait() end
	if #failures > 0 then
		for _, model in built do model:Destroy() end
		table.sort(failures)
		error("[ItemAssetBuilder] No loot replaced; mesh loading failed:\n" .. table.concat(failures, "\n"))
	end
	for _, id in ids do
		local previous = loot:FindFirstChild(id)
		if previous then previous:Destroy() end
		built[id].Parent = loot
	end
	local seconds = os.clock() - started
	loot:SetAttribute("ItemArtLoadSeconds", seconds)
	loot:SetAttribute("ItemArtLoadedCount", #ids)
	print(string.format("[ItemAssetBuilder] %d generated-mesh items installed in %.2fs (%d concurrent workers)", #ids, seconds, workers))
end

return Builder

