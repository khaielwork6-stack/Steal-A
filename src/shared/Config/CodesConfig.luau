--!strict
--[[
	CodesConfig
	The redeemable codes (Settings panel -> CODES). Server-authoritative: the
	client only ever sends the text the player typed; CodeService looks it up
	here, checks it and pays.

	HOW A CODE IS MATCHED
	The typed text is trimmed and upper-cased (`CodesConfig.normalise`), and so
	is every `code` below when the lookup table is built, so "museum ",
	"Museum" and "MUSEUM" are the same code. Keep codes to letters and digits:
	anything else is rejected before the lookup.

	WHAT A CODE PAYS (`rewards`, every field optional, any combination)
	  cash              a fixed dollar amount, or
	  cashMinutes       that many minutes of the player's BASE income (the 2x
	                    pass and boosts divided out - the same basis the Cash
	                    packs and the spin wheel use), never below `cashFloor`
	  speed             a fixed Speed amount, or
	  speedGateFraction that share of the recommended Speed of the zone AFTER
	                    the player's highest zone (SpinWheelConfig.nextGate),
	                    never below `speedFloor` and never above `speedMax`
	  guardianKey       a BaseGuardianConfig key. Granted through
	                    BaseGuardianService.grantWon (the spin wheel's path);
	                    a player who already owns it gets
	                    SpinWheelConfig.DUPLICATE_GUARDIAN_SPEED instead.
	Fixed and scaled forms of the same currency add up; normally use one.

	LIFETIME
	  enabled    false = the code does not exist as far as players can tell
	             ("That code is invalid."). The switch for pulling a code.
	  expiresAt  UTC unix seconds; at or after it the code answers "expired".
	             nil = never expires.
	  minZone    the player's HighestZoneReached must be at least this.

	Each code is redeemable ONCE PER PLAYER (Profile.RedeemedCodes), forever.
	Re-using a code string for a new reward later will NOT pay players who
	redeemed the old one - pick a new string instead.

	THE WALL. Codes are one-off gifts; keep Speed codes small (a percent or two
	of the next gate, capped) so no code moves the Zone 8+ progression.
]]

local CodesConfig = {}

export type Rewards = {
	cash: number?,
	cashMinutes: number?,
	cashFloor: number?,
	speed: number?,
	speedGateFraction: number?,
	speedFloor: number?,
	speedMax: number?,
	guardianKey: string?,
}

export type CodeDef = {
	code: string,
	enabled: boolean,
	rewards: Rewards,
	expiresAt: number?,
	minZone: number?,
	--- For the owner only (debug listing); never shown to players.
	note: string?,
}

--- The longest text the server will even look at. Longer input is refused
--- before any string work is done on it.
CodesConfig.MAX_LENGTH = 24

--- The icon at the left of the CODES row in Settings (CodesController).
--- "rbxassetid://0" = no icon yet; the row shows its title only. Codex fills
--- this in (docs/codex-prompts/retention-codes-daily.md).
CodesConfig.HEADER_ICON = "rbxassetid://117680902903904"

-- ==========================================================
-- RATE LIMITING (per player, server-side)
-- ==========================================================

--- Sustained attempts per second (5 a minute) and the burst allowed on top.
CodesConfig.ATTEMPTS_PER_SECOND = 5 / 60
CodesConfig.ATTEMPT_BURST = 5
--- This many FAILED attempts (invalid / expired / already redeemed / zone)
--- inside FAILURE_WINDOW seconds locks the player out for LOCKOUT_SECONDS.
--- Kept per UserId for the life of the server, so rejoining does not reset it.
CodesConfig.FAILURE_LIMIT = 8
CodesConfig.FAILURE_WINDOW = 10 * 60
CodesConfig.LOCKOUT_SECONDS = 5 * 60

-- ==========================================================
-- THE CODES
-- ==========================================================

CodesConfig.Codes = {
	{
		code = "MUSEUM",
		enabled = true,
		-- Ten minutes of base income, at least $2,500 (a fresh player earns
		-- a few $/s, so the floor is what they actually get).
		rewards = { cashMinutes = 10, cashFloor = 2500 },
		note = "launch code: 10 min of income",
	},
	{
		code = "RELEASE",
		enabled = true,
		-- 1% of the next zone's gate, 500 minimum, 250K maximum. For a Zone 8
		-- player (next gate 700M) that is the 250K cap: 0.04% of the wall.
		rewards = { speedGateFraction = 0.01, speedFloor = 500, speedMax = 250e3 },
		note = "launch code: Speed toward the next gate",
	},
	{
		-- An EXAMPLE of a retired code: disabled AND past its expiry
		-- (2026-01-01 00:00 UTC). Kept so the expired / disabled paths have a
		-- real row to be tested against; players see "invalid".
		code = "BETATEST",
		enabled = false,
		expiresAt = 1767225600,
		rewards = { cash = 1000 },
		note = "example: expired and disabled",
	},
} :: { CodeDef }

--- Trims whitespace and upper-cases. Returns nil for anything that is not a
--- plausible code (not a string, empty, too long, or not letters/digits), so
--- callers never look up junk.
function CodesConfig.normalise(raw: any): string?
	if type(raw) ~= "string" then
		return nil
	end
	-- The length check comes first so a megabyte of input costs nothing.
	if #raw > CodesConfig.MAX_LENGTH * 4 then
		return nil
	end
	local trimmed = string.match(raw, "^%s*(.-)%s*$") or ""
	if trimmed == "" or #trimmed > CodesConfig.MAX_LENGTH then
		return nil
	end
	if string.find(trimmed, "[^%w]") then
		return nil
	end
	return string.upper(trimmed)
end

--- Normalised code -> definition. Built once from `Codes`.
CodesConfig.ByCode = {} :: { [string]: CodeDef }
for _, def in CodesConfig.Codes do
	local key = CodesConfig.normalise(def.code)
	if key then
		CodesConfig.ByCode[key] = def
	end
end

return CodesConfig
