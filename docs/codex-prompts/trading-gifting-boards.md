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
