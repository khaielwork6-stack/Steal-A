# Tutorial onboarding (objective line, chevron trail, target ring)

Built from `docs/prompts/tutorial-onboarding.md` against the seven stills in
`docs/tutorial-reference/`. Unlike the brief's agent, this pass HAD Studio:
everything below marked "verified" was measured or seen in a Play session.

## What was built

**Server - `src/server/Services/TutorialService.luau`**

- `TutorialState` gained `step`, `title`, `pointer`. `stage` is unchanged and
  still the only persisted, monotonic number. `step` is what the client
  renders and is deliberately decoupled from the number.
- The copy table (`COPY`) is server-owned and verbatim from the brief. The
  reveal step reads "It's opening…" with no pointer while the container is
  still incubating, and "Open it!" / `OPEN IT` once it is ready.
- `present(player, step, stage)` builds one step's presentation; `buildState`
  picks the step for a stage. `PLACE` is the one stage with two faces:
  `place` while still carrying, `reveal` once the container is sealed on a
  pad. The reveal targets THAT pad (`DisplaySlot<NN>` from the item's
  `SlotIndex`), not the first free one.
- A push now also goes out when `step`, `title` or `pointer` change with the
  stage number unchanged (PLACE -> reveal, and incubating -> ready). Without
  this the client never saw the reveal beat.
- Readiness is read straight off the profile (`Hatched == false` and
  `HatchEndsAt <= os.time()`), so TutorialService adds no require edge to
  HatchService and keeps its place in the boot order.
- Debug hooks: `debugForceStep(player, step?)` / `debugSteps()`. Forcing a
  step swaps the presentation only; derivation and the profile are untouched.

**Client - `src/client/Controllers/TutorialController.luau`** (the old `▼`
billboard is gone)

- ONE objective line in its own ScreenGui (`TutorialObjective`,
  `ResetOnSpawn = false`, `IgnoreGuiInset = true`, `DisplayOrder = -1` - the
  pack's MainUI, which holds the toast stack, is at 0, so a toast is never
  under it). Two TextLabels swap with the brief's tweens (0.14 s out, up 12
  px; 0.20 s Back-out in from 14 px below); a change mid-transition cancels
  and replaces; `title == nil` fades over 0.2 s and leaves the GUI empty.
  Reduced Effects: straight cross-fade.
- The chevron trail: 8 chevrons x 4 WedgeParts (fill pair + 1.18x outline
  pair 0.02 studs lower) in one `workspace.TutorialFx` folder, built ONCE
  and reused. 4.5 x 5 x 0.3 studs, floating 0.35 above a downward raycast
  from +20 (length 60). Origin 5 studs off the feet toward the target,
  spacing 6, hidden under 8 studs, a fixed 8-chevron runway beyond 90.
  Scrolls at 9 studs/s on an `os.clock()` phase; fades over its first and
  last 0.8 studs. Low Graphics uses 5 chevrons; Reduced Effects stops the
  scroll and the fades.
- The ring: a rounded square Frame with only a 4 px `UIStroke`
  (`240, 70, 60`), on a BillboardGui (`AlwaysOnTop = false`, `MaxDistance =
  220`) hung from one pooled invisible part. Pulses 1.0 -> 1.08 on a 1.4 s
  sine, stroke 0.1 -> 0.35 in step; static under Reduced Effects. The verb
  under it is the pointer text in the objective line's treatment, one size
  down.
- Every Frame/TextLabel: `Active = false`, `Interactable = false`; nothing
  is a GuiButton.

**Config / validate / debug / docs**

- `PolishConfig.TUTORIAL_POINTER_ICON = "rbxassetid://0"` (the hand; see
  placeholders). One `validate` check pins it to an asset id.
- `src/server/Services/DebugCommands/Tutorial.luau` - see the test plan.
- `docs/codex-prompts/tutorial.md` - the hand icon brief.

## The `deriveStage` bug, and the fix

Confirmed against the code before changing anything: `Profile.Index[itemId]`
is written in `HatchService.commit` ("DISCOVERY HAPPENS HERE"), at the
reveal, not at placement. So after placing the sealed container the
derivation found no carry (not PLACE) and no discovery (not INCOME) and fell
through to `STAGE.STEAL` - a brand-new player who had just done the hardest
part of the loop was told to go back and steal another one, until they
happened to find the Reveal prompt. `deriveStage` now checks
`profile.DisplayItems` for a tutorial item (current or legacy id) with
`Hatched ~= true` before that fallback and returns `STAGE.PLACE`; the carry
check stays ahead of it, the STEAL fallback stays after it, so a caught or
dead thief still drops back exactly as before. No stage number was added,
renumbered or reused.

## Decisions and numbers

- **Gold, not red.** The reference keeps its chevrons red always. This
  game's lasers are red and "red means danger" is already established in
  the rooms, and gold (`255, 204, 56`) is the tutorial's existing accent.
  The trail turns red (`238, 52, 44`) over 0.25 s only while the server's
  `Chased` attribute is true - the same flag ChaseWarningController reads -
  and back to gold when it clears. One constant (`FILL_CALM`) makes it
  red-always if the owner prefers the reference.
- **The trail raycast respects CanCollide.** Not in the brief. Measured on
  the rendered trail: without it, a chevron perched on a treadmill rail
  twelve studs up, because the treadmill art is walk-through but queryable.
  Only what a player can stand on now catches a chevron.
- **Chevron orientation** was checked on the rendered trail, not assumed: a
  WedgePart's apex is on its own -Z, the same side `CFrame.lookAt` puts the
  look direction, so the look frame IS the chevron frame. The first build
  had an extra half-turn and the trail pointed at the player.
- `GuiService.SafeZoneOffsetsChanged` is RobloxScript-only and throws for a
  LocalScript (it took `start()` down before the subscribe, which is why
  nothing rendered on the first run). The line re-places itself on
  `GetPropertyChangedSignal("SafeZoneOffsets")` and on `ViewportSize`
  instead.
- `LINE_DISPLAY_ORDER = -1`: measured, StarterGui.MainUI is DisplayOrder 0
  and its Notifications frame is a centred stack.

## Part 3 - correctness, as satisfied

1. **One connection.** One `Heartbeat`, one `StateStore.subscribe`, one
   `CharacterAdded`; `start()` is guarded by a `started` flag. No
   `task.delay` chains - the scroll and the pulse are phases on `os.clock()`.
2. **One pool.** Verified in Play: `TutorialFx` holds exactly 97 BaseParts
   (24 x 4 wedges + the ring anchor; 12 chevrons are used under Low
   Graphics). The Heartbeat path calls no `Instance.new`; the raycast
   params object is reused and only its filter table is rewritten.

   **The route (revised the same day).** The trail is laid along a
   PathfindingService route, not a straight line, so it turns where the
   doorways are. The route is a fixed polyline in the world: where the
   player stands on it is a projection, so the visible window (up to 24
   chevrons, 140 studs) slides smoothly as they walk. It is recomputed only
   when missing, for a new target, older than 8 s, or with the player more
   than 9 studs off it - at most once per 0.6 s, in its own thread. Because
   the objective is usually a point the navmesh cannot reach (a socket in a
   case, a pad on a pedestal), the route is tried to the target, then the
   floor under it, then the floor 4/8/12 studs short of it, and the last
   stretch to the true target is added straight. The straight line is only
   the fallback while no route exists.
3. **Respawn.** Verified: killed the character with the train step showing;
   seven seconds later one folder, 33 parts, the trail back (3 chevrons)
   and the ring on, the line still reading "Train your Speed!".
4. **Resume.** The server derivation is unchanged except for the sealed
   case; verified `tutorialReset` derives to 1 / `steal` with the socket
   target (`-67, 5.1, 16.5`) and `tutorialRestore` back to 9 / nil. The
   client renders a nil tutorial (COMPLETE) as an empty line and a hidden
   pool without error.
5. **No input capture.** Every element `Active = false`,
   `Interactable = false` (read back in Play); nothing is a GuiButton.
6. **Reduced / Low Graphics** via `Effects.watchReduced` / `watchGraphics`:
   no scroll, no fades, no slide, no pulse under Reduced; 5 chevrons under
   Low.
7. **Flyover / reveal camera:** `FlyoverActive` attribute and
   `HatchController.cameraBusy()` both hide the trail and ring within a
   frame.
8. **Type-clean.** `--!strict`; `tools/check.sh` hard errors empty; zero
   TypeErrors in TutorialService, TutorialController and
   DebugCommands/Tutorial (the baseline for those files was zero);
   `selene src` 0 errors.

## Placeholder

The pointing hand inside the ring. `PolishConfig.TUTORIAL_POINTER_ICON` is
`rbxassetid://0`; the ring shows its verb alone until Codex writes the id
(`docs/codex-prompts/tutorial.md`). The ring plus "OPEN IT" reads fine
without it.

## A second bug seen while reading (not fixed here)

`IndexService.luau` carries a comment saying PlacementService writes
`Profile.Index` at placement. It does not; HatchService.commit does, at the
reveal. The comment is stale.

## Studio test plan (debug bridge)

All commands take the caller. `tutorialStep` never writes the profile;
`tutorialReset` and `tutorialSealed` snapshot first and `tutorialRestore`
puts it back (a throwing command restores on the spot).

1. `tutorialState` - note `derivedStage`, `savedStage`, `targetText`.
2. Each step's presentation, one at a time: `tutorialStep steal`, `escape`,
   `place`, `reveal`, `income`, `train`, `nextZone`. Expect the line to swap
   in place with the copy in the table below, the trail to run from your
   feet toward `targetText` (hidden within 8 studs; runway beyond 90), and
   the ring with its verb on `place`, `reveal` and `train` only. `income`
   shows the line alone. Then `tutorialStep clear`.
3. Get chased while a trail is up (carry loot past a guard): the trail turns
   red within a quarter second and back to gold when the chase ends. No
   second RUN element appears - ChaseWarningController's is the only one.
4. Fresh profile, end to end: `tutorialReset`, then play it: the socket
   trail (`steal`), the run home (`escape`), the pad ring (`place`, "PLACE
   IT HERE"), then WITHOUT doing anything the line must read "It's
   opening…" for ~5 s and then "Open it!" with the "OPEN IT" ring on that
   pad - this is the window that used to say "steal one". Reveal it, watch
   "It's earning you cash!" hold 5 s, "Train your Speed!" with "STEP ON" on
   the treadmill, then "Zone 2 is open — go deeper!" for 9 s, then nothing.
   `tutorialRestore` when done.
5. The sealed state on its own: with a tutorial item on the base,
   `tutorialSealed` re-seals it for 5 s; expect `reveal` immediately.
6. Respawn mid-step (reset the character): the trail returns on the new
   character; `workspace.TutorialFx` still has 33 parts.
7. Trigger a reveal and the first-join flyover: the trail and ring are gone
   for the duration of each and back afterwards.
8. Settings -> Reduced Effects: the trail stops scrolling, the ring stops
   pulsing, the line cross-fades. Low Graphics: 5 chevrons.
9. Touch (Device emulator): the line sits at inset + 58, 34 px tall; nothing
   under the thumbstick responds to it.

| step | title | pointer |
| --- | --- | --- |
| steal | Steal your first treasure! | — |
| escape | Run it home! | — |
| place | Put it on a pedestal! | PLACE IT HERE |
| reveal | Open it! (It's opening… while incubating) | OPEN IT |
| income | It's earning you cash! | — |
| train | Train your Speed! | STEP ON |
| nextZone | Zone 2 is open — go deeper! | — |
