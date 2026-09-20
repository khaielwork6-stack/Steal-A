--!strict
--[[
	RelicRollRevealController
	[relic-roll] The full-screen reveal after a Museum Relics purchase: a
	fast-then-decelerating belt of item cards under a fixed selector, landing
	on the best item won, then a "Successful Purchase!" dialog (with, for
	3x/10x/50x, a results grid of everything the roll won).

	IT CANNOT TRIGGER ITSELF. The only thing that starts this is
	`state.relicRoll.pendingReveal` (RelicRollService's durable replay
	record) - a live purchase pushes it the instant the receipt lands, and a
	client that missed that (offline, mid-rejoin) gets the exact same payload
	on its next join, because the record is durable until acked. Either way
	this controller reacts to STATE, never to a one-shot remote, so a missed
	push can never lose the reveal.

	THE LOOT IS ALREADY GRANTED by the time this ever plays - the belt is
	pure theatre over a result the server already committed. Skipping it
	loses nothing; RelicRollAck only ever clears the "show this again" flag.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local RelicRollConfig = require(ReplicatedStorage.Shared.Config.RelicRollConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local StateStore = require(script.Parent.Parent.StateStore)

local RelicRollRevealController = {}

local player = Players.LocalPlayer

local currentPurchaseId: string? = nil
local playing: ScreenGui? = nil

type RolledItem = { itemId: string, rarity: string, mutation: string?, scale: number?, income: number, overflow: boolean? }

-- ==========================================================
-- SMALL HELPERS
-- ==========================================================

local function rank(rarity: string): number
	return RarityConfig.rank(rarity)
end

local function bestOf(items: { RolledItem }): RolledItem
	local best = items[1]
	for _, item in items do
		if rank(item.rarity) > rank(best.rarity) then
			best = item
		end
	end
	return best
end

local function nameOf(itemId: string): string
	local def = LootConfig.ById[itemId]
	return if def then def.name else itemId
end

--- ONE weighted filler pick from the same pool the server rolls from - purely
--- cosmetic (client-side, never authoritative): the belt's other ~40 cards
--- are dressing around the one real result.
local function fillerTier(): RelicRollConfig.Tier
	return RelicRollConfig.rollTier(nil)
end

-- ==========================================================
-- CARD WIDGET
-- ==========================================================

local CARD_W = 108
local CARD_GAP = 10

local function buildCard(parent: Instance, itemId: string, rarity: string, layoutX: number): Frame
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
	card.Position = UDim2.fromOffset(layoutX, 0)
	card.Size = UDim2.fromOffset(CARD_W, CARD_W * 1.25)
	card.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = RarityConfig.Colors[rarity] or Color3.fromRGB(198, 205, 216)
	stroke.Parent = card

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.new(1, -12, 1, -34)
	icon.Position = UDim2.fromOffset(6, 6)
	icon.Parent = card
	ItemThumb.apply(icon, rarity, itemId)

	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -8, 0, 24)
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -4)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(235, 235, 240)
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = nameOf(itemId)
	label.Parent = card

	return card
end

-- ==========================================================
-- CONFETTI (Effects-aware)
-- ==========================================================

local CONFETTI_COLORS = {
	Color3.fromRGB(255, 92, 178),
	Color3.fromRGB(255, 208, 96),
	Color3.fromRGB(120, 224, 255),
	Color3.fromRGB(150, 255, 150),
}

local function burstConfetti(parent: Instance)
	if Effects.isReduced() then
		return
	end
	for _ = 1, 26 do
		local piece = Instance.new("Frame")
		piece.BackgroundColor3 = CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)]
		piece.Size = UDim2.fromOffset(math.random(6, 10), math.random(10, 16))
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = UDim2.fromScale(0.5, 0.4)
		piece.Rotation = math.random(0, 360)
		piece.BorderSizePixel = 0
		piece.ZIndex = 30
		piece.Parent = parent
		local dx = math.random(-260, 260)
		local dy = math.random(140, 380)
		local spin = math.random(-540, 540)
		local tween = TweenService:Create(
			piece,
			TweenInfo.new(math.random(9, 14) / 10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0.5, 0.4) + UDim2.fromOffset(dx, dy), Rotation = piece.Rotation + spin, BackgroundTransparency = 1 }
		)
		tween:Play()
		tween.Completed:Once(function()
			piece:Destroy()
		end)
	end
end

-- ==========================================================
-- THE ROULETTE
-- ==========================================================

local BELT_CARD_COUNT = 44
local BELT_TAIL = 4 -- decoy cards after the target, so the strip does not visibly end
local ROLL_SECONDS = 4.6

--- Runs the belt for `winner`, calling `onLanded()` once it has stopped (or
--- been skipped) on the winning card.
local function runRoulette(track: Frame, selectorX: number, winner: RolledItem, onLanded: () -> ())
	local belt = Instance.new("Frame")
	belt.Name = "Belt"
	belt.BackgroundTransparency = 1
	belt.Size = UDim2.fromOffset(BELT_CARD_COUNT * (CARD_W + CARD_GAP), CARD_W * 1.25)
	belt.Position = UDim2.fromOffset(0, 0)
	belt.Parent = track

	local targetIndex = BELT_CARD_COUNT - BELT_TAIL
	for index = 1, BELT_CARD_COUNT do
		local x = (index - 1) * (CARD_W + CARD_GAP)
		if index == targetIndex then
			buildCard(belt, winner.itemId, winner.rarity, x)
		else
			local tier = fillerTier()
			buildCard(belt, tier.itemId, (LootConfig.ById[tier.itemId] and LootConfig.ById[tier.itemId].rarity) or "Common", x)
		end
	end

	local targetCenter = (targetIndex - 0.5) * (CARD_W + CARD_GAP)
	local finalOffset = selectorX - targetCenter

	local reduced = Effects.isReduced()
	local duration = if reduced then 0.6 else ROLL_SECONDS
	local tween = TweenService:Create(belt, TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(finalOffset, 0),
	})

	local lastTickIndex = 0
	local ticking = true
	local heartbeatConn: RBXScriptConnection? = nil
	heartbeatConn = RunService.Heartbeat:Connect(function()
		if not ticking then
			return
		end
		local currentOffset = belt.Position.X.Offset
		local nearestIndex = math.clamp(math.floor((selectorX - currentOffset) / (CARD_W + CARD_GAP)) + 1, 1, BELT_CARD_COUNT)
		if nearestIndex ~= lastTickIndex then
			lastTickIndex = nearestIndex
			Audio.play("RevealCycle")
		end
	end)

	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		ticking = false
		if heartbeatConn then
			heartbeatConn:Disconnect()
		end
		belt.Position = UDim2.fromOffset(finalOffset, 0)
		local winnerCard = belt:FindFirstChildOfClass("Frame")
		for _, child in belt:GetChildren() do
			if child:IsA("Frame") and child.Position.X.Offset == (targetIndex - 1) * (CARD_W + CARD_GAP) then
				winnerCard = child
				break
			end
		end
		Audio.play("RevealPop")
		if winnerCard then
			UIAnim.punch(winnerCard, 0.3)
			local scale = winnerCard:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
			scale.Parent = winnerCard
			TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.18 }):Play()
		end
		onLanded()
	end

	tween:Play()
	tween.Completed:Once(finish)

	return finish -- exposed so a tap can skip straight to it
end

-- ==========================================================
-- THE SUCCESS DIALOG
-- ==========================================================

local function buildResultsGrid(parent: Instance, items: { RolledItem })
	-- Group by itemId, counted, best rarity first.
	local order: { string } = {}
	local counts: { [string]: number } = {}
	local rarities: { [string]: string } = {}
	for _, item in items do
		if not counts[item.itemId] then
			table.insert(order, item.itemId)
			rarities[item.itemId] = item.rarity
		end
		counts[item.itemId] = (counts[item.itemId] or 0) + 1
	end
	table.sort(order, function(a, b)
		return rank(rarities[a]) > rank(rarities[b])
	end)

	local scroller = Instance.new("ScrollingFrame")
	scroller.Name = "Results"
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.Size = UDim2.new(1, -24, 0, 190)
	scroller.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.ScrollBarThickness = 6
	scroller.Parent = parent

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(84, 106)
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroller

	for index, itemId in order do
		local rarity = rarities[itemId]
		local cell = Instance.new("Frame")
		cell.Name = `Cell_{itemId}`
		cell.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
		cell.LayoutOrder = index
		cell.Parent = scroller
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = cell
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = RarityConfig.Colors[rarity] or Color3.fromRGB(198, 205, 216)
		stroke.Parent = cell

		local icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.new(1, -10, 1, -34)
		icon.Position = UDim2.fromOffset(5, 5)
		icon.Parent = cell
		ItemThumb.apply(icon, rarity, itemId)

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.AnchorPoint = Vector2.new(0.5, 1)
		name.Position = UDim2.new(0.5, 0, 1, -4)
		name.Size = UDim2.new(1, -6, 0, 16)
		name.Font = Enum.Font.GothamBold
		name.TextScaled = true
		name.TextColor3 = Color3.fromRGB(230, 230, 235)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = nameOf(itemId)
		name.Parent = cell

		local count = counts[itemId]
		if count > 1 then
			local badge = Instance.new("TextLabel")
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.new(1, -3, 0, 3)
			badge.Size = UDim2.fromOffset(28, 18)
			badge.BackgroundColor3 = Color3.fromRGB(255, 208, 96)
			badge.Font = Enum.Font.FredokaOne
			badge.TextScaled = true
			badge.Text = `x{count}`
			badge.TextColor3 = Color3.fromRGB(40, 30, 10)
			badge.ZIndex = 3
			badge.Parent = cell
			local badgeCorner = Instance.new("UICorner")
			badgeCorner.CornerRadius = UDim.new(1, 0)
			badgeCorner.Parent = badge
		end
	end
end

local function showSuccessDialog(screen: ScreenGui, payload: { rollCount: number, items: { RolledItem } }, onClose: () -> ())
	local best = bestOf(payload.items)

	local dim = Instance.new("Frame")
	dim.Name = "DialogDim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 1
	dim.ZIndex = 10
	dim.Parent = screen
	TweenService:Create(dim, TweenInfo.new(0.2), { BackgroundTransparency = 0.4 }):Play()

	local dialog = Instance.new("Frame")
	dialog.Name = "Dialog"
	dialog.AnchorPoint = Vector2.new(0.5, 0.5)
	dialog.Position = UDim2.fromScale(0.5, 0.5)
	dialog.Size = UDim2.fromOffset(380, if payload.rollCount > 1 then 480 else 300)
	dialog.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
	dialog.ZIndex = 11
	dialog.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = dialog
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(80, 80, 96)
	stroke.Parent = dialog

	local closeX = Instance.new("TextButton")
	closeX.Name = "Close"
	closeX.AnchorPoint = Vector2.new(1, 0)
	closeX.Position = UDim2.new(1, -10, 0, 10)
	closeX.Size = UDim2.fromOffset(36, 36)
	closeX.Text = "X"
	closeX.Font = Enum.Font.FredokaOne
	closeX.TextScaled = true
	closeX.TextColor3 = Color3.fromRGB(220, 220, 230)
	closeX.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
	closeX.AutoButtonColor = false
	closeX.ZIndex = 12
	closeX.Parent = dialog
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(1, 0)
	closeCorner.Parent = closeX
	UIAnim.bindButton(closeX)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -30, 0, 30)
	title.Position = UDim2.fromOffset(15, 16)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Text = "Successful Purchase!"
	title.ZIndex = 11
	title.Parent = dialog

	local thanks = Instance.new("TextLabel")
	thanks.BackgroundTransparency = 1
	thanks.Size = UDim2.new(1, -30, 0, 22)
	thanks.Position = UDim2.fromOffset(15, 50)
	thanks.Font = Enum.Font.Gotham
	thanks.TextScaled = true
	thanks.TextColor3 = Color3.fromRGB(220, 220, 230)
	thanks.Text = "Thank you for your support! \u{2764}"
	thanks.ZIndex = 11
	thanks.Parent = dialog

	local itemName = Instance.new("TextLabel")
	itemName.BackgroundTransparency = 1
	itemName.Size = UDim2.new(1, -30, 0, 26)
	itemName.Position = UDim2.fromOffset(15, 80)
	itemName.Font = Enum.Font.GothamBold
	itemName.TextScaled = true
	itemName.TextColor3 = RarityConfig.Colors[best.rarity] or Color3.fromRGB(255, 255, 255)
	itemName.Text = if payload.rollCount > 1
		then `Best relic: {nameOf(best.itemId)} [{best.rarity}]`
		else `{nameOf(best.itemId)}  [{best.rarity}]`
	itemName.ZIndex = 11
	itemName.Parent = dialog

	if payload.rollCount > 1 then
		local grid = Instance.new("Frame")
		grid.Name = "GridHolder"
		grid.BackgroundTransparency = 1
		grid.Position = UDim2.fromOffset(12, 114)
		grid.Size = UDim2.new(1, -24, 0, 190)
		grid.ZIndex = 11
		grid.Parent = dialog
		buildResultsGrid(grid, payload.items)
	end

	local okButton = Instance.new("TextButton")
	okButton.Name = "Ok"
	okButton.AnchorPoint = Vector2.new(0.5, 1)
	okButton.Position = UDim2.new(0.5, 0, 1, -18)
	okButton.Size = UDim2.fromOffset(160, 48)
	okButton.BackgroundColor3 = Color3.fromRGB(70, 200, 96)
	okButton.Text = "Ok!"
	okButton.Font = Enum.Font.FredokaOne
	okButton.TextScaled = true
	okButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	okButton.AutoButtonColor = false
	okButton.ZIndex = 11
	okButton.Parent = dialog
	local okCorner = Instance.new("UICorner")
	okCorner.CornerRadius = UDim.new(0, 12)
	okCorner.Parent = okButton
	UIAnim.bindButton(okButton)

	local closed = false
	local function doClose()
		if closed then
			return
		end
		closed = true
		onClose()
	end
	okButton.Activated:Connect(doClose)
	closeX.Activated:Connect(doClose)

	burstConfetti(screen)
	Audio.play("CashPurchase")
end

-- ==========================================================
-- THE FULL SEQUENCE
-- ==========================================================

local function playReveal(payload: { purchaseId: string, rollCount: number, items: { RolledItem } })
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then
		return
	end
	if playing then
		playing:Destroy()
		playing = nil
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "RelicRollReveal"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 55
	screen.Parent = gui
	playing = screen

	local shade = Instance.new("TextButton")
	shade.Name = "Shade"
	shade.Text = ""
	shade.AutoButtonColor = false
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 1
	shade.ZIndex = 1
	shade.Parent = screen
	TweenService:Create(shade, TweenInfo.new(0.25), { BackgroundTransparency = 0.25 }):Play()

	local title = Instance.new("TextLabel")
	title.Name = "PackTitle"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 40)
	title.Size = UDim2.new(1, -40, 0, 46)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 214, 96)
	title.TextStrokeColor3 = Color3.fromRGB(30, 20, 6)
	title.TextStrokeTransparency = 0
	title.Text = "Relic Pack!"
	title.ZIndex = 2
	title.Parent = screen

	local skipHint = Instance.new("TextLabel")
	skipHint.Name = "SkipHint"
	skipHint.BackgroundTransparency = 1
	skipHint.AnchorPoint = Vector2.new(0.5, 1)
	skipHint.Position = UDim2.new(0.5, 0, 1, -24)
	skipHint.Size = UDim2.new(1, -40, 0, 24)
	skipHint.Font = Enum.Font.Gotham
	skipHint.TextSize = 16
	skipHint.TextTransparency = 0.25
	skipHint.TextColor3 = Color3.fromRGB(255, 255, 255)
	skipHint.Text = "Tap to skip"
	skipHint.ZIndex = 2
	skipHint.Parent = screen

	-- The track: fixed width, clips the belt, centred; a UIScale keeps card
	-- sizes sane on a phone the same way FusionController's stage does.
	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromScale(0.5, 0.48)
	stage.BackgroundTransparency = 1
	stage.Size = UDim2.fromOffset(0, 0)
	stage.ZIndex = 2
	stage.Parent = screen
	local stageScale = Instance.new("UIScale")
	local camera = workspace.CurrentCamera
	local shortEdge = if camera then math.min(camera.ViewportSize.X, camera.ViewportSize.Y) else 720
	stageScale.Scale = math.clamp(shortEdge / 700, 0.62, 1.15)
	stageScale.Parent = stage

	local TRACK_WIDTH = 700
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromOffset(0, 0)
	track.Size = UDim2.fromOffset(TRACK_WIDTH, CARD_W * 1.25 + 8)
	track.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
	track.BackgroundTransparency = 0.15
	track.ClipsDescendants = true
	track.ZIndex = 2
	track.Parent = stage
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 12)
	trackCorner.Parent = track

	-- The fixed selector: a thin vertical line with notches top and bottom.
	local selector = Instance.new("Frame")
	selector.Name = "Selector"
	selector.AnchorPoint = Vector2.new(0.5, 0)
	selector.Position = UDim2.fromScale(0.5, 0)
	selector.Size = UDim2.new(0, 3, 1, 0)
	selector.BackgroundColor3 = Color3.fromRGB(255, 214, 96)
	selector.BorderSizePixel = 0
	selector.ZIndex = 5
	selector.Parent = track
	for _, anchorY in { 0, 1 } do
		local notch = Instance.new("Frame")
		notch.AnchorPoint = Vector2.new(0.5, anchorY)
		notch.Position = UDim2.fromScale(0.5, anchorY)
		notch.Size = UDim2.fromOffset(16, 6)
		notch.BackgroundColor3 = Color3.fromRGB(255, 214, 96)
		notch.BorderSizePixel = 0
		notch.ZIndex = 5
		notch.Parent = selector
	end

	local best = bestOf(payload.items)
	local wonLabel = Instance.new("TextLabel")
	wonLabel.Name = "WonLabel"
	wonLabel.BackgroundTransparency = 1
	wonLabel.AnchorPoint = Vector2.new(0.5, 0)
	wonLabel.Position = UDim2.fromScale(0.5, 0.62)
	wonLabel.Size = UDim2.new(1, -40, 0, 60)
	wonLabel.Font = Enum.Font.FredokaOne
	wonLabel.TextScaled = true
	wonLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	wonLabel.Text = ""
	wonLabel.Visible = false
	wonLabel.ZIndex = 2
	wonLabel.Parent = screen

	local function toResults()
		title.Visible = false
		skipHint.Visible = false
		wonLabel.Visible = false
		showSuccessDialog(screen, payload, function()
			if playing then
				playing:Destroy()
				playing = nil
			end
			Remotes.get("RelicRollAck"):FireServer(payload.purchaseId)
		end)
	end

	local function onLanded()
		skipHint.Visible = false
		wonLabel.Visible = true
		wonLabel.Text = `{nameOf(best.itemId)}\n[{best.rarity}]`
		wonLabel.TextColor3 = RarityConfig.Colors[best.rarity] or Color3.fromRGB(255, 255, 255)
		task.delay(1.4, toResults)
	end

	local skipToEnd = runRoulette(track, TRACK_WIDTH / 2, best, onLanded)

	shade.Activated:Connect(function()
		skipToEnd()
	end)
end

-- ==========================================================
-- START
-- ==========================================================

function RelicRollRevealController.start()
	StateStore.subscribe(function(state)
		local relicRoll = state and state.relicRoll
		local pending = if type(relicRoll) == "table" then relicRoll.pendingReveal else nil
		if type(pending) ~= "table" then
			return
		end
		local purchaseId = tostring(pending.purchaseId or "")
		if purchaseId == "" or purchaseId == currentPurchaseId then
			return
		end
		local items = pending.items
		if type(items) ~= "table" or #items == 0 then
			return
		end
		currentPurchaseId = purchaseId
		playReveal({
			purchaseId = purchaseId,
			rollCount = tonumber(pending.rollCount) or #items,
			items = items :: { RolledItem },
		})
	end)
end

return RelicRollRevealController
