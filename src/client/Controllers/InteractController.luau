--!strict
--[[
	InteractController
	One clean interact prompt: a keycap on the left, an action panel on the right.

	WHY THE OLD ONE SPAMMED
	Roblox draws its default prompt UI for EVERY ProximityPrompt in range. A base
	has fourteen display-slot prompts plus the activation pad, upgrade pad and
	treadmill, all inside twelve studs of each other, so a player standing at
	their base saw a dozen overlapping "Object Text / Action Text" cards at once.
	Restyling would not have fixed that.

	THE FIX
	Every prompt is switched to Style = Custom, which suppresses Roblox's own UI
	entirely. This controller then tracks which prompts are currently shown and
	renders exactly ONE - the nearest - reusing a single billboard. Target
	changes swap the text in place, so there are never clones, stacks or flicker.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local InteractController = {}

local player = Players.LocalPlayer

local shown: { [ProximityPrompt]: boolean } = {}
local current: ProximityPrompt? = nil

local billboard: BillboardGui
local idleParent: Instance
local keycap: Frame
local keyLabel: TextLabel
local panel: Frame
local objectLabel: TextLabel
local actionLabel: TextLabel
local fillBar: Frame

local function stroke(parent: Instance, thickness: number, color: Color3)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

--- Built once and reused forever; nothing here is ever cloned per prompt.
local function build()
	billboard = Instance.new("BillboardGui")
	billboard.Name = "InteractPrompt"
	billboard.Size = UDim2.fromOffset(350, 96)
	-- AlwaysOnTop must stay FALSE. With it enabled the billboard reported itself
	-- as enabled, on-screen and correctly laid out, yet drew nothing at all.
	-- Depth-sorting normally is also more honest: a prompt behind a wall should
	-- not punch through it.
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.MaxDistance = 60
	-- Float above the target. Without this it draws at the part's centre, which
	-- for a floor-level display pad is under the player's own feet.
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	billboard.Enabled = false
	-- Parented to the target part rather than PlayerGui. The loot labels and
	-- guardian Zzz already use this pattern and render reliably; a BillboardGui
	-- sitting in PlayerGui refused to draw here even with a valid Adornee.
	billboard.Parent = player:WaitForChild("PlayerGui")
	idleParent = billboard.Parent

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = billboard

	-- Keycap
	keycap = Instance.new("Frame")
	keycap.Name = "Keycap"
	keycap.AnchorPoint = Vector2.new(0, 0.5)
	keycap.Position = UDim2.new(0, 0, 0.5, 0)
	keycap.Size = UDim2.fromOffset(74, 74)
	keycap.BackgroundColor3 = Color3.fromRGB(150, 255, 96)
	keycap.Parent = root
	corner(keycap, 14)
	stroke(keycap, 4, Color3.fromRGB(18, 24, 20))

	local keyGradient = Instance.new("UIGradient")
	keyGradient.Color = ColorSequence.new(Color3.fromRGB(190, 255, 150), Color3.fromRGB(104, 226, 64))
	keyGradient.Rotation = 90
	keyGradient.Parent = keycap

	keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Key"
	keyLabel.BackgroundTransparency = 1
	keyLabel.Size = UDim2.fromScale(1, 1)
	keyLabel.Font = Enum.Font.FredokaOne
	keyLabel.TextScaled = true
	keyLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	keyLabel.Text = "E"
	keyLabel.Parent = keycap
	stroke(keyLabel, 3, Color3.fromRGB(20, 26, 22))

	-- Hold-progress fill, drawn under the keycap text.
	fillBar = Instance.new("Frame")
	fillBar.Name = "HoldFill"
	fillBar.AnchorPoint = Vector2.new(0, 1)
	fillBar.Position = UDim2.new(0, 0, 1, 0)
	fillBar.Size = UDim2.fromScale(1, 0)
	fillBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	fillBar.BackgroundTransparency = 0.55
	fillBar.ZIndex = 0
	fillBar.Parent = keycap

	-- Action panel
	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 86, 0.5, 0)
	panel.Size = UDim2.fromOffset(256, 74)
	panel.BackgroundColor3 = Color3.fromRGB(64, 122, 46)
	panel.Parent = root
	corner(panel, 12)
	stroke(panel, 4, Color3.fromRGB(18, 24, 20))

	local panelGradient = Instance.new("UIGradient")
	panelGradient.Color = ColorSequence.new(Color3.fromRGB(88, 154, 64), Color3.fromRGB(48, 98, 34))
	panelGradient.Rotation = 90
	panelGradient.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = panel

	objectLabel = Instance.new("TextLabel")
	objectLabel.Name = "ObjectText"
	objectLabel.BackgroundTransparency = 1
	objectLabel.Position = UDim2.new(0, 0, 0, 8)
	objectLabel.Size = UDim2.new(1, 0, 0, 22)
	objectLabel.Font = Enum.Font.FredokaOne
	objectLabel.TextScaled = true
	objectLabel.TextXAlignment = Enum.TextXAlignment.Left
	objectLabel.TextColor3 = Color3.fromRGB(196, 226, 180)
	objectLabel.Parent = panel

	actionLabel = Instance.new("TextLabel")
	actionLabel.Name = "ActionText"
	actionLabel.BackgroundTransparency = 1
	actionLabel.Position = UDim2.new(0, 0, 0, 30)
	actionLabel.Size = UDim2.new(1, 0, 0, 34)
	actionLabel.Font = Enum.Font.FredokaOne
	actionLabel.TextScaled = true
	actionLabel.TextXAlignment = Enum.TextXAlignment.Left
	actionLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	actionLabel.Parent = panel
	stroke(actionLabel, 3, Color3.fromRGB(20, 30, 18))
end

--- Nearest currently-shown prompt, so walking past a row of slots highlights
--- only the one the player actually means.
local function pickNearest(): ProximityPrompt?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end

	local best, bestDistance = nil, math.huge
	for prompt in shown do
		local part = prompt.Parent
		if prompt.Parent and prompt.Enabled and part and part:IsA("BasePart") then
			local distance = (part.Position - root.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = prompt, distance
			end
		else
			shown[prompt] = nil
		end
	end
	return best
end

local function keyNameFor(prompt: ProximityPrompt): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "TAP"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Y"
	end
	return prompt.KeyboardKeyCode.Name
end

--- Swaps content in place. Never creates a second billboard.
local function apply(prompt: ProximityPrompt?)
	if prompt == current then
		return
	end
	current = prompt

	if not prompt then
		if billboard.Enabled then
			local root = billboard:FindFirstChild("Root")
			if root and root:IsA("GuiObject") then
				UIAnim.popOut(root)
			end
			task.delay(0.14, function()
				if not current then
					billboard.Enabled = false
					-- Park it off the world part so a destroyed slot cannot take
					-- the single shared billboard with it.
					billboard.Parent = idleParent
					billboard.Adornee = nil
				end
			end)
		end
		return
	end

	local part = prompt.Parent :: BasePart
	billboard.Adornee = part
	billboard.Parent = part
	objectLabel.Text = prompt.ObjectText
	actionLabel.Text = prompt.ActionText
	keyLabel.Text = keyNameFor(prompt)
	fillBar.Size = UDim2.fromScale(1, 0)

	local root = billboard:FindFirstChild("Root")
	local wasHidden = not billboard.Enabled or (root and root:IsA("GuiObject") and not root.Visible)

	billboard.Enabled = true
	if root and root:IsA("GuiObject") then
		-- Always re-show explicitly. A prompt reappearing between the hide tween
		-- and its delayed disable used to leave the billboard enabled but the
		-- root still invisible, so the prompt silently never came back.
		root.Visible = true
		if wasHidden then
			UIAnim.popIn(root, 0.7)
		else
			-- Same billboard, different target: a small punch reads as a swap.
			UIAnim.punch(root, 0.08)
		end
	end
end

function InteractController.start()
	build()

	-- Suppress Roblox's built-in prompt UI everywhere, including prompts that
	-- are created later at runtime.
	local function makeCustom(instance: Instance)
		if instance:IsA("ProximityPrompt") then
			instance.Style = Enum.ProximityPromptStyle.Custom
		end
	end
	for _, d in workspace:GetDescendants() do
		makeCustom(d)
	end
	workspace.DescendantAdded:Connect(makeCustom)

	ProximityPromptService.PromptShown:Connect(function(prompt)
		prompt.Style = Enum.ProximityPromptStyle.Custom
		shown[prompt] = true
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		shown[prompt] = nil
	end)

	-- Hold feedback on the keycap.
	ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
		if prompt == current and prompt.HoldDuration > 0 then
			TweenService:Create(
				fillBar,
				TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear),
				{ Size = UDim2.fromScale(1, 1) }
			):Play()
		end
	end)
	ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt)
		if prompt == current then
			TweenService:Create(fillBar, UIAnim.SNAP, { Size = UDim2.fromScale(1, 0) }):Play()
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt == current then
			fillBar.Size = UDim2.fromScale(1, 0)
			UIAnim.punch(keycap, 0.25)
		end
	end)

	RunService.Heartbeat:Connect(function()
		apply(pickNearest())
	end)
end

return InteractController
