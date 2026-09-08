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
	  Dropped   loose on the ground (PvP hit, DROP button, death, disconnect);
	            grabbable by players until the zone's guardian picks it up
	  Escorted  welded to the zone's guardian, on its way back to its socket
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
local SizeAura = require(ReplicatedStorage.Shared.Util.SizeAura)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

local LootService = {}

--- Above this height an item is too tall to hang its prompt over: the anchor
--- stops climbing and steps out of the silhouette instead.
local TALL_ITEM_PROMPT_HEIGHT = 9

export type LootState = "Spawned" | "Reserved" | "Carried" | "Dropped" | "Escorted" | "Returning" | "Placed"

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
	--- The exact visual scale rolled for this instance inside its size tier
	--- (RarityConfig.rollVisualScale). Rolled once, saved onto the trophy,
	--- never rerolled on render.
	visualScale: number,
	state: LootState,
	carrier: Player?,
	model: Model?,
	--- Where the steal prompt lives. The PrimaryPart for ordinary loot; a
	--- ground-level anchor for anything tall enough that its centre would be
	--- out of reach.
	promptPart: BasePart?,
	--- How far away a steal may be started. Grows with the footprint so a
	--- player at the edge of a Colossal can still reach it.
	interactRange: number,
	--- Presentation-only scale applied by the carry (see CarryService.attach),
	--- so detach can undo exactly what was done.
	carryScale: number?,
	droppedAt: number?,
	deliveredNotice: boolean?, -- so the "you're safe" toast fires only once
	escapeNotice: boolean?, -- so the "you escaped" toast fires only once
	--- A base steal (HeistService), not world loot: it lives in no socket and
	--- is not tracked here. CarryService carries it with the same weld and
	--- the same movement penalty, but every way it can be LOST (drop, death,
	--- leaving, a guardian) calls `onLost` instead of sending it to a socket.
	heist: boolean?,
	onLost: ((reason: string) -> ())?,
}

--- The part a player interacts with. Ordinary loot: its PrimaryPart. A tall
--- item: the ground-level anchor materialise() gave it.
function LootService.interactionPart(loot: LootInstance): BasePart?
	if loot.promptPart and loot.promptPart.Parent then
		return loot.promptPart
	end
	local model = loot.model
	return if model then model.PrimaryPart else nil
end

--- Its steal prompt, wherever materialise() put it.
function LootService.promptOf(loot: LootInstance): ProximityPrompt?
	local part = LootService.interactionPart(loot)
	return if part then part:FindFirstChildWhichIsA("ProximityPrompt") else nil
end

-- ==========================================================
-- CLOSURE (the Night)
-- ==========================================================
--
-- While closed no steal may start. NightService flips this around the world
-- refresh; CarryService asks it before every steal or grab. Prompts are turned
-- off too, so the player is not shown an action the server will refuse.

local closed = false
local closedReason = "The zones are closed for the Night!"

function LootService.isClosed(): boolean
	return closed
end

function LootService.closedReason(): string
	return closedReason
end

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
--- Temporary weight multipliers, installed by NightService for the duration
--- of ONE refresh and removed straight after. Multiplied in before the roller
--- renormalises, so a boosted 2% tier becomes 3% with everything else shrinking
--- to make room - never 150%. Nil means the plain tables.
export type RollBoosts = {
	rarity: ((rarity: string) -> number)?,
	size: ((sizeId: string) -> number)?,
}

local rollBoosts: RollBoosts? = nil

function LootService.setRollBoosts(boosts: RollBoosts?)
	rollBoosts = boosts
end

local function rollItem(zoneIndex: number, exclude: { [string]: boolean }?): LootConfig.ItemDef?
	local taken = exclude or activeTypes(zoneIndex)

	local candidates: { LootConfig.ItemDef } = {}
	local weights: { number } = {}
	local total = 0

	local rarityBoost = if rollBoosts then rollBoosts.rarity else nil
	for _, item in LootConfig.normalPool(zoneIndex) do
		if not taken[item.id] then
			table.insert(candidates, item)
			local weight = RarityConfig.NormalWeights[item.rarity] or 0
			if rarityBoost and weight > 0 then
				weight *= rarityBoost(item.rarity)
			end
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

local function rollVariant(list: { RarityConfig.Variant }, boost: ((string) -> number)?): RarityConfig.Variant
	if not boost then
		return list[weightedPick(list)]
	end
	-- Boosted: the same weighted pick over a temporary table, so the config
	-- itself is never mutated and the lean vanishes with the boost.
	local leaned = table.create(#list)
	for index, variant in list do
		leaned[index] = { chance = variant.chance * boost(variant.id) }
	end
	return list[weightedPick(leaned)]
end

--- Every size / rarity roll, exposed so the debug bridge can simulate the
--- distribution with and without the Night lean.
function LootService.rollSizeId(boost: ((string) -> number)?): string
	return rollVariant(RarityConfig.Sizes, boost).id
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
	-- The scale is the instance's OWN rolled value, so a Colossal that rolled
	-- 17.4x is 17.4x every time it is built and nowhere else.
	local model = LootModel.build({
		itemId = loot.itemId,
		rarity = loot.rarity,
		targetHeight = GameConfig.LOOT_WORLD_HEIGHT,
		sizeScale = loot.visualScale,
		maxFootprint = LootModel.WORLD_MAX_FOOTPRINT,
		placeholderSize = Vector3.new(6, 7, 6),
	})

	model:SetAttribute("LootId", loot.id)
	model:SetAttribute("ItemId", loot.itemId)
	model:SetAttribute("Rarity", loot.rarity)
	-- For the client's idle motion: how big this one is (a Colossal turns
	-- slowly and does not bob) and what it is (mutation accents).
	model:SetAttribute("VisualScale", loot.visualScale)
	model:SetAttribute("Size", loot.size)
	model:SetAttribute("Mutation", loot.mutation)

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
	-- ...and the size aura, which is the same idea one axis over: the artist
	-- authors one effect per tier and every item wears the right one. It lives
	-- ON the model, so it follows the item into a carry, a drop and a base
	-- display without any of those paths knowing about it.
	SizeAura.apply(model, loot.size)
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

	local surface = socket.part.Position.Y + socket.part.Size.Y / 2
	if lowest < math.huge then
		model:PivotTo(model:GetPivot() + Vector3.new(0, surface + 0.2 - lowest, 0))
	end

	-- Recursive: an imported model keeps its parts inside nested Models, so the
	-- anchor is often not a direct child.
	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		warn(`[LootService] {loot.itemId} has no part to host its prompt`)
		return
	end

	-- WHERE THE PROMPT LIVES. A prompt is reachable within its activation
	-- distance of the part it sits on. For ordinary loot that part is the
	-- PrimaryPart and the range is the normal one. A Titan or Colossal is a
	-- different problem: its PrimaryPart can be forty studs in the air and its
	-- edge fifty studs from its centre, so the prompt moves to a ground-level
	-- anchor at the socket and the range grows with the footprint. The player
	-- steals a giant from its feet, which is where they are standing anyway.
	local minCorner, maxCorner = LootModel.worldExtents(model)
	local footprint = if minCorner and maxCorner then math.max(maxCorner.X - minCorner.X, maxCorner.Z - minCorner.Z) else 0
	local height = if minCorner and maxCorner then maxCorner.Y - minCorner.Y else 0
	-- WHERE THE PROMPT HANGS. Never on the art itself. A prompt parented to a
	-- part is drawn AT that part, so on anything the player can walk up to -
	-- the briefcase, the shawarma, a Titan - the camera ends up inside the
	-- geometry the prompt is buried in and the E vanishes exactly when the
	-- player is close enough to use it.
	--
	-- Instead every item gets its own invisible anchor in clear air:
	--   short item  -> straight above its top, where nothing can occlude it
	--   tall item   -> at head height, pushed OUT of the silhouette toward the
	--                  lane centre, which is the side players approach from
	-- The anchor is welded to the art so a drop carries it along, and the
	-- interaction range is widened by the height it gained so the reach from
	-- the floor is exactly what it was.
	local anchorY = surface + math.min(height + 1.5, TALL_ITEM_PROMPT_HEIGHT)
	local anchorX, anchorZ = socket.part.Position.X, socket.part.Position.Z
	if height > TALL_ITEM_PROMPT_HEIGHT then
		local towardLane = if anchorX >= 0 then -1 else 1
		anchorX += towardLane * (footprint / 2 + 2)
	end

	local promptHost = Instance.new("Part")
	promptHost.Name = "PromptAnchor"
	promptHost.Size = Vector3.new(1, 1, 1)
	promptHost.Transparency = 1
	promptHost.Anchored = true
	promptHost.CanCollide = false
	promptHost.CanQuery = false
	promptHost.CanTouch = false
	promptHost.CastShadow = false
	promptHost.CFrame = CFrame.new(anchorX, anchorY, anchorZ)
	promptHost.Parent = model
	-- Ride along with the model if it is ever moved (a drop puts the whole
	-- model on the floor where the carrier stood).
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = promptHost
	weld.Parent = promptHost

	loot.promptPart = promptHost
	loot.interactRange = math.max(GameConfig.STEAL_INTERACTION_RANGE, footprint / 2 + 10)
		+ (anchorY - surface) * 0.6

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StealPrompt"
	prompt.ActionText = "Steal"
	prompt.ObjectText = loot.name
	prompt.HoldDuration = GameConfig.STEAL_HOLD_DURATION
	prompt.MaxActivationDistance = loot.interactRange
	-- Line of sight is what hides a prompt behind the item it belongs to.
	prompt.RequiresLineOfSight = false
	-- One prompt on screen at a time, so two items side by side can never both
	-- offer a hold and double-complete.
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	-- A closed world shows no steal prompts at all (see setClosed).
	prompt.Enabled = not closed
	prompt.Parent = promptHost

	loot.model = model
	socket.loot = loot
end

--- Shuts (or reopens) every steal in the world. Idempotent.
function LootService.setClosed(value: boolean, reason: string?)
	closed = value
	if reason then
		closedReason = reason
	end
	for _, loot in byId do
		if loot.state == "Spawned" or loot.state == "Dropped" then
			local prompt = LootService.promptOf(loot)
			if prompt then
				prompt.Enabled = not value
			end
		end
	end
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
	local sizeBoost = if rollBoosts then rollBoosts.size else nil
	local size = sizeId or rollVariant(RarityConfig.Sizes, sizeBoost).id
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
		-- ONE roll inside the tier's visual range, kept for the instance's life
		-- and written onto the trophy when it is placed.
		visualScale = RarityConfig.rollVisualScale(size),
		state = "Spawned",
		interactRange = GameConfig.STEAL_INTERACTION_RANGE,
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

--- Every live instance that belongs to a zone, whatever state it is in and
--- wherever it physically is. The guardian derives its work from this each
--- time it needs to - carriers to chase, drops to fetch - so it never holds a
--- reference that can go stale.
function LootService.instancesInZone(zoneIndex: number): { LootInstance }
	local list = {}
	for _, loot in byId do
		if loot.zoneIndex == zoneIndex then
			table.insert(list, loot)
		end
	end
	return list
end

--- Retires every instance lying loose on the ground. Run by the Night refresh
--- before the sockets are refilled: a drop left over from the old world would
--- otherwise come home to a socket that already holds its replacement.
function LootService.retireLoose(): number
	local count = 0
	for id, loot in byId do
		if loot.state == "Dropped" then
			despawn(loot)
			byId[id] = nil
			count += 1
		end
	end
	return count
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
			-- Back in its socket it is a fresh steal for whoever takes it next:
			-- the one-shot escape / safe notices (and the escape sting they
			-- gate) belong to the run that just ended, not to the instance.
			loot.escapeNotice = nil
			loot.deliveredNotice = nil
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

--- Every instance currently sitting in a socket, for the post-refresh
--- spotlight: the announcer inspects what was ACTUALLY generated and never
--- invents a spawn.
function LootService.spawnedLoot(): { LootInstance }
	local list = {}
	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] or {} do
			local loot = socket.loot
			if loot and loot.state == "Spawned" then
				table.insert(list, loot)
			end
		end
	end
	return list
end

--- The global world reroll.
---
--- Carried, reserved, dropped and returning loot is untouched: a player
--- mid-escape must never have their prize vanish, and a placed trophy is no
--- longer world state at all. Only items sitting quietly in a socket are
--- rerolled, and every empty socket is filled.
---
--- `boosts`, when given, lean the rolls for THIS refresh only (the Night
--- refresh) and are removed before returning - even if a roll errors.
function LootService.refreshAll(boosts: RollBoosts?): RefreshReport
	LootService.setRollBoosts(boosts)
	local ok, result = pcall(LootService.refreshAllUnboosted)
	LootService.setRollBoosts(nil)
	if not ok then
		error(result)
	end
	return result
end

function LootService.refreshAllUnboosted(): RefreshReport
	local report: RefreshReport = { rerolled = 0, filled = 0, preservedInSocket = 0 }

	-- Drops on the ground belong to the world being replaced.
	LootService.retireLoose()

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
				then `{loot.name} [{loot.rarity}] {loot.size}x{loot.visualScale}/{loot.mutation} {NumberFormat.income(loot.finalIncome)} ({loot.state}){if loot.jackpot then " JACKPOT" else ""}`
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

	-- The Index and Storage draw the real models: publish them where a client
	-- can clone them (ReplicatedStorage.LootPreviews) before anything opens.
	local previews = LootModel.publishPreviews()
	print(`[LootService] {previews} item previews published`)

	-- Fill everything on server start.
	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] do
			LootService.fillSocket(socket)
		end
	end

	-- THE ONLY THING THAT REFILLS A SOCKET is the Night refresh, and NightService
	-- owns that cadence (NightConfig.CYCLE_SECONDS). There is no per-socket
	-- timer and no second clock in here.
	print(`[LootService] {ZoneConfig.COUNT} zones x {ZoneConfig.SOCKETS_PER_ZONE} sockets filled`)
end

return LootService
