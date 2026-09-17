--!strict
--[[
	Studio debug commands for the data area: the session lock, save
	coalescing and the mailbox. Loaded by DebugService in Studio only.

	SAFETY. Studio writes to the owner's REAL DataStore, so:
	  * the lock test never touches a player's key - it runs on a THROWAWAY
	    key in a separate store ("DebugLockTest_v1") and deletes it after;
	  * the coalescing burst only saves the profile as it already is (the
	    same thing an autosave does);
	  * the mailbox test takes exactly the Cash it paid back out (Cash and
	    lifetime Cash) and saves - even if it fails part-way. Its one mail id
	    stays in DeliveredMail on purpose (see the command).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local GameConfig = require(game:GetService("ReplicatedStorage").Shared.Config.GameConfig)

local Services = script.Parent.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local MailboxService = require(Services.MailboxService)

local LOCK_TEST_STORE = "DebugLockTest_v1"

return {
	--- dataLockTest: runs the session-lock rules against a throwaway key.
	--- Needs Studio API access. Returns every step and whether it behaved.
	dataLockTest = function(_player: Player): any
		if DataService.isStudioMemoryMode() then
			return { error = "no DataStore access in this session (enable Studio API access)" }
		end
		local api = DataService.debugLockApi()
		local target = DataStoreService:GetDataStore(LOCK_TEST_STORE)
		local testKey = "lock_test_" .. HttpService:GenerateGUID(false)
		local steps: { string } = {}
		local failures: { string } = {}
		local function expect(label: string, ok: boolean, detail: any?)
			local line = `{if ok then "PASS" else "FAIL"} {label}{if detail ~= nil then " (" .. tostring(detail) .. ")" else ""}`
			table.insert(steps, line)
			if not ok then
				table.insert(failures, line)
			end
		end
		local function stored(): any
			return target:GetAsync(testKey)
		end
		local function foreign(age: number)
			target:SetAsync(testKey, { Cash = 1, SessionLock = { JobId = "foreign-session", PlaceId = 0, At = os.time() - age } })
		end

		local ran, err = pcall(function()
			-- A live foreign lock is respected...
			foreign(0)
			local outcome = api.claim(target, testKey, false)
			expect("a fresh foreign lock is held", outcome == "held", outcome)
			expect("a held claim wrote nothing", stored().SessionLock.JobId == "foreign-session")
			local written, rejected = api.writeGuarded(target, testKey, { Cash = 2 }, false)
			expect("a save under a foreign lock is refused", written == false and rejected == true)
			expect("the refused save wrote nothing", stored().Cash == 1, stored().Cash)

			-- ...until the wait runs out and it is taken over.
			local taken, document, holder = api.claim(target, testKey, true)
			expect("takeover claims the lock", taken == "taken" and holder == "foreign-session", holder)
			expect("takeover returns the stored data", type(document) == "table" and document.Cash == 1)
			expect("the lock is now ours", stored().SessionLock.JobId == api.sessionId)

			-- Our saves go through and refresh the stamp.
			written = api.writeGuarded(target, testKey, { Cash = 3 }, false)
			expect("our save is written", written == true and stored().Cash == 3)
			expect("our save keeps the lock", stored().SessionLock.JobId == api.sessionId)

			-- The release write stores the data AND clears the lock at once.
			written = api.writeGuarded(target, testKey, { Cash = 4 }, true)
			local after = stored()
			expect("the release save is written", written == true and after.Cash == 4)
			expect("the release save clears the lock", after.SessionLock == nil)

			-- After a release nothing more may be written by this session.
			written, rejected = api.writeGuarded(target, testKey, { Cash = 5 }, false)
			expect("a save after release is refused", written == false and rejected == true and stored().Cash == 4)

			-- A stale foreign lock is taken straight away.
			foreign(GameConfig.DATA_LOCK_STALE_SECONDS + 5)
			outcome = api.claim(target, testKey, false)
			expect("a stale foreign lock is taken without waiting", outcome == "taken")

			-- An unlocked document (an old save) is free.
			target:SetAsync(testKey, { Cash = 6 })
			outcome = api.claim(target, testKey, false)
			expect("an old unlocked save is claimed", outcome == "taken" and stored().Cash == 6)

			-- A missing key is created locked, as a default profile.
			target:RemoveAsync(testKey)
			outcome, document = api.claim(target, testKey, false)
			expect("a new key is created locked", outcome == "taken" and stored().SessionLock.JobId == api.sessionId)
			expect("a new key holds a default profile", type(document) == "table" and document.Cash == GameConfig.STARTING_CASH)
		end)
		-- The throwaway key is always removed.
		pcall(function()
			target:RemoveAsync(testKey)
		end)
		if not ran then
			table.insert(failures, `ERROR {err}`)
		end
		return { passed = #failures == 0, steps = steps, failures = failures, sessionId = api.sessionId }
	end,

	--- dataSaveBurst(count?): fires `count` (default 10) saves at once for the
	--- caller and reports how many DataStore writes they really cost. With
	--- coalescing that is 2 (the one in flight plus exactly one follow-up),
	--- and every caller must be told true.
	dataSaveBurst = function(player: Player, count: number?): any
		if DataService.isStudioMemoryMode() then
			return { error = "no DataStore access in this session (enable Studio API access)" }
		end
		if not DataService.get(player) then
			return { error = "no profile" }
		end
		local total = math.clamp(math.floor(tonumber(count) or 10), 2, 50)
		local before = DataService.debugWriteCount()
		local results: { boolean } = {}
		local remaining = total
		local started = os.clock()
		for index = 1, total do
			task.spawn(function()
				results[index] = DataService.save(player)
				remaining -= 1
			end)
		end
		local deadline = os.clock() + 30
		while remaining > 0 and os.clock() < deadline do
			task.wait(0.05)
		end
		local allTrue = true
		for index = 1, total do
			if results[index] ~= true then
				allTrue = false
			end
		end
		local writes = DataService.debugWriteCount() - before
		return {
			calls = total,
			finished = total - remaining,
			allReportedDurable = allTrue,
			writes = writes,
			passed = remaining == 0 and allTrue and writes <= 2,
			seconds = os.clock() - started,
		}
	end,

	--- dataMailTest: sends $1 to yourself through the mailbox, delivers it,
	--- checks it arrived exactly once, then takes the test Cash back out and
	--- saves.
	---
	--- Measured on the "debug" source tally rather than on Cash, so passive
	--- income landing during the test neither fails it nor gets thrown away
	--- by the restore.
	dataMailTest = function(player: Player): any
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local function debugTally(): number
			return EconomyService.awardedBySource(player).debug or 0
		end
		local tallyBefore = debugTally()
		local deliveredBefore = table.clone(profile.DeliveredMail)
		local report: { [string]: any } = {}

		local ran, err = pcall(function()
			report.sent = MailboxService.send(player.UserId, { kind = "cash", amount = 1, source = "debug", note = "mailbox test" })
			-- `send` starts a delivery for an online recipient; keep asking
			-- until the $1 shows up (or give up).
			local deadline = os.clock() + 15
			while debugTally() - tallyBefore < 1 and os.clock() < deadline do
				MailboxService.deliver(player)
				task.wait(0.5)
			end
			report.cashDelta = debugTally() - tallyBefore
			report.deliveredRecorded = #profile.DeliveredMail > #deliveredBefore
			-- A second pass must not pay again.
			MailboxService.deliver(player)
			task.wait(0.5)
			report.cashDeltaAfterSecondPass = debugTally() - tallyBefore
			local box = MailboxService.peek(player.UserId)
			report.mailboxLeft = if box then #box else "unreadable"
		end)

		-- RESTORE, whatever happened above: exactly what the test paid comes
		-- back out. The test entry's id is deliberately LEFT in DeliveredMail:
		-- if the mailbox removal failed, that id is what stops the entry being
		-- paid again later (one extra string in a capped list is harmless).
		local paid = debugTally() - tallyBefore
		profile.Cash = math.max(0, profile.Cash - paid)
		profile.Lifetime.CashEarned = math.max(0, profile.Lifetime.CashEarned - paid)
		local saved = if DataService.isPersistent() then DataService.save(player) else "memory mode"
		report.cashTakenBack = paid
		report.savedAfterRestore = saved

		if not ran then
			report.error = tostring(err)
		end
		report.passed = ran
			and report.sent == true
			and report.cashDelta == 1
			and report.cashDeltaAfterSecondPass == 1
			and report.deliveredRecorded == true
		return report
	end,

	--- dataStatus: what DataService thinks of the caller right now.
	dataStatus = function(player: Player)
		local profile = DataService.get(player)
		return {
			persistent = DataService.isPersistent(),
			studioMemoryMode = DataService.isStudioMemoryMode(),
			sessionLost = DataService.isSessionLost(player),
			loaded = profile ~= nil,
			sessionId = DataService.debugLockApi().sessionId,
			writesThisServer = DataService.debugWriteCount(),
			lastLeave = profile and profile.LastLeaveTimestamp,
			offlineRate = profile and profile.OfflineCashRate,
			deliveredMail = profile and #profile.DeliveredMail,
			sessionLockInMemory = profile and profile.SessionLock ~= nil,
		}
	end,
}
