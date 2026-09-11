--!strict
--[[
	LootService
	Four sealed mystery containers per zone, weighted rolls, and the socket
	lifecycle.

	WHAT A ZONE SHOWS. Never the item: a closed container whose SIZE is the
	hidden size variant and whose VFX is the hidden mutation. The identity,
	rarity and income are rolled here, once, and stay on the server until the
	player has escaped with it and hatched it (HatchService). Nothing about the
	reward is written onto the world model or replicated to a client.

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

	THE ONE EXCEPTION IS ZONE 1 (GameConfig.ZONE_RESPAWN). A socket emptied by
	a theft there rolls a fresh container after a random 60-90 seconds, so a
	new player sharing four sockets with six others is not left with nothing
	to do. Zone 1's best item is worth less than a common a few zones on, so
	the slot-machine argument above does not reach it. Every other zone keeps
	the rule exactly as written.

	Two paths put an item back early, and BOTH return the same instance rather
	than rolling a new one:
	  * a guardian reclaim (you were caught - you should not have to wait five
	    minutes for the thing you failed to steal)
	  * an unclaimed PvP drop timing out

	== THE ROLL ==

	FOUR sockets per zone, standing around that zone's guardian. Every socket
	rolls INDEPENDENTLY from ALL EIGHT of
	its zone's items at each item's own zone weight (LootConfig.ZoneWeights):
	no exclusion, no reroll, no jackpot slot, no Night lean, duplicates
	allowed. Scale and mutation are rolled once per instance from their own
	tables and saved. What the announcer calls out never feeds back into a
	roll. See rollItem.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local MysteryConfig = require(ReplicatedStorage.Shared.Config.MysteryConfig)
local MysteryModel = require(ReplicatedStorage.Shared.Util.MysteryModel)
local MysterySpawnService = require(script.Parent.MysterySpawnService)
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
	--- The six-word size LABEL, derived from `scale` (RarityConfig.sizeLabelFor).
	size: string,
	mutation: string,
	baseIncome: number,
	--- The pre-boost rate at moneyPass 1: what the card shows before an owner
	--- exists. An owner's real rate is EconomyService's business.
	finalIncome: number,
	--- THE economy Scale: rolled once (ScaleConfig.rollScale), saved onto the
	--- trophy, never rerolled. Income is a function of this and nothing else
	--- about size.
	scale: number,
	--- The scale the MODEL is built at. Equal to `scale` for everything rolled
	--- since the rebuild; a legacy item carries its old look here instead.
	visualScale: number,
	--- Unique per SPAWN, not per socket. Travels with the container through
	--- the carry, the base and the hatch, so two clients racing the same
	--- container - or a stale request after a return - can be told apart.
	spawnToken: string,
	--- True while the reward is still sealed. Set false only by a completed
	--- hatch; the world container is always sealed.
	sealed: boolean,
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
	--- The tutorial's guaranteed item, pinned by TutorialService. World state
	--- only - never saved. It does two things: only a player still in the
	--- tutorial may steal it (CarryService), and placing it starts the fast
	--- tutorial reveal (PlacementService). Without the first, a server with a
	--- new player in it would hand anyone an endless supply of Pharaoh Masks,
	--- re-pinned every half second.
	tutorialPin: boolean?,
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
	--- Bumped every time a theft empties this socket. A pending Zone 1 respawn
	--- carries the value it was scheduled under and does nothing if it has
	--- moved on - so a timer from an earlier theft can never refill a socket
	--- early after it has been refilled and emptied again.
	respawnGeneration: number?,
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

local function weightedPick(entries: { { chance: number } }, rng: Random?): number
	local total = 0
	for _, entry in entries do
		total += entry.chance
	end
	local roll = (if rng then rng:NextNumber() else math.random()) * total
	local cursor = 0
	for index, entry in entries do
		cursor += entry.chance
		if roll <= cursor then
			return index
		end
	end
	return #entries
end

--- THE ITEM ROLL. One socket, one independent draw from ALL EIGHT of the
--- zone's items, each at its own zone-specific weight (LootConfig.ZoneWeights).
---
--- Nothing is excluded, nothing is rerolled, nothing is leaned: a socket next
--- to a socket already showing the Blue Crystal has exactly the same chance
--- of the Blue Crystal as any other, so duplicates happen at the rate the
--- weights say and a Secret is exactly as likely with its announcement on or
--- off. `rng` is a Random for deterministic tests; nil uses the global one.
local function rollItem(zoneIndex: number, rng: Random?): LootConfig.ItemDef?
	local pool = LootConfig.pool(zoneIndex)
	if #pool == 0 then
		return nil
	end
	local total = LootConfig.ZoneWeightTotal[zoneIndex] or 0
	if total <= 0 then
		return nil
	end
	local roll = (if rng then rng:NextNumber() else math.random()) * total
	local cursor = 0
	for _, item in pool do
		cursor += item.weight
		if roll <= cursor then
			return item
		end
	end
	return pool[#pool]
end

LootService.rollItem = rollItem

--- ONE weighted pick straight off the config table. No lean, no reroll, no
--- fallback: the mutation odds are exactly the percentages written in
--- RarityConfig, at every refresh and in every zone, day or Night.
local function rollVariant(list: { RarityConfig.Variant }, rng: Random?): RarityConfig.Variant
	return list[weightedPick(list, rng)]
end

--- The mutation roll, exposed for the regression tests.
function LootService.rollMutationId(rng: Random?): string
	return rollVariant(RarityConfig.Mutations, rng).id
end

--- The Scale roll, exposed for the parity tool. ScaleConfig owns the bands,
--- and the roll is zone-biased, so the zone is not optional.
function LootService.rollScale(zoneIndex: number, rng: Random?): number
	return ScaleConfig.rollScale(zoneIndex, rng)
end

-- ==========================================================
-- WORLD MODEL
-- ==========================================================

--- THE SEALED CONTAINER. What a zone actually shows is never the item: it is
--- that zone's mystery container, grown to the hidden size variant and dressed
--- with the hidden mutation, and nothing else. The item's own model is built
--- only after a hatch (BaseService.buildTrophy).
---
--- ONLY the attributes a player is allowed to read are set on it. `ItemId`,
--- `Rarity`, the income and the mutation NAME stay on the server: a client
--- that walks the workspace finds a size and a mutation dressing, which is
--- exactly what it can already see with its eyes.
local function buildModel(loot: LootInstance): Model?
	local model = MysteryModel.build({
		zoneIndex = loot.zoneIndex,
		scale = loot.scale,
		mutation = loot.mutation,
		maxFootprint = MysteryConfig.WORLD_MAX_FOOTPRINT,
		hitbox = true,
	})
	if not model then
		return nil
	end

	model:SetAttribute("LootId", loot.id)
	-- Presentation only: how big it is, so the client's idle turn and bob can
	-- slow down for an enormous one. NOT the size WORD, which would name the
	-- variant, and nothing about the item.
	model:SetAttribute("VisualScale", loot.visualScale)
	model:SetAttribute("Sealed", true)
	return model
end

-- RETIRED: buildLabel. A sealed container carries NO overhead information -
-- no name, no rarity, no income, no mutation word and no size word. The
-- steal is offered through the bottom-centre interaction UI, and the item's
-- own card appears only after the hatch reveal, from BaseService.

-- The mutation and size dressing now lives in MysteryModel.dress, because a
-- sealed container wears exactly what the revealed item will wear (the same
-- MutationVfx and SizeAura assets) and the two must not drift apart.

-- ==========================================================
-- SOCKET LIFECYCLE
-- ==========================================================

local function despawn(loot: LootInstance)
	if loot.model then
		loot.model:Destroy()
		loot.model = nil
	end
end

--- Places a rolled instance into its socket and makes it stealable. Returns
--- false when the zone has no container model - the socket is then left EMPTY
--- rather than showing some other zone's container.
local function materialise(socket: Socket, loot: LootInstance): boolean
	local model = buildModel(loot)
	if not model then
		return false
	end

	model.Parent = socket.part

	-- Sit the model ON the pedestal by measuring where its lowest point actually
	-- ends up, rather than guessing from the PrimaryPart's height. An imported
	-- model's pivot is wherever the artist left it, and its PrimaryPart is often
	-- a small piece, so the old guess buried statues and floated paintings.
	model:PivotTo(socket.part.CFrame)
	-- The VISIBLE lowest point: an invisible helper hanging below the art
	-- would otherwise float a Colossal a helper's height above its socket.
	local lowestCorner = select(1, LootModel.visibleExtents(model))
	local lowest = if lowestCorner then lowestCorner.Y else math.huge

	local surface = socket.part.Position.Y + socket.part.Size.Y / 2
	if lowest < math.huge then
		model:PivotTo(model:GetPivot() + Vector3.new(0, surface + 0.2 - lowest, 0))
	end

	-- Recursive: an imported model keeps its parts inside nested Models, so the
	-- anchor is often not a direct child.
	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		warn(`[LootService] zone {loot.zoneIndex} container has no part to host its prompt`)
		model:Destroy()
		return false
	end

	-- WHERE THE PROMPT LIVES. A prompt is reachable within its activation
	-- distance of the part it sits on. For ordinary loot that part is the
	-- PrimaryPart and the range is the normal one. A Titan or Colossal is a
	-- different problem: its PrimaryPart can be forty studs in the air and its
	-- edge fifty studs from its centre, so the prompt moves to a ground-level
	-- anchor at the socket and the range grows with the footprint. The player
	-- steals a giant from its feet, which is where they are standing anyway.
	local minCorner, maxCorner = LootModel.visibleExtents(model)
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
	-- NEVER the item name: a sealed container says only "Steal".
	prompt.ObjectText = "Mystery"
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
	return true
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

--- Builds a concrete instance from a definition. `scale` / `mutationId` are
--- rolled when omitted; the tutorial and the debug bridge pin them.
local function makeInstance(
	def: LootConfig.ItemDef,
	zoneIndex: number,
	socketIndex: number,
	scale: number?,
	mutationId: string?
): LootInstance
	-- The Scale roll is ZONE-BIASED: early zones lean small, the last zones
	-- lean large (ScaleConfig.ZoneBands). One roll, one variant, always.
	local rolledScale = if scale then ScaleConfig.clampScale(scale) else ScaleConfig.rollScale(zoneIndex)
	local mutation = mutationId or rollVariant(RarityConfig.Mutations).id

	return {
		id = HttpService:GenerateGUID(false),
		itemId = def.id,
		name = def.name,
		zoneIndex = zoneIndex,
		socketIndex = socketIndex,
		rarity = def.rarity,
		size = RarityConfig.sizeLabelFor(rolledScale),
		mutation = mutation,
		baseIncome = def.income,
		finalIncome = RarityConfig.finalIncome(def.income, rolledScale, mutation),
		scale = rolledScale,
		-- A fresh roll looks exactly its size: the model is built at Scale.
		visualScale = rolledScale,
		spawnToken = HttpService:GenerateGUID(false),
		sealed = true,
		state = "Spawned",
		interactRange = GameConfig.STEAL_INTERACTION_RANGE,
	}
end

--- Rolls and spawns a fresh instance for an empty socket.
function LootService.fillSocket(socket: Socket): LootInstance?
	if socket.loot then
		return socket.loot
	end

	-- The post-game zone spawns only while the extension is switched on. Its
	-- sockets stand empty otherwise; nothing else about the zone changes.
	if GameConfig.isPostgameZone(socket.zoneIndex) and not GameConfig.postgameSpawnsEnabled() then
		return nil
	end

	-- A zone whose container model is missing spawns NOTHING. Reported by
	-- name at start-up; never quietly given another zone container.
	if MysterySpawnService.isZoneBlocked(socket.zoneIndex) then
		return nil
	end

	local def = rollItem(socket.zoneIndex)
	if not def then
		return nil
	end

	local loot = makeInstance(def, socket.zoneIndex, socket.index)
	if not materialise(socket, loot) then
		-- No container model for this zone. The socket stays empty and the
		-- roll is discarded rather than shown as another zone's container.
		return nil
	end
	byId[loot.id] = loot
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
--- Ancient Vase and by the debug bridge. Refuses if the socket is mid-steal so
--- a player escaping with something can never have it swapped out from under
--- them. Returns the instance now sitting in the socket, or nil if it could not
--- be forced.
---
--- `scale` / `mutationId` are optional: omit them to take the normal rolls,
--- pass them to pin an exact instance (what the tutorial wants). Duplicates
--- within a zone are ordinary now, so pinning touches no other socket.
function LootService.forceSocket(
	zoneIndex: number,
	socketIndex: number,
	itemId: string,
	scale: number?,
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
			and (scale == nil or math.abs(current.scale - scale) < 1e-6)
			and (mutationId == nil or current.mutation == mutationId)
		then
			return current -- already correct
		end
		despawn(current)
		byId[current.id] = nil
		socket.loot = nil
	end

	local loot = makeInstance(def, zoneIndex, socketIndex, scale, mutationId)
	if not materialise(socket, loot) then
		return nil
	end
	byId[loot.id] = loot
	return loot
end

function LootService.getSocket(zoneIndex: number, socketIndex: number): Socket?
	local zone = sockets[zoneIndex]
	return if zone then zone[socketIndex] else nil
end

--- Schedules the Zone 1 respawn for a socket a theft just emptied. A no-op in
--- every zone without a GameConfig.ZONE_RESPAWN entry, which is every zone
--- but the first.
---
--- The timer re-checks everything when it fires rather than trusting what was
--- true when it was set, because four things can happen in between:
---   * the thief is caught and returnToOrigin puts the SAME item back
---   * the tutorial re-pins its guaranteed item into this socket
---   * the Night refresh fills every empty socket in the world
---   * the socket is refilled and stolen from again (the generation moves on)
--- In the first three the socket is occupied and the timer stands down; in
--- the fourth the newer theft's own timer is the one that counts. While the
--- world is closed for the Night nothing spawns: the refresh at the end of it
--- fills the socket anyway.
local function scheduleRespawn(socket: Socket)
	local window = GameConfig.ZONE_RESPAWN[socket.zoneIndex]
	if not window then
		return
	end
	local generation = (socket.respawnGeneration or 0) + 1
	socket.respawnGeneration = generation
	local delay = window.min + math.random() * (window.max - window.min)
	task.delay(delay, function()
		if socket.respawnGeneration ~= generation or socket.loot or closed then
			return
		end
		LootService.fillSocket(socket)
	end)
end

--- Detaches loot from its socket, leaving the socket EMPTY until the next global
--- refresh - or, in Zone 1 only, until its own respawn (see scheduleRespawn).
function LootService.detach(loot: LootInstance)
	local socket = LootService.getSocket(loot.zoneIndex, loot.socketIndex)
	if socket and socket.loot == loot then
		socket.loot = nil
		-- Only when THIS call actually emptied the socket. `consume` also passes
		-- through here for an item placed long after its steal, by which time the
		-- socket is already empty or holds something new - neither may start a
		-- second timer.
		scheduleRespawn(socket)
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
			-- THE SAME container, with the SAME hidden reward and the SAME
			-- spawn token. Being caught never rerolls anything.
			if not materialise(socket, loot) then
				byId[loot.id] = nil
			end
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
}

-- RETIRED: eligibleJackpotZones / onJackpot / injectJackpot / rollJackpot. Every
-- item is an ordinary socket roll at its zone weight; nothing is injected.

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
function LootService.refreshAll(): RefreshReport
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
				then `{loot.name} [{loot.rarity}] {loot.size} s={loot.scale}/{loot.mutation} {NumberFormat.income(loot.finalIncome)} ({loot.state})`
				else "<empty>")
		end
		out[ZoneConfig.Zones[zoneIndex].id] = rows
	end
	return out
end

--- Counts, for tests: how many sockets are occupied and how many stand empty.
function LootService.occupancy(): { occupied: number, empty: number }
	local occupied, empty = 0, 0
	for zoneIndex = 1, ZoneConfig.COUNT do
		for _, socket in sockets[zoneIndex] or {} do
			if socket.loot then
				occupied += 1
			else
				empty += 1
			end
		end
	end
	return { occupied = occupied, empty = empty }
end

-- ==========================================================
-- START
-- ==========================================================

-- RETIRED: synthesiseSocket. MysterySpawnService lays out all four sockets
-- around the guardian at start-up and clones any a baked map lacks, so there
-- is exactly one place that can create a socket.

function LootService.start()
	local map = workspace:WaitForChild("Map", 20)
	assert(map, "LootService: Workspace.Map missing - run MapBuilder.build() first")
	local zonesFolder = map:WaitForChild("Zones", 10)

	-- Validate the twelve container models FIRST, so a zone with a missing
	-- model is known before anything tries to fill its sockets, and lay the
	-- four sockets of every zone out around its guardian (this also destroys
	-- the retired fifth spawn wherever a baked map still carries one).
	MysterySpawnService.validateModels()
	MysterySpawnService.layoutAll(map)

	for zoneIndex, zoneDef in ZoneConfig.Zones do
		local zone = zonesFolder:FindFirstChild(zoneDef.id)
		assert(zone, `LootService: missing map folder {zoneDef.id}`)

		sockets[zoneIndex] = {}
		local socketFolder = zone:FindFirstChild("SpawnSockets")
		assert(socketFolder, `LootService: {zoneDef.id} has no SpawnSockets`)

		for socketIndex = 1, ZoneConfig.SOCKETS_PER_ZONE do
			local name = string.format("Socket%02d", socketIndex)
			local part = socketFolder:FindFirstChild(name)
			-- MysterySpawnService has already laid these out and cloned any the
			-- baked map lacked, so a nil here is a genuine fault, not a gap.
			assert(part and part:IsA("BasePart"), `LootService: {zoneDef.id} missing {name}`)

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

	-- Every asset must have an audited Normal-size row, measured from the art
	-- that is actually in GameAssets.Loot. A missing or stale row is a
	-- warning here, by name, before a single socket is filled.
	local sizing = LootModel.checkNormalization()
	print(`[LootService] size normalisation: {sizing.ok} audited, {sizing.missing} missing, {sizing.stale} stale, {sizing.noArt} without art`)

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
