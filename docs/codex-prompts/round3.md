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
