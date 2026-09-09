--!strict
--[[
	TreadmillOfferController
	The Speed-multiplier card that appears ONLY while the player is on their
	treadmill: the next permanent Speed pass, drawn as a premium offer.

	IT SHOWS ONE TIER AND NEVER TEN.
	`StatePush.monetization.nextSpeedTier` is derived server-side from live
	gamepass ownership, so this renders whatever the player is actually next in
	line for. It cannot offer a tier out of order, and when the field is nil -
	they own 1,024x - it shows nothing at all.

	IT DOES NOT DETECT THE TREADMILL ITSELF.
	`TreadmillController` already runs the same oriented-box test the server uses
	and knows, on the first frame, whether the player is training. This listens to
	that rather than adding a second detector that could disagree with it.

	THE HUD STAYS UP.
	This is a side card, not a mode: the Shop, the stat card and the rail all
	remain usable while it is showing. It hides itself when there is no next tier
	to sell rather than showing a MAXED state.

	THE LOOK
	Built here in the HUD's own kit rather than borrowed from the pack's buy
	button (which read as a placeholder): a navy plate with a cyan-to-blue
	gradient border, a glowing icon badge, the multiplier as a big white-to-gold
	headline over a PERMANENT chip, a green Robux price pill, an OP DEAL tag, a
	sheen that sweeps every few seconds, and hover / press / purchase states.
	The whole card is the button.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local TreadmillOfferController = {}

local player = Players.LocalPlayer

local card: TextButton? = nil
local holder: Frame? = nil
local shown = false
local floatConnection: RBXScriptConnection? = nil
local latest: any = nil
--- Forward-declared: `repaint` hides the card when there is nothing to sell,
--- and `hide` is defined further down.
local hide: () -> ()

-- ==========================================================
-- LAYOUT
-- ==========================================================
--
-- A SIDE CARD, NOT A POPUP. Beside the stat card on desktop, bottom-aligned
-- with it; bottom-left on touch, right of the thumbstick and above the hotbar.

local GAP_FROM_STATS = 10
local FALLBACK_SHOWN_POSITION = UDim2.new(0.16, 24, 1, -14)
--- Touch layouts: bottom-left, clear of the thumbstick (left of x 150), the
--- 2x2 menu (ends at x 142) and the hotbar row (starts 66 px off the bottom).
local TOUCH_SHOWN_POSITION = UDim2.new(0, 150, 1, -150)
--- How far below the bottom edge the card parks while hidden.
local HIDDEN_DROP = 160
local CARD_SIZE = UDim2.fromScale(0.19, 0.125)
local CARD_MIN = Vector2.new(210, 68)
local CARD_MAX = if Device.isTouch() then Vector2.new(250, 78) else Vector2.new(330, 104)
--- Inset from the screen edge, matching the rail's own margin.
local EDGE_INSET = 14

-- ==========================================================
-- PALETTE
-- ==========================================================

local PLATE = Color3.fromRGB(14, 20, 42)
local FACE_TOP = Color3.fromRGB(46, 64, 118)
local FACE_BOTTOM = Color3.fromRGB(18, 26, 56)
local EDGE_A = Color3.fromRGB(120, 236, 255)
local EDGE_B = Color3.fromRGB(70, 120, 255)
local HEADLINE_TOP = Color3.fromRGB(255, 255, 255)
local HEADLINE_BOTTOM = Color3.fromRGB(255, 214, 90)
local OUTLINE = Color3.fromRGB(8, 12, 30)
local CHIP = Color3.fromRGB(72, 240, 226)
local CHIP_TEXT = Color3.fromRGB(10, 40, 48)
local PRICE_TOP = Color3.fromRGB(110, 245, 160)
local PRICE_BOTTOM = Color3.fromRGB(30, 190, 110)
local PRICE_PLATE = Color3.fromRGB(18, 110, 66)
local TAG = Color3.fromRGB(255, 196, 60)
local TAG_TEXT = Color3.fromRGB(60, 34, 4)
local BADGE_GLOW = Color3.fromRGB(120, 236, 255)

--- Seconds between sheen sweeps while the card is up.
local SHEEN_PERIOD = 3.2

--- The card's parts, resolved once.
local headline: TextLabel? = nil
local chip: TextLabel? = nil
local priceLabel: TextLabel? = nil
local sheen: Frame? = nil
local badgeIcon: ImageLabel? = nil
local edgeGradient: UIGradient? = nil
local sheenToken = 0

-- ==========================================================
-- BUILD
-- ==========================================================

local function text(parent: Instance, name: string, font: Enum.Font, color: Color3, max: number, z: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = font
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 1
	label.ZIndex = z
	label.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 9
	limit.MaxTextSize = max
	limit.Parent = label
	return label
end

local function build(): boolean
	if card then
		return true
	end
	local ui = ShopKit.mainUi()
	if not ui then
		return false
	end

	local frame = Instance.new("Frame")
	frame.Name = "TreadmillOffer"
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = FALLBACK_SHOWN_POSITION
	frame.Size = CARD_SIZE
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.ZIndex = 8
	frame.Parent = ui

	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = CARD_MIN
	limit.MaxSize = CARD_MAX
	limit.Parent = frame

	local inset = Instance.new("UIPadding")
	inset.PaddingLeft = UDim.new(0, EDGE_INSET)
	inset.Parent = frame

	-- THE PLATE: the whole card is one button.
	local plate = Instance.new("TextButton")
	plate.Name = "Card"
	plate.AnchorPoint = Vector2.new(0, 0.5)
	plate.Position = UDim2.fromScale(0, 0.5)
	plate.Size = UDim2.fromScale(1, 1)
	plate.BackgroundColor3 = PLATE
	plate.BorderSizePixel = 0
	plate.Text = ""
	plate.AutoButtonColor = false
	plate.ClipsDescendants = false
	plate.ZIndex = 9
	plate.Parent = frame
	local plateCorner = Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(0, 16)
	plateCorner.Parent = plate
	local outer = Instance.new("UIStroke")
	outer.Name = "Outer"
	outer.Thickness = 3
	outer.Color = OUTLINE
	outer.Parent = plate

	-- The face: gradient, studs, and a coloured border ring drawn as a stroke
	-- with its own gradient so it reads as light, not a flat line.
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.new(1, -6, 1, -6)
	face.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	face.BorderSizePixel = 0
	face.ClipsDescendants = true
	face.ZIndex = 10
	face.Parent = plate
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, 13)
	faceCorner.Parent = face
	local faceGradient = Instance.new("UIGradient")
	faceGradient.Rotation = 90
	faceGradient.Color = ColorSequence.new(FACE_TOP, FACE_BOTTOM)
	faceGradient.Parent = face
	local ring = Instance.new("UIStroke")
	ring.Name = "Ring"
	ring.Thickness = 2.5
	ring.Color = Color3.fromRGB(255, 255, 255)
	ring.Transparency = 0.05
	ring.Parent = face
	local ringGradient = Instance.new("UIGradient")
	ringGradient.Rotation = 20
	ringGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, EDGE_A),
		ColorSequenceKeypoint.new(0.5, EDGE_B),
		ColorSequenceKeypoint.new(1, EDGE_A),
	})
	ringGradient.Parent = ring
	edgeGradient = ringGradient

	local studs = Instance.new("ImageLabel")
	studs.Name = "Studs"
	studs.BackgroundTransparency = 1
	studs.Image = "rbxassetid://76728843491214"
	studs.ImageTransparency = 0.88
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(26, 26)
	studs.Size = UDim2.fromScale(1, 1)
	studs.ZIndex = 10
	studs.Parent = face

	-- A soft light across the top third so the plate has volume.
	local light = Instance.new("Frame")
	light.Name = "Light"
	light.Size = UDim2.fromScale(1, 0.5)
	light.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	light.BackgroundTransparency = 0.92
	light.BorderSizePixel = 0
	light.ZIndex = 10
	light.Parent = face
	local lightGradient = Instance.new("UIGradient")
	lightGradient.Rotation = 90
	lightGradient.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	lightGradient.Parent = light

	-- THE SHEEN: a diagonal white band that sweeps the face now and then.
	local sweep = Instance.new("Frame")
	sweep.Name = "Sheen"
	sweep.AnchorPoint = Vector2.new(0.5, 0.5)
	sweep.Position = UDim2.fromScale(-0.3, 0.5)
	sweep.Size = UDim2.fromScale(0.16, 1.8)
	sweep.Rotation = 22
	sweep.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	sweep.BackgroundTransparency = 0.72
	sweep.BorderSizePixel = 0
	sweep.ZIndex = 13
	sweep.Parent = face
	sheen = sweep

	-- THE BADGE: a rounded plate with a glow behind the Speed icon.
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.fromScale(0.03, 0.5)
	badge.Size = UDim2.fromScale(0.78, 0.78)
	badge.BackgroundColor3 = Color3.fromRGB(24, 40, 84)
	badge.BorderSizePixel = 0
	badge.ZIndex = 11
	badge.Parent = face
	local badgeRatio = Instance.new("UIAspectRatioConstraint")
	badgeRatio.AspectRatio = 1
	badgeRatio.DominantAxis = Enum.DominantAxis.Height
	badgeRatio.Parent = badge
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 12)
	badgeCorner.Parent = badge
	local badgeEdge = Instance.new("UIStroke")
	badgeEdge.Thickness = 2
	badgeEdge.Color = OUTLINE
	badgeEdge.Parent = badge
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(0.9, 0.9)
	glow.BackgroundColor3 = BADGE_GLOW
	glow.BackgroundTransparency = 0.55
	glow.BorderSizePixel = 0
	glow.ZIndex = 11
	glow.Parent = badge
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = glow
	local glowGradient = Instance.new("UIGradient")
	glowGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	glowGradient.Parent = glow
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.78, 0.78)
	icon.BackgroundTransparency = 1
	icon.Image = ShopKit.Icons.Speed
	icon.ZIndex = 12
	icon.Parent = badge
	badgeIcon = icon

	-- THE WORDS: multiplier headline over a PERMANENT chip.
	local head = text(face, "Headline", Enum.Font.FredokaOne, HEADLINE_TOP, 34, 12)
	head.AnchorPoint = Vector2.new(0, 0)
	head.Position = UDim2.fromScale(0.3, 0.1)
	head.Size = UDim2.fromScale(0.41, 0.48)
	head.TextXAlignment = Enum.TextXAlignment.Left
	local headGradient = Instance.new("UIGradient")
	headGradient.Rotation = 90
	headGradient.Color = ColorSequence.new(HEADLINE_TOP, HEADLINE_BOTTOM)
	headGradient.Parent = head
	local headStroke = Instance.new("UIStroke")
	headStroke.Thickness = 2.5
	headStroke.Color = OUTLINE
	headStroke.LineJoinMode = Enum.LineJoinMode.Round
	headStroke.Parent = head
	headline = head

	local tag = text(face, "Chip", Enum.Font.GothamBold, CHIP_TEXT, 13, 13)
	tag.AnchorPoint = Vector2.new(0, 0)
	tag.Position = UDim2.fromScale(0.3, 0.62)
	tag.Size = UDim2.fromScale(0.34, 0.24)
	tag.BackgroundTransparency = 0
	tag.BackgroundColor3 = CHIP
	tag.Text = "PERMANENT"
	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(0.5, 0)
	chipCorner.Parent = tag
	local chipPad = Instance.new("UIPadding")
	chipPad.PaddingLeft = UDim.new(0, 6)
	chipPad.PaddingRight = UDim.new(0, 6)
	chipPad.Parent = tag
	chip = tag

	-- THE PRICE PILL, right-hand side: green, with the Robux glyph.
	local pill = Instance.new("Frame")
	pill.Name = "Price"
	pill.AnchorPoint = Vector2.new(1, 0.5)
	pill.Position = UDim2.fromScale(0.97, 0.5)
	pill.Size = UDim2.fromScale(0.24, 0.5)
	pill.BackgroundColor3 = PRICE_PLATE
	pill.BorderSizePixel = 0
	pill.ZIndex = 12
	pill.Parent = face
	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(0, 10)
	pillCorner.Parent = pill
	local pillEdge = Instance.new("UIStroke")
	pillEdge.Thickness = 2
	pillEdge.Color = OUTLINE
	pillEdge.Parent = pill
	local pillFace = Instance.new("Frame")
	pillFace.Name = "Face"
	pillFace.AnchorPoint = Vector2.new(0.5, 0.5)
	pillFace.Position = UDim2.fromScale(0.5, 0.5)
	pillFace.Size = UDim2.new(1, -5, 1, -5)
	pillFace.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	pillFace.BorderSizePixel = 0
	pillFace.ZIndex = 13
	pillFace.Parent = pill
	local pillFaceCorner = Instance.new("UICorner")
	pillFaceCorner.CornerRadius = UDim.new(0, 8)
	pillFaceCorner.Parent = pillFace
	local pillGradient = Instance.new("UIGradient")
	pillGradient.Rotation = 90
	pillGradient.Color = ColorSequence.new(PRICE_TOP, PRICE_BOTTOM)
	pillGradient.Parent = pillFace
	local price = text(pillFace, "Amount", Enum.Font.FredokaOne, Color3.fromRGB(255, 255, 255), 24, 14)
	price.AnchorPoint = Vector2.new(0.5, 0.5)
	price.Position = UDim2.fromScale(0.5, 0.5)
	price.Size = UDim2.fromScale(0.9, 0.78)
	local priceStroke = Instance.new("UIStroke")
	priceStroke.Thickness = 2
	priceStroke.Color = Color3.fromRGB(8, 60, 30)
	priceStroke.LineJoinMode = Enum.LineJoinMode.Round
	priceStroke.Parent = price
	priceLabel = price

	-- THE TAG: OP DEAL, cocked at the top-right corner, overhanging the plate.
	local deal = text(plate, "Tag", Enum.Font.FredokaOne, TAG_TEXT, 14, 15)
	deal.AnchorPoint = Vector2.new(1, 0.5)
	deal.Position = UDim2.new(1, 6, 0, 0)
	deal.Size = UDim2.new(0.3, 0, 0.3, 0)
	deal.Rotation = 8
	deal.BackgroundTransparency = 0
	deal.BackgroundColor3 = TAG
	deal.Text = "OP DEAL"
	local dealCorner = Instance.new("UICorner")
	dealCorner.CornerRadius = UDim.new(0.5, 0)
	dealCorner.Parent = deal
	local dealEdge = Instance.new("UIStroke")
	dealEdge.Thickness = 2
	dealEdge.Color = OUTLINE
	dealEdge.Parent = deal
	local dealPad = Instance.new("UIPadding")
	dealPad.PaddingLeft = UDim.new(0, 6)
	dealPad.PaddingRight = UDim.new(0, 6)
	dealPad.Parent = deal

	-- Hover / press / ripple through the shared binder, plus a ring brighten
	-- on hover of our own.
	UIAnim.claimButton(plate)
	plate.MouseEnter:Connect(function()
		TweenService:Create(ring, UIAnim.HOVER, { Thickness = 3.5, Transparency = 0 }):Play()
	end)
	plate.MouseLeave:Connect(function()
		TweenService:Create(ring, UIAnim.UNHOVER, { Thickness = 2.5, Transparency = 0.05 }):Play()
	end)
	plate.Activated:Connect(function()
		if not latest or not latest.nextSpeedTier then
			return
		end
		UIAnim.punch(plate, 0.14)
		ShopKit.shine(plate)
		-- The client asks; the server picks the gamepass id from its own config.
		Remotes.get("PurchaseRequest"):FireServer("speedTier")
	end)

	holder = frame
	card = plate
	return true
end

-- ==========================================================
-- MOTION
-- ==========================================================

--- The sheen sweep and a slow rotation of the border light, while shown.
--- One task per showing; the token retires it on hide.
local function runSheen()
	sheenToken += 1
	local mine = sheenToken
	task.spawn(function()
		local phase = 0
		while shown and mine == sheenToken and sheen and sheen.Parent do
			-- Border light drifts round the frame.
			if edgeGradient then
				phase = (phase + 40) % 360
				TweenService:Create(edgeGradient, TweenInfo.new(SHEEN_PERIOD, Enum.EasingStyle.Linear), { Rotation = phase + 40 }):Play()
			end
			-- The badge kicks a little as the sweep passes it.
			if badgeIcon then
				badgeIcon.Rotation = -10
				TweenService:Create(badgeIcon, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Rotation = 0 }):Play()
			end
			sheen.Position = UDim2.fromScale(-0.3, 0.5)
			local pass = TweenService:Create(sheen, TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
				Position = UDim2.fromScale(1.3, 0.5),
			})
			pass:Play()
			pass.Completed:Wait()
			task.wait(SHEEN_PERIOD - 0.75)
		end
	end)
end

local function repaint()
	if not card then
		return
	end
	local tier = latest and latest.nextSpeedTier
	if tier then
		if headline then
			headline.Text = `{string.upper(tier.label)} SPEED`
		end
		if priceLabel then
			priceLabel.Text = `{utf8.char(0xE002)}{NumberFormat.comma(tier.robux)}`
		end
		if chip then
			chip.Text = "PERMANENT"
		end
	else
		-- Nothing left to sell. No MAXED card: a purchase card with nothing to
		-- buy is clutter, and the player who owns 1,024x already knows.
		hide()
	end
end

--- Where the card sits when shown: immediately right of the stat card and
--- bottom-aligned with it. Both share MainUI as parent and the same anchor
--- (bottom-left), so the stat card's scale and offset carry straight over.
local function shownPosition(): UDim2
	-- Touch: the stat card lives top-left there, and following it put this
	-- offer at the top of a phone screen. The card sits bottom-left instead,
	-- right of the thumbstick, above the hotbar row and beside the menu.
	if Device.isTouch() then
		return TOUCH_SHOWN_POSITION
	end
	local parent = holder and holder.Parent
	local stats = parent and parent:FindFirstChild("StatHUD")
	if stats and stats:IsA("GuiObject") then
		local position, size = stats.Position, stats.Size
		return UDim2.new(
			position.X.Scale + size.X.Scale,
			position.X.Offset + size.X.Offset + GAP_FROM_STATS,
			position.Y.Scale,
			position.Y.Offset
		)
	end
	return FALLBACK_SHOWN_POSITION
end

--- Parked below the bottom edge, straight under its shown spot.
local function hiddenPosition(): UDim2
	local shownAt = shownPosition()
	return UDim2.new(shownAt.X.Scale, shownAt.X.Offset, 1, HIDDEN_DROP)
end

local function show()
	if not build() then
		return
	end
	-- "Shown" means our flag AND the frame drawing: something outside (the pack
	-- hides all of MainUI while one of its panels is open) can flip Visible off
	-- under us, and the card must come back the next time it is asked for.
	if shown and holder and (holder :: Frame).Visible then
		return
	end
	shown = true
	repaint()
	-- Maxed: repaint hid the card and cleared the flag. Nothing to animate in.
	if not shown then
		return
	end

	local frame = holder :: Frame
	frame.Visible = true
	frame.Position = hiddenPosition()
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	scale.Scale = 0.7

	TweenService:Create(frame, UIAnim.SETTLE, { Position = shownPosition() }):Play()
	TweenService:Create(scale, UIAnim.GROW, { Scale = 1 }):Play()
	runSheen()

	-- Idle float starts only after the entrance has settled, so the two do not
	-- fight over the same UIScale.
	task.delay(0.5, function()
		if shown and card then
			floatConnection = ShopKit.idleFloat(card :: GuiObject, floatConnection)
		end
	end)
end

hide = function()
	if not shown then
		return
	end
	shown = false
	sheenToken += 1
	if floatConnection then
		floatConnection:Disconnect()
		floatConnection = nil
	end

	local frame = holder
	if not frame then
		return
	end
	local scale = frame:FindFirstChildOfClass("UIScale")
	TweenService:Create(frame, UIAnim.SHRINK, { Position = hiddenPosition() }):Play()
	if scale then
		local tween = TweenService:Create(scale, UIAnim.SHRINK, { Scale = 0.75 })
		tween:Play()
		tween.Completed:Once(function()
			-- Only actually hide if we are still meant to be hidden: stepping
			-- back on mid-exit must not have its entrance cancelled.
			if not shown and frame.Parent then
				frame.Visible = false
			end
		end)
	end
end

function TreadmillOfferController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if not state then
			return
		end
		local previous = latest and latest.speedMultiplier
		latest = state.monetization
		if shown then
			repaint()
			-- Celebrate an upgrade that just landed, then show the next tier.
			if previous and latest and latest.speedMultiplier > previous and card then
				ShopKit.shine(card :: GuiObject)
				UIAnim.punch(card :: GuiObject, 0.22)
			end
		end
	end)

	-- Driven by the controller that already knows, rather than a second detector.
	local TreadmillController = require(script.Parent.TreadmillController)
	TreadmillController.onTrainingChanged(function(training: boolean)
		if training then
			show()
		else
			hide()
		end
	end)
end

return TreadmillOfferController
