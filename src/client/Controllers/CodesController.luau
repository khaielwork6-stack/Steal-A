--!strict
--[[
	CodesController
	The CODES bar at the top of the Settings panel: a gift icon and the word
	CODES, a text box, and a REDEEM button, with the result written under
	the box (green / red) as well as the usual toast.

	WHY SETTINGS AND NOT ITS OWN HUD BUTTON
	The desktop rail and the phone 2x2 block are both full (HUDLayoutController
	lays out exactly four tiles), the top strip already carries BASE, GIFT,
	the gear and the Daily button, and players of this genre look for codes in
	Settings anyway. A bar in an existing panel costs no screen space and
	inherits the pack's slide, blur and close for free.

	HOW THE BAR IS MADE (round3-ui-base-settings rebuild)
	The first version cloned the whole Shadows toggle row and turned its ON
	button into REDEEM. Removing the toggle pair's layout let that button fill
	the pair's full-width frame, so a big green bar covered the title and the
	box and the REDEEM caption sat under the pack's face. Now:
	  * SettingsController owns the order and the size. It pins this bar
	    ABOVE the scrolling list (so it is always first and never scrolls
	    away) and calls `attach(bar, template)` with a pristine copy of the
	    Shadows row taken before any row was bound.
	  * Only the row's LOOK is kept from that copy: its plate, stroke,
	    gradient, full-size textures and the title label (font, stroke).
	    The toggle pair, icons and anything else are removed.
	  * The icon, box, REDEEM button and result line are our own plain
	    elements laid out in the row's scale, so nothing depends on where the
	    pack put its toggle.
	The bar lives outside the list's CanvasGroup clip guard on purpose: a
	TextBox is kept out of CanvasGroups (Shared.Util.ClipSafe).

	THE CONTRACT
	The client sends the typed text (RedeemCodeRequest) and nothing else. The
	server answers on RedeemCodeResult(ok, message) and shows the toast
	through Notify, like every other message.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)
local CodesConfig = require(ReplicatedStorage.Shared.Config.CodesConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ToastController = require(script.Parent.ToastController)

local CodesController = {}

local WHITE = Color3.fromRGB(255, 255, 255)
local INK = Color3.fromRGB(10, 12, 20)
local BOX_FILL = Color3.fromRGB(16, 22, 44)
local BOX_TEXT = Color3.fromRGB(240, 244, 255)
local BOX_HINT = Color3.fromRGB(140, 150, 176)
local EDGE_IDLE = Color3.fromRGB(0, 0, 0)
local EDGE_OK = Color3.fromRGB(88, 220, 110)
local EDGE_BAD = Color3.fromRGB(232, 74, 78)
local OK_TEXT = Color3.fromRGB(120, 255, 150)
local BAD_TEXT = Color3.fromRGB(255, 120, 120)
local REDEEM_TOP = Color3.fromRGB(120, 240, 130)
local REDEEM_BOTTOM = Color3.fromRGB(20, 160, 70)
local GIFT_RED = Color3.fromRGB(232, 64, 84)
local GIFT_GOLD = Color3.fromRGB(255, 212, 64)
--- A second press inside this window is ignored (the server limits too).
local SUBMIT_COOLDOWN = 1.2
--- How long a result stays under the box.
local STATUS_SECONDS = 6

local box: TextBox? = nil
local boxEdge: UIStroke? = nil
local status: TextLabel? = nil
local lastSubmit = 0
local statusToken = 0

local function flashEdge(color: Color3)
	local edge = boxEdge
	if not edge then
		return
	end
	edge.Color = color
	TweenService:Create(edge, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Color = EDGE_IDLE }):Play()
end

--- The line under the box. Clears itself after a while.
local function say(message: string, good: boolean)
	local line = status
	if not line then
		return
	end
	statusToken += 1
	local token = statusToken
	line.Text = message
	line.TextColor3 = if good then OK_TEXT else BAD_TEXT
	line.Visible = true
	task.delay(STATUS_SECONDS, function()
		if token == statusToken and line.Parent then
			line.Text = ""
		end
	end)
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
		say("Type a code first.", false)
		flashEdge(EDGE_BAD)
		return
	end
	if #text > CodesConfig.MAX_LENGTH then
		ToastController.show("error", "That code is invalid.")
		say("That code is invalid.", false)
		flashEdge(EDGE_BAD)
		return
	end
	lastSubmit = now
	say("Checking...", true)
	Remotes.get("RedeemCodeRequest"):FireServer(text)
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- A child that is only texture (a studs / pattern overlay covering the
--- element) - part of the row's look, kept.
local function isFullTexture(child: Instance): boolean
	return (child:IsA("ImageLabel") or child:IsA("Frame"))
		and child:FindFirstChildWhichIsA("GuiObject") == nil
		and (child :: GuiObject).Size.X.Scale >= 0.9
		and (child :: GuiObject).Size.Y.Scale >= 0.9
end

local function keepsLook(child: Instance): boolean
	if child:IsA("UIAspectRatioConstraint") or child:IsA("UISizeConstraint") or child:IsA("UIScale") then
		return false
	end
	if child:IsA("UIGridStyleLayout") then
		return false
	end
	return child:IsA("UIComponent") or isFullTexture(child)
end

--- The row's plate with everything but its look removed.
local function shell(template: GuiObject): (GuiObject, GuiObject, TextLabel?)
	local row = template:Clone()
	row.Name = "CodesRow"
	row.AnchorPoint = Vector2.zero
	row.Position = UDim2.new()
	row.Size = UDim2.fromScale(1, 1)
	row.Visible = true
	for _, key in { "_UIHandlerSetup", "AnimBound" } do
		row:SetAttribute(key, nil)
	end
	local body: GuiObject = row
	local found = row:FindFirstChild("Frame")
	for _, child in row:GetChildren() do
		if child ~= found and not keepsLook(child) then
			child:Destroy()
		end
	end
	local title: TextLabel? = nil
	if found and found:IsA("GuiObject") then
		body = found
		for _, child in found:GetChildren() do
			if child.Name == "Multiplier1" and child:IsA("TextLabel") and not title then
				title = child
			elseif not keepsLook(child) then
				child:Destroy()
			end
		end
	end
	return row, body, title
end

--- Placeholder until CodesConfig.HEADER_ICON has art: a small gift box.
local function drawGift(holder: Frame)
	local z = holder.ZIndex
	local function part(x: number, y: number, w: number, h: number, color: Color3, dz: number): Frame
		local frame = Instance.new("Frame")
		frame.BorderSizePixel = 0
		frame.BackgroundColor3 = color
		frame.Position = UDim2.fromScale(x, y)
		frame.Size = UDim2.fromScale(w, h)
		frame.ZIndex = z + dz
		frame.Parent = holder
		return frame
	end
	local boxPart = part(0.1, 0.4, 0.8, 0.56, GIFT_RED, 0)
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.15, 0)
	round.Parent = boxPart
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = INK
	stroke.Parent = boxPart
	local lid = part(0.04, 0.26, 0.92, 0.2, GIFT_RED:Lerp(WHITE, 0.15), 1)
	local lidStroke = stroke:Clone()
	lidStroke.Parent = lid
	part(0.43, 0.26, 0.14, 0.7, GIFT_GOLD, 2)
	part(0.1, 0.58, 0.8, 0.1, GIFT_GOLD, 2)
	for _, x in { 0.28, 0.54 } do
		local bow = part(x, 0.06, 0.18, 0.22, GIFT_GOLD, 3)
		local bowRound = Instance.new("UICorner")
		bowRound.CornerRadius = UDim.new(1, 0)
		bowRound.Parent = bow
	end
end

--- Builds the bar inside `bar` (a transparent Frame SettingsController sizes
--- and positions). `template` is a pristine Shadows row copy, or nil for a
--- plain dark plate.
function CodesController.attach(bar: Frame, template: GuiObject?): boolean
	if bar:FindFirstChild("CodesRow") then
		return true
	end
	local row: GuiObject
	local body: GuiObject
	local title: TextLabel?
	if template then
		row, body, title = shell(template)
	else
		local plain = Instance.new("Frame")
		plain.Name = "CodesRow"
		plain.Size = UDim2.fromScale(1, 1)
		plain.BackgroundColor3 = Color3.fromRGB(28, 36, 70)
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0, 12)
		round.Parent = plain
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2.5
		stroke.Color = INK
		stroke.Parent = plain
		row, body = plain, plain
	end
	local z = math.max(body.ZIndex, row.ZIndex) + 1

	-- ---------- left: icon + CODES ----------
	local icon = Instance.new("Frame")
	icon.Name = "CodesIcon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0.025, 0.5)
	icon.Size = UDim2.fromScale(0.1, 0.56)
	icon.ZIndex = z
	icon.Parent = body
	local square = Instance.new("UIAspectRatioConstraint")
	square.AspectRatio = 1
	square.Parent = icon
	if CodesConfig.HEADER_ICON ~= "rbxassetid://0" then
		local art = Instance.new("ImageLabel")
		art.BackgroundTransparency = 1
		art.Image = CodesConfig.HEADER_ICON
		art.Size = UDim2.fromScale(1, 1)
		art.ZIndex = z + 1
		art.Parent = icon
	else
		drawGift(icon)
	end

	local label = title
	if not label then
		local made = Instance.new("TextLabel")
		made.BackgroundTransparency = 1
		made.Font = Enum.Font.FredokaOne
		made.TextColor3 = WHITE
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = INK
		stroke.Parent = made
		made.Parent = body
		label = made
	end
	local titleLabel = label :: TextLabel
	titleLabel.Name = "Title"
	titleLabel.Text = "CODES"
	titleLabel.TextScaled = true
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.AnchorPoint = Vector2.new(0, 0.5)
	titleLabel.Position = UDim2.fromScale(0.14, 0.5)
	titleLabel.Size = UDim2.fromScale(0.17, 0.42)
	titleLabel.ZIndex = z
	local titleLimit = titleLabel:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
	titleLimit.MinTextSize = 12
	titleLimit.MaxTextSize = 34
	titleLimit.Parent = titleLabel

	-- ---------- middle: box + result line ----------
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
	input.ZIndex = z
	input.Position = UDim2.fromScale(0.33, 0.1)
	input.Size = UDim2.fromScale(0.43, 0.52)
	input.Parent = body
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
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
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = input
	box = input
	boxEdge = edge

	local line = Instance.new("TextLabel")
	line.Name = "Result"
	line.BackgroundTransparency = 1
	line.Font = Enum.Font.FredokaOne
	line.TextScaled = true
	line.Text = ""
	line.TextColor3 = OK_TEXT
	line.TextXAlignment = Enum.TextXAlignment.Center
	line.TextTruncate = Enum.TextTruncate.AtEnd
	line.Position = UDim2.fromScale(0.33, 0.66)
	line.Size = UDim2.fromScale(0.43, 0.26)
	line.ZIndex = z
	line.Parent = body
	local lineLimit = Instance.new("UITextSizeConstraint")
	lineLimit.MinTextSize = 10
	lineLimit.MaxTextSize = 18
	lineLimit.Parent = line
	local lineStroke = Instance.new("UIStroke")
	lineStroke.Thickness = 1.5
	lineStroke.Color = INK
	lineStroke.Parent = line
	status = line

	-- ---------- right: REDEEM ----------
	local redeem = Instance.new("TextButton")
	redeem.Name = "Redeem"
	redeem.Text = ""
	redeem.AutoButtonColor = false
	redeem.BorderSizePixel = 0
	redeem.BackgroundColor3 = WHITE
	redeem.AnchorPoint = Vector2.new(1, 0.5)
	redeem.Position = UDim2.fromScale(0.975, 0.5)
	redeem.Size = UDim2.fromScale(0.2, 0.64)
	redeem.ZIndex = z
	redeem.Parent = body
	local redeemCorner = Instance.new("UICorner")
	redeemCorner.CornerRadius = UDim.new(0, 12)
	redeemCorner.Parent = redeem
	local redeemEdge = Instance.new("UIStroke")
	redeemEdge.Thickness = 2.5
	redeemEdge.Color = INK
	redeemEdge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	redeemEdge.Parent = redeem
	local shine = Instance.new("UIGradient")
	shine.Rotation = 90
	shine.Color = ColorSequence.new(REDEEM_TOP, REDEEM_BOTTOM)
	shine.Parent = redeem
	local word = Instance.new("TextLabel")
	word.Name = "Word"
	word.BackgroundTransparency = 1
	word.AnchorPoint = Vector2.new(0.5, 0.5)
	word.Position = UDim2.fromScale(0.5, 0.5)
	word.Size = UDim2.fromScale(0.84, 0.6)
	word.Font = Enum.Font.FredokaOne
	word.TextScaled = true
	word.TextColor3 = WHITE
	word.Text = "REDEEM"
	word.ZIndex = z + 1
	word.Parent = redeem
	local wordStroke = Instance.new("UIStroke")
	wordStroke.Thickness = 2
	wordStroke.Color = INK
	wordStroke.Parent = word
	local wordLimit = Instance.new("UITextSizeConstraint")
	wordLimit.MinTextSize = 12
	wordLimit.MaxTextSize = 28
	wordLimit.Parent = word

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

	-- Our own button, not a pack clone: bound by UIAnim, kept from rotating.
	redeem:SetAttribute(ClipSafe.NO_ROTATION, true)
	UIAnim.claimButton(redeem)
	redeem.Activated:Connect(function()
		UIAnim.punch(redeem, 0.15)
		submit()
	end)

	row.Parent = bar
	return true
end

function CodesController.start()
	Remotes.get("RedeemCodeResult").OnClientEvent:Connect(function(ok, message)
		local input = box
		local text = if type(message) == "string" and message ~= "" then message else nil
		if ok == true then
			if input then
				input.Text = ""
				UIAnim.punch(input, 0.15)
			end
			flashEdge(EDGE_OK)
			say(text or "Code redeemed!", true)
		else
			flashEdge(EDGE_BAD)
			say(text or "That code didn't work.", false)
		end
	end)
	-- SettingsController builds the bar; say so if it never did.
	task.delay(30, function()
		if not box then
			warn("[CodesController] the CODES bar was not built (Settings panel missing?).")
		end
	end)
end

return CodesController
