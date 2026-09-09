--!strict
--[[
	EconomyService
	Aggregate passive income and all Cash mutation (GDD section 8).

	THE FUNNEL, per placed item, in this order and nowhere else:

	    preBoostRate = max( round( base x sizeFactor(Scale) x mutation x moneyPass ), 1 )
	    finalRate    = round( preBoostRate x SERVER_EARNINGS_BOOST x TEMPORARY_EARNINGS_BOOST )

	    total $/s    = sum of finalRate over ACTIVE items: on display, not being
	                   robbed, and MATURED (GrowthSeconds >= MaturationSeconds).

	`moneyPass` is 2 for an owner of the 2x Cash pass, else 1 - inside the
	per-item rounding, exactly once. Nothing else multiplies recurring income:
	no growth bonus, no Index percentage, no rebirth, no second Cash-pass
	application. Growth decides WHEN an item starts earning, never how much.

	Income architecture rule: do NOT run a loop per displayed item on a timer.
	The total is recalculated only when a display changes, and one heartbeat
	grants the aggregate once per second.

	Every Cash change in the game goes through award/spend here so there is a
	single place that can never go negative. Every award carries a SOURCE TAG
	so the parity tool can account for where Cash came from.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local DataService = require(script.Parent.DataService)

local EconomyService = {}

local incomePerSecond: { [Player]: number } = {}
local listeners: { (Player) -> () } = {}

--- Cash awarded this session, by source tag, per player. Read by the parity
--- tool; never saved.
local awardedBySource: { [Player]: { [string]: number } } = {}

export type CashSource = "passive" | "sell" | "discovery" | "index" | "offline" | "product" | "debug" | "other"

--- Fires whenever Cash or income changes so StatePush can replicate.
function EconomyService.onChanged(callback: (Player) -> ())
	table.insert(listeners, callback)
end

local function notify(player: Player)
	for _, callback in listeners do
		task.spawn(callback, player)
	end
end

-- ==========================================================
-- THE PER-ITEM RATE
-- ==========================================================

--- THE 2X CASH PASS. Overridden by init so this service need not require
--- MonetizationService. Returns 1 until ownership has been warmed, which is
--- the safe direction: a missed double is recoverable, a doubled purchase is
--- not.
function EconomyService.cashMultiplierFor(_player: Player): number
	return 1
end

--- True once a placed item has accrued its maturation time. An item with no
--- maturation (base growth 0, or a legacy item) is matured from the start.
function EconomyService.isMatured(item: DataService.DisplayItem): boolean
	local needed = tonumber(item.MaturationSeconds) or 0
	if needed <= 0 then
		return true
	end
	return (tonumber(item.GrowthSeconds) or 0) >= needed
end

--- Seconds until an item starts earning, 0 when it already does.
function EconomyService.maturationRemaining(item: DataService.DisplayItem): number
	local needed = tonumber(item.MaturationSeconds) or 0
	return math.max(0, needed - (tonumber(item.GrowthSeconds) or 0))
end

--- The item's rate for THIS owner, boosts included: what it adds to the
--- total while active. Zero while maturing or being robbed.
function EconomyService.itemRate(player: Player, item: DataService.DisplayItem): number
	-- A SEALED CONTAINER EARNS NOTHING. The reward is not the player's until
	-- it has been hatched, so an incubating - or ready but unopened - container
	-- contributes exactly zero to the rate, and the first income it ever pays
	-- is paid after HatchService.commit flips this flag.
	if item.Hatched == false then
		return 0
	end
	if item.RobbedBy or not EconomyService.isMatured(item) then
		return 0
	end
	local scale = ScaleConfig.clampScale(item.Scale)
	local pre = RarityConfig.preBoostRate(item.BaseIncome, scale, item.Mutation, EconomyService.cashMultiplierFor(player))
	return math.round(pre * GameConfig.SERVER_EARNINGS_BOOST * GameConfig.TEMPORARY_EARNINGS_BOOST)
end

--- Recomputes the player's $/s from their placed trophies. Call after any
--- placement, sale, maturation step or permanent multiplier change - never
--- on a timer.
function EconomyService.recalculate(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		incomePerSecond[player] = 0
		return 0
	end

	local total = 0
	for _, item in profile.DisplayItems do
		total += EconomyService.itemRate(player, item)
	end

	incomePerSecond[player] = total
	notify(player)
	return total
end

function EconomyService.getIncome(player: Player): number
	return incomePerSecond[player] or 0
end

function EconomyService.getCash(player: Player): number
	local profile = DataService.get(player)
	return if profile then profile.Cash else 0
end

-- ==========================================================
-- CASH MUTATION
-- ==========================================================

local function tally(player: Player, source: string, amount: number)
	local bucket = awardedBySource[player]
	if not bucket then
		bucket = {}
		awardedBySource[player] = bucket
	end
	bucket[source] = (bucket[source] or 0) + amount
end

--- Pays EXACTLY `amount`. Never multiplied by anything.
---
--- Use this for a value that is already final: the passive tick (whose rate
--- `recalculate` has already multiplied), the offline claim (captured from
--- that same rate) and Robux Cash packs (face value - doubling a purchased
--- pack hands the player more than the pack advertises).
function EconomyService.award(player: Player, amount: number, source: CashSource?)
	if amount <= 0 then
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return
	end
	profile.Cash += amount
	profile.Lifetime.CashEarned += amount
	tally(player, source or "other", amount)
	notify(player)
end

--- Pays `amount` scaled by the 2x Cash pass. Use for one-off GAMEPLAY
--- EARNINGS that are not derived from the aggregate rate - selling a trophy,
--- a discovery reward. The pass is applied here EXACTLY ONCE: the amounts
--- these callers pass in are computed at moneyPass 1.
function EconomyService.earn(player: Player, amount: number, source: CashSource?)
	if amount <= 0 then
		return
	end
	EconomyService.award(player, math.floor(amount * EconomyService.cashMultiplierFor(player)), source)
end

--- Atomic spend: returns false and changes nothing when the player cannot
--- afford it. Callers must treat false as "purchase did not happen".
function EconomyService.spend(player: Player, amount: number): boolean
	if amount < 0 then
		return false
	end
	local profile = DataService.get(player)
	if not profile or profile.Cash < amount then
		return false
	end
	profile.Cash -= amount
	notify(player)
	return true
end

--- Cash awarded this session by source, for the parity tool.
function EconomyService.awardedBySource(player: Player): { [string]: number }
	return table.clone(awardedBySource[player] or {})
end

function EconomyService.start()
	Players.PlayerRemoving:Connect(function(player)
		incomePerSecond[player] = nil
		awardedBySource[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(GameConfig.INCOME_TICK)
			for _, player in Players:GetPlayers() do
				local income = incomePerSecond[player]
				if income and income > 0 then
					EconomyService.award(player, income * GameConfig.INCOME_TICK, "passive")
				end
			end
		end
	end)
end

return EconomyService
