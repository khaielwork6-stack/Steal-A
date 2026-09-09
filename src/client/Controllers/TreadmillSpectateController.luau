--!strict
--[[
	TreadmillSpectateController
	Makes OTHER players' treadmill training visible: whenever a character other
	than our own carries the server's running flag, this client plays the run
	cycle on it, at the pace the server published, and stops it the moment the
	flag goes.

	WHY THIS EXISTS
	The runner's own client plays its run cycle locally the frame it steps on
	(TreadmillController), which is right for the runner - instant, no round
	trip. It is not something anyone else can rely on: a track a client starts
	on an Animator the default Animate script also drives does not reliably
	reach other clients, and from across the plot a training player looked
	parked on the belt. So the SERVER, which already decides who is training
	because it is the thing paying them, publishes that fact as ONE attribute on
	the character (TreadmillConfig.RUN_ATTRIBUTE, value = stride rate), and
	every client renders it for every other character.

	WHAT THIS COSTS THE NETWORK
	Nothing per frame. The attribute is written when a session starts, when the
	published rate crosses a step, and when the session ends - and it arrives
	with the character for anyone who joins while the run is already going.

	ONE TRACK PER CHARACTER, NEVER TWO
	Each watched character has at most one track, created when the flag
	appears, retimed in place when the flag's value changes, and stopped,
	destroyed and forgotten when the flag clears, the character dies, the
	character is removed, or the player leaves. If a replicated copy of the
	runner's own local track does turn up on the same Animator, it is stopped
	here, so the stride is never two run cycles fighting.

	NOTHING HERE IS TRUSTED FOR ANYTHING
	This reads a flag and moves limbs. It grants no Speed, decides nothing, and
	would draw exactly the same picture if the flag were wrong - which is why
	only the server writes it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)

local TreadmillSpectateController = {}

local localPlayer = Players.LocalPlayer

--- Roblox's own run cycles, used only when a character has no readable
--- Animate script (a custom rig, or one that has not replicated yet).
local FALLBACK_RUN_ID = {
	[Enum.HumanoidRigType.R15] = "rbxassetid://913376220",
	[Enum.HumanoidRigType.R6] = "rbxassetid://180426354",
}

type Entry = {
	character: Model,
	animator: Animator,
	animation: Animation,
	track: AnimationTrack,
	rate: number,
	target: number,
	connections: { RBXScriptConnection },
}

local entries: { [Model]: Entry } = {}
--- Per-character connections that outlive a session (attribute, death,
--- removal), so a character can start and stop many times on one hookup.
local watched: { [Model]: { RBXScriptConnection } } = {}

-- ==========================================================
-- THE TRACK
-- ==========================================================

--- The run animation the character's own avatar uses, falling back through
--- walk and then the stock cycle for its rig, so a runner is always animated.
local function runAnimationIdFor(character: Model, humanoid: Humanoid): string
	local animate = character:FindFirstChild("Animate")
	if animate then
		for _, path in { { "run", "RunAnim" }, { "walk", "WalkAnim" } } do
			local group = animate:FindFirstChild(path[1])
			local anim = group and group:FindFirstChild(path[2])
			if anim and anim:IsA("Animation") and anim.AnimationId ~= "" then
				return anim.AnimationId
			end
		end
	end
	return FALLBACK_RUN_ID[humanoid.RigType] or FALLBACK_RUN_ID[Enum.HumanoidRigType.R15]
end

--- Stops any OTHER track of the same animation on this Animator - the
--- replicated copy of the runner's own local track, if one arrived - so the
--- character never plays two run cycles at once.
local function silenceDuplicates(entry: Entry)
	for _, other in entry.animator:GetPlayingAnimationTracks() do
		if other ~= entry.track and other.Animation and other.Animation.AnimationId == entry.animation.AnimationId then
			other:Stop(0)
		end
	end
end

local function stopEntry(character: Model)
	local entry = entries[character]
	if not entry then
		return
	end
	entries[character] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	entry.track:Stop(0.15)
	entry.track:Destroy()
	entry.animation:Destroy()
end

local function startEntry(character: Model, rate: number): Entry?
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.Name = "TreadmillRunSpectate"
	animation.AnimationId = runAnimationIdFor(character, humanoid)
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not track then
		animation:Destroy()
		return nil
	end

	-- Action priority so it wins over the idle the character's own Animate
	-- script is replicating while they stand still on the belt.
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0.15)
	track:AdjustSpeed(rate)

	local entry: Entry = {
		character = character,
		animator = animator,
		animation = animation,
		track = track,
		rate = rate,
		target = rate,
		connections = {},
	}
	entries[character] = entry

	silenceDuplicates(entry)
	-- A replicated duplicate can arrive after ours started.
	table.insert(entry.connections, animator.AnimationPlayed:Connect(function(other)
		if entries[character] == entry and other ~= track and other.Animation
			and other.Animation.AnimationId == animation.AnimationId then
			other:Stop(0)
		end
	end))
	return entry
end

--- Reconciles one character with its flag: start, retime, or stop.
local function refresh(character: Model)
	local value = character:GetAttribute(TreadmillConfig.RUN_ATTRIBUTE)
	local rate = if type(value) == "number" and value > 0 then value else nil
	local entry = entries[character]

	if not rate then
		stopEntry(character)
		return
	end

	if entry then
		-- Retimed in place, eased by the heartbeat below. Never a second track.
		entry.target = rate
		if not entry.track.IsPlaying then
			-- A respawn or a state change can win the Animator back; re-assert
			-- rather than assume.
			stopEntry(character)
			startEntry(character, rate)
		end
		return
	end

	startEntry(character, rate)
end

-- ==========================================================
-- WATCHING CHARACTERS
-- ==========================================================

local function unwatch(character: Model)
	stopEntry(character)
	local connections = watched[character]
	if connections then
		watched[character] = nil
		for _, connection in connections do
			connection:Disconnect()
		end
	end
end

local function watch(character: Model)
	if watched[character] then
		return
	end
	local connections: { RBXScriptConnection } = {}
	watched[character] = connections

	table.insert(connections, character:GetAttributeChangedSignal(TreadmillConfig.RUN_ATTRIBUTE):Connect(function()
		refresh(character)
	end))
	-- Death ends the picture at once; the server clears the flag on its next
	-- tick anyway, and a fresh character arrives with no flag at all.
	table.insert(connections, character.ChildAdded:Connect(function(child)
		if child:IsA("Humanoid") then
			child.Died:Connect(function()
				stopEntry(character)
			end)
			-- The Animator can arrive after the flag did.
			refresh(character)
		end
	end))
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		table.insert(connections, humanoid.Died:Connect(function()
			stopEntry(character)
		end))
	end
	table.insert(connections, character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			unwatch(character)
		end
	end))

	-- A late joiner sees a run already in progress: the flag is already set.
	refresh(character)
end

local function watchPlayer(other: Player)
	if other == localPlayer then
		return
	end
	if other.Character then
		watch(other.Character)
	end
	other.CharacterAdded:Connect(watch)
	other.CharacterRemoving:Connect(unwatch)
end

-- ==========================================================
-- START
-- ==========================================================

function TreadmillSpectateController.start()
	for _, other in Players:GetPlayers() do
		watchPlayer(other)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(other)
		if other.Character then
			unwatch(other.Character)
		end
	end)

	-- Stride pace eases toward the published rate, exactly as the runner's own
	-- client eases its track, so a rate step reads as finding another gear.
	RunService.Heartbeat:Connect(function(dt)
		for character, entry in entries do
			if not character.Parent then
				stopEntry(character)
				continue
			end
			local eased = entry.rate + (entry.target - entry.rate) * math.min(1, TreadmillConfig.RUN_ANIMATION_EASE * dt)
			if math.abs(eased - entry.rate) > 0.002 then
				entry.rate = eased
				entry.track:AdjustSpeed(eased)
			end
		end
	end)
end

--- For tests: which characters are currently being animated, and at what rate.
function TreadmillSpectateController.snapshot(): { [string]: number }
	local out = {}
	for character, entry in entries do
		out[character.Name] = entry.rate
	end
	return out
end

return TreadmillSpectateController
