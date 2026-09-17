# Social pass (area "social")

This pass adds invites and referral rewards, friend and Premium income boosts,
badges, experience notifications, the reveal "share moment", and
private-server owner commands.

Status:
- Nothing here was run in Studio.
- `tools/check.sh` reports no hard errors.
- `selene src` reports 0 errors.
- The new files contain no type errors beyond the luau-lsp `pcall` false
  positive, which is cast away. The higher TypeError counts on existing files
  (LootService, DataService, Remotes, ...) are the known effect of extra
  modules requiring them: each one reports the same diagnostic again.

## What was built

### S1. Invite, favourite and referral rewards

**Invite button** (`SocialController`)
- A round green button in `MainUI.Top`, just left of the Settings gear. It
  follows the same pattern as the gear:
  - an invisible hit area that stays at least 44 px after MainUI's UIScale;
  - claimed with `UIAnim.claimButton` before it is parented;
  - not named after a panel.
- Pressing it calls `CanSendGameInviteAsync`, then `PromptGameInvite` with
  `ExperienceInviteOptions` (`INVITE_PROMPT_MESSAGE`, plus the optional
  `INVITE_MESSAGE_ID`). Every call is in a pcall.
- The button is hidden unless `CanSendGameInviteAsync` returns true.
- The icon is text-only ("+" and "INVITE") until `SocialConfig.INVITE_ICON`
  is set.

**Favourite and notification prompts, after a reveal** (client)
- Trigger: a `HatchReveal` cue arrives and the matching `social.*Prompted`
  flag is still false.
- Timing: it waits `FIRST_REVEAL_PROMPT_DELAY` (8 s), then until
  `UIStateController` is no longer suppressed.
- Favourite step:
  - `AvatarEditorService:GetFavorite` is tried first, in a pcall, and the
    prompt is skipped if the game is already a favourite;
  - otherwise `PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)`
    opens.
- Notification step: `ExperienceNotificationService:CanPromptOptInAsync`, then
  `PromptOptIn`.
- Asked once per account: each flag is stored in the profile through the
  `SocialRequest("prompted", "favorite" | "notifications")` remote.
  - The remote only ever sets the flag to true. It is rate-limited to 1/s
    (burst 3).
  - If a call errors, the flag is left unset, so the prompt is asked again
    after a later reveal.
- Existing players who have already revealed items see the prompts once, after
  their next reveal.

**Referral** (`SocialService`)
- **Recording:**
  - `noteProfileLoaded` runs in init's join block before
    `OfflineService.settle`.
  - A profile whose `LastLeaveTimestamp` is still 0 has never finished a
    session, so it counts as a new account for this game.
  - For those accounts only, `GetJoinData().ReferredByPlayerId` is recorded,
    provided it is positive and is not the player's own id.
  - The record is `ReferredBy`, with `ReferralState = "pending"`.
- **Payment trigger:** after `REFERRAL_MIN_PLAY_SECONDS` (5 minutes) of play.
  Play time accrues every 10 s and is saved, so leaving early just resumes the
  count next session.
- **Payment order:**
  1. Set the state to `"paid"` and save. This makes the payment at most once.
  2. Claim one daily slot in DataStore `SocialReferrals_v1`, key
     `ref_<inviter>_<yyyymmdd UTC>`, capped at `REFERRAL_DAILY_CAP` (5). If
     the cap is reached, the state becomes `"capped"`.
  3. Send `MailboxService.send(inviter, cash)` and `(inviter, speed)`, with
     source `"referral"` and 3 tries each. If both fail, the state becomes
     `"failed"`.
- **Amounts:**
  - Cash: `clamp(baseIncome × 10 min, $5,000, $1e12)`.
  - Speed: `clamp(1% of the inviter's next zone gate, 500, 1M)`. `validate`
    caps the fraction at 5%, so an invite can never get a player past a
    zone gate.
  - The inviter's figures come from the live values if they are in this
    server. Otherwise they come from their **saved** profile: a read-only
    `GetAsync` on `PlayerProfiles_v1/player_<id>` (`OfflineCashRate`,
    `HighestZoneReached`). Failing both, the floors are used.
  - Those two names are duplicated in `SocialService` (`PROFILE_STORE`). If
    DataService's store name or key format ever changes, change them there
    too.
- **Toasts:** both players get a toast when the inviter is in the same server.

### S2. Friend and Premium boost

**Values**
- +10% per friend in the server, capped at +50% (`FRIEND_BOOST_*`).
- +10% for Premium (`PREMIUM_BOOST`).
- The two add together.

**How it is tracked**
- Friendships are checked with `Player:IsFriendsWithAsync`, cached per pair,
  and recounted on join and leave. A friendship made mid-session counts from
  the next join or leave.
- Premium comes from `MembershipType` and updates on `PlayerMembershipChanged`.

**One multiplier point:** `EconomyService`'s income tick. It pays the
ordinary `"passive"` award, then a separate `"social"` award for the extra.
Fractional dollars carry over to the next tick.
- The boost is **not** in `maturedRate`, `recalculate` or `getIncome`. The
  monetization pass uses those as "income":
  - `MonetizationConfig.baseIncome` → Cash packs, spin-wheel prizes, the
    undeliverable-receipt fallback;
  - the OfflineService rate.

  So the boost never inflates a pack, a spin prize or offline earnings. It is
  a presence bonus. This is documented at "SOCIAL BOOST" in EconomyService.
- `EconomyService.getPaidIncome` is the boosted $/s. **StatePush `income`
  now uses it** (a one-line StateService change), so the HUD $/s matches what
  is actually paid. Trophy labels still show the item's own rate.

**HUD pills** (StatePush `social`)
- "+20% FRIENDS" (green) and "PREMIUM +10%" (gold), above the stat card as a
  child of `StatHUD`, so they hide with the HUD.
- Non-Premium players see a dimmed Premium pill. Tapping it opens
  `PromptPremiumPurchase` (`PREMIUM_UPSELL_ENABLED`).

### S3. Badges

**Config:** `BadgeConfig` has 23 badges, all with id 0:
- FirstSteal, FirstEscape, FirstReveal, FirstMythicReveal, FirstSecretReveal;
- Zone01–Zone12, via `ZONE_BADGE_IDS`;
- IndexZoneComplete, IndexComplete;
- Steals100, Steals1000;
- FirstHeist, Streak7.

**`BadgeAwardService.award(player, key)`**
- Skips id 0 silently.
- Caches owned badges per session.
- Runs one worker that spaces its calls 0.25 s apart:
  `GetBadgeInfoAsync` (a disabled badge is skipped), then `UserHasBadgeAsync`,
  then `AwardBadge`. Every call is in a pcall.
- Retries with backoff, up to 5 attempts.
- On join it runs a catch-up pass from the profile: steals, the highest zone,
  and Index sets.

**Stable facade for other features:** `SocialBadges.award(player, key)`.

**`ProgressEvents`** (new; see the merge note)
- Hooks, each a one-line call:
  - `"steal"` {zone}: init's `setStolenHandler`, which now also receives
    `loot`;
  - `"escape"`: init's escape handler;
  - `"heist"`: `HeistService`, after a deposit commits;
  - `"reveal"` {rarity, itemId}: fired by `SocialService` **at the swap**,
    so the Roblox badge toast can never spoil the roulette.
- A zone badge is awarded for every zone up to the one stolen from.
- Streak7 listens for `"streak"` or `"dailyStreak"`. It reads the amount,
  `info.streak` or `info.days`, and awards at 7 or more.

### S4. Experience notifications

**Client side:** the opt-in prompt described in S1.

**Server side:** `NotificationService`.
- **Request:** `HttpService:RequestAsync` POST to
  `https://apis.roblox.com/cloud/v2/users/{userId}/notifications`.
  - Header `x-api-key` holds the Secret object from
    `HttpService:GetSecret("OPEN_CLOUD_NOTIFICATIONS")`.
  - The body is
    `{source:{universe:"universes/<GameId>"}, payload:{message_id, type:"MOONSHOT", join_experience:{launch_data:"notify:<kind>"}, analytics_data:{category:kind}}}`.
  - No custom template parameters are sent.
- **No scheduling:** the Open Cloud API delivers immediately and cannot
  schedule. When a player leaves (a `DataService.onBeforeRelease` hook, run
  off the release path), the service queues:
  - `containerReady` at the earliest future `HatchEndsAt`, only if it is at
    least 10 min away;
  - `offlineFull` at leave time + `OFFLINE_EARNINGS_MAX_SECONDS` (6 h), only
    if the player was earning.
- **Queue storage:**
  - document `SocialNotify_v1/u_<userId>`;
  - index `SocialNotifyDue_v1` (an OrderedDataStore), key `<kind>_<userId>`,
    value `dueAt`.
- **Processing:**
  - Every server polls about every 60 s (with jitter) using
    `GetSortedAsync(asc, 20, 1, now)`.
  - Each entry is claimed with one `UpdateAsync` that removes it and stamps
    `lastSentAt`, so it is sent at most once. Then the request is sent, with
    retries on 429 and 5xx responses.
  - On join, a player's queued entries are cancelled. A due entry for a
    player who is currently in the polling server is cancelled too.
- **Rate limit:** at most 1 notification per user per 12 h
  (`NOTIFY_MIN_GAP_SECONDS`). Entries more than 6 h late are dropped.
- **Disabled cleanly** (one print) when any of these is true:
  - both template ids are `""` (the default);
  - HTTP requests are off;
  - the secret is missing;
  - Studio is in memory mode.

### S5. Reveal share moment
- `SocialService.onRevealCommitted` is called from init's `HatchService.onHatched`
  (in a pcall).
- It waits `HatchConfig.swapAt(rarity)`. For Mythic or better
  (`ANNOUNCE_REVEAL_MIN_RARITY`) it then sends `RevealAnnounce` to every
  client with `{userId, name (DisplayName), itemName, rarity, mutation}`.
- `RevealAnnounceController` shows a banner: "**Name** pulled a **DIVINE**
  Golden Private Jet!".
  - The rarity word is in its rarity colour, with a rarity-coloured stroke.
  - Each banner shows for 3 s, one at a time. At most 4 wait in the queue; the
    oldest is dropped beyond that.
  - With Reduced Effects on, it shows and hides without animation.
  - The revealer gets no banner, because they are watching their own reveal.
- Everyone, including the revealer, also gets a `DisplaySystemMessage` line in
  `RBXGeneral`.

### S6. Private-server owner commands (`OwnerCommandService`)
- **Setup:** `TextChatCommand`s are created on the server, so `Triggered`
  fires on the server. This only happens in private servers and in Studio,
  and only when the place uses TextChatService.
- **Commands:**
  - `/night` → `NightService.forceNight`. Cooldown 135 s, because Night ends in
    a full socket reroll.
  - `/day` → `forceDay`.
  - `/resetguards` → `GuardianService.resetAll`.
  - `/refill` → `LootService.fillSocket` on **empty** sockets only (nothing is
    rerolled). It is refused at Night.
  - `/kick <name>` → private servers only. It matches an exact name or display
    name first, then a unique prefix. The owner cannot kick themselves.
- **Cooldown:** 60 s for every command except `/night`.
- **Who can use them:** `game.PrivateServerOwnerId`. In Studio, also the game
  creator, or group rank 254 or higher.
- None of the commands grants currency.

### S7. Debug commands (`DebugCommands/Social.luau`)
`socialReferral [dry|self|cap]`, `socialBoosts`, `socialBadge`,
`socialNotify`, `socialAnnounce`, `socialOwner`, `socialPrompts`,
`socialProgress`. The file header documents each one. Every command that
changes the profile restores it.

## Shared-file edits (merge checklist)
- `Remotes.NAMES`: one block at the end with `SocialRequest` and
  `RevealAnnounce`.
- `DataService`: five fields in one `[social pass]` block each, in the type,
  the defaults and `reconcile`:
  - `ReferredBy`, `ReferralState`, `ReferralPlaySeconds`,
    `FavoritePrompted`, `NotificationsPrompted`.
  - No schema bump.
- `EconomyService`:
  - `socialMultiplierFor` (injected), `getPaidIncome`, the tick extra;
  - `"social"` added to `CashSource`.
- `StateService`: `income = EconomyService.getPaidIncome(player)`.
- `HeistService`: one `ProgressEvents.fire(player, "heist")` line after a
  deposit.
- `init.server.luau`:
  - requires;
  - the steal, escape and reveal hooks;
  - `socialMultiplierFor`;
  - `noteProfileLoaded` in the join block;
  - four `start()` calls before DebugService.
- `init.client.luau`: two `startLater` calls.
- `validate.luau`: one SOCIAL block, which requires `SocialConfig` and
  `BadgeConfig` itself.
- **ProgressEvents MERGE NOTE:** another agent is creating
  `src/server/Services/ProgressEvents.luau` with the same
  `fire(player, kind, amount?, info?)` / `on(kind, fn)` API. Keep one file. If
  theirs passes different listener arguments, the listeners here expect
  `fn(player, amount: number, info: table)`. Also make sure their streak
  feature fires `"streak"` or `"dailyStreak"` with the day count, or calls
  `SocialBadges.award(player, "Streak7")`.

## Owner actions
1. **Badges.** On the Creator Dashboard, go to the experience → Engagement →
   Badges and create the 23 badges (names, descriptions and art are in
   `docs/codex-prompts/social.md`). Paste each id into
   `src/shared/Config/BadgeConfig.luau`: `ZONE_BADGE_IDS[n]` for zones, and
   the row's `id` for the rest. Roblox may charge for badge creation; check
   the Dashboard.
2. **Invite message (optional).** Create an invite prompt template on the
   Creator Dashboard (Engagement) and paste its id into
   `SocialConfig.INVITE_MESSAGE_ID`.
3. **Notifications.**
   - **Templates.** Go to the Creator Dashboard → experience → Engagement →
     Notifications and create two notification strings, in plain text with
     **no custom parameters**. For example:
     - "Your container is ready to reveal! Come see what's inside."
     - "Your offline earnings are full - come collect them!"

     Paste their ids into `SocialConfig.NOTIFICATION_TEMPLATES.containerReady`
     and `.offlineFull`.
   - **API key.** Go to the Creator Dashboard → Open Cloud → API Keys →
     Create.
     - Add the **User Notification** API system, select this experience, and
       grant the **write** operation (`user.user-notification:write`).
     - Accepted IP addresses: `0.0.0.0/0`, because game servers have no fixed
       IP.
     - Set an expiry you are comfortable with and note the date.
   - **Secret.** Go to the Creator Dashboard → experience → Secrets (Secrets
     store) and add a secret named `OPEN_CLOUD_NOTIFICATIONS` whose value is
     the API key. Restrict its domain to `apis.roblox.com`.
     - To test in Studio: Game Settings → Security → Secrets, then add the
       same name, key and domain as the local Studio secret.
   - **HTTP.** Game Settings → Security → **Allow HTTP Requests: ON**.
   - **Who gets them.** Roblox delivers only to eligible users who opted in
     (the in-game prompt handles the opt-in).
4. **Private servers.** Enable them (Monetization → Private Servers) if they
   should be offered. The place must use TextChatService, which is already the
   default.
5. **Art.** See `docs/codex-prompts/social.md`: the invite icon, 2 pill icons,
   the banner frame and 23 badge images. The config keys stay at
   `rbxassetid://0` or `0` until then, and the UI falls back to text.

## Studio test plan
Call each command as `ServerStorage.DebugInvoke:Invoke(cmd, "<you>", ...)`.

1. **Startup.** `validate` passes, including the SOCIAL block. The output
   shows `[NotificationService] no notification template ids set -
   notifications off`, and there are no `[Client] SocialController.start
   failed` warnings.
2. **Invite.** The green + button sits left of the gear. Pressing it opens the
   Roblox invite sheet. In the device emulator (phone), the button is easy to
   tap and does not overlap BASE or GIFT.
3. **Referral.**
   - `socialReferral dry`: `result.recorded = true`,
     `result.outcome = "dry run"`, cash = 5000 and speed ≥ 500 at low
     progress, `selfInviteRefused = true`.
   - `socialPrompts` afterwards: `referralState` is unchanged.
   - `socialReferral cap`: `pass = true` (the last outcome is `"capped"`).
   - With API access on, `socialReferral self`: `pass = true`,
     `delivered ≥ 1`. Cash and Speed return to their original values, and the
     output says `save = saved`.
4. **Boosts.**
   - `socialBoosts 2 true`: the multiplier is 1.3. The HUD shows "+20%
     FRIENDS" and "PREMIUM +10%", and the $/s label is 1.3× `income`.
   - Watch Cash for 10 s: it grows by about `paidIncome` per second.
   - `monPacks`: the pack amounts are unchanged by the boost.
   - `socialBoosts 0 false`: the gold pill is dimmed. Tapping it opens the
     Premium sheet.
   - `socialBoosts reset`.
5. **Badges.** `socialBadge FirstSteal` prints the id-0 no-op and returns
   `queued = false`. After creating one real badge and pasting its id,
   `socialBadge <key>` awards it, and `log` shows "awarded".
   `socialProgress streak 7` queues Streak7 (a no-op while its id is 0).
6. **Reveal share.**
   - `socialAnnounce Divine`: the chat shows the system line. In a 2-player
     Team Test the other player sees the banner and you do not.
   - Fire 6 announcements quickly: banners queue, show one at a time, and at
     most 4 remain waiting.
   - With VFX OFF there is no slide.
   - Real reveal of a Mythic+ item (use the existing hatch debug commands):
     the other player's banner appears as your roulette lands, not before.
7. **Prompts.**
   - `socialPrompts reset`, then reveal any item. About 8 s after the reveal,
     the favourite prompt opens, then the notification opt-in (if Roblox
     allows it in Studio).
   - `socialPrompts` then shows both flags true.
   - Reveal again: no prompts.
8. **Notifications.** `socialNotify containerReady` prints the exact request
   with the key redacted and `disabledReason`. Place a Mythic container
   (15 min incubation): `wouldScheduleOnLeave.containerReady` is about 900 s
   away.
9. **Owner commands** (Studio, as the place owner):
   - `socialOwner night` → Night starts.
   - Run it again → the cooldown message.
   - `socialOwner day`, `socialOwner resetguards`, then steal something and
     `socialOwner refill` → "Refilled 1".
   - Also type `/night` in chat.
   - `socialOwner kick x` → "only works in a private server".

## Must be tested live
- **Invite and referral.** Account A invites a brand-new account B. B plays
  5 minutes. A receives the "You received $…" mail toast, in the same server
  or another one.
  - B rejoining does not pay again.
  - Six invites in one day pay only 5.
  - Check A's Speed gain against 1% of their next gate.
- **Boosts.** Two friends in one server both see "+10% FRIENDS". A friend
  leaving removes the pill, and a Premium account shows the gold pill.
- **Notifications.** Configure the templates, key and secret. Leave with a
  container whose timer is at least 10 min, stay out, and a notification
  arrives about when it is ready. Tapping it launches the game.
  - **Verify first** that `apis.roblox.com` user notifications are callable
    from in-experience HttpService with a Secret header. This matches the
    Open Cloud docs as known to this agent, but it has not been tested. If a
    send returns 403, check the API key's permission and IP settings.
- **Owner commands** in a real private server as its owner; a non-owner gets a
  refusal toast.
- **Badges** award for real once their ids exist.

## Known limits
- Friendships formed mid-session count only after the next join or leave in
  the server.
- The referral reward uses the inviter's **saved** rate when they are
  elsewhere. That rate includes their 2x pass if they own it, so it can be up
  to 2× the base; the ceiling still applies.
- An entry claimed from the notification queue by a server that dies before
  sending is lost (at-most-once by design).
- The `IsFriendsWithAsync` and `GetRankInGroupAsync` calls are in pcalls. If
  an engine build lacks them, the friend boost reads as zero or the Studio
  owner check fails; neither causes an error.
