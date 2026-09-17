# Codex prompt: loading screen, logo, tip icons, event banners (polish-events-analytics)

Make the images below for the Roblox game "Steal & Run!", a cartoon museum
heist game. In the game, players sneak into a grand museum and grab sealed
glowing mystery containers from glass display cases. They dodge red laser
beams and sleepy security guards, then run home to reveal the loot.

Upload each image as a Roblox Decal/Image. Then write its **image** id
(`rbxassetid://<id>`) into the config key given for it. If Roblox gives you a
decal id, convert it to the image id first.

Every key starts as `rbxassetid://0`. While a key is 0, the game draws a
fallback: a gradient, the title as text, or no icon at all. Nothing breaks
if an image is missing.

## Style (all assets)

- **Match the UI pack the HUD already uses.** Glossy cartoon style, thick
  dark outlines (#141008 to #1A1A22), bright two-tone gradients, one soft
  white highlight, and a small drop shadow straight down.
- **Reference pack icons:**
  - cash `rbxassetid://112931960147028`
  - speed arrow `rbxassetid://102080723305863`
  - shop crate `rbxassetid://109523362330544`
- **Palette.** Museum marble and gold, deep violet night (#261C56 to
  #0C0A1E), laser red #FF3040, loot glow gold #FFD040.
- **No real brands, logos or real people.**

## 1. Loading screen background, wide (16:9)

- **Used in:** the full-screen loading backdrop on desktop, tablets and
  landscape phones. It is cropped to fill the screen, and the bottom 45% is
  darkened for the tip text.
- **Size:** 1920 x 1080 PNG, no transparency.
- **Scene:** night interior of a grand cartoon museum hall, seen down the
  central corridor.
  - Marble columns, velvet rope lines and glass display cases, each holding
    a glowing sealed mystery container (gold, purple and cyan glows).
  - Red laser beams criss-cross the floor.
  - A chubby cartoon guard dozes on a stool in the mid-ground, with a "Zzz"
    bubble.
  - A small hooded cartoon thief sprints toward the camera, hugging a
    glowing container.
- **Composition:**
  - Keep the centre band (about 25-55% of the height) calm and low-detail.
    The title and progress bar sit there.
  - Put the busy detail in the left and right thirds.
  - No text.
- **Write to:** `src/first/LoadingConfig.luau` ->
  `LoadingConfig.BACKGROUND_WIDE`.

## 2. Loading screen background, tall (9:16)

- **Used in:** the same backdrop, for phones held in portrait. Everything
  else is the same as asset 1.
- **Size:** 1080 x 1920 PNG.
- **Scene:** the same scene, recomposed vertically.
  - The thief and container go in the lower-middle.
  - The guard goes near the top.
  - Lasers cross the lower third.
  - Keep 30-55% of the height calm.
- **Write to:** `src/first/LoadingConfig.luau` ->
  `LoadingConfig.BACKGROUND_TALL`.

## 3. Game logo

- **Used in:** the centre of the loading screen, drawn at up to 560 x 210 px
  (scale fit), over both backgrounds.
- **Size:** 1600 x 600 PNG with a transparent background.
- **Content:**
  - The words **STEAL & RUN!** in a chunky, rounded, slightly italic cartoon
    display font.
  - Gold-to-orange vertical gradient fill (#FFF096 to #FFA028) with a very
    thick dark outline and a 3D bevel/extrude.
  - The "&" is a small glowing mystery container, or a red laser line
    crosses behind the letters.
  - A couple of motion streaks behind "RUN!".
  - Readable at 280 px wide.
- **Write to:** `src/first/LoadingConfig.luau` -> `LoadingConfig.LOGO`.

## 4-11. Loading tip icons (8 icons)

- **Used in:** left of the rotating tip text on the loading screen, at 64 px.
- **Size:** 512 x 512 PNG, transparent background. The subject fills about
  88% of the canvas. No text.
- **Write to:** `src/first/LoadingConfig.luau` -> `LoadingConfig.TIPS`. Set
  the `icon` field of each tip listed below. The tips are numbered in list
  order, starting at 1.

| # | Icon | Subject | Tips that use it |
|---|------|---------|------------------|
| 4 | Laser | two crossing red laser beams with small emitter nubs | 1, 2 |
| 5 | Crouch | a small cartoon figure ducking low under a red beam | 3 |
| 6 | Guard | a sleeping cartoon security guard head with a cap and "Z" | 4, 6 |
| 7 | Doorway | a museum doorway arch with a green "go" glow | 5 |
| 8 | Moon | a crescent moon over a tiny museum roof, violet | 7 |
| 9 | Container | a sealed glowing gold mystery container with a timer ring | 8, 9 |
| 10 | Treadmill / trail | a speed shoe with a rainbow trail streak | 10, 11 |
| 11 | Gift code | a ticket or coupon with a gift bow | 12, 13, 14 |

## 12-15. Event banner art (4 images)

- **Used in:** two places.
  - The event pill on the HUD: a 26 px icon on the left.
  - The "EVENT IS ON!" announcement card at the top of the screen: a 64 px
    icon on the left.
- **Size:** 512 x 512 PNG, transparent background. One strong, simple
  silhouette that still reads at 26 px. No text.
- **Write to:** `src/shared/Config/EventConfig.luau` ->
  `EventConfig.Events`. Set the `icon` field of the entry with the given
  `key`.

| # | Event (`key`) | Subject | Colours |
|---|---------------|---------|---------|
| 12 | Mutation Weekend (`MutationWeekend`) | a mystery container bursting with a swirl of shiny/golden/flaming sparkles, "x2" shaped sparkle | magenta #FF78E6 to violet |
| 13 | Night Rush (`NightRush`) | a crescent moon with a stopwatch face and speed lines | violet #966EFF with gold hands |
| 14 | Halloween (`Halloween`) | a jack-o'-lantern wearing a tiny museum guard cap | orange #FF8C28, purple shadow |
| 15 | Winter Festival (`Winter`) | a snow-capped mystery container with a red ribbon and snowflakes | ice blue #78D2FF, white, red ribbon |

## Checklist

- 15 images uploaded (3 + 8 + 4). 21 keys filled: 3 loading keys, all 14
  tip `icon` fields (tips that share an icon reuse its id), and 4 event
  `icon` fields.
- Ids are `rbxassetid://<number>` (image ids).
- The static check passes. `validate` rejects any other id format.
