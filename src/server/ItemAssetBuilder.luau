--!strict
-- Generated mesh loot. Installed before LootService publishes previews.
-- Model assets preserve UV textures/alignment; mesh IDs below verify every piece.
-- The approved vase is the style reference. Primitives are small accents only.
local InsertService = game:GetService("InsertService")
local ServerStorage = game:GetService("ServerStorage")
local LootModel = require(game:GetService("ReplicatedStorage").Shared.Util.LootModel)
local Builder = {}
type Finish = {material: Enum.Material?, color: Color3?, transparency: number?, glow: boolean?,
	mode: string?, speed: number?, axis: string?, clearTexture: boolean?}
type Definition = {asset: number, primary: string, meshes: {[string]: string}, finishes: {[string]: Finish}?, authorRotation: CFrame?}
local DEFINITIONS: {[string]: Definition} = {
	-- Studio MCP generate_mesh, 08b1ef06-cdc1-4a1d-be08-acf94c139ad1 (2026-09-16).
	NorthPole_NiceList = {asset=112981394859159, primary="train_geom", authorRotation=CFrame.Angles(0,math.pi/2,0), meshes={
		["smoke_geom"]="rbxassetid://108557422657389",
		["wheels_geom"]="rbxassetid://101495797841279",
		["train_geom"]="rbxassetid://133804072102341",
	}, finishes={train_geom={material=Enum.Material.Metal}, wheels_geom={material=Enum.Material.Rubber}, smoke_geom={material=Enum.Material.SmoothPlastic}}},
	-- Studio MCP generate_mesh, 43feb6a6-7c1d-46f2-9246-0ff7e49d78d7 (2026-09-16).
	NorthPole_GoldenBell = {asset=99510621411127, primary="bell_geom", meshes={
		["inner_light_geom"]="rbxassetid://93942419272333",
		["holly_geom"]="rbxassetid://120847977894928",
		["ribbon_geom"]="rbxassetid://115792695501994",
		["bell_geom"]="rbxassetid://75596411365851",
	}, finishes={bell_geom={material=Enum.Material.Metal}, ribbon_geom={material=Enum.Material.Fabric}, holly_geom={material=Enum.Material.SmoothPlastic}, inner_light_geom={glow=true,color=Color3.fromRGB(255,224,142),clearTexture=true}}},
	-- Studio MCP generate_mesh, f56072f2-b6eb-4acf-9ea5-6d9aa09c527f (2026-09-16).
	NorthPole_ToyBlueprint = {asset=125963223639102, primary="paper_geom", meshes={
		["hologram_geom"]="rbxassetid://82216889787092",
		["paper_geom"]="rbxassetid://77181251220353",
	}, finishes={paper_geom={material=Enum.Material.Fabric}, hologram_geom={glow=true,color=Color3.fromRGB(87,241,255),clearTexture=true,mode="Hover",speed=1.1}}},
	-- Studio MCP generate_mesh, e801f2bb-6afa-4f4d-9c78-375055b02207 (2026-09-16).
	NorthPole_GoldenPresent = {asset=91090558173172, primary="box_geom", meshes={
		["inner_light_geom"]="rbxassetid://82741354850218",
		["bow_geom"]="rbxassetid://140437258800379",
		["lid_geom"]="rbxassetid://126683214838393",
		["box_geom"]="rbxassetid://124998849833198",
	}, finishes={box_geom={material=Enum.Material.Foil}, lid_geom={material=Enum.Material.Foil,mode="Hover",speed=1}, bow_geom={material=Enum.Material.Fabric,mode="Hover",speed=1}, inner_light_geom={glow=true,color=Color3.fromRGB(255,224,142),clearTexture=true}}},
	-- Studio MCP generate_mesh, 0f763941-9617-4662-8824-ee8202b9191b (2026-09-16).
	NorthPole_MagicSnowGlobe = {asset=111135401048404, primary="base_geom", meshes={
		["star_geom"]="rbxassetid://106325803741238",
		["pine_geom"]="rbxassetid://140655893795921",
		["cabin_geom"]="rbxassetid://116279578160380",
		["glass_geom"]="rbxassetid://127988657963229",
		["base_geom"]="rbxassetid://134484049553731",
	}, finishes={base_geom={material=Enum.Material.Wood}, glass_geom={material=Enum.Material.Glass,transparency=0.75,clearTexture=true,color=Color3.fromRGB(205,230,255)}, star_geom={glow=true,color=Color3.fromRGB(255,224,142),clearTexture=true,mode="Orbit",speed=0.3}}},
	-- Studio MCP generate_mesh, f296db98-2991-4151-be65-343e947153a1 (2026-09-16).
	NorthPole_SantasHat = {asset=120263058836680, primary="hat_geom", meshes={
		["fur_geom"]="rbxassetid://91306798182458",
		["hat_geom"]="rbxassetid://81515226799856",
	}, finishes={hat_geom={material=Enum.Material.Fabric}, fur_geom={material=Enum.Material.Fabric}}},
	-- Studio MCP generate_mesh, a3eb1e2c-5786-4f87-8f02-080faadcccfb (2026-09-16).
	NorthPole_SantasGiftSack = {asset=100838161833342, primary="sack_geom", meshes={
		["light_geom"]="rbxassetid://95540814880799",
		["rope_geom"]="rbxassetid://138813752651050",
		["sack_geom"]="rbxassetid://123244904992560",
	}, finishes={sack_geom={material=Enum.Material.Fabric,color=Color3.fromRGB(65,10,22)}, rope_geom={material=Enum.Material.Fabric}, light_geom={glow=true,color=Color3.fromRGB(255,224,142),clearTexture=true}}},
	-- Studio MCP generate_mesh, 354f1748-e5ee-4c4e-95f7-165732c2a57b (2026-09-16).
	Area51_MeteorFragment = {asset=74566797233942, primary="shard_geom", meshes={
		["ring_geom"]="rbxassetid://73037553108593",
		["shard_geom"]="rbxassetid://70687890628090",
	}, finishes={shard_geom={material=Enum.Material.Slate}, ring_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, b3c92716-591f-41a6-976b-1511ec1664be (2026-09-16).
	Area51_AlienHelmet = {asset=78189831554007, primary="helmet_geom", meshes={
		["visor_geom"]="rbxassetid://133965920226095",
		["helmet_geom"]="rbxassetid://124322453626786",
	}, finishes={helmet_geom={material=Enum.Material.Metal}, visor_geom={glow=true,color=Color3.fromRGB(83,255,63),transparency=0.15,clearTexture=true}}},
	-- Studio MCP generate_mesh, 95e08813-8a91-4953-8c33-34e0603d25cb (2026-09-16).
	Area51_TopSecretFiles = {asset=97790846306449, primary="folder_geom", meshes={
		["papers_geom"]="rbxassetid://139878119934851",
		["folder_geom"]="rbxassetid://78238528167328",
	}, finishes={folder_geom={material=Enum.Material.Fabric}}},
	-- Studio MCP generate_mesh, 2a1410ac-7dc1-460b-af7e-4968f3c0aa73 (2026-09-16).
	Area51_AlienRayDevice = {asset=129839009934157, primary="device_geom", authorRotation=CFrame.Angles(0,math.pi/2,0), meshes={
		["cell_geom"]="rbxassetid://137492560560309",
		["emitter_geom"]="rbxassetid://89693321202750",
		["device_geom"]="rbxassetid://103226908722203",
	}, finishes={device_geom={material=Enum.Material.Metal}, emitter_geom={glow=true,color=Color3.fromRGB(88,255,50),clearTexture=true}, cell_geom={glow=true,color=Color3.fromRGB(153,255,112)}}},
	-- Studio MCP generate_mesh, 83a3aa99-fbdd-48b7-b977-b1f1f5b0bcbd (2026-09-16).
	Area51_AlienCrystal = {asset=93786928235643, primary="base_geom", meshes={
		["crystals_geom"]="rbxassetid://124865195316854",
		["base_geom"]="rbxassetid://102908113061304",
	}, finishes={base_geom={material=Enum.Material.Metal}, crystals_geom={glow=true,color=Color3.fromRGB(49,255,112),transparency=0.1}}},
	-- Studio MCP generate_mesh, c65f4bf7-7e96-4c20-bd33-d8ae2d842257 (2026-09-16).
	Area51_AntiGravityCube = {asset=138908142599127, primary="base_geom", meshes={
		["debris_geom"]="rbxassetid://76718718176858",
		["seams_geom"]="rbxassetid://80248981497351",
		["cube_geom"]="rbxassetid://123987510095847",
		["base_geom"]="rbxassetid://98101610486939",
	}, finishes={base_geom={material=Enum.Material.Metal}, cube_geom={mode="Spin",speed=0.22}, seams_geom={glow=true,color=Color3.fromRGB(87,241,255),clearTexture=true,mode="Spin",speed=0.22}, debris_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.25}}},
	-- Studio MCP generate_mesh, fa57c288-1858-4aa9-b21d-2d4cf2b4fff7 (2026-09-16).
	Area51_UFOCore = {asset=73403648402931, primary="shell_geom", meshes={
		["segment_b_geom"]="rbxassetid://73928627209424",
		["segment_a_geom"]="rbxassetid://131152084492061",
		["core_geom"]="rbxassetid://82929486860334",
		["shell_geom"]="rbxassetid://113372459207546",
	}, finishes={shell_geom={material=Enum.Material.Metal}, core_geom={glow=true,color=Color3.fromRGB(113,255,59),clearTexture=true,mode="Hover",speed=1}, segment_a_geom={material=Enum.Material.Metal,mode="Spin",speed=0.15}, segment_b_geom={material=Enum.Material.Metal,mode="Spin",speed=-0.15}}},
	-- Studio MCP generate_mesh, c954f839-fb09-410a-823e-16dcb0a5cb06 (2026-09-16).
	Castle_GoldenGoblet = {asset=122217002493466, primary="goblet_geom", meshes={
		["wine_geom"]="rbxassetid://94585333719235",
		["goblet_geom"]="rbxassetid://126949456421904",
	}, finishes={goblet_geom={material=Enum.Material.SmoothPlastic}, wine_geom={material=Enum.Material.Glass}}},
	-- Studio MCP generate_mesh, a825dfce-f6c8-48bf-b9ea-30103370039c (2026-09-16).
	Castle_RoyalPainting = {asset=115153745407354, primary="frame_geom", meshes={
		["stand_geom"]="rbxassetid://87332797863152",
		["portrait_geom"]="rbxassetid://125621963141238",
		["frame_geom"]="rbxassetid://95268200953308",
	}, finishes={frame_geom={material=Enum.Material.Metal}, stand_geom={material=Enum.Material.Wood}}},
	-- Studio MCP generate_mesh, b96aeaca-6018-4ca6-a694-ad5d1eb3685d (2026-09-16).
	Castle_RoyalSeal = {asset=82514225210748, primary="stamp_geom", meshes={
		["wax_geom"]="rbxassetid://87774333299427",
		["stamp_geom"]="rbxassetid://95246490718660",
	}, finishes={stamp_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, aae291de-4f91-4bbc-9c63-99644219a73f (2026-09-16).
	Castle_GoldenKey = {asset=98615420129184, primary="key_geom", authorRotation=CFrame.Angles(0,0,math.pi/2)*CFrame.Angles(math.pi/2,0,0), meshes={
		["gem_geom"]="rbxassetid://83572834898578",
		["key_geom"]="rbxassetid://135826160765912",
	}, finishes={key_geom={material=Enum.Material.Metal}, gem_geom={glow=true,color=Color3.fromRGB(177,72,255),clearTexture=true}}},
	-- Studio MCP generate_mesh, d2d9ff30-dbda-436e-9b0b-cc08805adb9f (2026-09-16).
	Castle_JeweledShield = {asset=134911969617335, primary="shield_geom", meshes={
		["stand_geom"]="rbxassetid://136124197069444",
		["gems_geom"]="rbxassetid://116976930956094",
		["shield_geom"]="rbxassetid://125805352622975",
	}, finishes={shield_geom={material=Enum.Material.Metal}, gems_geom={glow=true,color=Color3.fromRGB(255,130,90)}, stand_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, 55bdd054-b3a6-413f-9286-55449d94c266 (2026-09-16).
	Castle_RoyalTreasureChest = {asset=94127489206252, primary="chest_geom", meshes={
		["inner_light_geom"]="rbxassetid://114480714629832",
		["hover_gem_geom"]="rbxassetid://76031517919659",
		["crown_geom"]="rbxassetid://82676176097312",
		["lid_geom"]="rbxassetid://77848098477738",
		["chest_geom"]="rbxassetid://105455695563185",
	}, finishes={chest_geom={material=Enum.Material.Fabric}, lid_geom={material=Enum.Material.Metal}, crown_geom={material=Enum.Material.Metal}, hover_gem_geom={glow=true,color=Color3.fromRGB(177,72,255),clearTexture=true,mode="Hover",speed=1.2}, inner_light_geom={glow=true,color=Color3.fromRGB(255,224,142),clearTexture=true}}},
	-- Studio MCP generate_mesh, 0113e8f2-d6bb-46c2-b2cd-c0eaa1179f46 (2026-09-16).
	Pirate_CaptainsHat = {asset=103102831491969, primary="hat_geom", meshes={
		["skull_badge_geom"]="rbxassetid://80945403095686",
		["feather_geom"]="rbxassetid://121235675240437",
		["hat_geom"]="rbxassetid://115345034376823",
	},finishes={hat_geom={material=Enum.Material.Fabric}, feather_geom={material=Enum.Material.Fabric}}},
	-- Studio MCP generate_mesh, af420ba9-3f05-4f1e-939a-35ab671c307c (2026-09-16).
	Pirate_CursedCoin = {asset=137142422950433, primary="coin_geom", meshes={
		["satellite_coins_geom"]="rbxassetid://114479267250456",
		["orbit_ring_geom"]="rbxassetid://97883487796091",
		["coin_geom"]="rbxassetid://117722438679161",
	},finishes={coin_geom={material=Enum.Material.Metal}, orbit_ring_geom={glow=true,color=Color3.fromRGB(112,45,215),clearTexture=true,mode="Spin",speed=0.2}, satellite_coins_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.35}}},
	-- Studio MCP generate_mesh, 1baae729-1f19-4f15-8052-494100a7ffc0 (2026-09-16).
	Pirate_TreasureMap = {asset=98242405550902, primary="parchment_geom", meshes={
		["twine_geom"]="rbxassetid://107857940895324",
		["parchment_geom"]="rbxassetid://110655926491518",
	}, finishes={parchment_geom={material=Enum.Material.Fabric}, twine_geom={material=Enum.Material.Fabric}}},
	-- Studio MCP generate_mesh, e02998a6-8186-486a-98f7-c1b34a3549e8 (2026-09-16).
	Pirate_GoldenCompass = {asset=106094860937174, primary="case_geom", meshes={
		["glass_geom"]="rbxassetid://112833406656214",
		["dial_geom"]="rbxassetid://76322563704620",
		["lid_geom"]="rbxassetid://92513364634071",
		["case_geom"]="rbxassetid://114166408168414",
	}, finishes={case_geom={material=Enum.Material.Metal}, lid_geom={material=Enum.Material.Metal}, glass_geom={material=Enum.Material.Glass, transparency=0.6, clearTexture=true, color=Color3.fromRGB(230,245,255)}}},
	-- Studio MCP generate_mesh, 4b78bf1c-1948-4039-92a8-5cef21ceeab2 (2026-09-16).
	Pirate_GoldenHook = {asset=113406777327550, primary="hook_geom", meshes={
		["cuff_geom"]="rbxassetid://111390378447011",
		["hook_geom"]="rbxassetid://140229809317792",
	}, finishes={hook_geom={material=Enum.Material.Metal}, cuff_geom={material=Enum.Material.Fabric}}},
	-- Studio MCP generate_mesh, 81e51636-0618-4ce5-b715-b499624444ca (2026-09-16).
	Pirate_TreasureChest = {asset=121257547949969, primary="chest_geom", meshes={
		["inner_glow_geom"]="rbxassetid://73277298214084",
		["treasure_geom"]="rbxassetid://105732428769684",
		["lid_geom"]="rbxassetid://105207001945124",
		["chest_geom"]="rbxassetid://102672946283675",
	}, finishes={chest_geom={material=Enum.Material.Wood}, lid_geom={material=Enum.Material.Wood}, treasure_geom={material=Enum.Material.Metal}, inner_glow_geom={glow=true, clearTexture=true, color=Color3.fromRGB(255,179,60)}}},
	-- Studio MCP generate_mesh, e1f134ce-6af2-4c13-9f00-a1504271e2d3 (2026-09-16).
	Pirate_CaptainsCutlass = {asset=74993511030038, primary="blade_geom", meshes={
		["mount_geom"]="rbxassetid://86202131157637",
		["grip_geom"]="rbxassetid://122485389368217",
		["hilt_geom"]="rbxassetid://70617068715145",
		["blade_geom"]="rbxassetid://87867377571837",
	}, finishes={blade_geom={material=Enum.Material.Metal}, hilt_geom={material=Enum.Material.Metal}, grip_geom={material=Enum.Material.Fabric}, mount_geom={material=Enum.Material.Slate}}},
	-- Studio MCP generate_mesh, 8e2954f3-d16a-47af-8ee7-9bc147c10321 (2026-09-16).
	Pirate_JeweledSkull = {asset=126677246884152, primary="skull_geom", meshes={
		["brow_band_geom"]="rbxassetid://129608764982123",
		["eyes_geom"]="rbxassetid://93591377398186",
		["skull_geom"]="rbxassetid://113400013654251",
	}, finishes={skull_geom={material=Enum.Material.Marble}, brow_band_geom={material=Enum.Material.Metal}, eyes_geom={glow=true, clearTexture=true, color=Color3.fromRGB(20,255,102)}}},
	-- Studio MCP generate_mesh, dbb2d898-5d29-462d-961f-2f03b4d0cf10 (2026-09-16).
	Museum_PharaohMask = {asset=89885023945258, primary="mask_geom", meshes={
		["headdress_geom"]="rbxassetid://74694780901052",
		["mask_geom"]="rbxassetid://87585968350974",
	}},
	-- Studio MCP generate_mesh, 2b7047c4-c65d-4f39-860d-a1fef4a14c55 (2026-09-16).
	Museum_Meteorite = {asset=132844588760781, primary="rock_geom", meshes={
		["display_ring_geom"]="rbxassetid://133116366119719",
		["fissures_geom"]="rbxassetid://139224356390479",
		["rock_geom"]="rbxassetid://110658841101781",
	}},
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

