--!strict
--[[
	WorldLootFxController
	Every piece of loot sitting in a zone socket is alive: a slow turn, a
	gentle hover for the ordinary sizes, and a soft ring of its rarity colour on
	the pad beneath it. Client-side and cosmetic, like the base displays
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
	    ring   a neon disc in the rarity colour, breathing slowly; Legendary and
	           above also get a small point light
	Only sockets within ANIMATE_DISTANCE of the camera move; the rest hold
	their rest pose. Reduced Effects keeps the turn and drops the hover, the
	breathing and the lights.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local WorldLootFxController = {}

local ANIMATE_DISTANCE = 320
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

--- Ring transparency at rest by rarity rank; brighter as it gets rarer.
local RING_TRANSPARENCY_COMMON = 0.72
local RING_TRANSPARENCY_TOP = 0.3
local RING_BREATHE = 0.1

type Entry = {
	model: Model,
	socket: BasePart,
	base: CFrame?,
	readyAt: number,
	angle: number,
	phase: number,
	turn: number,
	hover: number,
	near: boolean,
	ring: BasePart?,
	light: PointLight?,
	ringRest: number,
}

local entries: { [Model]: Entry } = {}
local reducedEffects = false
local lastCull = 0

function WorldLootFxController.setReducedEffects(value: boolean)
	reducedEffects = value
	for _, entry in entries do
		if entry.light then
			entry.light.Enabled = not value
		end
		if entry.ring then
			entry.ring.Transparency = entry.ringRest
		end
	end
end

-- ==========================================================
-- THE RING
-- ==========================================================

local function buildRing(entry: Entry)
	local rarity = entry.model:GetAttribute("Rarity")
	local color = RarityConfig.Colors[if type(rarity) == "string" then rarity else "Common"] or Color3.new(1, 1, 1)
	local rank = RarityConfig.rank(if type(rarity) == "string" then rarity else "Common")
	local top = RarityConfig.rank("Secret")
	local alpha = math.clamp(rank / math.max(top, 1), 0, 1)
	entry.ringRest = RING_TRANSPARENCY_COMMON + (RING_TRANSPARENCY_TOP - RING_TRANSPARENCY_COMMON) * alpha

	local socket = entry.socket
	local diameter = math.min(socket.Size.X, socket.Size.Z) * 0.8
	local ring = Instance.new("Part")
	ring.Name = "LootRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.12, diameter, diameter)
	ring.CFrame = CFrame.new(socket.Position + Vector3.new(0, socket.Size.Y / 2 + 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = entry.ringRest
	ring.Parent = socket
	entry.ring = ring

	if rank >= RarityConfig.rank("Legendary") then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Brightness = 0.9
		light.Range = 14
		light.Shadows = false
		light.Enabled = not reducedEffects
		light.Parent = ring
		entry.light = light
	end
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
	if not entry then
		return
	end
	entries[model] = nil
	if entry.ring then
		entry.ring:Destroy()
	end
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
		angle = math.random() * math.pi * 2,
		phase = math.random() * math.pi * 2,
		turn = TURN_RATE / math.sqrt(math.max(scale, 1)),
		hover = if scale <= HOVER_MAX_SCALE then HOVER_AMPLITUDE else 0,
		near = false,
		ring = nil,
		light = nil,
		ringRest = RING_TRANSPARENCY_COMMON,
	}
	entries[model] = entry
	buildRing(entry)

	-- The moment it leaves its socket (stolen, refreshed, destroyed) it is the
	-- server's again.
	model.AncestryChanged:Connect(function()
		if model.Parent ~= socket then
			unregister(model)
		end
	end)
end

-- ==========================================================
-- FRAME
-- ==========================================================

local function cull()
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	for _, entry in entries do
		entry.near = (entry.socket.Position - eye).Magnitude <= ANIMATE_DISTANCE
	end
end

local function step(dt: number)
	local now = os.clock()
	if now - lastCull >= CULL_INTERVAL then
		lastCull = now
		cull()
	end

	for model, entry in entries do
		if not model.Parent then
			unregister(model)
			continue
		end
		if now < entry.readyAt then
			continue
		end
		if not entry.base then
			if not model.PrimaryPart then
				continue
			end
			entry.base = model:GetPivot()
		end
		if not entry.near then
			continue
		end

		entry.angle += entry.turn * dt
		local lift = 0
		if not reducedEffects and entry.hover > 0 then
			lift = (math.sin(now * HOVER_RATE + entry.phase) + 1) * 0.5 * entry.hover
		end
		local base = entry.base :: CFrame
		model:PivotTo(base * CFrame.Angles(0, entry.angle, 0) + Vector3.new(0, lift, 0))

		local ring = entry.ring
		if ring and not reducedEffects then
			ring.Transparency = entry.ringRest + math.sin(now * 1.6 + entry.phase) * RING_BREATHE
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
