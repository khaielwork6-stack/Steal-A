--!strict
--[[
	TutorialController
	A world arrow pointing at the current objective. Nothing else.

	WHY THERE ARE NO STAGE BANNERS OR OPENING POPUP
	Every stage used to announce itself as a toast ("STEAL YOUR FIRST ITEM -
	Hold the prompt...", "PLACE YOUR STOLEN ITEM..."), and with the reveal
	system's own feedback they stacked into a wall of text over the player.
	The server no longer sends objective text at all - TutorialService pushes
	only the arrow's target.

	The one remaining popup on a first-ever start ("STEAL MYSTERY LOOT, ESCAPE
	THE GUARD, THEN REVEAL IT AT YOUR BASE!") is gone too, by request: it sat
	over the spawn on the one screen a new player is trying to read. The
	server still sends the showIntro flag and it is simply ignored here, so
	nothing on the save/tutorial side had to change.

	Presentation only. The stage is decided entirely on the server and arrives
	in StatePush; nothing here can advance the tutorial.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared").Remotes)

local TutorialController = {}

local player = Players.LocalPlayer

local ACCENT = Color3.fromRGB(255, 214, 64)

local arrowPart: Part? = nil
local currentTarget: Vector3? = nil

-- ==========================================================
-- THE ARROW
-- ==========================================================

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
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		local tutorial = state and state.tutorial
		if not tutorial then
			currentTarget = nil
			return
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
		local part = ensureArrow()
		local bob = math.sin(os.clock() * 3) * 1.4
		part.CFrame = CFrame.new(currentTarget + Vector3.new(0, 8 + bob, 0))
	end)
end

return TutorialController
