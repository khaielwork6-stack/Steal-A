--!strict
--[[
	DailyRewardConfig
	The 7-day login streak (DailyRewardService / DailyRewardController).

	DAYS ARE UTC DAYS: `math.floor(os.time() / 86400)` on the server. One claim
	per UTC day. Claiming on the day after the last claim continues the streak;
	missing more than GRACE_DAYS whole days in between starts it again at day 1.
	After day 7 the cycle starts over at day 1 (the streak COUNT keeps going,
	it is shown to the player; the reward is picked by the day in the cycle).

	WHAT A DAY PAYS - the same reward fields as CodesConfig.Rewards:
	  cashMinutes / cashFloor              minutes of BASE income, with a floor
	  speedGateFraction / speedFloor /     share of the next zone's gate, with a
	  speedMax                             floor and a cap
	  guardianKey                          a base guardian (the spin wheel's
	                                       grant path); if the player already
	                                       owns it, `duplicate` is paid instead
	Amounts are computed at claim time from the player's progress, and the
	panel is sent the same figures (the preview is the payout).

	THE WALL. A whole week of Speed for a Zone 8 player (next gate 700M) is at
	most 100K + 150K + 250K (+ 500K if the guardian is already owned), about
	0.15% of the gate. The caps are what keep it there - do not remove them.
]]

local DailyRewardConfig = {}

export type Day = {
	day: number,
	cashMinutes: number?,
	cashFloor: number?,
	speedGateFraction: number?,
	speedFloor: number?,
	speedMax: number?,
	guardianKey: string?,
	--- What a guardian day pays when the player already owns the animal.
	duplicate: {
		speedGateFraction: number?,
		speedFloor: number?,
		speedMax: number?,
	}?,
	--- Card art (rbxassetid). "rbxassetid://0" = none; the card falls back to
	--- the pack's cash / speed icon. Codex fills these in
	--- (docs/codex-prompts/retention-codes-daily.md).
	icon: string,
}

DailyRewardConfig.CYCLE_DAYS = 7
DailyRewardConfig.SECONDS_PER_DAY = 86400

--- Whole UTC days that may be skipped without losing the streak. 0 = strict
--- (claim on consecutive days or start over); 1 = one missed day is forgiven.
DailyRewardConfig.GRACE_DAYS = 0

--- DailyRewardRequest limiter: sustained requests per second and burst.
DailyRewardConfig.REQUESTS_PER_SECOND = 1
DailyRewardConfig.REQUEST_BURST = 3

--- How often the server re-checks online players for a UTC day rollover (so
--- the claimable flag and the HUD dot flip without any other push).
DailyRewardConfig.ROLLOVER_CHECK_SECONDS = 20

--- The HUD button's icon and the placeholder that means "no art yet".
DailyRewardConfig.NO_ICON = "rbxassetid://0"
DailyRewardConfig.HUD_ICON = "rbxassetid://74169425678933"

DailyRewardConfig.Days = {
	{ day = 1, cashMinutes = 3, cashFloor = 500, icon = "rbxassetid://118237015540809" },
	{ day = 2, speedGateFraction = 0.004, speedFloor = 150, speedMax = 100e3, icon = "rbxassetid://76635701852767" },
	{ day = 3, cashMinutes = 5, cashFloor = 1500, icon = "rbxassetid://89001890281554" },
	{ day = 4, speedGateFraction = 0.006, speedFloor = 300, speedMax = 150e3, icon = "rbxassetid://133687516171997" },
	{ day = 5, cashMinutes = 10, cashFloor = 3000, icon = "rbxassetid://122784984039918" },
	{ day = 6, speedGateFraction = 0.01, speedFloor = 600, speedMax = 250e3, icon = "rbxassetid://83421894336494" },
	{
		day = 7,
		-- The week's big one: cash AND Speed together. Not a guardian - the
		-- Panda is a 399 R$ gamepass, and a free one every week would undercut
		-- it (lead's call, 2026-09-17; set guardianKey = "Panda" here to
		-- change that, and `duplicate` pays Speed to owners).
		cashMinutes = 20,
		cashFloor = 10000,
		speedGateFraction = 0.02,
		speedFloor = 2000,
		speedMax = 500e3,
		icon = "rbxassetid://0",
	},
} :: { Day }

--- The UTC day number for a unix time.
function DailyRewardConfig.dayNumber(unix: number): number
	return math.floor(unix / DailyRewardConfig.SECONDS_PER_DAY)
end

--- The cycle day (1..CYCLE_DAYS) for a streak count (1 = first claim).
function DailyRewardConfig.cycleDay(streak: number): number
	local n = math.max(1, math.floor(streak))
	return ((n - 1) % DailyRewardConfig.CYCLE_DAYS) + 1
end

export type Status = {
	--- The streak count the NEXT claim will record (1 after a reset).
	nextStreak: number,
	--- The cycle day of the next claim (today's, if claimable).
	day: number,
	claimable: boolean,
	claimedToday: boolean,
	--- The streak as it stands (0 if it has been broken or never started).
	streak: number,
	--- Unix second the next UTC day begins.
	nextResetAt: number,
}

--- Pure streak rules. `streak` / `lastDay` are the saved DailyStreak and
--- DailyLastClaimDay (0 = never claimed); `now` is os.time().
---
--- A lastDay in the FUTURE (a clock that went backwards) reads as "claimed
--- today": the safe direction is to wait, never to pay twice.
function DailyRewardConfig.status(streak: number, lastDay: number, now: number): Status
	local today = DailyRewardConfig.dayNumber(now)
	local nextResetAt = (today + 1) * DailyRewardConfig.SECONDS_PER_DAY
	local saved = math.max(0, math.floor(streak))
	if lastDay >= today and lastDay > 0 then
		local next = saved + 1
		return {
			nextStreak = next,
			day = DailyRewardConfig.cycleDay(next),
			claimable = false,
			claimedToday = true,
			streak = saved,
			nextResetAt = nextResetAt,
		}
	end
	local continues = lastDay > 0 and saved > 0 and (today - lastDay) <= 1 + DailyRewardConfig.GRACE_DAYS
	local next = if continues then saved + 1 else 1
	return {
		nextStreak = next,
		day = DailyRewardConfig.cycleDay(next),
		claimable = true,
		claimedToday = false,
		streak = if continues then saved else 0,
		nextResetAt = nextResetAt,
	}
end

return DailyRewardConfig
