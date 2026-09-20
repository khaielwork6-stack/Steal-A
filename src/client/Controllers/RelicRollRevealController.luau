--!strict
--[[
	RelicRollRevealController
	[relic-roll] The full-screen reveal after a Museum Relics purchase: ONE
	roulette PER ROLL (a 10x purchase plays ten, back to back), each a strip of
	item cards scrolling right-to-left past a fixed centre selector - fast at
	the start, decelerating smoothly, settling exactly on that roll's result -
	then the item name + [Rarity] under the strip before the next roll starts.

	IT CANNOT TRIGGER ITSELF. The only thing that starts this is
	`state.relicRoll.pendingReveal` (RelicRollService's durable replay
	record) - a live purchase pushes it the instant the receipt lands, and a
	client that missed that (offline, mid-rejoin) gets the exact same payload
	on its next join, because the record is durable until every roll is acked.
	Either way this controller reacts to STATE, never to a one-shot remote, so
	a missed push can never lose the reveal.

	ONE QUEUE, ONE REVEAL. `queue` holds payloads; `pump` plays them strictly
	one at a time (a second purchase mid-reveal waits its turn), every
	purchaseId is remembered in `seen` so the repeated pushes that carry the
	same record never restart it, and the whole thing runs in a pcall so a bug
	can never leave the queue stuck, a Sound behind, or the HUD hidden.

	THE LOOT IS ALREADY IN STORAGE by the time this plays - the belt is pure
	theatre over a result the server committed. What the client adds is the
	per-roll ack `RelicRollAck(purchaseId, rollIndex)`: the SERVER then marks
	THAT roll's item held (so it appears in the hotbar only once its roll has
	landed - the hotbar can never spoil a result). "Skip all" acks index 0
	(hold everything not yet acked). Skipping loses nothing.

	THE BELT IS DRIVEN BY HAND, not by a Tween: every RenderStepped frame the
	position is computed from the clock (ease-out), applied to the belt, and
	the tick sound is decided from that SAME real position - so picture and
	sound cannot drift, and the tick pitch follows the belt's actual speed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local RelicRollConfig = require(ReplicatedStorage.Shared.Config.RelicRollConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local StateStore = require(script.Parent.Parent.StateStore)
local UIStateController = require(script.Parent.UIStateController)

local RelicRollRevealController = {}

local player = Players.LocalPlayer

local CLAIM = "relicroll"
-- Above MainUI and every panel, below the flyover / tutorial film.
local DISPLAY_ORDER = 600
-- The belt starts with this card (1-based) centred on the selector.
local START_INDEX = 4
-- Decoy cards after the winner so the strip never visibly ends.
local BELT_TAIL = 5

type RolledItem = { itemId: string, rarity: string, mutation: string?, scale: number?, income: number, overflow: boolean?, instanceId: string? }
type Roll = { index: number, item: RolledItem }
type Payload = { purchaseId: string, total: number, rolls: { Roll } }

local seen: { [string]: boolean } = {}
local queue: { Payload } = {}
local pumping = false

-- ==========================================================
-- SMALL HELPERS
-- ==========================================================

local function nameOf(itemId: string): string
	local def = LootConfig.ById[itemId]
	return if def then def.name else itemId
end

local function rarityColor(rarity: string): Color3
	return RarityConfig.Colors[rarity] or Color3.fromRGB(255, 255, 255)
end

--- A cosmetic filler card: uniform over the six banner items (the server
--- rolls the real weighted result; the belt's other cards are only dressing,
--- and a uniform pick shows more variety than the 39%-common weighted one).
local function fillerItem(): (string, string)
	local tiers = RelicRollConfig.Tiers
	local tier = tiers[math.random(1, #tiers)]
	local def = LootConfig.ById[tier.itemId]
	return tier.itemId, if def then def.rarity else "Common"
end

-- ==========================================================
-- CARD WIDGET
-- ==========================================================

local function buildCard(parent: Instance, itemId: string, rarity: string, layoutX: number, cardW: number): Frame
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0, 0.5)
	card.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
	card.Position = UDim2.new(0, layoutX, 0.5, 0)
	card.Size = UDim2.fromOffset(cardW, cardW * 1.25)
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

local function burstConfetti(parent: Instance, originY: number)
	if Effects.isReduced() then
		return
	end
	for _ = 1, 26 do
		local piece = Instance.new("Frame")
		piece.BackgroundColor3 = CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)]
		piece.Size = UDim2.fromOffset(math.random(6, 10), math.random(10, 16))
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = UDim2.fromScale(0.5, originY)
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
			{ Position = UDim2.fromScale(0.5, originY) + UDim2.fromOffset(dx, dy), Rotation = piece.Rotation + spin, BackgroundTransparency = 1 }
		)
		tween:Play()
		tween.Completed:Once(function()
			piece:Destroy()
		end)
	end
end

-- ==========================================================
-- THE TICK POOL
-- ==========================================================

--- TICK_POOL_SIZE pre-created Sounds, played round-robin so a fast run of ticks
--- overlaps instead of cutting itself off. Owned by the reveal that made it:
--- `destroy` runs on every exit path.
local function buildTickPool(parent: Instance): { play: (rate: number) -> (), destroy: () -> () }
	local sounds: { Sound } = {}
	for _ = 1, RelicRollConfig.TICK_POOL_SIZE do
		local sound = Audio.create("RelicTick")
		if sound then
			sound.Parent = parent
			table.insert(sounds, sound)
		end
	end
	local cursor = 0
	local pool = {}
	function pool.play(rate: number)
		if #sounds == 0 then
			return
		end
		cursor = cursor % #sounds + 1
		local sound = sounds[cursor]
		sound.PlaybackSpeed = rate
		sound.TimePosition = 0
		sound:Play()
	end
	function pool.destroy()
		for _, sound in sounds do
			sound:Stop()
			sound:Destroy()
		end
		table.clear(sounds)
	end
	return pool
end

-- ==========================================================
-- THE REVEAL (one purchase)
-- ==========================================================

--- Plays every roll of `payload`. Yields until the reveal is over. Returns
--- true when it ran, false when there was no PlayerGui to draw into.
local function playReveal(payload: Payload): boolean
	local gui = player:WaitForChild("PlayerGui", 10)
	if not gui then
		return false
	end

	-- 1. NOTHING ELSE ON SCREEN. Whatever panel the purchase came from (the
	-- Shop) closes through the MainUI script's own path - slide-down, blur
	-- off, HUD restored - and the HUD is then held hidden for the reveal.
	local closeAll = (_G :: any).CloseAllUIFrames
	if type(closeAll) == "function" then
		pcall(closeAll)
	end
	UIStateController.claim(CLAIM)

	local screen = Instance.new("ScreenGui")
	screen.Name = "RelicRollReveal"
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = DISPLAY_ORDER
	screen.Parent = gui

	local tickPool = buildTickPool(screen)

	local acked: { [number]: boolean } = {}
	local skippedAll = false

	local function ack(rollIndex: number)
		Remotes.get("RelicRollAck"):FireServer(payload.purchaseId, rollIndex)
	end

	local function body()
		-- ---------- sizes from the real viewport (portrait and landscape) ----------
		local size = screen.AbsoluteSize
		if size.X < 100 or size.Y < 100 then
			local camera = workspace.CurrentCamera
			size = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		end
		local trackW = math.clamp(size.X * 0.94, 300, 900)
		local cardW = math.floor(math.clamp(math.min(trackW / 5.5, size.Y * 0.27), 52, 128))
		local gap = math.max(6, math.floor(cardW * 0.09))
		local pitch = cardW + gap
		local cardH = cardW * 1.25
		local trackH = cardH + 12
		local trackCenterY = size.Y * 0.46
		local selectorX = trackW / 2

		local shade = Instance.new("TextButton")
		shade.Name = "Shade"
		shade.Text = ""
		shade.AutoButtonColor = false
		shade.Size = UDim2.fromScale(1, 1)
		shade.BackgroundColor3 = Color3.new(0, 0, 0)
		shade.BackgroundTransparency = 1
		shade.ZIndex = 1
		shade.Parent = screen
		TweenService:Create(shade, TweenInfo.new(0.2), { BackgroundTransparency = 0.12 }):Play()

		local title = Instance.new("TextLabel")
		title.Name = "PackTitle"
		title.BackgroundTransparency = 1
		title.AnchorPoint = Vector2.new(0.5, 0)
		title.Position = UDim2.new(0.5, 0, 0, math.max(16, trackCenterY - trackH / 2 - 96))
		title.Size = UDim2.new(1, -40, 0, math.clamp(size.Y * 0.07, 28, 46))
		title.Font = Enum.Font.FredokaOne
		title.TextScaled = true
		title.TextColor3 = Color3.fromRGB(255, 214, 96)
		title.TextStrokeColor3 = Color3.fromRGB(30, 20, 6)
		title.TextStrokeTransparency = 0
		title.Text = "Relic Pack!"
		title.ZIndex = 2
		title.Parent = screen

		local counter = Instance.new("TextLabel")
		counter.Name = "RollCounter"
		counter.BackgroundTransparency = 1
		counter.AnchorPoint = Vector2.new(0.5, 0)
		counter.Position = UDim2.new(0.5, 0, 0, title.Position.Y.Offset + title.Size.Y.Offset + 4)
		counter.Size = UDim2.new(1, -40, 0, 24)
		counter.Font = Enum.Font.GothamBold
		counter.TextScaled = true
		counter.TextColor3 = Color3.fromRGB(230, 230, 240)
		counter.Text = ""
		counter.Visible = payload.total > 1
		counter.ZIndex = 2
		counter.Parent = screen

		local hint = Instance.new("TextLabel")
		hint.Name = "SkipHint"
		hint.BackgroundTransparency = 1
		hint.AnchorPoint = Vector2.new(0.5, 1)
		hint.Position = UDim2.new(0.5, 0, 1, -24)
		hint.Size = UDim2.new(1, -40, 0, 24)
		hint.Font = Enum.Font.Gotham
		hint.TextSize = 16
		hint.TextTransparency = 0.25
		hint.TextColor3 = Color3.fromRGB(255, 255, 255)
		hint.Text = "Tap to skip"
		hint.ZIndex = 2
		hint.Parent = screen

		local skipAllButton = Instance.new("TextButton")
		skipAllButton.Name = "SkipAll"
		skipAllButton.AnchorPoint = Vector2.new(1, 1)
		skipAllButton.Position = UDim2.new(1, -16, 1, -16)
		skipAllButton.Size = UDim2.fromOffset(112, 44)
		skipAllButton.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
		skipAllButton.BackgroundTransparency = 0.1
		skipAllButton.AutoButtonColor = false
		skipAllButton.Font = Enum.Font.GothamBold
		skipAllButton.TextSize = 16
		skipAllButton.TextColor3 = Color3.fromRGB(235, 235, 245)
		skipAllButton.Text = "Skip all"
		skipAllButton.Visible = payload.total > 1
		skipAllButton.ZIndex = 10
		skipAllButton.Parent = screen
		local skipCorner = Instance.new("UICorner")
		skipCorner.CornerRadius = UDim.new(0, 10)
		skipCorner.Parent = skipAllButton
		UIAnim.bindButton(skipAllButton)

		local track = Instance.new("Frame")
		track.Name = "Track"
		track.AnchorPoint = Vector2.new(0.5, 0.5)
		track.Position = UDim2.new(0.5, 0, 0, trackCenterY)
		track.Size = UDim2.fromOffset(trackW, trackH)
		track.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
		track.BackgroundTransparency = 0.15
		track.ClipsDescendants = true
		track.ZIndex = 2
		track.Parent = screen
		local trackCorner = Instance.new("UICorner")
		trackCorner.CornerRadius = UDim.new(0, 12)
		trackCorner.Parent = track

		local belt = Instance.new("Frame")
		belt.Name = "Belt"
		belt.BackgroundTransparency = 1
		belt.Size = UDim2.new(0, 0, 1, 0)
		belt.Parent = track

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

		local wonLabel = Instance.new("TextLabel")
		wonLabel.Name = "WonLabel"
		wonLabel.BackgroundTransparency = 1
		wonLabel.AnchorPoint = Vector2.new(0.5, 0)
		wonLabel.Position = UDim2.new(0.5, 0, 0, trackCenterY + trackH / 2 + 14)
		wonLabel.Size = UDim2.new(1, -40, 0, math.clamp(size.Y * 0.075, 30, 46))
		wonLabel.Font = Enum.Font.FredokaOne
		wonLabel.TextScaled = true
		wonLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		wonLabel.TextStrokeTransparency = 0.5
		wonLabel.Text = ""
		wonLabel.Visible = false
		wonLabel.ZIndex = 2
		wonLabel.Parent = screen

		-- ---------- input ----------
		local phase = "spinning" -- "spinning" | "landed"
		local skipRoll = false
		local advance = false
		shade.Activated:Connect(function()
			if phase == "spinning" then
				skipRoll = true
			else
				advance = true
			end
		end)
		skipAllButton.Activated:Connect(function()
			skippedAll = true
		end)

		-- ---------- the belt (persistent; only a few cards are swapped per roll) ----------
		local reduced = Effects.isReduced()
		local travel = if reduced then math.min(RelicRollConfig.TRAVEL_CARDS, 12) else RelicRollConfig.TRAVEL_CARDS
		local duration = if reduced then RelicRollConfig.REDUCED_ROLL_SECONDS else RelicRollConfig.ROLL_SECONDS
		local power = RelicRollConfig.EASE_POWER
		local vPeak = power * travel / duration
		local winnerIndex = START_INDEX + travel
		local cardCount = winnerIndex + BELT_TAIL
		belt.Size = UDim2.new(0, cardCount * pitch, 1, 0)

		local cards: { Frame } = {}
		local function placeCard(index: number, itemId: string, rarity: string)
			local old = cards[index]
			if old then
				old:Destroy()
			end
			cards[index] = buildCard(belt, itemId, rarity, (index - 1) * pitch, cardW)
		end
		for index = 1, cardCount do
			local itemId, rarity = fillerItem()
			placeCard(index, itemId, rarity)
		end

		local function beltX(pos: number): number
			return selectorX - (START_INDEX - 0.5) * pitch - pos * pitch
		end

		local function tickRate(speed: number): number
			local frac = math.clamp(speed / vPeak, 0, 1)
			return RelicRollConfig.TICK_RATE_MIN + (RelicRollConfig.TICK_RATE_MAX - RelicRollConfig.TICK_RATE_MIN) * frac ^ RelicRollConfig.TICK_RATE_CURVE
		end

		-- ---------- one roll ----------
		for order, roll in payload.rolls do
			if skippedAll then
				break
			end
			local item = roll.item
			phase = "spinning"
			skipRoll = false
			advance = false
			wonLabel.Visible = false
			hint.Text = "Tap to skip"
			counter.Text = `Roll {roll.index} / {payload.total}`

			-- Refresh the winner and a handful of fillers (cheap: ~11 cards, not
			-- 40) so consecutive rolls do not scroll the identical strip.
			placeCard(winnerIndex, item.itemId, item.rarity)
			for _ = 1, 10 do
				local at = math.random(1, winnerIndex - 1)
				local itemId, rarity = fillerItem()
				placeCard(at, itemId, rarity)
			end
			belt.Position = UDim2.fromOffset(beltX(0), 0)
			if order == 1 then
				task.wait(0.2) -- let the shade fade and the first frame draw
			end

			local startClock = os.clock()
			local pos = 0
			local tickIndex = 0 -- boundaries already ticked: crossing k + 0.5 => k + 1
			local lastTickClock = -1
			local speed = 0
			local lastPos = 0
			local lastClock = startClock
			local landed = false
			while not landed do
				RunService.RenderStepped:Wait()
				if skippedAll or not screen.Parent then
					break
				end
				local now = os.clock()
				local u = math.min((now - startClock) / duration, 1)
				if skipRoll then
					u = 1
				end
				pos = travel * (1 - (1 - u) ^ power)
				belt.Position = UDim2.fromOffset(beltX(pos), 0)

				if skipRoll then
					-- A skip jumps straight to the result: no burst of ticks.
					tickIndex = travel
				else
					local dt = math.max(now - lastClock, 1 / 240)
					speed = speed * 0.5 + (math.abs(pos - lastPos) / dt) * 0.5
					lastPos, lastClock = pos, now
					local crossed = math.floor(pos + 0.5)
					if crossed > tickIndex then
						tickIndex = crossed
						-- A tick this soon after the last is only skippable
						-- away from the end: the final TICK_PROTECT_CARDS
						-- cards each get heard.
						local protected = travel - pos <= RelicRollConfig.TICK_PROTECT_CARDS + 0.5
						if protected or now - lastTickClock >= RelicRollConfig.TICK_MIN_GAP then
							lastTickClock = now
							tickPool.play(tickRate(speed))
						end
					end
				end
				landed = u >= 1
			end
			if skippedAll or not screen.Parent then
				break
			end

			-- ---------- the landing ----------
			belt.Position = UDim2.fromOffset(beltX(travel), 0)
			phase = "landed"
			hint.Text = "Tap to continue"
			local winnerCard = cards[winnerIndex]
			Audio.play("RelicWin")
			if not reduced then
				UIAnim.punch(winnerCard, 0.3)
				local scale = winnerCard:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
				scale.Parent = winnerCard
				TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.18 }):Play()
			end
			wonLabel.Text = `{nameOf(item.itemId)}  [{item.rarity}]`
			wonLabel.TextColor3 = rarityColor(item.rarity)
			wonLabel.Visible = true
			burstConfetti(screen, trackCenterY / size.Y)

			-- This roll has now been SHOWN: the server may hold its item.
			if not acked[roll.index] then
				acked[roll.index] = true
				ack(roll.index)
			end

			local deadline = os.clock() + RelicRollConfig.LANDING_HOLD_SECONDS
			while os.clock() < deadline and not advance and not skippedAll and screen.Parent do
				task.wait(0.03)
			end
		end

		if skippedAll then
			-- Grant everything now: index 0 = every roll not yet acked.
			ack(0)
		end
	end

	local ok: boolean, err: any = (pcall :: any)(body)
	if not ok then
		warn(`[RelicRollRevealController] reveal failed: {err}`)
		-- Never strand the purchase: hold whatever was not shown yet.
		if not skippedAll then
			ack(0)
		end
	end

	-- EVERY exit path lands here: no Sound, no GUI, no HUD claim left behind.
	tickPool.destroy()
	screen:Destroy()
	UIStateController.release(CLAIM)
	return true
end

-- ==========================================================
-- THE QUEUE
-- ==========================================================

local function pump()
	if pumping then
		return
	end
	pumping = true
	task.spawn(function()
		while #queue > 0 do
			local payload = table.remove(queue, 1) :: Payload
			local ok, ran = pcall(playReveal, payload)
			if not ok then
				warn(`[RelicRollRevealController] {ran}`)
			elseif ran == false then
				-- No PlayerGui yet: let the next state push offer it again.
				seen[payload.purchaseId] = nil
			end
		end
		pumping = false
	end)
end

--- Turns a state record into a payload of the rolls still to show, or nil.
local function payloadFrom(pending: { [string]: any }): Payload?
	local purchaseId = tostring(pending.purchaseId or "")
	if purchaseId == "" or seen[purchaseId] then
		return nil
	end
	local items = pending.items
	if type(items) ~= "table" or #items == 0 then
		return nil
	end
	local ackedSet: { [number]: boolean } = {}
	if type(pending.acked) == "table" then
		for _, index in pending.acked do
			if type(index) == "number" then
				ackedSet[index] = true
			end
		end
	end
	local rolls: { Roll } = {}
	for index, item in items do
		if not ackedSet[index] and type(item) == "table" and type(item.itemId) == "string" then
			table.insert(rolls, { index = index, item = item :: RolledItem })
		end
	end
	if #rolls == 0 then
		return nil
	end
	return { purchaseId = purchaseId, total = #items, rolls = rolls }
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
		local payload = payloadFrom(pending)
		if not payload then
			return
		end
		seen[payload.purchaseId] = true
		table.insert(queue, payload)
		pump()
	end)
end

return RelicRollRevealController
