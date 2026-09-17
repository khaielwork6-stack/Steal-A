--!strict
--[[
	DebugCommands/Social
	Studio test commands for the social pass. Call through
	ServerStorage.DebugInvoke:Invoke(name, "<you>", ...).

	socialReferral [mode] [referrerId]
	    mode "dry" (default): records a referral from `referrerId` (default:
	    your UserId + 1) as if this were your first session, runs the payout
	    as a DRY RUN (in-memory daily cap, no save, no mail) and restores
	    every referral field. Returns the amounts and the basis used.
	    mode "self": a real payout to YOUR OWN mailbox (you stand in for the
	    inviter), delivered at once; then the Cash, lifetime Cash and Speed it
	    paid are taken back, the referral fields restored and the profile
	    saved - even on error. Uses one slot of your own real daily cap.
	    mode "cap": runs the dry payout REFERRAL_DAILY_CAP + 1 times against
	    the in-memory counter; the last must say "capped".
	socialBoosts [friends|"reset"] [premium true/false]
	    Shows the boost (and what the HUD pill gets); with arguments, fakes the
	    friend count / Premium for this session ("reset" = real answers).
	socialBadge [key]
	    Queues a badge (default FirstSteal). An id of 0 is a printed no-op.
	socialNotify [kind]
	    Prints the exact Open Cloud request a send would make (key redacted),
	    and what would be scheduled if you left now. Sends nothing.
	socialAnnounce [rarity] [itemId]
	    Fires the server-wide reveal banner + chat line with your name.
	socialOwner <command> [argument]
	    Runs a private-server owner command as you (night/day/resetguards/
	    refill/kick), with the same owner check as chat.
	socialPrompts ["reset"]
	    Shows the one-time prompt flags; "reset" sets both back to false so
	    the favourite / notification prompts run again after your next reveal.
	socialProgress <kind> [amount]
	    Fires a ProgressEvents event (e.g. socialProgress streak 7).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BadgeConfig = require(ReplicatedStorage.Shared.Config.BadgeConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local Services = script.Parent.Parent
local BadgeAwardService = require(Services.BadgeAwardService)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local MailboxService = require(Services.MailboxService)
local NotificationService = require(Services.NotificationService)
local OwnerCommandService = require(Services.OwnerCommandService)
local ProgressEvents = require(Services.ProgressEvents)
local SocialService = require(Services.SocialService)
local SpeedService = require(Services.SpeedService)
local StateService = require(Services.StateService)

type Snapshot = { ReferredBy: number, ReferralState: string, ReferralPlaySeconds: number, LastLeaveTimestamp: number }

local function snapshot(profile: DataService.Profile): Snapshot
	return {
		ReferredBy = profile.ReferredBy,
		ReferralState = profile.ReferralState,
		ReferralPlaySeconds = profile.ReferralPlaySeconds,
		LastLeaveTimestamp = profile.LastLeaveTimestamp,
	}
end

local function restore(profile: DataService.Profile, saved: Snapshot)
	profile.ReferredBy = saved.ReferredBy
	profile.ReferralState = saved.ReferralState
	profile.ReferralPlaySeconds = saved.ReferralPlaySeconds
	profile.LastLeaveTimestamp = saved.LastLeaveTimestamp
end

local function saveNow(player: Player): string
	if not DataService.isPersistent() then
		return "memory mode"
	end
	return if DataService.save(player) then "saved" else "SAVE FAILED"
end

--- Records a referral as a first session would and runs a dry payout.
local function dryPayout(player: Player, profile: DataService.Profile, referrerId: number): { [string]: any }
	profile.ReferralState = ""
	profile.LastLeaveTimestamp = 0
	SocialService.noteProfileLoaded(player, referrerId)
	local recorded = profile.ReferralState == "pending" and profile.ReferredBy == referrerId
	profile.ReferralPlaySeconds = SocialConfig.REFERRAL_MIN_PLAY_SECONDS
	local result = SocialService.payReferral(player, { dryRun = true })
	result.recorded = recorded
	return result
end

return {
	socialReferral = function(player: Player, mode: string?, referrerArg: any?): any
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local saved = snapshot(profile)
		local which = mode or "dry"
		local out: { [string]: any } = { mode = which }

		if which == "dry" or which == "cap" then
			local referrerId = tonumber(referrerArg) or (player.UserId + 1)
			local ok, err = pcall(function()
				if which == "dry" then
					out.result = dryPayout(player, profile, referrerId)
					-- A self-invite must never be recorded.
					restore(profile, saved)
					profile.ReferralState = ""
					profile.LastLeaveTimestamp = 0
					SocialService.noteProfileLoaded(player, player.UserId)
					out.selfInviteRefused = profile.ReferralState == ""
				else
					-- A fresh fake inviter so earlier runs do not count.
					local fake = referrerId + math.random(1000, 9999) * 1000
					local outcomes = {}
					for _ = 1, SocialConfig.REFERRAL_DAILY_CAP + 1 do
						restore(profile, saved)
						table.insert(outcomes, dryPayout(player, profile, fake).outcome)
					end
					out.outcomes = outcomes
					out.pass = outcomes[#outcomes] == "capped" and outcomes[1] == "dry run"
				end
			end)
			restore(profile, saved)
			out.error = if ok then nil else tostring(err)
			out.restored = true
			return out
		elseif which == "self" then
			local cashBefore = profile.Cash
			local speedBefore = profile.SpeedPower
			local paidCash, paidSpeed = 0, 0
			local ok, err = pcall(function()
				profile.ReferredBy = player.UserId
				profile.ReferralState = "pending"
				profile.ReferralPlaySeconds = SocialConfig.REFERRAL_MIN_PLAY_SECONDS
				local result = SocialService.payReferral(player)
				out.result = result
				out.delivered = MailboxService.deliver(player)
				out.cashDelta = profile.Cash - cashBefore
				out.speedDelta = profile.SpeedPower - speedBefore
				-- What actually landed: the passive tick may add a little Cash
				-- while this runs, so the check allows for it.
				if result.cashSent then
					paidCash = math.min(tonumber(result.cash) or 0, math.max(0, out.cashDelta))
				end
				if result.speedSent then
					paidSpeed = math.min(tonumber(result.speed) or 0, math.max(0, out.speedDelta))
				end
				out.pass = result.outcome == "paid" and paidCash == result.cash and paidSpeed == result.speed
			end)
			-- Take back exactly what was paid, whatever happened above.
			profile.Cash = math.max(0, profile.Cash - paidCash)
			profile.Lifetime.CashEarned = math.max(0, profile.Lifetime.CashEarned - paidCash)
			profile.SpeedPower -= paidSpeed
			out.takenBack = { cash = paidCash, speed = paidSpeed }
			out.warning = "if delivered is 0 the mail is still queued: it will pay on the next mailbox pass and is NOT taken back"
			restore(profile, saved)
			SpeedService.applyMovement(player)
			EconomyService.recalculate(player)
			StateService.pushNow(player)
			out.save = saveNow(player)
			out.error = if ok then nil else tostring(err)
			out.restored = true
			return out
		end
		return { error = `unknown mode "{which}" (dry | self | cap)` }
	end,

	socialBoosts = function(player: Player, friends: any?, premium: any?): any
		if friends == "reset" then
			SocialService.debugResetBoost(player)
		elseif friends ~= nil or premium ~= nil then
			SocialService.debugSetBoost(
				player,
				tonumber(friends),
				if premium == nil then nil else (premium == true or premium == "true")
			)
		end
		return {
			boosts = SocialService.boosts(player),
			multiplier = SocialService.multiplierFor(player),
			income = EconomyService.getIncome(player),
			paidIncome = EconomyService.getPaidIncome(player),
			membership = tostring(player.MembershipType),
			note = "income = the base every formula uses; paidIncome = what the tick pays and the HUD shows",
		}
	end,

	socialBadge = function(player: Player, key: string?): any
		local wanted = key or "FirstSteal"
		local id = BadgeConfig.idFor(wanted)
		local queued = BadgeAwardService.award(player, wanted)
		if id == 0 then
			print(`[Social] badge {wanted} has id 0 (not created) - nothing awarded`)
		end
		return {
			key = wanted,
			id = id,
			known = BadgeConfig.ByKey[wanted] ~= nil,
			queued = queued,
			knownOwned = BadgeAwardService.knownOwned(player, wanted),
			log = BadgeAwardService.recentLog(),
		}
	end,

	socialNotify = function(player: Player, kind: string?): any
		local wanted = kind or "containerReady"
		local dry = NotificationService.dryRun(player.UserId, wanted)
		print(`[Social] notification dry run ({wanted}): POST {dry.url}\n{dry.body}`)
		local plan = {}
		for planned, dueAt in NotificationService.plannedFor(player) do
			plan[planned] = { dueAt = dueAt, inSeconds = dueAt - os.time() }
		end
		return { request = dry, wouldScheduleOnLeave = plan, log = NotificationService.recentLog() }
	end,

	socialAnnounce = function(player: Player, rarity: string?, itemId: string?): any
		local pool = LootConfig.Items[ZoneConfig.COUNT] or {}
		local fallback = pool[#pool]
		local id = itemId or (if fallback then fallback.id else "")
		SocialService.announceReveal(player.UserId, player.DisplayName, id, rarity or "Divine", nil)
		return { announced = true, itemId = id, rarity = rarity or "Divine" }
	end,

	socialOwner = function(player: Player, command: string?, argument: string?): any
		if type(command) ~= "string" then
			return { error = "usage: socialOwner <night|day|resetguards|refill|kick> [argument]" }
		end
		return {
			isOwner = OwnerCommandService.isOwner(player),
			ran = OwnerCommandService.run(player, command, argument),
			privateServer = game.PrivateServerId ~= "",
		}
	end,

	socialPrompts = function(player: Player, mode: string?): any
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		if mode == "reset" then
			profile.FavoritePrompted = false
			profile.NotificationsPrompted = false
			StateService.markDirty(player)
		end
		return {
			favoritePrompted = profile.FavoritePrompted,
			notificationsPrompted = profile.NotificationsPrompted,
			referredBy = profile.ReferredBy,
			referralState = profile.ReferralState,
			referralPlaySeconds = profile.ReferralPlaySeconds,
			lastPayout = SocialService.lastPayout(player),
		}
	end,

	socialProgress = function(player: Player, kind: string?, amount: any?): any
		if type(kind) ~= "string" then
			return { error = "usage: socialProgress <kind> [amount]" }
		end
		ProgressEvents.fire(player, kind, tonumber(amount) or 1, {})
		return { fired = kind, amount = tonumber(amount) or 1 }
	end,
}
