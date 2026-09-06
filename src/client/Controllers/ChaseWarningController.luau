--!strict
--[[
	ChaseWarningController
	The RUN!! warning: red corners pulse and "RUN!!" punches in, about once a
	second, for exactly as long as a guardian is on you and you are holding loot.

	TWO CONDITIONS, BOTH REQUIRED
	  1. `Player.Chased` attribute is true - set by GuardianService the moment a
	     guardian takes this player as its target, cleared the moment it lets go
	     (catch, escape, drop, leaving). The server owns that flag; the client
	     never infers a chase from distance or from the guardian's animation.
	  2. `StatePush.carrying` is non-nil - the player still has the item.
	Either going false stops the effect on the next frame and tears it down
	cleanly. There is no timer that can outlive the chase.

	WHY IT IS A VIGNETTE AND NOT A RED SCREEN
	Four edge gradients that fade from red at the border to nothing well before
	the centre. The middle of the screen - where the player is steering - stays
	completely clear. It reads as danger closing in, not as a filter over play.

	ONE LOOP, OWNED HERE
	A single RenderStepped connection exists only while the warning is live and
	is disconnected when it ends; the pulse is a phase on a clock rather than a
	chain of task.delays, so it cannot pile up or drift.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local ChaseWarningController = {}

local player = Players.LocalPlayer

--- Seconds per pulse. The brief asks for roughly once a second.
local PERIOD = 1.0
--- How much of the screen edge the red reaches into before it has fully faded.
local EDGE_DEPTH = 0.22
--- Peak transparency of the red at the very edge (0 = solid). Kept off solid so
--- the world is still visible through the border.
local PEAK_TRANSPARENCY = 0.18

local RED = Color3.fromRGB(255, 30, 30)

local gui: ScreenGui? = nil
local edges: { Frame } = {}
local runLabel: TextLabel? = nil
local runScale: UIScale? = nil
local loop: RBXScriptConnection? = nil
local phaseStart = 0
local lastBeat = -1

local chased = false
local carrying = false

-- ==========================================================
-- BUILD
-- ==========================================================

--- One edge of the vignette: a full-length strip whose gradient runs from red
--- at the screen border to fully transparent at EDGE_DEPTH.
local function edge(parent: Instance, name: string, size: UDim2, position: UDim2, anchor: Vector2, rotation: number): Frame
	local strip = Instance.new("Frame")
	strip.Name = name
	strip.Size = size
	strip.Position = position
	strip.AnchorPoint = anchor
	strip.BackgroundColor3 = RED
	strip.BackgroundTransparency = 1
	strip.BorderSizePixel = 0
	strip.ZIndex = 30
	strip.Parent = parent

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.55, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = strip
	return strip
end

local function build()
	if gui then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "ChaseWarning"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 40
	screen.Enabled = false
	screen.Parent = playerGui

	-- Gradient rotation 0 runs left->right; each strip is rotated so its red end
	-- is the screen border.
	table.insert(edges, edge(screen, "Left", UDim2.fromScale(EDGE_DEPTH, 1), UDim2.fromScale(0, 0), Vector2.new(0, 0), 0))
	table.insert(edges, edge(screen, "Right", UDim2.fromScale(EDGE_DEPTH, 1), UDim2.fromScale(1, 0), Vector2.new(1, 0), 180))
	table.insert(edges, edge(screen, "Top", UDim2.fromScale(1, EDGE_DEPTH), UDim2.fromScale(0, 0), Vector2.new(0, 0), 90))
	table.insert(edges, edge(screen, "Bottom", UDim2.fromScale(1, EDGE_DEPTH), UDim2.fromScale(0, 1), Vector2.new(0, 1), 270))

	-- RUN!! in the pack's voice: the same heavy face and black outline the HUD
	-- titles use, red so it belongs to the warning and not to a notification.
	local label = Instance.new("TextLabel")
	label.Name = "Run"
	label.Size = UDim2.fromScale(0.5, 0.14)
	label.Position = UDim2.fromScale(0.5, 0.24)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = "RUN!!"
	label.TextColor3 = Color3.fromRGB(255, 70, 70)
	label.TextStrokeColor3 = Color3.fromRGB(40, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextTransparency = 1
	label.ZIndex = 31
	label.Parent = screen

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(40, 0, 0)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = label

	-- Legible on a phone, never a billboard on a monitor.
	local sizeLimit = Instance.new("UITextSizeConstraint")
	sizeLimit.MinTextSize = 28
	sizeLimit.MaxTextSize = 96
	sizeLimit.Parent = label

	gui = screen
	runLabel = label
	runScale = scale
end

-- ==========================================================
-- PULSE
-- ==========================================================

--- One beat: the edges flash to peak and the label punches in; both then ease
--- out over the rest of the period. Called once per PERIOD from the loop.
local function beat()
	for _, strip in edges do
		strip.BackgroundTransparency = PEAK_TRANSPARENCY
		TweenService:Create(
			strip,
			TweenInfo.new(PERIOD * 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		):Play()
	end

	local label = runLabel
	local scale = runScale
	if label and scale then
		label.TextTransparency = 0
		label.TextStrokeTransparency = 0
		scale.Scale = 0.72
		TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.08 }):Play()
		TweenService:Create(
			label,
			TweenInfo.new(PERIOD * 0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1, TextStrokeTransparency = 1 }
		):Play()
	end
end

local function stop()
	if loop then
		loop:Disconnect()
		loop = nil
	end
	local screen = gui
	if not screen then
		return
	end
	-- Fade whatever is mid-pulse rather than cutting it, then switch off.
	for _, strip in edges do
		TweenService:Create(strip, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
	end
	local label = runLabel
	if label then
		TweenService:Create(label, TweenInfo.new(0.2), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end
	task.delay(0.22, function()
		if not loop and screen.Parent then
			screen.Enabled = false
		end
	end)
end

local function start()
	if loop then
		return
	end
	build()
	local screen = gui :: ScreenGui
	screen.Enabled = true
	phaseStart = os.clock()
	lastBeat = -1
	loop = RunService.RenderStepped:Connect(function()
		local index = math.floor((os.clock() - phaseStart) / PERIOD)
		if index ~= lastBeat then
			lastBeat = index
			beat()
		end
	end)
end

local function evaluate()
	if chased and carrying then
		start()
	else
		stop()
	end
end

-- ==========================================================
-- START
-- ==========================================================

function ChaseWarningController.start()
	chased = player:GetAttribute("Chased") == true
	player:GetAttributeChangedSignal("Chased"):Connect(function()
		chased = player:GetAttribute("Chased") == true
		evaluate()
	end)

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		local now = state.carrying ~= nil
		if now ~= carrying then
			carrying = now
			evaluate()
		end
	end)

	-- A respawn ends any chase on the server too, but the flag can lag a frame;
	-- stopping here means the warning never shows over a spawn screen.
	player.CharacterAdded:Connect(function()
		carrying = false
		evaluate()
	end)
end

return ChaseWarningController
