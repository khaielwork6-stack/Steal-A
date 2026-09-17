# Fusion, Auto Reveal and base themes (area: fusion-autoreveal-bases)

Nothing here was run in Studio. `tools/check.sh` reports no hard errors, and `selene` reports 0 errors.

Several existing files have higher TypeError counts than before (LootService, BaseGuardianService, SpeedService, Remotes, DataService and others). None of these are new type errors in those files. The checker repeats its existing diagnostics once more for each module that now requires them, because this area added new requirers.

## What was built

### 1. Item fusion
**Files.** `FusionConfig`, `FusionService`, `FusionController`, and a FUSE tab in `InventoryController`.

**The rule.**
- Three distinct stored copies of the same ItemId become one copy.
- Each copy must be revealed (`Hatched ~= false`), not robbed, not reserved by a heist, and not mid-reveal.
- A hook, `FusionService.isLocked(player, id)`, exists for a future trade window. The trade system should override it.
- Displayed items can never be inputs: only `profile.Inventory` is searched.

**Size.** The result is one class above the best input (`ScaleConfig.Variants` order), capped at Colossal.
- The Scale is drawn uniformly inside that class.
- At the cap, the Scale is never below the best input's Scale.

**Mutation.** One roll on `FusionConfig.MutationOdds` (62 / 22 / 10 / 4.5 / 1.5).
- The best input's mutation is a floor: a lower roll is lifted to it.
- `mutationOutcomes(floor)` gives the odds after the floor is applied. These are the odds the panel shows.

**Cost.** `max(250, 300 s × finalIncome(base, bottom of target class, Normal))`, paid in Cash only.

**Atomicity.** Every check runs first, then `EconomyService.spend`. There is no yield between the checks and the writes. After the spend, the service removes the 3 inputs and inserts the result.
- The result's income comes from `DataService.reconcileItem`, which uses `RarityConfig.finalIncome` and ScaleConfig.
- The result arrives already matured.
- It inherits the latest `ProtectedUntil` among the inputs.
- Storage count drops by 2.

**After a fusion.** The service pushes state and starts a save. `FusionResult` (consumed items plus the result) plays the client animation:
- three thumbnails spin inward, a flash, then the result card;
- with Reduced Effects on, it is a plain fade instead.

**The FUSE page.** Lists every item with at least 3 revealed stored copies.
- Picking one shows: a summary card (result size, cost, FUSE / BACK), a mutation-odds card, and every copy with USE / USING toggles.
- The default pick is the best copy plus the two weakest.

**Policy.** The roll is random, so fusion is Cash only and never sold for Robux. It is therefore offered in every region.

### 2. Auto Reveal Game Pass
**Files.** `AutoRevealService`, plus small changes to HatchService, init, HatchController, SettingsService, SettingsController and ShopController.

**The pass.** `MonetizationConfig.AutoRevealPass` (id **0**, suggested **199 R$**). Its id is added to `allGamePassIds` only once it is above 0.

**How it reveals.** A 1.5 s loop finds a ready sealed container for each online owner and calls `HatchService.commit(player, id, { auto = true, quick = not near })`.
- It waits while any reveal on that base is still locked.
- After each reveal it waits `HatchConfig.autoRevealSpacing`: the lock, plus the camera hold and return, plus 1.2 s.
- It skips a container with an open Instant Reveal purchase for 60 s.

**Near vs away.** "Near" means on the plot, or within 90 studs of the slab.
- Away, the commit is `quick`. The server swaps at 0.35 s and unlocks at 1.4 s (`HatchConfig.QuickReveal`).
- The `HatchReveal` payload carries `skipCamera = true` (plus `auto`). The client plays `playQuickReveal`: the container shrinks and fades, then the item bounces in with a ring. No camera, no roulette. Reduced Effects drops the ring and the bounce.
- A toast names the revealed item.

**Settings switch.** A Settings row, "Auto Reveal ON/OFF", cloned from Shadows and shown only to pass owners. It is saved as `Settings.AutoRevealOff` (inverted, so a missing value reads as ON).

**Shop card.** `AutoRevealPassCard` builds the card in the Shop's PASSES grid. ShopController only gained one call and a grid count.
- The card is hidden while the id is 0, except in Studio, where it shows as "NOT SET UP".
- It uses the `AutoRevealRequest("buy")` prompt. MonetizationService's existing `PromptGamePassPurchaseFinished` handler refreshes ownership.

**HatchService change.** `commit(player, id, options?)` and `onHatched(player, item, options?)`. With no options, behaviour is unchanged.

### 3. Base customisation
**Files.** `BaseThemeConfig`, `BaseThemeService`, and `BaseThemeController`, which is attached from `UpgradesController`.

**Catalogue.**
- 8 themes:
  - Classic: free.
  - Sunset, Midnight, Jungle, Frost and Lava: Cash, $250K to $20B.
  - NeonNight and RoyalGold: Robux via `MonetizationConfig.ThemePasses`, ids **0**, suggested **149 R$** each.
- 5 pedestal skins: Default (free), and Marble, Obsidian, GoldPlinth and Crystal ($100K to $100B).

**Profile.** `BaseTheme = { owned, equippedTheme, equippedPedestal }`. `DataService` has the type, the default and a reconcile block. There is no schema bump.

**What a theme paints.** It recolours or re-materials parts by the names `MapBuilder.buildBase` gives them:
- `PlotFloor.Slab`;
- `Paving/*`;
- `Fence` Post, GatePost and Rail;
- GateCap, which becomes the neon accent;
- the NeonFrame of empty pads, including their `NeonColor` attribute, which the client breathes.

It also adds decor props on the gate caps and back-corner posts: config primitives, or `ServerStorage.GameAssets.ThemeDecor.<modelName>` when that model exists.

**What a skin paints.** Every `Pedestal` part except the rarity `Accent` disc. The part's original look is kept in attributes, and SurfaceAppearances are parked, not destroyed. A trim ring is added.

**Keeping it on.**
- **After rebuilds.** `BaseService.onRebuilt(BaseThemeService.apply)` re-applies after every rebuild. Plot parts are repainted only when the theme or owner changed.
- **On release.** When a plot's `OwnerUserId` changes to someone else, every changed part is restored and the decor is removed.
- **On ownership change.** `MonetizationService.onOwnershipChanged` is wrapped in init so that a pass purchase or refund re-applies the theme.
- **Unowned themes.** An equipped Robux theme that is no longer owned shows the default look.

**UI.** The Upgrades panel gains TREADMILL | BASE tabs. The treadmill card was shrunk slightly to make room.
- The BASE page lists themes and pedestals with swatches, or a thumbnail once it has art.
- Each row has one action: buy, EQUIP, EQUIPPED, or the R$ button.
- A turning diorama preview updates when a row is tapped.
- Robux rows are hidden while their id is 0, except in Studio.

### Remotes, state and wiring
- **Remotes.** One new block: `FusionRequest`, `FusionResult`, `AutoRevealRequest`, `BaseThemeRequest`. Each is validated and rate-limited: fusion 2/s, auto reveal 2/s, theme 3/s.
- **StatePush.** New providers `autoReveal` and `baseTheme`. Both are small; `baseTheme` sends comma-joined key lists.
- **Server init.** One block before `BaseService.start()` starts Fusion, AutoReveal and BaseTheme, and wraps `onOwnershipChanged`. `onHatched` gained the `options` argument and passes `auto` / `skipCamera`.
- **Client init.** Starts `FusionController`.
- **validate.** One block covers:
  - the odds sum, order and floor;
  - the size cap and minimum cost;
  - the quick-reveal lock and auto-reveal spacing;
  - theme and pedestal keys (unique, known passes, free default).

## Owner actions (Creator Dashboard)
1. **Game Pass "Auto Reveal"**, suggested 199 R$. Put its id in `MonetizationConfig.AutoRevealPass.gamePassId`.
2. **Game Passes "Neon Night Theme" and "Royal Gold Theme"**, suggested 149 R$ each. Put their ids in `MonetizationConfig.ThemePasses`.
3. **Art.** See `docs/codex-prompts/fusion-autoreveal-bases.md`: the fusion icon, the pass icon, 8 theme thumbnails, 5 pedestal thumbnails, and optional decor models in `ServerStorage.GameAssets.ThemeDecor`.
4. **Save the place** after syncing, because there are new ModuleScripts.

## Lead: please verify
- **Theme paint.**
  - The fence part names (`Post`, `Rail`, `GatePost`, `GateCap`) and `Paving` exist on the baked plots. The themes paint only parts with these names, so a baked plot that uses other names shows only partial paint.
  - Back-corner decor finds its posts by distance to the slab edge (within 3 studs).
- **Pedestal skins.** The imported pedestal may be a MeshPart with a texture. The skin clears `TextureID` and restores it on the Default skin. Check that the look is acceptable.
- **Settings.** The Settings ScrollingFrame shows the new Auto Reveal row. It has the same CanvasSize caveat as the Graphics row.
- **Tabs.**
  - The Storage tab bar now holds 4 tabs, each 0.235 wide. Check phones.
  - The Upgrades tab bar is new. Check that it does not collide with the pack header.
- **Trading.** If a trading feature lands, override `FusionService.isLocked`.

## Studio test plan
Invoke each command with `ServerStorage.DebugInvoke:Invoke(cmd, "<you>", ...)`. Every command that changes the profile restores it and saves again.

| Command | Expect |
|---|---|
| `validate` (startup) | passes, including the new block |
| `fuseTest` | `pass = true`, `classOk`, `mutationFloorOk`, `incomeMatchesRarityConfig`, `inputsGone`, `storageDelta = -2`, and three refusal reasons |
| `fuseTest nil 0.999` | result mutation `Corrupted` |
| `fuseOdds 50000` | every `worstGapPercent` under ~0.5, `neverBelowFloor = true` |
| manual fusion | store 3 copies, then Storage > FUSE: pick the item, change the picks, check cost and odds, press FUSE. The spin animation plays, Storage updates and Cash drops by the shown cost. With VFX OFF, the plain fade plays instead. |
| `autoRevealTest full` (stand on your base, one pad free) | `pass`, with camera fly-in and roulette |
| `autoRevealTest quick` | `pass`, no camera, small pop and an "AUTO REVEAL" toast |
| `autoRevealTest off` | `pass`, nothing revealed |
| manual auto reveal | run `autoRevealOwn on`, then place 2-3 containers and wait. They reveal one after another, each in full. Walk into the museum while one is ready: the quick pop and toast play. Settings > Auto Reveal OFF stops it. Run `autoRevealOwn clear` at the end. |
| Shop (Studio) | the PASSES grid shows the Auto Reveal card greyed as NOT SET UP |
| `themeCycle 2` (with a trophy placed) | each theme repaints floor, fence and decor, then each skin repaints the pedestals, then the plot returns to its real look |
| `themeShow Lava Crystal`, then `themeClear` | preview and restore |
| `themeBuyTest` | `pass`; afterwards the profile and look are restored |
| manual themes | Upgrades > BASE: buy Sunset with Cash and it is equipped and painted. Place or store an item: the skin and pad accent survive the rebuild. A second player (Team Test) sees the theme. Leave and rejoin: the theme comes back, and the old plot returns to Classic for its next owner. |
| Robux themes | `themePassOwn ThemeNeonNight on`: the row shows EQUIP. Equip it, then `themePassOwn ThemeNeonNight off`: the plot falls back to Classic. |
