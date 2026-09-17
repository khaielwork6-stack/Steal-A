--!strict
--[[
	WorldLootFxController
	Every piece of loot sitting in a zone socket is alive: a slow turn and a
	gentle hover for the ordinary sizes. Client-side and cosmetic, like the base displays
	(DisplayFxController): forty-eight sockets animated here cost the server
	nothing and replicate nothing.

	HOW IT STAYS HONEST WITH THE SERVER
	The server owns where loot IS. This only ever moves a model that is sitting
	anchored in its socket, by a small offset from the pivot the server gave it,
	and it stops the moment the model leaves the socket (a steal re-parents it
	to the thief; a refresh destroys it). Loot models stream atomically
	(LootModel.build), so a model is never pivoted while half of it has yet to
	arrive.

	WHAT MOVES AND HOW MUCH
	    turn   0.5 rad/s, divided by the square root of the item's size so a
	           Colossal revolves with the weight it should have
	    hover  0.22 studs at ~0.55 Hz, only up to the carry knee (2.6x); giants
	           sit still and merely turn
	    (the neon ring that used to sit under each crate is gone: with the
	    reward hidden it could only ever be one colour, and the pads it sat
	    on are no longer drawn)
	EVERY socket turns, always, and the angle is a function of the clock -
	phase + rate x elapsed - rather than a counter that only advances while
	the camera is close. That is what makes the motion continuous from any
	distance: a crate seen from across the map is at exactly the angle it
	would have reached had it been watched the whole time, so there is no
	frozen pose and no jump when it is approached. Forty-eight pivots a frame
	is nothing - and now: crates near the camera move every frame, far ones
	every CLIENT_FAR_MOTION_INTERVAL, all in one workspace:BulkMoveTo
	(PivotBatch). Reduced Effects keeps the turn and drops the hover;
	Graphics LOW stops the turn too.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local PivotBatch = require(ReplicatedStorage.Shared.Util.PivotBatch)

local WorldLootFxController = {}

--- Crates within this radius of the camera move every frame (and hover);
--- farther ones are re-posed every FAR_INTERVAL seconds. See GameConfig.
local CULL_RADIUS = GameConfig.CLIENT_MOTION_CULL_RADIUS
local FAR_INTERVAL = GameConfig.CLIENT_FAR_MOTION_INTERVAL
local CULL_INTERVAL = 0.5

--- Base turn rate (radians per second) for a 1x item.
local TURN_RATE = 0.5
--- Hover amplitude (studs) and angular frequency.
local HOVER_AMPLITUDE = 0.22
local HOVER_RATE = 3.4
--- Items above this visual scale do not hover (matches the carry knee).
local HOVER_MAX_SCALE = RarityConfig.CARRY_SCALE_KNEE
--- How long after a model appears before it is touched: lets the whole
--- replicated hierarchy land so the rest pose captured is the true one.
local SETTLE_SECONDS = 0.5


type Entry = {
	model: Model,
	socket: BasePart,
	base: CFrame?,
	readyAt: number,
	--- The angle at t = 0 (os.clock zero). Chosen when the rest pose is
	--- captured so that the FIRST animated frame is the authored pose itself:
	--- the crate turns away from where it stands rather than jumping to a
	--- random angle when its animation begins.
	phase: number,
	--- Same idea for the hover: aligned so the first frame sits at zero lift.
	hoverPhase: number,
	--- Radians per second. The angle at any moment is phase + turn x clock.
	turn: number,
	hover: number,
	--- Within CLIENT_MOTION_CULL_RADIUS of the camera at the last cull.
	near: boolean,
	--- os.clock() at which a FAR crate is next re-posed.
	nextFarMove: number,
	--- Part offsets for the batched move (PivotBatch).
	cache: PivotBatch.Cache,
	ancestry: RBXScriptConnection?,
}

local entries: { [Model]: Entry } = {}
local reducedEffects = false
local batch = PivotBatch.newBatch()
local lastCull = 0

function WorldLootFxController.setReducedEffects(value: boolean)
	reducedEffects = value
end

-- ==========================================================
-- REGISTRY
-- ==========================================================

local function isSocket(instance: Instance?): boolean
	return instance ~= nil
		and instance:IsA("BasePart")
		and string.match(instance.Name, "^Socket%d%d$") ~= nil
		and instance.Parent ~= nil
		and instance.Parent.Name == "SpawnSockets"
end

local function unregister(model: Model)
	local entry = entries[model]
	if entry then
		PivotBatch.release(entry.cache)
		if entry.ancestry then
			entry.ancestry:Disconnect()
		end
	end
	entries[model] = nil
end

local function register(model: Model)
	if entries[model] or model:GetAttribute("LootId") == nil then
		return
	end
	local socket = model.Parent
	if not socket or not socket:IsA("BasePart") or not isSocket(socket) then
		return
	end
	local scale = tonumber(model:GetAttribute("VisualScale")) or 1
	local entry: Entry = {
		model = model,
		socket = socket,
		base = nil,
		readyAt = os.clock() + SETTLE_SECONDS,
		phase = 0,
		hoverPhase = 0,
		turn = TURN_RATE / math.sqrt(math.max(scale, 1)),
		hover = if scale <= HOVER_MAX_SCALE then HOVER_AMPLITUDE else 0,
		near = true,
		nextFarMove = os.clock() + math.random() * FAR_INTERVAL,
		cache = PivotBatch.newCache(model),
		ancestry = nil,
	}
	entries[model] = entry

	-- The moment it leaves its socket (stolen, refreshed, destroyed) it is the
	-- server's again. Unregistered synchronously, before any later frame could
	-- move a carried crate back to its socket pose.
	entry.ancestry = model.AncestryChanged:Connect(function()
		if model.Parent ~= socket then
			unregister(model)
		end
	end)
end

-- ==========================================================
-- FRAME
-- ==========================================================

local function cull(cameraPosition: Vector3)
	for _, entry in entries do
		entry.near = (entry.socket.Position - cameraPosition).Magnitude <= CULL_RADIUS
	end
end

local function step()
	local now = os.clock()
	local camera = workspace.CurrentCamera
	if camera and now - lastCull >= CULL_INTERVAL then
		lastCull = now
		cull(camera.CFrame.Position)
	end
	-- Graphics LOW: crates hold their pose (see DisplayFxController).
	local frozen = Effects.isLowGraphics()
	local reduced = reducedEffects or Effects.isReduced()

	for model, entry in entries do
		if not model.Parent then
			unregister(model)
			continue
		end
		if frozen or now < entry.readyAt then
			continue
		end
		-- Far crates are re-posed on a staggered, slower schedule; the angle is
		-- still read off the clock, so they never freeze or snap.
		if not entry.near then
			if now < entry.nextFarMove then
				continue
			end
			entry.nextFarMove = now + FAR_INTERVAL
		end
		if not entry.base then
			if not model.PrimaryPart then
				continue
			end
			entry.base = model:GetPivot()
			-- Continuous from the very first frame: no offset now, so no jump.
			entry.phase = -entry.turn * now
			entry.hoverPhase = -now * HOVER_RATE - math.pi / 2
		end
		-- Clock-derived, never accumulated: the same frame at the same
		-- moment whether this crate has been on screen for an hour or has
		-- just come into view.
		local angle = entry.phase + entry.turn * now
		local lift = 0
		if not reduced and entry.near and entry.hover > 0 then
			lift = (math.sin(now * HOVER_RATE + entry.hoverPhase) + 1) * 0.5 * entry.hover
		end
		local base = entry.base :: CFrame
		PivotBatch.queue(batch, model, entry.cache, base * CFrame.Angles(0, angle, 0) + Vector3.new(0, lift, 0))
	end

	-- One engine call for every crate moved this frame.
	if not PivotBatch.flush(batch) then
		for _, entry in entries do
			entry.cache.dirty = true
		end
	end
end

-- ==========================================================
-- START
-- ==========================================================

function WorldLootFxController.start()
	local map = workspace:WaitForChild("Map", 30)
	local zones = map and map:WaitForChild("Zones", 10)
	if not zones then
		return
	end

	for _, descendant in zones:GetDescendants() do
		if descendant:IsA("Model") and descendant:GetAttribute("LootId") ~= nil then
			register(descendant)
		end
	end
	zones.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Model") and descendant:GetAttribute("LootId") ~= nil then
			register(descendant)
		end
	end)

	RunService.Heartbeat:Connect(step)
end

return WorldLootFxController
