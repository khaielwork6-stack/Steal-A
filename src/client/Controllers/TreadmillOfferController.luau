--!strict
--[[
	TreadmillOfferController
	The Speed-multiplier card that appears ONLY while the player is on their
	treadmill, and the HUD transition around it.

	IT SHOWS ONE TIER AND NEVER TEN.
	`StatePush.monetization.nextSpeedTier` is derived server-side from live
	gamepass ownership, so this renders whatever the player is actually next in
	line for. It cannot offer a tier out of order, and when the field is nil -
	they own 1,024x - it shows a MAXED state instead of another purchase.

	IT DOES NOT DETECT THE TREADMILL ITSELF.
	`TreadmillController` already runs the same oriented-box test the server uses
	and knows, on the first frame, whether the player is training. This listens to
	that rather than adding a second detector that could disagree with it.

	THE HUD GOES THROUGH UIStateController.
	Nothing here sets `Visible` on a HUD element directly. It claims a suppressor
	and releases it, so leaving the treadmill while a shop is also open cannot
	strand the HUD hidden.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = require(script.Parent.UIStateController)

local TreadmillOfferController = {}

local player = Players.LocalPlayer

local card: GuiObject? = nil
local holder: Frame? = nil
local shown = false
local floatConnection: RBXScriptConnection? = nil
local latest: any = nil

-- A SIDE CARD, NOT A POPUP.
--
-- The first version sat centre-screen over the treadmill and the player - the
-- one place a purchase card must not be while someone is trying to train. The
-- reference is a small clean card down the left, under the navigation. So:
-- anchored to the left edge, parked below the nav rail, sliding in from just
-- off-screen and back out. It is part of the HUD, not something in front of it.
--
-- Positioned in SCALE against the screen, with a pixel floor and ceiling, so it
-- holds its place under the rail on a phone and on a 4K monitor alike.
local SHOWN_POSITION = UDim2.new(0, 0, 0.845, 0)
local HIDDEN_POSITION = UDim2.new(-0.25, 0, 0.845, 0)
--- Roughly the width of the nav rail and the height of one of its buttons.
local CARD_SIZE = UDim2.fromScale(0.17, 0.115)
local CARD_MIN = Vector2.new(190, 62)
local CARD_MAX = Vector2.new(300, 96)
--- Inset from the screen edge, matching the rail's own margin.
local EDGE_INSET = 14

-- Bright cyan/blue like the reference. The pack's own studs and rays do the rest.
local CARD_COLOR = Color3.fromRGB(80, 210, 255)
local CARD_ACCENT = Color3.fromRGB(20, 120, 210)
local MAXED_COLOR = Color3.fromRGB(255, 214, 120)
local MAXED_ACCENT = Color3.fromRGB(196, 130, 16)

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
	frame.AnchorPoint = Vector2.new(0, 0.5)
	frame.Position = HIDDEN_POSITION
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
		local owned = (latest and latest.speedMultiplier) or 1
		if headline then
			headline.Text = "MAXED"
		end
		if subline then
			subline.Text = `{NumberFormat.comma(owned)}x SPEED`
		end
		paintColours(MAXED_COLOR, MAXED_ACCENT)
	end
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

	local frame = holder :: Frame
	UIStateController.claim("treadmill")

	frame.Visible = true
	frame.Position = HIDDEN_POSITION
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	scale.Scale = 0.7

	TweenService:Create(frame, UIAnim.SETTLE, { Position = SHOWN_POSITION }):Play()
	TweenService:Create(scale, UIAnim.GROW, { Scale = 1 }):Play()

	-- Idle float starts only after the entrance has settled, so the two do not
	-- fight over the same UIScale.
	task.delay(0.5, function()
		if shown and card then
			floatConnection = ShopKit.idleFloat(card :: GuiObject, floatConnection)
		end
	end)
end

local function hide()
	if not shown then
		return
	end
	shown = false
	if floatConnection then
		floatConnection:Disconnect()
		floatConnection = nil
	end
	UIStateController.release("treadmill")

	local frame = holder
	if not frame then
		return
	end
	local scale = frame:FindFirstChildOfClass("UIScale")
	TweenService:Create(frame, UIAnim.SHRINK, { Position = HIDDEN_POSITION }):Play()
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
