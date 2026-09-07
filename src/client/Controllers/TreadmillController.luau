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

	YOU ARE ON THE BELT UNTIL YOU JUMP
	Stepping on starts a session: the player is eased to the middle of the belt,
	turned to face along it, and their movement input is overridden to zero one
	frame-step after the ControlModule writes it - so WASD and the thumbstick do
	nothing, and the character is still an ordinary Humanoid (no anchoring, no
	WalkSpeed edits, nothing the server has to know). JUMP is the exit - Space,
	the mobile Jump button, a gamepad A - and it hands movement straight back.
	After a jump the belt will not re-engage until the player has actually left
	it, so a hop cannot land them straight back into the lock. Death, respawn, a
	teleport, a destroyed treadmill or leaving the trigger all end the session
	through the same one path.

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
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local TreadmillController = {}

local player = Players.LocalPlayer

local trigger: BasePart? = nil
local deck: BasePart? = nil
local training = false

local runTrack: AnimationTrack? = nil
local lastSpeedPower: number? = nil
local pendingGain = 0

--- The player's real WalkSpeed from the last push. The run cycle's playback
--- rate is derived from THIS - a log-compressed, clamped number - and never
--- from the raw Speed stat, which climbs into the millions.
local lastWalkSpeed: number? = nil
--- The rate currently applied to the track. Eased toward the target each frame
--- so a treadmill tick or an upgrade changes the stride smoothly, not in a jump.
local animationRate = TreadmillConfig.RUN_ANIMATION_SPEED

--- Where the run cycle rate should sit for the player's current WalkSpeed:
--- RUN_ANIMATION_SPEED at the slowest a player can be, RUN_ANIMATION_SPEED_MAX
--- at the movement cap, straight between. A new player jogs; a top player
--- sprints; nobody blurs.
local function targetRate(): number
	local walk = lastWalkSpeed or GameConfig.WALKSPEED_MIN
	local span = math.max(GameConfig.WALKSPEED_MAX - GameConfig.WALKSPEED_MIN, 1)
	local alpha = math.clamp((walk - GameConfig.WALKSPEED_MIN) / span, 0, 1)
	return TreadmillConfig.RUN_ANIMATION_SPEED
		+ (TreadmillConfig.RUN_ANIMATION_SPEED_MAX - TreadmillConfig.RUN_ANIMATION_SPEED) * alpha
end
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
	-- Start AT the target rather than easing up from the slowest rate, so a fast
	-- player never takes a first stride at jogging pace.
	animationRate = targetRate()
	track:AdjustSpeed(animationRate)
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
-- HUD FEEDBACK
-- ==========================================================
--
-- The cash counter pulses and flashes when money lands; Speed earned on the
-- treadmill gets the same treatment on its own row of the stat card, plus a
-- small "+N Speed" that lifts off the row and fades. Screen-space, so it reads
-- on a phone where the world popup beside the character is tiny. Same
-- cadence as the world popup (POPUP_MIN_INTERVAL) so it can never spam, and
-- the amount is the same real server delta.

local SPEED_FLASH = Color3.fromRGB(150, 240, 255)
local SPEED_RISE_PIXELS = 46
local SPEED_HUD_LIFETIME = 0.95
local SPEED_HUD_MAX = 4
--- The HUD popup runs slower than the world one: gains inside this window are
--- summed into one "+N", so the corner reads as a rhythm, not a stream.
local SPEED_HUD_INTERVAL = 0.6

local liveHudPopups = 0
local hudSide = 1
local hudPending = 0
local lastHudAt = 0

--- The Speed row of the stat card (HUDLayoutController builds it) and the
--- amount label inside it.
local function speedRow(): (GuiObject?, TextLabel?)
	local playerGui = player:FindFirstChild("PlayerGui")
	local ui = playerGui and playerGui:FindFirstChild("MainUI")
	local card = ui and ui:FindFirstChild("StatHUD")
	local row = card and card:FindFirstChild("Speed", true)
	if not row or not row:IsA("GuiObject") then
		return nil, nil
	end
	local label = row:FindFirstChild("Amount")
	return row, if label and label:IsA("TextLabel") then label else nil
end

local function spawnHudPopup(amount: number)
	local row, label = speedRow()
	local ui = row and row:FindFirstAncestorOfClass("ScreenGui")
	if not row or not ui then
		return
	end

	-- The row itself: a punch and a cyan flash, the cash counter's treatment.
	if label then
		UIAnim.flashColor(label, SPEED_FLASH)
		UIAnim.punch(label, 0.1)
	end

	if liveHudPopups >= SPEED_HUD_MAX then
		return
	end
	liveHudPopups += 1

	-- Lifts off the row's right end, alternating a little left and right so
	-- two in a row never sit on top of each other. Positioned in pixels from
	-- the row's absolute frame, so it follows the card wherever the layout
	-- pass put it.
	hudSide = -hudSide
	local anchor = row.AbsolutePosition + Vector2.new(row.AbsoluteSize.X + 10 + hudSide * 8, row.AbsoluteSize.Y * 0.5)
	local inset = ui.IgnoreGuiInset and Vector2.zero or Vector2.new(0, 0)
	local popup = Instance.new("TextLabel")
	popup.Name = "SpeedGain"
	popup.BackgroundTransparency = 1
	popup.AnchorPoint = Vector2.new(0, 0.5)
	popup.Position = UDim2.fromOffset(anchor.X - inset.X, anchor.Y - inset.Y)
	popup.Size = UDim2.fromOffset(150, 30)
	popup.Font = Enum.Font.FredokaOne
	popup.TextSize = 24
	popup.TextXAlignment = Enum.TextXAlignment.Left
	popup.TextColor3 = SPEED_FLASH
	popup.TextStrokeTransparency = 0.25
	popup.TextStrokeColor3 = Color3.fromRGB(10, 30, 50)
	popup.Text = `+{NumberFormat.short(amount)} Speed`
	popup.ZIndex = 20
	popup.Parent = ui

	local scale = Instance.new("UIScale")
	scale.Scale = 0.6
	scale.Parent = popup

	TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.12 }):Play()
	TweenService:Create(
		popup,
		TweenInfo.new(SPEED_HUD_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = popup.Position - UDim2.fromOffset(0, SPEED_RISE_PIXELS) }
	):Play()
	TweenService:Create(
		popup,
		TweenInfo.new(SPEED_HUD_LIFETIME * 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ TextTransparency = 1, TextStrokeTransparency = 1 }
	):Play()

	task.delay(SPEED_HUD_LIFETIME, function()
		liveHudPopups -= 1
		popup:Destroy()
	end)
end

-- ==========================================================
-- STATE
-- ==========================================================

--- Listeners for "the player started / stopped training". Exposed so the
--- treadmill offer UI can follow the SAME detection the reward uses, rather than
--- running a second test that could disagree with it.
local trainingListeners: { (boolean) -> () } = {}

function TreadmillController.onTrainingChanged(callback: (boolean) -> ())
	table.insert(trainingListeners, callback)
end

local function announceTraining(value: boolean)
	for _, callback in trainingListeners do
		task.spawn(callback, value)
	end
end

--- After a jump exit the player is still standing inside the trigger. Without
--- this the very next frame would lock them straight back on. Set by the jump,
--- cleared the moment they are OUTSIDE the volume, so re-engaging means
--- actually stepping off and back on.
local lockedOut = false

--- The lock. While training, the ControlModule keeps writing the player.s move
--- vector every frame; this runs one priority later and overwrites it with zero,
--- so WASD and the thumbstick move nothing while jump - which the ControlModule
--- routes through Humanoid.Jump, not through Move - still works. No anchoring,
--- no WalkSpeed games, no state the server has to know about: the character is
--- a normal Humanoid standing still.
local LOCK_STEP = "TreadmillLock"
local lockBound = false

local function lockMovement()
	if lockBound then
		return
	end
	lockBound = true
	RunService:BindToRenderStep(LOCK_STEP, Enum.RenderPriority.Input.Value + 5, function()
		local character = player.Character
		local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
		if humanoid then
			humanoid:Move(Vector3.zero, true)
		end
	end)
end

local function unlockMovement()
	if not lockBound then
		return
	end
	lockBound = false
	RunService:UnbindFromRenderStep(LOCK_STEP)
end

local function leaveTreadmill()
	if not training then
		return
	end
	training = false
	announceTraining(false)
	stopRunning()
	unlockMovement()
	-- Anything banked but not yet shown is dropped: a popup appearing after the
	-- player has walked away is noise, and the Speed is already in their total.
	pendingGain = 0
	hudPending = 0
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
	if not on then
		-- Off the belt: any jump-exit hold is over, and the session ends.
		lockedOut = false
		if training then
			leaveTreadmill()
		end
		return
	end

	-- THE EXIT. Jump - Space, the mobile Jump button, or the gamepad - is the
	-- one input the lock lets through, and it ends the session: movement is
	-- handed back and the player is held off until they have physically left
	-- the belt, so a jump cannot land them straight back into the lock.
	if training and (humanoid.Jump or humanoid:GetState() == Enum.HumanoidStateType.Jumping) then
		lockedOut = true
		leaveTreadmill()
		return
	end

	if not training and not lockedOut then
		training = true
		announceTraining(true)
		startRunning(character, humanoid)
		lockMovement()
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

	-- Stride pace follows real movement speed. Eased, so the constant trickle
	-- of treadmill ticks reads as a runner gradually finding another gear, and
	-- an upgrade lands within a stride rather than snapping mid-cycle.
	local track = runTrack
	if track then
		local goal = targetRate()
		local eased = animationRate + (goal - animationRate) * math.min(1, TreadmillConfig.RUN_ANIMATION_EASE * dt)
		if math.abs(eased - animationRate) > 0.002 then
			animationRate = eased
			track:AdjustSpeed(animationRate)
		end
	end

	-- Release banked gains on a fixed cadence. Ticks arriving faster than this
	-- are summed into one popup instead of stacking three numbers on top of each
	-- other, which is what turns this into spam.
	local now = os.clock()
	if pendingGain > 0 and now - lastPopupAt >= TreadmillConfig.POPUP_MIN_INTERVAL then
		lastPopupAt = now
		spawnPopup(pendingGain, root)
		hudPending += pendingGain
		pendingGain = 0
	end
	if hudPending > 0 and now - lastHudAt >= SPEED_HUD_INTERVAL then
		lastHudAt = now
		spawnHudPopup(hudPending)
		hudPending = 0
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
		if type(state.walkSpeed) == "number" then
			lastWalkSpeed = state.walkSpeed
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
		-- A lock bound to the old character must not outlive it.
		lockedOut = false
		unlockMovement()
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
