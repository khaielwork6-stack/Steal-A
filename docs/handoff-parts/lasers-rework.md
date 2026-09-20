# Lasers rework (2026-09-20)

Two owner requests: (1) a touched laser kicks you back out of the door
instead of waking the guard, every time, with no cooldown; (2) harder, more
varied patterns as the zones get harder (upside down, sideways, higher,
lower, moving), but always fair.

**Nothing here was run in Studio.** Static gate: `tools/check.sh` hard errors
empty, `selene src` 0 errors. The generator and the fairness validator are
pure Luau and WERE run outside Studio with the `luau` CLI for all 24 rooms
(results below); everything that touches instances or physics is unverified.

The Zone 8+ progression wall is untouched (no treadmill, Speed gate, income
or loot-weight change).

## Files

| File | What |
| --- | --- |
| `src/shared/Config/LaserConfig.luau` (new) | every tuning number: `KNOCKBACK`, `FIELD`, `VALIDATOR`, `BODY`, `zone(index)` difficulty rows |
| `src/shared/LaserPatterns.luau` (new) | `generate`, `validate`, `forRoom` (seed + retry + thinning), `isolatedPoint` (test helper) |
| `src/shared/Util/LaserGeometry.luau` | + `MovingSegment`, `moveFraction`, `moveRate`, `blinkLit`, `segmentAt`, `segmentLit`, `sweptSegmentHit`. The vault's sweep-arm API is unchanged |
| `src/shared/MuseumLayout.luau` | `Layout.BEAMS` removed; `Layout.laserRoom(index)` added |
| `src/server/MuseumGallery.luau` | `buildLasers` builds the generated layout; `REVISION = 5` |
| `src/server/Services/LaserService.luau` | the throw (`exitAim`, `hit`), room movers, no cooldown, no alarm |
| `src/server/Services/RagdollService.luau` | the wall probe now sets `RespectCanCollide = true` (see Decisions 6) |
| `src/client/Controllers/LaserFxController.luau` (new) | poses movers, beam flash, camera shake; started in `init.client.luau` |
| `LaserHitController`, `shared/LaserFlight`, `shared/LaserBeams`, `tools/lasertest/` (second pass) | client-side hits: see "Client-side hits" below |
| `src/server/Services/DebugCommands/Lasers.luau` (new) | `laserRoutes`, `laserLayout`, `laserTouchTest`, `laserMoverSync` |
| `src/server/Services/MuseumTests.luau` | laser expectations rewritten (below) |
| `src/shared/Config/validate.luau` | one LASERS block |
| `DebugCommands/Gadgets.luau` | `gadgetJamTest` picks a Low/High static beam |
| comments / copy | `GuardianService` (alarm is dormant), `AudioConfig`, `GameConfig`, `PolishConfig` flyover caption, `START_HERE.md` |

No new remotes, no profile fields, no assets, no products.

## Part 1 - the throw

**What happens on a touch** (`LaserService.hit`), for a room's static beams,
its moving beams and the vault's rotating arms alike:

1. `LastLaserZone / LastLaserRoom / LastLaserTrip` are set exactly as before
   (AnalyticsSession still fires the `LaserTouched` custom event off
   `LastLaserTrip`, with its own throttle). The beam part gets `HitAt`
   (server time) for the client flash.
2. Carried **museum** loot is dropped at the touch point through
   `CarryService.forceDrop` (before the launch, the same order as a bat hit).
3. `RagdollService.launch` toward the doorway; the short zap rings.

`GuardianService.alarm` is **no longer called**. The guard does not wake, no
laser chase starts, `LaserChased` never becomes true in play.

### Decisions

1. **Aimed at the door, not "backwards"** (`LaserService.exitAim`). Rooms are
   140 x 58 studs with a 40-stud door in the middle of the long wall (not
   ~40 x 40), so "push away from the beam" would mostly hit a wall. The throw
   line goes from the player to the point on the doorway line nearest them
   but at least `DOOR_MARGIN` (5) inside the jambs, and continues
   `OVERSHOOT` (9) studs *straight out* into the corridor (more along the
   path for shallow angles, capped by `OVERSHOOT_MAX` 30; the corridor runs
   the zone's length, so sideways drift is harmless). Speed =
   path length / `FLIGHT_SECONDS` (0.6), clamped 45..135; lift 30 (about 7
   studs of rise - far under any door header). `launch` pushes *away from* a
   point, so the point is put 10 studs behind the body on that line.
   A vault uses its own frame and 14-stud door.
2. **No cooldown.** The 1.5 s per-room cooldown is gone. A thrown player is
   skipped while `RagdollService.isRagdolled` / `isImmune` (the server's own
   tables; PlatformStand is not read for this). `launch` is given
   `IMMUNITY = 0.4`, `STUN = 0.35` (minimum airborne), `GROUND_STUN = 1`;
   RagdollService itself extends immunity to 0.35 s past the stand-up. After
   that the next touch throws again - including the beam they are lying in
   if the throw fell short. `RETRIGGER_GUARD` (0.25 s) only stops a 10 Hz
   stream of zaps when a launch is *refused* (dead body); it is not a
   gameplay cooldown. One touch per 10 Hz step.
3. **Carried loot: dropped, not lost.** Museum loot goes through the ordinary
   `forceDrop`: it lies at the beam, the thief may grab it back, the room's
   guard gets up and fetches it (`noticeDrop` - this is the one way a touch
   still gets a guard on its feet, and it walks to the *item*, it does not
   chase the player), and the existing drop timers send it home. The
   tutorial vase goes straight back to its pedestal (existing rule). Because
   the thief leaves the room empty-handed, the doorway rule does not fire.
   A carried **base-heist** item (zone 0) is left alone: forceDrop would
   return it to its owner, which a museum beam has no business doing.
4. **The vault** - VaultService's rules (lock, lockout, pedestal reach,
   restock) never depended on the alarm, so the arms throw too, at the vault
   door. Known limit: a player *behind* the pedestal is thrown at it; the
   wall probe cuts that throw to a pop on the spot, and they are thrown again
   when they touch an arm again. `docs/handoff-parts/vaults-crews.md` step 5
   ("touch an arm: the Vault Guardian wakes") is now outdated.
5. **Kept dormant, documented:** `GuardianService.alarm`, the laser leash
   (`SecurityConfig.LASER_CHASE_TIMEOUT`, `VaultConfig.GUARDIAN.laserLeash`),
   the smoke resume of an alarm chase and `LaserChased`
   (ChaseWarningController). `MuseumTests.scenarios` / `paths` use `alarm` as
   "wake this guard and chase a non-carrier", validate.luau checks the leash.
   `AudioConfig.ALARM_SECONDS` is no longer read.
6. **RagdollService's wall probe** counted anything *queryable* as a wall.
   Laser beams are CanQuery/non-colliding, and the throw line usually crosses
   one within 6 studs, which would have cut most throws to 25 %. The probe
   now sets `RespectCanCollide = true`. It affects catches and bat hits too,
   only in the sense that invisible non-colliding parts no longer damp them.
7. **Anti-cheat.** Unchanged and not weakened. `launch` takes network
   ownership (MovementService re-bases while the server owns the body) and
   calls `allowTeleport(stun + 1.5)` and again at stand-up. With `groundStun`
   the body has landed before it is handed back. `laserTouchTest` runs with
   the movement check ON and asserts `newViolations == 0`.
8. **Still work:** Laser Jammer (`jam`), crouch / jump silhouettes (now read
   from `LaserConfig.BODY`), Night / closed museum, Studio `setExempt`.
9. **Feedback:** the `LaserAlarm` cue for `ZAP_SECONDS` (1.1 s) on the
   player's root; the touched beam flashes (swell + white, or a plain colour
   blink under Reduced Effects / Low Graphics); a 0.3 s light camera shake
   for the thrown player (skipped under Reduced Effects). No toast was added
   - say if you want "Zapped!" text.

## Part 2 - patterns

`LaserPatterns.forRoom(zone, room, Layout.laserRoom(zone))`: seed =
`zone * 100000 + room * 10000`, then +1 per retry (up to 24) until the
validator passes; if none does, the first layout is thinned beam by beam
until it passes (reported as `thinned`, warned at boot, failed by
`museumTests`). Own Park-Miller RNG, fixed pick order: the same rooms on
every server and in every test.

**Layout.** Rows of beams across the width (first at z = 10, last <= 33),
each row cut into sections (~21-30 studs, shared boundaries so neighbouring
beams share an emitter post). Beams run wall to wall - the old free walk
round the ends is gone. Section kinds: `Open`, `Low` (0.8, jump), `High`
(4.5, crouch), `Mid` (2.5, go elsewhere), `Slant` (0.4 to 8: low one side,
high the other), `FloorLow/FloorHigh` (a diagonal across the floor from one
row to the next), `Verticals` (floor-to-ceiling uprights 7.5 apart),
`Cross` (an X with a 6.5-stud way round each side), `Ceiling` (an inverted V
from a hanging emitter at y 16), and movers `Blink` (waist beam, dark for
1.7-2.2 s), `Bob` (a beam riding 0.8 <-> 4.5), `Slide` (an upright sweeping
the section). Zones 5+ also get dividers along the depth between rows.

| Zones | rows (spacing) | beam cap | kinds | movers |
| --- | --- | --- | --- | --- |
| 1 | 2 (12-14) | 3 | Low only | 0 |
| 2-4 | 3 (9-11) | 6 / 9 / 12 | + High; Slant + floor diagonals from 3; Mid from 4 | 0 |
| 5-8 | 4 (6-8) | 16-25 | + Verticals, Cross, Ceiling, dividers | 1 (5-6), 2 (7-8), cycle 5.5-7.5 s |
| 9-12 | 5 (5-6: jump-then-crouch gates) | 30-40 | denser, fewer Open, more dividers | 3 (9-10), 4 (11-12), cycle 4.6-6 s |

**Fairness validator** (`LaserPatterns.validate`): 1-stud grid, state =
(cell, standing | crouched), 8-way walking without corner cutting, plus
*jump runs* (over cells only a <= 1.5-high beam blocks, <= 6.5 studs, nothing
under 12.5 overhead, standing cells both ends) and *dash runs* (through the
cells ONE mover sweeps, <= 8 studs, between cells no mover reaches, only if
that mover leaves those cells alone for >= max(1.2 s, run / slow speed +
0.5 s); a cell two movers reach is a wall; the beam is padded by its travel
between the 32 time samples and the window loses one sample). Clearances:
2.6 studs (1.1 half width + 1.5) from anything walked around, 2.0 from a
beam crossed by posture. Slow speeds: walk 12, crouch 7 (WalkSpeed 16 with
the heaviest carry, x0.6 crouched). Jump: JumpPower 50 / gravity 196.2 -
the place's StarterPlayer settings are not in the repo, so the Roblox
default is assumed; **if the place changes JumpPower, revisit
`VALIDATOR.LOW_MAX_Y / JUMP_RUN / OVERHEAD_Y`.**
A room passes when: no beam leaves the field, the doorway apron (z < 6,
door width) is plain floor, every socket's standing spot (8.5 in front of
the socket) is free and reached from the doorway. Moves are reversible, so
reached = "and back". Guard posts and the corridor are outside the field by
construction (z < 0) and `museumTests` checks both.

**Zones 3+ must be solvable with no jump at all** (`requireNoJump`). Their
recommended WalkSpeed is 55-260: a jump carries 28-130 studs, more than the
field is deep, so a route that needs one is not controllable. Low beams
there are hazards you may jump, never the only way. (The old layout had the
same property by accident: every row had a 6-stud gap.)

**Offline results (all 24 rooms):** every room passed; 23 on the first seed,
zone 5 room 2 on the second; `thinned = 0` everywhere; tightest accepted
mover window 1.5 s; 499 beams in total (old layout: 202) at ~25 ms per room
(so ~0.6 s of server boot). Emitter parts are deduplicated per floor
position, feet were dropped, so total laser parts should be close to the
old build - **check `museumPartCount` and the `< 900` decoration budget in
`museumTests`**.

**Instances.** Static: `Beam` parts in `Zones.<id>.Lasers` with `A`, `B`,
`ZoneIndex`, `RoomIndex`, `Kind` (contract unchanged + Kind). Moving:
`MovingBeam`, CanQuery off, `RestA`, `RestB`, `Travel`, `Period`, `Phase`,
`OnSeconds`, `OffSeconds`, `BlinkPhase`; the server never moves them -
`LaserFxController` poses them from `GetServerTimeNow()`, LaserService tests
them with `sweptSegmentHit`. Uprights are modelled to y 14 and drawn to the
ceiling. The Jammer flicker works unchanged (it writes
`LocalTransparencyModifier` on every BasePart in `Lasers`).

## MuseumTests changes (deliberate)

- `museumTests`: `Layout.BEAMS` count check -> the generated layout is fair,
  unthinned, within the zone cap, windows >= 1.2 s, built parts match the
  layout, end points (both ends of a mover's travel) inside the laser field
  (beams now legitimately end on the side wall), corridor clear, guard post
  outside the field; plus pure checks of the mover functions and validator.
- `museumPaths`: `standingTrippedMatchingRoom` no longer requires the guard
  to wake; new `touchLaunchedPlayer`, `touchLeftGuardSleeping`. The high
  beam is found with `LaserPatterns.isolatedPoint`.
- `museumLoops`, `museumScenarios`, `roomEscapeAudit`: unchanged (they hold
  immunity, stay out of the field, or are laser-exempt).

## Studio test plan

`ServerStorage.DebugInvoke:Invoke(name, nil, ...)`, Day, no carry.

| Step | Expect |
| --- | --- |
| Boot | no `[MuseumGallery] ... laser layout` warnings; `Map.MuseumRevision = 5` |
| `validate` | 0 failed (new LASERS block) |
| `museumTests` | 0 failed |
| `laserRoutes` | `pass = true`, 24 PASS lines, `thinned=0`, `window` >= 1.2, `nojump=true` for zones 3+ |
| `laserMoverSync` | `pass`, `missing = 0`, `worstError` ~0, `partNeverMovedOnServer` |
| `laserTouchTest` (3, 2) | `pass`: `launched`, `guardDidNotWake`, `landedAtOrOutsideDoor` (`landedLocalZ` < 6.4, ideally negative), `secondTouchLaunched`, `carryDropped`, `droppedAtTheBeam`, `lootBackInSocket`, `sameLootNotDuplicated`, `newViolations = 0`. Try (3, 1), (1, 1), (6, 1). Dense rooms (9+) may answer "no isolated beam" - that is the helper, not a bug |
| `museumPaths`, `gadgetJamTest` | pass with the new fields |
| `museumPartCount` | laser parts per zone sane |
| Manual | walk zone 1, 4, 7, 12: beams meet their emitters (posts, wall boxes, hanging boxes, slide rails); movers glide and blink with a faint pre-warning; touch beams from the far corners and from beside the door: you should fly out of the doorway, not into the front wall; carry a container into a beam: it drops there, the guard walks in for it and does NOT chase you; vault arm: thrown at the vault door; Jammer: immune + flicker; Reduced Effects / Low Graphics: flash is a plain blink, no shake |
| Team Test | a second client sees the same mover positions and the flash |

## Tuning (all in `LaserConfig`)

- Throw too short / long: `KNOCKBACK.FLIGHT_SECONDS` (raise = shorter),
  `OVERSHOOT`, `MIN/MAX_SPEED`; arc height `LIFT`; time down `GROUND_STUN`.
- Difficulty per zone: `LaserConfig.zone` (`weights`, `rows`, `rowSpacing`,
  `maxSegments`, `movers`, `moverPeriod`, `blinkOff`, `dividerChance`).
  Any change reshuffles that zone's rooms; rerun `laserRoutes`.
- Strictness: `VALIDATOR` (clearances, `MIN_WINDOW`, slow speeds).
- A different room for the same numbers: change `LaserPatterns.seedFor`.

## Client-side hits (second pass, from the owner's first playtest)

Feedback: "once I touch them and they send me backwards ... it seems like my
FPS is dropping ... Also it seems like I always PASS it before it hits me."
Both were real, and both are fixed by moving detection and flight onto the
player's own client. **Not run in Studio: the lead must test the client (plan
below).** The pure pieces ran offline (`bash tools/lasertest/run.sh`).

**Diagnosis (verified in the code).**
(a) `LaserService` tested at 10 Hz from replicated positions. At WalkSpeed 260
the body moves 26 studs per sample, plus a network trip, so the touch was found
after the body was past the beam and the throw started late.
(b) `RagdollService.launch` takes network ownership and writes `root.CFrame`
every Heartbeat: the owning client then sees its own character as ~20 Hz
snapshots, which reads as lag.

**New design.**

| Piece | Where | Does |
| --- | --- | --- |
| `LaserHitController` (new client) | `src/client/Controllers` | every frame (bound before the camera): swept body vs the room's beams; on a touch: starts the flight, flashes / shakes, fires `LaserHit` |
| `LaserFlight` (shared, pure) | `src/shared/LaserFlight.luau` | `planLocal` / `plan` (the path: doorway then landing) and `sampler` (position at fraction t: polyline + arc). The client flies it; `RagdollService.launch` `path` uses the same sampler; `LaserService.exitPath` delegates to it |
| `LaserGeometry.bodyBox` / `beamHit` | shared | THE silhouette and THE beam test (static or moving, bounding-box rejection first) for both sides |
| `LaserBeams` (shared) | `src/shared/LaserBeams.luau` | reads beam parts into data by room and `BeamId`; server and client both use it |
| `LaserService.claim` | server | the `LaserHit` validation entry point |
| `LaserService` fallback detector | server | now `SERVER_HZ = 30`; holds a touch `CLAIM_GRACE = 0.25 s`; applies it itself if no claim came |
| `RagdollService.stampFlight` | server | stamp-only: `isRagdolled` + immunity + `allowTeleport`, no launch, no PlatformStand |

**Client detection** (`LaserHitController.detect`). Previous frame's position to
this frame's, exactly like the server's sweep, so a fast body cannot tunnel;
crouch = the posture the player asked for (`CrouchController.isCrouched`, new),
so pressing C just before a beam counts at once. Stands down for: Jammer
(`GadgetJamUntil`), Night, outside the lane, humanoid PlatformStand / Sit, the
server having the body immune (new character attribute `RagdollImmuneUntil`,
written by `RagdollService.grantImmunity`: a guard's catch, a bat hit, the tail
of a flight), Studio `setExempt` (now also published as player attribute
`LaserExempt`), and the debug attribute `LaserClientOff`.

**Client flight.** PlatformStand + Physics state, then each frame
`root.CFrame = sampler(t) * tumble`, zero velocities; at t = 1 a 12 stud/s
slide, `GROUND_STUN` (1 s) lying limp, then a recovery-net raycast (no floor
below: back to where the flight began), `PlatformStand = false`, `GettingUp`.
No ownership change, no server write to the character, no per-frame remote.
Tumble is time-based (7 / 3 / 7 rad/s), gentler than the server version's
per-frame spin. Camera: default camera follows; the light shake is
`LaserFxController.onLocalHit` (skipped under Reduced Effects; the server's
`LastLaserTrip` shake is de-duplicated against it), the beam flash is local and
instant (the server's `HitAt` flash is de-duplicated per beam).

**The claim.** One remote, `LaserHit(zoneIndex, roomIndex, beamId)` (appended
block at the end of `Remotes.NAMES`; `GameConfig.RATE_LIMITS.LaserHit = 4` +
`CLAIM_BURST 4`). `LaserService.claim` validates plausibility, not geometry:
well-formed integers in range; rate limit; body alive; not Studio-exempt, not
closed, not jammed, not `isRagdolled` / `isImmune`; the beam exists
(`LaserBeams.find`); server-known position (`MovementService.verifiedPosition`)
within `CLAIM_RADIUS 24 + peak speed x CLAIM_LATENCY 0.6` of the beam's whole
possible space (at 260 studs/s that is ~180 studs: a fast body is well past the
beam when its claim lands); inside the lane. Rejections are silent. On accept:
`LastLaser*` (LaserTouched analytics unchanged), beam `HitAt`, carried museum
loot dropped (`forceDrop`, at the server's view of the body), the zap, and
`RagdollService.stampFlight(flight + GROUND_STUN - STAMP_TAIL)`.

**Why the stamp is 0.4 s short (`STAMP_TAIL`).** The client stands up on its own
clock one network trip before the server's, and at 260 studs/s a body can be back
in a beam 0.1 s after standing (the first row is ~10 studs from the door). If the
server's record outlasted the client's stand-up, that second, legitimate claim
would be rejected as "already down" while the client flew anyway, unstamped.

**Cheating.** A client that never reports is hit by the server detector: it holds
the touch 0.25 s (`CLAIM_GRACE`), then applies it itself (drop, stamp, server-flown
guided path). A client that reports falsely can only get thrown out of a room
(and drop its loot): plausibility needs it near a real beam, and immunity stops
re-claiming. A claim is also a movement-check window, so the server checks
`LANDING_CHECK_AFTER` (0.5 s) after the flight should have landed that the body
is within `LANDING_RADIUS` (60) of the landing point, else puts it on it (warn +
`claimsSnapped`): a claim cannot be used to teleport. MovementService is not
weakened; `allowTeleport` is granted by `stampFlight` exactly as `launch` did.

**No double apply.** `applyByServer` and `claim` both refuse a player the server
has on record as ragdolled / immune, and both stamp that record in the same Luau
step (single-threaded: that is the lock). An accepted claim also clears any
pending server touch and leaves a `handled` token (beam key + window) that drops
a repeat detection of the same beam. Tested by `laserClientClaimTest`.

**Vault arms** have no client detector (their parts carry no `BeamId`); the
server detects them (now at 30 Hz) and applies at once with the server-flown
path. They still look like the earlier laggy throw. Moving them onto the client
means reading `VaultBeam` attributes in the controller and a beam key for arms;
not done, say if you want it.

### Tests

- **Offline** (`bash tools/lasertest/run.sh client`): 80 631 checks - every static
  beam kind of all 24 rooms crossed at 100 / 260 / 300 studs/s and 10-240 fps
  always registers, a crouched body passes a high beam, moving beams by the clock
  (lit registers, dark does not) across a full cycle, the flight leaves through
  the door from a grid of positions in every room, the silhouette equals the old
  server formula. `run.sh routes` re-runs the generator/validator.
- `laserTouchTest [zone room]` - the SERVER-FALLBACK path (sets `LaserClientOff`
  so a real client does not claim it): launched, guard asleep, landed at the door,
  re-touch relaunches, carried loot dropped and returned, 0 movement violations.
- `laserClientClaimTest [zone room]` - synthetic claims through `LaserService.claim`:
  malformed / fractional / absent beam / far away rejected; a claim beside a real
  beam accepted (stamped ragdolled + immune, `LastLaser*` set, guard asleep, no
  server launch); a second claim while down rejected; a burst rate-limited; a
  claim beating the server detector's grace leaves `serverApplied` unchanged.
  Nothing flies the body (that is the client's), so the runner may be put on the
  landing spot afterwards by the landing check.
- validate: LASERS block extended (`CLIENT` bounds, `LaserHit` rate limit,
  guided-flight numbers). museumTests: every beam readable by `BeamId`.
- Updated for the 0.25 s grace: `museumPaths` (also sets `LaserClientOff`) and
  `gadgetJamTest`.

### Studio test plan for the client (cannot be run headless)

Play with a real client (not a bot), Day.
1. Run `laserRoutes`, `laserMoverSync`, `validate`, `museumTests`,
   `laserTouchTest`, `laserClientClaimTest`: all `pass`.
2. **The owner's two complaints.** At high WalkSpeed (the owner's ~260) run
   straight into a low beam and a high beam in zones 1, 4, 7, 12: you must be hit
   the moment you touch (no overshoot past the beam), and the flight must look
   smooth at your normal frame rate (no 20 Hz stutter, camera follows, light
   shake, beam flashes red-white). Repeat with the Studio Network Emulation at
   150-250 ms: the hit is still instant on your screen.
3. Server side of it: `Output` should show no `[MovementService]` violation, and
   the guard stays asleep. Run `laserState` afterwards:
   (`claimsAccepted` up, `serverApplied` 0, `claimsRejected` ~0, `claimsSnapped` 0).
4. Stand up and run straight back into the beam within ~0.2 s: it must throw
   again (no rejected-claim desync: you must not fly unrecorded; watch for a
   `snap-back` warning or `claimsRejected` rising).
5. Carry a container into a beam: it drops at/near the beam, guard fetches it,
   does not chase you, no dupe.
6. Jammer: no hit while jammed (client and server), hit after. Crouch (C) under a
   high beam at speed: clean pass; press C just before it: counts.
7. Fallback: in the console `game.Players.LocalPlayer:SetAttribute("LaserClientOff", true)`
   then touch a beam: after ~0.25 s the SERVER throws you (the old server-flown
   look); clear the attribute again.
8. Reduced Effects on: no shake, plain colour blink. Team Test: the other client
   sees you fly (normal replication) and the beam flash.
9. Vault arm touch: still the server-flown path (known limitation above).

### Constants (all in `LaserConfig`)

`CLIENT.SERVER_HZ` 30, `CLAIM_GRACE` 0.25, `CLAIM_RADIUS` 24, `CLAIM_LATENCY` 0.6,
`CLAIM_BURST` 4 (+ `GameConfig.RATE_LIMITS.LaserHit`), `STAMP_TAIL` 0.4,
`LANDING_CHECK_AFTER` 0.5, `LANDING_RADIUS` 60, `SLIDE_SPEED` 12,
`RESCUE_PROBE` 250; the flight itself is `KNOCKBACK.GUIDED_*`, `ARC_HEIGHT`,
`GROUND_STUN`. The tumble rates are a local in `LaserHitController` (`TUMBLE`).

## Not done / to verify

- Throw distances are arithmetic, not measured; expect to tune
  `FLIGHT_SECONDS` once in Studio.
- Emitter placement vs pilasters / the side exhibit is cosmetic and unseen.
- No new art or sound (the existing `LaserAlarm` cue is reused).
