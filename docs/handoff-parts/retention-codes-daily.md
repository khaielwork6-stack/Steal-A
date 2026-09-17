# Retention area: redeem codes and daily login streak

Built 2026-09-17 on branch `worktree-agent-a06e2ee5b81763021`.

This was not run in Studio. I had no Studio access.

Static checks:
- `tools/check.sh` reports no hard errors.
- The new files report 0 TypeErrors.
- `selene src` reports 0 errors and 90 warnings, the same as the baseline.
- The per-file TypeError counts went up in files the new modules require,
  directly or indirectly (BaseGuardianService, LootService, DataService,
  Remotes, ...). This is the known duplicate-reporting effect described in
  `client.md`: an existing diagnostic is reported once more for each extra
  module that requires the file. No new diagnostics were introduced.

## What was built

### Files

| File | Role |
|---|---|
| `src/shared/Config/CodesConfig.luau` | Code list, matching (`normalise`), rate-limit and lockout numbers, header icon key |
| `src/shared/Config/DailyRewardConfig.luau` | The 7 days, grace, pure streak rules (`status`), icon keys |
| `src/server/Services/RetentionRewards.luau` | Shared helper (not a service): scales a reward spec, then pays or previews it |
| `src/server/Services/CodeService.luau` | The redeem remote, checks, lockout, and paying exactly once |
| `src/server/Services/DailyRewardService.luau` | Streak state (StatePush `daily`), 7-day preview push, claim, UTC rollover loop |
| `src/server/Services/DebugCommands/Retention.luau` | Studio test commands (see below) |
| `src/client/Controllers/CodesController.luau` | CODES row at the top of the Settings panel |
| `src/client/Controllers/DailyRewardController.luau` | Daily panel, top-strip HUD button with red dot, once-per-session popup |

Shared files, each with a small block marked `[retention-codes-daily]`:
- **`Remotes.luau`:** one block at the end of NAMES, with 4 remotes.
- **`DataService.luau`:** the Profile type, `defaultProfile` and `reconcile`. No schema bump.
- **`EconomyService.luau`:** `CashSource` gains `"code" | "daily"`. This one line may conflict if another agent also adds tags.
- **`validate.luau`:** one block.
- **`init.server.luau`:** service start, plus one line in the join block.
- **`init.client.luau`:** two `startLater` calls.

### Profile fields (additive, repaired by `reconcile`)
- **`RedeemedCodes: { [code]: os.time }`.** Only ever added to. `reconcile` repairs it only when it is not a table, the same way it treats the receipt list.
- **`DailyStreak: number`.** The number of consecutive claims.
- **`DailyLastClaimDay: number`.** The UTC day number, `floor(os.time()/86400)`. 0 means never claimed.

### Remotes
- **`RedeemCodeRequest(text)`**, client to server.
- **`RedeemCodeResult(ok, message)`**, server to client. It only tells the text box whether to clear or keep its text. Toasts go through `Notify`.
- **`DailyRewardRequest("claim" | "preview")`**, client to server. Limited to 1 per second with a burst of 3.
- **`DailyRewardPush(preview)`**, server to client. The 7-day amounts change with income every second, so they are not sent on StatePush. This push goes out only:
  - on join, after the settle;
  - when the client asks;
  - after a claim;
  - at the UTC rollover.

The StatePush field `daily` (added with `StateService.addProvider`) is small: `{ day, streak, claimable, claimedToday, nextResetAt }`.

### Codes
- **Matching.** Input is trimmed, upper-cased, and limited to letters and digits, at most 24 characters. A disabled code is indistinguishable from an unknown one ("That code is invalid.").
- **Checks, in order.**
  1. Lockout.
  2. Rate limit: 5 attempts per minute, as a token bucket with a burst of 5.
  3. Shape.
  4. The code exists and is enabled.
  5. The code has not expired (`expiresAt`, UTC).
  6. The player has not already redeemed it.
  7. `minZone`, checked against HighestZoneReached.
- **Lockout.** 8 failed attempts within 10 minutes lock the player out for 5 minutes. Failures are tracked per UserId for the life of the server, so rejoining does not reset them.
- **Paying exactly once.** The code is marked as redeemed before the payout, in a step that doesn't yield. The payout runs in a pcall; if it throws, the mark is rolled back. The server then does a `pushNow` and a `DataService.save`, and only after that tells the player.
- **Launch codes.**
  - **`MUSEUM`:** 10 minutes of base income, floor $2,500. Same income basis as the Cash packs and the wheel (2x pass and boosts divided out).
  - **`RELEASE`:** Speed equal to 1% of the next zone's gate, floor 500, cap 250K. For a Zone 8 player that is 250K, 0.04% of the 700M wall.
  - **`BETATEST`:** a disabled example that expired on 2026-01-01.
- **Owner decision needed on MUSEUM.** The smallest Robux Cash pack (`Cash24K`, 45 R$) also pays 10 minutes of income (floor 75K). A free, one-time code paying the same number of minutes was the brief's example. Lower `cashMinutes` if that overlap bothers you.

### Payout paths (RetentionRewards)
- **Cash:** `EconomyService.award` (the exact figure, source tag `code` or `daily`).
- **Speed:** `SpeedPower +=`, then `SpeedService.applyMovement`.
- **Guardian:** `BaseGuardianService.grantWon`, the same path the spin wheel uses. If the player already owns that guardian, they get the day's `duplicate` Speed instead. When no `duplicate` is set, they get `SpinWheelConfig.DUPLICATE_GUARDIAN_SPEED` (5000).
- **Note on `DataService`:** its `GuardiansWon` comment still says "only by SpinWheelService". Codes and the daily streak now add to it too, through the same `grantWon`.

### Daily streak
- **Days** (the Speed amounts are capped):

  | Day | Reward |
  |---|---|
  | 1 | 3 minutes of income, floor $500 |
  | 2 | 0.4% of the gate, floor 150, cap 100K |
  | 3 | 5 minutes of income, floor $1.5K |
  | 4 | 0.6% of the gate, floor 300, cap 150K |
  | 5 | 10 minutes of income, floor $3K |
  | 6 | 1% of the gate, floor 600, cap 250K |
  | 7 | **Panda Guardian**; if already owned, 2% of the gate, floor 5K, cap 500K |

- **Effect on the Zone 8 wall.** A full week is at most about 1M Speed, against a 700M gate.
- **Streak rules.**
  - One claim per UTC day.
  - Claiming the next day continues the streak.
  - If more than `GRACE_DAYS` whole days are missed, the streak restarts at day 1.
  - `GRACE_DAYS` defaults to **0**, the strict rule from the brief. Set it to 1 to forgive one missed day.
  - After day 7 the cycle wraps to day 1. The streak count keeps rising and is shown to the player.
  - A last-claim day in the future counts as "claimed today", so a player is never paid twice.
- **Join hook.** `DailyRewardService.onProfileReady(player)` runs in the join block right after the mailbox delivery, which is after `OfflineService.settle` and the first full push. Until it runs, `daily` is nil, so the client can't show the popup early.
- **UTC rollover.** A loop checks every 20 seconds. When `claimable` flips, it marks the state dirty and resends the preview.

### Client
- **Codes placement.** The CODES row sits at the top of the Settings panel, not behind a new HUD button. The reasons:
  - The desktop rail and the phone 2x2 block already hold the 4 tiles that HUDLayoutController lays out. A 5th tile would break the touch layout.
  - Players expect codes in Settings.
  - The row costs no screen space.
- **How the CODES row is built.**
  - It is a clone of the Shadows toggle row, placed first with LayoutOrder set to the lowest existing value minus 1.
  - The OFF button is hidden, and ON becomes REDEEM.
  - A TextBox is laid out between the title and the button, measured at runtime.
  - Enter or REDEEM submits the text. Empty input shows a local toast. Presses are throttled to one every 1.2 seconds on the client.
- **Daily panel.**
  - It is a clone of the pristine `StarterGui.MainUI.Frames.Index`, named `Daily`, in `Frames`. The pack pairs it with the button of the same name, which gives it the slide, blur and close X. HUDLayoutController enlarges it on touch.
  - It shows 7 `ShopKit.card()` cards in a 4 + 3 grid:
    - today has a gold outline and a TODAY ribbon;
    - past days carry a CLAIMED stamp;
    - an owned guardian day reads "... (owned)".
  - The Index "Features" line shows the streak and a countdown.
  - The CLAIM button turns into "COME BACK IN hh:mm:ss" after the claim.
- **Daily HUD button.**
  - A round orange button in the top strip at LayoutOrder -1, left of the Settings gear.
  - It has a "Daily" caption and a red dot while a reward is claimable.
  - Its touch target is at least 44 px after the UIScale, built the same way as the gear.
- **Popup.** It opens automatically once per session when `daily.claimable` has been true for 2.5 seconds, but only when all of these hold:
  - the offline-earnings modal is closed;
  - no panel is open in `Frames` or in `TrailShopLayer`;
  - UIStateController holds no claim;
  - the player is not carrying anything;
  - the tutorial stage is 9 or higher (complete).

  The pack's open function is local to its own script, so the popup copies it: slide up from below, then `UIBlur` 18. It holds a `daily` UIStateController claim to hide the HUD. The pack's close X still closes it, and the claim is released when the panel hides. Reduced Effects snaps the panel into place with no slide.
- **Toasts while the panel is open.** When the popup opened the panel, UIStateController hides `Notifications` too, so the claim toast isn't visible until the panel closes. The card shine and punch are the feedback. Other panels that take a claim (gift, trail shop) behave the same way.

## Placeholders
- **Icons.** `DailyRewardConfig.HUD_ICON`, `DailyRewardConfig.Days[1..7].icon` and `CodesConfig.HEADER_ICON` are all `rbxassetid://0`. While they are:
  - the HUD button shows a text "7";
  - the cards use the pack's cash, speed and crate icons;
  - the Codes row shows no icon.

  The asset prompt is in `docs/codex-prompts/retention-codes-daily.md`.
- **Robux.** No products or gamepasses. Nothing to create on the Creator Dashboard.

## Owner / lead actions
- **Merge conflicts.** Watch for them in `EconomyService.CashSource` and in the `Remotes.NAMES` tail.
- **Save the place** after syncing. There are 8 new ModuleScripts.
- **Settings panel.**
  - If the Settings ScrollingFrame has a fixed CanvasSize, the CODES row (and the Graphics row from the client pass) may push the last row out of view.
  - If its UIListLayout doesn't sort by LayoutOrder, CODES won't be first.
  - Fix either one in the place.
- **Choose the guardian gift.** Day 7 gives away the Panda (a 399 R$ pass) for free to anyone who keeps a 7-day streak. After that it converts to Speed. Change `guardianKey` if you want a different animal, or remove it and use Speed only.
- **Timing of the pass check.** `BaseGuardianService.owns` depends on the cached game-pass check. A Panda pass owner who claims day 7 before that check finishes gets `GuardiansWon.Panda` (which is harmless) instead of the Speed conversion.
- **Adding or retiring a code.** Edit `CodesConfig.Codes`, then publish. Never reuse a code string for a new reward: anyone who redeemed the old one is blocked from the new one.

## Studio test plan
Call each command as `local D = game.ServerStorage.DebugInvoke`. Every command that touches the profile restores it and saves, even on error.

1. **Config validation.** Run `D:Invoke("validate")`. There should be no failures. This covers the codes, the 7 days, the Speed caps and the streak rules on fixed clocks.
2. **List codes.** Run `D:Invoke("retentionCodes", "<you>")`.
   - MUSEUM and RELEASE should show `forYou = "ok"`, or `redeemed` if you already redeemed them for real.
   - BETATEST should show `invalid`.
3. **Redeem with rollback.** Run `D:Invoke("retentionRedeem", "<you>", "museum ")`. Expect:
   - `first = ok` and `paidCash` equal to `max(2500, baseIncome*600)`;
   - `second = redeemed`;
   - `passed = true`;
   - `restored.cashDelta` equal to the paid amount, then taken back out.

   Repeat with `"RELEASE"`: `paidSpeed` should be `max(500, min(1% of next gate, 250K))`. With `"BETATEST"`, expect `first = invalid`.
4. **Real UI redeem.**
   - Open Settings. CODES should be the top row.
   - Type ` museum` and press Enter. A success toast appears, the box clears and flashes green, and Cash rises.
   - Try it again: "You already redeemed that code."
   - Type `nope` 8 times: "Too many attempts - try again in 5 min".
   - Run `D:Invoke("retentionResetLimits", "<you>")` to clear the lockout.
   - This test is a **real** redemption. MUSEUM stays redeemed on your profile. Use an alt, or accept that.
5. **Daily state.** Run `D:Invoke("retentionDaily", "<you>")`.
   - `ready` should be true.
   - `status.claimable` should be true if you haven't claimed today.
   - `preview.days` should have 7 entries with your scaled amounts, and day 7 should be `guardian`, or `speed` with `converted = true` if you own the Panda.
6. **Daily simulation.**
   - `D:Invoke("retentionDailySim", "<you>", "newday")`: `before.day = 4`, `claimed = true`, `secondClaim = false`, `streakAfter = 4`, `passed = true`.
   - `D:Invoke("retentionDailySim", "<you>", "missed")`: `before.day = 1`, `streakAfter = 1`, `passed = true`.
   - `D:Invoke("retentionDailySim", "<you>", "week")`: 7 claims, streaks 1 to 7. Claim 7 pays the Panda (it appears in the bay if the bay was empty), or pays Speed if you own it. Afterwards, `restored.guardiansAdded` lists Panda, and the bay goes back to what it was.
7. **Popup.** Test on an alt or a fresh profile with the tutorial finished and nothing claimed today. Join and wait for any offline modal to close. About 2.5 seconds later the Daily panel slides up with day N highlighted, and the HUD is hidden.
   - Press CLAIM. The card shines, the stamp shows CLAIMED, and the button reads "COME BACK IN ...". Cash or Speed changes.
   - Close the panel with X. The HUD returns, and the red dot on the Daily button is gone.
   - It must not open while you carry loot, stand on the treadmill, or have Shop or Settings open. It opens once those are closed, still only once per session.
8. **Midnight.** Run `D:Invoke("retentionDailyClock", "<you>", 86400)`.
   - After a claim, this makes tomorrow claimable. The red dot returns within about 1 second, and the panel shows CLAIM.
   - A claim made while the clock is shifted is **real**. Use `retentionDailySim` for claims.
   - Run `D:Invoke("retentionDailyClock", "<you>", 0)` to reset.
9. **Persistence.** Run `persistTest`. There should be no errors. `RedeemedCodes`, `DailyStreak` and `DailyLastClaimDay` survive the JSON round trip.
10. **Device emulator (phone).**
    - The Daily button in the top strip doesn't overlap BASE, GIFT or the gear, and is easy to tap.
    - The panel is enlarged, and the 7 cards are readable.
    - The CLAIM button is at least 44 px tall.
    - In Settings, the CODES text box and REDEEM button fit the row and don't cover the CODES title. If they do, adjust `placeBox` in CodesController.
