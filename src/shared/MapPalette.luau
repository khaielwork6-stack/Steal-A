--!strict
--[[
	MapPalette
	Every colour in the world lives here.

	Bright, playful, low-poly - and BALANCED. Two passes got this wrong in
	opposite directions and this is the settled answer.

	  * Pass 1 was neon: lime grass, hot cyan, glowing pads. Harsh on a screen.
	  * Pass 2 over-corrected into pastel: the greens lost their saturation and
	    the checker pairs sat 10 RGB apart, so the ground read as flat mint.

	The rule now: RICH, SATURATED hues with a readable checker (about 20 RGB
	between the pair, the reference's own contrast) and a tile SIZE that reads
	from a standing player - roughly 18 studs in the lobby, 22 in the zones,
	not the 44-48 that showed one square per screen. Exposure and bloom are
	what stop it hurting the eye (EnvironmentService), never desaturation.
	Neon is kept for what must draw the eye: the red line, rarity rings,
	portals - not floors, not signs, not scenery.

	Each surface is a pair (a, b). `a` is the base slab, `b` is the alternating
	checker tile laid over it.
]]

local MapPalette = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

export type Surface = {
	a: Color3,
	b: Color3,
	studded: boolean, -- raised Roblox studs on the top face
	tile: number, -- checker square size in studs
}

local function surface(ar: number, ag: number, ab: number, br: number, bg: number, bb: number, studded: boolean, tile: number?): Surface
	return { a = rgb(ar, ag, ab), b = rgb(br, bg, bb), studded = studded, tile = tile or 40 }
end

-- ==========================================================
-- WALLS
-- ==========================================================
MapPalette.WallFace = surface(198, 138, 96, 184, 126, 84, false, 24)
MapPalette.WallCap = rgb(96, 188, 70)
--- Pilasters and the trim band: the wall's own clay, one shade deeper.
MapPalette.WallPilaster = rgb(172, 114, 78)
MapPalette.WallTrim = rgb(186, 128, 90)

-- ==========================================================
-- BASE AREA
-- ==========================================================
MapPalette.Plaza = surface(126, 208, 82, 106, 190, 68, true, 18)
MapPalette.SafeApron = surface(126, 208, 82, 106, 190, 68, true, 18)
-- Plots are one step lighter than the plaza so ownership reads without a
-- colour clash; the fence does the separating.
MapPalette.PlotFloor = surface(140, 216, 92, 120, 198, 78, true, 18)
--- Paved surfaces: the hub plaza, the avenue, base porches and paths.
-- Warm stone, deliberately a step off white: at brightness 2.6 a near-white
-- avenue was the brightest thing on screen and read as an airport runway.
MapPalette.Paving = surface(192, 183, 162, 182, 173, 152, false, 12)
MapPalette.PavingEdge = rgb(146, 136, 114)
MapPalette.PlotBorder = rgb(58, 64, 86)
MapPalette.FenceRail = rgb(246, 246, 240)
MapPalette.SafeLine = rgb(255, 60, 72)
MapPalette.Treadmill = rgb(58, 132, 244)
MapPalette.TreadmillBelt = rgb(38, 42, 58)
--- The upgrade pad is a dark plinth the sign stands on, not a glowing tile.
MapPalette.PadUpgrade = rgb(44, 52, 80)
--- Planters and greenery around the plots and the hub.
MapPalette.Planter = rgb(112, 92, 72)
MapPalette.Bush = rgb(72, 172, 76)
MapPalette.BushLight = rgb(104, 196, 92)
MapPalette.Rock = rgb(150, 150, 156)
MapPalette.LampPost = rgb(52, 56, 74)
MapPalette.LampGlow = rgb(255, 230, 160)

-- Display slots: a dark slate pad with a thin neon frame set into it (see
-- BaseService.styleSlot): cyan and breathing while it waits for an item, dim
-- grey while locked, the item's rarity colour once a pedestal stands on it.
-- Restrained on purpose - the collectible is the exhibit, not the floor.
MapPalette.DisplaySlot = rgb(46, 54, 78)
MapPalette.DisplaySlotRim = rgb(96, 214, 255)
MapPalette.DisplaySlotLocked = rgb(38, 42, 54)
MapPalette.DisplaySlotLockedRim = rgb(70, 78, 96)
MapPalette.SlotPadEmpty = rgb(30, 34, 46)
MapPalette.SlotPadLocked = rgb(26, 28, 36)
MapPalette.SlotPadOccupied = rgb(22, 26, 38)
MapPalette.SlotNeonEmpty = rgb(96, 214, 255)
MapPalette.SlotNeonLocked = rgb(70, 78, 96)

-- ==========================================================
-- UPGRADE SIGN
-- ==========================================================
-- Chunky simulator signage: a dark navy body so it is never blinding, a bold
-- white title, green progression text and a bright red purchase panel.
MapPalette.SignBody = rgb(28, 38, 72)
MapPalette.SignEdge = rgb(16, 22, 44)
MapPalette.SignPost = rgb(58, 64, 86)
MapPalette.SignTitle = rgb(255, 255, 255)
MapPalette.SignProgress = rgb(96, 240, 118)
MapPalette.SignButton = rgb(232, 58, 62)
MapPalette.SignButtonEdge = rgb(150, 26, 32)
MapPalette.SignButtonText = rgb(255, 255, 255)
MapPalette.SignMaxed = rgb(255, 206, 84)
--- A loot socket is a dark stone plinth; the client draws the rarity ring
--- on it. Nothing here glows.
MapPalette.LootSocket = rgb(64, 68, 88)
MapPalette.LootSocketRim = rgb(96, 100, 122)
--- Zone gates: dark navy pylons; the band and lintel face take the zone's
--- own colour (ZoneConfig).
MapPalette.GatePylon = rgb(40, 46, 70)
MapPalette.GateLintel = rgb(30, 36, 60)

-- ==========================================================
-- ZONES  (index matches MapConfig.ZONES)
-- ==========================================================
-- Each zone keeps its own hue, at full playful saturation. The ground is
-- allowed to be colourful: what keeps items and guardians readable on top of
-- it is the checker's own contrast and the dark plinths under the loot, not a
-- washed-out floor. Tile 22: reads as a pattern from standing height.
MapPalette.Zones = {
	surface(128, 208, 76, 110, 190, 62, true, 22), -- 01 Museum        manicured lawn
	surface(246, 222, 148, 232, 206, 128, true, 22), -- 02 Pirate        tropical sand
	surface(100, 194, 84, 86, 176, 70, true, 22), -- 03 Castle        deeper grass
	surface(118, 198, 168, 102, 182, 152, true, 22), -- 04 Area 51       desert scrub
	surface(238, 246, 254, 218, 232, 248, true, 22), -- 05 North Pole    snow
	surface(246, 212, 128, 232, 196, 108, true, 22), -- 06 Egypt         warm sand
	surface(86, 176, 226, 70, 158, 210, false, 22), -- 07 Gym           sport floor
	surface(202, 208, 222, 184, 191, 206, false, 22), -- 08 Bank          polished stone
	surface(146, 118, 232, 128, 100, 214, false, 22), -- 09 Secret Lab    lab composite
	surface(238, 160, 194, 224, 142, 178, true, 22), -- 10 Grandma       domestic
	surface(208, 164, 106, 192, 148, 90, true, 22), -- 11 Construction  dirt / gravel
	surface(140, 150, 170, 124, 134, 154, false, 22), -- 12 Airport       runway pavement
}

--- Transition strip between zone `i` and `i + 1`: the midpoint of both bases.
function MapPalette.transition(i: number): Color3
	local from = MapPalette.Zones[i].a
	local to = MapPalette.Zones[math.min(i + 1, #MapPalette.Zones)].a
	return from:Lerp(to, 0.5)
end

return MapPalette
