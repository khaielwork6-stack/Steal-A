--!strict
--[[
	HatchService
	The reveal timer and the one atomic moment a sealed container becomes a
	revealed, earning item. (The module keeps its historical name; every word a
	player sees says REVEAL.)

	THE STATE MACHINE, and every failure route out of it, lives here:

	    ZoneSpawned --steal--> Carried --escape+place--> Counting
	                                                        |
	                                              timer ends v
	                                                      Ready --reveal--> Revealed
	    Counting --Instant Reveal purchase (ProcessReceipt)--> Ready --> Revealed
	    Carried --caught / dropped / disconnected--> back to its own socket,
	                                                 SAME reward, no reroll
	    Counting/Ready --disconnect--> unchanged: the timestamp is absolute
	    Revealing --disconnect--> already committed; the item is simply theirs

	WHY THE TIMER IS A TIMESTAMP
	`HatchEndsAt` is an absolute Unix second (os.time), written once when the
	container is accepted onto a pedestal. Nothing counts down: readiness is
	`os.time() >= HatchEndsAt`, asked whenever someone looks. That is what makes
	it survive going offline, changing servers, a shutdown and a rejoin, and it
	is why no client countdown is ever trusted - the client is told the same
	absolute second and renders it locally.

	WHY A REVEAL CANNOT DOUBLE-PAY
	`commit` is the only writer. It re-reads the item out of the profile by
	InstanceId, checks ownership, checks `Hatched == false`, checks the clock,
	and flips the flag BEFORE it announces anything. A second request - a spam,
	a replay, a rejoin mid-animation - finds `Hatched == true` and is refused.
	On top of that a short reveal LOCK holds the slot for the length of the
	animation, so a held key cannot start a second sequence either.

	THE SWAP. The commit does NOT rebuild the pedestal at once. It tells the
	owner's client to start the animation and rebuilds SWAP_AT seconds later,
	on the pop frame, so the container stays in the world until the exact
	moment the item replaces it. That is what removes the old gap where the
	container vanished a second before anything renderable arrived.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HatchConfig = require(ReplicatedStorage.Shared.Config.HatchConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local MysteryConfig = require(ReplicatedStorage.Shared.Config.MysteryConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)

local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local IndexService = require(script.Parent.IndexService)
local StateService = require(script.Parent.StateService)

local HatchService = {}

local hatchLimiter = RateLimiter.new(MysteryConfig.HATCH_REQUESTS_PER_SECOND)

--- InstanceIds currently mid-commit, so two requests arriving in the same
--- frame cannot both pass the `Hatched == false` check before either writes.
local committing: { [string]: boolean } = {}

--- THE REVEAL LOCK. InstanceId -> os.clock the lock lifts. Held from the
--- trigger until the animation is over, and read by the prompt refresh, the
--- store path and this service's own commit, so a slot mid-reveal accepts
--- nothing at all from anyone.
local revealingUntil: { [string]: number } = {}

--- One open Instant Reveal prompt per player. Buyer -> what they were shown.
type PendingReveal = {
	instanceId: string,
	productId: number,
	openedAt: number,
}
local pendingByBuyer: { [Player]: PendingReveal } = {}

-- ==========================================================
-- READING
-- ==========================================================

--- How long this reward waits, from its own rolled identity. Called ONCE,
--- when the container is accepted onto a pedestal.
function HatchService.durationFor(rarity: string, sizeLabel: string?, mutationId: string?): number
	return HatchConfig.hatchSeconds(rarity, sizeLabel, mutationId)
end

--- Seconds left on an item, 0 when it is ready or already revealed.
function HatchService.remaining(item: DataService.DisplayItem): number
	if item.Hatched ~= false then
		return 0
	end
	local ends = tonumber(item.HatchEndsAt) or 0
	return math.max(0, ends - os.time())
end

function HatchService.isReady(item: DataService.DisplayItem): boolean
	return item.Hatched == false and HatchService.remaining(item) <= 0
end

--- True while this container's reveal animation is running.
function HatchService.isRevealing(instanceId: string): boolean
	local until_ = revealingUntil[instanceId]
	if until_ == nil then
		return false
	end
	if os.clock() >= until_ then
		revealingUntil[instanceId] = nil
		return false
	end
	return true
end

--- What a CLIENT may know about a sealed container. Deliberately no ItemId,
--- no rarity, no income and no mutation or size WORD: only the numbers needed
--- to draw a countdown and a ready state, plus the display scale it can
--- already measure by looking at the model.
export type SealedView = {
	instanceId: string,
	slotIndex: number,
	endsAt: number,
	ready: boolean,
	scale: number,
}

--- The sealed containers on a player's base, for StatePush. A revealed item is
--- not in this list; it is an ordinary trophy.
function HatchService.summarise(player: Player): { SealedView }
	local profile = DataService.get(player)
	if not profile then
		return {}
	end
	local out: { SealedView } = {}
	for _, item in profile.DisplayItems do
		if item.Hatched == false then
			table.insert(out, {
				instanceId = item.InstanceId,
				slotIndex = item.SlotIndex,
				endsAt = tonumber(item.HatchEndsAt) or 0,
				ready = HatchService.isReady(item),
				scale = ScaleConfig.clampScale(item.Scale),
			})
		end
	end
	return out
end

-- ==========================================================
-- STARTING THE TIMER
-- ==========================================================

--- Stamps a freshly placed container with its deadline. Called by
--- PlacementService the moment the container is accepted onto a pedestal -
--- never earlier: a container being carried has no timer, so being caught
--- costs the run and not the wait.
---
--- Idempotent: an item that already carries a deadline keeps it, so a rebuild
--- or a re-equip can never extend or restart somebody's wait.
---
--- `overrideSeconds` replaces the rolled duration. Only the tutorial's pinned
--- item passes one (GameConfig.TUTORIAL_HATCH_SECONDS); it is applied once, at
--- the first stamp, and the idempotence above means nothing can re-apply it.
function HatchService.beginIncubation(player: Player, item: DataService.DisplayItem, overrideSeconds: number?)
	if item.Hatched ~= false then
		return
	end
	if tonumber(item.HatchEndsAt) then
		return
	end
	local seconds = overrideSeconds or HatchService.durationFor(item.Rarity, item.Size, item.Mutation)
	item.HatchEndsAt = os.time() + seconds
	StateService.markDirty(player)
end

-- ==========================================================
-- THE COMMIT
-- ==========================================================

local function findItem(profile: DataService.Profile, instanceId: string): DataService.DisplayItem?
	for _, item in profile.DisplayItems do
		if item.InstanceId == instanceId then
			return item
		end
	end
	return nil
end

--- Fired the moment a reveal is committed so the owner's client can start the
--- animation. Overridden by init.server to send the remote; kept injectable
--- so this service can be tested without a client.
function HatchService.onHatched(_player: Player, _item: DataService.DisplayItem) end

--- Fired when a reveal lock lifts, so the slot prompt comes back as "Store".
--- The swap rebuild runs while the lock is still held, so without this the
--- prompt would stay dark until the next unrelated rebuild. Overridden by
--- init.server (PlacementService.refreshPrompts); injected to keep the two
--- services acyclic.
function HatchService.onLockLifted(_player: Player) end

--- THE ONE PLACE a container becomes an item. Returns false plus a
--- player-facing reason; never throws, never pays twice.
function HatchService.commit(player: Player, instanceId: string): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	if committing[instanceId] or HatchService.isRevealing(instanceId) then
		return false
	end

	local item = findItem(profile, instanceId)
	if not item then
		-- Not on this player's base. Covers a stale id, another player's
		-- container, and an item stored between the click and the request.
		return false, "That is not on your base."
	end
	if item.Hatched ~= false then
		-- Already revealed: a replay, a double click, or a rejoin after the
		-- commit landed. Silent, because the player already has the reward.
		return false
	end
	if item.RobbedBy then
		return false, "Someone is stealing that right now!"
	end
	local remaining = HatchService.remaining(item)
	if remaining > 0 then
		return false, `Not ready yet - {HatchService.formatRemaining(remaining)} left.`
	end

	committing[instanceId] = true
	-- FLIP FIRST. Everything below this line is presentation; the reward is
	-- the player's from here, whatever happens to the animation.
	item.Hatched = true
	item.HatchEndsAt = nil
	committing[instanceId] = nil
	-- And LOCK the slot for the animation: no prompt, no store, no second
	-- reveal until the item has landed.
	-- Rarity-aware: the silhouette roulette runs longer for a better prize,
	-- so the lock has to cover the sequence this particular item will play.
	revealingUntil[instanceId] = os.clock() + HatchConfig.lockSeconds(item.Rarity)

	-- The income starts NOW - exactly once, because recalculate reads Hatched
	-- and this is the only flip. The prompt on the slot is disabled by the
	-- refresh that this rebuild-less push triggers through the lock.
	EconomyService.recalculate(player)
	StateService.pushNow(player)

	-- DISCOVERY HAPPENS HERE, not at placement: an item the player has not
	-- seen yet must not appear in their Index or pay a discovery reward. The
	-- reveal is the moment they actually find it. Quiet: no banner, no cue -
	-- the pop itself is the moment.
	if not profile.Index[item.ItemId] then
		profile.Index[item.ItemId] = true
		IndexService.onDiscovered(player, item.ItemId)
	end

	-- START THE ANIMATION on the owner's client. An injected callback that
	-- touches a remote; if it throws, the reward is already the player's and
	-- the swap below still happens.
	local cued, cueError = pcall(HatchService.onHatched, player, item)
	if not cued then
		warn(`[HatchService] reveal cue failed for {player.Name}: {cueError}`)
	end

	-- THE SWAP, on the pop frame. The pedestal keeps showing the container
	-- until then; the rebuild replaces it with the item and its label in one
	-- pass, and the client reveals exactly what it finds on that frame.
	task.delay(HatchConfig.swapAt(item.Rarity), function()
		if player.Parent then
			BaseService.rebuildDisplays(player)
		end
	end)
	task.delay(HatchConfig.lockSeconds(item.Rarity), function()
		revealingUntil[instanceId] = nil
		if player.Parent then
			HatchService.onLockLifted(player)
		end
	end)

	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return true
end

--- "11h 42m", "14m 08s", "8s" - the same formatting the card shows.
function HatchService.formatRemaining(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	if total >= 3600 then
		return string.format("%dh %02dm", total // 3600, (total % 3600) // 60)
	elseif total >= 60 then
		return string.format("%dm %02ds", total // 60, total % 60)
	end
	return string.format("%ds", total)
end

-- ==========================================================
-- INSTANT REVEAL
-- ==========================================================
--
-- The single slot prompt offers Instant Reveal while a container is still
-- counting. The product is chosen by how long is LEFT at the moment of the
-- prompt. ProcessReceipt (MonetizationService) is the only thing that grants:
-- it calls `fulfil`, which marks the exact container ready and commits it.

--- Opens the purchase prompt for `instanceId`, or explains why not.
function HatchService.promptInstantReveal(player: Player, instanceId: string): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local item = findItem(profile, instanceId)
	if not item or item.Hatched ~= false then
		return false, "That is not waiting to be revealed."
	end
	if item.RobbedBy or HatchService.isRevealing(instanceId) then
		return false
	end
	local remaining = HatchService.remaining(item)
	if remaining <= 0 then
		-- Ready already: nothing to sell. The caller reveals it instead.
		return HatchService.commit(player, instanceId)
	end

	local existing = pendingByBuyer[player]
	if existing and existing.instanceId == instanceId and os.clock() - existing.openedAt < 3 then
		return false -- the dialog is already open for this container
	end

	local product = MonetizationConfig.revealProductFor(remaining)
	if not product or product.productId <= 0 then
		return false, "Instant Reveal is not available right now."
	end

	local pending: PendingReveal = {
		instanceId = instanceId,
		productId = product.productId,
		openedAt = os.clock(),
	}
	pendingByBuyer[player] = pending
	-- Saved, so a receipt that lands after a rejoin still finds the container
	-- it paid for. Cleared only by a cancelled dialog or a delivered receipt.
	profile.PendingReveal = { instanceId = instanceId, productId = product.productId }

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, product.productId)
	end)
	if not ok then
		warn(`[HatchService] PromptProductPurchase failed for {player.Name}: {err}`)
		pendingByBuyer[player] = nil
		profile.PendingReveal = nil
		return false, "Could not open the purchase."
	end
	return true
end

--- MarketplaceService.PromptProductPurchaseFinished, via MonetizationService.
--- NOTHING IS GRANTED HERE. A closed dialog with `purchased == false` is the
--- one thing this event is trusted for: the player backed out. `true` is
--- ignored; ProcessReceipt is the only authority for delivery.
function HatchService.onPromptClosed(player: Player, productId: number, purchased: boolean)
	local pending = pendingByBuyer[player]
	if not pending or pending.productId ~= productId or purchased then
		return
	end
	pendingByBuyer[player] = nil
	local profile = DataService.get(player)
	if profile then
		profile.PendingReveal = nil
	end
end

--- The receipt landed. Resolves the exact container the buyer selected, marks
--- it ready, saves, and commits it - which starts the reveal. Returns false to
--- leave the receipt OPEN for Roblox to retry (nothing to deliver yet).
function HatchService.fulfil(player: Player, profile: DataService.Profile, product: MonetizationConfig.ProductDef, purchaseId: string): boolean
	local pending = pendingByBuyer[player]
	local saved = profile.PendingReveal
	local instanceId: string? = nil
	if pending and pending.productId == product.productId then
		instanceId = pending.instanceId
	elseif type(saved) == "table" and saved.productId == product.productId and type(saved.instanceId) == "string" then
		instanceId = saved.instanceId
	end
	if not instanceId then
		warn(`[HatchService] receipt {purchaseId} ({product.key}) from {player.Name} matches no pending reveal - left OPEN`)
		return false
	end

	local item = findItem(profile, instanceId)
	if not item then
		-- Stored between the prompt and the receipt. Storing a sealed
		-- container is refused, so this is a container that was robbed or a
		-- profile that changed under us: keep the receipt open and try again.
		warn(`[HatchService] receipt {purchaseId}: container {instanceId} is not on {player.Name}'s base - left OPEN`)
		return false
	end

	-- The purchase is honoured against THIS container and no other. If its
	-- timer ran out while the dialog was open, or the player revealed it by
	-- hand meanwhile, the container is revealed and the purchase is spent on
	-- exactly what it was for. Never a second container.
	pendingByBuyer[player] = nil
	profile.PendingReveal = nil
	if item.Hatched == false then
		item.HatchEndsAt = os.time()
		HatchService.commit(player, instanceId)
	end
	return true
end

-- ==========================================================
-- THE READY SWEEP
-- ==========================================================
--
-- One timer for the whole server rather than one per container: every few
-- seconds it marks any player whose container has just crossed its deadline
-- as dirty, so the next StatePush carries `ready = true`. Quiet on purpose:
-- the card over the container says READY TO REVEAL, and the client flips the
-- prompt itself the second its own clock hits zero.

local READY_SWEEP_SECONDS = 2
local announced: { [string]: boolean } = {}

local function sweep()
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if not profile then
			continue
		end
		for _, item in profile.DisplayItems do
			if item.Hatched == false and HatchService.remaining(item) <= 0 and not announced[item.InstanceId] then
				announced[item.InstanceId] = true
				StateService.markDirty(player)
			end
		end
	end
end

-- ==========================================================
-- START
-- ==========================================================

function HatchService.start()
	StateService.addProvider("sealed", HatchService.summarise)

	Remotes.get("HatchRequest").OnServerEvent:Connect(function(player, instanceId)
		if not hatchLimiter:consume(player) then
			return
		end
		-- A GUID and nothing else. Never trusted as a key until it is a string
		-- of sane length, so a table - or a megabyte - cannot reach the scan.
		if type(instanceId) ~= "string" or #instanceId == 0 or #instanceId > 64 then
			return
		end
		local ok, reason = HatchService.commit(player, instanceId)
		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		hatchLimiter:release(player)
		pendingByBuyer[player] = nil
		local profile = DataService.get(player)
		if profile then
			for _, item in profile.DisplayItems do
				announced[item.InstanceId] = nil
				revealingUntil[item.InstanceId] = nil
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(READY_SWEEP_SECONDS)
			local ok, err = pcall(sweep)
			if not ok then
				warn(`[HatchService] ready sweep failed: {err}`)
			end
		end
	end)

	print("[HatchService] reveal timers and instant reveal online")
end

return HatchService
