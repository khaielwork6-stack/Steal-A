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
Layout.BEAMS = { 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14 }

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

function Layout.locate(position: Vector3): (number?, number?)
	if math.abs(position.X) <= Layout.CORRIDOR_HALF - 3 then return nil, nil end
	for index = 1, Map.ZONE_COUNT do
		if math.abs(position.Z - Map.zoneCenterZ(index)) <= Layout.width(index) / 2 + 1 then
			return index, if position.X < 0 then 1 else 2
		end
	end
	return nil, nil
end

function Layout.waypoint(from: Vector3, goal: Vector3): Vector3
	local zone, room = Layout.locate(from)
	local targetZone, targetRoom = Layout.locate(goal)
	if zone and room and (zone ~= targetZone or room ~= targetRoom) then
		-- First align with the opening while still inside the room. Only then
		-- cross its facade; a diagonal shortcut would clip the door jamb.
		local frame = Layout.frame(zone, room)
		local localFrom = frame:PointToObjectSpace(from)
		if math.abs(localFrom.X) > Layout.DOOR_WIDTH / 2 - 6 and localFrom.Z > 4 then
			return frame:PointToWorldSpace(Vector3.new(0, 0, math.max(10, localFrom.Z)))
		end
		return Vector3.new(0, 0, Map.zoneCenterZ(zone))
	end
	if targetZone and targetRoom and not zone then
		local center = Map.zoneCenterZ(targetZone)
		if math.abs(from.Z - center) > Layout.DOOR_WIDTH / 2 - 6 then
			return Vector3.new(0, 0, center)
		end
		return Layout.frame(targetZone, targetRoom):PointToWorldSpace(Vector3.new(0, 0, 12))
	end
	return goal
end

return Layout
