--!strict
--[[
	ChaseAudioController
	The chase soundtrack for the CHASED player, as one explicit state machine.

	THE SEQUENCE
	  guardian takes you as its target  (Player.Chased -> true)
	      the server has already played the alert at the guardian, once
	      wait 0.4 s
	      start the chase music loop                      [ALERTED -> CHASING]
	  you cross the red line           (SoundCue "EscapeSting")
	      stop the music at once, play the sting, wait 0.5 s, play Escape
	  the guardian catches you / you drop it / you die / Night falls
	                                   (Player.Chased -> false, or NightPhase)
	      stop the music, cancel any pending start        [-> IDLE]

	WHY TOKENS
	Every delayed step captures a token and checks it before acting. A start
	scheduled 0.4 s after the alert therefore cannot fire after the chase has
	already ended in that window, and a sting's follow-up cue cannot play if a
	new chase began meanwhile. The loop itself is one Sound instance, reused:
	it can never be started twice and never left playing.

	WHAT IS NOT HERE
	Entering a zone plays nothing from this file. Zone entry is
	ZoneSignService's business; there is no zone-entry music, on purpose.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local AudioController = require(script.Parent.AudioController)

local ChaseAudioController = {}

local player = Players.LocalPlayer

--- Seconds between the guardian's alert and the music starting.
local MUSIC_DELAY = 0.4
--- Seconds between the escape sting and the safe-zone cue.
local SAFE_DELAY = 0.5

type State = "Idle" | "Alerted" | "Chasing"

local state: State = "Idle"
local token = 0
local music: Sound? = nil

-- ==========================================================
-- THE LOOP
-- ==========================================================

local function ensureMusic(): Sound?
	if music and music.Parent then
		return music
	end
	local sound = Audio.create("ChaseMusic")
	if not sound then
		return nil
	end
	sound.Name = "ChaseMusic"
	sound.Volume = 0
	sound.Parent = SoundService
	music = sound
	return sound
end

local function startMusic()
	local cue = AudioConfig.get("ChaseMusic")
	local sound = ensureMusic()
	if not sound or not cue then
		return
	end
	if not sound.IsPlaying then
		sound.TimePosition = 0
		sound:Play()
	end
	TweenService:Create(sound, TweenInfo.new(cue.fade or 0.3, Enum.EasingStyle.Sine), { Volume = cue.volume }):Play()
end

local function stopMusic(immediate: boolean?)
	local sound = music
	if not sound or not sound.IsPlaying then
		return
	end
	if immediate then
		sound:Stop()
		sound.Volume = 0
		return
	end
	local cue = AudioConfig.get("ChaseMusic")
	local fade = TweenService:Create(sound, TweenInfo.new(cue and cue.fade or 0.3, Enum.EasingStyle.Sine), { Volume = 0 })
	local mine = token
	fade.Completed:Once(function()
		-- Only stop if nothing restarted it while it was fading.
		if token == mine and sound.Volume <= 0.01 then
			sound:Stop()
		end
	end)
	fade:Play()
end

-- ==========================================================
-- TRANSITIONS
-- ==========================================================

--- The state, mirrored onto the local Player as an attribute (client-side
--- only, never replicated) so a test can read it without reaching in.
local function setState(next: State)
	state = next
	player:SetAttribute("ChaseAudioState", next)
	-- The lobby bed steps aside for the whole chase and returns after it.
	AudioController.setDucked(next ~= "Idle")
end

local function toIdle(immediate: boolean?)
	-- Only a LIVE chase has anything to cancel (a start still counting down,
	-- a loop still fading). Going idle while already idle must not bump the
	-- token: the server clears Chased in the same frame it sends the escape
	-- sting, and that redundant call used to cancel the sting's follow-up cue.
	if state ~= "Idle" then
		token += 1
	end
	setState("Idle")
	stopMusic(immediate)
end

local function onChaseStarted()
	if state ~= "Idle" then
		return
	end
	token += 1
	local mine = token
	setState("Alerted")
	task.delay(MUSIC_DELAY, function()
		if token ~= mine or state ~= "Alerted" then
			return -- ended, or a new chase began, inside the delay
		end
		setState("Chasing")
		startMusic()
	end)
end

--- Crossing the line: the music stops NOW. The Escape cue itself is played
--- by AudioController's generic SoundCue path, exactly once; nothing is
--- played here, so the event can never sound twice.
local function onEscaped()
	toIdle(true)
end

-- ==========================================================
-- START
-- ==========================================================

function ChaseAudioController.start()
	local function chased(): boolean
		return player:GetAttribute("Chased") == true
	end

	player:GetAttributeChangedSignal("Chased"):Connect(function()
		if chased() then
			onChaseStarted()
		else
			toIdle(false)
		end
	end)
	if chased() then
		onChaseStarted()
	end

	Remotes.get("SoundCue").OnClientEvent:Connect(function(name: string)
		if name == "Escape" or name == "EscapeSting" then
			onEscaped()
		end
	end)

	-- Night ends every chase on the server, which clears Chased and stops the
	-- music through the path above; this is the belt to that brace, and it
	-- also cancels a start still counting down.
	ReplicatedStorage:GetAttributeChangedSignal("NightPhase"):Connect(function()
		if ReplicatedStorage:GetAttribute("NightPhase") == "Night" then
			toIdle(false)
		end
	end)

	-- Death, reset, respawn: nothing chases a fresh character.
	player.CharacterAdded:Connect(function()
		toIdle(false)
	end)
end

return ChaseAudioController
