--!strict
--[[
	Validate
	Shape checks for values that arrive over a remote.

	`type(x) == "number"` is not enough. NaN is a number, and so is infinity,
	and both slip straight through every `<` / `>` bounds check because every
	comparison against NaN is false. A NaN slot index used to pass
	PlacementService's range test, get written into the profile as
	`SlotIndex = nan`, and from then on every save of that profile failed:
	DataStores cannot serialise NaN. One bad packet, permanent data loss.

	These helpers return a clean value or nil. Callers treat nil as "ignore the
	request" - never as an error, because a malformed packet is either an
	exploit probe or a bug, and neither deserves a reply.
]]

local Validate = {}

--- True for a real, finite number. False for NaN, +/-inf and non-numbers.
function Validate.finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- A finite whole number within [min, max], or nil. Fractions are floored so a
--- client that sends 3.0 or 3.2 for slot 3 still works.
function Validate.integer(value: any, min: number?, max: number?): number?
	if not Validate.finite(value) then
		return nil
	end
	local whole = math.floor(value)
	if min and whole < min then
		return nil
	end
	if max and whole > max then
		return nil
	end
	return whole
end

--- A Vector3 whose every component is finite, or nil. A NaN component poisons
--- every Magnitude / Unit / Raycast it touches downstream.
function Validate.vector3(value: any): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	local v = value :: Vector3
	if Validate.finite(v.X) and Validate.finite(v.Y) and Validate.finite(v.Z) then
		return v
	end
	return nil
end

return Validate
