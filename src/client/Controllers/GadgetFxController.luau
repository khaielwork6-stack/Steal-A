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

	REDUCED EFFECTS / LOW GRAPHICS (Util/Effects). The smoke carries gameplay
	information - where the cloud is - so it is never hidden: under Reduced
	Effects it is a still, translucent sphere instead of moving particles,
	and under Low Graphics a much smaller particle burst. The jam outline
	always shows; its sparkles are skipped under either flag, and the beams
	dim steadily instead of flickering under Reduced Effects.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)

local GadgetFxController = {}

local localPlayer = Players.LocalPlayer

local SMOKE_COLOR = Color3.fromRGB(196, 200, 212)
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

local function smokeCloud(marker: BasePart)
	local duration = remaining(marker:GetAttribute("EndsAt"))
	if duration <= 0 then
		return
	end
	local radius = tonumber(marker:GetAttribute("Radius")) or GadgetConfig.SMOKE_RADIUS

	if Effects.isReduced() then
		-- Still, not animated: a soft sphere where the cloud is.
		local sphere = Instance.new("Part")
		sphere.Name = "SmokeSphere"
		sphere.Shape = Enum.PartType.Ball
		sphere.Size = Vector3.one * radius * 2
		sphere.CFrame = marker.CFrame + Vector3.new(0, radius * 0.5, 0)
		sphere.Anchored = true
		sphere.CanCollide = false
		sphere.CanQuery = false
		sphere.CanTouch = false
		sphere.CastShadow = false
		sphere.Material = Enum.Material.SmoothPlastic
		sphere.Color = SMOKE_COLOR
		sphere.Transparency = 0.35
		sphere.Parent = marker
		task.delay(duration, function()
			sphere:Destroy()
		end)
		return
	end

	local low = Effects.isLowGraphics()
	local attachment = Instance.new("Attachment")
	attachment.Position = Vector3.new(0, 1.5, 0)
	attachment.Parent = marker
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = GadgetConfig.SMOKE_TEXTURE
	emitter.Color = ColorSequence.new(SMOKE_COLOR, Color3.fromRGB(150, 156, 170))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, radius * 0.5),
		NumberSequenceKeypoint.new(1, radius * 1.1),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.7, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(1.6, 2.4)
	emitter.Speed = NumberRange.new(radius * 0.4, radius * 0.9)
	emitter.SpreadAngle = Vector2.new(180, 60)
	emitter.Acceleration = Vector3.new(0, 1.5, 0)
	emitter.Drag = 3
	emitter.RotSpeed = NumberRange.new(-40, 40)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LightInfluence = 0.6
	emitter.Rate = if low then 0 else 14
	emitter.Parent = attachment
	emitter:Emit(if low then 10 else 36)
	-- Stop feeding the cloud a little early so it thins out as it ends.
	task.delay(math.max(0, duration - 1.2), function()
		emitter.Enabled = false
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
