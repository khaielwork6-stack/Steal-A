--!strict
--[[
	MapPalette
	Every colour in the world lives here.

	The reference presentation is deliberately over-saturated: neon lime grass,
	warm terracotta walls, a hard cyan sky. Do NOT tone these down because they
	look loud in the Studio viewport - the exaggeration is the point.

	Each surface is a pair (a, b). `a` is the base slab, `b` is the alternating
	checker tile laid over it. Keep the two shades CLOSE: the checker should read
	as texture from a distance, never as a chessboard.
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
MapPalette.WallFace = surface(216, 132, 100, 205, 121, 90, false, 27)
MapPalette.WallCap = rgb(96, 226, 62)

-- ==========================================================
-- BASE AREA
-- ==========================================================
MapPalette.Plaza = surface(158, 240, 74, 145, 228, 62, true, 55)
MapPalette.SafeApron = surface(158, 240, 74, 145, 228, 62, true, 55)
-- Plots stay grass, one step lighter than the plaza, so ownership reads without
-- turning the base area into a colour clash. The fence does the separating.
MapPalette.PlotFloor = surface(180, 246, 104, 168, 236, 92, true, 55)
MapPalette.PlotBorder = rgb(150, 100, 58)
MapPalette.SafeLine = rgb(255, 60, 72)
MapPalette.Treadmill = rgb(58, 132, 244)
MapPalette.TreadmillBelt = rgb(38, 42, 58)
MapPalette.PadActivate = rgb(64, 226, 122)
MapPalette.PadUpgrade = rgb(255, 176, 46)
MapPalette.DisplaySlot = rgb(248, 246, 232)
MapPalette.LootSocket = rgb(255, 226, 110)

-- ==========================================================
-- ZONES  (index matches MapConfig.ZONES)
-- ==========================================================
MapPalette.Zones = {
	surface(146, 238, 68, 132, 226, 56, true), -- 01 Museum        manicured lawn
	surface(250, 228, 154, 240, 216, 138, true), -- 02 Pirate        tropical sand
	surface(112, 220, 92, 99, 208, 80, true), -- 03 Castle        deeper grass
	surface(128, 214, 180, 115, 202, 167, true), -- 04 Area 51       desert scrub
	surface(246, 250, 255, 226, 237, 250, true), -- 05 North Pole    snow
	surface(252, 220, 132, 242, 206, 112, true), -- 06 Egypt         warm sand
	surface(88, 194, 240, 74, 178, 226, false), -- 07 Gym           sport floor
	surface(206, 212, 224, 190, 197, 212, false), -- 08 Bank          polished stone
	surface(158, 122, 244, 140, 106, 228, false), -- 09 Secret Lab    lab composite
	surface(240, 158, 192, 226, 143, 179, true), -- 10 Grandma       domestic
	surface(214, 168, 108, 198, 152, 94, true), -- 11 Construction  dirt / gravel
	surface(146, 156, 172, 130, 141, 158, false), -- 12 Airport       runway pavement
}

--- Transition strip between zone `i` and `i + 1`: the midpoint of both bases.
function MapPalette.transition(i: number): Color3
	local from = MapPalette.Zones[i].a
	local to = MapPalette.Zones[math.min(i + 1, #MapPalette.Zones)].a
	return from:Lerp(to, 0.5)
end

return MapPalette
