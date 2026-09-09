--!strict
--[[
	OfflineEarningsController
	The "OFFLINE EARNINGS" modal.

	Shown once per session, the first time StatePush carries a positive
	`offlineCash` (OfflineService banks it when the profile loads). The client
	renders the number the server sent and can only ASK to claim it; the
	server pays what it holds, zeroes it and pushes, and the modal closes on
	that push. A double-click, a spammed remote or a rejoin finds nothing to
	pay, so nothing here needs to guard the money - only the animation.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local OfflineEarningsController = {}

local player = Players.LocalPlayer

local PANEL = Color3.fromRGB(16, 22, 44)
local FACE_TOP = Color3.fromRGB(44, 58, 104)
local FACE_BOTTOM = Color3.fromRGB(24, 32, 64)
local TITLE = Color3.fromRGB(255, 226, 120)
local BODY = Color3.fromRGB(230, 236, 250)
local CASH = Color3.fromRGB(110, 240, 130)
local CLAIM_TOP = Color3.fromRGB(96, 240, 150)
local CLAIM_BOTTOM = Color3.fromRGB(28, 190, 110)
local CLAIM_PLATE = Color3.fromRGB(22, 120, 70)

local CASH_ICON = "rbxassetid://112931960147028"

local gui: ScreenGui? = nil
local dim: Frame? = nil
local panel: Frame? = nil
local amountLabel: TextLabel? = nil
local claimButton: TextButton? = nil
local shine: Frame? = nil

local shownAmount = 0
local open = false
local claiming = false
local sessionShown = false
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
-- BUILD
-- ==========================================================

local function text(parent: Instance, name: string, color: Color3, max: number, bold: boolean): TextLabel
	local item = Instance.new("TextLabel")
	item.Name = name
	item.BackgroundTransparency = 1
	item.Font = if bold then Enum.Font.FredokaOne else Enum.Font.GothamBold
	item.TextColor3 = color
	item.TextScaled = true
	item.TextStrokeTransparency = 0.6
	item.TextStrokeColor3 = Color3.fromRGB(8, 12, 28)
	item.ZIndex = 6
	item.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 12
	limit.MaxTextSize = max
	limit.Parent = item
	return item
end

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
	backdrop.Parent = screen
	dim = backdrop

	local card = Instance.new("Frame")
	card.Name = "Panel"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(420, 300)
	card.BackgroundColor3 = PANEL
	card.BorderSizePixel = 0
	card.ZIndex = 3
	card.Parent = screen
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(420, 300)
	sizeLimit.MinSize = Vector2.new(260, 190)
	sizeLimit.Parent = card
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = card
	local edge = Instance.new("UIStroke")
	edge.Thickness = 3
	edge.Color = Color3.fromRGB(0, 0, 0)
	edge.Parent = card
	panel = card

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.new(1, -8, 1, -8)
	face.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	face.BorderSizePixel = 0
	face.ZIndex = 4
	face.Parent = card
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, 15)
	faceCorner.Parent = face
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(FACE_TOP, FACE_BOTTOM)
	gradient.Parent = face
	local studs = Instance.new("ImageLabel")
	studs.Name = "Studs"
	studs.BackgroundTransparency = 1
	studs.Image = "rbxassetid://76728843491214"
	studs.ImageTransparency = 0.84
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(28, 28)
	studs.Size = UDim2.fromScale(1, 1)
	studs.ZIndex = 4
	studs.Parent = face
	local studsCorner = Instance.new("UICorner")
	studsCorner.CornerRadius = UDim.new(0, 15)
	studsCorner.Parent = studs

	local title = text(face, "Title", TITLE, 34, true)
	title.Text = "OFFLINE EARNINGS"
	title.Position = UDim2.fromScale(0.5, 0.15)
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Size = UDim2.fromScale(0.9, 0.16)

	local body = text(face, "Body", BODY, 18, false)
	body.Text = "This is how much you earned offline:"
	body.Position = UDim2.fromScale(0.5, 0.31)
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Size = UDim2.fromScale(0.9, 0.1)

	local row = Instance.new("Frame")
	row.Name = "AmountRow"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.52)
	row.Size = UDim2.fromScale(0.86, 0.24)
	row.ZIndex = 5
	row.Parent = face
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.Padding = UDim.new(0, 10)
	rowLayout.Parent = row

	local cashIcon = Instance.new("ImageLabel")
	cashIcon.Name = "Icon"
	cashIcon.BackgroundTransparency = 1
	cashIcon.Image = CASH_ICON
	cashIcon.Size = UDim2.fromScale(0.9, 0.9)
	cashIcon.LayoutOrder = 1
	cashIcon.ZIndex = 6
	cashIcon.Parent = row
	local iconRatio = Instance.new("UIAspectRatioConstraint")
	iconRatio.AspectRatio = 1
	iconRatio.Parent = cashIcon

	local amount = text(row, "Amount", CASH, 48, true)
	amount.Text = "$0"
	amount.Size = UDim2.fromScale(0.7, 1)
	amount.LayoutOrder = 2
	amount.TextXAlignment = Enum.TextXAlignment.Left
	amount.TextStrokeTransparency = 0.15
	amountLabel = amount

	local claim = Instance.new("TextButton")
	claim.Name = "Claim"
	claim.AnchorPoint = Vector2.new(0.5, 0.5)
	claim.Position = UDim2.fromScale(0.5, 0.8)
	claim.Size = UDim2.fromScale(0.62, 0.2)
	claim.BackgroundColor3 = CLAIM_PLATE
	claim.BorderSizePixel = 0
	claim.Text = ""
	claim.AutoButtonColor = false
	claim.ClipsDescendants = true
	claim.ZIndex = 6
	claim.Parent = face
	local claimCorner = Instance.new("UICorner")
	claimCorner.CornerRadius = UDim.new(0, 14)
	claimCorner.Parent = claim
	local claimEdge = Instance.new("UIStroke")
	claimEdge.Thickness = 2.5
	claimEdge.Color = Color3.fromRGB(0, 0, 0)
	claimEdge.Parent = claim
	local claimFace = Instance.new("Frame")
	claimFace.Name = "Face"
	claimFace.AnchorPoint = Vector2.new(0.5, 0.5)
	claimFace.Position = UDim2.fromScale(0.5, 0.5)
	claimFace.Size = UDim2.new(1, -6, 1, -6)
	claimFace.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	claimFace.BorderSizePixel = 0
	claimFace.ZIndex = 7
	claimFace.Parent = claim
	local claimFaceCorner = Instance.new("UICorner")
	claimFaceCorner.CornerRadius = UDim.new(0, 11)
	claimFaceCorner.Parent = claimFace
	local claimGradient = Instance.new("UIGradient")
	claimGradient.Rotation = 90
	claimGradient.Color = ColorSequence.new(CLAIM_TOP, CLAIM_BOTTOM)
	claimGradient.Parent = claimFace
	local claimText = text(claimFace, "Label", Color3.fromRGB(255, 255, 255), 30, true)
	claimText.Text = "CLAIM"
	claimText.AnchorPoint = Vector2.new(0.5, 0.5)
	claimText.Position = UDim2.fromScale(0.5, 0.5)
	claimText.Size = UDim2.fromScale(0.8, 0.7)
	claimText.TextStrokeTransparency = 0.2
	claimText.ZIndex = 9

	-- A diagonal sheen that sweeps across the button now and then.
	local sheen = Instance.new("Frame")
	sheen.Name = "Shine"
	sheen.AnchorPoint = Vector2.new(0.5, 0.5)
	sheen.Position = UDim2.fromScale(-0.3, 0.5)
	sheen.Size = UDim2.fromScale(0.18, 1.6)
	sheen.Rotation = 20
	sheen.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	sheen.BackgroundTransparency = 0.7
	sheen.BorderSizePixel = 0
	sheen.ZIndex = 8
	sheen.Parent = claimFace
	shine = sheen

	claimButton = claim
	UIAnim.claimButton(claim)
end

-- ==========================================================
-- OPEN / CLOSE
-- ==========================================================

local shineToken = 0

local function runShine()
	shineToken += 1
	local mine = shineToken
	task.spawn(function()
		while open and mine == shineToken and shine do
			shine.Position = UDim2.fromScale(-0.3, 0.5)
			local sweep = TweenService:Create(shine, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
				Position = UDim2.fromScale(1.3, 0.5),
			})
			sweep:Play()
			sweep.Completed:Wait()
			-- A pulse between sweeps, on the button's own scale.
			if claimButton and open and mine == shineToken then
				UIAnim.punch(claimButton, 0.05)
			end
			task.wait(2.2)
		end
	end)
end

local function close(success: boolean)
	if not open then
		return
	end
	open = false
	shineToken += 1
	cancelTweens()
	local screen, backdrop, card = gui, dim, panel
	if not screen or not backdrop or not card then
		return
	end
	if success and claimButton then
		UIAnim.punch(claimButton, 0.2)
	end
	local scale = UIAnim.scaleOf(card)
	if scale then
		track(TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0.7 }))
	end
	track(TweenService:Create(backdrop, UIAnim.FADE, { BackgroundTransparency = 1 }))
	task.delay(0.24, function()
		if not open then
			screen.Enabled = false
			if scale then
				scale.Scale = 1
			end
		end
	end)
end

local function show(amount: number)
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

	-- Phones get a smaller card so it never crowds the safe area.
	local limit = card:FindFirstChildOfClass("UISizeConstraint")
	if limit then
		limit.MaxSize = if Device.isPhone() then Vector2.new(340, 236) else Vector2.new(420, 300)
	end
	card.Size = UDim2.fromOffset(limit and limit.MaxSize.X or 420, limit and limit.MaxSize.Y or 300)

	screen.Enabled = true
	backdrop.BackgroundTransparency = 1
	track(TweenService:Create(backdrop, UIAnim.FADE, { BackgroundTransparency = 0.45 }))

	local scale = UIAnim.scaleOf(card)
	if scale then
		scale.Scale = 0.6
		track(TweenService:Create(scale, TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }))
	end

	label.Text = "$0"
	-- countTo snaps on a label it has never counted; seed it at zero so the
	-- first reveal is the count-up.
	label:SetAttribute("_CountValue", 0)
	shownAmount = amount
	task.delay(0.18, function()
		if open and shownAmount == amount then
			UIAnim.countTo(label, amount, NumberFormat.cash, 0.9)
		end
	end)
	runShine()
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
			Remotes.get("OfflineClaimRequest"):FireServer()
			-- If the server never answers (a dropped packet), let them try
			-- again rather than leaving a dead button.
			task.delay(2.5, function()
				claiming = false
			end)
		end)
	end

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		local pending = tonumber(state.offlineCash) or 0
		if pending > 0 then
			-- Only the first positive push opens the modal; a later push with
			-- the same amount (an income tick) must not re-run the entrance.
			if not sessionShown and not open then
				sessionShown = true
				show(pending)
			elseif open and pending ~= shownAmount and amountLabel then
				shownAmount = pending
				UIAnim.countTo(amountLabel, pending, NumberFormat.cash, 0.4)
			end
		elseif open then
			-- Paid. The claim landed on the server and the balance moved.
			close(true)
		end
	end)
end

return OfflineEarningsController
