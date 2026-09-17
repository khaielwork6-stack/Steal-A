--!strict
--[[
	SecurityConfig
	Every number the server-side anti-cheat and the gameplay hardening pass
	(docs/handoff-parts/security-gameplay.md) are tuned by, in one place so a
	false positive can be loosened without reading the services.

	THE MOVEMENT MODEL (MovementService). Roblox characters are simulated by
	their own client, so the server only ever sees where a client SAYS it is.
	The check is a budget, not a per-frame speed limit:

	  * Every player holds a budget of studs. It refills at
	        (server-set WalkSpeed) x MOVEMENT_SPEED_TOLERANCE  studs per second
	    and is capped at MOVEMENT_BURST_SECONDS of that, plus
	    MOVEMENT_SLACK_STUDS. Moving spends it.
	  * A network stall followed by a burst of catch-up packets is paid for by
	    the budget that built up during the stall - that is why it is a bucket.
	    A teleport, or a sustained speed hack, drains it and keeps going.
	  * Distance beyond the budget becomes STRIKES (one per
	    MOVEMENT_STRIKE_STUDS of excess). Strikes decay while the player moves
	    legitimately. MOVEMENT_STRIKE_LIMIT strikes snap the character back to
	    the last trusted position and drop whatever it carries. Never a kick.

	Anything a real player can do inside MOVEMENT_SPEED_TOLERANCE is, by
	design, not detected: this catches teleports and real speed hacks, not a
	client that is 20% fast.
]]

local SecurityConfig = {}

-- ==========================================================
-- MOVEMENT ANTI-CHEAT (MovementService)
-- ==========================================================

--- Master switch. False turns the detector into a no-op (trusted position is
--- then simply the current position) without touching any caller.
SecurityConfig.MOVEMENT_ENABLED = true
--- Seconds between samples. 10 Hz is plenty: the budget model does not care
--- how the distance is split between samples.
SecurityConfig.MOVEMENT_SAMPLE_INTERVAL = 0.1
--- Multiplier on the server-set WalkSpeed a client may actually cover.
--- Covers humanoid acceleration quirks, slopes and timestamp noise.
SecurityConfig.MOVEMENT_SPEED_TOLERANCE = 1.35
--- The budget cap, in seconds of movement at the tolerated speed. This is the
--- longest network stall whose catch-up burst is forgiven in one go.
SecurityConfig.MOVEMENT_BURST_SECONDS = 0.6
--- Flat studs added to the cap: a root bobbing on a step, a jump's drift.
SecurityConfig.MOVEMENT_SLACK_STUDS = 8
--- Upward budget. Falling is always free; climbing refills at this many
--- studs/s plus the player's own WalkSpeed (a ramp is climbed at walk pace).
SecurityConfig.MOVEMENT_RISE_SPEED = 40
--- Upward budget cap: a full jump (about 7.2 studs at JumpPower 50) and a
--- step with room to spare. Two samples' worth of climbing is added on top
--- (MovementService), so fast players on stairs are not over budget.
SecurityConfig.MOVEMENT_RISE_SLACK_STUDS = 12
--- Studs of excess per strike. A 1000-stud teleport is fifty strikes at once;
--- a jittery sample a few studs over is a small fraction of one.
SecurityConfig.MOVEMENT_STRIKE_STUDS = 20
--- Strikes that trigger the snap-back.
SecurityConfig.MOVEMENT_STRIKE_LIMIT = 3
--- Strikes forgiven per second of legitimate movement.
SecurityConfig.MOVEMENT_STRIKE_DECAY = 1
--- Seconds after a character appears during which the server's own spawn
--- placement (init.server, BaseService.assign) is not measured.
SecurityConfig.MOVEMENT_SPAWN_GRACE = 2
--- Default window for MovementService.allowTeleport.
SecurityConfig.MOVEMENT_TELEPORT_GRACE = 1.5
--- After a snap-back, samples are ignored for this long so the client's
--- stale packets (sent before it saw the snap) are not strikes of their own.
SecurityConfig.MOVEMENT_SNAP_SETTLE = 0.5
--- The speed assumed before the server has set one (StarterPlayer default).
SecurityConfig.MOVEMENT_DEFAULT_SPEED = 16
--- How long server-set speed changes are remembered, so "the fastest this
--- player could have been going since the steal" survives a trail swap.
SecurityConfig.SPEED_HISTORY_SECONDS = 15 * 60

-- ==========================================================
-- DELIVERY (CarryService)
-- ==========================================================

--- A carry may only be delivered once enough time has passed to cover the
--- straight line from where it was picked up to where it is delivered at
--- (fastest server-set speed since the pickup) x this tolerance...
SecurityConfig.DELIVERY_SPEED_TOLERANCE = 1.35
--- ...minus this many seconds, which covers the client being ahead of the
--- server by its ping at the moment of the steal.
SecurityConfig.DELIVERY_SLACK_SECONDS = 1.5

-- ==========================================================
-- LASERS (LaserService)
-- ==========================================================

--- WalkSpeed multiplier while the server has accepted a crouch. Crouching
--- lets a player pass under high beams, so it must cost something.
SecurityConfig.CROUCH_SPEED_MULTIPLIER = 0.6

-- ==========================================================
-- GUARDS (GuardianService)
-- ==========================================================

--- A laser-triggered chase (the guard woke on a beam, not on stolen loot)
--- gives up after this many seconds. A chase over real stolen loot is still
--- ended only by the red line, a catch or the loot leaving the thief.
SecurityConfig.LASER_CHASE_TIMEOUT = 25

-- ==========================================================
-- BASE STEALING (HeistService)
-- ==========================================================

--- A saved PendingSteal older than this (os.time seconds) is ignored and
--- cleared: a receipt matching it is reported "undeliverable".
SecurityConfig.HEIST_PENDING_EXPIRY = 10 * 60
--- When a steal receipt is delivered the buyer must be within
--- HeistConfig.PROMPT_RANGE x this of the victim's slot.
SecurityConfig.HEIST_DELIVERY_RANGE_FACTOR = 2.5
--- How often stale robbery-cooldown entries are pruned.
SecurityConfig.HEIST_PRUNE_INTERVAL = 60

-- ==========================================================
-- REQUEST LIMITS
-- ==========================================================

--- TrailRequest "sync" / "equip": each one forces a full state push.
SecurityConfig.TRAIL_SYNC_PER_SECOND = 2
--- The base slot prompt (place / store / reveal / Instant Reveal).
SecurityConfig.SLOT_PROMPT_PER_SECOND = 3

return SecurityConfig
