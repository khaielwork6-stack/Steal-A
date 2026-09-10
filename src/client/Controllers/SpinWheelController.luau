--!strict
--[[
	SpinWheelController
	Everything a player SEES of the free spin: their own wheel, its countdown,
	the spin itself and the win.

	IT DECIDES NOTHING. The server rolls the wheel, grants the prize and then
	fires SpinResult with one number. By the time a single frame of the
	animation has drawn, the reward is already the player's - so this file is
	free to be as theatrical as it likes without any of it mattering to the
	outcome. If the sequence never finishes, nothing is lost.

	ONE WHEEL EXISTS FOR YOU, AND IT IS YOURS.
	Every plot in the world carries a wheel, and they all replicate to everyone.
	This controller hides all of them and then un-hides the ONE standing on the
	plot this player holds - parts, lights, art, prompt, the lot. Hiding is
	local: nothing here writes anything another client can see, so a neighbour
	spinning theirs is invisible and silent, and so is its countdown.

	The billboard and the win banner are not hidden at all - they are simply
	never BUILT except on the owner's own client, which is the only guarantee
	that cannot be got wrong.

	THE SPIN RUNS LOCALLY. The disc is anchored and the server never touches
	its CFrame, so this rotates it directly. That is what makes the landing
	frame-perfect on the owner's screen instead of a stutter of replicated
	positions - and it means the animation cannot desync from the result,
	because the result arrived first.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local EffectsController = require(script.Parent.EffectsController)

local SpinWheelController = {}

local player = Players.LocalPlayer

local ATTR_OWNER = "OwnerUserId"
local ATTR_READY_AT = "SpinReadyAt"

--- Every wheel this client knows about. `hidden` is what we last applied, so
--- the show/hide pass is idempotent and costs nothing when nothing changed.
type Wheel = {
	model: Model,
	disc: BasePart,
	prompt: ProximityPrompt?,
	hidden: boolean,
	--- The pose the disc rests in between spins: its landing angle, or the
	--- pose it was placed at before the first spin.
	rest: CFrame,
	--- Radians turned from `rest`. Kept so the next spin starts where the last
	--- one stopped rather than snapping back to zero first.
	angle: number,
}

local wheels: { [Model]: Wheel } = {}

--- How each part was BUILT, captured once before anything is hidden. Un-hiding
--- restores these rather than guessing at zero: the models were placed by hand
--- and a part of them may legitimately be half-transparent or non-collidable.
type Resting = { transparency: number, canCollide: boolean, canQuery: boolean, castShadow: boolean }
local resting: { [BasePart]: Resting } = {}

--- The wheel on this player's own plot, if they have one.
local owned: Wheel? = nil

--- One spin at a time. A late tween from an abandoned spin checks its token
--- and stops rather than touching a disc that has moved on.
local spinToken = 0
local spinning = false

local reducedEffects = false

function SpinWheelController.setReducedEffects(value: boolean)
	reducedEffects = value
end

-- ==========================================================
-- SHOW / HIDE
-- ==========================================================

local function setHidden(wheel: Wheel, hidden: boolean)
	if wheel.hidden == hidden then
		return
	end
	wheel.hidden = hidden

	for _, thing in wheel.model:GetDescendants() do
		if thing:IsA("BasePart") then
			local was = resting[thing]
			if not was then
				was = {
					transparency = thing.Transparency,
					canCollide = thing.CanCollide,
					canQuery = thing.CanQuery,
					castShadow = thing.CastShadow,
				}
				resting[thing] = was
			end
			if hidden then
				thing.Transparency = 1
				thing.CastShadow = false
				-- An invisible wheel must not be something to walk into, or to
				-- blank another player's interaction card by standing in the way
				-- of a raycast they cannot see the cause of.
				thing.CanCollide = false
				thing.CanQuery = false
			else
				thing.Transparency = was.transparency
				thing.CastShadow = was.castShadow
				thing.CanCollide = was.canCollide
				thing.CanQuery = was.canQuery
			end
		elseif thing:IsA("Light") then
			thing.Enabled = not hidden
		elseif thing:IsA("SurfaceGui") or thing:IsA("BillboardGui") then
			thing.Enabled = not hidden
		elseif thing:IsA("ParticleEmitter") then
			thing.Enabled = not hidden
		elseif thing:IsA("ProximityPrompt") then
			-- OFF for everyone but the owner. The owner's own gate - ready, and
			-- not mid-spin - is applied by the heartbeat below; this is only the
			-- floor, and it is the one that matters for somebody else's plot.
			thing.Enabled = false
		end
	end
end

-- ==========================================================
-- THE BILLBOARD
-- ==========================================================
--
-- Built ONCE, on the owner's client, and re-adorned when the owned wheel
-- changes. Nothing about it is replicated, so no other player has anything to
-- see even in principle.

local billboard: BillboardGui? = nil
local timerLabel: TextLabel? = nil
local timerStroke: UIStroke? = nil
local timerGradient: UIGradient? = nil
local billboardScale: UIScale? = nil

local IDLE_COLOR = Color3.fromRGB(255, 255, 255)
local IDLE_TINT = Color3.fromRGB(190, 214, 255)

local function buildBillboard(): BillboardGui
	if billboard then
		return billboard
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("BillboardGui")
	gui.Name = "SpinWheelSign"
	gui.Size = UDim2.fromScale(13, 3.4)
	gui.MaxDistance = 110
	-- Never through a wall, and never from across the plaza: this is a sign on
	-- the player's own plot, not a world marker.
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Parent = playerGui

	-- A PLAIN FRAME BETWEEN THE BILLBOARD AND ITS TEXT, and it earns its
	-- keep: a UIScale parented straight to a BillboardGui is not a supported
	-- arrangement and does not merely fail to scale - it drags the whole
	-- billboard off its adornee, so the sign renders beside the wheel instead
	-- of above it. On an ordinary Frame the same UIScale behaves.
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 1
	body.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = body
	billboardScale = scale

	-- No plate. The rest of the game's world text (the shop sign, the zone
	-- signs) is bare glyphs with a heavy contextual outline, and a panel here
	-- would read as UI stuck to the scenery.
	local text = Instance.new("TextLabel")
	text.Name = "Timer"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = IDLE_COLOR
	text.TextStrokeTransparency = 1
	text.Text = ""
	text.Parent = body

	local outline = Instance.new("UIStroke")
	outline.Thickness = 4
	outline.Color = Color3.fromRGB(12, 10, 26)
	outline.Transparency = 0
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	outline.Parent = text
	timerStroke = outline

	-- Sits inert (a flat white ramp) during the countdown and only carries
	-- colour once the spin is READY. One gradient, two jobs, nothing swapped.
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(IDLE_COLOR)
	gradient.Rotation = 0
	gradient.Parent = text
	timerGradient = gradient

	-- A ceiling on the glyph size so the sign is the same weight on a phone
	-- and a monitor; TextScaled alone would balloon it up close.
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 14
	limit.MaxTextSize = if Device.isPhone() then 40 else 54
	limit.Parent = text

	billboard = gui
	timerLabel = text
	return gui
end

--- The rainbow. Five stops walking the hue wheel, offset a little further
--- every frame - so the colour DRIFTS across the word rather than flashing.
--- Deliberately not full saturation: at S=1 the reds and blues lose contrast
--- against the outline and "READY!" stops being legible, which is exactly the
--- tacky version this is avoiding.
local RAINBOW_STOPS = 5
local RAINBOW_SATURATION = 0.55
local RAINBOW_VALUE = 1
local RAINBOW_SPEED = 0.16

local function rainbowAt(phase: number): ColorSequence
	local keys = table.create(RAINBOW_STOPS)
	for i = 1, RAINBOW_STOPS do
		local t = (i - 1) / (RAINBOW_STOPS - 1)
		local hue = (phase + t * 0.85) % 1
		table.insert(keys, ColorSequenceKeypoint.new(t, Color3.fromHSV(hue, RAINBOW_SATURATION, RAINBOW_VALUE)))
	end
	return ColorSequence.new(keys)
end

-- ==========================================================
-- THE COUNTDOWN
-- ==========================================================

local READY_TEXT = "READY!"

--- So the ready pulse fires once per readiness, not once per frame.
local announcedReady = false

--- os.clock() until which a too-early hold is still being answered on the
--- prompt card. See onEarlyAttempt.
local tooEarlyUntil = 0
--- How long that answer stays up. Long enough to read, short enough that it is
--- gone before the player tries again.
local TOO_EARLY_SECONDS = 3

local function remainingSeconds(): number
	local wheel = owned
	if not wheel then
		return math.huge
	end
	local readyAt = wheel.model:GetAttribute(ATTR_READY_AT)
	if type(readyAt) ~= "number" or readyAt <= 0 then
		return math.huge
	end
	return readyAt - workspace:GetServerTimeNow()
end

local function mmss(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", total // 60, total % 60)
end

local function clockText(seconds: number): string
	return "FREE SPIN IN " .. mmss(seconds)
end

--- A quiet nudge the moment the spin becomes available: one cue and one
--- swell on the sign. Never a banner and never a sound that repeats - the
--- player is in the middle of something else and this must not interrupt it.
local function announceReady()
	if announcedReady then
		return
	end
	announcedReady = true
	Audio.play("SpinReady")
	if billboardScale and not reducedEffects then
		billboardScale.Scale = 1.35
		TweenService:Create(billboardScale, UIAnim.SPRING, { Scale = 1 }):Play()
	end
end

-- ==========================================================
-- THE WIN BANNER
-- ==========================================================

local banner: ScreenGui? = nil
local bannerCard: Frame? = nil
local bannerTitle: TextLabel? = nil
local bannerPrize: TextLabel? = nil
local bannerStroke: UIStroke? = nil

local function buildBanner(): ScreenGui
	if banner then
		return banner
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "SpinWinUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 12
	gui.Enabled = false
	gui.Parent = playerGui

	-- The pack's card anatomy: dark plate, inner face, gradient, studs. The
	-- same three layers the stat card and every rail button are built from.
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.31)
	card.Size = UDim2.fromScale(0.3, 0.15)
	card.BackgroundColor3 = Color3.fromRGB(16, 22, 44)
	card.BorderSizePixel = 0
	card.Parent = gui
	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = Vector2.new(240, 96)
	limit.MaxSize = Vector2.new(460, 168)
	limit.Parent = card
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = card
	local plate = Instance.new("UIStroke")
	plate.Thickness = 3
	plate.Color = SpinWheelConfig.TierColors.normal
	plate.Parent = card
	bannerStroke = plate
	local scale = Instance.new("UIScale")
	scale.Parent = card

	local face = Instance.new("Frame")
	face.Name = "Frame"
	face.Size = UDim2.new(1, -8, 1, -8)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	face.BorderSizePixel = 0
	face.Parent = card
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, 11)
	faceCorner.Parent = face
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(44, 58, 104), Color3.fromRGB(24, 32, 64))
	gradient.Parent = face
	local studs = Instance.new("ImageLabel")
	studs.Name = "Studs"
	studs.BackgroundTransparency = 1
	studs.Image = "rbxassetid://76728843491214"
	studs.ImageTransparency = 0.84
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(30, 30)
	studs.Size = UDim2.fromScale(1, 1)
	studs.Parent = face
	local studsCorner = Instance.new("UICorner")
	studsCorner.CornerRadius = UDim.new(0, 11)
	studsCorner.Parent = studs

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(0.9, 0.3)
	title.Position = UDim2.fromScale(0.5, 0.24)
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(214, 226, 248)
	title.TextStrokeTransparency = 1
	title.Text = "YOU WON"
	title.Parent = face
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = 22
	titleCap.Parent = title

	local prize = Instance.new("TextLabel")
	prize.Name = "Prize"
	prize.Size = UDim2.fromScale(0.92, 0.46)
	prize.Position = UDim2.fromScale(0.5, 0.63)
	prize.AnchorPoint = Vector2.new(0.5, 0.5)
	prize.BackgroundTransparency = 1
	prize.Font = Enum.Font.FredokaOne
	prize.TextScaled = true
	prize.TextColor3 = SpinWheelConfig.TierColors.normal
	prize.TextStrokeTransparency = 1
	prize.Text = ""
	prize.Parent = face
	local prizeCap = Instance.new("UITextSizeConstraint")
	prizeCap.MaxTextSize = 46
	prizeCap.Parent = prize
	local prizeOutline = Instance.new("UIStroke")
	prizeOutline.Thickness = 2
	prizeOutline.Color = Color3.fromRGB(12, 10, 26)
	prizeOutline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	prizeOutline.Parent = prize

	banner = gui
	bannerCard = card
	bannerTitle = title
	bannerPrize = prize
	return gui
end

local function showBanner(segment: SpinWheelConfig.Segment)
	local gui = buildBanner()
	local card, prize, stroke = bannerCard, bannerPrize, bannerStroke
	if not card or not prize or not bannerTitle then
		return
	end
	local tint = SpinWheelConfig.TierColors[segment.tier] or SpinWheelConfig.TierColors.normal

	bannerTitle.Text = if segment.tier == "jackpot" then "JACKPOT!" else "YOU WON"
	prize.Text = segment.won
	prize.TextColor3 = tint
	if stroke then
		stroke.Color = tint
	end

	gui.Enabled = true
	UIAnim.popIn(card, 0.7)
	if segment.tier ~= "normal" and not reducedEffects then
		UIAnim.punchRotation(card, 3)
	end

	task.delay(SpinWheelConfig.RESULT_SECONDS, function()
		if not banner then
			return
		end
		UIAnim.popOut(card)
		task.delay(0.2, function()
			if banner and not spinning then
				banner.Enabled = false
			end
		end)
	end)
end

-- ==========================================================
-- THE SPIN
-- ==========================================================

--- The pointer's two wedges get a flick every time a wedge boundary passes
--- under them, which is the physical version of the tick the audio is making.
local function flickTicker(wheel: Wheel)
	local decoration = wheel.model:FindFirstChild("Decoration")
	if not decoration then
		return
	end
	for _, part in decoration:GetChildren() do
		if part:IsA("BasePart") and part.Name == "Ticker" then
			local rest = part:GetAttribute("_SpinRest")
			if typeof(rest) ~= "CFrame" then
				rest = part.CFrame
				part:SetAttribute("_SpinRest", rest)
			end
			part.CFrame = (rest :: CFrame) * CFrame.Angles(math.rad(11), 0, 0)
			TweenService:Create(part, UIAnim.RELEASE, { CFrame = rest :: CFrame }):Play()
		end
	end
end

local function runSpin(wheel: Wheel, index: number)
	local segment = SpinWheelConfig.segment(index)
	if not segment then
		return
	end

	spinToken += 1
	local token = spinToken
	spinning = true

	-- WHERE IT MUST STOP, decided before the first frame is drawn: the landing
	-- angle for this segment, plus enough whole turns to read as a spin. The
	-- travel is measured from wherever the disc is resting now, so consecutive
	-- spins never snap.
	local landing = SpinWheelConfig.angleFor(index)
	local from = wheel.angle
	local travel = SpinWheelConfig.SPIN_TURNS * math.pi * 2 + (landing - from) % (math.pi * 2)

	-- ONE Sound, looped. The asset is 0.7s and the spin is several times that,
	-- so looping is what keeps the ticking continuous with nothing to time and
	-- no second copy to leave behind.
	local cue = Audio.create("SpinLoop")
	if cue then
		cue.Parent = wheel.disc
		cue.Looped = true
		cue.PlaybackSpeed = SpinWheelConfig.PITCH_FAST
		cue:Play()
	end

	local started = os.clock()
	local lastWedge = math.floor(from / math.rad(SpinWheelConfig.SEGMENT_ARC))
	local connection: RBXScriptConnection? = nil

	local function finish()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		-- Stopped and destroyed on the landing frame, so a leftover copy can
		-- never outlive the spin it belongs to.
		if cue then
			cue:Stop()
			cue:Destroy()
			cue = nil
		end
		if token ~= spinToken then
			return
		end

		wheel.angle = landing % (math.pi * 2)
		local settled = wheel.rest * CFrame.Angles(wheel.angle, 0, 0)

		-- THE BOUNCE: a couple of degrees past the mark and back. Well inside a
		-- thirty-degree wedge, so the pointer is never briefly on the wrong
		-- prize - which would be worse than no bounce at all.
		if reducedEffects then
			wheel.disc.CFrame = settled
		else
			wheel.disc.CFrame = settled * CFrame.Angles(math.rad(SpinWheelConfig.BOUNCE_DEG), 0, 0)
			TweenService:Create(
				wheel.disc,
				TweenInfo.new(SpinWheelConfig.BOUNCE_SECONDS, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
				{ CFrame = settled }
			):Play()
		end
		flickTicker(wheel)

		Audio.play("RevealPop")
		if segment.tier ~= "normal" then
			-- A guardian or the jackpot gets a second layer. The rare wins have
			-- to feel different from a $1,500, and this is the difference.
			Audio.play("ZoneUnlock")
		end
		if not reducedEffects then
			local variant = if segment.tier == "normal" then "Gold" else "Blue"
			EffectsController.burst(variant, wheel.disc.Position)
			if segment.tier ~= "normal" then
				task.delay(0.18, function()
					EffectsController.burst("Gold", wheel.disc.Position + Vector3.new(0, 2, 0))
				end)
			end
		end
		showBanner(segment)

		task.delay(SpinWheelConfig.RESULT_SECONDS + 0.3, function()
			if token == spinToken then
				spinning = false
			end
		end)
	end

	connection = RunService.RenderStepped:Connect(function()
		if token ~= spinToken then
			if connection then
				connection:Disconnect()
			end
			return
		end
		local elapsed = os.clock() - started
		local s = math.clamp(elapsed / SpinWheelConfig.SPIN_SECONDS, 0, 1)
		local progress = SpinWheelConfig.progress(s)
		local angle = from + travel * progress
		wheel.disc.CFrame = wheel.rest * CFrame.Angles(angle, 0, 0)

		-- The audio rides the wheel's own remaining travel, so the ticking
		-- slows with the picture instead of running to its own clock.
		if cue then
			cue.PlaybackSpeed = SpinWheelConfig.PITCH_FAST
				+ (SpinWheelConfig.PITCH_SLOW - SpinWheelConfig.PITCH_FAST) * progress
		end

		local wedge = math.floor(angle / math.rad(SpinWheelConfig.SEGMENT_ARC))
		if wedge ~= lastWedge then
			lastWedge = wedge
			if not reducedEffects then
				flickTicker(wheel)
			end
		end

		if s >= 1 then
			finish()
		end
	end)
end

-- ==========================================================
-- OWNERSHIP
-- ==========================================================

local function adoptOwned(wheel: Wheel?)
	if owned == wheel then
		return
	end
	owned = wheel
	announcedReady = false

	local gui = buildBillboard()
	if not wheel then
		gui.Enabled = false
		gui.Adornee = nil
		return
	end
	-- Adorned to the disc and offset in WORLD space, so the sign hangs above
	-- the wheel and stays put while the disc turns underneath it.
	local radius = math.max(wheel.disc.Size.Y, wheel.disc.Size.Z) / 2
	gui.Adornee = wheel.disc
	gui.StudsOffsetWorldSpace = Vector3.new(0, radius + 3, 0)
	gui.Enabled = true
end

--- Which wheel is mine? The server publishes the owner on the model, so this
--- is a read rather than a guess - and it follows a plot changing hands with
--- no extra machinery.
local function refreshOwnership()
	local mine: Wheel? = nil
	for _, wheel in wheels do
		local ownerId = wheel.model:GetAttribute(ATTR_OWNER)
		local isMine = type(ownerId) == "number" and ownerId == player.UserId
		setHidden(wheel, not isMine)
		if isMine then
			mine = wheel
		end
	end
	adoptOwned(mine)
end

-- ==========================================================
-- REGISTRATION
-- ==========================================================

local function register(model: Model)
	if wheels[model] then
		return
	end
	local disc = model:FindFirstChild(SpinWheelConfig.WHEEL_PART_NAME)
	if not disc or not disc:IsA("BasePart") then
		return
	end
	local anchor = model:FindFirstChild("PromptAnchor")
	local prompt = anchor and anchor:FindFirstChildOfClass("ProximityPrompt")

	local wheel: Wheel = {
		model = model,
		disc = disc,
		prompt = prompt,
		-- `hidden` starts false so the first pass always applies something.
		hidden = false,
		rest = disc.CFrame,
		angle = 0,
	}
	wheels[model] = wheel

	-- Hidden until proven mine. Doing it in this order means a wheel is never
	-- visible for even one frame on somebody else's plot.
	setHidden(wheel, true)

	model:GetAttributeChangedSignal(ATTR_OWNER):Connect(refreshOwnership)
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			wheels[model] = nil
			if owned and owned.model == model then
				adoptOwned(nil)
			end
		end
	end)
end

-- ==========================================================
-- START
-- ==========================================================

function SpinWheelController.start()
	for _, thing in workspace:GetDescendants() do
		if thing:IsA("Model") and thing.Name == SpinWheelConfig.MODEL_NAME then
			register(thing)
		end
	end
	-- The wheels are baked into the place, but the prompt is added by the
	-- server at start-up, so a client that loads first still has to notice.
	workspace.DescendantAdded:Connect(function(thing)
		if thing:IsA("Model") and thing.Name == SpinWheelConfig.MODEL_NAME then
			task.defer(register, thing)
		elseif thing:IsA("ProximityPrompt") and thing.Name == "SpinPrompt" then
			local model = thing:FindFirstAncestorOfClass("Model")
			local wheel = if model then wheels[model] else nil
			if wheel then
				wheel.prompt = thing
				-- A prompt that arrives after the hide pass has to be hidden too.
				thing.Enabled = not wheel.hidden
			end
		end
	end)

	refreshOwnership()
	-- Ownership is an attribute per model, and a model can be registered after
	-- its attribute was last written; a slow re-check costs nothing and closes
	-- that window without a signal per wheel.
	task.spawn(function()
		while true do
			task.wait(2)
			refreshOwnership()
		end
	end)

	-- A HOLD THAT WAS TOO EARLY. The server refuses it and says nothing; the
	-- answer belongs here, on the card the player is already looking at,
	-- instead of as a toast across the screen. Purely a label - the refusal
	-- itself happened on the server before this ran.
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local wheel = owned
		if spinning or not wheel or prompt ~= wheel.prompt then
			return
		end
		local remaining = remainingSeconds()
		if remaining <= 0 or remaining == math.huge then
			return
		end
		prompt.ObjectText = `Time left before Spin  {mmss(remaining)}`
		tooEarlyUntil = os.clock() + TOO_EARLY_SECONDS
		Audio.play("UiDenied")
	end)

	Remotes.get("SpinResult").OnClientEvent:Connect(function(index)
		local wheel = owned
		if not wheel or type(index) ~= "number" then
			return
		end
		runSpin(wheel, index)
	end)

	-- ONE frame loop for the countdown, the rainbow and the prompt gate. At
	-- ~12Hz: this is a clock and a colour drift, and neither needs 60.
	local accumulated = 0
	local phase = 0
	--- True while the sign is showing a plain countdown, so its colours are
	--- written once on the way in rather than on every frame.
	local idle = false
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated < 1 / 12 then
			return
		end
		local step = accumulated
		accumulated = 0

		local wheel = owned
		local label, gradient, stroke = timerLabel, timerGradient, timerStroke
		if not wheel or not label or not gradient or not stroke then
			return
		end

		local remaining = remainingSeconds()
		local ready = remaining <= 0 and remaining ~= math.huge

		-- THE PROMPT IS A LOCAL DECISION. The server leaves it on for
		-- everybody and refuses anything it should not honour, so what happens
		-- here is presentation: off for a wheel that is not mine, and off for
		-- the length of a spin, which is what stops a held key starting a
		-- second one.
		--
		-- It stays ON during the countdown, deliberately. A prompt that simply
		-- is not there reads as a broken wheel; one that answers "not yet, here
		-- is how long" teaches the player what the wheel is. The server refuses
		-- the early hold either way.
		if wheel.prompt then
			wheel.prompt.Enabled = not spinning
			if not spinning then
				if os.clock() < tooEarlyUntil and not ready then
					-- Still counting DOWN while it is up, so the answer stays
					-- true for as long as the player is reading it.
					wheel.prompt.ObjectText = `Time left before Spin  {mmss(remaining)}`
				else
					wheel.prompt.ObjectText = if ready then "Free Spin" else ""
				end
			end
		end

		if spinning then
			label.Text = ""
			return
		end

		if ready then
			idle = false
			label.Text = READY_TEXT
			if reducedEffects then
				gradient.Color = ColorSequence.new(SpinWheelConfig.TierColors.jackpot)
				stroke.Color = Color3.fromRGB(12, 10, 26)
			else
				phase = (phase + step * RAINBOW_SPEED) % 1
				gradient.Color = rainbowAt(phase)
				-- The outline picks up a trace of the same hue, which is what
				-- reads as a glow rather than a coloured word on a black edge.
				stroke.Color = Color3.fromHSV(phase, 0.7, 0.32)
			end
			announceReady()
		else
			announcedReady = false
			label.Text = if remaining == math.huge then "" else clockText(remaining)
			-- Only on the way in. Rebuilding an identical ColorSequence twelve
			-- times a second for nine minutes is the sort of thing that costs
			-- nothing until it is doing it on seven wheels at once.
			if not idle then
				idle = true
				gradient.Color = ColorSequence.new(IDLE_COLOR, IDLE_TINT)
				stroke.Color = Color3.fromRGB(12, 10, 26)
			end
		end
	end)
end

return SpinWheelController
