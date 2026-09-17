# Owner to-do after the 2026-09-17 improvement pass

Everything below is something only the owner can do (Creator Dashboard,
Studio saves, decisions). The code already works without any of it: every
missing id/asset falls back to a placeholder or hides the feature.

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

## 2. Creator Dashboard: create these, paste the ids

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

- [ ] Send `docs/codex-prompts/ALL.md` to Codex (every icon, banner, badge
      image, gadget mesh, vault set, theme thumbnail and loading screen art,
      each with its exact config key).
- [ ] Optional re-export of the "24K" Cash pack card art: the pack now pays at
      least $75K or 10 minutes of income.

## 4. Decisions to review (current defaults in brackets)

- Offline earnings pay **50%** of live income (was 100%). `GameConfig.OFFLINE_EFFICIENCY`
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

- [ ] Leave for 5+ minutes and rejoin: offline earnings ~ rate x seconds x 0.5.
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
