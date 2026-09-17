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
