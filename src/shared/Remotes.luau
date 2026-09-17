--!strict
--[[
	Remotes
	Creates and resolves the RemoteEvents in ReplicatedStorage.Remotes.

	The server creates them on first require; clients wait for them. Every one of
	these carries untrusted *intent* only - the server derives rewards, targets
	and outcomes (GDD section 18).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

Remotes.NAMES = {
	"CrouchRequest", -- boolean intent; LaserService owns the accepted posture
	-- client -> server requests
	-- (StealRequest and SellLootRequest were removed by the security pass: no
	-- handler ever listened to them. A steal is a ProximityPrompt; selling goes
	-- through InventoryRequest. Their RATE_LIMITS rows are still used as the
	-- steal / store limiters and stay in GameConfig.)
	"PlaceLootRequest",
	"InventoryRequest",
	"BaseUpgradeRequest",
	"TreadmillUpgradeRequest",
	"BatSwingRequest",
	"TrapPlaceRequest",
	"IndexClaimRequest",
	-- Asks to hatch ONE sealed container, named by its InstanceId. Carries no
	-- reward, no timer and no result: the server owns all three and re-checks
	-- ownership, readiness and the un-hatched flag before it commits.
	"HatchRequest",
	-- server -> the owning client only. Sent AFTER the hatch is committed, and
	-- it is the first moment that client learns anything about the reward: the
	-- pedestal to play on and the two colours the reveal burst uses. The item
	-- itself arrives the ordinary way, as a rebuilt trophy on the base.
	"HatchReveal",
	-- The DROP button. Carries no payload at all: the server already knows what
	-- this player is carrying, and asking the client which item to drop would be
	-- handing it a target it has no business choosing.
	"DropLootRequest",
	-- Trail shop: buy with cash, buy with Robux, equip. Carries a trail KEY, never
	-- a price or a gamepass id - the server looks both of those up itself.
	"TrailRequest",
	-- Claims the group-join gift. Carries nothing: the server checks the group
	-- itself and pays out once. See GroupGiftService.
	"GroupGiftRequest",
	-- server -> client. The hub chest asking this client to open the gift panel
	-- it already has. Carries nothing and grants nothing; the claim still goes
	-- through GroupGiftRequest and GroupGiftService. See GiftChestService.
	"GiftMenuOpen",
	-- The Settings panel: volumes and toggles, saved on the profile so they
	-- survive a rejoin. Validated and clamped server-side; see SettingsService.
	"SettingsRequest",
	-- server -> client. The contextual "you were too slow" offer after a guardian
	-- catch. Carries the product key and the zone; the client renders it and can
	-- only ask to buy, never grant.
	"BossOffer",
	-- Asks the SERVER to open a Robux purchase prompt. The client never calls
	-- PromptProductPurchase with an id of its own choosing, so a tampered client
	-- cannot make the game prompt for an arbitrary product.
	"PurchaseRequest",
	-- server -> client, COSMETIC ONLY. Names the product key that just landed so
	-- the card that sold it can flash. It grants nothing and is never listened to
	-- on the server, so it cannot be used to ask for anything.
	--
	-- It exists because the alternative - inferring the purchase from the size of
	-- the balance jump - produces FALSE POSITIVES: a late-game loot sale is
	-- comfortably in the range of the smaller cash packs, and the shop would
	-- celebrate a sale as a purchase.
	"PurchaseFeedback",
	-- Base Guardians: equip / unequip an OWNED animal by key. Buying goes
	-- through PurchaseRequest("guardian"), and the server decides which of
	-- the four is on sale. See BaseGuardianService.
	"GuardianRequest",
	-- Weapons: equip the Bat or the Slap by name. Buying the Slap goes through
	-- PurchaseRequest("slap"). See PvPService.
	"WeaponRequest",
	-- server -> client. The back-to-base portal asking this client to play
	-- its teleport transition. Carries nothing; the move already happened.
	"PortalFx",
	-- Claims the Cash earned while away. Carries NOTHING: the server computed
	-- the amount when the profile loaded and holds it as a pending claim; the
	-- client can only ask for it. Idempotent. See OfflineService.
	"OfflineClaimRequest",
	-- server -> the spinning client only. Fired AFTER the wheel has been rolled
	-- and the prize granted, and it carries ONE number: the winning segment
	-- index. (Since the monetization pass also a display-only `{ won, amount }`
	-- table naming the scaled prize; the payout never reads it.) Everything the animation needs hangs off that through
	-- SpinWheelConfig, which both sides already have - so there is no reward,
	-- no amount and no odds on the wire, and nothing here can be replayed into
	-- a second prize. The spin itself is asked for with a ProximityPrompt, not
	-- a remote, so there is deliberately no client -> server event for it.
	"SpinResult",
	-- server -> client
	"StatePush",
	"Notify",
	-- The 96-entry Index discovery map. Deliberately NOT part of StatePush,
	-- which fires several times a second while income ticks.
	"IndexPush",
	-- Personal sound cues. Carries a cue NAME from AudioConfig, never an asset
	-- id. World/positional sounds do not use this: the server parents those to
	-- the part they belong to and they replicate on their own.
	"SoundCue",

	-- ==== MONETIZATION PASS (spin wheel AFK pause) ====
	-- client -> server. "This client has seen real input in the last two
	-- minutes." Carries nothing; rate-limited server-side; feeds only the
	-- free-spin clock's AFK pause. See ActivityController / SpinWheelService.
	"ActivityPing",

	-- ==========================================================
	-- CLIENT / STATE PUSH SPLIT (client performance pass)
	-- ==========================================================
	-- server -> client. `inventory` and the Index SUMMARY (the `index` field),
	-- split off StatePush and sent only when their content changed, plus on
	-- join, respawn and resync. The client StateStore merges them back into
	-- one state table. Not to be confused with IndexPush above, which is the
	-- full 96-entry discovery map and is unchanged.
	"InventoryPush",
	"IndexSummaryPush",
	-- client -> server. Carries nothing: "send me everything again". Sent by
	-- the StateStore on start so a late-starting client cannot miss the join
	-- push. Rate limited in StateService.
	"StateSyncRequest",

	-- ==== POLISH / EVENTS / ANALYTICS ====
	-- client -> server. One analytics funnel step the client alone can see,
	-- named by a KEY from AnalyticsEvents' allow-list ("shopOpened"). Carries
	-- nothing else; rate-limited; grants nothing. See AnalyticsEvents.
	"AnalyticsClientEvent",
	-- client -> server. "The first-join flyover has finished (or was
	-- skipped)." Carries nothing; the server only flips Profile.FlyoverSeen.
	-- Rate-limited. See FlyoverService.
	"FlyoverDone",

	-- ==========================================================
	-- RETENTION: CODES + DAILY STREAK (retention-codes-daily)
	-- ==========================================================
	-- client -> server. (codeText: string) - the text typed in the CODES box.
	-- The server trims, upper-cases, looks it up, rate limits and pays.
	"RedeemCodeRequest",
	-- server -> client. (ok: boolean, message: string) - the answer to one
	-- RedeemCodeRequest, for the CODES box. Display only; the toast comes
	-- through Notify as usual.
	"RedeemCodeResult",
	-- client -> server. (action: "claim" | "preview") - claim today's streak
	-- reward, or ask for the 7-day preview. Carries no day and no amount.
	"DailyRewardRequest",
	-- server -> client. The 7-day preview with this player's scaled amounts
	-- (DailyRewardService.preview). Sent on join, on request and after a
	-- claim - not on every StatePush.
	"DailyRewardPush",

	-- ==========================================================
	-- SOCIAL PASS (invites, boosts, badges, announcements)
	-- ==========================================================
	-- client -> server. ("prompted", "favorite" | "notifications"): the
	-- one-time favourite / notification opt-in prompt has been shown to this
	-- account, so it is never shown again. Grants nothing; validated and
	-- rate-limited in SocialService.
	"SocialRequest",
	-- server -> every client. A Mythic-or-better reveal, sent at the SWAP
	-- moment (HatchConfig.swapAt) so it never spoils the revealer's roulette.
	-- Display only: { userId, name, itemName, rarity, mutation }.
	"RevealAnnounce",

	-- ==========================================================
	-- GADGETS-PATROLS AREA (docs/handoff-parts/gadgets-patrols.md)
	-- ==========================================================
	-- client -> server. ("buy", gadgetKey) or ("use", gadgetKey, targetPoint?).
	-- A KEY, never a price or a count; the target point is only a hint for the
	-- Grappling Hook and is re-validated with the server's own raycast from
	-- the player's verified position. Rate limited in GadgetService.
	"GadgetRequest",

	-- ==========================================================
	-- FUSION / AUTO REVEAL / BASE THEMES (fusion-autoreveal-bases)
	-- ==========================================================
	-- client -> server. ("fuse", itemId, { instanceId x3 }). The server
	-- re-checks ownership, storage, reveal state and the price, and rolls the
	-- result itself. See FusionService.
	"FusionRequest",
	-- server -> the fusing client only. Sent AFTER the fusion is committed and
	-- saved in memory: what was consumed and what was made, for the animation.
	"FusionResult",
	-- client -> server. ("buy") opens the Auto Reveal Game Pass prompt. The
	-- on/off switch rides SettingsRequest (AutoRevealOff). See AutoRevealService.
	"AutoRevealRequest",
	-- client -> server. ("buy" | "equip" | "buyPass", key). Keys only; prices
	-- and pass ids are looked up server-side. See BaseThemeService.
	"BaseThemeRequest",
}

local folder: Folder

if RunService:IsServer() then
	folder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	for _, name in Remotes.NAMES do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

--- Resolves a remote by name; errors loudly on a typo rather than returning nil.
function Remotes.get(name: string): RemoteEvent
	local remote = folder:WaitForChild(name, 10)
	assert(remote, `Remotes.get: "{name}" does not exist`)
	return remote :: RemoteEvent
end

return Remotes
