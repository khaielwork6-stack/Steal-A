# Data area: saves, persistence, server-loop robustness

Owner-approved improvement pass, 2026-09-17. No Studio run was possible for this
part. Everything below still needs testing in Studio and on a live server.

## What changed and why

### A1. Session locking (`DataService`)
- The stored document is still the profile table. It now has one extra field,
  `SessionLock = { JobId, PlaceId, At }`. Saves written before this change have
  no lock, and a missing lock counts as free, so they load unchanged.
- The session id is `game.JobId`. Studio has no JobId, so it uses
  `"studio-" .. GUID`, generated once per server run.
- **Load** is one `UpdateAsync` that reads the profile and claims the lock:
  - It takes the lock if the lock is absent, already ours, or stale (older than
    `DATA_LOCK_STALE_SECONDS` = 1800).
  - If another live session holds the lock, it writes nothing and checks again
    every `DATA_LOCK_RETRY_SECONDS` (2). After `DATA_LOCK_WAIT_SECONDS` (20) it
    takes the lock anyway and logs "took over".
  - A brand-new key is written straight away as a locked default profile.
  - DataStore errors are retried 4 times with backoff. There is no sleep after
    the last attempt; the player is kicked.
- **Save** is `UpdateAsync` with a guard. If the stored lock is not ours, the
  transform returns nil, so nothing is written. A missing lock also counts as
  not ours, because only a release clears it. In that case the session is
  marked lost and the player is kicked with "Your progress was opened in
  another server". That profile is never written again. Otherwise the save
  writes a shallow copy of the profile with a fresh `At`.
- The lock is never held in memory. `load` strips it, `reconcile` clears it,
  and `save` adds it only to the copy it writes. It can't reach StatePush or
  `persistTest`.
- **Same-server rejoin:** a new load for the same user waits until any
  lock-clearing write for that user on this server has finished (the
  `releasing[userId]` set). Without this wait, the old leave-save would clear
  the lock under the new session.
- **Load finished but the player had left, or the document was unreadable:**
  `unlockOnly` gives the lock back, so the next join doesn't wait 20s.

### Release order (leave and shutdown)
1. **Before-release hooks** (`runBeforeRelease`). Anything held back during play
   (spin prizes, the ItemArtReview restore) goes into the final write.
2. **Save with the lock cleared, in the same write.** Clearing the lock and
   writing the final data in one atomic step means a new server can never read
   the profile between "lock gone" and "final data written". The save is retried
   `DATA_RELEASE_SAVE_ATTEMPTS` (5) times with backoff of 2, 4, 8, 8s. Retries
   stop early if the session was lost.
3. **Drop the profile, then run the new `DataService.onAfterRelease` hooks.**
   These clear per-player caches that the leave-save still reads.

`release` is idempotent. A second call (PlayerRemoving racing BindToClose)
waits for the first one instead of writing again.

### A2. Probe
- Only Studio falls back to in-memory profiles.
- A live server always has `useDataStore = true`. Its probe runs in the
  background (5 tries with backoff) and only logs.
- `isPersistent()` is now just `useDataStore`, so `not isPersistent()` can only
  be true in Studio memory mode. This means MonetizationService's
  `not DataService.isPersistent() or DataService.save(player)` shortcut needs no
  change.
- New `DataService.isStudioMemoryMode()` for callers that want to say so
  explicitly. **Monetization agent:** you may switch to it for readability, but
  nothing requires it.

### A3. Shutdown
BindToClose:
- releases every loaded profile in parallel (hooks, lock-clearing save,
  retries);
- waits until those releases and any leave-saves already running have
  finished, or until `DATA_SHUTDOWN_WAIT_SECONDS` (25) has passed.

This now also runs in Studio when API access is on, where it used to return
immediately. It is skipped in memory mode.

### A4 and A5. Leave retries and save coalescing
- Each player has one writer at a time (`saveQueues`).
- A save requested while a write is running is queued. Exactly one more write
  runs afterwards and covers every queued request, and each waiting caller gets
  that write's result. So `DataService.save` still yields and still means "my
  state is durable". MonetizationService depends on this.
- Before-save hooks now run once per actual write, right before it, instead of
  once per call.
- `DataService.debugWriteCount()` exists for the burst test.

### A6. Load robustness
`migrate` and `reconcile` now run inside a pcall. If either fails, the player is
kicked and `loading` is cleared.

### A7. `waitForProfile`
- It is now event-based (the `loadFinished` BindableEvent plus
  `AncestryChanged`).
- It has **no default timeout any more**. It returns when the load finishes
  (loaded or failed) or when the player leaves. It can't hang, because every
  load ends in a profile or a kick.
- The join block in `init.server.luau` now waits for the real load and returns
  if the result is nil. A slow 14s or 20s load still settles offline earnings.
- BaseService, PvPService, SpeedService and IndexService call it without a
  timeout, so they now also wait for the real load instead of giving up after
  10s. Their code was not changed.

### A8. Offline earnings
- `OfflineService.stamp` does nothing until the player has been settled this
  session. Otherwise an early receipt or spin save would erase the away time.
- EconomyService now clears `incomePerSecond` in `DataService.onAfterRelease`,
  not on PlayerRemoving, so the leave-save stamps the real rate.
- OfflineService clears its `settled` flag in `onAfterRelease` for the same
  reason.
- `EconomyService.recalculate` without a profile now clears the cache entry
  instead of writing 0, so released players don't leak an entry.
- `GameConfig.OFFLINE_EFFICIENCY = 0.5` and `OFFLINE_STATUS = "VERIFIED"`
  (the owner's choice, 2026-09-17).
- The offline modal's text doesn't claim 100% ("This is how much you earned
  offline:"), so it needed no change.
- EconomyTests and MuseumTests don't mention OFFLINE_EFFICIENCY.
- ParitySim reads the value live.
- HANDOFF §33 / the parity table still say "1, BLOCKED"; the lead should update
  that when merging.

### A9. Loop robustness
Each item below now runs inside its own pcall, logs with `warn`, and the loop
carries on:
- **EconomyService:** the income tick, per player.
- **SpeedService:** the training tick, per player. The body moved into
  `trainPlayer(player)`: the same code with its four `continue`s turned into
  `return`, and nothing else changed.
- **NightService:**
  - the scheduler pass and the growth tick;
  - every step of `beginNight` and `endNight`, through a `safely` helper, so a
    failed refresh, reset or publish still reaches `phase = "Day"` and
    `LootService.setClosed(false)`.
- **TutorialService:** tutorial loot upkeep and each player's evaluation.

### A10. Leaderboards
`storable()` turns NaN into 0, floors the value, and clamps it to
[0, 9e18] before SetAsync. Boards are still ranked by current Cash.

### A11. MailboxService (new)
- **API:** `send(userId, entry): boolean` (yields). `MailEntry` is exported,
  and each kind has its own shape:
  - `{kind="item", item, note?}`
  - `{kind="cash", amount, source, note?}`
  - `{kind="speed", amount, source, note?}`
- **Storage:** DataStore `Mailbox_v1`, key `mail_<userId>`.
  - `send` adds an `Id` (a GUID) and `SentAt`, and makes 3 attempts.
  - The mailbox is capped at `MAILBOX_CAPACITY` (50). A full mailbox makes
    `send` return false.
  - `send` refuses unknown ItemIds and amounts that aren't finite and above 0.
- **Delivery** runs on join (after the offline settle, from `init.server.luau`),
  every `MAILBOX_POLL_SECONDS` (30), and right away when a send targets a
  player online in this server. Each pass:
  1. reads the mailbox;
  2. grants each entry whose Id is not in `profile.DeliveredMail`:
     - **cash:** `EconomyService.award` with the entry's source tag;
     - **speed:** `SpeedPower +=` then `SpeedService.applyMovement`, the same
       path as the group gift;
     - **item:** added to `Inventory` as a stored item: `SlotIndex` 0,
       `Hatched` true, no timer, token or robbery, a fresh InstanceId if the
       one sent is missing or already used, then `reconcileItem`. Storage
       capacity comes from `StorageConfig.capacityForTier`. If storage is full,
       the entry stays in the mailbox and the player gets one notice per
       session.
  3. notifies the player through the `Notify` remote ("You received ...");
  4. calls `DataService.save`;
  5. only if that save succeeds, removes the granted Ids with UpdateAsync. The
     removal filters by Id, so mail sent during the pass is kept.
  If the server crashes between steps 4 and 5, the next pass finds the Ids in
  `DeliveredMail` and only removes them.
- `profile.DeliveredMail` is a list of strings capped at
  `MAILBOX_DELIVERED_MEMORY` (100). `reconcile` adds and repairs it.
- **Studio without API access:** mail is kept in memory for that server, with a
  warning.
- **Not done:** mailed items are not recorded in the Index on arrival. They are
  handled like any other stored item.

### A12. Schema
No `SCHEMA_VERSION` bump:
- `DeliveredMail` is filled in by `reconcile`, and an empty list is the only
  correct value for an old save.
- `SessionLock` is document metadata, not profile state.

Another agent adding v14 won't collide with this.

### Config (GameConfig "DATA" block) and validate
New constants: `DATA_LOCK_STALE_SECONDS` 1800, `DATA_LOCK_WAIT_SECONDS` 20,
`DATA_LOCK_RETRY_SECONDS` 2, `DATA_RELEASE_SAVE_ATTEMPTS` 5,
`DATA_SHUTDOWN_WAIT_SECONDS` 25, `MAILBOX_CAPACITY` 50,
`MAILBOX_POLL_SECONDS` 30, `MAILBOX_DELIVERED_MEMORY` 100.

`validate.luau` checks that:
- the stale window is at least 5 autosaves;
- the lock wait is shorter than the stale window;
- the shutdown wait is under 30s;
- the delivered-mail memory is at least the mailbox capacity.

## Owner / lead actions
- **Publishing:** use "Shut down all servers" or "Migrate to latest update".
  An old-build server writes without a lock. If a player moves from an old
  server to a new one while the old leave-save is still in flight, the new
  server sees a missing lock, treats the session as lost and kicks the player
  once. A rejoin then loads the newest data. That is the safe outcome, but it
  is visible to the player.
- **Mailbox:** no Creator Dashboard setup is needed; the DataStore is created on
  first use.
- **Heist and shutdown:** `HeistService.onPlayerLeaving` is wired to
  PlayerRemoving, which fires after BindToClose's releases. So at shutdown a
  robbery in progress is not resolved before the final save. The victim keeps
  the item, which is the safe direction; the old code behaved the same way.
  If wanted, the heist owner can register the victim-side resolution as a
  `DataService.onBeforeRelease` hook.
- Update the HANDOFF §33.6 and parity table wording for `OFFLINE_EFFICIENCY`.

## Studio test plan (Studio with API access on)
1. **Lock rules:** run `dataLockTest`.
   - Expect `passed = true`.
   - It uses the `DebugLockTest_v1` store, a throwaway GUID key, which it then
     deletes. It never touches a player key.
2. **Coalescing:** run `dataSaveBurst 10`.
   - Expect `allReportedDurable = true`, `writes <= 2` and `passed = true`.
   - It only saves the current state.
3. **Mailbox:** run `dataMailTest`.
   - Expect `sent`, `cashDelta = 1`, `cashDeltaAfterSecondPass = 1`,
     `deliveredRecorded` and `mailboxLeft = 0`.
   - The $1 is taken back out and saved afterwards.
   - Also run it with API access **off**. It should pass in memory mode, with
     the save reported as "memory mode".
4. **Status:** run `dataStatus`.
   - Expect `sessionLockInMemory = false` and `persistent = true`.
   - `sessionId` should start with `studio-`.
5. **Leave path:** stop play, then start again. The output should show no
   "held by session" wait, because the release cleared the lock.
6. **Stale self-lock:** kill Studio mid-play (end the process). On the next play
   with a new session id, expect "still held ... waiting", then after about 20s
   "took over". This checks the takeover path against the owner's real key, and
   no data changes.
7. Run `persistTest` as before, and `offline simulate 3600 100`. The pending
   amount should now be half of the old figure (180000).
8. **Night:** `forceNight` / `forceDay` still cycle, and the zones reopen.

## Must be tested LIVE (published server)
- **Offline earnings:** join and put an earning item on display. Wait for an
  autosave (60s), leave, wait at least 5 minutes, and rejoin. The modal should
  show about rate x seconds x 0.5. This confirms that the leave-save stamped a
  non-zero `OfflineCashRate`.
- **Fast hop:** leave server A and join server B within a couple of seconds
  (e.g. join a friend). There should be no rollback. B's log may show a short
  "held by session" wait.
- **Shutdown:** use "Shut down all servers" while in game, then rejoin. Progress
  from the last minute should be kept.
- **A Robux purchase right after joining:** it should be granted and saved, and
  the offline pending amount should still be paid.
