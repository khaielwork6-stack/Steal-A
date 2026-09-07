# Handoff — Steal Something

Written for the next Claude session. Read this before touching anything.

> **START AT §29** (map polish 2: the lobby measured and shrunk, the colour
> restored, the checker floor, socket dressing), then §28 (the map overhaul:
> hub, plots, zones, gates, lighting, the upgrade sign - and the Studio Save
> it still needs), then §27 (pop-up
> placement, solid barrier, trail toggle, 2x Cash owned look, zone signs,
> hotbar, Next Update stand), then §26 (smart
> guardians that carry loot back, living loot, the
> Night barrier, Index previews, zone pop-ups, trail plates), then §25 (the
> STEAL & ESCAPE pass: pedestals, giant sizes, the Night cycle, chase audio,
> settings, the trail-shop fix), then §22, §21, §20, §19 and §18. Between them they say exactly where the last sessions stopped, what
> is verified, what is not, and what to pick up. §0 below is still the first thing you must *act* on (§20 moved 61 models
> that live only in the place file); §9's "next steps" list is older than
> §16–§21 and is superseded by them.

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
| `ServerStorage.GameAssets.Loot` | **92 items.** Zones 1–5 except `Museum_Ruby` and `Pirate_CursedCoin`; zones 6–12 complete except `Egypt_GoldenAnkh` and `SecretLab_PortalBattery` (54 models moved in from Workspace in §20 — **unsaved until the place is saved**) |
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
3. *(Done in §20 — zones 6–12 loot and guardians are all adopted; only
   `Egypt_GoldenAnkh` and `SecretLab_PortalBattery` still want art.)*
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
applies.

The **54 "Zone N …" loot models** staged alongside them were moved the same
way, into `ServerStorage.GameAssets.Loot` under the ItemIds below (one more
undoable ChangeHistory step, again unsaved until the place is saved). Nothing
zone-labelled is left loose in Workspace.

### Zones 6–12 loot: the roster now follows the Studio models

The brief for this pass was explicit: the current models are the source of
truth, "Zone N" naming says where a thing belongs, the GDD is only the shape
of the curve, and old GDD items are not to be resurrected. This was missed on
the first pass through Part 13 (only the bosses were adopted) and done after
the user asked. What was done, in order:

1. Inventoried every loose `Zone 6`–`Zone 12` model (54 items + 7 bosses).
2. Rewrote the zone 6–12 pools in `LootConfig` around those models. Each
   model took the ladder slot of the GDD item it replaced, or slotted between
   its neighbours, so **no income number changed and the rarity ladders are
   untouched** — only the objects did. Where the new model is the same kind
   of object as the GDD item in that slot the ItemId was KEPT and only the
   display name changed (ids are save keys); a genuinely different object got
   a new id. Two slots have no model and keep their GDD row as a placeholder.
3. Moved and renamed the models under the §6 contract.

| Zone | Ladder, position 1 → 8 (kept id = same id as before; *new* = new id) |
|---|---|
| 6 Egypt | Canopic Jar (kept) · Shawarma (*new*) · Ancient Mau (*new*) · **Golden Ankh (kept, NO ART)** · Mummy (*new*) · Throne of Ra (*new*) · Nemes Mask (*new*) · Egyptian Pyramid (*new*, jackpot) |
| 7 Gym | Water (*new*) · Creatine (*new*) · Gym Whistle (kept `Gym_CoachsWhistle`) · Vanilla Milkshake (*new*) · Airpods (*new*) · Golden Dumbbells (kept) · Trophy (kept) · Golden Barbell (kept, jackpot) |
| 8 Bank | Money Stack (kept) · Cash Briefcase (kept `Bank_CashBag`) · Master Key (kept `Bank_VaultKey`) · Shiny Coin (kept `Bank_RareCoin`) · Gold Bar (kept) · Banker's Briefcase (kept) · Platinum Bullion Stack (*new*, the deliberate $25M step) · Vending Machine (*new*, jackpot) |
| 9 Secret Lab | Chemical Flask (kept `SecretLab_SecretFormula`) · Chemical Cylinder (*new*) · Containment Tank (*new*) · Robot Spider (*new*) · Blue Crystal (kept `SecretLab_MutationCrystal`) · **Portal Battery (kept, NO ART)** · Energy Canister (kept `SecretLab_EnergyCore`) · Radiation Chamber (*new*, jackpot) |
| 10 Grandma | Colorful Bowl (kept `Grandma_CandyBowl`) · Red Shirt (kept `Grandma_KnittedSweater`) · Walking Cane (*new*) · Golden Teapot (kept) · Grandfather Clock (kept `Grandma_AntiqueClock`) · Pink Handbag (kept `Grandma_GrandmasPurse`) · Legendary Gift Box (*new*) · Cookie Jar (kept, jackpot) |
| 11 Construction | Blueprints · Rare Safety Vest · Foreman's Toolbox (all kept) · Metal Fence (*new*) · Golden Hard Hat · Golden Drill (kept) · Boss Ladder (*new*) · Diamond Hammer (kept, jackpot) |
| 12 Airport | First-Class Ticket · VIP Passport · Pilot's Hat · Lost Briefcase (all kept) · Unknown Briefcase (*new*) · Pilot's Luggage (*new*) · Air Tower (*new*) · Private Jet (*new*, jackpot) |

Retired ids (no model, dropped from the pools): `Egypt_AncientScroll`,
`Egypt_GoldenScarab`, `Egypt_RoyalScepter`, `Egypt_PharaohCrown`,
`Egypt_PharaohMask`, `Egypt_GoldenSarcophagus`, `Gym_ProteinTub`,
`Gym_VIPGymBag`, `Gym_WorldRecordMedal`, `Gym_ChampionshipBelt`,
`Bank_DiamondBriefcase`, `Bank_GoldenCreditCard`, `SecretLab_PrototypeChip`,
`SecretLab_GlowingSerum`, `SecretLab_RobotBrain`,
`SecretLab_ForbiddenExperiment`, `Grandma_SecretRecipe`,
`Grandma_FamilyJewelryBox`, `Construction_MasterKey`,
`Construction_ConstructionTrophy`, `Airport_AirportMasterKey`,
`Airport_BlackBox`, `Airport_GoldenSuitcase`, `Airport_DutyFreeDiamond`.
A saved trophy carrying one of these is left untouched by `reconcileItem`
(it never zeroes an id it does not ship), so nothing breaks; it just cannot
be rolled again. `validate.luau`'s Bank assertion now names
`Bank_PlatinumBullionStack`. Total stays 96, eight per zone.

`LootModel` had to grow for these imports: a **Tool now contributes every
part**, not just its Handle (the Gym barbell, the Bank briefcases and the Lab
tank are multi-part Tools and came out as a bare handle), **Humanoids and
scripts inside loot are destroyed** on build (the VIP Passport import carried
a Humanoid, which means a floating name tag), and **Seats are disabled** (the
Throne of Ra is a working Seat; brushing the pedestal would sit you on it).

Verified in play: `LootService` filled 12 x 4 sockets with validate passing,
zones 6–12 sockets came up 27 real / 1 placeholder (the Golden Ankh), and the
Shawarma renders on its pedestal at loot height with the right label.

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
- RUN!! seen by eye: red vignette, `RUN!!` top-centre, DROP button up, HUD
  tinted, while a 2M-Speed player outran the zone 6 guardian. The NPC-hit
  offer lands in the same top-centre spot after the catch and had cleared
  within 8 s of its last show (the 6.5 s timer was not clocked precisely: a
  second catch during the first card re-arms it, by design).
- Treadmill: HUD stays visible, W does not move you (1.60 → 1.60 studs from
  the trigger), Speed ticks up, Space then W walks you 90 studs off and the
  ticks stop, the 2X side card shows beside the stat card and hides off-belt.
  Belt parts invisible (7/7).
- Tutorial vase: steal → drop → back on the pedestal, one instance throughout,
  re-stealable.
- Bat: `toolanim` cue appears, `ToolSlashAnim` plays.
- Base sign: click layer present over the Board, red at `$0`, green at `$1M`
  (both by eye), the invisible button is what the engine reports under the
  cursor at the painted button's centre. `ensureSign` now forces
  `Board.CanQuery = true` (the `slab` helper turns it off for decor, and a
  SurfaceGui cannot take input through a part the pointer ray ignores).

### NOT verified

- **The actual click on the base sign.** The Studio MCP's virtual mouse drives
  2D ScreenGui buttons fine but never delivered a single event (not even
  MouseEnter) to any SurfaceGui button, including a throwaway control button
  on the same board — 3D GUI picking appears to follow the real OS cursor. One
  real click on the green button in a playtest settles it: expect the
  `BaseUpgradeRequest` round trip, `slotsUnlocked` 7 → 8 with enough cash, a
  shake and `UiDenied` without.
- The gamepass prompt was **cancelled by stopping play**, not completed — the
  Studio test-purchase flow was not exercised. `PromptGamePassPurchaseFinished`
  handling is unchanged from before.
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
- **Anchoring a guardian's root does not hold it in place** — the chase
  steering moves it by CFrame — so that trick does not freeze a chase. A
  faster player running away (Speed 2M vs zone 6) does.
- **Do not launch "Roblox Studio" from the desktop/computer-use side while a
  Studio is already open.** It runs the installer, the MCP bridge reconnects
  under a new `studio_id`, and the running playtest is dropped. Re-list
  studios and carry on; the place itself was unaffected.

---

## 21. The painted UI pass — every shop, offer and gift card is a PNG

The Green Trail experiment (§20) became the system. Every card in the Trail
Shop, the main Shop's three sections, the boss-hit Speed offer and the whole
Free Gift panel are now full-image PNGs with real, invisible Roblox buttons
laid over the printed ones. Nothing about what is sold, for how much, by which
gamepass/product id, or how it is granted changed: every button ends in the
same `TrailRequest` / `PurchaseRequest` / `GroupGiftRequest` call the pack
cards made.

### The three pieces

| File | Role |
|---|---|
| `src/shared/Config/PngUiConfig.luau` | Every painted card, MEASURED: image id, solid body box in canvas texels, printed-button rects as fractions of that body, and a family (`Trail`, `Cash`, `Speed`, `Pass`, `Gift`) with a common aspect. Nothing else in the game holds a crop or a hitbox number. |
| `src/shared/Util/PngCard.luau` | Builds one card: cell Frame (family aspect) → art ImageLabel (cropped, own aspect nudged ≤4% towards the family, letterboxed for the rest, centred) → regions. Two modes: **regions** (each printed button is its own TextButton — trails) and **wholeCard** (one button the size of the art, printed button lights up — products, boss offer). Hover lift, wash, 0.96 press → Back rebound, 0.5 s press lock, `pill()` overlays, `retarget()` to swap art, `setInteractive()`, `preload()`. `DEBUG_HITBOXES` tints regions; ships false. |
| `src/shared/Util/TrailCardPng.luau` | Thin trail layer over PngCard: cash + robux regions, EQUIP / ✓ EQUIPPED / OWNED pills. |

### How the numbers were measured (repeat this for any new asset)

In Studio, `AssetService:CreateEditableImageAsync(Content.fromAssetId(id))` →
`ReadPixelsBuffer`. Body = bounding box of alpha > 200 (the glow at alpha
10–200 is 1–3 px and is dropped). Buttons = column/row projection of the
"button green" mask (g ≥ 150, g−r ≥ 45, g−b ≥ 45) in the lower-right of the
body, widest runs first. The Green trail's background is green, so its two
pills are the probe-render numbers from §20. The gift's X (red mask) and its
"Join Community" (saturated blue, b ≥ 200, r ≤ 110) were found the same way.
Requires **Game Settings → Security → Allow Mesh & Image APIs**, which is on.

### Normalisation, and the one judgement call

The ten trail bodies range from 2.72 (Blue) to 3.15 (Golden) wide-to-tall.
The grid gives every cell the family aspect (2.97, the median); each card is
stretched **at most 4%** towards it and letterboxed for the remainder, so the
worst case (Blue) draws at 95% of the cell width with a 4% stretch nobody can
see, and eight of the ten fill their cell exactly. The Cash family (3.35) and
Speed family (2.975) are within budget throughout, so they all fill. This is
the compromise between "no card 5% bigger than another" and "never distort";
`PngUiConfig.STRETCH_BUDGET` is the dial.

Grids are sized in PIXELS from the scroller's real width (two columns at
47%, cell height = width / family aspect) and re-fitted on the scroller's
`AbsoluteSize` and on every open — `TrailShopController.fitCells`,
`ShopController.fitGrid/trackGrid`. That is what keeps painted cards the
same shape at any resolution; hitboxes are children of the art in Scale, so
they cannot drift from it.

### Where each surface changed

- **Trail Shop** — every trail has `image` in `MonetizationConfig.Trails`;
  `TrailShopController.buildPngCard` takes `PngUiConfig.card("Trail_<key>")`.
  Grey is cash-only and its art has one button, so it gets one region.
- **Shop** — `ShopController` builds `Pass_Cash2x`, `Product_Cash*`,
  `Product_Speed*` as whole-card PngCards (printed R$ lights up under the
  pointer). The pack-card path is still there for any product without art.
  Owned 2x Cash: an OWNED pill over the price and the card stops taking
  clicks — the art is never redrawn.
- **Boss-hit offer** — `BossOfferController` is one PngCard re-targeted per
  offered product (`Product_<key>`), whole card buys, pack X rides the art's
  corner. Entrance 0.85 → 1 Back + drop + fade; exit 0.18 s. Token
  auto-dismiss, re-punch on repeat catches, purchase-landed detection are
  all as before.
- **Free Gift** — `GroupGiftController` is PNG-only now: backdrop (tap to
  close), panel enters from 0.88 / slightly low with fade, CLAIM breathes
  (looping wash, stopped on close/claimed), hit regions for CLAIM, X and
  "Join Community" (group prompt only, no knock), CLAIMED! pill, auto-close
  1.4 s after a successful claim. `claim()` is the same prompt-then-knock
  flow. **The pre-PNG version is preserved verbatim at
  `src/client/Backups/FreeGiftUI_Backup_PrePNG.luau`** (`Client.Backups.*`
  in Studio); it is never required. To roll back, copy it over
  `GroupGiftController.luau`.
- **Preload** — `init.client.luau` calls `PngCard.preload(PngUiConfig.allImages())`
  at boot, in the background.
- **Not wired**: "10,000 Speed" (82539746649879) is a square illustration
  with no button and there is no 10K product; recorded in
  `PngUiConfig.Unused`.

### Verified so far

- Client boots clean with every controller (one Luau syntax slip in
  `PngCard.rectFor` was caught by the console and fixed).
- Trail grid: all ten cards painted, cells identical, art widths 92–100% of
  the cell exactly as the budget predicts, both regions present per card and
  one on Grey.
- Shop: Passes / Cash / Speed grids hold PngCards with per-section cells.
- Boss offer: a zone-6 catch produced the card with the zone's product art
  (`Product_Speed1M`), whole-card button, X, and the auto-dismiss disabling
  input on schedule.

### NOT verified — Studio's viewport was minimised (1×1) for the whole test window

TweenService and virtual input both stop while the Studio window is
minimised, so none of these could be exercised by tool:

- entrance/exit animations landing (positions/scale were frozen at their
  start values), hover, press;
- real clicks on any painted button: trail cash/Robux, shop products, 2x
  Cash, the boss card, gift CLAIM / X / Join;
- screenshots of the new cards, and the hitbox tint overlay on the nine
  newly measured trails.

Run those first next time, with the window up: open the Trail Shop (walk
onto the booth ring), `monetize disown` + `cash 200000`, click Blue's $
button (owned + equipped, cash −75K), click a Robux button (prompt), Shop →
2x Cash and one Speed card (prompts), a catch for the boss card, GIFT →
CLAIM (group prompt). Flip `PngCard.DEBUG_HITBOXES` to eyeball the regions,
then back.

---

## 22. Deep audit, test, optimisation and polish pass

A full read of every server service, every client controller, every shared
util and config, and the map builder, followed by a live test battery in
Studio. Nothing was redesigned; every change below fixes a confirmed defect
or removes confirmed waste. The §21 "NOT verified" list is now closed (see
"Verified" below).

### Fixed — CRITICAL

- **NaN through the remotes → permanent save failure.** `type(x) == "number"`
  accepts NaN, and NaN passes every `<`/`>` bounds test. `PlaceLootRequest(0/0)`
  therefore reached `PlacementService.place`, was written into the profile as
  `SlotIndex = nan`, and from then on every `UpdateAsync` of that profile
  failed (DataStores cannot serialise NaN) — one packet, data loss. New
  `src/shared/Util/Validate.luau` (`finite`, `integer(min,max)`, `vector3`)
  guards `PlaceLootRequest`, `InventoryRequest("store")`,
  `IndexClaimRequest("claim")` and `TrapPlaceRequest` (a Vector3 with a NaN
  component poisoned the clamp and the ground raycast).

### Fixed — HIGH

- **Player leaves while their profile is loading.** `DataService.load` yields
  on `GetAsync`; a player who left inside that window had already had
  `release` run, so the profile stored afterwards lived forever and was
  re-saved on every autosave (memory + DataStore budget on a ghost). Now
  dropped when `player.Parent` is nil after the read.
- **Plot leak on the same race.** `BaseService.start` waited on the profile
  and then called `assign` regardless; `assign` claims the plot BEFORE its
  own wait. A player gone by then leaked one of seven plots for the server's
  life. `assign` now refuses a departed player up front and unassigns after
  its own wait if they left during it.
- **Server over capacity.** `Players.MaxPlayers` is **60** in the place while
  there are 7 plots (`GameConfig.MAX_PLAYERS = 7` is defined but nothing can
  apply it — the property is read-only to scripts, and `Players.MaxPlayers = 7`
  from the Edit command bar is refused). Player 8+ had no base, no spawn and
  nowhere to place. `assign` now kicks with "This server is full - please
  join another one!" after a 1 s grace when no plot is free. **OWNER ACTION:
  set Max Players to 7 in File → Game Settings → Places** (that is the real
  fix; the kick is the safety net).

### Fixed — MEDIUM / POLISH

- `InventoryController` rebuilt every Storage row on every StatePush (1/s
  from income, 4/s while training) while the panel was open: hover lost,
  presses straddling a rebuild never became clicks, visible flicker. Rows now
  rebuild only when an item signature (id/rarity/size/mutation/income)
  changes. Verified live: rows survive pushes by identity.
- `BaseSignController` reset `affordable = nil` on every push, restarting
  the green bar's breathing loop from phase 0 once a second (a visible
  stutter). Only a price change or a rebuilt sign forces a repaint now.
- `GuardianFxController` spawned a Zzz BillboardGui every 0.85 s per sleeping
  guardian (12 of them) for the whole session, including ones past the
  billboard's own 320-stud MaxDistance. Cadence kept, object skipped when the
  camera is beyond that distance.
- `UpgradesController.robuxPrice` retried a failed `GetProductInfo` (a
  yielding web call) on every StatePush while the panel was open. Failed
  lookups now back off 30 s (`priceRetryAt`).
- `DebugService.sell` called the long-retired `PlacementService.sell` and
  errored; it now stores the slot and sells it out of Storage, the way a
  player does.
- **Map:** five floating import leftovers (`_ImportedAssets` folder with three
  accessories, two `Meshes/possion_*` MeshParts anchored at Y≈90, an
  unanchored "Ancient Scroll" and a "Cyan Plasma" model) sat in the sky above
  the safe zone. Moved (not deleted) to `ServerStorage._UnusedImports` with
  ChangeHistory; nothing in `src/` references any of them. **This is in the
  place file — it survived the last save; delete the folder when convenient.**

### Audited and left alone (deliberately)

- Lighting is a complete, deliberate grade (Atmosphere 0.20/haze 0.5, Bloom
  0.5/24/1.6, ColorCorrection +0.22 sat / +0.08 contrast, SunRays, sky,
  ClockTime 14, EnvDiffuse 0.55). Per the brief's "same map, preserve visual
  identity", it was not retuned. Map: 1295 parts, 0 unions/meshes/decals/
  lights beyond the authored ones, StreamingEnabled on.
- Per-frame work is already gated (Heartbeat/RenderStepped loops early-out
  when idle; ChaseWarning connects its loop only while live). Measured at
  60 fps client and 60 Hz server heartbeat with `HeartbeatTimeMs 0.01`,
  worst frame 18.9 ms, no instance growth across the whole battery
  (ActiveAudio 0, SpeedPopup/Burst/Toast 0, ZzzPuff bounded at 3).
- `SellLootRequest` and `StealRequest` are declared but have no server
  handler (sell goes through Storage, steal through the ProximityPrompt).
  Harmless dead remotes; left so client code that names them keeps
  compiling.
- `Lifetime.CashEarned` counts purchased Cash packs (cosmetic, leaderboard
  "money" is Cash). Noted, not changed.

### Verified live (Studio Play, single player)

- Boot clean, server and client. Only console noise: LobbyMusic
  `92804804272270` "not approved for the requester" (see owner actions).
- 33 malformed/hostile payloads across every remote (NaN, ±inf, wrong types,
  tables, junk actions): zero server errors, zero state change beyond the
  legitimately-argument-free `DropLootRequest`/`GroupGiftRequest`.
- Same-frame spam: 12× index claim → one claim; 16× place → one placement;
  10× `buyCash` → one purchase, one deduction; 10× upgradeStorage → one
  tier. Receipt replay: `Cash24K` granted once (+24,000), replay of the same
  PurchaseId returns Granted with +0, unknown product → NotProcessedYet.
- Steal → chase (`Chased` attr + guardian `Chasing`) → drop ends chase →
  loot back in its socket; goHome/place/income tick/store/equip/sell/base
  upgrade/storage upgrade/treadmill train + stop/treadmill upgrade/index
  discover + claim (2x pass doubles it, as designed)/gift claim (once)/trail
  buy + equip + unequip/trap placement outside the safe zone (refused inside)/
  bat swing on a dummy (refused inside the safe zone).
- Death while carrying: loot returned, chase cleared, respawn on own plot.
  Death while training: SpeedPower stops rising.
- **Painted UI (§21's open list):** Shop (2x Cash OWNED pill, five Cash
  packs, four Speed packs, scroll), Trail Shop (ten cards; repaint after
  `monetize disown` shows $ + R$ on every card, $ only on Grey), Free Gift
  (backdrop, CLAIM/X/Join regions), boss offer (zone 6 → `Product_Speed1M`
  art with the X). Real clicks on the invisible hitboxes: gift **X** closed
  panel + backdrop; Blue **$** bought and equipped Blue (200,000 → 125,000,
  ×2.5, card repainted ✓ EQUIPPED / OWNED); Purple **R$** raised the gamepass
  prompt (input then reports "hits CoreGUI", i.e. the CoreGui dialog is up).

### NOT verified — and why

- Multiplayer (PvP hits between real players, plot assignment for a second
  player, leave-mid-load in the wild): one client only in Studio MCP.
- Real DataStore round-trips: Studio API access is off (in-memory profiles).
- The full-server kick and the `MaxPlayers` setting: needs 8 real players.
- Hover/press micro-animations were not captured mid-tween (a press capture
  happens after the 0.08 s tween has settled); the states are visibly
  correct in the stills.
- Pack panel close **X** buttons and the rail while a pack panel is open:
  virtual input reports "hits CoreGUI" for the whole screen while the pack's
  modal is up, so those were exercised by the earlier pack-verification
  sessions, not this one.

### Owner actions

1. **Game Settings → Places → Max Players = 7** (see HIGH above).
2. **Lobby music**: `AudioConfig.LobbyMusic` (`92804804272270`) is not
   approved for this experience, so the lobby bed never plays in production
   either. Replace it with an audio asset the group owns or a Creator Store
   track inserted into this experience; do not guess an id.
3. Save the place (the `_UnusedImports` move is Studio-side).

### Studio tooling notes (learned this pass)

- A 1×1 client viewport (captures time out, tweens freeze) means the Studio
  window is minimised OR a script tab is in front. Restore with PowerShell
  `ShowWindowAsync(hwnd, 9)`, then `WScript.Shell.SendKeys("^{TAB}")` to
  cycle back to the game tab.
- `user_mouse_input`: use `instance_path`, not coordinates; `mouseButtonDown`
  and `mouseButtonUp` must be in the SAME call (a later call has no position
  and leaves the button stuck down — "duplicate button state"). The top bar
  strip (y < ~60) and the whole screen while a pack modal or a CoreGui
  purchase prompt is open report "hits CoreGUI".
- `screen_capture` needs a `capture_id` string. It never draws CoreGui.
- The trail shop opens server-side when the character is inside the booth
  ring (`teleport -75 6 -30`); no key press needed.
- Launching Studio via desktop automation, or reconnecting Rojo after a
  Studio restart, changes the `studio_id` — call `list_roblox_studios`.
- To film a moving guardian: pin the camera with a RenderStepped follow
  stored in `_G.__guardianFollow` (a one-shot camera set is stale by the
  time the capture lands), and slow the boss for the shot with
  `workspace.Guardians.<Name>.Humanoid.WalkSpeed = 25` — WalkSpeed is reset
  on the next wake.

---

## 23. Guardians walk with Roblox's own walk cycle

### What changed

- `dressRig` no longer welds every costume part to the pivot. A costume with
  a **standard skeleton** (`shellSkeleton`: a Humanoid plus the canonical R6
  or R15 part names and enough Motor6Ds) is welded at its HumanoidRootPart
  only; its limbs stay on their Motor6Ds so an Animation can drive them.
  Everything the rig carries through its own joints/welds/rigid constraints
  (`partsCarriedBy`: accessories, the held prop) rides along; any part it
  does not carry is pinned to the pivot as before, so nothing can fall off.
  An `Animator` is created under the costume's Humanoid on the server and
  the shell is stamped `Rigged = true`.
- `prepareWalk` (called at spawn, after the model is in workspace — earlier
  and LoadAnimation refuses) loads `GameConfig.GUARDIAN_WALK_ANIMATIONS[rigType]`
  — the ids Roblox's default Animate script ships as `walk.WalkAnim`
  (R6 `180426354`, R15 `913402848`), nothing uploaded or guessed — as a
  looped Movement-priority track, and returns the studs/s one unit of rate
  represents for this costume's height (`WALK_REFERENCE_SPEED[rig] ×
  height / 5`).
- `animateShell`: a rigged costume plays that track while Chasing/Returning
  at `AdjustSpeed(clamp(horizontal velocity / walkSpeedPerRate, 0.45, 2.2))`
  with a 7° forward lean, and stops it (0.25 s fade) on Sleeping/Waking; the
  slump and the outrage shake still pose the pivot. Props and custom rigs
  keep the rigid cartoon run untouched.

### Who walks, who still bobs

| Zone | Boss | Rig | Result |
|---|---|---|---|
| 2 | PirateCaptain | R6 | walks |
| 3 | RoyalGuard | R6 | walks |
| 4 | Agent | R6 | walks |
| 6 | MummyGuardian | R6 | walks |
| 8 | BankGuard | R6 | walks |
| 9 | MadScientist | R6 | walks |
| 11 | Foreman | R15 | walks |
| 12 | AirportSecurity | R6 | walks |
| 1 | Cop | 28 anchored meshes, no Humanoid, no joints | cartoon bob |
| 5 | ElfGuard | Humanoid but 0 Motor6Ds | cartoon bob |
| 7 | Bodybuilder | 54 anchored parts, no Humanoid | cartoon bob |
| 10 | Grandma | Humanoid, custom joints (`RightArm`, one `feet` part) | cartoon bob |

The four bobbers have no skeleton the stock walk can drive. **Drop a rigged
R6/R15 version of any of them into `ServerStorage.GameAssets.Guardians`
under the same name and it walks with no code change** — the detection is by
rig shape, not by zone.

### Verified live

- Boot clean; all twelve guardians assembled (rigged ones: 1 pivot weld,
  Motor6Ds intact, parts within the costume's own height of the root; props:
  welded part-by-part exactly as before).
- Pirate chase: track `180426354` playing, rate 1.41 at 31.9 studs/s; Left
  Hip swings ±45°, Right Shoulder ±60° per sample on the server AND on the
  client (replicated). Foreman chase: track `913402848`, rate 1.19–1.87.
  Both stop within the fade once the guardian sleeps; root anchored.
- Filmed mid-stride from a follow camera: Pirate Captain (R6) and Foreman
  (R15), costumes and accessories intact, feet on the floor.
- Catch, offer, drop, return and sleep unchanged.

### Staged but not yet adopted (owner supplied these after the pass)

`workspace` holds three rigged replacements: `Zone 5 Santa` (R6),
`Zone 7 Sam Sulek` (R15), `Zone 10 Grandma` (R6, standard joints). Each has a
proper skeleton and no scripts. Move them into
`ServerStorage.GameAssets.Guardians` as `Zone05_ElfGuard`, `Zone07_Bodybuilder`
and `Zone10_Grandma` (park the old models in `_UnusedImports`) and they walk
with no code change. Only the Cop would then still use the cartoon run.

---

## 24. Two placeholder loot slots filled from the imports

- `Egypt_GoldenAnkh` (zone 6, slot 4, $11K/s, no art) → **`Egypt_AncientScroll`
  "Ancient Scroll"**, art = the owner's `Zone 6 Ancient Scroll` MeshPart.
- `SecretLab_PortalBattery` (zone 9, slot 6, $60M/s, no art) →
  **`SecretLab_CyanPlasma` "Cyan Plasma"**, art = the 4-part `Cyan Plasma` model.
- New ids because they are different objects (ids are save keys); incomes and
  ladder positions unchanged, so `validate` still passes 12×8.
- Studio side (place file — **save**): both models renamed to their ItemIds,
  anchored, and moved into `ServerStorage.GameAssets.Loot` (now 94 children).
- Verified in Play: config resolves both ids, `LootModel.hasArt` true for both,
  `grant` places each on a display slot and it renders (scroll 4.9 studs,
  plasma 2.6 studs), zone 6/9 economy listings show the new names.
- **Still without art: `Museum_Ruby`, `Pirate_CursedCoin`.** The `Pirate Wheel`
  the owner wanted for zone 2 is an EMPTY Accessory (no Handle, zero
  descendants — the import lost its mesh), so there is nothing to show; it
  stays in `_UnusedImports._ImportedAssets`. A re-imported wheel with a Handle
  dropped in as `Pirate_CursedCoin` (or a new id in that slot) will be picked
  up automatically.

---

## 25. The STEAL & ESCAPE pass — pedestals, giant sizes, Night, chase audio, settings, trail shop

The owner supplied a 17-page brief ("STEAL & ESCAPE — BASE, PEDESTAL, NIGHT &
GAMEPLAY POLISH") plus six reference images. Everything in it is implemented
and was exercised live in Studio Play (single player) unless listed under
25.5. All of it is in the commit after `6a6dab2`. Read this section top to
bottom before touching any of these systems.

### 25.1 What changed, by system

**Pedestal displays (BaseService, DisplayFxController, MapPalette)**
- Every occupied display slot now builds `ServerStorage.GameAssets.Pedestal`
  (the imported union, fitted uniformly to `PEDESTAL_MAX_FOOTPRINT = 8` and
  `PEDESTAL_HEIGHT = 5`; its rotated pivot is preserved with
  `PivotTo(CFrame.new(...) * pedestal:GetPivot().Rotation)` — dropping the
  rotation lays it on its side) with a neon `Accent` ring in the rarity colour.
  The trophy sits on the accent (`seatTrophy`), footprint-capped at
  `TROPHY_MAX_FOOTPRINT = 18`.
- Slots have three states (`styleSlot`: Locked / Empty / Occupied) drawn with a
  four-part neon `NeonFrame` (colours in `MapPalette.SlotNeon*`, pad colours
  `MapPalette.SlotPad*`). The old white `SlotRim` glow is gone. Attributes
  `SlotState`, `NeonColor`, `NeonRest` drive the client.
- Nameplates are three lines (`buildLabel`): name, "Rarity · Size · Mutation",
  income. Titan+ trophies get a `SizeSparkle` emitter.
- The owner sign (`ensureOwnerSign` / `paintOwnerSign`) stands at the slab's
  front-left corner: real headshot via
  `Players:GetUserThumbnailAsync(userId, HeadShot, Size150x150)` (pcall,
  guarded by the `OwnerUserId` attribute so a late thumbnail cannot paint a
  previous owner), display name, @username, a `YourBase` badge the client
  shows only on the local player's plot, and a crown from base tier
  `CROWN_TIER = 4`. Unowned plots read AVAILABLE.
- `DisplayFxController` (new) is the ONE client animation manager for every
  trophy: registry by `DescendantAdded` under `Map.Bases` (StreamingEnabled
  safe), culled beyond `ANIMATE_DISTANCE = 260`, spin `0.55/sqrt(scale)`, bob
  only for scale <= 2.6, breathing neon on Empty slots, pop-in on first sight,
  `setReducedEffects` kills the sparkle emitters and the bob.
- The Upgrade Base sign's progress line now reads
  "Level 1 > Level 2  ·  8 slots" (PlacementService.refreshUpgradeSign).
  The button already performed the real upgrade; unchanged.

**Giant items (RarityConfig, LootModel, LootService, CarryService, DataService, EconomyService)**
- `RarityConfig.Sizes` is now the six-tier ladder the brief asked for:
  Normal 70 / Big 20 / Huge 8 / Giant 1.5 (x3.5 income, 2.6x scale, 18 %
  slow) / Titan 0.4 (x4.5, 6–8x, 22 %) / Colossal 0.1 (x6.0, 15–20x, 25 %).
  Helpers: `sizeRank`, `rollVisualScale` (rolled ONCE at spawn, uniform in
  [scale, scaleMax], 2 dp), `clampVisualScale`, `carryVisualScale`
  (knee at 2.6: `2.6 + sqrt(v - 2.6)` above it).
- The existing relative `Model:ScaleTo` pipeline is kept; the universal 10x
  cap is gone. Instead: `LootModel.WORLD_MAX_FOOTPRINT = 110` in the world,
  `TROPHY_MAX_FOOTPRINT = 18` on a pedestal, and the carry knee. Every built
  model gets `LootWeld` WeldConstraints from the PrimaryPart so a Colossal
  carry cannot shed parts.
- `LootInstance.visualScale` is persisted as `DisplayItem.VisualScale`
  (schema v6 migration fills it from the size default; `reconcileItem`
  clamps it into the tier's range). `GrowthSeconds` likewise.
- Tall loot gets a `PromptAnchor` (invisible 2x2x2 part welded above the
  socket) and `interactRange = max(14, footprint/2 + 10)`; the steal
  validation measures against that part at `interactRange * 1.6`.
- Carry: scale > 2.6 rides overhead with its lowest point 2.6 studs above the
  root (`CARRY_OVERHEAD_CLEARANCE`), `CanQuery = false` while carried; drop
  seats the lowest point on the floor.
- Income formula unchanged. Growth during ownership
  (`NightConfig.GROWTH_*`): +10 % income and +8 % size reached after 20 min of
  ownership, x5 speed during Night, applied in 10 steps by `applyGrowth`
  (in-place ScaleTo by the ratio of `GrowthApplied`, re-seated on the accent).
- `DebugInvoke` gained `spawnSize(zone, socket, sizeId, itemId?)`,
  `sizeSim(trials)`, `growth(slot, seconds)`, `grant(..., visualScale)`.

**Night (NightConfig, NightService, NightController, LootService, GuardianService)**
- One authoritative 240 s cycle with a 10 s Night, published as
  ReplicatedStorage attributes `NightPhase`, `NightCycleStart`,
  `NightPhaseEndsAt`, `NightCycleSeconds`, `NightSeconds` on
  `workspace:GetServerTimeNow()`. Clients derive everything from those; no
  countdown is trusted from a client.
- `beginNight`: `LootService.setClosed(true)` (every StealPrompt disabled,
  steals refused with the closed reason), `GuardianService.resetAll()`,
  `returnEveryone()` (ring of `LOBBY_RING_RADIUS = 12` around
  `Map.SpawnLocations.LobbySpawn`, facing +Z), "NIGHT — LOOT REFRESHING"
  toast, then the refresh after `REFRESH_DELAY_SECONDS = 1.5`, guarded by the
  cycle number so it runs exactly once. Carried items are NOT touched; the
  carrier keeps them through Night and can place them afterwards (tested).
- `endNight`: refresh if it somehow has not run, reopen, "All loot refreshed!
  Go steal something!" fallback, then up to `SPOTLIGHT_MAX = 2` spotlight
  toasts spaced `SPOTLIGHT_GAP_SECONDS` apart, using the item's real display
  name and the zone's display name ("...spawned in Grandma's House!"), never
  "Zone 10".
- The refresh lean: `LootService.setRollBoosts` multiplies the weights of
  Legendary+ rarities and Huge+ sizes by 1.5 and renormalises. Pity is
  disabled (`PITY_ENABLED = false`) as the brief asked; there is no pity code.
- The old 300 s refresh loop inside LootService is gone; NightService owns
  the cadence. `GameConfig.GLOBAL_REFRESH_INTERVAL` mirrors
  `NightConfig.CYCLE_SECONDS` and `validate.luau` asserts they match.
- `NightController` (new): the compact pill at top-left (calm / warning at
  15 s / night colours) becomes a centred banner during Night; night lighting
  and atmosphere are tweened in and the exact day values captured at start
  are restored after. Warnings at 15 / 10 / 5 s.
- `GuardianService.resetAll()` clears every chase, target and steering state
  and puts each guardian back to sleep in place. `DebugInvoke night(in N |
  begin | end)` and `NightService.status()` drive it for tests.

**Guardians**
- Zone 5, 7 and 10 now use the owner's imports: `Zone05_ElfGuard` <- "Zone 5
  Santa" (R6), `Zone07_Bodybuilder` <- "Zone 7 Sam Sulek" (R15),
  `Zone10_Grandma` <- "Zone 10 Grandma" (R6). The replaced props are parked as
  `ServerStorage._UnusedImports.Zone0X_*_replaced`.
- Every rigged guardian plays Roblox's stock idle while Sleeping
  (`GameConfig.GUARDIAN_IDLE_ANIMATIONS`, R6 180435571 / R15 507766666) and
  the stock walk while moving (§23). Idle stops the moment it wakes.
- Each catch plays that zone's own hit sound (`AudioConfig.GuardianHits`,
  `guardianHitCue(zoneIndex)`) at the guardian, once.

**Chase audio (AudioConfig, Audio, AudioController, ChaseAudioController, init.server)**
- `ChaseAudioController` (new) is an explicit Idle / Alerted / Chasing state
  machine with token cancellation. Chased -> true: Alerted, 0.4 s, then the
  loop (one reused Sound under SoundService). `SoundCue "EscapeSting"`: loop
  stopped at once, sting, 0.5 s, "Escape". Chased -> false (catch, drop,
  death, Night): fade out and cancel any pending start. No zone-entry music
  exists anywhere.
- Two bugs found by the live test and fixed: (a) `toIdle` no longer bumps
  the token when already Idle — the server clears Chased in the same frame as
  the sting cue, and that redundant call was cancelling the follow-up
  "Escape" cue; (b) `LootService.returnToOrigin` now clears
  `escapeNotice`/`deliveredNotice`, so an item that already produced one
  escape stings again for its next thief (it used to go silent forever).
- IDs from the brief: Escape SFX 138891370077088 (`EscapeSting`), UI open
  97861038165143 (`UiOpen`, played when a panel becomes Visible; `UiToggle`
  removed, `UiDenied` kept for refusals), Bat hit 106511269477863, twelve
  guardian hits (see `AudioConfig.GuardianHits`), chase music 34234642
  (`ChaseMusic`) — that last one does NOT load, see 25.5.
- SoundGroups `Music` and `SFX` (client-side, `Audio.group`) are the mixer
  buses the settings sliders drive.

**Settings (SettingsService, SettingsController, DataService, StateService, Remotes)**
- Persisted per player in `profile.Settings`: `MusicVolume` (0.7),
  `SfxVolume` (0.8), `Shadows` (true), `ReducedVFX` (false), `ScreenShake`.
  `SettingsRequest` (rate limit 4/s) validates on the server (finite, clamped
  0–1, booleans) and marks dirty; the state push carries `settings` back.
- The pack's Settings frame rows are wired: `Music` / `Sound_Effects` sliders
  (an invisible `Hit` TextButton overlay takes the input because the fill and
  knob sit above the track; drag via `UserInputService.InputChanged`, commit on
  release, a `Value` readout added), `Shadows` toggle (row relabelled from
  "Textures"; drives `Lighting.GlobalShadows`), `VFX` toggle (inverse of
  `ReducedVFX`; feeds `NightController.setReducedEffects` and
  `DisplayFxController.setReducedEffects`). Nothing touches Roblox's own
  master volume.

**Trail shop (TrailShopController)**
- Root cause of "randomly does not open": the pack's UIAnimationHandler
  closes frames by tweening them OFF-SCREEN and leaves them there, and the
  trail shop cloned `Frames.Shop` lazily on first open — so whenever the Shop
  had been opened and closed before the first booth visit, the clone
  inherited an off-screen Position (and the pack's `hideOwnHud` state). Fix:
  build eagerly at start from the pristine `StarterGui.MainUI.Frames.Shop`
  (Position / AnchorPoint / Size / BackgroundTransparency copied from it),
  call `_G.CloseAllUIFrames` before showing, and watch `Frames` children's
  Visible so an opening pack frame closes the trail shop. No workaround layer.

**Validation / schema**
- `DataService.SCHEMA_VERSION = 6` (VisualScale, GrowthSeconds, Settings
  defaults). `validate.luau` covers the size ladder, the Night constants and
  the mirror; 907 checks pass.

### 25.2 Lives only in the place file — the owner must SAVE

- `ServerStorage.GameAssets.Pedestal` (Model, `Body` union as PrimaryPart).
- The three guardian swaps above and the parked `_replaced` props.
- §24's loot renames (`Egypt_AncientScroll`, `SecretLab_CyanPlasma`).
If the place is not saved, the game runs but pedestals fall back to nothing
(BaseService logs a warning) and zones 5/7/10 revert to the old props.

### 25.3 Assets used and their status (all preload-probed in Play)

| Asset | Id | Status |
|---|---|---|
| Escape SFX | 138891370077088 | loads, plays |
| UI open | 97861038165143 | loads, plays |
| Bat hit | 106511269477863 | loads, plays |
| Guardian hits 1–12 | see `AudioConfig.GuardianHits` | all 12 load |
| Chase music | 34234642 | **fails: "Asset type does not match requested type"** — not an audio asset |
| Lobby music | 92804804272270 | still "not approved for the requester" (pre-existing) |
| Idle animations | 180435571 (R6), 507766666 (R15) | Roblox's own, play |
| Walk animations | §23 | Roblox's own, play |
| Sparkle texture | 241594419 | loads |

### 25.4 What was actually tested (Play, single client)

- Size ladder: `sizeSim(200000)` within tolerance day and night (night lean
  Huge 11.4 %, Giant 2.16 %, Titan 0.56 %, Colossal 0.138 %). Colossal
  spawned via `spawnSize` painted 84 studs tall, prompt reachable through the
  `PromptAnchor` at range 52, carried overhead with the lowest point 2.6 above
  the root at 25 % slow, placed on a pedestal capped at 18 studs footprint,
  persisted scale survives store/equip.
- Pedestal system: Locked / Empty / Occupied restyle on place, store, equip,
  upgrade and sell; pedestal + trophy + 3-line label + sparkle; owner sign
  with the real headshot (`rbxthumb://type=AvatarHeadShot&id=...`), YOUR BASE
  badge only on the local plot, AVAILABLE on empty plots.
- Night: full cycle run twice with `night("in", 5)`: prompts disabled, steals
  refused, all guardians reset, lobby ring teleport, lighting + banner,
  48/48 sockets refreshed once, spotlight toasts with real names, day
  restored; a carried item survived Night and was placed after.
- Chase audio, read from the CLIENT DataModel (client-set attributes are
  invisible to the server — that cost one wrong measurement): Alerted ->
  Chasing at +0.41 s with the loop started; crossing the line -> sting cue,
  loop stopped, `EscapeSting` then `Escape` at +0.51 s; a second escape with
  the same returned item stings again; catch -> Idle with the loop fading and
  the zone's hit sound at the guardian.
- Guardians: idle tracks on all rigged sleepers including the three new
  models; walk cycle while chasing.
- Settings: toggles persist round-trip (`{"Shadows":false,"ReducedVFX":true}`
  echoed back from the server), Shadows drives GlobalShadows, slider click
  -> 0.50 fill / readout / Music bus volume.
- Trail shop: with the pack Shop open, entering the booth closed it and
  showed the trail shop on-screen at the pristine position.
- Regression: steal / place / store / equip / upgradeBase / sell / treadmill /
  gift / index paths through `DebugInvoke`, consoles clean apart from the two
  asset failures above.

NOT tested (cannot be, from Studio MCP): multiple simultaneous players
(everyone-to-lobby with several characters, spotlight fan-out, per-player
settings isolation), DataStore persistence across sessions (API access is
off in Studio; the migration is code-reviewed only), and the sound of the
chase loop itself (the id is not audio).

### 25.5 Remaining issues / the owner's steps

1. **Save (and publish) the place** — see 25.2.
2. **Chase music id 34234642 is not an audio asset.** Supply a real, approved
   audio id and put it in `AudioConfig` under `ChaseMusic`; nothing else
   needs to change. Until then the chase plays alert + sting + safe cue with
   silence where the loop should be.
3. Lobby music 92804804272270 is still not approved for this experience
   (pre-existing; needs an owned/approved audio or the group's asset
   permissions).
4. Game Settings -> Max Players = 7 (from §22; the server guard is in place).
5. The Pirate Wheel import has no Handle (§24); a re-import would slot in
   as zone 2's fourth item automatically.

### 25.6 Tooling notes learned this pass

- `start_stop_play` takes `is_start: true|false`, not `action`.
- Client-set attributes (`ChaseAudioState`, the settings mirrors) can only be
  read from the Client DataModel. A server read returns nil and proves
  nothing.
- After a code edit, stop Play, poll the synced `Source` for a unique string
  from the edit (an Edit-mode `execute_luau` loop), THEN start Play; Rojo
  needs ~3 s and Edit-mode commands are refused during Play.
- The owner's PDF brief could not be read by the Read tool or the browser;
  rendering pages to PNG with WinRT `Windows.Data.Pdf.PdfDocument` from
  PowerShell into the scratchpad worked.
- `DebugInvoke` new commands: `spawnSize`, `sizeSim`, `growth`, `night`,
  `lootSnapshot(zone?)`, `chase` (guardian states + your Chased flag).

---

## 26. The "additional requirements" pass — smart guardians, living loot, the Night barrier, Index previews, zone pop-ups, trail plates

The owner's second brief (14 pages, sections A–K). Everything in it is
implemented and was exercised live in Studio Play (single client) except
where 26.4 says otherwise. Read §25 first for the systems this builds on.

### 26.1 Guardian chase logic (GuardianService, CarryService, LootService)

The chase is now a real state machine, and the guardian PHYSICALLY carries
loot back. States, as published on the model's `State` attribute:

    Sleeping -> Waking (WAKE_DELAY, alert once) -> Chasing
    Chasing  -> escape (thief across the line) | catch -> ReturningLoot
    Recovering (walking to a dropped item) -> ReturningLoot -> Returning -> Sleeping

- **Dynamic pace.** `paceFor()` = base pace inside `catchRadius + NEAR_BAND`,
  rising smoothly to base × (1 + `CATCHUP_BOOST` 0.35) at `FAR_BAND` 70
  studs. `driveSpeed()` is the ONLY writer of WalkSpeed during a job and
  eases exponentially (`SPEED_EASE` 2.4/s) — measured: 9.2 → 17.7 → 16.8 on
  a standing thief, 36.6 → 57.7 on a fleeing one. Inside the near band the
  pace is exactly the base, so whether a thief at the zone's recommendation
  escapes is still decided by `speedForChase` — the boost only ever closes a
  gap, never wins the last ten studs. A trap's root (`rootGuardian`) holds
  zero and hands back to `guardian.currentSpeed` on expiry.
- **Multi-target.** The "one chase per zone" refusal is gone
  (`CarryService.validateSteal` no longer asks `isZoneBusy`). The guardian's
  work is DERIVED each time it needs it from `LootService.instancesInZone()`:
  the nearest valid carrier (Carried, alive, has a root, on the danger side)
  is the target; every `SCAN_INTERVAL` (0.4 s) it switches only if another
  carrier is under `SWITCH_MARGIN` (75%) of the current distance AND at least
  `SWITCH_MIN_GAIN` (12 studs) closer. Only the current target carries
  `Chased = true`. No stored reference can go stale: the target is
  re-validated from LootService every frame. **Not exercised live** — needs
  two players (see 26.4).
- **Catch.** `CarryService.reclaim` no longer teleports the item home. It
  detaches it, sets state `Escorted`, and `GuardianService.beginEscort` welds
  the model over the guardian's head (`attachEscort`: unanchored, massless,
  compressed to `carryVisualScale`, lowest point at the costume's `Height`).
  The guardian walks to the item's ORIGINAL socket (`stepEscort`) and within
  `ESCORT_REACH` 7 studs calls `LootService.returnToOrigin(loot, 0)` — the
  SAME instance rebuilt in the same socket — then takes the next job or goes
  home. Measured: catch → socket refilled with the same id in ~0.4 s of
  walking, asleep 3 s later.
- **Drop recovery.** `CarryService.dropLoose` (DROP button, bat hit, death,
  reset, disconnect via `releaseCarry`) lays the item down as `Dropped` and
  fires `GuardianService.noticeDrop`; a sleeping or returning guardian goes
  to fetch it (`Recovering`), picks it up within `catchRadius + PICKUP_REACH`,
  and escorts it home. Players may still grab it first (then they are
  chased). Two floors under it: a drop the guardian cannot walk to (behind the
  red line — `canRecover`) goes home after `DROPPED_RECLAIM_WINDOW` 8 s; ANY
  drop still lying there after `DROPPED_ORPHAN_TIMEOUT` 75 s, or a job past
  `JOB_TIMEOUT` 60 s, goes home the instant way. Nothing can be orphaned.
- **Night.** `resetAll()` returns escorted loot to its socket instantly and
  sleeps every guardian; `refreshAllUnboosted` calls `LootService.retireLoose`
  first so a leftover drop cannot come home into a refilled socket.
- **Re-grabs wake the guardian.** The old listener ignored `Dropped →
  Carried`, which let a thief drop, wait for sleep, grab and walk off free.
  `engage()` handles every state now.
- New `LootState` `"Escorted"`. New debug commands: `guardian(zone)` (state,
  target, base/current pace, distance), `socket(zone, index)`,
  `lootState(id)`.

### 26.2 Client work

- **WorldLootFxController** (new): every socketed loot turns (0.5 rad/s ÷
  √scale), hovers 0.22 studs up to the carry knee, and sits on a neon
  `LootRing` in its rarity colour (Legendary+ also a PointLight). Registry by
  `DescendantAdded` under `Map.Zones`, `SETTLE_SECONDS` 0.5 before the rest
  pose is captured, culled past 320 studs, unregisters the frame the model
  leaves its socket. Loot models are now `ModelStreamingMode.Atomic`
  (LootModel.build) so streaming can never hand the client half a model to
  pivot. `LootService.buildModel` stamps `VisualScale` / `Size` / `Mutation`.
- **Night barrier** (NightController): a client-only, non-colliding part
  (356 × 170 × 1.2) at Z = 0.8, just past the red line and in front of the
  zone-1 sign boards, with a SurfaceGui on each face: pale gradient, moon,
  countdown, "NIGHT — LOOT REFRESHING", subtitle. Fades element by element
  and the SurfaceGuis are `Enabled = false` after the fade-out.
  **CanvasGroup.GroupTransparency is NOT honoured on a SurfaceGui** — the
  first version used one and the wall's text stayed visible in daylight.
  Text on a SurfaceGui caps at 100 px, so the canvas is 2.5 px/stud.
  Closure itself stays server-authoritative (LootService.setClosed).
- **Nightfall timer** moved to the bottom-right (`PILL_POSITION`), where the
  "Displays 0/7" counter was; that label is destroyed by HUDController.
  Reads "Nightfall in 3:50" / "Night Reset 8s"; amber under 15 s, breathing
  under 10, punches on the last five; never becomes a banner any more.
  `NightService.forceNight` re-anchors the cycle so a forced Night lasts
  exactly NIGHT_SECONDS.
- **Speed feedback** (TreadmillController.spawnHudPopup): the stat card's
  Speed row flashes cyan and punches, and a "+N Speed" lifts off its right
  end, every `SPEED_HUD_INTERVAL` 0.6 s summing the ticks in between (5 in
  3 s measured). Same real server delta as the world popup.
- **Index**: the server publishes sanitised clones of every loot asset under
  `ReplicatedStorage.LootPreviews` (`LootModel.publishPreviews`, 94 of 96
  ids — `Museum_Ruby` and `Pirate_CursedCoin` have no art and keep the rarity
  plate). `ItemThumb.apply(icon, rarity, itemId)` drops the real model into a
  ViewportFrame on the card, three-quarter framed; `applyUnknown` shows it as
  a black silhouette (black ambient + light, textures hidden) on an unlit
  plate — rarity never leaks. Discovered previews turn while the panel is
  open; cards lift on hover and cascade in; a zone header ("Zone 7 · Gym 💪 ·
  3/8 found") sits above the grid. Storage cards use the same previews.
- **Zone pop-up** (ZonePopupController, new): geometry-driven from
  MapConfig bands, `SETTLE_SECONDS` 0.45 before a zone counts, re-announces
  only after the player has genuinely been elsewhere. ToastController style
  `zone`. `ZoneConfig.Zones[i].emoji` added (single code points; Pirate Island
  is ⚓ because ZWJ flags do not render).
- **Trail cards** (PngCard / TrailCardPng): state pills are now OPAQUE
  plates grown by `PILL_PAD` (and `PILL_EXTRA_LEFT.robux` for the icon left
  of the printed R$ button), clamped so the OWNED plate never crosses the
  EQUIP plate on the Green card. Three exclusive states: not owned = printed
  $ / R$ live; owned = EQUIP (live) + OWNED (R$ dead); equipped = ✓ EQUIPPED
  (dead) + OWNED. A dead region's invisible button is disabled, so nothing
  hidden takes a tap. Verified visually in all three states.
- **Audio**: LobbyMusic → 1848354536, ChaseMusic → 113688019858504 (both
  preload `Success`). `AudioController.setDucked` drops the lobby bed to 20%
  for the length of a chase (ChaseAudioController drives it from its state).

### 26.3 What was tested (Play, one client, all through `DebugInvoke`)

- Catch: Waking → Chasing → ReturningLoot → Returning → Sleeping; the socket
  holds the same instance id; pace samples show the ramp and the settle.
- Drop in the zone: Recovering → Escorted (parented to the guardian) →
  Spawned in the original socket; same id.
- Death mid-carry: item Dropped where the thief died; recovered the same way.
- Fleeing thief (walkSpeed 104): pace 36.6 → 57.7 with the gap, escape at the
  line, Chased cleared, guardian home; the item dropped behind the line went
  home on the 8 s timer.
- Night during an escort: guardian asleep at its post, loot back in socket.
- Barrier appears with the countdown, is gone (`Enabled = false`) after Night.
- Zone pop-ups: Pirate Island → (no repeat inside it) → Castle → lobby →
  Pirate Island again.
- Index: 8/8 discovered zone renders lit models; undiscovered render
  silhouettes; header correct.
- Trail shop: screenshots of the three states, plates clean on all six cards.
- Speed HUD popups and the row flash while on the treadmill.
- Consoles clean at start and after every test.

### 26.4 Not tested / remaining

- **Multiple players** (target switching, two thieves in one zone, per-player
  pop-ups): impossible from a single Studio client. The logic is
  code-reviewed; test with two clients on a real server before trusting it.
- Late joiners during Night read the same attributes as everyone (unchanged
  from §25) — not re-tested this pass.
- The two ids without art (`Museum_Ruby`, `Pirate_CursedCoin`) still show a
  rarity plate in the Index and a placeholder in the world.
- Nothing Studio-side changed this pass; §25.2's Save is still owed.

---

## 27. Seven fixes — pop-up placement, solid barrier, trail toggle, 2x Cash owned look, zone signs, hotbar, Next Update stand

The owner's third brief (3 pages, items 1–7). All seven done and tested in
Play; §27.4 lists the one thing Studio cannot show.

### 27.1 What changed

1. **Zone pop-up** (ZonePopupController): no longer a toast in the pack's
   centre-screen stack. It is its own label at the top (`POSITION` 0.16 of
   the screen, under the RUN!! slot), pack face and outline, a white-to-zone
   gradient. `ZoneConfig.Zones[i].color` is new (Gym green, Egypt gold,
   Grandma's warm peach, ...). Pops in, holds 1.7 s, fades; a new zone
   replaces it in place. Debounce and "no repeat inside the same zone"
   unchanged from §26.
2. **Night barrier** (NightController): `CanCollide = true` while it stands,
   off again the moment the fade-out starts. The local character is
   simulated on its own client, so a local collidable part is a real wall.
   Measured: a MoveTo through it at walkSpeed 108 stopped at Z = -0.3
   against the wall's face at Z = 0.2. Server closure still refuses steals.
3. **Trail cards** (TrailCardPng / TrailShopController): the OWNED tag and
   the EQUIP pill are gone. Owned cards get ONE polished `EquipToggle`
   (TextButton over the art, spanning both printed prices, opaque plate,
   rarity-coloured stroke, hover lift, press dip): "EQUIP" → equips;
   "✓ EQUIPPED" (green, reads UNEQUIP under the pointer) → unequips via
   `TrailRequest("equip", "")`. While the toggle shows, both printed
   regions' hidden buttons are disabled. Not owned: printed $ / R$ live, no
   toggle. Pack-built (non-PNG) cards toggle the same way.
4. **2x Cash** (ShopController): no OWNED pill. Owned = the print tinted
   grey (`ART_OWNED_TINT`), a small green ✓ badge top-right
   (`buildOwnedBadge`), card inert. In Studio the creator owns every pass,
   so this is what the Shop shows there.
5. **Zone signs** (ZoneSignService rewritten): dark rounded panel (SurfaceGui
   frame with UICorner on an invisible board), zone emoji + number + name,
   RECOMMENDED SPEED caption, the figure in the zone's jackpot-rarity
   colour, neon cap. Planted `SIGN_LEAD` 16 studs BEFORE the zone's near
   edge, turned `SIGN_YAW` 20° in toward the lane, face on Front (-Z) - the
   old ones sat inside the zone with the face on Back, readable only after
   walking past. Model name `Sign_<id>` and the `Board` part are kept for
   TutorialService.
6. **Hotbar** (HotbarController, new): the owner's MenuButtons frame (moved
   Studio-side from Workspace to `ReplicatedStorage.UITemplates.MenuButtons`;
   the Workspace spot is still accepted) cloned into `HotbarUI`, cut to four
   slots keyed 1-4, bottom-centre. Slot = key number, tool name, and a
   ViewportFrame of the tool's own Handle. Bat is always 1, Trap always 2.
   Keys (UserInputService) and taps toggle through
   `Humanoid:EquipTool/UnequipTools`; the equipped slot lifts with a green
   stroke. Roblox's CoreGui Backpack is switched off. TWO PACK TRAPS hit and
   fixed: its buttons ship `Active = false` (Activated never fires), and
   setting a UIStroke Thickness in pixels draws a screen-sized black slab
   (colour only, as ShopKit warns).
7. **Next Update stand** (EventStandService + EventStandController, new):
   the owner's `NextUpdate` model (one board part, dropped 65 studs in the
   air) is MOVED to `Map.NextUpdateStand`, stood on two posts at (-42, 0,
   -96) facing the lobby spawn, given the pack's `NextUpdate` SurfaceGui
   face and its "Next Update! / Notify Here!" billboard, and a
   `NotifyPrompt` (E, hold 0.35 s, 14 studs). The board's studded surfaces
   hid the SurfaceGui - set Smooth. The client answers the prompt with
   `SocialService:PromptRsvpToEventAsync(GameConfig.NEXT_UPDATE_EVENT_ID)`
   ("4257917435077853831"), labels the prompt "Following ✓" from
   `GetEventRsvpStatusAsync`, and toasts the result. A 20 s watchdog frees
   the prompt if the dialog never returns.

### 27.2 Tested (Play, one client)

- Pop-ups: Gym 💪 in green, Grandma's House 👵 in peach, at the top; no
  repeat while moving inside the same zone.
- Barrier: solid during Night, walk-through and invisible after.
- Trail toggle: click → UNEQUIP + trail on the character; click → EQUIP,
  trail off; Grey (unowned) shows the printed $100 and no toggle.
- 2x Cash: greyed print, badge, button inert (screenshot).
- Signs: "3. Castle / RECOMMENDED SPEED / 10K" readable on the approach
  from the lane centre; "1. Museum / STARTER ZONE" from the lobby.
- Hotbar: click slot 1 → Bat held, slot lit; click again → unequipped;
  slot 2 → Trap. Number keys cannot be sent by Studio's VirtualInput
  ("permanently bound to a CoreGUI core action"); the InputBegan path is
  the same code as the click path.
- Stand: face, title and prompt present; a held E fired PromptTriggered.

### 27.3 Studio-side (needs a Save)

- `workspace.MenuButtons` → `ReplicatedStorage.UITemplates.MenuButtons`.
- The `NextUpdate` model is re-parented and repositioned at runtime by the
  server, so nothing about it needs saving; the invisible `Action` pad the
  owner dropped in `workspace.Folder` is untouched.

### 27.4 Not verifiable here

- `PromptRsvpToEventAsync` never returns inside Studio (no dialog exists
  there), so the "You'll be notified" toast could not be seen; on a live
  client Roblox's own follow-event dialog opens. `GetEventRsvpStatusAsync`
  does answer in Studio (Going).
- The stand's face is the pack's own "ULTIMATE BRAINROT UI PACK - DM
  mangoui TO BUY" art (asset 126081168374124) - that is what the supplied
  SurfaceGui contains and what the reference image shows. Swap the
  ImageLabel's Image in `StarterGui.MainUI.Surface/Billboards.NextUpdate`
  for the game's own art when there is one.

## 28. Final pre-release map overhaul — hub, plots, zones, gates, lighting, upgrade sign

The map is GENERATED (`MapBuilder.build()` + `MapLandmarks.build`), so the
overhaul lives in the generator and was rebuilt in Studio; nothing inside
`Workspace.Map` is hand-placed. The old map is kept as a backup (28.5).

### 28.1 What changed

- `MapConfig`: `SAFE_ZONE_DEPTH` 64, `PLAZA_CORRIDOR_WIDTH` 124, `PLOT_DEPTH`
  176, `HEAD_PLOT_DEPTH` 96, `TREADMILL_STANDOFF` 16, `DISPLAY_SLOT_SIZE`
  17, `DISPLAY_BACK_INSET` 16, `DISPLAY_FRONT_RESERVE` 44, new `PORCH_DEPTH`
  22, wall pilaster/trim sizes, gate pylon/lintel sizes and `GATE_INSET`, and
  `MapConfig.HUB` (spawn (0,0,-34) facing +Z, `trailBooth`, `eventStand`,
  `leaderboards` at x ±70, `avenueWidth`). Lane width, zone lengths and the
  red line are UNCHANGED on purpose: chase balance is calibrated to run
  lengths.
- `MapPalette`: calmer, desaturated set; every key the code reads is present.
- `MapBuilder` (rewritten): paving (spawn circle, avenue, spur), wall bays
  (pilasters + trim on inward faces), a gate per zone (two pylons in the
  zone colour, a lintel with `{emoji} {NAME}`), dark 16-stud plinth sockets
  with a rim, invisible guardian posts, opaque locked pads, plots with a
  porch, fence rails, planters, lamps and two slot columns (the head plot
  gets rows across its width - it used to cram 7 pads into 32 studs), hub
  props, sockets/posts from `MapLandmarks.layouts` with prop clearance and
  `settle`, and a `LobbySpawn` that faces the Zone 01 gate. Decor and gate
  parts are non-colliding (`applyDecorCollision`).
- `MapLandmarks`: a props library (`crate`, `barrel`, `rock`, `bush`, `cone`,
  `bench`, `stall`, `barrier`), a `dressing` cluster per zone, and
  `MapLandmarks.layouts` - four socket offsets and a guardian post per zone,
  authored in the 320-wide lane space like the landmarks.
- `ZoneSignService`: ONE sign per zone, on the LEFT of the entrance, facing
  incoming players (`SIGN_INSET` 30).
- `LeaderboardService`, `TrailService`, `EventStandService`: positions come
  from `MapConfig.HUB`.
- `BaseService`: `styleUnowned` dresses every plot at start (the flashing
  white ground was the builder's near-white pads on the six unowned plots);
  `spawnsAtHub` (wired by init to `TutorialService.isAtStart`) and
  `homeSpawn` - one answer for the first join AND every respawn. The respawn
  handler in `init.server.luau` used to pivot every new character to the
  plot 0.2 s after `assign` had put a new player on the hub.
- `PlacementService`: `requestUpgrade` for both input paths, a
  `ClickDetector` on the sign board (range 40, owner only), and a 0.35 s
  `PRESS_WINDOW` that folds the second arrival of one press (the SurfaceGui
  button and the detector both fire for a single click). `BaseSignController`
  makes the whole board the hit target.
- `EnvironmentService` (new, first service started): Lighting numbers and
  the Bloom / ColorCorrection / Atmosphere / SunRays instances are set at
  server start, so the grade is the code's and not the last Studio session's;
  `default.project.json` carries the same Lighting properties.
- `LootModel.TROPHY_MAX_FOOTPRINT` 15 (fits the 17-stud pad).
- `InteractController` disables the UI pack's un-adorned `Titles`
  billboards ("Top Cash", "Gamepasses", "Next Update! Notify Here!"): a
  BillboardGui with no Adornee draws at the world origin, which is now the
  red line dead centre of a new player's first view. The server clones the
  StarterGui originals for the boards and the stand and enables its own.

### 28.2 Layout decisions

- Hub: the spawn circle is 28 studs from the gate pylons, facing them; the
  trail booth on the left (-66), the Next Update stand on the right (66),
  the two boards flank the gate at ±70; planters on ±X of the circle, lamps
  on its diagonals so nothing stands on the spawn-to-gate line. The avenue
  runs back from the circle to the head plot; treadmills stand in the avenue
  16 studs off each porch.
- Plots: 176 deep for 14 pads in two columns; the porch holds the spawn
  (facing the avenue), the upgrade pad 16 studs along the porch from it
  and the owner sign at the front corner (the pad's first position shared
  studs with that sign; see `buildBase`).
- Zones: the gate names the zone from a distance (the far lintels read over
  the near ones - that is the "anticipation" beat); the sign is left of the
  gate; sockets sit where the landmark suggests them (museum forecourt,
  pirate beach, castle yard...) and never inside scenery.
- Lighting: Brightness 2.2, exposure -0.05, bloom 0.22 above 2.2, +6%
  saturation, a light atmosphere haze; depth of field off.

### 28.3 Tested (Play, one client, DataStores off)

- Console clean at start; 12 guardians posted on the new posts; 12 x 4
  sockets filled; 12 signs / 12 boards; boards at (-70,6.4,-12) and
  (70,6.4,-12); stand at (66,0,-40); every unowned plot's slots Empty /
  Locked from the first frame.
- First join: the character stands at (0,2.7,-34) looking +Z, on the
  `LobbySpawn`; tutorial stage STEAL.
- Steal (1,1) → ESCAPE stage → `goHome` → PLACE stage → placed: pedestal
  5.1 wide on the 17-stud pad, trophy on top, socket re-pinned.
- Treadmill training at the new standoff (`standOnTreadmill`).
- Upgrade sign: a pointer click on the board (ClickDetector path) bought
  exactly one tier (7→8 slots, -$1M) and repainted the sign; two remote
  arrivals 50 ms apart bought one tier (9→10), not two.
- Trail booth: standing on the circle at (-57,0,-40) opened the shop.
- Zone 2 chase from the new post: Waking → Chasing → ReturningLoot →
  Returning → Sleeping in 4 s, loot back in its socket.
- Night `begin`: `NightBarrier` present at the red line.

### 28.4 Not verified here

- The SurfaceGui button path of the sign: Studio's simulated pointer
  reaches `UserInputService` but not 3D GUI buttons, so only the detector
  path was exercised. A real mouse fires both; the press window is what
  keeps that to one purchase. Touch and gamepad: no device.
- Multiplayer (seven plots at once), mobile performance: not testable here.
  Part count 1788 (old map 1295).
- The Next Update stand: the live API answered "Event has already started"
  for event 4257917435077853831, so the prompt is refused and the stand
  shows its "not available right now" toast. The ID needs a future event.

### 28.5 Studio-side (needs a Save / Publish)

- `Workspace.Map` was rebuilt by the generator in Edit mode. To rebuild
  again after a code change: `require` a FRESH CLONE of
  `ServerScriptService.Server` (Edit-mode `require` caches modules for the
  whole session and serves a stale `MapBuilder` otherwise), call
  `MapBuilder.build()`, destroy the clone.
- Backups: `ServerStorage._MapBackup_2026-09-07` (the old Map, 1295 parts)
  and `ServerStorage._RootBackup_2026-09-07`. Delete them once the new map
  is accepted; they are not referenced by anything.
- Still pending from §27: `ReplicatedStorage.UITemplates.MenuButtons`.

## 29. Map polish pass 2 — the lobby actually shrank, the colour came back, the floor got its checker

§28 was judged on the right things and got two of them wrong: the lobby was
recomposed but not REDUCED, and "less neon" was implemented as less
saturation, which read as pastel. This section is the correction. Everything
§28 built - porches, fences, aisles, gates, one sign per zone, the hub
composition - is kept.

### 29.1 The lobby, measured

Measured off the built map, not off the config:

|                                   | before  | after   |        |
| --------------------------------- | ------- | ------- | ------ |
| plaza floor                       | 476x356 | 376x320 | -29%   |
| safe apron                        | 256x64  | 256x52  | -19%   |
| lobby floor total                 | 185,840 | 133,632 | -28%   |
| OPEN floor (no plot on it)        | 72,560  | 34,560  | -52%   |
| corridor between the plot rows    | 124     | 80      | -35%   |
| paved avenue                      | 26x318  | 20x282  |        |
| spawn -> trail booth circle       | 57      | 30      | -47%   |
| spawn -> event stand              | 66      | 38      | -42%   |
| spawn -> leaderboard              | 73      | 47      | -36%   |
| spawn -> Zone 01 gate             | 28      | 20      |        |
| spawn -> own plot (Base01)        | 98      | 76      |        |
| spawn -> head plot (Base07)       | 302     | 274     |        |
| map parts                         | 1,788   | 2,765   | +55%   |

Where the space came from, in order of size:

1. **Plots hold the same 14 pads in less floor.** Three ranks instead of two
   ranks of seven (`DISPLAY_SLOT_COLS = 3`, 5/5/4 on one shared rank grid) cut
   `PLOT_DEPTH` 176 -> 148, and the plaza is two plot depths wide, so that
   alone is 56 studs off the width. Frontage 84 -> 76.
2. **The corridor was sized off what stands in it, not off a feeling.** A
   treadmill deck reaches 20 studs in from each plot edge, so 80 leaves a
   clear 40-stud street (measured by raycast: 40). It was 124.
3. **The head plot now spans the whole back** (`HEAD_PLOT_WIDTH` follows
   `PLAZA_WIDTH`, 376). At lane width it left a 110-stud pocket of bare floor
   in each back corner - 21k studs of nothing. Its pads stay grouped in the
   middle (`HEAD_PLOT_RANK_SPAN = 232`).
4. **The apron lost 12 studs and the hub furniture moved in** to +-38 from
   +-66, with the spawn circle at Z -26 (was -34) and 26 across (was 30).

Deliberately NOT changed: `LANE_WIDTH`, zone lengths, the red line. Chase
balance is calibrated against run lengths (§25's speed audit) and shortening a
zone would silently re-tune every guardian.

### 29.2 Colour: rich, not neon, and not pastel

The two failure modes are separate problems and are now fixed separately.
Exposure and bloom stop the world hurting the eye; saturation and contrast
carry the colour. §28 fixed the first by attacking the second.

- `EnvironmentService` / `default.project.json`: Brightness 2.2 -> 2.6,
  ExposureCompensation -0.05 -> -0.15, OutdoorAmbient 150,156,170 ->
  128,136,152 (a high sky-fill was bleaching the greens), Bloom 0.22@2.2 ->
  0.16@2.6, ColorCorrection Saturation 0.06 -> 0.22 and Contrast 0.06 -> 0.14,
  Atmosphere Density 0.24 -> 0.15 and Haze 0.6 -> 0.3, ShadowSoftness 0.55 ->
  0.35.
- `MapPalette`: grass back to a saturated green (126,208,82), plots a step
  lighter, walls to a richer clay (198,138,96) with a green cap, every zone
  surface re-saturated a step. Paving deliberately off-white
  (192,183,162): at brightness 2.6 a near-white avenue was the brightest
  thing on screen and read as a runway.

### 29.3 The checker floor

The checker system already existed; it was invisible because the pairs sat 10
RGB apart at a 44-48 stud tile - one square per screen. Now ~20 RGB apart at
**18 studs in the lobby and 22 in the zones**, which reads as a pattern from
standing height with the studs still visible on top. That is the +977 parts:
the tiles are one part per light square (anchored, CanCollide off, CastShadow
off).

**Z-fighting, found and fixed:** the plot floor slab and the plaza slab both
had their top at exactly Y = 0, and the plot's checker tiles sat at the same
0.02 as the plaza's - the two surfaces fought across every plot. The plot
floor now sits 0.15 proud (slab -0.45, tiles -0.33), well under a step
height.

### 29.4 Zone composition

`MapLandmarks.dressSocket(zoneIndex, decorFolder, worldPos)` puts two or three
themed props beside every loot plinth - barrel and crate at the pirate
plinths, hedges at the museum's, cones at Area 51's, urns in Egypt, a mat and
a weight in the Gym. 48 plinths, ~500 zone decoration parts in total.

It is a separate hook and not part of `dressing` for a reason: MapBuilder
settles each socket AGAINST the scenery, so anything placed near a socket
beforehand just pushes that socket elsewhere. This runs after placement, from
the socket's final world position, into the zone's `Decorations` folder -
which `applyDecorCollision` makes hollow, so none of it can catch a running
player or a guardian (verified: 0 colliding decoration parts).

### 29.5 Tested in Play (one client, DataStores off)

- Console clean; 7 plots x 14 pads; 12 zones x 4 sockets filled; 12 guardians;
  12 signs; booth, stand and boards at their new hub spots.
- Spawn at (0, -26) facing the gate; steal -> escape -> place (pedestal and
  trophy on the pad); treadmill at the new 13-stud standoff.
- Upgrade sign: one pointer click on the board bought exactly one tier
  ($1M, 7 -> 8 slots) and repainted itself. The two sign boards on the
  narrower porch do not overlap (measured).
- Trail booth circle at (-29, -32), 30 studs from spawn, opens the shop.
- Zone entry pop-up "Museum" at the top centre; Night barrier blocks the line
  (walked into it: stopped at Z -4.9); loot refreshed 48/48 after Night.
- Avenue raycast at torso height from the head plot to the red line: CLEAR at
  x = -16, -8, 0, 8, 16. Clear corridor width 40 studs at every treadmill row.
- Walls enclose the new plaza on both sides and behind the head plot.

### 29.6 Not verified

- Multiplayer (7 plots occupied at once) and mobile frame rate. Part count is
  up 55% and all of it is anchored, non-colliding, shadowless tiles, but no
  device test was possible here.
- The SurfaceGui button path on the upgrade sign (Studio's simulated pointer
  cannot reach 3D GUI buttons); the ClickDetector path was the one exercised.
