--!strict
--[[
	TreadmillController
	Makes standing on a treadmill LOOK like training: centred on the belt, running
	animation, the treadmill lit and humming, and a shoe-icon "+N" popping off
	the character as Speed is earned.

	THIS CONTROLLER GRANTS NOTHING
	SpeedService is still the only thing that awards SpeedPower, on its own
	authoritative 0.25s server tick. Everything here is presentation, and it is
	deliberately built so it cannot lie about the reward:

	  * The popup amount is the player's REAL SpeedPower delta, read back from
	    StatePush. It is never predicted from config, so it cannot drift from what
	    the server actually granted, and a refused tick shows nothing.
	  * Deltas inside a short window are SUMMED into one popup, from a small
	    pool of reusable billboards. Several ticks a second never become several
	    instances a second.

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

local Device = require(ReplicatedStorage.Shared.Util.Device)
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
local lastTreadmillLevel = 1
local pendingGain = 0
local lastPopupAt = 0

--- The player's real WalkSpeed from the last push. The run cycle's playback
--- rate is derived from THIS - a log-compressed, clamped number - and never
--- from the raw Speed stat, which climbs into the millions.
local lastWalkSpeed: number? = nil
--- The rate currently applied to the track. Eased toward the target each frame
--- so a treadmill tick or an upgrade changes the stride smoothly, not in a jump.
local animationRate = TreadmillConfig.RUN_ANIMATION_SPEED

--- Where the run cycle rate should sit for the player's current WalkSpeed.
--- The formula lives in TreadmillConfig.runAnimationRate because the server
--- publishes the same number to spectators: a new player jogs, a top player
--- sprints, nobody blurs, and everyone watching sees the same stride.
local function targetRate(): number
	return TreadmillConfig.runAnimationRate(lastWalkSpeed or GameConfig.WALKSPEED_MIN)
end

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

--- The Animation object the local track was loaded from. Kept alive for the
--- life of the track rather than destroyed straight after LoadAnimation: a
--- track whose Animation is gone cannot be described to anyone else, and
--- while spectators no longer depend on this track reaching them (see
--- TreadmillSpectateController), there is no reason to make it impossible.
local runAnimation: Animation? = nil

local function stopRunning()
	if runTrack then
		runTrack:Stop(0.15)
		runTrack:Destroy()
		runTrack = nil
	end
	if runAnimation then
		runAnimation:Destroy()
		runAnimation = nil
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
	animation.Name = "TreadmillRun"
	animation.AnimationId = id

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not track then
		animation:Destroy()
		return
	end
	runAnimation = animation

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
-- REWARD POPUPS
-- ==========================================================
--
-- A shoe icon and a big "+N" in cyan-to-blue, popping in slightly small,
-- overshooting, settling, then floating up and out while it fades. Drawn
-- from a POOL of four billboards that are re-used, never re-created, and
-- spread over four lanes around the character so consecutive gains do not
-- land on top of one another or on the player's head.

--- The Speed stat's own sneaker (HUDLayoutController's stat card, the shop).
local SHOE_ICON = "rbxassetid://102080723305863"

local POPUP_POOL = 4
--- Gains inside this window are shown as ONE number.
local POPUP_WINDOW = 0.25
local POPUP_LIFE = 0.95
local POPUP_RISE = 3.2
local POPUP_DRIFT = 1.1

local CYAN = Color3.fromRGB(120, 236, 255)
local BLUE = Color3.fromRGB(60, 150, 255)
local OUTLINE = Color3.fromRGB(10, 18, 44)

type Popup = {
	anchor: BasePart,
	gui: BillboardGui,
	scale: UIScale,
	label: TextLabel,
	stroke: UIStroke,
	shoe: ImageLabel,
	busy: boolean,
	token: number,
}

local popups: { Popup } = {}
local popupToken = 0
--- Which of the four lanes the next popup takes: round-robin, so the spread
--- is even, with a small bounded jitter inside each lane.
local laneCursor = 0
local LANES = {
	{ side = -1, forward = 0.4 },
	{ side = 1, forward = 0.4 },
	{ side = -1, forward = -0.6 },
	{ side = 1, forward = -0.6 },
}

local function buildPopup(): Popup
	local anchor = Instance.new("Part")
	anchor.Name = "SpeedPopup"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false

	local gui = Instance.new("BillboardGui")
	gui.Name = "Popup"
	-- Pixel-sized: readable on a phone, never a wall on a monitor. Phones
	-- get it a touch smaller so four in flight never cover the character.
	gui.Size = if Device.isPhone() then UDim2.fromOffset(150, 52) else UDim2.fromOffset(190, 64)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 90
	gui.Enabled = false
	gui.Adornee = anchor
	gui.Parent = anchor

	local row = Instance.new("Frame")
	row.Name = "Row"
	row.BackgroundTransparency = 1
	row.Size = UDim2.fromScale(1, 1)
	row.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = row
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.Parent = row

	local shoe = Instance.new("ImageLabel")
	shoe.Name = "Shoe"
	shoe.BackgroundTransparency = 1
	shoe.Image = SHOE_ICON
	shoe.Size = UDim2.fromScale(0.78, 0.78)
	shoe.LayoutOrder = 1
	shoe.Parent = row
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = shoe

	local label = Instance.new("TextLabel")
	label.Name = "Amount"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.68, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 1
	label.LayoutOrder = 2
	label.Parent = row
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 16
	limit.MaxTextSize = 44
	limit.Parent = label
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.35, CYAN),
		ColorSequenceKeypoint.new(1, BLUE),
	})
	gradient.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3.5
	stroke.Color = OUTLINE
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	return {
		anchor = anchor,
		gui = gui,
		scale = scale,
		label = label,
		stroke = stroke,
		shoe = shoe,
		busy = false,
		token = 0,
	}
end

local function popupHolder(): Instance
	local existing = workspace:FindFirstChild("SpeedPopups")
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "SpeedPopups"
	folder.Parent = workspace
	return folder
end

local function freePopup(): Popup?
	for _, popup in popups do
		if not popup.busy then
			return popup
		end
	end
	if #popups < POPUP_POOL then
		local made = buildPopup()
		made.anchor.Parent = popupHolder()
		table.insert(popups, made)
		return made
	end
	return nil
end

local function hidePopup(popup: Popup)
	popup.busy = false
	popup.gui.Enabled = false
end

local function spawnPopup(amount: number, root: BasePart)
	local popup = freePopup()
	if not popup then
		return -- four already flying; the next window's sum will show it
	end
	popup.busy = true
	popupToken += 1
	local token = popupToken
	popup.token = token

	laneCursor = laneCursor % #LANES + 1
	local lane = LANES[laneCursor]
	local side = root.CFrame.RightVector * (lane.side * (TreadmillConfig.POPUP_SIDE_OFFSET + math.random() * 0.5))
	local forward = root.CFrame.LookVector * (lane.forward + (math.random() - 0.5) * 0.4)
	local start = root.Position + side + forward + Vector3.new(0, TreadmillConfig.POPUP_START_HEIGHT + 0.6, 0)
	popup.anchor.CFrame = CFrame.new(start)

	popup.label.Text = `+{NumberFormat.short(amount)}`
	popup.label.TextTransparency = 0
	popup.stroke.Transparency = 0
	popup.shoe.ImageTransparency = 0
	popup.shoe.Rotation = -14
	popup.scale.Scale = 0.7
	popup.gui.Enabled = true

	-- 0.70 -> 1.15 -> 1.00: pop past full size, settle.
	local pop = TweenService:Create(popup.scale, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1.15 })
	pop:Play()
	pop.Completed:Once(function()
		if popup.token == token then
			TweenService:Create(popup.scale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end)
	-- The shoe kicks back upright during the pop.
	TweenService:Create(popup.shoe, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Rotation = 6 }):Play()
	-- Float up and a little outward, on the anchor so the text keeps facing
	-- the camera, then fade in the back half of the life.
	TweenService:Create(
		popup.anchor,
		TweenInfo.new(POPUP_LIFE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = CFrame.new(start + Vector3.new(0, POPUP_RISE, 0) + side.Unit * POPUP_DRIFT) }
	):Play()
	task.delay(POPUP_LIFE * 0.45, function()
		if popup.token ~= token then
			return
		end
		local fade = TweenInfo.new(POPUP_LIFE * 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(popup.label, fade, { TextTransparency = 1 }):Play()
		TweenService:Create(popup.stroke, fade, { Transparency = 1 }):Play()
		TweenService:Create(popup.shoe, fade, { ImageTransparency = 1 }):Play()
	end)
	task.delay(POPUP_LIFE, function()
		if popup.token == token then
			hidePopup(popup)
		end
	end)
end

local function clearPopups()
	for _, popup in popups do
		popup.token += 1
		hidePopup(popup)
	end
end

-- ==========================================================
-- HUD ROW
-- ==========================================================
--
-- The Speed row of the stat card punches and flashes with each shown gain.
-- There is no second "+N Speed" text on the HUD any more: the world popup is
-- the reward, and two numbers for one gain read as spam.

local SPEED_FLASH = Color3.fromRGB(150, 240, 255)

local function flashSpeedRow()
	local playerGui = player:FindFirstChild("PlayerGui")
	local ui = playerGui and playerGui:FindFirstChild("MainUI")
	local cardHud = ui and ui:FindFirstChild("StatHUD")
	local row = cardHud and cardHud:FindFirstChild("Speed", true)
	local label = row and row:FindFirstChild("Amount")
	if label and label:IsA("TextLabel") then
		UIAnim.flashColor(label, SPEED_FLASH)
		UIAnim.punch(label, 0.1)
	end
end

-- ==========================================================
-- TREADMILL FX
-- ==========================================================
--
-- Restrained life on the machine while it is in use: a tier-tinted glow, a
-- thin light strip on the belt that pulses when a reward lands, and a few
-- speed streaks at the runner's feet. Client-only instances, built once per
-- session and destroyed when the session ends, so nothing lingers.

--- Accent per treadmill tier: what the glow and the belt strip take on. The
--- shoe popup stays cyan whatever the tier - the reward must always read as
--- Speed.
local TIER_ACCENTS: { Color3 } = {
	Color3.fromRGB(255, 176, 80), -- 1 Rusty
	Color3.fromRGB(120, 230, 255), -- 2 Velocity
	Color3.fromRGB(255, 238, 90), -- 3 Voltic
	Color3.fromRGB(255, 110, 60), -- 4 Inferno
	Color3.fromRGB(170, 230, 255), -- 5 Frostbite
	Color3.fromRGB(255, 210, 70), -- 6 Midas
	Color3.fromRGB(190, 120, 255), -- 7 Overclock
	Color3.fromRGB(150, 90, 255), -- 8 Eclipse
	Color3.fromRGB(255, 244, 200), -- 9 Ascendant
}

local fxFolder: Folder? = nil
local fxLight: PointLight? = nil
local fxStrip: BasePart? = nil
local fxStreaks: ParticleEmitter? = nil
local fxAttachment: Attachment? = nil
local fxPulse: Tween? = nil

local function accentFor(level: number): Color3
	return TIER_ACCENTS[math.clamp(level, 1, #TIER_ACCENTS)]
end

local function startFx(root: BasePart)
	local surface = deck
	if fxFolder or not surface then
		return
	end
	local accent = accentFor(lastTreadmillLevel)

	local folder = Instance.new("Folder")
	folder.Name = "TreadmillFx"
	fxFolder = folder

	-- The belt strip: a thin neon slab on the deck top, faint at rest.
	local strip = Instance.new("Part")
	strip.Name = "BeltGlow"
	strip.Size = Vector3.new(surface.Size.X * 0.55, 0.08, surface.Size.Z * 0.82)
	strip.CFrame = surface.CFrame * CFrame.new(0, surface.Size.Y / 2 + 0.05, 0)
	strip.Anchored = true
	strip.CanCollide = false
	strip.CanQuery = false
	strip.CanTouch = false
	strip.CastShadow = false
	strip.Material = Enum.Material.Neon
	strip.Color = accent
	strip.Transparency = 0.72
	strip.Parent = folder
	fxStrip = strip

	local light = Instance.new("PointLight")
	light.Name = "TierGlow"
	light.Color = accent
	light.Brightness = 0.9
	light.Range = 14
	light.Shadows = false
	light.Parent = strip
	fxLight = light

	-- Speed streaks at the feet: short cyan lines shooting backward.
	local attachment = Instance.new("Attachment")
	attachment.Name = "StreakAttachment"
	attachment.Position = Vector3.new(0, -2.4, 0.6)
	attachment.Parent = root
	fxAttachment = attachment
	local streaks = Instance.new("ParticleEmitter")
	streaks.Name = "Streaks"
	streaks.Texture = "rbxassetid://241594419"
	streaks.Color = ColorSequence.new(CYAN, Color3.fromRGB(255, 255, 255))
	streaks.LightEmission = 0.9
	streaks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	streaks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
	streaks.Lifetime = NumberRange.new(0.25, 0.45)
	streaks.Rate = 14
	streaks.Speed = NumberRange.new(9, 14)
	streaks.EmissionDirection = Enum.NormalId.Back
	streaks.SpreadAngle = Vector2.new(14, 6)
	streaks.Parent = attachment
	fxStreaks = streaks

	folder.Parent = workspace

	-- Start transition: the strip and light ease up from dark.
	strip.Transparency = 1
	light.Brightness = 0
	TweenService:Create(strip, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 0.72 }):Play()
	TweenService:Create(light, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0.9 }):Play()
end

local function pulseFx()
	local strip, light = fxStrip, fxLight
	if not strip or not light then
		return
	end
	if fxPulse then
		fxPulse:Cancel()
	end
	strip.Transparency = 0.25
	light.Brightness = 2.2
	local tween = TweenService:Create(strip, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 0.72 })
	fxPulse = tween
	tween:Play()
	TweenService:Create(light, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0.9 }):Play()
end

local function stopFx()
	local folder = fxFolder
	fxFolder = nil
	if fxPulse then
		fxPulse:Cancel()
		fxPulse = nil
	end
	if fxStreaks then
		fxStreaks.Enabled = false
	end
	local strip, light, attachment = fxStrip, fxLight, fxAttachment
	fxStrip, fxLight, fxStreaks, fxAttachment = nil, nil, nil, nil
	-- Stop transition: ease down, then destroy. Streaks already in flight
	-- finish on their own before the attachment goes.
	if strip and light then
		TweenService:Create(strip, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
		TweenService:Create(light, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Brightness = 0 }):Play()
	end
	task.delay(0.5, function()
		if folder then
			folder:Destroy()
		end
		if attachment then
			attachment:Destroy()
		end
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
	stopFx()
	-- Anything banked but not yet shown is dropped, and anything still flying
	-- is cut: a popup appearing after the player has walked away is noise, and
	-- the Speed is already in their total.
	pendingGain = 0
	clearPopups()
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
		startFx(root)
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
	-- are summed into one popup instead of stacking numbers on top of each
	-- other. The number shown is the real server-approved sum for the window.
	local now = os.clock()
	if pendingGain > 0 and now - lastPopupAt >= POPUP_WINDOW then
		lastPopupAt = now
		spawnPopup(pendingGain, root)
		flashSpeedRow()
		pulseFx()
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
		if type(state.walkSpeed) == "number" then
			lastWalkSpeed = state.walkSpeed
		end
		if type(state.treadmillLevel) == "number" then
			local level = state.treadmillLevel
			if level ~= lastTreadmillLevel then
				lastTreadmillLevel = level
				-- An upgrade mid-session retints the glow to the new tier.
				local accent = accentFor(level)
				if fxStrip then
					fxStrip.Color = accent
				end
				if fxLight then
					fxLight.Color = accent
				end
			end
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
		stopFx()
		pendingGain = 0
		clearPopups()
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
