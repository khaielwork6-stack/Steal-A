local V3 = {}
V3.__index = function(t, k)
	if k == "Magnitude" then
		return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
	elseif k == "Unit" then
		local m = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
		return setmetatable({ X = t.X / m, Y = t.Y / m, Z = t.Z / m }, V3)
	end
	return V3[k]
end
local function v3(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3) end
function V3.Lerp(a, b, t) return v3(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t) end
V3.__add = function(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__unm = function(a) return v3(-a.X, -a.Y, -a.Z) end
V3.__mul = function(a, b)
	if type(a) == "number" then return v3(a * b.X, a * b.Y, a * b.Z) end
	if type(b) == "number" then return v3(a.X * b, a.Y * b, a.Z * b) end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then return v3(a.X / b, a.Y / b, a.Z / b) end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
local V2 = {}
V2.__index = V2
function V2.Lerp(a, b, t) return setmetatable({ X = a.X + (b.X - a.X) * t, Y = a.Y + (b.Y - a.Y) * t }, V2) end
return {
	Vector3 = { new = v3, zero = v3(0, 0, 0), one = v3(1, 1, 1) },
	Vector2 = { new = function(x, y) return setmetatable({ X = x, Y = y }, V2) end },
}
