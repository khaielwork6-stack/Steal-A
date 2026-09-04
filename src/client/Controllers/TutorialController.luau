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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

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

	-- Trailing objective widget. The old version was a bare pill of text that
	-- read as a debug label; this is a proper card with a heading, the goal and
	-- its own progress fill so the player can see how close they are.
	local chip = Instance.new("Frame")
	chip.Name = "QuestChip"
	chip.AnchorPoint = Vector2.new(1, 1)
	chip.Position = UDim2.new(1, -14, 1, -96)
	chip.Size = UDim2.fromOffset(238, 74)
	chip.BackgroundColor3 = Color3.fromRGB(30, 34, 46)
	chip.Visible = false
	chip.Parent = gui

	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(0, 12)
	chipCorner.Parent = chip

	local chipStroke = Instance.new("UIStroke")
	chipStroke.Thickness = 3
	chipStroke.Color = Color3.fromRGB(14, 16, 22)
	chipStroke.Parent = chip

	local heading = Instance.new("TextLabel")
	heading.Name = "Heading"
	heading.BackgroundTransparency = 1
	heading.Position = UDim2.new(0, 12, 0, 6)
	heading.Size = UDim2.new(1, -24, 0, 16)
	heading.Font = Enum.Font.FredokaOne
	heading.TextScaled = true
	heading.TextXAlignment = Enum.TextXAlignment.Left
	heading.TextColor3 = Color3.fromRGB(150, 160, 180)
	heading.Text = "NEXT GOAL"
	heading.Parent = chip

	local goal = Instance.new("TextLabel")
	goal.Name = "Goal"
	goal.BackgroundTransparency = 1
	goal.Position = UDim2.new(0, 12, 0, 22)
	goal.Size = UDim2.new(1, -24, 0, 26)
	goal.Font = Enum.Font.FredokaOne
	goal.TextScaled = true
	goal.TextXAlignment = Enum.TextXAlignment.Left
	goal.TextColor3 = ACCENT
	goal.Text = ""
	goal.Parent = chip

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.new(0, 12, 1, -20)
	track.Size = UDim2.new(1, -24, 0, 10)
	track.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
	track.Parent = chip

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 0, 0.5, 0)
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = ACCENT
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

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

		if tutorial.chip then
			if not chip.Visible then
				UIAnim.popIn(chip, 0.8)
			end
			goal.Text = tutorial.chip
			-- Show real progress toward the goal rather than a static label.
			local target = tutorial.chipTarget
			local value = tutorial.chipValue
			if type(target) == "number" and type(value) == "number" and target > 0 then
				UIAnim.setBarFill(fill, math.clamp(value / target, 0, 1), 1)
				track.Visible = true
			else
				track.Visible = false
			end
		elseif chip.Visible then
			UIAnim.popOut(chip)
		end

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
