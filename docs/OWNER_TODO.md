# Owner to-do after the 2026-09-17 improvement pass

Everything below is something only the owner can do (Creator Dashboard,
Studio saves, decisions). The code already works without any of it: every
missing id/asset falls back to a placeholder or hides the feature.

## 0. After the 2026-09-20 pass (do these first)

- [ ] **File > Save, then Publish with "Migrate to latest update".** Until then the live game still has
      the smoke-bomb exploit (Zone 12 loot at any Speed) and the Base03/Base04 "cannot place" bug.
      The Base03/Base04 SafeZone fix is IN THE PLACE FILE, so it needs the Save.
- [ ] Creator Dashboard > Developer Products: confirm the four **Relic Roll** products exist and are on
      sale: x1 3713786892 (52 R$), x3 3713786898 (128), x10 3713786905 (410), x50 3713786914 (1792).
- [ ] Decide the Relic Roll prize pool. Today it is six Zone 1-2 items (39/25/20/10/5/1 %, top prize
      Cursed Coin): a strong deal for a new player, worthless to a late one. `RelicRollConfig.Tiers`.
- [ ] Look at, in a real play session (the Studio screenshot tool cannot see 3D or viewports):
      the tutorial film's camera framing and pacing (`TutorialFilmConfig.BEATS`), the new laser rooms
      (zones 5+ have moving beams), the held item in your hands, the Relic Roll figures looking at the mouse.
- [ ] russ1719 (UserId 3230257566) used the smoke exploit: Zone 2 -> Zone 12 in 30 minutes, now ~$4.3T and
      1.06M Speed. Decide: roll back to the 16:59 UTC 2026-09-19 version, or leave.
- [ ] Studio Play tests use YOUR real save. If you are in the live game at the same time, Studio now plays
      a borrowed copy and saves nothing (console: "borrowed copy") instead of kicking you.

## 0b. What changed on 2026-09-20 (second batch) - look at these in a real session

- [ ] **Relic Roll**: buy a 3x with Studio's test path or a real 52 R$ 1x. Expect: the shop closes, a ~4 s roulette
      (fast, then slowing, a tick per card that follows the speed), a win sound, the name and rarity, then the next
      roll separately ("Roll 2 / 3"); each item lands in the hotbar as its roll finishes. "Skip all" ends it.
      No "Successful Purchase" box any more (Roblox's own purchase popup is Roblox's and cannot be removed).
- [ ] **Hotbar**: held items fill the next numbers straight after Slap / Trap / your gadgets (no gaps, same look as 1-4).
      Past 10 they go to the bag: press the backtick key (`), or the "Bag +N" button on a phone. The small
      "Store it" button on the right appears only while you hold an item.
- [ ] **Lasers**: run into a beam at full speed: you should be thrown the instant you touch it, smoothly, out of the
      door, with no guard woken. (Vault beams still use the older server-driven throw and may look less smooth.)
- [ ] **Lobby**: every shop, stand, pad and treadmill rail is walk-through; only floors and boundary walls are solid.
- [ ] **Storage > SELL ALL**: a red bar under the item list, "Are you sure?" first. It keeps items in your hands and
      unrevealed containers. (Test it with a few cheap items first.)
- [ ] The pack script (StarterGui.MainUI.LocalScript) hides every other ScreenGui while a panel is open; new full-screen
      UI must live inside MainUI (like the confirmation dialog) or be opened after `_G.CloseAllUIFrames`.

## 1. Right after syncing

- [ ] In Studio, accept/sync Rojo, then **File > Save** and **Publish**. New
      ModuleScripts, a new ReplicatedFirst loading screen, and the baked loot
      art all live in the place file.
- [ ] Publish with **Migrate to latest update** (or shut down all servers).
      Old servers save without the new session lock; mixing them can kick a
      player once (safe, but visible).
- [ ] Game Settings > Security: turn on **Allow HTTP Requests** (needed only
      for experience notifications).
- [ ] Check the server size in Creator Dashboard > Places > Server Size. The
      game is balanced for **7** players (plots, wheels, guards); Studio shows
      60.

## 2. Creator Dashboard

**Done on 2026-09-17 (ids are already in the config):**

- Game passes: Season Pass Premium 1982246812 (199 R$), Auto Reveal
  1985618401 (199 R$), Neon Night Theme 1986506321 and Royal Gold Theme
  1985804347 (149 R$ each).
- The nine gift developer products (3713252836 to 3713252877), same prices as
  the packs they gift.
- Five free badges: Sticky Fingers, What's Inside?, Myth Maker, Career Thief,
  Regular. Their art is a placeholder (`assets/badges/`); swap the images on
  the dashboard when Codex delivers. The other 18 badges stay off (100 R$ each
  beyond the 5 free per day).

**Still yours (Roblox has no API for these):**

- Engagement > Notifications: create the two notification strings and send me
  (or paste) their ids for `SocialConfig.NOTIFICATION_TEMPLATES`.
- Open Cloud > API Keys: a key with User Notification write access, saved as
  the secret `OPEN_CLOUD_NOTIFICATIONS` (Game Settings > Security), and turn on
  Allow HTTP Requests.

Original list, for reference:


| What | Type | Price (suggested) | Paste into |
|---|---|---|---|
| Season Pass Premium (Season 1) | Game Pass | 399 R$ | `MonetizationConfig.SeasonPremiumPass.gamePassId` |
| Auto Reveal | Game Pass | 199 R$ | `MonetizationConfig.AutoRevealPass.gamePassId` |
| Neon Night Theme | Game Pass | 149 R$ | `MonetizationConfig.ThemePasses` |
| Royal Gold Theme | Game Pass | 149 R$ | `MonetizationConfig.ThemePasses` |
| 9 x "Gift: ..." packs (one per Cash/Speed pack, same prices) | Developer Products | 45-2549 R$ | `MonetizationConfig.GiftProducts` (table in `docs/handoff-parts/trading-gifting-boards.md`) |
| 23 badges (first steal, zones 1-12, reveals, Index, streak...) | Badges | - | `src/shared/Config/BadgeConfig.luau` (list + art in `docs/codex-prompts/social.md`) |
| 2 notification strings ("container ready", "offline earnings full") | Engagement > Notifications | - | `SocialConfig.NOTIFICATION_TEMPLATES` |
| Open Cloud API key with **User Notification** write access | Open Cloud > API Keys | - | Game Settings > Security > Secrets, name `OPEN_CLOUD_NOTIFICATIONS`, domain `apis.roblox.com` |
| (optional) Invite prompt template | Engagement | - | `SocialConfig.INVITE_MESSAGE_ID` |

Ask Claude/Codex to paste ids for you if you prefer: give them the table
filled in.

## 3. Art

- [ ] Send `docs/codex-prompts/ROUND3_MASTER.md` to Codex (UI polish, Fusion Machine, animated pets, and it includes ALL.md)
- [ ] (covered by the master prompt) `docs/codex-prompts/ALL.md` (every icon, banner, badge
      image, gadget mesh, vault set, theme thumbnail and loading screen art,
      each with its exact config key).
- [ ] Optional re-export of the "24K" Cash pack card art: the pack now pays at
      least $75K or 10 minutes of income.

## 4. Decisions to review (current defaults in brackets)

- Offline earnings pay **25%** of live income, capped at 6 hours (owner, 2026-09-17). `GameConfig.OFFLINE_EFFICIENCY`
- Free spin every **5 min** of *active* play; AFK pauses the clock after 120 s;
  jackpot/Tiger/Panda weights lowered (8 / 15 / 50 of 10,000); prizes scale
  with your zone. `SpinWheelConfig`
- Cash packs pay **max(fixed floor, N minutes of income)** (10 min ... 12 h).
  Consider 49 / 99 R$ price points. `MonetizationConfig.CashProducts`
- Loss offer cooldown **90 s** (was every catch). `MonetizationConfig.BOSS_OFFER_COOLDOWN`
- Crouching slows you to **60%**. `SecurityConfig.CROUCH_SPEED_MULTIPLIER`
- Daily streak day 7 pays **Cash + Speed** (not a free Panda). `DailyRewardConfig`
- Launch codes: `MUSEUM` (10 min income), `RELEASE` (Speed). `CodesConfig`
- Vaults restock every **10 min** (Night restock **off**); Vault Guardian
  1.08x speed. `VaultConfig`
- Guard patrols in zones **7+**; gadget prices by zone. `PatrolConfig`, `GadgetConfig`
- Events: Mutation Weekend, Night Rush (Fri 18-22 UTC), Halloween, Winter. `EventConfig`
- Season trail placeholder is the Grey trail until an exclusive trail exists.
  `SeasonPassConfig.SEASON_TRAIL_KEY`

## 5. Live checks (need a published server / real devices)

- [ ] Leave for 5+ minutes and rejoin: offline earnings ~ rate x seconds x 0.25 (max 6 h).
- [ ] Hop servers quickly after a purchase: nothing rolls back.
- [ ] "Shut down all servers": the last minute of progress is kept.
- [ ] Phone + tablet: shift lock, crouch/shift-lock buttons vs Jump, Daily /
      Quests / Trade / Crew panels, the loading screen (portrait + landscape).
- [ ] Two-player test (Team Test): a trade, a gift purchase, a crew assist, a
      paid base steal, an invite reward (new account).
- [ ] A notification arrives about when a container is ready (after the setup
      in section 2).

## 6. Place-file housekeeping (do in Studio, then save)

- [ ] Right-click each backup folder in ServerStorage > **Save to File**, then
      delete it from the place: `_MapBackup_2026-09-07`, `_MapBackup_pre-kit`,
      `_RootBackup_2026-09-07`, `MuseumReplacedScenery`, `_UnusedImports`,
      `_RemovedByClaude`, `_SyntaxCheck` (~9,500 objects).
- [ ] `StarterGui.MainUI.LocalScript` (the UI pack script) is mirrored in
      `place/`; if you edit it in Studio, paste the new source there too.
