# Client pass + state push split (client agent)

Not run in Studio: the agent had no Studio access. Static check (`tools/check.sh`) shows no new hard errors. The only per-file count changes are `Remotes.luau` (58 -> 62) and `UIAnim.luau` (6 -> 7). Both are the existing "Expected type table, got nil" diagnostic, reported once more for each extra module that now requires those files.

## What changed, and why

### C1. State push split and the client StateStore
- **Server (`StateService`).** `build()` still returns the full snapshot, so `onPushed` listeners, debug commands and tests still see `state.inventory` and `state.index`. The split happens only on the wire:
  - `InventoryPush` carries `inventory`, and `IndexSummaryPush` carries `index`. Each is sent only when its JSON signature differs from what that player was last sent. Both fire *before* `StatePush`.
  - `StatePush` carries everything else.
  - A full resend happens on join (`pushNow(player, true)` plus the 12 re-marks in `init.server.luau`), on every `CharacterAdded`, and on the new client request `StateSyncRequest` (rate-limited to 1/s, burst 3).
- **Safety.**
  - `pushNow` is wrapped in `pcall`, and the push loop snapshots the dirty set before it iterates.
  - Every named provider (index, tutorial, carrying, monetization, groupGift) is now pcall-protected, the same way the extra providers already were.
  - `markDirty(player, full)` takes a second argument. The `EconomyService.onChanged` hookup is wrapped so a stray extra argument can never force a full resend.
- **New remotes.** One block at the end of `Remotes.NAMES`: `InventoryPush`, `IndexSummaryPush`, `StateSyncRequest`. The existing `IndexPush` (the full 96-entry discovery map) is **unchanged**, and `IndexController` still listens to it directly. It already had its own request/response sync.
- **Client (`src/client/StateStore.luau`).**
  - It is the only listener of StatePush, InventoryPush and IndexSummaryPush. It merges them into a fresh table per update, so `state.inventory` and `state.index` still exist.
  - `subscribe(fn)` replays the latest state (deferred) to late subscribers.
  - `onKeyChanged(key, fn)` and `get()` are also available.
  - If only a side channel arrives, subscribers are still notified after 0.1 s.
  - On start it fires `StateSyncRequest`, retrying every 3 s (up to 5 tries) until a state arrives.
- **Migration.** All 22 `Remotes.get("StatePush").OnClientEvent:Connect(` sites were replaced by `require(script.Parent.Parent.StateStore).subscribe(`. In ShopController, BossOfferController, OfferRailController and GuardianFxController (the latter had no connection), only that one line changed.
- **Behaviour change to know about.** All subscribers now receive the *same* table for a given update; before, each connection got its own copy. A grep found no handler that mutates `state`.

### C2. Controller startup (`init.client.luau`)
- `boot()` runs each `start` under `xpcall` and warns with a traceback.
- HUDController and HUDLayoutController still run first, in order, on the main thread. Everything below reads MainUI, and the layout pass must run before the nav buttons are cloned.
- Every other controller runs in its own `task.spawn`, in the original order, so the "after X" comments still hold for starts that don't yield.
- `EffectsController.start` no longer blocks HUD start for up to 20 s: its wait for GameAssets moved into a spawned thread.

### C3. Toast freeze
`retire()` now removes the toast from `live` before anything else. The loop that enforces `MAX_ON_SCREEN` is bounded and force-removes the toast if it is still first in the list. `show()` ignores a holder that is no longer parented.

### C4. Trophy and crate motion
- **New config** (`GameConfig`, validated): `CLIENT_MOTION_CULL_RADIUS = 250` and `CLIENT_FAR_MOTION_INTERVAL = 0.25`.
- **Near and far.** Near models move every frame. Far models are re-posed every 0.25 s on staggered timers. The angle is still read off the clock, so nothing freezes or snaps.
- **Batching.** New `Shared/Util/PivotBatch.luau` sends one `workspace:BulkMoveTo` per frame, using per-model part offsets.
  - Offsets are recaptured when a descendant is added or removed, when `GetScale()` changes (pop-in and reveal both use ScaleTo), and on a growth re-seat.
  - Models without a PrimaryPart fall back to `PivotTo`.
- **ItemArtMotion.**
  - It no longer has its own Heartbeat. `DisplayFxController` calls `ItemArtMotionController.step(now)` right after moving the trophies, which fixes the one-frame lag.
  - Trophies are registered from DescendantAdded/Removing into a retry set instead of a `GetDescendants` scan every 0.5 s.

### C5. Shift lock on touch
- **Fallback.** While locked, `Humanoid.AutoRotate` is off and a render step at Camera+1 turns the HumanoidRootPart to face the camera's yaw. The CameraOffset is kept.
- **When it stands aside** (and hands AutoRotate back): Health ≤ 0, PlatformStand, Sit, an anchored root, the `Rooted` attribute, Dead/Physics/Ragdoll/FallingDown/Seated states, and treadmill training.
- **Restore.** Turning the lock off unbinds the step and restores AutoRotate. A respawn re-applies the lock.
- **Desktop.** The character is untouched unless the touch button exists.

### C6. Hatch clock
Hatch cards now use `workspace:GetServerTimeNow()` everywhere, and card ticks are aligned to the server's whole seconds.

### C7. Interact line-of-sight
- One reused `RaycastParams` (`RespectCanCollide = true`) and one reused filter array.
- Each part's result is cached for 1/12 s, and cache entries are dropped when the prompt is hidden or removed.
- Behaviour fix: a non-collidable lamp in front of a wall no longer lets the card show through the wall.

### C8. Reduced Effects
- **New flag module** `Shared/Util/Effects.luau`: `isReduced`, `isLowGraphics`, change signals and `watch*` helpers. SettingsController sets it, and the old per-controller setters still run.
- **Now covered:**
  - EffectsController bursts (a third of the particles)
  - Chase warning (steady tint and a steady RUN!! label instead of the pulse)
  - GroupGift button and chest-sign rainbow (parked)
  - Portal, SlapDisplay and GuardianShop spins (held still)
  - DROP button breathing
  - Treadmill offer sheen, border drift and badge kick
  - `UIAnim.punch` (no-op) and `UIAnim.popIn` (instant)
- **Not covered: OfferRailController's rainbow.** That file belongs to another agent, so it was skipped. Fix it by returning early in its RenderStepped when `Effects.isReduced()` is true.

### C9. Graphics HIGH / LOW (new setting)
- **The row.** The Settings panel gets a **Graphics** row, cloned from the Shadows row and placed after VFX, with HIGH/LOW captions. It is saved as `Settings.LowGraphics`.
  - `SettingsService` validates it as a boolean.
  - No DataService edit was needed: a missing key reads as HIGH, and the reconcile step keeps unknown keys.
- **LOW mode** (new `GraphicsQualityController`) acts on `Map.Zones`:
  - Every Light under a `Decorations` folder is switched off, except each room's `RoomFill` light.
  - Every ParticleEmitter, Sparkles, Fire and Smoke under `Decorations` or `Weather` is switched off.
  - Trophy and crate spin and the item-art sparkles stop.
- **Reversible live.** HIGH re-enables only what LOW switched off.
- **Not done:** culling far decor. There was no cheap, safe way to do it.

### C10. Respawn HUD
- On respawn, only the `carry` and `treadmill` claims are released; panel claims survive.
- `applyRestored` no longer forces `was == nil` elements visible.

### C11. Touch target sizes
- **Settings gear.** The gear is now an invisible hit area sized to 44 ÷ MainUI's UIScale, so it stays 44 px on screen at the 0.72 phone scale. It follows scale changes, and the 44 px round face is unchanged.
- **Shift lock and Crouch.** Both are laid out from the real `TouchGui.TouchControlFrame.JumpButton` rectangle via `Device.jumpButton()`:
  - Both sit above Jump; Shift lock's right edge lines up with Jump's, and Crouch sits to its left.
  - Each is 60% of Jump's size, clamped to 48–72 px.
  - Both copy TouchGui's inset settings so the coordinates agree.
  - They re-check every 0.5 s (Shift lock) or 0.1 s (Crouch).
- **Touch/desktop switching.** New `Device.onTouchChanged` fires on LastInputTypeChanged and on TouchEnabled/KeyboardEnabled changes.
  - The Hotbar resizes, and the touch HUD layout is applied once if the session becomes touch.
  - Shift lock builds its button, or hides it and releases the lock.
  - `StarterTaskController` still decides its layout once, on purpose; its own comment says a mid-animation swap would lose its place.

### C12. `UIAnim.flashColor`
The resting colour is stored once, in the `_FlashBaseColor` attribute.

### C13. RenderStepped world animations
Portal, SlapDisplay, GuardianShop and GroupGift moved to Heartbeat. They skip work when far away: 300 / 250 / 250 / 220 studs respectively. The gift button also skips when it is hidden or the HUD is suppressed. OfferRail was skipped because another agent owns it.

### C14. Treadmill
- The fallback plot search runs at most once per second, and also runs when the trigger has been destroyed.
- Ownership listeners now attach to plots added later too, and to treadmill rebuilds on the player's own plot.

### C15. Shared workspace index
New `src/client/WorldIndex.luau` does one workspace scan and keeps one DescendantAdded/Removing connection. It indexes Sound, ProximityPrompt and BillboardGui by exact ClassName. Audio, Interact and Hatch now use `WorldIndex.watch`.

### C16. Treadmill offer border light
The rotation wrap is now applied to the current angle, so the light always tweens +40° and never spins backwards.

### C17. Hotbar
- Renders are coalesced to one per frame, so an equip no longer renders twice.
- A slot's lift tween is only created, and the previous one cancelled, when that slot's equipped state actually changes.

### C18. Inventory rows
When a row's content changes but its InstanceId stays the same, the card is rebuilt in place inside its existing slot.

### C19
Nothing depends on the place-only `UIAnimationHandler` LocalScript.

## Owner and lead actions
- Save the place after syncing: there are new ModuleScripts (StateStore, WorldIndex, Effects, PivotBatch, GraphicsQualityController, DebugCommands/Client).
- Place-only scripts that are not in the repo and listen to `StatePush` for `inventory` or `index` would stop seeing those fields. Search the place for `StatePush`.
- Check that the Settings ScrollingFrame shows the new Graphics row. If its CanvasSize is fixed, the row may be cut off, and CanvasSize (or AutomaticCanvasSize) will need adjusting.

## Measurement plan (StatePush size)
1. **Measure.** In Play, run `DebugInvoke:Invoke("statePushSizes", "<name>")` (also prints). Expect `statePushBytes` of about 1–1.3 KB. That is roughly the old ~6 KB minus inventory (~3.7 KB) and index (~1.2 KB), plus the unchanged fields.
2. **Watch the wire.** Open the Network stats (Shift+F3) or the MicroProfiler and watch the received-data rate while idle with income ticking. Per-second data should drop by about 80%.
3. **Check the side channels are quiet.** InventoryPush should appear only when you store, sell or display an item. IndexSummaryPush should appear only on a discovery or a claim.
4. **Force a resend.** `forceStatePush` sends all three immediately.

## Studio test plan
1. **Join (solo).** The HUD shows cash and income, and Storage shows the right count. No `[Client] X.start failed` warnings appear in the output.
2. **Store an item, sell it, and apply a mutation to a stored item.** The Storage row updates in place and its income and mutation are correct.
3. **Index panel.** The header counts are correct. Discover a new item and the summary updates.
4. **Toasts.** Spam more than the on-screen maximum (for example, repeated sells). There is no freeze.
5. **Trophies and crates.**
   - Stand at your base: trophies turn smoothly and procedural sub-parts move with their trophy, with no lag.
   - Walk more than 250 studs away and back: nothing snaps.
   - Hatch a reveal: the pop-in size is correct.
6. **Settings, VFX OFF.** The chase warning is a steady tint, and the gift, portal, slap and guardian-shop displays hold still. Also check that the DROP button stops breathing and that button punches stop.
7. **Settings, Graphics LOW.** Museum sconce lights and weather go off, room fill lights stay on, and trophies and crates stop turning. Switch back to HIGH: everything returns. Rejoin: the setting persists.
8. **Respawn while the gift panel is open.** The HUD stays hidden until the panel closes.
9. **Hatch countdown.** It matches the server's timing.
10. **Device emulator, phone (e.g. iPhone 14) and tablet (iPad).**
    - Shift-lock and Crouch buttons sit above Jump without overlapping it, on both.
    - The settings gear is easy to tap.
    - Hotbar slots are 58 px.
    - With Shift lock ON, walk and turn the camera: the character faces the camera direction.
    - With Shift lock ON, use the treadmill, get ragdolled, and sit: none of them fight the lock.
    - Turn Shift lock OFF: normal rotation returns.
    - Switch the emulator back to desktop: the Shift lock button hides.
11. **Interact card.** It does not show through museum walls, and does show past decor.
