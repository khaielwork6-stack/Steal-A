# Agent prompt — First-minute onboarding (objective banner, chevron trail, target ring)

Paste everything below the line into Claude Code, in this repo.

---

You are building one feature area for the Roblox (Luau) game **Steal & Run!**.
Read `docs/AGENT_RULES.md` first and obey every rule in it — especially: no
Roblox Studio MCP, no Studio launch, `bash tools/check.sh` clean before and
after, `selene src` at 0 errors, tabs, `--!strict`, "why"-style comments, no
`sed -i`, no reformatting, no new art assets.

Then read, in this order:

- `docs/START_HERE.md` (architecture, the core loop)
- `src/server/Services/TutorialService.luau` (the whole existing state machine)
- `src/client/Controllers/TutorialController.luau` (the whole existing arrow)
- `src/client/Controllers/ChaseWarningController.luau` (header only)
- `src/client/Controllers/FlyoverController.luau` (header only)
- `src/client/Controllers/ToastController.luau` (header only)
- `src/client/StateStore.luau` (header only)
- The seven stills in `docs/tutorial-reference/` — **look at them**. They are
  frames from the competitor build this brief is modelled on. `03-` and `04-`
  are 2x closeups of the two visuals you must match.

## What this is

The first sixty seconds are the hook of this game. Right now the tutorial is a
single bobbing `▼` chevron over a target and literally nothing else — no words,
no path, no confirmation. A new player does not know what "steal" means here,
does not know where home is, and does not know that a sealed container has to be
revealed.

You are replacing that with the three-part presentation in the reference stills:

1. **One objective line** at the top of the screen that says what to do now.
2. **A trail of chevrons on the ground** running from the player's feet to the
   objective, flowing toward it.
3. **A ring with a verb** drawn in the world at the exact spot to interact with,
   for the two steps that need a button press rather than a walk.

Short, friendly, premium. It must be the calmest thing on screen while also
being impossible to miss.

## Hard constraints (read these twice)

- **Presentation stays on the client; the server still decides every step.**
  `TutorialService` owns the stage machine and pushes it through
  `StateService`'s tutorial provider into `state.tutorial`. The client renders
  `state.tutorial` and can never advance it. Do not add a remote — this rides
  the existing push.
- **The objective line is not a toast and must never stack.** There is exactly
  one line, it is replaced in place, and it is the *only* text the tutorial
  adds. Read the "WHY THERE ARE NO STAGE BANNERS" note at the top of
  `TutorialController.luau`: stage text used to be pushed as toasts and it
  stacked into a wall of words over the player. That decision is being reversed
  **only** for this one fixed, non-stacking line. Keep it that way — do not
  route any tutorial copy through `ToastController`.
- **Do not build a "RUN!!" banner.** `ChaseWarningController` already owns the
  chase warning, and it is correctly gated on the server's `Chased` attribute
  plus a live carry. The tutorial's contribution to that beat is the objective
  line changing and the trail turning red (see below). Adding a second RUN
  element would double up on a real chase.
- **Nothing you add may eat input.** Every `Frame`/`TextLabel` gets
  `Active = false` and `Interactable = false`; nothing is a `GuiButton`. On
  touch the HUD is already crowded — see the note in
  `EscapeFlashController.luau` about the flash sitting over the thumbstick.
- **No image, mesh or sound assets.** Everything below is buildable from parts,
  `UICorner`, `UIStroke` and text. Where the reference uses a drawn icon (the
  pointing hand), ship without it behind a `0` asset id and write the Codex
  prompt for it — rule 7 in `AGENT_RULES.md`.
- **One loop.** `TutorialController` already owns a single `Heartbeat`. Keep it
  at one connection for the whole feature. No `task.delay` chains, no per-step
  connections, no per-frame `Instance.new`.

---

# Part 1 — Server: fix the step machine, then give it words

## 1a. The bug you must fix first

`deriveStage` in `TutorialService.luau` currently reads:

```lua
local placedFirstItem = profile.Index[GameConfig.TUTORIAL_ITEM_ID] == true
```

`Profile.Index[itemId]` is **not** written at placement. It is written in
`HatchService.commit` (search for "DISCOVERY HAPPENS HERE"), at the reveal. The
comment in `IndexService.luau` that says PlacementService writes it is stale.

So the window between *placing the sealed container on a pedestal* and
*revealing it* derives to neither `PLACE` (the player is no longer carrying) nor
`INCOME` (nothing is discovered yet), and falls through to the final
`return STAGE.STEAL`. **A brand-new player who has just done the hardest part of
the loop is told to go back to the museum and steal another one**, for at least
`GameConfig.TUTORIAL_HATCH_SECONDS` and in practice until they happen to find
the Reveal prompt on their own. Verify this reading against the code before you
change anything; if you conclude it is wrong, say so and stop.

## 1b. Add a reveal step — without adding a stage number

The `STAGE` numbers are persisted in `Profile.TutorialStage` and the save is
monotonic (`if stage > profile.TutorialStage`). The two free slots (`2`, and the
retired `6`) both sort wrongly for a step that belongs between `PLACE = 4` and
`INCOME = 5`. **Do not renumber and do not reuse them.**

Instead: the reveal step is emitted as `STAGE.PLACE` (4) — the persisted number
is unchanged — and the client is told which of the two it is by a new
client-facing field. Extend `TutorialState`:

```lua
export type TutorialState = {
	stage: number,        -- unchanged: persisted, monotonic, drives derivation
	step: string?,        -- what the CLIENT renders. Decoupled from `stage` on
	                      -- purpose: copy must never be hostage to a number
	                      -- that cannot be renumbered.
	title: string?,       -- the one objective line
	target: Vector3?,     -- where the chevron trail runs to
	pointer: string?,     -- nil, or the verb for the world ring at `target`
	showIntro: boolean?,  -- unchanged, still ignored by the client
}
```

`step` is one of `"steal"`, `"escape"`, `"place"`, `"reveal"`, `"income"`,
`"train"`, `"nextZone"`, or `nil` at `COMPLETE`.

In `deriveStage`, before the final `return STAGE.STEAL`, add the sealed case:
scan `profile.DisplayItems` for an entry whose `ItemId` is
`GameConfig.TUTORIAL_ITEM_ID` (or any id in `GameConfig.TUTORIAL_LEGACY_ITEM_IDS`)
with `Hatched ~= true`. If one exists, return `STAGE.PLACE`. Keep the existing
carry check ahead of it, and keep the `STEAL` fallback after it, so a caught or
dead thief still drops back to "steal it again" exactly as today.

In `buildState`, `STAGE.PLACE` now branches:

- still carrying → `step = "place"`, target = first free `DisplaySlot` (as now),
  `pointer = "PLACE IT HERE"`
- sealed item on a pad → `step = "reveal"`, target = that item's
  `DisplaySlot<NN>` part position, `pointer = "OPEN IT"`

Use `HatchService.isReady(item)` if you want the line to read differently while
it is still incubating (`TUTORIAL_HATCH_SECONDS` is 5, so this is a brief beat —
a single "It's opening…" line with no pointer is enough, and the pointer appears
when it is ready). Requiring `HatchService` from `TutorialService` must not
create a require cycle; check the boot order in `src/server/init.server.luau`
and, if it would, read the `Hatched` flag directly off the profile instead and
leave `HatchService` alone.

## 1c. The copy

Server-owned, one short sentence each, sentence case, one exclamation mark at
most. These are final — use them verbatim:

| `step` | `title` | `pointer` |
| --- | --- | --- |
| `steal` | `Steal your first treasure!` | — |
| `escape` | `Run it home!` | — |
| `place` | `Put it on a pedestal!` | `PLACE IT HERE` |
| `reveal` | `Open it!` | `OPEN IT` |
| `income` | `It's earning you cash!` | — |
| `train` | `Train your Speed!` | `STEP ON` |
| `nextZone` | `Zone 2 is open — go deeper!` | — |

`income` deliberately has no target and no pointer: it is a beat, not a task,
and `evaluate` already times it out after `TUTORIAL_INCOME_DWELL`.

Nothing else changes on the server. Do not touch the intro-window logic, the
`maintainTutorialLoot` pinning, or the persistence rules.

---

# Part 2 — Client: the three visuals

All of this lands in `src/client/Controllers/TutorialController.luau`, replacing
the current `▼`. It keeps its single `Heartbeat` and its
`StateStore.subscribe`. Delete the old billboard chevron entirely.

## 2a. The objective line

Top-centre, in a new `ScreenGui` (`ResetOnSpawn = false`, `IgnoreGuiInset = true`,
`DisplayOrder` just under the toast stack so a toast is never hidden by it).

- Text: `state.tutorial.title`. Font `Enum.Font.FredokaOne` — the file already
  uses it. `TextColor3 = Color3.fromRGB(255, 255, 255)`, a `UIStroke` of
  `Thickness = 3.5`, `Color = Color3.fromRGB(16, 12, 10)`,
  `LineJoinMode = Miter`. No background, no panel, no plate — see `01-` and
  `05-`: the line floats over the world.
- Position: `AnchorPoint = (0.5, 0)`, `X = 0.5 scale`,
  `Y = GuiService:GetGuiInset().Y + 84` on desktop, `+ 58` on touch
  (`Device.isTouch()`). Recompute on `GetPropertyChangedSignal("ViewportSize")`
  and on `GuiService.SafeZoneOffsetsChanged` — a phone rotating must not leave
  it under the notch.
- Size: `UDim2.fromScale(0.9, 0)` with an absolute height of 44 (34 on phone),
  `TextScaled = true` plus a `UITextSizeConstraint` of `MaxTextSize = 34`
  (`26` on phone) so one long line never balloons.
- Transition when `title` changes: old label tweens `Position` up 12px and
  `TextTransparency`/`UIStroke.Transparency` to 1 over 0.14s
  (`Quad`/`Out`), then the new text slides in from 14px below with a small
  overshoot (`Back`/`Out`, 0.55 overshoot, 0.20s). Two labels swapped, or one
  label re-tweened — either is fine, but a change must never flash an empty
  frame and must never queue: if a second change arrives mid-transition, it
  cancels and replaces.
- `title == nil` → fade out over 0.2s and leave the GUI in place, empty.
- Honour `Effects.isReduced()`: no slide, straight cross-fade.

## 2b. The chevron trail — the hero visual

Look at `docs/tutorial-reference/03-chevron-closeup.png`. Rounded-corner filled
triangles lying flat on the ground, marching from the player toward the target.

**Geometry, without an image asset.** Each chevron is a triangle built from two
mirrored `WedgePart`s, plus a second, larger mirrored pair underneath in the
outline colour to fake the thick stroke:

- fill pair: `Color3.fromRGB(238, 52, 44)` when chased, otherwise
  `Color3.fromRGB(255, 204, 56)`. `Material = Enum.Material.SmoothPlastic`,
  small `Neon`-free — do not use Neon, it blows out on bright museum floors.
- outline pair: `Color3.fromRGB(46, 8, 6)`, scaled 1.18x, sitting 0.02 studs
  lower so it reads as a stroke from any angle.
- size: 4.5 studs wide, 5 studs long, 0.3 thick; floating 0.35 studs above the
  surface it was raycast onto.

Every part: `Anchored = true`, `CanCollide = false`, `CanQuery = false`,
`CanTouch = false`, `Massless = true`, `Locked = true`, `CastShadow = false`.

**Pooling — this is where a naive version leaks.** Build `MAX_CHEVRONS` (8)
chevrons *once*, on first use, into a single `Folder` named `TutorialFx` in
`workspace`. Show and hide by moving them and setting `Transparency`; never
create or destroy per frame, per step or per respawn. One folder, created once,
and the parts inside it are the raycast ignore list.

**Layout, every Heartbeat:**

- Origin = the character's `HumanoidRootPart.Position`, pushed 5 studs toward
  the target so the trail never sits inside the player's feet.
- Direction = the flat (Y-zeroed) vector from origin to `target`.
- Spacing = 6 studs. If the target is nearer than `5 + 6 * 2`, show only the
  chevrons that fit; if `distance < 8`, hide the trail entirely and show the
  ring alone (2c) — a trail pointing at something you are standing on reads as
  a bug.
- If the target is farther than 90 studs, the trail is a fixed 8-chevron
  "runway" from the origin in the target's direction rather than a line that
  tries to span the museum.
- Each chevron is placed with a downward `Raycast` from `+20` studs, length 60,
  `FilterDescendantsInstances = { TutorialFx folder, every character model }`,
  `FilterType = Exclude`. This is what keeps them on the museum's ramps, the
  lobby steps and the plot slab instead of floating through them. If a ray
  misses, hide that one chevron rather than dropping it at Y=0.
- Orientation: `CFrame.lookAt(hit, hit + direction)` then rotated so the
  triangle lies flat and points along `direction`.

**Motion:** the whole chain scrolls toward the target at 9 studs/s — advance a
scalar phase on `os.clock()` and offset each chevron by
`(i * spacing + phase) % (spacing * count)`. The chevron that wraps past the far
end fades in over its first 0.8 studs and the one at the near end fades out over
its last 0.8, so nothing pops. Under `Effects.isReduced()` the scroll stops and
the chevrons sit static at full opacity; under `Effects.isLowGraphics()` drop
`MAX_CHEVRONS` to 5.

**Colour and the RUN beat:** read `player:GetAttribute("Chased")` — the same
server-owned flag `ChaseWarningController` uses. True → fill turns red
(`238, 52, 44`) over 0.25s; false → back to gold. This is the deliberate
adaptation of the reference's permanently-red chevrons: this game's lasers are
red, and a trail that is always red collides with the "red means danger" language
already established in the museum rooms. Gold is also the existing tutorial
`ACCENT` in this file. If the owner wants it red-always, it is one constant.

**When the trail must not exist** (hide within one frame, do not destroy the
pool):

- `state.tutorial` or `target` is nil
- `player:GetAttribute("FlyoverActive") == true` — the existing check; the
  first-join tour comes before the first objective
- no character, or `Humanoid.Health <= 0`
- the reveal camera is running — `HatchController` takes the camera for the
  roulette; a trail across a cinematic shot is the exact kind of bug this brief
  is trying to avoid. Find how `HatchController` announces that
  (`onRevealStarting` is how it tells `FlyoverController`) and use the same
  signal rather than inventing a second one.

## 2c. The target ring

Look at `docs/tutorial-reference/04-target-ring-closeup.png`. Shown only when
`state.tutorial.pointer` is non-nil, at `target`.

A `BillboardGui` (`AlwaysOnTop = false` — it must be occluded by the plot walls,
unlike the old arrow; `MaxDistance = 220`) adorned to one pooled invisible part
positioned at `target`:

- The ring: a `Frame`, `BackgroundTransparency = 1`, square, with
  `UICorner(CornerRadius = UDim.new(1, 0))` and a `UIStroke` of `Thickness = 4`,
  `Color = Color3.fromRGB(240, 70, 60)`, `Transparency = 0.1`. That is a true
  circle outline with no image. It pulses: scale 1.0 → 1.08 → 1.0 on a 1.4s
  sine, and the stroke transparency breathes 0.1 → 0.35 in step. Static under
  `Effects.isReduced()`.
- The verb: a `TextLabel` below the ring with `state.tutorial.pointer`, same
  white/FredokaOne/black-stroke treatment as the objective line, one size
  smaller.
- The hand icon inside the ring: the reference draws a cartoon pointing hand.
  **You cannot make that.** Add `PolishConfig.TUTORIAL_POINTER_ICON = "rbxassetid://0"`,
  render an `ImageLabel` only when that id is non-zero, and leave the ring empty
  otherwise (the ring plus the verb reads fine on its own). Write the Codex
  brief for the icon to `docs/codex-prompts/tutorial.md`: name, the exact key it
  must be written to, 512x512 transparent PNG, square, glossy cartoon with a
  thick dark outline to match the existing UI pack, a stylised hand with the
  index finger pointing up, warm yellow `#F2C94C` body.

Do **not** copy the reference's literal "CLICK HERE". Placing and revealing in
this game are `ProximityPrompt` holds (`ActionText` "Place" / "Reveal" — see
where those are set), and the prompt already shows the right key on every input
device. The ring says the *action*; the prompt says the *button*. Two sources of
truth for the keybind is how this gets wrong on gamepad.

---

# Part 3 — Correctness

The owner's word for what they want is "flawless". Treat each of these as a
requirement, and state in your notes how you satisfied each:

1. **One connection.** One `Heartbeat`, one `StateStore.subscribe`, one
   `CharacterAdded`. No `task.delay` chains. Nothing that can be connected twice
   if `start()` is somehow called twice — guard it.
2. **One pool.** Parts are created once and reused. Count them: 8 chevrons x 4
   wedges + 1 ring anchor = 33 parts, forever. Verify nothing in the file calls
   `Instance.new` inside the Heartbeat.
3. **Respawn.** Death, reset and `CharacterAdded` must leave no orphaned parts
   and must not need the pool rebuilt. `ResetOnSpawn = false` on the ScreenGui.
4. **Resume.** Rejoining at every step must land on the right line and the right
   target: mid-carry, dropped mid-lane, caught, sealed-on-pad, revealed, trained.
   The server derivation already handles most of this — your job is not to break
   it and to confirm the client renders `nil` states without erroring.
5. **No input capture**, desktop and touch.
6. **Reduced Effects and Low Graphics** both honoured, via `Effects.watchReduced`
   / `Effects.watchGraphics`.
7. **Nothing during the flyover or the reveal camera.**
8. **Type-clean.** `--!strict`, typed locals, `IsA` checks before every
   `BasePart` use. `tools/check.sh` hard errors empty; do not raise the
   TypeError count for the files you touch.

## Debug commands

Add `src/server/Services/DebugCommands/Tutorial.luau` following the existing
pattern in that folder, with commands to force each `step`, to reset the
tutorial to stage 1, and to jump straight to the sealed-on-pad state. Every
command that writes the profile must restore it on error — Studio writes to the
owner's real DataStore.

## Notes

Write `docs/handoff-parts/tutorial-onboarding.md`: what you built, the numbers
you chose and why, the `deriveStage` bug and the fix, the gold-vs-red decision,
what is placeholder (the hand icon), and a precise Studio test plan using your
debug commands that walks a fresh profile through all seven steps.

Then `git add -A && git commit`. Do not push.

## Out of scope

Do not touch `ChaseWarningController`, `ToastController`, `StarterTaskController`,
`FlyoverController`, the reveal roulette, the stage numbers, the intro-popup
logic, or any other agent's feature. If you find a second bug while reading,
write it in your notes — do not fix it here.
