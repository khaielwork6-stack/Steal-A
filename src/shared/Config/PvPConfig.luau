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
PvPConfig.BAT_COOLDOWN = 0.9
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

return PvPConfig
