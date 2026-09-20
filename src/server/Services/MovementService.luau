--!strict
--[[
	MovementService
	Server-side movement validation (security pass B1).

	WHY THIS EXISTS. A Roblox character is simulated by its own client, and the
	server simply believes the position that client reports. Every "is the
	player home?" question in this game (CarryService delivery, placement,
	BaseService.isInOwnSafeZone) is answered from that position, so a client
	that teleported or speed-hacked home with loot skipped the guards, the
	lasers and the whole escape. Nothing here can stop a client from LYING
	about where it is; it can notice that the lie is physically impossible
	and refuse to act on it.

	THE MODEL is a movement budget, described in SecurityConfig. In short: a
	player may spend (server-set WalkSpeed x tolerance) studs per second, may
	bank a short burst of it for network stalls, and anything beyond that is
	a strike. Enough strikes snap the character back to the last position
	that passed (`trustedPosition`) and drop whatever it was carrying, through
	the ordinary CarryService drop path (injected, see setViolationHandler).
	Nobody is ever kicked by this.

	THE SPEED IS THE SERVER'S OWN. `noteSpeed` is called by
	CarryService.applyMovement - the one writer of a player's WalkSpeed - with
	the value it just set. Humanoid.WalkSpeed itself is never read here: a
	client can change its local copy and the server would never know.

	LEGITIMATE SERVER MOVES. Every server-side teleport of a character calls
	`allowTeleport` first (BaseService.teleportHome and assign, the respawn
	placement in init.server, NightService's return to the lobby). A character
	whose physics the SERVER is simulating (a ragdoll launch hands network
	ownership to the server), a seated humanoid, and a
	freshly spawned character are re-based rather than measured: the server's
	own physics is not something a client can fake.

	STUDIO. DebugService moves characters with PivotTo and may not be edited
	by this pass, so in Studio ONLY a script-set change of the root's CFrame is
	treated as a server teleport (a client's own movement reaches the server as
	physics replication, which does not fire property-changed signals). Live
	servers rely solely on the explicit allowTeleport calls. `setExempt` is the
	Studio switch the test runners use (MuseumTests), like LaserService's.

	A LEAF MODULE: config only, no service requires. CarryService,
	BaseService and PvPService all require this, so it must never require them.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SecurityConfig = require(ReplicatedStorage.Shared.Config.SecurityConfig)

local MovementService = {}

type SpeedEntry = { at: number, speed: number, base: number }

type Track = {
	character: Model,
	--- The last position that passed the check. Every measurement is taken
	--- from here, and it is what a violation snaps the character back to.
	reference: Vector3,
	trustedAt: number,
	lastSample: number,
	--- Horizontal studs the player may still cover (see SecurityConfig).
	budget: number,
	--- Upward studs the player may still climb.
	rise: number,
	strikes: number,
	--- Re-base instead of measuring until this os.clock (spawn, teleport).
	graceUntil: number,
	--- Ignore samples until this os.clock (right after a snap-back).
	settleUntil: number,
}

local IS_STUDIO = RunService:IsStudio()

local tracks: { [Player]: Track? } = {}
local speedHistory: { [Player]: { SpeedEntry }? } = {}
local exempt: { [Player]: boolean? } = {}
--- os.clock of the last server-side move of this player's character that was
--- detected automatically (Studio only; see the header).
local serverMovedAt: { [Player]: number? } = {}
--- Pending allowTeleport windows for a character that has not been sampled
--- yet (the call can land before the first sample of a new character).
local teleportUntil: { [Player]: number? } = {}
--- Until when this service's OWN pivots of a character must not be read as
--- a debug teleport (its snap-back, and the simulated client move). A window,
--- not a flag: under deferred signal behaviour the root's CFrame-changed
--- handler runs AFTER the pivot call has returned, so a flag cleared right
--- after PivotTo was always already clear and every simulated cheat was
--- "trusted".
local ownPivotUntil: { [Player]: number? } = {}
local OWN_PIVOT_WINDOW = 0.25

local metrics = {
	samples = 0,
	violations = 0,
	autoTrustedPivots = 0,
	lastViolation = "",
}
local violationsByPlayer: { [Player]: number? } = {}

local onViolation: (Player, Vector3) -> () = function() end

--- Called after a snap-back with the position the character was returned to.
--- init wires CarryService.forceDrop here so a carried item falls at the
--- trusted position (the character has already been moved there).
function MovementService.setViolationHandler(fn: (Player, Vector3) -> ())
	onViolation = fn
end

-- ==========================================================
-- SPEED RECORD
-- ==========================================================

local function prune(history: { SpeedEntry }, now: number)
	-- Keep the newest entry that is older than the window: it is the value
	-- that was in effect at the start of the window.
	local cutoff = now - SecurityConfig.SPEED_HISTORY_SECONDS
	while #history > 1 and history[2].at <= cutoff do
		table.remove(history, 1)
	end
end

--- Records the WalkSpeed the server just gave this player. `base` is the same
--- value WITHOUT the carry penalty or the crouch cost - the fastest the player
--- could move if they put the item down - used for delivery timing.
function MovementService.noteSpeed(player: Player, speed: number, base: number?)
	local history: { SpeedEntry } = speedHistory[player] or {}
	speedHistory[player] = history
	local last: SpeedEntry? = history[#history]
	local baseSpeed = math.max(base or speed, speed)
	-- COALESCED. Treadmill training nudges the speed on every tick; one entry
	-- per nudge would be thousands of rows a session. A change this small is
	-- folded into the last row, keeping the HIGHER value - that only ever
	-- makes the check more forgiving, never stricter.
	if last and math.abs(last.speed - speed) < 0.5 and math.abs(last.base - baseSpeed) < 0.5 then
		last.speed = math.max(last.speed, speed)
		last.base = math.max(last.base, baseSpeed)
		return
	end
	local now = os.clock()
	table.insert(history, { at = now, speed = speed, base = baseSpeed })
	prune(history, now)
end

--- The fastest server-set speed in effect at any moment since `since`
--- (os.clock). `useBase` reads the unencumbered speed instead.
function MovementService.peakSpeedSince(player: Player, since: number, useBase: boolean?): number
	local history = speedHistory[player]
	local peak = 0
	if history then
		-- Newest first: every entry that began after `since`, plus the one that
		-- was already in effect at `since`, then stop. Sorted by time, so this
		-- only ever walks the recent tail.
		for index = #history, 1, -1 do
			local entry = history[index]
			peak = math.max(peak, if useBase then entry.base else entry.speed)
			if entry.at <= since then
				break
			end
		end
	end
	if peak <= 0 then
		peak = SecurityConfig.MOVEMENT_DEFAULT_SPEED
	end
	return peak
end

-- ==========================================================
-- EXEMPTIONS
-- ==========================================================

--- A legitimate server-side move is about to happen (or just happened): the
--- character is re-based rather than measured for `seconds`.
function MovementService.allowTeleport(player: Player, seconds: number?)
	local untilTime = os.clock() + (seconds or SecurityConfig.MOVEMENT_TELEPORT_GRACE)
	teleportUntil[player] = math.max(teleportUntil[player] or 0, untilTime)
	local track = tracks[player]
	if track then
		track.graceUntil = math.max(track.graceUntil, untilTime)
		track.strikes = 0
	end
end

-- ==========================================================
-- SERVER-GRANTED BURSTS (gadgets-patrols area)
-- ==========================================================
--
-- A server-applied pull (the Grappling Hook) moves the character faster than
-- its WalkSpeed while the CLIENT still owns and simulates it, so it is not a
-- teleport (no re-base: the path is still measured) and not serverDriven.
-- `allowBurst` widens the budget for a short window instead: the refill rate,
-- the cap and the climb rate all get `extraSpeed` studs/s on top, so the pull
-- is paid for and anything beyond it is still a strike.

type Burst = { from: number, untilTime: number, extra: number }
local bursts: { [Player]: Burst? } = {}

--- Adds `extraSpeed` studs/s to this player's movement budget for `seconds`.
--- Overlapping calls keep the larger extra and the later end.
function MovementService.allowBurst(player: Player, extraSpeed: number, seconds: number)
	if type(extraSpeed) ~= "number" or type(seconds) ~= "number" or extraSpeed ~= extraSpeed or seconds ~= seconds then
		return
	end
	local now = os.clock()
	local extra = math.clamp(extraSpeed, 0, 500)
	local untilTime = now + math.clamp(seconds, 0, 5)
	local current = bursts[player]
	if current and current.untilTime > now then
		current.extra = math.max(current.extra, extra)
		current.untilTime = math.max(current.untilTime, untilTime)
	else
		bursts[player] = { from = now, untilTime = untilTime, extra = extra }
	end
end

--- The burst extra (studs/s) in effect at any moment in [since, now].
local function burstExtraSince(player: Player, since: number): number
	local burst = bursts[player]
	if not burst then
		return 0
	end
	if burst.untilTime < since then
		-- Long over: forget it so the table stays small.
		if os.clock() - burst.untilTime > 5 then
			bursts[player] = nil
		end
		return 0
	end
	return burst.extra
end

--- DISTANCE CREDIT (round3-gameplay). A carrier may now grapple, and the
--- delivery timer (CarryService) assumes every stud was run on foot. The pull
--- logs the exact distance the SERVER chose; `creditSince` sums what was
--- logged after a given moment, so the timer can take it off the run.
type Credit = { at: number, studs: number }
local credits: { [Player]: { Credit } } = {}
local CREDIT_KEEP = 600

function MovementService.creditDistance(player: Player, studs: number)
	if type(studs) ~= "number" or studs ~= studs or studs <= 0 then
		return
	end
	local now = os.clock()
	local list = credits[player] or {}
	credits[player] = list
	table.insert(list, { at = now, studs = math.min(studs, 500) })
	while #list > 0 and (now - list[1].at > CREDIT_KEEP or #list > 32) do
		table.remove(list, 1)
	end
end

--- Studs credited since `since` (os.clock).
function MovementService.creditSince(player: Player, since: number): number
	local list = credits[player]
	local total = 0
	if list then
		for _, entry in list do
			if entry.at >= since then
				total += entry.studs
			end
		end
	end
	return total
end

--- Studio only (ignored live, like LaserService.setExempt): the test runners
--- move the character around with PivotTo and MoveTo and must not be judged.
function MovementService.setExempt(player: Player, on: boolean)
	if IS_STUDIO then
		exempt[player] = if on then true else nil
	end
end

function MovementService.isExempt(player: Player): boolean
	return exempt[player] == true
end

--- Studio only: whether a server-side move of this character was detected
--- since `since` (os.clock). CarryService uses it to waive the delivery timer
--- for DebugService's "steal then goHome" flow. Always false live, where no
--- legitimate server teleport ever happens while carrying (the portal and the
--- BASE button refuse a carrier, the Night cancels the carry first).
function MovementService.serverMovedSince(player: Player, since: number): boolean
	if not IS_STUDIO then
		return false
	end
	return exempt[player] == true or (serverMovedAt[player] or -math.huge) >= since
end

--- True when the server itself is simulating this body, or the humanoid is in
--- a state the client does not steer: its position is not the client's claim.
local function serverDriven(root: BasePart, humanoid: Humanoid): boolean
	-- NOT Humanoid.PlatformStand (2026-09-20). A client can set that on its
	-- own character, and doing so used to switch this whole check off. A real
	-- ragdoll does not need it: RagdollService.launch hands the body to the
	-- server (owner == nil below) and calls allowTeleport either side of it.
	if humanoid.SeatPart ~= nil then
		return true
	end
	local ok, owner = pcall(function()
		return root:GetNetworkOwner()
	end)
	-- Anchored (the call errors) or server-owned (nil): not the client's move.
	return not ok or owner == nil
end

-- ==========================================================
-- SAMPLING
-- ==========================================================

local function bodyOf(player: Player): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return nil, nil, nil
	end
	return character, root, humanoid
end

local function rebase(track: Track, position: Vector3, now: number)
	track.reference = position
	track.trustedAt = now
	track.strikes = 0
	track.budget = 0
	track.rise = 0
end

--- Studio only: a script-set CFrame on the root is a server teleport.
local function watchPivots(player: Player, root: BasePart)
	if not IS_STUDIO then
		return
	end
	root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if os.clock() < (ownPivotUntil[player] or 0) or not MovementService.debugAutoTrust() then
			return
		end
		metrics.autoTrustedPivots += 1
		serverMovedAt[player] = os.clock()
		MovementService.allowTeleport(player, 1)
	end)
end

local function violate(player: Player, track: Track, character: Model, root: BasePart, excess: number, now: number)
	metrics.violations += 1
	local count = (violationsByPlayer[player] or 0) + 1
	violationsByPlayer[player] = count
	local target = track.reference
	local message = string.format(
		"%s moved %.0f studs beyond their budget near (%.0f, %.0f, %.0f); snapped back (violation #%d)",
		player.Name,
		excess,
		root.Position.X,
		root.Position.Y,
		root.Position.Z,
		count
	)
	metrics.lastViolation = message
	warn("[MovementService] " .. message)

	ownPivotUntil[player] = os.clock() + OWN_PIVOT_WINDOW
	local ok, err = pcall(function()
		character:PivotTo(CFrame.new(target) * root.CFrame.Rotation)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end)
	ownPivotUntil[player] = os.clock() + OWN_PIVOT_WINDOW
	if not ok then
		warn(`[MovementService] snap-back failed for {player.Name}: {err}`)
	end

	track.strikes = 0
	track.budget = 0
	track.rise = 0
	track.settleUntil = now + SecurityConfig.MOVEMENT_SNAP_SETTLE

	-- The drop happens AFTER the move, so the item lands at the trusted spot.
	local handled, handlerErr = pcall(function()
		onViolation(player, target)
		return true
	end)
	if not handled then
		warn(`[MovementService] violation handler failed for {player.Name}: {handlerErr}`)
	end
end

local function sample(player: Player, now: number)
	local character, root, humanoid = bodyOf(player)
	if not character or not root or not humanoid then
		tracks[player] = nil
		return
	end

	local track = tracks[player]
	if not track or track.character ~= character then
		track = {
			character = character,
			reference = root.Position,
			trustedAt = now,
			lastSample = now,
			budget = 0,
			rise = 0,
			strikes = 0,
			graceUntil = math.max(now + SecurityConfig.MOVEMENT_SPAWN_GRACE, teleportUntil[player] or 0),
			settleUntil = 0,
		}
		tracks[player] = track
		watchPivots(player, root)
		return
	end

	local dt = now - track.lastSample
	track.lastSample = now
	if dt <= 0 then
		return
	end
	metrics.samples += 1

	if now < track.settleUntil then
		return
	end

	local position = root.Position
	if
		not SecurityConfig.MOVEMENT_ENABLED
		or exempt[player]
		or now < track.graceUntil
		or now < (teleportUntil[player] or 0)
		or serverDriven(root, humanoid)
	then
		rebase(track, position, now)
		return
	end

	local rate = MovementService.peakSpeedSince(player, now - dt) * SecurityConfig.MOVEMENT_SPEED_TOLERANCE
		+ burstExtraSince(player, now - dt) -- a granted pull (allowBurst)
	local cap = rate * SecurityConfig.MOVEMENT_BURST_SECONDS + SecurityConfig.MOVEMENT_SLACK_STUDS
	track.budget = math.min(cap, track.budget + rate * dt)
	local riseRate = SecurityConfig.MOVEMENT_RISE_SPEED + rate
	-- Capped at the slack plus two samples' worth of climbing, so a fast player
	-- taking stairs is never over budget on a single sample.
	local riseCap = SecurityConfig.MOVEMENT_RISE_SLACK_STUDS + riseRate * SecurityConfig.MOVEMENT_SAMPLE_INTERVAL * 2
	track.rise = math.min(riseCap, track.rise + riseRate * dt)

	local offset = position - track.reference
	local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
	-- Falling is free; only climbing spends the rise budget.
	local up = math.max(0, offset.Y)
	local excess = math.max(0, flat - track.budget) + math.max(0, up - track.rise)

	if excess <= 0 then
		track.budget -= flat
		track.rise -= up
		track.reference = position
		track.trustedAt = now
		track.strikes = math.max(0, track.strikes - SecurityConfig.MOVEMENT_STRIKE_DECAY * dt)
		return
	end

	-- Over budget. The reference stays where it was, so a teleport keeps
	-- failing on every sample until it is snapped back, while a jittery
	-- sample a few studs over passes again as soon as the budget refills.
	track.strikes += excess / SecurityConfig.MOVEMENT_STRIKE_STUDS
	if track.strikes >= SecurityConfig.MOVEMENT_STRIKE_LIMIT then
		violate(player, track, character, root, excess, now)
	end
end

-- ==========================================================
-- QUERIES
-- ==========================================================

--- The last position of this player's character that passed the movement
--- check. Nil only when there is no live character at all. Before the first
--- sample (and with the detector switched off) it is the current position.
function MovementService.trustedPosition(player: Player): Vector3?
	local character, root = bodyOf(player)
	if not character or not root then
		return nil
	end
	local track = tracks[player]
	if not SecurityConfig.MOVEMENT_ENABLED or not track or track.character ~= character or exempt[player] then
		return root.Position
	end
	return track.reference
end

--- The current position when it is consistent with the trusted one (within
--- what the player could have covered since), else the trusted position. For
--- range checks that want the live position without trusting a teleport.
function MovementService.verifiedPosition(player: Player): Vector3?
	local character, root = bodyOf(player)
	if not character or not root then
		return nil
	end
	local track = tracks[player]
	if not SecurityConfig.MOVEMENT_ENABLED or not track or track.character ~= character or exempt[player] then
		return root.Position
	end
	local now = os.clock()
	local rate = MovementService.peakSpeedSince(player, track.trustedAt) * SecurityConfig.MOVEMENT_SPEED_TOLERANCE
		+ burstExtraSince(player, track.trustedAt)
	local allowed = rate * (now - track.trustedAt + SecurityConfig.MOVEMENT_BURST_SECONDS) + SecurityConfig.MOVEMENT_SLACK_STUDS
	local offset = root.Position - track.reference
	if Vector3.new(offset.X, 0, offset.Z).Magnitude <= allowed then
		return root.Position
	end
	return track.reference
end

--- Treats the player as having failed the check right now: snap back to the
--- trusted position and run the violation handler. Used by CarryService when
--- a delivery arrives faster than any legal run could have.
function MovementService.flag(player: Player, reason: string)
	local character, root = bodyOf(player)
	local track = tracks[player]
	if not character or not root or not track or track.character ~= character or exempt[player] then
		return
	end
	warn(`[MovementService] {player.Name} flagged: {reason}`)
	violate(player, track, character, root, 0, os.clock())
end

-- ==========================================================
-- STUDIO TEST HOOKS (DebugCommands/Security)
-- ==========================================================

local autoTrust = true

--- Studio only. Moves the character the way a CHEATING CLIENT would: the
--- automatic "script-set CFrame = server teleport" rule is suppressed for this
--- one move, so the next samples judge it like any client claim.
function MovementService.debugSimulateClientMove(player: Player, target: CFrame): boolean
	local character = player.Character
	if not IS_STUDIO or not character then
		return false
	end
	ownPivotUntil[player] = os.clock() + OWN_PIVOT_WINDOW
	local ok = pcall(function()
		character:PivotTo(target)
	end)
	ownPivotUntil[player] = os.clock() + OWN_PIVOT_WINDOW
	return ok
end

--- Studio only. Switches the automatic pivot trust off, so a test can prove
--- that an explicit allowTeleport call alone keeps a server teleport legal.
function MovementService.debugSetAutoTrust(on: boolean)
	if IS_STUDIO then
		autoTrust = on
	end
end

function MovementService.debugAutoTrust(): boolean
	return autoTrust
end

--- Debug/reporting.
function MovementService.snapshot(player: Player?): { [string]: any }
	local out: { [string]: any } = table.clone(metrics)
	out.enabled = SecurityConfig.MOVEMENT_ENABLED
	if player then
		local track = tracks[player]
		out.player = {
			exempt = exempt[player] == true,
			violations = violationsByPlayer[player] or 0,
			speed = MovementService.peakSpeedSince(player, os.clock()),
			baseSpeed = MovementService.peakSpeedSince(player, os.clock(), true),
			strikes = if track then track.strikes else nil,
			budget = if track then track.budget else nil,
			trusted = if track then tostring(track.reference) else nil,
			trustedAge = if track then os.clock() - track.trustedAt else nil,
			inGrace = if track then os.clock() < track.graceUntil else nil,
		}
	end
	return out
end

-- ==========================================================
-- START
-- ==========================================================

function MovementService.start()
	Players.PlayerRemoving:Connect(function(player)
		tracks[player] = nil
		speedHistory[player] = nil
		exempt[player] = nil
		serverMovedAt[player] = nil
		teleportUntil[player] = nil
		ownPivotUntil[player] = nil
		violationsByPlayer[player] = nil
		bursts[player] = nil
		credits[player] = nil
	end)

	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated < SecurityConfig.MOVEMENT_SAMPLE_INTERVAL then
			return
		end
		accumulated = 0
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			-- One player's broken character must never stop the others.
			local ok, err = pcall(function()
				sample(player, now)
				return true
			end)
			if not ok then
				warn(`[MovementService] sample failed for {player.Name}: {err}`)
			end
		end
	end)

	print(`[MovementService] movement validation {if SecurityConfig.MOVEMENT_ENABLED then "online" else "DISABLED"}`)
end

return MovementService
