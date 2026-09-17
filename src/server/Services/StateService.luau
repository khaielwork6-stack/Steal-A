--!strict
--[[
	StateService
	The single server -> client replication path.

	Clients render replicated state and never compute rewards or ownership
	(GDD section 16). Pushes are coalesced onto a short timer so a burst of
	income ticks cannot spam the network.

	Three remotes, one snapshot: StatePush carries the small, fast-changing
	fields; InventoryPush and IndexSummaryPush carry `inventory` and `index`
	only when they changed. The client's StateStore merges them back. See
	"THE SPLIT PUSH" below.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local BaseService = require(script.Parent.BaseService)

local PUSH_INTERVAL = 0.25

local StateService = {}

local dirty: { [Player]: boolean } = {}

--- TutorialService installs itself here rather than being required, so the two
--- services do not form a cycle (TutorialService needs pushNow).
local tutorialProvider: ((Player) -> any)? = nil

function StateService.setTutorialProvider(fn: (Player) -> any)
	tutorialProvider = fn
end

--- IndexService does the same, and for the same reason: it needs notify and
--- pushNow, so it cannot be required from here.
local indexProvider: ((Player) -> any)? = nil

function StateService.setIndexProvider(fn: (Player) -> any)
	indexProvider = fn
end

--- And CarryService, so the DROP button can appear the moment a steal succeeds
--- without inventing a second replication channel for one boolean.
local carryProvider: ((Player) -> any)? = nil

function StateService.setCarryProvider(fn: (Player) -> any)
	carryProvider = fn
end

--- And monetization: what the player owns, and what the shop should offer next.
--- Riding the existing push rather than adding a channel means the treadmill
--- card and the trail shop can never disagree with the HUD about ownership.
local monetizationProvider: ((Player) -> any)? = nil

function StateService.setMonetizationProvider(fn: (Player) -> any)
	monetizationProvider = fn
end

--- And the group gift: claimed or not, and what it pays. Riding the push so a
--- reconnect renders CLAIMED without a second request.
local groupGiftProvider: ((Player) -> any)? = nil

function StateService.setGroupGiftProvider(fn: (Player) -> any)
	groupGiftProvider = fn
end

--- Named extras riding the same push (base guardians, weapons). One
--- registration per field; the field lands on the snapshot under `name`.
--- Same reason as the providers above: whoever renders a thing must read it
--- from the one snapshot everything else reads, so nothing can disagree.
local extraProviders: { [string]: (Player) -> any } = {}

function StateService.addProvider(name: string, fn: (Player) -> any)
	extraProviders[name] = fn
end

export type ClientState = {
	cash: number,
	income: number,
	speedPower: number,
	walkSpeed: number,
	baseActivated: boolean,
	treadmillLevel: number,
	treadmillNextCost: number?,
	capacityTier: number,
	slotsUnlocked: number,
	slotsUsed: number,
	slotsNextCost: number?,
	trapCount: number,
	--- Unix second the next trap is available (0 = ready). Absolute, so the
	--- client renders the countdown itself and no counter has to be ticked.
	trapReadyAt: number,
	tutorialStage: number,
	highestZone: number,
	indexCount: number,
	index: any?, -- IndexService.Summary: per-zone counts and claim flags only
	plotName: string?,
	tutorial: any?,
	--- { name, rarity } while carrying stolen loot, nil otherwise. Drives the
	--- DROP button. A summary, never the loot instance.
	carrying: any?,
	--- The stored items. Rides InventoryPush (only on change), not StatePush.
	inventory: any?,
}

--- Runs one injected provider under pcall. The named providers (index,
--- tutorial, carry, monetization, group gift) used to be called bare, so one
--- throwing provider threw out of build() and the player got NO push at all -
--- a single bad field froze the whole HUD. A failed field is now just nil,
--- exactly like the extra providers below.
local function safeProvide(name: string, provider: ((Player) -> any)?, player: Player): any
	if not provider then
		return nil
	end
	local ok, value = pcall(provider, player)
	if ok then
		return value
	end
	warn(`[StateService] provider "{name}" failed: {value}`)
	return nil
end

local function build(player: Player): ClientState?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end

	local discovered = 0
	for _ in profile.Index do
		discovered += 1
	end

	local nextTreadmill = TreadmillConfig.nextTier(profile.TreadmillLevel)
	local nextCapacity = BaseConfig.nextUpgrade(profile.BaseCapacityTier)
	local plot = BaseService.getPlot(player)

	local extras: { [string]: any } = {}
	for name, provider in extraProviders do
		local ok, value = pcall(provider, player)
		if ok then
			extras[name] = value
		else
			warn(`[StateService] provider "{name}" failed: {value}`)
		end
	end

	local state = {
		cash = profile.Cash,
		-- [social pass] What is actually paid: the friend / Premium boost
		-- included (EconomyService "SOCIAL BOOST"). Formulas keep getIncome.
		income = EconomyService.getPaidIncome(player),
		speedPower = profile.SpeedPower,
		walkSpeed = GameConfig.walkSpeedFromPower(profile.SpeedPower),
		baseActivated = profile.BaseActivated,
		treadmillLevel = profile.TreadmillLevel,
		treadmillNextCost = if nextTreadmill then nextTreadmill.cost else nil,
		capacityTier = profile.BaseCapacityTier,
		slotsUnlocked = BaseService.unlockedSlots(player), -- the level clamped to the plot's physical pads
		slotsUsed = #profile.DisplayItems,
		slotsNextCost = if nextCapacity then nextCapacity.cost else nil,
		trapCount = profile.TrapCount,
		trapReadyAt = profile.TrapReadyAt or 0,
		tutorialStage = profile.TutorialStage,
		highestZone = profile.HighestZoneReached,
		indexCount = discovered,
		index = safeProvide("index", indexProvider, player),
		plotName = if plot then plot.Name else nil,
		tutorial = safeProvide("tutorial", tutorialProvider, player),
		carrying = safeProvide("carrying", carryProvider, player),
		monetization = safeProvide("monetization", monetizationProvider, player),
		groupGift = safeProvide("groupGift", groupGiftProvider, player),
		-- The saved Settings, so the panel and the mixer restore on join without
		-- a request. Written only through SettingsService.
		settings = profile.Settings,
		inventory = profile.Inventory,
		storageUsed = #profile.Inventory,
		storageCapacity = StorageConfig.capacityForTier(profile.StorageTier),
		storageNextCost = (function()
			local next = StorageConfig.nextUpgrade(profile.StorageTier)
			return if next then next.cost else nil
		end)(),
	}
	for name, value in extras do
		(state :: any)[name] = value
	end
	return state
end

-- ==========================================================
-- THE SPLIT PUSH
-- ==========================================================
--
-- Measured live: the full snapshot was ~6 KB and went out every second while
-- income ticked, and `inventory` (~3.7 KB) plus `index` (~1.2 KB) were 80% of
-- it - two fields that change a few times a MINUTE at most. They now travel on
-- their own remotes (InventoryPush, IndexSummaryPush) and only when their
-- content differs from what this player was last sent. StatePush carries
-- everything else, unchanged.
--
-- build() still returns the FULL state (inventory and index included), so the
-- onPushed listeners, the debug commands and the tests that read
-- `state.inventory` keep working. The split happens only on the wire, and the
-- client's StateStore merges the three back into one table, so no controller
-- sees a difference.
--
-- The signature is the JSON encoding. Cheap at this size (a few KB, at most a
-- few times a second per player), and it catches in-place edits to the
-- profile tables that a version counter bumped by hand would miss.

local HttpService = game:GetService("HttpService")

--- What each player was last sent on the two side channels.
local sentSignature: { [Player]: { inventory: string?, index: string? } } = {}
--- Players whose next push must resend the side channels regardless.
local fullDirty: { [Player]: boolean } = {}

local unencodableCount = 0

local function signatureOf(value: any): string
	if value == nil then
		return "nil"
	end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
	if ok then
		return encoded
	end
	-- Not encodable (a NaN, a mixed table): never match, so it is always
	-- sent. Wrong-but-safe; the cost is the old behaviour for that field.
	unencodableCount += 1
	return `?{unencodableCount}`
end

--- Marks a player's state as needing replication on the next tick. `full`
--- also resends inventory and the Index summary even if they did not change
--- (join, respawn, an explicit client resync).
function StateService.markDirty(player: Player, full: boolean?)
	dirty[player] = true
	if full == true then
		fullDirty[player] = true
	end
end

--- Listeners that mirror every snapshot somewhere else - the player list, the
--- world leaderboards. They get the SAME table the client gets, after it has
--- been sent, so nothing they do can delay or alter the push.
local pushListeners: { (Player, any) -> () } = {}

function StateService.onPushed(fn: (Player, any) -> ())
	table.insert(pushListeners, fn)
end

--- The full snapshot as build() makes it, inventory and index included. For
--- the debug commands that measure the wire; nothing in gameplay needs it.
function StateService.snapshot(player: Player): ClientState?
	return build(player)
end

--- Returns false when there was nothing to send yet (profile still loading).
local function pushBody(player: Player, full: boolean): boolean
	local state = build(player)
	if not state then
		return false
	end

	local sent = sentSignature[player]
	if not sent then
		sent = {}
		sentSignature[player] = sent
	end

	-- The side channels go FIRST: remote events reach the client in the order
	-- they were fired, so by the time the StatePush below lands the client's
	-- store already holds the matching inventory and summary, and every
	-- subscriber is notified once with a coherent table.
	local inventorySignature = signatureOf(state.inventory)
	if full or sent.inventory ~= inventorySignature then
		Remotes.get("InventoryPush"):FireClient(player, state.inventory)
		sent.inventory = inventorySignature
	end
	local indexSignature = signatureOf(state.index)
	if full or sent.index ~= indexSignature then
		Remotes.get("IndexSummaryPush"):FireClient(player, state.index)
		sent.index = indexSignature
	end

	-- A shallow copy minus the two big fields. The listeners below still get
	-- the full `state`, as before.
	local wire = table.clone(state :: any)
	wire.inventory = nil
	wire.index = nil
	Remotes.get("StatePush"):FireClient(player, wire)

	for _, listener in pushListeners do
		task.spawn(listener, player, state)
	end
	return true
end

function StateService.pushNow(player: Player, full: boolean?)
	local wantFull = full == true or fullDirty[player] == true
	-- Cleared BEFORE the body runs: a push that throws must not be retried
	-- every tick forever (the next real change marks it dirty again).
	dirty[player] = nil
	fullDirty[player] = nil
	local ok, result = pcall(pushBody, player, wantFull)
	if not ok then
		warn(`[StateService] push for {player.Name} failed: {result}`)
	elseif result == false and wantFull then
		-- Nothing was built (profile not loaded): keep the "resend everything"
		-- request for the first push that can actually go out.
		fullDirty[player] = true
	end
end

--- One-off toast / feedback message.
function StateService.notify(player: Player, kind: string, message: string, detail: any?)
	Remotes.get("Notify"):FireClient(player, kind, message, detail)
end

--- A personal sound cue, named from AudioConfig. Positional world sounds do NOT
--- come through here - the server parents those to the part they belong to and
--- lets them replicate, so bystanders hear them from the right direction.
function StateService.sound(player: Player, cue: string)
	Remotes.get("SoundCue"):FireClient(player, cue)
end

--- The same toast to everybody. Used for genuinely server-wide events - the loot
--- refresh countdown and a jackpot appearing - and deliberately not for anything
--- personal, so a broadcast always means "look up, something happened to the
--- world".
function StateService.announce(kind: string, message: string, detail: any?, cue: string?)
	local notifyRemote = Remotes.get("Notify")
	local soundRemote = if cue then Remotes.get("SoundCue") else nil
	for _, player in Players:GetPlayers() do
		notifyRemote:FireClient(player, kind, message, detail)
		if soundRemote and cue then
			soundRemote:FireClient(player, cue)
		end
	end
end

function StateService.start()
	-- Wrapped, not passed directly: markDirty now takes a second argument
	-- (`full`), and a listener that ever grew an extra argument must not turn
	-- every income tick into a full resend.
	EconomyService.onChanged(function(player)
		StateService.markDirty(player)
	end)

	-- The client's StateStore asks once when it starts (and again if nothing
	-- has arrived a few seconds later). A request-response cannot lose the
	-- join race the way a timed push can. Carries nothing; rate limited.
	local syncLimiter = RateLimiter.new(1, 3)
	Remotes.get("StateSyncRequest").OnServerEvent:Connect(function(player)
		if not syncLimiter:consume(player) then
			return
		end
		StateService.markDirty(player, true)
	end)

	-- A respawn resends everything. The client store survives a respawn (it
	-- lives in StarterPlayerScripts), so this is belt and braces - but it is
	-- what the old full-every-time push implicitly guaranteed.
	local function watchCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			StateService.markDirty(player, true)
		end)
	end
	for _, player in Players:GetPlayers() do
		watchCharacter(player)
	end
	Players.PlayerAdded:Connect(watchCharacter)

	Players.PlayerRemoving:Connect(function(player)
		dirty[player] = nil
		fullDirty[player] = nil
		sentSignature[player] = nil
		syncLimiter:release(player)
	end)

	task.spawn(function()
		while true do
			task.wait(PUSH_INTERVAL)
			-- pushNow removes the entry while we iterate; collect first so the
			-- traversal is well defined. pushNow is itself pcall-guarded, so a
			-- throw for one player cannot kill this loop for everyone.
			local batch = {}
			for player in dirty do
				table.insert(batch, player)
			end
			for _, player in batch do
				if player.Parent then
					StateService.pushNow(player)
				else
					dirty[player] = nil
					fullDirty[player] = nil
				end
			end
		end
	end)
end

return StateService
