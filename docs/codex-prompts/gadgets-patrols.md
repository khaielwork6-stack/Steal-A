# Codex prompts: gadgets and patrols

Game: "Steal & Run!", a Roblox museum heist. Players buy three consumable
gadgets with in-game Cash and use them from the hotbar. Every asset below
currently uses a placeholder. After you upload an asset, put its id in the
config key given for it. `"rbxassetid://0"` means "not made yet" and the code
skips it.

Config file: `src/shared/Config/GadgetConfig.luau`, table
`GadgetConfig.Gadgets.<Key>`.

## 1. Handheld gadget meshes (3)

Style: stylised realism that matches the museum loot art. Use clean
mid-poly shapes, soft PBR-like colours baked into one texture, readable
silhouettes, and no text or logos. Each mesh is held in one hand by a
standard Roblox character, so it should be about 1.5-2 studs long at scale 1.
Put the origin at the grip point, with +Y pointing "up the tool" and -Z
pointing forward. Keep each mesh under 2,000 triangles and use one 512x512
texture per mesh.

| Key | Mesh | Description |
|---|---|---|
| `Smoke` | Smoke bomb | A matte gunmetal sphere (~1.3 studs) with a pale grey band around the middle and a short fabric fuse on top that has a glowing orange tip. |
| `Jammer` | Laser jammer | A handheld electronic device (~0.9 x 1.4 x 0.45 studs) in dark blue metal. Give it a glowing cyan screen on the front and a thin antenna with a cyan bead on top. |
| `Grapple` | Grappling hook launcher | A wooden pistol grip with a short dark-metal barrel. A folded three-prong brass hook sits at the muzzle. |

Upload each mesh and its texture, then set `meshId` and `textureId` for that
key. The server wraps the mesh in a SpecialMesh on a 1x1x1 Handle
(`GadgetService.buildTool`). If the mesh needs a scale other than 1, tell the
lead so `mesh.Scale` can be added.

## 2. Hotbar and shop icons (3)

Use a 512x512 PNG with a transparent background. Match the purchased UI
pack: a glossy cartoon look, a thick dark outline (about 16 px at 512),
bright gradients and a soft highlight. Show the object at a slight 3/4 angle
and centre it with about 8% padding. The icons are drawn at 58-66 px on the
hotbar, so the shapes must read at that size.

- `Smoke`: the smoke bomb with a puff of grey smoke curling from the fuse.
- `Jammer`: the jammer with a cyan lightning zig-zag over a red laser line.
- `Grapple`: the hook launcher with a rope and a hook flying out.

Set each image in `icon` for its key. It is used as the Tool's `TextureId`
and as the shop card art in `GadgetShopController`.

## 3. VFX textures (optional, 2)

- **Smoke puff sheet.** A single soft, cartoon cloud puff, 256x256, in
  greyscale on transparent. Its edges must tile well when rotated. Set it in
  `GadgetConfig.SMOKE_TEXTURE`. The current value is the engine's
  `rbxasset://textures/particles/smoke_main.dds`.
- **Jam spark.** A small four-point electric spark, 128x128, in white on
  transparent (it is tinted cyan in code). Set it in
  `GadgetConfig.JAM_TEXTURE`.

## 4. Gadget shop stand art (optional)

The gadgets are sold in the main Shop panel under a "GADGETS" section, so no
stand is required. If the owner wants a physical lobby stand next to the
trail shop, make a stylised museum-black-market kiosk model: a dark wood
counter, a brass sign frame with no text, and three small display pedestals
for the three gadgets. Make it about 14 wide x 10 tall x 8 deep studs.
Deliver it as a Model named `GadgetStand` in `ServerStorage.GameAssets`, and
tell the lead so a stand service can be added. No code expects it today.
