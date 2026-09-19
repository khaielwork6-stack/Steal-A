--!strict
--[[
	RagdollService
	Shared "get knocked about" effect, used by both a guardian catch and a bat hit.

	Extracted so there is exactly one place that knows how to launch a player.
	Two independent copies of this logic would drift, and the network-ownership
	handling below is subtle enough that duplicating it is asking for trouble.

	Immunity is tracked here too, so a player already tumbling cannot be hit
	again by anything - guardian or bat - until they recover.
]]

local Players = game:GetService("Players")

-- A leaf (config only), so no cycle.
local MovementService = require(script.Parent.MovementService)

local RagdollService = {}

--- Seconds after a launch hands the body back to its client during which the
--- movement check re-bases instead of measuring (the tail of the arc).
local STAND_UP_GRACE = 1.5

export type LaunchOptions = {
	knockback: number,
	lift: number,
	stun: number,
	--- When set, recovery is measured from the moment the player LANDS
	--- rather than from the launch: they stay down for this many seconds
	--- after touching the ground, however long the arc took. `stun` is then
	--- the floor (a minimum airborne time) rather than the whole timer.
	groundStun: number?,
	immunity: number,
}

local immuneUntil: { [Player]: number } = {}

--- Set by init so movement is recomputed from the profile once a root lifts,
--- rather than trusting the value captured when the root began.
local onRootExpired: ((Player) -> ())? = nil

function RagdollService.setMovementRefresher(fn: (Player) -> ())
	onRootExpired = fn
end

--- True while the player is mid-launch or in their recovery window.
function RagdollService.isImmune(player: Player): boolean
	return (immuneUntil[player] or 0) > os.clock()
end

function RagdollService.grantImmunity(player: Player, seconds: number)
	immuneUntil[player] = math.max(immuneUntil[player] or 0, os.clock() + seconds)
end

--- Seconds to keep polling for a landing before giving up and standing the
--- player up anyway. A launch that clears the map (or lands somewhere the
--- raycast never resolves) must not leave anyone face-down forever.
local LANDING_TIMEOUT = 8
--- Below this vertical speed the character is no longer travelling, which
--- separates "resting on the ground" from "skimming it at the top of a bounce".
local LANDED_SPEED = 8
--- How far under the root counts as ground contact.
local LANDED_PROBE = 5

-- ==========================================================
-- NOT THROUGH THE WALL (owner, 2026-09-18)
-- ==========================================================
--
-- Players were being launched THROUGH walls and out of the map. The cause was
-- one line: the launch constraint carried MaxForce = math.huge. A wall stops a
-- character by pushing back, and against an infinite force it cannot - the
-- solver resolves the overlap by moving the body out the far side. A finite
-- cap is plenty to throw someone and lets the wall win the argument.
--
-- Three layers, because one is not enough at point-blank range:
--   1. LAUNCH_MAX_FORCE          a wall can now resist the push at all
--   2. the wall probe            a victim with a wall right behind them is
--                                shoved less hard, so there is nothing to
--                                squeeze them through in the first place
--   3. the recovery net          and if they still end up somewhere with no
--                                ground under them, they are put back where
--                                they were standing when they were hit

--- Enough to fling a character assembly (mass ~15-25) up to speed inside a
--- couple of physics steps, and nowhere near enough to beat a wall.
local LAUNCH_MAX_FORCE = 25000
--- How far along the launch direction a wall counts as point-blank.
local WALL_PROBE = 6
--- The share of the horizontal knockback kept when a wall is that close. The
--- lift is untouched: up is still free, and a victim popped straight up off a
--- wall reads exactly like a victim slammed into it.
local WALL_KNOCKBACK_SCALE = 0.25
--- Below this height there is no map left; anyone here fell out of the world.
local VOID_Y = -60
--- How far down the recovery net looks for ground before calling a position
--- unreachable. Taller than any drop in the museum.
local GROUND_PROBE = 250

--- Resolves once `root` is resting on something, or once LANDING_TIMEOUT has
--- passed. Polled rather than driven by Humanoid.StateChanged: PlatformStand
--- puts the humanoid in Physics for the whole flight, so Landed never fires
--- and FloorMaterial stays Air the entire time.
local function waitForLanding(root: BasePart, minimumAirborne: number)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { root.Parent :: Instance }

	local deadline = os.clock() + LANDING_TIMEOUT
	-- Always spend the minimum in the air, so a player launched into a wall
	-- at point-blank range still gets the arc rather than an instant recovery.
	if minimumAirborne > 0 then
		task.wait(minimumAirborne)
	end
	while os.clock() < deadline do
		if not root.Parent then
			return
		end
		if math.abs(root.AssemblyLinearVelocity.Y) < LANDED_SPEED then
			local hit = workspace:Raycast(root.Position, Vector3.new(0, -LANDED_PROBE, 0), params)
			if hit then
				return
			end
		end
		task.wait(0.1)
	end
end

--- Launches `player` away from `fromPosition`. Returns false when they were
--- already immune, so callers can skip their own side effects.
function RagdollService.launch(player: Player, fromPosition: Vector3, options: LaunchOptions): boolean
	if RagdollService.isImmune(player) then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return false
	end

	RagdollService.grantImmunity(player, options.immunity)
	-- The launch itself is a server move; MovementService also re-bases while
	-- the server owns the body, this covers the frames either side of that.
	MovementService.allowTeleport(player, options.stun + STAND_UP_GRACE)

	local flat = Vector3.new(root.Position.X - fromPosition.X, 0, root.Position.Z - fromPosition.Z)
	local direction = if flat.Magnitude > 0.1 then flat.Unit else root.CFrame.LookVector

	-- WHERE THEY WERE STANDING, kept for the recovery net below. This position
	-- is known-good: they were on their feet on it a moment ago.
	local safeSpot = root.Position

	-- POINT-BLANK: a wall right behind the victim has nowhere to send them, so
	-- most of the shove is dropped and they are popped up off it instead. This
	-- is the case the old infinite force turned into a trip through the wall.
	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Exclude
	probeParams.FilterDescendantsInstances = { character :: Instance }
	local knockback = options.knockback
	if workspace:Raycast(root.Position, direction * WALL_PROBE, probeParams) then
		knockback *= WALL_KNOCKBACK_SCALE
	end

	-- A character is normally network-owned by its client, and a server-side
	-- impulse on a client-owned assembly is discarded. Take ownership for the
	-- launch, then hand it back.
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	-- A plain velocity assignment gets overwritten by the Humanoid on the next
	-- physics step; a short-lived constraint wins. Fixed velocity rather than an
	-- impulse keeps the launch identical regardless of what the avatar wears.
	local attachment = Instance.new("Attachment")
	attachment.Name = "LaunchAttachment"
	attachment.Parent = root

	local push = Instance.new("LinearVelocity")
	push.Attachment0 = attachment
	push.RelativeTo = Enum.ActuatorRelativeTo.World
	push.MaxForce = LAUNCH_MAX_FORCE
	push.VectorVelocity = direction * knockback + Vector3.new(0, options.lift, 0)
	push.Parent = root

	root.AssemblyAngularVelocity = Vector3.new(math.random(-9, 9), math.random(-6, 6), math.random(-9, 9))

	-- Cut the push almost immediately: it sets the launch, gravity does the arc.
	task.delay(0.2, function()
		push:Destroy()
		attachment:Destroy()
	end)

	--- THE RECOVERY NET. A launch that ends with the player somewhere the map
	--- cannot hold them - under the world, or hanging over nothing after
	--- clipping something - puts them back on the spot they were standing on
	--- when they were hit. Cheap (one raycast, once, on stand-up) and it
	--- cannot make things worse: `safeSpot` is a position the player was
	--- demonstrably standing on a second earlier.
	local function rescueIfLost()
		local here = root.Position
		if here.Y < VOID_Y then
			return true
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character :: Instance }
		return workspace:Raycast(here, Vector3.new(0, -GROUND_PROBE, 0), params) == nil
	end

	local function standUp()
		if not humanoid.Parent or humanoid.Health <= 0 then
			return
		end
		-- Ownership goes back to the client while the body may still be
		-- carrying the launch's speed: the rest of that arc is the server's
		-- doing, not a speed hack (security pass B1).
		MovementService.allowTeleport(player, STAND_UP_GRACE)
		if rescueIfLost() then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			root.CFrame = CFrame.new(safeSpot)
		end
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		pcall(function()
			root:SetNetworkOwner(player)
		end)
	end

	if options.groundStun then
		-- Down for a fixed spell AFTER the landing. The flight is not part of
		-- the punishment, so a long arc and a short one cost the same time on
		-- the floor, and immunity is extended to cover however long that took
		-- rather than expiring mid-tumble and letting a second hit chain.
		task.spawn(function()
			waitForLanding(root, options.stun)
			RagdollService.grantImmunity(player, options.groundStun + 0.35)
			task.wait(options.groundStun)
			standUp()
		end)
	else
		task.delay(options.stun, standUp)
	end

	return true
end

--- Roots a player in place without launching them (trap effect).
function RagdollService.root(player: Player, seconds: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local restoreWalk = humanoid.WalkSpeed
	local restoreJump = humanoid.JumpPower
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid:SetAttribute("Rooted", true)

	task.delay(seconds, function()
		if not humanoid.Parent then
			return
		end
		-- Clear the flag FIRST so whatever re-applies movement next is allowed to.
		humanoid:SetAttribute("Rooted", nil)
		humanoid.WalkSpeed = restoreWalk
		humanoid.JumpPower = restoreJump

		if onRootExpired then
			onRootExpired(player)
		end
	end)
end

function RagdollService.start()
	Players.PlayerRemoving:Connect(function(player)
		immuneUntil[player] = nil
	end)
end

return RagdollService
