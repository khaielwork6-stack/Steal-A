# Codex prompt: retention pass art (quests + Season 1 "Museum Heist")

You are making 2D UI art for the Roblox game "Steal & Run!" (a cartoon museum
heist: players steal sealed glowing containers from 12 themed museum zones past
lasers and sleepy guards, then reveal them at home). Upload each image to Roblox
as an Image asset and paste the resulting `rbxassetid://<id>` into the exact
config key given. Leave every other value alone. A key that stays
`"rbxassetid://0"` means "no art", and the game draws a text or pack fallback.

**House style (all assets).** Match the purchased UI pack already in the game:
glossy cartoon, a thick dark outline (about 6-8% of the icon size, near-black
navy #14141E), bright saturated gradients with a light top highlight, a soft
inner shadow, and no text unless stated. Use a transparent background (PNG),
keep the subject centred with about 8% padding, and make it readable at 40 px.

## 1. Quests HUD icon
- **Used in:** the "QUESTS" button in the top-right HUD strip (cloned from the BASE button). The icon sits on a purple gradient plate (#9646E6 to #501E8C).
- **Size:** 512x512, square.
- **Subject:** a rolled parchment checklist with two ticked boxes and a gold star badge in the corner. The paper is cream, the ticks are green and the star is gold.
- **Put the id in:** `src/shared/Config/QuestConfig.luau` -> `QuestConfig.HUD_ICON`.

## 2. Season pass banner (Season 1 "Museum Heist")
- **Used in:** the top of the SEASON PASS tab. It is drawn full-width behind white text on the LEFT half (season name, timer, tier, XP bar) and a "BUY PREMIUM" button on the RIGHT.
- **Size:** 1600x480 (10:3), cropped to fill the banner. Keep the important art in the middle 80% horizontally.
- **Scene:** a night-time museum hall in violet and blue (#7846C8 to #28185A). Show a glass display case with a glowing mystery container, crossing red laser beams, and a sleepy guard silhouette with a flashlight on the right side. Scatter gold coins and sparkles.
- **Composition:** keep the LEFT ~55% darker and low-detail, because text goes there. No text in the image.
- **Put the id in:** `src/shared/Config/SeasonPassConfig.luau` -> `SeasonPassConfig.BANNER_IMAGE`.

## 3. Premium badge and lock icon
- **Premium badge**
  - **Size:** 256x256.
  - **Subject:** a gold crown on a purple gem shield, with a glossy highlight.
  - **Used in:** the left edge of the BUY PREMIUM button.
  - **Put the id in:** `SeasonPassConfig.PREMIUM_BADGE_IMAGE`.
- **Lock**
  - **Size:** 256x256.
  - **Subject:** a chunky gold padlock with a purple keyhole.
  - **Used in:** the top-right corner of locked premium reward cells, at about 30% of the cell.
  - **Put the id in:** `SeasonPassConfig.LOCK_IMAGE`.

## 4. Tier reward icons
- **Size:** 256x256 each.
- **Where they are shown:** at the top of each tier cell, at about 40% of the cell width. The cells are dark (locked), green (claimable) or grey (claimed), so each icon needs its own outline to read on all three.
- **Where the ids go:** `src/shared/Config/SeasonPassConfig.luau`. Tier rewards are built by the helper functions `cash()`, `speed()`, `title()`, `guardian()` and `trail()`. Each helper returns `icon = "rbxassetid://0"`.
  - Make one icon per KIND.
  - Replace `"rbxassetid://0"` inside that helper, so every tier of the kind uses the new icon.

| Kind | Subject | Helper |
|---|---|---|
| cash | a stack of green cash with gold coins | `cash()` |
| speed | a blue lightning-bolt sneaker | `speed()` |
| title | a gold name-plate ribbon, left blank | `title()` |
| guardian | a paw print on a shield | `guardian()` |
| trail | a rainbow comet streak (season-exclusive look) | `trail()` |

## 5. Quest type icons
- **Size:** 256x256 each.
- **Where they are shown:** on quest cards (the pack's product card, in its icon slot).
- **Where the ids go:** `src/shared/Config/QuestConfig.luau` -> `QuestConfig.Icons.<key>`.

| Key | Subject |
|---|---|
| steal | a gloved hand grabbing a glowing mystery box |
| escape | a running sneaker leaving a dust cloud, with a red siren light |
| reveal | a mystery box bursting open with sparkles |
| train | a small treadmill with speed lines |
| earn | a gold coin with a "$" (the only icon allowed a glyph) |
| bat | a wooden baseball bat with an impact star |
| trap | a round spring trap with teeth |
| discover | an open book (catalogue) with a magnifying glass |
| spin | a colourful prize wheel |

After uploading, check that each id loads in Studio: set it as an ImageLabel's `Image`.
