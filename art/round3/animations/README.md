# Pet animation sources

These are draft motion sources for Cat, Dog, Panda and Tiger. They have not been
published or approved on final replacement rigs. No animation IDs are invented.

Run `tools/make-pet-animation-sources.py` to generate the 20 `.rbxmx` clips and
the inspectable `animation-sources.json` data. The generator also checks loop
seams. The files need Studio import/playback review before Open Cloud upload.

## Rig contract

- Model attribute `PetRig = true`; model forward is local **-Z**, up **+Y**.
- One invisible `HumanoidRootPart`, plus seven mesh segments: `Torso`, `Head`,
  `FrontLeft`, `FrontRight`, `HindLeft`, `HindRight`, `Tail`.
- `Humanoid` with `RequiresNeck = false`, and a server-created `Animator`.
- Motor6D tree: root → Torso; Torso → each of the other six segments.
- Limb pivots are at shoulder/hip, head at neck, tail at its base. Joint frames
  have the same axes as the model. Pose rotations are offsets from rest.
- Meshes are not welded across moving joints. Attach details to their segment.
- Author at the configured guardian height; inspect contact with the floor and
  intersections, then adjust the species tuning or joint pivots as needed.

Idle breathes and sways the tail; walk alternates diagonal pairs; run uses a
staggered gallop; attack crouches and pounces; celebrate makes a short hop.
All movement is cosmetic. The service controls speed and catch behavior.

Upload reviewed clips as **Animation**, creator **group 3774675**. Verify owner,
loadability and server-to-client playback before setting the five config IDs.
Keep the original pet models backed up before installing replacements.
