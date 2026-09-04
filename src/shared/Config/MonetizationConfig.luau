--!strict
--[[
	MonetizationConfig
	Developer Product IDs (GDD section 21).

	Treadmill upgrades use Developer Products, NOT Gamepasses, because each
	purchase advances one tier. Every ID defaults to 0 = disabled: with an
	unconfigured ID the server must refuse to grant anything rather than guess.

	Paste real IDs here once they exist in the Creator Dashboard.
]]

local MonetizationConfig = {}

MonetizationConfig.Products = {
	TreadmillTier2 = 0,
	TreadmillTier3 = 0,
	TreadmillTier4 = 0,
	TreadmillTier5 = 0,
	TreadmillTier6 = 0,
	TreadmillTier7 = 0,
	TreadmillTier8 = 0,
	TreadmillTier9 = 0,
} :: { [string]: number }

--- True once a real ID has been pasted in.
function MonetizationConfig.isConfigured(key: string): boolean
	local id = MonetizationConfig.Products[key]
	return id ~= nil and id > 0
end

--- Reverse lookup so ProcessReceipt can map a purchased id back to its key.
function MonetizationConfig.keyForProductId(productId: number): string?
	for key, id in MonetizationConfig.Products do
		if id == productId and id > 0 then
			return key
		end
	end
	return nil
end

return MonetizationConfig
