--!strict
--[[
	PolishConfig
	The first-join flyover and the analytics switches (polish-events-analytics
	pass). The branded loading screen that used to live in ReplicatedFirst
	was removed (owner, 2026-09-18) - Roblox draws its own.
]]

local PolishConfig = {}

-- ==========================================================
-- FIRST-JOIN FLYOVER
-- ==========================================================

--- Master switch. Off = the flyover never plays and the server still marks
--- nothing (a later switch-on shows it to players who are still new).
PolishConfig.FLYOVER_ENABLED = true

--- A player is shown the flyover while `Profile.FlyoverSeen` is false AND
--- their saved tutorial stage is below this (TutorialService STAGE.INCOME = 5:
--- they have not yet placed their first item).
PolishConfig.FLYOVER_MAX_TUTORIAL_STAGE = 5

--- Seconds the SKIP button waits before it appears.
PolishConfig.FLYOVER_SKIP_AFTER = 1

--- Longest the flyover waits for the client to finish starting before giving
--- up on it. `LoadingScreenDone` is set by init.client.luau now that the
--- branded loading screen is gone, so this is a safety net, not the norm.
PolishConfig.FLYOVER_LOADING_WAIT = 90

export type FlyoverShot = {
	--- Which zone the shot looks at.
	zone: number,
	--- "room" = from the corridor into side room `room` (1 = -X, 2 = +X);
	--- "lane" = high above the corridor looking back towards the lobby.
	kind: "room" | "lane",
	room: number?,
	--- Seconds to travel from the previous shot (the first shot fades in).
	travel: number,
	--- Seconds to hold (with a slow push-in unless Reduced Effects is on).
	hold: number,
	caption: string,
}

--- Zones 1 -> 3 along the museum corridor. Total about 7.4 s plus the fades.
PolishConfig.FLYOVER_SHOTS = {
	{ zone = 1, kind = "room", room = 2, travel = 0, hold = 2.0, caption = "Steal sealed treasures" },
	{ zone = 2, kind = "room", room = 1, travel = 1.6, hold = 1.6, caption = "Dodge the lasers - touch one and you're thrown out" },
	{ zone = 3, kind = "lane", travel = 1.4, hold = 0.8, caption = "Carry it home to reveal it" },
} :: { FlyoverShot }

--- Fade to black before the first shot and before handing the camera back.
PolishConfig.FLYOVER_FADE_SECONDS = 0.35

-- ==========================================================
-- ANALYTICS
-- ==========================================================

--- Studio never sends analytics unless this is on; with it on, every event
--- is printed as well as sent. Toggle live with the `analyticsDebug`
--- command. Live servers always send (and never print).
PolishConfig.ANALYTICS_DEBUG = false

--- Roblox's per-server budget, per event category, per minute:
--- BASE + PER_PLAYER x players. SAFETY keeps us under it.
PolishConfig.ANALYTICS_BUDGET_BASE = 120
PolishConfig.ANALYTICS_BUDGET_PER_PLAYER = 20
PolishConfig.ANALYTICS_BUDGET_SAFETY = 0.8

--- Passive income is paid every tick; it is summed per player and logged
--- as ONE economy event this often (and on leave).
PolishConfig.ANALYTICS_PASSIVE_FLUSH_SECONDS = 300

--- How many would-be events the debug dump keeps.
PolishConfig.ANALYTICS_DUMP_SIZE = 200

-- ==========================================================
-- TUTORIAL ONBOARDING
-- ==========================================================
-- The objective line, chevron trail and target ring (TutorialController)
-- were retired by the tutorial-film pass in favour of the short film
-- (TutorialFilmConfig / TutorialFilmController); TUTORIAL_POINTER_ICON went
-- with them; there is nothing left to point at.

--- The client funnel remote: sustained rate and burst per player.
PolishConfig.ANALYTICS_CLIENT_PER_SECOND = 0.5
PolishConfig.ANALYTICS_CLIENT_BURST = 3

-- ==========================================================
-- [analytics-discord] QUIT CONTEXT + PERFORMANCE SAMPLER
-- ==========================================================
-- Shared because the client reads it; nothing secret lives here (the
-- webhook and the Discord switches are server-only, in
-- ServerScriptService.Server.Config.DiscordConfig).

--- MainUI.Frames panels the client may name as "the open panel". Anything
--- else is reported as "Other"; nothing at all as "None". The server
--- re-checks every name against this list.
PolishConfig.ANALYTICS_PANELS = {
	"Shop",
	"Upgrades",
	"Settings",
	"Index",
	"Sell",
	"Quests",
	"SeasonPass",
	"Daily",
	"Crew",
	"Trade",
	"GadgetStore",
	"TrailShop",
	"Storage",
} :: { string }

--- Panel reports: sustained rate and burst per player (their own limiter).
PolishConfig.ANALYTICS_PANEL_PER_SECOND = 1
PolishConfig.ANALYTICS_PANEL_BURST = 5

--- The client FPS sampler (PerfController). A spike is recorded when the
--- frame rate stays under PERF_FPS_THRESHOLD for PERF_LOW_SECONDS; then
--- nothing for PERF_COOLDOWN_SECONDS, and at most PERF_SESSION_CAP per session.
PolishConfig.PERF_SAMPLER_ENABLED = true
PolishConfig.PERF_FPS_THRESHOLD = 25
PolishConfig.PERF_LOW_SECONDS = 2
PolishConfig.PERF_COOLDOWN_SECONDS = 60
PolishConfig.PERF_SESSION_CAP = 10
--- Radius (studs) of the one-off particle / effect count around the camera.
PolishConfig.PERF_SCAN_RADIUS = 80
--- Client script errors forwarded per session (deduplicated by message).
PolishConfig.PERF_CLIENT_ERROR_CAP = 10
--- The PerfReport remote: sustained rate and burst per player.
PolishConfig.PERF_REPORT_PER_SECOND = 0.2
PolishConfig.PERF_REPORT_BURST = 3

return PolishConfig
