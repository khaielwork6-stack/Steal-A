--!strict
--[[
	LaserFxController (lasers-rework)
	Draws what the museum rooms' lasers do. Presentation only: the server
	tests every beam itself (LaserService) and decides every throw.

	  MOVERS   a room's `MovingBeam` parts (MuseumGallery) are never moved by
	           the server. Each is posed here every frame from its attributes
	           and the SERVER clock with LaserGeometry.moveFraction / blinkLit -
	           the same functions the server tests and the fairness validator
	           times - so what is drawn is what hits. Only beams near the
	           camera are posed. A blinking beam shows faintly for a moment
	           before it relights: the warning is part of the timing game.
	  FLASH    the beam that was touched flashes (its `HitAt` attribute, server
	           time, set by LaserService). Full effects: a white-hot swell
	           that settles back; Reduced Effects / Low Graphics: a plain
	           colour blink, no tween.
	  SHAKE    a light camera shake for the player who was thrown (their own
	           `LastLaserTrip` attribute). Skipped under Reduced Effects.

	The Laser Jammer's flicker (GadgetFxController) works on these beams
	unchanged: it writes LocalTransparencyModifier on every BasePart in a
	zone's Lasers folder, which a mover's own Transparency does not fight.
	Beams are gameplay information, so neither flag ever hides one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)

local LaserFxController = {}

local player = Players.LocalPlayer

--- Beyond this (studs from the camera) a mover is not posed.
local ANIMATE_RANGE = 320
--- A dark blinker shows faintly this long before it relights.
local BLINK_WARNING = 0.35
local WARNING_TRANSPARENCY = 0.8
--- Ignore a HitAt older than this (a late join replicates old stamps).
local FLASH_FRESH = 1.5
local FLASH_SECONDS = 0.35
local FLASH_SWELL = 4
local FLASH_COLOR = Color3.fromRGB(255, 235, 235)
local SHAKE_SECONDS = 0.3
local SHAKE_STUDS = 0.22
local SHAKE_BINDING = "LaserFxShake"

type Mover = {
	part: BasePart,
	rest: CFrame,
	center: Vector3,
	travel: Vector3,
	period: number,
	phase: number,
	onSeconds: number?,
	offSeconds: number?,
	blinkPhase: number?,
	shown: number,
}

local movers: { Mover } = {}
--- Per beam: what it looks like at rest, and the token of its latest flash.
local resting: { [BasePart]: { color: Color3, size: Vector3, token: number } } = {}

local function flash(beam: BasePart)
	local stamp = beam:GetAttribute("HitAt")
	if type(stamp) ~= "number" or math.abs(workspace:GetServerTimeNow() - stamp) > FLASH_FRESH then
		return
	end
	local rest = resting[beam]
	if not rest then
		rest = { color = beam.Color, size = beam.Size, token = 0 }
		resting[beam] = rest
	end
	rest.token += 1
	local token = rest.token
	beam.Color = FLASH_COLOR
	if Effects.isReduced() or Effects.isLowGraphics() then
		task.delay(0.18, function()
			if rest.token == token and beam.Parent then
				beam.Color = rest.color
			end
		end)
		return
	end
	beam.Size = Vector3.new(rest.size.X * FLASH_SWELL, rest.size.Y * FLASH_SWELL, rest.size.Z)
	local tween = TweenService:Create(beam, TweenInfo.new(FLASH_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = rest.size, Color = rest.color })
	tween:Play()
	tween.Completed:Once(function()
		if rest.token == token and beam.Parent then
			beam.Size, beam.Color = rest.size, rest.color
		end
	end)
end

local registered: { [Instance]: boolean } = {}

local function register(beam: Instance)
	if not beam:IsA("BasePart") or registered[beam] then
		return
	end
	registered[beam] = true
	beam:GetAttributeChangedSignal("HitAt"):Connect(function()
		flash(beam)
	end)
	local restA, restB, travel = beam:GetAttribute("RestA"), beam:GetAttribute("RestB"), beam:GetAttribute("Travel")
	if typeof(restA) ~= "Vector3" or typeof(restB) ~= "Vector3" or typeof(travel) ~= "Vector3" then
		return
	end
	table.insert(movers, {
		part = beam,
		-- The builder's own frame: a mover only ever translates.
		rest = beam.CFrame,
		center = (restA + restB) / 2 + travel / 2,
		travel = travel,
		period = tonumber(beam:GetAttribute("Period")) or 0,
		phase = tonumber(beam:GetAttribute("Phase")) or 0,
		onSeconds = tonumber(beam:GetAttribute("OnSeconds")),
		offSeconds = tonumber(beam:GetAttribute("OffSeconds")),
		blinkPhase = tonumber(beam:GetAttribute("BlinkPhase")),
		shown = 0,
	})
end

local function animate()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local now = workspace:GetServerTimeNow()
	for _, mover in movers do
		if (mover.center - eye).Magnitude > ANIMATE_RANGE then
			continue
		end
		if mover.period > 0 then
			mover.part.CFrame = mover.rest + mover.travel * Geometry.moveFraction(mover.period, mover.phase, now)
		end
		if mover.offSeconds then
			local wanted = 0
			if not Geometry.blinkLit(mover.onSeconds, mover.offSeconds, mover.blinkPhase, now) then
				wanted = if Geometry.blinkLit(mover.onSeconds, mover.offSeconds, mover.blinkPhase, now + BLINK_WARNING) then WARNING_TRANSPARENCY else 1
			end
			if wanted ~= mover.shown then
				mover.shown = wanted
				mover.part.Transparency = wanted
			end
		end
	end
end

local shakeUntil = 0
local function shake()
	if Effects.isReduced() then
		return
	end
	local already = os.clock() < shakeUntil
	shakeUntil = os.clock() + SHAKE_SECONDS
	if already then
		return
	end
	-- After the camera has placed itself, so the default camera and the
	-- shift-lock offset are left alone and the jitter simply rides on top.
	RunService:BindToRenderStep(SHAKE_BINDING, Enum.RenderPriority.Camera.Value + 1, function()
		local left = shakeUntil - os.clock()
		local camera = workspace.CurrentCamera
		if left <= 0 or not camera then
			RunService:UnbindFromRenderStep(SHAKE_BINDING)
			return
		end
		local strength = SHAKE_STUDS * left / SHAKE_SECONDS
		camera.CFrame *= CFrame.new((math.random() - 0.5) * 2 * strength, (math.random() - 0.5) * 2 * strength, 0)
	end)
end

function LaserFxController.start()
	player:GetAttributeChangedSignal("LastLaserTrip"):Connect(function()
		local stamp = player:GetAttribute("LastLaserTrip")
		if type(stamp) == "number" and math.abs(workspace:GetServerTimeNow() - stamp) < FLASH_FRESH then
			shake()
		end
	end)

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 60)
		local zones = map and map:WaitForChild("Zones", 30)
		if not zones then
			return
		end
		for _, zone in zones:GetChildren() do
			-- Its own thread: a zone folder without lasers must not hold the
			-- others up for the length of the wait.
			task.spawn(function()
				local lasers = zone:WaitForChild("Lasers", 15)
				if lasers then
					lasers.ChildAdded:Connect(register)
					for _, beam in lasers:GetChildren() do
						register(beam)
					end
				end
			end)
		end
		RunService.RenderStepped:Connect(animate)
	end)
end

return LaserFxController
