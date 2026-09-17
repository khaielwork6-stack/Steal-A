# Codex prompt: fusion, Auto Reveal and base themes art

You are making art for the Roblox game "Steal & Run!", a cartoon museum-heist
game. Upload each asset to Roblox and paste the resulting asset id where it
says. Do not change anything else in the code.

**2D style.** Match the purchased UI pack:
- glossy cartoon look with a thick dark outline (about 6-8 px at 512 px);
- bright top-to-bottom gradients, a soft inner highlight and a light sparkle;
- transparent background (PNG);
- no text in the image unless a row below asks for it.

**3D style.** Stylised realism, like the museum loot:
- clean readable shapes and PBR-ish materials;
- under 2,000 triangles per prop;
- a single Model, with a PrimaryPart at the base centre and +Y up;
- every part Anchored, with CanCollide, CanTouch and CanQuery all false;
- no scripts.

Paste ids as `"rbxassetid://<id>"` unless a row says otherwise.

## 1. Fusion machine icon
- **Used in.** The fusion result popup, above "FUSION COMPLETE!".
- **Size.** 512x512, square.
- **Look.** A small glowing fusion machine:
  - a chunky metal base with two curved arms and a purple/cyan energy orb between them;
  - three tiny item silhouettes spiralling into the orb;
  - a purple-to-magenta glow.
- **Where the id goes.** `src/shared/Config/FusionConfig.luau`, `FusionConfig.ICON`.

## 2. Auto Reveal pass icon
- **Used in.** The Shop > PASSES card, and as the Game Pass thumbnail on the Creator Dashboard.
- **Size.** 512x512, square.
- **Look.**
  - A sealed mystery crate popping open by itself, with a golden clock/stopwatch badge in the corner and a small "auto" circular-arrow motif.
  - Purple and gold palette, to match the card tint `RGB(180,120,255)`.
- **Where the id goes.** `src/client/Controllers/AutoRevealPassCard.luau`, `AutoRevealPassCard.ICON`. Upload the same image as the Game Pass icon too.

## 3. Theme preview thumbnails (one per theme)
- **Used in.** Upgrades > BASE > THEMES, as a row thumbnail. The row falls back to colour swatches while the id is `rbxassetid://0`.
- **Size.** 256x256, square, with rounded corners baked in (radius about 28 px).
- **Look.** A 3/4 top-down view of a small square plot corner:
  - the floor;
  - a fence corner with two posts and a rail;
  - a glowing gate cap;
  - one display pedestal with a trophy silhouette.
- **Colours.** Use exactly the colours of each theme in `src/shared/Config/BaseThemeConfig.luau` (`floorColor`, `fenceColor`, `railColor`, `accentColor`, and the materials).
- **Where the id goes.** `BaseThemeConfig.Themes[<key>].thumbnail`.

| key | look |
|---|---|
| Classic | green grass-checker floor, dark slate posts, white rails, cyan pad glow |
| Sunset | sandstone floor, terracotta posts, cream rails, orange glowing lanterns |
| Midnight | dark slate floor, navy posts, cyan rails and a cyan beacon |
| Jungle | mossy grass floor, cobblestone posts, vine-green rails, stone totem, round bush |
| Frost | glacier-ice floor, white ice posts, pale blue rails, ice crystal |
| Lava | basalt floor, black basalt posts, molten orange rails, glowing brazier |
| NeonNight | black glass floor, magenta neon rails, magenta and cyan glowing orbs (Robux: add a small gold "R$" corner ribbon, no other text) |
| RoyalGold | white marble floor, gold foil posts, pale gold rails, golden crown ornament, marble urn (Robux: same ribbon) |

## 4. Pedestal skin thumbnails
- **Used in.** Upgrades > BASE > PEDESTALS, as a row thumbnail.
- **Size.** 256x256, square, same framing for every skin: one pedestal, centred, 3/4 view, with a soft floor shadow.
- **Look.** Each skin's `color`, `material` and `trimColor` / `trimMaterial` from `BaseThemeConfig.Pedestals`.
- **Where the id goes.** `BaseThemeConfig.Pedestals[<key>].thumbnail`.

| key | look |
|---|---|
| Default | the museum's grey stone pedestal |
| Marble | white marble, gold foil ring at the base |
| Obsidian | near-black basalt, glowing purple ring |
| GoldPlinth | polished gold, white ring |
| Crystal | translucent pale-blue glass, glowing cyan ring |

## 5. Optional 3D decor props
- **Used on.** Themed plots.
- **Placement.** `BaseThemeService` puts a prop on top of each gate cap (`anchor = "gate"`) or on the two back-corner fence posts (`anchor = "backCorner"`). The prop's bottom sits on the post top, and it faces the plot's front.
- **Size.** Roughly the `size` in the config row (2-4 studs), because the fence posts are 1.8 studs wide.
- **Fallback.** Until a model exists, a coloured primitive is used.
- **Where they go.** Put each Model in `ServerStorage.GameAssets.ThemeDecor`, named exactly as below. No config change is needed; the service finds them by name.

| Model name | theme | description |
|---|---|---|
| SunsetLantern | Sunset | round paper lantern, warm orange glow (add a PointLight, Range 10) |
| MidnightBeacon | Midnight | short metal pylon with a cyan glowing ring |
| MidnightOrb | Midnight | small floating cyan orb on a thin stand |
| JungleTotem | Jungle | mossy carved stone totem, 3 studs tall |
| JungleBush | Jungle | leafy round bush with a few vines |
| FrostCrystal | Frost | cluster of pale ice crystals, 3.4 studs tall |
| LavaBrazier | Lava | black iron brazier with glowing lava bowl (PointLight, orange) |
| NeonOrb | NeonNight | glass sphere with neon inner core |
| RoyalCrown | RoyalGold | gold crown finial |
| RoyalUrn | RoyalGold | white marble urn with gold rim |

Keep lights small (Range at most 14, Shadows off). Plot decor is not switched off by the client's Graphics LOW setting.
