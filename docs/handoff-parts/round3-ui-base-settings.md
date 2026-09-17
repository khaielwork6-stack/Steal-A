# Upgrades BASE tab and Settings panel fixes (area: round3-ui-base-settings)

Not run in Studio (no Studio access). `tools/check.sh`: no hard errors, and
every per-file TypeError count equals the baseline (the new files report 0).
`selene src`: 0 errors.

## What was wrong

### Controls drawing outside their panel (both bugs)
- **Upgrades > BASE.** EQUIP / price buttons rendered above the header and
  below the panel while the rows around them were clipped.
- **Settings.** A green "ON" bar floated over the panel title.

In both cases the escaping element was a **pack button**: the BASE rows used a
clone of the treadmill card's `Money` button, and the Settings rows use the
pack's `ON` / `OFF` buttons. Our own plain rows were always clipped. Roblox's
clip (a ScrollingFrame's, or `ClipsDescendants`) is a screen-aligned scissor
and does not apply to rotated GuiObjects; the pack's LocalScript and
`UIAnim.bindButton` both give every button a rotation punch, and the pack art
may carry a resting tilt. An unclipped high-ZIndex button then draws over the
header. I could not open the place to confirm which pack detail it is, so
the fix does not depend on it:

1. **No pack buttons in the BASE list any more** (see below).
2. **`Shared/Util/ClipSafe.luau` (new).**
   - `watch(list)` holds every GuiObject in the list at Rotation 0, marks
     buttons `_NoRotationPunch` / `_NoRipple` (UIAnim now honours both), and
     snaps back the pack's own punch on its authored buttons.
   - `guard(list)` wraps the list in a CanvasGroup of the same rectangle. A
     CanvasGroup renders its subtree into one texture of its own size, so
     nothing inside can draw outside it, whatever the cause.
   - TextBoxes and ViewportFrames are kept out of guards on purpose.
   - Kill switch: `ClipSafe.USE_CANVAS_GROUP = false` (layer 1 stays on).

### Settings CODES row
The old row cloned the whole Shadows row, destroyed the toggle pair's layout
and sized the ON button to fill the pair. The pair's frame spans the row, so
the green button covered the title and the box, and REDEEM sat under the
pack's face.

## What was built

### Upgrades > BASE (`BaseThemeController`, rewritten)
**Decision: kept inside the Upgrades panel, not a second panel.** One tap
(BASE tab) instead of two, and the panel is scaled up while BASE is open.
- **Scale boost.** ×1.15 via a new `setBoost` hook. `UpgradesController`'s
  fit pass multiplies it in and still steps the scale down until the panel
  fits. The pass now checks left/right edges as well as top/bottom.
- **Tab bar.** Two large pills (94% wide, 11.5% tall, min 40 px), each with an
  icon. The active tab is green with a white edge.
  - Icons: `BaseThemeConfig.UiIcons.TabTreadmill` (falls back to the pack's
    upgrade arrow) and `TabBase` (falls back to a drawn mini plot).
  - The treadmill card moved to y 0.14, height 0.85.
- **Banner.** Fixed, not scrolled, 27% of the page.
  - The existing turning 3D diorama was kept (it reads well), but moved out
    of the list so the ViewportFrame is outside the clip guard.
  - Text: "CURRENTLY EQUIPPED", the theme name and "Pedestal: X".
  - Tapping a card shows it here as "PREVIEW"; BACK returns to the equipped
    look. It still turns only while visible, and not under Reduced Effects.
- **Grid.** A ScrollingFrame with AutomaticCanvasSize, wrapped by
  `ClipSafe.guard`, holding:
  - THEMES: 2 columns once the list is at least 430 px wide on screen,
    otherwise 1.
  - PEDESTAL SKINS: 3 columns, otherwise 2.
  - Section headers with an "N / M OWNED" count.
  - Cell sizes are pre-UIScale offsets, worked out from the list's real
    width with `ClipSafe.scaleChain`, and follow resizes.
- **Theme card.**
  - Preview tile: a Frames-only diorama in the theme's colours (accent sky,
    fence with neon caps, floor with a paved path, pedestal and orb, gate
    decor). The thumbnail image replaces it once its id is set.
  - Name and short description.
  - Tier pill: FREE / COMMON (<$1M) / RARE (<$100M) / EPIC (<$10B) /
    LEGENDARY / EXCLUSIVE (Robux). The price beside it is red when you
    can't afford it, and reads OWNED once owned.
  - One full-width button, at least 46 units tall:
    - `BUY $X`: green; grey if unaffordable, and tapping it then shows
      "You need $X more."
    - `R$ X`: gold.
    - `EQUIP`: blue.
    - `✓ EQUIPPED`: inactive.
    - `NOT SET UP`: shown for a pass with id 0 in Studio.
- **Owned and equipped.**
  - Owned: green check badge and a soft green edge.
  - Equipped: a bright green edge that breathes (static under Reduced
    Effects) and a green plate.
  - A new unlock shines the tile, and a newly equipped card punches.
- **Pedestal card.** The material swatch (a column under a spotlight, with
  trim ring and material name), the name, and the same button (`BUY $X`
  carries the price).
- **Pack look without pack clones.** Dark plate, ink stroke, vertical
  gradient face, the pack's studs texture (`76728843491214`) and FredokaOne.
  - Buttons use a local scale-only press feedback and are stamped
    `_UIHandlerSetup` so the pack script leaves them alone.
  - ZIndex is 4 or higher throughout.
- **Unchanged.** Server contract, remotes and the StatePush `baseTheme`
  field. Robux cards are still hidden while not offered.

### Settings (`SettingsController.arrange`, `CodesController`, rewritten)
- **CODES bar.** Pinned **above** the list, so it is always first, never
  scrolls away, and its TextBox is outside the CanvasGroup.
  - Its look comes from a pristine copy of the Shadows row, taken before
    any row is bound. Only the plate, stroke, gradient, full-size textures
    and the title label (font) are kept.
  - Contents: a gift icon (`CodesConfig.HEADER_ICON`, or a drawn gift) and
    CODES; a rounded "Enter code" box; a green REDEEM button; and a result
    line under the box.
  - The result line is green on success, red on failure ("Checking..."
    while waiting) and clears after 6 s. The server's toast still shows.
  - Height: 1.45× a toggle row, minimum 92 px on touch and 66 px on
    desktop.
  - `CodesController.start` now only listens to `RedeemCodeResult`;
    SettingsController builds the bar.
- **Row order.** `SortOrder = LayoutOrder`, forced: Music 10, Sound_Effects
  20, Shadows 30, VFX 40, Graphics 50, AutoReveal 60; unknown rows follow.
- **Row sizes.**
  - Each row keeps the width:height ratio the pack authored (measured once).
    The Graphics and Auto Reveal copies use the Shadows ratio.
  - That ratio is written as a pixel height, minimum 62 px on touch and
    42 px on desktop. Aspect constraints on rows are removed, and a
    UIGridLayout, if present, is replaced by a UIListLayout.
  - The list then uses `AutomaticCanvasSize = Y` with no feedback loop, so
    the canvas always fits the added rows.
- **Clip guard.** The list is wrapped by `ClipSafe.guard` and `watch`. The
  new wrapper frame `Frames.Settings.SettingsBody` holds the bar and the
  guard.
- **Toggles.** The chosen word is bright and the other faded to 50%. Row
  titles have a minimum text size of 12.

### Small shared edits
- `UIAnim.punchRotation` and `UIAnim.ripple` skip buttons marked by
  ClipSafe.
- `BaseThemeConfig.UiIcons`, with one small validate block.

## Owner actions
- **Art.** `docs/codex-prompts/round3.md`, section "Upgrades BASE tab &
  Settings": 8 theme previews, 5 pedestal previews, 2 tab icons, 2 section
  icons and the CODES icon. It supersedes the thumbnail sizes in
  `fusion-autoreveal-bases.md`, because cards are wide.
- **No new products, passes or remotes.**
- **Save the place** after syncing: there is one new ModuleScript,
  `Shared.Util.ClipSafe`.

## Lead: please verify
- **CanvasGroup quality.** Text in the Settings list and the BASE grid
  should look as sharp as before, on a phone too. If it does not, set
  `ClipSafe.USE_CANVAS_GROUP = false` and run `uiAudit`; the rotation layer
  alone should still stop the escape.
- **Settings sizes.**
  - Row heights should look like the pack's.
  - If a slider row looks squashed, its authored ratio could not be
    measured and `DEFAULT_RATIO` (6.5) was used. Fix the ratio in
    `SettingsController`.
  - The CODES bar must not cover the header (it sits at the list's old top
    edge).
- **Panel scale.** Upgrades on a 1366x768 laptop and a phone: the BASE boost
  must not push the panel off-screen (the fit pass steps it down), and
  switching tabs changes the scale instantly.
- **ZIndex.** If MainUI uses Global ZIndexBehavior and cards render under
  the panel background, raise the base ZIndex (4) in BaseThemeController.

## Studio test plan
Invoke with `ServerStorage.DebugInvoke:Invoke(cmd, "<you>", ...)`.

| Step | Expect |
|---|---|
| Open Upgrades | Two big tabs with icons; TREADMILL is lit; the treadmill card is intact below them. |
| Click BASE | The panel grows a little and stays on-screen. The banner shows your equipped theme turning, with "CURRENTLY EQUIPPED". The THEMES cards are in 2 columns (1 on a narrow phone), then PEDESTAL SKINS. |
| Scroll the grid to both ends, fast, with mouse and touch (emulator) | Nothing draws above the tabs, below the panel or over the world. |
| `uiAudit` with Upgrades open on BASE, then with Settings open | The client output shows `clipGuards=1`, `rotated=0` and `outsidePanelUnguarded=0`; anything listed is pack decoration to eyeball. |
| `baseUiPreview on`, open BASE | Sunset and White Marble show `✓ EQUIPPED` with a breathing green edge. Classic, Midnight, Neon Night and Museum Stone show EQUIP with a check badge. Jungle and Obsidian show a green BUY. Frost, Lava, Solid Gold and Crystal show a grey BUY with a red price (a tap gives "You need $X more."). Royal Gold shows gold `R$ 149`. Any button gives "Preview mode: nothing was sent." Screenshot at desktop and phone sizes. |
| `baseUiPreview off` | Real data again. |
| Tap a card body | The banner shows PREVIEW with that theme or skin, plus BACK; BACK returns to the equipped look. |
| Real buy (enough Cash) | The card shines, turns EQUIPPED and the plot repaints; the count goes up. |
| `baseUiLive on` | Neon Night and Royal Gold show EQUIP; equipping one repaints the plot and the card turns EQUIPPED. |
| `baseUiLive off` | The overrides clear; the previously equipped theme and pedestal come back and are saved. |
| VFX OFF in Settings | The banner model and the equipped edge hold still; no press scale. |
| Settings panel | The CODES bar sits at the top (icon, CODES, box, REDEEM). Below it: Music, Sound Effects, Shadows, VFX, Graphics, then Auto Reveal (pass owners only). The list scrolls to the last row. There is no green bar over the title. |
| Type `MUSEUM`, press REDEEM (or Enter) | "Checking..." then a green line and a toast; the box clears. Again: a red line ("already redeemed") and a toast. Empty box: a red "Type a code first." |
| Toggle each row | The chosen word is bright and the other faded; the setting applies; a rejoin restores it. |
| Phone emulator (MainUI scale 0.72) | Rows are at least about 62 px, and the REDEEM button, box and toggles are easy to tap. |
