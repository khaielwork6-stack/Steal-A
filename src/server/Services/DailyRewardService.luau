--!strict
--[[
	DailyRewardService
	The 7-day login streak (DailyRewardConfig).

	SAVED STATE (DataService, [retention-codes-daily])
	  DailyStreak        consecutive claims so far
	  DailyLastClaimDay  UTC day number of the last claim (0 = never)
	The rules live in DailyRewardConfig.status, a pure function of those two
	and os.time(): one claim per UTC day; the next day continues the streak;
	missing more than GRACE_DAYS whole days starts again at day 1.

	WHAT THE CLIENT GETS
	  StatePush `daily`   { day, streak, claimable, claimedToday, nextResetAt }
	                      - small, on every push. nil until the player is
	                      "ready" (below), which is what stops the panel
	                      popping before the join has settled.
	  DailyRewardPush     the 7-day preview with this player's real amounts,
	                      only on join, on request and after a claim (the
	                      amounts follow income, which changes every second,
	                      so they do not ride StatePush).
	The client asks with DailyRewardRequest("claim" | "preview").

	READY
	`onProfileReady` is called from init.server.luau's join block AFTER the
	offline settle and the first full push, exactly where the mailbox is
	delivered. Only then does the state field appear, so the panel can open
	once per session without racing the offline modal's first frame.

	CLAIMING, EXACTLY ONCE PER UTC DAY
	The streak and the claim day are written BEFORE the payout, in the same
	non-yielding step as the check, so a second request (or a second server,
	which the session lock already rules out) sees "claimed today". The
	payout runs under pcall and a throw rolls both fields back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local DailyRewardConfig = require(ReplicatedStorage.Shared.Config.DailyRewardConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DataService = require(script.Parent.DataService)
local RetentionRewards = require(script.Parent.RetentionRewards)
local StateService = require(script.Parent.StateService)

local DailyRewardService = {}

local limiter = RateLimiter.new(DailyRewardConfig.REQUESTS_PER_SECOND, DailyRewardConfig.REQUEST_BURST)

--- Players whose join has settled (see READY).
local ready: { [Player]: boolean } = {}
--- The claimable flag each ready player was last pushed, for the rollover.
local lastClaimable: { [Player]: boolean } = {}

--- STUDIO ONLY: seconds added to os.time() for one player, so a debug command
--- can stand them on "tomorrow" without touching the saved fields. Never set
--- outside the debug bridge.
local clockOffset: { [Player]: number } = {}

local function now(player: Player): number
	return os.time() + (clockOffset[player] or 0)
end

--- The streak status for `player`, or nil before their profile exists.
function DailyRewardService.status(player: Player): DailyRewardConfig.Status?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	return DailyRewardConfig.status(profile.DailyStreak, profile.DailyLastClaimDay, now(player))
end

--- The StatePush field. nil until the join has settled.
function DailyRewardService.summarise(player: Player): { [string]: any }?
	if not ready[player] then
		return nil
	end
	local status = DailyRewardService.status(player)
	if not status then
		return nil
	end
	return {
		day = status.day,
		streak = status.streak,
		claimable = status.claimable,
		claimedToday = status.claimedToday,
		nextResetAt = status.nextResetAt,
	}
end

--- The seven cards, with the amounts THIS player would be paid today.
--- `kind` is "cash", "speed", "guardian" or "mixed"; `text` is the card line.
function DailyRewardService.preview(player: Player): { [string]: any }?
	local profile = DataService.get(player)
	local status = DailyRewardService.status(player)
	if not profile or not status then
		return nil
	end
	local days = table.create(#DailyRewardConfig.Days)
	for _, def in DailyRewardConfig.Days do
		local resolved = RetentionRewards.resolve(player, profile, def :: any)
		local kind = "cash"
		local text = ""
		if resolved.guardianKey and not resolved.guardianOwned then
			local guardian = BaseGuardianConfig.ByKey[resolved.guardianKey]
			kind = "guardian"
			text = `{if guardian then guardian.name else resolved.guardianKey} Guardian`
		elseif resolved.cash > 0 and resolved.speed > 0 then
			kind = "mixed"
		elseif resolved.speed > 0 then
			kind = "speed"
		end
		table.insert(days, {
			day = def.day,
			kind = kind,
			cash = resolved.cash,
			speed = resolved.speed,
			guardianKey = resolved.guardianKey,
			-- True when a guardian day will pay Speed because it is owned.
			converted = resolved.guardianOwned,
			text = text,
			icon = if def.icon ~= DailyRewardConfig.NO_ICON then def.icon else nil,
		})
	end
	return {
		days = days,
		day = status.day,
		streak = status.streak,
		claimable = status.claimable,
		claimedToday = status.claimedToday,
		nextResetAt = status.nextResetAt,
	}
end

function DailyRewardService.sendPreview(player: Player)
	local payload = DailyRewardService.preview(player)
	if payload then
		Remotes.get("DailyRewardPush"):FireClient(player, payload)
	end
end

--- Claims today's reward. Returns success and the player-facing message.
function DailyRewardService.claim(player: Player): (boolean, string)
	local profile = DataService.get(player)
	if not profile or not ready[player] then
		return false, "Your data is still loading - try again in a moment."
	end
	local status = DailyRewardConfig.status(profile.DailyStreak, profile.DailyLastClaimDay, now(player))
	if not status.claimable then
		return false, "You already claimed today's reward - come back tomorrow!"
	end
	local def = DailyRewardConfig.Days[status.day]
	if not def then
		return false, "Something went wrong - please try again."
	end

	-- Marked FIRST (nothing above yielded): a racing request is refused.
	local previousStreak, previousDay = profile.DailyStreak, profile.DailyLastClaimDay
	profile.DailyStreak = status.nextStreak
	profile.DailyLastClaimDay = DailyRewardConfig.dayNumber(now(player))

	local ok, paid = pcall(RetentionRewards.grant, player, profile, def :: any, "daily" :: any)
	if not ok then
		profile.DailyStreak = previousStreak
		profile.DailyLastClaimDay = previousDay
		warn(`[DailyRewardService] payout of day {status.day} failed for {player.Name}: {paid}`)
		return false, "Something went wrong - please try again."
	end

	lastClaimable[player] = false
	-- Streak milestones (the 7-day badge) listen on the shared progress bus.
	require(script.Parent.ProgressEvents).fire(player, "dailyStreak", status.nextStreak, { day = status.day })
	StateService.pushNow(player)
	DailyRewardService.sendPreview(player)
	if DataService.isPersistent() then
		local saved, err = pcall(DataService.save, player)
		if not saved then
			warn(`[DailyRewardService] save after claim failed for {player.Name}: {err}`)
		end
	end
	local suffix = if paid.converted then " (you already own that Guardian)" else ""
	print(`[DailyRewardService] {player.Name} claimed day {status.day} (streak {status.nextStreak}): {RetentionRewards.describe(paid)}`)
	return true, `Day {status.day} reward: {RetentionRewards.describe(paid)}{suffix}!`
end

--- Called by init.server.luau once the join has settled (after the offline
--- settle and the first full push). Idempotent.
function DailyRewardService.onProfileReady(player: Player)
	if ready[player] or not DataService.get(player) then
		return
	end
	ready[player] = true
	local status = DailyRewardService.status(player)
	lastClaimable[player] = if status then status.claimable else false
	StateService.markDirty(player)
	DailyRewardService.sendPreview(player)
end

-- ==========================================================
-- DEBUG (Studio bridge only - DebugCommands/Retention.luau)
-- ==========================================================

--- Moves this player's clock by `seconds` (0 clears it) and re-pushes.
function DailyRewardService.debugSetClockOffset(player: Player, seconds: number)
	if seconds ~= 0 then
		clockOffset[player] = seconds
	else
		clockOffset[player] = nil
	end
	StateService.pushNow(player)
	DailyRewardService.sendPreview(player)
end

function DailyRewardService.debugIsReady(player: Player): boolean
	return ready[player] == true
end

function DailyRewardService.start()
	StateService.addProvider("daily", DailyRewardService.summarise)

	Remotes.get("DailyRewardRequest").OnServerEvent:Connect(function(player, action)
		if not limiter:consume(player) then
			return
		end
		if action == "preview" then
			DailyRewardService.sendPreview(player)
		elseif action == "claim" then
			local ok, message = DailyRewardService.claim(player)
			if ok then
				StateService.notify(player, "success", message, "levelup")
				StateService.sound(player, "UpgradePurchase")
			else
				StateService.notify(player, "error", message)
			end
		end
		-- Anything else is ignored: no reply to a malformed request.
	end)

	Players.PlayerRemoving:Connect(function(player)
		ready[player] = nil
		lastClaimable[player] = nil
		clockOffset[player] = nil
		limiter:release(player)
	end)

	-- UTC midnight while online: flip the flag (and the HUD dot) without
	-- waiting for some other change to push.
	task.spawn(function()
		while true do
			task.wait(DailyRewardConfig.ROLLOVER_CHECK_SECONDS)
			for player in ready do
				local ok, err = pcall(function()
					local status = DailyRewardService.status(player)
					if status and status.claimable ~= lastClaimable[player] then
						lastClaimable[player] = status.claimable
						StateService.markDirty(player)
						DailyRewardService.sendPreview(player)
					end
				end)
				if not ok then
					warn(`[DailyRewardService] rollover check failed for {player.Name}: {err}`)
				end
			end
		end
	end)

	print("[DailyRewardService] daily streak online")
end

return DailyRewardService
