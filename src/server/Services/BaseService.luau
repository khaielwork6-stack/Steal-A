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
local SizeAura = require(ReplicatedStorage.Shared.Util.SizeAura)
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

--- Whether a joining player should start on the hub rather than their plot.
--- Overridden by init: true only when the player holds no plot at all.
function BaseService.spawnsAtHub(_player: Player): boolean
	return false
end

--- Where this player's character belongs when it appears: the hub's spawn
--- circle while they have not yet stolen anything, their own plot's Spawn
--- after that. ONE answer for the first join and for every respawn - the
--- server's respawn handler used to pivot every fresh character to the plot,
--- which silently undid the hub start a moment after `assign` had set it.
function BaseService.homeSpawn(player: Player): BasePart?
	local plot = assignments[player]
	local spawn: Instance? = if plot then plot:FindFirstChild("Spawn") else nil
	if BaseService.spawnsAtHub(player) then
		local map = workspace:FindFirstChild("Map")
		local spawns = map and map:FindFirstChild("SpawnLocations")
		spawn = (spawns and spawns:FindFirstChild("LobbySpawn")) or spawn
	end
	return if spawn and spawn:IsA("BasePart") then spawn else nil
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
	-- And the size aura. A Titan on a pedestal is the thing a visiting player
	-- should see from the avenue.
	SizeAura.apply(model, item.Size)

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
-- THE OWNER DISPLAY
-- ==========================================================
--
-- Who owns this plot, said the way a Roblox game says it: the owner's own
-- avatar headshot in a round frame with their display name under it, floating
-- over the front of the base. No board, no post, no wall of text.
--
-- WHAT IT REPLACED. This used to be a 14x6 stud physical sign standing at the
-- front corner - the "base belongs to someone" sign. It read as clutter from
-- the avenue and hid the porch behind it. The billboard version scales itself
-- on every screen (a BillboardGui is sized in studs and drawn in pixels, so a
-- phone gets the same readable size a desktop does) and disappears entirely
-- while the plot is unclaimed.
--
-- THE IMAGE IS NEVER HARD-CODED. `rbxthumb://` resolves the headshot from the
-- real UserId on the client that renders it, retries on its own, and shows
-- Roblox's placeholder if the account has no thumbnail yet - so a failed
-- avatar is a grey silhouette under the right name, never somebody else's
-- face and never a broken box.

local OWNER_SIGN_NAME = "OwnerSign" -- the retired board; destroyed on sight
local OWNER_DISPLAY_NAME = "OwnerDisplay"
--- Studs above the porch. High enough to clear a Colossal on the front pads,
--- low enough to read as belonging to this plot and not the sky.
local OWNER_DISPLAY_LIFT = 15
--- Capacity tier from which the crown shows (roughly the halfway mark).
local CROWN_TIER = 4

--- The invisible part the billboard hangs from, at the front-centre of the
--- plot, above the porch. Built once per plot and reused.
local function ownerDisplayAnchor(plot: Instance): BasePart?
	local existing = plot:FindFirstChild(OWNER_DISPLAY_NAME)
	if existing and existing:IsA("BasePart") then
		return existing
	end

	-- The plot's own frame comes from its floor slab, which MapBuilder laid
	-- down with the plot's rotation: local X across the plot, local -Z toward
	-- the open front where players arrive.
	local floor = plot:FindFirstChild("PlotFloor")
	local slab = floor and floor:FindFirstChild("Slab")
	if not slab or not slab:IsA("BasePart") then
		return nil
	end

	local anchor = Instance.new("Part")
	anchor.Name = OWNER_DISPLAY_NAME
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = slab.CFrame * CFrame.new(0, OWNER_DISPLAY_LIFT, -slab.Size.Z / 2 + 8)
	anchor.Parent = plot
	return anchor
end

local function ensureOwnerDisplay(plot: Instance): BillboardGui?
	-- The old physical sign, wherever it survives (a place saved before this
	-- change, a plot dressed by an older build).
	local retired = plot:FindFirstChild(OWNER_SIGN_NAME)
	if retired then
		retired:Destroy()
	end

	local anchor = ownerDisplayAnchor(plot)
	if not anchor then
		return nil
	end
	local existing = anchor:FindFirstChildOfClass("BillboardGui")
	if existing then
		return existing
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "Owner"
	-- Studs, so it is the same physical size for everyone. ExtentsOffset keeps
	-- the name under the portrait rather than the whole thing over the anchor.
	gui.Size = UDim2.fromScale(7, 8.6)
	gui.SizeOffset = Vector2.new(0, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 260
	gui.Adornee = anchor
	gui.Parent = anchor

	-- The portrait: a dark disc, the headshot inside it, a bright ring around
	-- it. Cropped by the disc, so a wide thumbnail cannot spill out.
	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0)
	ring.Position = UDim2.fromScale(0.5, 0)
	ring.Size = UDim2.fromScale(0.78, 0.68)
	ring.SizeConstraint = Enum.SizeConstraint.RelativeXX
	ring.BackgroundColor3 = Color3.fromRGB(24, 30, 52)
	ring.BorderSizePixel = 0
	ring.ClipsDescendants = true
	ring.Parent = gui
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = ring
	local stroke = Instance.new("UIStroke")
	stroke.Name = "RingStroke"
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 3
	stroke.Transparency = 0.05
	stroke.Parent = ring

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.Size = UDim2.fromScale(1, 1)
	avatar.BackgroundTransparency = 1
	avatar.ScaleType = Enum.ScaleType.Crop
	avatar.Image = ""
	avatar.Parent = ring

	local crown = Instance.new("TextLabel")
	crown.Name = "Crown"
	crown.AnchorPoint = Vector2.new(0.5, 1)
	crown.Position = UDim2.fromScale(0.5, 0.02)
	crown.Size = UDim2.fromScale(0.3, 0.22)
	crown.BackgroundTransparency = 1
	crown.Font = Enum.Font.FredokaOne
	crown.TextScaled = true
	crown.Text = "👑"
	crown.Visible = false
	crown.Parent = gui

	local name = Instance.new("TextLabel")
	name.Name = "DisplayName"
	name.AnchorPoint = Vector2.new(0.5, 1)
	name.Position = UDim2.fromScale(0.5, 1)
	name.Size = UDim2.fromScale(1, 0.26)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = Color3.fromRGB(255, 255, 255)
	name.TextStrokeTransparency = 0.1
	name.TextStrokeColor3 = Color3.fromRGB(12, 16, 32)
	name.Text = ""
	name.Parent = gui

	return gui
end

--- Repaints one plot's display. `player` nil hides it: an unclaimed plot says
--- nothing at all rather than advertising itself.
local function paintOwnerSign(plot: Instance, player: Player?, tier: number?)
	local gui = ensureOwnerDisplay(plot)
	if not gui then
		return
	end

	if not player then
		gui.Enabled = false
		gui:SetAttribute("OwnerUserId", 0)
		local ring = gui:FindFirstChild("Ring")
		local avatar = ring and ring:FindFirstChild("Avatar")
		if avatar and avatar:IsA("ImageLabel") then
			avatar.Image = ""
		end
		return
	end

	local name = gui:FindFirstChild("DisplayName") :: TextLabel?
	local crown = gui:FindFirstChild("Crown") :: TextLabel?
	local ring = gui:FindFirstChild("Ring")
	local avatar = ring and ring:FindFirstChild("Avatar") :: ImageLabel?

	if name then
		name.Text = player.DisplayName
	end
	if crown then
		crown.Visible = (tier or 0) >= CROWN_TIER
	end
	if avatar then
		-- Resolved per client from the real UserId, with Roblox's own retry and
		-- placeholder behind it. No web call on this server, and nothing to
		-- fail here.
		avatar.Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
	end
	gui:SetAttribute("OwnerUserId", player.UserId)
	gui.Enabled = true
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

	-- A RANDOM free plot, not the first one. Claiming in child order gave the
	-- first player of every session the same base, and the plaza filled from
	-- one end. The pick and the claim happen in the same resumption - there is
	-- no yield between them - so two players joining on the same frame cannot
	-- come out of this holding the same plot.
	local bases = getBases()
	local free: { Instance } = {}
	for _, plot in bases:GetChildren() do
		if not owners[plot] then
			table.insert(free, plot)
		end
	end
	if #free > 0 then
		local plot = free[math.random(#free)]
		do
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

			-- Where the player starts: the porch of the plot just claimed,
			-- facing out down the avenue, AFTER the profile has loaded and
			-- rebuildDisplays has put their collection back on the pads. The
			-- character is never moved before both of those are done, so a
			-- player never watches their own base populate around them.
			local character = player.Character
			local spawn = BaseService.homeSpawn(player)
			if spawn and character then
				character:PivotTo(spawn.CFrame * CFrame.new(0, 4, 0))
			end

			print(`[BaseService] {player.Name} -> {plot.Name} ({#free} were free)`)
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

--- The look of a plot nobody owns: no trophies, the starting capacity's worth
--- of empty slots, the rest locked - so it reads as available, and so the
--- builder's plain pads are never what a player sees.
local function styleUnowned(plot: Instance)
	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return
	end
	for _, slot in slots:GetChildren() do
		for _, name in { "Trophy", "Pedestal" } do
			local existing = slot:FindFirstChild(name)
			if existing then
				existing:Destroy()
			end
		end
		if slot:IsA("BasePart") then
			local index = slot:GetAttribute("SlotIndex") :: number?
			styleSlot(slot, if index and index <= GameConfig.STARTING_DISPLAY_SLOTS then "Empty" else "Locked")
		end
	end
end

function BaseService.unassign(player: Player)
	local plot = assignments[player]
	if not plot then
		return
	end

	styleUnowned(plot)

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
		-- Every plot is dressed from the first frame, owned or not: the
		-- builder's pads are plain, and six unowned plots of plain pads were
		-- the white rectangles across the plaza.
		styleUnowned(plot)
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
