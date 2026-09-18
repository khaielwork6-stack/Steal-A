--!strict
--[[
	BaseThemeConfig
	Cosmetic base customisation: plot THEMES and display PEDESTAL SKINS.

	PURELY COSMETIC. Nothing here touches income, capacity, speed or safety.
	BaseThemeService applies a theme by recolouring / re-materialing the parts
	MapBuilder.buildBase names (PlotFloor.Slab, Paving.*, Fence.Post / Rail /
	GatePost / GateCap) and the neon frame of EMPTY display pads; a pedestal
	skin recolours the `Pedestal` model BaseService clones onto each occupied
	pad (its rarity `Accent` disc is left alone - it carries information).
	Visitors see the owner's theme because the server makes the change.

	HOW A THEME IS UNLOCKED
	  cash      bought once with Cash (`cash` > 0), saved in profile.BaseTheme.owned
	  free      `cash` = 0 and no pass: everyone owns it (the defaults)
	  gamePass  `passKey` names a MonetizationConfig.ThemePasses row; Roblox
	            ownership is the authority (a refund removes it). While that
	            row's id is 0 the item is hidden outside Studio.

	KEYS ARE ONE NAMESPACE. Theme and pedestal keys share profile.BaseTheme
	.owned, so validate insists they are unique across both lists.

	ART. `thumbnail` is the preview image (0 = the UI draws colour swatches).
	`decor` props are primitives by default; a Model named `modelName` under
	ServerStorage.GameAssets.ThemeDecor replaces the primitive when present.
	See docs/codex-prompts/fusion-autoreveal-bases.md.
]]

local BaseThemeConfig = {}

export type Decor = {
	--- Where the prop stands: on top of both gate caps, or on the two back
	--- corner fence posts. Both anchors are the fence's own parts, so a prop
	--- can never block a pad, the porch or the treadmill.
	anchor: string, -- "gate" | "backCorner"
	shape: string, -- "Block" | "Ball" | "Cylinder"
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	--- Range of a PointLight in the prop's colour; 0 = no light. Keep ranges
	--- small (Graphics LOW does not reach plot decor). Every row sets it so
	--- the table literals type-check as one shape.
	light: number,
	--- ServerStorage.GameAssets.ThemeDecor.<modelName> replaces the primitive.
	modelName: string,
}

export type Theme = {
	key: string,
	name: string,
	blurb: string,
	--- 0 = free (default) or a Robux theme (see passKey).
	cash: number,
	passKey: string?,
	--- nil fields keep the map's own look.
	floorColor: Color3?,
	floorMaterial: Enum.Material?,
	pavingColor: Color3?,
	fenceColor: Color3?,
	railColor: Color3?,
	fenceMaterial: Enum.Material?,
	--- Neon on the gate caps and the frame of every EMPTY display pad.
	accentColor: Color3?,
	decor: { Decor }?,
	thumbnail: string,
}

export type PedestalSkin = {
	key: string,
	name: string,
	cash: number,
	passKey: string?,
	--- nil = the pedestal asset's own look (the default skin).
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	--- A thin ring round the top edge.
	trimColor: Color3?,
	trimMaterial: Enum.Material?,
	thumbnail: string,
}

BaseThemeConfig.DEFAULT_THEME = "Classic"
BaseThemeConfig.DEFAULT_PEDESTAL = "Default"

--- Requests per second on BaseThemeRequest, per player.
BaseThemeConfig.REQUESTS_PER_SECOND = 3

--- [round3-ui-base-settings] Icons for the Upgrades panel's tab bar and the
--- BASE page's section headers. "rbxassetid://0" = placeholder: the pack's
--- upgrade arrow for TREADMILL, a drawn mini plot for BASE, a drawn swatch
--- for the sections. See docs/codex-prompts/round3.md.
BaseThemeConfig.UiIcons = {
	TabTreadmill = "rbxassetid://88108320358342",
	TabBase = "rbxassetid://73130452273324",
	SectionThemes = "rbxassetid://77072843582885",
	SectionPedestals = "rbxassetid://138820984899615",
} :: { [string]: string }

-- ==========================================================
-- THEMES (cheapest first; the order is the display order)
-- ==========================================================

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Annotated locals rather than `:: { Theme }` casts: a cast infers the
-- literal first and then rejects rows whose optional fields differ.
local THEMES: { Theme } = {
	{
		key = "Classic",
		name = "Classic",
		blurb = "The museum's own green plot.",
		cash = 0,
		thumbnail = "rbxassetid://122910334010235",
	},
	{
		key = "Sunset",
		name = "Sunset Plaza",
		blurb = "Warm sandstone and terracotta.",
		cash = 250e3,
		floorColor = rgb(232, 196, 142),
		pavingColor = rgb(214, 170, 120),
		fenceColor = rgb(170, 84, 52),
		railColor = rgb(255, 226, 190),
		accentColor = rgb(255, 150, 60),
		decor = {
			{ anchor = "gate", shape = "Ball", size = Vector3.new(2.2, 2.2, 2.2), color = rgb(255, 170, 70), material = Enum.Material.Neon, light = 10, modelName = "SunsetLantern" },
		},
		thumbnail = "rbxassetid://130625653009493",
	},
	{
		key = "Midnight",
		name = "Midnight",
		blurb = "Slate stone under cyan light.",
		cash = 5e6,
		floorColor = rgb(52, 58, 78),
		floorMaterial = Enum.Material.Slate,
		pavingColor = rgb(70, 78, 102),
		fenceColor = rgb(24, 30, 52),
		railColor = rgb(120, 200, 255),
		accentColor = rgb(70, 220, 255),
		decor = {
			{ anchor = "gate", shape = "Cylinder", size = Vector3.new(2.6, 1.6, 1.6), color = rgb(70, 220, 255), material = Enum.Material.Neon, light = 12, modelName = "MidnightBeacon" },
			{ anchor = "backCorner", shape = "Ball", size = Vector3.new(1.6, 1.6, 1.6), color = rgb(70, 220, 255), material = Enum.Material.Neon, light = 0, modelName = "MidnightOrb" },
		},
		thumbnail = "rbxassetid://87748470112947",
	},
	{
		key = "Jungle",
		name = "Jungle Ruins",
		blurb = "Moss, old stone and vines.",
		cash = 50e6,
		floorColor = rgb(92, 140, 64),
		floorMaterial = Enum.Material.Grass,
		pavingColor = rgb(150, 140, 110),
		fenceColor = rgb(110, 98, 78),
		fenceMaterial = Enum.Material.Cobblestone,
		railColor = rgb(84, 120, 60),
		accentColor = rgb(150, 255, 90),
		decor = {
			{ anchor = "gate", shape = "Block", size = Vector3.new(2.4, 3, 2.4), color = rgb(120, 112, 90), material = Enum.Material.Cobblestone, light = 0, modelName = "JungleTotem" },
			{ anchor = "backCorner", shape = "Ball", size = Vector3.new(3, 3, 3), color = rgb(70, 130, 50), material = Enum.Material.Grass, light = 0, modelName = "JungleBush" },
		},
		thumbnail = "rbxassetid://82383429796738",
	},
	{
		key = "Frost",
		name = "Frost Palace",
		blurb = "Glacier floor and icy trim.",
		cash = 750e6,
		floorColor = rgb(200, 230, 250),
		floorMaterial = Enum.Material.Glacier,
		pavingColor = rgb(236, 246, 255),
		fenceColor = rgb(236, 244, 255),
		fenceMaterial = Enum.Material.Ice,
		railColor = rgb(160, 210, 255),
		accentColor = rgb(150, 220, 255),
		decor = {
			{ anchor = "gate", shape = "Block", size = Vector3.new(1.4, 3.4, 1.4), color = rgb(190, 235, 255), material = Enum.Material.Ice, light = 8, modelName = "FrostCrystal" },
		},
		thumbnail = "rbxassetid://78146481409731",
	},
	{
		key = "Lava",
		name = "Lava Forge",
		blurb = "Basalt and molten orange.",
		cash = 20e9,
		floorColor = rgb(60, 50, 48),
		floorMaterial = Enum.Material.Basalt,
		pavingColor = rgb(84, 68, 60),
		fenceColor = rgb(36, 30, 30),
		fenceMaterial = Enum.Material.Basalt,
		railColor = rgb(255, 110, 40),
		accentColor = rgb(255, 90, 30),
		decor = {
			{ anchor = "gate", shape = "Cylinder", size = Vector3.new(1.4, 2.6, 2.6), color = rgb(255, 110, 30), material = Enum.Material.Neon, light = 12, modelName = "LavaBrazier" },
			{ anchor = "backCorner", shape = "Cylinder", size = Vector3.new(1.2, 2, 2), color = rgb(255, 110, 30), material = Enum.Material.Neon, light = 0, modelName = "LavaBrazier" },
		},
		thumbnail = "rbxassetid://99098592123330",
	},
	-- ROBUX-EXCLUSIVE (Game Pass placeholders; see MonetizationConfig.ThemePasses)
	{
		key = "NeonNight",
		name = "Neon Night",
		blurb = "Black glass and magenta neon.",
		cash = 0,
		passKey = "ThemeNeonNight",
		floorColor = rgb(18, 16, 28),
		floorMaterial = Enum.Material.Glass,
		pavingColor = rgb(34, 24, 52),
		fenceColor = rgb(26, 20, 40),
		railColor = rgb(255, 60, 220),
		accentColor = rgb(255, 60, 220),
		decor = {
			{ anchor = "gate", shape = "Ball", size = Vector3.new(2.4, 2.4, 2.4), color = rgb(255, 60, 220), material = Enum.Material.Neon, light = 14, modelName = "NeonOrb" },
			{ anchor = "backCorner", shape = "Ball", size = Vector3.new(2, 2, 2), color = rgb(90, 220, 255), material = Enum.Material.Neon, light = 10, modelName = "NeonOrb" },
		},
		thumbnail = "rbxassetid://129189897009316",
	},
	{
		key = "RoyalGold",
		name = "Royal Gold",
		blurb = "Marble and polished gold.",
		cash = 0,
		passKey = "ThemeRoyalGold",
		floorColor = rgb(236, 232, 224),
		floorMaterial = Enum.Material.Marble,
		pavingColor = rgb(214, 196, 150),
		fenceColor = rgb(212, 170, 60),
		fenceMaterial = Enum.Material.Foil,
		railColor = rgb(255, 236, 170),
		accentColor = rgb(255, 210, 80),
		decor = {
			{ anchor = "gate", shape = "Ball", size = Vector3.new(2.2, 2.2, 2.2), color = rgb(255, 206, 60), material = Enum.Material.Foil, light = 8, modelName = "RoyalCrown" },
			{ anchor = "backCorner", shape = "Block", size = Vector3.new(1.6, 2.4, 1.6), color = rgb(236, 232, 224), material = Enum.Material.Marble, light = 0, modelName = "RoyalUrn" },
		},
		thumbnail = "rbxassetid://95896104729019",
	},
}
BaseThemeConfig.Themes = THEMES

-- ==========================================================
-- PEDESTAL SKINS
-- ==========================================================

local PEDESTALS: { PedestalSkin } = {
	{ key = "Default", name = "Museum Stone", cash = 0, thumbnail = "rbxassetid://117727520280928" },
	{
		key = "Marble",
		name = "White Marble",
		cash = 100e3,
		color = rgb(240, 238, 232),
		material = Enum.Material.Marble,
		trimColor = rgb(230, 190, 90),
		trimMaterial = Enum.Material.Foil,
		thumbnail = "rbxassetid://124190212352604",
	},
	{
		key = "Obsidian",
		name = "Obsidian",
		cash = 10e6,
		color = rgb(30, 26, 38),
		material = Enum.Material.Basalt,
		trimColor = rgb(170, 90, 255),
		trimMaterial = Enum.Material.Neon,
		thumbnail = "rbxassetid://137911196029906",
	},
	{
		key = "GoldPlinth",
		name = "Solid Gold",
		cash = 1e9,
		color = rgb(230, 180, 60),
		material = Enum.Material.Foil,
		trimColor = rgb(255, 255, 255),
		trimMaterial = Enum.Material.SmoothPlastic,
		thumbnail = "rbxassetid://132414674734023",
	},
	{
		key = "Crystal",
		name = "Crystal",
		cash = 100e9,
		color = rgb(150, 230, 255),
		material = Enum.Material.Glass,
		transparency = 0.25,
		trimColor = rgb(120, 230, 255),
		trimMaterial = Enum.Material.Neon,
		thumbnail = "rbxassetid://140580441452762",
	},
}
BaseThemeConfig.Pedestals = PEDESTALS

BaseThemeConfig.ThemeByKey = {} :: { [string]: Theme }
for _, theme in BaseThemeConfig.Themes do
	BaseThemeConfig.ThemeByKey[theme.key] = theme
end

BaseThemeConfig.PedestalByKey = {} :: { [string]: PedestalSkin }
for _, skin in BaseThemeConfig.Pedestals do
	BaseThemeConfig.PedestalByKey[skin.key] = skin
end

--- True when an asset id string is a real id (the UI skips "rbxassetid://0").
function BaseThemeConfig.hasImage(image: string?): boolean
	return type(image) == "string" and image ~= "" and image ~= "rbxassetid://0"
end

return BaseThemeConfig
