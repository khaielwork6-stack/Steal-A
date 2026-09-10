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
local AttractionSign = require(ReplicatedStorage.Shared.Util.AttractionSign)
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

--- ONE SALE SLOT. Everything that used to be a module-level singleton lives
--- here instead, so the shop can be built more than once without the second
--- pedestal overwriting the first one's prompt, sign or displayed animal.
type Slot = {
	index: number,
	frame: CFrame,
	model: Model?,
	pedestalTop: number,
	key: string,
	ring: BasePart?,
	prompt: ProximityPrompt?,
	labels: { [string]: TextLabel },
}

local slots: { Slot } = {}
--- Which prompt belongs to which slot, so a trigger resolves its own slot
--- rather than guessing from a shared "current" key.
local slotByPrompt: { [ProximityPrompt]: Slot } = {}

local function priceText(key: string): string
	local def = BaseGuardianConfig.ByKey[key]
	local price = if def then MonetizationService.livePassPrice(def.gamePassId) else nil
	return if price then `R${price}` else "R$ ..."
end

--- One line of the sale sign.
---
--- THE NAMES ARE AN INTERFACE. GuardianShopController finds "Timer" and
--- "Limited" by name to run the countdown and the pulse, so the four labels
--- keep the names they have always had however the layout around them moves.
---
--- UIStroke rather than TextStrokeTransparency: the old sign leaned on the
--- built-in stroke, which is a fixed one-pixel smear and vanishes at the
--- distance this sign is meant to be read from. A real outline scaled to the
--- line's weight is most of why the rebuilt sign reads from the spawn circle.
local function label(
	parent: Instance,
	name: string,
	y: number,
	height: number,
	color: Color3,
	size: number,
	stroke: number
): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Size = UDim2.fromScale(1, height)
	text.Position = UDim2.fromScale(0, y)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = color
	text.TextStrokeTransparency = 1
	text.Text = ""
	text.Parent = parent

	local outline = Instance.new("UIStroke")
	outline.Thickness = stroke
	outline.Color = Color3.fromRGB(12, 10, 26)
	outline.Transparency = 0
	-- Contextual, so the outline follows the glyphs rather than boxing the
	-- label, which is what makes a heavy stroke look deliberate.
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	outline.Parent = text

	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = size
	limit.Parent = text
	return text
end

--- The imported pedestal, scaled to the shop's size and stood on the floor.
local function buildPedestal(parent: Instance, frame: CFrame): number
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

local function buildStatic(map: Instance, slot: Slot): Model
	local frame = slot.frame
	local model = Instance.new("Model")
	-- Slot 1 keeps the historic name so anything that looked the shop up by
	-- it still finds a shop; the second is suffixed.
	model.Name = if slot.index == 1 then MODEL_NAME else MODEL_NAME .. tostring(slot.index)
	model:SetAttribute("SlotIndex", slot.index)

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
	slot.ring = disc

	slot.pedestalTop = buildPedestal(model, frame)

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
	slot.prompt = p
	slotByPrompt[p] = slot

	-- THE SALE SIGN. Rebuilt for hierarchy: the old one gave the name, the
	-- LIMITED TIME! banner and the price near-equal weight, so from any
	-- distance it read as four competing lines and the eye had nowhere to land.
	--
	-- The order below is what the player needs, in that order:
	--   1 LIMITED TIME   a small kicker. It qualifies the offer, so it sits
	--                    above the name and is the smallest thing on the sign
	--                    rather than shouting alongside it.
	--   2 the NAME       far and away the biggest line, in the animal's own
	--                    colour. This is the one thing that must read from the
	--                    spawn circle.
	--   3 the PRICE      second biggest. The decision, once they have looked.
	--   4 the TIMER      the smallest and the quietest: it matters only once
	--                    they are already interested, and it is the one line
	--                    that changes every second, so it must never be the
	--                    thing that catches the eye.
	--   5 the ARROW      which of the things on the apron this is about.
	local signAnchor = Instance.new("Part")
	signAnchor.Name = "SignAnchor"
	signAnchor.Size = Vector3.new(1, 1, 1)
	signAnchor.Transparency = 1
	signAnchor.Anchored = true
	signAnchor.CanCollide = false
	signAnchor.CanQuery = false
	signAnchor.CanTouch = false
	signAnchor.CFrame = CFrame.new(frame.Position + Vector3.new(0, slot.pedestalTop + BaseGuardianConfig.HEIGHT + 5.2, 0))
	signAnchor.Parent = model

	local gui = Instance.new("BillboardGui")
	gui.Name = "Sign"
	gui.Size = UDim2.fromScale(18, 11)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 260
	gui.Adornee = signAnchor
	gui.Parent = signAnchor

	slot.labels.Limited = label(gui, "Limited", 0, 0.12, Color3.fromRGB(255, 226, 90), 26, 2)
	slot.labels.Limited.Text = "LIMITED TIME"
	slot.labels.Name = label(gui, "Name", 0.12, 0.31, Color3.fromRGB(255, 255, 255), 68, 4)
	slot.labels.Price = label(gui, "Price", 0.45, 0.21, Color3.fromRGB(126, 255, 148), 48, 3)
	slot.labels.Timer = label(gui, "Timer", 0.68, 0.14, Color3.fromRGB(214, 222, 240), 26, 2)
	slot.labels.Timer.Text = "New Guardian In: --:--:--"

	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.AnchorPoint = Vector2.new(0.5, 0)
	arrow.Size = UDim2.fromScale(0.3, 0.17)
	arrow.Position = UDim2.fromScale(0.5, 0.83)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.FredokaOne
	arrow.TextScaled = true
	arrow.TextColor3 = Color3.fromRGB(255, 255, 255)
	arrow.TextStrokeColor3 = Color3.fromRGB(12, 10, 26)
	arrow.TextStrokeTransparency = 0
	arrow.Text = "\226\150\188"
	arrow:SetAttribute(AttractionSign.ARROW_TAG, true)
	arrow:SetAttribute("RestY", arrow.Position.Y.Scale)
	arrow.Parent = gui
	local arrowCap = Instance.new("UITextSizeConstraint")
	arrowCap.MaxTextSize = 46
	arrowCap.Parent = arrow

	model.Parent = map
	return model
end

--- Puts an animal on one slot's pedestal. Rebuilt at every rotation.
local function refreshDisplay(slot: Slot, key: string)
	local model = slot.model
	local frame = slot.frame
	local def = BaseGuardianConfig.ByKey[key]
	if not model or not def then
		return
	end
	slot.key = key

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
			local position = Vector3.new(frame.Position.X, slot.pedestalTop + root.Size.Y / 2 + 0.1, frame.Position.Z)
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

	if slot.ring then
		slot.ring.Color = def.color
	end
	slot.labels.Name.Text = `{string.upper(def.name)} GUARDIAN`
	slot.labels.Name.TextColor3 = def.color
	slot.labels.Price.Text = priceText(key)
	if slot.prompt then
		slot.prompt.ObjectText = `{def.name} Guardian  ·  {priceText(key)}`
	end

	local _, _, endsAt = BaseGuardianConfig.rotation(workspace:GetServerTimeNow())
	model:SetAttribute("RotationKey", key)
	model:SetAttribute("RotationEndsAt", endsAt)
	model:SetAttribute("GuardianName", def.name)
	model:SetAttribute("Price", MonetizationService.livePassPrice(def.gamePassId) or 0)
end

--- THE KEYS ON SALE RIGHT NOW, one per slot. This is the ONLY list the
--- purchase path will honour: a prompt hands its own slot's key to
--- MonetizationService, which checks it against this before opening any
--- Robux dialog, so a slot can never sell something that is not standing on
--- it and nothing a client says reaches the decision at all.
function GuardianShopService.onSaleKeys(): { string }
	local keys = {}
	for _, slot in slots do
		if slot.key ~= "" then
			table.insert(keys, slot.key)
		end
	end
	return keys
end

--- Live prices landed or changed.
function GuardianShopService.retext()
	for _, slot in slots do
		local def = if slot.key ~= "" then BaseGuardianConfig.ByKey[slot.key] else nil
		if def then
			slot.labels.Price.Text = priceText(slot.key)
			if slot.prompt then
				slot.prompt.ObjectText = `{def.name} Guardian  ·  {priceText(slot.key)}`
			end
			if slot.model then
				slot.model:SetAttribute("Price", MonetizationService.livePassPrice(def.gamePassId) or 0)
			end
		end
	end
end

local function onPrompt(player: Player, slot: Slot)
	local key = slot.key
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
	-- The key comes from the pedestal the player physically walked up to, not
	-- from anything the client sent, and the server checks it against the
	-- on-sale list before it opens a dialog.
	local ok, reason = MonetizationService.promptGuardianPass(player, key)
	if not ok and reason then
		StateService.notify(player, "error", reason)
	end
end

--- WHICH ANIMAL EACH SLOT SHOWS, for a moment in time.
---
--- Slot 1 is the rotation as it has always been, so a player who knew what
--- was on sale yesterday still sees it where they expect. Slot 2 shows the
--- NEXT animal in the same order - today's preview of tomorrow - which means
--- the two slots are never the same guardian, roll over together on the one
--- boundary, and need no rotation state of their own. With four animals in
--- ROTATION_ORDER the pair walks the whole roster in half the time.
local function keysForNow(): (string, number)
	local key, index, endsAt = BaseGuardianConfig.rotation(workspace:GetServerTimeNow())
	local order = BaseGuardianConfig.ROTATION_ORDER
	local nextKey = order[(index % #order) + 1]
	return key .. "\1" .. nextKey, endsAt
end

function GuardianShopService.start()
	local map = workspace:WaitForChild("Map", 20)
	if not map then
		return
	end

	-- Both pedestals, mirrored across the apron. The second marker is the
	-- first reflected in X, so the pair reads as a matching pair from the
	-- spawn circle rather than as one shop and an afterthought.
	local markers = {
		LobbyLayout.frame("GuardianShop", MapConfig.HUB.guardianShop),
		LobbyLayout.frame("GuardianShopB", MapConfig.HUB.guardianShopB),
	}

	table.clear(slots)
	table.clear(slotByPrompt)
	for index, marker in markers do
		local stale = map:FindFirstChild(if index == 1 then MODEL_NAME else MODEL_NAME .. tostring(index))
		if stale then
			stale:Destroy()
		end
		local slot: Slot = {
			index = index,
			-- Flat on the floor, whatever the marker's height.
			frame = CFrame.new(marker.Position.X, 0, marker.Position.Z) * marker.Rotation,
			model = nil,
			pedestalTop = 0,
			key = "",
			ring = nil,
			prompt = nil,
			labels = {},
		}
		slot.model = buildStatic(map, slot)
		if slot.prompt then
			local owner = slot
			slot.prompt.Triggered:Connect(function(player)
				onPrompt(player, owner)
			end)
		end
		table.insert(slots, slot)
	end

	local function apply(pair: string)
		local first, second = string.match(pair, "^(.-)\1(.*)$")
		local keys = { first, second }
		for index, slot in slots do
			local key = keys[index]
			if key and key ~= slot.key then
				refreshDisplay(slot, key)
			end
		end
	end

	local pair = keysForNow()
	apply(pair)

	-- Once a second is all the boundary needs; the countdown is the client's.
	task.spawn(function()
		while slots[1] and slots[1].model and (slots[1].model :: Model).Parent do
			task.wait(1)
			local now = keysForNow()
			if now ~= pair then
				pair = now
				apply(now)
				local lead = slots[1] and slots[1].key
				local def = if lead then BaseGuardianConfig.ByKey[lead] else nil
				if def then
					StateService.announce("info", `NEW GUARDIAN IN THE SHOP: {string.upper(def.name)}!`, "refresh")
				end
			end
		end
	end)

	local shown = {}
	for _, slot in slots do
		table.insert(shown, `{slot.key} at {slot.frame.Position}`)
	end
	print(`[GuardianShopService] {#slots} sale slots - {table.concat(shown, ", ")}`)
end

return GuardianShopService
