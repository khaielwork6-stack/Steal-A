--!strict
--[[
	RelicRollService
	[relic-roll] The "MUSEUM RELICS [LIMITED]" gacha banner at the top of the
	Shop panel: rolls, grants, and the durable "replay this reveal" record.

	RNG IS SERVER-SIDE ONLY. Every roll uses a fresh Random.new() made here;
	the client never sees anything but the finished result.

	A ROLL IS A DIRECT GRANT, NOT A RESERVATION. Unlike a base steal or an
	Instant Reveal (which pay for one specific item chosen before the Robux
	dialog opens), a Relic Roll invents its own reward the instant the
	receipt lands - there is nothing to reserve and nothing that can go stale
	while a purchase is in flight. That makes it closer to a Gadget refill
	than to HeistService/HatchService: MonetizationService calls `grant`
	directly (installed via `setRelicRollHandler`, like the Gadget and Skip
	handlers) and a `false` return is ALWAYS an "undeliverable" conversion to
	Cash, never a "retry" - waiting longer can never make an invalid grant
	valid (see MonetizationService's RelicRoll branch).

	NOTHING IS EVER LOST. The rolled item goes into Storage; if Storage is
	full it goes through MailboxService instead (durable, delivered the
	moment there is room or the player is next online) - see `performGrant`.

	THE REPLAY RECORD. `profile.PendingRelicReveal` is NOT the grant (the
	items are already safely in Storage/Mailbox by the time it is written) -
	it is only "what to animate next". It rides StatePush (`relicRoll.
	pendingReveal`) so a client that was offline, or that reconnects mid
	purchase, still gets to see the reveal it paid for; the client clears it
	with RelicRollAck once the animation has played (or immediately, if it
	only wants the loot).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local RelicRollConfig = require(ReplicatedStorage.Shared.Config.RelicRollConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)

local DataService = require(script.Parent.DataService)
local LootService = require(script.Parent.LootService)
local MailboxService = require(script.Parent.MailboxService)
local MonetizationService = require(script.Parent.MonetizationService)
local StateService = require(script.Parent.StateService)

local RelicRollService = {}

local ackLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.RelicRollAck or 2)

export type RolledSummary = {
	itemId: string,
	rarity: string,
	mutation: string,
	scale: number,
	income: number,
	overflow: boolean,
}

-- ==========================================================
-- ROLLING
-- ==========================================================

--- One item, fully rolled: the tier pick, then this game's own Scale and
--- mutation rolls (LootService/ScaleConfig - the SAME generators every other
--- spawned item uses, never a parallel format).
local function buildItem(itemId: string, rng: Random): DataService.DisplayItem?
	local def = LootConfig.ById[itemId]
	if not def then
		warn(`[RelicRollService] RelicRollConfig references unknown item "{itemId}"`)
		return nil
	end
	local scale = LootService.rollScale(def.zoneIndex, rng)
	local mutation = LootService.rollMutationId(rng)
	local item: DataService.DisplayItem = {
		InstanceId = HttpService:GenerateGUID(false),
		ItemId = itemId,
		ZoneId = def.zoneIndex,
		Rarity = def.rarity,
		Size = ScaleConfig.labelFor(scale),
		Mutation = mutation,
		BaseIncome = def.income,
		FinalIncome = 0, -- rebuilt by reconcileItem below
		SlotIndex = 0,
		Scale = scale,
		VisualScale = scale,
		SizeVisualVersion = RarityConfig.SIZE_VISUAL_VERSION,
		EconomyScaleVersion = ScaleConfig.ECONOMY_SCALE_VERSION,
		-- A gacha win is grown already, like a fused trophy or a mailed gift:
		-- the player did not just place a fresh container, so it earns from
		-- the moment it is opened.
		MaturationSeconds = 0,
		GrowthSeconds = 0,
		Hatched = true,
	}
	DataService.reconcileItem(item)
	return item
end

--- The actual work: roll `count` items, put each in Storage or (if full)
--- the Mailbox, and write the replay record. Never yields except through
--- MailboxService.send (a DataStore call) when Storage is full.
local function performGrant(player: Player, profile: DataService.Profile, count: number, purchaseId: string, rng: Random): { RolledSummary }
	local capacity = StorageConfig.capacityForTier(profile.StorageTier)
	local summary: { RolledSummary } = {}
	local overflowCount = 0

	for index = 1, count do
		local tier = RelicRollConfig.rollTier(rng)
		local item = buildItem(tier.itemId, rng)
		if not item then
			continue -- an unknown itemId in the config; skip rather than crash a whole batch
		end

		local overflow = false
		if #profile.Inventory < capacity then
			table.insert(profile.Inventory, item)
		else
			overflow = true
			local sent = MailboxService.send(player.UserId, {
				kind = "item",
				item = item,
				note = "Museum Relics roll - Storage was full",
				id = `relicroll:{purchaseId}:{index}`,
			})
			if not sent then
				-- LAST RESORT: nothing is ever lost, so a Mailbox failure
				-- (a DataStore outage) still lands the item in Storage, past
				-- the usual cap, rather than dropping it.
				warn(`[RelicRollService] mailbox refused a relic for {player.Name} - granting into Storage past capacity`)
				table.insert(profile.Inventory, item)
				overflow = false
			end
		end

		table.insert(summary, {
			itemId = item.ItemId,
			rarity = item.Rarity,
			mutation = RarityConfig.normaliseMutation(item.Mutation),
			scale = item.Scale or 1,
			income = item.FinalIncome,
			overflow = overflow,
		})
		if overflow then
			overflowCount += 1
		end
	end

	if overflowCount > 0 then
		StateService.notify(
			player,
			"info",
			`Your Storage was full - {overflowCount} relic{if overflowCount > 1 then "s" else ""} went to your Mailbox.`
		)
	end

	-- [analytics-discord] The best (highest-rank) item this batch won, for
	-- the RelicRoll custom event. Never a dependency on AnalyticsEvents
	-- directly - fired through the same bus every other service uses.
	local bestRarity, bestItemId = "Common", ""
	for _, rolled in summary do
		if RarityConfig.rank(rolled.rarity) >= RarityConfig.rank(bestRarity) then
			bestRarity, bestItemId = rolled.rarity, rolled.itemId
		end
	end
	require(script.Parent.ProgressEvents).fire(player, "relicRoll", count, { bestRarity = bestRarity, bestItemId = bestItemId })

	-- THE REPLAY RECORD, not the grant (already durable above). Overwrites
	-- any earlier one: only the most recent purchase's reveal is worth
	-- replaying, and the items from an older, unacked one were never lost -
	-- they are sitting in Storage/Mailbox exactly like this one's are.
	profile.PendingRelicReveal = {
		purchaseId = purchaseId,
		rollCount = count,
		items = summary,
		at = os.time(),
	}
	StateService.pushNow(player)
	return summary
end

-- ==========================================================
-- THE GRANT (installed on MonetizationService as the RelicRoll handler)
-- ==========================================================

--- `(player, rollCount, purchaseId) -> (granted, why)`. See the header: a
--- `false` here is always read as "convert this receipt to Cash", never as
--- "retry" - there is no reservation to still be honoured later.
---
--- Exposed directly (not wrapped) so DebugCommands/RelicRoll can call the
--- EXACT same path with a synthetic purchaseId - "simulate a roll without
--- Robux" - and MonetizationService's ProcessReceipt calls it as its handler.
function RelicRollService.grant(player: Player, rollCount: number, purchaseId: string): (boolean, string?)
	if type(rollCount) ~= "number" or rollCount ~= rollCount or rollCount <= 0 or rollCount > 50 then
		return false, "misconfigured roll count"
	end
	if type(purchaseId) ~= "string" or purchaseId == "" then
		return false, "missing purchase id"
	end
	-- [monetization pass] A Relic Roll is a paid random item, exactly like
	-- Instant Reveal: withheld where PolicyService restricts them. The
	-- client hides the whole banner for the same players (see `summarise`);
	-- this is the server-side refusal for a receipt that arrives anyway (an
	-- external purchase through the product's own catalog page).
	if MonetizationService.paidRandomRestricted(player) then
		return false, "paid random items are restricted for this account"
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "profile not loaded"
	end
	local ok, err = pcall(performGrant, player, profile, math.floor(rollCount), purchaseId, Random.new())
	if not ok then
		warn(`[RelicRollService] grant failed for {player.Name}: {err}`)
		return false, "internal error"
	end
	return true
end

-- ==========================================================
-- THE REPLAY ACK
-- ==========================================================

--- The client finished (or skipped) the reveal for `purchaseId`. Clears the
--- replay record so a later join does not show it again. A stale or
--- mismatched id is a no-op: the record it would have cleared already isn't
--- the one on the profile (a newer purchase landed, or it was already acked).
function RelicRollService.acknowledgeReveal(player: Player, purchaseId: string)
	local profile = DataService.get(player)
	if not profile then
		return
	end
	local pending = profile.PendingRelicReveal
	if type(pending) ~= "table" or pending.purchaseId ~= purchaseId then
		return
	end
	profile.PendingRelicReveal = nil
	StateService.pushNow(player)
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
end

-- ==========================================================
-- WHAT THE CLIENT RENDERS
-- ==========================================================

--- Rides StatePush as `relicRoll`. Everything the banner needs to draw
--- itself and hide correctly - the client decides nothing about odds, prices
--- or eligibility that this table does not already say.
function RelicRollService.summarise(player: Player): { [string]: any }
	local restricted = MonetizationService.paidRandomRestricted(player)

	local tiers = {}
	for _, tier in RelicRollConfig.Tiers do
		local def = LootConfig.ById[tier.itemId]
		table.insert(tiers, {
			itemId = tier.itemId,
			weight = tier.weight,
			rarity = if def then def.rarity else "Common",
			name = if def then def.name else tier.itemId,
			income = if def then def.income else 0,
		})
	end

	local prices: { [string]: any } = {}
	for _, key in RelicRollConfig.ProductKeys do
		local product = MonetizationConfig.ProductByKey[key]
		if product then
			prices[key] = {
				robux = MonetizationService.liveProductPrice(product.productId) or product.robux,
				rollCount = product.rollCount or 0,
				configured = product.productId > 0,
			}
		end
	end

	local profile = DataService.get(player)
	return {
		enabled = not restricted,
		restricted = restricted,
		limited = RelicRollConfig.limited,
		endsAt = RelicRollConfig.endsAt,
		title = RelicRollConfig.BANNER_TITLE,
		tag = RelicRollConfig.BANNER_TAG,
		tiers = tiers,
		prices = prices,
		pendingReveal = if profile then profile.PendingRelicReveal else nil,
	}
end

-- ==========================================================
-- START
-- ==========================================================

function RelicRollService.start()
	StateService.addProvider("relicRoll", RelicRollService.summarise)

	Remotes.get("RelicRollAck").OnServerEvent:Connect(function(player, purchaseId)
		if not ackLimiter:consume(player) then
			return
		end
		if type(purchaseId) ~= "string" or #purchaseId == 0 or #purchaseId > 100 then
			return
		end
		RelicRollService.acknowledgeReveal(player, purchaseId)
	end)

	Players.PlayerRemoving:Connect(function(player)
		ackLimiter:release(player)
	end)
end

return RelicRollService
