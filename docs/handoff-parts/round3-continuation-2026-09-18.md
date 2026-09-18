# Round 3 continuation — September 18, 2026

Status: IN PROGRESS. This is not final acceptance.

The owner authorized ROUND3_MASTER, assistant-managed group uploads, Studio art
installation, and commit/push to master. The earlier manual-upload choice was
superseded. No mouse/keyboard/window control. Existing pets are still unchanged.

## Verified

- Starting master checkpoint 01d0931; pull was current. No commit yet.
- Correct Studio: Steal & Run!, place 134344354476234, group 3774675.
- Owner enabled Mesh / Image APIs and restarted Studio. Reconnected and verified
  Rojo delivered current code and image IDs.
- 87 original images uploaded, verified as group-owned through MarketplaceService,
  preloaded successfully on the client and ImageLabel.IsLoaded checked. All wired.
- Records: art/round3/upload/uploaded-assets.json; mappings: asset-specs.json.
  Proof 05 supersedes proof 04, whose client check was interrupted by the restart.
- Fusion core model 128746381614439, mesh 119080625621647 and texture 74397465322379
  all belong to group 3774675. Model loads through InsertService. It is a draft
  core, not the final installed FusionMachine.
- Static: zero hard errors. Studio validate: 2,705 passes, zero failures.
- EconomyTests: 203,452 passes; MuseumTests: 2,074 passes; zero failures.
- Fresh Play reused 96 saved loot models, validated 12 containers, 96 sockets
  and 24 rooms. Zero missing/stale loot art. Gadget stand fallback passed.
- Storage tested with 0/1/10/90 client-only fixture cards, restored afterward.
- Portrait Storage/Guardians/Fuse, Settings, Quests, Trade, Crew and Daily checked.
- Landscape Daily now uses seven tiles in one row; portrait uses four plus three.
  NightTimer stays hidden while a modal is open. Final Daily captures saved.
- Base portrait preview checked with live art; fixture cleared.
- Overlapping modal claims suppress hotbar/touch/crouch/shift-lock screens and
  restore their remembered state only after the final claim closes.

## Work in progress

- All 115 image sources including 23 badges generated. Five regular images still
  need final review/export/upload: rays, announcement frame, smoke, spark, logo.
- Generator rays/sparks have noisy alpha and were rejected. Exact-size processing
  requires an outstanding owner reply to the Python/Pillow permission question.
  Do not mark high-resolution originals as exact-size exports.
- Segmented Cat, Dog, Panda and Tiger drafts generated in Edit. First Panda
  biped rejected; quadruped revision accepted visually. Pet exports in progress.
- Three gadget models and a dressed market stall generating in Edit.
- 20 animation sources authored, not published or final-rig tested yet.
- Server Animator support and procedural fallback implemented; runtime rig/chase
  verification remains.

## Remaining acceptance work

- Finish exact-size images and five live badge PNG replacements. Other 18 badges
  remain art-only; do not create badge IDs.
- Complete group-owned 3D props, vault art, theme decor, pet rigs and animations.
- Preserve old pets under ServerStorage.GameAssets.BaseGuardiansOld.
- Finish remaining UI, Reduced Effects / Low Graphics and screenshot checks.
- Final static/selene/Studio gates, provenance and asset table, commit/push master.
- Stop Play/device simulation and remove review/export fixtures from the place.
- Remind owner to Save & Publish after installing place-owned art.

## Export notes

GenerationService creates local DataModel content. A UUID could not recover the
lost Play draft after restart, so drafts now live in Edit under
ServerStorage.Round3GenerationDrafts. EditableMesh/Image extraction now works.

MCP execution cannot use HttpService.PostAsync (Network capability). The unused
local receiver was stopped and removed. Exports use bounded tool-output chunks,
lossless Zstandard, local decoding, and GLB packaging. Texture pixels are unchanged.

Upload tools use Open Cloud with explicit group creator 3774675. Keys are
Windows-encrypted outside Git; never print or commit them. GLB MIME must be
model/gltf-binary (Windows mimetypes does not know the extension).

Studio Play writes the REAL profile. Tests use pure fixtures or client UI previews;
no grants, purchases, sales or equipment changes were used.


## Landscape mobile pass completed

User requested efficiency after an extensive UI audit. The current focused pass is finished; avoid restarting broad checks. Nine main panels plus BASE, Season Pass, three alternate Storage tabs and TradeWindow passed size/bounds/GUI hit-query checks on a 567x319 viewport. Larger phone presets were also checked during the pass. Proof: art/round3/review/mobile-landscape-proof.json; screenshots mobile-landscape-hud and mobile-landscape-base. Studio returned to Edit; simulator reset; landscape sensor stored in default.project.json and StarterGui. Main menu buttons are now active, bound and 47.52px on the smallest tested viewport. Static gate: zero hard errors; focused selene: zero errors. No physical phone taps, purchases or real multiplayer trade/crew actions tested. Changes have NOT been committed/pushed/published.

Fixes: removed conflicting Upgrades/Quests fit loops; compact BASE cards and larger actions; mobile horizontal Index scrolling; responsive settings slider hit areas; pinned Trade actions with scrollable details; independent HUD layout for short landscape viewports; event/touch overlays suppressed while modals are open. MobileHudLayout owns short-screen rail sizing; legacy fitTouchRail exits for those screens.

Earlier Round 3 progress is ahead of the old notes above: all four pet rigs and all 20 clips are uploaded, installed and verified. FusionMachine, GadgetStand, VaultGuardian, theme/vault props are installed. See model/animation ownership and integration proof files. Remaining artwork/export permissions, final recovery/install documentation, final source/asset inclusion audit and commit/push remain pending. Never print stored credentials.
