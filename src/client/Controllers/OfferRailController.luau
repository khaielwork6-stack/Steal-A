--!strict
--[[
	OfferRailController
	The two stacked offer buttons on the right of the screen: the pack's
	"UI FOR ANIMAL + SLAP" frame, kept for its plate art, hover and pulse,
	with the placeholder content replaced.

	  TOP     the Guardian on sale in the global rotation right now: a live
	          3D preview of the animal, its name, LIMITED!, the live Robux
	          price and the time left. Tapping it opens the Game Pass
	          purchase for THAT animal (the server decides which one that
	          is; the client only knocks).
	  BOTTOM  the Slap: its real model, SLAP! in rainbow, OP DEAL, the live
	          price. Tapping it opens the Slap's Game Pass purchase - the
	          same prompt the lobby cage opens.

	OWNED means owned. The price reads OWNED, the tap does nothing, the
	button keeps only its idle breathing. Equipping happens in Storage.

	Everything drawn here comes from StatePush (`guardians`, `weapons`):
	ownership, prices and the rotation are the server's word, and the icon
	swaps by itself at the three-hour boundary because the state does.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local ModelPreview = require(ReplicatedStorage.Shared.Util.ModelPreview)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local OfferRailController = {}

local player = Players.LocalPlayer

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 106, 122)),
	ColorSequenceKeypoint.new(0.18, Color3.fromRGB(255, 176, 92)),
	ColorSequenceKeypoint.new(0.36, Color3.fromRGB(255, 238, 120)),
	ColorSequenceKeypoint.new(0.54, Color3.fromRGB(122, 236, 148)),
	ColorSequenceKeypoint.new(0.72, Color3.fromRGB(112, 196, 255)),
	ColorSequenceKeypoint.new(0.86, Color3.fromRGB(186, 142, 255)),
	ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 106, 122)),
})
local RAINBOW_PERIOD = 3.6
local PRICE_COLOR = Color3.fromRGB(126, 255, 148)
local OWNED_COLOR = Color3.fromRGB(190, 196, 210)
local TAG_LIMITED = Color3.fromRGB(255, 92, 92)
local TAG_DEAL = Color3.fromRGB(255, 196, 60)

type Offer = {
	kind: "guardian" | "slap",
	button: TextButton,
	badge: ImageLabel,
	icon: ImageLabel,
	title: TextLabel,
	price: TextLabel,
	tag: TextLabel,
	timer: TextLabel?,
	gradient: UIGradient?,
	scale: UIScale,
	preview: ModelPreview.Handle?,
	previewKey: string?,
	owned: boolean,
	endsAt: number?,
	phase: number,
}

local offers: { Offer } = {}
local latest: any = nil
local lastSecond = -1

-- ==========================================================
-- BUILD
-- ==========================================================

local function findRail(ui: Instance): Frame?
	for _, child in ui:GetChildren() do
		if child:IsA("Frame") and child.Name:upper():find("UI FOR ANIMAL", 1, true) then
			return child
		end
	end
	return nil
end

local function smallLabel(parent: Instance, name: string, zIndex: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.1
	label.TextStrokeColor3 = Color3.fromRGB(20, 16, 40)
	label.ZIndex = zIndex
	label.Parent = parent
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(20, 16, 40)
	stroke.Parent = label
	return label
end

local function buildOffer(button: TextButton, kind: "guardian" | "slap"): Offer?
	local badge = button:FindFirstChildOfClass("ImageLabel")
	local icon = badge and badge:FindFirstChildOfClass("ImageLabel")
	local title = icon and icon:FindFirstChild("Title")
	local price = icon and icon:FindFirstChild("Price")
	if not badge or not icon or not title or not title:IsA("TextLabel") or not price or not price:IsA("TextLabel") then
		return nil
	end

	button.Text = ""
	-- The purple placeholder goes; the real model takes its plate.
	icon.Image = ""
	icon.BackgroundTransparency = 1
	title.TextStrokeTransparency = 0
	price.TextStrokeTransparency = 0

	-- A small rotated tag at the badge's corner: LIMITED! / OP DEAL.
	local tag = smallLabel(badge, "Tag", title.ZIndex + 1)
	tag.AnchorPoint = Vector2.new(1, 0)
	tag.Position = UDim2.fromScale(1.04, -0.04)
	tag.Size = UDim2.fromScale(0.6, 0.2)
	tag.Rotation = 10
	tag.BackgroundTransparency = 0
	tag.BackgroundColor3 = TAG_LIMITED
	local tagCorner = Instance.new("UICorner")
	tagCorner.CornerRadius = UDim.new(0.4, 0)
	tagCorner.Parent = tag
	local tagPad = Instance.new("UIPadding")
	tagPad.PaddingLeft = UDim.new(0.08, 0)
	tagPad.PaddingRight = UDim.new(0.08, 0)
	tagPad.Parent = tag

	-- The rotation countdown, low over the preview, guardian only.
	local timer: TextLabel? = nil
	if kind == "guardian" then
		local made = smallLabel(icon, "Timer", title.ZIndex + 1)
		made.AnchorPoint = Vector2.new(0.5, 1)
		made.Position = UDim2.fromScale(0.5, 0.74)
		made.Size = UDim2.fromScale(0.9, 0.15)
		made.Text = "--:--:--"
		timer = made
	end

	local gradient: UIGradient? = nil
	if kind == "slap" then
		local made = Instance.new("UIGradient")
		made.Name = "Rainbow"
		made.Color = RAINBOW
		made.Parent = title
		gradient = made
	end

	local scale = button:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = button

	UIAnim.claimButton(button)

	local offer: Offer = {
		kind = kind,
		button = button,
		badge = badge,
		icon = icon,
		title = title,
		price = price,
		tag = tag,
		timer = timer,
		gradient = gradient,
		scale = scale,
		owned = false,
		phase = math.random() * math.pi * 2,
	}

	button.Activated:Connect(function()
		if offer.owned then
			-- Nothing to buy; a tiny acknowledgement and no prompt.
			UIAnim.punch(button, 0.05)
			return
		end
		UIAnim.punch(button, 0.12)
		Remotes.get("PurchaseRequest"):FireServer(if kind == "guardian" then "guardian" else "slap")
	end)

	return offer
end

-- ==========================================================
-- PAINT
-- ==========================================================

local function previewSource(kind: "guardian" | "slap", key: string): (Model?, number)
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	if not assets then
		return nil, 0
	end
	if kind == "guardian" then
		local def = BaseGuardianConfig.ByKey[key]
		local folder = assets:FindFirstChild("BaseGuardians")
		local model = if def and folder then folder:FindFirstChild(def.modelName) else nil
		return (if model and model:IsA("Model") then model else nil), ModelPreview.yawFor(if def then def.faceLocal else nil)
	end
	local weapons = assets:FindFirstChild("Weapons")
	local model = weapons and weapons:FindFirstChild("Slap")
	return (if model and model:IsA("Model") then model else nil), 0
end

local function mountPreview(offer: Offer, key: string)
	if offer.previewKey == key and offer.preview then
		return
	end
	if offer.preview then
		offer.preview.destroy()
		offer.preview = nil
	end
	offer.previewKey = key
	local source, yaw = previewSource(offer.kind, key)
	if source then
		offer.preview = ModelPreview.mount(offer.icon, source, { faceYaw = yaw, fit = 1.05 })
	end
end

local function priceText(price: number?): string
	return if price then `R${price}` else "R$ ..."
end

local function paintGuardian(offer: Offer, guardians: any)
	local key = guardians.rotationKey
	local def = BaseGuardianConfig.ByKey[key]
	if not def then
		return
	end
	local owned = guardians.owned and guardians.owned[key] == true
	offer.owned = owned
	offer.endsAt = tonumber(guardians.rotationEndsAt)

	offer.title.Text = string.upper(def.name)
	offer.title.TextColor3 = def.color
	offer.tag.Text = "LIMITED!"
	offer.tag.BackgroundColor3 = TAG_LIMITED
	offer.tag.Visible = true
	if owned then
		offer.price.Text = "OWNED"
		offer.price.TextColor3 = OWNED_COLOR
	else
		offer.price.Text = priceText(guardians.prices and guardians.prices[key])
		offer.price.TextColor3 = PRICE_COLOR
	end
	mountPreview(offer, key)
end

local function paintSlap(offer: Offer, weapons: any)
	local owned = weapons.owned and weapons.owned.Slap == true
	offer.owned = owned
	offer.title.Text = "SLAP!"
	offer.title.TextColor3 = Color3.fromRGB(255, 255, 255)
	offer.tag.Text = "OP DEAL"
	offer.tag.BackgroundColor3 = TAG_DEAL
	offer.tag.Visible = not owned
	if owned then
		offer.price.Text = "OWNED"
		offer.price.TextColor3 = OWNED_COLOR
	else
		offer.price.Text = priceText(weapons.slapPrice)
		offer.price.TextColor3 = PRICE_COLOR
	end
	mountPreview(offer, "Slap")
end

local function paint(state: any)
	for _, offer in offers do
		if offer.kind == "guardian" and type(state.guardians) == "table" then
			paintGuardian(offer, state.guardians)
		elseif offer.kind == "slap" and type(state.weapons) == "table" then
			paintSlap(offer, state.weapons)
		end
	end
end

-- ==========================================================
-- MOTION
-- ==========================================================

local function tick()
	local now = os.clock()
	local serverNow = workspace:GetServerTimeNow()
	local second = math.floor(serverNow)
	local newSecond = second ~= lastSecond
	lastSecond = second

	for _, offer in offers do
		if not offer.button.Parent then
			continue
		end
		-- A slow breath, whether or not it is owned.
		offer.scale.Scale = 1 + math.sin(now * 2.0 + offer.phase) * 0.014
		if offer.gradient then
			local t = now / RAINBOW_PERIOD
			offer.gradient.Offset = Vector2.new((t % 1) * 2 - 1, 0)
		end
		if offer.tag.Visible then
			offer.tag.Rotation = 10 + math.sin(now * 3.1 + offer.phase) * 3
		end
		if offer.timer and newSecond then
			local endsAt = offer.endsAt
			offer.timer.Text = if endsAt then BaseGuardianConfig.formatCountdown(endsAt - serverNow) else "--:--:--"
		end
	end
end

-- ==========================================================
-- START
-- ==========================================================

function OfferRailController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	local rail = if ui then findRail(ui) else nil
	if not rail then
		warn("[OfferRailController] the UI FOR ANIMAL + SLAP frame is missing - offers disabled.")
		return
	end

	local buttons: { TextButton } = {}
	for _, child in rail:GetChildren() do
		if child:IsA("TextButton") then
			table.insert(buttons, child)
		end
	end
	table.sort(buttons, function(a, b)
		if a.LayoutOrder ~= b.LayoutOrder then
			return a.LayoutOrder < b.LayoutOrder
		end
		return a.AbsolutePosition.Y < b.AbsolutePosition.Y
	end)
	if #buttons < 2 then
		warn("[OfferRailController] expected two offer buttons in the rail - offers disabled.")
		return
	end

	local top = buildOffer(buttons[1], "guardian")
	local bottom = buildOffer(buttons[2], "slap")
	if top then
		table.insert(offers, top)
	end
	if bottom then
		table.insert(offers, bottom)
	end
	-- Anything beyond the two is pack demo furniture.
	for index = 3, #buttons do
		buttons[index]:Destroy()
	end

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		latest = state
		paint(state)
	end)

	RunService.RenderStepped:Connect(tick)
end

return OfferRailController
