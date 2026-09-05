--!strict
--[[
	Remotes
	Creates and resolves the RemoteEvents in ReplicatedStorage.Remotes.

	The server creates them on first require; clients wait for them. Every one of
	these carries untrusted *intent* only - the server derives rewards, targets
	and outcomes (GDD section 18).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

Remotes.NAMES = {
	-- client -> server requests
	"StealRequest",
	"PlaceLootRequest",
	"SellLootRequest",
	"InventoryRequest",
	"BaseUpgradeRequest",
	"TreadmillUpgradeRequest",
	"BatSwingRequest",
	"TrapPlaceRequest",
	"IndexClaimRequest",
	"TeleportHomeRequest",
	-- server -> client
	"StatePush",
	"Notify",
	-- The 96-entry Index discovery map. Deliberately NOT part of StatePush,
	-- which fires several times a second while income ticks.
	"IndexPush",
}

local folder: Folder

if RunService:IsServer() then
	folder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	for _, name in Remotes.NAMES do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

--- Resolves a remote by name; errors loudly on a typo rather than returning nil.
function Remotes.get(name: string): RemoteEvent
	local remote = folder:WaitForChild(name, 10)
	assert(remote, `Remotes.get: "{name}" does not exist`)
	return remote :: RemoteEvent
end

return Remotes
