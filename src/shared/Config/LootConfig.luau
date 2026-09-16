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
	Zones 4-11 carry the reference game's verified per-slot weights, in this
	game's item-slot order; zones 1-3 carry this game's own richer early odds
	(see SPAWN WEIGHTS). Rarity is a label read off RarityConfig.ZoneRarities
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
-- The reference game's verified per-slot weights for zones 4-11. Zone 12
-- repeats Zone 11's - a PROVISIONAL post-game table, not a parity value.
--
-- ZONES 1-3 ARE THIS GAME'S OWN, NOT PARITY (owner decision, 2026-09-11).
-- Early progression was measured as the reason new players were leaving, so
-- the first three zones were given richer odds, specified PER RARITY:
--
--   Zone 1  Common 40  Uncommon 25  Rare 20  Epic 12  Legendary 3
--   Zone 2  Common 32  Uncommon 23  Rare 20  Epic 15  Legendary 9   Cosmic 1
--   Zone 3  Common 15  Uncommon 15  Rare 20  Epic 17  Legendary 14  Mythic 17  Cosmic 2
--
-- Where a rarity covers two slots, its share is split in the SAME RATIO the
-- reference weights had between them, so the cheaper of two Commons stays
-- the likelier one. Each zone sums to exactly 100. Zone 1 was 58% Common
-- ($1-$2/s items) and is now 40%; its expected income per steal goes from
-- $40.93/s to $88.56/s.
--
-- The old values, should parity ever be wanted back:
--   [1] = { 34, 24, 17, 10, 7, 4.5, 2.5, 1 }
--   [2] = { 29.274167, 23.217443, 17.160719, 12.113448, 8.075632, 5.551997, 4.037816, 0.568777 }
--   [3] = { 26.585432, 20.450332, 15.337749, 12.270199, 9.202650, 8.180133, 6.646358, 1.327147 }

LootConfig.ZoneWeights = {
	[1] = { 23.448276, 16.551724, 25.000000, 11.764706, 8.235294, 7.714286, 4.285714, 3.000000 },
	[2] = { 17.846154, 14.153846, 23.000000, 20.000000, 8.888889, 6.111111, 9.000000, 1.000000 },
	[3] = { 15.000000, 15.000000, 20.000000, 17.000000, 14.000000, 9.379310, 7.620690, 2.000000 },
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
	Museum_AncientVase = { 1.0000, 3.485, 5.000, 3.515 }, -- Generated mesh amphora; measured with lootAudit.
	Museum_RarePainting = { 1.0000, 3.721, 5.000, 1.913 }, -- Generated mesh, lootAudit.
	Museum_GoldenStatue = { 1.0000, 2.117, 5.000, 2.094 }, -- Generated mesh, lootAudit.
	Museum_PharaohMask = { 1.0000, 3.818, 5.000, 3.168 }, -- Generated mesh, live lootAudit
	Museum_Ruby = { 1.0000, 2.250, 5.000, 2.240 }, -- Generated mesh, lootAudit.
	Museum_GoldenCrown = { 1.0000, 9.154, 4.000, 9.144 }, -- Generated mesh, lootAudit.
	Museum_Meteorite = { 1.0000, 3.867, 5.000, 4.607 }, -- Generated mesh, live lootAudit
	Museum_Diamond = { 1.0000, 3.149, 5.000, 3.160 }, -- Generated mesh, lootAudit.
	Pirate_TreasureMap = { 1.0000, 4.780, 5.000, 3.419 }, -- Treasure Map: 4.78 x 5.00 x 3.42 -> 4.78 x 5.00 x 3.42
	Pirate_CaptainsHat = { 1.0000, 6.852, 5.000, 6.930 }, -- Captain's Hat: 6.85 x 5.00 x 6.93 -> 6.85 x 5.00 x 6.93
	Pirate_GoldenCompass = { 1.0000, 4.340, 5.000, 6.512 }, -- Golden Compass: 4.34 x 5.00 x 6.51 -> 4.34 x 5.00 x 6.51
	Pirate_GoldenHook = { 1.0000, 4.203, 5.000, 1.310 }, -- Golden Hook: 4.20 x 5.00 x 1.31 -> 4.20 x 5.00 x 1.31
	Pirate_TreasureChest = { 1.0000, 4.410, 5.000, 4.125 }, -- Treasure Chest: 4.41 x 5.00 x 4.12 -> 4.41 x 5.00 x 4.12
	Pirate_CaptainsCutlass = { 1.0000, 2.925, 5.000, 5.437 }, -- Captain's Cutlass: 2.93 x 5.00 x 5.44 -> 2.93 x 5.00 x 5.44
	Pirate_JeweledSkull = { 1.0000, 4.319, 5.000, 4.782 }, -- Jeweled Skull: 4.32 x 5.00 x 4.78 -> 4.32 x 5.00 x 4.78
	Pirate_CursedCoin = { 1.0000, 7.500, 4.048, 5.866 }, -- Cursed Coin: 7.50 x 4.05 x 5.87 -> 7.50 x 4.05 x 5.87
	Castle_GoldenGoblet = { 1.0000, 2.798, 5.000, 2.799 }, -- Golden Goblet: 2.80 x 5.00 x 2.80 -> 2.80 x 5.00 x 2.80
	Castle_RoyalPainting = { 1.0000, 2.372, 5.000, 1.204 }, -- Royal Painting: 2.37 x 5.00 x 1.20 -> 2.37 x 5.00 x 1.20
	Castle_RoyalSeal = { 1.0000, 5.377, 5.000, 5.304 }, -- Royal Seal: 5.38 x 5.00 x 5.30 -> 5.38 x 5.00 x 5.30
	Castle_GoldenKey = { 1.0000, 9.923, 4.000, 1.359 }, -- Golden Key: 9.92 x 4.00 x 1.36 -> 9.92 x 4.00 x 1.36
	Castle_JeweledShield = { 1.0000, 2.401, 5.000, 1.260 }, -- Jeweled Shield: 2.40 x 5.00 x 1.26 -> 2.40 x 5.00 x 1.26
	Castle_RoyalScepter = { 1.0000, 2.917, 5.000, 1.175 }, -- Royal Scepter: 2.92 x 5.00 x 1.17 -> 2.92 x 5.00 x 1.17
	Castle_RoyalTreasureChest = { 1.0000, 3.926, 5.000, 3.523 }, -- Royal Treasure Chest: 3.93 x 5.00 x 3.52 -> 3.93 x 5.00 x 3.52
	Castle_KingsCrown = { 1.0000, 5.795, 5.000, 5.275 }, -- King's Crown: 5.80 x 5.00 x 5.27 -> 5.80 x 5.00 x 5.27
	Area51_TopSecretFiles = { 1.0000, 4.457, 5.000, 2.110 }, -- Top Secret Files: 4.46 x 5.00 x 2.11 -> 4.46 x 5.00 x 2.11
	Area51_MeteorFragment = { 1.0000, 2.337, 5.000, 2.366 }, -- Meteor Fragment: 2.34 x 5.00 x 2.37 -> 2.34 x 5.00 x 2.37
	Area51_AlienHelmet = { 1.0000, 4.772, 5.000, 4.453 }, -- Alien Helmet: 4.77 x 5.00 x 4.45 -> 4.77 x 5.00 x 4.45
	Area51_AlienRayDevice = { 1.0000, 5.748, 5.000, 2.619 }, -- Alien Ray Device: 5.75 x 5.00 x 2.62 -> 5.75 x 5.00 x 2.62
	Area51_AlienCrystal = { 1.0000, 3.167, 5.000, 2.886 }, -- Alien Crystal: 3.17 x 5.00 x 2.89 -> 3.17 x 5.00 x 2.89
	Area51_AntiGravityCube = { 1.0000, 3.694, 5.000, 3.670 }, -- Anti-Gravity Cube: 3.69 x 5.00 x 3.67 -> 3.69 x 5.00 x 3.67
	Area51_UFOCore = { 1.0000, 5.480, 5.000, 5.461 }, -- UFO Core: 5.48 x 5.00 x 5.46 -> 5.48 x 5.00 x 5.46
	Area51_AlienArtifact = { 1.0000, 4.881, 5.000, 4.886 }, -- Alien Artifact: 4.88 x 5.00 x 4.89 -> 4.88 x 5.00 x 4.89
	NorthPole_SantasHat = { 1.0000, 5.652, 5.000, 4.650 }, -- Santa's Hat: 5.65 x 5.00 x 4.65 -> 5.65 x 5.00 x 4.65
	NorthPole_NiceList = { 1.0000, 5.391, 5.000, 2.208 }, -- Toy Train: 5.39 x 5.00 x 2.21 -> 5.39 x 5.00 x 2.21
	NorthPole_GoldenBell = { 1.0000, 4.189, 5.000, 3.678 }, -- Golden Bell: 4.19 x 5.00 x 3.68 -> 4.19 x 5.00 x 3.68
	NorthPole_ToyBlueprint = { 1.0000, 3.486, 5.000, 1.963 }, -- Toy Blueprint: 3.49 x 5.00 x 1.96 -> 3.49 x 5.00 x 1.96
	NorthPole_GoldenPresent = { 1.0000, 3.551, 5.000, 3.544 }, -- Golden Present: 3.55 x 5.00 x 3.54 -> 3.55 x 5.00 x 3.54
	NorthPole_MagicSnowGlobe = { 1.0000, 4.835, 5.000, 4.194 }, -- Magic Snow Globe: 4.83 x 5.00 x 4.19 -> 4.83 x 5.00 x 4.19
	NorthPole_SantasGiftSack = { 1.0000, 4.855, 5.000, 4.854 }, -- Santa's Gift Sack: 4.86 x 5.00 x 4.85 -> 4.86 x 5.00 x 4.85
	NorthPole_ChristmasStar = { 1.0000, 3.525, 5.000, 2.790 }, -- Christmas Star: 3.53 x 5.00 x 2.79 -> 3.53 x 5.00 x 2.79
	Egypt_CanopicJar = { 1.0000, 2.548, 5.000, 0.664 }, -- Pharaoh's Golden Scepter: 2.55 x 5.00 x 0.66 -> 2.55 x 5.00 x 0.66
	Egypt_Shawarma = { 1.0000, 1.940, 5.000, 2.005 }, -- Shawarma: 1.94 x 5.00 x 2.01 -> 1.94 x 5.00 x 2.01
	Egypt_AncientMau = { 1.0000, 2.322, 5.000, 3.230 }, -- Ancient Mau: 2.32 x 5.00 x 3.23 -> 2.32 x 5.00 x 3.23
	Egypt_AncientScroll = { 1.0000, 3.349, 5.000, 1.169 }, -- Ancient Scroll: 3.35 x 5.00 x 1.17 -> 3.35 x 5.00 x 1.17
	Egypt_Mummy = { 1.0000, 2.207, 5.000, 2.101 }, -- Mummy: 2.21 x 5.00 x 2.10 -> 2.21 x 5.00 x 2.10
	Egypt_ThroneOfRa = { 1.0000, 2.572, 5.000, 2.703 }, -- Throne of Ra: 2.57 x 5.00 x 2.70 -> 2.57 x 5.00 x 2.70
	Egypt_NemesMask = { 1.0000, 4.526, 5.000, 3.154 }, -- Nemes Mask: 4.53 x 5.00 x 3.15 -> 4.53 x 5.00 x 3.15
	Egypt_EgyptianPyramid = { 1.0000, 4.621, 5.000, 3.996 }, -- Egyptian Pyramid: 4.62 x 5.00 x 4.00 -> 4.62 x 5.00 x 4.00
	Gym_Water = { 1.0000, 1.800, 5.000, 1.556 }, -- Water: 1.80 x 5.00 x 1.56 -> 1.80 x 5.00 x 1.56
	Gym_Creatine = { 1.0000, 4.949, 5.000, 4.157 }, -- Boxing Gloves: 4.95 x 5.00 x 4.16 -> 4.95 x 5.00 x 4.16
	Gym_CoachsWhistle = { 1.0000, 4.050, 5.000, 1.831 }, -- Gym Whistle: 4.05 x 5.00 x 1.83 -> 4.05 x 5.00 x 1.83
	Gym_VanillaMilkshake = { 1.0000, 2.621, 5.000, 1.923 }, -- Vanilla Milkshake: 2.62 x 5.00 x 1.92 -> 2.62 x 5.00 x 1.92
	Gym_Airpods = { 1.0000, 3.461, 5.000, 2.908 }, -- Airpods: 3.46 x 5.00 x 2.91 -> 3.46 x 5.00 x 2.91
	Gym_GoldenDumbbell = { 1.0000, 5.971, 5.000, 3.203 }, -- Golden Dumbbells: 5.97 x 5.00 x 3.20 -> 5.97 x 5.00 x 3.20
	Gym_Trophy = { 1.0000, 4.098, 5.000, 2.686 }, -- Trophy: 4.10 x 5.00 x 2.69 -> 4.10 x 5.00 x 2.69
	Gym_GoldenBarbell = { 1.0000, 8.996, 4.000, 3.058 }, -- Golden Barbell: 9.00 x 4.00 x 3.06 -> 9.00 x 4.00 x 3.06
	Bank_MoneyStack = { 1.0000, 6.566, 5.000, 3.846 }, -- Money Stack: 6.57 x 5.00 x 3.85 -> 6.57 x 5.00 x 3.85
	Bank_CashBag = { 1.0000, 5.116, 5.000, 3.984 }, -- Money Print Machine: 5.12 x 5.00 x 3.98 -> 5.12 x 5.00 x 3.98
	Bank_VaultKey = { 1.0000, 2.098, 5.000, 0.610 }, -- Master Key: 2.10 x 5.00 x 0.61 -> 2.10 x 5.00 x 0.61
	Bank_RareCoin = { 1.0000, 7.057, 4.530, 7.500 }, -- Shiny Coin: 7.06 x 4.53 x 7.50 -> 7.06 x 4.53 x 7.50
	Bank_GoldBar = { 1.0000, 8.666, 4.000, 2.597 }, -- Gold Bar: 8.67 x 4.00 x 2.60 -> 8.67 x 4.00 x 2.60
	Bank_BankersBriefcase = { 1.0000, 5.342, 5.000, 2.211 }, -- Banker's Briefcase: 5.34 x 5.00 x 2.21 -> 5.34 x 5.00 x 2.21
	Bank_PlatinumBullionStack = { 1.0000, 6.523, 5.000, 5.031 }, -- Platinum Bullion Stack: 6.52 x 5.00 x 5.03 -> 6.52 x 5.00 x 5.03
	Bank_VendingMachine = { 1.0000, 5.000, 5.000, 2.445 }, -- Vending Machine: 5.00 x 5.00 x 2.44 -> 5.00 x 5.00 x 2.44
	SecretLab_SecretFormula = { 0.8333, 3.500, 6.000, 3.500 }, -- Mutant Specimen: 3.50 x 6.00 x 3.50 -> 2.92 x 5.00 x 2.92
	SecretLab_ChemicalCylinder = { 1.0000, 2.605, 5.000, 2.618 }, -- Chemical Cylinder: 2.61 x 5.00 x 2.62 -> 2.61 x 5.00 x 2.62
	SecretLab_ContainmentTank = { 1.0000, 2.048, 5.000, 2.048 }, -- Containment Tank: 2.05 x 5.00 x 2.05 -> 2.05 x 5.00 x 2.05
	SecretLab_RobotSpider = { 1.0000, 7.777, 4.000, 6.834 }, -- Robot Spider: 7.78 x 4.00 x 6.83 -> 7.78 x 4.00 x 6.83
	SecretLab_MutationCrystal = { 1.0000, 3.828, 5.000, 3.935 }, -- Blue Crystal: 3.83 x 5.00 x 3.94 -> 3.83 x 5.00 x 3.94
	SecretLab_CyanPlasma = { 1.0000, 4.472, 5.000, 2.099 }, -- Cyan Plasma: 4.47 x 5.00 x 2.10 -> 4.47 x 5.00 x 2.10
	SecretLab_EnergyCore = { 1.0000, 4.979, 5.000, 4.979 }, -- Energy Canister: 4.98 x 5.00 x 4.98 -> 4.98 x 5.00 x 4.98
	SecretLab_RadiationChamber = { 1.0000, 4.046, 5.000, 4.400 }, -- Radiation Chamber: 4.05 x 5.00 x 4.40 -> 4.05 x 5.00 x 4.40
	Grandma_CandyBowl = { 1.0870, 4.600, 4.600, 0.900 }, -- Grandmas Cookies: 4.60 x 4.60 x 0.90 -> 5.00 x 5.00 x 0.98
	Grandma_KnittedSweater = { 1.0000, 5.168, 5.000, 2.572 }, -- Red Shirt: 5.17 x 5.00 x 2.57 -> 5.17 x 5.00 x 2.57
	Grandma_WalkingCane = { 1.0000, 1.013, 5.000, 0.493 }, -- Walking Cane: 1.01 x 5.00 x 0.49 -> 1.01 x 5.00 x 0.49
	Grandma_GoldenTeapot = { 1.0000, 5.681, 5.000, 3.733 }, -- Golden Teapot: 5.68 x 5.00 x 3.73 -> 5.68 x 5.00 x 3.73
	Grandma_AntiqueClock = { 1.0000, 2.004, 5.000, 1.623 }, -- Grandfather Clock: 2.00 x 5.00 x 1.62 -> 2.00 x 5.00 x 1.62
	Grandma_GrandmasPurse = { 1.0000, 3.443, 5.000, 1.566 }, -- Pink Handbag: 3.44 x 5.00 x 1.57 -> 3.44 x 5.00 x 1.57
	Grandma_LegendaryGiftBox = { 1.0000, 5.003, 5.000, 4.986 }, -- Legendary Gift Box: 5.00 x 5.00 x 4.99 -> 5.00 x 5.00 x 4.99
	Grandma_CookieJar = { 1.0000, 3.775, 5.000, 3.609 }, -- Cookie Jar: 3.78 x 5.00 x 3.61 -> 3.78 x 5.00 x 3.61
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
LootConfig.ModelOverrides = {} :: { [string]: string }

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
