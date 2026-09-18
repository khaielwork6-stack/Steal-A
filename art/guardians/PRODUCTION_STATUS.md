# Zone guardians — installed 2026-09-18

All 12 approved designs were created with Roblox AI mesh generation, cleaned and
reduced in Blender, uploaded under group **3774675**, and installed in
`ServerStorage.GameAssets.Guardians`. Previous zone models are preserved in
`ServerStorage.GameAssets.GuardiansOld`; `VaultGuardian` is retained.

## Verified

- One skinned MeshPart per model; **3,742–3,746 triangles**, including props.
- Eleven deforming imported bones, AnimationController and Animator. Blender
  authoring rigs have 15 bones; the importer omits four unused hand/forearm bones.
  Arms and held props move rigidly about shoulder bones; legs use blended weights.
- Every imported vertex has normalized bone weights. No Parts, Unions, scripts,
  sounds or lights inside the model assets.
- Four SurfaceAppearance maps per model, each **1024×1024**, inspected in Studio.
  Meshes, maps, idle and walk clips individually verified as group-owned.
- Requested heights and chosen XYZ bounds within **0.002 studs** after import
  quantization. Floor Y=0, front -Z. Imported UV/position probes match the authored
  Blender source within **0.001 studs**.
- Walk and idle tracks loaded and advanced with Animator:StepAnimations in Edit.
  Four phases per clip checked on every model. Maximum sampled lowest-vertex
  floor deviation **0.018 studs** (Frost Yeti idle).
- Both guardian-key configurations match and were observed synced through Rojo.
  Audio IDs and gameplay tuning retained.
- `tools/check.sh`: zero hard errors. `selene --allow-warnings src`:
  **0 errors, 88 warnings, 0 parse errors**.

## Evidence and editable sources

- `production.json`: approved names, dimensions and requirements.
- `installed-assets.json`, `ASSETS.md`: model, mesh, map and animation IDs.
- `studio-production-audit.json`: complete pre-install audit; these same
  instances were moved into the final folder.
- `studio-playback-proof.json`, `studio-orientation-proof.json`,
  `studio-installation.json`: Edit-mode proof and installation.
- `models/<name>/<name>.blend`: editable rigged Blender source.
- `models/<name>/{ColorMap,NormalMap,RoughnessMap,MetalnessMap}.png`: final maps.
- `models/<name>/review-stride.png`: sampled walk render.
- `models/<name>/walk-validation.json`: 25 authored frames and grounding checks.
- `references/`: isolated approved characters used for mesh generation.
- Raw mesh exports, transfer chunks, portable Blender, GLB/FBX intermediates,
  source texture copies and Blender backups remain local and git-ignored.

## Integration and limitations

GuardianService opts into bone playback only for `SkinnedGuardian=true`.
`WalkAnimationId` and `IdleAnimationId` select group-owned clips. Existing
Humanoid and base-pet paths are retained. Shared idle: **112229916598460**.
Each body has a grounded walk. Iron Knight, Iron Titan and Wrecking Foreman
keep their carrying arm pose.

The final meshes interpret the approved illustrations within the requested
budgets; small lettering, facial detail and fabric ornament are simplified.
No sound/light/emitter extras were added.

The owner's Edit-only instruction was respected. Live chase/catch/return,
ragdoll, multiplayer replication and actual phone FPS/Reduced Effects remain
unverified. Direct Edit execution of GuardianService was blocked by the MCP
module capability boundary; that boundary was not bypassed.

**Save and Publish the real place in Studio.** GitHub/Rojo stores code; model
instances live in the place. Never publish a blank `rojo build` output.

## Published assets

| Guardian | Model | Mesh | Walk | Triangles |
|---|---:|---:|---:|---:|
| Zone01_NightWatchman | 117258647809929 | 128147656032099 | 77873181533906 | 3746 |
| Zone02_GhostCaptain | 106218046978146 | 110204265686441 | 129460518585346 | 3746 |
| Zone03_IronKnight | 95211809388527 | 138003853483666 | 133929564764513 | 3746 |
| Zone04_GreyAgent | 116073469252475 | 132320853559207 | 83393328520236 | 3744 |
| Zone05_FrostYeti | 136776006650388 | 121033984987910 | 124961619562758 | 3746 |
| Zone06_Mummy | 131950233845240 | 126953642288898 | 118265765349487 | 3744 |
| Zone07_IronTitan | 89644975750699 | 74219427770620 | 105113659859492 | 3744 |
| Zone08_VaultBot | 129725400419992 | 72095754787245 | 70898087955433 | 3742 |
| Zone09_LabMutant | 89743820400468 | 137725323385980 | 110642740743201 | 3744 |
| Zone10_Granny | 112261096982364 | 114078670090986 | 106380125174585 | 3746 |
| Zone11_WreckingForeman | 117578208048861 | 88965310161217 | 128537006584199 | 3744 |
| Zone12_SkyMarshal | 137258400817760 | 114532512055871 | 105207620813029 | 3742 |
