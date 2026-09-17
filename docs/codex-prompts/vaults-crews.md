# Codex prompts: vaults and crews

Five assets. They share one style. 3D assets use the stylised realism of the
museum loot: chunky readable shapes, clean PBR (SurfaceAppearance), and no
tiny detail that a phone can't show. 2D assets match the purchased UI pack:
a glossy cartoon look, a thick dark outline (about 6% of the short side),
bright top-to-bottom gradients, a soft inner highlight, and a transparent
background (PNG).

After you upload each asset, write its id or name exactly where the asset says.
Leave every other file alone. The code skips any asset whose value is still
`rbxassetid://0` or whose model is missing, so you can deliver them in any
order.

---

## 1. Vault door (3D)

- **Name:** `VaultDoor` (a Model).
- **Place it in:** `ServerStorage.GameAssets.Vault.VaultDoor`. Create the
  `Vault` folder if it doesn't exist. The name is already set in
  `src/shared/Config/VaultConfig.luau` → `VaultConfig.Art.DoorModelName`.
- **Where it's used:** every zone vault's doorway, on the corridor side of the
  wall. `VaultBuilder` scales the model so its largest side is **26 studs**.
  It pivots the model to the door centre, with the disc's face pointing out
  of the model's **-Z (LookVector)** toward the corridor. The client then
  slides the door sideways along the model's X axis to open it.
- **Shape:** a round bank-vault door, 26 × 26 studs across and about 3 studs
  deep. Include a thick gold outer rim, a dark gunmetal face with a
  diamond-plate or brushed finish, a large centre hub with a 3-spoke gold
  wheel handle, 8 chunky bolts around the rim, and a small stylised gear/lock
  emblem. There are no hinges: the door slides aside, so hinges would look
  wrong.
- **Setup:** set the Model's PrimaryPart to the main disc and make the pivot the
  disc centre. Use 30 parts or fewer (MeshParts are fine). Every part must be
  Anchored, with CanCollide, CanQuery and CanTouch off. Include no scripts.

## 2. Vault interior decor set (3D)

- **Name:** `VaultDecor` (a Model).
- **Place it in:** `ServerStorage.GameAssets.Vault.VaultDecor`. The name is
  already set in `VaultConfig.Art.DecorModelName`.
- **Where it's used:** it is cloned into every vault, pivoted to the vault
  frame. That frame's origin sits on the floor at the door. Local +Z runs
  **into** the vault, which is **58 studs deep**. Local X runs along the
  vault's width. The narrowest vault is **35.5 studs wide**, and the inner
  wall faces are at x = ±15.75. The ceiling is at **y = 30**.
- **Contents:** keep everything against the side and back walls, inside local
  x ∈ [-15.5, -12] ∪ [12, 15.5] and z ∈ [3, 56]:
  - stacked gold bars on low pallets (2 sets)
  - 4 wall-mounted safe-deposit box panels (grids of small doors)
  - 2 money-bag piles
  - riveted steel wall plates
  - 2 red rotating alarm beacons (static meshes, no lights)
- **Keep clear:** the middle of the room (|x| < 12), the doorway strip
  (z < 3), and the laser ring. The ring is centred at z ≈ 38 with a radius of
  up to 18 studs, so keep floor props low there (height < 0.5) or leave that
  area empty.
- **Budget and setup:** 60 parts or fewer. Everything must be Anchored, with
  CanCollide, CanQuery, CanTouch and CastShadow off. Include no lights and no
  scripts.

## 3. Vault Guardian costume (3D character)

- **Names:** `VaultGuardian` as the generic costume. You can also add
  per-zone variants named `Zone07_VaultGuardian` (use the two-digit zone
  number).
- **Place them in:** `ServerStorage.GameAssets.Guardians`. The base name is
  already set in `VaultConfig.GUARDIAN.costumeName`.
- **Where it's used:** the tougher guard that sleeps inside each vault.
  `GuardianService` scales it to **18 studs tall at most**, because the vault
  door is 20 studs tall.
- **Look:** a heavy armoured security guard. Give it a dark steel riot suit
  with gold trim, a visor helmet with a glowing red visor slit, shoulder
  plates, a large keyring on the belt, and a baton. The silhouette should be
  bulkier than a museum cop.
- **Rig:** a standard **R15** rig with a Humanoid and the standard part names
  and Motor6Ds. The game plays Roblox's own walk and idle animations on it.
  Face the rig down -Z, with its feet at the bottom of its bounding box.
  Include no scripts.

## 4. Crew HUD icons (2D)

Make four square PNGs, **256 × 256**, on a transparent background, in the UI
pack's glossy style. Use a teal/aqua palette (#28BEAA to #28AAFF) for crew
items and gold (#FFD25A) for the leader.

| Key | Picture | Write the id to |
| --- | --- | --- |
| `Crew` | three friendly heads side by side, the middle one slightly forward | `src/shared/Config/CrewConfig.luau` → `CrewConfig.Icons.Crew` |
| `Leader` | a gold star on a small crown | `CrewConfig.Icons.Leader` |
| `Invite` | one head with a plus badge | `CrewConfig.Icons.Invite` |
| `Assist` | two hands high-fiving with a burst of coins | `CrewConfig.Icons.Assist` |

The `Crew` icon appears on the "CREW" button of the HUD card, inside a
56-pixel-tall button. The code already shows it once its id is set. The other
three are kept in config for later polish, and the text labels work without
them.

## 5. "Vault restocked" banner (2D)

- **Size:** a **1024 × 256** PNG (4:1) on a transparent background.
- **Where it's used:** it pops up top-centre for about 3 seconds, together
  with the server-wide toast "The Zone 7 vault has restocked!". It is shown by
  `VaultController`.
- **Look:** the words **VAULT RESTOCKED!** in chunky white cartoon letters
  with a thick dark outline and a gold-to-orange gradient fill. Place them
  over a round steel vault door on the left, with gold bars and sparkles
  bursting out. Use the UI pack's glossy style with a light inner highlight.
  Leave no text other than the title: the zone name comes from the toast.
- **Write the id to:** `src/shared/Config/VaultConfig.luau` →
  `VaultConfig.Art.RestockBanner`, as `"rbxassetid://<id>"`.
