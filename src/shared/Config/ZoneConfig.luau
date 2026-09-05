--!strict
--[[
	ZoneConfig
	The 12-zone progression and its Speed gates (GDD section 5).

	`recommendedSpeed` is a SOFT gate. Players may physically walk into any zone;
	guardian tuning is what makes extraction hard below the recommendation. That
	preserves curiosity and creates "I almost made it" moments, so nothing in the
	codebase should ever hard-block entry on this number.
]]

local ZoneConfig = {}

export type ZoneDef = {
	index: number,
	id: string, -- matches the Workspace.Map.Zones folder name
	name: string,
	guardian: string,
	recommendedSpeed: number,
	--- Bosses get the alert horn and the heavy hit reaction; regular guards get
	--- the police whistle and the standard hit. Zone 1 is the tutorial Cop and is
	--- deliberately NOT a boss.
	isBoss: boolean,
}

ZoneConfig.Zones = {
	{ index = 1, id = "Zone01_Museum", name = "Museum", guardian = "Cop", recommendedSpeed = 0, isBoss = false },
	{ index = 2, id = "Zone02_Pirate", name = "Pirate Island", guardian = "PirateCaptain", recommendedSpeed = 900, isBoss = true },
	{ index = 3, id = "Zone03_Castle", name = "Castle", guardian = "RoyalGuard", recommendedSpeed = 10e3, isBoss = true },
	{ index = 4, id = "Zone04_Area51", name = "Area 51", guardian = "Agent", recommendedSpeed = 40e3, isBoss = true },
	{ index = 5, id = "Zone05_NorthPole", name = "North Pole", guardian = "ElfGuard", recommendedSpeed = 170e3, isBoss = true },
	{ index = 6, id = "Zone06_Egypt", name = "Ancient Egypt", guardian = "MummyGuardian", recommendedSpeed = 700e3, isBoss = true },
	{ index = 7, id = "Zone07_Gym", name = "Gym", guardian = "Bodybuilder", recommendedSpeed = 2.5e6, isBoss = true },
	{ index = 8, id = "Zone08_Bank", name = "Bank", guardian = "BankGuard", recommendedSpeed = 18e6, isBoss = true },
	{ index = 9, id = "Zone09_SecretLab", name = "Secret Lab", guardian = "MadScientist", recommendedSpeed = 700e6, isBoss = true },
	{ index = 10, id = "Zone10_Grandma", name = "Grandma's House", guardian = "Grandma", recommendedSpeed = 2.5e9, isBoss = true },
	{ index = 11, id = "Zone11_Construction", name = "Construction Site", guardian = "Foreman", recommendedSpeed = 7e9, isBoss = true },
	{ index = 12, id = "Zone12_Airport", name = "Airport", guardian = "AirportSecurity", recommendedSpeed = 20e9, isBoss = true },
} :: { ZoneDef }

ZoneConfig.COUNT = #ZoneConfig.Zones
ZoneConfig.SOCKETS_PER_ZONE = 4

ZoneConfig.ById = {} :: { [string]: ZoneDef }
for _, zone in ZoneConfig.Zones do
	ZoneConfig.ById[zone.id] = zone
end

--- Guardians move just under the player who meets the recommendation, so a
--- Normal-size item is a narrow win and bigger loot demands a Speed buffer.
ZoneConfig.GUARDIAN_SPEED_FACTOR = 0.98
ZoneConfig.GUARDIAN_CATCH_RADIUS = 6
ZoneConfig.GUARDIAN_REPATH_INTERVAL = 0.4

return ZoneConfig
