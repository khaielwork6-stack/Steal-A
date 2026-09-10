--!strict
--[[
	GuardianShopController
	The client half of the rotating Guardian shop in the lobby.

	  * The countdown on the sign, once a second, from GetServerTimeNow and
	    the RotationEndsAt attribute the server stamps - so every player's
	    clock reads the same and nothing is replicated per second.
	  * The slow presentation turn of the animal on the pedestal (a local
	    CFrame on an anchored root; the server never moves it).
	  * The prompt's wording for THIS player: Buy, Equip, or Equipped, from
	    the ownership in StatePush. The server decides what a trigger does
	    either way; this is the label.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local GuardianShopController = {}

local player = Players.LocalPlayer

local TURN_SPEED = 0.45
local BOB = 0.12

local shop: Model? = nil
local displayRoot: BasePart? = nil
local displayBase: CFrame? = nil
local latest: any = nil

local function timerLabel(): TextLabel?
	local anchor = shop and shop:FindFirstChild("SignAnchor")
	local gui = anchor and anchor:FindFirstChild("Sign")
	local label = gui and gui:FindFirstChild("Timer")
	return if label and label:IsA("TextLabel") then label else nil
end

local function limitedLabel(): TextLabel?
	local anchor = shop and shop:FindFirstChild("SignAnchor")
	local gui = anchor and anchor:FindFirstChild("Sign")
	local label = gui and gui:FindFirstChild("Limited")
	return if label and label:IsA("TextLabel") then label else nil
end

local function prompt(): ProximityPrompt?
	local anchor = shop and shop:FindFirstChild("PromptAnchor")
	local found = anchor and anchor:FindFirstChild("GuardianBuyPrompt")
	return if found and found:IsA("ProximityPrompt") then found else nil
end

local function paintPrompt()
	local p = prompt()
	local model = shop
	if not p or not model or type(latest) ~= "table" or type(latest.guardians) ~= "table" then
		return
	end
	local key = model:GetAttribute("RotationKey")
	local guardians = latest.guardians
	if type(key) ~= "string" then
		return
	end
	local owned = guardians.owned and guardians.owned[key] == true
	if not owned then
		p.ActionText = "Buy"
	elseif guardians.equipped == key then
		p.ActionText = "Equipped"
	else
		p.ActionText = "Equip"
	end
end

local function adoptDisplay(display: Instance)
	if not display:IsA("Model") then
		return
	end
	local root = display.PrimaryPart or display:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		displayRoot = root
		displayBase = root.CFrame
	end
	paintPrompt()
end

local function pulseLimited()
	local label = limitedLabel()
	if not label then
		return
	end
	local scale = label:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = label
	TweenService:Create(scale, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.08 }):Play()
end

local function attach(model: Model)
	shop = model
	local existing = model:FindFirstChild("Display")
	if existing then
		adoptDisplay(existing)
	end
	model.ChildAdded:Connect(function(child)
		if child.Name == "Display" then
			task.defer(adoptDisplay, child)
		end
	end)
	model.ChildRemoved:Connect(function(child)
		if child.Name == "Display" then
			displayRoot = nil
			displayBase = nil
		end
	end)
	model:GetAttributeChangedSignal("RotationKey"):Connect(paintPrompt)
	pulseLimited()

	-- THE COUNTDOWN. Driven off Heartbeat and re-texted only when the SECOND
	-- it would display actually changes, rather than from a `task.wait(1)`
	-- loop.
	--
	-- `task.wait(1)` does not sleep for one second, it sleeps for at least one
	-- second, so the old loop drifted a little further behind the clock on
	-- every pass and the sign would visibly hold a value for two beats and
	-- then skip one. Sampling the real clock every frame and writing only on a
	-- change costs one comparison a frame, never drifts, and cannot skip:
	-- whatever the frame rate does, the number on the sign is the number the
	-- server time says.
	local shownSecond = -1
	RunService.Heartbeat:Connect(function()
		if not model.Parent then
			return
		end
		local label = timerLabel()
		local endsAt = tonumber(model:GetAttribute("RotationEndsAt"))
		if not label or not endsAt then
			return
		end
		local remaining = math.max(0, endsAt - workspace:GetServerTimeNow())
		local whole = math.floor(remaining)
		if whole ~= shownSecond then
			shownSecond = whole
			label.Text = `New Guardian In: {BaseGuardianConfig.formatCountdown(remaining)}`
		end
	end)
end

function GuardianShopController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) == "table" then
			latest = state
			paintPrompt()
		end
	end)

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 60)
		if not map then
			return
		end
		local found = map:WaitForChild("GuardianShop", 120)
		if found and found:IsA("Model") then
			attach(found)
		end
		map.ChildAdded:Connect(function(child)
			if child.Name == "GuardianShop" and child:IsA("Model") then
				attach(child)
			end
		end)
	end)

	-- The presentation turn: a slow yaw and a breath, local only.
	RunService.RenderStepped:Connect(function()
		local root = displayRoot
		local base = displayBase
		if not root or not base or not root.Parent then
			return
		end
		local now = os.clock()
		root.CFrame = base * CFrame.new(0, math.sin(now * 1.4) * BOB, 0) * CFrame.Angles(0, now * TURN_SPEED, 0)
	end)
end

return GuardianShopController
