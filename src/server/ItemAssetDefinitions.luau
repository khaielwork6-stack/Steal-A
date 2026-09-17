--!strict
-- ItemAssetDefinitions
-- DATA ONLY: the published asset id, mesh ids, primary part, finishes and
-- revision of every generated loot item that ItemAssetBuilder installs into
-- ServerStorage.GameAssets.Loot. Moved out of ItemAssetBuilder.luau so the
-- ~600 lines of ids do not bury the build code. Editing a row here is how an
-- item's generated art changes; bump its `revision` (or ItemAssetBuilder's
-- ART_VERSION for a shared change) so saved models are rebuilt.

export type Finish = {material: Enum.Material?, color: Color3?, transparency: number?, glow: boolean?,
	mode: string?, speed: number?, axis: string?, clearTexture: boolean?}
export type Definition = {revision: number?, additionalAssets: {number}?, asset: number, primary: string, meshes: {[string]: string}, finishes: {[string]: Finish}?, authorRotation: CFrame?}
local DEFINITIONS: {[string]: Definition} = {
	-- Studio MCP generate_mesh, 5136680d-1be8-4d88-8b53-67717387228d (2026-09-16).
	-- Empty plate generated separately: 924d74e8-5a7d-4669-b489-082801c85101 / model 134967079944754.
	Grandma_CandyBowl = {revision=2,asset=118335755745507,additionalAssets={134967079944754},primary="cookies_geom",meshes={
		["cookies_geom"]="rbxassetid://125746011321253",
		["plate_geom"]="rbxassetid://133374951030376",
	},finishes={cookies_geom={material=Enum.Material.SmoothPlastic},plate_geom={material=Enum.Material.SmoothPlastic}}},
	-- Separate Studio meshes: jar 6fb65bd2-fa43-4e82-8266-d6d75f248af7; creature 4e8d7e5f-b5c6-421e-85e1-8dc0522a5893.
	SecretLab_SecretFormula = {asset=79232455189752,additionalAssets={123713422108541},primary="jar_geom",meshes={
		["lid_geom"]="rbxassetid://90311349781801",
		["jar_geom"]="rbxassetid://91204403336413",
		["creature_geom"]="rbxassetid://135066657753512",
	},finishes={jar_geom={material=Enum.Material.Glass,transparency=0.87,clearTexture=true,color=Color3.fromRGB(222,255,237)},lid_geom={material=Enum.Material.Metal},creature_geom={material=Enum.Material.SmoothPlastic,mode="Hover",speed=1.0}}},

	-- Studio MCP generate_mesh, a3e1ebcb-a58e-4335-900e-a61d23584a73 (2026-09-16).
	SecretLab_ChemicalCylinder = {asset=110305125083895, primary="cylinder_geom", meshes={
		["window_geom"]="rbxassetid://84697275082637",
		["valve_geom"]="rbxassetid://71269279706297",
		["cylinder_geom"]="rbxassetid://99719968566070",
	}, finishes={cylinder_geom={material=Enum.Material.Metal}, valve_geom={material=Enum.Material.Metal}, window_geom={glow=true,clearTexture=true,color=Color3.fromRGB(106,255,80)}}},
	-- Studio MCP generate_mesh, 2825b016-a6f5-4d14-b7f4-3fe54289f384 (2026-09-16).
	SecretLab_ContainmentTank = {asset=105064361391832, primary="frame_geom", meshes={
		["specimen_geom"]="rbxassetid://108388815563140",
		["fluid_geom"]="rbxassetid://129046285666803",
		["glass_geom"]="rbxassetid://100492957953094",
		["frame_geom"]="rbxassetid://121625256587596",
	}, finishes={frame_geom={material=Enum.Material.Metal}, glass_geom={material=Enum.Material.Glass,transparency=0.85,clearTexture=true,color=Color3.fromRGB(196,242,255)}, fluid_geom={glow=true,color=Color3.fromRGB(71,234,255),transparency=0.72,clearTexture=true}, specimen_geom={material=Enum.Material.SmoothPlastic,mode="Hover",speed=1.1}}},
	-- Studio MCP generate_mesh, a5b37653-2fac-4422-800f-30ea32ca93a9 (2026-09-16).
	SecretLab_RobotSpider = {asset=118928598803711, primary="body_geom", meshes={
		["satellite_geom"]="rbxassetid://134368225869226",
		["sensors_geom"]="rbxassetid://105835129327101",
		["legs_geom"]="rbxassetid://131749563825217",
		["body_geom"]="rbxassetid://113510420546951",
	}, finishes={body_geom={material=Enum.Material.Metal}, legs_geom={material=Enum.Material.Metal}, sensors_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,54,58)}, satellite_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.2}}},
	-- Studio MCP generate_mesh, 758cc70a-5593-459a-99be-913bb9b8099e (2026-09-16).
	SecretLab_MutationCrystal = {asset=80867123485295, primary="base_geom", meshes={
		["crystals_geom"]="rbxassetid://80313655219224",
		["base_geom"]="rbxassetid://113774794993687",
	}, finishes={base_geom={material=Enum.Material.Slate,color=Color3.fromRGB(17,22,35)}, crystals_geom={glow=true,clearTexture=true,color=Color3.fromRGB(26,104,255)}}},
	-- Studio MCP generate_mesh, f629a860-11dc-4497-935a-e7170c57b32b (2026-09-16).
	SecretLab_CyanPlasma = {asset=128993140443671, primary="ring_geom", meshes={
		["arcs_geom"]="rbxassetid://96522103944268",
		["core_geom"]="rbxassetid://75702558937249",
		["ring_geom"]="rbxassetid://136214337191781",
	}, finishes={ring_geom={material=Enum.Material.Metal}, core_geom={glow=true,clearTexture=true,color=Color3.fromRGB(66,235,255),mode="Hover",speed=0.8}, arcs_geom={glow=true,clearTexture=true,color=Color3.fromRGB(66,235,255)}}},
	-- Studio MCP generate_mesh, 6cc8c686-65dc-46f8-b4a4-4c8bfa67c59b (2026-09-16).
	SecretLab_EnergyCore = {asset=74355149095886, primary="canister_geom", meshes={
		["shafts_geom"]="rbxassetid://70426571043199",
		["halos_geom"]="rbxassetid://105976400276429",
		["core_geom"]="rbxassetid://84220646909555",
		["glass_geom"]="rbxassetid://132621841968889",
		["canister_geom"]="rbxassetid://71213076802776",
	}, finishes={canister_geom={material=Enum.Material.Metal}, glass_geom={material=Enum.Material.Glass,transparency=0.85,clearTexture=true,color=Color3.fromRGB(240,251,255)}, core_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,248,224)}, halos_geom={material=Enum.Material.Metal}, shafts_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,248,224)}}},
	-- Studio MCP generate_mesh, e20e27e4-a183-4f4f-9af6-00fe739523c1 (2026-09-16).
	Bank_CashBag = {asset=77206487977847, primary="press_geom", meshes={
		["slot_geom"]="rbxassetid://124383805408936",
		["notes_geom"]="rbxassetid://116366412651806",
		["crank_geom"]="rbxassetid://137051203666181",
		["press_geom"]="rbxassetid://122989386033478",
	}, finishes={press_geom={material=Enum.Material.Metal}, crank_geom={material=Enum.Material.Metal}, notes_geom={material=Enum.Material.Cardboard}, slot_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, 8c96b2e2-007f-48b1-898e-c42853ebe026 (2026-09-16).
	Bank_VaultKey = {asset=134290985779216, primary="key_geom", meshes={
		["lock_geom"]="rbxassetid://95918644908148",
		["key_geom"]="rbxassetid://115805830426254",
	}, finishes={key_geom={material=Enum.Material.Metal}, lock_geom={glow=true,clearTexture=true,color=Color3.fromRGB(71,255,134),mode="Orbit",speed=0.18}}},
	-- Studio MCP generate_mesh, 82793c8b-0444-4607-8884-a778d68e2f42 (2026-09-16).
	Bank_RareCoin = {asset=85170106335080, primary="coin_geom", meshes={
		["satellites_geom"]="rbxassetid://134422270428979",
		["coin_geom"]="rbxassetid://125616976713108",
	}, finishes={coin_geom={material=Enum.Material.Metal}, satellites_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.27}}},
	-- Studio MCP generate_mesh, fca8a498-284c-483c-9220-5301300f4dd1 (2026-09-16).
	Bank_GoldBar = {asset=116635368133671, primary="bar_geom", authorRotation=CFrame.Angles(0,math.pi/2,0), meshes={
		["satellites_geom"]="rbxassetid://139908587681120",
		["bar_geom"]="rbxassetid://107711067671284",
	}, finishes={bar_geom={material=Enum.Material.Metal}, satellites_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.2}}},
	-- Studio MCP generate_mesh, 683297cf-7ffe-4326-bd7b-af901afcd231 (2026-09-16).
	Bank_BankersBriefcase = {asset=112710390177395, primary="case_geom", meshes={
		["light_geom"]="rbxassetid://83022572745958",
		["lid_geom"]="rbxassetid://84193023668624",
		["case_geom"]="rbxassetid://137147088822972",
	}, finishes={case_geom={material=Enum.Material.Leather}, lid_geom={material=Enum.Material.Leather}, light_geom={glow=true,clearTexture=true,color=Color3.fromRGB(157,255,74)}}},
	-- Studio MCP generate_mesh, 936ff28f-5b39-4dbc-b82a-9e0fe8772edf (2026-09-16).
	Bank_PlatinumBullionStack = {asset=116502120155472, primary="bars_geom", meshes={
		["edges_geom"]="rbxassetid://112747464782818",
		["bars_geom"]="rbxassetid://73702209782596",
	}, finishes={bars_geom={material=Enum.Material.Metal,color=Color3.fromRGB(35,41,48)}, edges_geom={glow=true,clearTexture=true,color=Color3.fromRGB(143,249,255)}}},
	-- Studio MCP generate_mesh, a611a9ce-5f02-4ba0-8b50-5e58149d892c (2026-09-16).
	Bank_VendingMachine = {asset=95559568387895, primary="machine_geom", meshes={
		["shafts_geom"]="rbxassetid://84609455396306",
		["halos_geom"]="rbxassetid://76868807194480",
		["shelves_geom"]="rbxassetid://72294373792611",
		["glass_geom"]="rbxassetid://114378297477408",
		["machine_geom"]="rbxassetid://138286011063093",
	}, finishes={machine_geom={material=Enum.Material.Metal}, glass_geom={material=Enum.Material.Glass,transparency=0.8,clearTexture=true,color=Color3.fromRGB(219,252,245)}, shelves_geom={material=Enum.Material.Metal}, halos_geom={material=Enum.Material.Metal}, shafts_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, 6c732662-f452-4b24-b91f-0a043cbecbfb (2026-09-16).
	Bank_MoneyStack = {asset=128850277445732, primary="bills_geom", meshes={
		["band_geom"]="rbxassetid://136499775864929",
		["bills_geom"]="rbxassetid://110162836431702",
	}, finishes={bills_geom={material=Enum.Material.Cardboard}, band_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, 8d902918-1235-4df4-8832-891e5dcd83aa (2026-09-16).
	Airport_FirstClassTicket = {asset=101701577550942, primary="badge_geom", meshes={
		["star_geom"]="rbxassetid://100127402917749",
		["badge_geom"]="rbxassetid://84313465518548",
	}, finishes={badge_geom={material=Enum.Material.SmoothPlastic}, star_geom={material=Enum.Material.SmoothPlastic}}},
	-- Studio MCP generate_mesh, c457dfd6-218b-4284-bbad-4d3655c4289f (2026-09-16).
	Airport_VIPPassport = {asset=121731400843124, primary="airplane_geom", meshes={
		["engines_geom"]="rbxassetid://136495987263827",
		["airplane_geom"]="rbxassetid://117519934939818",
	}, finishes={airplane_geom={material=Enum.Material.SmoothPlastic}, engines_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, 18140b5d-ca1a-4b0c-b255-9474f580f756 (2026-09-16).
	Airport_PilotsHat = {asset=139936612524803, primary="hat_geom", meshes={
		["badge_geom"]="rbxassetid://107044563621983",
		["brim_geom"]="rbxassetid://137434564042463",
		["hat_geom"]="rbxassetid://84932879528849",
	}, finishes={hat_geom={material=Enum.Material.Fabric}, brim_geom={material=Enum.Material.Leather}, badge_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, d353f1ed-bfc1-49f6-bec2-399b3ad49789 (2026-09-16).
	Airport_LostBriefcase = {asset=117260289021527, primary="case_geom", meshes={
		["clasp_geom"]="rbxassetid://133400372352980",
		["tags_geom"]="rbxassetid://106878321592931",
		["case_geom"]="rbxassetid://77393799541876",
	}, finishes={case_geom={material=Enum.Material.Leather}, tags_geom={material=Enum.Material.Cardboard}, clasp_geom={glow=true,clearTexture=true,color=Color3.fromRGB(100,218,255)}}},
	-- Studio MCP generate_mesh, 36aca6b8-46ef-4817-af2d-30f8fdc4c83f (2026-09-16).
	Airport_UnknownBriefcase = {asset=125198735210755, primary="case_geom", meshes={
		["light_geom"]="rbxassetid://122338407224998",
		["lid_geom"]="rbxassetid://81900067385978",
		["case_geom"]="rbxassetid://112308097590575",
	}, finishes={case_geom={material=Enum.Material.Leather}, lid_geom={material=Enum.Material.Leather}, light_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, 04cd5e61-fc66-4644-acb3-ae6e03ad4c00 (2026-09-16).
	Airport_PilotsLuggage = {asset=117126095331567, primary="case_geom", meshes={
		["tags_geom"]="rbxassetid://98114024287250",
		["bag_geom"]="rbxassetid://98898796921575",
		["handle_geom"]="rbxassetid://130865379619974",
		["case_geom"]="rbxassetid://137853609510070",
	}, finishes={case_geom={material=Enum.Material.SmoothPlastic}, handle_geom={material=Enum.Material.Metal,mode="Hover",speed=1}, bag_geom={material=Enum.Material.Leather,mode="Hover",speed=0.8}, tags_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,184,63)}}},
	-- Studio MCP generate_mesh, 7da57c01-5bee-4c91-917e-ffc66f12af85 (2026-09-16).
	Airport_AirTower = {asset=89320963393606, primary="tower_geom", meshes={
		["aircraft_geom"]="rbxassetid://85306211301620",
		["beacon_geom"]="rbxassetid://140489858313292",
		["glass_geom"]="rbxassetid://104536823112394",
		["tower_geom"]="rbxassetid://79348114220032",
	}, finishes={tower_geom={material=Enum.Material.Concrete}, glass_geom={material=Enum.Material.Glass,transparency=0.3}, beacon_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,194,77),mode="Spin",speed=0.3}, aircraft_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.25}}},
	-- Studio MCP generate_mesh, a33e183e-c9eb-453f-82a3-7bb239fdd28d (2026-09-16).
	Airport_PrivateJet = {asset=138414525941714, primary="jet_geom", authorRotation=CFrame.Angles(0,math.pi/4,math.rad(-12)), meshes={
		["wisps_geom"]="rbxassetid://78326777478453",
		["shafts_geom"]="rbxassetid://93498899762381",
		["outer_halo_geom"]="rbxassetid://110288078809359",
		["middle_halo_geom"]="rbxassetid://120662935874314",
		["inner_halo_geom"]="rbxassetid://82320556606002",
		["engines_geom"]="rbxassetid://136554491146445",
		["jet_geom"]="rbxassetid://135407960579630",
	}, finishes={jet_geom={material=Enum.Material.Metal}, engines_geom={material=Enum.Material.Metal}, inner_halo_geom={material=Enum.Material.Metal}, middle_halo_geom={material=Enum.Material.Metal}, outer_halo_geom={material=Enum.Material.Metal}, shafts_geom={material=Enum.Material.Metal}, wisps_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, 8b229cca-a65b-4e6a-b826-5eeb32e5c091 (2026-09-16).
	Construction_Blueprints = {asset=138568158660441, primary="paper_geom", meshes={
		["lines_geom"]="rbxassetid://117185809553396",
		["square_geom"]="rbxassetid://138214017069900",
		["paper_geom"]="rbxassetid://124092497366981",
	}, finishes={paper_geom={material=Enum.Material.Cardboard}, square_geom={material=Enum.Material.Metal}, lines_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,240,210)}}},
	-- Studio MCP generate_mesh, 9a1d21f6-e5cc-4871-8fdd-9270d9f89952 (2026-09-16).
	Construction_RareSafetyVest = {asset=107678563600349, primary="vest_geom", meshes={
		["bands_geom"]="rbxassetid://84581493513681",
		["stand_geom"]="rbxassetid://89329991512923",
		["vest_geom"]="rbxassetid://101544972212187",
	}, finishes={vest_geom={material=Enum.Material.Fabric}, stand_geom={material=Enum.Material.Metal}, bands_geom={glow=true,clearTexture=true,color=Color3.fromRGB(235,248,255)}}},
	-- Studio MCP generate_mesh, 928a338b-6354-4968-8962-2b4b7a8e2610 (2026-09-16).
	Construction_ForemansToolbox = {asset=103585399184781, primary="box_geom", meshes={
		["light_geom"]="rbxassetid://84174373254520",
		["wrench_geom"]="rbxassetid://128742469830912",
		["tools_geom"]="rbxassetid://132969664491111",
		["lid_geom"]="rbxassetid://79403465307124",
		["box_geom"]="rbxassetid://136856877744152",
	}, finishes={box_geom={material=Enum.Material.Metal}, lid_geom={material=Enum.Material.Metal}, tools_geom={material=Enum.Material.Metal}, wrench_geom={material=Enum.Material.Metal,mode="Hover",speed=1.1}, light_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,225,143)}}},
	-- Studio MCP generate_mesh, 98110924-fa61-4622-b1de-a95181ae389b (2026-09-16).
	Construction_MetalFence = {asset=107276218035965, primary="frame_geom", meshes={
		["satellite_geom"]="rbxassetid://122407522457552",
		["links_geom"]="rbxassetid://101884021085468",
		["frame_geom"]="rbxassetid://125226870267971",
	}, finishes={frame_geom={material=Enum.Material.Metal}, links_geom={material=Enum.Material.Metal}, satellite_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.2}}},
	-- Studio MCP generate_mesh, 8722167f-d35e-472b-8432-5499772ef72a (2026-09-16).
	Construction_GoldenHardHat = {asset=78371115508656, primary="hat_geom", meshes={
		["rivet_geom"]="rbxassetid://139373793599153",
		["cone_geom"]="rbxassetid://94667212219082",
		["lamp_geom"]="rbxassetid://97338826404167",
		["hat_geom"]="rbxassetid://96755159504689",
	}, finishes={hat_geom={material=Enum.Material.Metal}, lamp_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,225,143)}, cone_geom={glow=true,color=Color3.fromRGB(255,225,143),clearTexture=true,transparency=0.8}, rivet_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.3}}},
	-- Studio MCP generate_mesh, c50d4da6-9bbe-45b9-a3b8-3abd1635189d (2026-09-16).
	Construction_GoldenDrill = {asset=132100698404804, primary="body_geom", authorRotation=CFrame.Angles(0,math.pi/2,0), meshes={
		["mount_geom"]="rbxassetid://106592262775262",
		["bit_geom"]="rbxassetid://131745763322937",
		["chuck_geom"]="rbxassetid://96168701233413",
		["body_geom"]="rbxassetid://119924097406936",
	}, finishes={body_geom={material=Enum.Material.Rubber,color=Color3.fromRGB(25,28,30)}, chuck_geom={material=Enum.Material.Metal}, bit_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,160,22)}, mount_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, 5eb5e06a-fab8-41ff-bcac-ac5b9340675d (2026-09-16).
	Construction_BossLadder = {asset=127705936911428, primary="ladder_geom", authorRotation=CFrame.Angles(0,math.pi/4,0), meshes={
		["shafts_geom"]="rbxassetid://122080741753463",
		["rungs_geom"]="rbxassetid://80948716087175",
		["halos_geom"]="rbxassetid://76633438154675",
		["ladder_geom"]="rbxassetid://138286407884387",
	}, finishes={ladder_geom={material=Enum.Material.Metal}, halos_geom={material=Enum.Material.Metal}, rungs_geom={material=Enum.Material.Metal}, shafts_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, a13376d4-6d80-4e7a-9446-d3d14bdd1a0a (2026-09-16).
	Construction_DiamondHammer = {asset=109721953383130, primary="haft_geom", meshes={
		["shafts_geom"]="rbxassetid://123183206282256",
		["shards_geom"]="rbxassetid://72767082764648",
		["outer_halo_geom"]="rbxassetid://130041825988928",
		["middle_halo_geom"]="rbxassetid://71005026898277",
		["inner_halo_geom"]="rbxassetid://129409518228755",
		["head_geom"]="rbxassetid://100416245690437",
		["haft_geom"]="rbxassetid://77272130582418",
	}, finishes={haft_geom={material=Enum.Material.Wood}, head_geom={material=Enum.Material.Glass,transparency=0.12}, inner_halo_geom={material=Enum.Material.Metal}, middle_halo_geom={material=Enum.Material.Metal}, outer_halo_geom={material=Enum.Material.Metal}, shards_geom={material=Enum.Material.Metal}, shafts_geom={material=Enum.Material.Metal}}},
	-- Studio MCP generate_mesh, b1305c82-5a11-4a4a-ba7c-82af5ccdac58 (2026-09-16).
	Grandma_KnittedSweater = {asset=74205462266801, primary="sweater_geom", meshes={
		["accent_geom"]="rbxassetid://82855031555761",
		["buttons_geom"]="rbxassetid://75456316431946",
		["sweater_geom"]="rbxassetid://72498454391945",
	}, finishes={sweater_geom={material=Enum.Material.Fabric}, buttons_geom={material=Enum.Material.Metal}, accent_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,225,143)}}},
	-- Studio MCP generate_mesh, 282db476-0191-475a-8d4b-c430f78eb05a (2026-09-16).
	Grandma_WalkingCane = {asset=122734549309930, primary="cane_geom", meshes={
		["gem_geom"]="rbxassetid://116322740348275",
		["inlay_geom"]="rbxassetid://114003071585821",
		["cane_geom"]="rbxassetid://72914730115848",
	}, finishes={cane_geom={material=Enum.Material.Wood}, inlay_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,225,143)}, gem_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,146,195),mode="Hover",speed=1.1}}},
	-- Studio MCP generate_mesh, 72589e64-3aa9-479a-a280-5ab80cfff94b (2026-09-16).
	Grandma_GoldenTeapot = {asset=90830424831441, primary="pot_geom", meshes={
		["cup_geom"]="rbxassetid://128706204779432",
		["lid_geom"]="rbxassetid://84237060317733",
		["pot_geom"]="rbxassetid://87075590136123",
	}, finishes={pot_geom={material=Enum.Material.Metal}, lid_geom={material=Enum.Material.Metal,mode="Hover",speed=1}, cup_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.22}}},
	-- Studio MCP generate_mesh, fc611cc7-0555-4c37-acca-9f47efd75ac6 (2026-09-16).
	Grandma_AntiqueClock = {asset=103011275211966, primary="case_geom", meshes={
		["face_geom"]="rbxassetid://91142281155291",
		["pendulum_geom"]="rbxassetid://120503609532488",
		["glass_geom"]="rbxassetid://125665921462377",
		["case_geom"]="rbxassetid://106861223672400",
	}, finishes={case_geom={material=Enum.Material.Wood}, glass_geom={material=Enum.Material.Glass,transparency=0.85,clearTexture=true,color=Color3.fromRGB(236,242,255)}, pendulum_geom={material=Enum.Material.Metal,mode="Swing",axis="Z",speed=1.5}, face_geom={material=Enum.Material.Marble}}},
	-- Studio MCP generate_mesh, b19829f2-a6f8-44a5-89ed-b85eae53e162 (2026-09-16).
	Grandma_GrandmasPurse = {asset=80600785455453, primary="bag_geom", meshes={
		["light_geom"]="rbxassetid://95188892302645",
		["chain_geom"]="rbxassetid://103803650721304",
		["bag_geom"]="rbxassetid://88017160346893",
	}, finishes={bag_geom={material=Enum.Material.Leather,color=Color3.fromRGB(29,22,29)}, chain_geom={material=Enum.Material.Metal}, light_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,33,147)}}},
	-- Studio MCP generate_mesh, e2e3109d-632f-453d-a330-6622baffa9c3 (2026-09-16).
	Grandma_LegendaryGiftBox = {asset=138046899572201, primary="box_geom", meshes={
		["light_geom"]="rbxassetid://87328209128799",
		["halos_geom"]="rbxassetid://126210125491428",
		["bow_geom"]="rbxassetid://107049205724913",
		["box_geom"]="rbxassetid://91198245218595",
	}, finishes={box_geom={material=Enum.Material.Foil}, bow_geom={material=Enum.Material.Metal,mode="Hover",speed=1}, halos_geom={material=Enum.Material.Metal}, light_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,248,224)}}},
	-- Studio MCP generate_mesh, 0d93cd3f-9485-4536-97ae-8fc45e4e48c9 (2026-09-16).
	Grandma_CookieJar = {asset=109723585075023, primary="jar_geom", meshes={
		["shafts_geom"]="rbxassetid://87411391168691",
		["outer_halo_geom"]="rbxassetid://116141139467205",
		["inner_halo_geom"]="rbxassetid://137960477771871",
		["cookies_geom"]="rbxassetid://91597709564420",
		["lid_geom"]="rbxassetid://129076274321237",
		["jar_geom"]="rbxassetid://124211847774371",
	}, finishes={jar_geom={material=Enum.Material.CeramicTiles}, lid_geom={material=Enum.Material.CeramicTiles,mode="Spin",speed=0.16}, cookies_geom={material=Enum.Material.Sand,mode="Orbit",speed=0.18}, inner_halo_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,248,224),mode="Spin",speed=0.16}, outer_halo_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,225,143),mode="Spin",speed=-0.13}, shafts_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,248,224)}}},
	-- Studio MCP generate_mesh, 9589fd12-ddd2-47a3-bd7d-213d65cec9a8 (2026-09-16).
	Gym_Water = {asset=96198588515189, primary="bottle_geom", meshes={
		["cap_geom"]="rbxassetid://96538009727687",
		["water_geom"]="rbxassetid://80745307073043",
		["bottle_geom"]="rbxassetid://89003574854153",
	}, finishes={bottle_geom={material=Enum.Material.Glass,transparency=0.7,clearTexture=true,color=Color3.fromRGB(220,243,255)}, water_geom={material=Enum.Material.Glass,transparency=0.3,color=Color3.fromRGB(87,183,255)}, cap_geom={material=Enum.Material.SmoothPlastic}}},
	-- Studio MCP generate_mesh, c677fe3d-07dd-413b-acaa-a4f1aea00d26 (2026-09-16).
	Gym_Creatine = {asset=99364783970111, primary="gloves_geom", meshes={
		["laces_geom"]="rbxassetid://113324348841271",
		["gloves_geom"]="rbxassetid://105908047844387",
	}, finishes={gloves_geom={material=Enum.Material.Leather}, laces_geom={material=Enum.Material.Fabric}}},
	-- Studio MCP generate_mesh, 15be7e1b-c1f0-44e4-a94d-a51a33816475 (2026-09-16).
	Gym_VanillaMilkshake = {asset=134226222063906, primary="glass_geom", meshes={
		["cherry_geom"]="rbxassetid://120338609150173",
		["straw_geom"]="rbxassetid://124903221098482",
		["shake_geom"]="rbxassetid://112221233988909",
		["glass_geom"]="rbxassetid://79222005277270",
	}, finishes={glass_geom={material=Enum.Material.Glass,transparency=0.55,clearTexture=true,color=Color3.fromRGB(236,249,255)}, shake_geom={material=Enum.Material.Marble}, straw_geom={material=Enum.Material.SmoothPlastic}, cherry_geom={mode="Hover",speed=1.3}}},
	-- Studio MCP generate_mesh, f4d06276-e0c0-4c84-8114-1f782a16db32 (2026-09-16).
	Gym_Airpods = {asset=99528368303261, primary="case_geom", meshes={
		["charge_geom"]="rbxassetid://116243522350418",
		["buds_geom"]="rbxassetid://134800406817604",
		["lid_geom"]="rbxassetid://115694455532963",
		["case_geom"]="rbxassetid://116450112765869",
	}, finishes={case_geom={material=Enum.Material.Metal}, lid_geom={material=Enum.Material.Metal}, buds_geom={material=Enum.Material.Metal,mode="Spin",speed=0.25}, charge_geom={glow=true,clearTexture=true,color=Color3.fromRGB(66,235,255)}}},
	-- Studio MCP generate_mesh, f3cb2c82-3653-441f-9bae-01fb79bf5960 (2026-09-16).
	Gym_Trophy = {asset=140067772940326, primary="cup_geom", meshes={
		["flutes_geom"]="rbxassetid://72539923159002",
		["base_geom"]="rbxassetid://87555293277470",
		["cup_geom"]="rbxassetid://112964306592045",
	}, finishes={cup_geom={material=Enum.Material.Metal,color=Color3.fromRGB(25,23,21)}, base_geom={material=Enum.Material.Marble}, flutes_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,248,224)}}},
	-- Studio MCP generate_mesh, 65114891-8594-457c-8c28-01132e1d75fe (2026-09-16).
	Gym_GoldenBarbell = {asset=92647840220934, primary="barbell_geom", meshes={
		["radiance_geom"]="rbxassetid://136595901475918",
		["right_halo_geom"]="rbxassetid://99457159698636",
		["left_halo_geom"]="rbxassetid://126491042024095",
		["barbell_geom"]="rbxassetid://82557275086350",
	}, finishes={barbell_geom={material=Enum.Material.Metal}, left_halo_geom={material=Enum.Material.Metal,color=Color3.fromRGB(231,176,60),clearTexture=true}, right_halo_geom={material=Enum.Material.Metal,color=Color3.fromRGB(231,176,60),clearTexture=true}, radiance_geom={material=Enum.Material.Metal,color=Color3.fromRGB(231,176,60),clearTexture=true}}},
	-- Studio MCP generate_mesh, f55398d1-99b6-419b-83e4-2a908d96e886 (2026-09-16).
	Gym_GoldenDumbbell = {asset=86586912211805, primary="left_dumbbell_geom", authorRotation=CFrame.identity, meshes={
		["orbit_plate_geom"]="rbxassetid://108157156947102",
		["right_dumbbell_geom"]="rbxassetid://74379116334491",
		["left_dumbbell_geom"]="rbxassetid://91862468168813",
	}, finishes={left_dumbbell_geom={material=Enum.Material.Metal}, right_dumbbell_geom={material=Enum.Material.Metal}, orbit_plate_geom={material=Enum.Material.Metal,mode="Orbit",speed=0.25}}},
	-- Studio MCP generate_mesh, 4cf77cbd-495c-45cf-bbd1-ab01fcaa695a (2026-09-16).
	Gym_CoachsWhistle = {asset=124460882028053, primary="whistle_geom", authorRotation=CFrame.identity, meshes={
		["lanyard_geom"]="rbxassetid://113352432198346",
		["whistle_geom"]="rbxassetid://113872290674784",
	}, finishes={whistle_geom={material=Enum.Material.Metal}, lanyard_geom={material=Enum.Material.Fabric}}},
	-- Studio MCP generate_mesh, ebc08536-a0c2-47e0-804d-50a97c68b347 (2026-09-16).
	Egypt_CanopicJar = {asset=122152560581491, primary="scepter_geom", meshes={
		["inlay_geom"]="rbxassetid://100894811243168",
		["scepter_geom"]="rbxassetid://129652639172131",
	}, finishes={scepter_geom={material=Enum.Material.Metal}, inlay_geom={material=Enum.Material.Glass}}},
	-- Studio MCP generate_mesh, a0792a8c-61b8-442d-b870-7c0d0f5a7dfe (2026-09-16).
	Egypt_Shawarma = {asset=113273470724173, primary="wrap_geom", authorRotation=CFrame.Angles(-math.pi/2,0,0), meshes={
		["foil_geom"]="rbxassetid://73487881122935",
		["filling_geom"]="rbxassetid://108104201781428",
		["wrap_geom"]="rbxassetid://79375772861048",
	}, finishes={wrap_geom={material=Enum.Material.Sand}, foil_geom={material=Enum.Material.Foil}}},
	-- Studio MCP generate_mesh, 7262c26e-9444-4eb0-a59c-f8cd1cd5a49e (2026-09-16).
	Egypt_AncientMau = {asset=126944060001505, primary="cat_geom", meshes={
		["eyes_geom"]="rbxassetid://71349940859395",
		["collar_geom"]="rbxassetid://112135074054477",
		["cat_geom"]="rbxassetid://82892874081507",
	}, finishes={cat_geom={material=Enum.Material.Granite}, collar_geom={material=Enum.Material.Metal}, eyes_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,180,32)}}},
	-- Studio MCP generate_mesh, 9e1a8a29-a219-4073-b4dd-ca63bab98f47 (2026-09-16).
	Egypt_AncientScroll = {asset=109898056081088, primary="papyrus_geom", authorRotation=CFrame.Angles(math.pi/2,0,0), meshes={
		["glyphs_geom"]="rbxassetid://132705105612048",
		["rods_geom"]="rbxassetid://77491074433181",
		["papyrus_geom"]="rbxassetid://84603250801962",
	}, finishes={papyrus_geom={material=Enum.Material.Fabric}, rods_geom={material=Enum.Material.Metal}, glyphs_geom={glow=true,clearTexture=true,color=Color3.fromRGB(48,231,190)}}},
	-- Studio MCP generate_mesh, 10552504-6335-40ff-9a80-e9fd176ca304 (2026-09-16).
	Egypt_ThroneOfRa = {asset=132184997346555, primary="throne_geom", meshes={
		["solar_disc_geom"]="rbxassetid://84129836519924",
		["falcons_geom"]="rbxassetid://74716538527404",
		["throne_geom"]="rbxassetid://140063989081048",
	}, finishes={throne_geom={material=Enum.Material.Granite,color=Color3.fromRGB(22,25,29)}, falcons_geom={material=Enum.Material.Metal}, solar_disc_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,183,50)}}},
	-- Studio MCP generate_mesh, c18ee980-701f-47a8-acb5-bf00808b4967 (2026-09-16).
	Egypt_NemesMask = {asset=74512256472323, primary="mask_geom", meshes={
		["outer_halo_geom"]="rbxassetid://100980557126559",
		["inner_halo_geom"]="rbxassetid://105679677256974",
		["cobra_geom"]="rbxassetid://86541433445808",
		["mask_geom"]="rbxassetid://110603859949046",
	}, finishes={mask_geom={material=Enum.Material.Metal}, cobra_geom={material=Enum.Material.Metal}, inner_halo_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,248,224),mode="Spin",speed=0.16}, outer_halo_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,225,143),mode="Spin",speed=-0.12}}},
	-- Studio MCP generate_mesh, a3d3f8bc-49ba-478c-8830-3b8c7b63a33a (2026-09-16).
	Egypt_EgyptianPyramid = {asset=124616533546449, primary="pyramid_geom", meshes={
		["light_geom"]="rbxassetid://122624038956508",
		["halo_geom"]="rbxassetid://105017350275623",
		["glyphs_geom"]="rbxassetid://77268328600938",
		["capstone_geom"]="rbxassetid://90707946406901",
		["pyramid_geom"]="rbxassetid://119526199827778",
	}, finishes={pyramid_geom={material=Enum.Material.Limestone}, capstone_geom={material=Enum.Material.Metal,mode="Hover",speed=1}, glyphs_geom={glow=true,clearTexture=true,color=Color3.fromRGB(66,235,255)}, halo_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,225,143),mode="Spin",speed=0.15}, light_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,248,224)}}},
	-- Studio MCP generate_mesh, 23bfc050-8595-472a-9f19-18e5edef3cf4 (2026-09-16).
	Egypt_Mummy = {asset=80002288302281, primary="case_geom", meshes={
		["bandage_geom"]="rbxassetid://74375928853172",
		["light_geom"]="rbxassetid://134720229451561",
		["lid_geom"]="rbxassetid://133510748974232",
		["case_geom"]="rbxassetid://93205377195513",
	}, finishes={case_geom={material=Enum.Material.Metal}, lid_geom={material=Enum.Material.Metal,mode="Hover",speed=0.8}, light_geom={glow=true,clearTexture=true,color=Color3.fromRGB(255,168,40)}, bandage_geom={material=Enum.Material.Fabric}}},
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
	Area51_AlienArtifact = { revision = 2, asset = 84840189777251, primary = "outer_frame_geom", meshes = {
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

return DEFINITIONS
