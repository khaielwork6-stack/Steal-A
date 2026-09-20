--!strict
--[[
	LobbyGhostService
	Two things the owner asked for in the safe-zone lobby (2026-09-18):

	NOBODY BLOCKS ANYBODY. A character in the safe zone is moved into the
	LobbyGhost collision group (GuardianService owns the groups and their
	rules): it still stands on the world, but walks through other players and
	through every plot's treadmill belt and trigger. Cross the safe line into
	the zones and it goes back to the Players group, where bodies matter
	again (the bat, the traps, the guardians' catch distance).

	YOUR OWN TREADMILL MOUNTS YOU. Walk up to your treadmill and you are set
	on it - the same pivot the Studio command uses - rather than having to
	find the exact spot on the belt. Only the plot's OWNER, only within a
	couple of studs of the trigger's footprint, and never for a moment after
	stepping off, so walking away is possible. A player tumbling from a hit
	is left alone until they are back on their feet.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BaseService = require(script.Parent.BaseService)
local GuardianService = require(script.Parent.GuardianService)
local MovementService = require(script.Parent.MovementService)
local RagdollService = require(script.Parent.RagdollService)
local SpeedService = require(script.Parent.SpeedService)

local LobbyGhostService = {}

--- Seconds between passes. A group swap a fifth of a second late is
--- invisible; running it every frame for every player is not free.
local PASS_INTERVAL = 0.2
--- How far outside the trigger's footprint still counts as touching the
--- treadmill, in studs. The art is walk-through, so this is the whole feel
--- of the snap: too small and the player has to find the belt anyway.
local MOUNT_MARGIN = 3
--- How far above or below the trigger's centre the root may be.
local MOUNT_HEIGHT = 8
--- After stepping off, no re-mount for this long, or the rails a player is
--- walking away through would pull them straight back on.
local DISMOUNT_GRACE = 1.5

local wasOn: { [Player]: boolean } = {}
local steppedOffAt: { [Player]: number } = {}

--- The plot's treadmill trigger, if this player has a plot with one.
local function triggerFor(player: Player): BasePart?
	local plot = BaseService.getPlot(player)
	local treadmill = plot and plot:FindFirstChild("Treadmill")
	local trigger = treadmill and treadmill:FindFirstChild("TrainingTrigger")
	return if trigger and trigger:IsA("BasePart") then trigger else nil
end

local function nearTrigger(root: BasePart, trigger: BasePart): boolean
	local offset = trigger.CFrame:PointToObjectSpace(root.Position)
	local half = trigger.Size / 2
	return math.abs(offset.X) <= half.X + MOUNT_MARGIN
		and math.abs(offset.Z) <= half.Z + MOUNT_MARGIN
		and math.abs(offset.Y) <= MOUNT_HEIGHT
end

local function pass()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
			continue
		end

		-- 1. The group: a ghost in the safe zone, a body everywhere else.
		GuardianService.setLobbyGhost(character, BaseService.isSafePosition(root.Position))

		-- 2. The mount.
		local on = SpeedService.isOnOwnTreadmill(player)
		if wasOn[player] and not on then
			steppedOffAt[player] = now
		end
		wasOn[player] = on
		if on or RagdollService.isImmune(player) or now - (steppedOffAt[player] or 0) < DISMOUNT_GRACE then
			continue
		end
		local trigger = triggerFor(player)
		if trigger and nearTrigger(root, trigger) then
			-- A server pivot of a client-owned body: tell the movement check
			-- it is ours before it measures a jump it did not see coming.
			MovementService.allowTeleport(player, 1)
			character:PivotTo(trigger.CFrame)
			wasOn[player] = true
		end
	end
end

--- Belts and triggers on every plot into the walk-through prop group. Runs
--- at start and again whenever a plot is rebuilt.
local function fileTreadmillProps()
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return
	end
	for _, plot in bases:GetChildren() do
		local treadmill = plot:FindFirstChild("Treadmill")
		if not treadmill then
			continue
		end
		for _, name in { "Belt", "TrainingTrigger" } do
			local part = treadmill:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				part.CollisionGroup = GuardianService.LOBBY_PROP_GROUP
			end
		end
	end
end

-- ==========================================================
-- EVERYTHING IN THE LOBBY IS WALK-THROUGH (2026-09-20)
-- ==========================================================
--
-- The owner: "make everything in the safe zone lobby something I can walk
-- through, except my own treadmill". A player already walks through other
-- players and the treadmill belts; this files every other SOLID PROP behind
-- the red line into the same LOBBY_PROP group - the gadget store, the trail
-- shop, the guardian-shop pedestals, the update stand, the spin wheels, the
-- leaderboards, the base pads and guardian bays, and the treadmill rails. A
-- ghost (a player in the safe zone) passes through all of it; step out into
-- the zones and the group is solid again, exactly like the belts.
--
-- WHAT STAYS SOLID: the floors (they hold the player up), the boundary walls
-- (they keep the player in the map), the zones, and anything tagged with the
-- attribute KeepSolid. The owner's OWN treadmill is not made special here:
-- its belt and trigger were already walk-through and the auto-mount below is
-- what puts the player on it, so it keeps working exactly as before - the
-- rails around it just no longer stop the walk up to it.
local KEEP_SOLID_MAP_ROOTS: { [string]: boolean } = {
	Walls = true, Zones = true, LaneFloors = true, Paving = true, SpawnLocations = true,
}
local KEEP_SOLID_NAMES: { [string]: boolean } = { Slab = true, LobbyFloor = true, PlotFloor = true }
--- Workspace-level lobby models (built outside `Map`), by name prefix.
local LOBBY_MODEL_PREFIXES = { "Spin Wheel System", "Leaderboard " }

local function isLobbyProp(part: BasePart): boolean
	if not part.Anchored or not part.CanCollide or part.CollisionGroup == GuardianService.LOBBY_PROP_GROUP then
		return false
	end
	if part:GetAttribute("KeepSolid") == true or KEEP_SOLID_NAMES[part.Name] then
		return false
	end
	if part.Position.Z >= 0 or part.Position.Z < -260 then
		return false
	end
	if part.Parent and part.Parent:FindFirstChildOfClass("Humanoid") then
		return false
	end
	return true
end

local function fileLobbyProps()
	local map = workspace:FindFirstChild("Map")
	local filed = 0
	if map then
		for _, child in map:GetChildren() do
			if KEEP_SOLID_MAP_ROOTS[child.Name] then
				continue
			end
			local function consider(part: Instance)
				if part:IsA("BasePart") and isLobbyProp(part) then
					part.CollisionGroup = GuardianService.LOBBY_PROP_GROUP
					filed += 1
				end
			end
			consider(child)
			for _, descendant in child:GetDescendants() do
				consider(descendant)
			end
		end
	end
	for _, child in workspace:GetChildren() do
		for _, prefix in LOBBY_MODEL_PREFIXES do
			if string.sub(child.Name, 1, #prefix) == prefix then
				for _, descendant in child:GetDescendants() do
					if descendant:IsA("BasePart") and isLobbyProp(descendant) then
						descendant.CollisionGroup = GuardianService.LOBBY_PROP_GROUP
						filed += 1
					end
				end
				break
			end
		end
	end
	return filed
end

function LobbyGhostService.start()
	fileTreadmillProps()
	fileLobbyProps()
	BaseService.onRebuilt(function(_player: Player)
		fileTreadmillProps()
		fileLobbyProps()
	end)
	-- Stands and shops other services build after this one starts (the event
	-- stand, the guardian shop, the gift chest) are caught by a slow rescan.
	task.spawn(function()
		for _ = 1, 6 do
			task.wait(10)
			fileLobbyProps()
		end
		while true do
			task.wait(60)
			fileLobbyProps()
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		wasOn[player] = nil
		steppedOffAt[player] = nil
	end)

	local since = 0
	RunService.Heartbeat:Connect(function(dt)
		since += dt
		if since < PASS_INTERVAL then
			return
		end
		since = 0
		local ok, err = pcall(pass :: any)
		if not ok then
			warn(`[LobbyGhostService] pass failed: {err}`)
		end
	end)

	print("[LobbyGhostService] walk-through lobby (players, props, rails) and treadmill auto-mount online")
end

return LobbyGhostService
