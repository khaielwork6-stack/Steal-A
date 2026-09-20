# Hold it in your hands (area: hold-items)

Nothing here was run in Studio (rule 1 - no Studio MCP, never launch Studio).
`bash tools/check.sh` reports the hard-errors section empty; `selene src`
reports 0 errors, 0 new warnings. Several existing files still show their
pre-existing TypeError counts (LootService, BaseGuardianService, DataService,
Remotes, HatchService, PlacementService...) - none of these are new; they are
the checker repeating existing diagnostics once more for every module that
now requires a file this pass touched.

## 2026-09-20 REWORK (hotbar, overflow, Store it) - this section wins

Where the text below disagrees (a 6-item cap, keys 6-0, "Hands full", the
"Picked up"/"PLACED" toasts, `holdFullTest`), THIS section is current. Nothing
was run in Studio (rule 1); check.sh hard errors empty, selene 0 errors.

**Rules settled**

1. **No pickup/place toasts.** `HoldService.pickup`, `HoldService.place` and
   `PlacementService.equip` (Storage DISPLAY) no longer call notify on success.
   Errors still toast. The pad ProximityPrompt text ("Pick up <name>" /
   "Place") is unchanged.
2. **Positional, compact hotbar, max 10.** Slots are
   `[1 Slap/Bat][2 Trap][owned gadgets in GadgetConfig order][held items in
   pickup order]`, numbered consecutively, only occupied slots drawn (no empty
   dark placeholders). Keys 1-9 and 0 (= 10th) equip by position; a tap
   equips too. A gadget's key is now its position (with no gadgets, the first
   held item is 3). While carrying, only gadget slots show (still above DROP,
   keeping their positional numbers) and pressing one calls
   `GadgetController.quickUse`; held items are hidden. `HotbarController`
   keeps a fixed pool of 10 slot buttons (all from the pack's MenuButtons
   slot: same frame, key number, size, lift, ViewportFrame icon, name label)
   and repaints a slot only when its content id changes, so a rebuild never
   re-tweens unchanged slots.
3. **Overflow inventory.** Held items past the hotbar's room (10 minus
   tools/gadgets) live in `HeldOverflowController`'s panel (backtick =
   `HoldConfig.OVERFLOW_KEY`; a "Bag +N" button beside the hotbar on touch;
   Escape/X/picking closes). Grid of rarity-bordered tiles with the name under
   each, scrolls, handles 90; viewports are made lazily as tiles scroll in.
   Tapping a tile sends `HoldRequest("equip", rank)`.
4. **Server and client agree by position only.** `src/shared/Util/HeldLayout`
   (`rank`, `capacity`) is the one ordering: Held Inventory entries by
   `HeldOrder` asc; ranks `1..capacity` are on the hotbar, the rest overflow.
   The server derives `capacity` from the player's Tool count (`toolCount`).
   Equipping an overflow rank, or picking up / `hold()`ing while the bar is
   full, puts that item in the LAST hotbar position and pushes the least
   recently used hotbar item (in-memory use clock, unknown = oldest, ties by
   lowest position) to the overflow - `activate()` re-deals the existing
   `HeldOrder` values in the new sequence. The equipped item is therefore
   always on the hotbar (unless tools fill all 10).
5. **No hand cap.** `HoldConfig.MAX_HELD_ITEMS` is now the largest Storage
   tier's capacity (90), a validation/UI ceiling only; the "Hands full"
   refusal is gone. Storage capacity ("Storage full") is the only bound.
   Held items still refuse sell / trade / fuse / display-from-storage
   (unchanged code).
6. **"Store it" button.** `HeldOverflowController`, own ScreenGui
   `HeldExtrasUI` (added to `UIStateController.HUD_SCREENS`, not to
   SCREEN_KEEP, so a carry or any panel/reveal claim hides it and closes the
   open overflow). 96x40 (44 tall on touch), mid-right (touch: left of the
   offer-rail column, above the event pills). Slides in/out; instant when
   `Effects.isReduced()`. Fires `HoldRequest("store")` (no arguments).
7. **New server action** `HoldService.store(player)` on `HoldRequest` action
   `"store"`: same 4/s limiter; resolves the active item itself, clears
   `Held/HeldOrder/HeldActive` (item stays in Inventory), the newest remaining
   held item becomes active; refused with "You are not holding anything." when
   empty-handed.

**Public API (Relic Roll calls it; do not rename)**
- `HoldService.hold(player, instanceId): (boolean, string?)` - item in
  Inventory, not held -> Held with next HeldOrder, active, visual + push
  refreshed; false only for no profile / not in Storage / already held. Same
  atomic (no-yield) `markHeld` path as pickup.
- `HoldService.holdMany(player, ids)` - in the given order, LAST is active,
  one refresh; unholdable ids are skipped and the first reason returned.
- Also `HoldService.hotbarCapacity(player)`.

**Files** (this pass): `src/shared/Util/HeldLayout.luau` (new),
`src/client/Controllers/HeldOverflowController.luau` (new),
`HotbarController.luau` (rewritten), `HoldService.luau`, `HoldConfig.luau`,
`validate.luau`, `Remotes.luau` (comment only), `PlacementService.luau`
(PLACED toast), `UIStateController.luau` (HUD_SCREENS), `init.client.luau`,
`DebugCommands/HoldItems.luau`.

**Debug suite** (`holdSuite` runs all, each restores the profile even on
error): `holdFullTest` (no cap, 14 held), `holdPositionTest` (0 vs 2 gadgets,
overflow counts), `holdOverflowTest` (active always on the bar, overflow swap),
`holdFromStorageTest` (hold/holdMany), `holdStoreTest`, `holdNoToastTest`,
plus the existing pickup/place/race/persist/titan tests.

**Studio checklist (not verifiable without Studio):** slot look identical
across tools and items on desktop and phone; icon framing of odd item models;
10th slot label reads "0"; backtick does not clash with a Studio/console
shortcut; Store it position on a short phone screen vs offer rail and event
pills; overflow panel with 90 tiles (scroll + lazy viewports); the bar
width/center while slots appear and disappear; gadget quick use during a carry
by position; hotbar re-render with no flicker while a StatePush arrives.

## What it does

Walk up to your own base pad holding a revealed trophy: the prompt reads
**"Pick up \<name\>"**. Press it and the trophy leaves the pad, appears small
in your hands with a rarity-coloured outline, and takes the next hotbar hand
slot. Walk to any empty pad (not carrying stolen loot): the prompt reads
**"Place"**. Press it and the currently-shown held item goes down there full
size, income resumes, and the hand slot it occupied is freed. Pick up a
second item and your hand becomes 1, 2 - the newest one is the one shown
small and it is what a **1** key (or a tap) would place. Tap or number-key
another hand slot to switch which one is shown, exactly like switching tools.

## The model: a held item is a flagged Storage entry, not a new list

`DataService.DisplayItem` (used for both `profile.DisplayItems`, the pads,
and `profile.Inventory`, Storage) gets three new optional fields, additive,
no schema bump:

- `Held: boolean?` - true while this Storage entry is "in your hands"
  instead of plain storage.
- `HeldOrder: number?` - a per-player, ever-increasing pickup counter,
  stamped once per pickup.
- `HeldActive: boolean?` - true on the ONE held item currently shown small;
  at most one at a time.

**Why not a new list.** A held item is a real Inventory (Storage) entry with
two flags on it - the exact same table that used to sit in `DisplayItems`,
just moved list. That means every existing guarantee about Storage is true
of a held item for free: it is real (moving the same table is how
`PlacementService.store`/`.equip` already worked - no new duplication path),
it still counts against `StorageConfig` capacity, it is saved on every
profile save, and it survives a leave/crash/server-hop/death exactly as any
other stored item, because nothing new had to be taught to `DataService`
about persistence.

**Hand-slot numbering, without ever renumbering anything.** Nothing rewrites
a slot number on a pickup or a place. A held item's `HeldOrder` is stamped
once; the hand-slot number shown (1..`HoldConfig.MAX_HELD_ITEMS`, currently
6) is the RANK of a held item's `HeldOrder` among the currently-held set,
recomputed fresh, live, on both the server (`HoldService.equip`,
`heldInOrder`) and the client (`HotbarController`, sorting the same field out
of the ordinary `inventory` push). Place item 1 while holding 1/2/3 and 2, 3
become 1, 2 automatically - nothing had to notice or react to the place.

## Files

- `src/shared/Config/HoldConfig.luau` - `MAX_HELD_ITEMS` (6),
  `HELD_TARGET_LONGEST_SIDE` (2 studs), the hand offset, outline
  transparency, billboard `MaxDistance`. Validated in
  `src/shared/Config/validate.luau` (new `HOLD ITEMS` block).
- `src/server/Services/DataService.luau` - the three new `DisplayItem`
  fields (comment-marked `[hold-items]`), plus a small DEFENSIVE block at the
  end of `reconcile()` (not a migration - every field is optional and a
  missing one already reads as "not held"): a `DisplayItems` entry can never
  carry `Held` (a pad and a hand are not the same place), and at most one
  `Inventory` entry may carry `HeldActive`. Runs on every load AND every
  server hop, so a corrupted save self-heals instead of confusing
  `HoldService` forever.
- `src/server/Services/HoldService.luau` (new) - `pickup`, `place`, `equip`,
  `heldCount`/`isHolding`/`activeHeld` (read-only helpers other services can
  ask), `refreshHeldVisual` (builds/welds the small hand model + rarity
  Highlight), and `start()` (the `HoldRequest` remote, respawn re-attach,
  hooks into `BaseService.onRebuilt`).
- `src/server/Services/PlacementService.luau` - `refreshPrompts` now labels
  an occupied, revealed slot **"Pick up \<name\>"** instead of "Store"; the
  `ProximityPromptService.PromptTriggered` dispatcher routes an occupied
  revealed slot to `HoldService.pickup` and an empty slot to
  `HoldService.place` UNLESS the player is currently carrying stolen loot (see
  "Two different Place" below), in which case the existing
  `PlacementService.place` (deliver-the-carry) still wins. `PlacementService.
  store`/`.equip` are unchanged and still reachable (Debug bridge, the raw
  `InventoryRequest("store", slot)` action) for anything that wants a
  held-less store; nothing in the shipped game calls them from the pad any
  more. Added `Held` refusals to `.equip` and `.sellStored` (see "Interaction
  with the rest of the game" below).
- `src/shared/Remotes.luau` - `HoldRequest` (client -> server), one new
  contiguous block at the end. `("pickup", padSlotIndex)`,
  `("place", padSlotIndex)`, `("equip", handSlotRank)`. No item ids, no
  amounts - every argument is an index the server re-resolves itself.
  `GameConfig.RATE_LIMITS.HoldRequest = 4`.
- `src/server/Services/AnalyticsEvents.luau` - `ItemPickedUp` / `ItemPlaced`
  added to `CUSTOM_EVENTS`. Fields: rarity name and a small `"nN"` hand-count
  bucket - never an item id or name (keeps cardinality low, per the rule).
- `src/server/Services/FusionService.luau`, `TradeLogic.luau` - a held item
  refuses fusion/trading with "Place it (before trading it)!" (see below).
- `src/client/Controllers/HotbarController.luau` - up to
  `HoldConfig.MAX_HELD_ITEMS` extra slots appended after the tool slots
  (5 -> up to 11), built from a pristine clone of the pack's own slot button
  so they match pixel-for-pixel. Icon = `ItemThumb.apply` (the same
  ViewportFrame-on-a-plate the Storage panel uses), name = the item's
  `LootConfig` name, equipped highlight = `HeldActive`. Data comes from the
  ordinary `inventory` field already pushed for Storage (`InventoryPush`) -
  filtered to `Held`, ranked by `HeldOrder` - so no new push channel exists.
  Hidden entirely while carrying stolen loot (`GADGET_SLOTS`-style rule).
  Keys 6, 7, 8, 9, 0 equip hand ranks 1-5; a 6th held item (rank 6, slot 11)
  is tap/click-only - there is no key left on the row for it.
- `src/client/Controllers/HeldItemFxController.luau` (new) - the small
  name/rarity/income-per-second billboard over a holder's head. Built
  CLIENT-SIDE, per viewer, off the held model's attributes
  (`HeldItem`/`HeldItemName`/`HeldRarity`/`HeldIncomePerSec`), specifically
  so each viewer can skip it under their OWN Low Graphics setting
  (`Effects.isLowGraphics()`) and so `BillboardGui.MaxDistance` gives "hide it
  while far away" for free, per viewer, with zero server work. Started from
  `src/client/init.client.luau` next to `GuardianFxController`.
- `src/client/Controllers/InventoryController.luau` - a Storage card for a
  held item now shows an **"IN HANDS"** tag first in its variant row.
- `src/server/Services/DebugCommands/HoldItems.luau` (new) - see Studio test
  plan below.

## Design decisions the brief left open

**The visual is server-built, the billboard is client-built.** The small
hand model is gameplay-adjacent geometry (everyone must see the same held
item on the same character), so `HoldService.refreshHeldVisual` builds and
welds it on the server, exactly like `BaseService.buildTrophy` and
`CarryService`'s stolen-loot carry already do. The info billboard is pure
decoration read off that model's attributes, so it is built PER VIEWER on
the client instead (`HeldItemFxController`) - the only way to honour each
viewer's own Effects/Low Graphics setting and to skip building 6 billboards
a server would otherwise have to build once per viewer anyway.

**Normalisation ignores the item's real Scale entirely.** `LootModel.build`
is called with `sizeScale = 1` and no footprint cap (always "Normal" size),
then the built model is measured (`LootModel.visibleExtents`) and rescaled
again so its longest side is exactly `HoldConfig.HELD_TARGET_LONGEST_SIDE`
(2 studs) - regardless of whether the real item is a coin or a Colossal. This
is simpler and more robust than trying to shrink-from-real-size: a Titan and
a coin measure differently going IN, but come out looking the same tiny size
either way, which is exactly "a Titan shows very small when you hold it, but
big when you place it" from the brief. No `SizeAura` is applied to the hand
model - that effect is authored around a pedestal-sized item and would
swallow a two-stud trinket whole; `MutationVfx` still applies (scaled to the
tiny size automatically, same as any other model it dresses), so a
Corrupted/Golden/etc. item still reads as its mutation in the hand.

**Base steals cannot touch a held item - stated as a deliberate rule.**
`HeistService` only ever reads/writes `profile.DisplayItems` (what is
physically on a pad); a held item has already left that list by the time it
is in someone's hands, exactly like a plain stored item already was safe.
An item in your hands is not on your base, so it is exactly as safe from a
night raid or a bat thief as anything already in Storage - **never safer,
never less safe than Storage already was.** This needed no new code; it falls
straight out of "held = an Inventory entry."

**Fusion / trading / selling refuse a held item; the Storage/Display button
does too.** The brief allowed either "refuse until placed" or "the UI
handles the flag"; refusing is the safer of the two (it can never silently
consume or move the one item the player is actively looking at in their
hands), so:
- `FusionService.fuse` refuses a `Held` input with "Place it first!".
- `PlacementService.sellStored` refuses a `Held` item the same way.
- `PlacementService.equip` (Storage panel's DISPLAY button) refuses a `Held`
  item with "Place it from your hands instead." - going through the ordinary
  equip path would leave an item flagged `Held` while ALSO standing on a pad
  and earning, which `HoldService.activeHeld`/the hand visual and
  `EconomyService` would then disagree about.
- `TradeLogic.itemTradable` refuses a `Held` item with "Place it before
  trading it." - it is checked both when adding an item to an offer and
  again at the swap, so a held item can never enter a trade in the first
  place.
- The Storage panel's card additionally shows an **"IN HANDS"** tag so the
  refusal is never a surprise; the buttons themselves are left connected
  (a clear server toast beats a client-side maze of disabled states, and the
  server is always the one deciding "handled safely" here anyway).
- `DataService.reconcile`'s defensive block (see above) is the backstop if
  any of this is ever bypassed by a bug: a `Held` flag on a `DisplayItems`
  entry is stripped on the very next load/rejoin.

**Two different "Place".** An empty pad's prompt always reads "Place", but it
can mean two different things depending on what the player is holding:
carried STOLEN loot (the core loop's payoff, `CarryService.getCarried`) or a
held BASE item (`HoldService.place`). The `ProximityPromptTriggered`
dispatcher in `PlacementService.start()` picks stolen loot first when both
are true, so a player mid-delivery can never have that press silently
swallowed by an unrelated base item; `HoldRequest("place", padId)` fired
directly (bypassing the prompt) only ever places a held item; the client
never sends slot ids for the stolen-carry path (that is still
`PlaceLootRequest`/the `ProximityPrompt` alone), so no client argument
decides which "Place" happens - the server does, from its own state.

**Idempotency / atomicity without a lock.** `pickup`/`place`/`equip` each
read the profile fresh, decide, and mutate - with NO yield anywhere in
between - so two requests for the same player can never interleave (Roblox
runs one `RemoteEvent` handler to completion before the next queued one
starts, as long as neither yields, and none of these do). A second, racing
request simply sees the state the first one already produced and is refused
on ordinary grounds ("Nothing to pick up there.", "You are not holding
anything.") rather than double-moving anything. See `holdRaceTest` below.

**Keys 6, 7, 8, 9, 0 for hand ranks 1-5; rank 6 is tap-only.** The design
note asked for "keys continue numbering" after the existing tool slots
(1-5); there are only 5 number-row keys left once 1-5 are taken, so the 6th
possible held item (`HoldConfig.MAX_HELD_ITEMS`) has no key of its own and
is switched to by tapping/clicking its hotbar slot, exactly like every
tool slot already supports both a key and a tap.

**"Hands full" is a hard cap, separate from Storage capacity.** Both are
checked on pickup: `HoldConfig.MAX_HELD_ITEMS` (6, a hand/UI limit) and
`StorageConfig.capacityForTier` (an economy limit, since a held item still
occupies a Storage slot). Either one can refuse a pickup; the messages are
"Hands full - place something first." and "Storage full - sell something
first." respectively, so the reason is never ambiguous.

## Owner actions

None. No new Robux products, gamepasses, badges, or Creator Dashboard
entries. No new art needed - the held model reuses the same `LootModel`
pipeline (and its placeholder-block fallback) every other trophy already
uses; the outline is a plain `Highlight` instance, not an asset; the pickup/
place sounds reuse the existing `StoredItem`/`PlaceItem` sound keys rather
than asking for new ones.

## Studio test plan

All commands live in `src/server/Services/DebugCommands/HoldItems.luau` and
run through `ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...)`
(see the README in that folder). Every one snapshots
`DisplayItems`/`Inventory`, runs in `pcall`, and restores them afterward even
on an error or an assertion failure - safe to run repeatedly against a real
account. Each returns a table with a `pass` boolean plus the numbers it
checked, so a failure is diagnosable from the Studio output alone.

1. **`holdPickupTest [itemId]`** - places a Giant/Shiny trophy on a free pad,
   records its income and an exact fingerprint of its economy/visual fields,
   picks it up, and checks: it left the pad, it is `Held` + `HeldActive` in
   Storage, `SlotIndex == 0`, income dropped by exactly its rate, and every
   preserved field (`Scale`, `VisualScale`, `Mutation`, `BaseIncome`,
   `FinalIncome`, `GrowthSeconds`, `MaturationSeconds`, `Hatched`) is
   byte-identical to before the pickup.
2. **`holdPlaceTest [itemId]`** - the same, then places it on a SECOND free
   pad and checks it left the held set, landed on the requested slot, income
   came back to exactly what it was before pickup, and the fields are still
   preserved.
3. **`holdFullTest`** - fills all `HoldConfig.MAX_HELD_ITEMS` (6) hand slots
   from separate pads, then tries a 7th: must be refused with the EXACT
   string `"Hands full - place something first."`, and the 7th item must
   still be sitting on its pad (not moved).
4. **`holdRaceTest [itemId]`** - fires `pickup()` twice back-to-back with no
   yield between them (the shape a doubled remote/prompt trigger would take),
   then `place()` twice the same way. Checks the first of each pair succeeds,
   the second is refused cleanly ("Nothing to pick up there." /
   "You are not holding anything."), and exactly one item ends up held after
   the doubled pickup - never two, never zero.
5. **`holdPersistTest`** - builds a correctly-held item PLUS two
   deliberately-corrupted ones (a second item wrongly flagged `HeldActive`,
   and a `DisplayItems` entry wrongly flagged `Held`), runs
   `DataService.reconcile` - the exact pass every load, rejoin and server hop
   already runs - and checks the real held item survives untouched while
   both corrupted states are cleaned up. This is the "leave and rejoin"
   simulation: it exercises the same code path a real disconnect/reconnect
   would, without needing two Studio clients.
6. **`holdTitanScaleTest [itemId]`** - picks up a Colossal-scale copy (the
   biggest `ScaleConfig` variant) and measures the actual built hand model
   on the test player's character: its longest side must be at
   `HoldConfig.HELD_TARGET_LONGEST_SIDE` regardless of how big the trophy's
   placed (full-size) `Scale` is. **Needs a live, spawned test player** (it
   reads `player.Character.HeldItemVisual`) - run it in Play mode, not from
   the command bar against an offline profile.
7. **`holdSuite [itemId]`** - runs all six above in order and returns one
   `{ pass, results }` summary; the fastest way to smoke-test the whole
   feature after any later change nearby.

**Manual pass, once the automated commands are green:** walk to a base with
a couple of revealed trophies on it. Confirm the pad prompt reads
"Pick up \<name\>"; pick two up; confirm the hotbar grows two slots after
the existing tools, the second one lit as equipped, and a small rarity-
outlined trophy appears in front of your character with a name/rarity/income
billboard over your head. Tap hand slot 1 (or press its key) and confirm the
model swaps to the first item. Walk to an empty pad and confirm it reads
"Place"; press it and confirm the item lands full size, the pad starts
paying again, and the hand slot disappears. Toggle Low Graphics in Settings
and confirm the billboard disappears immediately without needing another
pickup. Steal a container from the museum while already holding a base item
and confirm the hand slots vanish from the hotbar until you drop or deliver
the stolen loot.
