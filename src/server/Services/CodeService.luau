--!strict
--[[
	CodeService
	Redeemable codes (CodesConfig), typed into the CODES box on the Settings
	panel.

	THE CONTRACT
	  client -> RedeemCodeRequest(text)
	  server -> RedeemCodeResult(ok, message)   for the box
	            Notify(kind, message)           the usual toast
	The client sends only the text. Which code it is, whether it may be used
	and what it pays are all decided here.

	CHECKS, IN ORDER
	  1. Lockout: too many failed attempts recently -> "Too many attempts".
	  2. Rate limit: a token bucket, 5 a minute (CodesConfig).
	  3. Shape: CodesConfig.normalise (string, trimmed, letters/digits, short).
	  4. Exists and enabled, else "invalid" - a disabled code is
	     indistinguishable from one that never existed.
	  5. Not expired (CodesConfig expiresAt, UTC unix).
	  6. Not already redeemed by this profile (Profile.RedeemedCodes).
	  7. The player's HighestZoneReached meets minZone.
	Failures at 3-7 count toward the lockout; a rate-limited request does not
	(it was never looked at).

	PAYING, EXACTLY ONCE
	The code is written into RedeemedCodes BEFORE anything is paid, in the
	same non-yielding step as the checks, so a second request can never pass
	check 6. The payout (RetentionRewards.grant) runs under pcall; if it throws,
	the mark is taken back so the player can try again. The profile is then
	pushed and saved.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CodesConfig = require(ReplicatedStorage.Shared.Config.CodesConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DataService = require(script.Parent.DataService)
local RetentionRewards = require(script.Parent.RetentionRewards)
local StateService = require(script.Parent.StateService)

local CodeService = {}

export type Outcome = "ok" | "invalid" | "expired" | "redeemed" | "zone" | "limited" | "locked" | "loading" | "error"

local limiter = RateLimiter.new(CodesConfig.ATTEMPTS_PER_SECOND, CodesConfig.ATTEMPT_BURST)

--- Failed attempts per UserId (os.time stamps, oldest first) and the unix
--- second each lockout ends. Keyed by UserId, not Player, and kept for the
--- life of the server, so leaving and rejoining does not reset either.
local failures: { [number]: { number } } = {}
local lockedUntil: { [number]: number } = {}

--- A redemption in progress for this player (the save yields).
local busy: { [Player]: boolean } = {}

local function formatWait(seconds: number): string
	local s = math.max(1, math.ceil(seconds))
	if s < 60 then
		return `{s}s`
	end
	return `{math.ceil(s / 60)} min`
end

local function pruneFailures(userId: number, now: number): { number }
	local list = failures[userId]
	if not list then
		list = {}
		failures[userId] = list
	end
	while #list > 0 and now - list[1] > CodesConfig.FAILURE_WINDOW do
		table.remove(list, 1)
	end
	return list
end

local function recordFailure(player: Player, now: number)
	local list = pruneFailures(player.UserId, now)
	table.insert(list, now)
	if #list >= CodesConfig.FAILURE_LIMIT then
		lockedUntil[player.UserId] = now + CodesConfig.LOCKOUT_SECONDS
		table.clear(list)
	end
end

--- The code's state for this player, without paying. Used by redeem and by
--- the debug listing.
function CodeService.check(player: Player, def: CodesConfig.CodeDef, key: string, now: number): (Outcome, string)
	if not def.enabled then
		return "invalid", "That code is invalid."
	end
	if def.expiresAt and now >= def.expiresAt then
		return "expired", "That code has expired."
	end
	local profile = DataService.get(player)
	if not profile then
		return "loading", "Your data is still loading - try again in a moment."
	end
	if profile.RedeemedCodes[key] ~= nil then
		return "redeemed", "You already redeemed that code."
	end
	if def.minZone and profile.HighestZoneReached < def.minZone then
		return "zone", `Reach Zone {def.minZone} to use that code.`
	end
	return "ok", ""
end

--- Redeems `raw` for `player`. `skipLimits` is for the debug bridge only
--- (the rate limiter and lockout are bypassed; every other check runs).
--- Returns the outcome and the player-facing message.
function CodeService.redeem(player: Player, raw: any, skipLimits: boolean?): (Outcome, string)
	local now = os.time()
	if not skipLimits then
		local lockEnds = lockedUntil[player.UserId]
		if lockEnds and now < lockEnds then
			return "locked", `Too many attempts - try again in {formatWait(lockEnds - now)}.`
		end
		if not limiter:consume(player) then
			return "limited", "Too many attempts - slow down a little."
		end
	end
	if busy[player] then
		return "limited", "Hold on - still redeeming your last code."
	end

	local key = CodesConfig.normalise(raw)
	local def = if key then CodesConfig.ByCode[key] else nil
	if not key or not def then
		if not skipLimits then
			recordFailure(player, now)
		end
		return "invalid", "That code is invalid."
	end

	local outcome: Outcome, message: string = CodeService.check(player, def, key, now)
	if outcome ~= "ok" then
		if not skipLimits and outcome ~= "loading" then
			recordFailure(player, now)
		end
		return outcome, message
	end
	local profile = DataService.get(player)
	if not profile then
		return "loading", "Your data is still loading - try again in a moment."
	end

	-- Marked FIRST (nothing above yielded), so a racing request fails check 6.
	profile.RedeemedCodes[key] = now
	busy[player] = true
	local ok, paid = pcall(RetentionRewards.grant, player, profile, def.rewards :: any, "code" :: any)
	if not ok then
		profile.RedeemedCodes[key] = nil
		busy[player] = nil
		warn(`[CodeService] payout of {key} failed for {player.Name}: {paid}`)
		return "error", "Something went wrong - please try again."
	end

	StateService.pushNow(player)
	-- Durable before the player is told: a crash inside the autosave window
	-- must not leave the code unmarked with the reward already shown.
	if DataService.isPersistent() then
		local saved, err = pcall(DataService.save, player)
		if not saved then
			warn(`[CodeService] save after {key} failed for {player.Name}: {err}`)
		end
	end
	busy[player] = nil
	require(script.Parent.ProgressEvents).fire(player, "codeRedeemed", 1, { code = key }) -- [analytics-discord]
	print(`[CodeService] {player.Name} redeemed {key}: {RetentionRewards.describe(paid)}`)
	return "ok", `Code {key} redeemed: {RetentionRewards.describe(paid)}!`
end

--- STUDIO ONLY (debug bridge): clears a player's lockout and failure count.
function CodeService.debugResetLimits(player: Player)
	lockedUntil[player.UserId] = nil
	failures[player.UserId] = nil
	limiter:release(player)
end

function CodeService.start()
	local result = Remotes.get("RedeemCodeResult")
	Remotes.get("RedeemCodeRequest").OnServerEvent:Connect(function(player, raw)
		-- Anything that is not a string is a probe: no reply, but it still
		-- spends a token so it cannot be spammed for free.
		if type(raw) ~= "string" then
			limiter:consume(player)
			return
		end
		local outcome, message = CodeService.redeem(player, raw)
		local ok = outcome == "ok"
		result:FireClient(player, ok, message)
		if ok then
			StateService.notify(player, "success", message, "levelup")
			StateService.sound(player, "UpgradePurchase")
		else
			StateService.notify(player, "error", message)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
		busy[player] = nil
	end)

	-- Old failure records are dropped now and then; lockouts that ended too.
	task.spawn(function()
		while true do
			task.wait(CodesConfig.FAILURE_WINDOW)
			local now = os.time()
			for userId in failures do
				if #pruneFailures(userId, now) == 0 then
					failures[userId] = nil
				end
			end
			for userId, lockEnds in lockedUntil do
				if now >= lockEnds then
					lockedUntil[userId] = nil
				end
			end
		end
	end)

	print(`[CodeService] {#CodesConfig.Codes} code(s) configured`)
end

return CodeService
