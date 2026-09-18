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
	            (MovementService.allowBurst). Usable while carrying loot since
	            round3-gameplay (owner, 2026-09-17; GRAPPLE_WHILE_CARRYING).

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
		-- round3-gameplay: the chase resumes when the smoke clears.
		description = "Guards lose you briefly. Reach the red line before it clears!",
		basePrice = 250,
		maxCarried = 3,
		cooldown = 10,
		hotbarSlot = 3,
		icon = "rbxassetid://107139254495198",
		meshId = "rbxassetid://124725914946020",
		textureId = "rbxassetid://84571130904842",
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
		icon = "rbxassetid://120036928718933",
		meshId = "rbxassetid://134666074031773",
		textureId = "rbxassetid://84767158976783",
		color = Color3.fromRGB(96, 230, 255),
		accent = Color3.fromRGB(20, 110, 170),
	},
	Grapple = {
		key = "Grapple",
		toolName = "GrapplingHook",
		label = "Grappling Hook",
		-- The number must match GRAPPLE_RANGE (validate checks it).
		description = "Zip to a surface up to 80 studs away.",
		basePrice = 300,
		maxCarried = 3,
		cooldown = 6,
		hotbarSlot = 5,
		icon = "rbxassetid://124548706027503",
		meshId = "rbxassetid://125646359721049",
		textureId = "rbxassetid://116722379580454",
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
--- When the confusion ends, every guard it took a target from resumes that
--- chase at once unless the player is behind the safe line (round3-gameplay).
GadgetConfig.SMOKE_CONFUSE_SECONDS = 2.5
GadgetConfig.SMOKE_CLOUD_SECONDS = 3.5
--- Visual radius of the cloud, studs. 27 since round3-gameplay (3x the first
--- pass's 9): a cloud that genuinely hides a player and a guard.
GadgetConfig.SMOKE_RADIUS = 27
--- The cloud's thinning-out after SMOKE_CLOUD_SECONDS (visual only).
GadgetConfig.SMOKE_FADE_SECONDS = 1.5
--- Particle textures. The engine's own smoke/sparkle sheets until Codex
--- uploads dedicated ones (docs/codex-prompts/gadgets-patrols.md).
GadgetConfig.SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
GadgetConfig.JAM_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

--- Jammer: seconds the laser detector ignores the user.
GadgetConfig.JAM_SECONDS = 4

--- Grapple: the farthest surface point, the pull time, and how far the
--- server's own raycast hit may be from the point the client asked for.
GadgetConfig.GRAPPLE_RANGE = 80 -- owner, 2026-09-17 (was 40)
GadgetConfig.GRAPPLE_PULL_SECONDS = 0.6
GadgetConfig.GRAPPLE_TARGET_TOLERANCE = 4
--- Where the pull stops, short of the surface, so the player lands against it
--- rather than inside it.
GadgetConfig.GRAPPLE_STANDOFF = 2.5
--- Extra studs/s the anti-cheat budget allows on top of the pull speed
--- (network batching of the fast frames).
GadgetConfig.GRAPPLE_BURST_SLACK = 20
--- Owner, 2026-09-17: the grapple works while carrying loot (it was refused
--- in the first pass). The burst budget and the server raycast still apply,
--- and the pull's distance is credited to the delivery timer.
GadgetConfig.GRAPPLE_WHILE_CARRYING = true

-- ==========================================================
-- LOBBY STORE (round3-gameplay)
-- ==========================================================

--- The physical gadget stand in the lobby (GadgetStoreService). The position
--- is the LobbyLayout free spot unless the place has a part named
--- STORE_MARKER under workspace.LobbyMarkers (like the leaderboards).
GadgetConfig.STORE_MARKER = "GadgetStore"
--- Hold time of the "Shop" prompt.
GadgetConfig.STORE_PROMPT_HOLD = 0.3
--- Degrees per second the display models turn (0 under Reduced Effects).
GadgetConfig.STORE_SPIN_SPEED = 40

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
