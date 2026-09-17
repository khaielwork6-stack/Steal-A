--!strict
--[[
	OfflineService
	Cash earned while away, capped at six hours, claimed once.

	HOW IT WORKS
	  * Every save (autosave, leave, shutdown) stamps the profile with the
	    server clock and the player's AUTHORITATIVE $/s at that moment - the
	    same rate the HUD shows and the passive tick pays, permanent
	    multipliers included (EconomyService.getIncome).
	  * On the next load, once the profile AND the income have been rebuilt,
	    the absence is measured ONCE against os.time(), clamped to 0..6h, and
	    rate x seconds is added to a pending claim. The timestamp is then
	    advanced to now, so a reconnect measures a fresh (tiny) absence, never
	    the same one twice.
	  * The client is told the pending amount on StatePush and can only ASK to
	    claim it. The server pays exactly what it is holding, zeroes it, and
	    pushes. A second click, a spammed remote, or a rejoin finds nothing to
	    pay. Leaving before claiming keeps the pending amount for next time.

	WHAT IT WILL NOT DO
	  * Pay a player who has never left (timestamp 0).
	  * Trust anything from the client: no rate, no time, no amount.
	  * Talk to a DataStore itself - it rides DataService's save.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local StateService = require(script.Parent.StateService)

local OfflineService = {}

local claimLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.OfflineClaimRequest)

--- Players whose absence has been settled this session. Belt and braces on
--- top of the advanced timestamp: the settlement runs exactly once per join
--- however many times the profile-ready hooks fire.
local settled: { [Player]: boolean } = {}

--- round3-ui-rewards: the absence (seconds, already capped) measured this
--- session, for the WELCOME BACK popup's "You were away 2h 14m" line. Session
--- memory only - a pending amount carried over from an earlier session simply
--- shows no away line.
local awaySeconds: { [Player]: number } = {}

--- Stamps the departure clock and rate. Called from DataService's before-save
--- hook, so it covers autosave, PlayerRemoving and BindToClose without three
--- separate paths.
---
--- NOT BEFORE THE ABSENCE IS SETTLED. A save can happen before `settle` runs
--- (a receipt or a spin landing in the first seconds of a join); stamping
--- then would overwrite LastLeaveTimestamp with "now" and the away time the
--- player is owed would be gone before it was ever measured.
---
--- The rate is EconomyService's cached income, which stays valid through the
--- leave-save: EconomyService clears it in DataService.onAfterRelease, after
--- that save, not on its own PlayerRemoving (whose order is not guaranteed).
function OfflineService.stamp(player: Player, profile: DataService.Profile)
	if not settled[player] then
		return
	end
	profile.LastLeaveTimestamp = os.time()
	profile.OfflineCashRate = math.max(0, math.floor(EconomyService.getIncome(player)))
end

--- Measures the absence once and banks the capped payout as a pending claim.
--- Safe to call repeatedly; only the first call per session does anything.
function OfflineService.settle(player: Player)
	if settled[player] then
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return
	end
	settled[player] = true

	local now = os.time()
	local left = profile.LastLeaveTimestamp
	local rate = profile.OfflineCashRate

	-- Never left, or a corrupt clock: nothing is owed. Negative elapsed time
	-- (skew) clamps to zero the same way.
	if left > 0 and rate > 0 then
		local offlineSeconds = math.clamp(now - left, 0, GameConfig.OFFLINE_EARNINGS_MAX_SECONDS)
		-- OFFLINE_EFFICIENCY is the share of the live rate paid per offline
		-- second (GameConfig): 0.25, the owner's choice of 2026-09-17.
		local offlineCash = math.floor(rate * offlineSeconds * GameConfig.OFFLINE_EFFICIENCY)
		if offlineCash > 0 then
			-- The six-hour cap covers the WAITING total too, not just this
			-- absence: a player who leaves again before claiming would
			-- otherwise stack one capped window per rejoin. The pending sum
			-- never exceeds one full window at the current rate, and an
			-- amount already held (perhaps earned at a higher rate) is
			-- never reduced. (round3-gameplay)
			local window = math.floor(rate * GameConfig.OFFLINE_EARNINGS_MAX_SECONDS * GameConfig.OFFLINE_EFFICIENCY)
			local held = profile.PendingOfflineCash
			profile.PendingOfflineCash = math.max(held, math.min(held + offlineCash, window))
			awaySeconds[player] = offlineSeconds
			print(`[OfflineService] {player.Name} away {offlineSeconds}s at ${rate}/s -> +${profile.PendingOfflineCash - held} pending`)
		end
	end

	-- The absence is consumed. From here the clock runs from now, and the
	-- rate is whatever they are earning in THIS session.
	profile.LastLeaveTimestamp = now
	profile.OfflineCashRate = math.max(0, math.floor(EconomyService.getIncome(player)))
	StateService.markDirty(player)
end

--- What StatePush carries: the amount waiting, or 0.
function OfflineService.summarise(player: Player): number
	local profile = DataService.get(player)
	return if profile then math.max(0, math.floor(profile.PendingOfflineCash)) else 0
end

--- StatePush `offlineAway`: the capped seconds away behind the pending
--- amount, or nil (nothing pending, or not measured this session).
function OfflineService.summariseAway(player: Player): number?
	if OfflineService.summarise(player) <= 0 then
		return nil
	end
	return awaySeconds[player]
end

--- Pays the pending amount - exactly once, exactly what is held.
function OfflineService.claim(player: Player): (boolean, string?)
	if not claimLimiter:consume(player) then
		return false, "Slow down!"
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local amount = math.max(0, math.floor(profile.PendingOfflineCash))
	if amount <= 0 then
		return false
	end
	-- Zero FIRST, then pay: if anything below throws, the worst case is an
	-- unpaid claim rather than a doubled one.
	profile.PendingOfflineCash = 0
	awaySeconds[player] = nil
	-- `award`, not `earn`: the rate that produced this already carried the
	-- 2x Cash pass (EconomyService.recalculate applies it), so multiplying
	-- again here would double-dip.
	EconomyService.award(player, amount, "offline")
	StateService.pushNow(player)
	-- Make the payout durable straight away; a crash inside the autosave
	-- window must not hand it out again on the next join.
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return true
end

--- STUDIO ONLY (DebugService "offline" command). Rewrites the departure
--- stamp as if the player had left `secondsAway` ago earning `rate`, forgets
--- that this session was settled, and settles again - so the six-hour cap,
--- the never-left case and the double-claim can be exercised without waiting.
function OfflineService.debugSimulate(player: Player, secondsAway: number, rate: number): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	profile.LastLeaveTimestamp = if secondsAway < 0 then 0 else os.time() - math.floor(secondsAway)
	profile.OfflineCashRate = math.max(0, math.floor(rate))
	settled[player] = nil
	OfflineService.settle(player)
	StateService.pushNow(player)
	return profile.PendingOfflineCash
end

function OfflineService.start()
	DataService.onBeforeSave(OfflineService.stamp)
	StateService.addProvider("offlineCash", OfflineService.summarise)
	StateService.addProvider("offlineAway", OfflineService.summariseAway)

	Remotes.get("OfflineClaimRequest").OnServerEvent:Connect(function(player)
		local ok, reason = OfflineService.claim(player)
		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
	end)

	-- AFTER the leave-save, not on PlayerRemoving: the leave-save's stamp is
	-- skipped for a player who is not marked settled, so clearing the mark
	-- first (handler order is not guaranteed) would lose the departure time.
	DataService.onAfterRelease(function(player)
		settled[player] = nil
		awaySeconds[player] = nil
	end)
	Players.PlayerRemoving:Connect(function(player)
		claimLimiter:release(player)
	end)

	print("[OfflineService] offline earnings online (cap 6h)")
end

return OfflineService
