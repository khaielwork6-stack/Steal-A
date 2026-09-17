# Polish, timed events and analytics pass (polish-events-analytics)

Branch: `worktree-agent-a9d9456e8544901c3`. Master (the social and
retention passes) is already merged into this branch, and the conflicts are
resolved.

Nothing here was run in Studio.
- `tools/check.sh`: no hard errors.
- `selene src`: 0 errors, and no warnings in the new files.
- `rojo build`: succeeds.

Per-file TypeError counts rose only in files that new modules now require
(HatchController, LootService, DataService, Remotes, LootModel, ...). This is
the known "reported once more per requirer" effect; no new files have
diagnostics.

## What was built

### 1. Loading screen (`src/first/`, mapped to ReplicatedFirst)
- **Files.**
  - `LoadingScreen.client.luau` (LocalScript)
  - `LoadingConfig.luau`: title, art ids, 14 tips, timings. It lives in
    ReplicatedFirst because Shared has not replicated when the loading
    screen starts. `validate` checks it from the server.
- **Startup.** Calls `RemoveDefaultLoadingScreen`, then builds two
  ScreenGuis:
  - a full-bleed backdrop with a gradient (plus art when the id is not 0);
  - a content layer inside `DeviceSafeInsets`, scaled with a UIScale to the
    safe area. The SKIP button sits outside the UIScale, so it stays a
    120 x 48 touch target.
- **Progress bar.** Driven by three stages:
  - `ContentProvider.RequestQueueSize` moves the bar from 0 to 60%;
  - `game:IsLoaded()` moves it to 90%;
  - the `ClientReady` player attribute moves it to 100%.

  The bar also creeps forward slowly over time and never moves backwards.
- **Timing.** SKIP appears after 3 s. The screen shows for at least 1.5 s
  and fades out after at most 60 s. When it is gone, it sets the
  `LoadingScreenDone` player attribute.
- **Reduced Effects.** Honours Roblox `ReducedMotionEnabled` and the game's
  `Effects` flag, once Shared has loaded: no bob or shimmer, and instant tip
  swaps.
- **`init.client.luau`** sets `ClientReady` after the last `startLater` (a
  single added line).

### 2. First-join flyover
- **Server: `FlyoverService`.**
  - Adds the StatePush field `firstSession`. It is true only when all of
    these hold:
    - `FLYOVER_ENABLED`;
    - `Profile.FlyoverSeen` is false;
    - `TutorialStage < 5` (the player has not placed a first item).
  - The `FlyoverDone` remote (no payload, rate-limited) sets `FlyoverSeen`.
- **New profile field `FlyoverSeen`.**
  - Old saves are reconciled to "seen" if they had any tutorial progress,
    so only brand-new players get the flyover.
  - No schema bump.
- **Client: `FlyoverController`.** Starts after `LoadingScreenDone` (or a
  90 s timeout), a character and the map exist, and no reveal owns the
  camera. It then runs:
  - a fade in;
  - three shots from `PolishConfig.FLYOVER_SHOTS`, each with a caption: the
    Zone 1 room, the Zone 2 room, then high over the Zone 3 lane looking
    home. That is 7.4 s plus the fades.
  - a SKIP button after 1 s;
  - letterbox bars;
  - frozen character controls;
  - a UIStateController claim `flyover` that hides the HUD.

  With Reduced Effects on, shots are hard cuts with no drift.
- **Camera rules.** The same rules as HatchController's reveal camera:
  - the camera is saved once and restored once;
  - a Scriptable camera is restored as Custom;
  - one CFrameValue drives the per-frame writes.
- **A reveal always wins.** New `HatchController.onRevealStarting(fn)` runs
  synchronously before a reveal takes the camera, and the flyover then
  releases the camera instantly. `HatchController.cameraBusy()` stops the
  flyover from starting mid-reveal.
- **Tutorial coordination.**
  - The flyover sets the `FlyoverActive` player attribute.
  - TutorialController hides the objective arrow while it is set (one
    line), so the first objective appears after the tour.
  - DailyRewardController and SocialController already wait for
    `UIStateController.isSuppressed()`, and the daily popup waits for the
    tutorial to finish, so neither overlaps the flyover.

### 3. Analytics (`AnalyticsEvents`)
- **Onboarding funnel** (`LogOnboardingFunnelStepEvent`). Seven steps:
  joined, first steal, first escape, first delivery, first reveal, first
  upgrade, first purchase view.
  - Each step is logged once per player. The logged steps are saved in the
    new profile field `AnalyticsOnboarding`.
  - Players who existed before this change are marked `{legacy=true}` by
    reconcile and are never logged.
- **"FirstPurchase" funnel** (`LogFunnelStepEvent`). Steps: shop opened ->
  product prompted -> purchased. Each shop visit is one funnel session
  (15 min window), and it is logged only for players with no processed
  receipts.
  - "Shop opened" comes from the client (`AnalyticsController` watches
    `MainUI.Frames.Shop.Visible`) through the rate-limited
    `AnalyticsClientEvent` remote. The remote accepts only allow-listed
    keys.
  - "Prompted" comes from observing `PurchaseRequest`.
  - "Purchased" comes from wrapping `MonetizationService.processReceipt`.
    The wrapper returns the handler's decision unchanged and cannot throw.
    Gamepasses count through `PromptGamePassPurchaseFinished`.
- **Economy** (`LogEconomyEvent`). Fed by the new
  `EconomyService.onTransaction` hook, which fires on every award and spend.
  - `spend` now takes an optional sink tag. It is set at all four call
    sites: `upgrade:storage`, `upgrade:capacity`, `upgrade:treadmill` and
    `trail:<key>`.
  - Award tags `spin` and `task` replace `other` for the wheel and the
    checklist.
  - Transaction types:
    - `passive`, `social`, `sell`, `discovery`, `index`, `code`: Gameplay
    - `offline`, `spin`, `daily`: TimedReward
    - `task`: Onboarding
    - `product`: IAP
    - any sink: Shop
  - Per-tick sources (`passive`, `social`) are summed and sent every 5 min
    and on leave. `debug` is never sent.
- **Progression** (`LogProgressionEvent`, path `MuseumZone`, type Start).
  Sent when the pushed `highestZone` goes up. The first push is only the
  baseline.
- **Safety.**
  - Every call is spawned and pcall'd.
  - Each category has a token bucket at (120 + 20 x players) per minute,
    times 0.8.
  - Studio records events without sending them unless
    `PolishConfig.ANALYTICS_DEBUG` or the `analyticsDebug` command is on.
    When on, it also prints each event.
- **Progress bus.** Master's `ProgressEvents` is used as-is: social fires
  `steal`, `escape` and `reveal`. This pass adds only the `deliver` fire,
  in init's delivered handler. My duplicate steal/escape/reveal fires were
  dropped in the merge.

### 4. Timed events (`EventConfig`, `EventService`, `EventController`)
- **Windows** are UTC, computed from `os.time()`, using a pure-arithmetic
  calendar (`EventConfig.utc` / `windowFor`). `validate` checks the
  calendar maths, including leap years and New Year.
- **Mutation Weekend** (Saturday 00:00 to Monday 00:00 UTC).
  - `LootService.mutationTableFor()` is the new hook, used only by world
    rolls (`makeInstance`). During the event, init points it at
    `EventService.mutationTable`.
  - During the event that function returns a scaled copy of the table:
    non-Normal chances x2 and Normal takes the rest. That is 80 / 12 / 5 /
    2 / 1.
  - The multiplier is capped so no chance can go negative, and the total
    stays 100. `validate` checks this.
  - `RarityConfig.Mutations` and `rollMutationId` (the regression roll) are
    unchanged.
- **Night Rush** (Friday 18:00-22:00 UTC; Day 200 s instead of 260 s).
  - Why not Double Night Loot: its "+1 rarity tier" would need a second,
    leaning item-roll path, and the loot weights and the no-lean Night
    refresh are owner-pinned.
  - The new hook `NightService.daySecondsFor()` is read once per cycle, at
    server start and at each dawn (`captureDayLength`), so a countdown on
    screen never jumps. Night stays 10 s.
  - NightService publishes `NightRush`, and the Nightfall pill then reads
    "Rush! Night in m:ss" (a one-line NightController change).
- **Holidays** (Halloween Oct 25 - Nov 1, Winter Dec 18 - Jan 2; the end
  date is exclusive). Client only:
  - museum `Decorations` lights are blended 60% toward the holiday colour
    (each `RoomFill` is skipped) and restored exactly when the holiday ends;
  - the event title and banner text show on the pill and the card.
- **State field `events`:** `{active=[{key,title,banner,kind,color,icon,endsAt}], upcoming={key,title,startsAt}?}`.
- **HUD pill** (`EventPill` in MainUI).
  - Position: below the Nightfall pill on touch, to its left on desktop.
  - Content: a countdown to the event's end, "X in 3h 12m" for an event
    starting within 6 h, and several running events take turns every 5 s.
  - It hides while the HUD is suppressed or the flyover is playing.
  - A one-time "EVENT IS ON!" card appears when an event starts. It waits
    for the loading screen and the flyover to finish.
- **No paid luck boost**, as agreed.
- **Watch:** StarterTaskController places its checklist relative to
  `NightTimer` only. On desktop, check that the event pill (left of the
  Nightfall pill, bottom-right) does not overlap the checklist card.
  `EventPill` is not in `UIStateController.HUD_ELEMENTS`; it hides itself by
  polling once per second.

### 5. Text filtering audit
`src/server/Services/TextFilter.luau` provides three functions:
- `forBroadcast(text, fromUserId)`
- `forUser(text, fromUserId, toUserId)`
- `filterResult`

It uses `FilterStringAsync` with `GetNonChatStringForBroadcastAsync` or
`GetNonChatStringForUserAsync`, all pcall'd. It fails closed and returns
"#" x the text's length.

**Findings.** No player-typed text reaches other players today:
- the CODES TextBox only answers the typer, with fixed messages;
- `/kick <name>` only echoes to the owner;
- signs, toasts and announcements use `DisplayName` or usernames.

**Must use `TextFilter`:** any future crew/team name, trade note, pet or
plot name, custom sign, or a codes feature that echoes the typed code to
others. Filter on the server before storing, replicating or broadcasting,
and re-filter stored text when it is shown.

## Profile changes (DataService, marked `[polish-events-analytics]`)
- New fields: `FlyoverSeen: boolean` and
  `AnalyticsOnboarding: {[string]: boolean}`. Both are added to the type
  and to `defaultProfile`.
- There is a pre-defaults block at the top of `reconcile`, so existing
  players are not treated as new.
- No schema bump.

## Remotes (one block, appended)
- `AnalyticsClientEvent`: a key from an allow-list; 0.5/s, burst 3.
- `FlyoverDone`: no payload; 0.2/s, burst 2.

## Owner actions
- **Creator Dashboard: none.** AnalyticsService needs no setup. The funnels
  and the economy and progression events appear under Analytics after
  publishing; the custom funnel "FirstPurchase" appears once events arrive.
- **Codex:** `docs/codex-prompts/polish-events-analytics.md` covers 15
  images: 2 backgrounds, the logo, 8 tip icons and 4 event icons. All ids
  are currently 0, which gives a text/gradient fallback.
- **Studio:** save the place after syncing. It has new ReplicatedFirst
  scripts and new modules.
- **Schedule and tuning:** event windows and multipliers are in
  `EventConfig.Events`. Set `enabled = false` to turn one off.

## Studio test plan
All commands: `ServerStorage.DebugInvoke:Invoke(cmd, "<you>", ...)`.

1. **Loading screen.** Play with a network throttle.
   - The branded screen shows, the bar climbs, the tips rotate, and SKIP
     appears after 3 s.
   - It fades out once the controllers have started.
   - Try it in the device emulator (iPhone SE, portrait and landscape): the
     text stays inside the safe area and SKIP is tappable.
   - Turn on Roblox's Reduced Motion: nothing moves.
2. **Flyover.**
   - Run `flyoverReplay`: after about 1 s the tour plays (Zone 1 room, then
     Zone 2 room, then the lane), with no HUD and no tutorial arrow.
   - SKIP works. The camera comes back behind your character and normal
     control resumes.
   - Afterwards, `flyoverState` shows `flyoverSeen = true` and
     `replaying = false`. The original value is restored.
   - A new account (Studio memory mode with a fresh profile) sees it once;
     rejoin and it does not play again.
   - **Reveal conflict:** have a container ready, run `flyoverReplay`, then
     reveal during the tour. The flyover ends instantly and the reveal
     camera plays and returns you normally.
3. **Events.**
   - `eventSchedule` lists 4 events with UTC windows, and
     `worldMutationTable` reads 90/6/2.5/1/0.5.
   - `eventForce MutationWeekend on`: the pill shows "MUTATION WEEKEND",
     the card pops, and `worldMutationTable` reads 80/12/5/2/1. Run
     `forceNight` then `forceDay` and check the new world rolls.
   - `eventForce NightRush on`, then `forceNight` / `forceDay`: the pill
     reads "Rush! Night in 3:20" and `night.remaining` is about 200.
   - `eventForce Halloween on`: museum sconce lights turn orange and the
     pill reads HALLOWEEN. `eventForce Halloween off`: the colours return.
   - `eventClock 2026-12-20`: Winter shows as active. `eventClock
     2026-09-19`: Mutation Weekend is active. `eventReset` restores
     everything.
4. **Analytics.**
   - `analyticsDump`: `sendingForReal = false` and `recent` fills up as you
     play: onboarding steps (on a new profile only), economy sources and
     sinks for upgrades and trails, progression when you place a deeper
     zone's item, and FirstPurchase steps when you open the Shop and press
     a Robux button.
   - `analyticsDebug true` sends for real and prints each event.
   - `analyticsFlush` sends the pending passive and social sums.
5. **`validate`** at startup has no failures (the new
   POLISH/EVENTS/ANALYTICS block).
