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

function LobbyGhostService.start()
	fileTreadmillProps()
	BaseService.onRebuilt(function(_player: Player)
		fileTreadmillProps()
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

	print("[LobbyGhostService] walk-through lobby and treadmill auto-mount online")
end

return LobbyGhostService
