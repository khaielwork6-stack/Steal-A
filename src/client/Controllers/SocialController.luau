--!strict
--[[
	SocialController
	The client half of the social pass. Presentation and Roblox prompts only:
	nothing here decides a reward.

	  1. INVITE BUTTON. A small round button in MainUI.Top, next to the
	     Settings gear (the HUDLayoutController gear pattern: an invisible hit
	     area >= 44 px after MainUI's UIScale, a 44 px face inside). Opens
	     SocialService:PromptGameInvite. Hidden wherever
	     CanSendGameInviteAsync says no (or errors).
	  2. BOOST PILLS. "+20% FRIENDS" and "PREMIUM +10%" above the stat card,
	     from StatePush `social`. A non-Premium player sees a dimmed Premium
	     pill that opens MarketplaceService:PromptPremiumPurchase (config).
	  3. ONE-TIME PROMPTS after a reveal: favourite the game
	     (AvatarEditorService:PromptSetFavorite), then the experience
	     notification opt-in (ExperienceNotificationService). Each is asked
	     once per ACCOUNT: the server keeps the flag (SocialRequest).
	     Waits for the reveal (and any HUD-hiding camera moment) to finish.
]]

local AvatarEditorService = game:GetService("AvatarEditorService")
local ExperienceNotificationService = game:GetService("ExperienceNotificationService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local StateStore = require(script.Parent.Parent.StateStore)
local UIStateController = require(script.Parent.UIStateController)

local SocialController = {}

local player = Players.LocalPlayer

local FACE = 44
local MIN_TARGET = 44
local PILL_HEIGHT = 26

local function hasImage(id: string): boolean
	return id ~= "" and id ~= "rbxassetid://0"
end

local function corner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

--- Keeps `button` a >= 44 px target on screen under MainUI's UIScale.
local function keepTouchTarget(ui: ScreenGui, button: GuiObject, holder: GuiObject?, minFace: Vector2)
	local uiScale = ui:FindFirstChildWhichIsA("UIScale")
	local function size()
		local scale = if uiScale then math.max(uiScale.Scale, 0.1) else 1
		local side = math.ceil(MIN_TARGET / scale)
		local width = math.max(minFace.X, side)
		local height = math.max(minFace.Y, side)
		button.Size = UDim2.fromOffset(width, height)
		if holder then
			holder.Size = UDim2.new(0, width + 4, 1, 0)
		end
	end
	size()
	if uiScale then
		uiScale:GetPropertyChangedSignal("Scale"):Connect(size)
	end
end

-- ==========================================================
-- INVITE
-- ==========================================================

local function canInvite(): boolean
	local ok, result = pcall(SocialService.CanSendGameInviteAsync, SocialService, player)
	return ok and result == true
end

local function promptInvite()
	if not canInvite() then
		return
	end
	local ok, err = pcall(function()
		local options = Instance.new("ExperienceInviteOptions")
		options.PromptMessage = SocialConfig.INVITE_PROMPT_MESSAGE
		if SocialConfig.INVITE_MESSAGE_ID ~= "" then
			options.InviteMessageId = SocialConfig.INVITE_MESSAGE_ID
		end
		SocialService:PromptGameInvite(player, options)
	end)
	if not ok then
		warn(`[SocialController] invite prompt failed: {err}`)
	end
end

local function buildInviteButton(ui: ScreenGui)
	if ui:FindFirstChild("InviteButton", true) then
		return
	end
	local top = ui:FindFirstChild("Top")

	-- Joins the top strip's row like the Settings gear does; LayoutOrder -1
	-- puts it just left of the gear (LayoutOrder 0).
	local holder = Instance.new("Frame")
	holder.Name = "InviteButton"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0, 56, 1, 0)
	holder.LayoutOrder = -1
	holder.ZIndex = 5
	holder.Visible = false

	-- Deliberately not named after a panel: the pack script pairs a button
	-- with the Frame of the same name, and there is no "Invite" panel.
	local button = Instance.new("ImageButton")
	button.Name = "Invite"
	button.Size = UDim2.fromOffset(FACE, FACE)
	button.Position = UDim2.fromScale(0.5, 0.5)
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Image = ""
	button.ZIndex = 6
	button.Parent = holder

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromOffset(FACE, FACE)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.BackgroundColor3 = Color3.fromRGB(40, 190, 110)
	face.Active = false
	face.ZIndex = 6
	face.Parent = button
	corner(face, UDim.new(1, 0))
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(10, 60, 30)
	stroke.Parent = face

	if hasImage(SocialConfig.INVITE_ICON) then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.Image = SocialConfig.INVITE_ICON
		icon.Size = UDim2.fromScale(0.7, 0.7)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.ZIndex = 7
		icon.Parent = face
	else
		-- Text-only placeholder until the Codex icon lands.
		local plus = Instance.new("TextLabel")
		plus.Name = "Plus"
		plus.BackgroundTransparency = 1
		plus.Size = UDim2.fromScale(1, 1)
		plus.Font = Enum.Font.FredokaOne
		plus.Text = "+"
		plus.TextScaled = true
		plus.TextColor3 = Color3.new(1, 1, 1)
		plus.ZIndex = 7
		plus.Parent = face
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = 30
		limit.Parent = plus
	end

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.BackgroundTransparency = 1
	caption.Size = UDim2.fromOffset(60, 14)
	caption.Position = UDim2.new(0.5, 0, 1, -2)
	caption.AnchorPoint = Vector2.new(0.5, 0.5)
	caption.Font = Enum.Font.GothamBlack
	caption.Text = "INVITE"
	caption.TextSize = 11
	caption.TextColor3 = Color3.new(1, 1, 1)
	caption.TextStrokeTransparency = 0.3
	caption.ZIndex = 8
	caption.Parent = face

	keepTouchTarget(ui, button, holder, Vector2.new(FACE, FACE))

	-- Ours, not the pack's: claimed before it is parented, so the pack's
	-- DescendantAdded scan finds it already bound.
	UIAnim.claimButton(button)
	button.Activated:Connect(function()
		task.spawn(promptInvite)
	end)

	if top and top:IsA("GuiObject") then
		holder.Parent = top
	else
		holder.AnchorPoint = Vector2.new(1, 0)
		holder.Position = UDim2.new(1, -240, 0, 12)
		holder.Parent = ui
	end

	-- Visible only where Roblox allows invites; asked in the background.
	task.spawn(function()
		if canInvite() then
			holder.Visible = true
			UIAnim.popIn(holder, 0.6)
		end
	end)
end

-- ==========================================================
-- BOOST PILLS
-- ==========================================================

type Pill = { button: GuiButton, face: Frame, label: TextLabel }

local function makePill(parent: Instance, name: string, order: number, color: Color3, iconId: string): Pill
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	button.AutomaticSize = Enum.AutomaticSize.X
	button.Size = UDim2.fromOffset(0, PILL_HEIGHT)
	button.LayoutOrder = order
	button.Visible = false
	button.ZIndex = 6

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromOffset(0, PILL_HEIGHT)
	face.AnchorPoint = Vector2.new(0, 0.5)
	face.Position = UDim2.fromScale(0, 0.5)
	face.BackgroundColor3 = color
	face.Active = false
	face.ZIndex = 6
	face.Parent = button
	corner(face, UDim.new(1, 0))
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = face
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = face
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.Padding = UDim.new(0, 4)
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = face

	if hasImage(iconId) then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.Image = iconId
		icon.Size = UDim2.fromOffset(PILL_HEIGHT - 6, PILL_HEIGHT - 6)
		icon.LayoutOrder = 0
		icon.ZIndex = 7
		icon.Parent = face
	end

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, PILL_HEIGHT)
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 14
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.LayoutOrder = 1
	label.ZIndex = 7
	label.Parent = face

	button.Parent = parent
	-- The face sets the button's width; the button stays PILL_HEIGHT tall
	-- visually, and its hit area is grown for touch below.
	return { button = button, face = face, label = label }
end

local function buildPills(ui: ScreenGui): (Pill?, Pill?)
	local anchor = ui:WaitForChild("StatHUD", 15)
	if not anchor or not anchor:IsA("GuiObject") then
		return nil, nil
	end
	local strip = Instance.new("Frame")
	strip.Name = "SocialBoosts"
	strip.BackgroundTransparency = 1
	-- To the RIGHT of the stat card, bottom-aligned: above it the left rail
	-- (now five buttons tall with Trade) ran into the pills (seen in Studio).
	strip.AnchorPoint = Vector2.new(0, 1)
	strip.Position = UDim2.new(1, 8, 1, 0)
	strip.Size = UDim2.fromOffset(260, PILL_HEIGHT)
	strip.ZIndex = 6
	strip.Parent = anchor
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = strip

	local friends = makePill(strip, "FriendsBoost", 1, Color3.fromRGB(40, 170, 90), SocialConfig.FRIENDS_PILL_ICON)
	local premium = makePill(strip, "PremiumBoost", 2, Color3.fromRGB(220, 150, 20), SocialConfig.PREMIUM_PILL_ICON)
	-- Only the Premium pill does anything when pressed; its hit area is
	-- grown to a real touch target (the face stays pill-sized).
	premium.button.AutomaticSize = Enum.AutomaticSize.None
	premium.face:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local uiScale = ui:FindFirstChildWhichIsA("UIScale")
		local scale = if uiScale then math.max(uiScale.Scale, 0.1) else 1
		local width = premium.face.AbsoluteSize.X / scale
		premium.button.Size = UDim2.fromOffset(math.max(width, MIN_TARGET / scale), math.max(PILL_HEIGHT, MIN_TARGET / scale))
	end)
	-- Both are ours (the friends pill only so the pack's scanner leaves it be).
	UIAnim.claimButton(friends.button)
	UIAnim.claimButton(premium.button)
	return friends, premium
end

local function renderPills(friends: Pill, premium: Pill, social: any)
	local friendBoost = if type(social) == "table" then tonumber(social.friendBoost) or 0 else 0
	friends.button.Visible = friendBoost > 0
	friends.label.Text = `+{friendBoost}% FRIENDS`

	local isPremium = type(social) == "table" and social.premium == true
	local premiumBoost = if type(social) == "table" then tonumber(social.premiumBoost) or 0 else 0
	if isPremium and premiumBoost > 0 then
		premium.button.Visible = true
		premium.face.BackgroundTransparency = 0
		premium.label.Text = `PREMIUM +{premiumBoost}%`
		premium.button:SetAttribute("Upsell", false)
	elseif type(social) == "table" and social.premiumOffer == true then
		-- The offer: dimmed, and a tap opens Roblox's Premium sheet.
		premium.button.Visible = true
		premium.face.BackgroundTransparency = 0.45
		premium.label.Text = `PREMIUM +{math.floor(SocialConfig.PREMIUM_BOOST * 100 + 0.5)}%`
		premium.button:SetAttribute("Upsell", true)
	else
		premium.button.Visible = false
		premium.button:SetAttribute("Upsell", false)
	end
end

-- ==========================================================
-- ONE-TIME PROMPTS
-- ==========================================================

local promptRunning = false

local function markPrompted(which: string)
	Remotes.get("SocialRequest"):FireServer("prompted", which)
end

--- Waits until the HUD is back (the reveal camera and any panel claim are
--- over), at most `limit` seconds.
local function waitForCalm(limit: number)
	local deadline = os.clock() + limit
	while UIStateController.isSuppressed() and os.clock() < deadline do
		task.wait(0.5)
	end
end

local function askFavorite()
	local already = false
	local checkedOk, favorited = pcall(function()
		return AvatarEditorService:GetFavorite(game.PlaceId, Enum.AvatarItemType.Asset)
	end)
	if checkedOk and favorited == true then
		already = true
	end
	if not already then
		local closed = false
		local connection = AvatarEditorService.PromptSetFavoriteCompleted:Connect(function()
			closed = true
		end)
		local ok, err = pcall(function()
			AvatarEditorService:PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)
		end)
		if ok then
			local deadline = os.clock() + 60
			while not closed and os.clock() < deadline do
				task.wait(0.25)
			end
		else
			warn(`[SocialController] favourite prompt failed: {err}`)
		end
		connection:Disconnect()
		if not ok then
			-- Not shown: try again after a later reveal.
			return
		end
	end
	markPrompted("favorite")
end

local function askNotifications()
	local ok, can = pcall(function()
		return ExperienceNotificationService:CanPromptOptInAsync()
	end)
	if not ok then
		return -- unknown: try again after a later reveal
	end
	if can ~= true then
		-- Already opted in, or not eligible: a definitive answer.
		markPrompted("notifications")
		return
	end
	local closed = false
	local connection = ExperienceNotificationService.OptInPromptClosed:Connect(function()
		closed = true
	end)
	local shown, err = pcall(function()
		ExperienceNotificationService:PromptOptIn()
	end)
	if shown then
		markPrompted("notifications")
		local deadline = os.clock() + 60
		while not closed and os.clock() < deadline do
			task.wait(0.25)
		end
	else
		warn(`[SocialController] notification opt-in failed: {err}`)
	end
	connection:Disconnect()
end

local function afterReveal()
	if promptRunning then
		return
	end
	local state = StateStore.get()
	local social = state and state.social
	if type(social) ~= "table" then
		return
	end
	local wantFavorite = SocialConfig.FAVORITE_PROMPT_ENABLED and social.favoritePrompted ~= true
	local wantNotify = SocialConfig.NOTIFICATION_OPT_IN_ENABLED and social.notificationsPrompted ~= true
	if not wantFavorite and not wantNotify then
		return
	end
	promptRunning = true
	task.wait(SocialConfig.FIRST_REVEAL_PROMPT_DELAY)
	waitForCalm(20)
	if wantFavorite then
		askFavorite()
		waitForCalm(10)
	end
	if wantNotify then
		askNotifications()
	end
	promptRunning = false
end

-- ==========================================================
-- START
-- ==========================================================

function SocialController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		return
	end

	if SocialConfig.INVITE_BUTTON_ENABLED then
		buildInviteButton(ui)
	end

	-- A reveal cue for THIS player (the server only sends it to the owner).
	Remotes.get("HatchReveal").OnClientEvent:Connect(function()
		task.spawn(afterReveal)
	end)

	local friends, premium = buildPills(ui)
	if friends and premium then
		local lastKey = ""
		StateStore.subscribe(function(state)
			local social = state.social
			local key = if type(social) == "table"
				then `{social.friendBoost}|{social.premium}|{social.premiumBoost}|{social.premiumOffer}`
				else "-"
			if key == lastKey then
				return
			end
			lastKey = key
			renderPills(friends, premium, social)
		end)
		premium.button.Activated:Connect(function()
			if premium.button:GetAttribute("Upsell") ~= true then
				return
			end
			local ok, err = pcall(MarketplaceService.PromptPremiumPurchase, MarketplaceService, player)
			if not ok then
				warn(`[SocialController] premium prompt failed: {err}`)
			end
		end)
	end
end

return SocialController
