# Codex prompts: round 3

Other round 3 areas may add their own sections to this file.

## Daily rewards & offline earnings

Area: round3-ui-rewards. Make 5 images for the Roblox game "Steal & Run!", a
cartoon museum heist game. Upload each one as a Roblox Image. Then paste its
id into the config key listed for it, in
`src/shared/Config/RewardUiConfig.luau`. Use the image id
(`rbxassetid://<id>`), not the decal id. If Roblox gives you a decal id,
convert it to the image id first.

While a key is `rbxassetid://0`, the game draws a code placeholder instead,
so each image can be done on its own. `validate.luau` only accepts values
in the form `rbxassetid://<digits>`.

### Style (all 5 images)

- Match the purchased UI pack the HUD already uses:
  - glossy cartoon look;
  - a thick dark outline, about 6-8% of the subject's width, colour
    #141024 to #1A1A22;
  - bright two-tone vertical gradients;
  - one soft white highlight at the top left;
  - a small drop shadow straight down.
- Compare with these pack icons in the place:
  - cash stack: `rbxassetid://112931960147028`
  - speed arrow: `rbxassetid://102080723305863`
  - shop crate: `rbxassetid://109523362330544`
- Transparent background (PNG with alpha).
- No text, no numbers, no border or plate behind the subject.

### 1. Sun rays (sunburst)

- Key: `RewardUiConfig.RAYS_IMAGE`
- Used in:
  - behind the day 7 GRAND PRIZE tile (spinning slowly);
  - the claim burst behind a claimed day;
  - behind the cash pile on the WELCOME BACK popup.
- Size: 1024 x 1024 px, square. The centre of the burst is the exact centre
  of the canvas.
- Content:
  - 16 to 20 straight rays of equal angle from the centre, alternating wide
    and narrow;
  - pure WHITE (#FFFFFF), because the game tints the image;
  - each ray fades from about 70% opacity near the centre to 0% at the edge
    of the canvas;
  - no outline and no shadow on this one image;
  - nothing may touch the canvas edge (the image turns, and a visible edge
    would give it away).

### 2. Streak flame

- Key: `RewardUiConfig.FLAME_ICON`
- Used in: the orange "3 DAY STREAK" pill at the top of the Daily Rewards
  panel, left of the text. It is shown at about 40-60 px and gently pulses.
- Size: 512 x 512 px, square. The flame fills about 85% of the height and is
  centred.
- Content:
  - a single cartoon flame with 2-3 tongues;
  - outer red-orange (#FF5424), middle orange (#FFA028), yellow-white core
    (#FFEE6E);
  - thick dark outline;
  - a white gloss highlight on the upper left.

### 3. Grand prize chest

- Key: `RewardUiConfig.GRAND_PRIZE_ICON`
  (`DailyRewardConfig.Days[7].icon` wins if both are set. Leave that one at
  0.)
- Used in: the gold DAY 7 GRAND PRIZE tile of the Daily Rewards calendar,
  over spinning rays. It is shown at about 100-200 px wide.
- Size: 768 x 512 px (3:2 landscape). The chest fills about 90% of the width.
- Content:
  - an open treasure chest, 3/4 front view;
  - gold trim and dark red/purple wood;
  - overflowing with green cash bundles and gold coins;
  - one blue-to-cyan speed arrow (like the pack's speed icon) sticking out
    of the top at an angle, because day 7 pays Cash AND Speed;
  - a warm glow inside the lid;
  - thick dark outline.

### 4. Coin

- Key: `RewardUiConfig.COIN_ICON`
- Used in: the 12-16 coins that fly from a claimed reward into the HUD cash
  counter. Each coin is shown at only 22-44 px, so it must read at that
  size.
- Size: 256 x 256 px, square. The coin fills about 90%.
- Content:
  - one thick gold coin, slightly tilted (about 20 degrees) so its rim
    shows;
  - an embossed "$" in the middle (the only symbol allowed in this set);
  - thick dark outline;
  - a strong white glint at the top left.

### 5. Cash pile

- Key: `RewardUiConfig.CASH_PILE_ICON`
- Used in: the centre of the WELCOME BACK offline earnings popup, over the
  rays, shown at about 150-220 px wide. It gently bobs.
- Size: 768 x 512 px (3:2 landscape). The pile fills about 90% of the width.
- Content:
  - a big, generous pile of green cash bundles with paper bands;
  - a few gold coins scattered in front;
  - same palette as the pack cash stack (`rbxassetid://112931960147028`),
    but much bigger and richer;
  - thick dark outline;
  - a white gloss on the top bundles.

### After uploading

Paste the 5 ids into `src/shared/Config/RewardUiConfig.luau`. Then preview
both screens in Studio with the debug commands listed in
`docs/handoff-parts/round3-ui-rewards.md`:

- `rewardsUiDaily "<you>" grand`
- `rewardsUiOffline "<you>"`

Check that nothing is cropped and that the rays turn without a visible edge.

## Gameplay: gadget stand and gadget icons

Area: round3-gameplay. Everything here is **optional**. The game already
works with code-built placeholders, and each asset can be done on its own.

These assets are for the three consumable heist gadgets. Players buy them
with in-game Cash and use them from hotbar keys 3-5:

- **Smoke Bomb** (`Smoke`)
- **Laser Jammer** (`Jammer`)
- **Grappling Hook** (`Grapple`)

All ids go in `src/shared/Config/GadgetConfig.luau`, under
`GadgetConfig.Gadgets.<Key>`. Use the image id (`rbxassetid://<id>`), not
the decal id. `"rbxassetid://0"` means "not made yet".

### 1. Bigger gadget icons (3 images; supersedes gadgets-patrols §2)

The icons now appear in three places:

- the hotbar, at 58-66 px, which is also shown while the player is carrying
  loot, above the DROP button;
- the Shop panel's GADGETS cards;
- the new lobby "Gadgets" window, where the cards are larger (about
  120-160 px of icon).

Draw them so they read at both sizes.

- **Size:** 512 x 512 PNG, transparent background. The subject fills about
  84% (8% padding), at a slight 3/4 angle.
- **Style:** match the purchased UI pack:
  - glossy cartoon look;
  - a thick dark outline, about 16 px at 512 (#141024 to #1A1A22);
  - bright two-tone gradients;
  - one soft white highlight at the top left;
  - a small drop shadow straight down.
  - Pack references: cash stack `rbxassetid://112931960147028`, shop crate
    `rbxassetid://109523362330544`.
- **Content:**
  - `Smoke`: a round gunmetal bomb with a pale band and a lit fuse. A BIG
    billowing grey smoke cloud bursts out behind it and fills about 40% of
    the frame; the smoke is now a large, dense cloud in game.
  - `Jammer`: a dark-blue handheld device with a glowing cyan screen and an
    antenna. A cyan lightning zig-zag cuts a red laser line.
  - `Grapple`: a wooden-grip hook launcher, with the three-prong brass hook
    flying out on a rope trailing to the top right. It suggests long reach;
    the range is now 80 studs.
- **Where to put the id:** `icon` for each key. It is used as the Tool's
  TextureId and as the card art in `GadgetShopController` and
  `GadgetStoreController`.

### 2. Lobby gadget stand (1 model, optional)

The stand is built from parts at runtime by `GadgetStoreService`: a 16-stud
market stall with a cyan/white striped awning and a "GADGETS" board, and
three pedestals on the counter showing the gadget models, which spin. A
dedicated model would make it look hand-made.

- **Style:** stylised realism like the museum loot, with a
  "black-market gadget kiosk" feel:
  - dark navy panels and brushed steel posts;
  - thin cyan neon trim along the counter front;
  - a striped cyan/white fabric awning with a scalloped edge;
  - a blank board frame on top of the awning. The code draws the
    "GADGETS" text; do **not** bake text into the model.
- **Size:** 16 studs wide (X) x about 12 studs to the awning lip (Y) x 9
  studs deep (Z), plus the awning overhanging about 2.5 studs at the front.
- **Orientation:** the counter faces **-Z** (the model's LookVector). The
  origin is at floor level, in the centre of the footprint.
- **Counter:** the counter top is at Y = 3.6, near the front
  (Z ≈ -3.4 from the centre). Leave three empty spots on it at
  X = -4.6, 0 and +4.6; the code places the pedestals and spinning gadget
  models there.
- **Budget:** under 6,000 triangles in total, with one or two 1024 textures.
- **Collision:** the counter, posts and back wall collide; the awning and
  decoration do not (CanCollide off).
- **Delivery:** a Model named `GadgetStand` in `ServerStorage.GameAssets`.
  Then tell the lead. `GadgetStoreService.build` currently always builds
  from parts, so a small code change is needed to clone this model instead
  and to hang the board SurfaceGui, the prompt anchor (in front of the
  counter, 3 studs up) and the sign anchor on it.

### 3. Smoke puff texture (optional, supersedes gadgets-patrols §3a)

- **Size:** 512 x 512, greyscale on transparent.
- **Content:** one dense, cartoon cumulus puff. It is mostly opaque in the
  middle with a soft 15% feathered edge, and has no hard outline. Its edges
  must look fine when the puff is rotated.
- **Use:** the new cloud draws 40-100 of these at up to 27 studs across, so
  a dense puff matters more than detail.
- **Where to put the id:** `GadgetConfig.SMOKE_TEXTURE`. The current value
  is `rbxasset://textures/particles/smoke_main.dds`.
