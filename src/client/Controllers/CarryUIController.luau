--!strict
--[[
	CarryUIController
	While the player is carrying loot, the HUD gets out of the way: the only
	custom controls left are DROP and the gadget slots of the hotbar (keys
	3-5, round3-gameplay: UIStateController keeps HotbarUI up for this claim
	and HotbarController hides the other slots). Everything else - menu,
	stats, offers, the Night timer, toasts, the interact prompt - comes back
	the moment the carry ends, however it ends.

	ONE SOURCE OF TRUTH. `carrying` on StatePush is the server's word (set by
	CarryService the frame a steal lands, cleared on escape, catch, drop,
	death and leaving), and this controller only ever mirrors it into a
	single UIStateController claim. UIStateController already refuses double
	claims, restores to remembered state, and drops every claim on respawn -
	so overlapping events cannot leave the HUD hidden or restore it twice.
]]

local UIStateController = require(script.Parent.UIStateController)

local CarryUIController = {}

local CLAIM = "carry"

function CarryUIController.start()
	require(script.Parent.Parent.StateStore).subscribe(function(state)
		if type(state) ~= "table" then
			return
		end
		if state.carrying ~= nil then
			UIStateController.claim(CLAIM)
		else
			UIStateController.release(CLAIM)
		end
	end)
end

return CarryUIController
