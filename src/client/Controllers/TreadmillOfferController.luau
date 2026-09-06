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

local card: Frame? = nil
local holder: Frame? = nil
local shown = false
local floatConnection: RBXScriptConnection? = nil
local latest: any = nil

local SHOWN_POSITION = UDim2.new(0.5, 0, 0.30, 0)
local HIDDEN_POSITION = UDim2.new(0.5, 0, 0.10, 0)

-- Bright cyan-green, matching the reference's energy without depending on its
-- art. The pack's own gradient and rays do the rest.
local CARD_COLOR = Color3.fromRGB(96, 240, 200)
local CARD_ACCENT = Color3.fromRGB(28, 150, 190)
local MAXED_COLOR = Color3.fromRGB(255, 214, 120)
local MAXED_ACCENT = Color3.fromRGB(196, 130, 16)

local function build(): boolean
	if card then
		return true
	end
	local ui = ShopKit.mainUi()
	if not ui then
		return false
	end
	local built = ShopKit.card()
	if not built then
		warn("[TreadmillOfferController] no pack card to build from - treadmill offer disabled.")
		return false
	end

	-- A holder gives the card a stable anchor and a size independent of the
	-- grid cell it was authored for.
	local frame = Instance.new("Frame")
	frame.Name = "TreadmillOffer"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = HIDDEN_POSITION
	frame.Size = UDim2.fromScale(0.24, 0.24)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.ZIndex = 8
	frame.Parent = ui

	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = Vector2.new(190, 0)
	limit.MaxSize = Vector2.new(340, math.huge)
	limit.Parent = frame

	built.Size = UDim2.fromScale(1, 1)
	built.Position = UDim2.fromScale(0.5, 0.5)
	built.AnchorPoint = Vector2.new(0.5, 0.5)
	built.Parent = frame

	ShopKit.bindBuy(built, function()
		if not latest or not latest.nextSpeedTier then
			return
		end
		UIAnim.punch(built, 0.14)
		-- The client asks; the server picks the gamepass id from its own config.
		Remotes.get("PurchaseRequest"):FireServer("speedTier")
	end)

	holder = frame
	card = built
	return true
end

local function repaint()
	local built = card
	if not built then
		return
	end
	local tier = latest and latest.nextSpeedTier

	if tier then
		ShopKit.fillCard(built, {
			title = `{tier.label} SPEED`,
			description = "Permanent multiplier on all treadmill training.",
			price = `R$ {NumberFormat.comma(tier.robux)}`,
			icon = ShopKit.Icons.Speed,
			color = CARD_COLOR,
			accent = CARD_ACCENT,
		})
	else
		local owned = (latest and latest.speedMultiplier) or 1
		ShopKit.fillCard(built, {
			title = "MAXED",
			description = `{NumberFormat.comma(owned)}x Speed - the highest multiplier in the game.`,
			price = "",
			icon = ShopKit.Icons.Speed,
			color = MAXED_COLOR,
			accent = MAXED_ACCENT,
			hidePrice = true,
		})
	end
end

local function show()
	if shown or not build() then
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
