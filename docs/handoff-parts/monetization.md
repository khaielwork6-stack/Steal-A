# Monetization pass (2026-09-17)

Area: receipts, Cash packs, boss offer, spin wheel, PolicyService, offer rail.
Nothing here was run in Studio. `tools/check.sh`: no hard errors (the `level`
error is gone) and no new type errors.

## What changed and why

### E1. `level` in the save-failure warning
`processReceipt` put `{level}` in its save-failure warning, but `level` only
exists inside the TreadmillTier branch. The warning now prints `grantedWhat`,
which is set in every branch.

### E2. `promptProduct` only opens Cash and Speed products
A tampered client could send `PurchaseRequest("product", "StealDivine")` and
open a real purchase with nothing reserved behind it. `promptProduct` now
refuses any product whose `kind` is not `Cash` or `Speed`, and logs a warning.
I checked that the legitimate flows never go through `promptProduct`:
- Steal: `HeistService.begin` calls `PromptProductPurchase` itself.
- Reveal: `HatchService.promptInstantReveal` does the same.
- Treadmill tier: `PurchaseRequest("treadmill")` and `SpeedService.promptRobuxUpgrade` both go to `promptTreadmillUpgrade`.
- The boss offer and the Shop send Speed or Cash keys only.

### E3. Receipts that can never be delivered
- **New handler contract.** `(delivered, "retry" | "undeliverable")`.
  - A handler that returns only a boolean is treated as `"retry"`.
  - A handler that throws is treated as `"retry"`.
  - The handler type is `...any`, so both the old and the new HeistService/HatchService signatures can be assigned.
- **`"undeliverable"`, or a TreadmillTier bought while already maxed.** `grantFallback` runs:
  - It awards Cash and records the purchaseId.
  - It tells the player: "Your purchase couldn't be completed, so you received $X instead."
  - It saves and returns PurchaseGranted.
  - `PurchaseFeedback` is not fired, so no shop card flashes.
- **`"retry"`.** Returns NotProcessedYet, as before.
- **Formula** (`MonetizationConfig.fallbackCash`):
  `max(robux × 2,500, baseIncome × robux × 60)`.
  - That is one minute of base income per Robux. A 599 R$ steal gives 10 hours, compared with 12 hours from the 679 R$ pack.
  - The floor is $2,500 per Robux. The 200K pack works out to $2,353 per Robux.
  - `robux` is the receipt's `CurrencySpent` if it is positive, otherwise the live price, otherwise the config price.
- **Needs the security agent's change.** Steal and Reveal only reach the fallback once `HeistService.fulfil` and `HatchService.fulfil` return `"undeliverable"`. Until then those receipts stay open, as they do today.

### E4. Cash packs scale with income
Each pack pays `max(amount, baseIncome × incomeMinutes × 60)`. Product ids and
prices are unchanged.

| key | R$ | floor (was) | minutes |
|---|---|---|---|
| Cash24K | 45 | **75K** (24K) | 10 |
| Cash200K | 85 | 200K | 30 |
| Cash800K | 215 | 800K | 120 |
| Cash4M | 425 | 4M | 360 |
| Cash8M | 679 | 8M | 720 |

- **Value per Robux** rises with pack size, both for the floors and for the minutes. `validate` checks this.
- **Which income is used.** `MonetizationConfig.baseIncome` takes `EconomyService.getIncome` and divides out the 2x Cash pass and `SERVER_EARNINGS_BOOST × TEMPORARY_EARNINGS_BOOST`:
  - The pass still never doubles a purchased pack.
  - A weekend earnings boost doesn't change what a pack is worth.
- **When it is read.** At receipt time.
- **What the shop shows.** The server sends `StatePush.shop.cashPacks` (key → exact amount).
  - `ShopController` puts a "YOU GET $X" ribbon on each painted Cash card.
  - Cards without art show the amount in their title.
- **Label.** The 24K pack's `label` is now "75K".

### E5. Spin wheel
- **a) AFK pause.**
  - **Client.** `ActivityController` fires `ActivityPing` at most every 30 s, and only while it has seen input in the last 120 s.
    - Input counted: keys, mouse buttons, the mouse wheel, mouse movement, touch and gamepad.
    - Mouse movement is included on purpose: a player reading a panel is not AFK, and a jiggler could fake movement anyway.
  - **Server.** `SpinWheelService` handles the rest:
    - It rate-limits pings to one per 10 s.
    - It counts more than 3 studs of horizontal root movement between ticks as activity.
    - It adds progress only if the player was active in the last 120 s.
    - Joining counts as activity.
    - Standing on a treadmill without input counts as idle.
  - **Paused display.** While paused, the wheel publishes `SpinPausedRemaining`, and the sign reads "SPIN PAUSED (AFK) m:ss".
  - **Config.** `SpinWheelConfig.IDLE_SECONDS`, `ACTIVITY_PING_SECONDS`, `ACTIVITY_PING_MIN_GAP` and `MOVE_ACTIVITY_STUDS`.
- **b) Weights.**
  - Jackpot 30 → 8, Tiger 50 → 15, Panda 120 → 50.
  - The 127 freed points went to the six most common wedges:
    - The three $1,500 wedges are now 1521, 1521 and 1522.
    - The three 250-Speed wedges are now 1021 each.
  - The total is still 10,000.
- **c) Prizes scale with progress** (`SpinWheelConfig.amountFor`). "Base income" is the same basis the Cash packs use; "next gate" is the recommended Speed of the zone after `HighestZoneReached`.

  | wedge | pays |
  |---|---|
  | $1,500 | `max(1500, 20 s of base income)` |
  | $15,000 | `max(15000, 120 s)` |
  | 250 Speed | `max(250, 0.5% of next gate)`, capped at 500K |
  | 2,500 Speed | `max(2500, 2%)`, capped at 5M |
  | Jackpot | `max(1M, 25%)`, capped at 1B |

  - **Why the caps.** Each Speed cap is half the Speed pack it would compete with (1M and 10M). For a Zone 8 player the wheel is worth about 0.7M Speed per spin, roughly 1% of the 700M gate per active hour, so the Zone 8→9 wall stays where it is.
  - **Jackpot.** Its floor dropped from 1B to 1M. The art still reads "1B SPEED", which is what Zone 10+ players are actually paid.
  - **One amount throughout.** The amount is computed once at spin time and stored in the pending prize. `SpinResult` now fires `(index, { won, amount })`, and the banner shows `won`.
  - **Wedge labels.** They reach the client as `StatePush.spinWheel.labels`. `SpinWheelController` covers any printed wedge whose live label is different. The art is the fallback.
- **d) Pending prize is saved.**
  - A new profile field, `PendingSpinPrize = { Index, Kind, Amount, GuardianKey, At }`.
  - It is written in the same step as the spend, so the spend save covers both.
  - `settle` clears it together with the payout.
  - `payLeftover` pays a leftover prize once, about 3 s after the profile first appears. The clock tick calls it, and `onTriggered` calls it before a new spin.
  - The leave path (`onBeforeRelease` → `settle`) is unchanged and clears the field too.
  - **DataService edits:**
    - the `PendingSpinPrize: any?` field in the `Profile` type, just above `SpinProgress`;
    - a `type(...) ~= "table"` check in `reconcile`, just after the `PendingReveal` check.

    Both are marked `[monetization pass]`. There is no schema bump, because the field is additive.

### E6. Boss offer
- `BOSS_OFFER_COOLDOWN` is now 90 s (it was 0).
- `BossOfferByZone` is now a ceiling. `MonetizationConfig.bossOfferFor(zone, speed)` picks the cheapest Speed pack that doesn't exceed the ceiling and whose amount is at least 10% of `(zone gate − speed)`:
  - If the player is already at or above the gate, it picks the cheapest pack.
  - If no pack is big enough, it picks the ceiling.
- In practice, in Zones 9–11:
  - a player 1M short is offered 150K;
  - a player 50M short is offered 10M;
  - a player hundreds of millions short still sees 1B.
- Zone 12 still has no offer.

### E7. Early cash jackpot: not changed
Zone 2's Cursed Coin (slot 8) weight and Zone 3's King's Crown (slot 8) weight
are pinned by `validate` twice:
- `expectedWeights` checks each slot.
- The "ANCHORS" block checks the owner's written per-rarity odds: Zone 2 Cosmic = 1%, Zone 3 Cosmic = 2%.

These are the owner's own 2026-09-11 decision, not reference-game parity. The
task said to change them only if they weren't pinned, so they are unchanged.

If the owner wants them halved, change these in one commit:
- `LootConfig.ZoneWeights[2][8]` 1 → 0.5 and `[3][8]` 2 → 1, adding the freed weight to the Common slots in their existing ratio;
- both `validate` tables;
- the LootConfig comment.

### E8. PolicyService
- **Server.** `MonetizationService` calls `GetPolicyInfoForPlayerAsync` on join, in pcall, with up to 4 attempts 15 s apart, and caches the result.
  - Until it answers, or if it never does, the player is treated as restricted.
  - `MonetizationService.policy(player)` returns `{ known, paidRandomItemsRestricted, paidItemTradingAllowed, raw }`, for the trading feature later.
  - `paidRandomRestricted(player)` is used for Instant Reveal.
- **Instant Reveal counts as a paid random item.**
  - Server: HatchService got a small hook, `HatchService.canOfferInstantReveal`, which init wires to the policy. `promptInstantReveal` refuses restricted players with a message. Revealing a ready container is still free.
  - Client: `PurchasePolicyController` hides the SlotPrompt only while its container is still counting down. When the timer ends it gives the prompt back, using BasePromptController's rule (`ServerEnabled`), so a restricted player still reveals for free.
- **Paid base steals stay allowed,** because the player can see the item they are paying for.
- **Client state.** `StatePush.shop.policy = { known, paidRandomRestricted, paidTradingAllowed }`.

### E9. OfferRailController
- The rainbow sweep now runs on `Heartbeat` instead of `RenderStepped`.
- It skips all work while the rail frame is hidden or MainUI is disabled.
- There is no shared Reduced Effects module in this branch, so I added `OfferRailController.setReducedEffects(value)`, following the SpinWheelController pattern. When on, the rail stops breathing, sweeping and wobbling.
- Nothing calls it yet, because SettingsController is not mine. Whoever owns settings, or the shared module, should call it.

### E10. Pricing notes for the owner (Creator Dashboard)
- **No product ids changed.**
- **Cash24K.** Consider renaming it "Cash Pack S" on the Dashboard, and re-export its card art, which still prints "24K" (the floor is now 75K). The live ribbon covers the gap for now.
- **Cash packs overall.** Since the packs now scale with income, the 45 R$ and 85 R$ packs are the impulse buys. Consider 49 R$ and 99 R$ to match common price points. That is optional and needs no code change.
- **Speed1B at 2,549 R$** is now shown only to players who are hundreds of millions short. Watch its conversion; a mid pack (about 100M for about 999 R$) would fill the gap. That would be a new product id, so it isn't in this change.
- **Instant Reveal** is withheld in restricted regions, so expect lower reveal revenue there.

## Remotes, state and wiring
- `Remotes.NAMES`: one new block at the end, `ActivityPing`. The `SpinResult` comment was updated.
- New StatePush fields:
  - `shop` (`MonetizationService.summarise`)
  - `spinWheel` (`SpinWheelService.summarise`)
- **Server init.** One `HatchService.canOfferInstantReveal` assignment.
- **Client init.** Starts `ActivityController` and `PurchasePolicyController`.
- **StatePush listeners (for the StateStore migration).** These add new `StatePush` listeners:
  - `SpinWheelController` (new)
  - `PurchasePolicyController` (new)
  - `ShopController` (its existing line is unchanged)

## Studio test plan
Run each command with `ServerStorage.DebugInvoke:Invoke(cmd, "<you>", ...)`.
Every command that changes your profile restores it and saves again.

1. `validate` at startup has no failures. That covers the spin weights and caps, the pack order, the fallback formula and the boss-offer picks.
2. `monPacks`: `amountNow` equals the floor at zero income. Then place a few items and check it equals `max(floor, baseIncome × minutes × 60)`. Open the Shop: each Cash card's ribbon shows the same figure. Buy the smallest pack (a Studio test purchase): the toast shows the same amount.
3. `monPrompt StealCommon`, then `Reveal1m`, then `TreadmillTier2`: each gives `opened=false`. `monPrompt Cash200K`: the dialog opens.
4. `monFallback all`: for the treadmill, steal and reveal paths:
   - `decision = PurchaseGranted`;
   - `paid == expectedPaid`;
   - `receiptRecorded = true`;
   - `replayDecision = PurchaseGranted`, with `replayPaidAgain = false`.

   Your Cash is then back to its original value. After the security change merges, run `monFallback steal real`: it should also be granted.
5. `receipt deliver <TreadmillTier9 id> x`, with the level at max: this now converts to Cash, where it used to stay open. Afterwards, `receipt setlevel <yours>` resets your level.
6. Spin wheel:
   - `monWheel`: every row's live label equals the printed one for a fresh profile, except the jackpot, which shows 1M.
   - Visual check: plates cover the jackpot wedge text. If they are misplaced, tune `LABEL_RADIUS` and `LABEL_ROTATION` at the top of SpinWheelController's "LIVE WEDGE LABELS" section.
   - `spinReady`, then spin: the banner amount matches the wedge label and the Cash/Speed change.
7. AFK pause:
   - `monActivity idle`: the sign reads "SPIN PAUSED (AFK)" and `spin` shows progress frozen.
   - `monActivity auto` with no input for 2+ minutes: it pauses. Moving or pressing a key resumes within one tick.
   - Standing on the treadmill with no input: it pauses after 2 minutes.
8. `monSpinCrash`: `paidExactlyOnce = true`, `pendingCleared = true`, and `cashDelta` is the wedge amount. Your Cash is then restored. For a real crash test: spin, then stop the server during the spin while saves are live, then rejoin. The prize is paid about 3 s after load, with an "interrupted" toast.
9. `spinRelease` during a spin: paid once. `spin` then shows `savedPendingPrize = nil`.
10. Boss offer:
    - `monOffer 9 699000000`: offers Speed150K.
    - `monOffer 9 0`: offers Speed1B.
    - `monOffer 12`: offers none.
    - `monOffer 5 0 fire`: the card appears. Calling `offer 5` straight away shows nothing, because of the 90 s cooldown.
11. Policy:
    - `monPolicy restrict`: sealed containers that are still counting have no prompt. When the timer ends, "Reveal" appears. Firing the prompt anyway returns the "isn't available" toast.
    - `monPolicy allow`: "Instant Reveal" is back.
    - `monPolicy real`: restores the real answer.
12. Offer rail: open a pack panel (the rail hides), and check in the MicroProfiler that no rail work is running.
