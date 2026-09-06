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
	banner is re-texted and re-punched; a second one is never spawned.

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
local card: GuiObject? = nil
local currentKey: string? = nil
local offeredAmount: number? = nil
local lastSpeedPower: number? = nil
local visible = false

-- MEASURED OFF THE REFERENCE SHOT, not chosen by eye: a 290x75 pill on a
-- 1918x1008 screen, centred horizontally with its middle 62px down. That is a
-- banner across the top of the screen, not a card in the middle of it - which is
-- the point. It has to read at a glance during a chase and be out of the way the
-- moment it is ignored.
--
-- The reference's 0.062 is TAKEN in this game: the zone progress bar spans
-- y -48..13 and the banner landed on -43..11, directly across it. Dropped to sit
-- just underneath, keeping the proportions and the top-centre placement while
-- leaving both readable.
-- AT THE TOP. The zone-progress bar that used to occupy this slot is retired, so
-- the banner takes the top-centre with clean padding under the Roblox topbar
-- (MainUI ignores the inset, so 0.085 of the screen clears it on every device).
-- The RUN!! warning shares this exact slot; the two hand off, never overlap.
local SHOWN_POSITION = UDim2.new(0.5, 0, 0.085, 0)
--- Slides DOWN into place from just off the top edge.
local HIDDEN_POSITION = UDim2.new(0.5, 0, -0.08, 0)
--- 290/1918 wide, 75/1008 tall, clamped so it stays a banner on any screen.
-- LARGER than the first pass. At 213x54 the headline measured 23px and read as a
-- notification, not an offer; the reference is a big clean banner you cannot
-- miss and can still see past. Wider than the zone bar, a quarter of the
-- screen, clamped so it is never a strip on a phone or a billboard on a 4K.
local BANNER_SIZE = UDim2.fromScale(0.27, 0.115)
local BANNER_MIN = Vector2.new(320, 72)
local BANNER_MAX = Vector2.new(480, 108)
--- Seconds the banner stays before leaving on its own.
local AUTO_DISMISS = 6.5
--- Delay between the RUN!! warning fading and this sliding into the same slot:
--- long enough that they never overlap, short enough to read as one motion.
local HANDOFF_DELAY = 0.15
--- Every show() bumps this; a dismiss timer only fires if it still matches. A
--- second catch inside the window therefore restarts the clock instead of
--- leaving two timers to fight over one banner.
local showToken = 0

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
	local donor = ShopKit.card()
	if not donor then
		warn("[BossOfferController] no pack card to build from - loss offer disabled.")
		return false
	end

	-- THE PILL, NOT THE CARD.
	--
	-- The reference is a wide banner roughly four times as long as it is tall,
	-- and the pack's product CARD does not survive being squashed into that: its
	-- title strip came out under seven pixels high and its price under nine. The
	-- pack's own BUY BUTTON, though, already IS that shape - rounded, gradient,
	-- studs, rays, stroke - so the banner is built from the button and the card
	-- is kept only long enough to donate it and the icon.
	local donorBody = donor:FindFirstChild("Frame")
	local donorChoose = donorBody and donorBody:FindFirstChild("Choose")
	local pill = donorChoose and donorChoose:FindFirstChild("Buy")
	local donorIcon = donorBody and donorBody:FindFirstChild("Icon")
	if not pill or not pill:IsA("TextButton") then
		warn("[BossOfferController] pack card has no Buy button - loss offer disabled.")
		donor:Destroy()
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

	pill.Name = "Banner"
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromScale(0.5, 0.5)
	pill.Size = UDim2.fromScale(1, 1)
	-- The button is authored 3:1 for a card corner. The banner owns its own size.
	local pillAspect = pill:FindFirstChildOfClass("UIAspectRatioConstraint")
	if pillAspect then
		pillAspect:Destroy()
	end
	pill.Parent = frame

	local face = pill:FindFirstChild("Frame")
	if face then
		-- The demo sale furniture, same as everywhere else.
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
			icon.Position = UDim2.fromScale(0.015, 0.5)
			icon.Size = UDim2.fromScale(0.24, 0.92)
			icon.ZIndex = 6
			icon.Parent = face
		end

		-- The pack's price label becomes the headline, moved out of the icon's
		-- way and left-aligned so "+150K SPEED" reads as a statement rather than
		-- as a centred price tag.
		local headline = face:FindFirstChild("Price")
		if headline and headline:IsA("TextLabel") then
			headline.Name = "Headline"
			headline.AnchorPoint = Vector2.new(0, 0)
			headline.Position = UDim2.fromScale(0.27, 0.06)
			headline.Size = UDim2.fromScale(0.7, 0.54)
			headline.TextXAlignment = Enum.TextXAlignment.Left
			headline.ZIndex = 6

			-- The price rides underneath in the same voice, half the height, so
			-- what it costs is on the banner rather than only in Roblox's prompt.
			local cost = headline:Clone()
			cost.Name = "Cost"
			cost.Position = UDim2.fromScale(0.27, 0.62)
			cost.Size = UDim2.fromScale(0.7, 0.3)
			cost.Parent = face
		end
	end

	UIAnim.claimButton(pill)
	pill.Activated:Connect(function()
		if not currentKey then
			return
		end
		UIAnim.punch(pill, 0.16)
		-- The client names a config KEY, never a product id.
		Remotes.get("PurchaseRequest"):FireServer("product", currentKey)
	end)

	donor:Destroy()

	-- Dismiss. Borrowed from the pack's own shop header so the X matches the
	-- rest of the game rather than being a drawn cross. Sized in PIXELS: at
	-- banner scale a proportional X is too small to hit on a phone.
	local top = ShopKit.topBar()
	-- The pack nests its X as Top.Frame.Close, so this has to search rather than
	-- look one level down - a direct lookup finds nothing and the banner comes up
	-- with no way to dismiss it but the timer.
	local packClose = top and top:FindFirstChild("Close", true)
	if packClose and packClose:IsA("TextButton") then
		local close = packClose:Clone()
		close.Name = "Dismiss"
		close.AnchorPoint = Vector2.new(0.5, 0.5)
		close.Position = UDim2.fromScale(1.015, 0.02)
		close.Size = UDim2.fromOffset(26, 26)
		close.ZIndex = 20
		close.Parent = frame
		UIAnim.claimButton(close)
		close.Activated:Connect(hide)
	end
	if top then
		top:Destroy()
	end

	holder = frame
	card = pill
	return true
end

local function show(offer: any)
	if not build() then
		return
	end
	local frame = holder :: Frame
	local built = card :: GuiObject

	currentKey = offer.productKey
	offeredAmount = tonumber(offer.amount)

	-- The latest offer owns the clock. Any earlier timer wakes, sees a newer
	-- token, and does nothing.
	showToken += 1
	local token = showToken
	task.delay(AUTO_DISMISS + (if visible then 0 else HANDOFF_DELAY), function()
		if token == showToken then
			hide()
		end
	end)

	local face = built:FindFirstChild("Frame")
	if face then
		local headline = face:FindFirstChild("Headline")
		if headline and headline:IsA("TextLabel") then
			headline.Text = `+{offer.label} SPEED`
		end
		local cost = face:FindFirstChild("Cost")
		if cost and cost:IsA("TextLabel") then
			cost.Text = `R$ {NumberFormat.comma(offer.robux)}  ·  outrun the guard`
		end
		local gradient = face:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = ColorSequence.new(OFFER_COLOR, OFFER_ACCENT)
		end
		local icon = face:FindFirstChild("Icon")
		if icon then
			for _, layer in icon:GetDescendants() do
				if layer:IsA("ImageLabel") then
					layer.Image = ShopKit.Icons.Speed
				end
			end
		end
	end
	local stroke = built:FindFirstChildOfClass("UIStroke")
	if stroke then
		-- Colour only. Raising a pack stroke's authored thickness makes the engine
		-- draw the border as a filled slab; see TrailShopController.
		stroke.Color = OFFER_ACCENT
	end

	-- Already up: re-text and punch rather than stacking a second card.
	--
	-- "Up" means OUR flag AND the frame actually drawing. The pack's own script
	-- hides every visible thing in MainUI while one of its panels is open and
	-- only restores what it hid; anything else that flips Visible from outside
	-- would otherwise leave this flag true over a hidden frame, and every later
	-- offer would re-text a banner nobody can see.
	if visible and frame.Visible then
		UIAnim.punch(built, 0.18)
		ShopKit.shine(built)
		return
	end

	-- Claimed now, entered after the handoff: the RUN!! warning is fading out
	-- of this same slot, and the banner waits the one beat it takes to clear.
	-- A second offer landing inside that beat re-texts (the branch above) rather
	-- than starting a second entrance.
	visible = true
	task.delay(HANDOFF_DELAY, function()
		if token ~= showToken or not visible or not frame.Parent then
			return
		end
		frame.Visible = true
		frame.Position = HIDDEN_POSITION
		local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Parent = frame
		scale.Scale = 0.7

		TweenService:Create(frame, UIAnim.SETTLE, { Position = SHOWN_POSITION }):Play()
		-- Back easing overshoots and settles: 0.7 -> ~1.08 -> 1.0 in one tween.
		TweenService:Create(scale, UIAnim.GROW, { Scale = 1 }):Play()
		task.delay(0.3, function()
			if visible and token == showToken then
				ShopKit.shine(built)
				-- The amount itself punches once as the banner lands, so the eye
				-- goes to the number before anything else.
				local headline = built:FindFirstChild("Headline", true)
				if headline and headline:IsA("GuiObject") then
					UIAnim.punch(headline, 0.28)
				end
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

end

return BossOfferController
