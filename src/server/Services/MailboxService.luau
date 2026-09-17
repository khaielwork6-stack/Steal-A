--!strict
--[[
	MailboxService
	Durable delivery to a player who is offline or in another server.

	THE API (other services call exactly this)
	    MailboxService.send(userId, entry) -> boolean     -- yields
	  `entry` is a MailEntry: an item for storage, Cash, or Speed. `send`
	  stamps a unique Id and appends it to DataStore "Mailbox_v1", key
	  "mail_<userId>" (UpdateAsync, capped at GameConfig.MAILBOX_CAPACITY).
	  true = the entry is durably queued; false = it is not (full, invalid,
	  DataStore error) and the caller still owns whatever it was sending.

	DELIVERY
	  When a profile goes live (init, after the offline settle) and then every
	  MAILBOX_POLL_SECONDS for everyone online:
	    1. read the mailbox;
	    2. grant every entry whose Id is not already in profile.DeliveredMail
	       (an item needs a free storage slot - if storage is full it simply
	       stays in the mailbox for a later pass) and record its Id there;
	    3. SAVE the profile - only a durable grant may leave the mailbox;
	    4. remove, in one UpdateAsync, exactly the Ids that are now granted.
	  A crash between 3 and 4 leaves granted entries in the mailbox; the next
	  pass finds their Ids in DeliveredMail and only removes them. That record
	  is what makes delivery idempotent. Entries sent while a pass runs are
	  untouched by step 4, which filters by Id rather than rewriting the list.

	  The session lock (DataService) guarantees only one server delivers a
	  given player's mail at a time.

	STUDIO WITHOUT API ACCESS
	  There is no DataStore, so mail is kept in memory for this server only
	  (with a warning). Enough to exercise the flow on yourself; nothing
	  survives the session.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local StorageConfig = require(ReplicatedStorage.Shared.Config.StorageConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local SpeedService = require(script.Parent.SpeedService)
local StateService = require(script.Parent.StateService)

local MailboxService = {}

export type MailEntry = {
	kind: "item",
	item: DataService.DisplayItem,
	note: string?,
} | {
	kind: "cash",
	amount: number,
	source: string,
	note: string?,
} | {
	kind: "speed",
	amount: number,
	source: string,
	note: string?,
}

local STORE_NAME = "Mailbox_v1"
--- Attempts `send` makes before reporting failure.
local SEND_ATTEMPTS = 3

local store: DataStore? = nil
--- Studio memory mode only: userId -> entries.
local memoryBoxes: { [number]: { any } } = {}
--- Players with a delivery pass running, so the poll and the join never overlap.
local delivering: { [Player]: boolean } = {}
--- Players already told this session that mail is waiting on a full storage.
local toldStorageFull: { [Player]: boolean } = {}

local function mailKey(userId: number): string
	return "mail_" .. userId
end

local function memoryMode(): boolean
	return DataService.isStudioMemoryMode()
end

local function openStore(): DataStore?
	if store then
		return store
	end
	local ok, opened = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = opened
	end
	return store
end

local function finitePositive(value: any): number?
	local n = tonumber(value)
	if n == nil or n ~= n or n == math.huge or n <= 0 then
		return nil
	end
	return math.floor(n)
end

--- A deep-enough copy of an entry for storage, or nil (with a reason) when it
--- cannot be delivered.
local function normalise(entry: any): (any, string?)
	if type(entry) ~= "table" then
		return nil, "entry is not a table"
	end
	local note = if type(entry.note) == "string" then entry.note else nil
	if entry.kind == "cash" or entry.kind == "speed" then
		local amount = finitePositive(entry.amount)
		if not amount then
			return nil, "amount must be a finite number above 0"
		end
		return { kind = entry.kind, amount = amount, source = tostring(entry.source or "mail"), note = note }
	elseif entry.kind == "item" then
		if type(entry.item) ~= "table" or type(entry.item.ItemId) ~= "string" then
			return nil, "item must be a DisplayItem with an ItemId"
		end
		if not LootConfig.ById[entry.item.ItemId] then
			return nil, `unknown ItemId "{entry.item.ItemId}"`
		end
		return { kind = "item", item = table.clone(entry.item), note = note }
	end
	return nil, `unknown kind "{tostring(entry.kind)}"`
end

--- Queues one entry for `userId`. Yields. See the header for the contract.
function MailboxService.send(userId: number, entry: MailEntry): boolean
	local stored, reason = normalise(entry)
	if not stored then
		warn(`[MailboxService] refused mail for {userId}: {reason}`)
		return false
	end
	stored.Id = HttpService:GenerateGUID(false)
	stored.SentAt = os.time()

	local sent = false
	if memoryMode() then
		warn("[MailboxService] no DataStore (Studio API access off) - mail kept in memory for this server only")
		local box = memoryBoxes[userId] or {}
		memoryBoxes[userId] = box
		if #box < GameConfig.MAILBOX_CAPACITY then
			table.insert(box, stored)
			sent = true
		end
	else
		for attempt = 1, SEND_ATTEMPTS do
			local target = openStore()
			local full = false
			local ok, err = pcall(function()
				if not target then
					error("the Mailbox DataStore could not be opened")
				end
				target:UpdateAsync(mailKey(userId), function(list: any): any
					full = false
					local entries = if type(list) == "table" then list else {}
					if #entries >= GameConfig.MAILBOX_CAPACITY then
						full = true
						return nil
					end
					table.insert(entries, stored)
					return entries
				end)
			end)
			if ok then
				sent = not full
				if full then
					warn(`[MailboxService] mailbox for {userId} is full ({GameConfig.MAILBOX_CAPACITY}); {stored.kind} not sent`)
				end
				break
			end
			warn(`[MailboxService] send attempt {attempt} to {userId} failed: {err}`)
			if attempt < SEND_ATTEMPTS then
				task.wait(attempt)
			end
		end
	end

	-- The recipient is right here: no need to wait for the poll.
	if sent then
		local online = Players:GetPlayerByUserId(userId)
		if online then
			task.spawn(MailboxService.deliver, online)
		end
	end
	return sent
end

local function readBox(userId: number): { any }?
	if memoryMode() then
		return memoryBoxes[userId] or {}
	end
	local target = openStore()
	if not target then
		return nil
	end
	local ok, result = pcall(function()
		return target:GetAsync(mailKey(userId))
	end)
	if not ok then
		warn(`[MailboxService] could not read mail for {userId}: {result}`)
		return nil
	end
	return if type(result) == "table" then result else {}
end

local function removeIds(userId: number, finished: { [string]: boolean }): boolean
	local function keep(list: { any }): { any }
		local kept = {}
		for _, entry in list do
			if not (type(entry) == "table" and type(entry.Id) == "string" and finished[entry.Id]) then
				table.insert(kept, entry)
			end
		end
		return kept
	end
	if memoryMode() then
		memoryBoxes[userId] = keep(memoryBoxes[userId] or {})
		return true
	end
	local target = openStore()
	if not target then
		return false
	end
	local ok, err = pcall(function()
		target:UpdateAsync(mailKey(userId), function(list: any): any
			if type(list) ~= "table" then
				return nil
			end
			return keep(list)
		end)
	end)
	if not ok then
		warn(`[MailboxService] could not clear delivered mail for {userId}: {err}`)
	end
	return ok
end

local function remember(profile: DataService.Profile, id: string)
	table.insert(profile.DeliveredMail, id)
	while #profile.DeliveredMail > GameConfig.MAILBOX_DELIVERED_MEMORY do
		table.remove(profile.DeliveredMail, 1)
	end
end

local function withNote(message: string, note: any): string
	return if type(note) == "string" and note ~= "" then `{message} ({note})` else message
end

--- Applies one entry. Returns true when it was granted; false leaves it in
--- the mailbox (storage full, or something about it cannot be delivered).
local function grant(player: Player, profile: DataService.Profile, entry: any): boolean
	if entry.kind == "cash" then
		local amount = finitePositive(entry.amount)
		if not amount then
			return false
		end
		-- `award`: mail carries a final amount, never scaled by the Cash pass.
		EconomyService.award(player, amount, (tostring(entry.source or "other")) :: any)
		StateService.notify(player, "success", withNote(`You received {NumberFormat.cash(amount)}!`, entry.note), "levelup")
		return true
	elseif entry.kind == "speed" then
		local amount = finitePositive(entry.amount)
		if not amount then
			return false
		end
		-- The same direct grant the group gift and Speed products make.
		profile.SpeedPower += amount
		SpeedService.applyMovement(player)
		StateService.notify(player, "success", withNote(`You received +{NumberFormat.short(amount)} Speed!`, entry.note), "levelup")
		return true
	elseif entry.kind == "item" then
		local source = entry.item
		if type(source) ~= "table" or type(source.ItemId) ~= "string" or not LootConfig.ById[source.ItemId] then
			return false
		end
		if #profile.Inventory >= StorageConfig.capacityForTier(profile.StorageTier) then
			if not toldStorageFull[player] then
				toldStorageFull[player] = true
				StateService.notify(player, "info", "You have an item waiting - free a storage slot to receive it.")
			end
			return false
		end

		-- A normal STORED item: off display (SlotIndex 0), revealed (storage
		-- refuses sealed containers), not being robbed, with an InstanceId no
		-- other item of theirs uses. reconcileItem rebuilds its economy fields
		-- from the live config, exactly as a load would.
		local item = table.clone(source) :: DataService.DisplayItem
		local taken: { [string]: boolean } = {}
		for _, list in { profile.DisplayItems, profile.Inventory } do
			for _, other in list do
				taken[other.InstanceId] = true
			end
		end
		if type(item.InstanceId) ~= "string" or item.InstanceId == "" or taken[item.InstanceId] then
			item.InstanceId = HttpService:GenerateGUID(false)
		end
		item.SlotIndex = 0
		item.Hatched = true
		item.HatchEndsAt = nil
		item.SpawnToken = nil
		item.RobbedBy = nil
		DataService.reconcileItem(item)
		table.insert(profile.Inventory, item)

		local def = LootConfig.ById[item.ItemId]
		StateService.notify(player, "success", withNote(`You received {if def then def.name else item.ItemId}!`, entry.note), "levelup")
		return true
	end
	return false
end

local function deliverNow(player: Player): number
	local list = readBox(player.UserId)
	if not list or #list == 0 then
		return 0
	end
	-- Re-read after the yield: they may have left.
	local profile = DataService.get(player)
	if not profile then
		return 0
	end

	local already: { [string]: boolean } = {}
	for _, id in profile.DeliveredMail do
		already[id] = true
	end

	local finished: { [string]: boolean } = {}
	local anyFinished = false
	local granted = 0
	for _, entry in list do
		if type(entry) ~= "table" or type(entry.Id) ~= "string" then
			continue
		end
		if already[entry.Id] then
			finished[entry.Id] = true
			anyFinished = true
			continue
		end
		local ok, result = pcall(grant, player, profile, entry)
		if not ok then
			warn(`[MailboxService] granting {entry.Id} to {player.Name} failed: {result}`)
		elseif result then
			remember(profile, entry.Id)
			already[entry.Id] = true
			finished[entry.Id] = true
			anyFinished = true
			granted += 1
		end
	end
	if not anyFinished then
		return 0
	end

	if granted > 0 then
		EconomyService.recalculate(player)
		StateService.pushNow(player)
	end

	-- DURABLE FIRST. Only a saved grant may leave the mailbox; a failed save
	-- leaves everything there for the next pass, which will find the Ids in
	-- DeliveredMail (in memory now, on disk once a save lands) and not grant
	-- them again.
	if DataService.isPersistent() and not DataService.save(player) then
		warn(`[MailboxService] save after delivering to {player.Name} failed; mail kept for the next pass`)
		return granted
	end
	removeIds(player.UserId, finished)
	return granted
end

--- One delivery pass for `player`. Yields. Returns how many entries were
--- granted. Safe to call at any time; overlapping calls are dropped.
function MailboxService.deliver(player: Player): number
	if delivering[player] or not DataService.get(player) then
		return 0
	end
	delivering[player] = true
	local ok, result = pcall(deliverNow, player)
	delivering[player] = nil
	if not ok then
		warn(`[MailboxService] delivery to {player.Name} failed: {result}`)
		return 0
	end
	return result
end

--- STUDIO TEST SUPPORT: the raw mailbox, or nil when it cannot be read.
function MailboxService.peek(userId: number): { any }?
	return readBox(userId)
end

function MailboxService.start()
	Players.PlayerRemoving:Connect(function(player)
		toldStorageFull[player] = nil
	end)

	-- The poll. The join's own first pass is started by init once the
	-- profile is live and settled; this picks up everything sent later.
	task.spawn(function()
		while true do
			task.wait(GameConfig.MAILBOX_POLL_SECONDS)
			for _, player in Players:GetPlayers() do
				if DataService.get(player) then
					task.spawn(MailboxService.deliver, player)
				end
			end
		end
	end)

	print(`[MailboxService] mailbox online ({if memoryMode() then "in memory (Studio)" else STORE_NAME})`)
end

return MailboxService
