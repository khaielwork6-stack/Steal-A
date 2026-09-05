--!strict
--[[
	LootConfig
	The full 96-item economy: 12 zones x 8 item types.

	`income` is the item's BASE income per second, before Size and Mutation
	multipliers. It is the ONLY per-item number typed here.

	`rarity` and `jackpot` are DERIVED, not typed: an item's tier is a function of
	its position in its zone's ladder (RarityConfig.ZoneLadders), so the ladder is
	the single place to retune which zones can host which tiers, and an item can
	never drift out of step with the tier it is supposed to wear.

	ItemId is the stable save key and must NEVER be renamed - the display `name`
	is the only player-facing text and is safe to change.

	== THE SHAPE OF THIS ECONOMY (read before "fixing" a number) ==

	The intra-zone gaps are enormous ON PURPOSE. Position 1 in a zone is garbage
	the player steals anyway; position 8 is a jackpot worth hundreds or thousands
	of times more. The Museum runs $1 -> $1,800/s; Pirate Island runs $3 ->
	$220,000/s. Do not smooth these curves and do not sort them:

	  * The Bank is deliberately NON-monotonic - the Banker's Briefcase ($32M)
	    out-earns the Diamond Briefcase ($25M) that sits above it in the ladder.
	  * Income is deliberately NOT normalised across zones. A Common in a late
	    zone can be worth far less than an early zone's jackpot. That is what
	    makes a jackpot feel like a jackpot instead of a step on a staircase.

	Zone 12 (Airport) is our own post-reference extension and its numbers are a
	SEPARATE tuning layer - see the note above that pool.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

export type ItemDef = {
	id: string,
	name: string,
	income: number,
	-- Filled in below from the zone ladder. Never type these by hand.
	rarity: string,
	position: number,
	jackpot: boolean,
}

type ItemSeed = { id: string, name: string, income: number }

local LootConfig = {}

--- The slot in every zone that carries the jackpot. Jackpot items are excluded
--- from ordinary socket rolls entirely - they arrive only through the global
--- refresh jackpot event.
LootConfig.JACKPOT_POSITION = RarityConfig.JACKPOT_POSITION

--- Item pools keyed by zone index (1-12), eight types each, in ladder order.
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
		{ id = "NorthPole_NiceList", name = "Nice List", income = 600 },
		{ id = "NorthPole_GoldenBell", name = "Golden Bell", income = 7e3 },
		{ id = "NorthPole_ToyBlueprint", name = "Toy Blueprint", income = 35e3 },
		{ id = "NorthPole_GoldenPresent", name = "Golden Present", income = 42e3 },
		{ id = "NorthPole_MagicSnowGlobe", name = "Magic Snow Globe", income = 400e3 },
		{ id = "NorthPole_SantasGiftSack", name = "Santa's Gift Sack", income = 5e6 },
		{ id = "NorthPole_ChristmasStar", name = "Christmas Star", income = 65e6 },
	},
	-- Zone 06 ANCIENT EGYPT
	{
		{ id = "Egypt_CanopicJar", name = "Canopic Jar", income = 180 },
		{ id = "Egypt_AncientScroll", name = "Ancient Scroll", income = 850 },
		{ id = "Egypt_GoldenScarab", name = "Golden Scarab", income = 9500 },
		{ id = "Egypt_GoldenAnkh", name = "Golden Ankh", income = 11e3 },
		{ id = "Egypt_RoyalScepter", name = "Royal Scepter", income = 55e3 },
		{ id = "Egypt_PharaohCrown", name = "Pharaoh Crown", income = 8e6 },
		{ id = "Egypt_PharaohMask", name = "Pharaoh Mask", income = 85e6 },
		{ id = "Egypt_GoldenSarcophagus", name = "Golden Sarcophagus", income = 100e6 },
	},
	-- Zone 07 GYM
	{
		{ id = "Gym_ProteinTub", name = "Protein Tub", income = 220 },
		{ id = "Gym_CoachsWhistle", name = "Coach's Whistle", income = 1100 },
		{ id = "Gym_VIPGymBag", name = "VIP Gym Bag", income = 15e3 },
		{ id = "Gym_GoldenDumbbell", name = "Golden Dumbbell", income = 80e3 },
		{ id = "Gym_WorldRecordMedal", name = "World Record Medal", income = 700e3 },
		{ id = "Gym_Trophy", name = "Trophy", income = 850e3 },
		{ id = "Gym_ChampionshipBelt", name = "Championship Belt", income = 15e6 },
		{ id = "Gym_GoldenBarbell", name = "Golden Barbell", income = 130e6 },
	},
	-- Zone 08 BANK
	-- The $32M -> $25M step at positions 6/7 is INTENTIONAL. Do not sort.
	{
		{ id = "Bank_MoneyStack", name = "Money Stack", income = 280 },
		{ id = "Bank_CashBag", name = "Cash Bag", income = 22e3 },
		{ id = "Bank_VaultKey", name = "Vault Key", income = 120e3 },
		{ id = "Bank_RareCoin", name = "Rare Coin", income = 1.2e6 },
		{ id = "Bank_GoldBar", name = "Gold Bar", income = 1.5e6 },
		{ id = "Bank_BankersBriefcase", name = "Banker's Briefcase", income = 32e6 },
		{ id = "Bank_DiamondBriefcase", name = "Diamond Briefcase", income = 25e6 },
		{ id = "Bank_GoldenCreditCard", name = "Golden Credit Card", income = 180e6 },
	},
	-- Zone 09 SECRET LAB
	{
		{ id = "SecretLab_SecretFormula", name = "Secret Formula", income = 1500 },
		{ id = "SecretLab_PrototypeChip", name = "Prototype Chip", income = 30e3 },
		{ id = "SecretLab_GlowingSerum", name = "Glowing Serum", income = 180e3 },
		{ id = "SecretLab_RobotBrain", name = "Robot Brain", income = 2.2e6 },
		{ id = "SecretLab_MutationCrystal", name = "Mutation Crystal", income = 45e6 },
		{ id = "SecretLab_PortalBattery", name = "Portal Battery", income = 60e6 },
		{ id = "SecretLab_EnergyCore", name = "Energy Core", income = 250e6 },
		{ id = "SecretLab_ForbiddenExperiment", name = "Forbidden Experiment", income = 1e9 },
	},
	-- Zone 10 GRANDMA'S HOUSE
	-- The final value here is a balancing TARGET rather than a locked number.
	{
		{ id = "Grandma_CandyBowl", name = "Candy Bowl", income = 4e3 },
		{ id = "Grandma_KnittedSweater", name = "Knitted Sweater", income = 74e3 },
		{ id = "Grandma_SecretRecipe", name = "Secret Recipe", income = 450e3 },
		{ id = "Grandma_GoldenTeapot", name = "Golden Teapot", income = 7.5e6 },
		{ id = "Grandma_AntiqueClock", name = "Antique Clock", income = 12e6 },
		{ id = "Grandma_GrandmasPurse", name = "Grandma's Purse", income = 145e6 },
		{ id = "Grandma_FamilyJewelryBox", name = "Family Jewelry Box", income = 600e6 },
		{ id = "Grandma_CookieJar", name = "Cookie Jar", income = 4e9 },
	},
	-- Zone 11 CONSTRUCTION SITE
	{
		{ id = "Construction_Blueprints", name = "Blueprints", income = 95e3 },
		{ id = "Construction_RareSafetyVest", name = "Rare Safety Vest", income = 130e3 },
		{ id = "Construction_ForemansToolbox", name = "Foreman's Toolbox", income = 750e3 },
		{ id = "Construction_MasterKey", name = "Master Key", income = 3e6 },
		{ id = "Construction_GoldenHardHat", name = "Golden Hard Hat", income = 17.5e6 },
		{ id = "Construction_GoldenDrill", name = "Golden Drill", income = 215e6 },
		{ id = "Construction_ConstructionTrophy", name = "Construction Trophy", income = 880e6 },
		{ id = "Construction_DiamondHammer", name = "Diamond Hammer", income = 6e9 },
	},
	-- ======================================================================
	-- Zone 12 AIRPORT - CUSTOM ZONE 12 TUNING LAYER
	-- ======================================================================
	-- Zones 1-11 follow the reference progression we are matching. The Airport
	-- is OUR OWN extension past the end of it, so its economy is not derived
	-- from that reference and is tuned independently.
	--
	-- These numbers were NOT touched by the zones 1-11 rebalance. If they are
	-- ever retuned it should be as a deliberate Zone 12 pass, not as a side
	-- effect of moving an earlier zone.
	{
		{ id = "Airport_FirstClassTicket", name = "First-Class Ticket", income = 387e6 },
		{ id = "Airport_VIPPassport", name = "VIP Passport", income = 484e6 },
		{ id = "Airport_PilotsHat", name = "Pilot's Hat", income = 928e6 },
		{ id = "Airport_LostBriefcase", name = "Lost Briefcase", income = 1.16e9 },
		{ id = "Airport_AirportMasterKey", name = "Airport Master Key", income = 2.32e9 },
		{ id = "Airport_BlackBox", name = "Black Box", income = 5.42e9 },
		{ id = "Airport_GoldenSuitcase", name = "Golden Suitcase", income = 13.54e9 },
		{ id = "Airport_DutyFreeDiamond", name = "Duty-Free Diamond", income = 46.42e9 },
	},
}

--- The finished pools, with rarity and jackpot resolved from the zone ladder.
LootConfig.Items = {} :: { { ItemDef } }

--- Flat lookups, built once at require time.
LootConfig.ById = {} :: { [string]: ItemDef }
LootConfig.ZoneOf = {} :: { [string]: number }

--- The jackpot item of each zone, by zone index.
LootConfig.JackpotByZone = {} :: { [number]: ItemDef }

for zoneIndex, pool in Seeds do
	local built: { ItemDef } = {}
	for position, seed in pool do
		local item: ItemDef = {
			id = seed.id,
			name = seed.name,
			income = seed.income,
			position = position,
			rarity = RarityConfig.rarityAt(zoneIndex, position),
			jackpot = position == LootConfig.JACKPOT_POSITION,
		}
		built[position] = item
		LootConfig.ById[item.id] = item
		LootConfig.ZoneOf[item.id] = zoneIndex
		if item.jackpot then
			LootConfig.JackpotByZone[zoneIndex] = item
		end
	end
	LootConfig.Items[zoneIndex] = built
end

--- The jackpot item for a zone, or nil for an unknown zone index.
function LootConfig.jackpotFor(zoneIndex: number): ItemDef?
	return LootConfig.JackpotByZone[zoneIndex]
end

--- Every item in a zone that an ordinary socket roll is allowed to produce.
function LootConfig.normalPool(zoneIndex: number): { ItemDef }
	local out = {}
	for _, item in LootConfig.Items[zoneIndex] or {} do
		if not item.jackpot then
			table.insert(out, item)
		end
	end
	return out
end

return LootConfig
