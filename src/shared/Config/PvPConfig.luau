--!strict
--[[
	PvPConfig
	Bat and trap tuning (GDD section 12).

	PvP exists to create contested steals, not to deal damage. The entire result
	is positional disruption plus forcing a carried item to drop. Bases and
	treadmills are safe zones so nobody can be spawn-griefed.
]]

local PvPConfig = {}

-- Bat: a permanent Tool every player owns. No health damage, ever.
PvPConfig.BAT_RANGE = 6
-- Exactly half a second between VALID swings. The client mirrors this for feel;
-- this is the number that decides, and a client that swings faster is refused.
PvPConfig.BAT_COOLDOWN = 0.50
--- Seconds after the swing starts before the bat is "through" the target. The
--- server resolves the hit here, and the client's swing is Roblox's own
--- toolslash animation, whose forward pass crosses the body at about this
--- point - so the connect lands on the frame the bat visually arrives rather
--- than at the moment the button is pressed.
PvPConfig.BAT_STRIKE_DELAY = 0.2
PvPConfig.BAT_ARC_DEGREES = 100
PvPConfig.RAGDOLL_DURATION = 1.25
PvPConfig.KNOCKBACK_SPEED = 46
PvPConfig.KNOCKBACK_LIFT = 14
PvPConfig.POST_RAGDOLL_IMMUNITY = 1.5 -- stops permanent stun chains

-- Traps: consumable, saved, and never duplicated by resetting.
PvPConfig.TRAP_LIFETIME = 30
PvPConfig.TRAP_ROOT_DURATION = 5
PvPConfig.TRAP_TRIGGER_RADIUS = 5
PvPConfig.TRAP_PLACE_RADIUS = 12 -- max distance in front of the player
PvPConfig.TRAP_OWNER_IMMUNITY = 1.25 -- so you cannot step on your own trap
PvPConfig.TRAP_VICTIM_IMMUNITY = 3 -- granted after a root releases
PvPConfig.TRAP_MAX_ACTIVE_PER_PLAYER = 3
PvPConfig.TRAP_MAX_SLOPE = 30 -- degrees; refuse steep or invalid geometry

--- The bat does not affect zone guardians in MVP - traps are the guardian
--- control tool. Kept as a flag so the rule is explicit rather than implied.
PvPConfig.BAT_AFFECTS_GUARDIANS = false

-- ==========================================================
-- WEAPONS
-- ==========================================================
--
-- ONE swing framework, two weapons. The server decides which numbers apply
-- from the Tool actually in the attacker's hand (never from the request),
-- and every row goes through the same validation, cooldown, arc, safe-zone
-- and ragdoll path as the Bat always has. The Slap is the Bat's rules with
-- its own reach, timing, sound and a bigger, sillier launch.

export type WeaponDef = {
	name: string,
	range: number,
	cooldown: number,
	--- Seconds after the press before the hit is resolved: matched to the
	--- moment the client's swing visually arrives.
	strikeDelay: number,
	arcDegrees: number,
	knockback: number,
	lift: number,
	stun: number,
	--- AudioConfig cue played at the victim on a connect.
	hitCue: string,
	--- Whether owning it is a Game Pass (the Bat is free for everyone).
	gamePass: boolean,
}

PvPConfig.Weapons = {
	Bat = {
		name = "Bat",
		range = PvPConfig.BAT_RANGE,
		cooldown = PvPConfig.BAT_COOLDOWN,
		strikeDelay = PvPConfig.BAT_STRIKE_DELAY,
		arcDegrees = PvPConfig.BAT_ARC_DEGREES,
		knockback = PvPConfig.KNOCKBACK_SPEED,
		lift = PvPConfig.KNOCKBACK_LIFT,
		stun = PvPConfig.RAGDOLL_DURATION,
		hitCue = "BatHit",
		gamePass = false,
	},
	Slap = {
		name = "Slap",
		range = 7,
		cooldown = 0.7,
		strikeDelay = 0.22,
		arcDegrees = 110,
		-- Harder and higher than the bat: the joke is the distance.
		knockback = 70,
		lift = 30,
		stun = 1.5,
		hitCue = "SlapHit",
		gamePass = true,
	},
} :: { [string]: WeaponDef }

--- Order the Weapons page lists them in.
PvPConfig.WeaponOrder = { "Bat", "Slap" }
--- What a fresh profile holds.
PvPConfig.DEFAULT_WEAPON = "Bat"
--- How the held Slap is sized: the import's hand is 7 studs tall, which in a
--- fist reads as a wall. Scaled once when the Tool is built.
PvPConfig.SLAP_TOOL_SCALE = 0.42

return PvPConfig
