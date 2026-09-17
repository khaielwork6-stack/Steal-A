# Saving generated loot into the place

The builder is the source of the art recipe. The place must also contain its
finished output because user-owned model packages cannot be assumed loadable
by this group-owned experience.

- A current model has `ProceduralItemArt=1`, the expected `ItemArtVersion`,
  matching `ItemArtAssetId`, a PrimaryPart and the recorded part count.
- Startup reuses current models without loading packages or reapplying the recipe.
- Missing/outdated models use the existing concurrent load path and retry once.
  A failure preserves prior art and reports the error. Do not rely on that path
  to distribute a new version to live servers.
- Bump a definition's `revision` when changing its materials or geometry.
  Bump `ART_VERSION` when changing shared authoring. Asset IDs and extra
  component package IDs are included in the version key automatically.

## Studio MCP installation workflow

Direct `require(ItemAssetBuilder)` from the Edit MCP thread is denied by Studio
capabilities. Do not change those capabilities. Use the supported asset insertion
tool and a data-only transfer:

1. Sync the builder, run fresh Play, and export the finished models with
   `export-built.luau`. Limit exports to one zone per call to avoid tool output
   truncation. Do not export account data.
2. Stop Play. Use Studio MCP `insert_asset` for the model package IDs into
   `ServerStorage._ItemArtBakeSources`. Include additional component packages
   and the reusable generated halo package 74512256472323 when needed.
3. Pass each small batch of exported rows to `bake-edit.luau` in Edit.
   It reconstructs the final model from inserted MeshParts plus exact properties,
   attributes, effects and welds. Original ItemId-named art is preserved in
   `Loot._OriginalArt`; original alias-named assets remain in place.
4. Start fresh Play. Require all items cached and `ItemArtNetworkLoads=0`.
   Run the standard debug audits. Stop Play and remove the temporary insertion
   source folder and only the known generated review imports.
5. The owner must **Save and Publish the place**. A git push alone cannot ship
   the embedded model instances. Check a published server afterward.

The exported models are already sized; the installer copies final part sizes
and frames and does not normalize them again. Do not run the recipe over a
current baked model.
