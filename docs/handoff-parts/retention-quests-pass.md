# Retention pass: daily/weekly quests + Season Pass (retention-quests-pass)

This was not run in Studio. Static checks:
- `tools/check.sh`: no hard errors, and none of the new files has a TypeError.
- Two per-file counts rose, and both are known report noise, not new code errors: `DataService` 68 -> 72 and `Remotes` 64 -> 66. The client pass describes this noise: pre-existing diagnostics get reported once more for each additional module that requires these files.
- `selene src`: 0 errors.

## What was built

### ProgressEvents (shared event bus)
File: `src/server/Services/ProgressEvents.luau`.
- It is **byte-identical to master's copy** (from the social pass). On merge, keep either one: they are the same blob.
- **Event names.** The social pass already fires `steal` (at pickup), `escape` and `reveal` (at the swap). This pass fires **its own names**, so nothing is counted twice after the merge. The hooks are one line each, marked `[retention-quests-pass]`:

| event | where | info |
|---|---|---|
| `stealDelivered` | `PlacementService.place`, after a museum container is placed at home | `{zone}` (no rarity: the container is still sealed) |
| `chaseEscape` | `GuardianService` stepChase, the chasing guard sees the red line | `{lootId, zone}` (QuestService counts one per lootId) |
| `revealed` | `HatchService.commit`, fired in the SWAP delay | `{rarity, itemId}` |
| `train` | `SpeedService.trainPlayer`, a tick that paid; amount = `TICK_INTERVAL` seconds | - |
| `earn` | `EconomyService.award`, amount = cash | `{source}` |
| `pvpHit` | `PvPService.resolveSwing`, a resolved hit | `{weapon, knockedLoot}` |
| `trapPlaced` | `PvPService.tryPlaceTrap`, after the charge is spent | - |
| `discover` | `IndexService.onDiscovered` | `{itemId}` |
| `spin` | `SpinWheelService` onTriggered, after the spin is spent and rolled | `{index}` |

- `revealed` waits for the swap so that a quest toast naming a rarity can't finish before the roulette does.
- The retention services also fire these events for other listeners:
  - `questCompleted` and `questClaimed`, with `{period, questId}`;
  - `seasonTier`, with amount = tier and `{track}`.
- **Lead: possible follow-up.** Unify `stealDelivered` and `chaseEscape` with the social pass's names if you want badges and quests to count the same moments. Only a rename in `QuestConfig.EVENT_FOR_KIND` is needed.
- `dailyStreak` (DailyRewardService) is not consumed yet. A "claim your daily reward" quest would be one template plus an `EVENT_FOR_KIND` row.
- `EconomyService.CashSource` gained `"quest"` and `"season"`. Earn quests count only `passive`, `sell` and `discovery` (`QuestConfig.EARN_SOURCES`).

### QuestConfig / QuestService
- **The lists.** Each player gets 3 daily quests (reset at 00:00 UTC) and 3 weekly quests (reset Monday 00:00 UTC).
- **Picking.** Each list is weighted, drawn without replacement, and has at most one quest of each kind. The seed comes from `userId` and the period, and the list is saved, so a rejoin shows the same quests.
- **Templates.**
  - **Kinds:** steal, rare-steal (`minRarity`, counted on `revealed` because the rarity is secret until then; the text reads "Steal & reveal N Rare+"), escape, reveal, train (seconds), earn (target = max(floor, base income x minutes)), bat hits, knock loot loose, traps, discover (capped by the items still undiscovered), and spin.
  - **Gating:** `minZone` hides a template until the player has reached that zone.
- **Profile.** Stored as `Quests = { Daily = {period, list}, Weekly = {period, list} }`, where each entry is `{id, target, progress, claimed}`. Unknown ids are dropped. When a period ends, its unclaimed rewards are dropped with it.
- **Rewards.** Computed at claim time. `award` is used, so the 2x pass does not apply.

| list | cash | Speed | season XP |
|---|---|---|---|
| daily | max($2.5K, 10 min base income) | 0.5% of the next gate, min 250, cap 500K | 100 |
| weekly | max($15K, 60 min) | 2%, min 2.5K, cap 5M | 400 |

- **Scaling.** `rewardScale` multiplies both cash and Speed, but Speed is capped after the multiplier. The caps equal the spin wheel's, so the Zone 8+ wall is untouched.
- **Claiming.** The flag is set first, then the reward is granted, then the profile is saved. Claims are idempotent.
- **Remote.** `QuestRequest("claim", period, index)`, limited to 2/s with a burst of 4. `"sync"` is limited to 1/s with a burst of 3. Arguments are validated with `Validate.integer`.
- **Replication.**
  - `QuestPush`: sent only when its content changes (JSON signature), at most once a second, plus on join, on sync and when the panel opens.
  - StatePush `retention = {claimable}`: drives the HUD red dot.
  - The rollover to a new day or week is checked every second.

### SeasonPassConfig / SeasonPassService
- **Season.** Season `S1` "Museum Heist" runs 2026-09-14 to 2026-11-09 UTC and has 30 tiers.
- **XP needed per tier.** 400 for tier 1, plus 20 for each later tier, so 20,700 XP in total, about 4.4 weeks of every quest.
- **Rewards.** Every tier has a free reward and a premium reward: cash-minutes, Speed-fraction (capped at 500K or 5M), title strings, Cat and Dog guardians (tiers 10 and 20 premium), and a trail at tier 30 premium.
- **XP sources.**

| source | XP | daily cap |
|---|---|---|
| daily quest | 100 | counts towards 800/day |
| weekly quest | 400 | uncapped |
| delivered steal | 10 each | 200/day, which also counts towards the 800/day cap |

  XP only accrues between the season's start and end dates.
- **Profile.** Stored as `Season = {id, xp, claimedFree, claimedPremium, xpDay, dayXp, dayStealXp}`. Claim keys are **tier strings**, because sparse number keys don't survive a DataStore round trip. The whole record resets when `id ~= SEASON_ID`. `Titles = {[title]=true}` is kept across seasons, but nothing renders titles yet.
- **Claiming.** `QuestRequest("season", tier, "free"|"premium")`: the flag is set first, then the reward is granted, then the profile is saved.
- **Premium.**
  - Ownership is checked live through `MonetizationService.ownsSeasonPremium`, so buying mid-season makes every tier already reached claimable.
  - Ownership changes re-push the panel: `onOwnershipChanged` is chained in init.
- **Duplicates.** A duplicate guardian or trail pays 5,000 Speed instead.
- **Dependencies.** The two services require only DataService, EconomyService and ProgressEvents. Everything else is injected through `SeasonPassService.hooks`, which is wired in one block in `init.server.luau`.

### Monetization
- **New pass.** `MonetizationConfig.SeasonPremiumPass`, **gamePassId 0** (placeholder, R$ 199 display fallback).
  - It is added to `allGamePassIds` only when the id is greater than 0.
  - New service functions: `MonetizationService.ownsSeasonPremium` and `promptSeasonPremium`.
  - `PurchaseRequest("seasonPremium")` is handled in the existing switch.
- **While the id is 0:**
  - the premium row is visible and marked "SOON";
  - the button reads "PREMIUM COMING SOON";
  - no premium claim or purchase can happen.
- **Every season needs a NEW pass id.**

### UI (`QuestController`)
- **Panel.** `Frames.Quests` is cloned from `Frames.Index`. The clone keeps the Top bar, the close button and the decorative images; all other content is removed.
- **Tabs.** The QUESTS and SEASON PASS tabs are cloned from the pack's Index button, the same way IndexController builds its tabs.
- **QUESTS tab.**
  - Two sections built from ShopKit headers, each with a "NEW QUESTS IN …" timer.
  - Quest rows are ShopKit product cards: title, "progress / target", the reward line, and a price button reading %, CLAIM! or CLAIMED.
  - A progress bar is added along the bottom of each card, and each card is tinted by its state.
- **SEASON PASS tab.**
  - The banner shows the art (if set) or a gradient, the season name and the timer, the tier and the XP bar, and the BUY PREMIUM button.
  - Below it, a horizontal scroller holds 30 tier columns. Each column has a free cell and a premium cell, and each cell is one whole button.
  - Opening the tab jumps to the first unclaimed tier.
- **HUD button.**
  - "QUESTS" is cloned from the Top **BASE** button, the GroupGiftController pattern.
  - It is not added to `Buttons.Left`, because the touch layout forces that rail into an exact 2x2 grid.
  - It shows a red count dot while anything is claimable.
  - The pack's script pairs the button with the panel by name. If the pack doesn't bind it, a fallback opener is used.
- **Mobile.**
  - The panel's UIScale undoes MainUI's phone scale and then steps down until the panel fits.
  - Tier cells, tabs and buttons have a minimum height of 44 px on screen after scaling.
  - The Track and QuestList ScrollingFrames are nested one level down, so HUDLayoutController's vertical-scroll lock doesn't apply to the horizontal track.
- **Reduced Effects.** When it is on, the bar fills without tweening and there are no punches.

## Owner actions
1. **Creator Dashboard:** create a Game Pass "Season Pass Premium (Season 1)" and paste its id into `MonetizationConfig.SeasonPremiumPass.gamePassId`. Until then, premium shows "coming soon".
2. **Season trail placeholder:** tier 30 premium grants `SeasonPassConfig.SEASON_TRAIL_KEY = "Grey"`, an existing cheap trail. Create a real season-exclusive trail row in `MonetizationConfig.Trails` (cash-only, no gamePassId, and a cash price nobody should pay, or add an "exclusive" flag to TrailShopController) and set the key.
3. **Art:** run `docs/codex-prompts/retention-quests-pass.md`: HUD icon, banner, premium badge, lock, reward icons and quest icons.
4. **Titles:** earned titles are stored in `Profile.Titles` but not displayed anywhere yet (future: an overhead tag or a leaderboard).
5. **Save the place** after syncing (new ModuleScripts).

## Studio test plan
Run every command as `ServerStorage.DebugInvoke:Invoke("<cmd>", "<You>", ...)`.
- The first command that changes anything snapshots Quests, Season, Titles, Cash, SpeedPower, guardians, trails and Lifetime.
- `questRestore` restores that snapshot. Leaving or stopping Play also restores it, inside the leave path, before the final save.
- A command that throws restores it at once.
- `questKeep` keeps the changes.

1. **Validate.** Run `validate`: there should be no failures. The retention block checks that generation is deterministic, the Monday boundary, the caps and the tier table.
2. **Show.** Run `questShow`: 3 daily and 3 weekly quests with periods and reset times. Rejoin and run `questShow` again: the same quests.
3. **HUD button.** "QUESTS" appears in the top-right strip. Click it: the panel slides up with blur, the close X works, and the other panels close.
4. **Complete and claim.**
   - Run `questComplete daily 1`: the toast appears, the red dot shows 1, and the card turns green and reads CLAIM!.
   - Click CLAIM!: cash, Speed and "+100 Season XP" arrive, the card turns grey (CLAIMED), and the dot disappears.
   - Click again: nothing happens.
   - Run `questClaim daily 1`: `claimed=false`.
5. **Real paths** (each should tick the matching quest when it is in your list):
   - steal a container and place it at home;
   - escape a chase over the red line: +1 only, even with two guards chasing;
   - reveal a container: the tick lands at the swap;
   - train on the treadmill: seconds count up;
   - earn passive income;
   - hit a player with the bat (Team Test);
   - place a trap;
   - discover a new item;
   - spin the wheel.
   - Selling counts towards earn. Robux packs, offline cash and quest rewards do not.
6. **Rare steals.** Run `questEvent revealed 1 rarity=Common` against a "Steal & reveal Rare+" quest: no progress. Run `rarity=Epic`: +1.
7. **Rollover.** Run `questNewDay`: new daily quests appear, and the weekly list is unchanged. Run `questNewWeek`: new weekly quests. Then run `questCalendarReset`.
8. **Season XP and claiming.**
   - Run `seasonXp 4500`: a tier-reached toast, then the PASS tab shows tier 9 (4,320 XP reached; tier 10 needs 4,900) and its XP bar.
   - Free cells 1-9 read CLAIM!. Claim a few: cash, Speed and titles arrive.
   - Run `seasonClaim all free`: the rest are claimed, and the results list shows "Reach tier N first!" for higher tiers.
9. **Premium placeholder.**
   - Premium cells read SOON, and the button reads "PREMIUM COMING SOON".
   - Clicking does nothing, and `seasonClaim 1 premium` returns "coming soon".
   - With a real id configured: `seasonPremium on` makes tiers 1-9 premium claimable, the Cat guardian arrives at tier 10 (after `seasonXp 400`), and `seasonPremium real` restores the real answer.
10. **Daily caps.** Deliver 25 steals in one day: season XP from steals stops at 200. Daily-quest XP stops once the day's total reaches 800. Weekly claims still add XP.
11. **Mobile.** In the device emulator (a phone, e.g. iPhone 14), check:
    - the QUESTS button does not overlap BASE or GIFT;
    - the panel fits the screen;
    - the tier track scrolls sideways and the quest list scrolls vertically;
    - the cells are easy to tap.
12. **Restore.** Run `questRestore`: `questShow` matches the start, and Cash and Speed are back.
13. **Season id change.** Change `SEASON_ID` to "S1test" and play: XP is 0 and the claims are cleared. Then change it back. The "S1" record is gone from that profile, so use an alt account or restore the snapshot first.

## Known limits
- **Quest cards are the pack's wide product card.** Long quest text relies on TextScaled. Check readability.
- **The reset timer on the section header is laid over the pack's header art.** If it overlaps the title, move `ResetTimer` in `buildSection`.
- **A player who leaves during a reveal's roulette** (a few seconds) doesn't get that reveal counted: the event fires at the swap.
- **Titles have no UI.** The season trail is a placeholder.
