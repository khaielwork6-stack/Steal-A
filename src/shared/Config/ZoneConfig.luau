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
	--- The accent shown beside the zone's name in the entry pop-up and the
	--- Index. Single code points only: Roblox's text renderer draws these but
	--- not every multi-glyph (ZWJ) sequence, and a broken sequence shows as
	--- two boxes.
	emoji: string,
	--- The zone's own colour: the entry pop-up's title gradient runs from
	--- white into this, so every zone announces itself in its own voice.
	color: Color3,
	--- True for a zone with no reference-game equivalent. Lives behind
	--- GameConfig.POSTGAME_EXTENSION and outside every parity claim.
	postgame: boolean?,
}

ZoneConfig.Zones = {
	{ index = 1, id = "Zone01_Museum", name = "Museum", guardian = "Cop", recommendedSpeed = 0, isBoss = false, emoji = "🏛️", color = Color3.fromRGB(214, 190, 140) },
	{ index = 2, id = "Zone02_Pirate", name = "Pirate Island", guardian = "PirateCaptain", recommendedSpeed = 900, isBoss = true, emoji = "⚓", color = Color3.fromRGB(80, 190, 235) },
	{ index = 3, id = "Zone03_Castle", name = "Castle", guardian = "RoyalGuard", recommendedSpeed = 10e3, isBoss = true, emoji = "🏰", color = Color3.fromRGB(190, 160, 255) },
	{ index = 4, id = "Zone04_Area51", name = "Area 51", guardian = "Agent", recommendedSpeed = 40e3, isBoss = true, emoji = "👽", color = Color3.fromRGB(120, 255, 150) },
	{ index = 5, id = "Zone05_NorthPole", name = "North Pole", guardian = "ElfGuard", recommendedSpeed = 170e3, isBoss = true, emoji = "🎅", color = Color3.fromRGB(150, 220, 255) },
	{ index = 6, id = "Zone06_Egypt", name = "Ancient Egypt", guardian = "MummyGuardian", recommendedSpeed = 700e3, isBoss = true, emoji = "🏺", color = Color3.fromRGB(255, 200, 80) },
	{ index = 7, id = "Zone07_Gym", name = "Gym", guardian = "Bodybuilder", recommendedSpeed = 2.5e6, isBoss = true, emoji = "💪", color = Color3.fromRGB(110, 235, 110) },
	{ index = 8, id = "Zone08_Bank", name = "Bank", guardian = "BankGuard", recommendedSpeed = 18e6, isBoss = true, emoji = "🏦", color = Color3.fromRGB(255, 220, 90) },
	{ index = 9, id = "Zone09_SecretLab", name = "Secret Lab", guardian = "MadScientist", recommendedSpeed = 700e6, isBoss = true, emoji = "🧪", color = Color3.fromRGB(120, 255, 240) },
	{ index = 10, id = "Zone10_Grandma", name = "Grandma's House", guardian = "Grandma", recommendedSpeed = 2.5e9, isBoss = true, emoji = "👵", color = Color3.fromRGB(255, 190, 150) },
	{ index = 11, id = "Zone11_Construction", name = "Construction Site", guardian = "Foreman", recommendedSpeed = 7e9, isBoss = true, emoji = "🚧", color = Color3.fromRGB(255, 165, 60) },
	-- POST-GAME: no reference equivalent. See GameConfig.POSTGAME_EXTENSION.
	{ index = 12, id = "Zone12_Airport", name = "Airport", guardian = "AirportSecurity", recommendedSpeed = 20e9, isBoss = true, emoji = "✈️", color = Color3.fromRGB(150, 200, 255), postgame = true },
} :: { ZoneDef }

ZoneConfig.COUNT = #ZoneConfig.Zones
--- Zones that take part in the parity baseline: 1-11. Zone 12 is post-game.
ZoneConfig.PARITY_COUNT = 11
--- FOUR mystery containers per zone, standing around that zone's guardian
--- (MysteryConfig.SocketOffsets). Each rolls independently from all eight of
--- the zone's items. The retired fifth spawn is destroyed on sight at
--- start-up by MysterySpawnService and cannot come back.
ZoneConfig.SOCKETS_PER_ZONE = 4

--- True for a zone inside the parity baseline.
function ZoneConfig.isParityZone(zoneIndex: number): boolean
	local zone = ZoneConfig.Zones[zoneIndex]
	return zone ~= nil and not zone.postgame
end

ZoneConfig.ById = {} :: { [string]: ZoneDef }
for _, zone in ZoneConfig.Zones do
	ZoneConfig.ById[zone.id] = zone
end

--- How much of its zone's recommended Speed a guardian effectively "has".
---
--- READ THIS BEFORE CHANGING IT. It is a fraction of the SPEED STAT, not of
--- WalkSpeed, and the difference is the entire reason the recommendations used
--- to be meaningless.
---
--- This was 0.98 applied to the guardian's finished WalkSpeed. WalkSpeed is a
--- LOGARITHM of Speed, so shaving 2% off it does not shave 2% off the stat - it
--- shaves about 25%. At the North Pole that turned a guardian who was supposed
--- to represent 170K into one that moved like 127K, which is exactly the
--- "127K casually outruns Santa" bug: the player and the guardian were, to four
--- significant figures, the same speed.
---
--- Applied to the STAT and then converted, the sign is always right:
---     player well below the recommendation  -> guardian is clearly faster
---     player just below                     -> guardian closes, slowly
---     player at the recommendation          -> escapes, narrowly
---     player above                          -> pulls away
--- Studs/second a player who exactly MEETS the recommendation is faster than the
--- guardian by.
---
--- A fixed subtraction, deliberately, and it is not the bug this replaced. The
--- old code multiplied the guardian's finished WalkSpeed by 0.98 - and because
--- WalkSpeed is a logarithm of Speed, a 2% trim there quietly meant "25% less
--- STAT", which is what made a 170K guardian behave like a 127K one.
---
--- A fixed margin has neither problem. It is expressed in the unit that actually
--- decides a chase - studs of separation per second - it is the same at every
--- zone, and it does not silently mean something different at 900 Speed than at
--- 20B. At 1.5 studs/s a player who just meets the bar pulls away by roughly ten
--- to thirty studs over a full run: escapable, and close enough to be tense.
ZoneConfig.GUARDIAN_GATE_MARGIN = 1.5

--- How much faster a guardian runs against a thief who is UNDER the zone's
--- recommendation, at the point where they have none of it at all.
---
--- Fixing the stat-space bug above got the SIGN right - a 127K player is slower
--- than a 170K guardian - but not the MARGIN. WalkSpeed is logarithmic in Speed,
--- so 127K and 170K are only 1.5 studs/s apart, and over the 894 studs between
--- the North Pole and the safe line that is not enough to close a head start.
--- Measured: the 127K thief still escaped.
---
--- So the guardian also reacts to the DEFICIT. A thief at or above the
--- recommendation gets the baseline guardian and escapes narrowly; the further
--- below they are, the harder it runs them down. That is what makes the number
--- on the zone sign a real threshold rather than a decoration, and it is derived
--- from that same number rather than being a per-zone WalkSpeed hack.
---
--- TUNED AGAINST THE ACTUAL GEOMETRY, not by feel. A guardian starts 55-100
--- studs from its own sockets, and a run to the safe line is 224 studs (Pirate
--- Island) to 1,535 (the Bank). The binding case is the SHORT run with the BIG
--- gap - Pirate Island, 83 studs to make up in about seven seconds - which needs
--- roughly 11 studs/s of advantage against a thief at half the recommendation.
---
---     thief at 100%+ of the recommendation -> x1.00, escapes by the gate margin
---     thief at  85%                        -> about the crossover
---     thief at  75%                        -> x1.18, caught
---     thief at  50%                        -> x1.35, caught comfortably
ZoneConfig.GUARDIAN_DEFICIT_CATCHUP = 0.70

--- Catch distance for a zone-1-sized guardian. Later guardians are physically
--- larger and GuardianService scales this with them, so a fifteen-stud boss does
--- not have to bury its own model in the player before the catch registers.
ZoneConfig.GUARDIAN_CATCH_RADIUS = 6

return ZoneConfig
