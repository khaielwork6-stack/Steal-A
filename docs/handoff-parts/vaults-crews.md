# Vaults and crew heists (vaults-crews)

This branch adds vault rooms and crew heists (the vaults-crews worktree).
None of it was run in Studio. Every change was read back and checked
statically:

- `tools/check.sh`: no hard errors. Every new TypeError is the existing
  pcall / attribute pattern.
- `selene src`: 0 errors.

Art is placeholder until the assets in `docs/codex-prompts/vaults-crews.md`
land.

## 1. Vault rooms

### Where the vaults are (MuseumLayout, new VAULTS block)

The museum left **unused wings**: the space behind each FacadeExtension,
between a room's side wall and the end of the zone. Each vault fills one of
these wings.

- **Length:** up to 48 studs along the corridor.
- **Depth:** the room depth (58). The vault reaches from the corridor facade
  (X = ±22) to the lane wall.
- **Height:** 30.
- **Door:** 14 wide × 20 tall.

Zones 1 and 2 have only 4-stud wings, so their vaults sit in **Zone 3's near
wings**, left and right, on the corridor just past Zone 2. Their folders still
live under `Zone01_Museum.Vault` and `Zone02_Pirate.Vault`. Every other zone
has its vault in its own **far** wing: odd zones on the left, even zones on
the right. The Zone 3 vault is 35.5 long; from Zone 4 on they are 47-48.

**Nothing pinned moved.** Rooms, doorways, sockets, posts and lasers are
unchanged. `MuseumGallery`'s facade loop now asks
`Layout.facadeSegments(zone, side, end)`, so a wing that holds a vault leaves
that span to the vault's own front wall. The front wall is full museum height
(64) with the door cut in.

**MuseumLayout contract changes.** The vault is "room 3" (`VAULT_ROOM`):

- Its loot is `VAULT_SOCKET` = 9, and `roomOfSocket(9) == 3`.
- `locate()` returns (zone, 3) inside a vault. It still returns nil
  everywhere it used to return nil.
- `key(zone, 3)` = 24 + zone. It used to collide with the next zone's room 1.
- `waypoint()` routes through a vault door with the same rule as a room. For
  rooms the numbers are identical to before (tolerance 14, corridor point
  zoneCenterZ).

### Geometry (`src/server/VaultBuilder.luau`)

`MapBuilder` calls `VaultBuilder` right after `MuseumGallery`, in both
`rebuildGalleries` and `build`. It builds `Zones.<id>.Vault`, about 50 parts
per vault, all anchored:

- **Structure (8):** front wall ×2, header, side walls ×2, rear wall,
  ceiling, pedestal. These collide.
- **Decorations:** `PartKit.decor`, so CanCollide, CanQuery, CanTouch and
  CastShadow are all off. This includes the floor, the ring track, the gold
  rails, the wall ribs, the light strips, the door jambs, the hazard step and
  the status sign.
- **Door:** a Model (disc, rim, hub, spokes, bolts). The client slides it
  aside. If `ServerStorage.GameAssets.Vault.VaultDoor` exists, it replaces
  the placeholder.
- **VaultBarrier:** fills the doorway and **never collides on the server**
  (see the Speed gate below).
- **Lasers:** `VaultBeam` parts carrying `LaserGeometry.SweepArm` attributes.
- **SpawnSockets.Socket09:** the pedestal socket. The folder name lets
  `WorldLootFxController` idle the container.
- **GuardianPost:** just inside the door, facing the pedestal.
- **Attributes on Vault:** `VaultZone`, `HostZone`, `RequiredSpeed`,
  `DoorOpen`, `DoorForced`, `Stocked`, `RestockAt` (server time).

`MuseumRevision` was not bumped. It belongs to MuseumGallery, and the vault
has its own folder.

### Loot (LootService)

The vault pedestal is a socket kept **outside** `sockets`. That means
`refreshAll`, `occupancy`, `spawnedLoot`, the spotlight and every existing
count/economy test never see it. It differs from a normal socket in these
ways:

- **Roll:** `VaultConfig.pick`. Only the zone's **top two rarities**, weighted
  25:75, with each item's ordinary weight inside its tier. Zone loot weights
  are unchanged.
- **Size:** the container footprint is capped at 7 so it fits inside the
  laser ring.
- **Reach:** the prompt range is sized so the pedestal can be reached from
  inside the ring only. Its ObjectText is "Vault".
- **Respawn:** no Zone 1 60-90 s respawn.
- **New API:** `addVaultSocket`, `isVaultLoot`, `restockVault(zone, reroll)`.
  `getSocket(zone, 9)` returns the vault socket.

Carry, catch, drop, return, Night cancel and placement all go through the
ordinary paths. The container is sealed and hatches like any other.

### The Speed gate

A player qualifies when their `SpeedPower` is at least the zone's
`recommendedSpeed` × `VaultConfig.SPEED_GATE_FRACTION` (1). Zone 1 is open to
everyone.

- **Door (VaultService, 4 Hz):** `DoorOpen` is true while a qualified player
  is within 22 studs of the door or inside the vault. Every client animates
  the door from that.
- **Barrier (VaultController):** the client sets `VaultBarrier.CanCollide`
  locally to *true* when **this** player doesn't qualify, or when the door is
  forced closed. An honest client is stopped at the door, and server-owned
  guards pass freely.
- **Authority (VaultService):** an unqualified player found inside a vault is
  teleported just outside the door, using `MovementService.allowTeleport`,
  and gets a toast. `CarryService.pickupVeto`, a new injected hook wired to
  `VaultService.pickupVeto`, refuses vault loot to unqualified players. A
  pedestal steal also needs the verified position within `ring.inner + 0.5`
  of the pedestal, so the steal can't be done from outside the laser ring.
- **Design note:** `ZoneConfig` says nothing should hard-block **zone entry**
  on the recommendation. The vault door is a hard gate by request, and zone
  entry is untouched.

### Rotating lasers (LaserGeometry, LaserService)

- `LaserGeometry.sweepAngle / sweepLit / sweepAt / sweptArmHit` compute an
  arm from `workspace:GetServerTimeNow()`. The angle is reduced modulo the
  period first, so it keeps full precision.
- An arm can have an on/off duty cycle.
- `sweptArmHit` sub-steps the 0.1 s sample (up to 8 steps). It grows the
  body's box by the arm tip's travel in each step, so a fast arm can't slip
  between samples.
- `LaserService.addMovingField(zone, room, arms, inside)` is registered once
  per vault. Each 10 Hz step sweeps a player who is inside a vault against its
  arms. The trip handling is the same as a static beam: the room-3 cooldown
  key, the `LastLaser*` attributes, and `GuardianService.alarm(zone, player, 3)`.
- The client (`VaultController`) poses the beam parts every frame from the
  same function, and only for vaults within 260 studs of the camera. The
  server never moves those parts.
- **Pattern (`VaultConfig.beamsFor`):**
  - All zones: 2 ankle arms (jump them). The period is max(3.2, 7 − 0.3·zone)
    seconds per turn.
  - Zone 4+: a counter-rotating head arm (crouch under it).
  - Zone 8+: a third ankle arm.
  - Zone 11+: a waist arm, lit 3 s and dark 2 s (time it).
- **Ring:** the pedestal radius is 5.45. The inner edge is at 8.95, which
  leaves a 3.5-stud standing ring. The outer edge is at
  min(inner + 9, half-width − 1), so 14.75 in Zone 3 and 17.95 elsewhere.

### Vault Guardian (GuardianService, same AI)

The start loop now also posts room 3 from `Vault.GuardianPost`, with profile
`VaultConfig.GUARDIAN`:

| Setting | Value | Effect |
| --- | --- | --- |
| `speedScale` | 1.08 | chase speed is ×1.08 of the per-thief speed |
| `wakeScale` | 0.5 | halves both the wake beat and the doorway grace |
| `catchScale` | 1.35 | catch radius is ×1.35 |
| `laserLeash` | 45 s | how long a laser chase lasts (room guards: 25 s) |
| `maxHeight` | 18 | costume height cap |

The costume comes from `Guardians.Zone{NN}_VaultGuardian`, then
`VaultGuardian`, then the zone's own guard. The doorway rule, catch, recovery
and Night reset are unchanged, because vault loot is room 3's.

**Merge note:** another agent is moving guard patrols (zones 7+) in
GuardianService. My edits are small and marked:

- the `profile` field on `Guardian`
- the `buildRig(zoneIndex, profile?)` branch
- two lines in `beginChase` and one line in `stepChase` (the leash)
- the start loop, which now runs to `Layout.VAULT_ROOM` with the post lookup
  and `profile`
- `activeChaseRooms` now also returns `target`

**Balance note:** at exactly the recommended Speed, a thief carrying vault
loot is meant to be caught (×1.08). Tune `speedScale` if that is too harsh.

### Restock (VaultService)

- **Timer:** an empty pedestal restocks `RESTOCK_SECONDS` (600) after it
  emptied. A container the guard brings back stops the clock. The restock
  sends the server-wide toast "The Zone N vault has restocked!" (style
  `vault`, cue NightSpawn). Once `VaultConfig.Art.RestockBanner` is set, the
  banner image shows too.
- **Night:** with `RESTOCK_AT_NIGHT` (on), each Night, 2 s after it falls,
  sitting vault containers are **rerolled** and empty vaults filled. Players
  get one "The vaults have restocked!" toast if any vault had been empty.
- **Owner decision:** the Night comes every 270 s, so while
  `RESTOCK_AT_NIGHT` is on, the Night — not the 10-minute timer — usually
  decides the refill. That is a guaranteed top-two-rarity container per zone
  every 4.5 minutes for anyone with the Speed. If that is too generous, set
  `RESTOCK_AT_NIGHT = false`.
- **Kill switch:** `VaultConfig.ENABLED = false` leaves the vaults empty with
  their doors shut.

## 2. Crew heists

- **Server:** `CrewService`. **Client:** `CrewController`.
- **Remote:** `CrewRequest(action, targetUserId?)`, appended at the end of
  `Remotes.NAMES`. It is validated (action whitelist, `Validate.integer`,
  target in server) and rate-limited to 3/s.
- **Rules:**
  - Up to 4 members.
  - Anyone not in a crew can be invited. An invite lasts 60 s, and a player
    can have at most 6 invites out at once.
  - Accepting creates the crew, with the inviter as leader, or joins it.
  - Only the leader invites and kicks. Anyone can leave.
  - If the leader leaves, the next member leads.
  - A crew with fewer than 2 members dissolves.
  - Nothing is saved. `lastCrew` is kept for the session only and shows as
    "RECENT CREW MATE".
- **Replication:**
  - `Player` attribute `CrewId`, used for nameplates and for hiding the Rob
    prompt between crew mates.
  - StatePush field `crew`, registered with `StateService.addProvider` in
    init. It carries members, invites, sent, recent and max.
- **UI:**
  - **HUD card:** on the right edge, inside MainUI. It has a teal "CREW"
    button, a member list with ★ for the leader, and quick ✓/✕ buttons for
    invites.
  - **Frames.Crew:** cloned from the Sell skeleton that InventoryController
    parks in `MainUI.Templates`. The card's button is named `Crew`, so the
    pack script opens this panel. The panel has one row per player
    (INVITE / KICK / JOIN / NO), and the header's SELL ALL becomes LEAVE.
  - **Nameplates:** a local BillboardGui ("CREW" or "★ CREW LEAD") over each
    crew mate.
  - **Touch targets:** 56 px before the phone UIScale.
  - **Toasts:** crew toasts use style `crew`. Two styles were added to
    ToastController: `vault` and `crew`.
- **No robbing crew mates:** `HeistService.areCrewmates` is injected, and
  `begin` refuses with "You can't steal from your crew!".
  `RobPromptController` hides the prompt on a crew mate's base.

### Crew assist

**Where it fires:** `CarryService.consumeCarry` has **one line**:
`ProgressEvents.fire(player, "delivered", 1, {itemId, zoneIndex, income, heist})`.

**When it pays:** `CrewService` listens for that event. It pays when the
deliverer has another crew member who either:

- is within **60 studs**, or
- was the target of a guard of the item's zone in the last **20 s**.

Chases are sampled every 0.5 s from `GuardianService.activeChaseRooms`.

**Who gets paid:** the deliverer, members within 60 studs, and members seen
inside that zone's band in the last 45 s. Each earns
`income × 60 × 0.25` through `EconomyService.earn` (source `crew`, a new
`CashSource`) and gets a "CREW ASSIST! +$X" toast. Heist deliveries
(zone 0) never pay.

**ProgressEvents:** `src/server/Services/ProgressEvents.luau` is a minimal
copy with the agreed API: `fire(player, kind, amount?, info?)` and
`on(kind, fn)`. `on` returns a disconnect function. **On merge, keep the
fuller version from master**, as long as it keeps that API. My `info` also
carries `heist`.

## Owner actions

- No Robux products, gamepasses, badges or DataStore changes. The profile
  schema is unchanged.
- Codex assets and where their ids go: see
  `docs/codex-prompts/vaults-crews.md`. They are the door model, the decor
  set, the guardian costume, 4 crew icons (`CrewConfig.Icons`) and the
  restock banner (`VaultConfig.Art.RestockBanner`).
- Decide on `RESTOCK_AT_NIGHT` and `GUARDIAN.speedScale` (see the notes
  above).

## Studio test plan

Run every command as `ServerStorage.DebugInvoke:Invoke(name, nil, ...)`. The
commands are in `DebugCommands/Vaults.luau`.

1. **Boot.** Sync and press Play. In Output:
   - `[VaultService] 12 vaults open for business`
   - `[GuardianService] 36 guardians posted`
   - no "has no vault GuardianPost" warnings

   The existing boot lines must be unchanged.
2. **Static checks.**
   - `validate` shows 0 failed. The new block covers the roll tables, ring
     widths and config shapes.
   - `museumTests` shows 0 failed. Per vault it checks: in an unused wing, no
     overlap, key/socket, decor flags, < 150 parts, 8 Structure children,
     barrier never colliding, doorway open, wall beside the door, the host
     corridor still clear, socket and post inside, `locate`, 4 door routes,
     arms inside the walls, beam count, and stocked with a prompt.
   - The existing checks must still pass unchanged, including the room
     doorway routes, which changed code but not numbers.
   - `museumLoops`, `museumScenarios`, `museumPaths` and `museumPartCount`:
     same results as before.
3. **Look at the vaults.** Run `vaultStates`, then `vaultTeleport 7` and
   `vaultTeleport 1`. Walk Zones 1-3 and 7. Check that:
   - the door, sign and gold trim look right, with no gaps next to the room
     side walls and the facade closed over the rest of each wing;
   - the arms rotate smoothly, and the Zone 11/12 waist arm blinks;
   - the Zone 1 and Zone 2 vaults sit in Zone 3's near wings.
4. **Speed gate.**
   - Run `vaultBypass false` on a profile below Zone 7's 2.5M. Walk to the
     Zone 7 door: it stays shut and you are blocked at it. The sign status is
     red.
   - Run `vaultDoor 7 open` and walk in: you can.
   - Run `vaultDoor 7` (nil). You should be ejected outside with the toast.
   - `vaultVeto 7` then shows the Speed reason.
   - On a qualified profile (or Zone 1): the door slides open when you are
     within 22 studs, and closes when you leave.
5. **Steal.**
   - With bypass on: `vaultVeto 7` from the doorway says "Get inside the
     laser ring". From inside the ring (on the gold circle) it returns
     "none".
   - Touch an arm: the Vault Guardian wakes fast and `LastLaserRoom` is 3.
   - Steal inside the ring, then walk out of the door: the guard alerts after
     about 0.5 s. Get caught: the same container goes back to the pedestal.
   - Escape and place it: it arrives sealed and reveals a top-two rarity item.
6. **Restock.**
   - After a steal, `vaultStates` shows `restockIn` counting down from 600,
     and the sign shows "RESTOCKS IN m:ss".
   - `vaultRestock 7` fills the vault, and **everyone** gets "The Zone 7
     vault has restocked!".
   - `Invoke("night", nil, "begin")` (existing command): about 2 s in, the
     vaults reroll.
   - `vaultRestock nil nil true` rerolls every vault.
7. **Crew assist in solo Studio.**
   - `crewAssistSim near 7` and `crewAssistSim chased 7`: `paid` has your
     name with income×15, you see the toast, and `restoredCash = true`.
   - `crewAssistSim present 7` and `crewAssistSim none 7`: reason "no crew
     mate nearby or distracting".
8. **Team Test (2-3 clients).**
   - Open CREW, INVITE the other player. They get a toast and ✓/✕ on their
     card; accept. Both cards list the members, with ★ on the leader, and
     "CREW" tags float over heads.
   - The Rob prompt is gone on your crew mate's base. Firing it anyway gives
     "You can't steal from your crew!".
   - Steal, have your crew mate stand next to you at home, and place the
     item: both get CREW ASSIST.
   - Repeat with the crew mate far away but chased in that zone within 20 s:
     both are paid.
   - KICK or LEAVE down to one member: the crew dissolves with a toast.
   - A leaving player is removed and their invites vanish.
   - `crewForm <name>` and `crewState` help set this up quickly.
9. **Mobile emulator.** The CREW card doesn't overlap the rail or the
   checklist, the buttons are tappable, and the panel scrolls.
