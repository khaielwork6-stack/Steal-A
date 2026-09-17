--!strict
--[[
	GadgetConfig
	The three consumable heist gadgets (docs/handoff-parts/gadgets-patrols.md).

	A CASH SINK WITH SKILL EXPRESSION. Gadgets are bought with Cash, carried in
	small stacks (`maxCarried`), and each use costs one. They never grant
	anything: they only change how a run can be played.

	    Smoke   dropped at the player's feet: every museum guard currently
	            chasing that player loses them (GuardianService.confuse).
	    Jammer  the laser detector ignores this player for JAM_SECONDS
	            (LaserService.jam - a server-owned, time-limited state).
	    Grapple pulls the player to a surface point within GRAPPLE_RANGE; the
	            anti-cheat budget is widened for the pull
	            (MovementService.allowBurst). NOT usable while carrying loot
	            (GRAPPLE_WHILE_CARRYING): it would be a guaranteed escape tool
	            that skips the chase the whole game is built around.

	PRICE = basePrice x ZONE_PRICE_MULTIPLIER[the player's HighestZoneReached],
	so a gadget costs a similar number of seconds of income at every stage of
	the game. The multipliers follow the zones' income ladder (LootConfig);
	they are a first pass for the owner to tune, not measured parity numbers.

	Every number here is checked by validate.luau (GADGETS AND PATROLS block).
]]

local GadgetConfig = {}

export type GadgetDef = {
	--- "Smoke" | "Jammer" | "Grapple": the profile key (Gadgets[key]).
	key: string,
	--- The Tool's Name in the Backpack. Also the HotbarController fixed-slot key.
	toolName: string,
	label: string,
	description: string,
	basePrice: number,
	--- The most a player may hold at once. A purchase past this is refused.
	maxCarried: number,
	--- Seconds between two uses of THIS gadget.
	cooldown: number,
	--- The hotbar key it lives on (1 = weapon, 2 = trap).
	hotbarSlot: number,
	--- "rbxassetid://0" = no icon yet: the shop card keeps the pack art and
	--- the hotbar draws the Tool's placeholder parts. Codex fills these
	--- (docs/codex-prompts/gadgets-patrols.md).
	icon: string,
	--- "rbxassetid://0" = build the placeholder handle from parts.
	meshId: string,
	textureId: string,
	--- Card tint and placeholder colour.
	color: Color3,
	accent: Color3,
}

GadgetConfig.Order = { "Smoke", "Jammer", "Grapple" } :: { string }

GadgetConfig.Gadgets = {
	Smoke = {
		key = "Smoke",
		toolName = "SmokeBomb",
		label = "Smoke Bomb",
		description = "Guards chasing you lose your trail.",
		basePrice = 250,
		maxCarried = 3,
		cooldown = 10,
		hotbarSlot = 3,
		icon = "rbxassetid://0",
		meshId = "rbxassetid://0",
		textureId = "rbxassetid://0",
		color = Color3.fromRGB(170, 176, 196),
		accent = Color3.fromRGB(72, 78, 102),
	},
	Jammer = {
		key = "Jammer",
		toolName = "LaserJammer",
		label = "Laser Jammer",
		description = "Lasers ignore you for 4 seconds.",
		basePrice = 400,
		maxCarried = 2,
		cooldown = 14,
		hotbarSlot = 4,
		icon = "rbxassetid://0",
		meshId = "rbxassetid://0",
		textureId = "rbxassetid://0",
		color = Color3.fromRGB(96, 230, 255),
		accent = Color3.fromRGB(20, 110, 170),
	},
	Grapple = {
		key = "Grapple",
		toolName = "GrapplingHook",
		label = "Grappling Hook",
		description = "Zip to a surface up to 40 studs away. Not while carrying.",
		basePrice = 300,
		maxCarried = 3,
		cooldown = 6,
		hotbarSlot = 5,
		icon = "rbxassetid://0",
		meshId = "rbxassetid://0",
		textureId = "rbxassetid://0",
		color = Color3.fromRGB(255, 196, 92),
		accent = Color3.fromRGB(170, 96, 24),
	},
} :: { [string]: GadgetDef }

--- Tool name -> gadget key, for the client's tool hook and the server's
--- "which tool is this" checks.
GadgetConfig.ByToolName = {} :: { [string]: GadgetDef }
for _, def in GadgetConfig.Gadgets do
	GadgetConfig.ByToolName[def.toolName] = def
end

-- ==========================================================
-- PRICE
-- ==========================================================

--- One entry per zone (12). Roughly the zones' common-item income ladder.
GadgetConfig.ZONE_PRICE_MULTIPLIER = { 1, 4, 20, 150, 800, 3e3, 15e3, 80e3, 300e3, 1.5e6, 6e6, 150e6 }

--- The Cash price of one `key` for a player whose highest zone is `zone`.
function GadgetConfig.priceFor(key: string, zone: number): number
	local def = GadgetConfig.Gadgets[key]
	if not def then
		return math.huge
	end
	local list = GadgetConfig.ZONE_PRICE_MULTIPLIER
	local index = math.clamp(math.floor(tonumber(zone) or 1), 1, #list)
	return math.floor(def.basePrice * list[index])
end

-- ==========================================================
-- EFFECTS
-- ==========================================================

--- Smoke: how long a guard chasing the user loses them (and stands
--- "Searching"), and how long the cloud is on screen.
GadgetConfig.SMOKE_CONFUSE_SECONDS = 2.5
GadgetConfig.SMOKE_CLOUD_SECONDS = 3.5
--- Visual radius of the cloud, studs.
GadgetConfig.SMOKE_RADIUS = 9
--- Particle textures. The engine's own smoke/sparkle sheets until Codex
--- uploads dedicated ones (docs/codex-prompts/gadgets-patrols.md).
GadgetConfig.SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
GadgetConfig.JAM_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

--- Jammer: seconds the laser detector ignores the user.
GadgetConfig.JAM_SECONDS = 4

--- Grapple: the farthest surface point, the pull time, and how far the
--- server's own raycast hit may be from the point the client asked for.
GadgetConfig.GRAPPLE_RANGE = 40
GadgetConfig.GRAPPLE_PULL_SECONDS = 0.6
GadgetConfig.GRAPPLE_TARGET_TOLERANCE = 4
--- Where the pull stops, short of the surface, so the player lands against it
--- rather than inside it.
GadgetConfig.GRAPPLE_STANDOFF = 2.5
--- Extra studs/s the anti-cheat budget allows on top of the pull speed
--- (network batching of the fast frames).
GadgetConfig.GRAPPLE_BURST_SLACK = 20
--- Decision (see header): the grapple is refused while carrying loot.
GadgetConfig.GRAPPLE_WHILE_CARRYING = false

-- ==========================================================
-- LIMITS
-- ==========================================================

--- Gadgets work only on the museum's danger side (past the red line, inside
--- the lane). Outside it they would be wasted, or - for the grapple - a way
--- onto roofs and other players' plots.
GadgetConfig.MUSEUM_ONLY = true
--- Minimum gap between ANY two gadget uses, on top of each gadget's cooldown.
GadgetConfig.SHARED_COOLDOWN = 0.75
--- GadgetRequest rate limits (per second): uses, and shop buys.
GadgetConfig.USE_PER_SECOND = 3
GadgetConfig.BUY_PER_SECOND = 2

return GadgetConfig
