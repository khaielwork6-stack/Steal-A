# Place-owned scripts (mirror, not synced)

These scripts live inside the Studio place, under UI that Rojo does not manage,
so Rojo cannot sync them without taking over (and resetting) the purchased UI
pack. This folder is a **version-controlled copy** so changes can be reviewed
and rolled back. It is not listed in `default.project.json`.

| File | Lives in the place at |
|---|---|
| `StarterGui/MainUI/LocalScript.client.luau` | `StarterGui.MainUI.LocalScript` (the UI pack's "UIAnimationHandler": panel slide-in, blur, button feedback, notifications, `F` opens Inventory) |

When you edit one of these in Studio, paste the new source here in the same
commit as any code that depends on it. When you edit it here, paste it into
Studio and save the place.
