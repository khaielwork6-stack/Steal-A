# Owner model standards

Recorded from the owner's explicit instructions on 2026-09-18. These supersede conflicting older model specifications for future model work. They do not authorize starting an unapproved build or rebuilding existing assets.

## Construction and appearance

- Build all model geometry as MeshParts. No Parts, Unions, wedges, or block-built geometry.
- Author meshes in Blender and import through Studio's 3D Importer, or use Roblox's AI mesh generator.
- Clean up holes, floating pieces, and malformed geometry.
- Texture every model with SurfaceAppearance: ColorMap, NormalMap, RoughnessMap, and MetalnessMap for metal surfaces.
- Keep a consistent game style. The owner's latest style field was a placeholder; the established zone-guardian brief specifies bright saturated colors, chunky cartoon proportions, dark painted outlines, and glossy highlights. Use that established direction unless the owner changes it.
- No scripts, sounds, or lights inside models unless explicitly requested.

## Phone performance

- Small models: strictly under 1,000 triangles; 512 px textures.
- Big models and characters: strictly under 4,000 triangles; 1024 px textures. Treat the limit as the total per complete model, including props.
- Reuse mesh assets for repeated pieces rather than generating duplicate mesh data.

## Dimensions and installation

- Use the exact requested X width, Y height, Z depth in studs.
- Front faces -Z unless otherwise specified.
- Use the requested names and Studio destinations.
- Work in Studio Edit mode, not Play, for this model workflow.
- Remind the owner to save the place when finished.

## Characters and pets

- Use bones and skinned MeshParts with an AnimationController containing an Animator.
- Upload animations to the account or group owning the game. Steal & Run! is owned by group 3774675.
- This supersedes the older zone-guardian brief's Humanoid/Motor6D R15 costume specification. The existing guardian service expects that older skeleton for stock walk/idle playback. Resolve compatibility explicitly before implementation; do not silently substitute the old rig type or claim stock animation compatibility without verification.

## Current zone-guardian approval state

**APPROVED on 2026-09-18.** The owner confirmed: "all 12 designs look good". This approves the complete concept set and authorizes Phase B under these superseding standards.

The owner has explicitly confirmed that ALL TWELVE zone guardians must follow these standards. No guardian is exempt from the MeshPart, SurfaceAppearance, triangle/texture budget, bone-rig, or animation ownership requirements.

The owner has authorized choosing widths and depths to match the concepts while keeping every listed height. No further dimension confirmation is required. Record the chosen XYZ dimensions before building and verify the resulting model bounds. The established bright, chunky cartoon style remains the design direction.

The later whole-set design approval supersedes the earlier "not approved yet" response. No additional concept or dimension confirmation is required.
