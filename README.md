# Steal Something

A Roblox game. Rojo 7.7.0 project.

**Place:** `PlaceId 134344354476234` · `GameId 10765058861`

---

## ⛔ READ THIS BEFORE YOU RUN ANYTHING

**Do NOT run `rojo build`.**

The default Rojo README tells you to build a place from the repo. That is wrong
for this project and it will cost you every asset in the game.

**Code lives in git. Art lives in the place file. They are separate.**

`default.project.json` maps only three folders:

```
ReplicatedStorage.Shared                   <- src/shared
ServerScriptService.Server                 <- src/server
StarterPlayer.StarterPlayerScripts.Client  <- src/client
```

Everything else — all 38 loot models, the 5 guardians, the mutation VFX, the
9 treadmills, the purchased UI pack — exists **only inside the place file** and
is not in this repo. `rojo build` produces a place containing the code and
nothing else. Open that and you have an empty game.

**Always open the real place through Team Create.** Never open a locally built
`.rbxlx`.

---

## Getting set up (macOS or Windows)

### 1. Get the code

```bash
git clone https://github.com/khaielwork6-stack/Steal-A.git
cd Steal-A
```

If you already have a clone, **pull before you do anything else**:

```bash
git pull origin master
```

### 2. Install the toolchain

`rokit.toml` pins Rojo to 7.7.0. Install [Rokit](https://github.com/rojo-rbx/rokit)
(its README has the current macOS install line), then from the project folder:

```bash
rokit install
```

That reads `rokit.toml` and installs the exact Rojo version this project uses.
Mismatched Rojo versions will refuse to connect to the Studio plugin.

### 3. Install the Rojo plugin in Studio

Roblox Studio → Plugins → Manage Plugins → install **Rojo**. It must be the
plugin that matches Rojo 7.x.

### 4. Open the place

Studio → the game → **Edit** (Team Create). Not a local file.

### 5. Start the sync server

```bash
rojo serve default.project.json
```

It listens on port **34872**. Then in Studio: Rojo plugin → Connect.

---

## ⚠️ Only ONE person may have Rojo connected at a time

This is the rule that matters most when two people are working on the same
place.

Rojo pushes the contents of `src/` into the live place. If two people are
connected to the same Team Create session with different checkouts, whoever
syncs last wins, and the other person's work is silently overwritten inside the
place — including work that was already committed.

**Handover procedure:**

1. The person finishing **disconnects the Rojo plugin** in Studio and stops
   their `rojo serve`.
2. They commit and push everything: `git push origin master`.
3. The person taking over runs `git pull origin master`, **confirms they are on
   the newest commit**, and only then connects their Rojo.

If code ever does get clobbered, it is recoverable: everything is pushed to
`master`, so pull and reconnect. **Art is not recoverable from git** — that is
why the place must be saved, and why nobody should ever open a built `.rbxlx`.

---

## Where to start reading

`HANDOFF.md` is the real documentation — architecture, every non-obvious bug and
its root cause, and the current state of the project.

**Start at §18.** It says exactly where the last session stopped, what is
verified, what is not, and what to pick up next. §0 is the checklist to act on
first. §16 and §17 cover the two most recent bodies of work (the economy
rebalance, and the chase / DROP button / interaction fixes).

`src/shared/Config/` is where every tuning number lives. Nothing gameplay-facing
is hardcoded in a service — if you are changing a number, it belongs there.

---

## Verifying you have a working setup

In Studio, with Rojo connected, press **Play** and check the Output:

```
[LootService] 12 zones x 4 sockets filled
[GuardianService] 12 guardians posted (one per zone), safe line at Z=0
[Server] Steal Something services started
[Client] controllers started
```

Then run the config validation from the command bar:

```lua
require(game.ReplicatedStorage.Shared.Config.validate)()
```

It should print `[Config] validation PASSED - 849 checks`.

Two warnings are **expected and pre-existing**, ignore them:

- `StudioAccessToApisNotAllowed` — DataStores are off in Studio, profiles run in
  memory.
- `Failed to load sound rbxassetid://92804804272270` — the lobby music asset is
  not approved for this experience. Not a code bug.

### In Edit mode the game looks empty. That is correct.

Loot, guardians, and half the UI are created **at runtime**. In Edit mode the
sockets are genuinely empty, the left button rail is missing Upgrades and
Storage (they are cloned in by their controllers), the HUD shows the UI pack's
demo numbers, and the DROP button sits in the middle of the screen still
labelled "SHOP" because `DropController` only retitles and moves it on start.

None of that is damage. Press Play and it all appears.

---

## Testing tools

There is a Studio-only debug bridge. From the command bar in Play mode:

```lua
game.ServerStorage.DebugInvoke:Invoke("snapshot")
game.ServerStorage.DebugInvoke:Invoke("nope")  -- lists every command
```

Note the second argument is a player **name string or `nil`**, not a Player.

`execute_luau` / the command bar runs in a **separate Lua VM** from the game.
`require`-ing a server module there gives you a fresh copy with empty state, and
event connections made there die with the script. Go through `DebugInvoke`.
