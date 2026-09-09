--!strict
--[[
	InteractController
	The single on-screen interaction prompt - and, on touch, the thing you
	press and hold.

	WHY ONE SHARED PROMPT
	Roblox draws its default prompt UI for EVERY ProximityPrompt in range. A
	base has fourteen display-slot prompts plus the treadmill within twelve
	studs, so a player at their base saw a dozen overlapping cards. Every
	prompt is therefore switched to Style = Custom (which suppresses Roblox's
	UI entirely) and this controller renders exactly ONE - the nearest - so
	there are never clones, stacks or flicker.

	VISIBLE THROUGH THE ITEM
	The card is our own BillboardGui with AlwaysOnTop = true and a fixed
	PIXEL size, adorned to the prompt's own part. Loot prompts already live
	on an invisible anchor in clear air (LootService.materialise puts it just
	above a short item, or at head height beside a tall one), so the card is
	never inside a model, never at the top of a Colossal, and reads the same
	at two studs and at fourteen. Anything else (a base pad, the treadmill)
	gets a modest lift above its part.

	HOLD-TO-STEAL, TWO INPUTS, ONE PATH
	  Desktop  Roblox reads the E key for a Custom prompt itself. This only
	           renders the hold: a radial ring fills over HoldDuration, and
	           rewinds if the key is released early. PromptTriggered - which
	           Roblox fires once at the end of a completed hold - is the only
	           thing that counts.
	  Touch    THE CARD ITSELF is the button. A BillboardGui in PlayerGui
	           takes input, so the whole card (plus a generous invisible
	           margin) calls the prompt's own InputHoldBegin / InputHoldEnd -
	           the SAME server validation, HoldDuration and single Triggered
	           apply. One active touch at a time; a second finger, a repeat
	           touch or a spammed tap cannot start a second hold. Releasing,
	           sliding off, dying, the item vanishing or the target changing
	           all end the hold through one function. The thumbstick is a
	           separate touch and keeps working.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = require(script.Parent.UIStateController)

local InteractController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- LOOK
-- ==========================================================

local PANEL_COLOR = Color3.fromRGB(16, 22, 44)
local PANEL_EDGE = Color3.fromRGB(0, 0, 0)
local KEY_FACE = Color3.fromRGB(255, 255, 255)
local KEY_TEXT = Color3.fromRGB(26, 32, 60)
local RING_TRACK = Color3.fromRGB(44, 58, 104)
local RING_FILL = Color3.fromRGB(120, 230, 255)
local RING_DONE = Color3.fromRGB(126, 255, 148)
local OBJECT_COLOR = Color3.fromRGB(255, 255, 255)
local ACTION_COLOR = Color3.fromRGB(255, 226, 120)
local PRESSED_EDGE = Color3.fromRGB(120, 230, 255)

--- The card's on-screen size. Pixels, deliberately: a card that shrank with
--- distance was mush at the edge of the interaction range.
local CARD_WIDTH = 236
local CARD_HEIGHT = 84
local KEY_SIZE = 66
--- Invisible margin around the card that still counts as pressing it, on
--- touch. The billboard is the card plus this on every side.
local TOUCH_MARGIN = 34
--- Farthest the card draws. Every interaction in the game is within this.
local CARD_MAX_DISTANCE = 64

-- ==========================================================
-- STATE
-- ==========================================================

local shown: { [ProximityPrompt]: boolean } = {}
local current: ProximityPrompt? = nil

local board: BillboardGui? = nil
local hitArea: TextButton
local card: Frame
local cardEdge: UIStroke
local keyLabel: TextLabel
local objectLabel: TextLabel
local actionLabel: TextLabel
local cardRing: (alpha: number, color: Color3?) -> ()

--- The prompt a hold is in progress on (from either input).
local holding: ProximityPrompt? = nil
--- The touch driving the hold, so a second finger is ignored and only the
--- finger that started it can end it.
local activeTouch: InputObject? = nil
--- Bumped whenever the card changes hands, so a deferred hide can tell it
--- has been superseded.
local hideToken = 0

-- ==========================================================
-- RADIAL RING
-- ==========================================================
--
-- A circular progress ring from plain Frames: two clipped halves, each
-- holding a full disc whose gradient hides half of it, rotated so the
-- visible wedge grows clockwise from twelve o'clock. No image assets.

local function buildRing(parent: GuiObject, thickness: number): (alpha: number, color: Color3?) -> ()
	local function halfClip(name: string, x: number, discX: number, transparency: NumberSequence): (Frame, Frame)
		local clip = Instance.new("Frame")
		clip.Name = name
		clip.BackgroundTransparency = 1
		clip.ClipsDescendants = true
		clip.Position = UDim2.fromScale(x, 0)
		clip.Size = UDim2.fromScale(0.5, 1)
		clip.ZIndex = parent.ZIndex + 1
		clip.Parent = parent

		local disc = Instance.new("Frame")
		disc.Name = "Disc"
		disc.AnchorPoint = Vector2.new(0.5, 0.5)
		disc.Position = UDim2.fromScale(discX, 0.5)
		disc.Size = UDim2.fromScale(2, 1)
		disc.BackgroundColor3 = RING_FILL
		disc.BorderSizePixel = 0
		disc.ZIndex = clip.ZIndex
		disc.Parent = clip
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = disc
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = transparency
		gradient.Parent = disc
		return clip, disc
	end

	-- Right half: the disc's RIGHT side is opaque.
	local _, rightDisc = halfClip("Right", 0.5, 0, NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.499, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 0),
	}))
	-- Left half: the disc's LEFT side is opaque.
	local _, leftDisc = halfClip("Left", 0, 1, NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.499, 0),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(1, 1),
	}))

	-- The hole, so the discs read as a ring rather than a pie.
	local hole = Instance.new("Frame")
	hole.Name = "Hole"
	hole.AnchorPoint = Vector2.new(0.5, 0.5)
	hole.Position = UDim2.fromScale(0.5, 0.5)
	hole.Size = UDim2.new(1, -thickness * 2, 1, -thickness * 2)
	hole.BackgroundColor3 = parent.BackgroundColor3
	hole.BorderSizePixel = 0
	hole.ZIndex = parent.ZIndex + 2
	hole.Parent = parent
	local holeRound = Instance.new("UICorner")
	holeRound.CornerRadius = UDim.new(1, 0)
	holeRound.Parent = hole

	return function(alpha: number, color: Color3?)
		local degrees = math.clamp(alpha, 0, 1) * 360
		-- These rotations make the wedge start at twelve o'clock and sweep
		-- clockwise, right half first.
		rightDisc.Rotation = math.clamp(degrees, 0, 180) - 180
		leftDisc.Rotation = math.clamp(degrees, 180, 360) - 360
		rightDisc.Visible = degrees > 0.5
		leftDisc.Visible = degrees > 180.5
		local fill = color or RING_FILL
		rightDisc.BackgroundColor3 = fill
		leftDisc.BackgroundColor3 = fill
	end
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function label(parent: Instance, name: string, color: Color3, size: number, bold: boolean): TextLabel
	local item = Instance.new("TextLabel")
	item.Name = name
	item.BackgroundTransparency = 1
	item.Font = if bold then Enum.Font.FredokaOne else Enum.Font.GothamBold
	item.TextColor3 = color
	item.TextScaled = true
	item.TextStrokeTransparency = 0.2
	item.TextStrokeColor3 = Color3.fromRGB(8, 12, 28)
	item.TextXAlignment = Enum.TextXAlignment.Left
	item.TextTruncate = Enum.TextTruncate.AtEnd
	item.ZIndex = 4
	item.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 10
	limit.MaxTextSize = size
	limit.Parent = item
	return item
end

--- The pack's demo billboards ("Top Cash", "Gamepasses", "Next Update!",
--- the Action template) ship ENABLED with no Adornee, and a BillboardGui
--- with no Adornee draws at the world origin - the red line in front of the
--- spawn, dead centre of a new player's first view. The server clones what
--- it needs from StarterGui; the copies in PlayerGui are leftovers.
local function silencePackBillboards(mainUi: Instance)
	local surface = mainUi:FindFirstChild("Surface/Billboards")
	if not surface then
		return
	end
	for _, gui in surface:GetDescendants() do
		if gui:IsA("BillboardGui") and gui.Adornee == nil then
			gui.Enabled = false
		end
	end
end

local function buildCard(): boolean
	local playerGui = player:WaitForChild("PlayerGui")
	local mainUi = playerGui:WaitForChild("MainUI", 20)
	if mainUi then
		silencePackBillboards(mainUi)
	end

	local touch = Device.isTouch()
	local margin = if touch then TOUCH_MARGIN else 0

	local gui = Instance.new("BillboardGui")
	gui.Name = "InteractPrompt"
	gui.Size = UDim2.fromOffset(CARD_WIDTH + margin * 2, CARD_HEIGHT + margin * 2)
	gui.StudsOffsetWorldSpace = Vector3.zero
	gui.MaxDistance = CARD_MAX_DISTANCE
	-- THROUGH the item. A prompt hidden behind the thing it acts on is the
	-- whole bug this controller exists to fix.
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ClipsDescendants = false
	-- Input only reaches a BillboardGui that is Active and lives in
	-- PlayerGui - both true here - which is what lets the card be the button.
	gui.Active = true
	-- A BillboardGui is a LayerCollector: PlayerGui wipes it on respawn
	-- unless told otherwise, and being caught by a guardian respawns you.
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Parent = playerGui
	board = gui

	-- The whole billboard is the touch target: card plus margin.
	local hit = Instance.new("TextButton")
	hit.Name = "HitArea"
	hit.Size = UDim2.fromScale(1, 1)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.Active = touch
	hit.Selectable = false
	hit.ZIndex = 1
	hit.Visible = false
	hit.Parent = gui
	hitArea = hit

	local panel = Instance.new("Frame")
	panel.Name = "Card"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Parent = hit
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = panel
	local edge = Instance.new("UIStroke")
	edge.Thickness = 3
	edge.Color = PANEL_EDGE
	edge.Parent = panel
	cardEdge = edge
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(44, 58, 104), Color3.fromRGB(18, 24, 48))
	gradient.Parent = panel
	card = panel

	-- The keycap: a ring around a white disc with the key (or HOLD) on it.
	local keyHolder = Instance.new("Frame")
	keyHolder.Name = "Key"
	keyHolder.AnchorPoint = Vector2.new(0, 0.5)
	keyHolder.Position = UDim2.new(0, 9, 0.5, 0)
	keyHolder.Size = UDim2.fromOffset(KEY_SIZE, KEY_SIZE)
	keyHolder.BackgroundColor3 = RING_TRACK
	keyHolder.BorderSizePixel = 0
	keyHolder.ZIndex = 3
	keyHolder.Parent = panel
	local keyRound = Instance.new("UICorner")
	keyRound.CornerRadius = UDim.new(1, 0)
	keyRound.Parent = keyHolder
	cardRing = buildRing(keyHolder, 6)

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.new(1, -16, 1, -16)
	face.BackgroundColor3 = KEY_FACE
	face.BorderSizePixel = 0
	face.ZIndex = 6
	face.Parent = keyHolder
	local faceRound = Instance.new("UICorner")
	faceRound.CornerRadius = UDim.new(1, 0)
	faceRound.Parent = face
	local faceEdge = Instance.new("UIStroke")
	faceEdge.Thickness = 2
	faceEdge.Color = Color3.fromRGB(20, 24, 40)
	faceEdge.Parent = face

	keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "KeyText"
	keyLabel.BackgroundTransparency = 1
	keyLabel.Size = UDim2.fromScale(0.8, 0.8)
	keyLabel.Position = UDim2.fromScale(0.5, 0.5)
	keyLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	keyLabel.Font = Enum.Font.FredokaOne
	keyLabel.TextScaled = true
	keyLabel.TextColor3 = KEY_TEXT
	keyLabel.Text = "E"
	keyLabel.ZIndex = 7
	keyLabel.Parent = face

	local textLeft = 9 + KEY_SIZE + 10
	objectLabel = label(panel, "Object", OBJECT_COLOR, 24, true)
	objectLabel.Position = UDim2.new(0, textLeft, 0, 12)
	objectLabel.Size = UDim2.new(1, -textLeft - 12, 0, 30)
	actionLabel = label(panel, "Action", ACTION_COLOR, 17, false)
	actionLabel.Position = UDim2.new(0, textLeft, 0, 46)
	actionLabel.Size = UDim2.new(1, -textLeft - 12, 0, 24)

	return true
end

-- ==========================================================
-- HOLD RENDERING
-- ==========================================================

local ringTween: Tween? = nil
local ringAlpha = Instance.new("NumberValue")

local function paintRing(color: Color3?)
	cardRing(ringAlpha.Value, color)
end

local function stopRingTween()
	if ringTween then
		ringTween:Cancel()
		ringTween = nil
	end
end

local function rewindRing()
	stopRingTween()
	local tween = TweenService:Create(ringAlpha, UIAnim.SNAP, { Value = 0 })
	ringTween = tween
	tween:Play()
	if cardEdge then
		cardEdge.Color = PANEL_EDGE
	end
end

local function fillRing(duration: number)
	stopRingTween()
	ringAlpha.Value = 0
	local tween = TweenService:Create(ringAlpha, TweenInfo.new(math.max(duration, 0.05), Enum.EasingStyle.Linear), { Value = 1 })
	ringTween = tween
	tween:Play()
	if cardEdge then
		cardEdge.Color = PRESSED_EDGE
	end
end

local function completeRing()
	stopRingTween()
	ringAlpha.Value = 1
	paintRing(RING_DONE)
	task.delay(0.18, function()
		if not holding then
			ringAlpha.Value = 0
			paintRing()
			if cardEdge then
				cardEdge.Color = PANEL_EDGE
			end
		end
	end)
end

-- ==========================================================
-- HOLD CONTROL (touch side)
-- ==========================================================

--- Ends the touch hold, if one is running. The ONE place a mobile hold
--- stops: release, slide-off, target change, death, despawn all come here.
local function endTouchHold()
	local prompt = holding
	activeTouch = nil
	if not prompt then
		return
	end
	holding = nil
	if prompt.Parent and prompt:IsDescendantOf(workspace) then
		prompt:InputHoldEnd()
	end
	rewindRing()
end

local function beginTouchHold(input: InputObject)
	local prompt = current
	if not prompt or holding or activeTouch then
		return
	end
	if not prompt.Enabled or not prompt:IsDescendantOf(workspace) then
		return
	end
	activeTouch = input
	holding = prompt
	prompt:InputHoldBegin()
	if prompt.HoldDuration <= 0 then
		-- A tap prompt triggers on the begin; close the hold straight away
		-- so a finger resting there cannot re-trigger anything.
		task.defer(endTouchHold)
	else
		fillRing(prompt.HoldDuration)
	end
	UIAnim.punch(card, 0.06)
end

-- ==========================================================
-- TARGETING
-- ==========================================================

--- Nearest currently-shown prompt, so walking past a row of slots highlights
--- only the one the player actually means.
---
--- The `IsDescendantOf(workspace)` test is load-bearing: PromptHidden does
--- NOT fire for a prompt whose part is destroyed (every piece of loot, the
--- moment it is stolen), and a destroyed prompt still reports Enabled and a
--- Parent - so it kept winning this search while nothing rendered.
local function pickNearest(): ProximityPrompt?
	local character = player.Character
	local origin = character and character:FindFirstChild("HumanoidRootPart")
	if not origin or not origin:IsA("BasePart") then
		return nil
	end

	local best, bestDistance = nil, math.huge
	for prompt in shown do
		local part = prompt.Parent
		if prompt.Enabled and part and part:IsA("BasePart") and prompt:IsDescendantOf(workspace) then
			local distance = (part.Position - origin.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = prompt, distance
			end
		else
			shown[prompt] = nil
		end
	end
	return best
end

--- How far above the prompt's part the card floats.
---
--- Loot prompts live on LootService's `PromptAnchor`, already placed in clear
--- air at the reachable side of the item: no lift. Anything else gets a
--- modest lift above the part (or its small model), capped so a tall part
--- never pushes the card off the top of the screen.
local function liftFor(part: BasePart): number
	if part.Name == "PromptAnchor" then
		return 0
	end
	local height = part.Size.Y
	local model = part:FindFirstAncestorWhichIsA("Model")
	if model and model ~= workspace then
		local _, size = model:GetBoundingBox()
		if size.Y <= height * 4 + 8 then
			height = math.max(height, size.Y)
		end
	end
	return math.min(height / 2 + 2.2, 6)
end

local function keyNameFor(prompt: ProximityPrompt): string
	if Device.isTouch() then
		return if prompt.HoldDuration > 0 then "HOLD" else "TAP"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return prompt.GamepadKeyCode.Name
	end
	return prompt.KeyboardKeyCode.Name
end

--- The current prompt can be RETITLED under us: a display slot flips from
--- "Instant Reveal" to "Reveal" the second its container is ready. This
--- follows that change on the one prompt being shown, so the card never
--- has to be re-applied to notice.
local retitle: RBXScriptConnection? = nil

--- Swaps content in place. Never creates a second card.
local function apply(prompt: ProximityPrompt?)
	if prompt == current then
		return
	end
	if retitle then
		retitle:Disconnect()
		retitle = nil
	end
	if prompt then
		retitle = prompt:GetPropertyChangedSignal("ActionText"):Connect(function()
			if prompt == current then
				actionLabel.Text = if prompt.HoldDuration > 0 then `HOLD  {prompt.ActionText}` else prompt.ActionText
			end
		end)
	end
	local gui = board
	if not gui or not gui:IsDescendantOf(game) then
		return
	end

	-- A hold on the previous target cannot survive a target change.
	if holding and holding ~= prompt then
		endTouchHold()
		rewindRing()
	end

	current = prompt

	if not prompt then
		hideToken += 1
		local token = hideToken
		local scale = UIAnim.scaleOf(card)
		if scale then
			TweenService:Create(scale, UIAnim.SNAP, { Scale = 0.85 }):Play()
		end
		task.delay(0.12, function()
			if token ~= hideToken or current then
				return
			end
			hitArea.Visible = false
			if scale then
				scale.Scale = 1
			end
			gui.Enabled = false
			gui.Adornee = nil
		end)
		return
	end

	hideToken += 1
	local part = prompt.Parent :: BasePart
	-- ADORNEE ONLY. Parented into the world, the card would be destroyed with
	-- the first piece of loot it was attached to.
	gui.Adornee = part
	gui.StudsOffsetWorldSpace = Vector3.new(0, liftFor(part), 0)

	objectLabel.Text = prompt.ObjectText
	actionLabel.Text = if prompt.HoldDuration > 0 then `HOLD  {prompt.ActionText}` else prompt.ActionText
	keyLabel.Text = keyNameFor(prompt)
	ringAlpha.Value = 0
	paintRing()

	local wasHidden = not gui.Enabled or not hitArea.Visible
	gui.Enabled = true
	hitArea.Visible = true
	if wasHidden then
		UIAnim.popIn(card, 0.7)
	else
		UIAnim.punch(card, 0.08)
	end
end

-- ==========================================================
-- START
-- ==========================================================

function InteractController.start()
	if not buildCard() then
		return
	end
	ringAlpha.Changed:Connect(function()
		paintRing()
	end)

	-- Suppress Roblox's built-in prompt UI everywhere, including prompts
	-- created later at runtime.
	local function makeCustom(instance: Instance)
		if instance:IsA("ProximityPrompt") then
			instance.Style = Enum.ProximityPromptStyle.Custom
		end
	end
	for _, descendant in workspace:GetDescendants() do
		makeCustom(descendant)
	end
	workspace.DescendantAdded:Connect(makeCustom)

	ProximityPromptService.PromptShown:Connect(function(prompt)
		prompt.Style = Enum.ProximityPromptStyle.Custom
		shown[prompt] = true
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		shown[prompt] = nil
		if holding == prompt then
			endTouchHold()
		end
	end)

	-- Desktop / gamepad hold: Roblox drives the input; this draws it.
	ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
		if prompt ~= current or prompt.HoldDuration <= 0 then
			return
		end
		if not holding then
			holding = prompt
		end
		fillRing(prompt.HoldDuration)
	end)

	-- Fires on release AND on completion, so it must only rewind what the
	-- trigger handler has not already claimed.
	ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt)
		if prompt ~= current then
			return
		end
		if holding == prompt and not activeTouch then
			holding = nil
		end
		if ringAlpha.Value < 0.999 then
			rewindRing()
		end
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt ~= current then
			return
		end
		holding = nil
		activeTouch = nil
		completeRing()
		UIAnim.punch(card, 0.12)
	end)

	-- The card as a button. Touch only: a mouse over it does nothing, so a
	-- desktop click can never start a hold Roblox is not also driving.
	hitArea.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			beginTouchHold(input)
		end
	end)
	hitArea.InputEnded:Connect(function(input)
		if input == activeTouch then
			endTouchHold()
		end
	end)
	-- A finger that slides off the card ends the hold even though the button
	-- never sees the InputEnded.
	hitArea.MouseLeave:Connect(function()
		if activeTouch then
			endTouchHold()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input == activeTouch then
			endTouchHold()
		end
	end)

	-- Death, respawn: nothing is held by a character that no longer exists.
	player.CharacterAdded:Connect(function()
		endTouchHold()
		rewindRing()
	end)

	RunService.Heartbeat:Connect(function()
		local gui = board
		if not gui or not gui:IsDescendantOf(game) then
			return
		end

		-- An adornee that has left the world renders nothing. Release the
		-- target so the next candidate can claim the card next frame.
		local adornee = gui.Adornee
		if current and (not adornee or not adornee:IsDescendantOf(workspace)) then
			if holding == current then
				endTouchHold()
			end
			current = nil
			gui.Enabled = false
			gui.Adornee = nil
		end

		-- While carrying, the only prompts that matter are the display slots
		-- the item can be placed on. Steal prompts and everything else stay
		-- hidden with the rest of the HUD; DROP is the only button.
		local candidate = pickNearest()
		if UIStateController.hasClaim("carry") and candidate and candidate.Name ~= "SlotPrompt" then
			candidate = nil
		end
		apply(candidate)

		-- A touch hold that outlives its prompt (disabled mid-hold by the
		-- server, or the player walked out of range) is cut, never left to
		-- trigger later.
		local held = holding
		if held and activeTouch and (not held.Enabled or not held:IsDescendantOf(workspace) or held ~= current) then
			endTouchHold()
		end
	end)
end

return InteractController
