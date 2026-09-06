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
	The server cooldown is zero - every catch offers - so this is what keeps a bad
	run from burying the screen. Caught again while it is up and the EXISTING
	card is re-targeted and re-punched; a second one is never spawned.

	IT NEVER BLOCKS PLAY.
	Top-centre, no modal backdrop, an X to dismiss and an auto-dismiss behind it.
	Being caught is already frustrating; a prompt you have to fight is worse.

	THE CARD IS THE SAME PAINTED SPEED CARD THE SHOP SELLS.
	PngUiConfig `Product_<key>` supplies the art for whichever product the zone
	offers; there is exactly one price on it, so the whole card is the button
	and the printed R$ pill is what lights up. What is offered, when, at what
	price and what it grants is untouched: the server names a product KEY and
	the client asks for it through PurchaseRequest, like every other purchase.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PngCard = require(ReplicatedStorage.Shared.Util.PngCard)
local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local BossOfferController = {}

local player = Players.LocalPlayer

local holder: Frame? = nil
local png: PngCard.Card? = nil
--- Which product's art the card currently wears.
local shownKey: string? = nil
local currentKey: string? = nil
local offeredAmount: number? = nil
local lastSpeedPower: number? = nil
local visible = false

-- AT THE TOP. The zone-progress bar that used to occupy this slot is retired, so
-- the banner takes the top-centre with clean padding under the Roblox topbar
-- (MainUI ignores the inset, so 0.085 of the screen clears it on every device).
-- The RUN!! warning shares this exact slot; the two hand off, never overlap.
local SHOWN_POSITION = UDim2.new(0.5, 0, 0.085, 0)
--- Slides DOWN into place from just off the top edge.
local HIDDEN_POSITION = UDim2.new(0.5, 0, -0.08, 0)
--- The painted Speed card is a ~3:1 banner. A little under a third of the
--- screen wide, clamped so it is never a strip on a phone or a billboard on a
--- 4K; the family aspect inside PngCard keeps its shape whatever the clamp
--- lands on.
local BANNER_SIZE = UDim2.fromScale(0.30, 0.13)
local BANNER_MIN = Vector2.new(300, 100)
local BANNER_MAX = Vector2.new(480, 162)
--- Seconds the banner stays before leaving on its own.
local AUTO_DISMISS = 6.5
--- Delay between the RUN!! warning fading and this sliding into the same slot:
--- long enough that they never overlap, short enough to read as one motion.
local HANDOFF_DELAY = 0.15
--- Every show() bumps this; a dismiss timer only fires if it still matches. A
--- second catch inside the window therefore restarts the clock instead of
--- leaving two timers to fight over one banner.
local showToken = 0

--- Entrance: a touch small, scaling up with a small overshoot while it drops
--- into place and fades in. Exit: quick, no bounce.
local ENTER_SCALE = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ENTER_MOVE = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local ENTER_FADE = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LEAVE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function hide()
	if not visible then
		return
	end
	visible = false
	local frame = holder
	local built = png
	if not frame then
		return
	end
	if built then
		built.setInteractive(false)
		TweenService:Create(built.artwork, LEAVE, { ImageTransparency = 1 }):Play()
	end
	local scale = frame:FindFirstChildOfClass("UIScale")
	TweenService:Create(frame, LEAVE, { Position = HIDDEN_POSITION }):Play()
	if scale then
		local tween = TweenService:Create(scale, LEAVE, { Scale = 0.88 })
		tween:Play()
		tween.Completed:Once(function()
			if not visible and frame.Parent then
				frame.Visible = false
			end
		end)
	else
		frame.Visible = false
	end
end

local function purchase()
	if not currentKey or not visible then
		return
	end
	-- The client names a config KEY, never a product id.
	Remotes.get("PurchaseRequest"):FireServer("product", currentKey)
end

local function build(): boolean
	if holder and png then
		return true
	end
	local ui = ShopKit.mainUi()
	if not ui then
		return false
	end
	-- Built on the first Speed card's art; show() re-targets per product.
	local firstLayout = PngUiConfig.card("Product_Speed150K")
	if not firstLayout then
		warn("[BossOfferController] no painted Speed card in PngUiConfig - loss offer disabled.")
		return false
	end

	local frame = Instance.new("Frame")
	frame.Name = "BossOffer"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = HIDDEN_POSITION
	frame.Size = BANNER_SIZE
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.ZIndex = 12
	frame.Parent = ui

	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = BANNER_MIN
	limit.MaxSize = BANNER_MAX
	limit.Parent = frame

	local built = PngCard.build({
		name = "Banner",
		layout = firstLayout,
		familyAspect = PngUiConfig.Families.Speed,
		regions = { buy = {} },
		wholeCard = purchase,
	})
	built.frame.Size = UDim2.fromScale(1, 1)
	built.frame.Parent = frame
	shownKey = "Speed150K"

	-- Dismiss. Borrowed from the pack's own shop header so the X matches the
	-- rest of the game rather than being a drawn cross. Sized in PIXELS: at
	-- banner scale a proportional X is too small to hit on a phone. It rides
	-- the ART's top-right corner, so it follows the card at any size.
	local top = ShopKit.topBar()
	local packClose = top and top:FindFirstChild("Close", true)
	if packClose and packClose:IsA("TextButton") then
		local close = packClose:Clone()
		close.Name = "Dismiss"
		close.AnchorPoint = Vector2.new(0.5, 0.5)
		close.Position = UDim2.new(1, -2, 0, 2)
		close.Size = UDim2.fromOffset(26, 26)
		close.ZIndex = 20
		close.Parent = built.artwork
		UIAnim.claimButton(close)
		close.Activated:Connect(hide)
	end
	if top then
		top:Destroy()
	end

	holder = frame
	png = built
	return true
end

local function show(offer: any)
	if not build() then
		return
	end
	local frame = holder :: Frame
	local built = png :: PngCard.Card

	local layout = PngUiConfig.card(`Product_{offer.productKey}`)
	if not layout then
		warn(`[BossOfferController] no painted card for {offer.productKey}; offer not shown.`)
		return
	end

	currentKey = offer.productKey
	offeredAmount = tonumber(offer.amount)
	if shownKey ~= offer.productKey then
		built.retarget(layout)
		shownKey = offer.productKey
	end

	-- The latest offer owns the clock. Any earlier timer wakes, sees a newer
	-- token, and does nothing.
	showToken += 1
	local token = showToken
	task.delay(AUTO_DISMISS + (if visible then 0 else HANDOFF_DELAY), function()
		if token == showToken then
			hide()
		end
	end)

	-- Already up: re-punch rather than stacking a second card.
	--
	-- "Up" means OUR flag AND the frame actually drawing. The pack's own script
	-- hides every visible thing in MainUI while one of its panels is open and
	-- only restores what it hid; anything else that flips Visible from outside
	-- would otherwise leave this flag true over a hidden frame, and every later
	-- offer would re-target a banner nobody can see.
	if visible and frame.Visible then
		UIAnim.punch(built.artwork, 0.16)
		ShopKit.shine(built.artwork)
		return
	end

	-- Entered after the handoff: the RUN!! warning is fading out of this same
	-- slot, and the banner waits the one beat it takes to clear. A second
	-- offer landing inside that beat re-punches (the branch above) rather than
	-- starting a second entrance.
	visible = true
	task.delay(HANDOFF_DELAY, function()
		if token ~= showToken or not visible or not frame.Parent then
			return
		end
		built.setInteractive(true)
		frame.Visible = true
		frame.Position = HIDDEN_POSITION
		local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Parent = frame
		scale.Scale = 0.85
		built.artwork.ImageTransparency = 1

		TweenService:Create(frame, ENTER_MOVE, { Position = SHOWN_POSITION }):Play()
		-- Back easing overshoots and settles: 0.85 -> ~1.03 -> 1.0 in one tween.
		TweenService:Create(scale, ENTER_SCALE, { Scale = 1 }):Play()
		TweenService:Create(built.artwork, ENTER_FADE, { ImageTransparency = 0 }):Play()
		task.delay(0.3, function()
			if visible and token == showToken then
				ShopKit.shine(built.artwork)
			end
		end)
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
			local built = png
			if built then
				ShopKit.shine(built.artwork)
				UIAnim.punch(built.artwork, 0.2)
			end
			currentKey = nil
			offeredAmount = nil
			task.delay(0.8, hide)
		end
	end)
end

return BossOfferController
