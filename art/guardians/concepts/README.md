# Zone guardian concepts — Phase A

**Status: all twelve designs approved by the owner on 2026-09-18: "all 12 designs look good".**

Brief: [ZONE_GUARDIANS.md](../../../docs/codex-prompts/ZONE_GUARDIANS.md).
Generated with the built-in image_gen tool. Exact prompts: [prompts.json](prompts.json).

[Open the 4 × 3 overview](ALL.png). Each individual sheet contains a front three-quarter view, back view, chase pose, height label, player reference, palette swatch and prop caption.

These are visual concepts, not rig/mesh deliverables. Height labels are the verified GameConfig values; illustrated player silhouettes are approximate visual references, not measured engineering scale drawings. The overview is for comparing the character designs. Production rig heights will use GameConfig exactly after approval.

| Zone | Location | Guardian sheet | Height (studs) |
| --- | --- | --- | ---: |
| 1 | Museum | [NightWatchman](Zone01_NightWatchman.png) | 7 |
| 2 | Pirate Island | [GhostCaptain](Zone02_GhostCaptain.png) | 7.8 |
| 3 | Castle | [IronKnight](Zone03_IronKnight.png) | 8.8 |
| 4 | Area 51 | [GreyAgent](Zone04_GreyAgent.png) | 10 |
| 5 | North Pole | [FrostYeti](Zone05_FrostYeti.png) | 11.5 |
| 6 | Ancient Egypt | [Mummy](Zone06_Mummy.png) | 14 |
| 7 | Gym | [IronTitan](Zone07_IronTitan.png) | 17 |
| 8 | Bank | [VaultBot](Zone08_VaultBot.png) | 20.5 |
| 9 | Secret Lab | [LabMutant](Zone09_LabMutant.png) | 24.5 |
| 10 | Grandma's House | [Granny](Zone10_Granny.png) | 29 |
| 11 | Construction Site | [WreckingForeman](Zone11_WreckingForeman.png) | 34 |
| 12 | Airport | [SkyMarshal](Zone12_SkyMarshal.png) | 40 |

## Approval gate

The complete set is approved. Phase B uses the superseding [model standards](../../../docs/MODEL_STANDARDS.md): bone-skinned MeshParts, AnimationController/Animator, PBR SurfaceAppearance, fewer than 4,000 triangles per character, and 1024 px textures. Work stays in Studio Edit mode. No Studio operations or game-code changes were made for Phase A.

The existing working tree was preserved. Git pull is deferred to Phase B because this phase's explicit gate prohibits changing game code.
