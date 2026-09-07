--!strict
--[[
	BaseSignController
	The UPGRADE BASE sign's green bar IS the button, and it is green or red for
	YOU depending on whether you can afford the next level.

	HOW THE CLICK WORKS
	The sign is a SurfaceGui the server builds once per plot; its "Button" is a
	plain Frame painted with the price. This controller lays a SurfaceGui of its
	own in PlayerGui, adorned to the same Board, carrying one INVISIBLE
	TextButton sized and positioned to exactly the bar's region - so the tap
	target is the visible green button and nothing else, and it works on
	desktop, touch and gamepad through Activated. A PlayerGui SurfaceGui with an
	Adornee is the one form of in-world button whose input is guaranteed.

	Pressing it sends `BaseUpgradeRequest`, empty. The SERVER decides: it owns
	the plot lookup, the price, the balance and the atomic spend, and answers
	with a toast on refusal. The old Hold-E prompt is gone; this is the only
	way to buy, so the two can never race.

	WHY THE COLOUR IS CLIENT-SIDE
	Whether YOU can afford it is a fact about you, not the sign - two players at
	the same plot would see two colours - so it is painted per-client from your
	own StatePush, which already carries Cash and the next cost. Only your own
	sign: a visitor has nothing to buy there.

	FEEDBACK
	Hover: a short brighten and a 3% lift on the bar. Press: 0.96 compression,
	rebound, and the request goes out immediately - it never waits on the
	tween. Refused (red): a small sideways shake and the denied cue. A local
	0.6s lock stops a double-tap sending two requests; the server's rate limit
	and atomic spend stand behind it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseSignController = {}

local player = Players.LocalPlayer

local GREEN = Color3.fromRGB(58, 200, 96)
local GREEN_BRIGHT = Color3.fromRGB(96, 240, 130)
local GREEN_EDGE = Color3.fromRGB(24, 120, 52)
local RED = Color3.fromRGB(232, 58, 62)
local RED_EDGE = Color3.fromRGB(150, 26, 32)

--- The hit area is THE WHOLE SIGN. Matching the visible bar exactly (0.9 x 0.35
--- of the face) left most of what looks like a button dead; a tap anywhere on
--- the board buys, and the painted bar still animates as the thing pressed.
local BAR_POSITION = UDim2.fromScale(0, 0)
local BAR_SIZE = UDim2.fromScale(1, 1)

local HOVER = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS = TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local REBOUND = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICK_LOCK = 0.6

local cash = 0
local nextCost: number? = nil
local affordable: boolean? = nil
local pulse: RBXScriptConnection? = nil

local clickGui: SurfaceGui? = nil
local clickButton: TextButton? = nil
local boundBoard: BasePart? = nil
local barScale: UIScale? = nil
local hovering = false
local pressed = false
local lockedUntil = 0

-- ==========================================================
-- RESOLUTION
-- ==========================================================

local function ownPlot(): Instance?
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return nil
	end
	for _, plot in bases:GetChildren() do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			return plot
		end
	end
	return nil
end

--- The owner's own sign: its board, and the painted bar (edge + button).
local function ownSign(): (BasePart?, Frame?, Frame?)
	local plot = ownPlot()
	local sign = plot and plot:FindFirstChild("UpgradeSign")
	local board = sign and sign:FindFirstChild("Board")
	local gui = board and board:FindFirstChildOfClass("SurfaceGui")
	local edge = gui and gui:FindFirstChild("ButtonEdge")
	local button = edge and edge:FindFirstChild("Button")
	if board and board:IsA("BasePart") and edge and edge:IsA("Frame") and button and button:IsA("Frame") then
		return board, edge, button
	end
	return nil, nil, nil
end

-- ==========================================================
-- COLOUR
-- ==========================================================

local function stopPulse()
	if pulse then
		pulse:Disconnect()
		pulse = nil
	end
end

--- Green breathes very slightly - inviting, not alarming. Red is flat.
local function startPulse(edge: Frame, button: Frame)
	stopPulse()
	local start = os.clock()
	pulse = RunService.Heartbeat:Connect(function()
		if not button.Parent then
			stopPulse()
			return
		end
		-- Hover holds the bright end; otherwise breathe between the two.
		local wave = if hovering then 1 else (math.sin((os.clock() - start) * 2.4) + 1) / 2 * 0.6
		button.BackgroundColor3 = GREEN:Lerp(GREEN_BRIGHT, wave)
		edge.BackgroundColor3 = GREEN_EDGE
	end)
end

local function paint()
	local _, edge, button = ownSign()
	if not edge or not button then
		return
	end
	local canAfford = nextCost ~= nil and cash >= (nextCost :: number)
	if canAfford == affordable then
		return
	end
	affordable = canAfford

	if canAfford then
		startPulse(edge, button)
	else
		stopPulse()
		-- MAX is painted by the server in its own colour; only a real, priced
		-- upgrade gets the red "not yet".
		if nextCost ~= nil then
			button.BackgroundColor3 = RED
			edge.BackgroundColor3 = RED_EDGE
		end
	end
end

-- ==========================================================
-- FEEDBACK
-- ==========================================================

local function setBarScale(target: number, info: TweenInfo)
	local scale = barScale
	if scale then
		TweenService:Create(scale, info, { Scale = target }):Play()
	end
end

--- A tiny sideways shake on the bar plus the denied cue: the physical "no" for
--- a press the player could not afford. The server has already declined and
--- sent its toast.
local function denied()
	local _, edge = ownSign()
	if not edge then
		return
	end
	Audio.play("UiDenied")
	local origin = edge.Position
	local shake = TweenInfo.new(0.045, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 3, true)
	TweenService:Create(edge, shake, { Position = origin + UDim2.fromScale(0.012, 0) }):Play()
	task.delay(0.045 * 8, function()
		if edge.Parent then
			edge.Position = origin
		end
	end)
end

local function onActivated()
	local now = os.clock()
	if now < lockedUntil then
		return
	end
	lockedUntil = now + CLICK_LOCK

	if affordable == false then
		denied()
		-- Still ask: the server's answer is the truth, and its toast says why.
	else
		Audio.play("UiClick")
	end
	-- Fire FIRST, animate after. The purchase never waits on a tween.
	Remotes.get("BaseUpgradeRequest"):FireServer()
end

-- ==========================================================
-- THE CLICK LAYER
-- ==========================================================

--- (Re)builds the invisible button over the owner's bar. Idempotent per board:
--- a rebuild of the plot (new Board instance) gets a fresh layer, the same
--- board never gets two.
local function ensureClickLayer()
	local board, edge = ownSign()
	if not board or not edge then
		return
	end
	if boundBoard == board and clickGui and clickGui.Parent then
		return
	end
	if clickGui then
		clickGui:Destroy()
		clickGui = nil
		clickButton = nil
	end
	boundBoard = board
	-- A new board means a freshly painted sign: repaint it whatever we last knew.
	affordable = nil

	-- The bar itself gets a UIScale so hover/press can lift the PAINTED button
	-- (what the player sees) rather than an invisible rectangle.
	local scale = edge:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = edge
	end
	barScale = scale

	local gui = Instance.new("SurfaceGui")
	gui.Name = "UpgradeSignClick"
	gui.Adornee = board
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.AlwaysOnTop = false
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local button = Instance.new("TextButton")
	button.Name = "Upgrade"
	button.Position = BAR_POSITION
	button.Size = BAR_SIZE
	button.BackgroundTransparency = 1
	button.TextTransparency = 1
	button.Text = ""
	button.AutoButtonColor = false
	button.Active = true
	button.Parent = gui

	button.MouseEnter:Connect(function()
		hovering = true
		if not pressed then
			setBarScale(1.03, HOVER)
		end
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		if not pressed then
			setBarScale(1, HOVER)
		end
	end)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressed = true
			setBarScale(0.96, PRESS)
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressed = false
			setBarScale(if hovering and not UserInputService.TouchEnabled then 1.03 else 1, REBOUND)
		end
	end)
	button.Activated:Connect(onActivated)

	clickGui = gui
	clickButton = button
end

-- ==========================================================
-- START
-- ==========================================================

function BaseSignController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		cash = tonumber(state.cash) or 0
		local cost = tonumber(state.slotsNextCost)
		-- A new upgrade tier means a new price; force a repaint. Only THEN: this
		-- used to reset on every push, which restarted the green bar's breathing
		-- loop from phase zero once a second and made it visibly stutter.
		if cost ~= nextCost then
			affordable = nil
		end
		nextCost = cost
		ensureClickLayer()
		paint()
	end)

	-- The sign is built by the server after the plot is assigned, which can be
	-- after the first push. Bind and repaint when it appears or is rebuilt.
	local map = workspace:WaitForChild("Map", 20)
	if map then
		map.DescendantAdded:Connect(function(descendant)
			if descendant.Name == "UpgradeSign" then
				task.defer(function()
					affordable = nil
					ensureClickLayer()
					paint()
				end)
			end
		end)
	end
end

return BaseSignController
