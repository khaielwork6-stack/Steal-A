--!strict
--[[
	GadgetStoreController
	The lobby GADGETS stand, client side (round3-gameplay).

	THE PANEL. Holding "Shop" on the stand's GadgetStorePrompt opens a small
	Gadgets window, built the way the Trail Shop's is: the pack's Shop panel
	cloned into a layer that mirrors `Frames`, emptied, retitled, and filled
	with three ShopKit cards. Each card shows the gadget, "have n/max" and the
	server's Cash price (FULL at the limit), painted by the same function as
	the Shop panel's GADGETS section (GadgetShopController.cardFor). BUY sends
	GadgetRequest("buy", key): the server prices and validates it. The window
	closes on its X, on walking away from the stand, on respawn, or when a
	pack panel opens.

	THE DISPLAYS. The three gadget models on the counter turn slowly
	(GadgetConfig.STORE_SPIN_SPEED) with a small bob, locally, as a function
	of time from the origin the server stamped (`SpinOrigin`), so nothing
	drifts. Held still under Reduced Effects and Low Graphics, and not
	animated when far from the camera.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local GadgetShopController = require(script.Parent.GadgetShopController)
local UIStateController = require(script.Parent.UIStateController)

local GadgetStoreController = {}

local player = Players.LocalPlayer

local STORE_NAME = "GadgetStore"
local PROMPT_NAME = "GadgetStorePrompt"
local CLAIM = "gadgetstore"
local NO_ASSET = "rbxassetid://0"
local PANEL_REST_SCALE = 0.92
local PANEL_CLOSE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
--- Walking further than this from the prompt closes the window.
local CLOSE_DISTANCE = 20
local CARD_ASPECT = 2
local ROW_GAP = 8
local ANIMATE_DISTANCE = 220
local BOB = 0.25

local panel: Frame? = nil
local cards: { [string]: Frame } = {}
local shown: { [string]: string } = {}
local shownCount: { [string]: number } = {}
local refitCells: (() -> ())? = nil
local panelTween: Tween? = nil
local open = false
local openedAt: BasePart? = nil
local latest: any = nil

-- ==========================================================
-- PANEL
-- ==========================================================

local function close()
	if not open then
		return
	end
	open = false
	openedAt = nil
	UIStateController.release(CLAIM)
	local frame = panel
	if not frame then
		return
	end
	local scale = frame:FindFirstChildOfClass("UIScale")
	if not scale then
		frame.Visible = false
		return
	end
	if panelTween then
		panelTween:Cancel()
	end
	local tween = TweenService:Create(scale, PANEL_CLOSE, { Scale = PANEL_REST_SCALE })
	panelTween = tween
	tween.Completed:Once(function()
		if panelTween ~= tween then
			return
		end
		panelTween = nil
		if not open and frame.Parent then
			frame.Visible = false
		end
	end)
	tween:Play()
end

--- The window: the pack's Shop panel, cloned from its pristine StarterGui copy
--- (see TrailShopController.build for why), emptied and retitled.
local function build(): boolean
	if panel then
		return true
	end
	local ui = ShopKit.mainUi()
	local frames = ui and ui:FindFirstChild("Frames")
	local shop = frames and frames:FindFirstChild("Shop")
	if not ui or not frames or not frames:IsA("GuiObject") or not shop or not shop:IsA("Frame") then
		return false
	end
	ShopKit.warm()

	local layer = ui:FindFirstChild("GadgetStoreLayer")
	if not layer then
		local made = Instance.new("Frame")
		made.Name = "GadgetStoreLayer"
		made.BackgroundTransparency = 1
		made.Size = frames.Size
		made.Position = frames.Position
		made.AnchorPoint = frames.AnchorPoint
		made.ZIndex = 10
		local ratio = frames:FindFirstChildOfClass("UIAspectRatioConstraint")
		if ratio then
			ratio:Clone().Parent = made
		end
		made.Parent = ui
		layer = made
	end

	local clone = shop:Clone()
	clone.Name = "GadgetStore"
	clone.Visible = false
	local pristine = StarterGui:FindFirstChild("MainUI")
	local pristineFrames = pristine and pristine:FindFirstChild("Frames")
	local pristineShop = pristineFrames and pristineFrames:FindFirstChild("Shop")
	if pristineShop and pristineShop:IsA("Frame") then
		clone.Position = pristineShop.Position
		clone.AnchorPoint = pristineShop.AnchorPoint
		clone.Size = pristineShop.Size
		clone.BackgroundTransparency = pristineShop.BackgroundTransparency
	end
	-- Touch: the same growth the Trail Shop gets, so BUY stays >= 44px.
	if Device.isTouch() then
		clone.AnchorPoint = Vector2.new(0.5, 0.5)
		clone.Position = UDim2.fromScale(0.5, 0.52)
		clone.Size = UDim2.fromScale(0.94, 0.9)
		for _, label in clone:GetDescendants() do
			if (label:IsA("TextLabel") or label:IsA("TextButton")) and label.TextScaled and not label:FindFirstChildOfClass("UITextSizeConstraint") then
				local limit = Instance.new("UITextSizeConstraint")
				limit.MaxTextSize = 26
				limit.Parent = label
			end
		end
	end
	-- Outside `Frames`, so the pack never tries to manage it.
	clone.Parent = layer

	local scroller = clone:FindFirstChild("ScrollingFrame")
	if not scroller or not scroller:IsA("ScrollingFrame") then
		clone:Destroy()
		return false
	end
	for _, child in scroller:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.CanvasSize = UDim2.fromScale(0, 0)
	scroller.ScrollBarThickness = 6

	local top = clone:FindFirstChild("Top")
	local topFrame = top and top:FindFirstChild("Frame")
	local title = topFrame and topFrame:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = "Gadgets"
	end
	local closeButton = (topFrame and topFrame:FindFirstChild("Close")) or (top and top:FindFirstChild("Close"))
	if closeButton and closeButton:IsA("TextButton") then
		UIAnim.claimButton(closeButton)
		closeButton.Activated:Connect(close)
	end

	local holder = Instance.new("Frame")
	holder.Name = "GadgetGrid"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 100)
	holder.Parent = scroller
	local inset = Instance.new("UIPadding")
	inset.PaddingTop = UDim.new(0, 8)
	inset.Parent = holder
	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.new(0.02, 0, 0, ROW_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = holder

	local function fitCells()
		local width = scroller.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local cellWidth = width * 0.47
		local cellHeight = cellWidth / CARD_ASPECT
		layout.CellSize = UDim2.fromOffset(cellWidth, cellHeight)
		local rows = math.ceil(#GadgetConfig.Order / 2)
		holder.Size = UDim2.new(1, 0, 0, 8 + rows * cellHeight + (rows - 1) * ROW_GAP + 8)
	end
	fitCells()
	scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitCells)
	refitCells = fitCells

	for index, key in GadgetConfig.Order do
		local def = GadgetConfig.Gadgets[key]
		local card = ShopKit.card()
		if not card then
			continue
		end
		card.Name = `StoreGadget_{key}`
		card.LayoutOrder = index
		card.Parent = holder
		local options = (GadgetShopController.cardFor(key, nil))
		options.icon = if def.icon ~= NO_ASSET then def.icon else ShopKit.Icons.Shop
		ShopKit.fillCard(card, options)
		ShopKit.bindBuy(card, function()
			UIAnim.punch(card, 0.14)
			Remotes.get("GadgetRequest"):FireServer("buy", key)
		end)
		cards[key] = card
	end

	panel = clone
	return true
end

local function refresh()
	if not latest then
		return
	end
	for key, card in cards do
		local options, have, signature = GadgetShopController.cardFor(key, latest)
		if shown[key] == signature then
			continue
		end
		local before = shownCount[key]
		shown[key] = signature
		shownCount[key] = have
		ShopKit.fillCard(card, options)
		if before ~= nil and have > before then
			ShopKit.shine(card)
			UIAnim.punch(card, 0.2)
		end
	end
end

local function show(anchor: BasePart?)
	if not build() then
		return
	end
	local frame = panel :: Frame
	openedAt = anchor
	if open and frame.Visible then
		return
	end
	open = true
	refresh()
	if refitCells then
		refitCells()
	end
	-- One window at a time, exactly like the Trail Shop.
	local closeAll = _G.CloseAllUIFrames
	if type(closeAll) == "function" then
		pcall(closeAll)
	end
	local layer = frame.Parent
	if layer and layer:IsA("GuiObject") then
		layer.Visible = true
	end
	UIStateController.claim(CLAIM)
	frame.Visible = true
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	if panelTween then
		panelTween:Cancel()
	end
	scale.Scale = PANEL_REST_SCALE
	local pop = TweenService:Create(scale, UIAnim.POP, { Scale = 1 })
	panelTween = pop
	pop.Completed:Once(function()
		if panelTween == pop then
			panelTween = nil
		end
	end)
	pop:Play()
	local list: { GuiObject } = {}
	for _, key in GadgetConfig.Order do
		local card = cards[key]
		if card then
			table.insert(list, card)
		end
	end
	ShopKit.cascadeIn(list, 0.03)
end

--- Studio / tests (DebugCommands can't reach the client; kept for parity
--- with the other shops and for a console check).
function GadgetStoreController.isOpen(): boolean
	return open
end

-- ==========================================================
-- DISPLAYS
-- ==========================================================

type Spinner = { model: Model, origin: CFrame, phase: number }
local spinners: { Spinner } = {}
local resting = false

local function collect(store: Instance)
	table.clear(spinners)
	resting = false
	local index = 0
	for _, child in store:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("GadgetDisplay") ~= nil then
			local origin = child:GetAttribute("SpinOrigin")
			index += 1
			table.insert(spinners, {
				model = child,
				origin = if typeof(origin) == "CFrame" then origin else child:GetPivot(),
				phase = index * 2.1,
			})
		end
	end
end

local function watchStore()
	local map = workspace:WaitForChild("Map", 60)
	if not map then
		return
	end
	local function consider(child: Instance)
		if child.Name == STORE_NAME and child:IsA("Model") then
			-- The displays are parented with the stall; give streaming a beat.
			task.delay(1, collect, child)
		end
	end
	local existing = map:FindFirstChild(STORE_NAME)
	if existing then
		consider(existing)
	end
	map.ChildAdded:Connect(consider)
end

local function stepSpin()
	if #spinners == 0 then
		return
	end
	local still = Effects.isReduced() or Effects.isLowGraphics() or GadgetConfig.STORE_SPIN_SPEED <= 0
	if still then
		if not resting then
			resting = true
			for _, spinner in spinners do
				if spinner.model.Parent then
					spinner.model:PivotTo(spinner.origin)
				end
			end
		end
		return
	end
	resting = false
	local camera = workspace.CurrentCamera
	local first = spinners[1].origin.Position
	if camera and (first - camera.CFrame.Position).Magnitude > ANIMATE_DISTANCE then
		return
	end
	local now = os.clock()
	local turn = math.rad(GadgetConfig.STORE_SPIN_SPEED) * now
	for _, spinner in spinners do
		if spinner.model.Parent then
			local base = spinner.origin
			spinner.model:PivotTo(
				CFrame.new(base.Position + Vector3.new(0, math.sin(now * 1.4 + spinner.phase) * BOB, 0))
					* CFrame.Angles(0, turn + spinner.phase, 0)
					* base.Rotation
			)
		end
	end
end

-- ==========================================================
-- START
-- ==========================================================

function GadgetStoreController.start()
	build()

	ProximityPromptService.PromptTriggered:Connect(function(prompt, who)
		if who ~= player or prompt.Name ~= PROMPT_NAME then
			return
		end
		local anchor = prompt.Parent
		show(if anchor and anchor:IsA("BasePart") then anchor else nil)
	end)

	-- A pack panel opening on top closes this one.
	local ui = ShopKit.mainUi()
	local frames = ui and ui:FindFirstChild("Frames")
	if frames then
		local function watch(frame: Instance)
			if frame:IsA("GuiObject") then
				frame:GetPropertyChangedSignal("Visible"):Connect(function()
					if frame.Visible and open then
						close()
					end
				end)
			end
		end
		for _, frame in frames:GetChildren() do
			watch(frame)
		end
		frames.ChildAdded:Connect(watch)
	end

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		if type(state) ~= "table" then
			return
		end
		latest = state.gadgets
		if open then
			refresh()
		end
	end)

	player.CharacterAdded:Connect(close)

	-- Walking away closes the window (checked a few times a second).
	task.spawn(function()
		while true do
			task.wait(0.3)
			local anchor = openedAt
			if open and anchor then
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if not anchor.Parent or (root and root:IsA("BasePart") and (root.Position - anchor.Position).Magnitude > CLOSE_DISTANCE) then
					close()
				end
			end
		end
	end)

	task.spawn(watchStore)
	RunService.Heartbeat:Connect(stepSpin)
end

return GadgetStoreController
