--!strict
--[[
	TutorialController
	A world arrow pointing at the current objective, and nothing else on screen.

	WHY THERE IS NO BANNER ANY MORE
	This controller used to draw the objective and hint as two huge yellow
	TextScaled labels pinned across the top of the screen. That was the only
	source of the "GET BACK TO YOUR BASE!" / "PLACE YOUR STOLEN ITEM" /
	"UPGRADE BASE - $1K" text in the game - it was one banner whose contents
	changed per stage, not several widgets - and it clashed with the UI pack in
	every way: wrong font weight, wrong colour, no animation, and it sat on top
	of the pack's own notifications whenever both fired for the same event.

	Objectives now arrive as pack notifications through ToastController, which is
	the same animated path every other piece of feedback uses. Only the stage's
	first push shows a toast, so standing still never re-announces anything.

	Presentation only. The stage is decided entirely on the server and arrives in
	StatePush; nothing here can advance the tutorial.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared").Remotes)
local ToastController = require(script.Parent.ToastController)

local TutorialController = {}

local player = Players.LocalPlayer

local ACCENT = Color3.fromRGB(255, 214, 64)

local arrowPart: Part? = nil
local currentTarget: Vector3? = nil
local lastObjective: string? = nil

--- A single floating chevron that bobs above whatever the objective points at.
--- This is the world-space pointer the GDD asks for, and is deliberately kept:
--- it is what replaces the removed text.
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
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		local tutorial = state.tutorial

		if not tutorial then
			currentTarget = nil
			lastObjective = nil
			return
		end

		local objective = tutorial.objective
		if objective and objective ~= "" and objective ~= lastObjective then
			-- Only on change: StatePush repeats the same stage every tick.
			local hint = tutorial.hint
			ToastController.show("info", if hint and hint ~= "" then `{objective} - {hint}` else objective)
		end
		lastObjective = objective

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

		-- Kept low so the chevron reads as attached to the thing it points at.
		local part = ensureArrow()
		local bob = math.sin(os.clock() * 3) * 1.4
		part.CFrame = CFrame.new(currentTarget + Vector3.new(0, 8 + bob, 0))
	end)
end

return TutorialController
