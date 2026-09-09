--!strict
--[[
	MysteryConfig
	The closed mystery container: which model each zone uses, how big it gets,
	and where the four of them stand around their guardian.

	THE LOOP THIS SERVES
	A zone no longer shows the item it is offering. It shows a sealed container
	whose SIZE is the hidden size variant and whose VFX is the hidden mutation -
	and nothing else. The identity, rarity and income stay on the server until
	the player has stolen it, escaped, incubated it on a pedestal and hatched
	it. See MysterySpawnService (rolling and spawning) and HatchService (the
	timer and the reveal).

	WHAT A CONTAINER MAY TELL A PLAYER, AND WHAT IT MAY NOT
	  may:  its physical size, its mutation dressing, "ready" vs "incubating"
	  may not: item name, rarity, income, mutation NAME, size NAME
	There is deliberately no overhead BillboardGui on a sealed container. The
	steal is offered through the existing bottom-centre interaction UI, and the
	incubation countdown is drawn flat on the pedestal, never floating.
]]

local MysteryConfig = {}

-- ==========================================================
-- THE MODELS
-- ==========================================================
--
-- ONE container model per zone. THE NAMES BELOW ARE THE ONES ACTUALLY IN THE
-- PLACE, not the ones the brief listed: the folder holds `Zonespawn1` ...
-- `Zonespawn12` (with `ZoneSpawn1` capitalised differently from the rest), not
-- `Zone 1 Spawn`. Both spellings are accepted - `MysteryModel.templateFor`
-- tries every alias in order - so renaming them in Studio later breaks
-- nothing. A zone whose model is missing is reported BY NAME at start-up and
-- that zone spawns nothing; no other zone's model is ever substituted in.

export type ZoneModel = {
	--- Every accepted name, best first.
	aliases: { string },
}

local function names(zoneIndex: number): { string }
	return {
		`Zonespawn{zoneIndex}`, -- what the place actually has
		`ZoneSpawn{zoneIndex}`, -- the odd one out (zone 1)
		`Zone {zoneIndex} Spawn`, -- the brief's spelling
		`ZoneSpawn{zoneIndex} `,
	}
end

MysteryConfig.ZoneModels = {} :: { [number]: ZoneModel }
for zoneIndex = 1, 12 do
	MysteryConfig.ZoneModels[zoneIndex] = { aliases = names(zoneIndex) }
end

--- Folders searched for the container models, in order. The models shipped
--- loose in Workspace; MysteryModel moves the folder into ServerStorage at
--- start-up so they are not standing in the world, and finds them either way.
MysteryConfig.MODEL_FOLDER_NAME = "ZoneModels"
MysteryConfig.MODEL_SEARCH = {
	{ service = "ServerStorage", path = { "GameAssets", "ZoneModels" } },
	{ service = "ServerStorage", path = { "ZoneModels" } },
	{ service = "ReplicatedStorage", path = { "GameAssets", "ZoneModels" } },
	{ service = "ReplicatedStorage", path = { "ZoneModels" } },
	{ service = "Workspace", path = { "ZoneModels" } },
}

-- ==========================================================
-- CONTAINER SIZE
-- ==========================================================
--
-- The container's PHYSICAL size is the hidden size variant, so a Titan or a
-- Colossal is unmistakable across the zone. The economy Scale itself lives in
-- ScaleConfig and is NOT duplicated here - this is presentation only.

--- The height a Scale-1 container is built to, in studs. Chosen against the
--- socket, the pedestal and the carry: readable from the lane, liftable
--- without filling the camera.
MysteryConfig.CONTAINER_HEIGHT = 5.5

--- A container never gets wider than this many times its height, so a wide
--- authored mesh cannot become a wall at Colossal.
MysteryConfig.MAX_WIDTH_RATIO = 1.6

--- The widest a container may be in the WORLD (socket) and on a PEDESTAL.
--- Only ever shrinks; a Colossal is meant to tower, not to swallow the lane.
MysteryConfig.WORLD_MAX_FOOTPRINT = 48
MysteryConfig.PEDESTAL_MAX_FOOTPRINT = 30

--- The invisible interaction hitbox kept around every container, whatever its
--- visual size, so a Colossal is no harder to reach than a Normal and a
--- Normal is never fiddly on a phone.
MysteryConfig.HITBOX_SIZE = Vector3.new(6, 6, 6)
--- Interaction range grows with the footprint so a player standing at the edge
--- of an enormous container can still start the steal.
MysteryConfig.INTERACT_RANGE_MIN = 16
MysteryConfig.INTERACT_RANGE_PER_STUD = 0.5

--- Above this display scale a carried container is hoisted overhead instead of
--- held in front. Mirrors the loot rule so the camera stays usable.
MysteryConfig.CARRY_OVERHEAD_SCALE = 2.6

-- ==========================================================
-- WHERE THE FOUR STAND
-- ==========================================================
--
-- FOUR containers per zone, in a shallow protective arc around the guardian:
-- two in front of it and two behind, so the guardian reads as the thing
-- guarding them and the lane down the middle stays open to run.
--
-- Offsets are in the zone's own frame, in studs: +X is across the lane, +Z is
-- deeper into the zone (away from the safe line). The guardian rests at the
-- origin of this frame. MysterySpawnService raycasts each one to the floor and
-- nudges it clear of scenery before it settles.

MysteryConfig.SOCKETS_PER_ZONE = 4

MysteryConfig.SocketOffsets = {
	{ name = "Spawn01", x = -26, z = -14 }, -- front-left  (nearer the entrance)
	{ name = "Spawn02", x = 26, z = -14 }, -- front-right
	{ name = "Spawn03", x = -32, z = 18 }, -- rear-left
	{ name = "Spawn04", x = 32, z = 18 }, -- rear-right
}

--- Clear space demanded around a socket when it is settled against scenery.
MysteryConfig.SOCKET_CLEARANCE = 16
--- Two containers are never allowed closer than this centre to centre, so two
--- Colossals side by side cannot intersect.
MysteryConfig.SOCKET_MIN_SEPARATION = 26
--- How far a blocked socket may slide before it gives up and takes its spot.
MysteryConfig.SOCKET_MAX_SHIFT = 30

-- ==========================================================
-- PRESENTATION
-- ==========================================================

--- The sealed look: a slow hover turn and a gentle bob, so a container reads
--- as alive without ever suggesting what is inside.
MysteryConfig.IDLE_TURN_RATE = 0.35 -- radians/second at Scale 1
MysteryConfig.IDLE_BOB_AMPLITUDE = 0.35
MysteryConfig.IDLE_BOB_PERIOD = 3.2

--- The neutral "something is in here" sparkle every sealed container wears.
--- Deliberately rarity-NEUTRAL: it is the same on a Common and on a Divine.
MysteryConfig.MYSTERY_PARTICLE = "rbxassetid://241594419"
MysteryConfig.MYSTERY_TINT = Color3.fromRGB(226, 236, 255)

--- The question mark on a sealed container's face, and the colour of the
--- "ready to hatch" pulse.
MysteryConfig.READY_TINT = Color3.fromRGB(120, 255, 170)
MysteryConfig.INCUBATING_TINT = Color3.fromRGB(150, 170, 210)

--- Rate limit: how often one player may ask to hatch, per second.
MysteryConfig.HATCH_REQUESTS_PER_SECOND = 2

return MysteryConfig
