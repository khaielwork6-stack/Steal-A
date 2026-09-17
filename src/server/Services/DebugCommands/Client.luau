--!strict
--[[
	DebugCommands.Client
	Studio-only commands for the client performance pass (state push split).
	Loaded by DebugService; invoke through ServerStorage.DebugInvoke or the
	DebugRequest attribute bridge, e.g. DebugInvoke:Invoke("statePushSizes", "Player1").

	  statePushSizes   JSON byte sizes of what one push costs on the wire:
	                   the full snapshot, the per-change StatePush, and the two
	                   side channels (inventory, Index summary) that now only
	                   travel when they change.
	  forceStatePush   Sends everything now, side channels included (the same
	                   push a join, respawn or client resync gets).
]]

local HttpService = game:GetService("HttpService")

local StateService = require(script.Parent.Parent.StateService)

local function bytes(value: any): number
	if value == nil then
		return 0
	end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
	return if ok then #encoded else -1
end

return {
	statePushSizes = function(player: Player): any
		local state = StateService.snapshot(player) :: any
		if not state then
			return { error = "profile not loaded" }
		end
		local wire = table.clone(state)
		wire.inventory = nil
		wire.index = nil
		local result = {
			fullSnapshotBytes = bytes(state),
			statePushBytes = bytes(wire),
			inventoryPushBytes = bytes(state.inventory),
			indexSummaryPushBytes = bytes(state.index),
			inventoryCount = if type(state.inventory) == "table" then #state.inventory else 0,
		}
		print(
			`[DebugCommands.Client] {player.Name}: full {result.fullSnapshotBytes} B -> StatePush {result.statePushBytes} B`
				.. ` (+ inventory {result.inventoryPushBytes} B, index {result.indexSummaryPushBytes} B only on change)`
		)
		return result
	end,

	forceStatePush = function(player: Player)
		StateService.pushNow(player, true)
		return { pushed = true }
	end,
}
