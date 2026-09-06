# Handoff — Steal Something

Written for the next Claude session. Read this before touching anything.

> **START AT §20**, then §19 and §18. Between them they say exactly where the
> last sessions stopped, what is verified, what is not, and what to pick up. §0
> below is still the first thing you must *act* on (§20 adds seven more models
> that live only in the place file); §9's "next steps" list is older than
> §16–§20 and is superseded by them.

---

## 0. DO THIS FIRST — the place file may be unsaved

Two things must be true before the game runs correctly:

1. **The Roblox place must be saved.** A large amount of work lives *only* in the
   `.rbxl`, not in git. If it was never saved, the game is broken on load: no
   loot models, no mutation VFX, no Cop, and the "press E spams four popups" bug
   returns. Ask the user whether they did **File → Save to Roblox** and
   **File → Publish to Roblox**. There is **no save/publish tool** in the Studio
   MCP integration, so you cannot do it for them.

2. **Rojo must be serving.** `rojo serve default.project.json` on port `34872`,
   with the Rojo plugin connected in Studio. Without it, Studio runs stale code.

Place: `PlaceId 134344354476234`, `GameId 10765058861`.

---

## 1. Repo state

- Remote: `https://github.com/khaielwork6-stack/Steal-A.git`
- Working branch: **`master`**. `ui/pack-migration-and-prompt-fixes` has been
  merged in (`c119838`) and is no longer the place to work.
- No PR was opened (`gh` CLI is not installed on this machine)

Recent commits:

| Hash | Summary |
|---|---|
| `dc8a227` | Move all UI onto the purchased pack; fix three interaction bugs |
| `efa4644` | Wire in imported Zone 1 art; add reusable mutation VFX system |
| `c119838` | Merge the UI pack migration into master |
| `02164f0` | Phase 9 — the Loot Index (see §12) |
| `dd50eee` | Zone 1/2 art pipeline, Storage UI rebuild, tutorial dedupe, audio pass |
| `4e74e35` | Fix loot being unstealable when its art nests in sub-models (see §13) |
| `a533337` | Phase 11 — Robux treadmill tiers, idempotent ProcessReceipt |
| `ede4b9e` | Wire the real Developer Products; rebuild the Upgrades panel |
| *(this session)* | Normalise and wire the 9 treadmill models (see §15) |

---

## 2. The single most important architectural fact

**Code lives in git. Art lives in the place file. They are separate.**

`default.project.json` maps only:

```
ReplicatedStorage.Shared          <- src/shared
ServerScriptService.Server        <- src/server
StarterPlayer.StarterPlayerScripts.Client <- src/client
```

Everything below is **Studio-side only, not version controlled**, and will be
lost if the place is not saved:

| Location | Contents |
|---|---|
| `StarterGui.MainUI` | The purchased UI pack (art + its own animation `LocalScript`), including the `DROP BUTTON NEW` the DROP button is built from |
| `ServerStorage.GameAssets.Loot` | **38 items.** All of zones 1–5 EXCEPT `Museum_Ruby` and `Pirate_CursedCoin`. Zones 6–12 have none |
| `ServerStorage.GameAssets.Guardians` | All twelve: `Zone01_Cop` … `Zone05_ElfGuard`, plus `Zone06_MummyGuardian`, `Zone07_Bodybuilder`, `Zone08_BankGuard`, `Zone09_MadScientist`, `Zone10_Grandma`, `Zone11_Foreman`, `Zone12_AirportSecurity` (moved in from Workspace in §20 — **unsaved until the place is saved**) |
| `ReplicatedStorage.GameAssets.Mutations` | `Shiny`, `Golden`, `Flaming`, `Corrupted` |
| `ReplicatedStorage.GameAssets.Effects` | `LevelUpBlue`, `LevelUpGold` |
| `ReplicatedStorage.GameAssets.Treadmills` | All 9 treadmill models (see §15) |

Two edits were also made **inside** the place that are not in git:

- `StarterGui.MainUI.ResetOnSpawn` set to **false** (fixes duplicate HUD on respawn)
- `StarterGui.MainUI.LocalScript` — the pack's demo `E` keybind was surgically
  removed (see §5)

---

## 3. Phase status (per the GDD, section 19)

- **Phases 0–8: complete.** Config, data/base assignment, loot spawning,
  steal/carry/guardian, placement/economy, treadmill + Speed, T0–T9 tutorial, PvP.
- **Phase 9 (Index): COMPLETE.** `IndexService` + `IndexConfig` + the
  `IndexController` panel. Per-zone set completion, claimable rewards
  (cash / Speed / a permanent income multiplier) and the all-96 completionist
  reward. See §12.
- **Phase 10 (UI/VFX/audio): done, one blocked asset.** All UI is on the pack,
  mutation VFX, upgrade VFX and the Zone 1/2 models are in, and the audio system
  is built (see §11). 17 of 18 cues play; the lobby music id is rejected by
  Roblox — see §7.
- **Phase 11 (monetization): COMPLETE.** Developer Products for treadmill tiers,
  an idempotent `ProcessReceipt`, and the Upgrades panel (§14). The nine
  treadmill models are normalised and wired into both the world and that panel
  (§15).
- **Phases 12–13 (multiplayer hardening, polish): not started.** Phase 12 is now
  the largest remaining risk — nothing in this project has ever been tested with
  two players. See §18.
- **Economy/progression rebalance: COMPLETE.** The old economy is gone. Read
  §16 before touching any income, rarity or spawn-timing number — several
  things in this document that were true before it are now wrong, and §16 says
  which.
- **Zones 3–5 art, the chase fix, the DROP button, the Hold-E fix, the treadmill
  facing fix: COMPLETE.** See §17.

---

## 4. What the UI architecture is now

The pack ships its own animation `LocalScript` at `StarterGui.MainUI.LocalScript`.
It owns every button inside `MainUI`: hover/press/ripple, and it opens the panel
in `MainUI.Frames` whose **name matches the clicked button's name**.

**Rules that must not be broken:**

- Do **not** call `UIAnim.bindAllButtons` on `MainUI`. The pack stamps buttons it
  owns with the attribute `_UIHandlerSetup` and **skips anything already carrying
  it**. If we bind first, the pack refuses the button and it animates but never
  opens anything. `UIAnim` is for UI we build *outside* the pack.
- Anything cloned from an existing pack button must have `_UIHandlerSetup` and
  `AnimBound` **cleared** before parenting, or the pack ignores it (this exact
  bug made the Storage button dead — see §5).
- Never write into a notification template. `ToastController` clones them.
- `MainUI.Frames.Sell` is a **template**, moved at runtime into
  `MainUI.Templates` by `InventoryController`. Anything left in `Frames` is
  treated by the pack as an openable panel.

Controllers (`src/client/Controllers/`):

| File | Role |
|---|---|
| `HUDController` | Binds pack HUD to `StatePush`; starts Toast + Effects controllers |
| `ToastController` | The **only** path from a server `Notify` to screen. Clones pack templates |
| `InteractController` | Single shared prompt built from the pack's `Action UI` billboard |
| `InventoryController` | Storage panel, cloned from the pack's `Sell` frame |
| `EffectsController` | One-shot world VFX bursts (LevelUp) |
| `TutorialController` | World arrow only. Objectives go out as toasts |
| `BasePromptController`, `CombatController`, `GuardianFxController` | Unchanged |

---

## 5. Bugs found and fixed (root causes — this is the valuable part)

These were all real, and several are non-obvious. Do not reintroduce them.

1. **`Workspace` is itself a `Model`.**
   `part:FindFirstAncestorWhichIsA("Model")` on any part without its own model
   returns Workspace, whose bounding box is the whole map (~303 studs). This
   lifted every base interact prompt ~154 studs into the sky — Activate Base,
   Upgrade Base, treadmill and display slots all *worked* but appeared to have no
   UI at all. Guarded in `InteractController.liftFor`.

2. **`Model:GetBoundingBox()` returns an *oriented* box** aligned to the model's
   pivot. `size.Y` is **not** world height when the pivot is rotated. Using it to
   scale imports produced nonsense (an 11-stud model "shrank" to 20 studs). Use a
   true world AABB from part corners.

3. **`Model:ScaleTo()` is absolute, not relative.** Multiply through
   `model:GetScale()`.

4. **`FindFirstChildWhichIsA` is not recursive by default.** Imported models keep
   their parts inside nested `Model`s (the meteorite is
   `Zone One Meteor > meteor > OldMeteor`), so the non-recursive call found no
   anchor part — silently no prompt and no VFX. All such calls now pass `true`.

5. **Notification templates must never be mutated.** The old HUD wrote toast text
   into the pack's template and set `Visible = true`. The pack clones from that
   same template, so real messages leaked into unrelated popups.

6. **The pack shipped a demo keybind**: `NOTIFICATION_TEST_KEYBIND = Enum.KeyCode.E`
   calling `showAllNotifications()`, which played *every* template on each `E`
   press ("??? Spawned" / "Inventory Full!" / …). Removed from the pack
   `LocalScript` in the place file.

7. **Cleanup must filter on what to KEEP.** The inventory cleared rows with
   `if child:IsA("Frame")`, but the empty-state was a `TextLabel`, so one
   "Nothing stored." accumulated per `StatePush`. Now filters on `UILayout`.

8. **A deferred hide must be cancellable.** `UIAnim.popOut`'s completion callback
   set `Visible = false` even after a new target had claimed the shared interact
   billboard, leaving it enabled but invisible forever. Fixed with a `hideToken`.

9. **`ResetOnSpawn` on a persistent HUD.** `MainUI` had it on, so respawning
   (which the guardian causes constantly) kept the bound HUD *and* added a second
   unbound copy over it — the pack's demo numbers reappeared and its script ran
   twice. Also destroyed the interact billboard (a `BillboardGui` is a
   `LayerCollector`), causing "Parent property is locked" spam.

10. **State was only pushed on change, and the join push raced the client.** A
    fresh account with $0 income could sit on default values indefinitely. Fixed
    in `src/server/init.server.luau` by re-marking dirty for a few seconds after
    the profile loads.

11. **Self-inflicted, caught in testing:** rewriting the loot placement lift
    deleted the `local anchor` line, so `prompt.Parent = anchor` orphaned **all
    48 steal prompts**. If loot suddenly becomes unstealable, look there first.

---

## 6. Systems added

### Mutations — locked ladder

`Normal → Shiny → Golden → Flaming → Corrupted` (Corrupted is best). Defined in
`src/shared/Config/RarityConfig.luau`:

| Mutation | Chance | Multiplier |
|---|---|---|
| Normal | 90.0% | ×1.00 |
| Shiny | 6.0% | ×1.25 |
| Golden | 2.5% | ×2.00 |
| Flaming | 1.0% | ×2.50 |
| Corrupted | 0.5% | ×3.00 |

`RarityConfig.MutationAliases` maps the old `Neon → Flaming` and
`Glitched → Corrupted` so existing saves keep their tier. **Always run a stored
mutation id through `RarityConfig.normaliseMutation()`.**

### `src/shared/Util/MutationVfx.luau`

Generic, no per-item code. Reads whatever is in
`ReplicatedStorage.GameAssets.Mutations` and applies it to any model. The four
authored assets have four *different* shapes (emitters on a Model, on a Part, or
on a nested `MainPart`), so the effect source is discovered rather than assumed.
Emitter `Size`/`Speed` are scaled to the target's span. Applied both to world
loot (`LootService`) and to displayed trophies (`BaseService.buildTrophy`).

To add a mutation: author it in that folder, add a row to `RarityConfig`. No code.

### `src/client/Controllers/EffectsController.luau`

The two `LVLUP!` assets were the **same effect in two colourways**, with **no
literal text**. Kept both. Their emitters are named `Emit-1` / `Emit-6` — that
suffix is the **emit count**; they are bursts fired with `:Emit(n)`, not looping
emitters to enable.

Triggered by the 4th argument of `StateService.notify(player, kind, message, detail)`:

- `detail = "levelup"` → gold burst (storage upgrade, base upgrade, treadmill upgrade)
- `detail = "unlock"` → blue burst (base activation)

### Zone 1 guardian (the Cop)

**The imported Cop is a static prop** — 28 anchored parts, **no `Humanoid`, no
`Motor6D`**. It cannot be animated by Roblox's animation system. Rather than
re-rig the artist's model, `GuardianService.dressRig` welds it on as a *costume*
over the existing working rig (invisible `HumanoidRootPart` keeps physics and
pathfinding) and `animateShell` poses it procedurally each frame:

- **Sleeping** — slumped 14° forward, slow breathing bob
- **Waking** — bolts upright, vibrates
- **Chasing** — −24° forward lean, 0.85-stud bob at ~5 footfalls/sec, ±17° waddle

Tuning constants are at the top of `GuardianService` (`RUN_CYCLE_SPEED`,
`RUN_BOB`, `RUN_ROLL`, `RUN_YAW`, `RUN_LEAN`).

Other zones have no art and keep the placeholder block body automatically.

### Asset naming contract

Drop new art in and it is picked up with **no code change**:

- Loot: `ServerStorage.GameAssets.Loot.<ItemId>` (e.g. `Museum_Diamond`)
- Guardian: `ServerStorage.GameAssets.Guardians.Zone<NN>_<guardian>`
  (guardian name comes from `ZoneConfig.Zones[i].guardian`, e.g. `Zone02_PirateCaptain`)

**Any class works** — `Model`, bare `MeshPart`/`Part`/union, or a legacy
`Hat`/`Accessory` (its `Handle` is extracted). `src/shared/Util/LootModel.luau`
is the single resolver for world loot AND base trophies; both used to have their
own copy that required a `Model` and silently ignored everything else.

**Do not resize imports by hand.** Every asset is scaled on build to
`GameConfig.LOOT_WORLD_HEIGHT` / `LOOT_TROPHY_HEIGHT` / `GUARDIAN_HEIGHT`,
measured from real part corners. Scaling is applied RELATIVE, which also fixed a
live bug: `ScaleTo` is absolute, so a Big roll on an asset saved at scale 0.22
was six times too large.

---

## 7. Known issues / not done

- **Lobby music does not play.** `92804804272270` returns *"Asset is not approved
  for the requester"* — a Roblox audio-permission problem, not a code one. The
  other 17 cues load and play. Either re-upload that track under the place
  owner's account or grant this experience permission, then update the id in
  `AudioConfig`. Everything around it (safe-zone detection, fade in/out) is wired
  and verified working.
- **Zone 1 is missing Ruby art and Zone 2 is missing Cursed Coin.** Both fall
  back to the rarity-tinted placeholder; drop them in under the naming contract.
  Zones 3–12 have no art at all.
- **No real item thumbnails.** There is no per-item art in the project — loot and
  trophies are both a `Placeholder` part tinted by rarity. The Storage cards show
  a rarity-coloured swatch instead of the pack's demo creature. Swap point is in
  `InventoryController.buildCard`.
- **Rejoin persistence is unverified** — DataStore API access is off in Studio, so
  profiles are in-memory. The save schema was never touched, but this needs a
  live-server check.
- **The Storage button click was never verified by an actual click** (see §8).
  A fallback opener exists and warns to console if the pack fails to bind it.
- `MainUI.Templates` is created at runtime, not authored in the place.

---

## 8. Testing gotchas in this environment (will save you hours)

- **`execute_luau` runs in a separate Lua VM** from the game's scripts. `_G` is
  **not** shared, and `require`-ing a server module gives you a *fresh instance
  with empty state* (`DataService.get` will return `nil`). Use the debug bridge
  instead: `game.ServerStorage.DebugInvoke:Invoke(command, playerName, ...)` —
  note the 2nd argument is a player **name string or `nil`**, not a `Player`.
- **Synthetic clicks DO work — via `instance_path`.** (This corrects an earlier
  note in this file.) `user_mouse_input` with
  `instance_path = "LocalPlayer.PlayerGui.MainUI.Buttons.Left.Index"` reaches the
  client and fires the button. Raw `x`/`y` coordinates are far less reliable, and
  `VirtualInputManager` is still blocked (`lacking capability RobloxScript`).
  Keyboard input via `user_keyboard_input` also works.
  When a click appears to do nothing, click a **pack** button the same way as a
  control before concluding the harness is at fault — that is what exposed the
  `Active = false` bug below.
- **Find pack elements by SHAPE, not by name.** The interact billboard has
  shipped as both `Action UI` and `Action`. InteractController matched the name,
  so a re-import of `Surface/Billboards` left a perfectly intact prompt sitting
  there while every interact prompt in the game silently disabled itself.
  `findActionTemplate` now tries the known names and then falls back to scanning
  for the required hierarchy.
- **A clone of a pack button is inert until you fix two properties.** Pack
  buttons ship `Active = false` (the pack drives them from `InputBegan`, not
  `Activated`) and already carry `_UIHandlerSetup`. So a clone bound with
  `Activated` never fires, and `UIAnim.bindButton` silently bails on it, leaving
  a button with no hover, press or ripple. **Always route through
  `UIAnim.claimButton`**, which does it in the right order. This has now bitten
  twice — the Index tabs, then the Storage DISPLAY/SELL buttons.
- **`ProximityPromptService` is camera-aware.** A scriptable camera parked away
  from the character suppresses `PromptShown` entirely and makes `TextBounds`
  read `0,0` — which looks exactly like a broken font. Restore
  `CameraType = Custom` before concluding anything about prompts.
- **`BillboardGui.AlwaysOnTop = true` renders nothing here.** Verified twice: it
  reports `Enabled`, `Visible` and a correct `AbsoluteSize`, and draws nothing.
  Solve occlusion by lifting the billboard instead.
- Screenshots of short particle bursts are near-impossible to time; verify those
  programmatically instead.
- `DebugInvoke` commands: `snapshot`, `cash`, `grant(itemId, size, mutation)`,
  `clearDisplays`, `steal`, `inventory(action, arg)`, `upgradeBase`,
  `activateBase`, `resetTutorial`, `tutorial`, `treadmill`,
  `index(action, zoneIndex)` where action is `discover`/`claim`/`wipe`.
- **`grant` refuses once the base is full** (7 slots). To finish a set for
  testing use `index("discover", zone)` rather than an 8th `grant`.

---

## 9. Suggested next steps

1. Confirm the place is **saved and published** (§0).
2. **Paste the real Developer Product ids** into `MonetizationConfig` once they
   exist in the Creator Dashboard. Everything else for Phase 11 is done and
   tested; until an id is filled in, the Robux button stays hidden by design.
3. **Fix the lobby-music asset permission** (see §7) — one blocked asset id.
4. Add `Museum_Ruby` and `Pirate_CursedCoin`, then zones 3–12, using the naming
   contract in §6. No code needed, and no manual resizing.
5. Phase 12 (multiplayer hardening) — this also covers the unverified rejoin
   persistence — then Phase 13.

---

## 5b. One more bug worth its own entry

**A character-shaped guardian costume gets ADOPTED by the rig's Humanoid.**
    The Pirate Captain import has parts named `Torso`, `Head`, `Left Arm` … and
    its own `HumanoidRootPart`. Parent that into a model containing a `Humanoid`
    and Roblox claims those reserved names and **re-enables `CanCollide` on the
    torso**, which welds a colliding part to the assembly. The guardian then
    jams a few studs short of its target and can never land a catch — while
    still reporting `state = Chasing` and `HumanoidState = Running`, so it looks
    like a pathfinding bug. `dressRig` now strips any Humanoid from the costume,
    prefixes every reserved part name with `Shell_`, and re-asserts
    `CanCollide = false` AFTER parenting. The Cop never hit this because it is an
    unnamed mesh prop.

---

## 14. Phase 11 — monetization

Treadmill tiers are **Developer Products**, not Gamepasses, because each purchase
advances one tier and is repeatable. `MonetizationService` owns all of it.

Four rules, each of which the code exists to enforce:

1. **`ProcessReceipt` is the only grant path.** `PromptProductPurchaseFinished`
   is deliberately not connected anywhere — it reports that a dialog closed, not
   that Roblox took the money.
2. **Receipts are safe to replay.** Roblox retries until it gets
   `PurchaseGranted`, across rejoins and servers, so granted `PurchaseId`s live
   in the **profile** (schema v3), not in memory. An in-memory set would hand out
   a free tier on every post-rejoin retry. The list is trimmed oldest-first at
   100 entries.
3. **An unconfigured product grants nothing** and the receipt is left OPEN
   (`NotProcessedYet`) rather than consumed, so a purchase made against a
   half-configured build still grants once the id is pasted in.
4. **A purchase is never silently lost.** The grant is always the tier the player
   is *next in line for*, never the tier named on the product — which covers them
   earning it with Cash while the receipt was in flight, and cannot be abused to
   skip tiers.

`PurchaseGranted` is only returned once the grant is **durable**, because it
consumes the receipt permanently. A failed save returns `NotProcessedYet` and the
retry re-drives the save (rule 2 already recorded the grant, so it cannot double
up). `DataService.isPersistent()` exists so Studio — where nothing can be saved —
does not refuse every receipt.

**The client never names a product id.** It sends `PurchaseRequest("treadmill")`
and the server decides which product that is, so a tampered client cannot prompt
for an arbitrary product.

`UpgradesController` fills in the pack's `Frames.Upgrades`, whose card already
ships a `Money` and a `Robux` button in one row plus a `Lvl N -> Lvl N+1` display.
The Robux button is hidden unless the tier being sold has a real id.

**Testing.** Robux cannot be spent in Studio, so use the debug bridge:
`receipt("configure" | "clear" | "seed", n | "setlevel", n | "deliver", productId, purchaseId)`.
Note `configure` mutates only the **server's** copy of `MonetizationConfig` — the
client reads its own, so it cannot be used to test the Robux button's visibility.
For that, paste an id into the file and restart, which is the real path anyway.

---

## 11. Audio

`src/shared/Config/AudioConfig.luau` holds every asset id, volume and category.
**No `rbxassetid://` belongs anywhere else.** `src/shared/Util/Audio.luau` is the
only thing that constructs a `Sound`; it pools one-shots per (parent, cue) and
makes loops idempotent, so a repeated trigger cannot stack instances.

The split that matters:

- **World cues** (`Snoring`, `BossAlert`, `PoliceWhistle`, `BossHit`, `NpcCatch`,
  `BatHit`) are created **on the server**, parented to the part they belong to,
  and replicate positionally on their own. No remote traffic, and bystanders
  hear them from the right direction.
- **Personal cues** go over the `SoundCue` remote as a cue NAME, never an id.
- **UI + music** are client-only in `AudioController`.

**One cue per event, never two.** A boss hit plays `BossHit` *instead of*
`NpcCatch`; an event-specific cue cancels the generic `Notification` beep queued
for the same toast (the toast always arrives first, so the generic one is
deferred a frame and cancelled). `ZoneConfig.isBoss` decides boss vs police —
Zone 1's Cop is deliberately NOT a boss.

UI hover/click is wired by walking `MainUI` and connecting listeners **only** —
it never stamps `_UIHandlerSetup`, so it cannot steal a button from the pack the
way `bindButton` would.

Lobby music is pure geometry: the red line is `Z = 0`, so the client compares its
own position every frame with a hysteresis band rather than asking the server.

---

## 12. Phase 9 — the Loot Index

**Discovery is recorded on PLACEMENT, not on a steal** (`PlacementService`
writes `Profile.Index[itemId]`, then calls `IndexService.onDiscovered`). Carrying
an item home is the achievement.

**Rewards are derived, never typed.** `IndexConfig` holds three ratios and all
twelve zones re-balance together:

| | Formula | Zone 1 | Zone 12 |
|---|---|---|---|
| Cash | `CASH_SECONDS` (90) × the zone's combined base income | $9.8M | $6.36T |
| Speed | `SPEED_FRACTION` (0.15) × the **next** zone's recommended Speed | 135 | 3B |
| Income | `+2%` permanent, per claimed set | | |

All twelve claimed = **+24%**; the all-96 completionist claim adds **+10%** on
top and requires every zone already claimed. The multiplier is applied in
`EconomyService.recalculate` against the aggregate, so a claim never rewrites
saved per-item `FinalIncome`.

**Replication.** The 96-entry discovery map rides its own `IndexPush` remote, not
`StatePush` — `StatePush` fires ~4×/sec while income ticks. `StatePush` carries
only a twelve-entry summary. The client also fires `IndexClaimRequest("sync")` on
start and on panel open, which is immune to the join race in a way a timed
re-push is not.

**The panel is filled in, not built.** `MainUI.Frames.Index` already exists and
`Buttons.Left.Index` already opens it. The pack's demo grid shipped both states
an index needs — a card with `Rarity`+`Name`, and one with `Count` = "???" — and
both are lifted out as templates. Zone tabs exist because the grid is four wide,
so eight items are exactly two rows.

Verified end to end in Play mode: gating, double-claim refusal, the completionist
order requirement, the multiplier reaching real income (60,577 → 61,788 = ×1.02),
the opener badge, and 20 open/close cycles leaking nothing.

---

## 13. The nested-model regression (read before adding art)

Imported art keeps its parts inside its own sub-Models — the vase is
`Museum_AncientVase > brass_vase_01 > Circle.001`. The steal handler used
`prompt:FindFirstAncestorOfClass("Model")`, which returns the **nearest** model —
the artist's inner group — which carries no `LootId`. The steal then resolved to
nothing and returned **silently**, so holding E on a real object did nothing at
all and looked like the game was frozen.

It only affected items with real art whose source Model nests, and the tutorial
pins the Ancient Vase into socket 1 — so the very first item a new player touches
was the broken one, and it read as "I cannot pick ANYTHING up".

Fixed with `LootService.fromDescendant`, which walks ancestors looking for the
**attribute** rather than for a class, and is therefore immune to however deeply
a future import nests itself. It is bounded at `workspace`, which is itself a
Model. That path now also `warn`s instead of failing silently.

**Testing note:** verifying this is fiddly and two artifacts will mislead you.
Teleporting a character next to a pedestal makes it FALL, so by the time a
1-second hold completes it is out of the 22-stud range and the steal is refused
as "Too far away" — raycast for ground and let it settle for ~3s first. And a
stationary character is caught by the guardian almost instantly, so "carrying:
nothing" a second later is a successful steal that was already reclaimed. Watch
the `Notify` stream, not the carry slot.

---

## 15. Treadmills — the nine models

Nine AI-generated treadmill models drive the Speed progression. They are the
player-facing reward for every treadmill tier, so they are normalised hard.

**Where they live:** `ReplicatedStorage.GameAssets.Treadmills.<Key>` — deliberately
*Replicated*Storage, not ServerStorage, because the Upgrades panel renders them
client-side in a ViewportFrame. Keys match `TreadmillConfig.Tiers[i].modelKey`.

**Tier order (do not reorder):** Rusty, Velocity, Voltic, Inferno, Frostbite,
Midas, Overclock, Eclipse, Ascendant. `Midas` was imported as "Aurum"; the
Studio-side model has already been renamed.

### The gameplay rig is never the art

Every model is a single MeshPart with `Default` collision fidelity — a crude
hull, not the real surface. Trusting it means players catching on handlebars or
falling through a belt that only looks solid. So:

```
Treadmill/            Folder on the plot (MapBuilder)
  Frame               INVISIBLE collision deck - the only thing you stand on
  TrainingTrigger     INVISIBLE detection volume - what SpeedService reads
  Belt                thin cosmetic strip, kept for the activation tint
  Model/              decorative art, swapped by SpeedService on upgrade
```

The art is always `Anchored`, `CanCollide/CanQuery/CanTouch = false`, and any
script inside it is stripped. MapBuilder builds only the invisible rig and knows
nothing about tiers, so an upgrade is a pure model swap against a fixed frame.

### Normalisation (`TreadmillModel`)

- **Uniform scale only.** Long axis matched to `STANDARD_LENGTH = 13`; no axis is
  ever stretched independently, so wings and arches stay undeformed. Eight of the
  nine were authored at exactly 13, so only Inferno actually scales (×1.717).
- **Deck height is measured, not guessed.** `deckHeight` per tier is where that
  model's real belt sits, found by raycasting a grid over the mesh. Each model is
  then SUNK by `deckHeight - STANDARD_DECK_HEIGHT` so every belt lands on the
  same plane. Regenerate with `DebugInvoke:Invoke("treadmills", nil, "measure")`.
- **`STANDARD_DECK_HEIGHT = 1.6`** is identical to the old placeholder deck, so
  safe volumes, corridor clearance and map layout are untouched — and it stays
  under humanoid step height, which is what lets a player walk straight on.
- **Orientation is normalised twice**: long axis onto the deck axis, then
  front-to-back via `tallestEndZ` (a treadmill's tallest feature is its console).
  Three of the nine were authored 180° from the rest.

Verified across all nine: belt length 13.00, belt plane 1.60, player stands at
4.60, footprint centred to 0.00, all facing the same way, zero colliding parts.

### Farming feel

`TreadmillController` (client) makes standing on a treadmill look like training.
It GRANTS NOTHING - SpeedService remains the only thing that awards SpeedPower.

- **Detection is local.** The client runs the same oriented-box test against the
  same `TrainingTrigger` the server uses, so it reacts on the first frame with no
  "you are training" remote. The server keeps its own independent check, so a
  tampered client changes what it SEES and never what it earns.
- **The centre hold is soft.** The player is eased to the belt centre and turned
  to face along it, but ONLY while `Humanoid.MoveDirection` is zero. The instant
  they push a key the hold releases, so walking off is immediate and the controls
  are never fought. A hard lock would trap them.
- **The animation is the player's own**, read out of `character.Animate.run.RunAnim`
  and played at `Action` priority so it beats the idle animation. Deliberately not
  a shipped animation id - that is one more asset that can come back "not approved
  for the requester", as the lobby music did.
- **Popups show the REAL granted delta**, observed from `StatePush.speedPower`,
  never predicted from config - so they cannot drift from what was actually
  awarded, and a refused tick shows nothing. Gains arriving faster than
  `POPUP_MIN_INTERVAL` are summed into one popup rather than stacked, which is
  what keeps it from becoming spam. They spawn to alternating SIDES: directly
  overhead is where the tier label lives and the two used to collide.

### Upgrades preview

`UpgradesController.fillViewport(target, level)` builds from the SAME library and
builder the world uses, so the shop shows exactly what you receive. It shows the
NEXT tier (falling back to current at max), auto-fits the camera from real model
bounds — so wings cannot be cropped and no per-model camera is needed — and
repaints the instant an upgrade lands, with no reopen.

---

## 16. The economy / progression rebalance

The single largest change to the game since it was built. The old economy let
almost every object be valuable, so Cash inflated far faster than the Speed
ladder could absorb. It is gone.

**This section OVERRIDES anything earlier in this file that disagrees with it.**

### What the game feels like now

`trash → trash → decent → rare → HOLY SHIT`, instead of
`good → better → better → better`.

Income is deliberately **not** normalised across zones. A late-zone Common can
be worth far less than an early-zone jackpot, and that is the point: it is what
makes a jackpot read as a jackpot rather than as the next step on a staircase.

### The five rules that hold it together

1. **Position 8 in every zone is its JACKPOT**, worth 50×–2,200× that zone's
   ordinary loot. `LootConfig.JACKPOT_POSITION`.
2. **A jackpot can never come out of an ordinary socket roll.**
   `LootConfig.normalPool()` excludes it, and `LootService.rollItem` draws only
   from that pool. There is no percentage anywhere that can produce one.
3. **A socket emptied by a successful theft stays empty** until the next global
   refresh. The old 20-second per-socket refill timer is deleted, along with
   `GameConfig.SOCKET_REFILL_DELAY`. `validate.luau` asserts that constant does
   not come back.
4. **One jackpot roll per WORLD refresh**, at `JACKPOT_REFRESH_CHANCE = 0.10`.
   Never one roll per socket — 48 sockets rolling independently is the failure
   mode this whole pass exists to prevent.
5. **Saved income is a cache, never a source of truth.** Every profile load
   recomputes `BaseIncome`, `Rarity` and `FinalIncome` from the live config.

### Rarity: ten tiers, and where they live

`Common → Uncommon → Rare → Epic → Legendary → Mythic → Cosmic → Secret →
Eternal → Divine`

`RarityConfig` owns all of it and is the only file that enumerates tier names.
An item's rarity is **derived** from its position in its zone's ladder — it is
not typed per item, so an item can never drift out of step with its tier.

| Zones | positions 1–7 | position 8 (jackpot) |
|---|---|---|
| 1–4 | Common, Common, Uncommon, Rare, Epic, Legendary, Mythic | **Cosmic** |
| 5–8 | Common … Cosmic | **Secret** |
| 9–10 | Common … Cosmic | **Eternal** |
| 11–12 | Common … Cosmic | **Divine** |

Normal spawn weights (`RarityConfig.NormalWeights`, totalling 100):
`35 / 27 / 18 / 11 / 6 / 2.5 / 0.5`.

**Why zones 1–4 carry two Commons.** Early zones top out at Cosmic on purpose,
so their Cosmic item *is* the jackpot and is excluded from the pool. That leaves
six tiers for seven ordinary items, so the two deliberate-garbage items share
the Common band and the unused 0.5% renormalises. Zones 5–12 map one item to
each of the seven tiers and hit the target curve exactly. If you would rather
early zones matched the curve too, the only lever is to move a band boundary in
`RarityConfig.ZoneLadders` — which puts Secret in the Museum. That trade is the
reason the table looks the way it does; it is not an oversight.

### Where every number lives

Nothing in this pass is a literal in a gameplay script.

| Knob | Home |
|---|---|
| item $/s | `LootConfig` (the only per-item number typed by hand) |
| rarity ladders | `RarityConfig.ZoneLadders` |
| normal spawn weights | `RarityConfig.NormalWeights` |
| jackpot chance | `GameConfig.JACKPOT_REFRESH_CHANCE` |
| refresh cadence / countdown | `GameConfig.GLOBAL_REFRESH_INTERVAL` / `_WARNING` |
| tutorial cash bridge | `GameConfig.TUTORIAL_CASH_BRIDGE` |
| treadmill costs and gains | `TreadmillConfig.Tiers` |
| zone Speed gates | `ZoneConfig.Zones` (**unchanged** by this pass) |

### The tutorial cash bridge

The Ancient Vase is **$1/s**, not $967/s. A fresh player would otherwise wait
~17 minutes for the $1,000 base activation, so their **first successful
placement** tops their balance up to exactly $1,000 — `max(0, 1000 - cash)`, a
floor and never a bonus.

`PlacementService.grantTutorialBridge`. The flag is durable
(`Profile.TutorialBridgeGranted`, schema v4) and is set **before** the award, so
resetting, selling and re-stealing, rejoining, replaying the placement remote or
racing two placements all re-enter and find it already true. Verified: 50 direct
attacks on the grant path paid out $0.

### Data migration (schema v4)

`DataService.reconcileItem` runs over every display and inventory item on
**every** load, not once as a migration step. Rerunning it forever is the point:
the next economy change reaches existing saves for free.

Durable identity is `ItemId + Size + Mutation` (+ `InstanceId`, `SlotIndex`).
Income and rarity are recomputed. An unknown `ItemId` is left completely alone
rather than zeroed.

Test it with `DebugInvoke:Invoke("migrationTest")` — it plants a deliberately
stale trophy (old $967 income, retired `Neon` mutation, wrong rarity, wrong zone)
and reports whether one pass fixes it and a second pass changes nothing.

### Things elsewhere in this file that are now WRONG

- §6's claim that Secret is the top tier — there are four tiers above it.
- Anything describing a 20-second socket refill.
- Anything quoting $967 for the Ancient Vase.
- §8's debug command list says `treadmill`; the command is **`treadmills`**.

### New debug commands

`refresh`, `occupancy`, `forceJackpot`, `jackpotSim`, `raritySim`, `economy`,
`progressionSim`, `indexAudit`, `migrationTest`, `bridge`, `drop`.

`drop` exists because `swing` needs a second real Player, which a solo Studio
session cannot provide; it calls the same `CarryService.forceDrop` the bat does.

`raritySim` passes an EMPTY exclusion set to `rollItem`, so it measures the raw
weight curve rather than the without-replacement one four occupied sockets
produce. Run it against live sockets and it will look wildly skewed and be lying
to you.

### Bug found and fixed during this pass

**A zone could show the same item type twice.** `forceSocket` bypasses the
roller, so pinning the tutorial vase into socket 1 while an ordinary roll had
already put a vase in socket 2 produced two of them. It was survivable when
sockets churned every 20 seconds; now they persist for a full refresh cycle, and
the very first thing a new player sees would have been a duplicate. `forceSocket`
now clears same-type sockets first and refills them *after* the pin lands, so the
reroll sees the pinned type as taken.

### Known gap

There is **no multiplayer test**. This integration drives one client, so the
two-player cases (simultaneous steal on one socket, a shared refresh seen by
both, cross-base isolation) are unverified by observation. The single-player
halves of those guarantees were checked: the `Reserved` state gates the second
claim, refresh is one server-side loop, and income is keyed per Player. Run
"Start Server + 2 Players" in Studio to close this properly.

---

## 17. Zones 3–5 art, the chase fix, the DROP button

### Zone 3/4/5 assets

All 24 items and 3 bosses arrived loose in Workspace under human-readable names
("Zone 4Alien Artifcat"). They are now renamed to their ItemIds and moved under
the §6 naming contract, so no code knows they exist:

- `ServerStorage.GameAssets.Loot.<ItemId>` — 38 of the 40 items in zones 1–5 now
  have real art. Only `Museum_Ruby` and `Pirate_CursedCoin` are still missing.
- `ServerStorage.GameAssets.Guardians.Zone03_RoyalGuard` / `Zone04_Agent` /
  `Zone05_ElfGuard`.

**`LootModel` now unwraps a `Tool` as well as an Accessory/Hat** — the Castle's
Golden Key is a Tool, and Tools were falling through to a placeholder.

### Bosses grow by zone

`GameConfig.guardianHeightFor(zoneIndex)` — 7 studs at the Museum, compounding
8.5% a zone, capped at 15 (lane walls are 22). The physics root, the head on
art-less zones and the CATCH RADIUS all scale with it, so a fifteen-stud boss
does not have to bury its own model in you before the catch registers.

### The chase: what was actually wrong

Four separate causes, all fixed at the root. **Do not put any of them back.**

1. **`Humanoid:MoveTo` re-issued every 0.4s.** MoveTo walks to a FIXED POINT, so
   for up to 0.4s the guardian ran at where the player *used to be* — and when
   the player got past it, it visibly turned around and went backwards to a
   stale point. It also STOPS on arrival, and every repath restarted the walk
   from zero. That is the rubber-banding, the lost momentum and the backward
   yank, all from one line.
   → `Humanoid:Move(direction)` every Heartbeat. No goal, nothing to arrive at,
   nothing stale. See the STEERING block in `GuardianService`.

2. **The safe-line clamp teleported the guardian backward and zeroed its whole
   velocity**, every frame it was within six studs of the line.
   → The *direction* is clamped instead, so it slides along the boundary. The
   position correction is now a last resort that only fires if it actually
   crossed, and only cancels the inward component of velocity.

3. **Network ownership.** The guardian root is a loose unanchored assembly, so
   Roblox handed simulation to the nearest player — during a chase, always the
   thief. Their client simulated the thing hunting them and every server
   correction read as a stutter. → `SetNetworkOwner(nil)` on wake.

4. **`LEASH_DISTANCE = 900` silently abandoned the chase.** Zone 5's post is 894
   studs from the line and zone 12's is 2,626, so from zone 5 on the guardian
   gave up a third of the way home. → Deleted. The chase now ends on exactly
   three things: the thief crosses the line, the thief is caught, or the loot
   stops being carried.

**The red line is the ONLY escape condition.** `BaseService.isInOwnSafeZone` was
also ending chases; it is an intermediate checkpoint and is gone from that test.

`ZoneConfig.GUARDIAN_REPATH_INTERVAL` is deleted — nothing repaths any more.

Measured after the fix: **0 backward samples in 128** over an 850-stud pursuit; a
Speed-10 player in the 10K zone is caught in 3.4s; a player *at* the 10K gate
(36.96 walkspeed vs the guardian's 37.73) is never closed on and crosses the line
after 468 studs, with the chase active the whole way.

### The Hold-E prompt going invisible

Three causes, all real, all in `InteractController`:

1. **The single shared billboard was PARENTED into the target part.** Loot models
   are `Destroy()`ed the instant they are stolen — taking the prompt for the
   whole game with them, permanently, from one steal. → **Adornee only. Never
   reparent it into the world.** A BillboardGui in PlayerGui renders at its
   Adornee perfectly well.
2. **`apply` set `current = prompt` BEFORE checking the billboard was alive**, so
   one bad frame latched a target that had never been rendered and the
   `prompt == current` guard then returned early forever. → `current` is only
   committed once the billboard is genuinely claimed.
3. **`PromptHidden` does not fire for a prompt whose part is destroyed**, and a
   destroyed prompt still reports `Enabled = true` with a `BasePart` parent — so
   it kept winning `pickNearest`. → also requires `IsDescendantOf(workspace)`.

Plus a rate-limited self-heal that rebuilds the billboard if it ever goes
missing. Verified across steals, three range in/out cycles, a guardian catch and
a full death/respawn: exactly one copy, always visible when it should be.

### The DROP button

`MainUI["DROP BUTTON NEW"]` is a real pack button that shipped as a spare SHOP
button. `DropController` retitles it, moves it bottom-centre, and drives it from
`StatePush.carrying`.

- **No new drop system.** `DropLootRequest` (no payload — the server knows what
  you are carrying) calls the same `CarryService.forceDrop` the PvP bat does, so
  the drop position, the 8s reclaim window and the return-to-origin are one set
  of rules. Verified: dropped items return to their own socket with their own
  variant and no extra roll.
- Route through `UIAnim.claimButton`, never `bindButton` — see §8.
- It is NOT hidden optimistically on click; it hides when the server says the
  carry is gone, so a refused drop leaves it up.

### Treadmill facing

`TreadmillConfig.PLAYER_FACING_SIGN = -1`. The deck's LookVector points out at
the corridor and the console is at the other end, so turning the player to the
raw LookVector faced them at the back of their own treadmill.

**`TreadmillModel.FRONT_SIGN` does NOT normalise anything today** and must not be
trusted to. Every model is a single MeshPart, so `tallestEndZ` can only see the
bounding box, whose corners are symmetric — it returns -6.5 for all nine and the
flip never fires. The nine happen to be authored consistently, so one sign covers
them; that comment is now in the file.

Stance also improved: lateral correction pulls 2.2× harder than longitudinal
(standing off the SIDE of the belt is what reads as broken), and the player
settles `STANCE_OFFSET` studs behind the console instead of inside it. Measured
across three enter/leave cycles: lateral offset 0.000, +8 Speed/s while on, 0
while off, movement restored each time.

### Also fixed in passing

All eight `MonetizationConfig.ListedPriceRobux` values were stale — the products
are priced 16/24/32/40/56/72/96/120, not 19/29/39/49/69/89/119/149. Display only
(the panel already trusts `GetProductInfo`), but it was warning on every open.

---

## 18. WHERE THE LAST SESSION STOPPED — read this first

Two sessions of work sit above this: **§16** (the economy/progression rebalance)
and **§17** (zones 3–5 art, the chase fix, the DROP button, the Hold-E fix, the
treadmill facing fix). This section is the state of the world as they left it.

### Repo

- Branch **`master`**, clean, at **`48381ea`**, pushed to
  `https://github.com/khaielwork6-stack/Steal-A.git`.
- `gh` is not installed; pushes go over HTTPS. An early push in the previous
  session was refused with a 403 (the local git user is `Fallendead1`, the repo
  is owned by `khaielwork6-stack`) and then succeeded on retry, so if a push is
  denied, retry before assuming anything is broken.
- Nothing is half-finished. There is no work-in-progress branch, no stash and no
  uncommitted file.

### 🔴 THE ONE URGENT THING

**Ask the user whether they have saved and published the place.**

The previous session moved **27 art assets** in Studio — all 24 Zone 3/4/5 items
plus the three bosses — out of `Workspace` and into
`ServerStorage.GameAssets.Loot` / `.Guardians`, renaming each to its ItemId.
**That change exists only in the `.rbxl`.** If the place was not saved, zones 3–5
lose every model and all three bosses revert to placeholder blocks, and it is not
recoverable from git. There is no save/publish tool in the Studio MCP
integration, so you cannot do it for them.

### What is genuinely verified

Everything below was observed running in Play mode, not just written:

- 849 config validation checks pass (`require(...Config.validate)()`).
- Fresh account: $0 → steals a $1/s vase → placement bridges to exactly $1,000 →
  activation consumes it → treadmill level 1. 50 attacks on the grant path paid
  out $0.
- A stolen socket is still empty at 26s; the global refresh refills it; a caught
  thief gets the SAME item back; a PvP drop returns without an extra roll.
- Normal rarity roller lands within 0.11pp of 35/27/18/11/6/2.5/0.5 over 300k
  rolls, with zero jackpots. Jackpot roll converges on 0.0996 over 200k, max one
  injection per refresh.
- Chase: 0 backward samples in 128 over an 850-stud pursuit. Speed-10 player in
  the 10K zone caught in 3.4s. Player *at* the 10K gate never closed on across
  468 studs with the chase live the whole way.
- Hold-E prompt: exactly one copy, always visible when it should be, across
  steals, range cycles, a guardian catch and a full death/respawn.
- DROP button: appears on carry, drops through the shared `forceDrop`, hides on
  the server's word, item returns to its own socket with its own variant.
- Treadmill: 3 enter/leave cycles, lateral offset 0.000, +8 Speed/s on, 0 off,
  movement restored each time.
- Studio Output is clean apart from two KNOWN pre-existing warnings: Studio
  DataStore API access is off, and the lobby-music asset id is not approved.

### What is NOT verified — do not claim these work

1. **No multiplayer test has ever been run.** Both sessions drove a single
   client. Simultaneous steal on one socket, a shared refresh seen by two
   players, cross-base isolation and guardian cross-targeting are all unobserved.
   The single-player halves hold up (the `Reserved` state gates a double claim,
   refresh is one server loop, income is keyed per Player) but that is reasoning,
   not observation. Use Studio's **Start Server + 2 Players**.
2. **Rejoin persistence.** DataStore API access is off in Studio, so profiles are
   in-memory and the v4 economy migration has never survived a real save/load
   round trip. It is idempotent and was unit-tested via `migrationTest`, but a
   live-server check is still owed.
3. **Treadmill facing on tiers 2–9.** Only Rusty was verified (visually and
   geometrically). The other eight rely on the nine models being authored
   consistently. If one is backwards, flip `TreadmillConfig.PLAYER_FACING_SIGN`
   — but that turns ALL nine, so check them before flipping.
4. **The chase on foot, by a human.** It was driven by script at the player's
   exact WalkSpeed. Feel is unmeasured.
5. **The DROP button on a phone**, where it clamps to its 132px minimum.

### Suggested next steps, in the order they are worth doing

1. Confirm the place is saved (above). Nothing else matters until that is true.
2. **Add `Museum_Ruby` and `Pirate_CursedCoin` art.** The Cursed Coin is now a
   **$220,000/s jackpot** — the single most exciting object in the first two
   zones — and it renders as a rarity-tinted placeholder block. Drop them into
   `ServerStorage.GameAssets.Loot` under those exact ids; no code needed, no
   manual resizing.
3. **Zones 6–12 have no loot art** (their guardians were adopted in §20). Same
   contract (§6).
4. **Phase 12 — multiplayer hardening.** This closes items 1 and 2 above and is
   the largest remaining risk in the project.
5. Fix the lobby-music asset permission (§7) — one blocked id, not a code bug.

### Things that are deliberately NOT in scope

- **Trails.** *(Stale — trails were built in a later pass: `TrailService`, the
  walk-in Trail Shop, `MonetizationConfig.Trails`, and in §20 the painted Green
  Trail card. Kept here only as history.)*
- **Airport (zone 12) economy.** It is our own extension past the reference
  progression and is marked in `LootConfig` as a separate tuning layer. Zones
  1–11 were rebalanced; zone 12's numbers were deliberately not touched.
- **A post-placement "securing"/appraising timer**, and the under-speed Robux
  prompt. Neither system exists in the codebase. Both were "preserve if present"
  requests, so neither was built.

### Traps that will cost you an hour if you forget them

- `execute_luau` runs in a **separate Lua VM**. `require`-ing a server module
  there gives a fresh instance with empty state, and an event connection made
  there dies with the script. Go through
  `game.ServerStorage.DebugInvoke:Invoke(command, playerNameOrNil, ...)`.
- **Rojo syncs into the Edit DataModel only.** Play mode clones from Edit at
  start, so any file you change while Play is running does not take effect until
  you stop and restart Play. Also, an Edit-mode `require` returns a CACHED module
  even after Rojo replaces its Source — Edit-mode requires will lie to you about
  config values. Test in Play.
- **StreamingEnabled is on** (1600 stud radius). Anything you build far from the
  player is not replicated to the client, and a screenshot of it is sky.
- Full debug command list: `DebugInvoke:Invoke("nope")` returns it.

---

## 19. Physical speed, the guardian mismatch, the money scare, hollow decor,
## automatic base activation, and the upgrade sign

### The speed curve (`GameConfig`)

Log compression alone was too flat at the top: every 10x of Speed only ever
bought a fixed 7.5 studs/s, so the last orders of magnitude of progression felt
like nothing. There is now a PROGRESSION BOOST layered on the same log measure -
exactly 1.0 at the starting Speed, rising linearly in log space to
`SPEED_BOOST_MAX = 1.5` at the Airport gate.

| Speed | was | now | |
|---|---|---|---|
| 10 | 18.3 | 18.3 | x1.00 - a new player is untouched |
| 900 | 30.7 | 33.5 | x1.09 |
| 170K | 47.7 | 58.2 | x1.22 |
| 18M | 62.9 | 83.7 | x1.33 |
| 20B | 85.8 | 128.6 | x1.50 |

Linear in log space means no breakpoints - 999K and 1M are imperceptibly apart.
`WALKSPEED_MAX` went 90 -> 140 so the top of the curve is not swallowed by the
clamp. **The displayed Speed stat is unchanged**; only its physical conversion
moved.

### Why "Recommended Speed" used to mean nothing

Two separate faults, both fixed. Do not reintroduce either.

**1. The handicap was applied in the wrong space.** It was
`guardianWalkSpeed * 0.98`. WalkSpeed is a LOGARITHM of Speed, so trimming 2%
off it does not trim 2% off the stat - it trims about 25%. A guardian meant to
represent 170K therefore moved exactly like 127K, which is precisely the
"127K casually outruns Santa" report: player and guardian were the same speed to
four significant figures. It is now a FIXED margin in studs/s
(`ZoneConfig.GUARDIAN_GATE_MARGIN = 1.5`), which is the unit that actually
decides a chase and means the same thing at 900 Speed as at 20B.

**2. The right sign was still the wrong margin.** Fixing (1) made a 127K thief
genuinely slower - by 1.5 studs/s. Over the 894 studs between the North Pole and
the safe line that is not enough to overturn the guardian's 80-100 stud starting
gap, and the thief **still escaped** in testing. So the guardian also reacts to
the DEFICIT: `GUARDIAN_DEFICIT_CATCHUP = 0.70` scales its speed by how far short
of the recommendation the thief is. At or above the bar, nothing is added and the
thief escapes by the gate margin.

`GuardianService.speedForChase(zone, thiefPower)` is where both meet, and the
speed is set **per chase** in `wake()` rather than once at spawn.

Tuned against measured geometry, not feel: guardians start 55-100 studs from
their own sockets, and runs to the line are 224 studs (Pirate Island) to 1,535
(the Bank). The binding case is the short run with the big gap.

**Verified live, two zones:**

| | result |
|---|---|
| North Pole (170K) vs 75K | CAUGHT 6.3s |
| North Pole vs **127K - the reported case** | **CAUGHT 11.8s** |
| North Pole vs 170K (at the gate) | ESCAPED 14.8s |
| North Pole vs 340K | ESCAPED 13.9s |
| Pirate Island (900) vs 450 | CAUGHT 5.9s |
| Pirate Island vs 900 | ESCAPED 7.0s |

`DebugInvoke:Invoke("speedAudit")` prints the whole table for all twelve zones;
`("speedCurve")` prints the old-vs-new conversion.

### The money "bug"

**The income pipeline was already correct and is unchanged.** Only
`EconomyService.award` / `.spend` touch Cash, and there is exactly ONE passive
loop - a single global `task.wait(INCOME_TICK)` that iterates players, so no
per-player loop exists that could be duplicated by a respawn or a rejoin.

What produced "UI says $3/s but I gained thousands" was almost certainly the
**one-time $1,000 tutorial Cash bridge** landing on the first placement. That is
now gone entirely (below), so nothing moves Cash on its own except the tick.

Measured: 3 items, $11/s displayed, **$132 gained in 12.0s** (ratio 0.999), and
still exact after a respawn, after removing an item, and after adding one.

### Base activation is gone

A base is claimed AND active from the moment it is assigned. `DataService` sets
it in the default profile and **forces it true in `reconcile` on every load**, so
saves written when it was a purchase come back active too, and everything that
gates on it initialises on the first push.

Removed with it: `SpeedService.activateBase`, the activation pad and its prompt,
`BaseConfig.ACTIVATION_COST`, the "Activate your base first" guards in
Placement/Monetization/Speed, the tutorial's ACTIVATE stage, and the
"TREADMILL LOCKED" presentation. `validate.luau` asserts the constants stay gone.

**The onboarding Cash bridge went with it** - it existed only to pay for the
$1,000 activation, and a grant of a thousand dollars landing on a $1/s income is
indistinguishable from a broken economy.

Tutorial now runs: STEAL -> ESCAPE -> PLACE -> EARNING $X/s -> TRAIN -> NEXT
ZONE. INCOME needed its own dwell (`TUTORIAL_INCOME_DWELL`) because it used to
end when you could afford activation. Stage NUMBERS are unchanged - ACTIVATE = 6
is kept as a retired slot so saved `TutorialStage` values do not shift.

### Decor is hollow

**186 decorative parts across the twelve zones were solid.** Every zone's scenery
already lives in `Map.Zones.<zone>.Decorations`, so that folder IS the
categorisation - `MapBuilder.applyDecorCollision()` flips collision on it and
nothing else, and runs at server start because the map is baked into the place.

Untouched: lane floors (2), walls (28), zone floors (12), treadmill decks,
training triggers, safe zones, display slots, all 48 steal prompts. Verified by
running a player through an 83x35 stud decorative wall at 72.5 studs/s - passed
through, zero seconds blocked.

### Base visuals and the upgrade sign

Display slots were near-white 20x20 pads at 0.55 transparency, fourteen per plot
- a grid of blown-out white rectangles. Now a dark slate pad with a bright rim,
dimmer and greyed when locked. Restyled at RUNTIME in
`PlacementService.refreshPrompts` because the map is baked; `MapPalette` holds
the colours and MapBuilder matches for a fresh build.

The upgrade station is a real chunky sign (`PlacementService.refreshUpgradeSign`)
on a post: navy body with a darker edge, white "UPGRADE BASE", green
"Level X > Level Y", red purchase panel with an icon and the price. **Every
number comes from `BaseConfig.nextUpgrade`** - the same call the purchase
validates against - so it cannot advertise a price the server will not honour.
Built once, then only re-texted.

The post is deliberately cut off at the board's bottom edge; at full height it
ran through the red panel and hid the price.

Verified: insufficient funds refused, exact money accepted, **five rapid attempts
granted exactly one upgrade**, and the sign repainted to the next tier instantly.

---

## 20. Second polish pass — booth, HUD trims, bat swing, treadmill, tutorial vase, zones 6–12 bosses, the painted Green Trail card

Sits on top of §19 and the first polish pass (`91427b1`, `e960bcc`: group gift,
world leaderboards, bat combat, RUN warning, HUD reorganisation, base sign,
traps). Everything below is in one commit after `e960bcc`.

### 🔴 Studio-side work that is NOT in git

Seven boss models were **moved** (renamed + reparented, one undoable
ChangeHistory step, nothing destroyed) out of `Workspace` into
`ServerStorage.GameAssets.Guardians`, under the names `buildRig` looks up:

| Was (loose in Workspace) | Now |
|---|---|
| `Zone 6 Boss` | `Zone06_MummyGuardian` |
| `Zone 7 Sam Sulek` | `Zone07_Bodybuilder` |
| `Zone 8 Uncle Sam` | `Zone08_BankGuard` |
| `Zone 9 Mad Scientist` | `Zone09_MadScientist` |
| `Zone 10 Grandma` | `Zone10_Grandma` |
| `Zone 11 Foreman` | `Zone11_Foreman` |
| `Zone 12 Pilot` | `Zone12_AirportSecurity` |

**If the place is not saved, all seven revert to placeholder bodies.** §0
applies. The other loose models (`Zone 11 Boss Ladder`, `Zone 11 Foreman's
Toolbox`, `Zone 12 Pilot's Hat `, `Zone 12 Pilots Luggage`) are loot art, not
bosses, and were left where they were.

### What changed, by part of the brief

1. **Trail booth faces the plaza.** `TrailService.BOOTH_CFRAME` yaw 35 → 215
   (one CFrame moves the whole stall); the board's SurfaceGui face is `Back`.
2. **BASE button gone.** `GroupGiftController.buildOpener` clones `Top.Base`
   for the GIFT button's look, then destroys the original. The
   `TeleportHomeRequest` remote and its server handler are deleted.
3. **Bat swing animation** without inventing an animation id:
   `CombatController.playSwing` drops a `StringValue` named `toolanim` with
   value `"Slash"` into the equipped Tool, which is the cue Roblox's own
   `Animate` script listens for and answers with its licensed `ToolSlashAnim`.
   Falls back to the grip-weld swing on a rig without `Animate.toolslash`.
   `PvPConfig.BAT_STRIKE_DELAY` is 0.2 to land on the slash's forward pass.
   `hookTool` is guarded by a `_CombatHooked` attribute so equip/unequip cycles
   never stack `Activated` connections.
4. **Upgrade the base by clicking the sign.** `BaseSignController` (rewritten)
   lays a PlayerGui `SurfaceGui` on the sign's `Board` with one invisible
   `TextButton` exactly over the painted `ButtonEdge` (`0.05,0.56 / 0.9,0.35`),
   fires the existing `BaseUpgradeRequest`, paints green/red from `StatePush`
   (`cash` vs `slotsNextCost`), pulses when affordable, shakes + `UiDenied` when
   not, 0.6 s click lock. The Hold-E `UpgradePrompt` is removed from
   `PlacementService`; the slot prompts are untouched.
5. **Treadmill helper parts invisible.** `MapBuilder` sets the Belt to
   `Transparency 1`; `SpeedService.start` does the same for the baked map.
6. **Treadmill lock.** `TreadmillController` binds a RenderStep at
   `Input + 5` calling `humanoid:Move(Vector3.zero, true)` while training, so
   WASD cannot walk you off; **Space** ends training and sets `lockedOut` until
   you are physically off the belt, so a jump does not immediately re-engage.
7. **The UI is not hidden on the treadmill.** `TreadmillOfferController` no
   longer claims `UIStateController("treadmill")`; the Shop stays usable. The
   2X card is a side card — and **as of this pass it sits beside the stat card,
   bottom-aligned**, placed at runtime from `StatHUD`'s own Position/Size
   (`shownPosition()`). Its first position (under the nav rail) was found in
   testing to sit on top of the Speed counter, the one number a training player
   is watching.
9. **NEXT-area bar removed** from the HUD (`HUDController`; zone progression
   logic is server-side and untouched). `UIStateController.HUD_ELEMENTS` no
   longer lists `ZoneProgress`.
10. **NPC-hit offer** top-centre (`BossOfferController.SHOWN_POSITION 0.5,
    0.085`), auto-dismisses after 6.5 s via a `showToken` pattern (a newer
    show invalidates the older dismiss) instead of the old `while true` loop
    that was hiding it on a stale timer.
11. **RUN!!** top-centre in the same spot (`ChaseWarningController`, size
    `0.42 x 0.11`), and `stop()` is a 0.14 s shrink-fade so the offer can take
    the spot cleanly.
12. **Tutorial vase duplication.** Dropping the pinned tutorial vase sends it
    back to its pedestal instead of leaving a second one on the floor:
    `CarryService.returnsHomeOnDrop` is a provider injected from
    `init.server.luau` with `TutorialService.isTutorialLoot` (item id, zone 1
    socket 1, stage before INCOME), and `maintainTutorialLoot` no longer re-pins
    while the pinned vase is out being carried.
13. **Bosses much bigger, still chaseable.** `GameConfig.GUARDIAN_HEIGHTS`
    (7, 7.8, 8.8, 10, 11.5, 14, 17, 20.5, 24.5, 29, 34, 40) is the VISUAL
    height; `GUARDIAN_PHYSICS_MAX_GROWTH = 2.0` caps the collider, hip height,
    step height and catch radius at twice zone 1's. Feet are grounded by baking
    the costume's lowest-corner offset into `ShellMotor.C1` (C0 is what
    `animateShell` drives). Measured in play: heights 14.2 / 17.1 / 21.0 /
    24.9 / 30.0 / 34.5 / 40.8, feet within 0.6 studs of the floor, zone 6 wakes,
    chases, catches and returns exactly like zone 1.
14. **The painted Green Trail card** — next section.

### The painted card — `src/shared/Util/TrailCardPng.luau`

A trail whose `MonetizationConfig` entry carries `image = <assetId>` is drawn
from that PNG instead of the pack card. Only **Green** (`111545352261958`,
group-owned, 1024x720) has one. The Trail Shop branches on `trail.image` in
`build()` and `refresh()`; every other trail is the pack card, unchanged.

- **The art is untouched.** `ImageRectOffset (52,218)` / `ImageRectSize
  (918,300)` crop the transparent padding; the label carries a
  `UIAspectRatioConstraint` at `918/300`, so the art letterboxes inside the
  grid cell rather than stretching (251x82 inside a 263x82 cell at 1415x670).
- **Real buttons over the print.** Two transparent `TextButton`s, positioned in
  SCALE fractions of the art (`cash 0.4496,0.638 / 0.2525,0.29`; `robux
  0.7187,0.638 / 0.255,0.29`), measured off a probe render of the PNG and
  verified pixel-on with a tinted overlay. Because they are children of the
  aspect-locked art, the fractions hold at every size.
- **`TrailCardPng.DEBUG_HITBOXES = false`.** Flip to true to see them (green
  cash, blue Robux). Ships false; the buttons also keep their debug colour with
  transparency 1, so at runtime you can just set `BackgroundTransparency` on
  them from the client command bar.
- **Behaviour:** hover wash on the printed button, 0.96 press → Back-eased
  rebound, 2.5 % card lift, 0.5 s press lock. `AudioController` already sounds
  every button under MainUI, so the card passes no sound hooks.
- **The client decides nothing.** Cash → `TrailRequest("buyCash","Green")`,
  Robux → `TrailRequest("buyRobux","Green")` (gamepass `1970564658`, from
  config), owned → `("equip","Green")`. Same remote, same server validation as
  the pack cards. Ownership arrives on `StatePush.monetization`; the card only
  ever calls `setState`.
- **State overlays:** `EQUIP` / `✓ EQUIPPED` pill over the printed `$5K`, an
  `OWNED` pill over `R$14` and the Robux button retired once owned by either
  route. Nothing is drawn over the art until then.
- **To convert another trail:** author it on the same layout, upload, put
  `image = <id>` on its config row. Nothing else. If a future PNG uses a
  different layout, `TEMPLATE` needs a sibling, not an edit.

Trail Shop polish in the same pass: opens 0.92 → 1.0 (`UIAnim.POP`), closes to
0.92 in 0.18 s, the two tweens cancel each other (`panelTween`), cards stagger
in (`ShopKit.cascadeIn`, painted and pack cards alike).

### Guardian costumes keep their Humanoid now (`GuardianService.dressRig`)

Adopting zones 6 and 12 (R6 characters with Shirt/Pants/BodyColors) exposed
that `dressRig` was destroying the import's Humanoid and renaming its limbs to
`Shell_*` — and **clothing, CharacterMeshes and BodyColors only render beside
a Humanoid under canonical limb names**. The Egyptian boss stood there as a
bare tan block under a pharaoh's hat; the Pirate, Agent and Elf had been
losing their outfits the same way since §17.

Now the costume's Humanoid stays with `EvaluateStateMachine = false` (a pure
renderer: no state machine, no forces, no dying), names are left alone, and
every costume part goes in the `GuardianShell` collision group, which collides
with nothing. That last part is what makes it safe: the Humanoid does still
flip `CanCollide` back on for one part per costume (measured), and the group
makes that inert, so §5b's "adopted torso jams the guardian" failure cannot
come back. The costume is a nested Model, so the rig's own Humanoid never
treats those parts as limbs. Verified: zone 6 and zone 12 fully dressed at
14 and 40 studs, zone 6 chase → catch → return in under 2 s.

### Verified this pass (Studio, one player, in-memory profiles)

- Trail Shop opens from the booth circle (server-fired), Green card renders,
  hitboxes on the print, `$0` cash → server refuses and grants nothing, `$12K`
  → `buyCash` deducts 5K, owns, auto-equips, visual attached, pills flip;
  `buyRobux` reaches the server and opens the real gamepass prompt; X closes.
- Bosses: all twelve shells build; heights as above; zone 6 catch loop; zone 6
  and 12 costumes.
- NPC-hit offer at top-centre after a catch; `ChaseWarning.Run` is at
  `0.5, 0.085` sized `0.42 x 0.11`.
- Treadmill: HUD stays visible, W does not move you (1.60 → 1.60 studs from
  the trigger), Speed ticks up, Space then W walks you 90 studs off and the
  ticks stop, the 2X side card shows beside the stat card and hides off-belt.
  Belt parts invisible (7/7).
- Tutorial vase: steal → drop → back on the pedestal, one instance throughout,
  re-stealable.
- Bat: `toolanim` cue appears, `ToolSlashAnim` plays.
- Base sign: click layer present over the Board; red at `$0` vs `$1M`.

### NOT verified

- The gamepass prompt was **cancelled by stopping play**, not completed — the
  Studio test-purchase flow was not exercised. `PromptGamePassPurchaseFinished`
  handling is unchanged from before.
- RUN!! was verified by geometry, not by eye: with one stationary player the
  chase is over before a capture lands.
- Touch input, other resolutions, and more than one player.
- The group-join gift's live `PromptJoinAsync` flow (unchanged from §19's pass).

### Debug knobs that made this testable

- `monetize disown` — the place creator owns every gamepass, so on this account
  every trail card reads OWNED and the treadmill card reads MAXED until you
  pin the passes off. `monetize clear` is not enough (§14).
- `steal <zone> <socket>`, `drop`, `carry`, `standOnTreadmill`, `stepOff`,
  `setSpeed`, `trail buy|equip|unequip`, `resetTutorial`, `cash`.
- Anchoring a guardian's root from the command bar holds it in `Chasing` for a
  capture; unanchor it afterwards.

### Traps

- **The Studio command bar does not share the server's module cache.**
  `require(DataService)` from the Server command bar returns a fresh copy with
  no profiles. Go through `ServerStorage.DebugInvoke` for anything stateful.
- **MCP tool calls in one response run one after another**, in order. A client
  "watcher" issued alongside a server action starts only after the action has
  finished.
- **An open Roblox purchase prompt swallows all virtual input** ("hits
  CoreGUI"); Escape is a core-bound key the tool cannot send. Stop play to
  clear it.
- `screen_capture` does not draw CoreGui, so an open purchase prompt is
  invisible in captures but still blocks clicks.
- Far zones are not streamed until a character is near them; a camera capture
  of zone 12 from spawn shows sky and water.
