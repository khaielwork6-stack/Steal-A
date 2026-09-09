--!strict
--[[
	AudioController
	Client-side sound: UI feedback, personal event cues, and the lobby music bed.

	WHAT PLAYS WHERE
	World sounds (guardian snoring, alerts, impacts) are NOT here. Those are
	created on the server, parented to the part they belong to, and replicate
	positionally on their own - so a bystander hears the whistle from the right
	direction with no network traffic of ours. This controller owns only what is
	specific to the local player.

	UI SOUND WITHOUT TOUCHING THE PACK
	Hover and click are wired by walking MainUI and connecting MouseEnter /
	Activated on every button, plus DescendantAdded for buttons built later. That
	is deliberately sound-only: it never sets `_UIHandlerSetup` and never binds an
	animation, so it cannot take a button away from the pack's own handler the way
	UIAnim.bindButton would. Adding a listener is additive; claiming a button is
	not.

	LOBBY MUSIC IS GEOMETRY, NOT NETWORK
	The red line is Z = 0 in map space and the lobby is behind it, so "am I safe"
	is a comparison the client can make every frame for free. Asking the server
	would cost a replicated flag and would lag the crossfade behind the player.
	A margin band stops the music flapping when someone stands on the boundary.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local AudioConfig = require(ReplicatedStorage.Shared.Config.AudioConfig)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local AudioController = {}

local player = Players.LocalPlayer

local lastHoverAt = 0
local musicSound: Sound? = nil
--- True behind the red line (lobby bed), false out in the zones (zone bed).
local musicWanted = false
--- Lets an event-specific cue cancel the generic notification beep queued for
--- the same moment. See the SoundCue handler in start().
local pendingGenericToken = 0

-- ==========================================================
-- PUBLIC
-- ==========================================================

function AudioController.play(name: string)
	Audio.play(name)
end

-- ==========================================================
-- UI
-- ==========================================================

local function hookButton(button: GuiButton)
	if button:GetAttribute("_AudioHooked") then
		return
	end
	button:SetAttribute("_AudioHooked", true)

	-- NO HOVER SOUND ON TOUCH. A phone has no hover: MouseEnter fires as a
	-- thumb drags across a button, so a thumbstick nudged upward through the
	-- menu block machine-gunned the hover tick. Touch keeps the click.
	if not Device.isTouch() then
		button.MouseEnter:Connect(function()
			local now = os.clock()
			if now - lastHoverAt < AudioConfig.HOVER_COOLDOWN then
				return
			end
			lastHoverAt = now
			Audio.play("UiHover")
		end)
	end

	button.Activated:Connect(function()
		Audio.play("UiClick")
	end)

	-- Activated does not fire on a button the pack left Active = false, and the
	-- pack drives plenty of its own buttons that way. MouseButton1Click still
	-- fires there, so it is the reliable click signal for sound purposes.
	button.MouseButton1Click:Connect(function()
		if not button.Active then
			Audio.play("UiClick")
		end
	end)
end

--- Panels opening and closing. Watched by Visible rather than by hooking the
--- pack's open routine, so it covers every panel including ones we add.
local function hookPanel(frame: GuiObject)
	if frame:GetAttribute("_AudioHooked") then
		return
	end
	frame:SetAttribute("_AudioHooked", true)
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		-- OPENING only. A close is silent, and a refused action never comes
		-- through here at all (it is a Notify "error", which is UiDenied).
		if frame.Visible then
			Audio.play("UiOpen")
		end
	end)
end

local function hookInterface(ui: Instance)
	for _, descendant in ui:GetDescendants() do
		if descendant:IsA("GuiButton") then
			hookButton(descendant)
		end
	end

	local frames = ui:FindFirstChild("Frames")
	if frames then
		for _, panel in frames:GetChildren() do
			if panel:IsA("GuiObject") then
				hookPanel(panel)
			end
		end
		frames.ChildAdded:Connect(function(child)
			if child:IsA("GuiObject") then
				hookPanel(child)
			end
		end)
	end

	-- Cards, tabs and claim bars are all built after this runs.
	ui.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("GuiButton") then
			hookButton(descendant)
		end
	end)
end

-- ==========================================================
-- MUSIC
-- ==========================================================

-- TWO BEDS, ONE PLAYING. The LOBBY bed behind the red line, the ZONE bed out
-- in the zones - and neither while a chase is on, because ChaseAudioController
-- owns that moment with the chase loop. Both beds stay alive and looped at
-- volume 0 rather than being stopped and restarted, so a fade in resumes
-- where the track was instead of snapping back to its first bar.

--- The bed for a cue, created once and kept.
local zoneSound: Sound? = nil

local function ensureBed(cue: string, current: Sound?): Sound?
	if current and current.Parent then
		return current
	end
	local sound = Audio.create(cue)
	if not sound then
		return nil
	end
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	sound:Play()
	return sound
end

--- While a chase is on, both beds go SILENT: the chase loop replaces them
--- rather than layering over a quiet bed underneath.
local ducked = false

local function fadeTo(sound: Sound?, cueName: string, target: number)
	local cue = AudioConfig.get(cueName)
	if not sound or not cue then
		return
	end
	-- Always a fade. Cutting a bed the instant a player steps over the line is
	-- exactly the jarring transition this is meant to avoid.
	TweenService:Create(sound, TweenInfo.new(cue.fade or 1, Enum.EasingStyle.Sine), { Volume = target }):Play()
end

local function applyMusicVolume()
	musicSound = ensureBed("LobbyMusic", musicSound)
	zoneSound = ensureBed("ZoneMusic", zoneSound)
	local lobbyCue = AudioConfig.get("LobbyMusic")
	local zoneCue = AudioConfig.get("ZoneMusic")
	local lobbyTarget = if musicWanted and not ducked and lobbyCue then lobbyCue.volume else 0
	local zoneTarget = if not musicWanted and not ducked and zoneCue then zoneCue.volume else 0
	fadeTo(musicSound, "LobbyMusic", lobbyTarget)
	fadeTo(zoneSound, "ZoneMusic", zoneTarget)
end

--- `on` = in the lobby (safe zone). Off = out in the zones.
local function setMusic(on: boolean)
	if on == musicWanted then
		return
	end
	musicWanted = on
	applyMusicVolume()
end

--- ChaseAudioController silences the beds for the length of a chase, so the
--- chase loop is the only music until it ends however it ends.
function AudioController.setDucked(value: boolean)
	if ducked == value then
		return
	end
	ducked = value
	applyMusicVolume()
end

--- Behind the red line (Z below zero) is the lobby and every player base.
local function updateMusic()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local z = root.Position.Z
	local margin = AudioConfig.MUSIC_BOUNDARY_MARGIN
	-- Hysteresis: the threshold to START music is deeper into the lobby than the
	-- threshold to STOP it, so standing on the line cannot oscillate.
	if musicWanted then
		if z > margin then
			setMusic(false)
		end
	elseif z < -margin then
		setMusic(true)
	end
end

-- ==========================================================
-- START
-- ==========================================================

--- Warms the gameplay cues that must land on their first play - the guardian
--- catch sounds and the event stings - so the first hit of a session is not
--- silent while the asset streams in. Background; nothing waits on it.
local function preloadCues()
	local ContentProvider = game:GetService("ContentProvider")
	local sounds: { Instance } = {}
	local wanted = { "Notification", "PlaceItem", "StoredItem", "NightSpawn", "Escape", "BossHit", "NpcCatch", "BatHit" }
	for zoneIndex in AudioConfig.GuardianHits do
		table.insert(wanted, `GuardianHit_{zoneIndex}`)
	end
	for _, name in wanted do
		local sound = Audio.create(name)
		if sound then
			sound.Parent = SoundService
			table.insert(sounds, sound)
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(sounds)
		end)
		for _, sound in sounds do
			sound:Destroy()
		end
	end)
end

function AudioController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if ui then
		hookInterface(ui)
	end
	preloadCues()

	-- The server names a cue; it never sends an asset id.
	--
	-- A specific cue also CANCELS the pending generic notification beep for the
	-- same event. Selling fires a toast and then a Sell cue from the same server
	-- frame, and playing both is the muddy double-hit the boss/regular split
	-- exists to avoid. The toast always lands first, so the generic beep is
	-- deferred by a frame and a specific cue arriving in that window wins.
	Remotes.get("SoundCue").OnClientEvent:Connect(function(name: string)
		if type(name) ~= "string" then
			return
		end
		pendingGenericToken += 1
		-- The escape sting is sequenced by ChaseAudioController (stop the
		-- chase music, sting, then the safe-zone cue); playing it here too
		-- would double it.
		if name == "EscapeSting" then
			return
		end
		Audio.play(name)
	end)

	-- Server-made world sounds (snoring, hits, the bat) arrive with no mixer
	-- group. File them under SFX as they appear so the volume slider owns them.
	local sfx = Audio.group(Audio.GROUP_SFX)
	local function adopt(instance: Instance)
		if instance:IsA("Sound") and sfx and instance.SoundGroup == nil then
			instance.SoundGroup = sfx
		end
	end
	for _, descendant in workspace:GetDescendants() do
		adopt(descendant)
	end
	workspace.DescendantAdded:Connect(adopt)

	-- Toasts already carry a `detail` tag that drives the world VFX burst, so the
	-- purchase and unlock cues ride that same tag rather than needing a sound
	-- call added at every upgrade site on the server.
	Remotes.get("Notify").OnClientEvent:Connect(function(kind: string, _message: string, detail: string?)
		-- EXACTLY ONE cue per toast. A specific cue replaces the generic one
		-- rather than layering over it, for the same reason a boss hit replaces
		-- the regular hit: two sounds on one event just muddies both.
		if detail == "levelup" then
			Audio.play("UpgradePurchase")
		elseif detail == "unlock" then
			Audio.play("TreadmillUnlock")
		elseif kind == "error" then
			-- A refused action should sound wrong, not merely informative.
			Audio.play("UiDenied")
		else
			-- Deferred so an event-specific cue (Escape, Sell, the reveal pop)
			-- arriving in the same server frame can claim the moment instead.
			pendingGenericToken += 1
			local token = pendingGenericToken
			task.delay(0.05, function()
				if token == pendingGenericToken then
					Audio.play("Notification")
				end
			end)
		end
	end)

	RunService.Heartbeat:Connect(updateMusic)
end

return AudioController
