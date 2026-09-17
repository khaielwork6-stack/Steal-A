# Trading, gifting and new leaderboards (trading-gifting-boards)

Nothing here was run in Studio.
- `tools/check.sh`: no hard errors.
  - The TypeError counts for LootService, LootModel, DataService, Remotes, MysterySpawnService, SpeedService, MysteryModel, BaseService, CarryService and TreadmillModel went up by 2 to 14. These are the existing diagnostics, repeated once for each new module that requires those files. No new code line has an error.
  - LeaderboardService dropped from 33 to 0.
- `selene src`: 0 errors. There is one new warning: `_G` in TradeController, which is used to call the pack's `_G.CloseAllUIFrames`.

## What was built

### 1. Trading (same server)

**Files**
- `shared/Config/TradeConfig.luau`: all the numbers.
- `server/Services/TradeLogic.luau`: pure rules and the swap.
- `server/Services/TradeService.luau`: requests, the trade window, the handshake, saving and the log.
- `client/Controllers/TradeController.luau`: all the trade UI.

**Starting a trade**
- The world prompt:
  - It is a local "Trade" prompt, key **T**, 7 studs, 0.3 s hold, placed on other players' root parts.
  - It is enabled only while both players are on the lobby apron (Z between -78 and 0), so it never competes with the steal, rob or pad prompts.
  - It is also off while you are carrying loot, while you are already trading, and while trading is unavailable to you.
- The new HUD button **Trade** (purple, 5th in the rail) opens `Frames.Trade`:
  - a list of the players in the server, each with a TRADE button;
  - a status line that says why you can't trade, when you can't.
  - `TradeConfig.HUD_BUTTON = false` removes the button.

**Requests**
- A request lasts 20 s. The target sees a top-centre popup with ACCEPT, DECLINE and BLOCK, and requests queue behind each other.
- BLOCK ignores that player for the rest of the session. The requester is only told "declined".
- There is a 10 s cooldown for each asker/target pair, which also starts on a decline.
- A target can have at most 3 requests pending.
- If B has already asked A and A asks B, the trade window opens.

**The trade window**
- It is its own ScreenGui (`TradeUI`), because it opens on a server event. Opening it closes any open pack panel and claims the HUD suppressor `"trade"`.
- Layout:
  - two columns, YOU GIVE and <NAME> GIVES, each with 6 slots;
  - a card per item showing the 3D thumb, name, rarity, size, mutation and income;
  - a Cash box (accepts "1.5M" or "250k");
  - your storage strip (tap to add; sealed containers are shown dimmed and can't be added; tap your own card to remove it);
  - READY/UNREADY, CONFIRM and CANCEL buttons;
  - a countdown;
  - a lopsided warning.
- The panel shells are stripped clones of `Frames.Index` (Top bar and styling only). Column headers use `ShopKit.header()`.

**Rules (server)**
- Only items in `profile.Inventory` can be traded, and only if they are revealed (`Hatched ~= false`), not `RobbedBy`, and have a known ItemId.
- **Sealed containers cannot be traded.**
- At most 6 items per side.
- Cash must be a whole number from 0 to min(balance, 1e15).
- **Any offer change un-readies both sides** and cancels the countdown.
- When both sides are READY, a 3 s countdown runs. After it, CONFIRM unlocks, and both sides must confirm.
- At confirm, `finalize` checks again that:
  - both players are present and loaded;
  - the policy allows trading;
  - neither player is carrying loot;
  - the rate limit is not exceeded.
- It then calls `TradeLogic.execute`, which checks again, in the same step:
  - both offers (the items are still stored and revealed, and the Cash is still there);
  - storage capacity on both sides. An even swap into a full storage is allowed.
- The swap itself happens in memory with no yield. An InstanceId that clashes with one the receiver already has is regenerated.
- After the swap:
  - both sides get a push and a toast;
  - both profiles are saved in parallel (`DataService.save`, with session locking as before);
  - the log is written.
- Every 0.5 s a watch loop checks each open window. It:
  - closes it if a player leaves, picks up loot, or loses policy;
  - closes it after 180 s of inactivity;
  - removes offered items that left storage, and resets Cash that is no longer covered. Either change resets the handshake.

**Anti-scam**
- Rarity, size, mutation and income are shown on both sides.
- Any change resets the handshake.
- No trading for 30 s after joining (the panel counts down).
- A player can make at most 8 completed trades per 10 minutes.
- **Lopsided warning:** shown to the side giving at least 4 times the card income it gets, when that is at least $10/s.
- The remote allows 6 requests/s with a burst of 14. Every argument is validated (userId integer, id string of at most 64 characters, finite Cash, boolean ready).

**Policy**
- Trading is disabled entirely for a player whose `MonetizationService.policy(player).paidItemTradingAllowed` is not true.
- An unknown policy counts as not allowed, and the panel says "Checking...".
- StatePush has a new field, `trade = { allowed, reason, readyAt, inTrade }`, added via `StateService.addProvider`.

**Night, carrying and leaving**
- Trades are allowed at night.
- Carrying loot blocks trading.
- If a player leaves, the window closes with no swap.

**Moderation log**
- DataStore `TradeLog_v1`:
  - `t_<unix>_<tradeId>` holds `{Id, At, JobId, PlaceId, A={UserId, Name, Cash, Items[]}, B={...}}`. It is tagged with both user ids, which covers GDPR erasure.
  - `u_<userId>` holds that user's last 50 trade keys.
- In Studio memory mode the log is kept in memory only (`tradeLogs`).

**Known limit**
- DataStores have no cross-key transaction. If the server crashes in the roughly 1 s between the in-memory swap and both saves landing, one side's half can be lost.
- Session locks rule out cross-server duplication.
- The log is always written, so moderation can repair the loss.

**Not done**
- Items received in a trade are **not** added to the receiver's Index. MailboxService doesn't add them either. Say if trading should count as discovery.

### 2. Gifting

**Config**
- `MonetizationConfig.GiftProducts` has 9 rows of `kind = "Gift"`, each with `giftOf`, the same price and the same floor as its pack:
  - `GiftCash24K`, `GiftCash200K`, `GiftCash800K`, `GiftCash4M`, `GiftCash8M`
  - `GiftSpeed150K`, `GiftSpeed1M`, `GiftSpeed10M`, `GiftSpeed1B`
- **All ids are 0.**
- Id-0 rows are in `ProductByKey` only, never in `ProductById`.
- `validate` checks each gift for price and amount parity, and that every pack has a gift.

**Server (`GiftService.luau`)**
- **Prompt:** `GiftRequest(recipientUserId, giftKey)` runs these checks:
  - the recipient is in this server and loaded;
  - the recipient is not the buyer;
  - the product id is greater than 0.

  It then remembers `buyer -> {recipient, key, shownAmount}` for 15 min, keyed by buyer userId, and calls `MonetizationService.promptGiftProduct`. That is a new function; `promptProduct` still refuses gift keys coming from the client.
- **Receipt:** ProcessReceipt has a new `kind == "Gift"` branch that calls the installed gift handler (`setGiftHandler`). The receipt is recorded on the **buyer's** profile and saved as usual. The handler works like this:
  - **With a remembered recipient:**
    - It always delivers through `MailboxService.send` with the fixed id `gift_<PurchaseId>`, so a replayed receipt never queues or grants twice.
    - Cash is the recipient's scaled amount (`cashPackAmount`) if they are still in this server; otherwise it is the amount captured when the buyer picked them.
    - Speed is the pack amount.
    - The source tag is `"gift"`, which does not count as weekly earnings.
    - The buyer is told "sent to X", or "arrives when they next play" if the recipient has left.
    - If the send fails, the intent is restored and the receipt returns `NotProcessedYet`.
  - **With no intent** (server restart, intent lapsed, different pack):
    - The pack is granted to the buyer, exactly like a normal pack.
    - The buyer is told "We couldn't tell who your gift was for...".

**MailboxService changes** (small and additive)
- `MailEntry` accepts an optional stable `id`. A duplicate id already in the mailbox makes the send a no-op success.
- `deliver()` now runs one extra pass when mail arrives during a pass that is already running. Previously such mail waited for the 30 s poll.

**Client**
- `GiftShopSection.luau` adds a GIFT A FRIEND section at the bottom of the Shop:
  - a picker button, "GIFT TO: name >", which cycles through the other players;
  - a pack card per gift (title "GIFT $75K+", with "Scales with their income" on the Cash cards).
- The section is hidden unless `StatePush.gifts.enabled` is set (some gift id is greater than 0) and at least one other player is present.
- ShopController has 2 marked lines: build and update.

**Policy:** gift packs are plain Cash or Speed, so they follow the normal purchase rules.

### 3. Leaderboards

**New boards**

| Board | Store | Value shown |
| --- | --- | --- |
| Total Steals | `GlobalSteals_v1` | `Lifetime.Steals` |
| Index % | `GlobalIndex_v1` | discovered item count, shown as "63% (61/96)" |
| Time Played | `GlobalPlayTime_v1` | `Lifetime.PlaySeconds`, shown as "12h 05m" |
| Weekly Cash Earned | `WeeklyEarned_<ISO week>`, e.g. `WeeklyEarned_2026W38` | gameplay earnings this week |

**How values are collected**
- **Weekly:** only the sources passive, sell, discovery, index and offline count (`BoardConfig.WEEKLY_SOURCES`). Purchases, gifts, trades, spin wheel and debug grants are excluded.
  - `EconomyService.onAwarded` is a new, non-yielding listener list, called from `award`.
  - The weekly total is stored in the new field `profile.WeeklyEarned = {Week, Amount}`. It resets when the week string changes, and a stale week reads as 0.
- **PlaySeconds:** accrued every 15 s. The remainder is added in `onBeforeRelease`.

**New profile fields** (DataService, marked `[trading-gifting-boards]`, no schema bump)
- `Lifetime.PlaySeconds`: it is repaired in `reconcile`, because the fill-in only adds missing top-level keys.
- `WeeklyEarned`

**Write budget**
- A stat is written only when its value changed.
- Weekly is written only when greater than 0.
- PlayTime is written at most every 300 s per player; the leave write is forced.
- Players are submitted one at a time, spread over the first third of the 60 s cycle.
- Writes are skipped while the `SetIncrementSortedAsync` budget is below 8.

**Physical boards**
- At start, `Workspace."Leaderboard Money"` is cloned before its post and header are added. A model the owner has already placed under the same name ("Leaderboard Steals", etc.) is used instead of a clone.
- Placement (`BoardConfig.Boards`):
  - Steals goes toward the centre of Money, and Weekly goes outward.
  - Index goes toward the centre of Speed, and PlayTime goes outward.
  - Each board is offset by plate width + 3 studs.
  - It must stay 4 studs inside the lobby side edge and outside the lane mouth.
  - Before placing, a `GetPartBoundsInBox` check (ignoring Map, LobbyMarkers and invisible non-colliding parts) makes sure it doesn't overlap the booth, stand, chest or other boards. If it does, the board moves one slot further, then to the other side.
  - With no free spot, the board is not built and a warning is logged.
- **Owner override:** add an anchored part `Workspace.LobbyMarkers.LeaderboardSteals` (or `LeaderboardIndex`, `LeaderboardPlayTime`, `LeaderboardWeekly`) and save.
- The header is text, or `headerImage` once Codex supplies one.
- **Studio without API access:** the boards show this server's players, with the "(this server)" suffix, as before.

## Remotes, state, wiring
- **`Remotes.NAMES`:** one new block at the end: `TradeRequest`, `TradeUpdate`, `GiftRequest`.
- **StatePush:** two new provider fields, `trade` and `gifts`.
- **`init.server`:** `TradeService.start()` and `GiftService.start()` are called after MailboxService and before DebugService.
- **`init.client`:** `TradeController` is started last.
- **HUDLayoutController:**
  - adds a `Trade` accent and `MENU_ORDER.Trade = 5`;
  - the touch block now has `ceil(tiles / 2)` rows, so 3 with five tiles.
- **validate:** one new block.

## Owner actions
1. **Creator Dashboard:** create 9 Developer Products. Paste their ids into `MonetizationConfig.GiftProducts`.

   | Key | Price | Suggested name |
   | --- | --- | --- |
   | GiftCash24K | 45 R$ | "Gift: Cash Pack S" |
   | GiftCash200K | 85 R$ | |
   | GiftCash800K | 215 R$ | |
   | GiftCash4M | 425 R$ | |
   | GiftCash8M | 679 R$ | |
   | GiftSpeed150K | 69 R$ | |
   | GiftSpeed1M | 215 R$ | |
   | GiftSpeed10M | 595 R$ | |
   | GiftSpeed1B | 2549 R$ | |

   Until at least one id is set, the Gift section stays hidden.
2. **DataStores:** `TradeLog_v1`, the three `Global*_v1` ordered stores and the weekly ordered stores are created automatically.
3. **Studio, optional:**
   - Place `LobbyMarkers.Leaderboard<Key>` parts if the automatic spots look wrong. Check this especially near the trail booth at X -146 and the event stand at X 128.
   - Save the place after syncing, since there are new ModuleScripts.
4. **Art:** see `docs/codex-prompts/trading-gifting-boards.md`.

## Lead must verify
- **Desktop HUD rail with a 5th button.** Check that the rail (Buttons.Left grid, 0.56 of the screen tall) still fits, and that Trade does not overflow onto the stat card. If it overflows, set `TradeConfig.HUD_BUTTON = false` (the world prompt still works), or shrink the rail cells.
- **Touch HUD block with 3 rows.** Check that it fits between the stat card and the thumbstick on a small phone.
- **Panel shells.** The Index shell clone must come out with a header and a working Close. `Frames.Trade` must open and close through the pack, including blur and one-panel-at-a-time behaviour.
- **InteractController and the local prompt.** It should render the client-created Trade prompt, and hold-to-trade should work on touch.

## Studio test plan
Call each command as `ServerStorage.DebugInvoke:Invoke(cmd, "<you>", ...)`. Every command restores what it changes.

1. `validate`: no failures. This includes the ISO-week checks and the gift parity checks.
2. `tradeSim` (solo): expect `passed = true`. The steps cover:
   - refusals: sealed, not owned, duplicate, too much Cash, fractional Cash, empty, over 6 items, full partner storage;
   - a refused execute changes nothing;
   - an even swap into a full storage is allowed;
   - the lopsided warning;
   - the swap: Cash 940/560, items moved, a clashing InstanceId replaced.

   Afterwards your Inventory and Cash are restored and saved.
3. `tradeStatus`:
   - `you.allowed` is false with the join-grace reason for 30 s, then true (in Studio, PolicyService normally answers "allowed").
   - `monPolicy restrict`: shows the "not available in your region" reason, and the Trade panel shows it too.
   - `monPolicy real`: restores the real policy.
4. **Two players.** In the Test tab, choose Clients and Servers with 2 players. On the server, run `tradeOpen Player1 Player2`: the window opens on both clients. Then check each of these:
   - **Handshake:** add items and Cash on both sides, press READY on both, wait out the countdown, and CONFIRM on both. The items and Cash move, both players get a toast, and `tradeLogs` shows the record.
   - **Changes reset READY:** change an offer after READY; both sides un-ready.
   - **Leaving storage:** during a trade, display an offered item from the base. It is removed from the offer.
   - **Carrying:** pick up loot during a trade. The trade is cancelled.
   - **World prompt:** it appears only on the lobby apron.
   - **Popup:** ACCEPT, DECLINE and BLOCK all work, and the popup expires after 20 s.
   - **Leaving:** a player leaving mid-trade closes the window.
5. `giftSim cash all` and `giftSim speed all`:
   - **`self`:** `PurchaseGranted`, `paidCash` (or `paidSpeed`) greater than 0, `deliveredViaMail = true`, `replayPaidAgain = false`.
   - **`none`:** `PurchaseGranted`, paid to the buyer, with the "couldn't tell who" toast, and `replayPaidAgain = false`.

   Cash and Speed are taken back and saved afterwards.
6. **Real gift (after ids are set).** With 2 players, use Shop > GIFT A FRIEND, pick the other player, and buy (a Studio test purchase). The recipient gets a toast "You received ... (a gift from X)", and the buyer gets "sent to X".
7. **Boards.**
   - `boardStatus`: shows 6 boards, their positions (`newBoardSpots`), `week = "2026W38"` (the current week), and your scores.
   - `boardRefresh`: repaints.
   - Visual check: the four new boards stand beside the Money and Speed boards, facing the spawn, and are not inside the booth or stand.
   - `boardWeeklyTest`: `passed = true` (passive counts, product does not). The weekly count is restored afterwards.
   - Stay in game for 60 s or more, then run `boardStatus`: `playSeconds` has grown.
