--!strict
--[[
	ProgressEvents
	A tiny in-process event bus for "the player made progress" moments.

	    ProgressEvents.fire(player, kind, amount?, info?)
	    ProgressEvents.on(kind, fn)     -- fn(player, amount, info)

	Services that already KNOW a thing happened fire it from their committed
	success path; listeners (badges, quests, streaks) subscribe by kind and
	never become a dependency of the service that fired. A leaf module:
	requires nothing, so anything can require it.

	MERGE NOTE (social pass). Another agent is creating this same module with
	this exact API. If both exist at merge time, keep ONE file; the social
	pass only uses `fire` and `on` as written here. Kinds fired by the social
	pass wiring (init.server.luau / HeistService):
	  "steal"   amount 1, info { zone }
	  "escape"  amount 1
	  "reveal"  amount 1, info { rarity, itemId }  (fired at the SWAP moment)
	  "heist"   amount 1
	Kinds listened to by SocialService/BadgeAwardService:
	  the four above, plus "streak" / "dailyStreak" (amount = streak days,
	  or info.streak / info.days).

	Listeners run in their own thread under pcall: a failing listener can
	never undo, delay or break the gameplay that fired the event.
]]

export type Listener = (Player, number, { [string]: any }) -> ()

local ProgressEvents = {}

local listeners: { [string]: { Listener } } = {}

--- Subscribes `fn` to `kind`. Returns a disconnect function.
function ProgressEvents.on(kind: string, fn: Listener): () -> ()
	local list = listeners[kind]
	if not list then
		list = {}
		listeners[kind] = list
	end
	table.insert(list, fn)
	return function()
		local current = listeners[kind]
		local at = if current then table.find(current, fn) else nil
		if current and at then
			table.remove(current, at)
		end
	end
end

--- Reports one progress moment. Never yields, never throws.
function ProgressEvents.fire(player: Player, kind: string, amount: number?, info: { [string]: any }?)
	local list = listeners[kind]
	if not list or #list == 0 then
		return
	end
	local value = tonumber(amount) or 1
	local detail = info or {}
	for _, fn in table.clone(list) do
		task.spawn(function()
			-- (`:: any`: luau-lsp mistypes pcall of a function returning nothing.)
			local ok: boolean, err: any = (pcall :: any)(fn, player, value, detail)
			if not ok then
				warn(`[ProgressEvents] "{kind}" listener failed: {err}`)
			end
		end)
	end
end

return ProgressEvents
