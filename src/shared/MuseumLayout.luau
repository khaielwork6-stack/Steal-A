--!strict
-- Shared geometry for construction, display sizing and guardian doorway routes.
local Map = require(script.Parent.MapConfig)
local Layout = {}
Layout.ROOMS_PER_ZONE = 2
Layout.ITEMS_PER_ROOM = 4
Layout.CORRIDOR_HALF = 22
Layout.DEPTH = Map.LANE_HALF - Layout.CORRIDOR_HALF
Layout.HEIGHT = 64
Layout.DOOR_WIDTH = 40
-- (lasers-rework) `Layout.BEAMS`, the per-zone beam COUNT, is gone: a room's
-- beams now come from shared/LaserPatterns, scaled by Config/LaserConfig.
-- `Layout.laserRoom` below is the room description that generator takes.

function Layout.doorHeight(index: number): number
	return ({ 24, 24, 26, 26, 28, 30, 32, 34, 38, 40, 44, 46 })[index]
end

function Layout.width(index: number): number
	return math.min(Map.zoneLength(index) - 8, 140)
end

function Layout.frame(index: number, room: number): CFrame
	local sign = if room == 1 then -1 else 1
	return CFrame.new(sign * Layout.CORRIDOR_HALF, 0, Map.zoneCenterZ(index)) * CFrame.Angles(0, sign * math.pi / 2, 0)
end

function Layout.roomOfSocket(socket: number): number
	return math.floor((socket - 1) / Layout.ITEMS_PER_ROOM) + 1
end

function Layout.key(zone: number, room: number): number
	-- A vault (room VAULT_ROOM, see VAULTS below) must not share a key with the
	-- next zone's first room, so vault keys come after every room key.
	if room > Layout.ROOMS_PER_ZONE then
		return Map.ZONE_COUNT * Layout.ROOMS_PER_ZONE + zone
	end
	return (zone - 1) * Layout.ROOMS_PER_ZONE + room
end

function Layout.displayFootprint(index: number): number
	-- A visual cap only, like the existing world/base caps. Roll scale and
	-- income remain unchanged; rotating sealed containers fit their cases.
	return math.min(12, (Layout.width(index) * 0.18 - 3) / math.sqrt(2))
end

function Layout.socketFrame(index: number, socket: number): CFrame
	local room = Layout.roomOfSocket(socket)
	local column = (socket - 1) % Layout.ITEMS_PER_ROOM + 1
	local x = ({ -0.36, -0.18, 0.18, 0.36 })[column] * Layout.width(index)
	return Layout.frame(index, room) * CFrame.new(x, 5.1, Layout.DEPTH - 13)
end

--- What shared/LaserPatterns needs to know about one of zone `index`'s two
--- rooms (they are mirror images, so one description serves both): its size,
--- its doorway and where its sockets are, all in the room's own frame.
function Layout.laserRoom(index: number): { width: number, depth: number, doorWidth: number, socketXs: { number }, socketZ: number }
	local frame = Layout.frame(index, 1)
	local xs: { number } = {}
	local z = Layout.DEPTH - 13
	for socket = 1, Layout.ITEMS_PER_ROOM do
		local at = frame:PointToObjectSpace(Layout.socketFrame(index, socket).Position)
		-- Rounded: the frame's rotation leaves float dust, and the layout
		-- must be the same table on every machine.
		xs[socket] = math.round(at.X * 1000) / 1000
		z = math.round(at.Z * 1000) / 1000
	end
	return { width = Layout.width(index), depth = Layout.DEPTH, doorWidth = Layout.DOOR_WIDTH, socketXs = xs, socketZ = z }
end

function Layout.locate(position: Vector3): (number?, number?)
	if math.abs(position.X) <= Layout.CORRIDOR_HALF - 3 then return nil, nil end
	for index = 1, Map.ZONE_COUNT do
		if math.abs(position.Z - Map.zoneCenterZ(index)) <= Layout.width(index) / 2 + 1 then
			return index, if position.X < 0 then 1 else 2
		end
	end
	-- Vaults sit in the unused wings, outside every room's span. Like a room,
	-- a vault also claims the 3-stud strip of corridor in front of its door
	-- (the rooms get it from the CORRIDOR_HALF - 3 test above): without it a
	-- walker leaving a vault stopped being "in the vault" while still level
	-- with the facade, skipped the line-up with the door and cut diagonally
	-- into the wall beside it (museumTests "vault route 2/3").
	local vault = Layout.inVault(position) or Layout.atVaultDoor(position)
	if vault then
		return vault, Layout.VAULT_ROOM
	end
	return nil, nil
end

--- The doorway of a room or a vault: its frame (local +Z points inside), half
--- the opening's width, and the corridor Z the opening faces.
local function doorOf(zone: number, room: number): (CFrame, number, number)
	if room == Layout.VAULT_ROOM then
		local frame = Layout.vaultFrame(zone)
		return frame, Layout.VAULT_DOOR_WIDTH / 2, frame.Position.Z
	end
	return Layout.frame(zone, room), Layout.DOOR_WIDTH / 2, Map.zoneCenterZ(zone)
end

function Layout.waypoint(from: Vector3, goal: Vector3): Vector3
	local zone, room = Layout.locate(from)
	local targetZone, targetRoom = Layout.locate(goal)
	if zone and room and (zone ~= targetZone or room ~= targetRoom) then
		-- First align with the opening while still inside the room. Only then
		-- cross its facade; a diagonal shortcut would clip the door jamb.
		-- (Rooms: 20 - 6 = 14 as before. A vault's narrow door keeps 1.5.)
		local frame, halfDoor, doorZ = doorOf(zone, room)
		local localFrom = frame:PointToObjectSpace(from)
		if math.abs(localFrom.X) > math.max(halfDoor - 6, 1.5) and localFrom.Z > 4 then
			return frame:PointToWorldSpace(Vector3.new(0, 0, math.max(10, localFrom.Z)))
		end
		return Vector3.new(0, 0, doorZ)
	end
	if targetZone and targetRoom and not zone then
		local frame, halfDoor, doorZ = doorOf(targetZone, targetRoom)
		if math.abs(from.Z - doorZ) > math.max(halfDoor - 6, 1.5) then
			return Vector3.new(0, 0, doorZ)
		end
		return frame:PointToWorldSpace(Vector3.new(0, 0, 12))
	end
	return goal
end

-- ==========================================================
-- VAULTS (vaults-crews)
-- ==========================================================
--
-- One vault per zone: a third, gated room holding a single pedestal. It lives
-- in an UNUSED WING: the space behind a FacadeExtension, between a room's side
-- wall and the zone's end, which MuseumGallery used to close with a blank
-- wall. Nothing that MuseumTests pins moves: rooms, doorways, sockets, posts
-- and lasers are untouched; the facade of a vault wing is split around the
-- vault's own front wall (see facadeSegments).
--
-- Zones 1 and 2 have only 4-stud wings (their rooms span almost the whole
-- zone), so their vaults sit in Zone 3's two NEAR wings, on the corridor just
-- past Zone 2. Every other zone's vault is in its own FAR wing, alternating
-- sides (odd zones left, even zones right).
--
-- The vault is "room 3" everywhere a room index is used: its loot lives in
-- socket VAULT_SOCKET (roomOfSocket = 3), `locate` returns (zone, 3) inside it,
-- `key(zone, 3)` is its guard's key and `waypoint` routes through its door.

Layout.VAULT_ROOM = Layout.ROOMS_PER_ZONE + 1
Layout.VAULT_SOCKET = Layout.ROOMS_PER_ZONE * Layout.ITEMS_PER_ROOM + 1
Layout.VAULT_DOOR_WIDTH = 14
Layout.VAULT_DOOR_HEIGHT = 20
Layout.VAULT_HEIGHT = 30
Layout.VAULT_MAX_LENGTH = 48

--- Which wing holds zone `zone`'s vault: (host zone, corridor side -1 left /
--- +1 right, zone end -1 near / +1 far).
function Layout.vaultHost(zone: number): (number, number, number)
	if zone == 1 then
		return 3, -1, -1
	elseif zone == 2 then
		return 3, 1, -1
	end
	return zone, if zone % 2 == 1 then -1 else 1, 1
end

--- The world Z span of zone `index`'s unused wing at its `endSign` end (the
--- same on both corridor sides).
local function wingSpan(index: number, endSign: number): (number, number)
	local center, half = Map.zoneCenterZ(index), Layout.width(index) / 2
	local spare = Map.zoneLength(index) / 2 - half
	if endSign > 0 then
		return center + half, center + half + spare
	end
	return center - half - spare, center - half
end

type VaultBox = { frame: CFrame, length: number, z0: number, z1: number, side: number }
local vaultBoxes: { [number]: VaultBox } = {}

local function vaultBox(zone: number): VaultBox
	local cached = vaultBoxes[zone]
	if cached then
		return cached
	end
	local host, side, endSign = Layout.vaultHost(zone)
	local a, b = wingSpan(host, endSign)
	local length = math.min(b - a, Layout.VAULT_MAX_LENGTH)
	-- Flush against the room's side wall (back to back, never overlapping).
	local z0, z1 = a, a + length
	if endSign < 0 then
		z0, z1 = b - length, b
	end
	local box = {
		-- Same convention as Layout.frame: origin on the corridor facade, local
		-- +Z into the vault, local X along the vault's length.
		frame = CFrame.new(side * Layout.CORRIDOR_HALF, 0, (z0 + z1) / 2) * CFrame.Angles(0, side * math.pi / 2, 0),
		length = length,
		z0 = z0,
		z1 = z1,
		side = side,
	}
	vaultBoxes[zone] = box
	return box
end

--- The vault's frame: on the corridor facade at the door, local +Z inside.
function Layout.vaultFrame(zone: number): CFrame
	return vaultBox(zone).frame
end

--- The vault's outer length along the corridor (its local X extent).
function Layout.vaultLength(zone: number): number
	return vaultBox(zone).length
end

--- World Z span and corridor side of the vault.
function Layout.vaultSpan(zone: number): (number, number, number)
	local box = vaultBox(zone)
	return box.z0, box.z1, box.side
end

--- The zone whose vault interior contains `position`, or nil.
function Layout.inVault(position: Vector3): number?
	if math.abs(position.X) <= Layout.CORRIDOR_HALF + 1 then
		return nil
	end
	for zone = 1, Map.ZONE_COUNT do
		local box = vaultBox(zone)
		if position.Z >= box.z0 and position.Z <= box.z1 and math.sign(position.X) == box.side then
			local at = box.frame:PointToObjectSpace(position)
			if at.Z > 1 and at.Z < Layout.DEPTH - 1 and math.abs(at.X) < box.length / 2 - 1 then
				return zone
			end
		end
	end
	return nil
end

--- The zone whose vault doorway strip contains `position`: the band of
--- corridor within 3 studs of the facade, across the vault's own span, plus
--- the vault interior itself. Routing only; interior tests use inVault.
function Layout.atVaultDoor(position: Vector3): number?
	if math.abs(position.X) <= Layout.CORRIDOR_HALF - 3 then
		return nil
	end
	for zone = 1, Map.ZONE_COUNT do
		local box = vaultBox(zone)
		if position.Z >= box.z0 and position.Z <= box.z1 and math.sign(position.X) == box.side then
			local at = box.frame:PointToObjectSpace(position)
			if at.Z < Layout.DEPTH - 1 and math.abs(at.X) < box.length / 2 - 1 then
				return zone
			end
		end
	end
	return nil
end

--- The facade pieces closing one wing of `index`, as { startZ, endZ } pairs.
--- A wing that holds a vault leaves the vault's span to the vault's own front
--- wall (VaultBuilder); anything left over is still closed here.
function Layout.facadeSegments(index: number, side: number, endSign: number): { { number } }
	local a, b = wingSpan(index, endSign)
	for zone = 1, Map.ZONE_COUNT do
		local host, vaultSide, vaultEnd = Layout.vaultHost(zone)
		if host == index and vaultSide == side and vaultEnd == endSign then
			local box = vaultBox(zone)
			local out = {}
			if box.z0 - a > 0.01 then
				table.insert(out, { a, box.z0 })
			end
			if b - box.z1 > 0.01 then
				table.insert(out, { box.z1, b })
			end
			return out
		end
	end
	return { { a, b } }
end

return Layout
