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
