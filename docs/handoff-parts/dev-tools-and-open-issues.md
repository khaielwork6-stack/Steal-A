# Dev tools (Studio only) and open issues - 2026-09-20 end of session

## Dev tools (built, tested, not yet pressed for real)
- `src/server/Services/DevService.luau` + `src/client/Controllers/DevToolsController.luau`.
  A "DEV" pill at top-centre (Studio only): GIVE CASH (amount box + +$1M/$1B/$1T/$1Qa)
  and RESET ALL DATA (behind ConfirmDialog). Remote `DevRequest`; the server only
  listens in Studio, the client only builds the panel in Studio.
- `DataService.devReset(player)` replaces the profile IN PLACE with a new player's and
  saves the previous state first (so that version stays in DataStore history ~30 days).
- Test: `devToolsTest` (DebugCommands/Dev.luau) is self-restoring and passes. Nobody has
  pressed the real RESET button yet.
- WARNING: Studio plays on the owner's REAL save (unless it is a guest on a live server's
  save: then nothing is written). RESET wipes what the live game loads too.

## OPEN ISSUE: the owner's saved data lost its items
Read from DataStore (`PlayerProfiles_v1`, key `player_<Yeno_mediaX id>`):
- 17:59:48 UTC 2026-09-20: 10 displays, Inventory = RarePainting(held), RoyalPainting(held), Cash 33.49B, Speed 1.751B.
- 18:14:03 UTC (newest): 0 displays, 0 Inventory, Cash 33.82B, Speed 1.759B, Lifetime.Steals unchanged (176).
Cash and Speed kept rising after 17:59, so a full reset is ruled out and the owner (or the
live game) played in between. The profile was already empty when the last Studio session
loaded it. CAUSE UNKNOWN. Ask the owner what they did in the live game around 18:00-18:14
(sold everything? a live-only bug? the live build is an older publish with the first hold-items
version). The 17:59:48 version can be restored (needs the owner's OK, it writes the real save):
read it with the `profileHistory` command / `store:GetVersionAsync`, copy DisplayItems and
Inventory back, keep the newer Cash/Speed.

## Also outstanding
- Owner must Save + Publish ("Migrate to latest update"): the smoke exploit fix and the
  Base03/Base04 SafeZone fix are not live until then. See docs/OWNER_TODO.md sections 0 and 0b.
- Decide the Relic Roll prize pool; decide what happens to russ1719's account.
