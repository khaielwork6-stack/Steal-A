--!strict
--[[
	LootService
	Four active loot sockets per zone, weighted rolls, and the socket lifecycle.

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

	== SPAWN PACING - THE RULE THAT SHAPES THE WHOLE GAME ==

	A socket emptied by a SUCCESSFUL theft stays empty. There is no per-socket
	refill timer, and adding one back would undo the entire economy pass: 48
	sockets each quietly rerolling every 20 seconds is a slot machine that prints
	the best items in the game faster than anyone can spend them.

	Sockets refill ONLY at the global refresh (every GLOBAL_REFRESH_INTERVAL
	seconds, with a countdown). That gives the server a shared rhythm - loot
	appears, players hunt, the good sockets get taken, the world empties, the
	countdown runs, everyone races out again.

	Two paths put an item back early, and BOTH return the same instance rather
	than rolling a new one:
	  * a guardian reclaim (you were caught - you should not have to wait five
	    minutes for the thing you failed to steal)
	  * an unclaimed PvP drop timing out

	== JACKPOTS ==

	The 8th item in every zone is its jackpot and is excluded from ordinary rolls
	entirely. Once per global refresh the server makes ONE roll (never one per
	socket) at GameConfig.JACKPOT_REFRESH_CHANCE; on success exactly one jackpot
	is placed in one socket of one reachable zone and announced. Players still
	have to go and steal it.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local MutationVfx = require(ReplicatedStorage.Shared.Util.MutationVfx)
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
	jackpot: boolean,
	state: LootState,
	carrier: Player?,
	model: Model?,
	droppedAt: number?,
	deliveredNotice: boolean?, -- so the "you're safe" toast fires only once
	escapeNotice: boolean?, -- so the "you escaped" toast fires only once
}

type Socket = {
	zoneIndex: number,
	index: number,
	part: BasePart,
	loot: LootInstance?,
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

--- ItemIds of the types currently active anywhere in a zone. A zone never shows
--- the same type twice at once.
local function activeTypes(zoneIndex: number): { [string]: boolean }
	local active = {}
	for _, socket in sockets[zoneIndex] or {} do
		if socket.loot then
			active[socket.loot.itemId] = true
		end
	end
	return active
end

--- Rolls one item for a socket out of the zone's NORMAL pool.
---
--- Jackpots are not in that pool at all, so no amount of socket churn can
--- produce one. Everything else is weighted by its rarity's share of
--- RarityConfig.NormalWeights and then RENORMALISED across whatever is actually
--- eligible - which handles both a zone whose ladder omits a tier and a tier
--- whose item is already on show in another socket, without the old
--- roll-a-band-then-hunt-for-a-member fallback that quietly skewed the curve.
--- `exclude` defaults to the types already on show in the zone (a zone never
--- shows the same type twice at once). Tests pass an empty table to measure the
--- raw weight curve rather than the without-replacement one four live sockets
--- actually produce.
local function rollItem(zoneIndex: number, exclude: { [string]: boolean }?): LootConfig.ItemDef?
	local taken = exclude or activeTypes(zoneIndex)

	local candidates: { LootConfig.ItemDef } = {}
	local weights: { number } = {}
	local total = 0

	for _, item in LootConfig.normalPool(zoneIndex) do
		if not taken[item.id] then
			table.insert(candidates, item)
			local weight = RarityConfig.NormalWeights[item.rarity] or 0
			table.insert(weights, weight)
			total += weight
		end
	end

	if #candidates == 0 then
		return nil
	end
	if total <= 0 then
		-- No eligible tier carries a normal weight. Should be impossible with a
		-- sane ladder, but never leave a socket empty over a config typo.
		return candidates[math.random(#candidates)]
	end

	local roll = math.random() * total
	local cursor = 0
	for index, item in candidates do
		cursor += weights[index]
		if roll <= cursor then
			return item
		end
	end
	return candidates[#candidates]
end

LootService.rollItem = rollItem

local function rollVariant(list: { RarityConfig.Variant }): RarityConfig.Variant
	return list[weightedPick(list)]
end

-- ==========================================================
-- WORLD MODEL
-- ==========================================================

--- Real per-zone models are used when present; otherwise a rarity-tinted
--- placeholder keeps the whole loop testable without art. LootModel owns the
--- lookup, the wrapping of non-Model art and the scale normalisation, so this
--- and BaseService.buildTrophy cannot drift apart.
local function buildModel(loot: LootInstance): Model
	-- Size is a visual scale plus a movement multiplier, never physics mass.
	local size = RarityConfig.SizeById[loot.size]

	local model = LootModel.build({
		itemId = loot.itemId,
		rarity = loot.rarity,
		targetHeight = GameConfig.LOOT_WORLD_HEIGHT,
		sizeScale = if size then size.scale else nil,
		placeholderSize = Vector3.new(6, 7, 6),
	})

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
	-- +6 rather than +4. This label is 4 studs tall, so at +4 its lower edge sat
	-- only two studs above the object - not enough room for the interact prompt,
	-- which has to live between them and needs about three. The prompt is the
	-- call to action and belongs nearest the object, so the label yields.
	gui.StudsOffsetWorldSpace = Vector3.new(0, anchor.Size.Y / 2 + 6, 0)
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
--- Mutation dressing is one shared system (MutationVfx) driven by the artist's
--- assets, so a new mutation or a new item needs no code here. Materials are no
--- longer overridden: the imported models have their own, and replacing them
--- turned a stone meteorite into glass.
local function applyMutation(loot: LootInstance, model: Model)
	MutationVfx.apply(model, loot.mutation)
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

	model.Parent = socket.part

	-- Sit the model ON the pedestal by measuring where its lowest point actually
	-- ends up, rather than guessing from the PrimaryPart's height. An imported
	-- model's pivot is wherever the artist left it, and its PrimaryPart is often
	-- a small piece, so the old guess buried statues and floated paintings.
	model:PivotTo(socket.part.CFrame)
	local lowest = math.huge
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local half = descendant.Size / 2
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local corner = (descendant.CFrame * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
						lowest = math.min(lowest, corner.Y)
					end
				end
			end
		end
	end

	if lowest < math.huge then
		local surface = socket.part.Position.Y + socket.part.Size.Y / 2
		model:PivotTo(model:GetPivot() + Vector3.new(0, surface + 0.2 - lowest, 0))
	end

	-- Recursive: an imported model keeps its parts inside nested Models, so the
	-- anchor is often not a direct child.
	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		warn(`[LootService] {loot.itemId} has no part to host its prompt`)
		return
	end

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
end

--- Builds a concrete instance from a definition. `sizeId` / `mutationId` are
--- rolled when omitted - a jackpot injection deliberately takes the normal rolls
--- so it can still arrive Huge and Corrupted.
local function makeInstance(
	def: LootConfig.ItemDef,
	zoneIndex: number,
	socketIndex: number,
	sizeId: string?,
	mutationId: string?
): LootInstance
	local size = sizeId or rollVariant(RarityConfig.Sizes).id
	local mutation = mutationId or rollVariant(RarityConfig.Mutations).id

	return {
		id = HttpService:GenerateGUID(false),
		itemId = def.id,
		name = def.name,
		zoneIndex = zoneIndex,
		socketIndex = socketIndex,
		rarity = def.rarity,
		size = size,
		mutation = mutation,
		baseIncome = def.income,
		finalIncome = RarityConfig.finalIncome(def.income, size, mutation),
		jackpot = def.jackpot,
		state = "Spawned",
	}
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

	local loot = makeInstance(def, socket.zoneIndex, socket.index)
	byId[loot.id] = loot
	materialise(socket, loot)
	return loot
end

function LootService.get(lootId: string): LootInstance?
	return byId[lootId]
end

--- Resolves the loot instance that owns any descendant - typically the part a
--- ProximityPrompt is parented to.
---
--- Do NOT use `FindFirstAncestorOfClass("Model")` for this. It returns the
--- NEAREST model, and imported art keeps its parts inside nested Models: the
--- vase lives at `Museum_AncientVase > brass_vase_01 > Circle.001`, so the
--- nearest model is the artist's inner group, which carries no LootId. The steal
--- then silently did nothing on exactly the items that have real art - including
--- the tutorial vase, which blocked the whole opening.
---
--- Walking for the ATTRIBUTE instead of for a class is also immune to however
--- deeply a future import nests itself. Bounded at workspace, which is itself a
--- Model and would otherwise be walked into.
function LootService.fromDescendant(instance: Instance?): LootInstance?
	local current = instance
	while current and current ~= workspace do
		local lootId = current:GetAttribute("LootId")
		if type(lootId) == "string" then
			return byId[lootId]
		end
		current = current.Parent
	end
	return nil
end

--- Pins a specific item into a socket. Used for the tutorial's guaranteed
--- Ancient Vase and for jackpot injection. Refuses if the socket is mid-steal so
--- a player escaping with something can never have it swapped out from under
--- them. Returns the instance now sitting in the socket, or nil if it could not
--- be forced.
---
--- `sizeId` / `mutationId` are optional: omit them to take the normal variant
--- rolls (what a jackpot wants), pass them to pin an exact instance (what the
--- tutorial wants).
function LootService.forceSocket(
	zoneIndex: number,
	socketIndex: number,
	itemId: string,
	sizeId: string?,
	mutationId: string?
): LootInstance?
	local socket = LootService.getSocket(zoneIndex, socketIndex)
	if not socket then
		return nil
	end

	local def = LootConfig.ById[itemId]
	if not def then
		return nil
	end

	local current = socket.loot
	if current then
		if current.state ~= "Spawned" then
			return nil -- reserved or being carried; leave it alone
		end
		if
			current.itemId == itemId
			and (sizeId == nil or current.size == sizeId)
			and (mutationId == nil or current.mutation == mutationId)
		then
			return current -- already correct
		end
		despawn(current)
		byId[current.id] = nil
		socket.loot = nil
	end

	-- A zone never shows the same type twice. Pinning bypasses the roller, so it
	-- has to enforce that itself: an ordinary roll elsewhere in this zone may
	-- already have produced the very item we are about to pin. Clear those
	-- sockets first and refill them AFTER the pin lands, so the reroll sees the
	-- pinned type as taken and cannot simply reproduce it.
	--
	-- This matters far more than it used to. Sockets no longer churn every 20
	-- seconds, so a duplicate would sit there for a full refresh cycle - and the
	-- tutorial pins the Ancient Vase, which means the very first thing a new
	-- player sees would be two of them.
	local toRefill: { Socket } = {}
	for _, other in sockets[zoneIndex] or {} do
		local occupant = other.loot
		if other.index ~= socketIndex and occupant and occupant.itemId == itemId and occupant.state == "Spawned" then
			despawn(occupant)
			byId[occupant.id] = nil
			other.loot = nil
			table.insert(toRefill, other)
		end
	end

	local loot = makeInstance(def, zoneIndex, socketIndex, sizeId, mutationId)
	byId[loot.id] = loot
	materialise(socket, loot)

	for _, other in toRefill do
		LootService.fillSocket(other)
	end

	return loot
end

function LootService.getSocket(zoneIndex: number, socketIndex: number): Socket?
	local zone = sockets[zoneIndex]
	return if zone then zone[socketIndex] else nil
end

--- Detaches loot from its socket, leaving the socket EMPTY until the next global
--- refresh. There is deliberately no delay argument: a per-socket refill timer is
--- the thing this economy exists to remove.
function LootService.detach(loot: LootInstance)
	local socket = LootService.getSocket(loot.zoneIndex, loot.socketIndex)
	if socket and socket.loot == loot then
		socket.loot = nil
	end
end

--- Sends an instance back to its origin socket. Used by guardian reclaims,
--- expired PvP drops, disconnects and any failed transition.
---
--- This returns the SAME item - it is a recovery path, not a reroll. A failed
--- steal must not cost the player five minutes, and must not hand the world a
--- free extra roll either.
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

--- Removes an instance from world tracking once it becomes a base trophy. The
--- socket it came from stays empty until the global refresh.
function LootService.consume(loot: LootInstance)
	setState(loot, "Placed")
	despawn(loot)
	byId[loot.id] = nil
	LootService.detach(loot)
end

-- ==========================================================
-- REFRESH
-- ==========================================================

export type RefreshReport = {
	rerolled: number,
	filled: number,
	--- Sockets whose occupant was mid-transition (Reserved or Dropped) and so was
	--- left alone. Carried loot does NOT appear here and does not need to: a steal
	--- detaches it from its socket, so the refresh never sees it at all.
	preservedInSocket: number,
	jackpot: LootInstance?,
}

--- Which zones a jackpot may be injected into.
---
--- Overridden by init.server so LootService stays free of player/profile
--- dependencies. The default is every zone, which is correct for an empty server
--- and for tests; the real implementation narrows it to what somebody online can
--- actually reach, because a jackpot nobody can walk to is not an event.
function LootService.eligibleJackpotZones(): { number }
	local all = {}
	for index = 1, ZoneConfig.COUNT do
		table.insert(all, index)
	end
	return all
end

--- Fired when a jackpot is injected. Overridden by init.server to broadcast.
function LootService.onJackpot(_loot: LootInstance) end

--- Puts one jackpot item into one socket of one eligible zone.
--- Returns the instance, or nil if nowhere would take it.
function LootService.injectJackpot(): LootInstance?
	local zones = LootService.eligibleJackpotZones()
	if #zones == 0 then
		return nil
	end

	-- Try zones in a random order so a blocked zone does not bias the choice.
	for _ = 1, #zones do
		local pick = math.random(#zones)
		local zoneIndex = zones[pick]
		table.remove(zones, pick)

		local def = LootConfig.jackpotFor(zoneIndex)
		local zoneSockets = sockets[zoneIndex]
		if def and zoneSockets then
			-- Prefer an empty socket, then any socket holding an ordinary item
			-- that is not mid-steal. Never disturb a reserved or carried one.
			local empty, replaceable = {}, {}
			for _, socket in zoneSockets do
				local current = socket.loot
				if not current then
					table.insert(empty, socket)
				elseif current.state == "Spawned" and not current.jackpot then
					table.insert(replaceable, socket)
				end
			end

			local target = if #empty > 0
				then empty[math.random(#empty)]
				else (if #replaceable > 0 then replaceable[math.random(#replaceable)] else nil)

			if target then
				-- Size and Mutation are rolled normally on top: a jackpot can
				-- still arrive Giant and Corrupted, which is the best moment the
				-- game has to offer.
				local loot = LootService.forceSocket(zoneIndex, target.index, def.id)
				if loot then
					return loot
				end
			end
		end
	end

	return nil
end

--- ONE server-level jackpot roll. Never called per socket.
function LootService.rollJackpot(): LootInstance?
	if math.random() >= GameConfig.JACKPOT_REFRESH_CHANCE then
		return nil
	end
	return LootService.injectJackpot()
end

--- The global world reroll.
---
--- Carried, reserved, dropped and returning loot is untouched: a player
--- mid-escape must never have their prize vanish, and a placed trophy is no
--- longer world state at all. Only items sitting quietly in a socket are
--- rerolled, and every empty socket is filled.
function LootService.refreshAll(): RefreshReport
	local report: RefreshReport = { rerolled = 0, filled = 0, preservedInSocket = 0 }

	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] or {} do
			local loot = socket.loot
			if loot then
				if loot.state == "Spawned" then
					despawn(loot)
					byId[loot.id] = nil
					socket.loot = nil
					report.rerolled += 1
				else
					report.preservedInSocket += 1
				end
			end
		end
	end

	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] or {} do
			if not socket.loot and LootService.fillSocket(socket) then
				report.filled += 1
			end
		end
	end

	-- Exactly one world-level jackpot roll, AFTER the world is repopulated.
	local jackpot = LootService.rollJackpot()
	if jackpot then
		report.jackpot = jackpot
		LootService.onJackpot(jackpot)
	end

	return report
end

--- Snapshot for tests and debugging.
function LootService.snapshot(): { [string]: any }
	local out = {}
	for zoneIndex = 1, ZoneConfig.COUNT do
		local rows = {}
		for _, socket in sockets[zoneIndex] or {} do
			local loot = socket.loot
			table.insert(rows, if loot
				then `{loot.name} [{loot.rarity}] {loot.size}/{loot.mutation} {NumberFormat.income(loot.finalIncome)} ({loot.state}){if loot.jackpot then " JACKPOT" else ""}`
				else "<empty>")
		end
		out[ZoneConfig.Zones[zoneIndex].id] = rows
	end
	return out
end

--- Counts, for tests: how many sockets are occupied and how many stand empty.
function LootService.occupancy(): { occupied: number, empty: number, jackpots: number }
	local occupied, empty, jackpots = 0, 0, 0
	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] or {} do
			if socket.loot then
				occupied += 1
				if socket.loot.jackpot then
					jackpots += 1
				end
			else
				empty += 1
			end
		end
	end
	return { occupied = occupied, empty = empty, jackpots = jackpots }
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

	-- The ONLY thing that refills a socket. No per-socket timer exists.
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
