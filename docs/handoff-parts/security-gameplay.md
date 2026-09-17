# Security & gameplay hardening pass (2026-09-17)

Branch: the `security-gameplay` worktree. Nothing here was run in Studio: every
change was read back and passed `tools/check.sh` (no new hard errors, no file
above its baseline TypeError count). All numbers live in
`src/shared/Config/SecurityConfig.luau` and are checked by `validate`.

## What changed, and why

### B1 - Movement anti-cheat (`MovementService`, new)
The server never checked movement; "is the player home" came straight from the
client-owned root position, so a teleport or speed hack skipped the whole escape.

* **Budget model** (10 Hz). Each player may cover
  `server-set WalkSpeed x 1.35` studs/s, may bank up to 0.6 s of that
  (+8 studs) for network stalls, and climbs at `40 + speed` studs/s (falling is
  free). Excess becomes strikes (1 per 20 studs); strikes decay 1/s while moving
  legally; **3 strikes** snap the character back to its last trusted position
  and drop what it carries (normal `CarryService.forceDrop`, so a base steal
  goes back to its owner). Never a kick. `warn` + per-player/server counters.
* **The speed is the server's own**: `CarryService.applyMovement` (the only
  WalkSpeed writer) calls `MovementService.noteSpeed(final, unencumbered)`. A
  15-min history keeps "fastest speed since X", so a trail swap mid-run is safe.
* **Re-based, not measured**: first 2 s of a character, `allowTeleport`
  windows (1.5 s), PlatformStand, seated, server-owned physics (ragdoll).
  `allowTeleport` is called by `BaseService.teleportHome` and `assign`, the
  respawn placement in `init.server`, `NightService` return-to-lobby, and
  `RagdollService.launch` / stand-up (tail of the arc).
* **Studio only**: a script-set root CFrame counts as a server teleport, so the
  untouched DebugService `steal`/`goHome`/`teleport` keep working, and
  `MovementService.serverMovedSince` waives the delivery timer for them.
  `setExempt` (Studio only) is used by all four MuseumTests runners.
* **Delivery hardening** (`CarryService.deliveryReady` / `watchDelivery`):
  home needs BOTH the live and the trusted position on the player's own plot,
  and enough time since the pickup (straight line to home / (fastest
  unencumbered speed x 1.35) - 1.5 s). Two clocks: this carrier's own pickup,
  and - if they also took it out of its socket - the whole run, so dropping at
  home and re-grabbing does not reset it. A too-fast delivery is confiscated
  (world loot straight back to its socket, base steal back to its owner) and
  the player is snapped back. `PlacementService.place` uses the same check.
* **Range checks** use `MovementService.verifiedPosition` (live position if
  consistent with the trusted one): steal/grab, heist hold and delivery, bat.

### B2 / B19 - Paid base steal
`HeistService.fulfil` now returns `(boolean, "retry" | "undeliverable" | nil)`
(documented at the function; `HatchService.fulfil` has the same contract).
* `undeliverable` (reservation cleared, **monetization agent grants its
  fallback**): no/other-product record, record older than 10 min (`createdAt`
  os.time; undated records count as expired), item no longer on the victim's
  base, rarity mismatch. Reveal: no pending reveal, container gone, or already
  revealed.
* `retry`: victim not in the server, item mid-robbery / protected / on the
  60 s robbery cooldown (all re-checked in `restore`), buyer carrying,
  buyer farther than `PROMPT_RANGE x 2.5` (35 studs) from the victim's pad,
  still Night after waiting.
* **Night**: `begin` is refused. A receipt landing at Night **yields in
  `fulfil`** until dawn (max `NIGHT_SECONDS + 5` = 15 s), telling the buyer,
  then delivers normally. MonetizationService must tolerate that yield.
* Also fixed: a receipt arriving while the buyer carries an earlier steal used
  to overwrite the live reservation (stranding the carried item) - now `retry`.

### B3 - Victim leaves mid-robbery
A failed escape with an orphaned item (caught, dropped, thief leaves) now calls
`MailboxService.send(victimUserId, {kind="item", item, note})` in its own
thread (guarded; module looked up by name). If the mailbox is missing or
returns false, the old rule (thief's Storage) applies and the full record is
`warn`ed. A deposit still lets the thief keep it. Deposit now saves the
**victim first, then the thief**, sequentially in one thread.

### B4-B7, B11, B18 - Loot lifecycle
* One `validatePickup` for steal and grab (alive, range, rate limit,
  tutorial reservation, liveness, base full).
* Drops carry `dropGeneration`; both drop timers check generation, state and
  `LootService.isLive`. `returnToOrigin` refuses non-live loot and re-checks in
  its delayed callback.
* `retireLoose` sets the new terminal state **`Retired`** (also used when a
  return finds its socket refilled). GuardianService treats it like Placed.
* Attach failure detaches from the socket before `returnToOrigin`.
* `watchDelivery` body is in a pcall.
* `LootService` keeps a per-zone index (`byZone`) maintained with `byId`
  through `track/untrack`; `instancesInZone` reads only that zone.

### B8 / B9 - Guards
* Laser (alarm) chases give up after **25 s** (`LASER_CHASE_TIMEOUT`); loot
  chases are unchanged. `nextJob` still picks up a carrier whose loot left the room.
* **Pose moved to the client**: servers write `ShellMotor.C0` only on a state
  change (rest pose). `GuardianFxController` animates sway / slump / shake /
  run cycle / base-guard swipe locally (within 400 studs) from `State`,
  `PoseWalkTrack` (set at spawn) and `AttackAt` (server time, set per hit).
  Walk/idle AnimationTracks stay server-side (Animator replicates them);
  `AdjustSpeed` only when the rate moves > 0.05. The FX controller now uses
  `GetAttributeChangedSignal("State")` instead of a per-frame poll.
* `clearCatch` reuses one RaycastParams and runs only when `arrived` could be true.
* `Chased` has one counted writer: `GuardianService.setChasedBy(player,
  source, on)`; base guardians register with themselves as the source.

### B10, B12, B13, B14, B15, B16, B17
* Bat: swing origin/safe-zone from verified position; at impact re-checks
  alive, same weapon still held, not in a safe zone. `activeChaseRooms` once
  per frame; trap refill body in pcall.
* TrailRequest `sync`/`equip`: 2/s limiter.
* Crouch costs speed: **x0.6** via `CarryService.crouchMultiplierFor`
  (injected from `LaserService.isCrouched`), refreshed on posture change and
  respawn. One shared OverlapParams.
* Removed dead remotes `StealRequest`, `SellLootRequest` (no listeners; their
  RATE_LIMITS rows stay - they size the steal/store limiters).
* `teleportHome` refuses carriers itself (`BaseService.isCarrying`, injected).
* Slot prompt (place/store/reveal/Instant Reveal): 3/s limiter.
* `HatchService.announced` pruned each sweep; `lastRobbedAt` pruned every 60 s.

## Owner actions / things to verify
1. **Merge**: MonetizationService must read `fulfil`'s second value, grant a
   fallback on `"undeliverable"`, and accept that the steal handler may yield
   up to 15 s. `MailboxService.send` must exist with the agreed signature.
2. Walk and sprint around in Studio, then `secMovement`: `autoTrustedPivots`
   must stay 0 while simply walking (proves client movement does not fire the
   Studio auto-trust). If it climbs, tell the lead - the Studio detector would
   be blind (live servers do not use that path).
3. Play a real session with lag (Studio network emulation ~250 ms) and fast
   trails: `violations` must stay 0.
4. Base guardians and zone guards should still visibly bob/run/shake for
   everyone; the swipe should play on a base-guard hit.
5. Crouch x0.6 is a gameplay change - tune `CROUCH_SPEED_MULTIPLIER` if runs
   under high beams feel too punishing.

## Studio test plan
All commands: `ServerStorage.DebugInvoke:Invoke(name, nil, ...)`. They need a
free display slot / non-full base, Day time, and no carry. Each restores
Lifetime.Steals, PendingSteal/PendingReveal, ProtectedUntil and the robbery
stamp even on error.

| Command | Expect |
|---|---|
| `secTeleportCarry` (zone, default 3) | `pass`, `snappedBack`, `carryGone`, `lootStateAtDrop = "Dropped"`, `newViolations >= 1`, `reactionSeconds` ~0.1-0.3 |
| `secLegitTeleport` | `pass`, `teleported`, `trustedAtHome`, `newViolations = 0`, `carrierRefused = true` |
| `secGrabFar` (zone, default 2) | `pass`: `farRefused`, `nearAccepted` |
| `secNightDrop` (fast=true, zone=2) | `pass`: `retired`, `stayedRetired`, `noGhostInSocket`, `socketHealthy`; `socketEmptiedBeforeTimers` should be true (else the ghost path was not exercised). `secNightDrop, nil, false` uses the real 8 s / 75 s timers. |
| `secHeistFulfil` | `pass`; noPending/expired/itemGone/reveal = undeliverable, victimAway/protected/cooldown/night = retry, `night.waitedSeconds >= 0.9`, `expired.recordKept = false` |
| `museumLoops`, `museumScenarios`, `museumPaths`, `roomEscapeAudit` | unchanged results (runners are exempt from the movement check) |
| manual: `steal 3` then `goHome` then `place` | still places (Studio waiver) |
| manual live-like: steal, press BASE button | refused with "You can't travel while carrying loot" |

Two-player (Team Test) checks: paid steal delivered only near the pad;
victim leaves mid-carry then thief is caught -> item arrives in the victim's
mailbox; thief deposits -> thief keeps it; bat still hits normally.
