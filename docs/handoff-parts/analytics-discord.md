# Analytics and Discord reporter (analytics-discord)

The goal: understand **why players leave**. This pass adds new Roblox
Analytics events on top of the polish-events-analytics ones and a Discord
reporter. The reporter **mirrors every analytics event** to Discord, and
also posts purchases, big reveals, errors, summaries, a daily digest and an
"errors and spikes" feed.

Nothing here was run in Studio.
- `tools/check.sh`: no hard errors, and no TypeErrors in any new file. The
  counts rose only in files that the new modules require (the known
  "reported once more per requirer" effect).
- `selene src`: 0 errors.

## Files

| File | What it is |
|---|---|
| `src/server/Services/AnalyticsEvents.luau` | Extended. Adds `custom()` (a fixed list of event names), the Speed economy, the per-product and BossOffer funnels, PurchaseCancelled, `observe`/`emit` for Discord, the `mirror` hook in `send()`, and `dump(filter)`. |
| `src/server/Services/AnalyticsSession.luau` | **New.** Sessions, the quit context, the core-loop events and the feature-use events. |
| `src/server/Services/DiscordReporter.luau` | **New.** The queue, the webhook, the embeds, the 30-minute summary, the daily digest and the analytics mirror. |
| `src/server/Services/PerfFeed.luau` | **New.** The "errors and spikes" CSV feed (server side). |
| `src/server/Config/DiscordConfig.luau` | **New, server only** (it never replicates). The webhook and every Discord switch. |
| `src/client/Controllers/PerfController.luau` | **New.** The FPS-drop sampler and the client error forwarder. |
| `src/client/Controllers/AnalyticsController.luau` | Also reports the open MainUI panel. |
| `src/server/Services/DebugCommands/AnalyticsDiscord.luau` | **New.** The Studio commands. |
| `src/shared/Config/PolishConfig.luau` | Panel list and the perf sampler settings (shared, nothing secret). |
| `src/shared/Remotes.luau` | One remote appended: `PerfReport`. |
| `src/shared/Util/RateLimiter.luau` | Optional server-only `onReject` observer (used for the remote-flood rows). |
| `src/server/Services/DataService.luau` | One new field, `AnalyticsLife`. |
| `validate.luau` | One ANALYTICS-DISCORD block. |

**One-line hooks.** Each is marked `[analytics-discord]` and fires
`ProgressEvents`:
- Speed grants (`speedGain`) in 11 files: GiftService, GroupGiftService,
  IndexService, MailboxService, MonetizationService, QuestService,
  RetentionRewards, SeasonPassService (x3), SpeedService, SpinWheelService
  (x2) and StarterTaskService.
- Other events:
  - `caught`: GuardianService, plus a `chaseCause` field set in
    `beginChase`; BaseGuardianService.
  - `robbed` and `storageFull`: HeistService.
  - `storageFull`: CarryService and PlacementService.
  - HatchService adds zone, wait and how to its existing `revealed` info.
  - init adds `vault` to its `steal` info.
  - `codeRedeemed`: CodeService.
  - `tradeCompleted`: TradeService.
  - `fused`: FusionService.
  - `gadgetUsed`: GadgetService.
- One injected hook: `MonetizationService.onBossOfferShown`.

**New profile field** (DataService, marked `[analytics-discord]`, no schema
bump): `AnalyticsLife = { Sessions, FirstJoin, FirstReveal, FirstEpic,
D1Counted, Purchases }`.
- A brand-new profile gets `FirstJoin = os.time()`.
- An older save gets `FirstJoin = 0` ("unknown"), and its once-in-a-life
  timings are never logged.

## Safety

These apply to everything in this pass:
- Every AnalyticsService call goes through the existing `send()`, so it is
  spawned, pcall'd and budgeted.
  - The new `custom` category has its own token bucket.
  - Studio records events but does not send them unless `analyticsDebug`
    is on. When it is on, it also prints them.
- Custom event names come from `AnalyticsEvents.CUSTOM_EVENTS` (30 names).
  An unknown name is refused, and in Studio it prints a warning.
- Each event has at most 3 customFields. Every field is a short label from a
  small set: buckets, zone labels (`Z03`, `Base`, `OtherBase`, `Lobby`),
  rarity names, step names or panel names. None is free text. The only
  exception is `CodeRedeemed`, which carries the code's config key.

## A. The new analytics events

### Speed economy
`LogEconomyEvent`, currency `"Speed"`, flow Source. The `itemSku` is the
source tag. Every place that adds to `SpeedPower` fires `speedGain` right
after the add:

| Tag | Source | Transaction type |
|---|---|---|
| `train` | Treadmill tick. Summed per player and sent with passive Cash every 5 min and on leave. | Gameplay |
| `product` | Speed packs (IAP), and the gift fallback that pays the buyer | IAP |
| `spin` | Wheel prize, and the duplicate-guardian Speed | TimedReward |
| `code` | Codes | Gameplay |
| `daily` | Daily reward | TimedReward |
| `quest` | Quests | Gameplay |
| `season` | Season pass: Speed rewards and duplicate conversions | Gameplay |
| `group` | Group gift | Gameplay |
| `index` | Index set rewards | Gameplay |
| `referral`, `gift`, ... | Mailbox Speed entries: the entry's own `source`, else `mail` | Gameplay |
| `task` | Starter checklist | Onboarding |

There are no gadget Speed sources. Debug commands that set Speed are
deliberately not hooked.

### Core loop: custom events (value, CustomField01 / 02 / 03)

| Event | Value | Fields | Answers |
|---|---|---|---|
| `Caught` | 1 | zone (`Z03` / `Base`), cause (`laser`, `doorway`, `patrol`, `guard`, `vault`, `base`), `carrying` / `empty` / `unknown` | Where and by what are players caught? |
| `LaserTouched` | 1 | zone, room (`R1`, `R2`, `Vault`) | Which lasers are hit most? Throttled to once per player per zone and room per 30 s. |
| `Robbed` | 1 | rarity lost | How often is a victim robbed, and of what? |
| `StorageFullBlocked` | 1 | where (`steal`, `store`, `heist`), zone or current place | Does full storage block play? Throttled to once per 30 s per kind. |
| `UnderSpeedAttempt` | zone | zone, `entered` / `stole`, Speed / recommended (`<25%` ... `75-100%`) | Do players go too deep too early? Once per zone and action per session. |
| `Revealed` | 1 | rarity, zone, `manual` / `auto` / `quick` | What do reveals give? |
| `RevealWait` | seconds | wait bucket (`0s`, `1-10s`, ... `1d+`), how, rarity | How long do ready containers sit before they are revealed? |
| `FirstEpicReveal` | seconds since first join | duration bucket, rarity | How long until the first Epic or better? Once per life. |
| `TimeToFirstReveal` | seconds since first join | duration bucket, rarity | How long until the first reveal? Once per life. |

**How a catch's cause is decided.** The chase remembers what started it:
- a laser alarm gives `laser`;
- the doorway exit rule gives `doorway`;
- a guard that was patrolling or searching gives `patrol`;
- anything else gives `guard` (the guard woke for the steal).

A Vault Guardian's catch is always `vault`, and a base guardian's hit is
`base`.

### Sessions and quit context
- **`SessionStart`**: value = the session number. Fields:
  - the session bucket (`S1`, `S2`, `S3`, `S4-5`, `S6-10`, `S11-20`,
    `S21+`);
  - the player type: `new`, `d1return` (their first join was yesterday,
    counted once), `returning`, or `legacy` (first join unknown);
  - the highest zone reached.
- **`SessionEnd`**: value = seconds. Fields: the duration bucket, the
  session bucket, and the name of the quit event below.

On leave, exactly **one** quit event is logged, and the value is the session
seconds. The first match in this order wins:

| Event | When | Fields |
|---|---|---|
| `QuitInTutorial` | a tutorial step is still active | step (`steal`, `escape`, `place`, `reveal`, `income`, `train`, `nextZone`), duration, session |
| `QuitAfterCatch` | caught 60 s or less before leaving | zone, cause, session |
| `QuitAfterRobbed` | robbed 120 s or less before leaving | rarity lost, duration, session |
| `QuitWhileCarrying` | carrying loot | zone / place, duration, session |
| `QuitInPanel` | a MainUI panel was open | panel, place, session |
| `QuitIdle` | did not move for 120 s or more | place, idle time, session |
| `QuitActive` | anything else | place, duration, session |

**Where the context comes from.** It is a 2-second server poll of place,
carry, tutorial step and last movement, so it is correct even though
PlayerRemoving tears the carry down. The open panel is reported by the
client:
- `AnalyticsClientEvent("panel", name)`, sent after the panel has been open
  for 1 s;
- the server checks the name against `PolishConfig.ANALYTICS_PANELS` (or
  `None` / `Other`);
- it has its own limiter, at 1/s with a burst of 5.

**Tutorial skip: there is no skip in the game** (TutorialService has none),
so there is nothing to report. `QuitInTutorial` carries the step instead.

**Dashboard recipe.** Custom events > `SessionEnd`, broken down by
CustomField03, gives the share of each quit reason. Then open, for example,
`QuitAfterCatch`, broken down by CustomField01 and CustomField02, to see the
zone and cause.

### Feature use

| Event | Value | Fields |
|---|---|---|
| `DailyClaim` | streak | day (`D1`..), streak (`1`..`6`, `7+`) |
| `QuestClaim` | 1 | period (`Daily` / `Weekly`) |
| `SeasonTier` | tier | `T<n>`, track |
| `TradeCompleted` | items moved | `0 items` / `1 items` / `2-3 items` / `4+ items` |
| `Fusion` | 1 | result rarity |
| `GadgetUsed` | 1 | gadget key, place |
| `VaultSteal` | zone | zone |
| `CrewAssist` | Cash paid | none (seen as the `crew` Cash source) |
| `SpinUsed` | 1 | none |
| `CodeRedeemed` | 1 | the code's config key |

`TimeToFirstReveal` is listed with the core-loop events above.

### Purchase funnels per product type
`LogFunnelStepEvent` with three steps: 1 Shown, 2 Prompted, 3 Purchased.
Each funnel session lasts at most 15 minutes. Earlier steps are filled in
if a later one arrives first.

| Funnel | Kinds | "Shown" comes from |
|---|---|---|
| `Buy_Pack` | Cash, Speed, TreadmillTier | the Shop or Upgrades panel opening |
| `Buy_Pass` | every gamepass | Shop or TrailShop |
| `Buy_Gift` | Gift | Shop |
| `Buy_Gadget` | Gadget | GadgetStore |
| `Buy_SeasonSkip` | Skip | SeasonPass |
| `Buy_Steal`, `Buy_Reveal` | Steal, Reveal | These are world prompts with no separate "shown" moment, so it is recorded with "prompted". |

The steps are fed as follows:
- **Prompted:** `PromptProductPurchaseFinished` or
  `PromptGamePassPurchaseFinished`. Every dialog ends in exactly one of
  these, so this counts dialogs no matter which service opened them.
- **Purchased:** a GRANTED receipt (the existing receipt wrapper), or a
  gamepass bought.
- **Cancelled:** a dialog closed without buying also logs
  `PurchaseCancelled` (kind, product key).

**`BossOffer`** (the Speed offer after a catch) has three steps:
- Shown: `offerAfterCatch` sent it.
- Clicked: `PurchaseRequest("product", <the offered key>)`.
- Purchased: a receipt for that key.

## B. The Discord reporter

### Owner setup (do this once)
1. **Game Settings > Security > Allow HTTP Requests: ON.** Without it the
   reporter prints one warning and turns itself off.
2. Create the webhook: Discord channel > Edit Channel > Integrations >
   Webhooks > New Webhook > Copy Webhook URL. It looks like
   `https://discord.com/api/webhooks/<id>/<token>`.
3. Choose **one** way to give the game the webhook.

**Option A: the experience secret (recommended for live servers).** The URL
never exists in the place or the repo.
- Go to Creator Dashboard > your experience > Configure (Settings) >
  **Secrets** > Create Secret.
  - Name: `DISCORD_WEBHOOK`
  - Value: ONLY `<id>/<token>`, the part after `/api/webhooks/`.
  - Domain: `webhook.lewisakura.moe`
- The server calls `HttpService:GetSecret("DISCORD_WEBHOOK")`. It builds the
  URL with `secret:AddPrefix("https://webhook.lewisakura.moe/api/webhooks/")`
  and passes the Secret object as the `Url` of `RequestAsync`. The URL is
  never a readable string.
- Roblox blocks `discord.com`. `webhook.lewisakura.moe` is the usual public
  proxy for it.
- **In Studio**, secrets are not read from the dashboard. Roblox has a
  Studio-only place for local test secrets, under Game Settings > Security.
  It takes a JSON map of name to `[value, domain]`, for example
  `{"DISCORD_WEBHOOK": ["<id>/<token>", "webhook.lewisakura.moe"]}`. **Check
  that field in your Studio version; I could not verify it.** If it is not
  there, use the fallback: set a string attribute
  `DISCORD_WEBHOOK_STUDIO` = `<id>/<token>` on **ServerStorage**. It is read
  only when `RunService:IsStudio()`. **Delete it before you publish**,
  because it is saved into the place file.

**Option B: `DiscordConfig.WEBHOOK` (the owner's request).**
- Paste the full `https://discord.com/api/webhooks/<id>/<token>` URL into
  `src/server/Config/DiscordConfig.luau` > `DiscordConfig.WEBHOOK`. It is
  rewritten to the lewisakura proxy automatically. The `discordapp.com` form
  also works.
- It works in Studio and on live servers with no secret.
- It lives under ServerScriptService and never replicates to clients. But
  anyone with edit access to the place can read it, and **it must never be
  committed**. Leave it `""` in the repo. To stop git from picking up your
  local edit, run
  `git update-index --skip-worktree src/server/Config/DiscordConfig.luau`.
  To undo that, run `--no-skip-worktree`.

**Priority.** `WEBHOOK` if it is not empty, else the secret, else (Studio
only) the ServerStorage attribute.

**Studio posting.** Studio posts nothing unless one of these is on:
- `DiscordConfig.DEBUG`;
- `DiscordConfig.POST_FROM_STUDIO`;
- the `discordDebug true` command.

`discordTest` can always post its single test message.

**If the webhook leaks.** Delete the webhook in Discord and create a new
one. Then update the secret (or `WEBHOOK`).

### What gets posted
Every message goes out as username "Steal & Run!" with
`allowed_mentions: {parse: []}`, so a username or an error text can never
ping anyone. Only Roblox usernames and user ids are posted.

| Message | When | Content |
|---|---|---|
| **Robux purchase** (gold) | Instant. Purchases within 10 s are merged into one embed. | player (name and id), product or pass name, kind, Robux, and "FIRST PURCHASE" when it is their first. Robux is the receipt's `CurrencySpent`; for gamepasses it is `MonetizationService.livePassPrice`, falling back to the config price. |
| **Big reveal** (purple) | Instant, merged within 10 s | Reveals at `REVEAL_MIN_RARITY` (Secret) or better: player, mutation, rarity, item, zone. |
| **Server error** (red) | Instant | `ScriptContext.Error`, with one post per distinct message per 10 min: the message, the script path, the first stack line, the repeat count since the last post, and the player count. |
| **Server summary** (blue) | Every 30 min while the server has players | players now / peak, sessions ended, average session, new players, purchases and Robux, the top 3 quit contexts, the top 3 catch zones, and the mirror's row / merged / dropped counts. |
| **Daily digest** (green) | Once a day across all servers, after 00:05 UTC | See the next section. |
| **Steal & Run! analytics** (text, csv) | Every 60 s, or early at 15 rows | The analytics mirror (below). |
| **Steal & Run! errors and spikes** (text, csv) | Every 90 s, or early at 10 rows | The performance feed (below). |

**How the daily digest works.**
- Each server adds its counters to the DataStore `AnalyticsDaily_v1`, key =
  the UTC date (`2026-09-19`). It uses `UpdateAsync` every 2 min and in
  `BindToClose`.
- The counters are: joins, new players, sessions, play seconds, D1 returns,
  purchases, Robux, quits by context, catches by zone, and reveals by
  rarity.
- After 00:05 UTC, a server claims `digest_<yesterday>` with an
  `UpdateAsync` that writes only if the key is empty. Only the winner posts.
- The digest shows:
  - joins, new players;
  - D1 return as "X of Y new the day before (Z%)";
  - sessions, average session, total play hours;
  - purchases and Robux;
  - quits by context, catches by zone, reveals by rarity.
- If no server is running at 00:05, the first server to start after that
  posts it.

**Rate limits.**
- One queue per server, 20 messages per minute. The mirror may use up to 10
  of them.
- A 429 waits out Discord's `retry_after`. A network error or 5xx backs off
  2, 4 and 8 s, then the message is dropped. Any other 4xx is dropped with
  one warning.
- Past 50 queued messages, the oldest *feed* message is dropped first, so
  purchases and errors are never pushed out by CSV rows.

### The analytics mirror (the owner's main ask)
Every event that goes through `AnalyticsEvents`' single `send()` path is
also a CSV row:
- onboarding steps;
- the FirstPurchase, `Buy_*` and BossOffer funnel steps;
- Cash and Speed economy events;
- MuseumZone progression;
- every custom event.

Rows are mirrored **as they are recorded**: before the Roblox budget, and in
Studio as well (where they are posted only while posting is on).

~~~
**Steal & Run! analytics**
```csv
utc,type,event,player,sid,field1,field2,field3,value
2026-09-19 19:41:09,custom,Caught,SomeUser,8e5d225784,Z03,laser,carrying,1
2026-09-19 19:41:12,economy,Speed,SomeUser,8e5d225784,source:Gameplay,train,bal=1234567,5400
2026-09-19 19:41:15,funnel,Buy_Pack,SomeUser,8e5d225784,2,Prompted,,2
```
~~~

What the fields hold for each type:
- **funnel:** field1 = step number, field2 = step name.
- **economy:** field1 = `flow:transactionType`, field2 = tag,
  field3 = `bal=<ending balance>`, value = amount. Passive Cash and
  treadmill Speed stay batched: one row per player per tag every 5 min, as
  on the Roblox side.
- **progression:** `Start`, level, zone name.
- **custom:** the three custom fields, and the value.

**When there are more rows than the budget allows.** The budget is 10
messages a minute, about 16 rows each. A flush that is over budget reduces
its rows in this order:
1. Identical rows (same event, player and fields) are merged into one, with
   the value summed and shown as `value xN`.
2. Rows are merged across players, with player `*`.
3. Only then are the oldest rows dropped.

The merged and dropped counts appear in the 30-minute summary and in
`discordStatus`.

Switch: `DiscordConfig.MIRROR_ANALYTICS`.

### Errors and spikes feed
Same format as the owner's other game: a bold title
`**Steal & Run! errors and spikes**` and a csv block with the header
`utc,kind,where,detail,cpu_ms,gpu_ms,drawcalls,tris_k,top_script`.
Messages are split under 2000 characters.

An example row:

```
2026-09-19 19:41:09,fps-drop,Phone Z3-R2 sid=8e5d225784,ver=412 fps=17 cause=Network nearby=1 guards=2 particles=24 effects=9 ping=458 recv=120 fx=Reduced,21.2,18.5,1600,15,Render
```

| kind | Source |
|---|---|
| `fps-drop` | See below. |
| `server-lag` | Server FPS under 40 for 5 s, with 5 min between rows. Detail: `hb_ms`, `physics_ms`, players, active chases, `mem_mb`. |
| `error` | `where` = `server:<script path>` (ScriptContext.Error) or `client:<script path>` (forwarded; the player's name is replaced by `<player>`). Detail = the first line. One row per message per 10 min. |
| `remote-flood` | Any `RateLimiter` refusing one player 40 times inside 10 s. `where` is the limiter's rate. Detail = user id and count. At most one row per player per 5 min. |

**How a `fps-drop` row is made.**
- **The client (PerfController)** counts frames and reads them twice a
  second. When FPS stays under 25 for 2 s, it sends ONE snapshot, then
  nothing for 60 s, and at most 10 per session.
- **What the snapshot holds:**
  - device class (`Phone`, `Tablet`, `Console`, `Desktop`);
  - the effects setting (`Full`, `Reduced`, `Low`, `ReducedLow`);
  - ping (`GetNetworkPing`) and `DataReceiveKbps`;
  - particles and effects: enabled emitters, beams, trails, fire, smoke
    and sparkles on the parts within 80 studs of the camera, from ONE
    bounded spatial query;
  - `RenderCPUFrameTime` / `RenderGPUFrameTime`, pcall'd because they may
    be missing;
  - `SceneDrawcallCount` and `SceneTriangleCount`.
- **The server** adds the location (`Z3-R2`, `Z3-Vault`, `Z3-Corridor`,
  `Base`, `OtherBase`, `Lobby`), players within 60 studs, guards within 80
  studs, the session id and `game.PlaceVersion`. It picks the cause from
  `DiscordConfig.CAUSE_THRESHOLDS`: the largest measurement-to-threshold
  ratio at or above 1 wins, otherwise `Unknown`.
- **Every number is clamped and every word is whitelisted.** The
  `PerfReport` remote is limited to 0.2/s with a burst of 3.
- **Analytics:** each spike is also a `PerfSpike` custom event (device,
  cause, fps bucket), and so also a mirror row.
- **`top_script`:** Roblox exposes no per-script cost to a LocalScript. The
  client reports `Render` when render CPU or GPU time is 25 ms or more,
  `Network` when ping is 300 ms or more, and `n/a` otherwise.

Switches: `DiscordConfig.PERF_FEED` (Discord rows) and
`PolishConfig.PERF_SAMPLER_ENABLED` (the client sampler).

## Studio test plan
All commands: `ServerStorage.DebugInvoke:Invoke(cmd, "<you>", ...)`.

1. **Startup.** The output shows `[AnalyticsEvents] online (Studio:
   recording only)` and `[DiscordReporter] off (Studio: posting is off
   ...)`. `validate` has no failures.
2. **Session and quit.**
   - Play and run `analyticsSession`. Your entry shows `where` (for example
     `Base`, and `Z1-R1` inside a room), `carrying`, `tutorialStep`,
     `panel`, `idleSeconds` and `wouldQuitAs`.
   - Open the Shop. After about 1 s, `panel = "Shop"` and `wouldQuitAs` is
     `QuitInPanel`. Close it and it returns to `None`.
   - Steal something, then run `analyticsQuitTest`. The event is
     `QuitWhileCarrying` (or `QuitInTutorial` on a fresh profile).
   - Get caught by a guard, then run `analyticsQuitTest` within 60 s. The
     event is `QuitAfterCatch` with the zone and cause.
   - Stop the game, run it again, and run `analyticsEvents Session`. You
     see `SessionStart` with a session number one higher than before.
3. **Core loop, live.**
   - Touch a laser, then run `analyticsEvents LaserTouched`: one row with
     zone and room. A second touch within 30 s adds no row.
   - Get caught after a laser trip: `Caught [Z0x, laser, ...]`.
   - Leave a room with loot and get caught: `doorway`.
   - Fill the base and try to steal: `StorageFullBlocked [steal, Z0x]`.
   - Reveal a container: `Revealed`, `RevealWait` (and `TimeToFirstReveal`
     on a brand-new profile only).
   - Walk into a zone above your Speed: `UnderSpeedAttempt [Z0x, entered,
     ...]`.
4. **Speed economy.**
   - Train on the treadmill, then run `analyticsFlush`. `analyticsEvents
     Speed` shows `source Speed <n> (Gameplay, train)`.
   - Spin the wheel and win Speed: `Speed ... spin`.
   - Redeem a code: `Speed ... code` (if it pays Speed) and
     `CodeRedeemed`.
5. **All new names at once.** Run `analyticsSimulate` (analytics-only facts;
   the profile is unchanged). `analyticsEvents custom` then lists Caught,
   StorageFullBlocked, Robbed, VaultSteal, UnderSpeedAttempt, GadgetUsed,
   CodeRedeemed, Fusion, TradeCompleted, SpinUsed, QuestClaim, DailyClaim,
   SeasonTier, Revealed, RevealWait and LaserTouched, and `customByName`
   counts them.
6. **Purchase funnels.**
   - Open the Shop: `analyticsEvents Buy_` shows `Buy_Pack 1 Shown`,
     `Buy_Pass 1 Shown` and `Buy_Gift 1 Shown`.
   - Press a Cash pack and cancel the dialog: `Buy_Pack 2 Prompted` and
     `PurchaseCancelled [Cash, <key>]`.
   - Studio test purchases complete it: `Buy_Pack 3 Purchased`.
   - Get caught with an offer available: `BossOffer 1 Shown`. Press BUY:
     `2 Clicked`.
7. **Discord, with a test webhook.**
   - Set the Studio attribute (or `DiscordConfig.WEBHOOK` locally).
   - `discordTest`: a grey "Test message" arrives. `discordStatus` shows
     `webhookSource` (for example `Studio attribute ...`) and never the URL.
   - `discordDebug true`, then play. Within 60 s an "analytics" csv block
     arrives with your rows. `discordFlush` sends it at once.
   - `perfSpikeTest`: an "errors and spikes" block with one `fps-drop` row
     (after `discordFlush`). `perfErrorTest` adds an `error` row.
   - `discordSummaryNow`: the blue summary.
   - `discordDigestPreview`: returns the digest embed built from today's
     local counters. It posts nothing.
   - Make a test purchase: a gold embed within about 10 s.
   - Make a server Script error (for example, a temporary Script in
     ServerScriptService with `error("test")`): a red embed. The command
     bar does not raise ScriptContext.Error. The same error again within 10
     minutes only increases the repeat count.
   - `discordDebug false` when you are done. **Note:** while posting is on,
     Studio also writes the day counters to the real `AnalyticsDaily_v1`
     store.
8. **Live check after publishing** (with the secret set). A purchase posts,
   and a summary appears every 30 minutes on busy servers. At 00:05 UTC,
   exactly one digest is posted.

## Owner actions
- Turn on Allow HTTP Requests.
- Create the Discord webhook, and either create the `DISCORD_WEBHOOK`
  secret (id/token, domain `webhook.lewisakura.moe`) or paste the URL into
  `DiscordConfig.WEBHOOK` locally, never committed.
- No gamepasses, products, badges or art. The Roblox dashboard shows the
  custom events and funnels automatically once they arrive.
- Optional: in the Analytics dashboard, pin `SessionEnd` broken down by
  CustomField03.

## Could not do / notes for the lead
- **Not run in Studio.** The lead must check these:
  - `HttpService:GetSecret` with a Studio local secret (the name of the
    Studio field);
  - that `RequestAsync` accepts the Secret as `Url` on the live server;
  - that `Stats.RenderCPUFrameTime` / `RenderGPUFrameTime` exist. If they
    do not, those cells are left blank.
- There is no tutorial skip, so no "skipped" field.
- `Buy_Steal` and `Buy_Reveal` have no separate "shown" step.
- `top_script` is a coarse label (see above).
- `RateLimiter.onReject` does not know the remote's name. A flood row names
  the limiter's rate and the user id.
- Guardian catch causes are attributed from the chase that caught the
  thief. A chase that switched targets keeps the cause of its newest target.
