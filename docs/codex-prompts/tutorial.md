# Codex prompt: tutorial pointer hand (tutorial-onboarding)

Make ONE image for the Roblox game "Steal & Run!", a cartoon museum heist
game. The first-minute tutorial draws a pulsing red ring in the world at the
exact spot a new player must interact with (a display pedestal, the
treadmill), with a verb under it ("PLACE IT HERE", "OPEN IT", "STEP ON").
The reference build draws a cartoon pointing hand inside that ring; ours is
empty until this asset exists.

Upload the image as a Roblox Decal/Image, then write its **image** id
(`rbxassetid://<id>`) into the key below. If Roblox gives you a decal id,
convert it to the image id first. The key starts as `rbxassetid://0`; while
it is 0 the ring shows its verb alone, so nothing breaks without the art.

## Style

- **Match the UI pack the HUD already uses.** Glossy cartoon style, a thick
  dark outline (#141008 to #1A1A22), one soft white highlight, no drop shadow
  (it sits over the world, not a panel).
- **Reference pack icons** for weight and gloss: cash
  `rbxassetid://112931960147028`, speed arrow `rbxassetid://102080723305863`.
- **No real brands, logos or real people.**

## 1. Pointer hand

- **Name:** `TutorialPointerHand`
- **Write to:** `src/shared/Config/PolishConfig.luau` ->
  `PolishConfig.TUTORIAL_POINTER_ICON`
- **Used in:** the centre of the tutorial's target ring, drawn inside a
  BillboardGui in the world at about 60% of a 6-stud ring, so it is seen
  from 5 to 40 studs away and must read at a glance.
- **Size:** 512 x 512, transparent PNG, square. Keep the drawing inside the
  central ~80% so the ring's stroke never clips it.
- **Subject:** a stylised cartoon hand, index finger pointing straight UP,
  the other fingers curled, seen from the front - the classic "tap here"
  hand. Warm yellow body `#F2C94C`, a slightly darker yellow-orange
  `#D9A032` on the underside for the two-tone gradient, one white gloss
  highlight on the knuckle, thick dark outline as above. No sleeve, no
  cuff, no shadow beneath it.
- **Do not** put any text in the image; the verb is drawn separately.
