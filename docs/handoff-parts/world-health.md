# World health pass (museum build, loot previews, tooling)

Branch work for items D1-D13. Nothing here was run in Studio; every change
was checked statically (`tools/check.sh`, selene) and needs the Studio test
plan at the bottom.

## What changed and why

### D1 - display cases are built once
`MuseumGallery.vitrine` used to `ClearAllChildren()` and rebuild ~20 parts and
a SurfaceGui every time a container was added to or removed from its socket
(every steal, return and Night refill), and shrank back to 12 studs after a
steal. Now each case is built once, with no socket listeners:
- **span** = max(12, displayFootprint(zone) x sqrt(2) + 2). LootService caps a
  socket container's widest side at `MuseumLayout.displayFootprint` (<= 12);
  the client spins it, so the square footprint sweeps that circle. Zones 2-12:
  18.97 studs. Zone 1: 15.12 (its plinths just touch, as the old fit did for a
  max-size container).
- **height** = max(10, tallest + 3), capped at `HEIGHT - 10` (54). `tallest` is
  the new `MysteryModel.tallestDisplayHeight(zone, footprint)`: build()'s
  normalisation at `ScaleConfig.MAX_SCALE` under the footprint cap, measured
  from the zone's container template. **Studio: check the case heights look
  right** - tall/thin container art gives a tall case.
- The case plaque was placed 0.25 studs *inside* the plinth face and never
  showed. It now sits 0.06 proud of the corridor-facing face, so
  "EXHIBIT 0N / SEALED" labels are **newly visible**. (To drop them instead,
  delete the `plaque(holder, ...)` line in `vitrine`.)

### D2 - museum part count (-28% per room)
All museum decor goes through `PartKit.decor` (Anchored, CanCollide/CanTouch/
CanQuery/CastShadow false). Removed per room:
- rope lines: 3 stanchions per side instead of 6 (the old 6 were two doubled
  pairs plus ends; the rope still spans z 7-40) : -22
- ceiling: one neon strip per row (3) instead of 3 x bays panels : -15 (-9 z1)
- hidden: outermost 2 coffer ribs (inside the side walls) and first/last
  crossbeam (inside the front/rear walls) : -4
- cases: one glass shell instead of 4 panes + lid (-4), no base gold ring
  (sat on the gold lip) (-4) : -32 for 4 cases
- laser emitter stands entirely inside the emitter cube (emitters at y <= 0.8)
Unchanged: lasers, doorways, walls (7 Structure parts), guard posts, socket
positions, all MuseumLayout geometry, exhibits.

Computed from the builder (room = Structure + Decorations, lasers excluded):

| Zone | before | after | saved |
| --- | --- | --- | --- |
| 1 | 245 | 174 | 29% |
| 2 | 262 | 185 | 29% |
| 3 | 265 | 188 | 29% |
| 4 | 268 | 189 | 29% |
| 5 | 277 | 196 | 29% |
| 6 | 283 | 204 | 28% |
| 7 | 288 | 209 | 27% |
| 8 | 297 | 216 | 27% |
| 9 | 302 | 219 | 27% |
| 10 | 308 | 225 | 27% |
| 11 | 313 | 230 | 27% |
| 12 | 335 | 248 | 26% |
| 24 rooms | 6886 | 4966 | 1920 (27.9%) |

Measure with `museumPartCount` (below). MuseumTests assertions are unchanged
and should still hold (7 Structure parts, Glass + GoldUpright in each case,
case fits room, decor flags, < 900 decor parts per zone).

### D3 - MapBuilder cleanup, one socket owner
- `MuseumGallery` now creates all 8 sockets (`Socket01-08`, 1x0.2x1,
  invisible, inert, CastShadow off, attributes `MuseumSocket`, `RoomIndex`) at
  `MuseumLayout.socketFrame`, and both guardian posts (`GuardianPost`,
  `GuardianPost02`, attribute `RoomIndex`) at the same frames as before.
  Names, attributes and final positions are unchanged; sockets 1-4 no longer
  pass through a 16x0.6x16 plinth-with-Rim stage first.
- `MapBuilder.placeSockets` and its helpers (`footprintOf`,
  `blockerFootprints`, `isClear`, `settle`, `makeSocket`,
  `makeGuardianPost`, dead `layout = nil` branch) are removed; `buildZones`
  still creates the empty `SpawnSockets` / `GuardianSpawns` folders.
- `MysterySpawnService.layoutZone`: museum sockets are skipped without
  re-setting their properties (MuseumGallery owns them). The legacy offset
  fallback is untouched and, as before, unreachable on a normal boot.
- `applyDecorCollision` runs once, inside `rebuildGalleries` (and in the full
  `build()`); the second call in `init.server.luau` is gone. The boot log line
  `[MapBuilder] decor made hollow: N part(s)` now prints from rebuildGalleries.
  Its Workspace pass is documented: after `archiveLaneScenery` only lane
  models with a Humanoid remain for it.
- `relocateWeather` and its call removed (could never return true:
  `buildWeather` already gives zone 5 the Zone09 weather and zone 9 none).
- `MuseumRevision` is set only by `MuseumGallery.build` (now **4**).
- Removed unused `segmentRun`, `Layout.WALL`, empty section headers.
- Now unused but left alone (not my files): `MapConfig.SOCKET_*`,
  `MapConfig.LANDMARK_SCALE`, `MapPalette.LootSocket/LootSocketRim`.

### D4 - lean loot previews
`LootModel.publishPreviews` publishes exactly one preview per item id, from
`findSource(itemId)` (the same art `build()` uses). Unclaimed assets (saved-
place aliases such as "Toy Train") are no longer copied to clients. Stripped
from previews: scripts, sounds, prompts, ClickDetectors, humanoids, GUIs,
particles, beams, trails, fire/smoke/sparkles, lights, highlights, joints/
welds/constraints/body movers, attachments (bones kept). Parts: anchored,
CanCollide/CanQuery/CanTouch/CastShadow false. SurfaceAppearances, textures,
decals and meshes are kept. `previewSource(itemId)` is unchanged.

### D5 - old art can't shadow new art
- `LootModel.findSource` returns a direct child of `GameAssets.Loot` first and
  never searches inside `_OriginalArt`.
- `ItemAssetBuilder` keeps superseded art in `ServerStorage.GameAssets.
  LootOriginals`; at every build it moves an existing `Loot._OriginalArt`
  there (renames it if LootOriginals does not exist; otherwise merges, never
  deleting a duplicate). **Owner action:** after one Play, or after running
  the builder in Edit, save the place so the move is permanent.

### D6 - shared helpers
- `LootModel.adopt(source, preferUpright?)` is the one adopt;
  `MysteryModel` calls it with `preferUpright = true` (its old pivot rule).
  Behaviour change: a Tool/Accessory-shaped **container** model is now
  unwrapped like loot is (the old MysteryModel copy kept the Tool wrapper).
- New `src/server/PartKit.luau`: `folder`, `decor` (the museum part),
  `span`/`bar`, `GOLD`/`DARK`. Used by MapBuilder (folder), MuseumGallery and
  MuseumExhibits (rod uses `PartKit.span`).

### D7 - dead files removed
`src/client/Backups/` (FreeGiftUI_Backup_PrePNG), `src/server/MapLandmarks.luau`,
`src/shared/Hello.luau` - nothing required them.

### D8 - ItemAssetBuilder split
The DEFINITIONS table and its `Finish`/`Definition` types are in
`src/server/ItemAssetDefinitions.luau` (data only). The builder's
1-space-per-level lines are now tabs. No behaviour change.

### D9 - per-slot trophy rebuild
`BaseService.rebuildSlot(player, slotIndex)` redraws one pad (same drawing
code as the full rebuild via `drawSlot`; the "Trophy" child is still destroyed
and re-created, so HatchController's `ChildAdded` reveal works). It refreshes
the owner sign and fires the `onRebuilt` listeners like the full rebuild, and
falls back to `rebuildDisplays` if the slot is not found (e.g. SlotIndex 0).
Now used by: `HatchService.commit` (reveal swap), `PlacementService.place`,
`.store`, `.equip`. Still on the full rebuild (by design or not mine):
`PlacementService.upgradeCapacity` (lock states of many pads change),
`HeistService` (581, 622, 717, 722), `NightService` (431),
`BaseService.assign`, `DebugService` (9 calls), `ItemArtReview` (29, 44),
`MuseumTests` (272, 342). HeistService is a good next candidate.
Note: a reveal no longer redraws *other* pads; trophies' `IncomeRate`
attributes on other pads refresh on the next full rebuild (same value unless
multipliers changed).

### D10 / D11 - tooling
- `.gitattributes`: `* text=auto eol=lf`, `*.sh text eol=lf`, binaries
  (png/jpg/jpeg/rbxl/rbxm/mp4). **Files were not renormalised** - lead runs
  `git add --renormalize .` once after all merges.
- `stylua.toml` (tabs, 120 columns, LF, double quotes). Not enforced.
- `selene.toml` (std roblox, auto-generated by selene - no roblox.yml needed;
  shadowing and multiple statements allowed; unused vars, if-same, UDim2,
  arg-count and std-lib-use as warnings).
- `tools/check.sh`: finds tools in `~/.rokit/bin` or on PATH, fails cleanly
  if a tool/definitions download is missing, and **exits 1 when the hard-error
  list is non-empty** (Backups paths still ignored).
- `.github/workflows/checks.yml` (ubuntu-latest): installs Rokit via its
  install script + `rokit install --no-trust-check`, `rojo build`,
  `bash tools/check.sh`, `selene --allow-warnings src`.
- `.gitignore`: `*.rbxl`, `*.rbxm`, `*.rbxmx`, `*.rbxl.lock`, `build.rbxl`.

**CI will be red until two existing bugs are fixed (other owners):**
1. `MonetizationService.luau:531` - unknown global `level` (check.sh hard
   error and selene error).
2. `DebugService.luau:1807` - duplicate key `night` in the COMMANDS table
   (selene error; the later definition silently replaces the earlier one).

### D12 - docs
`README.md` rewritten (name, 96 items, Rojo, checks, debug commands,
DebugCommands folder, real-DataStore warning); new `docs/START_HERE.md`. Boot
log now says `[Server] Steal & Run! services started`; MapBuilder header too.
`src/shared/MapConfig.luau` still says "Steal Something" in its header (not
touched - shared file owned elsewhere).

### D13 - large files in git (recommendation only)
- `tools/art-review/sheets/`: 19 JPGs, ~2.9 MB (largest 324 KB). Recommend Git
  LFS for `*.jpg`/`*.png` under `tools/art-review`, or moving the sheets to
  shared storage and keeping only the scripts/markdown in git.
- Other large tracked files: `HANDOFF.md` 300 KB,
  `tools/art-review/generations/remaining-plan.json` 76 KB,
  `GuardianService.luau` 88 KB, `DebugService.luau` 84 KB. No place/model
  files are tracked.

## New debug commands (`DebugCommands/World.luau`)
- `museumPartCount` - parts per room (structure/decor/cases), beams per room,
  zone-level and laser part totals, average per room, `lines` summary.
- `museumCaseChurn(zone?, socket?)` - consumes a socket's container, refills
  the socket, and compares the case's instances. `pass = true` means nothing
  in the case was destroyed or created.

## Studio test plan
1. Sync, Play. Output: no errors from MapBuilder/MuseumGallery/ItemAssetBuilder;
   `[MapBuilder] decor made hollow: ...`; `[LootService] N item previews
   published` (expect ~96, the number of items with art - previously this also
   counted unclaimed aliases); `12 zones x 8 sockets filled`;
   `[Server] Steal & Run! services started`.
2. `DebugInvoke:Invoke("museumTests")` - 0 failed.
3. `DebugInvoke:Invoke("museumPartCount")` - compare `lines` with the table
   above (before numbers: run the same command on master; the module only
   reads the map). Expect ~174-248 parts per room.
4. `DebugInvoke:Invoke("museumCaseChurn", nil, 1, 1)` and `(nil, 12, 6)` -
   `pass = true`, `destroyed = 0`, `created = 0`, `sizeUnchanged = true`.
5. Visual walk through zones 1, 6, 12: cases hold every container (watch a
   Colossal roll: `DebugInvoke:Invoke("spawnSize", ...)` if useful), glass
   reads as glass, EXHIBIT plaques readable on the plinths, ceiling light
   strips, rope lines on 3 stanchions, laser emitters still grounded.
6. `museumLoops`, `museumScenarios`, `museumPaths` - same results as before.
7. Base: steal -> place (only that pad redraws; container + reveal card
   appear); reveal (roulette, trophy swaps in on the pop frame); store and
   equip a trophy; upgrade base capacity (full rebuild). Slot prompts must
   stay correct after each.
8. Index / Storage / reveal roulette: thumbnails in full colour, including
   items with SurfaceAppearance, and the snow globe / radiation chamber.
   `ReplicatedStorage.LootPreviews` has no ParticleEmitter, Attachment (except
   Bones), light, sound or weld descendants, and no non-item names.
9. ServerStorage.GameAssets: `LootOriginals` exists and `Loot._OriginalArt`
   is gone (or warned about). Save the place from Edit if you want it
   permanent.
10. `bash tools/check.sh` exits 1 only for the known MonetizationService
    line; after that fix, 0.
