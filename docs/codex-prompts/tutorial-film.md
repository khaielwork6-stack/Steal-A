# Codex prompt: tutorial film assets (tutorial-film)

The old objective-line tutorial (TutorialController) was retired in favour of
a short in-engine film that plays once for a new player
(TutorialFilmController). It builds its own small, self-contained "stage" out
of clones of REAL replicated art wherever that exists (a live workspace
guardian, a live laser beam, the shared TreadmillModel), and simple parts
everywhere else. This is the list of everywhere else - the placeholders that
would look much better as real 3D art. Nothing here blocks the film from
working today; it plays correctly with the placeholders described below.

None of this is UI (no ImageLabel/Decal work) - it is **3D art**: models to
upload as a Roblox Model asset (or MeshPart with a rig), inserted into the
Rojo tree (or place file) at the path given, and referenced by an
`rbxassetid://` in the config key given. Match the game's existing style:
stylised realism for props (see the museum loot in `ServerStorage.GameAssets`
in a Studio session), cartoon-glossy for anything UI-adjacent - none of these
are UI-adjacent, they are all world props seen only from a cinematic camera.

## 1. The sealed chest / mystery container

- **Where it's used:** `TutorialFilmController.buildChest()` (client), the
  "Grab a chest" and "Place it in your base" beats.
- **Why it's a placeholder:** the REAL sealed-container art
  (`MysteryModel.build`) lives in `ServerStorage`, which a LocalScript can
  never see (server-only storage never replicates) - see MysteryModel's own
  header comment. The film cannot borrow it without exposing server-only art
  to every client, which is out of scope for this pass.
- **Current placeholder:** three plain Parts (a base box, a lid, a metal
  band) in wood-brown and gold, built entirely in code
  (`TutorialFilmController.buildChest`).
- **What to make instead:** a single stylised wooden treasure-chest Model
  (or MeshPart), sealed shut (no visible hinge gap), roughly 2.2 x 1.4 x 1.6
  studs, in the same "stylised realism" register as the real museum loot -
  dark wood, one gold metal band, a small glowing rune or padlock on the
  front reading "sealed", NOT a specific real item's shape (it must never
  hint at what is inside, exactly like the real MysteryModel dressing rule).
  No scripts, no Humanoid, no seats.
- **Deliver:** upload as a Model asset. Write its asset id into a new
  `TutorialFilmConfig.CHEST_ASSET_ID = "rbxassetid://0"` field (add the field
  - it does not exist yet) and change
  `TutorialFilmController.buildChest` to try
  `game:GetService("InsertService"):LoadAsset(id)` (wrapped in the existing
  pcall pattern) before falling back to the current part-built stand-in.

## 2. The hero placeholder rig (only seen when the clone path fails)

- **Where it's used:** `TutorialFilmController.buildHero()`'s fallback
  branch - normally the film clones the PLAYER'S OWN live character, which
  needs no art at all and is what almost every player will actually see.
  This placeholder only shows if that clone fails (no Humanoid on the
  character yet, an unusual load-order case).
- **Current placeholder:** a gold cylinder body with a ball head, no rig, no
  animation - moved only by CFrame.
- **What to make instead:** a simple stylised R15-rigged mascot (a "generic
  thief" silhouette in the brand's gold/navy palette) with a default Roblox
  Animate script, so `TutorialFilmController` can play its own run
  animation via the same `findAnimationId` path a live character clone uses.
  Low priority - most players never see this branch.

## 3. The guard placeholder rig (only seen when no guardian exists yet)

- **Where it's used:** `TutorialFilmController.buildGuard()`'s fallback
  branch - normally the film clones a REAL guardian straight out of
  `workspace.Guardians` (built once at server boot; see GuardianService),
  which needs no new art. This placeholder only shows if that folder is
  empty (a server that has not finished its boot pass).
- **Current placeholder:** a single dark grey block, no rig.
- **What to make instead:** nothing required - if you want to improve it
  anyway, a simple stylised security-guard silhouette matching one of the
  real zone guardian costumes (`ServerStorage.GameAssets.Guardians`) would
  do, but this is the lowest-priority item on this list since the real
  clone path is what almost every player sees.

## Everything else already uses real art or simple geometry that reads fine

- **Laser beam:** cloned from a real `workspace.Map.Zones.*.Lasers` part -
  falls back to a plain red Neon bar (matches the real beam's colour,
  `Color3.fromRGB(255, 35, 49)`) if none exists yet. No art needed.
- **Treadmill:** built with the real, shared `TreadmillModel.build(1)` -
  exact same art the Upgrades panel shows. No art needed.
- **Pedestal, floor, base pad:** plain coloured Parts (marble pedestal,
  grey museum floor, green base floor, blue display pad). These are
  deliberately simple ("simple clean parts where not [replicated]" per the
  brief) and not worth bespoke art for a five-second cinematic shot; skip
  unless the owner specifically asks for more polish here.
