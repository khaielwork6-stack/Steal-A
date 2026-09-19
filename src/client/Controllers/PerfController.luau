--!strict
--[[
	PerfController  (analytics-discord)
	A cheap frame-rate watch and a client error forwarder, for the server's
	"errors and spikes" feed (PerfFeed). Sends numbers and fixed words only,
	through the rate-limited PerfReport remote; the server adds where the
	player is, who is near and why, and decides whether to keep it.

	FPS: frames are counted and read twice a second - nothing heavy runs per
	frame. When the rate stays under PolishConfig.PERF_FPS_THRESHOLD for
	PERF_LOW_SECONDS, ONE snapshot is taken and sent, then nothing for
	PERF_COOLDOWN_SECONDS, and never more than PERF_SESSION_CAP a session.
	The snapshot's particle / effect count is one bounded spatial query
	around the camera, made only then.

	ERRORS: ScriptContext.Error on this client (LocalScripts / ModuleScripts),
	the first line and the script path, each distinct message once a session,
	at most PERF_CLIENT_ERROR_CAP.

	top_script: Roblox exposes no per-script cost to a LocalScript, so this
	names the costliest of the frame's own stages it can read (Render when
	the GPU / CPU render time dominates, Network on a high ping, else n/a).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local Stats = game:GetService("Stats")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local PolishConfig = require(ReplicatedStorage.Shared.Config.PolishConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local PerfController = {}

local player = Players.LocalPlayer

local SAMPLE_SECONDS = 0.5
local MAX_SCAN_PARTS = 600

local function deviceClass(): string
	if GuiService:IsTenFootInterface() then
		return "Console"
	elseif Device.isPhone() then
		return "Phone"
	elseif Device.isTouch() then
		return "Tablet"
	end
	return "Desktop"
end

local function fxSetting(): string
	local reduced = Effects.isReduced()
	local low = Effects.isLowGraphics()
	if reduced and low then
		return "ReducedLow"
	elseif low then
		return "Low"
	elseif reduced then
		return "Reduced"
	end
	return "Full"
end

--- A Stats property that may not exist on every client; seconds become ms.
local function statMs(name: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	if not ok or type(value) ~= "number" or value < 0 then
		return nil
	end
	-- Some builds report seconds: a render frame is never under 0.5 ms.
	return if value > 0 and value < 0.5 then value * 1000 else value
end

local function statNumber(name: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	return if ok and type(value) == "number" then value else nil
end

--- Enabled emitters / effects on the parts near the camera. One bounded
--- query; only ever run when a spike is being reported.
local function countEffects(): (number, number)
	local camera = workspace.CurrentCamera
	if not camera then
		return 0, 0
	end
	local params = OverlapParams.new()
	params.MaxParts = MAX_SCAN_PARTS
	local parts = workspace:GetPartBoundsInRadius(camera.CFrame.Position, PolishConfig.PERF_SCAN_RADIUS, params)
	local particles, effects = 0, 0
	local function look(holder: Instance)
		for _, child in holder:GetChildren() do
			if child:IsA("ParticleEmitter") then
				if child.Enabled then
					particles += 1
				end
			elseif child:IsA("Beam") or child:IsA("Trail") or child:IsA("Fire") or child:IsA("Smoke") or child:IsA("Sparkles") then
				if (child :: any).Enabled == true then
					effects += 1
				end
			elseif child:IsA("Attachment") then
				look(child)
			end
		end
	end
	for _, part in parts do
		look(part)
	end
	return particles, effects
end

local function snapshot(fps: number): { [string]: any }
	local particles, effects = 0, 0
	pcall(function()
		particles, effects = countEffects()
	end)
	local ping = 0
	pcall(function()
		ping = player:GetNetworkPing() * 1000
	end)
	local cpu = statMs("RenderCPUFrameTime")
	local gpu = statMs("RenderGPUFrameTime")
	local top = "n/a"
	if ping >= 300 then
		top = "Network"
	elseif (cpu or 0) >= 25 or (gpu or 0) >= 25 then
		top = "Render"
	end
	return {
		fps = math.floor(fps * 10 + 0.5) / 10,
		device = deviceClass(),
		fx = fxSetting(),
		pingMs = math.floor(ping),
		recvKbps = statNumber("DataReceiveKbps") or 0,
		particles = particles,
		effects = effects,
		cpuMs = cpu,
		gpuMs = gpu,
		drawcalls = statNumber("SceneDrawcallCount"),
		tris = statNumber("SceneTriangleCount"),
		top = top,
	}
end

local function watchFrames(remote: RemoteEvent)
	local frames, elapsed, lowFor = 0, 0, 0
	local nextAllowed = 0
	local sent = 0
	RunService.RenderStepped:Connect(function(dt)
		frames += 1
		elapsed += dt
		if elapsed < SAMPLE_SECONDS then
			return
		end
		local fps = frames / elapsed
		frames, elapsed = 0, 0
		if fps >= PolishConfig.PERF_FPS_THRESHOLD then
			lowFor = 0
			return
		end
		lowFor += SAMPLE_SECONDS
		local now = os.clock()
		if lowFor < PolishConfig.PERF_LOW_SECONDS or now < nextAllowed or sent >= PolishConfig.PERF_SESSION_CAP then
			return
		end
		lowFor = 0
		nextAllowed = now + PolishConfig.PERF_COOLDOWN_SECONDS
		sent += 1
		task.spawn(function()
			local ok, payload = pcall(snapshot, fps)
			if ok then
				remote:FireServer("spike", payload)
			end
		end)
	end)
end

local function watchErrors(remote: RemoteEvent)
	local seen: { [string]: true } = {}
	local sent = 0
	local lastAt = -math.huge
	ScriptContext.Error:Connect(function(message, _trace, scriptInstance)
		if sent >= PolishConfig.PERF_CLIENT_ERROR_CAP then
			return
		end
		local line = string.sub(string.match(message, "^[^\n]+") or message, 1, 300)
		if seen[line] or os.clock() - lastAt < 2 then
			return
		end
		seen[line] = true
		sent += 1
		lastAt = os.clock()
		local path = if scriptInstance then string.sub(scriptInstance:GetFullName(), 1, 150) else "?"
		remote:FireServer("error", { message = line, source = path })
	end)
end

function PerfController.start()
	if not PolishConfig.PERF_SAMPLER_ENABLED then
		return
	end
	local remote = Remotes.get("PerfReport")
	watchErrors(remote)
	watchFrames(remote)
end

return PerfController
