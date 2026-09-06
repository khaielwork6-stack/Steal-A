--!strict
--[[
	TreadmillOfferController
	The Speed-multiplier card that appears ONLY while the player is on their
	treadmill, and the HUD transition around it.

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
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)


local TreadmillOfferController = {}

local player = Players.LocalPlayer

local card: GuiObject? = nil
local holder: Frame? = nil
local shown = false
local floatConnection: RBXScriptConnection? = nil
local latest: any = nil
--- Forward-declared: `repaint` hides the card when there is nothing to sell,
--- and `hide` is defined further down.
local hide: () -> ()

-- A SIDE CARD, NOT A POPUP.
--
-- The first version sat centre-screen over the treadmill and the player - the
-- one place a purchase card must not be while someone is trying to train. The
-- reference is a small clean card down the left. The first cut parked it under
-- the nav rail, which put it straight on top of the stat card - the one HUD
-- element a training player is actually watching, because the Speed counter
-- is what the treadmill moves. So: BESIDE the stat card, bottom-aligned with
-- it, sliding up from below the screen edge and back down. It is part of the
-- HUD, not something in front of it.
--
-- Placed at runtime from the stat card's own Position and Size (same parent,
-- same units), so it follows the card if the HUD is ever rearranged. The
-- fallback below is only for a HUD that has no stat card to sit beside.
local GAP_FROM_STATS = 10
local FALLBACK_SHOWN_POSITION = UDim2.new(0.16, 24, 1, -14)
--- How far below the bottom edge the card parks while hidden.
local HIDDEN_DROP = 140
--- Roughly the width of the nav rail and the height of one of its buttons.
local CARD_SIZE = UDim2.fromScale(0.17, 0.115)
local CARD_MIN = Vector2.new(190, 62)
local CARD_MAX = Vector2.new(300, 96)
--- Inset from the screen edge, matching the rail's own margin.
local EDGE_INSET = 14

-- Bright cyan/blue like the reference. The pack's own studs and rays do the rest.
local CARD_COLOR = Color3.fromRGB(80, 210, 255)
local CARD_ACCENT = Color3.fromRGB(20, 120, 210)

--- The card's parts, resolved once.
local headline: TextLabel? = nil
local subline: TextLabel? = nil
local iconImage: ImageLabel? = nil

local function build(): boolean
	if card then
		return true
	end
	local ui = ShopKit.mainUi()
	if not ui then
		return false
	end
	local donor = ShopKit.card()
	if not donor then
		warn("[TreadmillOfferController] no pack card to build from - treadmill offer disabled.")
		return false
	end

	-- THE PILL, NOT THE CARD - same reasoning as the boss banner. The pack's
	-- product card does not survive being squeezed to a side-card; its buy
	-- BUTTON already is one: rounded, gradient, studs, rays, stroke.
	local donorBody = donor:FindFirstChild("Frame")
	local donorChoose = donorBody and donorBody:FindFirstChild("Choose")
	local pill = donorChoose and donorChoose:FindFirstChild("Buy")
	local donorIcon = donorBody and donorBody:FindFirstChild("Icon")
	if not pill or not pill:IsA("TextButton") then
		warn("[TreadmillOfferController] pack card has no Buy button - treadmill offer disabled.")
		donor:Destroy()
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

	pill.Name = "Card"
	pill.AnchorPoint = Vector2.new(0, 0.5)
	pill.Position = UDim2.fromScale(0, 0.5)
	pill.Size = UDim2.fromScale(1, 1)
	local pillAspect = pill:FindFirstChildOfClass("UIAspectRatioConstraint")
	if pillAspect then
		pillAspect:Destroy()
	end
	pill.Parent = frame

	local face = pill:FindFirstChild("Frame")
	if face then
		for _, name in { "Promo", "Line" } do
			local extra = face:FindFirstChild(name, true)
			if extra and extra:IsA("GuiObject") then
				extra.Visible = false
			end
		end

		if donorIcon then
			local icon = donorIcon:Clone()
			icon.Name = "Icon"
			icon.AnchorPoint = Vector2.new(0, 0.5)
			icon.Position = UDim2.fromScale(0.02, 0.5)
			icon.Size = UDim2.fromScale(0.3, 0.9)
			icon.ZIndex = 6
			icon.Parent = face
			iconImage = icon:FindFirstChildWhichIsA("ImageLabel", true)
			for _, layer in icon:GetDescendants() do
				if layer:IsA("ImageLabel") then
					layer.Image = ShopKit.Icons.Speed
				end
			end
		end

		-- "2X SPEED" big, "ONLY R$ 3" small under it - the reference's hierarchy.
		local price = face:FindFirstChild("Price")
		if price and price:IsA("TextLabel") then
			price.Name = "Headline"
			price.AnchorPoint = Vector2.new(0, 0)
			price.Position = UDim2.fromScale(0.34, 0.08)
			price.Size = UDim2.fromScale(0.64, 0.5)
			price.TextXAlignment = Enum.TextXAlignment.Left
			price.ZIndex = 6
			headline = price

			local sub = price:Clone()
			sub.Name = "Subline"
			sub.Position = UDim2.fromScale(0.34, 0.58)
			sub.Size = UDim2.fromScale(0.64, 0.3)
			sub.Parent = face
			subline = sub
		end
	end

	UIAnim.claimButton(pill)
	pill.Activated:Connect(function()
		if not latest or not latest.nextSpeedTier then
			return
		end
		UIAnim.punch(pill, 0.14)
		-- The client asks; the server picks the gamepass id from its own config.
		Remotes.get("PurchaseRequest"):FireServer("speedTier")
	end)

	donor:Destroy()
	holder = frame
	card = pill
	return true
end

local function paintColours(color: Color3, accent: Color3)
	local built = card
	if not built then
		return
	end
	local face = built:FindFirstChild("Frame")
	local gradient = face and face:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(color, accent)
	end
	local stroke = built:FindFirstChildOfClass("UIStroke")
	if stroke then
		-- Colour only, never thickness - see TrailShopController.
		stroke.Color = accent
	end
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
		if subline then
			subline.Text = `ONLY R$ {NumberFormat.comma(tier.robux)}`
		end
		paintColours(CARD_COLOR, CARD_ACCENT)
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
	local shown = shownPosition()
	return UDim2.new(shown.X.Scale, shown.X.Offset, 1, HIDDEN_DROP)
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
	-- The HUD stays. An earlier pass hid the whole interface while training,
	-- which took the Shop with it; this card is a side panel, not a mode.

	frame.Visible = true
	frame.Position = hiddenPosition()
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	scale.Scale = 0.7

	TweenService:Create(frame, UIAnim.SETTLE, { Position = shownPosition() }):Play()
	TweenService:Create(scale, UIAnim.GROW, { Scale = 1 }):Play()

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
