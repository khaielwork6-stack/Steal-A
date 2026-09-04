--!strict
--[[
	LootService
	Four active loot sockets per zone, weighted rolls, and the socket lifecycle
	(GDD section 6).

	Authoritative state lives here and only here. Every concrete loot instance
	carries a GUID and a state, and every transition checks both the current
	state and the expected owner, so RemoteEvent spam or two prompt callbacks
	racing can never duplicate a reward.

	Lifecycle:
	  Spawned   world loot sits in its origin socket
	  Reserved  a steal was accepted; blocks a second claim
	  Carried   welded to one player, guardian active
	  Dropped   loose after PvP, 8s reclaim window
	  Returning transient cleanup
	  Placed    handed to BaseService, no longer world state
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

local LootService = {}

export type LootState = "Spawned" | "Reserved" | "Carried" | "Dropped" | "Returning" | "Placed"

export type LootInstance = {
	id: string,
	itemId: string,
	name: string,
	zoneIndex: number,
	socketIndex: number,
	rarity: string,
	size: string,
	mutation: string,
	baseIncome: number,
	finalIncome: number,
	state: LootState,
	carrier: Player?,
	model: Model?,
	droppedAt: number?,
	deliveredNotice: boolean?, -- so the "you're safe" toast fires only once
}

type Socket = {
	zoneIndex: number,
	index: number,
	part: BasePart,
	loot: LootInstance?,
	refillAt: number?,
}

local sockets: { { Socket } } = {}
local byId: { [string]: LootInstance } = {}

local listeners: { (LootInstance, LootState, LootState) -> () } = {}

--- Notified on every state transition so Carry/Guardian services can react
--- without polling.
function LootService.onStateChanged(callback: (LootInstance, LootState, LootState) -> ())
	table.insert(listeners, callback)
end

local function setState(loot: LootInstance, next: LootState)
	local previous = loot.state
	if previous == next then
		return
	end
	loot.state = next
	for _, callback in listeners do
		task.spawn(callback, loot, previous, next)
	end
end

LootService.setState = setState

-- ==========================================================
-- ROLLING
-- ==========================================================

local function weightedPick(entries: { { chance: number } }): number
	local total = 0
	for _, entry in entries do
		total += entry.chance
	end
	local roll = math.random() * total
	local cursor = 0
	for index, entry in entries do
		cursor += entry.chance
		if roll <= cursor then
			return index
		end
	end
	return #entries
end

--- Rolls a rarity band for the zone, honouring the Secret lock on zones 1-4.
local function rollRarity(zoneIndex: number): string
	local weights = RarityConfig.weightsFor(zoneIndex)
	local total = 0
	for _, weight in weights do
		total += weight
	end

	local roll = math.random() * total
	local cursor = 0
	for _, rarity in RarityConfig.Order do
		cursor += weights[rarity] or 0
		if roll <= cursor then
			return rarity
		end
	end
	return "Common"
end

--- ItemIds of the types currently active anywhere in a zone. A zone never shows
--- the same type twice at once.
local function activeTypes(zoneIndex: number): { [string]: boolean }
	local active = {}
	for _, socket in sockets[zoneIndex] do
		if socket.loot then
			active[socket.loot.itemId] = true
		end
	end
	return active
end

--- Rolls rarity, then an eligible item of that rarity not already active.
--- Falls back through other rarities rather than ever leaving a socket empty.
local function rollItem(zoneIndex: number): LootConfig.ItemDef?
	local pool = LootConfig.Items[zoneIndex]
	local taken = activeTypes(zoneIndex)

	for _ = 1, 12 do
		local rarity = rollRarity(zoneIndex)
		local candidates = {}
		for _, item in pool do
			if item.rarity == rarity and not taken[item.id] then
				table.insert(candidates, item)
			end
		end
		if #candidates > 0 then
			return candidates[weightedPick(candidates)]
		end
	end

	-- Everything in the rolled bands was already active: take any free type.
	local remaining = {}
	for _, item in pool do
		if not taken[item.id] then
			table.insert(remaining, item)
		end
	end
	if #remaining == 0 then
		return nil
	end
	return remaining[weightedPick(remaining)]
end

local function rollVariant(list: { RarityConfig.Variant }): RarityConfig.Variant
	return list[weightedPick(list)]
end

-- ==========================================================
-- WORLD MODEL
-- ==========================================================

--- Real per-zone models are used when present; otherwise a rarity-tinted
--- placeholder keeps the whole loop testable without art.
local function buildModel(loot: LootInstance): Model
	local model: Model

	local assets = game:GetService("ServerStorage"):FindFirstChild("GameAssets")
	local source = if assets and assets:FindFirstChild("Loot")
		then assets.Loot:FindFirstChild(loot.itemId, true)
		else nil

	if source and source:IsA("Model") then
		model = source:Clone()
	else
		model = Instance.new("Model")
		local part = Instance.new("Part")
		part.Name = "Placeholder"
		part.Size = Vector3.new(6, 7, 6)
		part.Color = RarityConfig.Colors[loot.rarity] or Color3.fromRGB(200, 200, 200)
		part.Material = Enum.Material.SmoothPlastic
		part.Parent = model
		model.PrimaryPart = part
	end

	model.Name = loot.itemId

	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart")
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CastShadow = false
		end
	end

	-- Size is a visual scale plus a movement multiplier, never physics mass.
	local size = RarityConfig.SizeById[loot.size]
	if size and size.scale and size.scale ~= 1 then
		model:ScaleTo(size.scale)
	end

	model:SetAttribute("LootId", loot.id)
	model:SetAttribute("ItemId", loot.itemId)
	model:SetAttribute("Rarity", loot.rarity)

	return model
end

--- Floating card: name, rarity, variants and live income.
local function buildLabel(loot: LootInstance, model: Model)
	local anchor = model.PrimaryPart
	if not anchor then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "LootLabel"
	gui.Size = UDim2.fromScale(11, 4)
	gui.StudsOffsetWorldSpace = Vector3.new(0, anchor.Size.Y / 2 + 4, 0)
	gui.MaxDistance = 260
	gui.Adornee = anchor
	gui.Parent = anchor

	local color = RarityConfig.Colors[loot.rarity] or Color3.new(1, 1, 1)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, 0.42)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextStrokeTransparency = 0.35
	title.TextColor3 = color
	title.Text = loot.name
	title.Parent = gui

	local variant = Instance.new("TextLabel")
	variant.Size = UDim2.fromScale(1, 0.28)
	variant.Position = UDim2.fromScale(0, 0.42)
	variant.BackgroundTransparency = 1
	variant.Font = Enum.Font.FredokaOne
	variant.TextScaled = true
	variant.TextStrokeTransparency = 0.4
	variant.TextColor3 = Color3.fromRGB(240, 240, 248)
	local tags = loot.rarity
	if loot.size ~= "Normal" then
		tags ..= " · " .. loot.size
	end
	if loot.mutation ~= "Normal" then
		tags ..= " · " .. loot.mutation
	end
	variant.Text = tags
	variant.Parent = gui

	local income = Instance.new("TextLabel")
	income.Size = UDim2.fromScale(1, 0.3)
	income.Position = UDim2.fromScale(0, 0.7)
	income.BackgroundTransparency = 1
	income.Font = Enum.Font.FredokaOne
	income.TextScaled = true
	income.TextStrokeTransparency = 0.4
	income.TextColor3 = Color3.fromRGB(126, 255, 148)
	income.Text = NumberFormat.income(loot.finalIncome)
	income.Parent = gui
end

--- Mutations are asset-cheap: material, colour and particles only. Never a
--- separate mesh per variant.
local function applyMutation(loot: LootInstance, model: Model)
	if loot.mutation == "Normal" then
		return
	end
	local anchor = model.PrimaryPart
	if not anchor then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "MutationGlow"
	highlight.FillTransparency = 0.7
	highlight.OutlineTransparency = 0
	highlight.Adornee = model
	highlight.Parent = model

	if loot.mutation == "Shiny" then
		highlight.FillColor = Color3.fromRGB(255, 255, 255)
		highlight.OutlineColor = Color3.fromRGB(220, 240, 255)
		anchor.Material = Enum.Material.Glass
	elseif loot.mutation == "Golden" then
		highlight.FillColor = Color3.fromRGB(255, 205, 60)
		highlight.OutlineColor = Color3.fromRGB(255, 226, 120)
		anchor.Material = Enum.Material.Metal
		anchor.Color = Color3.fromRGB(255, 198, 62)
	elseif loot.mutation == "Neon" then
		highlight.FillColor = Color3.fromRGB(120, 240, 255)
		highlight.OutlineColor = Color3.fromRGB(160, 250, 255)
		anchor.Material = Enum.Material.Neon
	elseif loot.mutation == "Glitched" then
		highlight.FillColor = Color3.fromRGB(255, 74, 190)
		highlight.OutlineColor = Color3.fromRGB(140, 255, 255)
		anchor.Material = Enum.Material.ForceField
	end
end

-- ==========================================================
-- SOCKET LIFECYCLE
-- ==========================================================

local function despawn(loot: LootInstance)
	if loot.model then
		loot.model:Destroy()
		loot.model = nil
	end
end

--- Places a rolled instance into its socket and makes it stealable.
local function materialise(socket: Socket, loot: LootInstance)
	local model = buildModel(loot)
	buildLabel(loot, model)
	applyMutation(loot, model)

	local anchor = model.PrimaryPart :: BasePart
	local lift = anchor.Size.Y / 2 + 1
	model.Parent = socket.part
	model:PivotTo(socket.part.CFrame * CFrame.new(0, lift, 0))

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StealPrompt"
	prompt.ActionText = "Steal"
	prompt.ObjectText = loot.name
	prompt.HoldDuration = GameConfig.STEAL_HOLD_DURATION
	prompt.MaxActivationDistance = GameConfig.STEAL_INTERACTION_RANGE
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	loot.model = model
	socket.loot = loot
	socket.refillAt = nil
end

--- Rolls and spawns a fresh instance for an empty socket.
function LootService.fillSocket(socket: Socket): LootInstance?
	if socket.loot then
		return socket.loot
	end

	local def = rollItem(socket.zoneIndex)
	if not def then
		return nil
	end

	local size = rollVariant(RarityConfig.Sizes)
	local mutation = rollVariant(RarityConfig.Mutations)

	local loot: LootInstance = {
		id = HttpService:GenerateGUID(false),
		itemId = def.id,
		name = def.name,
		zoneIndex = socket.zoneIndex,
		socketIndex = socket.index,
		rarity = def.rarity,
		size = size.id,
		mutation = mutation.id,
		baseIncome = def.income,
		finalIncome = RarityConfig.finalIncome(def.income, size.id, mutation.id),
		state = "Spawned",
	}

	byId[loot.id] = loot
	materialise(socket, loot)
	return loot
end

function LootService.get(lootId: string): LootInstance?
	return byId[lootId]
end

function LootService.getSocket(zoneIndex: number, socketIndex: number): Socket?
	local zone = sockets[zoneIndex]
	return if zone then zone[socketIndex] else nil
end

--- Detaches loot from its socket. The socket refills after `delay` seconds.
function LootService.detach(loot: LootInstance, delay: number)
	local socket = LootService.getSocket(loot.zoneIndex, loot.socketIndex)
	if socket and socket.loot == loot then
		socket.loot = nil
		socket.refillAt = os.clock() + delay
	end
end

--- Sends an instance back to its origin socket. Used by guardian reclaims,
--- expired PvP drops, disconnects and any failed transition.
function LootService.returnToOrigin(loot: LootInstance, delay: number?)
	setState(loot, "Returning")
	loot.carrier = nil

	task.delay(delay or 0, function()
		if loot.state ~= "Returning" then
			return
		end
		despawn(loot)

		local socket = LootService.getSocket(loot.zoneIndex, loot.socketIndex)
		if socket and not socket.loot then
			loot.state = "Spawned"
			materialise(socket, loot)
		else
			-- Origin was refilled while we were away; retire this instance.
			byId[loot.id] = nil
		end
	end)
end

--- Removes an instance from world tracking once it becomes a base trophy.
function LootService.consume(loot: LootInstance)
	setState(loot, "Placed")
	despawn(loot)
	byId[loot.id] = nil
	LootService.detach(loot, GameConfig.SOCKET_REFILL_DELAY)
end

-- ==========================================================
-- REFRESH
-- ==========================================================

--- Rerolls every uncarried world item. Carried and reserved loot is untouched:
--- a player mid-escape must never have their prize vanish.
function LootService.refreshAll()
	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] do
			local loot = socket.loot
			if loot and loot.state == "Spawned" then
				despawn(loot)
				byId[loot.id] = nil
				socket.loot = nil
			end
		end
	end

	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] do
			LootService.fillSocket(socket)
		end
	end
end

--- Snapshot for tests and debugging.
function LootService.snapshot(): { [string]: any }
	local out = {}
	for zoneIndex = 1, ZoneConfig.COUNT do
		local rows = {}
		for _, socket in sockets[zoneIndex] do
			local loot = socket.loot
			table.insert(rows, if loot
				then `{loot.name} [{loot.rarity}] {loot.size}/{loot.mutation} {NumberFormat.income(loot.finalIncome)} ({loot.state})`
				else "<empty>")
		end
		out[ZoneConfig.Zones[zoneIndex].id] = rows
	end
	return out
end

-- ==========================================================
-- START
-- ==========================================================

function LootService.start()
	local map = workspace:WaitForChild("Map", 20)
	assert(map, "LootService: Workspace.Map missing - run MapBuilder.build() first")
	local zonesFolder = map:WaitForChild("Zones", 10)

	for zoneIndex, zoneDef in ZoneConfig.Zones do
		local zone = zonesFolder:FindFirstChild(zoneDef.id)
		assert(zone, `LootService: missing map folder {zoneDef.id}`)

		sockets[zoneIndex] = {}
		local socketFolder = zone:FindFirstChild("SpawnSockets")
		assert(socketFolder, `LootService: {zoneDef.id} has no SpawnSockets`)

		for socketIndex = 1, ZoneConfig.SOCKETS_PER_ZONE do
			local part = socketFolder:FindFirstChild(string.format("Socket%02d", socketIndex))
			assert(part and part:IsA("BasePart"), `LootService: {zoneDef.id} missing Socket{socketIndex}`)

			sockets[zoneIndex][socketIndex] = {
				zoneIndex = zoneIndex,
				index = socketIndex,
				part = part :: BasePart,
				loot = nil,
			}
		end
	end

	-- Fill everything on server start.
	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] do
			LootService.fillSocket(socket)
		end
	end

	-- Refill timer: sockets emptied by a theft come back after 20s.
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for zoneIndex = 1, ZoneConfig.COUNT do
				for _, socket in sockets[zoneIndex] do
					if not socket.loot and socket.refillAt and now >= socket.refillAt then
						LootService.fillSocket(socket)
					end
				end
			end
		end
	end)

	-- Global reroll on a 300s cadence, with a countdown so nobody is surprised.
	task.spawn(function()
		while true do
			task.wait(GameConfig.GLOBAL_REFRESH_INTERVAL - GameConfig.GLOBAL_REFRESH_WARNING)
			LootService.refreshWarning()
			task.wait(GameConfig.GLOBAL_REFRESH_WARNING)
			LootService.refreshAll()
		end
	end)

	print(`[LootService] {ZoneConfig.COUNT} zones x {ZoneConfig.SOCKETS_PER_ZONE} sockets filled`)
end

--- Overridden by StateService wiring in init so LootService stays dependency-free.
function LootService.refreshWarning() end

return LootService
