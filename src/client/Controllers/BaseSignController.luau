--!strict
--[[
	BaseSignController
	The UPGRADE BASE sign's purchase bar is GREEN when you can afford the next
	level and RED when you cannot, live, as your Cash moves.

	WHY THIS IS CLIENT-SIDE
	The sign is a SurfaceGui the server builds once per plot. Whether YOU can
	afford it is a fact about you, not about the sign - two players looking at
	the same plot could see two different colours - so the recolour is done on
	each client against its own StatePush, which already carries both the Cash
	and the next upgrade's cost. The server keeps deciding the purchase; a client
	that paints the bar green early still gets refused and told why.

	It touches ONLY the owner's own sign. Other players' signs stay the server's
	authored red, because there is nothing for a visitor to buy there.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseSignController = {}

local player = Players.LocalPlayer

local GREEN = Color3.fromRGB(58, 200, 96)
local GREEN_EDGE = Color3.fromRGB(24, 120, 52)
local RED = Color3.fromRGB(232, 58, 62)
local RED_EDGE = Color3.fromRGB(150, 26, 32)

local cash = 0
local nextCost: number? = nil
local affordable: boolean? = nil
local pulse: RBXScriptConnection? = nil

--- The owner's own sign face, or nil until the plot and sign exist.
local function ownSignFace(): (Frame?, Frame?)
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return nil, nil
	end
	for _, plot in bases:GetChildren() do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			local sign = plot:FindFirstChild("UpgradeSign")
			local board = sign and sign:FindFirstChild("Board")
			local gui = board and board:FindFirstChildOfClass("SurfaceGui")
			local edge = gui and gui:FindFirstChild("ButtonEdge")
			local button = edge and edge:FindFirstChild("Button")
			if edge and edge:IsA("Frame") and button and button:IsA("Frame") then
				return edge, button
			end
			return nil, nil
		end
	end
	return nil, nil
end

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
		local wave = (math.sin((os.clock() - start) * 2.4) + 1) / 2
		button.BackgroundColor3 = GREEN:Lerp(Color3.fromRGB(96, 240, 130), wave * 0.6)
		edge.BackgroundColor3 = GREEN_EDGE
	end)
end

local function paint()
	local edge, button = ownSignFace()
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

--- A tiny sideways shake on the bar when a refused upgrade is attempted, plus
--- the denied cue. The server has already declined and sent its toast; this is
--- the physical "no".
local function denied()
	local edge = ownSignFace()
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

function BaseSignController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		cash = tonumber(state.cash) or 0
		nextCost = tonumber(state.slotsNextCost)
		-- A new upgrade tier means a new price; force a repaint.
		affordable = nil
		paint()
	end)

	-- The sign is built by the server after the plot is assigned, which can be
	-- after the first push. Repaint when it appears.
	local map = workspace:WaitForChild("Map", 20)
	if map then
		map.DescendantAdded:Connect(function(descendant)
			if descendant.Name == "UpgradeSign" then
				task.defer(function()
					affordable = nil
					paint()
				end)
			end
		end)
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt.Name == "UpgradePrompt" and affordable == false then
			denied()
		end
	end)
end

return BaseSignController
