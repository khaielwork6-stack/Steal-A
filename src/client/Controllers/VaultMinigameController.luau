--!strict
--[[
	VaultMinigameController
	The two ways to crack a vault's lock, drawn and played here; judged there.

	The SERVER (VaultService) picks the method, rolls the parameters and sends
	them with a one-shot token (VaultMinigame "start"). This controller blurs
	and darkens the world, hides the HUD, plays the one method it was given,
	and reports ONE verdict with the token (VaultMinigameResult). It never
	decides access: a reported success still has to pass the server's checks,
	and anything that interrupts the game here - the player has no cancel -
	is judged by the server as a failure (death, walking off, timeout).

	CUT   A green target pad orbits a big steel dial at a rate that eases up
	      and down. The cursor (a held finger on touch) must stay inside the
	      pad; a cutting arm follows it, leaving a cyan cut line and sparks.
	      Outside the pad for longer than the grace: failure. One full turn:
	      success. The turn does not begin until the cursor first enters the
	      pad, so nobody fails before they have started.

	PINS  Cylinders bob through a horizontal line. Tap each while the line
	      passes through its bright notch: it locks with a click and a flash
	      and stops moving. A tap while the line is outside the notch fails
	      the attempt. All locked: success.

	Reduced Effects: no blur, no sparks, snapping instead of tweens.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = require(script.Parent.UIStateController)

local VaultMinigameController = {}

local player = Players.LocalPlayer

local CLAIM = "vault"

-- Palette: the game's dark navy plates with the vault's gold, the cut's
-- cyan and the pad's green.
local INK = Color3.fromRGB(14, 16, 30)
local PLATE = Color3.fromRGB(28, 32, 52)
local STEEL_TOP = Color3.fromRGB(96, 104, 128)
local STEEL_BOTTOM = Color3.fromRGB(52, 58, 78)
local GOLD = Color3.fromRGB(255, 200, 70)
local GREEN = Color3.fromRGB(96, 240, 140)
local CYAN = Color3.fromRGB(80, 230, 255)
local RED = Color3.fromRGB(255, 92, 92)
local WHITE = Color3.fromRGB(255, 255, 255)
local FONT = Enum.Font.FredokaOne

--- Trail dots around the dial, and the spark pool.
local TRAIL_DOTS = 96
local SPARK_POOL = 16

type Session = {
	token: string,
	screen: ScreenGui,
	blur: BlurEffect?,
	loop: RBXScriptConnection?,
	inputs: { RBXScriptConnection },
	done: boolean,
}

local session: Session? = nil

-- ==========================================================
-- BUILDING BLOCKS
-- ==========================================================

local function corner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function gradient(parent: Instance, top: Color3, bottom: Color3)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(top, bottom)
	g.Parent = parent
end

local function label(parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3, maxText: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Size, l.Position = size, position
	l.Font, l.Text, l.TextColor3 = FONT, text, color
	l.TextScaled = true
	l.TextStrokeColor3 = INK
	l.TextStrokeTransparency = 0.2
	l.ZIndex = 5
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxText
	limit.Parent = l
	l.Parent = parent
	return l
end

--- The dark stage every method plays on: a full-screen shade, the blur, a
--- title and a hint. Returns the screen and the centre stage frame.
local function buildStage(title: string, hint: string): (ScreenGui, Frame)
	local gui = player:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "VaultMinigame"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 40
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = if Effects.isReduced() then 0.45 else 1
	shade.BorderSizePixel = 0
	shade.Parent = screen
	if not Effects.isReduced() then
		TweenService:Create(shade, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { BackgroundTransparency = 0.45 }):Play()
	end

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromScale(0.5, 0.52)
	stage.Size = UDim2.fromScale(1, 1)
	stage.BackgroundTransparency = 1
	stage.Parent = screen

	label(screen, title, UDim2.fromScale(0.8, 0.09), UDim2.fromScale(0.5, 0.09), GOLD, 44)
	label(screen, hint, UDim2.fromScale(0.8, 0.05), UDim2.fromScale(0.5, 0.16), WHITE, 22)

	screen.Parent = gui
	return screen, stage
end

local function pointer(): (Vector2?, boolean)
	-- The last touch is authoritative on touch; the mouse elsewhere.
	if Device.isTouch() then
		local touch = session and (session :: any).touch
		if touch and touch.down then
			return touch.at, true
		end
		return nil, false
	end
	return UserInputService:GetMouseLocation(), true
end

-- ==========================================================
-- SESSION
-- ==========================================================

local function teardown(current: Session)
	if current.loop then
		current.loop:Disconnect()
	end
	for _, connection in current.inputs do
		connection:Disconnect()
	end
	if current.blur then
		current.blur:Destroy()
	end
	local screen = current.screen
	local shade = screen:FindFirstChild("Shade")
	if Effects.isReduced() or not shade or not shade:IsA("Frame") then
		screen:Destroy()
	else
		local stage = screen:FindFirstChild("Stage")
		if stage and stage:IsA("GuiObject") then
			UIAnim.popOut(stage)
		end
		local tween = TweenService:Create(shade, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 })
		tween:Play()
		tween.Completed:Once(function()
			screen:Destroy()
		end)
	end
	UIStateController.release(CLAIM)
	if session == current then
		session = nil
	end
end

--- The one verdict. `report` is false when the SERVER already ruled (it told
--- us we failed), so nothing is sent back. Everything after this is
--- cosmetic - and the HUD claim is released at once, so the server's toast
--- ("Vault access locked...") has a HUD to land on while the verdict lingers.
local function finish(current: Session, success: boolean, report: boolean?)
	if current.done then
		return
	end
	current.done = true
	if report ~= false then
		Remotes.get("VaultMinigameResult"):FireServer(current.token, success)
	end
	UIStateController.release(CLAIM)
	Audio.play(if success then "ZoneUnlock" else "UiDenied")
	local stage = current.screen:FindFirstChild("Stage")
	if stage and stage:IsA("GuiObject") and not Effects.isReduced() then
		UIAnim.punch(stage, if success then 0.12 else 0.06)
	end
	local verdict = label(current.screen, if success then "UNLOCKED!" else "LOCK JAMMED", UDim2.fromScale(0.8, 0.1), UDim2.fromScale(0.5, 0.88), if success then GREEN else RED, 48)
	UIAnim.popIn(verdict)
	task.delay(if success then 0.9 else 1.3, function()
		teardown(current)
	end)
end

local function openSession(token: string, title: string, hint: string): (Session, Frame)
	if session then
		teardown(session)
	end
	UIStateController.claim(CLAIM)
	local screen, stage = buildStage(title, hint)
	local blur: BlurEffect? = nil
	if not Effects.isReduced() and not Effects.isLowGraphics() then
		blur = Instance.new("BlurEffect")
		blur.Name = "VaultMinigameBlur"
		blur.Size = 0
		blur.Parent = Lighting
		TweenService:Create(blur, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { Size = 18 }):Play()
	end
	local current: Session = { token = token, screen = screen, blur = blur, inputs = {}, done = false }
	session = current
	Audio.play("UiOpen")
	UIAnim.popIn(stage, 0.9)
	return current, stage
end

-- ==========================================================
-- METHOD 1: CIRCULAR CUTTING
-- ==========================================================

local function runCut(current: Session, stage: Frame, params: { [string]: any })
	local rotationSeconds = tonumber(params.rotationSeconds) or 9
	local padFraction = tonumber(params.padFraction) or 0.11
	local grace = tonumber(params.graceSeconds) or 0.4
	local wobble = tonumber(params.wobble) or 0.35
	local direction = if tonumber(params.direction) == -1 then -1 else 1
	local angle = tonumber(params.startAngle) or 0

	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local radius = math.floor(math.min(viewport.X, viewport.Y) * 0.3)
	local trackRadius = radius * 0.84

	-- The dial: a steel disc with a gold rim and a darker hub.
	local dial = Instance.new("Frame")
	dial.Name = "Dial"
	dial.AnchorPoint = Vector2.new(0.5, 0.5)
	dial.Position = UDim2.fromScale(0.5, 0.5)
	dial.Size = UDim2.fromOffset(radius * 2, radius * 2)
	dial.BackgroundColor3 = WHITE
	dial.BorderSizePixel = 0
	dial.Parent = stage
	corner(dial, UDim.new(1, 0))
	gradient(dial, STEEL_TOP, STEEL_BOTTOM)
	stroke(dial, GOLD, 5)
	local hub = Instance.new("Frame")
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromScale(0.42, 0.42)
	hub.BackgroundColor3 = PLATE
	hub.BorderSizePixel = 0
	hub.ZIndex = 2
	hub.Parent = dial
	corner(hub, UDim.new(1, 0))
	stroke(hub, INK, 3)
	local percent = label(hub, "0%", UDim2.fromScale(0.8, 0.4), UDim2.fromScale(0.5, 0.5), CYAN, 40)
	percent.ZIndex = 3

	local function onTrack(degrees: number, r: number): UDim2
		local radians = math.rad(degrees)
		return UDim2.new(0.5, math.sin(radians) * r, 0.5, -math.cos(radians) * r)
	end

	-- The cut trail: dots around the track, lit as the arm passes.
	local dots: { Frame } = {}
	for index = 1, TRAIL_DOTS do
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = onTrack((index - 1) / TRAIL_DOTS * 360, trackRadius)
		dot.Size = UDim2.fromOffset(7, 7)
		dot.BackgroundColor3 = CYAN
		dot.BorderSizePixel = 0
		dot.Visible = false
		dot.ZIndex = 3
		dot.Parent = dial
		corner(dot, UDim.new(1, 0))
		dots[index] = dot
	end

	-- The target pad: a green capsule lying along the track.
	local padLength = math.max(48, math.floor(2 * math.pi * trackRadius * padFraction))
	local pad = Instance.new("Frame")
	pad.Name = "Target"
	pad.AnchorPoint = Vector2.new(0.5, 0.5)
	pad.Size = UDim2.fromOffset(padLength, 30)
	pad.BackgroundColor3 = GREEN
	pad.BorderSizePixel = 0
	pad.ZIndex = 4
	pad.Parent = dial
	corner(pad, UDim.new(1, 0))
	local padGlow = stroke(pad, GREEN, 6, 0.6)

	-- The arm: from the hub to the track, with a cutter head at its tip.
	-- A GuiObject rotates about its own CENTRE, not its anchor, so the arm is
	-- centred halfway along the radius and rotated there: its inner end then
	-- sits on the hub and its outer end on the track at every angle.
	local arm = Instance.new("Frame")
	arm.Name = "Arm"
	arm.AnchorPoint = Vector2.new(0.5, 0.5)
	arm.Position = UDim2.fromScale(0.5, 0.5)
	arm.Size = UDim2.fromOffset(trackRadius, 6)
	arm.BackgroundColor3 = Color3.fromRGB(200, 208, 224)
	arm.BorderSizePixel = 0
	arm.ZIndex = 5
	arm.Parent = dial
	corner(arm, UDim.new(1, 0))
	local head = Instance.new("Frame")
	head.Name = "Cutter"
	head.AnchorPoint = Vector2.new(0.5, 0.5)
	head.Size = UDim2.fromOffset(20, 20)
	head.BackgroundColor3 = CYAN
	head.BorderSizePixel = 0
	head.ZIndex = 6
	head.Parent = dial
	corner(head, UDim.new(1, 0))
	stroke(head, WHITE, 2)

	-- Sparks: a pool of tiny squares flung from the cutter.
	type Spark = { frame: Frame, velocity: Vector2, life: number }
	local sparks: { Spark } = {}
	local sparkPool: { Frame } = {}
	if not Effects.isReduced() then
		for _ = 1, SPARK_POOL do
			local spark = Instance.new("Frame")
			spark.AnchorPoint = Vector2.new(0.5, 0.5)
			spark.Size = UDim2.fromOffset(5, 5)
			spark.BackgroundColor3 = Color3.fromRGB(255, 236, 160)
			spark.BorderSizePixel = 0
			spark.Visible = false
			spark.ZIndex = 7
			spark.Parent = dial
			corner(spark, UDim.new(1, 0))
			table.insert(sparkPool, spark)
		end
	end

	local baseRate = 360 / rotationSeconds
	local covered = 0
	local started = false
	local outside = 0
	local elapsed = 0
	local sparkClock = 0
	local litUpTo = 0

	local function placeArm(degrees: number)
		-- Rotation 0 points along +X; the track's 0 is up, so offset by 90.
		arm.Rotation = degrees - 90
		arm.Position = onTrack(degrees, trackRadius / 2)
		head.Position = onTrack(degrees, trackRadius)
	end
	pad.Position = onTrack(angle, trackRadius)
	pad.Rotation = angle
	placeArm(angle)

	current.loop = RunService.RenderStepped:Connect(function(dt)
		if current.done then
			return
		end
		elapsed += dt

		-- Where is the cursor, and is it on the pad?
		local at, held = pointer()
		local padCentre = pad.AbsolutePosition + pad.AbsoluteSize / 2
		local inside = false
		if at and held then
			-- Along the pad's own axis: a capsule test in the pad's frame.
			local rel = at - padCentre
			local rad = math.rad(pad.Rotation)
			local along = rel.X * math.cos(rad) + rel.Y * math.sin(rad)
			local across = -rel.X * math.sin(rad) + rel.Y * math.cos(rad)
			inside = math.abs(along) <= padLength / 2 + 10 and math.abs(across) <= 26
		end

		if not started then
			if inside then
				started = true
				Audio.play("UiClick")
			else
				padGlow.Transparency = 0.35 + 0.25 * math.sin(elapsed * 6)
				return
			end
		end

		-- The pad's rate eases between (1 - wobble) and (1 + wobble).
		local rate = baseRate * (1 + wobble * math.sin(elapsed * 2.1))
		local step = rate * dt
		angle = (angle + direction * step) % 360
		covered += step
		pad.Position = onTrack(angle, trackRadius)
		pad.Rotation = angle
		placeArm(angle)
		percent.Text = `{math.floor(math.min(covered / 360, 1) * 100)}%`

		-- The cut line lights up behind the arm.
		local lit = math.floor(math.min(covered / 360, 1) * TRAIL_DOTS)
		while litUpTo < lit do
			litUpTo += 1
			local index = ((math.floor(((tonumber(params.startAngle) or 0) / 360) * TRAIL_DOTS) + direction * litUpTo) % TRAIL_DOTS) + 1
			dots[index].Visible = true
		end

		-- Sparks off the cutter while cutting.
		if #sparkPool > 0 and inside then
			sparkClock += dt
			if sparkClock > 0.05 then
				sparkClock = 0
				local spark = table.remove(sparkPool)
				if spark then
					spark.Position = head.Position
					spark.Visible = true
					spark.BackgroundTransparency = 0
					local fling = math.rad(angle + 90 + (math.random() - 0.5) * 120)
					table.insert(sparks, { frame = spark, velocity = Vector2.new(math.cos(fling), math.sin(fling)) * (140 + math.random() * 160), life = 0.45 })
				end
			end
		end
		for index = #sparks, 1, -1 do
			local spark = sparks[index]
			spark.life -= dt
			local frame = spark.frame
			frame.Position = frame.Position + UDim2.fromOffset(spark.velocity.X * dt, spark.velocity.Y * dt)
			spark.velocity += Vector2.new(0, 500 * dt)
			frame.BackgroundTransparency = 1 - math.max(spark.life / 0.45, 0)
			if spark.life <= 0 then
				frame.Visible = false
				table.remove(sparks, index)
				table.insert(sparkPool, frame)
			end
		end

		-- The rule: stay inside, or lose the attempt.
		if inside then
			outside = 0
			pad.BackgroundColor3 = GREEN
			padGlow.Transparency = 0.4
		else
			outside += dt
			pad.BackgroundColor3 = pad.BackgroundColor3:Lerp(RED, 0.2)
			padGlow.Transparency = 0.15
			if outside > grace then
				finish(current, false)
				return
			end
		end

		if covered >= 360 then
			finish(current, true)
		end
	end)
end

-- ==========================================================
-- METHOD 2: LOCK PINS
-- ==========================================================

local function runPins(current: Session, stage: Frame, params: { [string]: any })
	local specs = if type(params.pins) == "table" then params.pins else {}
	local notchFraction = tonumber(params.notchFraction) or 0.2
	local count = #specs
	if count == 0 then
		finish(current, false)
		return
	end

	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local width = math.clamp(math.floor(viewport.X * 0.52), 300, 680)
	local height = math.clamp(math.floor(viewport.Y * 0.5), 220, 420)

	-- The lock body.
	local body = Instance.new("Frame")
	body.Name = "Lock"
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.5)
	body.Size = UDim2.fromOffset(width, height)
	body.BackgroundColor3 = WHITE
	body.BorderSizePixel = 0
	body.ClipsDescendants = true
	body.Parent = stage
	corner(body, UDim.new(0, 18))
	gradient(body, PLATE, INK)
	stroke(body, GOLD, 4)

	-- The target line, glowing amber, across the middle.
	local line = Instance.new("Frame")
	line.Name = "Line"
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.Position = UDim2.fromScale(0.5, 0.5)
	line.Size = UDim2.new(1, -16, 0, 3)
	line.BackgroundColor3 = GOLD
	line.BorderSizePixel = 0
	line.ZIndex = 6
	line.Parent = body
	stroke(line, GOLD, 4, 0.7)

	type Pin = {
		button: TextButton,
		shaft: Frame,
		notch: Frame,
		spec: { [string]: any },
		locked: boolean,
	}
	local pins: { Pin } = {}
	local slot = width / count
	local pinWidth = math.floor(math.clamp(slot * 0.5, 34, 72))
	for index, spec in specs do
		local pinHeight = math.floor(height * (tonumber(spec.height) or 0.35))
		local button = Instance.new("TextButton")
		button.Name = `Pin{index}`
		button.Text = ""
		button.AutoButtonColor = false
		button.BackgroundTransparency = 1
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = UDim2.new(0, slot * (index - 0.5), 0.5, 0)
		-- A hit area a touch can find: the whole slot, the pin's full travel.
		button.Size = UDim2.new(0, math.floor(slot), 1, 0)
		button.ZIndex = 7
		button.Parent = body
		local shaft = Instance.new("Frame")
		shaft.Name = "Shaft"
		shaft.AnchorPoint = Vector2.new(0.5, 0.5)
		shaft.Position = UDim2.fromScale(0.5, 0.5)
		shaft.Size = UDim2.fromOffset(pinWidth, pinHeight)
		shaft.BackgroundColor3 = WHITE
		shaft.BorderSizePixel = 0
		shaft.ZIndex = 4
		shaft.Parent = button
		corner(shaft, UDim.new(0, math.floor(pinWidth / 2)))
		gradient(shaft, STEEL_TOP, STEEL_BOTTOM)
		stroke(shaft, INK, 3)
		local notch = Instance.new("Frame")
		notch.Name = "Notch"
		notch.AnchorPoint = Vector2.new(0.5, 0.5)
		notch.Position = UDim2.fromScale(0.5, 0.5)
		notch.Size = UDim2.new(1, -8, notchFraction, 0)
		notch.BackgroundColor3 = CYAN
		notch.BorderSizePixel = 0
		notch.ZIndex = 5
		notch.Parent = shaft
		corner(notch, UDim.new(0, 6))
		local pin: Pin = { button = button, shaft = shaft, notch = notch, spec = spec, locked = false }
		pins[index] = pin

		button.Activated:Connect(function()
			if current.done or pin.locked then
				return
			end
			local lineY = line.AbsolutePosition.Y + line.AbsoluteSize.Y / 2
			local notchY = notch.AbsolutePosition.Y + notch.AbsoluteSize.Y / 2
			local valid = math.abs(lineY - notchY) <= notch.AbsoluteSize.Y / 2
			if not valid then
				shaft.BackgroundColor3 = RED
				finish(current, false)
				return
			end
			pin.locked = true
			notch.BackgroundColor3 = GREEN
			Audio.play("UiClick")
			Audio.play("PlaceItem")
			if not Effects.isReduced() then
				local flash = Instance.new("Frame")
				flash.AnchorPoint = Vector2.new(0.5, 0.5)
				flash.Position = UDim2.fromScale(0.5, 0.5)
				flash.Size = UDim2.fromScale(1.4, 1.2)
				flash.BackgroundColor3 = WHITE
				flash.BorderSizePixel = 0
				flash.ZIndex = 8
				flash.Parent = shaft
				corner(flash, UDim.new(0, 14))
				local tween = TweenService:Create(flash, TweenInfo.new(0.28, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 })
				tween:Play()
				tween.Completed:Once(function()
					flash:Destroy()
				end)
				UIAnim.punch(shaft, 0.14)
			end
			for _, other in pins do
				if not other.locked then
					return
				end
			end
			task.delay(0.35, function()
				finish(current, true)
			end)
		end)
	end

	local elapsed = 0
	current.loop = RunService.RenderStepped:Connect(function(dt)
		if current.done then
			return
		end
		elapsed += dt
		for _, pin in pins do
			if pin.locked then
				continue
			end
			local spec = pin.spec
			local amplitude = (tonumber(spec.amplitude) or 0.25) * height
			local period = tonumber(spec.period) or 1.6
			local phase = tonumber(spec.phase) or 0
			local offset = math.sin(elapsed * (2 * math.pi / period) + phase) * amplitude
			pin.shaft.Position = UDim2.new(0.5, 0, 0.5, offset)
		end
	end)
end

-- ==========================================================
-- START
-- ==========================================================

function VaultMinigameController.start()
	Remotes.get("VaultMinigame").OnClientEvent:Connect(function(action: any, token: any, zone: any, method: any, params: any)
		if action == "abort" then
			if session and session.token == token then
				session.done = true
				teardown(session)
			end
			return
		end
		if action == "fail" then
			-- The server ruled (walked off, died, timed out): show the jam,
			-- report nothing back.
			if session and session.token == token then
				finish(session, false, false)
			end
			return
		end
		if action ~= "start" or type(token) ~= "string" then
			return
		end
		local zoneName = `Zone {tostring(zone)} Vault`
		if method == "Pins" then
			local current, stage = openSession(token, zoneName, "Tap each pin while the line crosses its bright notch. Miss one and the lock jams.")
			runPins(current, stage, if type(params) == "table" then params else {})
		else
			local current, stage = openSession(token, zoneName, if Device.isTouch()
				then "Hold your finger inside the green target and follow it all the way round."
				else "Keep your cursor inside the green target and follow it all the way round.")
			-- Touch tracking for the cut: the held finger is the cursor.
			local touch = { down = false, at = Vector2.zero }
			(current :: any).touch = touch
			table.insert(current.inputs, UserInputService.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.Touch then
					touch.down = true
					touch.at = Vector2.new(input.Position.X, input.Position.Y)
				end
			end))
			table.insert(current.inputs, UserInputService.InputChanged:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.Touch then
					touch.at = Vector2.new(input.Position.X, input.Position.Y)
				end
			end))
			table.insert(current.inputs, UserInputService.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.Touch then
					touch.down = false
				end
			end))
			runCut(current, stage, if type(params) == "table" then params else {})
		end
	end)
end

return VaultMinigameController
