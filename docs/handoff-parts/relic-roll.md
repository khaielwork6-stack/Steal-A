# Relic Roll: "MUSEUM RELICS [LIMITED]" gacha banner (2026-09-20)

Area: a new gacha section at the TOP of the Shop panel (above PASSES),
replicating the reference video's structure with our own items/odds/art.
Nothing here was run in Studio (rule 1). `bash tools/check.sh`: hard errors
stayed empty; no new TypeErrors traced to a file this pass touched. `selene
src`: 0 errors, 92 warnings (unchanged from baseline).

## Files

**New**
- `src/shared/Config/RelicRollConfig.luau` - item pool, odds, product keys,
  `endsAt`/`limited`.
- `src/server/Services/RelicRollService.luau` - rolls, grants, the durable
  replay record, the `relicRoll` StatePush provider.
- `src/server/Services/DebugCommands/RelicRoll.luau` - test commands.
- `src/client/Controllers/RelicRollSection.luau` - the banner (figures,
  tooltip, mouse-follow, buttons).
- `src/client/Controllers/RelicRollRevealController.luau` - the full-screen
  roulette + success dialog.
- `docs/codex-prompts/relic-roll.md` - banner/ribbon/Robux-icon art brief.

**Edited**
- `src/shared/Config/MonetizationConfig.luau` - `RelicRollProducts` (kind
  `"RelicRoll"`, real ids below), `rollCount` field on `ProductDef`.
- `src/server/Services/MonetizationService.luau` - `relicRollHandler`
  injection point (`setRelicRollHandler`), the `RelicRoll` ProcessReceipt
  branch, `promptProduct` allow-list.
- `src/server/Services/DataService.luau` - `Profile.PendingRelicReveal`
  (additive, no schema bump).
- `src/server/Services/AnalyticsEvents.luau` - `RelicRoll` custom event,
  `Buy_RelicRoll` funnel, catalogue entry.
- `src/server/Services/AnalyticsSession.luau` - the `relicRoll` ProgressEvents
  listener -> the custom event.
- `src/shared/Remotes.luau`, `src/shared/Config/GameConfig.luau` -
  `RelicRollAck` remote + rate limit.
- `src/shared/Config/validate.luau` - a RELIC ROLL block (odds sum to 100,
  ascending rarity, Zone <= 8 only, product ids configured, honest "was"
  price).
- `src/server/init.server.luau` - require, handler wiring, `.start()`.
- `src/client/Controllers/ShopController.luau` - builds the banner above
  Passes, plus **the PASSES bug fix** (see below).
- `src/client/init.client.luau` - starts the reveal controller.

## The four Robux ids (already created, per your message)

| Key | Product | Price | Id |
| --- | --- | --- | --- |
| `RelicRoll1x` | 1x | 52 R$ | 3713786892 |
| `RelicRoll3x` | 3x | 128 R$ | 3713786898 |
| `RelicRoll10x` | 10x | 410 R$ | 3713786905 |
| `RelicRoll50x` | 50x | 1792 R$ | 3713786914 |

All four are real ids in `MonetizationConfig.RelicRollProducts` - nothing to
create. **Owner action**: confirm these are all "Consumable, not limited"
Developer Products on the Creator Dashboard (they should already be, since
they exist) - a one-time/limited product would silently stop granting after
its first sale.

## Item pool and odds (my call - here's the reasoning)

Six **existing** `LootConfig` items, ascending rarity, at the reference's own
39/25/20/10/5/1:

| Odds | Item | Zone | Rarity | Base income |
| --- | --- | --- | --- | --- |
| 39% | Museum_AncientVase | 1 | Common | $1/s |
| 25% | Museum_GoldenStatue | 1 | Uncommon | $8/s |
| 20% | Museum_PharaohMask | 1 | Rare | $35/s |
| 10% | Museum_GoldenCrown | 1 | Epic | $180/s |
| 5% | Museum_Diamond | 1 | Legendary | $1,800/s |
| 1% | Pirate_CursedCoin | 2 | Cosmic | $220,000/s |

**Why these six and not something bigger.** Out-of-scope says the Zone 8+
progression wall must never move. The safest way to guarantee that from a
brand-new gacha pool is to never sell a Zone 9-12 item at all, at any odds -
so I went further and kept every tier at Zone 1-2. `validate.luau` now
enforces `zoneIndex <= 8` for every Relic Roll tier as a hard check, so a
future edit cannot accidentally slip a late-game item in.

**Expected value** (worked by hand in `RelicRollConfig`'s own header comment;
`relicRollDist` below gives the exact simulated numbers): the six tiers'
average Scale-roll size factor is ~2.1-2.25x their printed base income, so a
single 52 R$ roll's BLENDED expected income is roughly **$5,200/s**, almost
entirely carried by the 1% slot (Cursed Coin averages ~$495K/s when it hits,
before mutation). Sanity check against a **guaranteed** purchase at a similar
price: `MonetizationConfig.StealProducts` sells a guaranteed item up to
$2,500/s for 39 R$ and up to $100,000/s for 69 R$. A 52 R$ Relic Roll's ~$5.2K
blended EV sits well **below** that guaranteed band - the right side to err
on for a gamble, even before charging anything for the show. A max-luck pull
(Colossal Scale + Corrupted mutation on the 1% slot) can spike far higher,
but needs two independent long-odds rolls at once, so it reads as a rare
delight rather than the expected outcome.

## How a roll is granted (server-authoritative)

`RelicRollService.grant(player, rollCount, purchaseId)` is installed on
`MonetizationService` as the `RelicRoll` product handler
(`setRelicRollHandler`) - a **direct grant**, exactly like the Gadget/Skip
handlers, because there is nothing to reserve before the receipt lands (unlike
a base steal or Instant Reveal, which pay for one item chosen in advance). A
`false` from the handler is therefore **always** converted to Cash by
`MonetizationService.grantFallback` (see the `RelicRoll` branch in
`processReceipt`), never left "open" - waiting longer can never make an
already-invalid grant valid.

Each roll:
1. Picks a tier (`RelicRollConfig.rollTier`, weighted, `Random.new()` -
   server-side only, never the client).
2. Rolls Scale and mutation with the **same generators every spawned item
   uses** - `LootService.rollScale` / `LootService.rollMutationId` - so a
   Relic Roll item is not a parallel format; `DataService.reconcileItem`
   fills in Rarity/Size/FinalIncome exactly like a load would.
3. Puts the item in `Inventory` if there is room, else through
   `MailboxService.send` (durable; the player is told); if even the Mailbox
   fails (a DataStore outage), it goes into `Inventory` past the cap rather
   than being lost. **Nothing is ever dropped.**
4. Writes `profile.PendingRelicReveal` - NOT the grant (already durable by
   step 3), just "what to animate next" - so a client that missed the live
   push (offline, mid-rejoin) gets the same reveal on its next join via the
   ordinary `relicRoll` StatePush field. The client acks
   (`RelicRollAck` remote) once it has shown (or skipped) the reveal, which
   clears the record.

Policy: `MonetizationService.paidRandomRestricted(player)` (the same
PolicyService flag Instant Reveal already respects) hides the whole banner
client-side and refuses the grant server-side - a receipt that lands anyway
(an external purchase via the product's own catalog page) converts to Cash
instead of rolling.

## The PASSES section bug - found and fixed

**What I found.** `ShopController`'s `fitGrid` sized a section's grid from its
ORIGINAL card count whenever every card in it came back `Visible = false`
(the `if visible > 0 then count = visible end` guard skipped updating `count`
at exactly `visible == 0`). The Passes section is the only one that can have
EVERY card owned at once (2x Cash pass + Auto Reveal pass, both permanent),
and an **owner's own Studio account typically owns every Game Pass it
sells** - so the owner's screenshot (header, then a blank rectangle) is not a
one-off: it reproduces on essentially every load of an account that owns both
passes. It is a real bug in our code, not a Studio/asset issue.

**The fix.** `fitGrid` now takes the section's header too; when a grid ends up
with zero visible cards it collapses to 0 height AND hides its own header,
matching the pattern `GiftShopSection` already uses when it has nothing to
sell. `section()` returns `(grid, header)`; `trackGrid` and the `fitted` list
carry the header through. Cash/Speed are unaffected (they can never reach
zero visible cards today), so this only changes behaviour for Passes.

**How to see the bug (before this fix) / verify the fix**: own both the 2x
Cash pass and the Auto Reveal pass (or fake it: `monWheel`-style debug isn't
needed here - `MonetizationService.setOwnedForTesting(player,
MonetizationConfig.CashPass.gamePassId, true)` and the same for
`MonetizationConfig.AutoRevealPass.gamePassId`, then push state and open the
Shop) - Passes should now disappear entirely (header included) instead of
leaving an empty rectangle.

## Client

`RelicRollSection.build(list, 5)` - order 5, one below the Passes header's
order 10, so it always sorts to the very top of the Shop's scroller. It owns:
the banner card, the "NEW" ribbon, the title, six `ViewportFrame` item
figures (via `ItemThumb.apply`, the SAME component every other item card in
the game uses - no parallel art path), the hover/tap tooltip
(`[Rarity]`/name/income), the odds row, and the four purchase buttons
(50x/10x/3x/1x, matching the reference's own left-to-right order and its
crossed-out "was" price on 50x - honest math, `50 x the 1x price`).

Figures turn to face the mouse (Y-yaw + a small tilt, damped) while it is over
the banner; on a touch device they sway gently instead. Both respect
`Effects.isReduced()` (holds the pose, no motion). Buttons use the existing
`UIAnim.bindButton` hover/press feel, an idle shine sweep on 50x
(Effects-aware) and a small looping bob.

`RelicRollRevealController` is fully independent (reacts to
`state.relicRoll.pendingReveal`, never a one-shot remote, so a missed push can
never lose the reveal): a fast-then-decelerating belt of item cards (real
figures via `ItemThumb`, one real filler pool drawn from the same
`RelicRollConfig`/`LootConfig` the server rolls from - purely cosmetic) under
a fixed selector, a tick sound per card (`RevealCycle`, already in
`AudioConfig` - no new asset), tap-anywhere-to-skip, a landing pulse
(`RevealPop`), then a "Successful Purchase!" dialog (`CashPurchase` sound,
heart, item name in its rarity colour, Ok!/X) with, for 3x/10x/50x, a
scrollable results grid grouped by item with `xN` count badges. Confetti is a
plain animated-Frame burst, skipped entirely under Reduced Effects.

**Not pixel-identical to the reference** - I have no reference stills/video,
only the written description, and rule 7 means I cannot generate the banner
background, ribbon or a Robux icon myself. The structure (ribbon, title, six
ascending figures, odds row, four buttons, roulette belt, success dialog) is
built exactly as described; the ART is a clean gradient/stroke placeholder
behind config keys that skip themselves at `rbxassetid://0` - see
`docs/codex-prompts/relic-roll.md` for exactly what to draw and where each id
goes.

## Debug commands (`DebugCommands/RelicRoll.luau`)

- `relicRollState` - the caller's live banner data (odds, prices, restricted,
  pending reveal).
- `relicRoll [count]` - rolls `count` (default 1) WITHOUT Robux, through the
  exact same `RelicRollService.grant` a real purchase calls. Reports every
  item rolled, where each one went, then restores the profile.
- `relicRollFull [count]` - the same, but Storage is padded to its cap first
  so every roll is forced through the Mailbox overflow path; reports
  `allOverflowed`.
- `relicRollReplay` - grants one roll, confirms the replay record survives a
  wrong-id ack (must NOT clear), confirms it is visible in
  `relicRollState().pendingReveal` (what a rejoining client would see),
  confirms the real ack clears it. All restored after.
- `relicRollDist [count]` (default 10000) - a PURE statistics check, no
  player/profile: simulates `count` rolls with the live RNG functions
  (`RelicRollConfig.rollTier`, `LootService.rollScale`/`rollMutationId`,
  `RarityConfig.finalIncome`) and reports observed % vs configured % per
  tier, average income per hit, and the blended expected income/s. Run this
  in Studio for the exact numbers behind the "EV worked by hand" section
  above.

## Studio test plan

1. `relicRollDist 20000` - confirm each tier's `observedPercent` is close to
   `configuredPercent` (39/25/20/10/5/1) and note the printed
   `blendedExpectedIncomePerRoll`.
2. `relicRoll 1`, `relicRoll 3`, `relicRoll 10`, `relicRoll 50` - confirm
   `granted = true`, the right count of `rolled` entries, and
   `inventoryCountAfter` matches (profile is restored after, so re-run freely).
3. `relicRollFull 5` - confirm `allOverflowed = true`.
4. `relicRollReplay` - confirm `survivedGrant`, `survivedWrongAck`,
   `replayVisibleInState` and `clearedAfterRealAck` are all `true`.
5. Open the Shop in Play mode: the banner should sit above PASSES, the six
   figures should turn toward the mouse, hovering one should show its
   tooltip, and tapping a button should open the real Roblox purchase prompt
   for that product id (Studio cannot complete a real purchase, but the
   dialog opening confirms the id and the client wiring).
6. Own both the 2x Cash pass and the Auto Reveal pass (real purchase, or
   `MonetizationService.setOwnedForTesting`) and confirm PASSES now
   disappears entirely instead of leaving a blank rectangle (the bug fix).
7. Toggle `MonetizationService.setPolicyForTesting(player, true)` (restricted)
   and confirm the Relic Roll banner disappears from the Shop.

## What I could not do / owner follow-ups

- **Art**: banner background, "NEW" ribbon, Robux icon, and an optional glow
  texture - `docs/codex-prompts/relic-roll.md` has the exact briefs and
  config keys. The banner is fully functional without them (a clean
  gradient/stroke placeholder), just not the reference's exact look.
- **The reference video/stills**: I was not given them for this pass (the
  brief describes them in prose); if you have the actual frames, a follow-up
  pass could tighten spacing/sizes to match more closely.
- **Creator Dashboard**: please confirm the four RelicRoll product ids are
  Consumable (not "limited quantity") - I cannot check this myself.
- **Everything else** (grant logic, odds, policy, analytics, the PASSES fix)
  is code-complete and covered by the debug commands above.

---

# Reveal rework (2026-09-20, from the owner's Studio feedback)

Supersedes the "Client" paragraph about the reveal above: the **"Successful
Purchase!" dialog and its results grid are DELETED** (only that dialog had the
text; the phrase in the older section is history). Nothing else in the repo
used it. NOTE: Roblox's own native purchase-confirmation popup (CoreGui) is not
ours and cannot be removed from code.

## What the reveal does now
- **Trigger, unchanged in spirit**: `state.relicRoll.pendingReveal` only (never
  a one-shot remote). Now ONE queue: payloads play strictly one at a time, each
  purchaseId is remembered so repeated pushes never restart it, the whole run
  is pcall'd, and every exit path destroys the ScreenGui, the tick Sounds and
  releases the HUD claim. A rejoin replays only the rolls not yet acked.
- **Panels close first**: `_G.CloseAllUIFrames()` (slide-down, blur off, HUD
  restored by the MainUI script) then a `UIStateController` claim `relicroll`
  hides the HUD for the duration. The ScreenGui is DisplayOrder 600 (above
  MainUI/panels, below the flyover 900 and tutorial film 950), Sibling ZIndex.
  Why the owner saw a bare box could not be reproduced without Studio; the
  old flow left the Shop open under the reveal, an early `return` when
  PlayerGui was missing left the id marked seen forever, and a second push
  destroyed a running reveal. The queue / `seen` / pcall / close-first design
  removes every path found.
- **One roulette per roll**, ROLL_SECONDS 4.0 (config, validated 3-5). The belt
  is driven by hand every RenderStepped from the clock:
  `pos = TRAVEL * (1 - (1-u)^EASE_POWER)`, TRAVEL 30 cards, power 3. Peak speed
  22.5 cards/s, ~1.4 cards/s at t=3 s, the last 0.5 card over the final second
  (Quint froze for the last second). Lands exactly on the server's item.
  Card width scales with the viewport (min(track/5.5, 27% of height), 52-128px).
- After each landing: name + [Rarity] for 1.2 s (tap = advance), "Roll k / N"
  counter, "Tap to skip" (jump to this roll's result), "Skip all" button.
  The belt is persistent; per roll only the winner + 10 fillers are rebuilt.
- Reduced Effects: 0.6 s roll, 12-card travel, no confetti/punch.

## Sound (AudioConfig)
- `RelicTick` 139719503904449 (event, vol 0.7), `RelicWin` 111289716155568
  (event, vol 0.95, played on the landing).
- One tick per card boundary crossing the selector, decided from the real belt
  position each frame (`floor(pos + 0.5)` increases). Pool of 8 pre-created
  Sounds, round-robin, destroyed on every exit.
- PlaybackSpeed = 0.8 + (1.5 - 0.8) * (v / vPeak)^0.6, v = smoothed cards/s
  from the real position delta, vPeak = 3*30/4 = 22.5 cards/s. A tick within
  0.03 s of the previous is skipped, except inside the last 8 cards (all
  heard). A tap-skip plays no tick burst. All numbers are `RelicRollConfig`
  `TICK_*` constants.

## Remote and server flow
`RelicRollAck(purchaseId: string, rollIndex: number)`: 1..N = "that roll has
landed"; **0 = Skip all** (every not-yet-acked roll). Validated: string <=100,
integer 0..50, each index honoured once (`PendingRelicReveal.acked = {int}`),
limiter 6/s burst 60. The server still grants all items into Storage at
purchase time; on an ack it calls `HoldService.hold(player, instanceId)` for
that roll's item (lazy require, `type == "function"` check, pcall: missing or
failing = the item stays in Storage). Overflow (Mailbox) rolls are never held.
The record clears after the last roll is acked; a newer purchase overwrites
it, and the older one's remaining items simply stay in Storage. The summary now
carries `instanceId`. Analytics: `RelicRollReveal` custom event
("watched"/"skipped", "xN") fires when the record clears.

## Debug / Studio test plan additions
- `relicRollReveal [count]`: real N-roll reveal on your client, no Robux;
  profile restored after the acks (or a timeout, or on leave). Play tests take
  the real save lock: use only on a guest/safe profile.
- `relicRollAckCheck`: expect afterOneAck 1, afterRepeatAck 1,
  afterOutOfRange 1, recordSurvivedPartialAcks true, clearedBySkipAll true.
- Shop open -> `relicRollReveal 1`: shop and blur close, only the roulette is
  visible; 10 rolls play back to back with "Roll k / 10"; each item appears in
  the hotbar only after its roll lands; Skip all holds the rest; tick pitch
  falls as the belt slows; phone portrait and landscape; Reduced Effects.
