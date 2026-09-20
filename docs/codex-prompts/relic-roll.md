<!-- ===================== relic-roll ===================== -->

# Codex prompt: Museum Relics banner art (relic-roll)

Make the art for the **Shop panel's new top banner** in "Steal & Run!" (a
cartoon museum heist game). Every asset below has an exact config key; the
code already renders a clean placeholder (gradients, strokes, a rotated red
"NEW" text badge) while that key is `rbxassetid://0`, so each asset you
deliver lights up on its own with no code changes.

## Before you start

1. `git pull` (this feature's branch), read `docs/START_HERE.md` and
   `docs/AGENT_RULES.md` (rule 3: preserve line endings, never `sed -i`).
2. Upload every Image/Decal so the GROUP owns it, not a personal account.
3. Style: match the purchased UI pack already in `StarterGui.MainUI` (glossy
   cartoon, thick dark outline, bright gradients, soft top highlight, small
   drop shadow, transparent PNG) - this banner sits directly above the
   pack's own PASSES section and must not look like a different game bolted
   on top.
4. Do NOT change any number (odds, prices, item names). Only paste asset ids
   into the keys named below.

## Assets

### 1. Banner background art
- **Where**: `src/client/Controllers/RelicRollSection.luau`, local
  `BANNER_BG_IMAGE` (currently `"rbxassetid://0"`).
- **Size/aspect**: 1536x864 (16:9), will be cropped to fill a card roughly
  1:0.72 wide:tall - keep the important art centred.
- **Content**: a wide purple-to-violet gradient card background with
  decorative museum motifs (faint gold picture frames, pedestal silhouettes,
  soft light rays from the top), dark enough at the bottom third that white
  text and item figures standing there stay readable. No text baked in - the
  title, ribbon and odds are drawn by the code on top.

### 2. "NEW" ribbon
- **Where**: same file, local `RIBBON_IMAGE`.
- **Size**: 240x120, transparent PNG, a diagonal ribbon banner shape already
  including the word "NEW" in bold white with a dark outline (red ribbon
  fabric, small drop shadow). The code rotates and positions it at the
  banner's top-left corner - keep the ribbon horizontal in the source image.

### 3. Robux icon for the purchase buttons
- **Where**: same file, local `ROBUX_ICON`.
- **Size**: 32x32, transparent PNG. A simple Robux coin/diamond glyph in the
  pack's own colour treatment (do not use Roblox's own trademarked Robux
  logo verbatim - a clean stylised coin reads fine and avoids any trademark
  question). Optional: the price text alone is already legible without it.

### 4. Rarest-figure glow (optional polish)
- **Where**: same file, `RelicRollSection.update` builds a small placeholder
  glow (`rbxasset://textures/particles/sparkles_main.dds`, tinted to the top
  prize's rarity colour) behind the 6th (rarest, largest) item figure.
- If you want a nicer glow: supply a soft radial burst PNG, square,
  transparent, ~512x512, white/neutral tint (the code multiplies it by the
  rarity colour), and swap the `Glow.Image` property in
  `RelicRollSection.luau` to your asset id - name the constant `GLOW_IMAGE`
  next to the other art constants if you add it, so it stays a one-line
  change.

## When you finish

- Run `bash tools/check.sh` (hard errors must stay empty) and `selene src`
  (0 errors).
- Commit with a clear message.
- Reply with a table: asset name -> asset id -> file/key you pasted it into.
