# Zone guardian production

## Approved

All twelve concepts approved by the owner on 2026-09-18: "all 12 designs look good".
The newer requirements in `docs/MODEL_STANDARDS.md` supersede the original R15
Humanoid specification. Exact production bounds are in `production.json`.

## Completed preparation

- Confirmed the connected place is Steal & Run! (134344354476234), group 3774675.
- Pulled master with `--ff-only`: already up to date at 6a4094e.
- Required static baseline: `tools/check.sh` had zero hard errors.
- Preserved the existing unrelated vault/UI working-tree changes.
- Added `tools/audit-zone-guardians.luau` for production validation. It has not
  run against new models; no new guardian has passed validation yet.

## Current interruption

Studio was in Play. It was stopped for the owner's Edit-only workflow, and an
Edit query confirmed the correct place and group. Studio then returned to Play
while the first mesh generation was starting. Job
`7bb4504a-ba69-434c-ab2d-434af04735d8` failed with:
`Model generation should only be called from the server.`

Do not retry or repeatedly stop another task's test session until Studio access
is settled. The owner has been asked whether Studio can remain in Edit for this
work, or another task needs it and local preparation should proceed first.

## Remaining

1. Validate the first AI-generated mesh's skinning, complete PBR maps, exact
   bounds and group publication before scaling up to all twelve.
2. Build and visually inspect all twelve; validate triangle/texture budgets,
   surface maps, bones, weights, ownership and animations.
3. Add the minimal AnimationController support to GuardianService, preserving
   its existing pet and Humanoid paths and all gameplay tuning.
4. Preserve old zone models under GuardiansOld; install the validated models
   and update both guardian-key configurations.
5. Verify in Edit mode, run static gates, commit/push only this task's files,
   and remind the owner to save/publish the place. Live chase testing remains
   unverified while the owner's Edit-only requirement applies.

No new guardian model was uploaded or installed, and no gameplay source file
was changed during this production preparation.
