--!strict
--[[
	TutorialController
	A world arrow pointing at the current objective, and ONE opening popup on
	a player's first-ever start. Nothing else.

	WHY THERE ARE NO STAGE BANNERS
	Every stage used to announce itself as a toast ("STEAL YOUR FIRST ITEM -
	Hold the prompt...", "PLACE YOUR STOLEN ITEM...", "NEXT: Pirate Island -
	Recommended Speed 900..."), and with the reveal system's own feedback they
	stacked into a wall of text over the player. The server no longer sends
	objective text at all - TutorialService pushes only the arrow's target and,
	exactly once in a player's life, `showIntro`. Respawning, rejoining and
	finishing the tutorial cannot bring the popup back: the flag that gates it
	is flipped and saved on the server before the push goes out.

	Presentation only. The stage is decided entirely on the server and arrives
	in StatePush; nothing here can advance the tutorial.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared").Remotes)

local TutorialController = {}

local player = Players.LocalPlayer

local ACCENT = Color3.fromRGB(255, 214, 64)
local INTRO_TEXT = "STEAL MYSTERY LOOT, ESCAPE THE GUARD, THEN REVEAL IT AT YOUR BASE!"
local INTRO_FADE = 0.45
local INTRO_HOLD = 4.2

local arrowPart: Part? = nil
local currentTarget: Vector3? = nil
--- True while the server is carrying showIntro on its pushes. The popup is
--- shown once per such window: the server sends the flag for a short window
--- after a first-ever start (so a client still wiring up cannot miss it) and,
--- because the durable flag behind it never resets, that window happens once
--- in a lifetime. Cleared when the flag stops arriving.
local introArmed = false

-- ==========================================================
-- THE OPENING POPUP
-- ==========================================================

--- One line, centred high on the screen, faded in and out, gone in about five
--- seconds. Built fresh and destroyed after, so it can never linger or stack.
local function showIntro()
	local gui = player:FindFirstChild("PlayerGui")
	if not gui or gui:FindFirstChild("IntroPopup") then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "IntroPopup"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 60
	screen.Parent = gui

	local group = Instance.new("CanvasGroup")
	group.AnchorPoint = Vector2.new(0.5, 0)
	group.Position = UDim2.fromScale(0.5, 0.16)
	group.Size = UDim2.fromScale(0.62, 0.11)
	group.BackgroundColor3 = Color3.fromRGB(14, 16, 30)
	group.BackgroundTransparency = 0.18
	group.BorderSizePixel = 0
	group.GroupTransparency = 1
	group.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = group
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = ACCENT
	stroke.Transparency = 0.2
	stroke.Parent = group
	local sizeCap = Instance.new("UISizeConstraint")
	sizeCap.MaxSize = Vector2.new(760, 96)
	sizeCap.MinSize = Vector2.new(260, 56)
	sizeCap.Parent = group

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextWrapped = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.5
	label.Text = INTRO_TEXT
	label.Parent = group
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = label

	local fadeIn = TweenService:Create(group, TweenInfo.new(INTRO_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { GroupTransparency = 0 })
	fadeIn:Play()
	task.delay(INTRO_FADE + INTRO_HOLD, function()
		if not screen.Parent then
			return
		end
		local fadeOut = TweenService:Create(group, TweenInfo.new(INTRO_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { GroupTransparency = 1 })
		fadeOut:Play()
		fadeOut.Completed:Once(function()
			screen:Destroy()
		end)
	end)
end

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
		if tutorial.showIntro == true then
			if not introArmed then
				introArmed = true
				showIntro()
			end
		else
			introArmed = false
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
