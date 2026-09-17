--!strict
--[[
	OfflineEarningsController
	The WELCOME BACK! offline earnings reveal.

	Shown once per session, the first time StatePush carries a positive
	`offlineCash` (OfflineService banks it when the profile loads). The client
	renders the number the server sent and can only ASK to claim it; the
	server pays what it holds, zeroes it and pushes, and the popup closes on
	that push. A double-click, a spammed remote or a rejoin finds nothing to
	pay, so nothing here needs to guard the money - only the animation.

	THE LOOK (round3-ui-rewards redesign, Util/RewardFx)
	A bright blue-to-violet pack plate with a thick outline. Behind a big cash
	pile, a slow sunburst and a soft glow; above it WELCOME BACK! in gold and
	"You were away 2h 14m (max 6h)" (StatePush `offlineAway`, the capped
	seconds the server measured; the line falls back to a plain one when a
	pending amount was carried over from an earlier session). The amount
	counts up from $0; under it "at 25% of your income" is read from
	GameConfig.OFFLINE_EFFICIENCY. CLAIM carries a sheen sweep.

	THE CLAIM. When the server's push zeroes the amount: coins burst from the
	amount into the HUD cash counter (which counts up on its own), the popup's
	number drains to $0 and the card pops away. Reduced Effects: no rays, bob,
	sheen or coins; the card simply appears and fades.

	STUDIO PREVIEW. RewardsUIPreview("offline", { amount, away })
	(DebugCommands/RewardsUI) opens the popup on a fake amount; CLAIM then
	plays the moment locally and sends nothing.

	No Cash-multiplier offer is shown here: MonetizationConfig has no product
	meant for this screen, and this pass adds none.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RewardFx = require(ReplicatedStorage.Shared.Util.RewardFx)
local RewardUiConfig = require(ReplicatedStorage.Shared.Config.RewardUiConfig)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local AudioController = require(script.Parent.AudioController)

local OfflineEarningsController = {}

local player = Players.LocalPlayer

local Z = 3
local CARD_TOP = Color3.fromRGB(80, 200, 255)
local CARD_BOTTOM = Color3.fromRGB(130, 60, 235)
local WHITE = RewardFx.WHITE
local CASH = Color3.fromRGB(140, 255, 140)
local CLAIM_TOP = Color3.fromRGB(110, 250, 150)
local CLAIM_BOTTOM = Color3.fromRGB(20, 175, 90)
local CARD_MAX = Vector2.new(480, 420)
local CARD_MIN = Vector2.new(250, 218)
local CARD_ASPECT = 1.15

local gui: ScreenGui? = nil
local dim: Frame? = nil
local panel: Frame? = nil
local awayLabel: TextLabel? = nil
local rateLabel: TextLabel? = nil
local amountLabel: TextLabel? = nil
local claimButton: TextButton? = nil
local sheen: Frame? = nil
local rays: Frame? = nil
local pile: ImageLabel? = nil

local shownAmount = 0
local open = false
local claiming = false
local sessionShown = false
--- A Studio preview is on screen: the claim plays locally.
local previewing = false
local loops = RewardFx.loopSet()
--- Entrance / exit tweens (cancelled when the other one starts).
local liveTweens: { Tween } = {}

local function cancelTweens()
	for _, tween in liveTweens do
		tween:Cancel()
	end
	table.clear(liveTweens)
end

local function track(tween: Tween): Tween
	table.insert(liveTweens, tween)
	tween:Play()
	return tween
end

-- ==========================================================
-- TEXT
-- ==========================================================

local function maxHours(): number
	return math.max(1, math.floor(GameConfig.OFFLINE_EARNINGS_MAX_SECONDS / 3600 + 0.5))
end

local function awayText(seconds: number?): string
	local cap = maxHours()
	if type(seconds) ~= "number" or seconds <= 0 then
		return `While you were away you earned (max {cap}h)`
	end
	if seconds >= GameConfig.OFFLINE_EARNINGS_MAX_SECONDS then
		return `You were away {cap}h+ (max {cap}h)`
	end
	local s = math.floor(seconds)
	local hours, minutes = s // 3600, (s % 3600) // 60
	local span = if hours > 0 then `{hours}h {minutes}m` elseif minutes > 0 then `{minutes}m` else "a moment"
	return `You were away {span} (max {cap}h)`
end

local function rateText(): string
	local percent = math.floor(GameConfig.OFFLINE_EFFICIENCY * 100 + 0.5)
	return `at {percent}% of your income`
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function build()
	local playerGui = player:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "OfflineEarningsUI"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 45
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false
	screen.Parent = playerGui
	gui = screen

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Dim"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(4, 6, 14)
	backdrop.BackgroundTransparency = 1
	backdrop.BorderSizePixel = 0
	backdrop.ZIndex = 1
	backdrop.Active = true -- swallows clicks behind the popup
	backdrop.Parent = screen
	dim = backdrop

	-- The card never outgrows the screen: a scale size, an aspect lock and
	-- a pixel range.
	local holder = RewardFx.box(screen, "Panel", Z)
	RewardFx.place(holder, 0.5, 0.5, 0.82, 0.74)
	RewardFx.aspect(holder, CARD_ASPECT)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = CARD_MAX
	limit.MinSize = CARD_MIN
	limit.Parent = holder
	UIAnim.scaleOf(holder)
	panel = holder

	local plate, face = RewardFx.plate(holder, "Card", CARD_TOP, CARD_BOTTOM, Z, 22, 5)
	RewardFx.stroke(plate, 3)

	-- Behind the pile: a glow and a slow sunburst, clipped to the face.
	local art = RewardFx.box(face, "ArtClip", Z + 2)
	art.ClipsDescendants = true
	local glow = RewardFx.glow(art, "Glow", Color3.fromRGB(255, 250, 190), Z + 2, 0.15)
	RewardFx.place(glow, 0.5, 0.42, 0.7, 0.5)
	local burst = RewardFx.rays(art, "Rays", Color3.fromRGB(255, 248, 200), Z + 2, 0.4)
	RewardFx.place(burst, 0.5, 0.42, 1.1, 0.78)
	rays = burst

	local pileId = if RewardUiConfig.hasArt(RewardUiConfig.CASH_PILE_ICON) then RewardUiConfig.CASH_PILE_ICON else ShopKit.Icons.Cash
	local cashPile = RewardFx.image(face, "Pile", pileId, Z + 4)
	RewardFx.place(cashPile, 0.5, 0.42, 0.46, 0.27)
	pile = cashPile

	local title = RewardFx.label(face, "Title", "WELCOME BACK!", WHITE, 46, Z + 5)
	RewardFx.place(title, 0.5, 0.115, 0.9, 0.15)
	RewardFx.goldText(title)

	local away = RewardFx.label(face, "Away", "", WHITE, 20, Z + 5)
	RewardFx.place(away, 0.5, 0.215, 0.9, 0.065)
	awayLabel = away

	local amount = RewardFx.label(face, "Amount", "$0", CASH, 56, Z + 5)
	RewardFx.place(amount, 0.5, 0.635, 0.92, 0.15)
	local amountFill = Instance.new("UIGradient")
	amountFill.Rotation = 90
	amountFill.Color = ColorSequence.new(Color3.fromRGB(230, 255, 200), Color3.fromRGB(80, 235, 110))
	amountFill.Parent = amount
	amount.TextColor3 = WHITE
	amountLabel = amount

	local rate = RewardFx.label(face, "Rate", rateText(), Color3.fromRGB(225, 232, 255), 18, Z + 5)
	RewardFx.place(rate, 0.5, 0.728, 0.9, 0.055)
	rateLabel = rate

	local claim = Instance.new("TextButton")
	claim.Name = "Claim"
	claim.BackgroundColor3 = RewardFx.OUTLINE
	claim.BorderSizePixel = 0
	claim.Text = ""
	claim.AutoButtonColor = false
	claim.ZIndex = Z + 6
	RewardFx.place(claim, 0.5, 0.865, 0.58, 0.16)
	RewardFx.corner(claim, 16)
	RewardFx.stroke(claim, 2)
	-- A finger-sized target on any screen (this ScreenGui has no UIScale).
	local claimMin = Instance.new("UISizeConstraint")
	claimMin.MinSize = Vector2.new(150, 44)
	claimMin.Parent = claim
	claim.Parent = face

	local claimFace = Instance.new("Frame")
	claimFace.Name = "Face"
	claimFace.AnchorPoint = Vector2.new(0.5, 0.5)
	claimFace.Position = UDim2.fromScale(0.5, 0.5)
	claimFace.Size = UDim2.new(1, -6, 1, -6)
	claimFace.BackgroundColor3 = WHITE
	claimFace.BorderSizePixel = 0
	claimFace.ZIndex = Z + 7
	RewardFx.corner(claimFace, 13)
	RewardFx.gradient(claimFace, CLAIM_TOP, CLAIM_BOTTOM)
	claimFace.Parent = claim
	local gloss = Instance.new("Frame")
	gloss.Name = "Gloss"
	gloss.BackgroundColor3 = WHITE
	gloss.BackgroundTransparency = 0.72
	gloss.BorderSizePixel = 0
	gloss.Position = UDim2.fromScale(0.03, 0.08)
	gloss.Size = UDim2.fromScale(0.94, 0.36)
	gloss.ZIndex = Z + 8
	RewardFx.corner(gloss, 9)
	gloss.Parent = claimFace
	sheen = RewardFx.sheen(claimFace, Z + 8)
	local claimText = RewardFx.label(claimFace, "Label", "CLAIM", WHITE, 34, Z + 9)
	RewardFx.place(claimText, 0.5, 0.5, 0.8, 0.72)

	claimButton = claim
	UIAnim.claimButton(claim)
end

-- ==========================================================
-- LOOPS
-- ==========================================================

local function startLoops()
	loops.stop()
	if not open or Effects.isReduced() then
		return
	end
	local burst, cashPile, bar, button = rays, pile, sheen, claimButton
	if burst then
		loops.play(RewardFx.spin(burst, RewardUiConfig.RAYS_TURN_SECONDS), function()
			burst.Rotation = 0
		end)
	end
	if cashPile then
		local rest = UDim2.fromScale(0.5, 0.42)
		cashPile.Position = rest
		loops.play(RewardFx.yoyo(cashPile, 0.9, { Position = UDim2.fromScale(0.5, 0.405) }), function()
			cashPile.Position = rest
		end)
	end
	if bar and button then
		loops.every(2.2, function()
			RewardFx.sweep(bar, 0.65)
			if open then
				UIAnim.punch(button, 0.05)
			end
		end)
	end
end

-- ==========================================================
-- OPEN / CLOSE
-- ==========================================================

local function close(success: boolean)
	if not open then
		return
	end
	open = false
	previewing = false
	loops.stop()
	cancelTweens()
	local screen, backdrop, card = gui, dim, panel
	if not screen or not backdrop or not card then
		return
	end
	local scale = UIAnim.scaleOf(card)
	local reduced = Effects.isReduced()
	-- Paid: the coins leave first, then the card pops away.
	local hold = if success and not reduced then 0.55 else 0
	task.delay(hold, function()
		if open then
			return -- reopened meanwhile
		end
		if scale and not reduced then
			scale.Scale = 1
			local grow = track(TweenService:Create(scale, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1.08 }))
			grow.Completed:Once(function(state)
				if state == Enum.PlaybackState.Completed and not open then
					track(TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0 }))
				end
			end)
		end
		track(TweenService:Create(backdrop, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }))
		task.delay(if reduced then 0.3 else 0.36, function()
			if not open then
				screen.Enabled = false
				if scale then
					scale.Scale = 1
				end
			end
		end)
	end)
end

--- The paid moment: coins into the HUD, the number drains, then close.
local function payOut()
	local label = amountLabel
	if label and not Effects.isReduced() then
		RewardFx.flyToHud(RewardFx.screenCenter(label), "Cash", RewardFx.coinImage(), RewardUiConfig.COIN_COUNT + 4)
		UIAnim.countTo(label, 0, NumberFormat.cash, 0.45)
		if claimButton then
			UIAnim.punch(claimButton, 0.2)
		end
	end
	AudioController.play("RevealPop")
	close(true)
end

local function show(amount: number, away: number?)
	local screen, backdrop, card, label = gui, dim, panel, amountLabel
	if not screen or not backdrop or not card or not label then
		return
	end
	if open then
		return
	end
	open = true
	claiming = false
	cancelTweens()

	if awayLabel then
		awayLabel.Text = awayText(away)
	end
	if rateLabel then
		rateLabel.Text = rateText()
	end

	screen.Enabled = true
	backdrop.BackgroundTransparency = 1
	track(TweenService:Create(backdrop, UIAnim.FADE, { BackgroundTransparency = 0.45 }))

	local reduced = Effects.isReduced()
	local scale = UIAnim.scaleOf(card)
	if scale then
		if reduced then
			scale.Scale = 1
		else
			scale.Scale = 0.55
			track(TweenService:Create(scale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }))
		end
	end

	shownAmount = amount
	if reduced then
		label:SetAttribute("_CountValue", amount)
		label.Text = NumberFormat.cash(amount)
	else
		label.Text = "$0"
		-- countTo snaps on a label it has never counted; seed it at zero so
		-- the reveal is the count-up.
		label:SetAttribute("_CountValue", 0)
		task.delay(0.3, function()
			if open and shownAmount == amount then
				UIAnim.countTo(label, amount, NumberFormat.cash, RewardUiConfig.OFFLINE_COUNT_SECONDS)
			end
		end)
		task.delay(0.3 + RewardUiConfig.OFFLINE_COUNT_SECONDS, function()
			if open and shownAmount == amount then
				UIAnim.punch(label, 0.18)
			end
		end)
	end
	startLoops()
end

-- ==========================================================
-- START
-- ==========================================================

function OfflineEarningsController.start()
	build()

	if claimButton then
		claimButton.Activated:Connect(function()
			if not open or claiming then
				return
			end
			claiming = true
			UIAnim.punch(claimButton :: TextButton, 0.12)
			if previewing then
				-- Studio preview: nothing to ask the server for.
				payOut()
				return
			end
			Remotes.get("OfflineClaimRequest"):FireServer()
			-- If the server never answers (a dropped packet), let them try
			-- again rather than leaving a dead button.
			task.delay(2.5, function()
				claiming = false
			end)
		end)
	end

	Remotes.get("RewardsUIPreview").OnClientEvent:Connect(function(kind, payload)
		if kind ~= "offline" or type(payload) ~= "table" then
			return
		end
		local amount = tonumber(payload.amount) or 0
		if amount <= 0 then
			return
		end
		if open then
			close(false)
		end
		-- Let a closing card finish before the preview reopens it.
		task.delay(0.4, function()
			previewing = true
			show(amount, tonumber(payload.away))
		end)
	end)

	Effects.reducedChanged:Connect(function()
		startLoops()
	end)

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		if type(state) ~= "table" then
			return
		end
		local pending = tonumber(state.offlineCash) or 0
		if pending > 0 then
			-- Only the first positive push opens the popup; a later push with
			-- the same amount (an income tick) must not re-run the entrance.
			if not sessionShown and not open then
				sessionShown = true
				show(pending, tonumber(state.offlineAway))
			elseif open and not previewing and pending ~= shownAmount and amountLabel then
				shownAmount = pending
				UIAnim.countTo(amountLabel, pending, NumberFormat.cash, 0.4)
			end
		elseif open and not previewing then
			-- Paid. The claim landed on the server and the balance moved.
			payOut()
		end
	end)
end

return OfflineEarningsController
