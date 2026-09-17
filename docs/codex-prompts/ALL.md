# Codex: all art for the 2026-09-17 feature pass (Steal & Run!)

You are producing the ART for eight new features that are already coded and
working with placeholders. Every asset below has an exact config key; the game
shows a text/colour placeholder while that key is `rbxassetid://0` (or `""` /
`0`), so each asset you deliver lights up on its own.

## Before you start
1. `git pull` (branch `master`, repo https://github.com/khaielwork6-stack/Steal-A.git).
2. Read `docs/START_HERE.md` and `docs/AGENT_RULES.md` (rule 3 on line endings:
   preserve each file's endings, never `sed -i`; rule 10: out-of-scope list).
3. The place is **Steal & Run!** (placeId 134344354476234), owned by group
   3774675. Upload every Image/Mesh/Model so the GROUP owns it (not a personal
   account), or the live game cannot load it.
4. Do NOT change gameplay code or numbers. Only paste asset ids into the keys
   named below (and add models under the ServerStorage paths named below).
5. Style for all UI art: match the purchased UI pack in `StarterGui.MainUI`
   (glossy cartoon, thick dark outline ~6% of width, bright top-to-bottom
   gradients, soft top highlight, small drop shadow, transparent PNG, no text
   unless the entry says so). 3D art: match the museum loot in
   `ServerStorage.GameAssets.Loot` (stylised realism, clean silhouettes,
   PBR-ish materials, low-to-mid poly, no tiny detail that vanishes on phones).
6. Never use Roblox logos/trademarks (e.g. the Premium icon).

## Order of work (most visible first)
1. HUD button icons (Daily, Quests, Invite, Trade, Crew) and the loading screen.
2. Badge images (they must exist before the owner creates the 23 badges).
3. Panel art (daily cards, quest/pass banners, trade window, fusion machine,
   theme thumbnails).
4. 3D: gadget meshes, vault door + decor + Vault Guardian costume, theme decor.
5. Event banners and tip icons.

## When you finish
- Run `bash tools/check.sh` (hard errors must stay empty) and `selene src`.
- Commit with a clear message and push to `master`.
- Reply with a table: asset name -> asset id -> config key, plus anything you
  could not make (leave its key at the placeholder).
- Remind the owner to Save & Publish the place in Studio for anything placed
  under ServerStorage.

---


<!-- ===================== retention-codes-daily ===================== -->

# Codex prompt: Daily Rewards + Codes icons (retention-codes-daily)

Make 9 flat 2D UI icons for the Roblox game "Steal & Run!", a cartoon museum
heist game. Upload each one as a Roblox Decal/Image. Then write each asset id
into the config key given for that icon. Use the image id
(`rbxassetid://<id>`), not the decal id. If Roblox hands you a decal id,
convert it to the image id first.

## Style (all icons)

- Match the purchased UI pack the HUD already uses: glossy cartoon, a thick
  dark outline (about 6-8% of the icon width, colour #141008 to #1A1A22),
  bright two-tone vertical gradients, one soft white highlight at the top
  left, and a small drop shadow straight down.
- For reference, look at the existing pack icons in the place:
  - cash stack: `rbxassetid://112931960147028`
  - speed arrow: `rbxassetid://102080723305863`
  - shop crate: `rbxassetid://109523362330544`
  - gear: `rbxassetid://127441972943624`

  New icons must sit beside these without looking foreign.
- Transparent background (PNG with alpha). The subject is centred and fills
  about 88% of the canvas. No text, no numbers (the one exception is icon 1),
  no borders or plates behind the subject. The UI draws its own card and
  button behind each icon.
- Square, 512 x 512 px.

## 1. Daily HUD button icon

- **Used in:** the round orange/gold "Daily" button in the top-right HUD
  strip, left of the Settings gear. It is drawn at about 34 px inside a
  44 px circle with an orange gradient (#FFD25A to #F0821E), so the icon
  must read at that size against orange.
- **Subject:** a cartoon tear-off calendar page with a red top binding and a
  big gold star on the page, plus a small gift bow at one corner. White or
  cream page with a heavy outline. A bold "7" in place of the star is also
  acceptable.
- **Write to:** `src/shared/Config/DailyRewardConfig.luau` ->
  `DailyRewardConfig.HUD_ICON = "rbxassetid://<id>"`.
  While the value is `rbxassetid://0`, the button shows a text "7" instead.

## 2-8. Seven day-card reward icons

- **Used in:** the Daily Rewards panel (a clone of the Index panel). There
  are seven product cards in a 4 + 3 grid. Each icon fills the card's icon
  slot, about 90-140 px on screen. The cards are tinted:
  - Cash days: green (#60F096 to #167846)
  - Speed days: blue (#78C8FF to #1E5ABE)
  - Guardian day: purple (#D7A0FF to #6E32BE)

  Icons must keep strong contrast against their card colour.
- **Escalation:** each day's icon is a little "bigger" and richer than the
  one before, so the week reads as a climb.

| Key | Day | Reward | Subject |
|---|---|---|---|
| `DailyRewardConfig.Days[1].icon` | Day 1 | Cash | a small stack of 2-3 green banknotes |
| `DailyRewardConfig.Days[2].icon` | Day 2 | Speed | one lightning-bolt sneaker (blue/white) with 2 speed lines |
| `DailyRewardConfig.Days[3].icon` | Day 3 | Cash | a thicker cash stack with a paper band and 2 gold coins |
| `DailyRewardConfig.Days[4].icon` | Day 4 | Speed | a winged sneaker with 3 speed lines and a small lightning bolt |
| `DailyRewardConfig.Days[5].icon` | Day 5 | Cash | an open money bag (green, "$" embossed shape, no letters) spilling coins and notes |
| `DailyRewardConfig.Days[6].icon` | Day 6 | Speed | a glowing blue lightning bolt over a winged sneaker, with sparkles |
| `DailyRewardConfig.Days[7].icon` | Day 7 | Guardian | a cute chubby cartoon panda head (the Panda base guardian) in front of a purple shield with a gold rim and sparkles |

- **Write to:** `src/shared/Config/DailyRewardConfig.luau`, in the
  `DailyRewardConfig.Days` table. Replace the `icon = "rbxassetid://0"` value
  on the row with the matching `day = N`.
  While a value is `rbxassetid://0`, the card falls back to the pack's cash,
  speed or shop icon.

## 9. Codes section header icon

- **Used in:** the CODES row at the top of the Settings panel. It sits just
  left of the "CODES" title, drawn at about 28-36 px on a dark navy row
  (#10162C).
- **Subject:** a gold ticket/coupon with notched edges and a small key or
  sparkle on it. It should read as "redeem a code". Use a gold gradient
  (#FFE278 to #FF9628) with a dark outline.
- **Write to:** `src/shared/Config/CodesConfig.luau` ->
  `CodesConfig.HEADER_ICON = "rbxassetid://<id>"`.
  While the value is `rbxassetid://0`, no icon is drawn.

## When done

- Change only the config values listed above. Nothing else in those files.
- Check that each id loads: paste it into an ImageLabel in Studio and confirm
  it isn't pending moderation.
- In Play:
  - Open the Daily panel from the top-right button. All seven cards show
    their icon, and the HUD button shows the calendar.
  - Open Settings. The CODES row shows the ticket beside its title, and the
    icon doesn't cover the title text. If it does, report back; don't move
    the title.


<!-- ===================== retention-quests-pass ===================== -->

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


<!-- ===================== social ===================== -->

# Codex prompts: social pass (invite, boosts, announcement, badges)

Game: **Steal & Run!**, a cartoon museum-heist game on Roblox. Players steal
sealed containers from 12 themed zones, carry them home and reveal them in a
casino-style roulette.

Match the purchased UI pack in `StarterGui.MainUI`: glossy cartoon shapes, a
thick dark outline (about 6% of the width), bright top-to-bottom gradients, a
soft inner highlight on the top edge and a small drop shadow. Use a transparent
background. No text unless stated. Export PNG.

Every UI image below is uploaded as an **Image** asset. Paste the resulting
`rbxassetid://<id>` into the config key given. A key left at
`"rbxassetid://0"` keeps the text-only placeholder, so the game works before
the art exists.

---

## 1. UI assets

### 1.1 Invite HUD icon
- **Used in:** the round green Invite button in the top bar, next to the
  Settings gear (`SocialController.buildInviteButton`). It is drawn at about
  31 px inside a 44 px green circle, and an "INVITE" caption is added in code.
- **Size:** 256x256, square, transparent. Keep the artwork inside the central
  80%.
- **Design:** a white person silhouette with a bold "+" badge at its
  upper right. White fill, dark green outline (#0A3C1E), and a slight glossy
  highlight. It must read clearly on the green (#28BE6E) circle.
- **Put the id in:** `src/shared/Config/SocialConfig.luau` →
  `SocialConfig.INVITE_ICON`

### 1.2 Friends boost pill icon
- **Used in:** the green "+20% FRIENDS" pill above the Cash/Speed card, at
  20x20 px.
- **Size:** 128x128, square, transparent.
- **Design:** two overlapping cartoon heads, one slightly in front, with a
  small upward arrow. White with a dark outline, readable on green (#28AA5A).
- **Put the id in:** `SocialConfig.FRIENDS_PILL_ICON`

### 1.3 Premium boost pill icon
- **Used in:** the gold "PREMIUM +10%" pill, at 20x20 px.
- **Size:** 128x128, square, transparent.
- **Design:** a generic glossy gold coin with a small upward arrow. Do NOT
  copy Roblox's Premium logo or any other Roblox trademark.
- **Put the id in:** `SocialConfig.PREMIUM_PILL_ICON`

### 1.4 Reveal announcement banner frame
- **Used in:** the banner at the top centre of the screen: "Name pulled a
  DIVINE Private Jet!". It is drawn as a 9-slice
  (`SliceCenter = Rect(64, 64, 448, 448)`) and stretched to about 640x56 px.
  The text is drawn in code on top of it.
- **Size:** 512x512, transparent. Put the 9-slice corners in the outer 64 px.
  The centre area must be a flat, dark, slightly translucent navy (#0E1020 at
  about 90%) so white text stays readable.
- **Design:** a rounded ribbon plate with a thick dark outline and a thin
  gold inner trim. Add small sparkle accents in the corners only (they must
  survive stretching). Keep the whole frame neutral, because the game adds a
  rarity-coloured stroke around it.
- **Put the id in:** `SocialConfig.ANNOUNCE_FRAME_IMAGE`

---

## 2. Badge images (23)

Roblox badge icons are uploaded on the **Creator Dashboard** when the badge is
created (Experience → Engagement → Badges → Create). They are not
`rbxassetid` values in code.

- **Deliverable:** 23 PNG files, **512x512**, one per badge, named
  `badge_<Key>.png`. Save them to `art/badges/` in the project, or wherever
  the owner collects uploads.
- **Circle-safe:** Roblox crops badges to a circle. Keep every important
  element inside the central circle, 460 px across.
- **Style:** one consistent medal family. Use a round emblem with a thick dark
  outline and a glossy rim, with the subject centred and cartoon-rendered like
  the museum loot art. There is no text on any badge, except the numbers where
  noted.
- **Rim colour (tier):**
  - bronze: first-time badges
  - silver: milestones
  - gold: completion and top tier
  - zone colour: zone badges (use the hex values given below)
- **After creating each badge:** paste its id into
  `src/shared/Config/BadgeConfig.luau`:
  - zone badges go in `ZONE_BADGE_IDS[n]`;
  - all other badges go in the `id` of the row with the same `key`.

| # | Key (file name) | Badge name | Theme / subject | Rim |
|---|---|---|---|---|
| 1 | FirstSteal | Sticky Fingers | A gloved hand lifting a glowing sealed crate off a museum pedestal | bronze |
| 2 | FirstEscape | Clean Getaway | A running cartoon thief with a crate, crossing a red finish line, with speed lines | bronze |
| 3 | FirstReveal | What's Inside? | A crate bursting open with light and confetti; a question mark in the glow | bronze |
| 4 | FirstMythicReveal | Myth Maker | The burst-open crate with a red (#FF4E4E) glowing silhouette rising out | silver |
| 5 | FirstSecretReveal | Top Secret | A pink (#FF4A8C) glowing crate stamped with a keyhole and a "classified" ribbon (no words) | gold |
| 6 | IndexZoneComplete | Curator | An open collection book with 8 filled slots and a check mark | silver |
| 7 | IndexComplete | Master Curator | A golden book with a crown on top, radiating light | gold |
| 8 | Steals100 | Career Thief | A money-bag-shaped loot sack with a large "100" | silver |
| 9 | Steals1000 | Legendary Thief | A heap of crates with a large "1000" and a star | gold |
| 10 | FirstHeist | Base Raider | A cartoon mask over a small house with a stolen trophy | bronze |
| 11 | Streak7 | Regular | A calendar page with 7 flame ticks and a large "7" | silver |
| 12 | Zone01 | Zone 1 Explorer | Classic museum: a columned building with a vase | zone #D6BE8C |
| 13 | Zone02 | Zone 2 Explorer | Pirate Island: an anchor, a treasure chest and a palm tree | zone #50BEEB |
| 14 | Zone03 | Zone 3 Explorer | Castle: towers with a crown | zone #BEA0FF |
| 15 | Zone04 | Zone 4 Explorer | Area 51: a flying saucer over a desert fence | zone #78FF96 |
| 16 | Zone05 | Zone 5 Explorer | North Pole: a present with snowflakes and candy canes | zone #96DCFF |
| 17 | Zone06 | Zone 6 Explorer | Ancient Egypt: a pyramid with a golden scarab | zone #FFC850 |
| 18 | Zone07 | Zone 7 Explorer | Gym: a dumbbell and a trophy belt | zone #6EEB6E |
| 19 | Zone08 | Zone 8 Explorer | Bank: a vault door and gold bars | zone #FFDC5A |
| 20 | Zone09 | Zone 9 Explorer | Secret Lab: a bubbling flask and a glowing crystal | zone #78FFF0 |
| 21 | Zone10 | Zone 10 Explorer | Grandma's House: a cookie jar and a knitted heart | zone #FFBE96 |
| 22 | Zone11 | Zone 11 Explorer | Construction Site: a hard hat, a crane and cones | zone #FFA53C |
| 23 | Zone12 | Zone 12 Explorer | Airport: a jet taking off over a runway | zone #96C8FF |

Also return a short list mapping each file name to its key, so the owner can
upload them in order.


<!-- ===================== trading-gifting-boards ===================== -->

# Codex prompt: trading, gifting and leaderboard art

You are making UI images for the Roblox game "Steal & Run!" and uploading them
to Roblox. Every asset below is optional: the game already works with text
placeholders, and each one only appears once its id is pasted into the config
key named for it. Paste ids in the form `"rbxassetid://<number>"`.

## Style (all assets)

Match the purchased UI pack that is already in the game:
- glossy cartoon look with bright gradients;
- a thick dark outline (about 6-8% of the icon size) around every shape;
- a soft top highlight;
- no text unless the asset says so;
- transparent background (PNG with alpha);
- icons centred, with about 8% padding.

The HUD menu buttons (Shop = red/pink crate, Index = blue book, Storage =
orange chest, Upgrades = green arrow) are the reference for colour and weight.

## 1. Trade button icon
- **Name:** `TradeIcon`
- **Used on:** the purple "Trade" HUD button in the left menu rail, drawn over the
  pack's studded plate.
- **Size:** 512 x 512, square.
- **Content:** two chunky curved arrows chasing each other in a circle (a
  swap). One arrow is gold, the other is white-lilac. It must read clearly at
  48 px.
- **Paste into:** `src/shared/Config/TradeConfig.luau`, key `TradeConfig.Icons.Trade`.

## 2. Trade window header badge
- **Name:** `TradeHeader`
- **Used on:** the icon slot in the header bar of the Trade panel and the trade
  window, next to the title "Trade".
- **Size:** 512 x 512, square.
- **Content:** two cartoon hands shaking over a small gold coin, in purple and
  gold tones.
- **Paste into:** `TradeConfig.Icons.TradeHeader` (same file).

## 3. Ready check
- **Name:** `TradeReady`
- **Used on:** a player's side of the trade window once they press READY.
- **Size:** 256 x 256, square.
- **Content:** a green rounded badge with a bold white check mark.
- **Paste into:** `TradeConfig.Icons.Ready` (same file).
- **Note for the lead:** the window currently shows the text "READY ✓". The
  icon is reserved for a later polish pass.

## 4. Gift icon
- **Name:** `GiftIcon`
- **Used on:**
  - the "GIFT TO: <name>" picker button in the Shop's GIFT A FRIEND section;
  - the icon slot of every gift pack card.
- **Size:** 512 x 512, square.
- **Content:** a pink present box with a gold ribbon and bow, with a few
  sparkles around it.
- **Paste into:** `TradeConfig.Icons.Gift` (same file).

## 5. Leaderboard header plates (optional)

The four new world boards are clones of the pack's `Leaderboard Money` board.
The script builds a flat header plate above each board, about 2.2 studs tall
and as wide as the board, and writes the title on it in text. A painted title
replaces that text when you provide one.

For each plate:
- **Size:** 1024 x 256 (4:1), transparent background.
- **Content:** the title text below in a bold rounded cartoon font, white with
  a thick dark-brown outline (#28140A), plus a small themed icon on the left.
  It must be readable from 30 studs away.

| Name | Text | Icon | Paste into (`src/shared/Config/BoardConfig.luau`, `BoardConfig.Boards`) |
| --- | --- | --- | --- |
| `BoardSteals` | TOP STEALS | a sack with a $ sign | the `Steals` row, `headerImage` |
| `BoardIndex` | TOP INDEX % | an open book with a star | the `Index` row, `headerImage` |
| `BoardPlayTime` | MOST TIME PLAYED | a stopwatch | the `PlayTime` row, `headerImage` |
| `BoardWeekly` | TOP EARNERS THIS WEEK | a calendar page with a coin | the `Weekly` row, `headerImage` |

The header image is only used when the boards read the real global stores. In
Studio without API access the text header stays, so it can say "(this
server)".

## Checklist
- [ ] Upload each image as a Decal/Image.
- [ ] Use the **Image** asset id, not the Decal id.
- [ ] Paste each id into the key listed for it.
- [ ] Make no other code changes.


<!-- ===================== gadgets-patrols ===================== -->

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


<!-- ===================== vaults-crews ===================== -->

# Codex prompts: vaults and crews

Five assets. They share one style. 3D assets use the stylised realism of the
museum loot: chunky readable shapes, clean PBR (SurfaceAppearance), and no
tiny detail that a phone can't show. 2D assets match the purchased UI pack:
a glossy cartoon look, a thick dark outline (about 6% of the short side),
bright top-to-bottom gradients, a soft inner highlight, and a transparent
background (PNG).

After you upload each asset, write its id or name exactly where the asset says.
Leave every other file alone. The code skips any asset whose value is still
`rbxassetid://0` or whose model is missing, so you can deliver them in any
order.

---

## 1. Vault door (3D)

- **Name:** `VaultDoor` (a Model).
- **Place it in:** `ServerStorage.GameAssets.Vault.VaultDoor`. Create the
  `Vault` folder if it doesn't exist. The name is already set in
  `src/shared/Config/VaultConfig.luau` → `VaultConfig.Art.DoorModelName`.
- **Where it's used:** every zone vault's doorway, on the corridor side of the
  wall. `VaultBuilder` scales the model so its largest side is **26 studs**.
  It pivots the model to the door centre, with the disc's face pointing out
  of the model's **-Z (LookVector)** toward the corridor. The client then
  slides the door sideways along the model's X axis to open it.
- **Shape:** a round bank-vault door, 26 × 26 studs across and about 3 studs
  deep. Include a thick gold outer rim, a dark gunmetal face with a
  diamond-plate or brushed finish, a large centre hub with a 3-spoke gold
  wheel handle, 8 chunky bolts around the rim, and a small stylised gear/lock
  emblem. There are no hinges: the door slides aside, so hinges would look
  wrong.
- **Setup:** set the Model's PrimaryPart to the main disc and make the pivot the
  disc centre. Use 30 parts or fewer (MeshParts are fine). Every part must be
  Anchored, with CanCollide, CanQuery and CanTouch off. Include no scripts.

## 2. Vault interior decor set (3D)

- **Name:** `VaultDecor` (a Model).
- **Place it in:** `ServerStorage.GameAssets.Vault.VaultDecor`. The name is
  already set in `VaultConfig.Art.DecorModelName`.
- **Where it's used:** it is cloned into every vault, pivoted to the vault
  frame. That frame's origin sits on the floor at the door. Local +Z runs
  **into** the vault, which is **58 studs deep**. Local X runs along the
  vault's width. The narrowest vault is **35.5 studs wide**, and the inner
  wall faces are at x = ±15.75. The ceiling is at **y = 30**.
- **Contents:** keep everything against the side and back walls, inside local
  x ∈ [-15.5, -12] ∪ [12, 15.5] and z ∈ [3, 56]:
  - stacked gold bars on low pallets (2 sets)
  - 4 wall-mounted safe-deposit box panels (grids of small doors)
  - 2 money-bag piles
  - riveted steel wall plates
  - 2 red rotating alarm beacons (static meshes, no lights)
- **Keep clear:** the middle of the room (|x| < 12), the doorway strip
  (z < 3), and the laser ring. The ring is centred at z ≈ 38 with a radius of
  up to 18 studs, so keep floor props low there (height < 0.5) or leave that
  area empty.
- **Budget and setup:** 60 parts or fewer. Everything must be Anchored, with
  CanCollide, CanQuery, CanTouch and CastShadow off. Include no lights and no
  scripts.

## 3. Vault Guardian costume (3D character)

- **Names:** `VaultGuardian` as the generic costume. You can also add
  per-zone variants named `Zone07_VaultGuardian` (use the two-digit zone
  number).
- **Place them in:** `ServerStorage.GameAssets.Guardians`. The base name is
  already set in `VaultConfig.GUARDIAN.costumeName`.
- **Where it's used:** the tougher guard that sleeps inside each vault.
  `GuardianService` scales it to **18 studs tall at most**, because the vault
  door is 20 studs tall.
- **Look:** a heavy armoured security guard. Give it a dark steel riot suit
  with gold trim, a visor helmet with a glowing red visor slit, shoulder
  plates, a large keyring on the belt, and a baton. The silhouette should be
  bulkier than a museum cop.
- **Rig:** a standard **R15** rig with a Humanoid and the standard part names
  and Motor6Ds. The game plays Roblox's own walk and idle animations on it.
  Face the rig down -Z, with its feet at the bottom of its bounding box.
  Include no scripts.

## 4. Crew HUD icons (2D)

Make four square PNGs, **256 × 256**, on a transparent background, in the UI
pack's glossy style. Use a teal/aqua palette (#28BEAA to #28AAFF) for crew
items and gold (#FFD25A) for the leader.

| Key | Picture | Write the id to |
| --- | --- | --- |
| `Crew` | three friendly heads side by side, the middle one slightly forward | `src/shared/Config/CrewConfig.luau` → `CrewConfig.Icons.Crew` |
| `Leader` | a gold star on a small crown | `CrewConfig.Icons.Leader` |
| `Invite` | one head with a plus badge | `CrewConfig.Icons.Invite` |
| `Assist` | two hands high-fiving with a burst of coins | `CrewConfig.Icons.Assist` |

The `Crew` icon appears on the "CREW" button of the HUD card, inside a
56-pixel-tall button. The code already shows it once its id is set. The other
three are kept in config for later polish, and the text labels work without
them.

## 5. "Vault restocked" banner (2D)

- **Size:** a **1024 × 256** PNG (4:1) on a transparent background.
- **Where it's used:** it pops up top-centre for about 3 seconds, together
  with the server-wide toast "The Zone 7 vault has restocked!". It is shown by
  `VaultController`.
- **Look:** the words **VAULT RESTOCKED!** in chunky white cartoon letters
  with a thick dark outline and a gold-to-orange gradient fill. Place them
  over a round steel vault door on the left, with gold bars and sparkles
  bursting out. Use the UI pack's glossy style with a light inner highlight.
  Leave no text other than the title: the zone name comes from the toast.
- **Write the id to:** `src/shared/Config/VaultConfig.luau` →
  `VaultConfig.Art.RestockBanner`, as `"rbxassetid://<id>"`.


<!-- ===================== fusion-autoreveal-bases ===================== -->

# Codex prompt: fusion, Auto Reveal and base themes art

You are making art for the Roblox game "Steal & Run!", a cartoon museum-heist
game. Upload each asset to Roblox and paste the resulting asset id where it
says. Do not change anything else in the code.

**2D style.** Match the purchased UI pack:
- glossy cartoon look with a thick dark outline (about 6-8 px at 512 px);
- bright top-to-bottom gradients, a soft inner highlight and a light sparkle;
- transparent background (PNG);
- no text in the image unless a row below asks for it.

**3D style.** Stylised realism, like the museum loot:
- clean readable shapes and PBR-ish materials;
- under 2,000 triangles per prop;
- a single Model, with a PrimaryPart at the base centre and +Y up;
- every part Anchored, with CanCollide, CanTouch and CanQuery all false;
- no scripts.

Paste ids as `"rbxassetid://<id>"` unless a row says otherwise.

## 1. Fusion machine icon
- **Used in.** The fusion result popup, above "FUSION COMPLETE!".
- **Size.** 512x512, square.
- **Look.** A small glowing fusion machine:
  - a chunky metal base with two curved arms and a purple/cyan energy orb between them;
  - three tiny item silhouettes spiralling into the orb;
  - a purple-to-magenta glow.
- **Where the id goes.** `src/shared/Config/FusionConfig.luau`, `FusionConfig.ICON`.

## 2. Auto Reveal pass icon
- **Used in.** The Shop > PASSES card, and as the Game Pass thumbnail on the Creator Dashboard.
- **Size.** 512x512, square.
- **Look.**
  - A sealed mystery crate popping open by itself, with a golden clock/stopwatch badge in the corner and a small "auto" circular-arrow motif.
  - Purple and gold palette, to match the card tint `RGB(180,120,255)`.
- **Where the id goes.** `src/client/Controllers/AutoRevealPassCard.luau`, `AutoRevealPassCard.ICON`. Upload the same image as the Game Pass icon too.

## 3. Theme preview thumbnails (one per theme)
- **Used in.** Upgrades > BASE > THEMES, as a row thumbnail. The row falls back to colour swatches while the id is `rbxassetid://0`.
- **Size.** 256x256, square, with rounded corners baked in (radius about 28 px).
- **Look.** A 3/4 top-down view of a small square plot corner:
  - the floor;
  - a fence corner with two posts and a rail;
  - a glowing gate cap;
  - one display pedestal with a trophy silhouette.
- **Colours.** Use exactly the colours of each theme in `src/shared/Config/BaseThemeConfig.luau` (`floorColor`, `fenceColor`, `railColor`, `accentColor`, and the materials).
- **Where the id goes.** `BaseThemeConfig.Themes[<key>].thumbnail`.

| key | look |
|---|---|
| Classic | green grass-checker floor, dark slate posts, white rails, cyan pad glow |
| Sunset | sandstone floor, terracotta posts, cream rails, orange glowing lanterns |
| Midnight | dark slate floor, navy posts, cyan rails and a cyan beacon |
| Jungle | mossy grass floor, cobblestone posts, vine-green rails, stone totem, round bush |
| Frost | glacier-ice floor, white ice posts, pale blue rails, ice crystal |
| Lava | basalt floor, black basalt posts, molten orange rails, glowing brazier |
| NeonNight | black glass floor, magenta neon rails, magenta and cyan glowing orbs (Robux: add a small gold "R$" corner ribbon, no other text) |
| RoyalGold | white marble floor, gold foil posts, pale gold rails, golden crown ornament, marble urn (Robux: same ribbon) |

## 4. Pedestal skin thumbnails
- **Used in.** Upgrades > BASE > PEDESTALS, as a row thumbnail.
- **Size.** 256x256, square, same framing for every skin: one pedestal, centred, 3/4 view, with a soft floor shadow.
- **Look.** Each skin's `color`, `material` and `trimColor` / `trimMaterial` from `BaseThemeConfig.Pedestals`.
- **Where the id goes.** `BaseThemeConfig.Pedestals[<key>].thumbnail`.

| key | look |
|---|---|
| Default | the museum's grey stone pedestal |
| Marble | white marble, gold foil ring at the base |
| Obsidian | near-black basalt, glowing purple ring |
| GoldPlinth | polished gold, white ring |
| Crystal | translucent pale-blue glass, glowing cyan ring |

## 5. Optional 3D decor props
- **Used on.** Themed plots.
- **Placement.** `BaseThemeService` puts a prop on top of each gate cap (`anchor = "gate"`) or on the two back-corner fence posts (`anchor = "backCorner"`). The prop's bottom sits on the post top, and it faces the plot's front.
- **Size.** Roughly the `size` in the config row (2-4 studs), because the fence posts are 1.8 studs wide.
- **Fallback.** Until a model exists, a coloured primitive is used.
- **Where they go.** Put each Model in `ServerStorage.GameAssets.ThemeDecor`, named exactly as below. No config change is needed; the service finds them by name.

| Model name | theme | description |
|---|---|---|
| SunsetLantern | Sunset | round paper lantern, warm orange glow (add a PointLight, Range 10) |
| MidnightBeacon | Midnight | short metal pylon with a cyan glowing ring |
| MidnightOrb | Midnight | small floating cyan orb on a thin stand |
| JungleTotem | Jungle | mossy carved stone totem, 3 studs tall |
| JungleBush | Jungle | leafy round bush with a few vines |
| FrostCrystal | Frost | cluster of pale ice crystals, 3.4 studs tall |
| LavaBrazier | Lava | black iron brazier with glowing lava bowl (PointLight, orange) |
| NeonOrb | NeonNight | glass sphere with neon inner core |
| RoyalCrown | RoyalGold | gold crown finial |
| RoyalUrn | RoyalGold | white marble urn with gold rim |

Keep lights small (Range at most 14, Shadows off). Plot decor is not switched off by the client's Graphics LOW setting.


<!-- ===================== polish-events-analytics ===================== -->

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

