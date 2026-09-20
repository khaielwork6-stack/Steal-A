--!strict
--[[
	TutorialFilmConfig
	The in-engine cinematic that replaces the old objective-line tutorial
	(tutorial-film pass). One master switch, the caption/timing script for
	every beat, and the safety numbers the server enforces while it plays.

	THE FILM IS CLIENT-ONLY AND SELF-CONTAINED (TutorialFilmController). It
	builds a small stand-in stage from clones of real replicated art (a
	workspace guardian, a workspace laser beam, TreadmillModel) plus simple
	parts where nothing replicated exists (the sealed chest - see
	docs/codex-prompts/tutorial-film.md), and never touches the player's real
	plot, museum or profile. This file is shared so both the client (what to
	show) and the server (how long it may safely run) read the same numbers.
]]

local TutorialFilmConfig = {}

--- Master switch. Off = the film never plays and nothing is marked seen, so
--- turning it back on later still shows it to anyone who has not watched it.
--- TEMPORARILY OFF (owner, 2026-09-20): new players get no tutorial film while it
--- is being reworked. Set this back to true to turn it on again; nothing else
--- needs to change (no profile is marked, so everyone who has not watched it
--- will see it once it is back). While it is off the Settings "Tutorial" row
--- does nothing. The old objective-line tutorial no longer exists, so a new
--- player currently gets no guidance at all.
TutorialFilmConfig.ENABLED = false

--- Hard cap on how long a player can be marked "in cinematic" server-side,
--- whatever the client reports (or fails to report). Belt and braces against
--- a client that freezes mid-film: the server clears the mark and restores
--- the character on its own after this many seconds.
TutorialFilmConfig.HARD_CAP_SECONDS = 90

--- Seconds the SKIP button waits before it appears (always big enough to tap,
--- never truly hidden - see TutorialFilmController).
TutorialFilmConfig.SKIP_AFTER = 1

--- Fade to/from black around the whole film and between hard cuts.
TutorialFilmConfig.FADE_SECONDS = 0.35

--- The end card ("Now it's your turn!") auto-closes after this long if the
--- player never taps it or the Play button.
TutorialFilmConfig.END_CARD_SECONDS = 5

--- Longest the controller waits for the client to finish starting and the
--- character to be at its base before giving up on playing at all this
--- session (it tries again next join).
TutorialFilmConfig.LOADING_WAIT = 90

export type Beat = {
	--- Unique, stable identifier TutorialFilmController matches against to
	--- build and animate that beat's own pieces of the stage.
	key: string,
	--- One short line, sentence case, shown bottom-centre while this beat
	--- plays. No caption is ever longer than a short sentence - the brief
	--- asks for "no reading required beyond short captions".
	caption: string,
	--- Seconds this beat holds once its camera move finishes.
	hold: number,
}

--- THE SCRIPT, in order. ~40-60s of picture; the number of words on screen
--- at once is deliberately tiny. TutorialFilmController owns what each named
--- beat actually builds and animates; this table is only the caption + the
--- pacing, so retiming the film is a config change.
TutorialFilmConfig.BEATS = {
	{ key = "spawn", caption = "Steal & Run!", hold = 3.0 },
	{ key = "sneak", caption = "Sneak into the museum", hold = 4.0 },
	{ key = "guard", caption = "Guards guard the loot", hold = 3.5 },
	{ key = "laser", caption = "Jump the lasers", hold = 3.5 },
	{ key = "grab", caption = "Grab a chest", hold = 3.0 },
	{ key = "run", caption = "Run home!", hold = 4.5 },
	{ key = "place", caption = "Place it in your base", hold = 3.5 },
	{ key = "income", caption = "It earns money while you're away", hold = 4.0 },
	{ key = "train", caption = "Train Speed to escape faster", hold = 4.0 },
} :: { Beat }

--- The end card is not a BEAT (no camera move, its own layout), so it is
--- its own constant rather than a row in the table above.
TutorialFilmConfig.END_CAPTION = "Now it's your turn!"

-- ==========================================================
-- STAGE GEOMETRY
-- ==========================================================

--- Where the whole self-built stage is planted: far from the real map so it
--- can never overlap real geometry (streaming is off - see START_HERE.md -
--- so "far away" is about avoiding overlap, not about culling). Built and
--- destroyed by TutorialFilmController every run; nothing else ever reads
--- this folder.
TutorialFilmConfig.STAGE_ORIGIN = Vector3.new(0, 4000, 0)
TutorialFilmConfig.STAGE_FOLDER_NAME = "_TutorialFilmStage"

return TutorialFilmConfig
