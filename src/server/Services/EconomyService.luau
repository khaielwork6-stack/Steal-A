--!strict
--[[
	EconomyService
	Aggregate passive income and all Cash mutation (GDD section 8).

	Income architecture rule: do NOT run a loop per displayed item. The total is
	recalculated only when a display changes, and one heartbeat grants the
	aggregate once per second.

	Every Cash change in the game goes through award/spend here so there is a
	single place that can never go negative.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local IndexConfig = require(ReplicatedStorage.Shared.Config.IndexConfig)
local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local DataService = require(script.Parent.DataService)

local EconomyService = {}

local incomePerSecond: { [Player]: number } = {}
local listeners: { (Player) -> () } = {}

--- Fires whenever Cash or income changes so StatePush can replicate.
function EconomyService.onChanged(callback: (Player) -> ())
	table.insert(listeners, callback)
end

local function notify(player: Player)
	for _, callback in listeners do
		task.spawn(callback, player)
	end
end

--- Recomputes the player's $/s from their placed trophies. Call after any
--- placement, sale, or permanent multiplier change - never on a timer.
function EconomyService.recalculate(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		incomePerSecond[player] = 0
		return 0
	end

	local total = 0
	for _, item in profile.DisplayItems do
		-- Maturity. A trophy that has been on display for a while earns a
		-- little more (NightConfig.GROWTH_INCOME_BONUS at full growth). Applied
		-- to the AGGREGATE from the saved growth seconds, so the item's own
		-- FinalIncome stays the config value and nothing is baked into the save.
		local growth = math.clamp((tonumber(item.GrowthSeconds) or 0) / NightConfig.GROWTH_FULL_SECONDS, 0, 1)
		total += item.FinalIncome * (1 + NightConfig.GROWTH_INCOME_BONUS * growth)
	end
	total = math.floor(total)

	-- Completed Index sets. Reading it from the config keeps the reward defined in
	-- one place, and applying it here means it lands on the aggregate rather than
	-- on each item's frozen FinalIncome - so a claim never rewrites saved data.
	total = math.floor(total * IndexConfig.incomeMultiplier(profile.ClaimedIndexRewards))

	-- The 2x Cash gamepass is applied HERE as well as in `award`, deliberately.
	-- The HUD renders this number, and the passive tick pays `award(income)` -
	-- so if the pass doubled the payout but not this, the game would be back to
	-- displaying one rate and paying another, which is the exact class of bug
	-- this economy was last fixed for. One multiplier, both sides.
	total = math.floor(total * EconomyService.cashMultiplierFor(player))

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

--- THE 2X CASH GAMEPASS LIVES IN EXACTLY TWO PLACES, and they must agree:
---   * `recalculate`, so the HUD's $/s already includes it, and
---   * `earn`, for one-off gameplay payouts that do not come from that rate.
---
--- Overridden by init so this service need not require MonetizationService.
--- Returns 1 until ownership has been warmed, which is the safe direction: a
--- missed double is recoverable, a doubled purchase is not.
function EconomyService.cashMultiplierFor(_player: Player): number
	return 1
end

--- Pays EXACTLY `amount`. Never multiplied by anything.
---
--- Use this for a value that is already final: the passive tick (whose rate
--- `recalculate` has already multiplied) and Robux Cash packs (which must grant
--- their face value - doubling a purchased pack hands the player more than the
--- pack advertises and quietly devalues the pass itself).
function EconomyService.award(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return
	end
	profile.Cash += amount
	profile.Lifetime.CashEarned += amount
	notify(player)
end

--- Pays `amount` scaled by the 2x Cash pass. Use for GAMEPLAY EARNINGS that are
--- not derived from the aggregate rate - selling a trophy, an Index claim.
function EconomyService.earn(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	EconomyService.award(player, math.floor(amount * EconomyService.cashMultiplierFor(player)))
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

function EconomyService.start()
	Players.PlayerRemoving:Connect(function(player)
		incomePerSecond[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(GameConfig.INCOME_TICK)
			for _, player in Players:GetPlayers() do
				local income = incomePerSecond[player]
				if income and income > 0 then
					EconomyService.award(player, income * GameConfig.INCOME_TICK)
				end
			end
		end
	end)
end

return EconomyService
