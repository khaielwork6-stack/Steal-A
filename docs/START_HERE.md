# Start here

A short, current map of **Steal & Run!** for a new developer. Setup, the
"code in git / art in the place" rule and the debug bridge are in the
[README](../README.md). `HANDOFF.md` is the **historical design log**: every
decision and bug, in the order it happened. Search it for context on a
system; don't treat old sections as current.

## The core loop

1. **Steal.** The lane runs along +Z from the lobby (Z < 0) through 12 museum
   zones. Each zone has two side rooms; each room has 4 display cases (sealed
   mystery containers), lasers and one sleeping guard.
2. **Escape.** Taking a container is quiet; leaving the room with it wakes that
   room's guard (short doorway grace). Touching a laser wakes it at once
   (crouch under high beams, jump low ones). Cross the red safe line at Z = 0.
3. **Place.** Put the container on a free display pad on your base. It is
   still sealed and incubates (`HatchConfig`).
4. **Reveal.** When ready, the reveal roulette shows which of the 96 items it
   was; the trophy starts earning Cash.
5. **Grow.** Spend Cash; train Speed on your treadmill. Zones have recommended
   Speed gates, so faster players steal from deeper zones.
6. **Night.** Every `NightConfig.CYCLE_SECONDS` the world closes, everyone is
   sent home, guards reset and every socket is rerolled/refilled.

Side systems: base heists (steal from other players' pads for Robux),
PvP bat and traps, base guardians, free spin wheel, Index (collection rewards),
trails, offline earnings, starter tasks, tutorial, group gift.

## Architecture

Rojo maps `src/shared` -> `ReplicatedStorage.Shared`, `src/server` ->
`ServerScriptService.Server`, `src/client` -> `StarterPlayerScripts.Client`.

### Server boot (`src/server/init.server.luau`)

1. `MapBuilder.rebuildGalleries()` regenerates the lane: zone floors, walls,
   weather (`MapBuilder`), then rooms, cases, sockets, guardian posts and
   lasers (`MuseumGallery`, `MuseumExhibits`, shared geometry in
   `shared/MuseumLayout`; part factory in `server/PartKit`).
2. `ItemAssetBuilder.build()` installs generated loot art into
   `ServerStorage.GameAssets.Loot` (ids in `ItemAssetDefinitions`).
3. Services start in dependency order; `BaseService` starts last.

### Server services (`src/server/Services`)

| Service | Owns |
| --- | --- |
| DataService | Profile load/save/migration (DataStore). |
| StateService | The single server -> client state push (`StatePush`). |
| EconomyService | Passive income and every Cash change. |
| LootService | The 8 sockets per zone: rolls, spawning, refresh, previews. |
| MysterySpawnService | Container model validation; socket layout checks. |
| CarryService | Steal reservation, carrying, movement penalty, delivery. |
| GuardianService | The 24 room guards: sleep, wake, chase, catch, return. |
| LaserService | Static beams, crouch posture, trips (10 Hz). |
| RagdollService | Knock-back and catch immunity. |
| PlacementService | Placing, storing, equipping, selling; capacity upgrades. |
| BaseService | Plot assignment, display pads, trophies (`rebuildDisplays` / `rebuildSlot`). |
| HatchService | Incubation timers and the reveal moment. |
| HeistService | Player-to-player base stealing. |
| BaseGuardianService | Animal guardians defending a player's own base. |
| GuardianShopService | The rotating guardian shop in the lobby. |
| SpeedService | Treadmill training and SpeedPower -> WalkSpeed. |
| TrailService | Trail ownership, equipping and bonus. |
| PvPService | Bat and traps. |
| NightService | The Night cycle and world refresh. |
| IndexService | Discovery tracking and Index rewards. |
| MonetizationService | Developer Products, granted exactly once. |
| SpinWheelService | The free spin on every plot. |
| OfflineService | Offline earnings (capped, claimed once). |
| StarterTaskService / TutorialService | Beginner checklist; the persisted T0-T9 stage and the guaranteed first item (no UI any more). |
| TutorialFilmService | The new-player short film: due flag, "in cinematic" safety, completion (`TutorialFilmController` plays it). |
| GroupGiftService / GiftChestService | Group-join gift; the lobby gift chest. |
| LeaderboardService / StatsService | World boards; the player-list stats. |
| EnvironmentService | Lighting. |
| ZoneSignService / EventStandService / PortalService / SlapDisplayService | Lobby and lane props. |
| SettingsService | Validates and stores player settings. |
| DebugService | Studio-only test bridge (+ `DebugCommands/`). |

Tests and audits live next to the services: `EconomyTests`, `MuseumTests`,
`ParitySim`, `ItemArtAudit`, `ItemArtReview`, plus
`shared/Config/validate.luau`. All run through DebugService (README lists
the commands).

### Client (`src/client`)

`init.client.luau` starts one controller per concern from
`Controllers/`. The important ones: `HUDController` / `HUDLayoutController`
(the purchased UI pack), `UIStateController` (the only thing that hides the
HUD), `InteractController` (the one interaction prompt), `HatchController`
(reveal card and roulette), `InventoryController` (storage),
`IndexController`, `ShopController`, `DisplayFxController` (trophy motion),
`WorldLootFxController` (container idle motion), `GuardianFxController`,
`CrouchController`, `ChaseAudioController`, `NightController`,
`ToastController` (the only path from a server notify to the screen).
Controllers never decide outcomes; they send intents and render state.

### Shared (`src/shared`)

- `Config/` - every tuning number: `GameConfig`, `ZoneConfig` (12 zones,
  Speed gates), `LootConfig` (96 items), `RarityConfig`, `ScaleConfig`,
  `MysteryConfig`, `HatchConfig`, `NightConfig`, `MonetizationConfig` (every
  Robux id), `PvPConfig`, `TreadmillConfig`, ... `validate.luau` checks
  their shape. If you are changing a number, it belongs here.
- `MapConfig`, `MapPalette`, `MuseumLayout`, `LobbyLayout` - world geometry
  and colours.
- `Remotes.luau` - creates and resolves every RemoteEvent.
- `Util/` - shared helpers: `LootModel` (loot art -> model, previews),
  `MysteryModel` (sealed containers), `ItemThumb`, `MutationVfx`,
  `SizeAura`, `RateLimiter`, `Validate`, `UIAnim`, `ShopKit`, ...

### Where the art lives (place file only)

`ServerStorage.GameAssets`: `Loot` (one asset per item id),
`LootOriginals` (superseded saved-place art; never looked up), `ZoneModels`
(the 12 container models), `Template` (the map kit). Clients see loot only
through `ReplicatedStorage.LootPreviews`, a stripped copy published at boot.

## Conventions

- **Server authority.** Clients send intents; every remote is validated
  (`Util/Validate`) and rate-limited (`Util/RateLimiter`). New remotes are
  declared in `Remotes.luau`.
- **Style.** Tabs, `--!strict` in new modules, comments that explain *why*.
  Match the surrounding file; don't mass-reformat (`stylua.toml` is for the
  files you touch).
- **Line endings.** LF in the repository (`.gitattributes`). Don't let an
  editor or script flip a whole file's endings; never `sed -i` a tracked file
  on Windows.
- **Debug commands** go in `src/server/Services/DebugCommands/<Area>.luau`,
  not in `DebugService.luau`.
- **Map geometry** is generated. Before changing it, grep `MuseumTests.luau`
  (it asserts counts, positions and routes) and update it deliberately.
- **Streaming is off** on purpose (distant zones were missing on join). Keep
  replicated part counts down instead (`museumPartCount`).
- **Studio Play saves to the real DataStore** - see the README.
- **Checks before you push:** `bash tools/check.sh` (no new hard errors) and
  `selene --allow-warnings src`. CI runs both.

## Where to look first

- A gameplay number: `src/shared/Config/`.
- "Why is it like this?": search `HANDOFF.md` for the system's name.
- The museum: `MuseumGallery.luau`, `MuseumLayout.luau`, `MuseumTests.luau`.
- Loot from roll to trophy: `LootService` -> `CarryService` ->
  `PlacementService` -> `HatchService` -> `BaseService`.
- Recent change notes: `docs/handoff-parts/`.
