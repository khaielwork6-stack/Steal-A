--!strict
--[[
	TutorialFilmService
	Server half of the short film that replaced the old objective-line
	tutorial (tutorial-film pass). The film itself is entirely client-side
	and self-contained (TutorialFilmController); this service only:

	  * tells StateService whether a player is still owed the automatic
	    first-time play (`tutorialFilmDue`), from Profile.TutorialFilmDone;
	  * marks a playing player "in cinematic" for the film's length, so the
	    server-side safety rule has somewhere to live: the character is
	    anchored and PvPService refuses to land a hit on anyone this is true
	    for (isInCinematic); a hard cap clears the mark on its own if the
	    client never reports back;
	  * on a real "start" session finishing or being skipped, sets
	    Profile.TutorialFilmDone and completes the old tutorial's stage
	    (TutorialService.STAGE.COMPLETE) so nothing that ever gated on that
	    number - Daily Reward's auto-open, the flyover - is left waiting on
	    a system that no longer runs. A "replay" session (the Settings
	    "Watch tutorial again" button) touches neither.

	WHY THE CHARACTER NEEDS NO EXTRA GUARDIAN CHECK. The film only ever plays
	while the character is standing at its own base (TutorialFilmController
	waits for that), and BaseService.isSafePosition already refuses PvP and
	keeps guardians out of ANY safe zone including a plot - see BaseService's
	own comment on isSafePosition. The isInCinematic check below is belt and
	braces on top of that, not the only thing standing in the way.

	SAFETY. Every entry point is pcall-guarded; the hard cap
	(TutorialFilmConfig.HARD_CAP_SECONDS) restores a player on its own even
	if the client that asked for cinematic safety never says it is done - a
	frozen or disconnected client can never leave a player anchored forever.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TutorialFilmConfig = require(ReplicatedStorage.Shared.Config.TutorialFilmConfig)

local AnalyticsEvents = require(script.Parent.AnalyticsEvents)
local DataService = require(script.Parent.DataService)
local StateService = require(script.Parent.StateService)
local TutorialService = require(script.Parent.TutorialService)

local TutorialFilmService = {}

type Session = {
	--- The Settings replay never touches Profile.TutorialFilmDone or the
	--- old tutorial's stage; the automatic first-time play always does.
	replay: boolean,
	--- Bumped by every new session; the hard-cap timer for an old one that
	--- sees a newer token quits instead of clearing a session that is not
	--- its own.
	token: number,
}

local sessions: { [Player]: Session } = {}
local nextToken = 0

-- ==========================================================
-- DUE / DONE
-- ==========================================================

--- Read by StateService (`tutorialFilmDue`). True only while the automatic
--- first-time play is still owed; the client itself waits for its own
--- start-up, the character and the base before actually starting it.
function TutorialFilmService.isDue(player: Player): boolean
	if not TutorialFilmConfig.ENABLED then
		return false
	end
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	return profile.TutorialFilmDone ~= true
end

--- True while `player` is marked safe for the film, whoever asked for it.
--- Checked by PvPService so nobody can be hit while it plays.
function TutorialFilmService.isInCinematic(player: Player): boolean
	return sessions[player] ~= nil
end

-- ==========================================================
-- CINEMATIC SAFETY
-- ==========================================================

--- Returns true always (never false) - the return value exists only so
--- `pcall(setAnchored, ...)` has something to destructure a second value
--- from at every call site; a missing root is not an error, just a no-op.
local function setAnchored(player: Player, anchored: boolean): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = anchored
	end
	return true
end

--- Clears the mark and restores the character, whatever ended the session.
local function endSession(player: Player, reason: string)
	if not sessions[player] then
		return
	end
	sessions[player] = nil
	player:SetAttribute("InTutorialFilm", nil)
	local ok, err = pcall(setAnchored, player, false)
	if not ok then
		warn(`[TutorialFilmService] failed to restore {player.Name} after {reason}: {err}`)
	end
end

local function beginSession(player: Player, replay: boolean)
	-- A second "start"/"replay" while one is already running just replaces
	-- it (a reconnecting client asking again) rather than stacking.
	if sessions[player] then
		endSession(player, "restarted")
	end
	nextToken += 1
	local token = nextToken
	sessions[player] = { replay = replay, token = token }
	player:SetAttribute("InTutorialFilm", true)
	pcall(setAnchored, player, true)

	task.delay(TutorialFilmConfig.HARD_CAP_SECONDS, function()
		local session = sessions[player]
		if session and session.token == token then
			warn(`[TutorialFilmService] {player.Name}'s film hit the {TutorialFilmConfig.HARD_CAP_SECONDS}s hard cap - restoring on its own`)
			endSession(player, "hard cap")
		end
	end)
end

-- ==========================================================
-- COMPLETION
-- ==========================================================

--- Returns true always (never false) - see setAnchored on why.
local function markDone(player: Player): boolean
	local profile = DataService.get(player)
	if not profile then
		return true
	end
	profile.TutorialFilmDone = true
	-- The film replaces the whole old opening; nothing should still be
	-- waiting on TutorialService's stage machine once it has been shown.
	if profile.TutorialStage < TutorialService.STAGE.COMPLETE then
		profile.TutorialStage = TutorialService.STAGE.COMPLETE
	end
	StateService.markDirty(player, true)
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return true
end

local function finishSession(player: Player, skipped: boolean)
	local session = sessions[player]
	local replay = session ~= nil and session.replay
	endSession(player, if skipped then "skip" else "finish")
	if replay then
		-- A replay from Settings: nothing persisted changes.
		return
	end
	local ok, err = pcall(markDone, player)
	if not ok then
		warn(`[TutorialFilmService] failed to mark {player.Name}'s film done: {err}`)
	end
	pcall(AnalyticsEvents.custom, player, if skipped then "FilmSkipped" else "FilmFinished")
end

-- ==========================================================
-- START
-- ==========================================================

function TutorialFilmService.start()
	StateService.addProvider("tutorialFilmDue", TutorialFilmService.isDue)

	-- One "start"/"replay" and one "done" per film is the normal traffic; a
	-- few more covers a reconnect or a retried request.
	local limiter = RateLimiter.new(1, 4)
	Remotes.get("TutorialFilmRequest").OnServerEvent:Connect(function(player, action, arg)
		if type(action) ~= "string" or not limiter:consume(player) then
			return
		end
		local ok, err = pcall(function()
			if action == "start" then
				beginSession(player, false)
				AnalyticsEvents.custom(player, "FilmStarted")
			elseif action == "replay" then
				beginSession(player, true)
			elseif action == "done" then
				finishSession(player, arg == true)
			end
		end)
		if not ok then
			warn(`[TutorialFilmService] request "{tostring(action)}" from {player.Name} failed: {err}`)
			-- Never leave a player anchored because a handler threw partway
			-- through; the hard-cap timer would eventually catch it, but
			-- there is no reason to wait.
			endSession(player, "error")
		end
	end)

	-- Belt and braces: if a session somehow survives a respawn (the client
	-- should have reported "done" first), the new character is anchored too
	-- rather than left free while the old one's mark is still up.
	local function onCharacterAdded(player: Player)
		player.CharacterAdded:Connect(function()
			if sessions[player] then
				pcall(setAnchored, player, true)
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		onCharacterAdded(player)
	end
	Players.PlayerAdded:Connect(onCharacterAdded)

	Players.PlayerRemoving:Connect(function(player)
		endSession(player, "left")
		limiter:release(player)
	end)
end

-- ==========================================================
-- DEBUG (DebugCommands.TutorialFilm)
-- ==========================================================

--- Debug only: puts the automatic first-time play "due" again, without
--- touching anything else - the caller is responsible for restoring
--- Profile.TutorialFilmDone afterwards (see the debug commands' snapshot).
function TutorialFilmService.debugForceDue(player: Player)
	local profile = DataService.get(player)
	if profile then
		profile.TutorialFilmDone = false
		StateService.markDirty(player, true)
	end
end

--- Debug only: the exact server-side effect of a client report, without a
--- live film running - mirrors the TutorialFilmRequest handler exactly, so
--- `simulateSkip` / `simulateFinish` test the real completion path.
function TutorialFilmService.debugSimulate(player: Player, action: string, arg: any): boolean
	if action == "start" then
		beginSession(player, false)
		AnalyticsEvents.custom(player, "FilmStarted")
	elseif action == "replay" then
		beginSession(player, true)
	elseif action == "done" then
		finishSession(player, arg == true)
	else
		return false
	end
	return true
end

--- Debug only: a snapshot for the `filmState` command.
function TutorialFilmService.debugState(player: Player): { [string]: any }
	local profile = DataService.get(player)
	return {
		due = TutorialFilmService.isDue(player),
		inCinematic = TutorialFilmService.isInCinematic(player),
		filmDone = profile and profile.TutorialFilmDone,
		tutorialStage = profile and profile.TutorialStage,
	}
end

return TutorialFilmService
