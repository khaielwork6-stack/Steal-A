--!strict
--[[
	PngUiConfig
	Every painted (PNG) interface in the game, measured.

	The art for the Trail Shop, the main Shop, the boss-hit Speed offer and the
	Free Gift arrives as full-image PNGs generated one at a time. They are
	designed to match, but each canvas has its own transparent padding, its
	card body sits a few pixels differently, and the printed buttons are not at
	identical coordinates. This module is where those differences are ABSORBED,
	so that everything else in the game can treat "a painted card" as one thing.

	MEASURED, NOT EYEBALLED. Every number here was read from the asset's pixels
	in Studio (EditableImage): `body` is the bounding box of solid pixels
	(alpha > 200) in canvas texels, and each region is the bounding box of the
	printed button's pill, as FRACTIONS of that body. Re-measure if an asset is
	re-uploaded; do not nudge by hand.

	FAMILIES. Cards that sit in the same grid share a family aspect so the
	grid can give every cell one shape. A card whose body is a little wider or
	narrower than its family is stretched by at most STRETCH_BUDGET to meet it
	and letterboxed for the rest (see PngCard), which is what keeps ten
	separately-generated banners reading as one kit without visibly distorting
	any of them.

	THESE ARE IMAGE IDS. Nothing in here is a gamepass or developer product id;
	purchases go through MonetizationConfig exactly as before.
]]

local PngUiConfig = {}

export type Rect = { x: number, y: number, w: number, h: number }

export type Layout = {
	--- Roblox image asset id.
	image: number,
	--- Solid body of the card inside its canvas, in texels: x, y, w, h.
	body: Rect,
	--- Printed buttons, as fractions of `body`. Keys are what the code asks
	--- for: `cash` / `robux` on a trail, `buy` on a product, `claim` / `close`
	--- / `join` on the gift.
	regions: { [string]: Rect },
	--- Which family aspect this card is fitted to.
	family: string,
}

--- How far a card may be stretched (either axis) to meet its family aspect
--- before the remainder is letterboxed instead. 4% is below what the eye
--- catches on a banner; the worst case here (the Blue trail) needs 8.4%.
PngUiConfig.STRETCH_BUDGET = 0.04

--- Common aspect (width / height) per family: the median of the members'
--- measured bodies.
PngUiConfig.Families = {
	Trail = 2.97,
	Cash = 3.35,
	Speed = 2.975,
	Pass = 2.99,
	Gift = 1.3669,
} :: { [string]: number }

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x = x, y = y, w = w, h = h }
end

PngUiConfig.Cards = {
	-- ======================================================================
	-- TRAILS (1024x720 canvases). `cash` = the printed $ button, `robux` = the
	-- printed R$ button. Gray sells for cash only and has one button.
	-- ======================================================================
	Trail_Green = {
		image = 111545352261958,
		body = rect(51, 219, 922, 297),
		-- The Green card's background is itself green, so its pills were
		-- measured from a probe render rather than by colour; verified pixel-on.
		regions = { cash = rect(0.4487, 0.641, 0.2514, 0.293), robux = rect(0.7167, 0.641, 0.2539, 0.293) },
		family = "Trail",
	},
	Trail_Grey = {
		image = 127721075493076,
		body = rect(45, 187, 934, 333),
		regions = { cash = rect(0.6435, 0.6126, 0.3266, 0.2973) },
		family = "Trail",
	},
	Trail_Blue = {
		image = 104546791326408,
		body = rect(56, 183, 911, 335),
		regions = { cash = rect(0.4369, 0.6418, 0.2602, 0.2716), robux = rect(0.7881, 0.6478, 0.1789, 0.2657) },
		family = "Trail",
	},
	Trail_Purple = {
		image = 113372749804594,
		body = rect(37, 199, 952, 322),
		regions = { cash = rect(0.4580, 0.6398, 0.2532, 0.2826), robux = rect(0.7931, 0.6398, 0.1765, 0.2826) },
		family = "Trail",
	},
	Trail_Golden = {
		image = 134326224195619,
		body = rect(39, 209, 946, 300),
		regions = { cash = rect(0.4715, 0.6700, 0.2400, 0.2600), robux = rect(0.8034, 0.6667, 0.1702, 0.2633) },
		family = "Trail",
	},
	Trail_Red = {
		image = 91087636120554,
		body = rect(32, 193, 960, 337),
		regions = { cash = rect(0.4104, 0.6380, 0.2646, 0.2789), robux = rect(0.7719, 0.6380, 0.1906, 0.2789) },
		family = "Trail",
	},
	Trail_Galaxy = {
		image = 80929775598758,
		body = rect(30, 195, 970, 323),
		regions = { cash = rect(0.4515, 0.6409, 0.2515, 0.2817), robux = rect(0.7845, 0.6409, 0.1814, 0.2817) },
		family = "Trail",
	},
	Trail_Secret = {
		image = 134542331964427,
		body = rect(32, 193, 964, 324),
		regions = { cash = rect(0.4585, 0.6451, 0.2521, 0.2778), robux = rect(0.7936, 0.6451, 0.1732, 0.2778) },
		family = "Trail",
	},
	Trail_Eternal = {
		image = 94938242410097,
		body = rect(20, 193, 982, 327),
		regions = { cash = rect(0.4572, 0.6453, 0.2485, 0.2783), robux = rect(0.7841, 0.6453, 0.1853, 0.2783) },
		family = "Trail",
	},
	Trail_Divine = {
		image = 133374673004187,
		body = rect(26, 193, 972, 331),
		regions = { cash = rect(0.4516, 0.6405, 0.2531, 0.2779), robux = rect(0.7850, 0.6405, 0.1831, 0.2779) },
		family = "Trail",
	},

	-- ======================================================================
	-- SHOP: the 2x Cash gamepass and the Cash packs. One printed R$ button
	-- each (`buy`); the whole card is clickable and the button is the focus.
	-- ======================================================================
	Pass_Cash2x = {
		image = 106517680817275,
		body = rect(18, 195, 987, 330),
		regions = { buy = rect(0.7568, 0.6091, 0.2057, 0.2909) },
		family = "Pass",
	},
	Product_Cash24K = {
		image = 113046135628916,
		body = rect(10, 204, 1003, 310),
		regions = { buy = rect(0.6830, 0.5548, 0.2812, 0.4129) },
		family = "Cash",
	},
	Product_Cash200K = {
		image = 70685402260963,
		body = rect(11, 213, 1003, 292),
		regions = { buy = rect(0.6869, 0.5479, 0.2812, 0.4384) },
		family = "Cash",
	},
	Product_Cash800K = {
		image = 125480631538823,
		body = rect(12, 211, 998, 298),
		regions = { buy = rect(0.6804, 0.5638, 0.2876, 0.4228) },
		family = "Cash",
	},
	Product_Cash4M = {
		image = 130101236811066,
		body = rect(14, 213, 997, 295),
		regions = { buy = rect(0.6861, 0.5661, 0.2828, 0.4203) },
		family = "Cash",
	},
	Product_Cash8M = {
		image = 105868173825348,
		body = rect(16, 211, 993, 298),
		-- Height matched to its siblings: the pill's darker lower edge fell
		-- outside the colour pass, the button is the same size as the others.
		regions = { buy = rect(0.6818, 0.5671, 0.2860, 0.4200) },
		family = "Cash",
	},

	-- ======================================================================
	-- SPEED developer products. Used in the Shop AND as the boss-hit offer
	-- (BossOfferController picks the card by product key).
	-- ======================================================================
	Product_Speed150K = {
		image = 97186327937421,
		body = rect(15, 193, 995, 333),
		regions = { buy = rect(0.6874, 0.6006, 0.2935, 0.3243) },
		family = "Speed",
	},
	Product_Speed1M = {
		image = 101054956392080,
		body = rect(14, 190, 998, 337),
		regions = { buy = rect(0.6884, 0.6053, 0.2916, 0.3234) },
		family = "Speed",
	},
	Product_Speed10M = {
		image = 80402206892182,
		body = rect(15, 192, 994, 335),
		regions = { buy = rect(0.6911, 0.6090, 0.2887, 0.3254) },
		family = "Speed",
	},
	Product_Speed1B = {
		image = 72142904868647,
		body = rect(14, 192, 998, 335),
		regions = { buy = rect(0.6723, 0.6060, 0.3066, 0.3224) },
		family = "Speed",
	},

	-- ======================================================================
	-- FREE GIFT (1000x1000 canvas). CLAIM is the action; X closes; the printed
	-- "Join Community" button opens the group prompt on its own.
	-- ======================================================================
	Gift = {
		image = 138500620963071,
		body = rect(4, 138, 991, 725),
		regions = {
			claim = rect(0.2624, 0.8193, 0.4823, 0.1490),
			close = rect(0.9142, 0.0276, 0.0666, 0.0883),
			join = rect(0.705, 0.732, 0.25, 0.058),
		},
		family = "Gift",
	},
} :: { [string]: Layout }

--- Not wired anywhere: "10,000 Speed" (82539746649879) is a square 1024x1024
--- illustration with no printed button and there is no 10K Speed product to
--- sell. Kept on record so nobody goes looking for it.
PngUiConfig.Unused = { Speed10K = 82539746649879 }

--- The layout for a card name, or nil.
function PngUiConfig.card(name: string): Layout?
	return PngUiConfig.Cards[name]
end

--- Family aspect for a layout.
function PngUiConfig.aspectFor(layout: Layout): number
	return PngUiConfig.Families[layout.family] or (layout.body.w / layout.body.h)
end

--- Every image id in use, for preloading.
function PngUiConfig.allImages(): { number }
	local out = {}
	for _, layout in PngUiConfig.Cards do
		table.insert(out, layout.image)
	end
	return out
end

return PngUiConfig
