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

local RagdollService = {}

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

	local flat = Vector3.new(root.Position.X - fromPosition.X, 0, root.Position.Z - fromPosition.Z)
	local direction = if flat.Magnitude > 0.1 then flat.Unit else root.CFrame.LookVector

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
	push.MaxForce = math.huge
	push.VectorVelocity = direction * options.knockback + Vector3.new(0, options.lift, 0)
	push.Parent = root

	root.AssemblyAngularVelocity = Vector3.new(math.random(-9, 9), math.random(-6, 6), math.random(-9, 9))

	-- Cut the push almost immediately: it sets the launch, gravity does the arc.
	task.delay(0.2, function()
		push:Destroy()
		attachment:Destroy()
	end)

	local function standUp()
		if not humanoid.Parent or humanoid.Health <= 0 then
			return
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
