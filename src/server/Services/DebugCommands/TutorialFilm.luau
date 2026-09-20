--!strict
--[[
	DebugCommands.TutorialFilm
	Studio-only test commands for the short tutorial film (tutorial-film
	pass). Loaded by DebugService; invoke through
	ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...) or the
	DebugRequest attribute bridge.

	THE FILM ITSELF PLAYS CLIENT-SIDE. These commands drive the SERVER half
	only - `Profile.TutorialFilmDone`, StateService's `tutorialFilmDue`
	field, and the "in cinematic" safety mark - the same way a real client
	report would. `filmForceStart` flips the due flag and pushes a full
	state, which makes any client already in the game (Studio Play) pick it
	up and actually play the film through the normal `tutorialFilmDue`
	watcher; `filmSimulateSkip` / `filmSimulateFinish` exercise the
	server-side completion path directly, without needing a client to be
	watching at all.

	PROFILE SAFETY. Studio with API access writes to the owner's REAL
	DataStore. `filmForceStart` and `filmReset` snapshot
	`TutorialFilmDone` / `TutorialStage` first; a command that throws
	restores it on the spot, and `filmRestore` puts it back (and saves) when
	the test is over. `filmSimulateSkip` / `filmSimulateFinish` are meant to
	be run right after `filmForceStart` while the snapshot is held, so
	`filmRestore` undoes the whole sequence in one call.

	  filmState                      due, inCinematic, filmDone, tutorialStage
	  filmForceStart                 due = true, full push (Play a client to
	                                  see it start on its own)
	  filmSimulateSkip               as if the client reported ("done", true)
	  filmSimulateFinish             as if the client reported ("done", false)
	  filmReplay                     as if the client asked ("replay") -
	                                  marks in-cinematic, touches no flag
	  filmRestore                    put the snapshot back
]]

local DataService = require(script.Parent.Parent.DataService)
local StateService = require(script.Parent.Parent.StateService)
local TutorialFilmService = require(script.Parent.Parent.TutorialFilmService)

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

local SNAPSHOT_FIELDS = { "TutorialFilmDone", "TutorialStage" }

local snapshots: { [Player]: { [string]: any } } = {}

local function snapshot(player: Player, profile: DataService.Profile)
	if snapshots[player] then
		return
	end
	local held = {}
	for _, field in SNAPSHOT_FIELDS do
		held[field] = copy((profile :: any)[field])
	end
	snapshots[player] = held
end

local function restore(player: Player): boolean
	local held = snapshots[player]
	local profile = DataService.get(player)
	if not held or not profile then
		return false
	end
	for field, value in held do
		(profile :: any)[field] = copy(value)
	end
	snapshots[player] = nil
	StateService.pushNow(player, true)
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return true
end

local function guarded(player: Player, fn: (DataService.Profile) -> any): any
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	snapshot(player, profile)
	local ok, result = pcall(fn, profile)
	if not ok then
		restore(player)
		error(result)
	end
	return result
end

return {
	filmState = function(player: Player): any
		return TutorialFilmService.debugState(player)
	end,

	filmForceStart = function(player: Player): any
		return guarded(player, function(_profile)
			TutorialFilmService.debugForceDue(player)
			return {
				due = TutorialFilmService.isDue(player),
				note = "Play as this character in Studio: the film should start on its own within a few seconds. filmRestore undoes this.",
			}
		end)
	end,

	filmSimulateSkip = function(player: Player): any
		return guarded(player, function(profile)
			-- The debug caller decides "skip" happened; a real client would
			-- have to have called "start" or "replay" first for the
			-- in-cinematic mark to exist, but the completion path (setting
			-- the flag / stage) works the same either way.
			local ok = TutorialFilmService.debugSimulate(player, "done", true)
			return {
				simulated = ok,
				filmDone = profile.TutorialFilmDone,
				tutorialStage = profile.TutorialStage,
				note = "as if the client reported a skip; filmRestore undoes this",
			}
		end)
	end,

	filmSimulateFinish = function(player: Player): any
		return guarded(player, function(profile)
			local ok = TutorialFilmService.debugSimulate(player, "done", false)
			return {
				simulated = ok,
				filmDone = profile.TutorialFilmDone,
				tutorialStage = profile.TutorialStage,
				note = "as if the client reported finishing; filmRestore undoes this",
			}
		end)
	end,

	filmReplay = function(player: Player): any
		local ok = TutorialFilmService.debugSimulate(player, "replay", nil)
		return { simulated = ok, inCinematic = TutorialFilmService.isInCinematic(player), note = "no profile field is touched by a replay" }
	end,

	filmRestore = function(player: Player): any
		return { restored = restore(player) }
	end,
}
