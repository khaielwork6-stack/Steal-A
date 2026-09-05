# Handoff — Steal Something

Written for the next Claude session. Read this before touching anything.

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
| *(this session)* | Zone 1/2 art pipeline, Storage UI rebuild, tutorial dedupe, audio pass |

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
| `StarterGui.MainUI` | The purchased UI pack (art + its own animation `LocalScript`) |
| `ServerStorage.GameAssets.Loot` | Zone 1: all but `Museum_Ruby`. Zone 2: all but `Pirate_CursedCoin` |
| `ServerStorage.GameAssets.Guardians` | `Zone01_Cop`, `Zone02_PirateCaptain` |
| `ReplicatedStorage.GameAssets.Mutations` | `Shiny`, `Golden`, `Flaming`, `Corrupted` |
| `ReplicatedStorage.GameAssets.Effects` | `LevelUpBlue`, `LevelUpGold` |

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
- **Phase 10 (UI/VFX/audio): mostly done.** All UI is on the pack, mutation VFX,
  upgrade VFX and real Zone 1 models are in. **Audio is untouched.**
- **Phases 11–13 (monetization, multiplayer hardening, polish): not started.**

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
- **Zone 1 has 8 items but only 4 models** (`AncientVase`, `Ruby`, `GoldenCrown`,
  `Diamond` still use placeholders). Zones 2–12 have none.
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
2. **Fix the lobby-music asset permission** (see §7) — one blocked asset id.
3. Add `Museum_Ruby` and `Pirate_CursedCoin`, then zones 3–12, using the naming
   contract in §6. No code needed, and no manual resizing.
4. Phase 11 (monetization), then 12–13.

12. **A character-shaped guardian costume gets ADOPTED by the rig's Humanoid.**
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
