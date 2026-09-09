--!strict
--[[
	CarryUIController
	While the player is carrying loot, the HUD gets out of the way: the only
	custom button left is DROP. Everything else - menu, stats, hotbar, offers,
	the Night timer, toasts, the interact prompt - comes back the moment the
	carry ends, however it ends.

	ONE SOURCE OF TRUTH. `carrying` on StatePush is the server's word (set by
	CarryService the frame a steal lands, cleared on escape, catch, drop,
	death and leaving), and this controller only ever mirrors it into a
	single UIStateController claim. UIStateController already refuses double
	claims, restores to remembered state, and drops every claim on respawn -
	so overlapping events cannot leave the HUD hidden or restore it twice.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local UIStateController = require(script.Parent.UIStateController)

local CarryUIController = {}

local CLAIM = "carry"

function CarryUIController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
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
