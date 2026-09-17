--!strict
--[[
	CodesController
	The CODES row: a text box and a REDEEM button at the TOP of the Settings
	panel (MainUI.Frames.Settings.ScrollingFrame).

	WHY SETTINGS AND NOT ITS OWN HUD BUTTON
	The desktop rail and the phone 2x2 block are both full (HUDLayoutController
	lays out exactly four tiles), the top strip already carries BASE, GIFT,
	the gear and now the Daily button, and players of this genre look for
	codes in Settings anyway. A row in an existing panel costs no screen space
	and inherits the pack's slide, blur and close for free.

	HOW THE ROW IS MADE
	A clone of the pack's Shadows toggle row (the same source the Graphics row
	is copied from), so it has the panel's plate, font and stroke:
	  * the title reads CODES (with CodesConfig.HEADER_ICON beside it, if set);
	  * the OFF button is hidden and the ON button becomes REDEEM, filling the
	    toggle area;
	  * a TextBox is laid between the title and the button, measured from
	    where the pack actually put those two (their layout is place-owned).
	SettingsController may already have added its ON/OFF captions and hit
	areas to the Shadows row before this clone is taken; they are stripped.

	THE CONTRACT
	The client sends the typed text (RedeemCodeRequest) and nothing else. The
	server answers on RedeemCodeResult (to clear or keep the box) and shows
	the toast through Notify, like every other message.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CodesConfig = require(ReplicatedStorage.Shared.Config.CodesConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ToastController = require(script.Parent.ToastController)

local CodesController = {}

local player = Players.LocalPlayer

local BOX_FILL = Color3.fromRGB(16, 22, 44)
local BOX_TEXT = Color3.fromRGB(240, 244, 255)
local BOX_HINT = Color3.fromRGB(140, 150, 176)
local EDGE_IDLE = Color3.fromRGB(0, 0, 0)
local EDGE_OK = Color3.fromRGB(88, 220, 110)
local EDGE_BAD = Color3.fromRGB(232, 74, 78)
local REDEEM_COLOR = Color3.fromRGB(88, 220, 110)
--- A second press inside this window is ignored (the server limits too).
local SUBMIT_COOLDOWN = 1.2

local box: TextBox? = nil
local boxEdge: UIStroke? = nil
local lastSubmit = 0

local function flashEdge(color: Color3)
	local edge = boxEdge
	if not edge then
		return
	end
	edge.Color = color
	TweenService:Create(edge, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Color = EDGE_IDLE }):Play()
end

local function submit()
	local input = box
	if not input then
		return
	end
	local now = os.clock()
	if now - lastSubmit < SUBMIT_COOLDOWN then
		return
	end
	local text = string.match(input.Text, "^%s*(.-)%s*$") or ""
	if text == "" then
		ToastController.show("error", "Type a code first.")
		flashEdge(EDGE_BAD)
		return
	end
	if #text > CodesConfig.MAX_LENGTH then
		ToastController.show("error", "That code is invalid.")
		flashEdge(EDGE_BAD)
		return
	end
	lastSubmit = now
	Remotes.get("RedeemCodeRequest"):FireServer(text)
end

--- Removes what SettingsController (or the pack) may already have put on the
--- Shadows row before it was cloned.
local function strip(row: Instance)
	for _, child in row:GetDescendants() do
		if child.Name == "Word" or child.Name == "Hit" or child.Name == "_RippleContainer" then
			child:Destroy()
		end
	end
	for _, child in row:GetDescendants() do
		if child:IsA("GuiButton") then
			child:SetAttribute("_UIHandlerSetup", nil)
			child:SetAttribute("AnimBound", nil)
		end
	end
end

--- Lays the box between the title's right edge and the button's left edge,
--- in the body's own scale, from where the pack actually drew them.
local function placeBox(body: GuiObject, title: GuiObject?, button: GuiObject, input: TextBox)
	local width = body.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local left = 0.3
	if title and title.AbsoluteSize.X > 0 then
		-- The title is text-scaled in a wide box; never let the box start
		-- further right than 45% of the row.
		left = math.clamp((title.AbsolutePosition.X - body.AbsolutePosition.X + title.AbsoluteSize.X) / width, 0.18, 0.45)
		left = math.min(left, 0.34)
	end
	local right = math.clamp((button.AbsolutePosition.X - body.AbsolutePosition.X) / width, left + 0.2, 0.98)
	local gap = 0.02
	input.AnchorPoint = Vector2.new(0, 0.5)
	input.Position = UDim2.fromScale(left + gap, 0.5)
	input.Size = UDim2.fromScale(math.max(0.15, right - left - gap * 2), 0.64)
end

local function build(list: Instance, template: GuiObject): boolean
	if list:FindFirstChild("Codes") then
		return true
	end
	local row = template:Clone()
	row.Name = "Codes"
	strip(row)

	-- First in the list: one below the smallest LayoutOrder already there.
	local lowest = math.huge
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") and child ~= row then
			lowest = math.min(lowest, child.LayoutOrder)
		end
	end
	row.LayoutOrder = if lowest == math.huge then -1 else lowest - 1

	local body = row:FindFirstChild("Frame")
	local choose = body and body:FindFirstChild("Choose")
	local redeem = choose and choose:FindFirstChild("ON")
	local off = choose and choose:FindFirstChild("OFF")
	if not body or not body:IsA("GuiObject") or not choose or not choose:IsA("GuiObject") or not redeem or not redeem:IsA("GuiButton") then
		row:Destroy()
		warn("[CodesController] the Settings row template is not the expected shape - CODES not built.")
		return false
	end

	local title = body:FindFirstChild("Multiplier1")
	if title and title:IsA("TextLabel") then
		title.Text = "CODES"
	end

	-- The optional section icon, to the left of the title, only when real
	-- art exists.
	if CodesConfig.HEADER_ICON ~= "rbxassetid://0" and title and title:IsA("GuiObject") then
		local icon = Instance.new("ImageLabel")
		icon.Name = "CodesIcon"
		icon.BackgroundTransparency = 1
		icon.Image = CodesConfig.HEADER_ICON
		icon.AnchorPoint = Vector2.new(1, 0.5)
		icon.Position = UDim2.new(title.Position.X.Scale, title.Position.X.Offset - 4, 0.5, 0)
		icon.Size = UDim2.fromScale(0.8, 0.8)
		icon.ZIndex = title.ZIndex
		icon.Parent = body
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.AspectRatio = 1
		ratio.Parent = icon
	end

	-- The toggle pair becomes one button. Any layout in the pair would keep
	-- sizing it as half, so it goes (this is our clone).
	if off and off:IsA("GuiObject") then
		off.Visible = false
	end
	for _, child in choose:GetChildren() do
		if child:IsA("UIGridLayout") or child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	local ratio = redeem:FindFirstChildOfClass("UIAspectRatioConstraint")
	if ratio then
		ratio:Destroy()
	end
	redeem.Name = "Redeem"
	redeem.AnchorPoint = Vector2.new(0.5, 0.5)
	redeem.Position = UDim2.fromScale(0.5, 0.5)
	redeem.Size = UDim2.fromScale(1, 1)
	redeem.BackgroundTransparency = 0
	local face = redeem:FindFirstChild("Frame")
	if face and face:IsA("GuiObject") then
		face.BackgroundColor3 = REDEEM_COLOR
	end
	local word = Instance.new("TextLabel")
	word.Name = "Word"
	word.BackgroundTransparency = 1
	word.AnchorPoint = Vector2.new(0.5, 0.5)
	word.Position = UDim2.fromScale(0.5, 0.5)
	word.Size = UDim2.fromScale(0.86, 0.7)
	word.Font = Enum.Font.FredokaOne
	word.TextScaled = true
	word.TextColor3 = Color3.fromRGB(255, 255, 255)
	word.TextStrokeTransparency = 0.3
	word.Text = "REDEEM"
	word.ZIndex = redeem.ZIndex + 3
	word.Parent = redeem

	local input = Instance.new("TextBox")
	input.Name = "CodeBox"
	input.BackgroundColor3 = BOX_FILL
	input.BackgroundTransparency = 0.05
	input.BorderSizePixel = 0
	input.ClearTextOnFocus = false
	input.Font = Enum.Font.GothamBold
	input.PlaceholderText = "Enter code"
	input.PlaceholderColor3 = BOX_HINT
	input.Text = ""
	input.TextColor3 = BOX_TEXT
	input.TextScaled = true
	input.TextXAlignment = Enum.TextXAlignment.Center
	input.ZIndex = body.ZIndex + 3
	input.AnchorPoint = Vector2.new(0, 0.5)
	input.Position = UDim2.fromScale(0.32, 0.5)
	input.Size = UDim2.fromScale(0.36, 0.64)
	input.Parent = body
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = input
	local edge = Instance.new("UIStroke")
	edge.Thickness = 2
	edge.Color = EDGE_IDLE
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = input
	local textLimit = Instance.new("UITextSizeConstraint")
	textLimit.MinTextSize = 12
	textLimit.MaxTextSize = 24
	textLimit.Parent = input
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = input
	box = input
	boxEdge = edge

	-- Max length on the box itself, so a paste cannot grow it unbounded.
	input:GetPropertyChangedSignal("Text"):Connect(function()
		if #input.Text > CodesConfig.MAX_LENGTH then
			input.Text = string.sub(input.Text, 1, CodesConfig.MAX_LENGTH)
		end
	end)
	input.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submit()
		end
	end)

	UIAnim.claimButton(redeem)
	redeem.Activated:Connect(function()
		UIAnim.punch(redeem, 0.2)
		submit()
	end)

	row.Parent = list

	-- Measure once the row has been laid out, and whenever it resizes (the
	-- panel is scaled up on touch and follows the viewport).
	local titleObject: GuiObject? = if title and title:IsA("GuiObject") then title else nil
	local bodyObject = body :: GuiObject
	local chooseObject = choose :: GuiObject
	local function refit()
		placeBox(bodyObject, titleObject, chooseObject, input)
	end
	task.defer(refit)
	bodyObject:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	return true
end

function CodesController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	local frames = ui and ui:FindFirstChild("Frames")
	local panel = frames and frames:FindFirstChild("Settings")
	local list = panel and panel:FindFirstChild("ScrollingFrame")
	if not list then
		warn("[CodesController] Frames.Settings.ScrollingFrame not found - CODES disabled.")
		return
	end
	local template = list:WaitForChild("Shadows", 10)
	if not template or not template:IsA("GuiObject") then
		warn("[CodesController] Settings has no Shadows row to copy - CODES disabled.")
		return
	end
	if not build(list, template) then
		return
	end

	Remotes.get("RedeemCodeResult").OnClientEvent:Connect(function(ok, _message)
		local input = box
		if ok == true then
			if input then
				input.Text = ""
				UIAnim.punch(input, 0.15)
			end
			flashEdge(EDGE_OK)
		else
			flashEdge(EDGE_BAD)
		end
	end)
end

return CodesController
