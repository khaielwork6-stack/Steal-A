# Tutorial film (replaces the objective-line tutorial)

Owner's ask: retire the old "unreliable" live tutorial UI and replace the
first-minute onboarding with a short (~40-60 s) in-engine cinematic that
shows the whole loop once, automatically, to brand-new players only.

## What plays, and when

`TutorialFilmController` (client) builds a small self-contained "stage" -
a folder of LOCAL, CLIENT-ONLY instances parented far from the real map
(`workspace._TutorialFilmStage`, `TutorialFilmConfig.STAGE_ORIGIN =
(0, 4000, 0)`) - and runs nine beats against it, matching the brief's script
exactly (`TutorialFilmConfig.BEATS`):

`spawn` -> `sneak` -> `guard` -> `laser` -> `grab` -> `run` -> `place` ->
`income` -> `train` -> an end card ("Now it's your turn!" + a PLAY button,
auto-closes after `END_CARD_SECONDS` = 5s, tap anywhere to continue).

It is entirely **self-contained**: it never reads or writes a real guardian,
laser, container, plot or the player's real profile beyond the one flag that
gates it. It is built from:

- a **clone of the player's own live character** (their real avatar,
  scripts stripped, anchored, driven only by CFrame tweens - see "THE HERO"
  below) for the hero, falling back to a simple stylised rig;
- a **clone of a live guardian** straight out of `workspace.Guardians`
  (built once at server boot by GuardianService - a plain replicated
  instance, not server-only) for the guard, falling back to a simple block;
- a **clone of a live laser beam** out of `workspace.Map.Zones.*.Lasers`
  for the laser, falling back to a plain red Neon bar;
- the real, shared **`TreadmillModel.build(1)`** (the exact same art the
  Upgrades panel already shows client-side) for the treadmill;
- **simple parts** for the floor, the pedestal, the base pad and the sealed
  chest (MysteryModel's real container art lives in `ServerStorage`, which
  never replicates to a client - see `docs/codex-prompts/tutorial-film.md`
  for the one real placeholder this pass leaves behind).

Camera: the same Scriptable-camera ownership pattern as `FlyoverController`
/ `HatchController`'s reveal camera - one CFrameValue driven every
RenderStepped frame, tweened cuts, save-once/restore-once. It explicitly
waits for the first-join flyover (`FlyoverController.isPlaying()` and the
`firstSession` field it watches) so the two cinematics can never fight over
the camera.

Plays automatically once the profile has loaded, the character exists and is
at its own base, and (see above) the flyover is not owed or already playing;
also playable any time from **Settings -> "Watch tutorial again"**
(a plain button, styled like the other toggle rows - see
`SettingsController.bindAction`), which replays it without touching any
profile flag.

## Server safety while it plays

`TutorialFilmService` marks the player `player:SetAttribute("InTutorialFilm",
true)` and **anchors their HumanoidRootPart** for the film's length, with a
**90 s hard cap** (`TutorialFilmConfig.HARD_CAP_SECONDS`) that clears the mark
on its own even if the client never reports back. It clears on every exit
path: the client's own "done" report (finish or skip), `PlayerRemoving`, and
a thrown handler (wrapped in pcall, `endSession(player, "error")`).

**Why no extra guardian/PvP check was needed in the general case:** the film
only ever plays while the character is standing at its own base, and
`BaseService.isSafePosition` already refuses PvP and keeps every guardian out
of ANY safe zone including a plot (see that function's own comment - "PvP is
disabled here so nobody can be spawn-griefed at their own base"). Client-side
controls are frozen for the film's duration (same technique as
`FlyoverController`), so the player cannot walk off their own base while
anchored. **Belt and braces added anyway:** one line in
`PvPService.resolveSwing`'s victim loop refuses to land a hit on anyone
`TutorialFilmService.isInCinematic` is true for. GuardianService was left
untouched - a guardian catch requires `LootService`'s carrier state, which is
never set for a player standing at their own base doing nothing, so there was
no real vector there to guard against.

**Known limitation, accepted rather than engineered around:** if the server
itself repositions the character mid-film via a raw CFrame set (not a new
character - e.g. a Night cycle "send everyone home" pass, which is on a
multi-minute timer and vanishingly unlikely to land inside the ~60 s film),
the saved pre-film camera CFrame restored on stop() would be stale for one
frame before Roblox's own camera scripts reacquire the character. A full
respawn (a new Character) is handled correctly - the film aborts instantly
(`player.CharacterAdded`) rather than fighting it.

## Who sees it

One new profile field, `Profile.TutorialFilmDone` (boolean, default `false`
in `defaultProfile()`). **Every existing save is treated as done**, not just
ones that finished the old tutorial: `DataService.reconcile`'s early
"BEFORE the defaults are copied in" block (the same one that back-fills
`FlyoverSeen` / `AnalyticsOnboarding`) sets it to `true` whenever a loaded
save simply doesn't have the field yet - which is every profile that existed
before this pass, whatever stage they were at. Only a profile built fresh
from `defaultProfile()` (a genuinely new player) starts `false`. No schema
version bump (per AGENT_RULES rule 5).

Completing or skipping the film (a real "start" session, not a "replay")
sets `TutorialFilmDone = true` **and** advances `Profile.TutorialStage` to
`TutorialService.STAGE.COMPLETE` if it was not there already, so nothing
that still reads that number - `FlyoverService` (flyover eligibility),
`DailyRewardController` (the popup's auto-open gate) - is left waiting on a
stage machine the film has now superseded.

## Retired vs kept

**Deleted:** `src/client/Controllers/TutorialController.luau` (857 lines -
the objective line, the chevron trail, the target ring) and its
`init.client.luau` wiring. `PolishConfig.TUTORIAL_POINTER_ICON` and its
`validate.luau` check (the hand icon that ring used) - nothing reads it any
more. `TutorialService.resetIntro` and the `introReset` debug command (the
old first-start popup this service used to drive) - the film is now the
first thing a new player sees, so there is nothing left to "show again."
`DebugCommands/Tutorial.luau`'s `tutorialStep` / `tutorialSteps` commands
(they tested the retired presentation only).

**Kept, deliberately - this was real gameplay, not UI:**
`TutorialService`'s stage DERIVATION (`deriveStage`, `Profile.TutorialStage`)
and the guaranteed-first-item mechanic (`isTutorialLoot` / `mayTakeLoot`,
the pinned Pharaoh Mask in Zone 1). Both are still depended on:
`FlyoverService.isFirstSession`, `DailyRewardController`'s auto-open gate,
`DataService.reconcile`'s legacy-save detection, and `AnalyticsSession`'s
`QuitInTutorial` bucket (which now reads a small analytics-only `step` label
computed the same way the old presentation picked one, just with no title,
pointer, target or trail attached to it - see `TutorialService.stepFor`).
`StarterTaskService` / `StarterTaskController` (the phone's starter-task
card) were left exactly as they were: `StarterTaskConfig.SHOW_HUD = false`
already made the card dormant in a prior pass, and the service still pays
real cash/Speed rewards for real actions (steal, reveal, train) - unrelated
to the tutorial UI this pass retires.

## Analytics

Three new low-cardinality custom events (`AnalyticsEvents.CUSTOM_EVENTS`):
`FilmStarted`, `FilmSkipped`, `FilmFinished`, fired by `TutorialFilmService`
from the server-confirmed completion path (never trusted from the client
alone beyond "which action did you ask for"). The Onboarding funnel
(Joined / First Steal / First Escape / First Delivery,
`AnalyticsEvents.ONBOARDING`) was NOT touched - it already fires from real
player actions (`AnalyticsEvents.onboarding`, called from
`CarryService`/init's steal/escape/deliver handlers), independent of
either tutorial system, exactly as the brief asked.

## Placeholders (see docs/codex-prompts/tutorial-film.md)

The sealed chest is three plain Parts (a box, a lid, a metal band) rather
than real container art, because `MysteryModel`'s templates live in
`ServerStorage` and are never replicated to a client - confirmed by reading
`MysteryModel.folder()`'s own `serviceByName` guard. The hero and guard
placeholder rigs (simple blocks) are fallbacks only - the paths almost every
player actually sees clone the player's own live character and a real
`workspace.Guardians` model respectively, needing no new art at all.

## Debug commands (Studio only)

`src/server/Services/DebugCommands/TutorialFilm.luau`:

| command | what it does |
| --- | --- |
| `filmState` | `due`, `inCinematic`, `filmDone`, `tutorialStage` |
| `filmForceStart` | flips `TutorialFilmDone` back to false and pushes a full state - Play as that character in Studio and the film starts on its own within a few seconds, exactly like a real new player |
| `filmSimulateSkip` | runs the server-side "skipped" completion path directly, no client needed |
| `filmSimulateFinish` | runs the server-side "finished" completion path directly |
| `filmReplay` | runs the server-side "replay" path (marks in-cinematic, touches no flag) |
| `filmRestore` | puts the profile snapshot back (and saves) |

`filmForceStart` / `filmSimulateSkip` / `filmSimulateFinish` snapshot
`TutorialFilmDone` and `TutorialStage` first (same pattern as every other
`DebugCommands` module) and a throwing command restores on the spot;
`filmRestore` undoes the whole sequence when the test is over.

**Client-side trigger (no new debug pattern needed):** the Settings ->
"Watch tutorial again" button IS the manual client-side trigger - it calls
`TutorialFilmController.replay()` directly and needs no profile state, so it
doubles as the easiest way to watch the film repeatedly in Play mode without
touching the DataStore at all.

## Studio test plan

1. `filmState` on a fresh Studio account (or after `resetTutorial` +
   `filmForceStart` on an existing one) - expect `due = true`,
   `filmDone = false`.
2. Play as that character: spawn at your own base, wait a few seconds
   (loading screen + the flyover, if any, finishing first) - the film should
   fade in from black within `TutorialFilmConfig.LOADING_WAIT` (90 s) of the
   character existing. Watch all nine beats and the end card; confirm the
   captions match `TutorialFilmConfig.BEATS` in order and every beat's prop
   (guard, laser, chest, treadmill) is visible and moves as described.
3. Skip: press Skip mid-film (top-right, always visible, >= 44 px) - the
   film should end INSTANTLY (no fade), camera and controls return
   immediately, and `filmState` afterwards shows `filmDone = true`,
   `tutorialStage` at `TutorialService.STAGE.COMPLETE` (9).
4. Let it play to the end card without touching anything - it should
   auto-continue after 5 s; tapping the card or the PLAY button should also
   continue it immediately.
5. `filmForceStart` again, then open Settings and press "Watch tutorial
   again" WHILE the auto-play would otherwise fire - confirm only one film
   ever plays at a time (the second request is a no-op while one is
   running: `play()` checks `running`).
6. `filmReplay` then `filmState` mid-"replay": confirm `inCinematic = true`
   and, after ending it (there is no client to report "done" here, so use
   the hard cap or manually clear via a rejoin), that `TutorialFilmDone` and
   `TutorialStage` were NOT touched by a replay - only `filmSimulateFinish`/
   `filmSimulateSkip` (a real "start" session) touch them.
7. Kill the character mid-film (Studio's own kill / fall damage is blocked
   by the safe zone, so use the `kill` debug command if one exists, or a
   manual `Humanoid:TakeDamage` override) - the film should abort instantly
   via `player.CharacterAdded` on respawn, with the camera and controls back
   to normal on the new character.
8. Settings -> Reduced Effects / Low Graphics: replay the film - confirm
   the chest's sparkle and the floating cash numbers are skipped, captions
   cross-fade instead of sliding (Reduced), and nothing that carries the
   story (camera cuts, the jump, the captions themselves) is ever skipped.
9. Existing account (`SchemaVersion` from before this pass, or any save
   with `TutorialStage > 0`/`TutorialIntroSeen = true` predating the field):
   confirm `filmState` reports `filmDone = true` and `due = false` on load,
   without ever having called `filmForceStart` - the reconcile back-fill
   should have done this on its own.
10. `bash tools/check.sh` - hard errors section empty; `selene src` - 0
    errors.

## What the lead should verify

- The pacing/camera framing of the nine beats (I could not run this in
  Studio - see AGENT_RULES rule 1). The stage geometry is in
  `TutorialFilmController`'s constants (`HOME_SPAWN`, `LOBBY_POINT`,
  `GUARD_POST`, `LASER_POINT`, `PEDESTAL_POINT`, `HOME_PAD`,
  `HOME_TREADMILL`) - all easy to retune without touching the beat logic.
- Whether the chest placeholder (three plain Parts) reads clearly enough at
  the film's camera distances, or whether the Codex asset in
  `docs/codex-prompts/tutorial-film.md` should be prioritised.
- That a live guardian actually exists in `workspace.Guardians` by the time
  a new player's film would play (it should - GuardianService builds them
  at server boot, well before any player joins) - if it does not for some
  reason, `buildGuard()` silently falls back to the placeholder block
  rather than erroring, so this is a look-and-feel check, not a
  reliability one.
