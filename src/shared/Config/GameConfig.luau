--!strict
--[[
	GameConfig
	Global tuning constants. Every number a designer might want to change lives in
	a config module, never inline in a service (GDD operating rules).
]]

local GameConfig = {}

GameConfig.MAX_PLAYERS = 7

-- Fresh account state (GDD section 4).
GameConfig.STARTING_CASH = 0
GameConfig.STARTING_SPEED_POWER = 10
GameConfig.STARTING_TRAPS = 3
GameConfig.STARTING_DISPLAY_SLOTS = 7
GameConfig.MAX_DISPLAY_SLOTS = 14

-- Movement compression (GDD section 5). Huge SpeedPower stays exciting without
-- handing the Humanoid billions of studs/second.
GameConfig.WALKSPEED_BASE = 16
GameConfig.WALKSPEED_COEFFICIENT = 7.5
GameConfig.WALKSPEED_MIN = 18
GameConfig.WALKSPEED_MAX = 90

--- RealWalkSpeed = clamp(16 + 7.5 * log10(1 + SpeedPower / 10), 18, 90)
function GameConfig.walkSpeedFromPower(power: number): number
	local raw = GameConfig.WALKSPEED_BASE
		+ GameConfig.WALKSPEED_COEFFICIENT * math.log10(1 + power / 10)
	return math.clamp(raw, GameConfig.WALKSPEED_MIN, GameConfig.WALKSPEED_MAX)
end

-- Economy cadence.
GameConfig.INCOME_TICK = 1 -- seconds between aggregate Cash grants
GameConfig.AUTOSAVE_INTERVAL = 60
GameConfig.SELL_REFUND_SECONDS = 60 -- selling pays this many seconds of income

-- Interaction.
GameConfig.STEAL_HOLD_DURATION = 1.0
GameConfig.STEAL_INTERACTION_RANGE = 14

-- Loot lifecycle (GDD section 6).
GameConfig.SOCKET_REFILL_DELAY = 20 -- after a successful theft
GameConfig.GUARDIAN_RETURN_DELAY = 2 -- after a guardian reclaims
GameConfig.DROPPED_RECLAIM_WINDOW = 8 -- before a PvP drop returns to origin
GameConfig.GLOBAL_REFRESH_INTERVAL = 300
GameConfig.GLOBAL_REFRESH_WARNING = 10

-- Anti-exploit: max accepted requests per player per second, per remote.
GameConfig.RATE_LIMITS = {
	StealRequest = 4,
	PlaceLootRequest = 4,
	SellLootRequest = 4,
	BaseUpgradeRequest = 2,
	TreadmillUpgradeRequest = 2,
	BatSwingRequest = 4,
	TrapPlaceRequest = 3,
	IndexClaimRequest = 4,
}

return GameConfig
