--!strict
--[[
	MapPalette
	Every colour in the world lives here.

	Bright, playful, low-poly - and BALANCED. The first pass of this world was
	pushed to neon (lime grass, hot cyan, glowing pads) and read as harsh on a
	real screen, so the greens sit a step back toward grass, the walls toward
	clay, and the checker pairs stay close so the pattern is texture, never a
	chessboard. Neon is kept for what must draw the eye: the red line, rarity
	rings, portals - not floors, not signs, not scenery.

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
MapPalette.WallFace = surface(212, 152, 120, 202, 142, 110, false, 27)
MapPalette.WallCap = rgb(118, 198, 96)
--- Pilasters and the trim band: the wall's own clay, one shade deeper.
MapPalette.WallPilaster = rgb(176, 118, 90)
MapPalette.WallTrim = rgb(190, 130, 100)

-- ==========================================================
-- BASE AREA
-- ==========================================================
MapPalette.Plaza = surface(132, 208, 92, 122, 196, 84, true, 48)
MapPalette.SafeApron = surface(132, 208, 92, 122, 196, 84, true, 48)
-- Plots are one step lighter than the plaza so ownership reads without a
-- colour clash; the fence does the separating.
MapPalette.PlotFloor = surface(150, 216, 106, 140, 206, 98, true, 44)
--- Paved surfaces: the hub plaza, the avenue, base porches and paths.
MapPalette.Paving = surface(204, 196, 176, 194, 186, 166, false, 12)
MapPalette.PavingEdge = rgb(150, 140, 118)
MapPalette.PlotBorder = rgb(58, 64, 86)
MapPalette.FenceRail = rgb(246, 246, 240)
MapPalette.SafeLine = rgb(255, 60, 72)
MapPalette.Treadmill = rgb(58, 132, 244)
MapPalette.TreadmillBelt = rgb(38, 42, 58)
--- The upgrade pad is a dark plinth the sign stands on, not a glowing tile.
MapPalette.PadUpgrade = rgb(44, 52, 80)
--- Planters and greenery around the plots and the hub.
MapPalette.Planter = rgb(112, 92, 72)
MapPalette.Bush = rgb(88, 176, 92)
MapPalette.BushLight = rgb(118, 200, 104)
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
-- Each zone keeps its own hue; saturation is pulled back a step so items,
-- guardians and the landmarks stand out against the ground instead of
-- fighting it.
MapPalette.Zones = {
	surface(136, 210, 86, 126, 198, 78, true), -- 01 Museum        manicured lawn
	surface(244, 224, 160, 234, 212, 146, true), -- 02 Pirate        tropical sand
	surface(110, 200, 98, 100, 188, 88, true), -- 03 Castle        deeper grass
	surface(126, 200, 174, 116, 188, 162, true), -- 04 Area 51       desert scrub
	surface(240, 246, 252, 224, 234, 246, true), -- 05 North Pole    snow
	surface(244, 216, 140, 234, 204, 124, true), -- 06 Egypt         warm sand
	surface(98, 180, 222, 88, 166, 208, false), -- 07 Gym           sport floor
	surface(200, 206, 218, 186, 193, 206, false), -- 08 Bank          polished stone
	surface(150, 126, 226, 136, 112, 210, false), -- 09 Secret Lab    lab composite
	surface(232, 166, 194, 220, 152, 182, true), -- 10 Grandma       domestic
	surface(206, 168, 118, 192, 154, 104, true), -- 11 Construction  dirt / gravel
	surface(146, 154, 170, 132, 141, 156, false), -- 12 Airport       runway pavement
}

--- Transition strip between zone `i` and `i + 1`: the midpoint of both bases.
function MapPalette.transition(i: number): Color3
	local from = MapPalette.Zones[i].a
	local to = MapPalette.Zones[math.min(i + 1, #MapPalette.Zones)].a
	return from:Lerp(to, 0.5)
end

return MapPalette
