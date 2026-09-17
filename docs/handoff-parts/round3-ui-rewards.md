# Round 3: Daily Rewards and offline earnings UI (round3-ui-rewards)

This pass redesigns two reward screens: the Daily Rewards panel and the
offline earnings popup. The owner said both looked "cheap and generic".

It was not run in Studio. I had no Studio access.

Static checks:
- `tools/check.sh` reports no hard errors.
- The new and changed files have 0 TypeErrors.
- The ShopKit and UIAnim counts went up (8 to 12, and 7 to 8). This is the
  known duplicate-reporting effect: the new `RewardFx` requires both files,
  so their existing diagnostics are reported again. No new diagnostics were
  added.
- `selene src` reports 0 errors and 90 warnings, the same as before.

## What changed

| File | Change |
|---|---|
| `src/shared/Util/RewardFx.luau` | **New.** Shared look and motion for both screens: <ul><li>the pack-style plate (dark outline, gradient face, gloss, studs)</li><li>outlined text in the pack's FontFace, read from the pristine `StarterGui.MainUI.Frames.Index` header, with FredokaOne as the fallback</li><li>code placeholders for the rays, flame, check mark, padlock and clock</li><li>confetti, a ray flare, a rising count-up amount, and coins that fly to the HUD counters</li><li>a `LoopSet` that owns every repeating tween or loop, so a panel can stop all of them when it hides</li></ul> |
| `src/shared/Config/RewardUiConfig.luau` | **New.** Five art keys (all `rbxassetid://0` for now) and the feel numbers: coin count, confetti count, ray turn time, offline count-up time. |
| `src/client/Controllers/DailyRewardController.luau` | Rewritten as a reward calendar. The popup, HUD button, red dot and remotes behave as before. |
| `src/client/Controllers/OfflineEarningsController.luau` | Rewritten as a "WELCOME BACK!" reveal. |
| `src/server/Services/OfflineService.luau` | Small change: remembers the capped away seconds for this session and sends them as the new StatePush field `offlineAway`, through `StateService.addProvider`. The value is cleared on claim and on release. The payout logic is unchanged. |
| `src/shared/Remotes.luau` | New block at the end with `RewardsUIPreview`. It is server to client and Studio debug only. There is no server handler. |
| `src/server/Services/DebugCommands/RewardsUI.luau` | **New.** Preview commands (see below). They never touch the profile. |
| `src/shared/Config/validate.luau` | One block that checks `RewardUiConfig`. |
| `docs/codex-prompts/round3.md` | Section "Daily rewards & offline earnings" with 5 image requests. |

`DailyRewardService` did not need changes: the preview push already carries
the `cash`, `speed` and `kind` fields for each day.

### Daily Rewards calendar

The panel is still a clone of the pristine Index panel, named `Daily`, so the
pack still handles the slide, blur, close button and one-panel-at-a-time
rule. As in `QuestController`, the clone keeps only the header, the UI
modifiers and the pure-decoration images.

**Header**
- The pack's title bar is recoloured gold to orange and titled
  "DAILY REWARDS".
- The bar's ZIndex is raised so it always draws above our content.
- Below the bar:
  - an orange streak pill with a code-drawn flame (three teardrop layers)
    and gold "N DAY STREAK" text ("START A STREAK!" at 0);
  - a 7-segment week bar. Claimed segments are filled orange. Today's
    segment is gold and pulses while the reward is claimable.
- A blue-to-violet plate sits behind everything below the header.

**Tiles**
- Layout:
  - `layoutTiles()` works out the geometry from the tile area's pixel size
    and applies it as scale values.
  - Desktop: all 7 tiles in one row. Day 7 is 1.5 tiles wide.
  - Phones (`Device.isPhone()`), or a panel too narrow for one row: days 1-4
    on the first row, days 5-6 plus a double-width day 7 on the second.
  - The layout runs again when the area is resized or the touch mode
    changes.
  - The tile area has `ClipsDescendants`, so nothing can render outside it.
- Each tile has:
  - a "DAY n" ribbon;
  - a large icon: the day's own icon if set, otherwise the pack's cash or
    speed icon;
  - the amount in large bold text, with a caption ("CASH", "SPEED", or
    "+500K SPEED" on day 7);
  - a halo, and a glow stroke that gets brighter and thicker from day 1 to
    day 6.
- Day 7 is the gold "DAY 7 - GRAND PRIZE" tile, with spinning rays and a
  repeating sheen.
- States:
  - **Claimed:** darkened, green check stamp, "CLAIMED".
  - **Today, claimable:** pulsing gold edge, a 3 px bob, a sheen and a
    "CLAIM!" tag. The whole tile is the touch target (an invisible `Hit`
    TextButton), so it passes the 44 px rule on phones.
  - **Locked:** art darkened but text still readable, a padlock, and
    "TOMORROW" or "IN n DAYS".

**Footer**
- A dark pill with a code-drawn clock and "Next reward in HH:MM:SS" (or
  "Today's reward is ready!").
- A large glossy CLAIM button. It is green with a sheen when claimable, and
  grey with "COME BACK IN HH:MM:SS" when not.
- The button's minimum height is at least 44 px after MainUI's UIScale.

**Claim moment**
1. Pressing CLAIM keeps today's tile in its "claimable" look and fires
   `DailyRewardRequest("claim")`.
2. When the server's `DailyRewardPush` confirms, `celebrate()` plays:
   - the tile pops and sheens;
   - rays flare and confetti bursts behind the tile (both clipped to the Fx
     layer);
   - coins fly into `MainUI.Bottom.Currencies.Cash` (speed arrows into
     `.Speed` for Speed days), and the counter punches when the first one
     lands;
   - "+$X" (and/or "+X SPEED") counts up from 0 and rises;
   - `RevealPop` plays (the server still sends its own `UpgradePurchase`
     cue and toast);
   - after 0.5 s the tile flips (squashes to zero width, repaints as
     CLAIMED, opens again) and the check stamp pops in.
3. If the claim is refused or lost, the tile goes back to its normal look
   after 4 s.
4. With Reduced Effects on, there are no coins, confetti, rays, bob or flip.
   The stamp fades in and the amount is shown without animation.

Repeating decoration runs only while the panel is visible. It stops when the
panel hides and when Reduced Effects changes. The flying coins are drawn on
a temporary `RewardFxUI` ScreenGui (DisplayOrder 60). This is the only thing
drawn outside the panel, because the coins have to travel to the HUD.

### WELCOME BACK popup

- The card is a bright sky-blue to violet plate with a thick outline.
- Size limits: scale size 0.82 x 0.74, aspect ratio 1.15, clamped to
  250x218 - 480x420 px. It always fits the screen.
- Behind a large cash pile: a glow and slow rays, clipped to the card face.
- Text on the card:
  - "WELCOME BACK!" in gold;
  - "You were away 2h 14m (max 6h)";
  - the amount, counting up from $0 over 1.3 s with Quad-out easing, then a
    punch;
  - "at N% of your income", where N comes from
    `GameConfig.OFFLINE_EFFICIENCY` (it shows 25% once the other agent's
    change to 0.25 lands).
- The CLAIM button is glossy green with a sheen every 2.2 s and a minimum
  size of 150x44.
- Away line rules:
  - If the away time reached the cap: "You were away 6h+ (max 6h)".
  - If the pending amount was carried over from an earlier session (no
    `offlineAway` this session): "While you were away you earned (max 6h)".
- When the claim is paid (the push zeroes `offlineCash`):
  - coins fly from the amount into the HUD cash counter (which counts up by
    itself);
  - the popup's amount counts down to $0;
  - `RevealPop` plays;
  - after 0.55 s the card grows slightly and then shrinks away with a Back
    easing.
- With Reduced Effects on, there are no rays, bob, sheen or coins. The card
  appears at full size and fades out.
- I found no Cash-multiplier product meant for this screen in
  MonetizationConfig, so the popup shows no offer. I added no new products.

## How to preview each state (Studio, server command bar)

These commands only fire `RewardsUIPreview` at your client. The Daily preview
uses your real 7-day amounts if they have loaded, and made-up amounts if
not. Pressing CLAIM in a preview plays the full claim moment on your screen
and sends nothing to the server. Closing the panel discards the preview
data.

```lua
local D = game.ServerStorage.DebugInvoke
D:Invoke("rewardsUiDaily", "<you>")                 -- today = day 3, claimable
D:Invoke("rewardsUiDaily", "<you>", "today", 6)     -- today = day 6 (brightest normal tile)
D:Invoke("rewardsUiDaily", "<you>", "claimed", 4)   -- day 4 done, timer + grey button
D:Invoke("rewardsUiDaily", "<you>", "grand")        -- day 7 GRAND PRIZE claimable
D:Invoke("rewardsUiDaily", "<you>", "fresh")        -- streak 0, day 1
D:Invoke("rewardsUiDaily", "<you>", "done")         -- whole week claimed
D:Invoke("rewardsUiOffline", "<you>")               -- $473M, away 2h 14m
D:Invoke("rewardsUiOffline", "<you>", 1.2e9, 30000) -- capped away line
D:Invoke("rewardsUiOffline", "<you>", 5000, -1)     -- no away line
```

Real flows still use the existing commands. They restore the profile when
they finish:
- `offline` (DebugService) runs the real offline settle and claim.
- `retentionDailyClock "<you>" 86400` makes the Daily reward claimable
  again for a real claim. Use `retentionDailySim` for the rollback test.

## Test plan for the lead

1. Desktop:
   - Run `rewardsUiDaily ... today 3`. Expect one row of 7 tiles, day 7
     wider and gold with turning rays, days 1-2 claimed (check stamp),
     day 3 pulsing and bobbing, and days 4-7 with a lock and
     "TOMORROW" / "IN n DAYS".
   - Press the tile or the footer CLAIM. Check the pop, rays, confetti,
     coins flying into the HUD cash counter, "+$X", the flip to CLAIMED,
     and the streak bar and pill updating.
2. `grand`: check that the day 7 claim sends both coins and speed arrows,
   and both "+" amounts appear.
3. `claimed 4`: the footer should be grey with a running
   "COME BACK IN" timer.
4. Device emulator (a phone, landscape): the tiles should form two rows
   (4 + 3, day 7 double width) with nothing clipped at the panel edges.
   Every button should be at least 44 px.
5. Settings, VFX OFF (Reduced Effects): repeat step 1. There should be no
   bob, rays, confetti or coins. The stamp fades in and the amount shows
   without animation.
6. `rewardsUiOffline` (all three variants): check the count-up, the away
   line and the rate line. Press CLAIM: coins fly to the HUD cash counter
   and the card pops away. Repeat with VFX OFF.
7. Real paths:
   - Rejoin after being away: the real popup should show the right away
     time (StatePush `offlineAway`).
   - A real daily claim through `retentionDailyClock` should play the claim
     moment once. The HUD red dot and the once-per-session auto-open should
     behave as before (they wait for the offline popup to close).
8. Check the pack header: the gold recolour should not tint the close X,
   and the X should still close the panel.

## Owner actions

- None in the Creator Dashboard. No products, passes or badges.
- Codex art: 5 images, listed in `docs/codex-prompts/round3.md`. Their ids
  go in `RewardUiConfig`.

## Known limits

- Nothing here was run in Studio. The main visual risks:
  - The recolour of the pack's `Top` bar is a guess at its gradients. It
    only changes UIGradients that are not on text and not under `Close`.
  - The pack Index panel's real size and aspect decide whether the desktop
    layout is one row. It falls back to two rows if one row would make the
    tiles much smaller.
- Sheens are clipped with `ClipsDescendants`, which ignores rounded
  corners, so a faint sliver can show at a corner during a sweep. The old
  offline button had the same issue.
- If an offline preview is started while the real offline popup is open,
  the real popup closes for the rest of that session. The pending cash stays
  banked for the next join. This only affects Studio.
