# Twelve zone guardian replacement — 2026-09-18

All twelve approved models are installed under ServerStorage.GameAssets.Guardians.
The previous zone models are preserved under GameAssets.GuardiansOld. VaultGuardian
is retained. Save and Publish the real Studio place to persist the art.

The owner's newer model standards superseded the initial R15 brief. Each new
guardian is one skinned MeshPart with an AnimationController/Animator, four 1024px
PBR maps and fewer than 4,000 triangles including props. GuardianService has a
small opt-in bone-animation path; existing Humanoid and pet behavior is retained.
Both zone configuration keys and guardian audio labels use the new names.
Sound IDs, guardian heights and gameplay tuning are unchanged.

Full asset table, editable sources, verification and limitations:
[Guardian production report](../../art/guardians/PRODUCTION_STATUS.md).

## Verified in Edit

All twelve: exact bounds within import quantization, front -Z, floor Y=0, normalized
skin weights, triangle budget, four texture resolutions, group ownership and
sampled idle/walk playback. All checks passed. Code synced through Rojo.
Static gate: zero hard errors; selene: zero errors, 88 warnings, zero parse errors.

## Still requires Play/device verification

The owner requested Edit-only model work. Chase, catch, return, ragdoll, multiplayer
replication and actual phone FPS/Reduced Effects were not run. Once Play testing is
authorized, use the existing DebugCommands/Gadgets.gadgetSmokeTest pattern for each
zone and verify effects, floor contact and carried props throughout a full chase.
No production model contains scripts, sounds, lights or emitters.
