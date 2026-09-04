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

local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

local DataService = require(script.Parent.DataService)

local BaseService = {}

local assignments: { [Player]: Model | Folder } = {}
local owners: { [Instance]: Player } = {}

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
local function setOwner(plot: Instance, player: Player?)
	plot:SetAttribute("OwnerUserId", if player then player.UserId else 0)
	plot:SetAttribute("OwnerName", if player then player.Name else "")

	local spawn = plot:FindFirstChild("Spawn")
	if spawn and spawn:IsA("SpawnLocation") then
		spawn.Enabled = player ~= nil
	end
end

function BaseService.getPlot(player: Player): (Model | Folder)?
	return assignments[player]
end

function BaseService.getOwner(plot: Instance): Player?
	return owners[plot]
end

--- Resolves the plot a position sits inside, if any. Used by safe-zone checks.
function BaseService.plotAt(position: Vector3): Instance?
	for plot in owners do
		local safe = plot:FindFirstChild("SafeZone")
		if safe and safe:IsA("BasePart") then
			local local_ = safe.CFrame:PointToObjectSpace(position)
			local half = safe.Size / 2
			if
				math.abs(local_.X) <= half.X
				and math.abs(local_.Y) <= half.Y
				and math.abs(local_.Z) <= half.Z
			then
				return plot
			end
		end
	end
	return nil
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

--- Placeholder trophy. Real per-zone models drop into
--- ServerStorage.GameAssets.Loot.<ZoneFolder>.<AssetName> and are used
--- automatically once present; until then we show a labelled block so the
--- economy is fully testable without art.
local function buildTrophy(item: DataService.DisplayItem): Model
	local model = Instance.new("Model")
	model.Name = item.ItemId

	local assets = game:GetService("ServerStorage"):FindFirstChild("GameAssets")
	local source = nil
	if assets then
		local loot = assets:FindFirstChild("Loot")
		if loot then
			source = loot:FindFirstChild(item.ItemId, true)
		end
	end

	if source and source:IsA("Model") then
		model = source:Clone()
		model.Name = item.ItemId
	else
		local part = Instance.new("Part")
		part.Name = "Placeholder"
		part.Size = Vector3.new(8, 10, 8)
		part.Color = RarityConfig.Colors[item.Rarity] or Color3.fromRGB(200, 200, 200)
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = true
		part.CanCollide = false
		part.Parent = model
		model.PrimaryPart = part
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CastShadow = false
		end
	end

	model:SetAttribute("InstanceId", item.InstanceId)
	model:SetAttribute("ItemId", item.ItemId)
	model:SetAttribute("FinalIncome", item.FinalIncome)

	return model
end

--- Income/name card floating over a placed trophy.
local function buildLabel(item: DataService.DisplayItem, parent: Model)
	local def = LootConfig.ById[item.ItemId]
	local anchor = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart")
	if not anchor then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "TrophyLabel"
	gui.Size = UDim2.fromScale(9, 3)
	gui.StudsOffsetWorldSpace = Vector3.new(0, anchor.Size.Y / 2 + 4, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 220
	gui.Adornee = anchor
	gui.Parent = anchor

	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, 0.55)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = RarityConfig.Colors[item.Rarity] or Color3.new(1, 1, 1)
	title.TextStrokeTransparency = 0.4
	title.Text = if def then def.name else item.ItemId
	title.Parent = gui

	local income = Instance.new("TextLabel")
	income.Size = UDim2.fromScale(1, 0.45)
	income.Position = UDim2.fromScale(0, 0.55)
	income.BackgroundTransparency = 1
	income.Font = Enum.Font.FredokaOne
	income.TextScaled = true
	income.TextColor3 = Color3.fromRGB(120, 255, 140)
	income.TextStrokeTransparency = 0.4
	income.Text = NumberFormat.income(item.FinalIncome)
	income.Parent = gui
end

--- Rebuilds every placed trophy from the profile. Called on assignment and
--- after any placement or sale.
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

	for _, slot in slots:GetChildren() do
		local index = slot:GetAttribute("SlotIndex") :: number?
		if not index then
			continue
		end

		local existing = slot:FindFirstChild("Trophy")
		if existing then
			existing:Destroy()
		end

		if slot:IsA("BasePart") then
			-- Slots past current capacity stay hidden and non-interactive.
			slot.Transparency = if index <= unlocked then 0.55 else 1
		end
	end

	for _, item in profile.DisplayItems do
		local slot = slots:FindFirstChild(string.format("DisplaySlot%02d", item.SlotIndex))
		if slot and slot:IsA("BasePart") and item.SlotIndex <= unlocked then
			local trophy = buildTrophy(item)
			trophy.Name = "Trophy"
			buildLabel(item, trophy)
			trophy.Parent = slot

			local anchor = trophy.PrimaryPart or trophy:FindFirstChildWhichIsA("BasePart")
			if anchor then
				local lift = anchor.Size.Y / 2
				trophy:PivotTo(slot.CFrame * CFrame.new(0, lift + 0.5, 0))
			end
		end
	end
end

-- ==========================================================
-- ASSIGNMENT
-- ==========================================================

function BaseService.assign(player: Player): (Model | Folder)?
	if assignments[player] then
		return assignments[player]
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

	warn(`[BaseService] no free plot for {player.Name} (server over {BaseConfig.PLOT_COUNT} players?)`)
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
			local trophy = slot:FindFirstChild("Trophy")
			if trophy then
				trophy:Destroy()
			end
			if slot:IsA("BasePart") then
				slot.Transparency = 0.55
			end
		end
	end

	setOwner(plot, nil)
	owners[plot] = nil
	assignments[player] = nil
end

function BaseService.start()
	local bases = getBases()
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
