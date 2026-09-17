# Round 3 gameplay (2026-09-17)

Branch: the `round3-gameplay` worktree. None of this was run in Studio.
Every touched file was read back. `tools/check.sh` reports no hard errors
and no new TypeErrors in the touched files (the per-file counts drift a
little in untouched files between runs). `selene src` reports 0 errors.

This pass makes six owner changes: offline earnings, gadgets while carrying,
the smoke re-chase, the smoke visual, the grapple range, and a lobby gadget
stand. It also adds tests for them.

## 1. Offline earnings: 25%, capped at 6 hours

- `GameConfig.OFFLINE_EFFICIENCY` is now `0.25` (was 0.5). The comment
  records "owner, 2026-09-17".
- `GameConfig.OFFLINE_EARNINGS_MAX_SECONDS` is still `6 * 60 * 60`.
- **Verified in `OfflineService.settle`.** The absence is
  `math.clamp(now - left, 0, OFFLINE_EARNINGS_MAX_SECONDS)` before it is
  multiplied, so the cap applies to the payout.
- **Gap fixed.** A player who left again *without claiming* used to stack one
  capped window per rejoin, so `PendingOfflineCash` could exceed 6 hours'
  worth.
  - Pending is now capped at one full window at the current rate:
    `rate x 6h x 0.25`.
  - An amount already held is never reduced.
- `validate` and `EconomyTests` did not pin 0.5; validate only checks the
  range (0, 1], so neither was changed.
- **UI text.**
  - The current modal states no percentage.
  - master's new WELCOME BACK popup (round3-ui-rewards) computes the percent
    from `OFFLINE_EFFICIENCY`, so it now reads 25% on its own.
- `ParitySim` reads the config value.

## 2. Gadgets while carrying

**HUD**
- `UIStateController` has a new `SCREEN_KEEP` table: `HotbarUI` stays
  enabled under the `carry` claim only. Any other claim (treadmill, a shop
  panel) still hides it.
- Screens are now re-settled on every claim or release (`refreshScreens`),
  not only on the first claim and the last release.
- The rest of the carry HUD is unchanged: only DROP comes back from MainUI.

**HotbarController**
- During a carry (StatePush `carrying`) it shows **only the gadget slots
  (3-5)**.
- It moves the bar **above the DROP button**. It first uses a 0.74 screen
  fallback, then measures `DROP BUTTON NEW` once the button's slide-in has
  settled. This keeps the bar clear of DROP on short phone screens.
- When the carry ends, the bar goes back to the bottom centre.

**Using a gadget without equipping it**
- The loot is welded to the root **outside** the character
  (`CarryService.attach`), so a Tool would not physically disturb it.
- To avoid any interaction with the hand or the carry, keys 3-5 and taps on
  a slot during a carry call `GadgetController.quickUse(key)`. This sends
  the existing `GadgetRequest("use", key, aim?)` without equipping the Tool.
  No new remote was added.
- A slot tap aims the grapple through the **screen centre**; a key press
  aims through the pointer.
- **Server rule (`GadgetService.use`).** The held-tool rule is waived only
  when the server's `CarryService.getCarried(player)` is set *and* the Tool
  is in the Backpack. Every other check is unchanged: count, cooldowns,
  museum-only, verified position, Night closed.

**All three gadgets now work while carrying**
- `GRAPPLE_WHILE_CARRYING = true`.
- The grapple still passes through `MovementService.allowBurst` and the
  server raycast.

**Carry safety during a pull**
- The pull used to end whenever `getCarried` was set. It now ends only if a
  *different* carry begins mid-flight, i.e. a pickup.
- It also ends on `PlatformStand`, which a catch's ragdoll launch sets, and
  on death.
- A drop or a catch mid-pull is the ordinary CarryService path, which uses
  the root's position. The weld lives on the loot and the pull's pieces live
  on the root and in `GadgetFx`, so neither touches the other.

**Delivery timer (new)**
- CarryService's "too fast" check assumes every stud was run on foot.
- The pull now logs its exact server-chosen distance with
  `MovementService.creditDistance`.
- `CarryService.tooSoon` subtracts `MovementService.creditSince(origin.at)`
  from the straight-line distance. Without this, a carrier who grapples
  could have their delivery confiscated as "too fast".

## 3. Smoke re-chase (owner rule)

**GuardianService**
- `enterSearch` now remembers the lost chase on the guard: `smokeTarget`,
  `smokeLootId`, `smokeAlarm` and `smokeAlarmElapsed`. It captures them
  before `releaseTarget`.
- **When the search ends** (`stepSearch`, at `SMOKE_CONFUSE_SECONDS`),
  `resumeAfterSmoke` runs. It:
  - takes the player straight back with `beginChase(..., fromSleep = false)`,
    so the state is **Chasing** with no wake beat and no new doorway or laser
    trigger;
  - re-marks a shaken loot as `exitedLoot`;
  - for a laser chase, keeps the leash time already used.
- **Exception:** if the player is behind the safe line by then
  (`isBehindSafeLine`, the same test `stepChase` uses), there is no re-chase.
  If they still hold the loot, the escape is credited exactly like a chase
  escape: `onEscape` plus `chaseEscape`.
- **No re-chase and falls back to `nextJob` when** the player left, died,
  dropped the loot or had it delivered, or when the museum is closed.
- **A second smoke** from the same player keeps the guard searching until
  the later smoke clears.
- **Memory is cleared** by any new `beginChase`, by `releaseTarget`, and so
  by `resetAll` (Night).
- **Unchanged:** the doorway and laser logic, catch, leash, patrols and
  vision.
- **Kept on purpose:** a smoked player with **no** guard on them who slips
  out of a room is still "shaken", so no alert is raised after the smoke.
  **Owner's call:** say if that case should also alert when the smoke
  clears.
- `GuardianService.inspect` also reports `smokeTarget`, `alarm` and
  `wakeAt`.
- The Smoke description now reads "Guards lose you briefly. Reach the red
  line before it clears!".

## 4. Smoke visual (GadgetFxController)

- `SMOKE_RADIUS` goes from 9 to **27**. There is a new `SMOKE_FADE_SECONDS`
  of 1.5. The durations are unchanged: `SMOKE_CONFUSE_SECONDS` is 2.5 and
  `SMOKE_CLOUD_SECONDS` is 3.5.
- **Normal quality:**
  - On a fresh cloud, a detonation "pop": a neon flash sphere that swells
    and fades, a PointLight pulse, and 32 sparks.
  - The body: a box-volume emitter of big, near-opaque puffs
    (0.35-0.85 x radius, transparency about 0.02-0.08), with a 40-puff
    burst plus 18/s.
  - Edge wisps.
  - Feeding stops at the end of the cloud. Each puff lives the fade time
    plus about 1 second, so the cloud thins out over about 1.5-2.5 seconds.
- **Low Graphics:** a 12-puff burst at 4/s with puffs 1.2x bigger, no wisps,
  and 10 sparks.
- **Reduced Effects:** no particles and no pop. A static cloud of six
  overlapping spheres (transparency 0.08) sits for the duration, then fades
  its transparency.
- The client cloud lives in `workspace.GadgetFx`, not under the marker, so
  the fade outlives the marker. The server's `Debris` keeps the marker until
  cloud + fade + 1 second.
- A cloud streamed in late (more than 0.5 seconds old) skips the pop.

## 5. Grapple range: 80

- `GadgetConfig.GRAPPLE_RANGE` is now **80**. The server raycast
  (`grappleTarget`) reads it.
- The client aim ray is now the camera-to-character gap + range + tolerance,
  replacing the fixed 300.
- The shop description reads "Zip to a surface up to 80 studs away."
  - `validate` now checks that the description contains the range.
  - The range bound was raised to 100.
  - New checks cover the smoke size, fade and store settings.
- The pull time is still 0.6s, so an 80-stud pull runs at about 133
  studs/s, plus 20 of burst slack.

## 6. Lobby GADGETS stand

**New files**
- `GadgetStoreService`, on the server. It is started in `init.server` after
  the other lobby props.
- `GadgetStoreController`, on the client, added at the end of
  `init.client`.

**The stall (built from parts under `workspace.Map.GadgetStore`)**
- A 16 x 9 platform, four steel posts, and a back wall with a neon stripe
  and a shelf of crates.
- A counter with a cyan neon trim and one colour swatch per gadget.
- A cyan/white striped awning that rises to the front, with scallops.
- A "GADGETS" SurfaceGui board standing on the awning lip, so it never
  covers the displays.
- Three neon-ringed pedestals on the counter. Each holds its gadget's model
  at 2.2x, built by the new `GadgetService.buildDisplay(key)`, the same
  builder as the Tool.
- An `AttractionSign` billboard ("GADGETS" / "SMOKE · JAMMER · HOOK") above
  everything.

**The prompt**
- `GadgetStorePrompt` sits in front of the counter: "Shop" / "Gadgets", hold
  0.3s (`GadgetConfig.STORE_PROMPT_HOLD`), 12 studs, no line of sight
  needed.

**Placement**
1. **Override:** an anchored part named `GadgetStore` under
   `Workspace.LobbyMarkers`. Its XZ position and LookVector are used, and
   the counter faces the LookVector. This is documented in the LobbyLayout
   header. The marker is **not** stamped automatically, same as the new
   leaderboards.
2. **Otherwise:** the first free spot of `(150,-38)`, `(-150,-40)`,
   `(150,-28)`, `(-62,-44)` and `(62,-44)`, facing the spawn.
   - "Free" means `GetPartBoundsInBox` over the stall, the 7-stud customer
     space and 2 studs of padding, from 1 stud above the floor to 16 studs
     high, finds nothing visible or colliding. Markers, Terrain and GadgetFx
     are ignored.
   - Every other lobby prop (trail booth, gift chest, Slap cage, Guardian
     pedestals, event stand, all leaderboards) is built before this runs.
   - `(150,-38)` sits between the Guardian pedestal (104,-24) and the Speed
     board (178,-12), and in front of the treadmill row (Z ≤ -51).
3. **None free:** nothing is built, and a warning names the marker to add.

**The panel (client)**
- Holding the prompt opens a small "Gadgets" window. It is cloned from the
  pack Shop panel the same way the Trail Shop's is: a layer mirroring
  `Frames`, pristine geometry, and touch enlargement.
- It holds three ShopKit cards. They are painted by the new shared
  `GadgetShopController.cardFor`, so they show the same price, have n/max
  and FULL as the Shop section.
- BUY sends `GadgetRequest("buy", key)`.
- The window closes on its X, when the player walks more than 20 studs
  away, on respawn, or when a pack panel opens.
- It holds a `gadgetstore` UIState claim, which hides the HUD while open.

**Motion**
- The displays turn at `STORE_SPIN_SPEED` (40°/s) with a 0.25-stud bob, on
  each client, from the server-stamped `SpinOrigin`.
- They stay still under Reduced Effects **and** Low Graphics, and are not
  animated beyond 220 studs.
- The Shop panel's GADGETS section still exists.

## Owner actions

- **Robux:** none. There are no new products, passes, badges or remotes.
- **Studio (optional):** to choose the stand's spot, add an anchored,
  invisible part named `GadgetStore` under `Workspace.LobbyMarkers`, with
  its front face toward where customers stand, then save.
- **Art:** see `docs/codex-prompts/round3.md`, section "Gameplay: gadget
  stand and gadget icons". Everything is optional; placeholders work.
- **Decide:** should slipping out of a room under smoke, with no guard
  chasing, also raise the alert when the smoke clears? It currently does
  not (see §3).

## Studio test plan

Run these during the Day, not carrying:
`ServerStorage.DebugInvoke:Invoke(name, nil, ...)`. Every command restores
what it changes (gadget counts, `Lifetime.Steals`, the carry, jam and
exemptions), even if it errors.

| Command | Expect `pass = true`, and |
|---|---|
| `validate` | 0 failures, including the new GADGETS checks |
| `offline` `simulate 36000 100` | `pending` = 100 x 21600 x 0.25 = **540000** (the 10h absence is capped at 6h). Run `offline claim` afterwards. |
| `offline` `simulate 3600 100` repeated without claiming | Pending goes 90000, 180000, and so on, then **stops at 540000** (the window cap) however many more times it is run. |
| `gadgetSmokeTest` (2) | `chasingBefore`, `searching`, `remembersTarget`, `searchingUntilExpiry`, **`rechased`**, **`noWakeBeat`**, `chasedFlagBack`, `lootChaseableAgain`, then **`safeLineRespected`** and `escapeCredited` |
| `gadgetCarryUseTest` (2) | `heldRuleWithoutLoot`, `noToolInHand`, smoke / jammer / grapple all true while carrying, `carryAfter*` true (weld intact), `moved` and `lootMoved` ≥ 12, `creditLogged`, `newViolations = 0`, `countsSpent` |
| `gadgetGrappleTest` | `moved` ≥ 12, **`longMoved` ≥ 50** (a ~70-stud pull), `newViolations` and `newViolationsLong` 0, `farRefused`, **`beyondRangeRefused`** (95 studs) |
| `gadgetStoreTest` | `built`, `promptExists`, `promptSetup`, `displays = 3`, `signExists`, `boardSaysGadgets`, `onApron`, `clearOfOthers`. `where` tells whether a marker placed it. |
| `gadgetBuyTest`, `gadgetJamTest`, `gadgetPatrolTest`, `museumLoops` | unchanged results |

### Manual checks (need eyes)

**Carrying (play, with `gadgetGive`)**
- The hotbar shows three slots above DROP, on desktop and on a phone. Check
  the phone layout with the Device emulator.
- Keys 3-5 and slot taps use the gadget without the Tool appearing in the
  hand.
- DROP still works.
- Placing the loot on a base slot still works.
- Grappling with loot and then running home delivers normally, with no
  "too fast!" message.

**The smoke cloud**
- At normal quality, Low Graphics and Reduced Effects, the cloud is roughly
  54 studs across and hides a player and a guard, and the pop and fade read
  well.
- Check the frame rate on a phone at normal quality: 80-100 puffs up to
  about 27 studs across is heavy overdraw. If it is too heavy, lower `Rate`
  or the burst in `smokeCloud`.

**The stand**
- Its position, and that it does not block walkways (the marker overrides
  it).
- The pedestals turn and hold still under Reduced Effects.
- The prompt opens the window, BUY works, and walking away closes it.
- The `GADGETS` board is readable from the spawn circle.

**Grapple aim**
- On touch, a slot tap aims through the screen centre.
- The 80-stud pull feels right; 133 studs/s may look abrupt.

## Not verified

- The measured position of the hotbar above DROP when MainUI has a phone
  UIScale. It uses AbsolutePosition plus the gui inset; a 0.74 screen
  fallback applies until the measurement is taken.
- The effect of `ParticleEmitter.Shape` Box/Volume on a 40 x 24 x 40 part,
  judged by look only.
- Whether `Model:ScaleTo` handles the SpecialMesh displays correctly once
  Codex meshes exist.
