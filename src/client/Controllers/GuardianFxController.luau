--!strict
--[[
	GuardianFxController
	The floating Zzz while a guardian sleeps, and the "!" pop when it wakes.

	Runs entirely on the client, driven by the guardian model's `State`
	attribute. Twelve looping effects therefore cost the server nothing and
	generate no network traffic.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GuardianFxController = {}

local SLEEP_COLOR = Color3.fromRGB(180, 226, 255)
local ALERT_COLOR = Color3.fromRGB(255, 74, 74)

--- One rising, fading "Z" / "Zz" / "Zzz" puff.
local function puff(adornee: BasePart, stage: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "ZzzPuff"
	gui.Size = UDim2.fromScale(4, 4)
	gui.StudsOffsetWorldSpace = Vector3.new(0.6, 3.4, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 320
	gui.Adornee = adornee
	gui.Parent = adornee

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = SLEEP_COLOR
	text.TextStrokeTransparency = 0.4
	text.Text = string.rep("z", stage - 1) ~= "" and ("Z" .. string.rep("z", stage - 1)) or "Z"
	text.Parent = gui

	-- Drift up and to the side while fading out.
	local rise = TweenService:Create(gui, TweenInfo.new(2.2, Enum.EasingStyle.Linear), {
		StudsOffsetWorldSpace = Vector3.new(2.4, 8.4, 0),
	})
	local fade = TweenService:Create(text, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	rise:Play()
	fade:Play()

	task.delay(2.3, function()
		gui:Destroy()
	end)
end

local function alertPop(adornee: BasePart)
	local gui = Instance.new("BillboardGui")
	gui.Name = "AlertPop"
	gui.Size = UDim2.fromScale(0.5, 0.5)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 400
	gui.Adornee = adornee
	gui.Parent = adornee

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = ALERT_COLOR
	text.TextStrokeTransparency = 0.15
	text.Text = "!"
	text.Parent = gui

	TweenService:Create(gui, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(4.5, 4.5),
	}):Play()

	task.delay(1.4, function()
		local out = TweenService:Create(text, TweenInfo.new(0.3), { TextTransparency = 1, TextStrokeTransparency = 1 })
		out:Play()
		out.Completed:Wait()
		gui:Destroy()
	end)
end

local function clearPuffs(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BillboardGui") and descendant.Name == "ZzzPuff" then
			descendant:Destroy()
		end
	end
end

local function watch(model: Model)
	-- ChildAdded can fire before the model's own children have replicated, so
	-- this must wait rather than test-and-bail.
	local root = model:WaitForChild("HumanoidRootPart", 15)
	if not root or not root:IsA("BasePart") then
		return
	end

	local stage = 0
	local nextPuff = 0
	local wasSleeping = model:GetAttribute("State") == "Sleeping"

	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		if not model.Parent or not root.Parent then
			connection:Disconnect()
			return
		end

		local sleeping = model:GetAttribute("State") == "Sleeping"

		if sleeping then
			if os.clock() >= nextPuff then
				stage = stage % 3 + 1
				puff(root, stage)
				nextPuff = os.clock() + 0.85
			end
		elseif wasSleeping then
			-- Woke up this frame: kill the Zzz immediately, then react.
			clearPuffs(model)
			alertPop(root)
		end

		wasSleeping = sleeping
	end)
end

function GuardianFxController.start()
	local holder = workspace:WaitForChild("Guardians", 30)
	if not holder then
		return
	end

	for _, model in holder:GetChildren() do
		if model:IsA("Model") then
			task.spawn(watch, model)
		end
	end
	holder.ChildAdded:Connect(function(model)
		if model:IsA("Model") then
			task.spawn(watch, model)
		end
	end)
end

return GuardianFxController
