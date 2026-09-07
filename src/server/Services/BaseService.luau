--!strict
--[[
	BaseService
	Assigns one of the seven physical plots, rebuilds a returning player's
	displays, and owns base activation / capacity (GDD section 8).

	The plot is SESSION-owned: when the player leaves it is cleaned and handed to
	someone else. The collection itself is persistent and lives in the profile, so
	a player can come back to a different physical plot and still see their stuff.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local MapPalette = require(ReplicatedStorage.Shared.MapPalette)
local MutationVfx = require(ReplicatedStorage.Shared.Util.MutationVfx)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

local DataService = require(script.Parent.DataService)

local BaseService = {}

local assignments: { [Player]: Model | Folder } = {}
local owners: { [Instance]: Player } = {}
local rebuildListeners: { (Player) -> () } = {}

--- Fires after a plot's trophies are rebuilt, so PlacementService can keep its
--- slot prompts in step without BaseService having to know about prompts.
function BaseService.onRebuilt(callback: (Player) -> ())
	table.insert(rebuildListeners, callback)
end

local basesFolder: Folder? = nil

local function getBases(): Folder
	if not basesFolder then
		local map = workspace:WaitForChild("Map", 20)
		assert(map, "BaseService: Workspace.Map is missing - run MapBuilder.build() first")
		basesFolder = map:WaitForChild("Bases", 10) :: Folder
	end
	return basesFolder :: Folder
end

--- Marks every plot's ownership on the instance itself so client UI, guardians
--- and PvP checks can all read one source of truth.
--- Forward-declared: the sign lives further down with the rest of the display
--- code, but ownership changes are what repaint it.
local paintOwnerSignRef: ((plot: Instance, player: Player?, tier: number?) -> ())? = nil

local function setOwner(plot: Instance, player: Player?)
	plot:SetAttribute("OwnerUserId", if player then player.UserId else 0)
	plot:SetAttribute("OwnerName", if player then player.Name else "")

	local spawn = plot:FindFirstChild("Spawn")
	if spawn and spawn:IsA("SpawnLocation") then
		spawn.Enabled = player ~= nil
	end

	if paintOwnerSignRef then
		paintOwnerSignRef(plot, player, nil)
	end
end

function BaseService.getPlot(player: Player): (Model | Folder)?
	return assignments[player]
end

function BaseService.getOwner(plot: Instance): Player?
	return owners[plot]
end

--- Vertical tolerance around the plot floor. Deliberately generous: whether a
--- player is home is a question about the ground they are standing on, not
--- about the exact height of an invisible volume. Testing Y against the part
--- made placement silently fail when a SafeZone part drifted upward.
local SAFE_ZONE_VERTICAL_TOLERANCE = 80

--- Resolves the plot a position sits inside, if any. Used by safe-zone checks.
function BaseService.plotAt(position: Vector3): Instance?
	for plot in owners do
		local safe = plot:FindFirstChild("SafeZone")
		if safe and safe:IsA("BasePart") then
			-- Footprint test in the volume's own frame so plot rotation is honoured.
			local offset = safe.CFrame:PointToObjectSpace(position)
			local half = safe.Size / 2
			if math.abs(offset.X) <= half.X and math.abs(offset.Z) <= half.Z then
				-- Height is measured from the plot's own floor, not the volume.
				local floorY = 0
				local floor = plot:FindFirstChild("PlotFloor")
				local slab = floor and floor:FindFirstChild("Slab")
				if slab and slab:IsA("BasePart") then
					floorY = slab.Position.Y + slab.Size.Y / 2
				end
				if math.abs(position.Y - floorY) <= SAFE_ZONE_VERTICAL_TOLERANCE then
					return plot
				end
			end
		end
	end
	return nil
end

local safeLineZ: number? = nil

--- Any position behind the red line, or inside any plot's volume, is safe.
--- PvP is disabled here so nobody can be spawn-griefed at their own base
--- (GDD section 12). Note this is ANY safe zone, not just your own.
function BaseService.isSafePosition(position: Vector3): boolean
	if not safeLineZ then
		local map = workspace:FindFirstChild("Map")
		local zone = map and map:FindFirstChild("SafeZone")
		local line = zone and zone:FindFirstChild("BoundaryLine")
		safeLineZ = if line and line:IsA("BasePart") then line.Position.Z else 0
	end

	if position.Z < (safeLineZ :: number) then
		return true
	end
	return BaseService.plotAt(position) ~= nil
end

--- True when the player is standing inside their OWN base safe zone. Guardians
--- may not cross it and PvP is disabled there (GDD sections 10 and 12).
function BaseService.isInOwnSafeZone(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local plot = assignments[player]
	if not plot then
		return false
	end
	return BaseService.plotAt(root.Position) == plot
end

function BaseService.unlockedSlots(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		return GameConfig.STARTING_DISPLAY_SLOTS
	end
	return BaseConfig.slotsForTier(profile.BaseCapacityTier)
end

--- Slot indices that are unlocked and currently empty.
function BaseService.freeSlots(player: Player): { number }
	local profile = DataService.get(player)
	if not profile then
		return {}
	end

	local taken: { [number]: boolean } = {}
	for _, item in profile.DisplayItems do
		taken[item.SlotIndex] = true
	end

	local free = {}
	for index = 1, BaseService.unlockedSlots(player) do
		if not taken[index] then
			table.insert(free, index)
		end
	end
	return free
end

function BaseService.isFull(player: Player): boolean
	return #BaseService.freeSlots(player) == 0
end

-- ==========================================================
-- DISPLAY RECONSTRUCTION
-- ==========================================================

--- The pedestal copy of a stolen item. Real art drops into
--- ServerStorage.GameAssets.Loot.<ItemId> and is used automatically once
--- present; until then a rarity-tinted block keeps the economy fully testable
--- without art. LootModel owns both branches - see it for the naming contract.
--- How much bigger a trophy has grown, 1 at placement rising to
--- 1 + GROWTH_SCALE_BONUS at full maturity. Read from the SAVED seconds, so it
--- is the same after every rebuild and never compounds.
function BaseService.growthScale(item: DataService.DisplayItem): number
	local seconds = math.clamp(tonumber(item.GrowthSeconds) or 0, 0, NightConfig.GROWTH_FULL_SECONDS)
	return 1 + NightConfig.GROWTH_SCALE_BONUS * (seconds / NightConfig.GROWTH_FULL_SECONDS)
end

local function buildTrophy(item: DataService.DisplayItem): Model
	-- A trophy shows the size it was stolen at: the exact visual scale that was
	-- rolled for the instance and saved with it, times its growth. Both come
	-- from the save, so a rejoin, a store and a re-equip all build the same
	-- model - nothing is ever scaled twice.
	local visual = RarityConfig.clampVisualScale(item.Size, item.VisualScale)

	local model = LootModel.build({
		itemId = item.ItemId,
		rarity = item.Rarity,
		targetHeight = GameConfig.LOOT_TROPHY_HEIGHT,
		sizeScale = visual * BaseService.growthScale(item),
		maxFootprint = LootModel.TROPHY_MAX_FOOTPRINT,
		placeholderSize = Vector3.new(8, 10, 8),
	})

	-- A trophy keeps the mutation it was stolen with. The whole point of the
	-- base is that it looks like a museum of what you took, so a Corrupted
	-- Meteorite must still read as Corrupted once it is on the pedestal.
	MutationVfx.apply(model, item.Mutation)

	model:SetAttribute("InstanceId", item.InstanceId)
	model:SetAttribute("ItemId", item.ItemId)
	model:SetAttribute("FinalIncome", item.FinalIncome)
	model:SetAttribute("Size", item.Size)
	model:SetAttribute("VisualScale", RarityConfig.clampVisualScale(item.Size, item.VisualScale))
	model:SetAttribute("Rarity", item.Rarity)
	model:SetAttribute("Mutation", item.Mutation)
	-- What growth this build already includes, for applyGrowth's ratio.
	model:SetAttribute("GrowthApplied", BaseService.growthScale(item))

	return model
end

--- Nameplate over a placed trophy: name in its rarity colour, the variant line
--- (rarity, and size / mutation when they are not Normal), and the real income.
--- `topY` is the item's highest point so the card sits just above whatever it
--- is - a coin and a Colossal get the same clearance.
local function buildLabel(item: DataService.DisplayItem, parent: Model, topY: number)
	local def = LootConfig.ById[item.ItemId]
	local anchor = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "TrophyLabel"
	gui.Size = UDim2.fromScale(9, 3.6)
	gui.StudsOffsetWorldSpace = Vector3.new(0, (topY - anchor.Position.Y) + 2.4, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 220
	gui.Adornee = anchor
	gui.Parent = anchor

	local color = RarityConfig.Colors[item.Rarity] or Color3.new(1, 1, 1)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.42)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = color
	title.TextStrokeTransparency = 0.35
	title.Text = if def then def.name else item.ItemId
	title.Parent = gui

	local tags = { item.Rarity }
	if item.Size ~= "Normal" then
		table.insert(tags, item.Size)
	end
	local mutation = RarityConfig.normaliseMutation(item.Mutation)
	if mutation ~= "Normal" then
		table.insert(tags, mutation)
	end
	local variant = Instance.new("TextLabel")
	variant.Name = "Variant"
	variant.Size = UDim2.fromScale(1, 0.26)
	variant.Position = UDim2.fromScale(0, 0.42)
	variant.BackgroundTransparency = 1
	variant.Font = Enum.Font.FredokaOne
	variant.TextScaled = true
	variant.TextColor3 = Color3.fromRGB(240, 240, 248)
	variant.TextStrokeTransparency = 0.4
	variant.Text = table.concat(tags, " · ")
	variant.Parent = gui

	local income = Instance.new("TextLabel")
	income.Name = "Income"
	income.Size = UDim2.fromScale(1, 0.32)
	income.Position = UDim2.fromScale(0, 0.68)
	income.BackgroundTransparency = 1
	income.Font = Enum.Font.FredokaOne
	income.TextScaled = true
	income.TextColor3 = Color3.fromRGB(120, 255, 140)
	income.TextStrokeTransparency = 0.4
	income.Text = NumberFormat.income(item.FinalIncome)
	income.Parent = gui
end

-- ==========================================================
-- THE PEDESTAL
-- ==========================================================
--
-- One imported model, `ServerStorage.GameAssets.Pedestal`, is the template for
-- every occupied display. It is scaled ONCE per clone to a fixed height and
-- footprint, so every pedestal on every plot is the same physical size; the
-- collectible on top is what varies. A rarity-coloured accent disc sits on its
-- top face so the tier reads before the label does.

local PEDESTAL_HEIGHT = 5
local PEDESTAL_MAX_FOOTPRINT = 8
--- Gap between the pedestal's top face and the item's lowest point.
local ITEM_HOVER = 0.15

local function pedestalTemplate(): Model?
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local found = assets and assets:FindFirstChild("Pedestal")
	return if found and found:IsA("Model") then found else nil
end

--- A fresh pedestal, standing on `padTop` at the pad's centre. Returns the
--- model and the world Y of its top face. Nil when the asset is missing, in
--- which case the item simply sits on the pad as before.
local function buildPedestal(slot: BasePart, padTop: number, rarity: string): (Model?, number)
	local template = pedestalTemplate()
	if not template then
		return nil, padTop
	end

	local pedestal = template:Clone()
	pedestal.Name = "Pedestal"
	for _, descendant in pedestal:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = true
			descendant.CanQuery = true
			descendant.CastShadow = true
		elseif descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end

	-- Normalise to the display size, uniformly, whichever of height or
	-- footprint binds first. The import is 9.3 tall on an 11.8 footprint.
	local minCorner, maxCorner = LootModel.worldExtents(pedestal)
	if minCorner and maxCorner then
		local size = maxCorner - minCorner
		local fit = math.huge
		if size.Y > 0.01 then
			fit = PEDESTAL_HEIGHT / size.Y
		end
		local widest = math.max(size.X, size.Z)
		if widest > 0.01 then
			fit = math.min(fit, PEDESTAL_MAX_FOOTPRINT / widest)
		end
		if fit < math.huge and math.abs(fit - 1) > 0.001 then
			pedestal:ScaleTo(pedestal:GetScale() * fit)
		end
	end

	pedestal.Parent = slot
	-- Keep the import's own orientation (its pivot is rotated: the model's
	-- local X is the vertical axis). A bare positional PivotTo would stand the
	-- pedestal on its side.
	pedestal:PivotTo(CFrame.new(slot.Position.X, padTop, slot.Position.Z) * pedestal:GetPivot().Rotation)
	minCorner, maxCorner = LootModel.worldExtents(pedestal)
	local top = padTop
	if minCorner and maxCorner then
		pedestal:PivotTo(pedestal:GetPivot() + Vector3.new(0, padTop - minCorner.Y, 0))
		top = padTop + (maxCorner.Y - minCorner.Y)
		-- The rarity accent: a thin neon disc inset on the top face.
		local footprint = math.max(maxCorner.X - minCorner.X, maxCorner.Z - minCorner.Z)
		local accent = Instance.new("Part")
		accent.Name = "Accent"
		accent.Shape = Enum.PartType.Cylinder
		accent.Size = Vector3.new(0.14, footprint * 0.62, footprint * 0.62)
		accent.CFrame = CFrame.new(slot.Position.X, top + 0.02, slot.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
		accent.Material = Enum.Material.Neon
		accent.Color = RarityConfig.Colors[rarity] or Color3.fromRGB(200, 200, 210)
		accent.Transparency = 0.35
		accent.Anchored = true
		accent.CanCollide = false
		accent.CanQuery = false
		accent.CanTouch = false
		accent.CastShadow = false
		accent.Parent = pedestal
		top += 0.09
	end
	pedestal:SetAttribute("Rarity", rarity)
	return pedestal, top
end

-- ==========================================================
-- THE SLOT
-- ==========================================================
--
-- One logical slot, one display state: Locked -> Empty -> Occupied. The pad is
-- a quiet dark square; a thin neon frame set into it says "something belongs
-- here". Empty and unlocked: cyan, and the client breathes it. Locked: dim
-- grey. Occupied: the item's rarity colour, at rest under the pedestal.
--
-- Styled at runtime because the map is baked into the place file - this
-- restyles the plots already saved there without rebuilding the world. The
-- SelectionBox rim an earlier build used is removed on sight.

export type SlotState = "Locked" | "Empty" | "Occupied"

local FRAME_THICKNESS = 0.55
local FRAME_HEIGHT = 0.24
local FRAME_INSET = 1.4

local function ensureNeonFrame(slot: BasePart): Model
	local existing = slot:FindFirstChild("NeonFrame")
	if existing and existing:IsA("Model") then
		return existing
	end
	local frame = Instance.new("Model")
	frame.Name = "NeonFrame"
	local inner = slot.Size.X - FRAME_INSET * 2
	local innerZ = slot.Size.Z - FRAME_INSET * 2
	local y = slot.Size.Y / 2 + FRAME_HEIGHT / 2 - 0.02
	local edges = {
		{ name = "North", size = Vector3.new(inner, FRAME_HEIGHT, FRAME_THICKNESS), offset = Vector3.new(0, y, innerZ / 2) },
		{ name = "South", size = Vector3.new(inner, FRAME_HEIGHT, FRAME_THICKNESS), offset = Vector3.new(0, y, -innerZ / 2) },
		{ name = "East", size = Vector3.new(FRAME_THICKNESS, FRAME_HEIGHT, innerZ), offset = Vector3.new(inner / 2, y, 0) },
		{ name = "West", size = Vector3.new(FRAME_THICKNESS, FRAME_HEIGHT, innerZ), offset = Vector3.new(-inner / 2, y, 0) },
	}
	for _, edge in edges do
		local part = Instance.new("Part")
		part.Name = edge.name
		part.Size = edge.size
		part.CFrame = slot.CFrame * CFrame.new(edge.offset)
		part.Material = Enum.Material.Neon
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Parent = frame
	end
	frame.Parent = slot
	return frame
end

local function styleSlot(slot: BasePart, state: SlotState, accent: Color3?)
	local rim = slot:FindFirstChild("SlotRim")
	if rim then
		rim:Destroy()
	end

	slot.Material = Enum.Material.SmoothPlastic
	slot.CastShadow = false
	if state == "Locked" then
		slot.Color = MapPalette.SlotPadLocked
		slot.Transparency = 0.5
	elseif state == "Empty" then
		slot.Color = MapPalette.SlotPadEmpty
		slot.Transparency = 0.08
	else
		slot.Color = MapPalette.SlotPadOccupied
		slot.Transparency = 0.05
	end

	local color = if state == "Locked"
		then MapPalette.SlotNeonLocked
		elseif state == "Empty" then MapPalette.SlotNeonEmpty
		else (accent or MapPalette.SlotNeonEmpty)
	local transparency = if state == "Locked" then 0.75 elseif state == "Empty" then 0.2 else 0.4
	for _, edge in ensureNeonFrame(slot):GetChildren() do
		if edge:IsA("BasePart") then
			edge.Color = color
			edge.Transparency = transparency
		end
	end

	-- What the client's animation manager reads: it breathes Empty frames and
	-- leaves the rest alone.
	slot:SetAttribute("SlotState", state)
	slot:SetAttribute("NeonColor", color)
	slot:SetAttribute("NeonRest", transparency)
end

--- Where an item's lowest point should sit: on the pedestal's top face, or on
--- the pad when there is no pedestal.
local function seatTrophy(trophy: Model, slot: BasePart, surfaceY: number)
	trophy:PivotTo(CFrame.new(slot.Position.X, surfaceY, slot.Position.Z) * (slot.CFrame - slot.CFrame.Position))
	local minCorner = select(1, LootModel.worldExtents(trophy))
	if minCorner then
		trophy:PivotTo(trophy:GetPivot() + Vector3.new(0, surfaceY + ITEM_HOVER - minCorner.Y, 0))
	end
end

--- A Titan or Colossal earns a restrained sparkle. Mutations already carry
--- their own authored effects (MutationVfx); this is the size's.
local function addSizeSparkle(trophy: Model, item: DataService.DisplayItem)
	if RarityConfig.sizeRank(item.Size) < RarityConfig.sizeRank("Titan") then
		return
	end
	local anchor = trophy.PrimaryPart
	if not anchor then
		return
	end
	local minCorner, maxCorner = LootModel.worldExtents(trophy)
	local span = if minCorner and maxCorner then math.max(maxCorner.X - minCorner.X, maxCorner.Y - minCorner.Y, maxCorner.Z - minCorner.Z) else 6
	local attachment = Instance.new("Attachment")
	attachment.Name = "SizeSparkleAttachment"
	attachment.Parent = anchor
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "SizeSparkle"
	sparkle.Texture = "rbxassetid://241594419"
	sparkle.Color = ColorSequence.new(RarityConfig.Colors[item.Rarity] or Color3.new(1, 1, 1), Color3.new(1, 1, 1))
	sparkle.LightEmission = 0.7
	sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, span * 0.05), NumberSequenceKeypoint.new(1, 0) })
	sparkle.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	sparkle.Lifetime = NumberRange.new(1.4, 2.2)
	sparkle.Rate = if item.Size == "Colossal" then 6 else 4
	sparkle.Speed = NumberRange.new(span * 0.08, span * 0.16)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Parent = attachment
end

--- Rebuilds every slot's look and every placed trophy from the profile.
--- Called on assignment and after any placement, store or sale. The server
--- owns the state: a pedestal appearing or disappearing here never creates,
--- deletes or moves an item - it only draws the profile.
function BaseService.rebuildDisplays(player: Player)
	local plot = assignments[player]
	local profile = DataService.get(player)
	if not plot or not profile then
		return
	end

	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return
	end

	local unlocked = BaseService.unlockedSlots(player)

	local occupied: { [number]: DataService.DisplayItem } = {}
	for _, item in profile.DisplayItems do
		occupied[item.SlotIndex] = item
	end

	for _, slot in slots:GetChildren() do
		local index = slot:GetAttribute("SlotIndex") :: number?
		if not index or not slot:IsA("BasePart") then
			continue
		end

		for _, name in { "Trophy", "Pedestal" } do
			local existing = slot:FindFirstChild(name)
			if existing then
				existing:Destroy()
			end
		end

		local item = occupied[index]
		if index > unlocked then
			styleSlot(slot, "Locked")
			continue
		end
		if not item then
			styleSlot(slot, "Empty")
			continue
		end

		styleSlot(slot, "Occupied", RarityConfig.Colors[item.Rarity])

		local padTop = slot.Position.Y + slot.Size.Y / 2
		local _, surfaceY = buildPedestal(slot, padTop, item.Rarity)

		local trophy = buildTrophy(item)
		trophy.Name = "Trophy"
		trophy.Parent = slot
		seatTrophy(trophy, slot, surfaceY)

		local _, maxCorner = LootModel.worldExtents(trophy)
		buildLabel(item, trophy, if maxCorner then maxCorner.Y else surfaceY + GameConfig.LOOT_TROPHY_HEIGHT)
		addSizeSparkle(trophy, item)
	end

	BaseService.refreshOwnerSign(player)

	for _, callback in rebuildListeners do
		task.spawn(callback, player)
	end
end

--- Re-applies growth to the trophies already standing, IN PLACE. Called when
--- an item crosses a growth step (NightService), so the base does not rebuild
--- - and flicker - every few seconds. Each trophy remembers the growth factor
--- it was built with; the change is the ratio, so it can never compound.
function BaseService.applyGrowth(player: Player)
	local plot = assignments[player]
	local profile = DataService.get(player)
	if not plot or not profile then
		return
	end
	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return
	end

	for _, item in profile.DisplayItems do
		local slot = slots:FindFirstChild(string.format("DisplaySlot%02d", item.SlotIndex))
		local trophy = slot and slot:FindFirstChild("Trophy")
		if not slot or not slot:IsA("BasePart") or not trophy or not trophy:IsA("Model") then
			continue
		end
		local applied = tonumber(trophy:GetAttribute("GrowthApplied")) or 1
		local wanted = BaseService.growthScale(item)
		if math.abs(wanted - applied) < 0.001 then
			continue
		end
		trophy:ScaleTo(trophy:GetScale() * (wanted / applied))
		trophy:SetAttribute("GrowthApplied", wanted)
		-- ScaleTo grows about the pivot; re-seat the lowest point on whatever
		-- the item stands on (the pedestal's top face, or the pad).
		local minCorner = select(1, LootModel.worldExtents(trophy))
		if minCorner then
			local surfaceY = slot.Position.Y + slot.Size.Y / 2
			local pedestal = slot:FindFirstChild("Pedestal")
			local accent = pedestal and pedestal:FindFirstChild("Accent")
			if accent and accent:IsA("BasePart") then
				surfaceY = accent.Position.Y + accent.Size.X / 2
			end
			trophy:PivotTo(trophy:GetPivot() + Vector3.new(0, surfaceY + ITEM_HOVER - minCorner.Y, 0))
		end
	end
end

-- ==========================================================
-- THE OWNER SIGN
-- ==========================================================
--
-- A board at the front corner of every plot: the owner's real avatar headshot
-- in a round frame, their display name, their @username in smaller type, a
-- crown once their base has reached a high capacity tier, and a YOUR BASE
-- badge the owner's own client switches on. Fetched from the real UserId - no
-- account is hard-coded anywhere - and repainted whenever the plot is assigned
-- or released.

local OWNER_SIGN_NAME = "OwnerSign"
local OWNER_SIGN_WIDTH = 14
local OWNER_SIGN_HEIGHT = 6
local OWNER_SIGN_LIFT = 7.5
--- Capacity tier from which the crown shows (roughly the halfway mark).
local CROWN_TIER = 4

local function ownerSignLabel(parent: Instance, name: string, size: UDim2, pos: UDim2, color: Color3, align: Enum.TextXAlignment): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Size = size
	text.Position = pos
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextXAlignment = align
	text.TextColor3 = color
	text.TextStrokeTransparency = 0.1
	text.TextStrokeColor3 = Color3.fromRGB(12, 16, 32)
	text.ZIndex = 3
	text.Parent = parent
	return text
end

local function ensureOwnerSign(plot: Instance): SurfaceGui?
	local existing = plot:FindFirstChild(OWNER_SIGN_NAME)
	if existing then
		local board = existing:FindFirstChild("Board")
		local gui = board and board:FindFirstChildOfClass("SurfaceGui")
		return gui :: SurfaceGui?
	end

	-- The plot's own frame comes from its floor slab, which MapBuilder laid
	-- down with the plot's rotation: local X across the plot, local -Z toward
	-- the open front where players arrive.
	local floor = plot:FindFirstChild("PlotFloor")
	local slab = floor and floor:FindFirstChild("Slab")
	if not slab or not slab:IsA("BasePart") then
		return nil
	end
	local halfW, halfD = slab.Size.X / 2, slab.Size.Z / 2
	-- Front-left corner, a little in from both edges, facing out.
	local foot = slab.CFrame * CFrame.new(-halfW + 12, slab.Size.Y / 2, -halfD + 7)
	local facing = CFrame.lookAt(foot.Position, foot.Position - slab.CFrame.LookVector)

	local model = Instance.new("Model")
	model.Name = OWNER_SIGN_NAME

	local function slabPart(name: string, size: Vector3, cf: CFrame, color: Color3): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.CFrame = cf
		part.Color = color
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end

	local postTop = OWNER_SIGN_LIFT - OWNER_SIGN_HEIGHT / 2
	slabPart("Post", Vector3.new(1.4, postTop, 1.4), facing * CFrame.new(0, postTop / 2, 0), MapPalette.SignPost)
	local base = facing * CFrame.new(0, OWNER_SIGN_LIFT, 0)
	slabPart("Edge", Vector3.new(OWNER_SIGN_WIDTH + 0.8, OWNER_SIGN_HEIGHT + 0.8, 0.8), base, MapPalette.SignEdge)
	local board = slabPart("Board", Vector3.new(OWNER_SIGN_WIDTH, OWNER_SIGN_HEIGHT, 0.9), base, MapPalette.SignBody)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Adornee = board
	gui.Parent = board

	-- Round avatar frame on the left.
	local ring = Instance.new("Frame")
	ring.Name = "AvatarRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.17, 0.5)
	ring.Size = UDim2.fromScale(0.26, 0.74)
	ring.BackgroundColor3 = MapPalette.SignEdge
	ring.BorderSizePixel = 0
	ring.ZIndex = 2
	ring.Parent = gui
	local ringRatio = Instance.new("UIAspectRatioConstraint")
	ringRatio.AspectRatio = 1
	ringRatio.Parent = ring
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Thickness = 4
	ringStroke.Color = MapPalette.SignProgress
	ringStroke.Parent = ring

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.AnchorPoint = Vector2.new(0.5, 0.5)
	avatar.Position = UDim2.fromScale(0.5, 0.5)
	avatar.Size = UDim2.fromScale(0.9, 0.9)
	avatar.BackgroundColor3 = MapPalette.SignBody
	avatar.BorderSizePixel = 0
	avatar.Image = ""
	avatar.ZIndex = 3
	avatar.Parent = ring
	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatar

	-- Name block on the right.
	ownerSignLabel(gui, "DisplayName", UDim2.fromScale(0.62, 0.34), UDim2.fromScale(0.34, 0.14), MapPalette.SignTitle, Enum.TextXAlignment.Left)
	ownerSignLabel(gui, "Username", UDim2.fromScale(0.62, 0.18), UDim2.fromScale(0.34, 0.5), Color3.fromRGB(176, 190, 220), Enum.TextXAlignment.Left)

	-- YOUR BASE badge: built here, switched on by the owner's own client.
	local badge = Instance.new("Frame")
	badge.Name = "YourBase"
	badge.Size = UDim2.fromScale(0.36, 0.2)
	badge.Position = UDim2.fromScale(0.34, 0.72)
	badge.BackgroundColor3 = MapPalette.SignProgress
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = 3
	badge.Parent = gui
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 8)
	badgeCorner.Parent = badge
	local badgeText = ownerSignLabel(badge, "Text", UDim2.fromScale(0.9, 0.8), UDim2.fromScale(0.05, 0.1), Color3.fromRGB(12, 30, 18), Enum.TextXAlignment.Center)
	badgeText.Text = "YOUR BASE"
	badgeText.TextStrokeTransparency = 1
	badgeText.ZIndex = 4

	-- The crown, for a well-upgraded base.
	local crown = ownerSignLabel(gui, "Crown", UDim2.fromScale(0.12, 0.3), UDim2.fromScale(0.86, 0.04), MapPalette.SignMaxed, Enum.TextXAlignment.Center)
	crown.Text = "♛"
	crown.Visible = false

	model.Parent = plot
	return gui
end

--- Repaints a plot's owner sign for whoever holds it (or nobody).
local function paintOwnerSign(plot: Instance, player: Player?, tier: number?)
	local gui = ensureOwnerSign(plot)
	if not gui then
		return
	end
	local displayName = gui:FindFirstChild("DisplayName") :: TextLabel?
	local username = gui:FindFirstChild("Username") :: TextLabel?
	local crown = gui:FindFirstChild("Crown") :: TextLabel?
	local ring = gui:FindFirstChild("AvatarRing")
	local avatar = ring and ring:FindFirstChild("Avatar") :: ImageLabel?
	local badge = gui:FindFirstChild("YourBase") :: Frame?

	if not player then
		if displayName then
			displayName.Text = "AVAILABLE"
			displayName.TextColor3 = Color3.fromRGB(176, 190, 220)
		end
		if username then
			username.Text = "claim this plot"
		end
		if crown then
			crown.Visible = false
		end
		if avatar then
			avatar.Image = ""
		end
		if badge then
			badge.Visible = false
		end
		gui:SetAttribute("OwnerUserId", 0)
		return
	end

	if displayName then
		displayName.Text = player.DisplayName
		displayName.TextColor3 = MapPalette.SignTitle
	end
	if username then
		username.Text = if player.DisplayName ~= player.Name then `@{player.Name}` else ""
	end
	if crown then
		crown.Visible = (tier or 0) >= CROWN_TIER
	end
	gui:SetAttribute("OwnerUserId", player.UserId)

	-- The headshot, from the real UserId. Async and best-effort: a failed
	-- fetch leaves the ring empty rather than showing somebody else.
	if avatar then
		local userId = player.UserId
		task.spawn(function()
			local ok, url = pcall(function()
				return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
			end)
			if ok and type(url) == "string" and avatar.Parent and gui:GetAttribute("OwnerUserId") == userId then
				avatar.Image = url
			end
		end)
	end
end

paintOwnerSignRef = paintOwnerSign

--- Repaints the owner sign from the current profile (the crown depends on the
--- capacity tier, which is only known once the profile is loaded).
function BaseService.refreshOwnerSign(player: Player)
	local plot = assignments[player]
	if not plot then
		return
	end
	local profile = DataService.get(player)
	paintOwnerSign(plot, player, if profile then profile.BaseCapacityTier else 0)
end

-- ==========================================================
-- ASSIGNMENT
-- ==========================================================

function BaseService.assign(player: Player): (Model | Folder)?
	if assignments[player] then
		return assignments[player]
	end
	-- Callers reach here after yielding on the profile. A player who left during
	-- that wait has already had PlayerRemoving fire, so a plot claimed for them
	-- now would never be released - and with seven plots per server, one leaked
	-- plot is one seventh of the server gone for good.
	if not player.Parent then
		return nil
	end

	local bases = getBases()
	for _, plot in bases:GetChildren() do
		if not owners[plot] then
			owners[plot] = player
			assignments[player] = plot :: any
			setOwner(plot, player)

			local profile = DataService.waitForProfile(player)
			if profile then
				BaseService.rebuildDisplays(player)
			end
			if not player.Parent then
				-- Left while the profile was loading. PlayerRemoving may have run
				-- before the claim above landed, in which case nothing will free
				-- the plot but us.
				BaseService.unassign(player)
				return nil
			end

			-- Put the player on their own plot immediately.
			local spawn = plot:FindFirstChild("Spawn")
			local character = player.Character
			if spawn and spawn:IsA("BasePart") and character then
				character:PivotTo(spawn.CFrame * CFrame.new(0, 4, 0))
			end

			print(`[BaseService] {player.Name} -> {plot.Name}`)
			return plot :: any
		end
	end

	-- Every plot is taken. This only happens when the place's Max Players is set
	-- above BaseConfig.PLOT_COUNT (it is a Game Settings value, not something a
	-- script can set). A player with no plot has no base, no spawn, nowhere to
	-- place loot and no treadmill - the game is unplayable for them - so the
	-- honest thing is to say so and let matchmaking put them in a server with
	-- room, rather than leave them wandering a map that cannot pay them.
	warn(`[BaseService] no free plot for {player.Name} (server over {BaseConfig.PLOT_COUNT} players?)`)
	task.delay(1, function()
		if player.Parent and not assignments[player] then
			player:Kick("This server is full - please join another one!")
		end
	end)
	return nil
end

function BaseService.unassign(player: Player)
	local plot = assignments[player]
	if not plot then
		return
	end

	local slots = plot:FindFirstChild("DisplaySlots")
	if slots then
		for _, slot in slots:GetChildren() do
			for _, name in { "Trophy", "Pedestal" } do
				local existing = slot:FindFirstChild(name)
				if existing then
					existing:Destroy()
				end
			end
			if slot:IsA("BasePart") then
				-- A released plot shows the starting capacity's worth of empty
				-- slots, the rest locked, so it reads as available.
				local index = slot:GetAttribute("SlotIndex") :: number?
				styleSlot(slot, if index and index <= GameConfig.STARTING_DISPLAY_SLOTS then "Empty" else "Locked")
			end
		end
	end

	setOwner(plot, nil)
	owners[plot] = nil
	assignments[player] = nil
end

--- The HUD's BASE button. Rate-limited by a simple cooldown, and refused while
--- carrying so it cannot be used to skip an escape.
local lastTeleport: { [Player]: number } = {}

function BaseService.teleportHome(player: Player): (boolean, string?)
	local now = os.clock()
	if now - (lastTeleport[player] or 0) < 3 then
		return false, "Wait a moment."
	end

	local plot = assignments[player]
	local spawn = plot and plot:FindFirstChild("Spawn")
	if not plot or not spawn or not spawn:IsA("BasePart") then
		return false, "You have no base yet."
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return false, "You cannot travel right now."
	end

	lastTeleport[player] = now
	character:PivotTo(spawn.CFrame * CFrame.new(0, 4, 0))
	return true
end

function BaseService.start()
	local bases = getBases()

	Players.PlayerRemoving:Connect(function(player)
		lastTeleport[player] = nil
	end)
	for _, plot in bases:GetChildren() do
		setOwner(plot, nil)
	end

	local function onPlayer(player: Player)
		task.spawn(function()
			DataService.waitForProfile(player)
			BaseService.assign(player)
		end)
	end

	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(BaseService.unassign)
end

return BaseService
