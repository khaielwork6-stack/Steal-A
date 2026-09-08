--!strict
--[[
	GuardianShopService
	The rotating Guardian shop in the lobby: a pedestal with the animal
	currently on sale standing on it, a sign over it (name, LIMITED TIME!,
	the live Robux price, the countdown to the next one) and a prompt to buy
	it - or, for a player who already owns it, to equip it.

	WHICH ANIMAL is BaseGuardianConfig.rotation(serverTime): three-hour slots
	of the Unix clock, so every server shows the same one and a fresh server
	shows the same remaining time as the others. A one-second loop here only
	notices the boundary and swaps the display; the countdown text itself is
	drawn by the client (GuardianShopController) from GetServerTimeNow, so
	nothing is replicated once a second.

	THE PRICE is never typed here. MonetizationService.livePassPrice is what
	the sign shows, and `retext` repaints it when the live lookup lands.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local LobbyLayout = require(ReplicatedStorage.Shared.LobbyLayout)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local BaseGuardianService = require(script.Parent.BaseGuardianService)
local DataService = require(script.Parent.DataService)
local GuardianService = require(script.Parent.GuardianService)
local MonetizationService = require(script.Parent.MonetizationService)
local StateService = require(script.Parent.StateService)

local GuardianShopService = {}

local MODEL_NAME = "GuardianShop"
local PEDESTAL_HEIGHT = 3.6
local PEDESTAL_FOOTPRINT = 11
local RING_DIAMETER = 18
local PROMPT_HOLD = 0.35
local PROMPT_RANGE = 16

local shop: Model? = nil
local frame: CFrame = CFrame.new()
local pedestalTop = 0
local currentKey = ""
local ring: BasePart? = nil
local prompt: ProximityPrompt? = nil
local labels: { [string]: TextLabel } = {}

local function priceText(key: string): string
	local def = BaseGuardianConfig.ByKey[key]
	local price = if def then MonetizationService.livePassPrice(def.gamePassId) else nil
	return if price then `R${price}` else "R$ ..."
end

local function label(parent: Instance, name: string, y: number, height: number, color: Color3, size: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Size = UDim2.fromScale(1, height)
	text.Position = UDim2.fromScale(0, y)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = color
	text.TextStrokeTransparency = 0.1
	text.TextStrokeColor3 = Color3.fromRGB(14, 12, 30)
	text.Text = ""
	text.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = size
	limit.Parent = text
	return text
end

--- The imported pedestal, scaled to the shop's size and stood on the floor.
local function buildPedestal(parent: Instance): number
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local template = assets and assets:FindFirstChild("Pedestal")
	local floorY = frame.Position.Y
	if not template or not template:IsA("Model") then
		local block = Instance.new("Part")
		block.Name = "Pedestal"
		block.Size = Vector3.new(PEDESTAL_FOOTPRINT, PEDESTAL_HEIGHT, PEDESTAL_FOOTPRINT)
		block.CFrame = CFrame.new(frame.Position + Vector3.new(0, PEDESTAL_HEIGHT / 2, 0))
		block.Anchored = true
		block.Color = Color3.fromRGB(48, 52, 70)
		block.Material = Enum.Material.Slate
		block.Parent = parent
		return floorY + PEDESTAL_HEIGHT
	end

	local pedestal = template:Clone()
	pedestal.Name = "Pedestal"
	for _, descendant in pedestal:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = true
			descendant.CanQuery = true
		elseif descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
	local minCorner, maxCorner = LootModel.worldExtents(pedestal)
	if minCorner and maxCorner then
		local size = maxCorner - minCorner
		local fit = math.huge
		if size.Y > 0.01 then
			fit = PEDESTAL_HEIGHT / size.Y
		end
		local widest = math.max(size.X, size.Z)
		if widest > 0.01 then
			fit = math.min(fit, PEDESTAL_FOOTPRINT / widest)
		end
		if fit < math.huge and math.abs(fit - 1) > 0.001 then
			pedestal:ScaleTo(pedestal:GetScale() * fit)
		end
	end
	pedestal.Parent = parent
	-- The import's pivot is rotated (its local X is vertical); keep it.
	pedestal:PivotTo(CFrame.new(frame.Position) * pedestal:GetPivot().Rotation)
	minCorner, maxCorner = LootModel.worldExtents(pedestal)
	local top = floorY + PEDESTAL_HEIGHT
	if minCorner and maxCorner then
		pedestal:PivotTo(pedestal:GetPivot() + Vector3.new(0, floorY - minCorner.Y, 0))
		top = floorY + (maxCorner.Y - minCorner.Y)
	end
	return top
end

local function buildStatic(map: Instance): Model
	local model = Instance.new("Model")
	model.Name = MODEL_NAME

	-- The glowing ring on the floor, coloured per animal.
	local disc = Instance.new("Part")
	disc.Name = "Ring"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.3, RING_DIAMETER, RING_DIAMETER)
	disc.CFrame = CFrame.new(frame.Position + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	disc.Material = Enum.Material.Neon
	disc.Transparency = 0.45
	disc.Parent = model
	ring = disc

	pedestalTop = buildPedestal(model)

	-- The prompt stands in front of the pedestal, where a customer stops.
	local anchor = Instance.new("Part")
	anchor.Name = "PromptAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = frame * CFrame.new(0, 3, -(RING_DIAMETER / 2 - 1))
	anchor.Parent = model

	local p = Instance.new("ProximityPrompt")
	p.Name = "GuardianBuyPrompt"
	p.ActionText = "Buy"
	p.ObjectText = "Guardian"
	p.HoldDuration = PROMPT_HOLD
	p.MaxActivationDistance = PROMPT_RANGE
	p.RequiresLineOfSight = false
	p.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	p.Parent = anchor
	prompt = p

	-- The sign: name, LIMITED TIME!, price, countdown - over the animal.
	local signAnchor = Instance.new("Part")
	signAnchor.Name = "SignAnchor"
	signAnchor.Size = Vector3.new(1, 1, 1)
	signAnchor.Transparency = 1
	signAnchor.Anchored = true
	signAnchor.CanCollide = false
	signAnchor.CanQuery = false
	signAnchor.CanTouch = false
	signAnchor.CFrame = CFrame.new(frame.Position + Vector3.new(0, pedestalTop + BaseGuardianConfig.HEIGHT + 5.2, 0))
	signAnchor.Parent = model

	local gui = Instance.new("BillboardGui")
	gui.Name = "Sign"
	gui.Size = UDim2.fromScale(17, 9)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 220
	gui.Adornee = signAnchor
	gui.Parent = signAnchor

	labels.Name = label(gui, "Name", 0, 0.34, Color3.fromRGB(255, 255, 255), 60)
	labels.Limited = label(gui, "Limited", 0.34, 0.2, Color3.fromRGB(255, 226, 90), 40)
	labels.Limited.Text = "LIMITED TIME!"
	labels.Price = label(gui, "Price", 0.55, 0.24, Color3.fromRGB(126, 255, 148), 46)
	labels.Timer = label(gui, "Timer", 0.79, 0.21, Color3.fromRGB(230, 236, 250), 34)
	labels.Timer.Text = "New Guardian In: --:--:--"

	model.Parent = map
	return model
end

--- Puts the current animal on the pedestal. Rebuilt at every rotation.
local function refreshDisplay(key: string)
	local model = shop
	local def = BaseGuardianConfig.ByKey[key]
	if not model or not def then
		return
	end
	currentKey = key

	local old = model:FindFirstChild("Display")
	if old then
		old:Destroy()
	end

	local source = BaseGuardianService.modelFor(key)
	if source then
		local flat = Vector3.new(def.faceLocal.X, 0, def.faceLocal.Z)
		local yaw = if flat.Magnitude > 0.01 then math.atan2(flat.X, -flat.Z) else 0
		local rig = GuardianService.buildRigFrom(source, BaseGuardianConfig.HEIGHT, 1, "Display", CFrame.Angles(0, yaw, 0))
		local root = rig.PrimaryPart
		local humanoid = rig:FindFirstChildWhichIsA("Humanoid")
		if humanoid then
			-- A statue: no state machine, no forces, nothing to simulate.
			humanoid.EvaluateStateMachine = false
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
		if root then
			-- Every part of the display is a picture: nothing to bump into on
			-- the pedestal, nothing for the camera to pop against.
			for _, descendant in rig:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.CanCollide = false
					descendant.CanQuery = false
					descendant.CanTouch = false
				end
			end
			root.Anchored = true
			local position = Vector3.new(frame.Position.X, pedestalTop + root.Size.Y / 2 + 0.1, frame.Position.Z)
			rig:PivotTo(CFrame.lookAt(position, position + frame.LookVector))
			-- Tasteful, not a bonfire: a quarter of the kit's rate, particles
			-- at two thirds size, so the animal reads through its own aura.
			BaseGuardianService.applyAura(root, key, 0.22, 0.65)
		end
		rig:SetAttribute("GuardianKey", key)
		rig.Parent = model
	else
		warn(`[GuardianShopService] no model for {key}`)
	end

	if ring then
		ring.Color = def.color
	end
	labels.Name.Text = `{string.upper(def.name)} GUARDIAN`
	labels.Name.TextColor3 = def.color
	labels.Price.Text = priceText(key)
	if prompt then
		prompt.ObjectText = `{def.name} Guardian  ·  {priceText(key)}`
	end

	local _, _, endsAt = BaseGuardianConfig.rotation(workspace:GetServerTimeNow())
	model:SetAttribute("RotationKey", key)
	model:SetAttribute("RotationEndsAt", endsAt)
	model:SetAttribute("GuardianName", def.name)
	model:SetAttribute("Price", MonetizationService.livePassPrice(def.gamePassId) or 0)
end

--- Live prices landed or changed.
function GuardianShopService.retext()
	if currentKey ~= "" then
		labels.Price.Text = priceText(currentKey)
		local def = BaseGuardianConfig.ByKey[currentKey]
		if prompt and def then
			prompt.ObjectText = `{def.name} Guardian  ·  {priceText(currentKey)}`
		end
		if shop and def then
			shop:SetAttribute("Price", MonetizationService.livePassPrice(def.gamePassId) or 0)
		end
	end
end

local function onPrompt(player: Player)
	local key = currentKey
	if key == "" then
		return
	end
	local def = BaseGuardianConfig.ByKey[key]
	if BaseGuardianService.owns(player, key) then
		local profile = DataService.get(player)
		if profile and profile.EquippedGuardian == key then
			StateService.notify(player, "info", `Your {def.name} Guardian is already on guard.`)
			return
		end
		local ok, reason = BaseGuardianService.equip(player, key)
		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
		return
	end
	local ok, reason = MonetizationService.promptGuardianPass(player)
	if not ok and reason then
		StateService.notify(player, "error", reason)
	end
end

function GuardianShopService.start()
	local map = workspace:WaitForChild("Map", 20)
	if not map then
		return
	end
	local existing = map:FindFirstChild(MODEL_NAME)
	if existing then
		existing:Destroy()
	end
	frame = LobbyLayout.frame("GuardianShop", MapConfig.HUB.guardianShop)
	-- Flat on the floor, whatever the marker's height.
	frame = CFrame.new(frame.Position.X, 0, frame.Position.Z) * frame.Rotation

	shop = buildStatic(map)
	if prompt then
		prompt.Triggered:Connect(onPrompt)
	end

	local key = BaseGuardianConfig.rotation(workspace:GetServerTimeNow())
	refreshDisplay(key)

	-- Once a second is all the boundary needs; the countdown is the client's.
	task.spawn(function()
		while shop and shop.Parent do
			task.wait(1)
			local now = BaseGuardianConfig.rotation(workspace:GetServerTimeNow())
			if now ~= currentKey then
				refreshDisplay(now)
				StateService.announce("info", `NEW GUARDIAN IN THE SHOP: {string.upper(BaseGuardianConfig.ByKey[now].name)}!`, "refresh")
			end
		end
	end)

	print(`[GuardianShopService] shop at {frame.Position} showing {key}`)
end

return GuardianShopService
