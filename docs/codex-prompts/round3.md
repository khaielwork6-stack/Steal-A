# Codex prompts: round 3

You are making art for the Roblox game "Steal & Run!", a cartoon museum-heist
game. Upload each asset to Roblox and paste the resulting asset id where it
says, as `"rbxassetid://<id>"`. Do not change anything else in the code.
Other areas may add their own sections to this file; keep them.

## Upgrades BASE tab & Settings

**2D style (all rows below).** Match the purchased UI pack:
- glossy cartoon look with a thick dark outline (about 6-8 px at 512 px);
- bright top-to-bottom gradients, a soft inner highlight and a light sparkle;
- PNG; transparent background unless a row says "full-bleed";
- no text in the image.

While an id is `rbxassetid://0` the game draws a placeholder, so these can be
done in any order.

### 1. Theme card previews (8 images, full-bleed)
These replace the size asked for in `fusion-autoreveal-bases.md` section 3:
the themes are now shown as wide cards, not rows.
- **Used in.** Upgrades > BASE > THEMES: the picture at the top of each
  theme card. It is drawn with `ScaleType = Crop` into a box between 2:1 and
  3:1 wide, so keep everything important inside the middle 60% of the width.
- **Size.** 768x384 (2:1), full-bleed (no transparency, no rounded corners;
  the game rounds and outlines it).
- **Look.** A 3/4 view of one corner of a player's base plot in that theme: the
  floor, a short fence with posts and rails, a glowing accent strip on the
  post caps, one stone display pedestal in the middle with a small glowing
  mystery orb on it, and the theme's decor on the gate posts. The colours
  must match the theme's values in `src/shared/Config/BaseThemeConfig.luau`
  (`floorColor`, `fenceColor`, `railColor`, `accentColor`, `decor`).
  - Classic: bright green grass plot, dark grey fence, white rails, cyan accents.
  - Sunset: warm sandstone floor, terracotta fence, orange lanterns, dusk sky.
  - Midnight: dark slate floor, navy fence, cyan beacons, night sky.
  - Jungle: mossy grass and old cobblestone, stone totems, vines.
  - Frost: glacier-blue ice floor, white ice fence, ice crystals.
  - Lava: black basalt, glowing orange cracks and braziers.
  - NeonNight: black glass floor, magenta neon, cyan orbs, synthwave glow.
  - RoyalGold: white marble floor, gold fence, gold crown ornaments.
- **Where the id goes.** `src/shared/Config/BaseThemeConfig.luau`,
  `THEMES[<row with key = "...">].thumbnail` for the keys Classic, Sunset,
  Midnight, Jungle, Frost, Lava, NeonNight, RoyalGold.

### 2. Pedestal skin card previews (5 images, full-bleed)
These replace the size asked for in `fusion-autoreveal-bases.md` section 4.
- **Used in.** Upgrades > BASE > PEDESTAL SKINS: the picture at the top of
  each (smaller) card, drawn with `ScaleType = Crop` into a box of about 2:1.
- **Size.** 512x256 (2:1), full-bleed.
- **Look.** One museum display pedestal (a short round column with a wider
  cap and base), centred, under a soft spotlight on a dark blue studio
  background, with a small purple glowing orb on top. Material per key:
  - Default: pale grey museum stone.
  - Marble: white marble with a gold trim ring.
  - Obsidian: black glassy stone with a purple neon trim ring.
  - GoldPlinth: solid polished gold with a white trim ring.
  - Crystal: translucent pale-blue crystal with a cyan neon trim ring.
- **Where the id goes.** `src/shared/Config/BaseThemeConfig.luau`,
  `PEDESTALS[<row with key = "...">].thumbnail` for the keys Default, Marble,
  Obsidian, GoldPlinth, Crystal.

### 3. Upgrades tab icons (2 images)
- **Used in.** The two large tab buttons at the top of the Upgrades panel,
  left of the words TREADMILL and BASE (shown at about 32-48 px).
- **Size.** 256x256, transparent background, the subject filling ~85%.
- **Look.**
  - TabTreadmill: a chunky cartoon treadmill seen from the side with a
    motion swoosh and a small up arrow (speed training).
  - TabBase: a tiny cartoon plot: a green square of grass with a short
    fence, a flag and one pedestal (a "home base").
- **Where the id goes.** `src/shared/Config/BaseThemeConfig.luau`,
  `BaseThemeConfig.UiIcons.TabTreadmill` and `BaseThemeConfig.UiIcons.TabBase`.
  (Until then TREADMILL uses the pack's upgrade arrow and BASE a drawn plot.)

### 4. BASE page section icons (2 images)
- **Used in.** Left of the THEMES and PEDESTAL SKINS headers (about 28 px).
- **Size.** 128x128, transparent background.
- **Look.**
  - SectionThemes: a paint roller over a small house outline, gold and teal.
  - SectionPedestals: a small gold-rimmed display pedestal with a sparkle.
- **Where the id goes.** `src/shared/Config/BaseThemeConfig.luau`,
  `BaseThemeConfig.UiIcons.SectionThemes` and
  `BaseThemeConfig.UiIcons.SectionPedestals`.

### 5. CODES icon (1 image)
Same asset as `retention-codes-daily.md` asks for; skip if that id is already
pasted.
- **Used in.** Settings panel, the pinned CODES bar, left of the word CODES
  (about 40-56 px).
- **Size.** 256x256, transparent background.
- **Look.** A red gift box with a gold ribbon and bow and a small gold ticket
  sticking out of the lid.
- **Where the id goes.** `src/shared/Config/CodesConfig.luau`,
  `CodesConfig.HEADER_ICON`.
