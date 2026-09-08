--!strict
--[[
	SlapDisplayService
	The Slap in its cage in the lobby: the owner's `Slap` model (a neon cage
	with the hand-on-a-stick inside) dressed as a shop display. SLAM! over
	the top, "SLAP PLAYERS AWAY!", the live Robux price and a prompt that
	opens the SAME Game Pass purchase the right-side offer opens
	(MonetizationService.promptSlapPass) - one purchase path, two doors.

	The model is left where the owner put it. The hand's slow turn and bob
	are drawn by the client (SlapDisplayController) so the server moves
	nothing per frame; the price on the sign is re-texted when the live
	lookup lands.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)

local MonetizationService = require(script.Parent.MonetizationService)
local StateService = require(script.Parent.StateService)

local SlapDisplayService = {}

local DISPLAY_NAME = "Slap"
local PROMPT_HOLD = 0.35
local PROMPT_RANGE = 16

local priceLabel: TextLabel? = nil
local prompt: ProximityPrompt? = nil
local display: Model? = nil

local function priceText(): string
	local price = MonetizationService.livePassPrice(MonetizationConfig.SlapPass.gamePassId)
	return if price then `R${price}` else "R$ ..."
end

local function label(parent: Instance, name: string, y: number, height: number, color: Color3, size: number, text: string): TextLabel
	local item = Instance.new("TextLabel")
	item.Name = name
	item.Size = UDim2.fromScale(1, height)
	item.Position = UDim2.fromScale(0, y)
	item.BackgroundTransparency = 1
	item.Font = Enum.Font.FredokaOne
	item.TextScaled = true
	item.TextColor3 = color
	item.TextStrokeTransparency = 0.05
	item.TextStrokeColor3 = Color3.fromRGB(10, 20, 40)
	item.Text = text
	item.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = size
	limit.Parent = item
	return item
end

function SlapDisplayService.retext()
	if priceLabel then
		priceLabel.Text = priceText()
	end
	if prompt then
		prompt.ObjectText = `Slap  ·  {priceText()}`
	end
	if display then
		display:SetAttribute("Price", MonetizationService.livePassPrice(MonetizationConfig.SlapPass.gamePassId) or 0)
	end
end

function SlapDisplayService.start()
	local model = workspace:FindFirstChild(DISPLAY_NAME)
	if not model or not model:IsA("Model") then
		warn(`[SlapDisplayService] no workspace.{DISPLAY_NAME} model - the cage display is not dressed`)
		return
	end
	display = model
	model:SetAttribute("SlapDisplay", true)

	local cf, size = model:GetBoundingBox()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	-- The sign, over the cage.
	local signAnchor = Instance.new("Part")
	signAnchor.Name = "SignAnchor"
	signAnchor.Size = Vector3.new(1, 1, 1)
	signAnchor.Transparency = 1
	signAnchor.Anchored = true
	signAnchor.CanCollide = false
	signAnchor.CanQuery = false
	signAnchor.CanTouch = false
	-- High enough that it clears the FREE! sign on the gift chest the owner
	-- stood ten studs away, from the spawn's line of sight.
	signAnchor.CFrame = CFrame.new(cf.Position.X, cf.Position.Y + size.Y / 2 + 7.5, cf.Position.Z)
	signAnchor.Parent = model

	local gui = Instance.new("BillboardGui")
	gui.Name = "Sign"
	gui.Size = UDim2.fromScale(16, 8)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 220
	gui.Adornee = signAnchor
	gui.Parent = signAnchor

	local slam = label(gui, "Slam", 0, 0.5, Color3.fromRGB(255, 255, 255), 72, "SLAM!")
	-- Swept by the client; white underneath so the rainbow reads clean.
	local gradient = Instance.new("UIGradient")
	gradient.Name = "Rainbow"
	gradient.Parent = slam
	label(gui, "Sub", 0.5, 0.24, Color3.fromRGB(255, 226, 90), 40, "SLAP PLAYERS AWAY!")
	priceLabel = label(gui, "Price", 0.75, 0.25, Color3.fromRGB(126, 255, 148), 42, priceText())

	-- The prompt: in front of the cage, on the side the spawn circle is.
	local toward = Vector3.new(0, 0, -34) - cf.Position
	local flat = Vector3.new(toward.X, 0, toward.Z)
	local front = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
	local anchor = Instance.new("Part")
	anchor.Name = "PromptAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = CFrame.new(cf.Position + front * (math.max(size.X, size.Z) / 2 + 2) + Vector3.new(0, 3 - cf.Position.Y, 0))
	anchor.Parent = model

	local p = Instance.new("ProximityPrompt")
	p.Name = "SlapBuyPrompt"
	p.ActionText = "Buy"
	p.ObjectText = `Slap  ·  {priceText()}`
	p.HoldDuration = PROMPT_HOLD
	p.MaxActivationDistance = PROMPT_RANGE
	p.RequiresLineOfSight = false
	p.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	p.Parent = anchor
	prompt = p

	-- A little life: a glow and a trickle of sparks inside the cage.
	local item = model:FindFirstChild("Item")
	local glowHost = if item and item:IsA("BasePart") then item else anchor
	local light = Instance.new("PointLight")
	light.Name = "CageGlow"
	light.Color = Color3.fromRGB(80, 220, 255)
	light.Brightness = 1.2
	light.Range = 18
	light.Shadows = false
	light.Parent = glowHost
	local attachment = Instance.new("Attachment")
	attachment.Name = "SparkAttachment"
	attachment.Parent = glowHost
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "Sparks"
	sparks.Texture = "rbxassetid://241594419"
	sparks.Color = ColorSequence.new(Color3.fromRGB(120, 230, 255), Color3.fromRGB(255, 255, 255))
	sparks.LightEmission = 0.8
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
	sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	sparks.Lifetime = NumberRange.new(1.2, 2)
	sparks.Rate = 5
	sparks.Speed = NumberRange.new(1, 2)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Parent = attachment

	model:SetAttribute("Price", MonetizationService.livePassPrice(MonetizationConfig.SlapPass.gamePassId) or 0)

	p.Triggered:Connect(function(player)
		if MonetizationService.ownsSlap(player) then
			StateService.notify(player, "info", "You own the Slap! Equip it in Storage > WEAPONS.")
			return
		end
		local ok, reason = MonetizationService.promptSlapPass(player)
		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
	end)

	print(`[SlapDisplayService] Slap cage dressed at {cf.Position}`)
end

return SlapDisplayService
