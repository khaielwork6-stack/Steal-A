# Codex: replace all twelve ZONE guardians (Steal & Run!)

This job is 100% the zone guardians. Nothing else - not the base pets, not the
vault warden, not UI. Twelve new characters, one per zone, that actually belong
to their zone, built as real rigs that use the existing walk / idle / chase
code exactly as the current ones do.

**The current guardians are free toolbox avatars. The owner hates them. They
are NOT a reference for anything - not silhouette, not palette, not quality.**
The only thing to keep from them is the file layout and the gameplay hooks
listed in Part C.

## Read first
1. `git pull` on `master` (https://github.com/khaielwork6-stack/Steal-A.git).
2. Read `docs/START_HERE.md` and `docs/AGENT_RULES.md` (preserve each file's
   line endings, never `sed -i`; `bash tools/check.sh` and `selene src` must
   stay at zero hard errors / zero errors before every commit).
3. Place: **Steal & Run!** (placeId 134344354476234), owned by **group
   3774675**. Every mesh, texture, image and model must be uploaded so the
   GROUP owns it (Open Cloud with creator group 3774675, as the round 3 art
   pipeline did - see `tools/upload-round3-model.py`, `art/round3/upload/`),
   or the live game cannot load it.
4. How a guardian is built and driven - read these before designing anything:
   - `src/server/Services/GuardianService.luau`: `buildRigFrom`, `dressRig`,
     `shellSkeleton`, `prepareWalk`, `animateShell`. A costume ("shell") is
     cloned from `ServerStorage.GameAssets.Guardians.Zone<NN>_<Key>`, scaled
     to the zone's height, hung off an invisible physics root, and if it has a
     Humanoid + HumanoidRootPart with Motor6D joints it is marked `Rigged` and
     plays the stock walk / idle cycles from
     `GameConfig.GUARDIAN_WALK_ANIMATIONS` / `GUARDIAN_IDLE_ANIMATIONS` (R6 and
     R15 ids). Un-rigged shells get the procedural bob instead. **Every new
     guardian must be a rigged R15 Humanoid so it gets the real walk/run.**
   - `src/shared/Config/GameConfig.luau`: `GUARDIAN_HEIGHTS` (7 studs at zone
     1 up to 40 at zone 12 - the costume is scaled to this, do not change the
     table) and `GUARDIAN_PHYSICS_MAX_GROWTH`.
   - `src/shared/Config/ZoneConfig.luau` and `src/shared/MapConfig.luau`: the
     `guardian` key per zone. `src/shared/Config/AudioConfig.luau`
     `GuardianHits`: one hit sound per zone.
   - `src/client/Controllers/GuardianFxController.luau`: the client pose /
     lean / Zzz / "!" layer. It must keep working on the new rigs untouched.
5. Style target for every character: the game's look - chunky cartoon
   proportions (big head, big hands, short legs), bold saturated colours,
   thick dark outlines baked into the texture, glossy highlights, readable
   from 60 studs away and at a phone's size. Think a premium Roblox
   simulator boss, not a realistic figure and not a stock avatar. Each one
   needs ONE unmistakable silhouette prop and ONE signature colour so a
   player knows which zone they are in from the guardian alone.

---

## THE TWO PHASES - AND THE GATE BETWEEN THEM

**Phase A (concepts) ends with you STOPPING and waiting.** You do not touch
Studio, upload anything, build a model, or change a line of code until the
owner has written "APPROVED" against the concept sheet. The owner may reject,
change or swap any character; you redo those and present again. Only when the
whole set is approved does Phase B begin. If you are unsure whether something
is approved, it is not.

---

## Part A - Concept sheets (do this first, then STOP)

For each of the twelve guardians in Part D produce ONE concept image:

- **File:** `art/guardians/concepts/Zone<NN>_<Key>.png`, 1536x1024, on a flat
  neutral grey (#2A2D36) so the silhouette reads.
- **Layout:** left two-thirds a front three-quarter full-body view in a
  neutral stance; top-right a small back view; bottom-right a small CHASE
  pose (sprinting, arms pumping, the prop raised) - that is how players see
  it most. A thin height bar next to the front view labelled with the zone's
  stud height from `GUARDIAN_HEIGHTS` and a 5-stud player silhouette beside it
  for scale.
- **Caption strip** along the bottom: zone number and name, the guardian's
  name, its signature colour swatch, and its prop.
- Also produce `art/guardians/concepts/ALL.png`: a 4x3 contact sheet of the
  twelve front views at equal scale, in zone order, so the set can be judged
  as a set (they must escalate in menace and bulk from zone 1 to 12 and never
  two of them share a palette).

Then write `art/guardians/concepts/README.md` listing every file, and post
the contact sheet plus all twelve sheets in your report. **Stop there.**

Iterate on whatever the owner sends back until every character is approved.

---

## Part B - Build, upload, install, wire (only after "APPROVED")

### B1. Model spec (identical for all twelve)
- A Roblox **R15 Humanoid rig**: `HumanoidRootPart`, `Head`, `UpperTorso`,
  `LowerTorso`, `LeftUpperArm/LeftLowerArm/LeftHand`, right arm likewise,
  `LeftUpperLeg/LeftLowerLeg/LeftFoot`, right leg likewise, joined by
  Motor6Ds with the standard R15 names (`Root`, `Neck`, `Waist`,
  `LeftShoulder`, `LeftElbow`, `LeftWrist`, `LeftHip`, `LeftKnee`,
  `LeftAnkle`, and the right-hand equivalents). This is what lets
  `GameConfig.GUARDIAN_WALK_ANIMATIONS.R15` (the stock walk) and the R15 idle
  play on it through `prepareWalk` with no code change. Do NOT use a
  HumanoidDescription or any Roblox catalogue asset.
- The costume art is MeshParts (skinned or rigid) welded to those limbs - or
  the limbs themselves are the meshes. Any prop (baton, cutlass, jackhammer)
  is welded to the hand that holds it. Under 45 BaseParts, under 12k
  triangles total, textures 1024 max, one material per mesh.
- Every BasePart `CanCollide = false`, `Massless = true`, `Anchored = false`
  (dressRig re-asserts this, but author it right). No scripts inside the
  model. No ParticleEmitters, Beams or Lights except where a design in Part D
  says so, and those must be cheap (one emitter, rate <= 8).
- Authored standing on Y = 0 with the feet on the floor, facing **-Z**, about
  10 studs tall as authored (buildRigFrom rescales to the zone's height, so
  the authored size only has to be sane). Model `PrimaryPart =
  HumanoidRootPart`. Humanoid `HipHeight` set correctly for the legs so the
  stock walk does not float or sink.
- Name: `Zone<NN>_<Key>` with the keys from Part D, e.g. `Zone06_Mummy`.
- Set attribute `ArtSource = "zone-guardians-2026-09"` on the model.

### B2. Install
- Move every existing `ServerStorage.GameAssets.Guardians.Zone<NN>_*` model
  into a new folder `ServerStorage.GameAssets.GuardiansOld` (do not delete;
  the owner deletes after sign-off). Leave `VaultGuardian` where it is - the
  vault warden is out of scope.
- Put the twelve new models in `ServerStorage.GameAssets.Guardians`.
- Update the `guardian` key for every zone in BOTH
  `src/shared/Config/ZoneConfig.luau` and `src/shared/MapConfig.luau` to the
  new keys (they must match each other and the model names; `MapBuilder`
  writes the key to the zone's `GuardianId` attribute and `GuardianService`
  builds the model name from it). `grep -rn` for every old key
  (`Cop`, `PirateCaptain`, `RoyalGuard`, `Agent`, `ElfGuard`, `MummyGuardian`,
  `Bodybuilder`, `BankGuard`, `MadScientist`, `Grandma`, `Foreman`,
  `AirportSecurity`) across `src/` and `docs/` and update every reference,
  including comments, `AudioConfig.GuardianHits` labels, quest / reward text,
  and `src/shared/Config/validate.luau` if it checks the keys.
- `AudioConfig.GuardianHits`: keep the existing sound per zone unless a
  design in Part D names a better one; if you replace any, upload it
  group-owned and note it in the asset table.
- Do NOT change `GUARDIAN_HEIGHTS`, chase speeds, catch radius, wake rules,
  the safe line, patrols, smoke, or anything in `GuardianService` beyond what
  a rigged R15 already supports. If a new rig exposes a real bug in that
  code, fix the bug minimally and say so in the report.

### B3. Verify every zone (this is the acceptance test)
For each of the twelve zones, in Studio Play:
1. The guardian stands at its post at the right height (compare the sign's
   zone height; feet on the floor, not sunk, not floating), facing into the
   room, playing the idle.
2. Steal an item in that zone. Studio-only commands go through
   `ServerStorage.DebugInvoke` (see `src/server/Services/DebugCommands/
   README.md`): `gadgetSmokeTest` in `DebugCommands/Gadgets.luau` already
   scripts a steal, a chase and a re-chase in a chosen zone and is the model
   to copy for a per-zone `guardianChaseTest`; `GuardianService.inspect(zone,
   room)` reports a guardian's state and target, `GuardianService.resetAll()`
   puts every guardian home. Add whatever small command you need to drive
   all twelve, in the same style. The guardian wakes
   (the "!"), turns, runs the stock walk cycle at chase speed with the legs
   and arms moving, catches or stops at the red line, carries the loot back,
   and walks home to idle.
3. Nothing detaches, stretches or clips through the floor during the run or
   the ragdoll launch. The Zzz / "!" billboards sit over the head.
4. Take one screenshot per zone of the guardian mid-chase and one at rest.
Also run a Reduced Effects pass on one late zone (11 or 12) and confirm the
frame rate is not worse than with the old models.

### B4. Finish
- `bash tools/check.sh` (zero hard errors), `selene src` (zero errors), then
  commit and push to `master` with a message that lists the twelve keys.
- Report: the 24 screenshots; a table model -> asset ids (mesh, texture,
  model) -> zone key; the old-key -> new-key mapping; anything left undone.
- Remind the owner to **Save & Publish** the place (the models live in the
  place, not in `src/`).

---

## Part D - The twelve guardians

Heights are the visual height from `GameConfig.GUARDIAN_HEIGHTS`; they are
given so the design fits its size (a 40-stud character needs big simple
shapes, a 7-stud one can carry more detail). The **Key** is the exact model
suffix and config value.

### 1. Museum - Key `NightWatchman` (7 studs)
The tutorial guardian: harmless-looking, a little sleepy, easy to read. A
short, round, middle-aged night watchman in a navy uniform with a tan belt
loaded with a huge key ring, a peaked cap pulled low, and a big grey
moustache. Prop: an oversized yellow flashlight (the beam is a static cone
mesh, no Light). Signature colour: navy #1E3A6E with the yellow torch. Face:
half-asleep eyes at rest, wide-awake and furious in the chase pose. He waddles.

### 2. Pirate Island - Key `GhostCaptain` (7.8 studs)
A skeletal ghost pirate captain: tricorn hat with a torn feather, tattered
teal-and-gold coat, a bony jaw with a gold tooth, one glowing green eye
socket, a hook for the left hand. Prop: a rusted cutlass in the right hand.
Lower body fades into a translucent teal wisp (a single tapered mesh at 40%
transparency) but he still has R15 legs under it for the walk. Signature
colour: sea-teal #1FA3A0 with bone white. One cheap green ember emitter at
the eye, rate 4.

### 3. Castle - Key `IronKnight` (8.8 studs)
A full plate-armour knight, squat and wide, visor down with two red slits.
Purple-and-gold heraldry on a tabard, a crested helm plume. Prop: a
two-handed greataxe carried on the shoulder at rest and swung forward in the
chase. Signature colour: royal purple #6E3FB0 with steel. Heavy stomp gait
(it is the same stock walk; sell the weight in the proportions - big boots,
big pauldrons).

### 4. Area 51 - Key `GreyAgent` (10 studs)
The joke of the set: a classic grey alien wearing a black government suit
and tie, sunglasses, an earpiece, holding a clipboard in one hand. Big oval
head, spindly limbs made chunky by the suit. Prop: a "neuralyzer"-style
silver flash rod in the other hand (no light). Signature colour: matte black
suit with a neon-green #4CFF7A badge and tie clip. Deadpan at rest;
sprinting with the tie flying in the chase.

### 5. North Pole - Key `FrostYeti` (11.5 studs)
An abominable snowman: shaggy white-blue fur, a huge under-bite with two
tusks, tiny angry eyes under a heavy brow, icicles hanging from the arms and
chin. Wears a stolen red Santa hat, too small for its head. Prop: a frozen
candy-cane club the size of a lamppost. Signature colour: ice white with a
glacier blue #7FD3FF underside. Fur is sculpted into big simple clumps, not
strands.

### 6. Ancient Egypt - Key `Mummy` (14 studs)
A towering bandaged mummy, bandages loose and trailing at the wrists and
one leg, gaps showing dark leathery skin, two glowing amber eyes deep in the
wrappings. A cracked gold-and-lapis pharaoh's collar and a broken
headdress. Prop: an ankh-topped staff. Signature colour: linen #E8DCB8 with
gold #F2B233 and lapis #1F4FB0 accents. One small dust emitter at the feet,
rate 6, only while moving (attach it to a foot).

### 7. Gym - Key `IronTitan` (17 studs)
A cartoonishly over-muscled gym bro: tiny head, huge traps, arms bigger
than the torso, a shredded tank top reading nothing (no text), lifting belt,
headband, tiny legs. Prop: a giant barbell with plates, carried across the
shoulders at rest and in one hand like a bat in the chase. Signature colour:
lime #7CF23A tank on bronze skin. Face: permanent flex-scowl.

### 8. Bank - Key `VaultBot` (20.5 studs)
The first non-human: a heavy security robot built like a walking bank
vault. A cylindrical vault-door torso with a spinning-handle detail on the
chest, riveted steel limbs, a single red camera-lens eye in a slot, a police
light on the head (static red dome, no Light). Prop: a riot shield in the
left arm with a dollar-sign emblem. Signature colour: gunmetal #5B6470 with
gold #E0B341 rivets and the red eye. It must still be an R15 rig - the legs
are pistons with boots.

### 9. Secret Lab - Key `LabMutant` (24.5 studs)
A failed experiment: a hulking green mutant bursting out of a torn lab coat,
one arm grotesquely larger than the other, goggles pushed up on a bald
head, a bubbling glass canister of glowing green fluid strapped to its back.
Prop: a syringe the size of a spear. Signature colour: toxic green #52E85A
with the white coat. One slow bubble emitter inside the canister, rate 5.

### 10. Grandma's House - Key `Granny` (29 studs)
Sweet-looking and terrifying because of the size: a tiny old lady blown up
to giant scale. Grey bun, round glasses on a chain, a floral cardigan and
apron, fluffy pink slippers. Prop: a rolling pin in one hand and a tea
towel over the shoulder. Signature colour: lavender #B79BE0 cardigan with
pink #FF9EC7 slippers. Face: kindly smile at rest, "GET BACK HERE" in the
chase. A rolled-up ball of yarn welded to one foot is a nice touch.

### 11. Construction Site - Key `WreckingForeman` (34 studs)
A giant foreman: yellow hard hat, orange hi-vis vest over a checked shirt,
a huge belly, work gloves, steel-toe boots. Prop: a jackhammer held like a
rifle. Signature colour: safety orange #FF7A1A with hi-vis yellow #FFE01A
stripes. Big square jaw, cigar-less (keep it clean), an angry unibrow.

### 12. Airport - Key `SkyMarshal` (40 studs)
The endgame: frighteningly huge, simple shapes. A towering airport security
marshal in a black tactical uniform with hi-vis chevrons, a peaked cap with
a silver wing badge, mirrored aviators, an earpiece. Prop: a metal-detector
wand in one hand and a small quad-rotor drone (static, no motion) hovering
by welded rods over the other shoulder with a red lens. Signature colour:
black with aviation white and a red #FF3B3B lens/chevron accent. Every
detail must be big - at 40 studs, small details turn to noise.

---

## Rules of the job, restated
- Phase A first. STOP after the concept sheets. Wait for "APPROVED".
- Zone guardians only. Vault warden, base pets, UI: untouched.
- Rigged R15 with standard names, so the existing walk / idle / chase code
  runs them without changes. No HumanoidDescription, no catalogue assets.
- Group-owned uploads. Old models to `GuardiansOld`, not deleted.
- Both config files, every old-key reference, and the audio table updated.
- Twelve zones verified in Play with screenshots; gates at zero; push;
  remind the owner to Save & Publish.
