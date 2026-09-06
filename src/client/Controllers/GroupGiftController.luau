--!strict
--[[
	GroupGiftController
	The "Free Gift!" popup: +10,000 Speed for joining the group.

	BUILT FROM THE PACK, TO THE REFERENCE
	  the Shop panel's frame, gradient and stroke -> the window
	  the Shop panel's Top bar and Close X        -> "Free Gift!" header
	  the Gamepass card, three times             -> Like / Favorite / Join cards
	  the DROP button                            -> the giant CLAIM
	Same reason as every other screen: it cannot look foreign to the game if it
	is literally made of the game's parts.

	WHAT THE CLIENT DOES AND DOES NOT DO
	  * It shows Roblox's OWN group prompt (GroupService:PromptJoinAsync). There
	    is no imitation of that prompt anywhere here.
	  * When that prompt closes, it sends `GroupGiftRequest`. Empty. A knock.
	  * It renders CLAIMED when `StatePush.groupGift.claimed` says so - which is
	    the server's word, saved with the profile, so it survives a rejoin.
	  It never grants, never decides membership, and never marks anything.

	THE OPENER
	A small "Gift" button sits in the HUD. It is NOT placed under `Buttons`, and
	deliberately does not share a name with any frame in `Frames`, so the pack's
	button script animates it but does not try to open a panel for it.
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = require(script.Parent.UIStateController)

local GroupGiftController = {}

local player = Players.LocalPlayer

local panel: Frame? = nil
local opener: GuiButton? = nil
local claimButton: GuiButton? = nil
local claimLabel: TextLabel? = nil
local rewardLabel: TextLabel? = nil
local art: GuiObject? = nil
local floatConnection: RBXScriptConnection? = nil
local open = false
local prompting = false
local latest: any = nil

local GIFT_COLOR = Color3.fromRGB(96, 200, 255)
local GIFT_ACCENT = Color3.fromRGB(24, 110, 200)
local CLAIM_COLOR = Color3.fromRGB(96, 230, 118)
local CLAIM_ACCENT = Color3.fromRGB(28, 150, 66)
local CLAIMED_COLOR = Color3.fromRGB(150, 156, 170)
local CLAIMED_ACCENT = Color3.fromRGB(70, 74, 88)

local STEPS = {
	{ title = "1. Like the game!", body = "Hit the thumbs up on the game page." },
	{ title = "2. Favorite the game!", body = "Tap the star so it's easy to find." },
	{ title = "3. Join the community!", body = "Join our group, then press CLAIM." },
}

-- ==========================================================
-- HELPERS
-- ==========================================================

local function mainUi(): ScreenGui?
	local found = ShopKit.mainUi()
	return if found and found:IsA("ScreenGui") then found else nil
end

--- The layer that mirrors `Frames`, shared with the Trail Shop so both panels
--- resolve their scale against the same box the real Shop does.
local function layerFor(ui: ScreenGui): Frame?
	local frames = ui:FindFirstChild("Frames")
	if not frames or not frames:IsA("GuiObject") then
		return nil
	end
	local existing = ui:FindFirstChild("TrailShopLayer")
	if existing and existing:IsA("Frame") then
		return existing
	end
	local made = Instance.new("Frame")
	made.Name = "TrailShopLayer"
	made.BackgroundTransparency = 1
	made.Size = frames.Size
	made.Position = frames.Position
	made.AnchorPoint = frames.AnchorPoint
	made.ZIndex = 10
	local ratio = frames:FindFirstChildOfClass("UIAspectRatioConstraint")
	if ratio then
		ratio:Clone().Parent = made
	end
	made.Parent = ui
	return made
end

local function claimedState(): boolean
	return latest ~= nil and latest.claimed == true
end

-- ==========================================================
-- CLOSE / OPEN
-- ==========================================================

local function close()
	if not open then
		return
	end
	open = false
	UIStateController.release("gift")
	if floatConnection then
		floatConnection:Disconnect()
		floatConnection = nil
	end
	local frame = panel
	if not frame then
		return
	end
	local scale = frame:FindFirstChildOfClass("UIScale")
	if scale then
		local tween = TweenService:Create(scale, UIAnim.SHRINK, { Scale = 0.85 })
		tween:Play()
		tween.Completed:Once(function()
			if not open and frame.Parent then
				frame.Visible = false
			end
			scale.Scale = 1
		end)
	else
		frame.Visible = false
	end
end

-- ==========================================================
-- CLAIM FLOW
-- ==========================================================

--- CLAIM pressed. Shows Roblox's group prompt, then knocks on the server. If
--- the player is already in the group the prompt returns AlreadyMember at once
--- and the knock still goes out - which is exactly right for someone who joined
--- from the website.
local function claim()
	if prompting or claimedState() then
		return
	end
	local groupId = latest and tonumber(latest.groupId) or 0
	if groupId <= 0 then
		return
	end
	prompting = true

	local button = claimButton
	if button then
		UIAnim.punch(button, 0.16)
	end

	task.spawn(function()
		local ok, status = pcall(function()
			return GroupService:PromptJoinAsync(groupId)
		end)
		prompting = false
		if not ok then
			warn("[GroupGiftController] group prompt failed:", status)
		end
		-- Whatever the prompt said, the SERVER decides. It re-checks membership
		-- itself and either pays out once or explains why not.
		Remotes.get("GroupGiftRequest"):FireServer()
	end)
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function buildStepCard(parent: Instance, index: number, step: { title: string, body: string })
	local card = ShopKit.card()
	if not card then
		return
	end
	card.Name = `Step{index}`
	card.LayoutOrder = index
	ShopKit.fillCard(card, {
		title = step.title,
		description = step.body,
		price = "",
		icon = if index == 3 then ShopKit.Icons.Shop else ShopKit.Icons.Speed,
		color = GIFT_COLOR,
		accent = GIFT_ACCENT,
		hidePrice = true,
	})
	card.Parent = parent
end

local function build(): boolean
	if panel then
		return true
	end
	local ui = mainUi()
	local frames = ui and ui:FindFirstChild("Frames")
	local shop = frames and frames:FindFirstChild("Shop")
	local layer = ui and layerFor(ui)
	if not ui or not shop or not shop:IsA("Frame") or not layer then
		return false
	end
	ShopKit.warm()

	local clone = shop:Clone()
	clone.Name = "GroupGift"
	clone.Visible = false
	clone.Parent = layer

	-- Strip the scroll body entirely; this screen is a fixed composition.
	local scroller = clone:FindFirstChild("ScrollingFrame")
	if scroller then
		scroller:Destroy()
	end

	local top = clone:FindFirstChild("Top")
	local title = top and top:FindFirstChild("Frame") and top.Frame:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = "Free Gift!"
	end
	local closeButton = top and top:FindFirstChild("Close", true)
	if closeButton and closeButton:IsA("TextButton") then
		UIAnim.claimButton(closeButton)
		closeButton.Activated:Connect(close)
	end

	-- BODY: art left, headline right, three cards across, CLAIM along the foot.
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(0.94, 0.8)
	body.Position = UDim2.fromScale(0.5, 0.58)
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Parent = clone

	-- The reward art: the Speed icon, big, on a soft glow. Floats gently.
	local artHolder = Instance.new("Frame")
	artHolder.Name = "Art"
	artHolder.BackgroundTransparency = 1
	artHolder.Size = UDim2.fromScale(0.34, 0.5)
	artHolder.Position = UDim2.fromScale(0.02, 0.02)
	artHolder.Parent = body

	local glow = Instance.new("ImageLabel")
	glow.Name = "Glow"
	glow.BackgroundTransparency = 1
	glow.Image = "rbxassetid://92627249277540" -- the pack's rays burst
	glow.ImageColor3 = GIFT_COLOR
	glow.ImageTransparency = 0.35
	glow.Size = UDim2.fromScale(1.3, 1.3)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.ZIndex = 2
	glow.Parent = artHolder
	local glowRatio = Instance.new("UIAspectRatioConstraint")
	glowRatio.AspectRatio = 1
	glowRatio.Parent = glow

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Image = ShopKit.Icons.Speed
	icon.Size = UDim2.fromScale(0.86, 0.86)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.ZIndex = 3
	icon.Parent = artHolder
	local iconRatio = Instance.new("UIAspectRatioConstraint")
	iconRatio.AspectRatio = 1
	iconRatio.Parent = icon
	art = artHolder

	-- Headline: "~ LIMITED TIME! ~" over "10,000 SPEED!".
	local function headline(name: string, text: string, color: Color3, y: number, height: number): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(0.6, height)
		label.Position = UDim2.fromScale(0.38, y)
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.Text = text
		label.TextColor3 = color
		label.TextStrokeColor3 = Color3.fromRGB(10, 14, 30)
		label.TextStrokeTransparency = 0
		label.ZIndex = 3
		label.Parent = body
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(10, 14, 30)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.Parent = label
		return label
	end
	headline("Limited", "~ LIMITED TIME! ~", Color3.fromRGB(255, 90, 90), 0.06, 0.16)
	rewardLabel = headline("Reward", "10,000 SPEED!", Color3.fromRGB(96, 240, 160), 0.24, 0.24)

	-- The three requirement cards.
	local steps = Instance.new("Frame")
	steps.Name = "Steps"
	steps.BackgroundTransparency = 1
	steps.Size = UDim2.fromScale(1, 0.26)
	steps.Position = UDim2.fromScale(0, 0.55)
	steps.Parent = body
	local stepLayout = Instance.new("UIGridLayout")
	stepLayout.CellSize = UDim2.fromScale(0.32, 1)
	stepLayout.CellPadding = UDim2.fromScale(0.02, 0)
	stepLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stepLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	stepLayout.Parent = steps
	for index, step in STEPS do
		buildStepCard(steps, index, step)
	end

	-- CLAIM: the DROP button, recoloured. Same anatomy, so it animates the same.
	local dropSource = ui:FindFirstChild("DROP BUTTON NEW")
	if dropSource and dropSource:IsA("TextButton") then
		local button = dropSource:Clone()
		button.Name = "Claim"
		button.Visible = true
		-- GIANT, per the brief: two thirds of the panel wide and tall enough to
		-- be the obvious thing on the screen. The aspect constraint keeps it a
		-- pill rather than a bar as the panel scales.
		button.Size = UDim2.fromScale(0.66, 0.2)
		button.Position = UDim2.fromScale(0.5, 0.905)
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.ZIndex = 4
		local ratio = button:FindFirstChildOfClass("UIAspectRatioConstraint")
		if ratio then
			ratio.AspectRatio = 4.6
		end
		for _, extra in button:GetChildren() do
			if extra.Name == "_RippleContainer" or extra:IsA("UIScale") then
				extra:Destroy()
			end
		end
		button:SetAttribute("_UIHandlerSetup", nil)
		button:SetAttribute("AnimBound", nil)
		local label = button:FindFirstChild("Title")
		if label and label:IsA("TextLabel") then
			label.Text = "CLAIM"
			claimLabel = label
		end
		button.Parent = body
		UIAnim.claimButton(button)
		button.Activated:Connect(claim)
		claimButton = button
	end

	panel = clone
	return true
end

--- Paints the CLAIM/CLAIMED state and the reward number from the push.
local function repaint()
	local button = claimButton
	local label = claimLabel
	if rewardLabel and latest and tonumber(latest.reward) then
		rewardLabel.Text = `{NumberFormat.comma(latest.reward)} SPEED!`
	end
	if not button or not label then
		return
	end
	local claimed = claimedState()
	label.Text = if claimed then "CLAIMED!" else "CLAIM"
	button.Active = not claimed
	button.AutoButtonColor = false
	button.BackgroundColor3 = if claimed then CLAIMED_ACCENT else CLAIM_ACCENT
	local face = button:FindFirstChild("Frame")
	local gradient = face and face:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = if claimed
			then ColorSequence.new(CLAIMED_COLOR, CLAIMED_ACCENT)
			else ColorSequence.new(CLAIM_COLOR, CLAIM_ACCENT)
	end
	local stroke = face and face:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if claimed then CLAIMED_COLOR else Color3.fromRGB(170, 255, 190)
	end
	if opener then
		-- The opener dims once there is nothing left to claim; it stays so the
		-- player can re-read the steps, but it stops asking for attention.
		local face2 = opener:FindFirstChild("Frame")
		local grad2 = face2 and face2:FindFirstChildOfClass("UIGradient")
		if grad2 then
			grad2.Color = if claimed
				then ColorSequence.new(CLAIMED_COLOR, CLAIMED_ACCENT)
				else ColorSequence.new(GIFT_COLOR, GIFT_ACCENT)
		end
	end
end

local function show()
	if open or not build() then
		return
	end
	open = true
	repaint()
	local frame = panel :: Frame
	UIStateController.claim("gift")
	frame.Visible = true
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	scale.Scale = 0.85
	TweenService:Create(scale, UIAnim.POP, { Scale = 1 }):Play()

	-- Reward art bobs while the window is open. One connection, dropped on close.
	local target = art
	if target then
		local start = os.clock()
		local base = target.Position
		if floatConnection then
			floatConnection:Disconnect()
		end
		floatConnection = RunService.RenderStepped:Connect(function()
			if not target.Parent then
				return
			end
			target.Position = base + UDim2.fromScale(0, math.sin((os.clock() - start) * 2.2) * 0.02)
		end)
	end

	local list = {}
	local steps = frame:FindFirstChild("Steps", true)
	if steps then
		for _, child in steps:GetChildren() do
			if child:IsA("GuiObject") then
				table.insert(list, child)
			end
		end
	end
	ShopKit.cascadeIn(list, 0.05)
end

--- The HUD opener. Cloned from the Top "BASE" button so it matches, retitled,
--- recoloured, and hung under it on the right.
local function buildOpener(ui: ScreenGui)
	if opener then
		return
	end
	local top = ui:FindFirstChild("Top")
	local source = top and top:FindFirstChild("Base")
	if not source or not source:IsA("TextButton") then
		return
	end
	local button = source:Clone()
	button.Name = "GiftOpener"
	button.LayoutOrder = 2
	button:SetAttribute("_UIHandlerSetup", nil)
	button:SetAttribute("AnimBound", nil)
	for _, extra in button:GetChildren() do
		if extra.Name == "_RippleContainer" or extra:IsA("UIScale") then
			extra:Destroy()
		end
	end
	local label = button:FindFirstChild("Title")
	if label and label:IsA("TextLabel") then
		label.Text = "GIFT"
	end
	button.BackgroundColor3 = GIFT_ACCENT
	local face = button:FindFirstChild("Frame")
	local gradient = face and face:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(GIFT_COLOR, GIFT_ACCENT)
	end
	local stroke = face and face:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = Color3.fromRGB(170, 230, 255)
	end
	button.Parent = top
	UIAnim.claimButton(button)
	button.Activated:Connect(function()
		if open then
			close()
		else
			show()
		end
	end)
	opener = button

	-- BASE is retired. It only ever teleported the player home, which the
	-- respawn already does, and it was the one thing in the strip pulling
	-- attention from GIFT. It survives just long enough to donate its look.
	source:Destroy()
end

-- ==========================================================
-- START
-- ==========================================================

function GroupGiftController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		local ui = mainUi()
		if ui then
			buildOpener(ui)
		end
		local previous = latest
		latest = state.groupGift
		repaint()
		-- The moment the server says claimed, celebrate on the button itself.
		if previous and not previous.claimed and claimedState() and claimButton then
			ShopKit.shine(claimButton :: GuiObject)
			UIAnim.punch(claimButton :: GuiObject, 0.22)
		end
	end)

	player.CharacterAdded:Connect(close)
end

return GroupGiftController
