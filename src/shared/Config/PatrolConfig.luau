--!strict
--[[
	PatrolConfig
	Moving guard patrols in the later zones (docs/handoff-parts/gadgets-patrols.md).

	In zones >= MIN_ZONE a room guard does not sleep at its corridor post: it
	walks a slow loop inside its own room ("Patrolling"). A patrolling guard
	does NOT chase on sight. The two rules of HANDOFF §48 still apply
	unchanged (leaving the room with its loot -> alert + doorway grace;
	touching a laser -> wake). The one addition is the VISION CONE: a
	patrolling guard that can see a player carrying ITS room's loot, within
	VISION_RANGE and VISION_ANGLE, raises exactly the doorway alert.

	The loop is derived from MuseumLayout's room geometry in GuardianService
	(patrolRoute): a rectangle between ROUTE_NEAR_Z and ROUTE_FAR_Z (studs into
	the room), clear of the side walls/ropes (ROUTE_WALL_MARGIN), of the side
	exhibit on the room's +X wall (ROUTE_EXHIBIT_MARGIN), of the display cases
	at the rear (they start around depth - 18) and of the doorway line (z 0).
]]

local PatrolConfig = {}

--- Master switch. False: every guard sleeps at its post, as before.
PatrolConfig.ENABLED = true
--- The first zone whose guards patrol.
PatrolConfig.MIN_ZONE = 7
--- Walk speed while patrolling, studs/s. Deliberately slow: a patrol is
--- something to time, not something to outrun.
PatrolConfig.SPEED = 12
--- How close counts as "at" a waypoint.
PatrolConfig.WAYPOINT_REACH = 3
--- The guard stands and looks around this long at each corner.
PatrolConfig.CORNER_PAUSE = 1.2

--- The loop, in the room's local frame (see header).
PatrolConfig.ROUTE_NEAR_Z = 14
PatrolConfig.ROUTE_FAR_Z = 32
PatrolConfig.ROUTE_WALL_MARGIN = 14
PatrolConfig.ROUTE_EXHIBIT_MARGIN = 20

--- The vision cone. ANGLE is the FULL width of the cone (35 degrees either
--- side of where the guard faces). Checked at VISION_HZ, and only for a
--- patrolling guard whose room holds a carrier of its own loot.
PatrolConfig.VISION_ENABLED = true
PatrolConfig.VISION_RANGE = 25
PatrolConfig.VISION_ANGLE = 70
PatrolConfig.VISION_HZ = 5

return PatrolConfig
