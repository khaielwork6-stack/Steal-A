--!strict
-- Intersect a laser segment with a moving axis-aligned body. Clipping the
-- (beam position, time) unit square tests the WHOLE sweep, including a fast
-- player who crosses a thin beam between samples. No rays or substeps.
local LaserGeometry = {}

function LaserGeometry.sweptBoxHit(a: Vector3, b: Vector3, from: Vector3, to: Vector3, half: Vector3): boolean
	local beam, travel, offset = b - a, to - from, a - from
	local polygon = { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(1, 1), Vector2.new(0, 1) }
	for _, axis in { "X", "Y", "Z" } do
		for _, sign in { -1, 1 } do
			local output: { Vector2 } = {}
			local function distance(p: Vector2): number
				return sign * (offset[axis] + beam[axis] * p.X - travel[axis] * p.Y) - half[axis] - 0.07
			end
			local previous = polygon[#polygon]
			local last = distance(previous)
			for _, point in polygon do
				local current = distance(point)
				if (current <= 0) ~= (last <= 0) then
					table.insert(output, previous:Lerp(point, last / (last - current)))
				end
				if current <= 0 then table.insert(output, point) end
				previous, last = point, current
			end
			if #output == 0 then return false end
			polygon = output
		end
	end
	return true
end

return LaserGeometry
