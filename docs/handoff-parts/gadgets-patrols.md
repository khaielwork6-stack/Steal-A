# Gadgets and moving guard patrols (2026-09-17)

Branch: the `gadgets-patrols` worktree. Nothing in this pass was run in
Studio. Every file was read back, `tools/check.sh` reports no hard errors
and no new TypeErrors in the touched files, and `selene src` reports 0
errors.

## 1. Gadgets

There are three consumables, bought with **Cash**. The config lives in
`src/shared/Config/GadgetConfig.luau`, which `validate` checks.

| Key | Tool | Base price | Max carried | Cooldown | Hotbar key | Effect |
|---|---|---|---|---|---|---|
| Smoke | SmokeBomb | 250 | 3 | 10s | 3 | `GuardianService.confuse(player, 2.5)` plus a smoke cloud |
| Jammer | LaserJammer | 400 | 2 | 14s | 4 | `LaserService.jam(player, 4)` |
| Grapple | GrapplingHook | 300 | 3 | 6s | 5 | Server pull of up to 40 studs over 0.6s |

- **Price:** `basePrice x ZONE_PRICE_MULTIPLIER[HighestZoneReached]`. The
  multipliers are `1, 4, 20, 150, 800, 3e3, 15e3, 80e3, 300e3, 1.5e6, 6e6,
  150e6` and roughly follow the zones' common-item income. **This is a first
  pass for the owner to tune.**
- **Shared rules:**
  - 0.75s shared cooldown between any two gadget uses.
  - Rate limits: 3 uses/s and 2 buys/s.
  - Gadgets only work on the museum danger side (`MUSEUM_ONLY`), and not at
    Night.
  - The Tool must be in the player's hand.
  - The position is `MovementService.verifiedPosition`.
  - A use is fully validated before anything happens. The charge is spent
    only after the effect is applied.
- **Profile:** `Gadgets = { Smoke = n, ... }`, stored in its own DataService
  block (type, default and reconcile). Reconcile clamps each count to its
  carry limit. The schema version is unchanged.
- **Remote:** one new remote, `GadgetRequest`, taking `("buy", key)` or
  `("use", key, aimPoint?)`.
- **State:** StatePush field `gadgets = {counts, prices, max, ready}`, added
  through `StateService.addProvider`.
- **Tools:** `GadgetService.syncTools` works like PvPService: there is one
  Tool per gadget while its count is above 0. The Tool's
  `HotbarLabel = "Smoke x2"` attribute is shown as the slot caption.
  HotbarController now has **5 slots**; the pack template ships five. Gadgets
  have fixed keys 3, 4 and 5, and the key `Five` was added.
- **Shop:** a "GADGETS" section (LayoutOrder 40/41) at the end of the
  existing Shop panel, built with ShopKit cards (`GadgetShopController`).
  Each card shows "have n/max" and the Cash price. A full stack shows FULL.
  This was the least invasive option: there is no new panel, stand or HUD
  button.

### Smoke: `GuardianService.confuse(player, seconds, searchSeconds?)`

- Every guard that is **Waking or Chasing** this player goes to a new state,
  **Searching**. It stands still, looks around, shows a grey "?", and then
  takes its next job through `nextJob`.
- For `seconds`, the player cannot be taken as a target. `asCarrier` skips
  them, the laser `alarm` is refused, and doorway alerts and vision are
  ignored.
- Loot the player carries that has already left its room is "shaken". It is
  removed from `exitedLoot`, and `checkDoorways` ignores it until the
  carrier walks back into that loot's room. After the smoke, only a **new**
  doorway exit or a laser touch can start a chase. This matches the spec's
  "re-acquires only if the doorway/laser rule triggers again".
- Leaving a room during the smoke also counts as shaken, so smoke can cover
  an exit.
- The doorway grace, the laser leash and the catch code are unchanged.
  `confuse` ends chases only through `releaseTarget`.
- `resetAll` (Night) clears all smoke state.

### Jammer: `LaserService.jam(player, seconds)`, `isJammed`, `clearJam`

- This is a new server-owned, time-limited table. It is **not** the
  Studio-only `setExempt`.
- While a player is jammed, the detector keeps no sample for them. The first
  sample after the jam is fresh, so it cannot sweep back across the jammed
  path.
- A respawn or leaving the game clears the jam.
- The replicated attribute `GadgetJamUntil` (server time) drives the visuals
  in GadgetFxController:
  - Everyone sees a cyan Highlight on the jammed player, plus sparkles unless
    Reduced Effects or Low Graphics is on.
  - The jammed player sees nearby beams flicker through the local
    `LocalTransparencyModifier`. Under Reduced Effects the beams dim steadily
    instead.

### Grapple (decision: refused while carrying loot)

- **Decision:** the grapple is refused while carrying loot
  (`GRAPPLE_WHILE_CARRYING = false`). With loot it would skip the chase
  entirely, and a reduced range would still clear laser rows and doorways.
- **Validation:** the client sends an aim point, which is only a hint. The
  server raycasts from the verified chest position against collidable
  `workspace.Map` geometry. The target is refused if any of these hold:
  - the ray does not hit within 40 studs;
  - the hit is more than 4 studs from the aim point;
  - the hit is outside the museum;
  - the player is seated, PlatformStanding, rooted or already pulling.
- **Movement:** an `AlignPosition` on the root, which the client still owns
  and simulates. MaxVelocity is the distance / 0.6s. The client switches the
  Humanoid to Freefall when the constraint appears. A Beam is used as the
  rope. The pull ends after 0.6s, on arrival, on respawn, or if the player
  picks up loot.
- **Anti-cheat:** new `MovementService.allowBurst(player, extraSpeed,
  seconds)`. It adds `extraSpeed` studs/s to the budget refill, the cap and
  `verifiedPosition` for the pull window. The move is still measured; it is
  **not** a teleport re-base. The grapple passes `pull speed + 20` for
  0.6s + 0.6s.

### Visual placeholders

- **Tools:** the tools are built from simple parts. A mesh is used when
  `meshId` is set.
- **Smoke cloud:** the server drops an invisible marker in
  `workspace.GadgetFx` with the attributes `Radius` and `EndsAt`. Each
  client builds the ParticleEmitter itself.
  - Low Graphics gives a small burst.
  - Reduced Effects gives a still translucent sphere. The smoke is never
    hidden, because its position is gameplay information.

## 2. Moving patrols (`PatrolConfig.luau`, `GuardianService`)

- **Where:** zones >= `MIN_ZONE` (7). The resting state becomes
  **Patrolling** instead of Sleeping. `enterRest` is now the single place
  that chooses between them. It is used at start, on arrival home and in
  `resetAll`.
- **Route:** `patrolRoute` builds a rectangle in the room's local frame:
  - z from 14 to 32 studs into the room, which keeps it clear of the doorway
    line (z = 0) and of the cases (z ≈ 45);
  - x from `-(w/2 - 14)`, clear of the ropes and pilasters, to `w/2 - 20`,
    clear of the side exhibit at `w/2 - 10`.
  - The guard walks it at 12 studs/s and pauses 1.2s at each corner. It uses
    the existing `steer`, `driveSpeed`, `arrived` and stuck-sidestep code,
    and adds no raycasts.
- **No chase on sight:** a patrolling guard does not chase anyone it sees.
  The same triggers as §48 apply: a doorway exit gives the alert plus the
  grace, and a laser touch gives the wake beat. A patrolling or Searching
  guard is treated like a sleeping one: it gets the Waking beat, and the
  client shows "!" on any change into Waking.
- **Vision cone:** `checkVision` runs at 5 Hz and is driven by carriers.
  - For each player carrying loot that has not yet left its room, and who is
    still inside that room, it tests only that room's guard, and only if the
    guard is Patrolling.
  - Distance must be 25 studs or less and the angle 35° or less. Then one
    raycast runs, reusing `clearCatch`'s parameters.
  - A hit calls `doorwayExit`, the exact doorway alert: Waking,
    `DOOR_GRACE`, then a chase.
  - `VISION_ENABLED` switches it off.
- **Other behaviour:**
  - A patrolling guard still fetches drops.
  - The walk home returns to the nearest patrol corner.
  - Night (`resetAll`) snaps patrol guards to corner 1.
  - Switching patrols off for a zone mid-patrol sends those guards to sleep
    at their post.
- **Client:** GuardianFxController gives Patrolling a slow stroll pose on
  unrigged costumes; rigged costumes use the walk track and stop at corners.
  Searching has a peering pose. Going from Sleeping to Patrolling is not an
  alert.

### MuseumTests (updated deliberately)

- `museumLoops`, `museumScenarios` and `museumPaths` expect `"Sleeping"` in
  every zone, including zone 12 in `museumPaths`. `roomEscapeAudit` measures
  the sleeping-guard doorway rule.
- Each of these runners now calls `Guardian.suspendPatrols(true)` at the
  start and `false` in its cleanup. The call is counted, so every guard
  sleeps at its post for the run, and the existing expectations and tables
  stay valid.
- `museumTests` (geometry) is unchanged.
- The patrol behaviour has its own test, `gadgetPatrolTest`.
- `isZoneBusy` treats Patrolling as idle.

## Owner actions

- There are no Robux products, gamepasses or badges.
- Art: see `docs/codex-prompts/gadgets-patrols.md` (3 meshes, 3 icons,
  optional VFX textures and an optional stand). The ids go in `GadgetConfig`.
- Tune the prices (`ZONE_PRICE_MULTIPLIER`, `basePrice`) and the patrol
  values (`SPEED`, `MIN_ZONE`, `VISION_*`) after playtesting.

## Studio test plan

Run `ServerStorage.DebugInvoke:Invoke(name, nil, ...)` during the Day with no
carry. Every command restores what it changes, even if it errors.

| Command | Expect |
|---|---|
| `validate` / `museumTests` | 0 failures (new GADGETS AND PATROLS block) |
| `gadgetBuyTest` (key = "Smoke") | `pass`: first buy spent the price, count 1, tool given, over-limit and broke refused, cash kept on refusal |
| `gadgetSmokeTest` (zone = 2) | `pass`: `chasingBefore`, `searching`, `chasedFlagCleared`, `stillCarrying`, `leftRoomCleared`, `notReacquired` |
| `gadgetJamTest` | `pass`: `noTripWhileJammed`, `guardStillIdle`, `tripAfterJam` (this trip really wakes the zone 3 room 2 guard; the runner leaves at once) |
| `gadgetGrappleTest` | `pass`: `moved >= 12`, **`newViolations = 0` with the movement check ON**, `farRefused`, `carrierRefused` |
| `gadgetPatrolTest` (zone = 7) | `pass`: `patrolling`, `walks` (>= 5 studs in 3s), `bystanderIgnored`, `visionAlert`, `markedAsLeft`. If `frontIsInRoom` is false the guard was facing the doorway; rerun. |
| `gadgetPatrols` | zones 7-12: `Patrolling`, `patrolActive = true`, 4 waypoints; zones 1-6 `Sleeping` |
| `gadgetPatrolToggle` (7, false), then (7) | room guards sleep at their posts, then go back to patrolling |
| `museumLoops`, `museumScenarios`, `museumPaths`, `roomEscapeAudit` | same results as before (patrols suspended during the runs) |
| `gadgetGive` (n, seconds), then play manually, then `gadgetRestore` | tools on keys 3-5 with "Smoke x3" captions; counts restored |

**Manual checks:**
- In zones 7-12, the guards walk the loop and do not clip the cases, ropes or
  side exhibit, including zone 12's aircraft room. Check both rooms, because
  the frames are mirrored.
- The walk-cycle pace looks right at 12 studs/s.
- A smoke cloud appears and looks right with Reduced Effects and with Low
  Graphics.
- The beams flicker for the jammed player only.
- The grapple rope is visible to a second client (Team Test).
- On a phone, touch-aiming the grapple works. It uses the last touch
  position through `GetMouse`; verify this.

**Not verified:**
- The AlignPosition pull feel with real network latency.
- Whether the Humanoid's Freefall switch is enough to stop ground friction.
- The patrol walk-cycle pace.
- Performance with 12 patrolling guards (expected cheap: the same per-frame
  steering the walk home already uses).
