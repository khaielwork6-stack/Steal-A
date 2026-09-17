--!strict
--[[
	StateStore
	The ONE client listener of the replicated player state.

	WHY THIS EXISTS
	Twenty-odd controllers each connected to StatePush on their own. That had
	two costs:
	  * A controller that started late (several start() functions wait up to a
	    minute for world objects) missed the pushes that arrived before it
	    connected, and state is only resent on CHANGE - so a panel could sit on
	    defaults until something happened to change.
	  * The server could not split the snapshot without every controller
	    learning about three remotes.

	The server now sends the state on three remotes (see StateService, "THE
	SPLIT PUSH"):
	  StatePush         everything small, whenever anything changed
	  InventoryPush     `inventory`, only when it changed
	  IndexSummaryPush  `index` (the per-zone summary), only when it changed
	This module merges them into one table that looks exactly like the old
	StatePush payload - `state.inventory` and `state.index` are still there -
	and hands it to subscribers.

	CONTRACT
	  subscribe(fn)             fn(state) on every update, AND once right away
	                            (deferred) if a state has already arrived.
	  onKeyChanged(key, fn)     fn(value, state) when state[key] is a different
	                            value (by identity) from the last notification,
	                            and once right away if the key is present.
	  get()                     the latest merged state, or nil.
	Every call runs in its own thread, like RBXScriptSignal handlers did, so a
	handler that yields or throws cannot hold up the others.

	The Index DISCOVERY map (IndexPush) is a different channel with its own
	request-response sync and is still listened to by IndexController.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local StateStore = {}

type Handler = (any) -> ()
type KeyHandler = (any, any) -> ()

local latest: { [string]: any }? = nil
local inventory: any = nil
local index: any = nil
-- True once a side channel has arrived that no StatePush has folded in yet.
local sidePending = false

local subscribers: { Handler } = {}
local keyHandlers: { [string]: { KeyHandler } } = {}
-- What each key held at the last notification, for onKeyChanged.
local lastKeyValue: { [string]: any } = {}

local started = false

--- A fresh table per notification, as the old per-event payload was, so a
--- consumer that keeps a reference never sees it mutate underneath it.
local function merged(base: { [string]: any }): { [string]: any }
	local state = table.clone(base)
	state.inventory = inventory
	state.index = index
	return state
end

local function notify(state: { [string]: any })
	latest = state
	sidePending = false
	for _, fn in subscribers do
		task.spawn(fn, state)
	end
	for key, handlers in keyHandlers do
		local value = state[key]
		if value ~= lastKeyValue[key] then
			lastKeyValue[key] = value
			for _, fn in handlers do
				task.spawn(fn, value, state)
			end
		end
	end
end

--- A side channel changed. The server fires StatePush straight after it, so
--- normally that push folds it in; the short fallback covers the case where
--- no StatePush follows (or arrives first), so a change is never stranded.
local function onSideChannel()
	sidePending = true
	task.delay(0.1, function()
		if sidePending and latest then
			notify(merged(latest))
		end
	end)
end

function StateStore.get(): { [string]: any }?
	return latest
end

function StateStore.subscribe(fn: Handler): () -> ()
	table.insert(subscribers, fn)
	if latest then
		-- Deferred, not immediate: the caller is usually in the middle of its
		-- own start() and may not have finished setting up what fn uses.
		local snapshot = latest
		task.defer(fn, snapshot)
	end
	return function()
		local at = table.find(subscribers, fn)
		if at then
			table.remove(subscribers, at)
		end
	end
end

function StateStore.onKeyChanged(key: string, fn: KeyHandler): () -> ()
	local list = keyHandlers[key]
	if not list then
		list = {}
		keyHandlers[key] = list
		lastKeyValue[key] = if latest then latest[key] else nil
	end
	table.insert(list, fn)
	local current = latest
	if current and current[key] ~= nil then
		task.defer(fn, current[key], current)
	end
	return function()
		local at = table.find(list, fn)
		if at then
			table.remove(list, at)
		end
	end
end

--- Connects the three remotes and asks the server for a full resync. Safe to
--- call more than once. Call it before any controller starts.
function StateStore.start()
	if started then
		return
	end
	started = true

	Remotes.get("InventoryPush").OnClientEvent:Connect(function(value)
		inventory = value
		onSideChannel()
	end)
	Remotes.get("IndexSummaryPush").OnClientEvent:Connect(function(value)
		index = value
		onSideChannel()
	end)
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		notify(merged(state))
	end)

	-- Ask rather than hope the join push lands after we connected. Retried a
	-- few times while nothing has arrived (the profile may still be loading;
	-- the server also re-marks for six seconds after the load).
	local sync = Remotes.get("StateSyncRequest")
	task.spawn(function()
		for _ = 1, 5 do
			if latest then
				return
			end
			sync:FireServer()
			task.wait(3)
		end
	end)
end

return StateStore
