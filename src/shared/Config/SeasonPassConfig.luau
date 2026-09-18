--!strict
--[[
	SeasonPassConfig
	The season pass (retention pass): one season at a time, 30 tiers, a free
	track and a premium track.

	THE SEASON ID IS THE RESET. `Profile.Season.id` is compared with SEASON_ID
	on every access; a different id wipes XP and both claim lists for the new
	season (SeasonPassService). Start a new season by changing SEASON_ID and
	the dates - never by reusing an id.

	XP (all server-side, SeasonPassService):
	  * a claimed daily quest   QuestConfig.SEASON_XP.daily   (100)
	  * a claimed weekly quest  QuestConfig.SEASON_XP.weekly  (400)
	  * a museum steal          STEAL_XP (10), at most DAILY_STEAL_XP_CAP a day
	Everything except weekly-quest XP also counts towards DAILY_XP_CAP; a
	weekly claim is never cut short by it. XP earned outside the season's
	start/end window is not added.

	PREMIUM is a Game Pass (MonetizationConfig.SeasonPremiumPass). While its id
	is 0 the premium row is shown locked with "COMING SOON" and nothing on it
	can be claimed. Premium tiers are claimable for every tier already reached,
	so buying mid-season unlocks everything earned so far.

	REWARD KINDS
	  cash      `minutes` of base income, at least `floor`
	  speed     `fraction` of the next zone gate, at least `floor`, at most `cap`
	  guardian  a base guardian by key (BaseGuardianService.grantWon); an owned
	            one pays DUPLICATE_GUARDIAN_SPEED instead
	  trail     a trail by key, added to TrailsOwned. PLACEHOLDER: the
	            exclusive season trail does not exist yet, so `trailKey` points
	            at the cash-bought "Grey" trail (see the handoff notes).
	  title     a cosmetic title string, kept forever in Profile.Titles.
	            Nothing renders titles yet.
]]

local SeasonPassConfig = {}

--- THE SWITCH. False: no XP, no claims, no PASS tab.
SeasonPassConfig.ENABLED = true

SeasonPassConfig.SEASON_ID = "S1"
SeasonPassConfig.SEASON_NAME = "Museum Heist"
SeasonPassConfig.SEASON_NUMBER = 1
--- Inclusive start, exclusive end, UTC. Eight weeks.
SeasonPassConfig.STARTS_AT = DateTime.fromUniversalTime(2026, 9, 14, 0, 0, 0).UnixTimestamp
SeasonPassConfig.ENDS_AT = DateTime.fromUniversalTime(2026, 11, 9, 0, 0, 0).UnixTimestamp

--- Banner art for the PASS tab. 0 = no art yet (a gradient banner is drawn).
SeasonPassConfig.BANNER_IMAGE = "rbxassetid://129767194657030"
--- The premium badge / lock icon. 0 = a text badge is drawn.
SeasonPassConfig.PREMIUM_BADGE_IMAGE = "rbxassetid://116117219554176"
SeasonPassConfig.LOCK_IMAGE = "rbxassetid://122764576805899"
--- [quests-season-split] The round HUD opener's icon, in the top strip
--- beside Daily. "rbxassetid://0" = no art yet, and a star mark is drawn in
--- the pack's font instead.
SeasonPassConfig.HUD_ICON = "rbxassetid://0"

SeasonPassConfig.STEAL_XP = 10
SeasonPassConfig.DAILY_STEAL_XP_CAP = 200
SeasonPassConfig.DAILY_XP_CAP = 800

--- Speed paid instead of a guardian the player already owns.
SeasonPassConfig.DUPLICATE_GUARDIAN_SPEED = 5000

--- Remote limits (token bucket per player).
SeasonPassConfig.CLAIM_PER_SECOND = 3
SeasonPassConfig.CLAIM_BURST = 6

-- ==========================================================
-- TIERS
-- ==========================================================

SeasonPassConfig.TIER_COUNT = 30

--- XP needed to go from tier n-1 to tier n: 400 for tier 1, +20 per tier
--- after. The whole pass is 20,700 XP - about four and a half weeks of every
--- daily and weekly quest (4,700 XP a week) plus steals, inside an eight-week
--- season, so a regular (not daily) player can still finish.
function SeasonPassConfig.costOf(tier: number): number
	return 400 + 20 * (tier - 1)
end

--- Cumulative XP at which each tier is reached.
SeasonPassConfig.Thresholds = {} :: { number }
do
	local total = 0
	for tier = 1, SeasonPassConfig.TIER_COUNT do
		total += SeasonPassConfig.costOf(tier)
		SeasonPassConfig.Thresholds[tier] = total
	end
end

export type RewardKind = "cash" | "speed" | "guardian" | "trail" | "title"

export type Reward = {
	kind: RewardKind,
	minutes: number?,
	floor: number?,
	fraction: number?,
	cap: number?,
	guardianKey: string?,
	trailKey: string?,
	title: string?,
	--- Tier reward icon; "rbxassetid://0" = no art yet (the client falls back
	--- to the pack's cash / speed icon or a text glyph).
	icon: string,
}

local function cash(minutes: number, floor: number): Reward
	return { kind = "cash", minutes = minutes, floor = floor, icon = "rbxassetid://125470424066769" }
end

local function speed(fraction: number, floor: number, cap: number): Reward
	return { kind = "speed", fraction = fraction, floor = floor, cap = cap, icon = "rbxassetid://83161544861662" }
end

local function title(text: string): Reward
	return { kind = "title", title = text, icon = "rbxassetid://113278101868190" }
end

local function guardian(key: string): Reward
	return { kind = "guardian", guardianKey = key, icon = "rbxassetid://115452231897906" }
end

--- PLACEHOLDER trail key: "Grey" is an existing, cash-bought trail. Replace
--- with the real season trail's key once it exists in MonetizationConfig.Trails.
SeasonPassConfig.SEASON_TRAIL_KEY = "Grey"

local function trail(): Reward
	return { kind = "trail", trailKey = SeasonPassConfig.SEASON_TRAIL_KEY, icon = "rbxassetid://133370093057404" }
end

export type Tier = { tier: number, free: Reward, premium: Reward }

-- Speed caps are the spin wheel's (500K / 5M): the pass never moves the
-- Zone 8+ wall. Free fractions are small; premium ones a little larger.
SeasonPassConfig.Tiers = {
	{ tier = 1, free = cash(5, 2000), premium = speed(0.01, 1000, 500e3) },
	{ tier = 2, free = speed(0.005, 500, 500e3), premium = cash(15, 5000) },
	{ tier = 3, free = cash(8, 3000), premium = title("Night Shift") },
	{ tier = 4, free = speed(0.005, 500, 500e3), premium = cash(20, 8000) },
	{ tier = 5, free = title("Rookie Thief"), premium = speed(0.015, 1500, 500e3) },
	{ tier = 6, free = cash(10, 4000), premium = cash(25, 10000) },
	{ tier = 7, free = speed(0.006, 600, 500e3), premium = speed(0.015, 1500, 500e3) },
	{ tier = 8, free = cash(12, 5000), premium = cash(30, 12000) },
	{ tier = 9, free = speed(0.006, 600, 500e3), premium = speed(0.02, 2000, 5e6) },
	{ tier = 10, free = title("Curator's Nightmare"), premium = guardian("Cat") },
	{ tier = 11, free = cash(15, 6000), premium = cash(35, 15000) },
	{ tier = 12, free = speed(0.007, 700, 500e3), premium = speed(0.02, 2000, 5e6) },
	{ tier = 13, free = cash(15, 6000), premium = title("Vault Cracker") },
	{ tier = 14, free = speed(0.007, 700, 500e3), premium = cash(40, 18000) },
	{ tier = 15, free = cash(20, 8000), premium = speed(0.025, 2500, 5e6) },
	{ tier = 16, free = speed(0.008, 800, 500e3), premium = cash(45, 20000) },
	{ tier = 17, free = cash(20, 8000), premium = speed(0.025, 2500, 5e6) },
	{ tier = 18, free = speed(0.008, 800, 500e3), premium = cash(50, 22000) },
	{ tier = 19, free = cash(25, 10000), premium = speed(0.03, 3000, 5e6) },
	{ tier = 20, free = title("Laser Dancer"), premium = guardian("Dog") },
	{ tier = 21, free = cash(25, 10000), premium = cash(60, 25000) },
	{ tier = 22, free = speed(0.009, 900, 500e3), premium = speed(0.03, 3000, 5e6) },
	{ tier = 23, free = cash(30, 12000), premium = cash(60, 28000) },
	{ tier = 24, free = speed(0.009, 900, 500e3), premium = speed(0.035, 3500, 5e6) },
	{ tier = 25, free = cash(30, 12000), premium = title("Master Thief") },
	{ tier = 26, free = speed(0.01, 1000, 500e3), premium = cash(75, 30000) },
	{ tier = 27, free = cash(40, 15000), premium = speed(0.04, 4000, 5e6) },
	{ tier = 28, free = speed(0.01, 1000, 500e3), premium = cash(90, 35000) },
	{ tier = 29, free = cash(45, 18000), premium = speed(0.05, 5000, 5e6) },
	{ tier = 30, free = title("Museum Legend"), premium = trail() },
} :: { Tier }

-- ==========================================================
-- HELPERS
-- ==========================================================

--- The highest tier `xp` has reached (0 = none yet).
function SeasonPassConfig.tierFor(xp: number): number
	local reached = 0
	for tier, threshold in SeasonPassConfig.Thresholds do
		if xp >= threshold then
			reached = tier
		else
			break
		end
	end
	return reached
end

function SeasonPassConfig.isActive(now: number): boolean
	return now >= SeasonPassConfig.STARTS_AT and now < SeasonPassConfig.ENDS_AT
end

--- The amount a cash/speed reward pays right now; 0 for other kinds.
function SeasonPassConfig.amountFor(reward: Reward, baseIncome: number, nextGate: number): number
	local income = tonumber(baseIncome) or 0
	if income ~= income or income == math.huge or income < 0 then
		income = 0
	end
	local gate = tonumber(nextGate) or 0
	if gate ~= gate or gate == math.huge or gate < 0 then
		gate = 0
	end
	if reward.kind == "cash" then
		return math.floor(math.max(reward.floor or 0, income * (reward.minutes or 0) * 60))
	elseif reward.kind == "speed" then
		local scaled = math.max(reward.floor or 0, gate * (reward.fraction or 0))
		return math.floor(math.min(reward.cap or scaled, scaled))
	end
	return 0
end

return SeasonPassConfig
