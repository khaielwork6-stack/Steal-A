--!strict
--[[
	Audio
	The only thing in the game that creates a Sound instance.

	Two rules this exists to enforce:

	  1. NO DUPLICATES PER ACTIVATION. A naive `Instance.new("Sound")` on every
	     trigger leaves a growing pile of Sounds on a part that is hit repeatedly.
	     One-shots here are pooled per (parent, cue) and simply replayed, and
	     loops are idempotent - asking for a loop that is already running does
	     nothing rather than starting a second copy.

	  2. NO ASSET IDS AT CALL SITES. Everything is addressed by cue name and
	     resolved through AudioConfig.

	Usable from both the server and the client. A world cue parented to a part on
	the SERVER replicates to everyone automatically, which is what makes guardian
	snoring and impact hits audible to bystanders with no remote traffic.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)

local Audio = {}

local FOLDER_NAME = "ActiveAudio"

--- Builds a Sound from a cue. Not parented; callers decide where it lives.
function Audio.create(name: string): Sound?
	local cue = AudioConfig.get(name)
	if not cue then
		warn(`[Audio] unknown cue "{name}"`)
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = cue.id
	sound.Volume = cue.volume
	sound.Looped = cue.looped == true

	if cue.category == "world" then
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMaxDistance = cue.rollOff or 150
		sound.RollOffMinDistance = 8
	end

	return sound
end

-- ==========================================================
-- ONE-SHOTS
-- ==========================================================

--- Plays a positional one-shot at `parent`. Reuses the Sound if this cue is
--- already attached there, so hitting the same target repeatedly cannot stack
--- up instances.
function Audio.playAt(name: string, parent: Instance?): Sound?
	if not parent then
		return nil
	end

	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Sound") then
		existing.TimePosition = 0
		existing:Play()
		return existing
	end

	local sound = Audio.create(name)
	if not sound then
		return nil
	end
	sound.Parent = parent
	sound:Play()

	-- A one-shot on a part that outlives it would otherwise linger forever.
	if not sound.Looped then
		sound.Ended:Connect(function()
			sound:Destroy()
		end)
		Debris:AddItem(sound, 30)
	end
	return sound
end

--- Plays a non-positional one-shot. Client-side use; on the server this would
--- be inaudible, so callers there want playAt instead.
function Audio.play(name: string): Sound?
	local holder = SoundService:FindFirstChild(FOLDER_NAME)
	if not holder then
		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = SoundService
		holder = folder
	end
	return Audio.playAt(name, holder)
end

-- ==========================================================
-- LOOPS
-- ==========================================================

--- Starts a looping cue on `parent` if it is not already running. Idempotent:
--- calling it every frame while a guardian sleeps is safe.
function Audio.startLoop(name: string, parent: Instance?): Sound?
	if not parent then
		return nil
	end

	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Sound") then
		if not existing.IsPlaying then
			existing:Play()
		end
		return existing
	end

	local sound = Audio.create(name)
	if not sound then
		return nil
	end
	sound.Looped = true
	sound.Parent = parent
	sound:Play()
	return sound
end

--- Stops and removes a looping cue. Safe to call when it was never started,
--- which matters because a guardian can wake from states that never slept.
function Audio.stopLoop(name: string, parent: Instance?)
	if not parent then
		return
	end
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Sound") then
		existing:Stop()
		existing:Destroy()
	end
end

return Audio
