--!strict
--[[
	LobbyLayout
	Where the lobby's runtime-built objects stand, as things the owner can MOVE
	IN STUDIO.

	THE PROBLEM THIS SOLVES. The trail booth, the event stand, the gift chest,
	the two leaderboards and the lobby spawn are built or repositioned by
	scripts at server start, from numbers in MapConfig.HUB. Drag the booth
	somewhere better in Studio and the next Play snaps it straight back - the
	position was never Studio's to keep.

	THE ANSWER. An invisible anchored part per object, under
	`Workspace.LobbyMarkers`, is the placement. A service asks this module for
	its marker's CFrame and stands its object there; MapConfig.HUB is only the
	fallback that stamps out a missing marker. The markers live OUTSIDE
	Workspace.Map on purpose, so a map rebuild never touches them: move one,
	save, and it stays moved.

	  Spawn             the lobby spawn pad (facing = the marker's LookVector)
	  TrailBooth        the booth, its counter and circle on its local +Z
	  EventStand        the Next Update board (turned to face the Spawn marker)
	  GiftChest         the free-gift chest
	  LeaderboardMoney  the Money board (turned to face the Spawn marker)
	  LeaderboardSpeed  the Speed board
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local LobbyLayout = {}

LobbyLayout.FOLDER_NAME = "LobbyMarkers"

--- Marker name -> the MapConfig.HUB default it is stamped from.
local function defaults(): { [string]: CFrame }
	local hub = MapConfig.HUB
	local spawn = hub.spawn
	local function facingSpawn(position: Vector3): CFrame
		local flat = Vector3.new(spawn.X, position.Y, spawn.Z)
		if (flat - position).Magnitude < 0.5 then
			return CFrame.new(position)
		end
		return CFrame.lookAt(position, flat)
	end
	return {
		Spawn = CFrame.lookAt(spawn, spawn + Vector3.new(0, 0, 40)),
		TrailBooth = hub.trailBooth,
		EventStand = facingSpawn(hub.eventStand),
		GiftChest = facingSpawn(hub.giftChest),
		LeaderboardMoney = facingSpawn(hub.leaderboards.Money),
		LeaderboardSpeed = facingSpawn(hub.leaderboards.Speed),
	}
end

local function markerFolder(): Instance?
	return workspace:FindFirstChild(LobbyLayout.FOLDER_NAME)
end

--- The marker's CFrame, or nil when the owner has not got one (the caller
--- falls back to MapConfig.HUB).
function LobbyLayout.cframe(name: string): CFrame?
	local folder = markerFolder()
	local marker = folder and folder:FindFirstChild(name)
	return if marker and marker:IsA("BasePart") then marker.CFrame else nil
end

--- Marker CFrame, else the given fallback.
function LobbyLayout.frame(name: string, fallback: CFrame): CFrame
	return LobbyLayout.cframe(name) or fallback
end

--- Marker position, else the given fallback.
function LobbyLayout.position(name: string, fallback: Vector3): Vector3
	local cf = LobbyLayout.cframe(name)
	return if cf then cf.Position else fallback
end

--- Server / builder. Creates the folder and any marker that is missing, from
--- the MapConfig.HUB defaults. NEVER moves or replaces one that exists: an
--- existing marker is the owner's placement.
function LobbyLayout.ensureMarkers(): number
	local folder = markerFolder()
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = LobbyLayout.FOLDER_NAME
		folder.Parent = workspace
	end
	local made = 0
	for name, cf in defaults() do
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("BasePart") then
			continue
		end
		if existing then
			existing:Destroy()
		end
		local marker = Instance.new("Part")
		marker.Name = name
		marker.Size = Vector3.new(4, 1, 4)
		marker.CFrame = cf
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.CastShadow = false
		marker.Transparency = 1
		marker.Locked = false
		marker.Parent = folder
		made += 1
	end
	return made
end

return LobbyLayout
