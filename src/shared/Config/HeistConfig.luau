--!strict
--[[
	HeistConfig
	Player-to-player base stealing: which Developer Product a rarity costs,
	how long the hold is, how long a stolen item is protected.

	THE PRODUCT IDS THEMSELVES live in MonetizationConfig.StealProducts (one
	place for every Robux id); this maps a rarity to that product's KEY. The
	server picks the product from the REAL item's rarity in the owner's
	profile - never from anything the client sends.

	Prices are not repeated here. The live PriceInRobux from Roblox is what
	the prompt shows (MonetizationService.livePrices); the `robux` on each
	product row is only the display fallback while that lookup is in flight.
]]

local HeistConfig = {}

--- Rarity -> MonetizationConfig product key.
HeistConfig.PRODUCT_KEY_BY_RARITY = {
	Common = "StealCommon",
	Uncommon = "StealUncommon",
	Rare = "StealRare",
	Epic = "StealEpic",
	Legendary = "StealLegendary",
	Mythic = "StealMythic",
	Cosmic = "StealCosmic",
	Secret = "StealSecret",
	Eternal = "StealEternal",
	Divine = "StealDivine",
} :: { [string]: string }

--- The hold on another player's trophy before the purchase prompt opens.
HeistConfig.HOLD_SECONDS = 1.0
--- How far from the display slot the prompt can be started.
HeistConfig.PROMPT_RANGE = 14
--- A successfully stolen item cannot be stolen again for this long. Saved
--- as an absolute Unix time on the item, so leaving and rejoining does not
--- reset it.
HeistConfig.PROTECTION_SECONDS = 10 * 60
--- After a successful robbery the victim's whole base is off limits briefly.
HeistConfig.ROBBERY_COOLDOWN = 60
--- An accepted prompt the player never pays for is released after this.
HeistConfig.RESERVATION_TIMEOUT = 120
--- Between two steal attempts by the same player.
HeistConfig.BEGIN_COOLDOWN = 1.5
--- Seconds the victim's base guardian hunts the thief beyond its usual
--- leash after a purchase lands, so the chase the purchase starts is real.
HeistConfig.GUARDIAN_HUNT_SECONDS = 12

return HeistConfig
