# Steal & Run!

A Roblox museum-heist game: run down a lane of 12 themed museum zones, steal
sealed mystery containers from the display cases in each zone's two side
rooms, dodge the lasers and the room guards, and carry the loot home to your
base, where it is revealed as one of **96 loot items** (12 zones x 8) and earns
Cash on a pedestal.

Rojo 7.7.0 project. **Place:** `PlaceId 134344354476234` · `GameId 10765058861`

New here? Read **[docs/START_HERE.md](docs/START_HERE.md)** first. `HANDOFF.md`
is the historical design log (long; search it, don't read it top to bottom).

---

## ⛔ Code lives in git. Art lives in the place file.

`default.project.json` maps only three folders:

```
ReplicatedStorage.Shared                   <- src/shared
ServerScriptService.Server                 <- src/server
StarterPlayer.StarterPlayerScripts.Client  <- src/client
```

Everything else - the loot art (`ServerStorage.GameAssets.Loot`), the zone
container models, the map kit, guardians, VFX, treadmills, the purchased UI
pack - exists **only inside the place file**. A place built with `rojo build`
contains the code and nothing else. **Never open a built place to work in, and
never publish one.** (CI runs `rojo build` only as a compile check; the output
`build.rbxl` is git-ignored and thrown away.)

**Always work in the real place through Team Create**, with Rojo syncing the
code into it.

The museum lane (zones, rooms, display cases, sockets, guardian posts, lasers)
is generated from source at server start by `MapBuilder` + `MuseumGallery` +
`MuseumExhibits`, before any service binds to it. Edit-mode changes to that
geometry do not survive the next Play. The lobby, plots and wheels are saved in
the place and are not rebuilt.

---

## Setup (Windows or macOS)

1. **Clone and pull.** `git clone <repo>`; before any session, `git pull`.
2. **Install the toolchain.** Install [Rokit](https://github.com/rojo-rbx/rokit),
   then in the project folder run `rokit install`. `rokit.toml` pins rojo,
   luau-lsp, selene, StyLua and luau.
3. **Install the Rojo plugin** in Studio (Plugins -> Manage Plugins -> Rojo 7.x).
   The plugin and the CLI versions must match.
4. **Open the place** in Studio through Team Create (not a local file).
5. **Sync:** `rojo serve default.project.json` (port 34872), then Rojo plugin
   -> Connect. Press **Play** to run the synced code.

### ⚠️ Only ONE person may have Rojo connected at a time

Rojo pushes `src/` into the live place; whoever syncs last wins. Handover:
the person finishing disconnects the plugin, stops `rojo serve`, commits and
pushes; the next person pulls, confirms they are on the newest commit, and only
then connects. Code is recoverable from git; **art is not**.

---

## ⚠️ Studio Play writes to the REAL DataStore

When the place has Studio API access enabled, a Play session loads and saves
your **real profile** (Cash, Speed, trophies, purchases). Debug commands that
grant, place or reset things change that profile. Test on an alt account, or
expect your main profile to change. Some integration tests restore what they
touch (see their comments), most do not.

---

## Static checks

```bash
bash tools/check.sh            # luau-lsp over src (or pass files/dirs)
selene --allow-warnings src    # lint; fails on errors only
stylua --check <file>          # formatting; only for files you touch
```

`tools/check.sh` prints **hard errors** (syntax errors, unknown globals,
unknown requires - always bugs) and then a per-file TypeError count. It exits
non-zero only when the hard-error list is non-empty; TypeErrors are for
comparing a change against the baseline and never fail the check. It finds the
tools in `~/.rokit/bin` or on `PATH`.

The same three steps (rojo build, check.sh, selene) run in GitHub Actions on
every push and pull request (`.github/workflows/checks.yml`).

Do **not** mass-reformat the codebase with StyLua; format only what you change.

---

## Verifying a working setup

Press **Play** and look in Output for, among others:

```
[LootService] 12 zones x 8 sockets filled
[Server] Steal & Run! services started
[Server] boot completed in ...s
```

In Edit mode the lane has no loot and parts of the HUD look like the UI pack's
demo - loot, guardians and many panels are created at runtime. That is
expected.

---

## Debug / test commands (Studio only)

`DebugService` exposes a bridge while playing in Studio. From the command bar
(Play mode, server side):

```lua
local Debug = game.ServerStorage.DebugInvoke
Debug:Invoke("snapshot")                  -- quick state dump
Debug:Invoke("nope")                      -- unknown name: lists every command
Debug:Invoke("validate")                  -- config validation (validate.luau)
Debug:Invoke("economyTests")              -- economy regression suite
Debug:Invoke("museumTests")               -- museum geometry/static checks
Debug:Invoke("museumLoops", "YourName")   -- steal/escape loop in every room
Debug:Invoke("museumScenarios", "YourName")
Debug:Invoke("museumPaths", "YourName")
Debug:Invoke("roomEscapeAudit", "YourName")
Debug:Invoke("paritySim")                 -- Monte Carlo roll parity
Debug:Invoke("museumPartCount")           -- parts per museum room
Debug:Invoke("museumCaseChurn", nil, 3, 2) -- case rebuild check, zone 3 socket 2
```

The second argument is a **player name string or `nil`** (first player), not a
Player object. The command bar runs in a separate Lua VM: `require`-ing a
server module there gives you a fresh copy with empty state, so always go
through `DebugInvoke` (or the `DebugRequest` / `DebugResponse` attribute bridge
on ServerStorage, documented in `DebugService.luau`, for tools that cannot
call a BindableFunction).

### Adding test commands: `DebugCommands/`

Don't grow `DebugService.luau`. Put new commands in a module under
`src/server/Services/DebugCommands/` returning
`{ [name] = function(player, ...) ... end }`. DebugService loads every module
there at start; a name that already exists is warned about and ignored.
`DebugCommands/World.luau` is an example.
