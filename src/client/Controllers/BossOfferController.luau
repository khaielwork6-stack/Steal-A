--!strict
--[[
	BossOfferController
	The "too slow" Speed offer that animates in after a zone guardian catches you.

	IT CANNOT TRIGGER ITSELF.
	The only thing that shows this card is a `BossOffer` from the server, fired
	from GuardianService's catch handler - the one path that means "you were
	carrying loot and the chase beat you". This controller has no idea what a
	death, a reset or a fall is, which is exactly why it cannot fire on one.

	ONE CARD, REUSED.
	Caught again while it is up and the existing card is re-texted and re-punched
	rather than a second one being spawned. The server also holds a cooldown, so
	the two together mean a bad run cannot bury the screen in purchase prompts.

	IT NEVER BLOCKS PLAY.
	Top-centre, no modal backdrop, an X to dismiss and an auto-dismiss behind it.
	Being caught is already frustrating; a prompt you have to fight is worse.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local BossOfferController = {}

local player = Players.LocalPlayer

local holder: Frame? = nil
local card: Frame? = nil
local currentKey: string? = nil
local offeredAmount: number? = nil
local lastSpeedPower: number? = nil
local dismissAt = 0
local visible = false

local SHOWN_POSITION = UDim2.new(0.5, 0, 0.26, 0)
local HIDDEN_POSITION = UDim2.new(0.5, 0, 0.13, 0)
local AUTO_DISMISS = 12

local OFFER_COLOR = Color3.fromRGB(96, 240, 200)
local OFFER_ACCENT = Color3.fromRGB(26, 128, 176)

local function hide()
	if not visible then
		return
	end
	visible = false
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
			if not visible and frame.Parent then
				frame.Visible = false
			end
		end)
	end
end

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
		warn("[BossOfferController] no pack card to build from - loss offer disabled.")
		return false
	end

	local frame = Instance.new("Frame")
	frame.Name = "BossOffer"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = HIDDEN_POSITION
	frame.Size = UDim2.fromScale(0.23, 0.23)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.ZIndex = 12
	frame.Parent = ui

	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = Vector2.new(180, 0)
	limit.MaxSize = Vector2.new(320, math.huge)
	limit.Parent = frame

	built.Size = UDim2.fromScale(1, 1)
	built.Position = UDim2.fromScale(0.5, 0.5)
	built.AnchorPoint = Vector2.new(0.5, 0.5)
	built.Parent = frame

	ShopKit.bindBuy(built, function()
		if not currentKey then
			return
		end
		UIAnim.punch(built, 0.16)
		-- The client names a config KEY, never a product id.
		Remotes.get("PurchaseRequest"):FireServer("product", currentKey)
	end)

	-- Dismiss. Borrowed from the pack's own shop header so the X matches the
	-- rest of the game rather than being a drawn cross.
	local top = ShopKit.topBar()
	-- The pack nests its X as Top.Frame.Close, so this has to search rather than
	-- look one level down - a direct lookup finds nothing and the card comes up
	-- with no way to dismiss it but the timer.
	local packClose = top and top:FindFirstChild("Close", true)
	if packClose and packClose:IsA("TextButton") then
		local close = packClose:Clone()
		close.Name = "Dismiss"
		close.AnchorPoint = Vector2.new(1, 0)
		close.Position = UDim2.fromScale(1.02, -0.04)
		close.Size = UDim2.fromScale(0.2, 0.2)
		close.ZIndex = 20
		close.Parent = frame
		UIAnim.claimButton(close)
		close.Activated:Connect(hide)
	end
	if top then
		top:Destroy()
	end

	holder = frame
	card = built
	return true
end

local function show(offer: any)
	if not build() then
		return
	end
	local frame = holder :: Frame
	local built = card :: Frame

	currentKey = offer.productKey
	offeredAmount = tonumber(offer.amount)
	dismissAt = os.clock() + AUTO_DISMISS

	ShopKit.fillCard(built, {
		title = `+{offer.label} SPEED`,
		description = "Too slow! Catch up and outrun the guard.",
		price = `R$ {NumberFormat.comma(offer.robux)}`,
		icon = ShopKit.Icons.Speed,
		color = OFFER_COLOR,
		accent = OFFER_ACCENT,
	})

	-- Already up: re-text and punch rather than stacking a second card.
	if visible then
		UIAnim.punch(built, 0.18)
		ShopKit.shine(built)
		return
	end

	visible = true
	frame.Visible = true
	frame.Position = HIDDEN_POSITION
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	scale.Scale = 0.7

	TweenService:Create(frame, UIAnim.SETTLE, { Position = SHOWN_POSITION }):Play()
	-- Back easing overshoots and settles: 0.7 -> ~1.08 -> 1.0 in one tween.
	TweenService:Create(scale, UIAnim.GROW, { Scale = 1 }):Play()
	task.delay(0.3, function()
		if visible then
			ShopKit.shine(built)
		end
	end)
end

function BossOfferController.start()
	Remotes.get("BossOffer").OnClientEvent:Connect(function(offer)
		if type(offer) ~= "table" or type(offer.productKey) ~= "string" then
			return
		end
		show(offer)
	end)

	-- A purchase landing while the card is up should close it: the player has
	-- what it was selling, and leaving it up reads as "it did not work".
	--
	-- Detected from the SIZE of the jump, not from the prompt closing. Treadmill
	-- training pushes speedPower several times a second, so anything less strict
	-- would dismiss the card the moment the player stepped on a treadmill. A
	-- grant is at least 150,000 - orders of magnitude past any single tick.
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" or type(state.speedPower) ~= "number" then
			return
		end
		local previous = lastSpeedPower
		lastSpeedPower = state.speedPower
		if not visible or not previous or not offeredAmount then
			return
		end
		if state.speedPower - previous >= offeredAmount * 0.9 then
			local built = card
			if built then
				ShopKit.shine(built)
				UIAnim.punch(built, 0.2)
			end
			currentKey = nil
			offeredAmount = nil
			task.delay(0.8, hide)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(0.5)
			if visible and os.clock() >= dismissAt then
				hide()
			end
		end
	end)
end

return BossOfferController
