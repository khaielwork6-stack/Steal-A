--!strict
--[[
	TutorialController
	Renders the tutorial objective, a world arrow pointing at the current target,
	and the trailing quest chip.

	Presentation only. The stage is decided entirely on the server and arrives in
	StatePush; nothing here can advance the tutorial.

	The GDD is explicit about not dumping popups on a new player, so this shows
	exactly one objective line, one hint line, and one arrow at a time.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local TutorialController = {}

local player = Players.LocalPlayer

local ACCENT = Color3.fromRGB(255, 214, 64)

local arrowPart: Part? = nil
local currentTarget: Vector3? = nil

--- A single floating chevron that bobs above whatever the objective points at.
local function ensureArrow(): Part
	if arrowPart and arrowPart.Parent then
		return arrowPart
	end

	local part = Instance.new("Part")
	part.Name = "TutorialArrow"
	part.Size = Vector3.new(4, 4, 4)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = workspace

	local gui = Instance.new("BillboardGui")
	gui.Name = "Chevron"
	gui.Size = UDim2.fromScale(9, 9)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 1500
	gui.Adornee = part
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = ACCENT
	label.TextStrokeTransparency = 0.15
	label.Text = "▼"
	label.Parent = gui

	arrowPart = part
	return part
end

function TutorialController.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Tutorial"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Objective banner, top centre and well clear of the stats block.
	local banner = Instance.new("Frame")
	banner.Name = "Objective"
	-- Sits below the zone-progress bar, which owns the very top of the screen.
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 112)
	banner.Size = UDim2.new(0, 620, 0, 82)
	banner.BackgroundTransparency = 1
	banner.Visible = false
	banner.Parent = gui

	local objective = Instance.new("TextLabel")
	objective.Name = "Title"
	objective.Size = UDim2.new(1, 0, 0, 48)
	objective.BackgroundTransparency = 1
	objective.Font = Enum.Font.FredokaOne
	objective.TextScaled = true
	objective.TextColor3 = ACCENT
	objective.TextStrokeTransparency = 0.2
	objective.Parent = banner

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.Position = UDim2.new(0, 0, 0, 50)
	hint.Size = UDim2.new(1, 0, 0, 28)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.FredokaOne
	hint.TextScaled = true
	hint.TextColor3 = Color3.fromRGB(238, 240, 248)
	hint.TextStrokeTransparency = 0.35
	hint.Parent = banner

	-- Trailing quest chip, bottom left, out of the way.
	local chip = Instance.new("TextLabel")
	chip.Name = "QuestChip"
	chip.AnchorPoint = Vector2.new(0, 1)
	chip.Position = UDim2.new(0, 18, 1, -18)
	chip.Size = UDim2.new(0, 250, 0, 34)
	chip.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
	chip.BackgroundTransparency = 0.25
	chip.Font = Enum.Font.FredokaOne
	chip.TextScaled = true
	chip.TextColor3 = ACCENT
	chip.Visible = false
	chip.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = chip

	local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Remotes)

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		local tutorial = state.tutorial

		if not tutorial then
			banner.Visible = false
			chip.Visible = false
			currentTarget = nil
			return
		end

		local hasObjective = tutorial.objective ~= nil and tutorial.objective ~= ""
		banner.Visible = hasObjective
		if hasObjective then
			if objective.Text ~= tutorial.objective then
				-- Small pop so a changed objective is noticed without a popup.
				objective.Text = tutorial.objective
				objective.TextTransparency = 1
				TweenService:Create(objective, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
			end
			hint.Text = tutorial.hint or ""
		end

		chip.Visible = tutorial.chip ~= nil
		chip.Text = tutorial.chip or ""

		currentTarget = tutorial.target
	end)

	-- Arrow bob. Kept on Heartbeat so it tracks a target that moves (the base
	-- spawn changes when a plot is reassigned).
	RunService.Heartbeat:Connect(function()
		if not currentTarget then
			if arrowPart then
				arrowPart:Destroy()
				arrowPart = nil
			end
			return
		end

		-- Kept low so the chevron reads as attached to the thing it points at,
		-- and does not drift up behind the objective banner.
		local part = ensureArrow()
		local bob = math.sin(os.clock() * 3) * 1.4
		part.CFrame = CFrame.new(currentTarget + Vector3.new(0, 8 + bob, 0))
	end)
end

return TutorialController
