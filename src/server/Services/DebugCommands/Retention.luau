--!strict
--[[
	Studio debug commands for codes and the daily login streak
	(retention-codes-daily). Loaded by DebugService in Studio only.

	SAFETY. Studio writes to the owner's REAL DataStore. Every command that
	changes the profile snapshots what it can touch (Cash, lifetime Cash,
	Speed, redeemed codes, the streak, won guardians and the equipped one)
	and restores it in a `finally` step that runs even when the test throws,
	then saves. A guardian granted during a test is taken back out of
	GuardiansWon and the bay is re-synced.
	(The real claim / redeem paths save mid-test too; only a Studio crash in
	the second between that save and the restore could keep test values.)

	    DebugInvoke:Invoke("retentionCodes")                         list codes + your status
	    DebugInvoke:Invoke("retentionRedeem", "<you>", "MUSEUM")     redeem as you, twice, then roll back
	    DebugInvoke:Invoke("retentionDaily", "<you>")                the streak state + 7-day preview
	    DebugInvoke:Invoke("retentionDailySim", "<you>", "newday")   claim on a new day, claim again, roll back
	    DebugInvoke:Invoke("retentionDailySim", "<you>", "missed")   a missed day resets to day 1
	    DebugInvoke:Invoke("retentionDailySim", "<you>", "week")     claim days 1-7 in a row (day 7 guardian)
	    DebugInvoke:Invoke("retentionDailyClock", "<you>", 86400)    shift YOUR clock (UI test; 0 clears)
	    DebugInvoke:Invoke("retentionResetLimits", "<you>")          clear the code lockout
]]

local Services = script.Parent.Parent
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CodesConfig = require(ReplicatedStorage.Shared.Config.CodesConfig)
local DailyRewardConfig = require(ReplicatedStorage.Shared.Config.DailyRewardConfig)

local BaseGuardianService = require(Services.BaseGuardianService)
local CodeService = require(Services.CodeService)
local DailyRewardService = require(Services.DailyRewardService)
local DataService = require(Services.DataService)
local SpeedService = require(Services.SpeedService)
local StateService = require(Services.StateService)

type Snapshot = {
	cash: number,
	cashEarned: number,
	speed: number,
	redeemed: { [string]: number },
	streak: number,
	lastDay: number,
	guardiansWon: { [string]: boolean },
	equipped: string,
}

local function snapshot(profile: DataService.Profile): Snapshot
	return {
		cash = profile.Cash,
		cashEarned = profile.Lifetime.CashEarned,
		speed = profile.SpeedPower,
		redeemed = table.clone(profile.RedeemedCodes),
		streak = profile.DailyStreak,
		lastDay = profile.DailyLastClaimDay,
		guardiansWon = table.clone(profile.GuardiansWon),
		equipped = profile.EquippedGuardian,
	}
end

local function restore(player: Player, profile: DataService.Profile, saved: Snapshot): { [string]: any }
	local report = {
		cashDelta = profile.Cash - saved.cash,
		speedDelta = profile.SpeedPower - saved.speed,
		guardiansAdded = {} :: { string },
		saved = nil :: boolean?,
	}
	for key in profile.GuardiansWon do
		if not saved.guardiansWon[key] then
			table.insert(report.guardiansAdded, key)
		end
	end
	profile.Cash = saved.cash
	profile.Lifetime.CashEarned = saved.cashEarned
	profile.SpeedPower = saved.speed
	profile.RedeemedCodes = saved.redeemed
	profile.DailyStreak = saved.streak
	profile.DailyLastClaimDay = saved.lastDay
	-- GuardiansWon is only ever added to in play; a test is the one place it
	-- is put back, because the test granted it.
	profile.GuardiansWon = saved.guardiansWon
	profile.EquippedGuardian = saved.equipped
	pcall(BaseGuardianService.sync, player)
	pcall(SpeedService.applyMovement, player)
	DailyRewardService.debugSetClockOffset(player, 0)
	StateService.pushNow(player)
	if DataService.isPersistent() then
		report.saved = DataService.save(player)
	end
	return report
end

--- Runs `body` against a snapshot and always restores it.
local function withRollback(player: Player, body: (DataService.Profile) -> any): any
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile loaded" }
	end
	local saved = snapshot(profile)
	local ok, result = pcall(body, profile)
	local restored = restore(player, profile, saved)
	return {
		ok = ok,
		result = if ok then result else tostring(result),
		restored = restored,
	}
end

local function statusTable(player: Player): any
	local status = DailyRewardService.status(player)
	return if status then table.clone(status :: any) else nil
end

return {
	--- retentionCodes: every configured code and what it would say to you.
	retentionCodes = function(player: Player): any
		local now = os.time()
		local rows = {}
		for _, def in CodesConfig.Codes do
			local key = CodesConfig.normalise(def.code) or def.code
			local outcome, message = CodeService.check(player, def, key, now)
			table.insert(rows, {
				code = key,
				enabled = def.enabled,
				expiresAt = def.expiresAt,
				minZone = def.minZone,
				note = def.note,
				forYou = outcome,
				message = message,
			})
		end
		return rows
	end,

	--- retentionRedeem <code>: redeems as the caller (limits bypassed), tries
	--- the same code again (must be refused), then rolls everything back.
	retentionRedeem = function(player: Player, code: any): any
		local text = if type(code) == "string" then code else "MUSEUM"
		return withRollback(player, function(profile)
			local before = { cash = profile.Cash, speed = profile.SpeedPower }
			local first, firstMessage = CodeService.redeem(player, text, true)
			local afterFirst = { cash = profile.Cash, speed = profile.SpeedPower }
			local second, secondMessage = CodeService.redeem(player, text, true)
			return {
				first = first,
				firstMessage = firstMessage,
				paidCash = afterFirst.cash - before.cash,
				paidSpeed = afterFirst.speed - before.speed,
				second = second,
				secondMessage = secondMessage,
				secondPaidNothing = profile.Cash == afterFirst.cash and profile.SpeedPower == afterFirst.speed,
				-- For a code that SHOULD work. For "BETATEST" (disabled) expect
				-- first = "invalid" and passed = false.
				passed = first == "ok" and second == "redeemed" and profile.Cash == afterFirst.cash,
			}
		end)
	end,

	--- retentionDaily: the streak state and the 7-day preview.
	retentionDaily = function(player: Player): any
		local profile = DataService.get(player)
		return {
			ready = DailyRewardService.debugIsReady(player),
			saved = if profile then { streak = profile.DailyStreak, lastClaimDay = profile.DailyLastClaimDay } else nil,
			today = DailyRewardConfig.dayNumber(os.time()),
			status = statusTable(player),
			preview = DailyRewardService.preview(player),
		}
	end,

	--- retentionDailySim <newday|missed|week>: claims under a rewritten
	--- streak, then rolls back.
	retentionDailySim = function(player: Player, mode: any): any
		local today = DailyRewardConfig.dayNumber(os.time())
		local which = if type(mode) == "string" then mode else "newday"
		return withRollback(player, function(profile)
			if which == "week" then
				-- Seven consecutive days, starting fresh. Each claim is made
				-- "yesterday" relative to the next by rewinding the saved day.
				profile.DailyStreak = 0
				profile.DailyLastClaimDay = 0
				local claims = {}
				for step = 1, DailyRewardConfig.CYCLE_DAYS do
					local cash, speed = profile.Cash, profile.SpeedPower
					local ok, message = DailyRewardService.claim(player)
					table.insert(claims, {
						step = step,
						ok = ok,
						message = message,
						streak = profile.DailyStreak,
						cash = profile.Cash - cash,
						speed = profile.SpeedPower - speed,
					})
					profile.DailyLastClaimDay = today - 1
				end
				local passed = true
				for step, row in claims do
					passed = passed and row.ok and row.streak == step
				end
				return { claims = claims, guardiansWon = table.clone(profile.GuardiansWon), passed = passed }
			end

			local expectedDay: number
			if which == "missed" then
				-- Streak 3, last claim beyond the grace window: back to day 1.
				profile.DailyStreak = 3
				profile.DailyLastClaimDay = today - 2 - DailyRewardConfig.GRACE_DAYS
				expectedDay = 1
			else
				-- Streak 3, claimed yesterday: day 4 today.
				profile.DailyStreak = 3
				profile.DailyLastClaimDay = today - 1
				expectedDay = 4
			end
			local before = statusTable(player)
			local cash, speed = profile.Cash, profile.SpeedPower
			local ok, message = DailyRewardService.claim(player)
			local paid = { cash = profile.Cash - cash, speed = profile.SpeedPower - speed }
			local again, againMessage = DailyRewardService.claim(player)
			return {
				mode = which,
				before = before,
				claimed = ok,
				message = message,
				paid = paid,
				streakAfter = profile.DailyStreak,
				secondClaim = again,
				secondMessage = againMessage,
				passed = ok and before ~= nil and before.day == expectedDay and not again and profile.DailyStreak == (if which == "missed" then 1 else 4),
			}
		end)
	end,

	--- retentionDailyClock <seconds>: shifts only THIS player's streak clock
	--- (no saved field changes) so the panel, countdown and HUD dot can be
	--- checked across a "midnight". A claim made while shifted IS real and
	--- is saved - use retentionDailySim for claims. 0 clears the shift.
	retentionDailyClock = function(player: Player, seconds: any): any
		local offset = tonumber(seconds) or 0
		DailyRewardService.debugSetClockOffset(player, offset)
		return { offset = offset, status = statusTable(player) }
	end,

	--- retentionResetLimits: clears your code lockout and rate limit.
	retentionResetLimits = function(player: Player): any
		CodeService.debugResetLimits(player)
		return { cleared = true }
	end,
}
