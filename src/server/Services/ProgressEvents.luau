--!strict
--[[
	ProgressEvents
	A tiny server-side event bus for "a player did X" progress signals.

	MERGE NOTE (vaults-crews): another feature pass is creating this module with
	the same API. This is a MINIMAL COMPATIBLE copy so the crew assist works on
	its own; when both land, keep the fuller version and make sure it offers
	exactly:

	    ProgressEvents.fire(player, kind, amount, info)
	    ProgressEvents.on(kind, fn) -> disconnect function

	Kinds fired today:
	    "delivered"  CarryService.consumeCarry - a carried item became a
	                 trophy on the player's base. amount = 1,
	                 info = { itemId, zoneIndex, income, heist }
	                 (zoneIndex 0 and heist = true for a base steal).

	Listeners run in their own threads: a slow or throwing listener can never
	delay or break the gameplay path that fired the event.
]]

local ProgressEvents = {}

export type Listener = (player: Player, amount: number, info: any) -> ()

local listeners: { [string]: { Listener } } = {}

--- Reports progress. Never yields and never throws.
function ProgressEvents.fire(player: Player, kind: string, amount: number?, info: any?)
	local list = listeners[kind]
	if not list then
		return
	end
	for _, fn in table.clone(list) do
		task.spawn(function()
			local ok, err = pcall(function()
				fn(player, amount or 1, info)
				return true
			end)
			if not ok then
				warn(`[ProgressEvents] "{kind}" listener failed: {err}`)
			end
		end)
	end
end

--- Listens for one kind. Returns a function that removes the listener.
function ProgressEvents.on(kind: string, fn: Listener): () -> ()
	local list = listeners[kind]
	if not list then
		list = {}
		listeners[kind] = list
	end
	table.insert(list, fn)
	return function()
		local current = listeners[kind]
		local index = current and table.find(current, fn)
		if current and index then
			table.remove(current, index)
		end
	end
end

return ProgressEvents
