--!strict
--[[
	LootConfig
	The full 96-item economy: 12 zones x 8 item types, each with its BASE
	income, its zone-specific SPAWN WEIGHT, and its rarity label.

	`income` is the item's BASE income per second at Scale 1, before the size
	factor and the mutation multiplier (RarityConfig.preBoostRate).

	`weight` is the item's share of every socket roll in its zone. EVERY
	socket in a zone rolls independently from ALL EIGHT items using these
	weights; duplicates are allowed, nothing is excluded, nothing is rerolled.
	Zones 1-11 carry the reference game's verified per-slot weights, in this
	game's item-slot order. Rarity is a label read off RarityConfig.ZoneRarities
	and drives nothing in the roll.

	ItemId is the stable save key and must NEVER be renamed - the display `name`
	is the only player-facing text and is safe to change.

	== THE SHAPE OF THIS ECONOMY (read before "fixing" a number) ==

	Base incomes through Zone 9 are unchanged from the shipped game. Three
	values were corrected to the reference progression in the rebuild:
	  Zone 10 slot 8  4B/s   -> 1.8B/s
	  Zone 11 slot 4  3M/s   -> 11M/s
	  Zone 11 slot 8  6B/s   -> 3B/s
	The intra-zone gaps are enormous ON PURPOSE and the Bank is deliberately
	NON-monotonic. Do not smooth these curves and do not sort them.

	== ZONE 12 IS POST-GAME ==
	The reference game has eleven comparable zones. The Airport is this game's
	own extension past the end of them: it keeps its assets, items and saves,
	but it sits behind GameConfig.POSTGAME_EXTENSION, carries PROVISIONAL
	weights (Zone 11's), and is excluded from every parity claim, test and
	simulation. Its income cliff must never be read as part of the baseline.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

export type ItemDef = {
	id: string,
	name: string,
	income: number,
	--- Per-socket spawn weight inside its zone. Relative: shares are
	--- weight / zone total (LootConfig.weightShare).
	weight: number,
	--- Seconds a Scale-1 copy takes to start earning once placed. 0 = at once.
	--- See LootConfig.GROWTH_TIMES_STATUS.
	growthSeconds: number,
	-- Filled in below from the zone ladder. Never type these by hand.
	rarity: string,
	position: number,
	zoneIndex: number,
	--- True for the post-game zone (no parity equivalent).
	postgame: boolean,
}

type ItemSeed = { id: string, name: string, income: number }

local LootConfig = {}

-- ==========================================================
-- SPAWN WEIGHTS (per zone, in item-slot order)
-- ==========================================================
--
-- The reference game's verified per-slot weights for zones 1-11. Zone 12
-- repeats Zone 11's - a PROVISIONAL post-game table, not a parity value.

LootConfig.ZoneWeights = {
	[1] = { 34, 24, 17, 10, 7, 4.5, 2.5, 1 },
	[2] = { 29.274167, 23.217443, 17.160719, 12.113448, 8.075632, 5.551997, 4.037816, 0.568777 },
	[3] = { 26.585432, 20.450332, 15.337749, 12.270199, 9.202650, 8.180133, 6.646358, 1.327147 },
	[4] = { 26.006779, 20.005214, 17.004432, 13.003389, 11.002868, 7.852047, 5.001304, 0.123968 },
	[5] = { 29.444067, 21.570745, 18.335133, 14.020984, 11.863910, 4.171033, 0.371904, 0.222224 },
	[6] = { 26.848869, 22.040116, 18.032822, 15.027352, 17.030999, 0.619840, 0.222224, 0.177779 },
	[7] = { 34.755713, 24.665345, 19.059585, 14.574977, 3.412663, 2.616375, 0.826453, 0.088890 },
	[8] = { 39.066058, 26.044039, 20.835231, 4.929402, 6.995959, 0.826453, 0.991743, 0.311113 },
	[9] = { 39.869773, 34.387407, 19.618806, 4.550072, 0.495856, 0.743784, 0.311104, 0.023199 },
	[10] = { 37.51, 26.27, 16.83, 13.96, 4.36, 0.74, 0.31, 0.02 },
	[11] = { 37.51, 26.27, 16.83, 13.96, 4.36, 0.74, 0.31, 0.02 },
	-- POST-GAME, PROVISIONAL: Zone 11's table reused. Not a parity value.
	[12] = { 37.51, 26.27, 16.83, 13.96, 4.36, 0.74, 0.31, 0.02 },
} :: { [number]: { number } }

-- ==========================================================
-- BASE GROWTH TIMES
-- ==========================================================
--
-- Seconds a Scale-1 copy of each item takes to mature once placed (it earns
-- nothing until then; ScaleConfig.growthMultiplier stretches this for bigger
-- items). The reference game keeps a per-creature GrowthTime in its asset
-- catalog; those values were NOT reachable from this project at rebuild time
-- (the reference place was not connected), so no per-item value is typed
-- here and every item falls back to DEFAULT_GROWTH_SECONDS. At 0 the
-- maturation system is fully wired but inert - an item earns from the moment
-- it is placed, which is what the game did before. Fill this table from the
-- catalog and the delay switches on with no code change.

LootConfig.GROWTH_TIMES_STATUS = "BLOCKED_GROWTH_TIMES"
LootConfig.DEFAULT_GROWTH_SECONDS = 0
LootConfig.BaseGrowthSeconds = {} :: { [string]: number }

--- Item pools keyed by zone index (1-12), eight types each, in slot order.
local Seeds: { { ItemSeed } } = {
	-- Zone 01 MUSEUM
	{
		{ id = "Museum_AncientVase", name = "Ancient Vase", income = 1 },
		{ id = "Museum_RarePainting", name = "Rare Painting", income = 2 },
		{ id = "Museum_GoldenStatue", name = "Golden Statue", income = 8 },
		{ id = "Museum_PharaohMask", name = "Pharaoh Mask", income = 35 },
		{ id = "Museum_Ruby", name = "Ruby", income = 45 },
		{ id = "Museum_GoldenCrown", name = "Golden Crown", income = 180 },
		{ id = "Museum_Meteorite", name = "Meteorite", income = 240 },
		{ id = "Museum_Diamond", name = "Diamond", income = 1800 },
	},
	-- Zone 02 PIRATE ISLAND
	{
		{ id = "Pirate_TreasureMap", name = "Treasure Map", income = 3 },
		{ id = "Pirate_CaptainsHat", name = "Captain's Hat", income = 4 },
		{ id = "Pirate_GoldenCompass", name = "Golden Compass", income = 12 },
		{ id = "Pirate_GoldenHook", name = "Golden Hook", income = 60 },
		{ id = "Pirate_TreasureChest", name = "Treasure Chest", income = 260 },
		{ id = "Pirate_CaptainsCutlass", name = "Captain's Cutlass", income = 320 },
		{ id = "Pirate_JeweledSkull", name = "Jeweled Skull", income = 2800 },
		{ id = "Pirate_CursedCoin", name = "Cursed Coin", income = 220e3 },
	},
	-- Zone 03 CASTLE
	{
		{ id = "Castle_GoldenGoblet", name = "Golden Goblet", income = 6 },
		{ id = "Castle_RoyalPainting", name = "Royal Painting", income = 18 },
		{ id = "Castle_RoyalSeal", name = "Royal Seal", income = 75 },
		{ id = "Castle_GoldenKey", name = "Golden Key", income = 325 },
		{ id = "Castle_JeweledShield", name = "Jeweled Shield", income = 3600 },
		{ id = "Castle_RoyalScepter", name = "Royal Scepter", income = 16e3 },
		{ id = "Castle_RoyalTreasureChest", name = "Royal Treasure Chest", income = 18.5e3 },
		{ id = "Castle_KingsCrown", name = "King's Crown", income = 280e3 },
	},
	-- Zone 04 AREA 51
	{
		{ id = "Area51_TopSecretFiles", name = "Top Secret Files", income = 90 },
		{ id = "Area51_MeteorFragment", name = "Meteor Fragment", income = 110 },
		{ id = "Area51_AlienHelmet", name = "Alien Helmet", income = 420 },
		{ id = "Area51_AlienRayDevice", name = "Alien Ray Device", income = 4800 },
		{ id = "Area51_AlienCrystal", name = "Alien Crystal", income = 5500 },
		{ id = "Area51_AntiGravityCube", name = "Anti-Gravity Cube", income = 22e3 },
		{ id = "Area51_UFOCore", name = "UFO Core", income = 28e3 },
		{ id = "Area51_AlienArtifact", name = "Alien Artifact", income = 3.5e6 },
	},
	-- Zone 05 NORTH POLE
	{
		{ id = "NorthPole_SantasHat", name = "Santa's Hat", income = 140 },
		{ id = "NorthPole_NiceList", name = "Toy Train", income = 600 },
		{ id = "NorthPole_GoldenBell", name = "Golden Bell", income = 7e3 },
		{ id = "NorthPole_ToyBlueprint", name = "Toy Blueprint", income = 35e3 },
		{ id = "NorthPole_GoldenPresent", name = "Golden Present", income = 42e3 },
		{ id = "NorthPole_MagicSnowGlobe", name = "Magic Snow Globe", income = 400e3 },
		{ id = "NorthPole_SantasGiftSack", name = "Santa's Gift Sack", income = 5e6 },
		{ id = "NorthPole_ChristmasStar", name = "Christmas Star", income = 65e6 },
	},
	-- ======================================================================
	-- ZONES 6-12 FOLLOW THE STUDIO MODELS, NOT THE GDD
	-- ======================================================================
	-- The art for these zones arrived as "Zone N <thing>" imports, and those
	-- imports are the roster. Each model took the slot of the GDD item it
	-- replaced, so the income curve is what it was - only the objects changed.
	-- Where the model is the same kind of object the ItemId is KEPT (ids are
	-- save keys); a genuinely different object got a new id.
	--
	-- Zone 06 ANCIENT EGYPT
	{
		{ id = "Egypt_CanopicJar", name = "Pharaoh's Golden Scepter", income = 180 },
		{ id = "Egypt_Shawarma", name = "Shawarma", income = 850 },
		{ id = "Egypt_AncientMau", name = "Ancient Mau", income = 9500 },
		{ id = "Egypt_AncientScroll", name = "Ancient Scroll", income = 11e3 },
		{ id = "Egypt_Mummy", name = "Mummy", income = 55e3 },
		{ id = "Egypt_ThroneOfRa", name = "Throne of Ra", income = 8e6 },
		{ id = "Egypt_NemesMask", name = "Nemes Mask", income = 85e6 },
		{ id = "Egypt_EgyptianPyramid", name = "Egyptian Pyramid", income = 100e6 },
	},
	-- Zone 07 GYM
	{
		{ id = "Gym_Water", name = "Water", income = 220 },
		{ id = "Gym_Creatine", name = "Boxing Gloves", income = 1100 },
		{ id = "Gym_CoachsWhistle", name = "Gym Whistle", income = 15e3 },
		{ id = "Gym_VanillaMilkshake", name = "Vanilla Milkshake", income = 80e3 },
		{ id = "Gym_Airpods", name = "Airpods", income = 700e3 },
		{ id = "Gym_GoldenDumbbell", name = "Golden Dumbbells", income = 850e3 },
		{ id = "Gym_Trophy", name = "Trophy", income = 15e6 },
		{ id = "Gym_GoldenBarbell", name = "Golden Barbell", income = 130e6 },
	},
	-- Zone 08 BANK
	-- The $32M -> $25M step at positions 6/7 is INTENTIONAL. Do not sort.
	{
		{ id = "Bank_MoneyStack", name = "Money Stack", income = 280 },
		{ id = "Bank_CashBag", name = "Money Print Machine", income = 22e3 },
		{ id = "Bank_VaultKey", name = "Master Key", income = 120e3 },
		{ id = "Bank_RareCoin", name = "Shiny Coin", income = 1.2e6 },
		{ id = "Bank_GoldBar", name = "Gold Bar", income = 1.5e6 },
		{ id = "Bank_BankersBriefcase", name = "Banker's Briefcase", income = 32e6 },
		{ id = "Bank_PlatinumBullionStack", name = "Platinum Bullion Stack", income = 25e6 },
		{ id = "Bank_VendingMachine", name = "Vending Machine", income = 180e6 },
	},
	-- Zone 09 SECRET LAB
	{
		{ id = "SecretLab_SecretFormula", name = "Mutant Specimen", income = 1500 },
		{ id = "SecretLab_ChemicalCylinder", name = "Chemical Cylinder", income = 30e3 },
		{ id = "SecretLab_ContainmentTank", name = "Containment Tank", income = 180e3 },
		{ id = "SecretLab_RobotSpider", name = "Robot Spider", income = 2.2e6 },
		{ id = "SecretLab_MutationCrystal", name = "Blue Crystal", income = 45e6 },
		{ id = "SecretLab_CyanPlasma", name = "Cyan Plasma", income = 60e6 },
		{ id = "SecretLab_EnergyCore", name = "Energy Canister", income = 250e6 },
		{ id = "SecretLab_RadiationChamber", name = "Radiation Chamber", income = 1e9 },
	},
	-- Zone 10 GRANDMA'S HOUSE
	{
		{ id = "Grandma_CandyBowl", name = "Grandmas Cookies", income = 4e3 },
		{ id = "Grandma_KnittedSweater", name = "Red Shirt", income = 74e3 },
		{ id = "Grandma_WalkingCane", name = "Walking Cane", income = 450e3 },
		{ id = "Grandma_GoldenTeapot", name = "Golden Teapot", income = 7.5e6 },
		{ id = "Grandma_AntiqueClock", name = "Grandfather Clock", income = 12e6 },
		{ id = "Grandma_GrandmasPurse", name = "Pink Handbag", income = 145e6 },
		{ id = "Grandma_LegendaryGiftBox", name = "Legendary Gift Box", income = 600e6 },
		-- Corrected 4B -> 1.8B (reference slot value).
		{ id = "Grandma_CookieJar", name = "Cookie Jar", income = 1.8e9 },
	},
	-- Zone 11 CONSTRUCTION SITE
	{
		{ id = "Construction_Blueprints", name = "Blueprints", income = 95e3 },
		{ id = "Construction_RareSafetyVest", name = "Rare Safety Vest", income = 130e3 },
		{ id = "Construction_ForemansToolbox", name = "Foreman's Toolbox", income = 750e3 },
		-- Corrected 3M -> 11M (reference slot value).
		{ id = "Construction_MetalFence", name = "Metal Fence", income = 11e6 },
		{ id = "Construction_GoldenHardHat", name = "Golden Hard Hat", income = 17.5e6 },
		{ id = "Construction_GoldenDrill", name = "Golden Drill", income = 215e6 },
		{ id = "Construction_BossLadder", name = "Boss Ladder", income = 880e6 },
		-- Corrected 6B -> 3B (reference slot value).
		{ id = "Construction_DiamondHammer", name = "Diamond Hammer", income = 3e9 },
	},
	-- ======================================================================
	-- Zone 12 AIRPORT - POST-GAME EXTENSION (GameConfig.POSTGAME_EXTENSION)
	-- ======================================================================
	-- No reference equivalent. Numbers untouched by the parity rebuild; the
	-- zone is excluded from every parity table, test and simulation.
	{
		{ id = "Airport_FirstClassTicket", name = "Golden Pilot Badge", income = 387e6 },
		{ id = "Airport_VIPPassport", name = "Airplane", income = 484e6 },
		{ id = "Airport_PilotsHat", name = "Pilot's Hat", income = 928e6 },
		{ id = "Airport_LostBriefcase", name = "Lost Briefcase", income = 1.16e9 },
		{ id = "Airport_UnknownBriefcase", name = "Unknown Briefcase", income = 2.32e9 },
		{ id = "Airport_PilotsLuggage", name = "Pilot's Luggage", income = 5.42e9 },
		{ id = "Airport_AirTower", name = "Air Tower", income = 13.54e9 },
		{ id = "Airport_PrivateJet", name = "Private Jet", income = 46.42e9 },
	},
}

--- Zones with no reference equivalent. Read from here rather than typed in
--- GameConfig so the loot tables and the feature flag cannot disagree.
LootConfig.POSTGAME_ZONES = { [12] = true } :: { [number]: boolean }

--- The finished pools, with rarity, weight and zone resolved.
LootConfig.Items = {} :: { { ItemDef } }

--- Flat lookups, built once at require time.
LootConfig.ById = {} :: { [string]: ItemDef }
LootConfig.ZoneOf = {} :: { [string]: number }
LootConfig.ZoneWeightTotal = {} :: { [number]: number }

for zoneIndex, pool in Seeds do
	local weights = LootConfig.ZoneWeights[zoneIndex]
	assert(weights and #weights == #pool, `LootConfig: zone {zoneIndex} needs {#pool} weights`)
	local built: { ItemDef } = {}
	local total = 0
	for position, seed in pool do
		local item: ItemDef = {
			id = seed.id,
			name = seed.name,
			income = seed.income,
			weight = weights[position],
			growthSeconds = LootConfig.BaseGrowthSeconds[seed.id] or LootConfig.DEFAULT_GROWTH_SECONDS,
			position = position,
			zoneIndex = zoneIndex,
			rarity = RarityConfig.rarityAt(zoneIndex, position),
			postgame = LootConfig.POSTGAME_ZONES[zoneIndex] == true,
		}
		built[position] = item
		LootConfig.ById[item.id] = item
		LootConfig.ZoneOf[item.id] = zoneIndex
		total += item.weight
	end
	LootConfig.Items[zoneIndex] = built
	LootConfig.ZoneWeightTotal[zoneIndex] = total
end

--- Every item a socket in this zone can roll: all eight, with their weights.
function LootConfig.pool(zoneIndex: number): { ItemDef }
	return LootConfig.Items[zoneIndex] or {}
end

--- The per-socket probability of an item: its weight over its zone's total.
function LootConfig.weightShare(itemId: string): number
	local item = LootConfig.ById[itemId]
	if not item then
		return 0
	end
	local total = LootConfig.ZoneWeightTotal[item.zoneIndex] or 0
	return if total > 0 then item.weight / total else 0
end

--- True for a zone that takes part in the parity baseline (1-11).
function LootConfig.isParityZone(zoneIndex: number): boolean
	return LootConfig.Items[zoneIndex] ~= nil and not LootConfig.POSTGAME_ZONES[zoneIndex]
end

-- ==========================================================
-- NORMAL-SIZE NORMALISATION
-- ==========================================================
--
-- Every authored loot asset arrives at its own import scale (a crown half a
-- stud tall, a treasure map fourteen). ONE multiplier per item turns the
-- asset into a Scale-1 model of consistent apparent size, proportions
-- untouched. LootModel.build applies it EXACTLY ONCE, to a fresh clone, under
-- the instance's display scale - so a Scale-2 item is twice a correctly
-- sized Scale-1, and nothing that respawns, is stolen, returned, placed,
-- loaded or reparented can ever scale twice, because none of those paths
-- scale at all.
--
-- The numbers are MEASURED, not guessed: `Invoke("lootAudit")` in Studio
-- measures the VISIBLE bounding box of every asset (helpers, hitboxes and
-- transparent parts ignored), runs it through LootModel.normalisationFor,
-- and prints this table ready to paste. Each row is
--
--     ItemId = { multiplier, sourceX, sourceY, sourceZ },
--
-- where source is the visible box of the authored asset in studs. The source
-- size is recorded so the server can tell when the art has changed under a
-- stale number (LootModel.checkNormalization warns at start).
--
-- An item with art but no row here still builds - LootModel measures it on
-- the fly with the same rule - but the start-up check names it as missing
-- configuration, so a new import never ships unaudited by accident.

-- Measured in Studio on 2026-09-09 from ServerStorage.GameAssets.Loot (visible
-- bounding boxes, LootModel.audit). 95 of 96 items have art; Pirate_CursedCoin has
-- no asset in the place and builds a placeholder. Re-run Invoke("lootAudit") after
-- any art change - the start-up check flags a stale row by name.
LootConfig.Normalization = {
	Museum_AncientVase = { 0.8800, 1.865, 5.682, 1.865 }, -- Ancient Vase: 1.87 x 5.68 x 1.87 -> 1.64 x 5.00 x 1.64
	Museum_RarePainting = { 1.0000, 5.000, 5.000, 0.200 }, -- Rare Painting: 5.00 x 5.00 x 0.20 -> 5.00 x 5.00 x 0.20
	Museum_GoldenStatue = { 1.1924, 4.016, 4.193, 2.771 }, -- Golden Statue: 4.02 x 4.19 x 2.77 -> 4.79 x 5.00 x 3.30
	Museum_PharaohMask = { 0.8621, 4.500, 5.800, 1.400 }, -- Pharaoh Mask: 4.50 x 5.80 x 1.40 -> 3.88 x 5.00 x 1.21
	Museum_Ruby = { 1.6583, 3.132, 3.015, 3.308 }, -- Ruby: 3.13 x 3.02 x 3.31 -> 5.19 x 5.00 x 5.49
	Museum_GoldenCrown = { 7.8257, 1.248, 0.511, 1.249 }, -- Golden Crown: 1.25 x 0.51 x 1.25 -> 9.76 x 4.00 x 9.77
	Museum_Meteorite = { 0.8333, 5.635, 6.000, 4.902 }, -- Meteorite: 5.64 x 6.00 x 4.90 -> 4.70 x 5.00 x 4.08
	Museum_Diamond = { 3.1250, 2.000, 1.600, 2.000 }, -- Diamond: 2.00 x 1.60 x 2.00 -> 6.25 x 5.00 x 6.25
	Pirate_TreasureMap = { 0.3571, 11.000, 14.000, 2.000 }, -- Treasure Map: 11.00 x 14.00 x 2.00 -> 3.93 x 5.00 x 0.71
	Pirate_CaptainsHat = { 0.8042, 6.908, 6.217, 3.454 }, -- Captain's Hat: 6.91 x 6.22 x 3.45 -> 5.56 x 5.00 x 2.78
	Pirate_GoldenCompass = { 2.5011, 2.000, 1.999, 2.000 }, -- Golden Compass: 2.00 x 2.00 x 2.00 -> 5.00 x 5.00 x 5.00
	Pirate_GoldenHook = { 1.8834, 1.496, 2.655, 1.496 }, -- Golden Hook: 1.50 x 2.65 x 1.50 -> 2.82 x 5.00 x 2.82
	Pirate_TreasureChest = { 1.8450, 2.830, 2.710, 1.750 }, -- Treasure Chest: 2.83 x 2.71 x 1.75 -> 5.22 x 5.00 x 3.23
	Pirate_CaptainsCutlass = { 0.2801, 14.329, 17.848, 0.511 }, -- Captain's Cutlass: 14.33 x 17.85 x 0.51 -> 4.01 x 5.00 x 0.14
	Pirate_JeweledSkull = { 0.4721, 4.694, 10.590, 6.627 }, -- Jeweled Skull: 4.69 x 10.59 x 6.63 -> 2.22 x 5.00 x 3.13
	Castle_GoldenGoblet = { 0.9449, 3.087, 5.292, 2.865 }, -- Golden Goblet: 3.09 x 5.29 x 2.86 -> 2.92 x 5.00 x 2.71
	Castle_RoyalPainting = { 0.8000, 9.600, 5.000, 0.050 }, -- Royal Painting: 9.60 x 5.00 x 0.05 -> 7.68 x 4.00 x 0.04
	Castle_RoyalSeal = { 0.7636, 0.222, 6.548, 8.387 }, -- Royal Seal: 0.22 x 6.55 x 8.39 -> 0.17 x 5.00 x 6.40
	Castle_GoldenKey = { 0.9020, 1.109, 4.435, 12.750 }, -- Golden Key: 1.11 x 4.43 x 12.75 -> 1.00 x 4.00 x 11.50
	Castle_JeweledShield = { 0.4849, 1.933, 10.311, 8.378 }, -- Jeweled Shield: 1.93 x 10.31 x 8.38 -> 0.94 x 5.00 x 4.06
	Castle_RoyalScepter = { 0.3687, 10.337, 13.562, 2.033 }, -- Royal Scepter: 10.34 x 13.56 x 2.03 -> 3.81 x 5.00 x 0.75
	Castle_RoyalTreasureChest = { 1.2117, 3.503, 4.126, 5.383 }, -- Royal Treasure Chest: 3.50 x 4.13 x 5.38 -> 4.24 x 5.00 x 6.52
	Castle_KingsCrown = { 1.0083, 5.841, 4.959, 5.662 }, -- King's Crown: 5.84 x 4.96 x 5.66 -> 5.89 x 5.00 x 5.71
	Area51_TopSecretFiles = { 1.0000, 4.000, 5.000, 1.000 }, -- Top Secret Files: 4.00 x 5.00 x 1.00 -> 4.00 x 5.00 x 1.00
	Area51_MeteorFragment = { 0.5690, 12.044, 8.787, 11.873 }, -- Meteor Fragment: 12.04 x 8.79 x 11.87 -> 6.85 x 5.00 x 6.76
	Area51_AlienHelmet = { 0.7596, 7.381, 6.582, 7.377 }, -- Alien Helmet: 7.38 x 6.58 x 7.38 -> 5.61 x 5.00 x 5.60
	Area51_AlienRayDevice = { 0.7179, 2.528, 6.185, 10.448 }, -- Alien Ray Device: 2.53 x 6.18 x 10.45 -> 1.81 x 4.44 x 7.50
	Area51_AlienCrystal = { 0.5627, 2.670, 8.886, 3.127 }, -- Alien Crystal: 2.67 x 8.89 x 3.13 -> 1.50 x 5.00 x 1.76
	Area51_AntiGravityCube = { 0.5000, 6.667, 10.000, 6.667 }, -- Anti-Gravity Cube: 6.67 x 10.00 x 6.67 -> 3.33 x 5.00 x 3.33
	Area51_UFOCore = { 0.1957, 51.503, 20.434, 45.276 }, -- UFO Core: 51.50 x 20.43 x 45.28 -> 10.08 x 4.00 x 8.86
	Area51_AlienArtifact = { 0.1357, 55.253, 29.662, 24.997 }, -- Alien Artifact: 55.25 x 29.66 x 25.00 -> 7.50 x 4.03 x 3.39
	NorthPole_SantasHat = { 0.9615, 5.200, 5.200, 5.200 }, -- Santa's Hat: 5.20 x 5.20 x 5.20 -> 5.00 x 5.00 x 5.00
	NorthPole_NiceList = { 1.0000, 3.500, 4.000, 8.000 }, -- Toy Train: 3.50 x 4.00 x 8.00 -> 3.50 x 4.00 x 8.00
	NorthPole_GoldenBell = { 1.8614, 1.306, 2.686, 2.575 }, -- Golden Bell: 1.31 x 2.69 x 2.57 -> 2.43 x 5.00 x 4.79
	NorthPole_ToyBlueprint = { 1.5000, 4.260, 3.000, 5.000 }, -- Toy Blueprint: 4.26 x 3.00 x 5.00 -> 6.39 x 4.50 x 7.50
	NorthPole_GoldenPresent = { 0.2105, 21.793, 23.752, 22.540 }, -- Golden Present: 21.79 x 23.75 x 22.54 -> 4.59 x 5.00 x 4.74
	NorthPole_MagicSnowGlobe = { 0.5788, 10.284, 8.639, 10.310 }, -- Magic Snow Globe: 10.28 x 8.64 x 10.31 -> 5.95 x 5.00 x 5.97
	NorthPole_SantasGiftSack = { 0.5431, 9.663, 9.206, 9.665 }, -- Santa's Gift Sack: 9.66 x 9.21 x 9.67 -> 5.25 x 5.00 x 5.25
	NorthPole_ChristmasStar = { 0.1088, 29.577, 45.935, 29.577 }, -- Christmas Star: 29.58 x 45.94 x 29.58 -> 3.22 x 5.00 x 3.22
	Egypt_CanopicJar = { 0.8333, 4.800, 6.000, 1.200 }, -- Pharaoh's Golden Scepter: 4.80 x 6.00 x 1.20 -> 4.00 x 5.00 x 1.00
	Egypt_Shawarma = { 1.0910, 6.874, 3.925, 4.577 }, -- Shawarma: 6.87 x 3.92 x 4.58 -> 7.50 x 4.28 x 4.99
	Egypt_AncientMau = { 0.2778, 4.485, 18.000, 5.437 }, -- Ancient Mau: 4.49 x 18.00 x 5.44 -> 1.25 x 5.00 x 1.51
	Egypt_AncientScroll = { 1.1466, 6.541, 3.537, 3.233 }, -- Ancient Scroll: 6.54 x 3.54 x 3.23 -> 7.50 x 4.06 x 3.71
	Egypt_Mummy = { 0.2778, 8.679, 18.000, 7.671 }, -- Mummy: 8.68 x 18.00 x 7.67 -> 2.41 x 5.00 x 2.13
	Egypt_ThroneOfRa = { 0.4245, 8.200, 11.778, 8.105 }, -- Throne of Ra: 8.20 x 11.78 x 8.10 -> 3.48 x 5.00 x 3.44
	Egypt_NemesMask = { 0.7143, 7.000, 7.000, 7.000 }, -- Nemes Mask: 7.00 x 7.00 x 7.00 -> 5.00 x 5.00 x 5.00
	Egypt_EgyptianPyramid = { 0.0781, 84.000, 52.000, 96.000 }, -- Egyptian Pyramid: 84.00 x 52.00 x 96.00 -> 6.56 x 4.06 x 7.50
	Gym_Water = { 0.8581, 3.410, 5.827, 3.468 }, -- Water: 3.41 x 5.83 x 3.47 -> 2.93 x 5.00 x 2.98
	Gym_Creatine = { 1.2500, 5.000, 4.000, 3.000 }, -- Boxing Gloves: 5.00 x 4.00 x 3.00 -> 6.25 x 5.00 x 3.75
	Gym_CoachsWhistle = { 0.5349, 9.313, 9.347, 7.634 }, -- Gym Whistle: 9.31 x 9.35 x 7.63 -> 4.98 x 5.00 x 4.08
	Gym_VanillaMilkshake = { 0.4797, 3.253, 10.424, 3.386 }, -- Vanilla Milkshake: 3.25 x 10.42 x 3.39 -> 1.56 x 5.00 x 1.62
	Gym_Airpods = { 0.5747, 8.583, 8.700, 4.297 }, -- Airpods: 8.58 x 8.70 x 4.30 -> 4.93 x 5.00 x 2.47
	Gym_GoldenDumbbell = { 1.7432, 6.280, 2.295, 5.723 }, -- Golden Dumbbells: 6.28 x 2.29 x 5.72 -> 10.95 x 4.00 x 9.98
	Gym_Trophy = { 0.4577, 2.408, 10.925, 3.772 }, -- Trophy: 2.41 x 10.93 x 3.77 -> 1.10 x 5.00 x 1.73
	Gym_GoldenBarbell = { 0.2817, 35.297, 14.200, 14.200 }, -- Golden Barbell: 35.30 x 14.20 x 14.20 -> 9.94 x 4.00 x 4.00
	Bank_MoneyStack = { 1.8523, 9.407, 2.159, 5.847 }, -- Money Stack: 9.41 x 2.16 x 5.85 -> 17.42 x 4.00 x 10.83
	Bank_CashBag = { 1.4286, 5.000, 3.500, 4.000 }, -- Money Print Machine: 5.00 x 3.50 x 4.00 -> 7.14 x 5.00 x 5.71
	Bank_VaultKey = { 0.5523, 3.461, 9.052, 2.139 }, -- Master Key: 3.46 x 9.05 x 2.14 -> 1.91 x 5.00 x 1.18
	Bank_RareCoin = { 1.0104, 3.974, 4.949, 3.439 }, -- Shiny Coin: 3.97 x 4.95 x 3.44 -> 4.02 x 5.00 x 3.47
	Bank_GoldBar = { 1.3454, 9.539, 2.973, 3.664 }, -- Gold Bar: 9.54 x 2.97 x 3.66 -> 12.83 x 4.00 x 4.93
	Bank_BankersBriefcase = { 0.9099, 7.060, 5.495, 7.092 }, -- Banker's Briefcase: 7.06 x 5.50 x 7.09 -> 6.42 x 5.00 x 6.45
	Bank_PlatinumBullionStack = { 0.9136, 8.956, 4.378, 5.495 }, -- Platinum Bullion Stack: 8.96 x 4.38 x 5.50 -> 8.18 x 4.00 x 5.02
	Bank_VendingMachine = { 0.6944, 6.000, 7.200, 3.400 }, -- Vending Machine: 6.00 x 7.20 x 3.40 -> 4.17 x 5.00 x 2.36
	-- RE-MEASURED after the art swap. The old row was audited against the
	-- previous Secret Formula model and left the flask 1.79 studs tall on a
	-- pedestal built for 5.00; lootAudit reported it "stale" by name.
	SecretLab_SecretFormula = { 0.8333, 3.500, 6.000, 3.500 }, -- Mutant Specimen: 3.50 x 6.00 x 3.50 -> 2.92 x 5.00 x 2.92
	SecretLab_ChemicalCylinder = { 0.5928, 5.166, 8.435, 5.166 }, -- Chemical Cylinder: 5.17 x 8.43 x 5.17 -> 3.06 x 5.00 x 3.06
	SecretLab_ContainmentTank = { 0.8922, 4.588, 5.604, 3.929 }, -- Containment Tank: 4.59 x 5.60 x 3.93 -> 4.09 x 5.00 x 3.51
	SecretLab_RobotSpider = { 0.4810, 9.756, 10.396, 12.285 }, -- Robot Spider: 9.76 x 10.40 x 12.29 -> 4.69 x 5.00 x 5.91
	SecretLab_MutationCrystal = { 0.4886, 4.943, 10.234, 7.136 }, -- Blue Crystal: 4.94 x 10.23 x 7.14 -> 2.42 x 5.00 x 3.49
	SecretLab_CyanPlasma = { 0.5337, 9.228, 9.369, 5.600 }, -- Cyan Plasma: 9.23 x 9.37 x 5.60 -> 4.93 x 5.00 x 2.99
	SecretLab_EnergyCore = { 0.7139, 9.130, 7.004, 7.029 }, -- Energy Canister: 9.13 x 7.00 x 7.03 -> 6.52 x 5.00 x 5.02
	SecretLab_RadiationChamber = { 0.2214, 12.610, 22.586, 12.817 }, -- Radiation Chamber: 12.61 x 22.59 x 12.82 -> 2.79 x 5.00 x 2.84
	Grandma_CandyBowl = { 1.0870, 4.600, 4.600, 0.900 }, -- Grandmas Cookies: 4.60 x 4.60 x 0.90 -> 5.00 x 5.00 x 0.98
	Grandma_KnittedSweater = { 0.5139, 12.434, 9.729, 1.565 }, -- Red Shirt: 12.43 x 9.73 x 1.57 -> 6.39 x 5.00 x 0.80
	Grandma_WalkingCane = { 0.3710, 2.925, 13.476, 1.121 }, -- Walking Cane: 2.92 x 13.48 x 1.12 -> 1.09 x 5.00 x 0.42
	Grandma_GoldenTeapot = { 0.7143, 7.520, 7.000, 7.520 }, -- Golden Teapot: 7.52 x 7.00 x 7.52 -> 5.37 x 5.00 x 5.37
	Grandma_AntiqueClock = { 0.6128, 2.380, 8.160, 6.799 }, -- Grandfather Clock: 2.38 x 8.16 x 6.80 -> 1.46 x 5.00 x 4.17
	Grandma_GrandmasPurse = { 0.7817, 6.362, 6.396, 2.140 }, -- Pink Handbag: 6.36 x 6.40 x 2.14 -> 4.97 x 5.00 x 1.67
	Grandma_LegendaryGiftBox = { 0.9615, 4.975, 5.102, 7.800 }, -- Legendary Gift Box: 4.97 x 5.10 x 7.80 -> 4.78 x 4.91 x 7.50
	Grandma_CookieJar = { 0.7299, 5.347, 6.850, 5.238 }, -- Cookie Jar: 5.35 x 6.85 x 5.24 -> 3.90 x 5.00 x 3.82
	Construction_Blueprints = { 0.4532, 16.550, 10.934, 9.884 }, -- Blueprints: 16.55 x 10.93 x 9.88 -> 7.50 x 4.96 x 4.48
	Construction_RareSafetyVest = { 0.4936, 9.680, 10.129, 5.090 }, -- Rare Safety Vest: 9.68 x 10.13 x 5.09 -> 4.78 x 5.00 x 2.51
	Construction_ForemansToolbox = { 0.7163, 10.470, 5.872, 7.513 }, -- Foreman's Toolbox: 10.47 x 5.87 x 7.51 -> 7.50 x 4.21 x 5.38
	Construction_MetalFence = { 0.4907, 11.509, 10.190, 5.960 }, -- Metal Fence: 11.51 x 10.19 x 5.96 -> 5.65 x 5.00 x 2.92
	Construction_GoldenHardHat = { 0.8240, 9.102, 5.377, 6.613 }, -- Golden Hard Hat: 9.10 x 5.38 x 6.61 -> 7.50 x 4.43 x 5.45
	Construction_GoldenDrill = { 0.2293, 22.809, 21.810, 7.431 }, -- Golden Drill: 22.81 x 21.81 x 7.43 -> 5.23 x 5.00 x 1.70
	Construction_BossLadder = { 0.5324, 9.396, 9.392, 3.400 }, -- Boss Ladder: 9.40 x 9.39 x 3.40 -> 5.00 x 5.00 x 1.81
	Construction_DiamondHammer = { 0.4345, 5.613, 11.507, 7.600 }, -- Diamond Hammer: 5.61 x 11.51 x 7.60 -> 2.44 x 5.00 x 3.30
	Airport_FirstClassTicket = { 1.6000, 6.000, 2.500, 1.000 }, -- Golden Pilot Badge: 6.00 x 2.50 x 1.00 -> 9.60 x 4.00 x 1.60
	Airport_VIPPassport = { 0.1250, 74.667, 32.000, 85.333 }, -- Airplane: 74.67 x 32.00 x 85.33 -> 9.33 x 4.00 x 10.67
	Airport_PilotsHat = { 1.6136, 7.175, 2.479, 7.625 }, -- Pilot's Hat: 7.17 x 2.48 x 7.62 -> 11.58 x 4.00 x 12.30
	Airport_LostBriefcase = { 0.6440, 2.865, 7.245, 11.646 }, -- Lost Briefcase: 2.86 x 7.24 x 11.65 -> 1.85 x 4.67 x 7.50
	Airport_UnknownBriefcase = { 0.6906, 9.302, 7.240, 9.344 }, -- Unknown Briefcase: 9.30 x 7.24 x 9.34 -> 6.42 x 5.00 x 6.45
	Airport_PilotsLuggage = { 0.3214, 14.434, 15.557, 2.381 }, -- Pilot's Luggage: 14.43 x 15.56 x 2.38 -> 4.64 x 5.00 x 0.77
	Airport_AirTower = { 0.0702, 21.314, 71.200, 21.314 }, -- Air Tower: 21.31 x 71.20 x 21.31 -> 1.50 x 5.00 x 1.50
	Airport_PrivateJet = { 0.3707, 47.438, 10.789, 36.508 }, -- Private Jet: 47.44 x 10.79 x 36.51 -> 17.59 x 4.00 x 13.53
} :: { [string]: { number } }

-- ==========================================================
-- PER-ITEM MODEL OVERRIDES AND ORIENTATION
-- ==========================================================
--
-- MODEL OVERRIDE. An item's art is normally found by its ItemId
-- (LootModel.findSource). A row here points one item at a DIFFERENTLY NAMED
-- asset instead, which is how a replacement model is adopted without renaming
-- the item: the ItemId stays the save key it has always been, and only the
-- picture changes.

-- The 2026-09-09 art replacement pass. Ten items were re-arted; each keeps its
-- ItemId (the save key), its rarity, income, weight, zone, growth time and
-- every mutation and size-variant behaviour. Only the display `name` above and
-- the asset named here changed. The right-hand string must match the model's
-- name in ServerStorage.GameAssets.Loot EXACTLY, including apostrophes.
LootConfig.ModelOverrides = {
	-- Zone 01: a better Pharaoh Mask model. Display name unchanged.
	Museum_PharaohMask = "Pharaohs Mask",
	-- Zone 04: same item, same name, better art.
	Area51_TopSecretFiles = "Top Secret Files",
	-- Zone 05: Nice List -> Toy Train.
	NorthPole_NiceList = "Toy Train",
	-- Zone 06: Canopic Jar -> Pharaoh’s Golden Scepter. NOTE: the asset name
	-- uses a curly apostrophe (U+2019), not an ASCII one; a straight quote here
	-- will not find it.
	Egypt_CanopicJar = "Pharaoh’s Golden Scepter",
	-- Zone 07: Creatine -> Boxing Gloves.
	Gym_Creatine = "Boxing Gloves",
	-- Zone 08: Cash Briefcase -> Money Print Machine.
	Bank_CashBag = "Money Print Machine",
	-- Zone 09: Chemical Flask -> Mutant Specimen. (Was overridden to
	-- "Chemical Flask"; that art is superseded.)
	SecretLab_SecretFormula = "Mutant Specimen",
	-- Zone 10: Colorful Bowl -> Grandmas Cookie.
	Grandma_CandyBowl = "Grandmas Cookie",
	-- Zone 12: First-Class Ticket -> Pilots Badge.
	Airport_FirstClassTicket = "Pilots Badge",
	-- Zone 12: VIP Passport -> Airplane.
	Airport_VIPPassport = "Airplane",
} :: { [string]: string }

--- The asset name to look for, which is the item's own id unless overridden.
function LootConfig.modelNameFor(itemId: string): string
	return LootConfig.ModelOverrides[itemId] or itemId
end

-- ORIENTATION. Every build re-pivots a model onto its socket or pedestal,
-- which replaces whatever rotation the artist left on its pivot. For almost
-- every asset that is right - it stands the model upright. For a handful
-- whose authored pivot IS their "up", it lands them on their side or upside
-- down, and the fix belongs in configuration rather than in a random rotation
-- applied somewhere in the pipeline.
--
-- Degrees, applied about the model's own axes AFTER normalisation and BEFORE
-- it is seated, so it holds in the world, in the hand, on the pedestal and in
-- the Index preview alike, at every size.

LootConfig.ModelOrientation = {
	-- EMPTY, AND THAT IS THE ANSWER, NOT AN OMISSION.
	--
	-- The Vanilla Milkshake was the one item this table existed for: it stood
	-- on its head on every pedestal. The cause was not its authoring. Its
	-- parts are all built the right way up; one of them - the union named
	-- "Vanilla  Milkshake" - carries a frame whose UpVector is (0, -1, 0), and
	-- LootModel picked that part as the PrimaryPart simply because it was
	-- first in child order. Since Model:GetPivot() IS the PrimaryPart's frame,
	-- every PivotTo onto an upright socket then turned the whole shake over.
	--
	-- LootModel.chooseAnchor now prefers a part whose own frame is upright, so
	-- the milkshake needs no correction at all - and a row here would put it
	-- back on its head. Add one only for art that is genuinely authored lying
	-- down as a SET, and check it with LootModel.uprightAudit() rather than by
	-- eye.
} :: { [string]: Vector3 }

--- The orientation correction for an item, or nil when it needs none.
function LootConfig.orientationFor(itemId: string): CFrame?
	local euler = LootConfig.ModelOrientation[itemId]
	if not euler then
		return nil
	end
	return CFrame.Angles(math.rad(euler.X), math.rad(euler.Y), math.rad(euler.Z))
end

--- The audited multiplier for an item, or nil when it has no row.
function LootConfig.normalizationFor(itemId: string): number?
	local row = LootConfig.Normalization[itemId]
	local value = if row then row[1] else nil
	if type(value) ~= "number" or value ~= value or value <= 0 then
		return nil
	end
	return value
end

return LootConfig
