--!strict
--[[
	TreadmillController
	Makes standing on a treadmill LOOK like training: centred on the belt, running
	animation, and floating "+N Speed" as it is earned.

	THIS CONTROLLER GRANTS NOTHING
	SpeedService is still the only thing that awards SpeedPower, on its own
	authoritative 0.25s server tick. Everything here is presentation, and it is
	deliberately built so it cannot lie about the reward:

	  * The popup amount is the player's REAL SpeedPower delta, read back from
	    StatePush. It is never predicted from config, so it cannot drift from what
	    the server actually granted, and a refused tick shows nothing.

	DETECTION IS LOCAL, NOT NETWORKED
	The client runs the same trigger test the server does, against the same
	TrainingTrigger part. That costs nothing, reacts on the very first frame, and
	needs no "you are training" remote. The server keeps its own independent check
	for the reward, so a tampered client can change what it SEES and never what it
	earns.

	THE CENTRE HOLD IS SOFT
	The player is eased to the middle of the belt and turned to face along it, but
	ONLY while they are giving no movement input. The moment they push a stick or
	a key the hold releases entirely, so walking off is instant and the controls
	are never fought. A hard lock would trap players who wanted to leave.

	THE ANIMATION IS THE PLAYER'S OWN
	Rather than shipping an animation id - which would be one more asset that can
	come back "not approved for the requester", as the lobby music did - this
	borrows the run animation out of the character's own Animate script. That
	respects whatever animation package the player is wearing and is always
	permitted.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)

local TreadmillController = {}

local player = Players.LocalPlayer

local trigger: BasePart? = nil
local deck: BasePart? = nil
local training = false

local runTrack: AnimationTrack? = nil
local lastSpeedPower: number? = nil
local pendingGain = 0
local lastPopupAt = 0
local livePopups = 0
--- Flipped each popup so they alternate sides instead of overlapping.
local popupSide = 1

-- ==========================================================
-- PLOT LOOKUP
-- ==========================================================

--- Re-resolved rather than cached forever: plots are session-owned and a player
--- can be assigned a different one after a rejoin.
local function refreshPlot()
	trigger, deck = nil, nil
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return
	end
	for _, plot in bases:GetChildren() do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			local treadmill = plot:FindFirstChild("Treadmill")
			local found = treadmill and treadmill:FindFirstChild("TrainingTrigger")
			local frame = treadmill and treadmill:FindFirstChild("Frame")
			trigger = if found and found:IsA("BasePart") then found else nil
			deck = if frame and frame:IsA("BasePart") then frame else nil
			return
		end
	end
end

--- The same oriented-box test SpeedService uses, so what the player sees and
--- what they earn can never disagree about where the treadmill is.
local function isOnTreadmill(root: BasePart): boolean
	local volume = trigger
	if not volume then
		return false
	end
	local offset = volume.CFrame:PointToObjectSpace(root.Position)
	local half = volume.Size / 2
	return math.abs(offset.X) <= half.X
		and math.abs(offset.Y) <= half.Y
		and math.abs(offset.Z) <= half.Z
end

-- ==========================================================
-- ANIMATION
-- ==========================================================

--- The run animation the player's own avatar uses. Falls back through walk, and
--- gives up quietly rather than substituting something that would look wrong.
local function findRunAnimationId(character: Model): string?
	local animate = character:FindFirstChild("Animate")
	if not animate then
		return nil
	end
	for _, path in { { "run", "RunAnim" }, { "walk", "WalkAnim" } } do
		local group = animate:FindFirstChild(path[1])
		local anim = group and group:FindFirstChild(path[2])
		if anim and anim:IsA("Animation") and anim.AnimationId ~= "" then
			return anim.AnimationId
		end
	end
	return nil
end

local function stopRunning()
	if runTrack then
		runTrack:Stop(0.15)
		runTrack:Destroy()
		runTrack = nil
	end
end

local function startRunning(character: Model, humanoid: Humanoid)
	if runTrack then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	local id = findRunAnimationId(character)
	if not animator or not id then
		return
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = id

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not ok or not track then
		return
	end

	-- Action priority so it wins over the idle animation the default Animate
	-- script plays while the character is standing still.
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0.15)
	track:AdjustSpeed(TreadmillConfig.RUN_ANIMATION_SPEED)
	runTrack = track
end

-- ==========================================================
-- FLOATING TEXT
-- ==========================================================

local function spawnPopup(amount: number, root: BasePart)
	if livePopups >= TreadmillConfig.POPUP_MAX_CONCURRENT then
		return
	end
	livePopups += 1

	local anchor = Instance.new("Part")
	anchor.Name = "SpeedPopup"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false

	-- Thrown out to the SIDE, alternating left and right, rather than straight
	-- up from the player. Directly overhead is exactly where the treadmill's own
	-- name/price label lives, and the two stacked into an unreadable jumble.
	-- Alternating also stops consecutive popups from overlapping each other.
	popupSide = -popupSide
	local right = root.CFrame.RightVector * (popupSide * (TreadmillConfig.POPUP_SIDE_OFFSET + math.random() * 0.6))
	local forward = root.CFrame.LookVector * (math.random(-8, 8) / 10)
	anchor.CFrame = CFrame.new(root.Position + right + forward + Vector3.new(0, TreadmillConfig.POPUP_START_HEIGHT, 0))
	anchor.Parent = workspace

	local gui = Instance.new("BillboardGui")
	gui.Name = "Popup"
	gui.Size = UDim2.fromScale(7, 2.4)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 90
	gui.Adornee = anchor
	gui.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(126, 236, 255)
	label.TextStrokeTransparency = 0.3
	label.Text = `+{NumberFormat.short(amount)} Speed`
	label.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Scale = 0.6
	scale.Parent = label

	local life = TreadmillConfig.POPUP_LIFETIME

	-- Pop in fast, drift up, fade out. The rise is on the anchor so the text
	-- keeps facing the camera the whole way.
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.1 }):Play()
	TweenService:Create(
		anchor,
		TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = anchor.CFrame + Vector3.new(0, TreadmillConfig.POPUP_RISE, 0) }
	):Play()
	TweenService:Create(
		label,
		TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ TextTransparency = 1, TextStrokeTransparency = 1 }
	):Play()

	task.delay(life, function()
		livePopups -= 1
		anchor:Destroy()
	end)
end

-- ==========================================================
-- STATE
-- ==========================================================

local function leaveTreadmill()
	if not training then
		return
	end
	training = false
	stopRunning()
	-- Anything banked but not yet shown is dropped: a popup appearing after the
	-- player has walked away is noise, and the Speed is already in their total.
	pendingGain = 0
end

--- The direction a runner on this deck should be facing, in world space.
---
--- The deck's own LookVector points out toward the corridor; the console sits at
--- the other end. See TreadmillConfig.PLAYER_FACING_SIGN for the whole story and
--- for the one number to change if a future model is authored the other way.
local function runDirection(surface: BasePart): Vector3
	return surface.CFrame.LookVector * TreadmillConfig.PLAYER_FACING_SIGN
end

--- Eases the player onto the belt, facing the console.
---
--- Only while they are standing still. `MoveDirection` is zero exactly when the
--- player is giving no input, so the instant they try to walk this stops
--- touching them and they leave normally.
local function holdCentre(root: BasePart, humanoid: Humanoid, dt: number)
	local surface = deck
	if not surface or humanoid.MoveDirection.Magnitude > 0.05 then
		return
	end
	if humanoid:GetState() == Enum.HumanoidStateType.Freefall or humanoid.Jump then
		return
	end

	local facing = runDirection(surface)

	-- Settle BEHIND the deck centre rather than on it: a runner stands back from
	-- the console, and dead centre put the character's chest through the display
	-- on the taller tiers.
	local target = surface.Position - facing * TreadmillConfig.STANCE_OFFSET
	-- Keep the player's own height, so this can never shove them into the deck or
	-- lift them off it.
	target = Vector3.new(target.X, root.Position.Y, target.Z)

	local toTarget = target - root.Position
	local distance = toTarget.Magnitude

	local current = root.CFrame.LookVector
	local turned = current:Angle(facing)

	if distance < TreadmillConfig.CENTRE_DEADZONE and turned < 0.02 then
		return
	end

	-- Split the correction into "across the belt" and "along the belt" and pull
	-- the lateral one harder. Standing off the SIDE of the belt is the part that
	-- reads as broken; being slightly forward or back of the mark does not, and
	-- correcting both at the same rate feels like being sucked to a point.
	local right = surface.CFrame.RightVector
	local lateral = right * toTarget:Dot(right)
	local along = toTarget - lateral

	local rate = TreadmillConfig.CENTRE_SNAP_SPEED * dt
	local lateralStep = math.min(1, (rate * TreadmillConfig.CENTRE_LATERAL_MULTIPLIER) / math.max(lateral.Magnitude, 0.001))
	local alongStep = math.min(1, rate / math.max(along.Magnitude, 0.001))

	local position = root.Position + lateral * lateralStep + along * alongStep
	local rotation = CFrame.lookAt(Vector3.zero, current):Lerp(
		CFrame.lookAt(Vector3.zero, facing),
		math.min(1, TreadmillConfig.CENTRE_TURN_SPEED * dt)
	)
	root.CFrame = CFrame.new(position) * rotation.Rotation
end

local function step(dt: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		leaveTreadmill()
		return
	end

	if not trigger then
		refreshPlot()
	end

	local on = isOnTreadmill(root)
	if on and not training then
		training = true
		startRunning(character, humanoid)
	elseif not on and training then
		leaveTreadmill()
	end

	if not training then
		return
	end

	-- The default Animate script can win the track back after a respawn or a
	-- state change, so re-assert rather than assuming it stayed playing.
	if not runTrack or not runTrack.IsPlaying then
		stopRunning()
		startRunning(character, humanoid)
	end

	holdCentre(root, humanoid, dt)

	-- Release banked gains on a fixed cadence. Ticks arriving faster than this
	-- are summed into one popup instead of stacking three numbers on top of each
	-- other, which is what turns this into spam.
	local now = os.clock()
	if pendingGain > 0 and now - lastPopupAt >= TreadmillConfig.POPUP_MIN_INTERVAL then
		lastPopupAt = now
		spawnPopup(pendingGain, root)
		pendingGain = 0
	end
end

-- ==========================================================
-- START
-- ==========================================================

function TreadmillController.start()
	refreshPlot()

	-- The popup amount is the REAL granted delta, not a prediction from config.
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if not state or type(state.speedPower) ~= "number" then
			return
		end
		local previous = lastSpeedPower
		lastSpeedPower = state.speedPower
		if not previous then
			return -- first push is a baseline, not a gain
		end

		local delta = state.speedPower - previous
		-- Only while actually training: Index claims and other grants also move
		-- SpeedPower, and those are not treadmill feedback.
		if delta > 0 and training then
			pendingGain += delta
		end
	end)

	player.CharacterAdded:Connect(function()
		-- The old track belonged to a Humanoid that no longer exists.
		runTrack = nil
		training = false
		pendingGain = 0
		refreshPlot()
	end)

	-- A plot is assigned after join, and reassigned on rejoin.
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if bases then
		for _, plot in bases:GetChildren() do
			plot:GetAttributeChangedSignal("OwnerUserId"):Connect(refreshPlot)
		end
	end

	RunService.RenderStepped:Connect(step)
end

return TreadmillController
