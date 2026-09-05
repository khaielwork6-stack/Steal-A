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

-- The key names the tier the product GRANTS, not the tier you buy it from:
-- TreadmillTier2 moves a level-1 player to level 2. Tier 1 is the starting
-- treadmill and is granted by base activation, so it has no product.
MonetizationConfig.Products = {
	TreadmillTier2 = 3711354814,
	TreadmillTier3 = 3711354847,
	TreadmillTier4 = 3711354872,
	TreadmillTier5 = 3711354886,
	TreadmillTier6 = 3711354896,
	TreadmillTier7 = 3711354919,
	TreadmillTier8 = 3711354939,
	TreadmillTier9 = 3711354965,
} :: { [string]: number }

--- Robux prices as listed in the Creator Dashboard.
---
--- These are for DISPLAY ONLY and are never trusted: the panel asks Roblox for
--- the live price via GetProductInfo and only falls back to this table if that
--- call fails. Roblox is the authority on what a product costs, so a stale entry
--- here can never make the UI quote a price the player is not actually charged -
--- it is checked against the live value and disagreements are warned about.
--- Corrected against GetProductInfo: every one of these was stale, and the
--- panel was warning about all eight on open. The products are actually priced
--- 16/24/32/40/56/72/96/120, not the 19/29/39/... that was guessed here.
MonetizationConfig.ListedPriceRobux = {
	TreadmillTier2 = 16,
	TreadmillTier3 = 24,
	TreadmillTier4 = 32,
	TreadmillTier5 = 40,
	TreadmillTier6 = 56,
	TreadmillTier7 = 72,
	TreadmillTier8 = 96,
	TreadmillTier9 = 120,
} :: { [string]: number }

--- True once a real ID has been pasted in.
function MonetizationConfig.isConfigured(key: string): boolean
	local id = MonetizationConfig.Products[key]
	return id ~= nil and id > 0
end

--- The product id for a key, or nil when unset. Returning nil rather than 0
--- means a caller cannot accidentally prompt for product "0", which Roblox
--- surfaces to the player as a broken purchase dialog.
function MonetizationConfig.productIdFor(key: string?): number?
	if not key then
		return nil
	end
	local id = MonetizationConfig.Products[key]
	return if id and id > 0 then id else nil
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
