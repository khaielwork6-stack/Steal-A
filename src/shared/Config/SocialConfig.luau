--!strict
--[[
	SocialConfig
	Every tuning number for the social pass: invites and referral rewards,
	the friend / Premium income boost, the reveal announcement, the
	favourite / notification opt-in prompts, Open Cloud notifications and the
	private-server owner commands.

	Server-authoritative except where noted: the client reads the display
	values (pill text, banner timing) and nothing it reads here decides a
	reward. validate.luau checks the shape (the SOCIAL block).
]]

local SocialConfig = {}

-- ==========================================================
-- INVITES
-- ==========================================================

--- Shows the Invite button on the HUD (still hidden wherever Roblox says the
--- player may not send invites).
SocialConfig.INVITE_BUTTON_ENABLED = true
--- The line on Roblox's invite sheet. Plain text; Roblox filters it.
SocialConfig.INVITE_PROMPT_MESSAGE = "Steal with me in Steal & Run!"
--- An invite message template id from the Creator Dashboard (Engagement >
--- Invite prompts), or "" for Roblox's default text.
SocialConfig.INVITE_MESSAGE_ID = ""
--- The HUD button's icon, or "rbxassetid://0" to draw the text-only face.
--- Codex: docs/codex-prompts/social.md "Invite HUD icon".
SocialConfig.INVITE_ICON = "rbxassetid://93427904685916"

-- ==========================================================
-- REFERRAL REWARDS (paid to the INVITER, through the mailbox)
-- ==========================================================
--
-- A player who joins through an invite (Player:GetJoinData().
-- ReferredByPlayerId) on their FIRST session in this game is recorded once
-- (profile.ReferredBy). After they have played REFERRAL_MIN_PLAY_SECONDS
-- the inviter is paid, wherever they are, through MailboxService. The
-- inviter's daily count is kept in a DataStore, so the cap holds across
-- servers.

--- Seconds of play (this session or later ones) before the inviter is paid.
SocialConfig.REFERRAL_MIN_PLAY_SECONDS = 5 * 60
--- Paid referrals per inviter per UTC day. Joins beyond this are recorded
--- but not paid.
SocialConfig.REFERRAL_DAILY_CAP = 5
--- Cash: this many minutes of the inviter's BASE income (no 2x pass, no
--- event or social boosts - the same basis the Cash packs use), never below
--- the floor and never above the ceiling.
SocialConfig.REFERRAL_CASH_MINUTES = 10
SocialConfig.REFERRAL_CASH_FLOOR = 5000
SocialConfig.REFERRAL_CASH_MAX = 1e12
--- Speed: this fraction of the inviter's NEXT zone gate (SpinWheelConfig.
--- nextGate), never below the floor and never above the ceiling. Small on
--- purpose: an invite must not be a way past the Zone 8+ wall.
SocialConfig.REFERRAL_SPEED_GATE_FRACTION = 0.01
SocialConfig.REFERRAL_SPEED_FLOOR = 500
SocialConfig.REFERRAL_SPEED_MAX = 1e6
--- How often the play clock of pending referrals is advanced.
SocialConfig.REFERRAL_TICK_SECONDS = 10

-- ==========================================================
-- FRIEND AND PREMIUM INCOME BOOST
-- ==========================================================
--
-- Applied at ONE point: EconomyService's passive income tick (see its
-- "SOCIAL BOOST" note). It is NOT part of `getIncome`, so the Cash-pack /
-- spin-wheel / fallback "minutes of income" base and the offline rate never
-- include it. The boosts add, then the total is capped.

--- Extra income per friend in the same server.
SocialConfig.FRIEND_BOOST_PER_FRIEND = 0.10
--- The friend part never exceeds this.
SocialConfig.FRIEND_BOOST_CAP = 0.50
--- Extra income for Roblox Premium members.
SocialConfig.PREMIUM_BOOST = 0.10
--- The pill offers PromptPremiumPurchase to non-Premium players when tapped.
SocialConfig.PREMIUM_UPSELL_ENABLED = true
--- Pill icons ("rbxassetid://0" = text only). Codex: social.md.
SocialConfig.FRIENDS_PILL_ICON = "rbxassetid://115260215543732"
SocialConfig.PREMIUM_PILL_ICON = "rbxassetid://84952495015282"

--- The combined social income multiplier, 1 or more.
function SocialConfig.multiplier(friendCount: number, premium: boolean): number
	local friends = math.min(math.max(tonumber(friendCount) or 0, 0) * SocialConfig.FRIEND_BOOST_PER_FRIEND, SocialConfig.FRIEND_BOOST_CAP)
	local bonus = friends + (if premium then SocialConfig.PREMIUM_BOOST else 0)
	return 1 + math.max(bonus, 0)
end

-- ==========================================================
-- REVEAL ANNOUNCEMENT
-- ==========================================================

--- Reveals of this rarity or better are announced to the whole server.
SocialConfig.ANNOUNCE_REVEAL_MIN_RARITY = "Mythic"
--- Seconds each banner is on screen.
SocialConfig.ANNOUNCE_BANNER_SECONDS = 3
--- Banners waiting beyond this are dropped (oldest first) so a burst never
--- turns into a minute of banners.
SocialConfig.ANNOUNCE_QUEUE_MAX = 4
--- Also post a system line in the general chat channel.
SocialConfig.ANNOUNCE_CHAT_MESSAGE = true
--- Banner frame art ("rbxassetid://0" = the built-in flat frame). Codex.
SocialConfig.ANNOUNCE_FRAME_IMAGE = "rbxassetid://0"

-- ==========================================================
-- ONE-TIME PROMPTS AFTER THE FIRST REVEAL (client)
-- ==========================================================

SocialConfig.FAVORITE_PROMPT_ENABLED = true
SocialConfig.NOTIFICATION_OPT_IN_ENABLED = true
--- Seconds after the reveal cue before the favourite prompt opens (the
--- roulette and the camera hold are over by then).
SocialConfig.FIRST_REVEAL_PROMPT_DELAY = 8

-- ==========================================================
-- OPEN CLOUD USER NOTIFICATIONS (server)
-- ==========================================================

--- The secret's name in the experience's Secrets store.
SocialConfig.NOTIFICATION_SECRET_NAME = "OPEN_CLOUD_NOTIFICATIONS"
--- Notification string ids (Creator Dashboard > Engagement > Notifications),
--- or "" to disable that notification. Each template may use the parameters
--- listed in docs/handoff-parts/social.md.
SocialConfig.NOTIFICATION_TEMPLATES = {
	containerReady = "",
	offlineFull = "",
} :: { [string]: string }
--- A container that is ready sooner than this after leaving is not worth a
--- notification (the player is probably still around).
SocialConfig.NOTIFY_READY_MIN_DELAY = 10 * 60
--- ("offline earnings are full" is due GameConfig.OFFLINE_EARNINGS_MAX_SECONDS
--- after leaving; that number is read from GameConfig, not repeated here.)
---
--- Minimum seconds between two notifications to the same user. Roblox also
--- throttles per user on its side; this keeps us well under it.
SocialConfig.NOTIFY_MIN_GAP_SECONDS = 12 * 60 * 60
--- How often a server looks for due notifications (with jitter).
SocialConfig.NOTIFY_POLL_SECONDS = 60
--- Due entries handled per poll.
SocialConfig.NOTIFY_BATCH = 20
--- Entries older than this past their due time are dropped unsent.
SocialConfig.NOTIFY_MAX_LATE_SECONDS = 6 * 60 * 60

-- ==========================================================
-- PRIVATE-SERVER OWNER COMMANDS
-- ==========================================================

SocialConfig.OWNER_COMMANDS_ENABLED = true
--- Seconds between two uses of the SAME world command (/night, /day,
--- /resetguards, /refill). Stops a private server being used as a free
--- reroll machine for socket loot.
SocialConfig.OWNER_COMMAND_COOLDOWN = 60
--- /night ends in a full world refresh (every Spawned socket is rerolled),
--- so it waits at least half a normal Day/Night cycle between uses.
SocialConfig.OWNER_NIGHT_COOLDOWN = 135
--- Group rank that counts as "admin" for the Studio-only owner check.
SocialConfig.OWNER_GROUP_MIN_RANK = 254

return SocialConfig
