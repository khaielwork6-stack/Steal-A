--!strict
--[[
	TradeLogic
	The rules of a trade, as PURE functions over two profiles - no players, no
	remotes, no DataStores, no yields. TradeService calls these with the two
	live profiles; the Studio debug command calls the very same functions with
	a synthetic in-memory profile, which is how the swap is tested with one
	player.

	WHAT MAY BE TRADED
	  * Only STORED items (profile.Inventory). A trophy on display has to be
	    stored first, which is also what takes it out of reach of a base heist.
	  * Only REVEALED items. A sealed container (Hatched == false) is refused:
	    its content is unknown to both sides, and a paid Instant Reveal plus a
	    trade would be a paid random item changing hands.
	  * Never an item mid-robbery (RobbedBy) or with an unknown ItemId.
	  * Cash: a whole number, 0 .. min(balance, TradeConfig.MAX_CASH).

	THE SWAP IS ATOMIC IN MEMORY
	`execute` re-validates BOTH offers and BOTH storage capacities first and
	changes nothing unless every check passes. Then, with no yield anywhere,
	it removes both offers, moves the Cash and inserts the items. Nothing can
	run between the check and the write.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)
local TradeConfig = require(ReplicatedStorage.Shared.Config.TradeConfig)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local TradeLogic = {}

export type Offer = {
	--- InstanceIds from the offering profile's Inventory, in the order added.
	items: { string },
	cash: number,
}

export type ItemView = {
	id: string,
	itemId: string,
	name: string,
	rarity: string,
	size: string,
	mutation: string,
	scale: number,
	income: number,
}

--- A profile as far as a trade is concerned. DataService.Profile satisfies it.
type TradeProfile = {
	Cash: number,
	Inventory: { any },
	DisplayItems: { any },
	StorageTier: number,
}

function TradeLogic.emptyOffer(): Offer
	return { items = {}, cash = 0 }
end

--- The stored item with this InstanceId, and its index in Inventory.
function TradeLogic.findStored(profile: TradeProfile, instanceId: string): (any, number?)
	for index, item in profile.Inventory do
		if type(item) == "table" and item.InstanceId == instanceId then
			return item, index
		end
	end
	return nil, nil
end

--- Whether one stored item may be offered, and why not.
function TradeLogic.itemTradable(item: any): (boolean, string?)
	if type(item) ~= "table" then
		return false, "That item is not in your storage."
	end
	if item.Hatched == false then
		return false, "Reveal it before trading it."
	end
	if item.RobbedBy ~= nil then
		return false, "That item is being stolen."
	end
	if type(item.ItemId) ~= "string" or not LootConfig.ById[item.ItemId] then
		return false, "That item can't be traded."
	end
	return true, nil
end

--- A clean Cash amount for an offer, or nil when it is not a usable number.
function TradeLogic.cleanCash(value: any): number?
	return Validate.integer(value, 0, TradeConfig.MAX_CASH)
end

--- Checks one side's whole offer against its own profile.
function TradeLogic.validateOffer(profile: TradeProfile, offer: Offer): (boolean, string?)
	if #offer.items > TradeConfig.MAX_ITEMS then
		return false, `At most {TradeConfig.MAX_ITEMS} items per trade.`
	end
	local seen: { [string]: boolean } = {}
	for _, id in offer.items do
		if seen[id] then
			return false, "An item was offered twice."
		end
		seen[id] = true
		local item = TradeLogic.findStored(profile, id)
		if not item then
			return false, "An offered item is no longer in storage."
		end
		local ok, reason = TradeLogic.itemTradable(item)
		if not ok then
			return false, reason
		end
	end
	local cash = TradeLogic.cleanCash(offer.cash)
	if cash == nil then
		return false, "That Cash amount is not valid."
	end
	if cash > (tonumber(profile.Cash) or 0) then
		return false, "Not enough Cash for that offer."
	end
	return true, nil
end

--- Whether `profile` has room for what it would end up storing.
function TradeLogic.hasRoom(profile: TradeProfile, gives: number, gets: number): boolean
	local capacity = StorageConfig.capacityForTier(profile.StorageTier)
	local after = #profile.Inventory - gives + gets
	-- A player already over capacity (a tier change, an old save) may still
	-- make a trade that does not add to their storage.
	return after <= capacity or gets <= gives
end

--- Every check `execute` makes, without changing anything. Returns
--- (ok, reason, whichSide) where whichSide is "a", "b" or nil.
function TradeLogic.validate(profileA: TradeProfile, offerA: Offer, profileB: TradeProfile, offerB: Offer): (boolean, string?, string?)
	if profileA == profileB then
		return false, "You can't trade with yourself.", nil
	end
	local okA, whyA = TradeLogic.validateOffer(profileA, offerA)
	if not okA then
		return false, whyA, "a"
	end
	local okB, whyB = TradeLogic.validateOffer(profileB, offerB)
	if not okB then
		return false, whyB, "b"
	end
	if #offerA.items == 0 and #offerB.items == 0 and offerA.cash == 0 and offerB.cash == 0 then
		return false, "The trade is empty.", nil
	end
	if not TradeLogic.hasRoom(profileA, #offerA.items, #offerB.items) then
		return false, "Not enough storage space.", "a"
	end
	if not TradeLogic.hasRoom(profileB, #offerB.items, #offerA.items) then
		return false, "Not enough storage space.", "b"
	end
	return true, nil, nil
end

--- Removes the offered items from a profile's Inventory and returns them,
--- in offer order. Only called after validate passed.
local function takeItems(profile: TradeProfile, ids: { string }): { any }
	local taken = {}
	for _, id in ids do
		local item, index = TradeLogic.findStored(profile, id)
		if item and index then
			table.remove(profile.Inventory, index)
			table.insert(taken, item)
		end
	end
	return taken
end

--- Puts items into a profile's Inventory as ordinary stored items. An
--- InstanceId the receiver already uses (vanishingly unlikely for GUIDs, but
--- a clash would make two items answer to one id) is replaced.
local function giveItems(profile: TradeProfile, items: { any })
	local taken: { [string]: boolean } = {}
	for _, list in { profile.DisplayItems, profile.Inventory } do
		for _, other in list do
			if type(other) == "table" and type(other.InstanceId) == "string" then
				taken[other.InstanceId] = true
			end
		end
	end
	for _, item in items do
		if type(item.InstanceId) ~= "string" or item.InstanceId == "" or taken[item.InstanceId] then
			item.InstanceId = HttpService:GenerateGUID(false)
		end
		taken[item.InstanceId] = true
		item.SlotIndex = 0
		item.RobbedBy = nil
		table.insert(profile.Inventory, item)
	end
end

export type Result = {
	aGave: { any },
	bGave: { any },
	aCash: number,
	bCash: number,
}

--- THE SWAP. Validates, then moves both offers in one uninterrupted step.
--- Returns (true, nil, result) or (false, reason, whichSide) with nothing
--- changed.
function TradeLogic.execute(profileA: TradeProfile, offerA: Offer, profileB: TradeProfile, offerB: Offer): (boolean, string?, any)
	local ok, reason, side = TradeLogic.validate(profileA, offerA, profileB, offerB)
	if not ok then
		return false, reason, side
	end
	-- From here to the end nothing yields and nothing can fail validation.
	local aItems = takeItems(profileA, offerA.items)
	local bItems = takeItems(profileB, offerB.items)
	profileA.Cash = profileA.Cash - offerA.cash + offerB.cash
	profileB.Cash = profileB.Cash - offerB.cash + offerA.cash
	giveItems(profileA, bItems)
	giveItems(profileB, aItems)
	local result: Result = { aGave = aItems, bGave = bItems, aCash = offerA.cash, bCash = offerB.cash }
	return true, nil, result
end

--- What a client is shown about one offered item. Rarity, size, mutation
--- and income are always visible on both sides (anti-scam).
function TradeLogic.view(item: any): ItemView
	local def = LootConfig.ById[item.ItemId]
	return {
		id = tostring(item.InstanceId),
		itemId = tostring(item.ItemId),
		name = if def then def.name else tostring(item.ItemId),
		rarity = tostring(item.Rarity or "Common"),
		size = tostring(item.Size or "Normal"),
		mutation = tostring(item.Mutation or "Normal"),
		scale = tonumber(item.Scale) or 1,
		income = tonumber(item.FinalIncome) or 0,
	}
end

--- Summed card income of an offer (the value the lopsided warning compares).
function TradeLogic.offerIncome(profile: TradeProfile, offer: Offer): number
	local total = 0
	for _, id in offer.items do
		local item = TradeLogic.findStored(profile, id)
		if item then
			total += tonumber(item.FinalIncome) or 0
		end
	end
	return total
end

--- True when the side giving `gives` for `gets` should be warned.
function TradeLogic.lopsided(gives: number, gets: number): boolean
	if gives < TradeConfig.LOPSIDED_MIN_INCOME then
		return false
	end
	return gives >= TradeConfig.LOPSIDED_RATIO * math.max(gets, 1)
end

--- A log-sized copy of a traded item (no session fields).
function TradeLogic.logItem(item: any): { [string]: any }
	return {
		InstanceId = item.InstanceId,
		ItemId = item.ItemId,
		Rarity = item.Rarity,
		Size = item.Size,
		Mutation = item.Mutation,
		Scale = item.Scale,
		FinalIncome = item.FinalIncome,
	}
end

return TradeLogic
