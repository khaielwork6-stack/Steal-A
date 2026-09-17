--!strict
--[[
	Studio debug commands for the reward reveals (round3-ui-rewards): open the
	DAILY REWARDS calendar or the WELCOME BACK popup on FAKE figures, for
	screenshots and animation checks. Loaded by DebugService in Studio only.

	NOTHING HERE TOUCHES THE PROFILE. The server only reads the player's real
	7-day preview (for realistic amounts) and fires RewardsUIPreview to that
	one client. A CLAIM pressed in a preview plays the whole moment locally
	and sends no request; closing the panel drops the fake figures.

	    DebugInvoke:Invoke("rewardsUiDaily", "<you>")                today = day 3 (claimable)
	    DebugInvoke:Invoke("rewardsUiDaily", "<you>", "today", 5)     today = day 5 (claimable)
	    DebugInvoke:Invoke("rewardsUiDaily", "<you>", "claimed", 4)   day 4 already claimed, timer running
	    DebugInvoke:Invoke("rewardsUiDaily", "<you>", "grand")        day 7 GRAND PRIZE claimable
	    DebugInvoke:Invoke("rewardsUiDaily", "<you>", "fresh")        streak 0, day 1 claimable
	    DebugInvoke:Invoke("rewardsUiDaily", "<you>", "done")         whole week claimed (day 7 today)
	    DebugInvoke:Invoke("rewardsUiOffline", "<you>")               $473M, away 2h 14m
	    DebugInvoke:Invoke("rewardsUiOffline", "<you>", 1.2e9, 30000) $1.2B, away past the 6h cap
	    DebugInvoke:Invoke("rewardsUiOffline", "<you>", 5000, -1)     no away line (carried-over amount)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DailyRewardConfig = require(ReplicatedStorage.Shared.Config.DailyRewardConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DailyRewardService = require(script.Parent.Parent.DailyRewardService)

--- Stand-in amounts when the player's real preview is not available yet.
local function syntheticDays(): { any }
	local days = {}
	local cash = { 12500, 0, 48000, 0, 2.4e6, 0, 63.9e6 }
	local speed = { 0, 150, 0, 3000, 0, 42000, 500e3 }
	for index = 1, DailyRewardConfig.CYCLE_DAYS do
		local kind = if cash[index] > 0 and speed[index] > 0 then "mixed" elseif speed[index] > 0 then "speed" else "cash"
		table.insert(days, { day = index, kind = kind, cash = cash[index], speed = speed[index], text = "" })
	end
	return days
end

return {
	--- rewardsUiDaily [state] [day]: the calendar on fake figures.
	rewardsUiDaily = function(player: Player, state: any, day: any): any
		local mode = if type(state) == "string" then string.lower(state) else "today"
		local real = DailyRewardService.preview(player)
		local days = if real and type(real.days) == "table" then real.days else syntheticDays()
		local cycle = DailyRewardConfig.CYCLE_DAYS
		local pick = math.clamp(math.floor(tonumber(day) or 3), 1, cycle)

		local today, streak, claimable
		if mode == "claimed" then
			-- `pick` was claimed today; the next claim is tomorrow.
			streak, claimable = pick, false
			today = DailyRewardConfig.cycleDay(pick + 1)
		elseif mode == "done" then
			streak, claimable = cycle, false
			today = 1
		elseif mode == "grand" then
			today, streak, claimable = cycle, cycle - 1, true
		elseif mode == "fresh" then
			today, streak, claimable = 1, 0, true
		else
			mode = "today"
			today, streak, claimable = pick, pick - 1, true
		end

		local payload = {
			days = days,
			day = today,
			streak = streak,
			claimable = claimable,
			claimedToday = not claimable,
			nextResetAt = (DailyRewardConfig.dayNumber(os.time()) + 1) * DailyRewardConfig.SECONDS_PER_DAY,
			debugPreview = true,
		}
		Remotes.get("RewardsUIPreview"):FireClient(player, "daily", payload)
		return { mode = mode, day = today, streak = streak, claimable = claimable, realAmounts = real ~= nil }
	end,

	--- rewardsUiOffline [amount] [awaySeconds]: the WELCOME BACK popup on a
	--- fake amount. awaySeconds < 0 sends no away time.
	rewardsUiOffline = function(player: Player, amount: any, away: any): any
		local cash = math.max(1, math.floor(tonumber(amount) or 473e6))
		local seconds = tonumber(away) or (2 * 3600 + 14 * 60)
		local payload = {
			amount = cash,
			away = if seconds >= 0 then math.floor(seconds) else nil,
		}
		Remotes.get("RewardsUIPreview"):FireClient(player, "offline", payload)
		return payload
	end,
}
