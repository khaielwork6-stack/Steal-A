--!strict
--[[
	GadgetFxController
	What the gadgets look like (gadgets-patrols area). Presentation only: the
	server has already decided everything.

	    Smoke   a marker part in workspace.GadgetFx (attributes Gadget="Smoke",
	            Radius, EndsAt) becomes a local smoke cloud.
	    Jammer  a player's `GadgetJamUntil` attribute (server time) puts a
	            cyan outline (and sparkles) on that player for everyone; on
	            the jammed player's OWN screen the nearby laser beams flicker
	            (LocalTransparencyModifier, so nothing replicates and nothing
	            is left changed).
	    Grapple the rope is a real server Beam; nothing to do here.

	THE SMOKE CLOUD (round3-gameplay: 3x the first pass). A detonation pop
	(flash, light pulse, sparks) on a fresh cloud, then a thick, near-opaque
	body of big puffs filling a SMOKE_RADIUS volume for the cloud's duration,
	then a lingering fade (SMOKE_FADE_SECONDS) as feeding stops.

	REDUCED EFFECTS / LOW GRAPHICS (Util/Effects). The smoke carries gameplay
	information - where the cloud is - so it is never hidden: under Reduced
	Effects it is a big static, nearly opaque cloud of spheres (no particles,
	no pop) that fades at the end, and under Low Graphics far fewer (bigger)
	puffs, no wisps and a smaller spark burst. The jam outline
	always shows; its sparkles are skipped under either flag, and the beams
	dim steadily instead of flickering under Reduced Effects.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)

local GadgetFxController = {}

local localPlayer = Players.LocalPlayer

local SMOKE_COLOR = Color3.fromRGB(196, 200, 212)
local SMOKE_DEEP = Color3.fromRGB(138, 144, 160)
local JAM_COLOR = Color3.fromRGB(96, 230, 255)
--- Beams this far from the jammed player flicker; the rest are off screen.
local FLICKER_RADIUS = 220
local FLICKER_STEP = 0.1

local function remaining(endsAt: any): number
	if type(endsAt) ~= "number" then
		return 0
	end
	return endsAt - workspace:GetServerTimeNow()
end

-- ==========================================================
-- SMOKE
-- ==========================================================

--- A local, invisible, non-interactive anchored part.
local function localPart(name: string, size: Vector3, at: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = at
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = parent
	return part
end

--- REDUCED EFFECTS: no particles and no motion - a big, nearly opaque cloud
--- of overlapping spheres that sits still for the duration, then fades.
local function staticCloud(parent: Instance, center: Vector3, radius: number, duration: number)
	local holder = Instance.new("Model")
	holder.Name = "SmokeCloudStatic"
	local puffs: { BasePart } = {}
	local offsets: { Vector3 } = {
		Vector3.zero,
		Vector3.new(radius * 0.55, -radius * 0.2, 0),
		Vector3.new(-radius * 0.55, -radius * 0.2, 0),
		Vector3.new(0, -radius * 0.2, radius * 0.55),
		Vector3.new(0, -radius * 0.2, -radius * 0.55),
		Vector3.new(0, radius * 0.45, 0),
	}
	local scales: { number } = { 1, 0.62, 0.62, 0.62, 0.62, 0.6 }
	for index, offset in offsets do
		local scale = scales[index]
		local puff = localPart(`Puff{index}`, Vector3.one * radius * 2 * scale, CFrame.new(center + offset), holder)
		puff.Shape = Enum.PartType.Ball
		puff.Material = Enum.Material.SmoothPlastic
		puff.Color = if index % 2 == 0 then SMOKE_COLOR else SMOKE_DEEP
		puff.Transparency = 0.08
		table.insert(puffs, puff)
	end
	holder.Parent = parent
	task.delay(duration, function()
		if not holder.Parent then
			return
		end
		-- A fade is not motion; it tells the player the cover is going.
		for _, puff in puffs do
			TweenService:Create(puff, TweenInfo.new(GadgetConfig.SMOKE_FADE_SECONDS, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
		end
		task.delay(GadgetConfig.SMOKE_FADE_SECONDS + 0.1, function()
			holder:Destroy()
		end)
	end)
end

--- The detonation: a white flash that swells and vanishes, a light pulse and
--- a spray of sparks. Only for a fresh cloud, never under Reduced Effects.
local function popFlash(volume: BasePart, center: Vector3, radius: number, low: boolean)
	local flash = localPart("SmokePop", Vector3.one * radius * 0.35, CFrame.new(center), volume)
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 250, 235)
	flash.Transparency = 0.1
	local grow = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(flash, grow, { Size = Vector3.one * radius * 1.4, Transparency = 1 }):Play()
	task.delay(0.4, function()
		flash:Destroy()
	end)

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 244, 220)
	light.Brightness = 8
	light.Range = math.min(radius * 1.5, 60)
	light.Shadows = false
	light.Parent = volume
	TweenService:Create(light, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()
	task.delay(0.5, function()
		light:Destroy()
	end)

	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "SmokePopSparks"
	sparks.Texture = GadgetConfig.JAM_TEXTURE
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 236, 170), Color3.fromRGB(255, 150, 60))
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 0) })
	sparks.Lifetime = NumberRange.new(0.3, 0.55)
	sparks.Speed = NumberRange.new(radius * 1.2, radius * 2)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Drag = 4
	sparks.Rate = 0
	sparks.Shape = Enum.ParticleEmitterShape.Sphere
	sparks.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	sparks.Parent = volume
	sparks:Emit(if low then 10 else 32)
end

local function smokeCloud(marker: BasePart)
	local duration = remaining(marker:GetAttribute("EndsAt"))
	if duration <= 0 then
		return
	end
	local radius = tonumber(marker:GetAttribute("Radius")) or GadgetConfig.SMOKE_RADIUS
	local fade = GadgetConfig.SMOKE_FADE_SECONDS
	-- The cloud's body is centred a little above the feet so it swallows a
	-- standing player and a guard; the floor clips the lower part.
	local center = marker.Position + Vector3.new(0, radius * 0.35, 0)
	-- Streaming / a late join: no detonation for a cloud that is already old.
	local fresh = GadgetConfig.SMOKE_CLOUD_SECONDS - duration < 0.5
	-- Our own children live in the fx folder, not under the marker: the server
	-- removes the marker shortly after the cloud ends, and the fade outlives it.
	local parent = marker.Parent or workspace

	if Effects.isReduced() then
		staticCloud(parent, center, radius, duration)
		return
	end

	local low = Effects.isLowGraphics()
	local volume = localPart("SmokeVolume", Vector3.new(radius * 1.5, radius * 0.9, radius * 1.5), CFrame.new(center), parent)
	if fresh then
		popFlash(volume, center, radius, low)
	end

	-- THE BODY: thick, near-opaque puffs filling the volume. Each puff lives a
	-- little longer than the fade, so when feeding stops at the end of the
	-- cloud the last ones thin out over roughly SMOKE_FADE_SECONDS.
	local body = Instance.new("ParticleEmitter")
	body.Name = "SmokeBody"
	body.Texture = GadgetConfig.SMOKE_TEXTURE
	body.Color = ColorSequence.new(SMOKE_COLOR, SMOKE_DEEP)
	-- Low Graphics: far fewer puffs, each bigger, so the cover is the same size.
	local grow = if low then 1.2 else 1
	body.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, radius * 0.35 * grow),
		NumberSequenceKeypoint.new(0.3, radius * 0.7 * grow),
		NumberSequenceKeypoint.new(1, radius * 0.85 * grow),
	})
	body.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.1, 0.02),
		NumberSequenceKeypoint.new(0.72, 0.08),
		NumberSequenceKeypoint.new(1, 1),
	})
	body.Lifetime = NumberRange.new(fade + 0.8, fade + 1.5)
	body.Speed = NumberRange.new(1, 4)
	body.SpreadAngle = Vector2.new(180, 180)
	body.Acceleration = Vector3.new(0, 0.6, 0)
	body.Drag = 2
	body.RotSpeed = NumberRange.new(-25, 25)
	body.Rotation = NumberRange.new(0, 360)
	body.LightInfluence = 0.4
	body.Shape = Enum.ParticleEmitterShape.Box
	body.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	body.Rate = if low then 4 else 18
	body.Parent = volume
	if fresh then
		body:Emit(if low then 12 else 40)
	else
		body:Emit(if low then 8 else 24)
	end

	-- Wisps curling off the edge: decoration, so not on Low Graphics.
	local wisps: ParticleEmitter? = nil
	if not low then
		local edge = Instance.new("ParticleEmitter")
		edge.Name = "SmokeWisps"
		edge.Texture = GadgetConfig.SMOKE_TEXTURE
		edge.Color = ColorSequence.new(Color3.fromRGB(220, 224, 234))
		edge.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, radius * 0.15),
			NumberSequenceKeypoint.new(1, radius * 0.4),
		})
		edge.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(0.5, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		edge.Lifetime = NumberRange.new(1.2, 2)
		edge.Speed = NumberRange.new(radius * 0.2, radius * 0.4)
		edge.SpreadAngle = Vector2.new(180, 180)
		edge.Acceleration = Vector3.new(0, 2, 0)
		edge.Drag = 1.5
		edge.RotSpeed = NumberRange.new(-60, 60)
		edge.Rotation = NumberRange.new(0, 360)
		edge.LightInfluence = 0.5
		edge.Shape = Enum.ParticleEmitterShape.Sphere
		edge.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		edge.Rate = 8
		edge.Parent = volume
		wisps = edge
	end

	-- Feed the cloud until it ends, then let it fade out and clean up.
	task.delay(math.max(0, duration - 0.3), function()
		body.Enabled = false
		if wisps then
			wisps.Enabled = false
		end
	end)
	task.delay(duration + fade + 1.8, function()
		volume:Destroy()
	end)
end

local function watchSmoke()
	local folder = workspace:WaitForChild("GadgetFx", 60)
	if not folder then
		return
	end
	local function consider(child: Instance)
		if child:IsA("BasePart") and child:GetAttribute("Gadget") == "Smoke" then
			smokeCloud(child)
		end
	end
	for _, child in folder:GetChildren() do
		consider(child)
	end
	folder.ChildAdded:Connect(consider)
end

-- ==========================================================
-- LASER JAMMER
-- ==========================================================

local function nearbyBeams(center: Vector3): { BasePart }
	local found: { BasePart } = {}
	local map = workspace:FindFirstChild("Map")
	local zones = map and map:FindFirstChild("Zones")
	if not zones then
		return found
	end
	for _, zone in zones:GetChildren() do
		local lasers = zone:FindFirstChild("Lasers")
		if not lasers then
			continue
		end
		for _, beam in lasers:GetChildren() do
			if beam:IsA("BasePart") and (beam.Position - center).Magnitude <= FLICKER_RADIUS then
				table.insert(found, beam)
			end
		end
	end
	return found
end

local flickerToken = 0

--- The jammed player's own view: nearby beams flicker (or dim) until the jam ends.
local function flickerBeams(endsAt: number)
	flickerToken += 1
	local token = flickerToken
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local beams = nearbyBeams(root.Position)
	task.spawn(function()
		local on = false
		while token == flickerToken and workspace:GetServerTimeNow() < endsAt do
			local value = if Effects.isReduced() then 0.6 else (if on then 0.85 else 0.25)
			on = not on
			for _, beam in beams do
				beam.LocalTransparencyModifier = value
			end
			task.wait(FLICKER_STEP)
		end
		-- Always put the beams back, even when a newer jam took over (it
		-- re-applies its own value on its next step).
		for _, beam in beams do
			beam.LocalTransparencyModifier = 0
		end
	end)
end

--- Everyone's view of a jammed player: an outline, and sparkles if allowed.
local function jamLook(player: Player, endsAt: number)
	local character = player.Character
	if not character then
		return
	end
	local existing = character:FindFirstChild("GadgetJamOutline")
	local outline = if existing and existing:IsA("Highlight") then existing else Instance.new("Highlight")
	outline.Name = "GadgetJamOutline"
	outline.FillColor = JAM_COLOR
	outline.FillTransparency = 0.8
	outline.OutlineColor = JAM_COLOR
	outline.OutlineTransparency = 0
	outline.DepthMode = Enum.HighlightDepthMode.Occluded
	outline.Adornee = character
	outline.Parent = character

	local root = character:FindFirstChild("HumanoidRootPart")
	local sparkles: ParticleEmitter? = nil
	if root and root:IsA("BasePart") and not Effects.isReduced() and not Effects.isLowGraphics()
		and not root:FindFirstChild("GadgetJamSparkles") then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "GadgetJamSparkles"
		emitter.Texture = GadgetConfig.JAM_TEXTURE
		emitter.Color = ColorSequence.new(JAM_COLOR)
		emitter.LightEmission = 0.8
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
		emitter.Lifetime = NumberRange.new(0.4, 0.7)
		emitter.Speed = NumberRange.new(2, 4)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Rate = 18
		emitter.Parent = root
		sparkles = emitter
	end

	task.delay(math.max(0, endsAt - workspace:GetServerTimeNow()), function()
		-- A later jam moved the end: leave it to that one.
		local current = player:GetAttribute("GadgetJamUntil")
		if type(current) == "number" and current > endsAt + 0.05 then
			return
		end
		if outline.Parent then
			outline:Destroy()
		end
		if sparkles then
			sparkles:Destroy()
		end
	end)
end

local function watchJam(player: Player)
	local function refresh()
		local endsAt = player:GetAttribute("GadgetJamUntil")
		if type(endsAt) ~= "number" or remaining(endsAt) <= 0 then
			return
		end
		jamLook(player, endsAt)
		if player == localPlayer then
			flickerBeams(endsAt)
		end
	end
	player:GetAttributeChangedSignal("GadgetJamUntil"):Connect(refresh)
	refresh()
end

function GadgetFxController.start()
	task.spawn(watchSmoke)
	for _, player in Players:GetPlayers() do
		watchJam(player)
	end
	Players.PlayerAdded:Connect(watchJam)
end

return GadgetFxController
