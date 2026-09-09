--!strict
--[[
	NumberFormat
	Display formatting for Cash and SpeedPower.

	Formatted strings are for humans only. NEVER store one as the currency value
	or parse one back into a number (GDD section 17).
]]

local NumberFormat = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

--- Three significant figures: 13.5K, 135K, 1.35M, with trailing zeros trimmed
--- so "5K" is shown rather than "5.00K" - but ONLY when there is a decimal
--- point. Trimming unconditionally turned 250K into 25K and 100M into 1M,
--- because it ate the zeros of a whole number.
local function threeFigures(scaled: number): string
	local text: string
	if scaled < 10 then
		text = string.format("%.2f", scaled)
	elseif scaled < 100 then
		text = string.format("%.1f", scaled)
	else
		text = string.format("%.0f", scaled)
	end
	if text:find("%.") then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end
	return text
end

--- 967 -> "967", 13540 -> "13.5K", 2.5e9 -> "2.5B", 1e12 -> "1T".
function NumberFormat.short(value: number): string
	if value ~= value then -- NaN guard
		return "0"
	end

	local negative = value < 0
	local n = math.abs(value)

	if n < 1000 then
		local rounded = math.floor(n + 0.5)
		return (if negative then "-" else "") .. tostring(rounded)
	end

	-- The tier is found by DIVIDING, never by math.log(n, 1000): the logarithm
	-- of one trillion in base 1000 comes back as 3.9999999999999996, which
	-- floored to tier 3 and printed 1T as "1000B". Repeated division by an
	-- exact power of ten has no such rounding, so every boundary lands where
	-- it should: 999B, then 1T; 999T, then 1Qa.
	local top = #SUFFIXES - 1
	local tier = 0
	local scaled = n
	while scaled >= 1000 and tier < top do
		scaled /= 1000
		tier += 1
	end

	local text = threeFigures(scaled)
	-- Rounding to three figures can carry the number over the edge on its own:
	-- 999.6B formats as "1000". That is the next suffix, not four digits of
	-- this one.
	if (tonumber(text) or 0) >= 1000 and tier < top then
		scaled /= 1000
		tier += 1
		text = threeFigures(scaled)
	end

	return (if negative then "-" else "") .. text .. SUFFIXES[tier + 1]
end

--- "$13.54K/s" for income labels.
function NumberFormat.income(value: number): string
	return "$" .. NumberFormat.short(value) .. "/s"
end

--- "$13.54K" for prices and balances.
function NumberFormat.cash(value: number): string
	return "$" .. NumberFormat.short(value)
end

--- 1234567 -> "1,234,567". Used where exact figures matter, e.g. tooltips.
function NumberFormat.comma(value: number): string
	local text = tostring(math.floor(math.abs(value) + 0.5))
	local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return (if value < 0 then "-" else "") .. out
end

return NumberFormat
