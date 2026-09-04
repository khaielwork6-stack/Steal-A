--!strict
--[[
	LootConfig
	The full 96-item economy: 12 zones x 8 item types.

	Transcribed directly from section 7 of the master GDD. `income` is the item's
	BASE income per second, before Size and Mutation multipliers. `chance` is the
	exact per-roll probability for that item within its zone.

	ItemId is the stable save key and must NEVER be renamed - the display `name`
	is the only player-facing text and is safe to change.
]]

export type ItemDef = {
	id: string,
	name: string,
	rarity: string,
	chance: number,
	income: number,
}

local LootConfig = {}

--- Item pools keyed by zone index (1-12), eight types each.
LootConfig.Items = {
	-- Zone 01 MUSEUM
	{
		{ id = "Museum_AncientVase", name = "Ancient Vase", rarity = "Common", chance = 0.175, income = 967 },
		{ id = "Museum_RarePainting", name = "Rare Painting", rarity = "Common", chance = 0.175, income = 1210 },
		{ id = "Museum_GoldenStatue", name = "Golden Statue", rarity = "Uncommon", chance = 0.135, income = 2320 },
		{ id = "Museum_PharaohMask", name = "Pharaoh Mask", rarity = "Uncommon", chance = 0.135, income = 2900 },
		{ id = "Museum_Ruby", name = "Ruby", rarity = "Rare", chance = 0.18, income = 5800 },
		{ id = "Museum_GoldenCrown", name = "Golden Crown", rarity = "Epic", chance = 0.11, income = 13540 },
		{ id = "Museum_Meteorite", name = "Meteorite", rarity = "Legendary", chance = 0.045, income = 33840 },
		{ id = "Museum_Diamond", name = "Diamond", rarity = "Legendary", chance = 0.045, income = 48350 },
	},
	-- Zone 02 PIRATE ISLAND
	{
		{ id = "Pirate_TreasureMap", name = "Treasure Map", rarity = "Common", chance = 0.175, income = 3870 },
		{ id = "Pirate_CaptainsHat", name = "Captain's Hat", rarity = "Common", chance = 0.175, income = 4830 },
		{ id = "Pirate_GoldenCompass", name = "Golden Compass", rarity = "Uncommon", chance = 0.135, income = 9280 },
		{ id = "Pirate_GoldenHook", name = "Golden Hook", rarity = "Uncommon", chance = 0.135, income = 11600 },
		{ id = "Pirate_TreasureChest", name = "Treasure Chest", rarity = "Rare", chance = 0.18, income = 23210 },
		{ id = "Pirate_CaptainsCutlass", name = "Captain's Cutlass", rarity = "Epic", chance = 0.11, income = 54150 },
		{ id = "Pirate_JeweledSkull", name = "Jeweled Skull", rarity = "Legendary", chance = 0.045, income = 135000 },
		{ id = "Pirate_CursedCoin", name = "Cursed Coin", rarity = "Legendary", chance = 0.045, income = 193000 },
	},
	-- Zone 03 CASTLE
	{
		{ id = "Castle_GoldenGoblet", name = "Golden Goblet", rarity = "Common", chance = 0.175, income = 11600 },
		{ id = "Castle_RoyalPainting", name = "Royal Painting", rarity = "Common", chance = 0.175, income = 14510 },
		{ id = "Castle_RoyalSeal", name = "Royal Seal", rarity = "Uncommon", chance = 0.135, income = 27850 },
		{ id = "Castle_GoldenKey", name = "Golden Key", rarity = "Uncommon", chance = 0.135, income = 34810 },
		{ id = "Castle_JeweledShield", name = "Jeweled Shield", rarity = "Rare", chance = 0.18, income = 69620 },
		{ id = "Castle_RoyalScepter", name = "Royal Scepter", rarity = "Epic", chance = 0.11, income = 162000 },
		{ id = "Castle_RoyalTreasureChest", name = "Royal Treasure Chest", rarity = "Legendary", chance = 0.045, income = 406000 },
		{ id = "Castle_KingsCrown", name = "King's Crown", rarity = "Legendary", chance = 0.045, income = 580000 },
	},
	-- Zone 04 AREA 51
	{
		{ id = "Area51_TopSecretFiles", name = "Top Secret Files", rarity = "Common", chance = 0.175, income = 33840 },
		{ id = "Area51_MeteorFragment", name = "Meteor Fragment", rarity = "Common", chance = 0.175, income = 42310 },
		{ id = "Area51_AlienHelmet", name = "Alien Helmet", rarity = "Uncommon", chance = 0.135, income = 81230 },
		{ id = "Area51_AlienRayDevice", name = "Alien Ray Device", rarity = "Uncommon", chance = 0.135, income = 102000 },
		{ id = "Area51_AlienCrystal", name = "Alien Crystal", rarity = "Rare", chance = 0.18, income = 203000 },
		{ id = "Area51_AntiGravityCube", name = "Anti-Gravity Cube", rarity = "Epic", chance = 0.11, income = 474000 },
		{ id = "Area51_UFOCore", name = "UFO Core", rarity = "Legendary", chance = 0.045, income = 1180000 },
		{ id = "Area51_AlienArtifact", name = "Alien Artifact", rarity = "Legendary", chance = 0.045, income = 1690000 },
	},
	-- Zone 05 NORTH POLE
	{
		{ id = "NorthPole_SantasHat", name = "Santa's Hat", rarity = "Common", chance = 0.175, income = 96700 },
		{ id = "NorthPole_NiceList", name = "Nice List", rarity = "Common", chance = 0.175, income = 121000 },
		{ id = "NorthPole_GoldenBell", name = "Golden Bell", rarity = "Uncommon", chance = 0.135, income = 232000 },
		{ id = "NorthPole_ToyBlueprint", name = "Toy Blueprint", rarity = "Uncommon", chance = 0.135, income = 290000 },
		{ id = "NorthPole_GoldenPresent", name = "Golden Present", rarity = "Rare", chance = 0.18, income = 580000 },
		{ id = "NorthPole_MagicSnowGlobe", name = "Magic Snow Globe", rarity = "Epic", chance = 0.11, income = 1350000 },
		{ id = "NorthPole_SantasGiftSack", name = "Santa's Gift Sack", rarity = "Legendary", chance = 0.07, income = 3380000 },
		{ id = "NorthPole_ChristmasStar", name = "Christmas Star", rarity = "Secret", chance = 0.02, income = 11600000 },
	},
	-- Zone 06 ANCIENT EGYPT
	{
		{ id = "Egypt_CanopicJar", name = "Canopic Jar", rarity = "Common", chance = 0.175, income = 290000 },
		{ id = "Egypt_AncientScroll", name = "Ancient Scroll", rarity = "Common", chance = 0.175, income = 363000 },
		{ id = "Egypt_GoldenScarab", name = "Golden Scarab", rarity = "Uncommon", chance = 0.135, income = 696000 },
		{ id = "Egypt_GoldenAnkh", name = "Golden Ankh", rarity = "Uncommon", chance = 0.135, income = 870000 },
		{ id = "Egypt_RoyalScepter", name = "Royal Scepter", rarity = "Rare", chance = 0.18, income = 1740000 },
		{ id = "Egypt_PharaohCrown", name = "Pharaoh Crown", rarity = "Epic", chance = 0.11, income = 4060000 },
		{ id = "Egypt_PharaohMask", name = "Pharaoh Mask", rarity = "Legendary", chance = 0.07, income = 10150000 },
		{ id = "Egypt_GoldenSarcophagus", name = "Golden Sarcophagus", rarity = "Secret", chance = 0.02, income = 34810000 },
	},
	-- Zone 07 GYM
	{
		{ id = "Gym_ProteinTub", name = "Protein Tub", rarity = "Common", chance = 0.175, income = 870000 },
		{ id = "Gym_CoachsWhistle", name = "Coach's Whistle", rarity = "Common", chance = 0.175, income = 1090000 },
		{ id = "Gym_VIPGymBag", name = "VIP Gym Bag", rarity = "Uncommon", chance = 0.135, income = 2090000 },
		{ id = "Gym_GoldenDumbbell", name = "Golden Dumbbell", rarity = "Uncommon", chance = 0.135, income = 2610000 },
		{ id = "Gym_WorldRecordMedal", name = "World Record Medal", rarity = "Rare", chance = 0.18, income = 5220000 },
		{ id = "Gym_Trophy", name = "Trophy", rarity = "Epic", chance = 0.11, income = 12180000 },
		{ id = "Gym_ChampionshipBelt", name = "Championship Belt", rarity = "Legendary", chance = 0.07, income = 30460000 },
		{ id = "Gym_GoldenBarbell", name = "Golden Barbell", rarity = "Secret", chance = 0.02, income = 104000000 },
	},
	-- Zone 08 BANK
	{
		{ id = "Bank_MoneyStack", name = "Money Stack", rarity = "Common", chance = 0.175, income = 2900000 },
		{ id = "Bank_CashBag", name = "Cash Bag", rarity = "Common", chance = 0.175, income = 3630000 },
		{ id = "Bank_VaultKey", name = "Vault Key", rarity = "Uncommon", chance = 0.135, income = 6960000 },
		{ id = "Bank_RareCoin", name = "Rare Coin", rarity = "Uncommon", chance = 0.135, income = 8700000 },
		{ id = "Bank_GoldBar", name = "Gold Bar", rarity = "Rare", chance = 0.18, income = 17410000 },
		{ id = "Bank_BankersBriefcase", name = "Banker's Briefcase", rarity = "Epic", chance = 0.11, income = 40610000 },
		{ id = "Bank_DiamondBriefcase", name = "Diamond Briefcase", rarity = "Legendary", chance = 0.07, income = 102000000 },
		{ id = "Bank_GoldenCreditCard", name = "Golden Credit Card", rarity = "Secret", chance = 0.02, income = 348000000 },
	},
	-- Zone 09 SECRET LAB
	{
		{ id = "SecretLab_SecretFormula", name = "Secret Formula", rarity = "Common", chance = 0.175, income = 9670000 },
		{ id = "SecretLab_PrototypeChip", name = "Prototype Chip", rarity = "Common", chance = 0.175, income = 12090000 },
		{ id = "SecretLab_GlowingSerum", name = "Glowing Serum", rarity = "Uncommon", chance = 0.135, income = 23210000 },
		{ id = "SecretLab_RobotBrain", name = "Robot Brain", rarity = "Uncommon", chance = 0.135, income = 29010000 },
		{ id = "SecretLab_MutationCrystal", name = "Mutation Crystal", rarity = "Rare", chance = 0.18, income = 58020000 },
		{ id = "SecretLab_PortalBattery", name = "Portal Battery", rarity = "Epic", chance = 0.11, income = 135000000 },
		{ id = "SecretLab_EnergyCore", name = "Energy Core", rarity = "Legendary", chance = 0.07, income = 338000000 },
		{ id = "SecretLab_ForbiddenExperiment", name = "Forbidden Experiment", rarity = "Secret", chance = 0.02, income = 1160000000 },
	},
	-- Zone 10 GRANDMA'S HOUSE
	{
		{ id = "Grandma_CandyBowl", name = "Candy Bowl", rarity = "Common", chance = 0.175, income = 33840000 },
		{ id = "Grandma_KnittedSweater", name = "Knitted Sweater", rarity = "Common", chance = 0.175, income = 42310000 },
		{ id = "Grandma_SecretRecipe", name = "Secret Recipe", rarity = "Uncommon", chance = 0.135, income = 81230000 },
		{ id = "Grandma_GoldenTeapot", name = "Golden Teapot", rarity = "Uncommon", chance = 0.135, income = 102000000 },
		{ id = "Grandma_AntiqueClock", name = "Antique Clock", rarity = "Rare", chance = 0.18, income = 203000000 },
		{ id = "Grandma_GrandmasPurse", name = "Grandma's Purse", rarity = "Epic", chance = 0.11, income = 474000000 },
		{ id = "Grandma_FamilyJewelryBox", name = "Family Jewelry Box", rarity = "Legendary", chance = 0.07, income = 1180000000 },
		{ id = "Grandma_CookieJar", name = "Cookie Jar", rarity = "Secret", chance = 0.02, income = 4060000000 },
	},
	-- Zone 11 CONSTRUCTION SITE
	{
		{ id = "Construction_Blueprints", name = "Blueprints", rarity = "Common", chance = 0.175, income = 116000000 },
		{ id = "Construction_RareSafetyVest", name = "Rare Safety Vest", rarity = "Common", chance = 0.175, income = 145000000 },
		{ id = "Construction_ForemansToolbox", name = "Foreman's Toolbox", rarity = "Uncommon", chance = 0.135, income = 278000000 },
		{ id = "Construction_MasterKey", name = "Master Key", rarity = "Uncommon", chance = 0.135, income = 348000000 },
		{ id = "Construction_GoldenHardHat", name = "Golden Hard Hat", rarity = "Rare", chance = 0.18, income = 696000000 },
		{ id = "Construction_GoldenDrill", name = "Golden Drill", rarity = "Epic", chance = 0.11, income = 1620000000 },
		{ id = "Construction_ConstructionTrophy", name = "Construction Trophy", rarity = "Legendary", chance = 0.07, income = 4060000000 },
		{ id = "Construction_DiamondHammer", name = "Diamond Hammer", rarity = "Secret", chance = 0.02, income = 13920000000 },
	},
	-- Zone 12 AIRPORT
	{
		{ id = "Airport_FirstClassTicket", name = "First-Class Ticket", rarity = "Common", chance = 0.175, income = 387000000 },
		{ id = "Airport_VIPPassport", name = "VIP Passport", rarity = "Common", chance = 0.175, income = 484000000 },
		{ id = "Airport_PilotsHat", name = "Pilot's Hat", rarity = "Uncommon", chance = 0.135, income = 928000000 },
		{ id = "Airport_LostBriefcase", name = "Lost Briefcase", rarity = "Uncommon", chance = 0.135, income = 1160000000 },
		{ id = "Airport_AirportMasterKey", name = "Airport Master Key", rarity = "Rare", chance = 0.18, income = 2320000000 },
		{ id = "Airport_BlackBox", name = "Black Box", rarity = "Epic", chance = 0.11, income = 5420000000 },
		{ id = "Airport_GoldenSuitcase", name = "Golden Suitcase", rarity = "Legendary", chance = 0.07, income = 13540000000 },
		{ id = "Airport_DutyFreeDiamond", name = "Duty-Free Diamond", rarity = "Secret", chance = 0.02, income = 46420000000 },
	},
} :: { { ItemDef } }

--- Flat lookups, built once at require time.
LootConfig.ById = {} :: { [string]: ItemDef }
LootConfig.ZoneOf = {} :: { [string]: number }

for zoneIndex, pool in LootConfig.Items do
	for _, item in pool do
		LootConfig.ById[item.id] = item
		LootConfig.ZoneOf[item.id] = zoneIndex
	end
end

return LootConfig