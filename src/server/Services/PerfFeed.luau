--!strict
--[[
	PerfFeed  (analytics-discord)
	The "Steal & Run! errors and spikes" feed: CSV rows, batched into one
	Discord message (a bold title and a ```csv block) every
	PERF_FLUSH_SECONDS, or as soon as PERF_BATCH_ROWS are waiting.

	    utc,kind,where,detail,cpu_ms,gpu_ms,drawcalls,tris_k,top_script

	ROWS
	  fps-drop      a client's frame rate stayed low (PerfController). The
	                client sends only numbers and fixed words; the SERVER
	                adds where the player is, who and which guards are near,
	                the session id and the cause (DiscordConfig.CAUSE_THRESHOLDS).
	                Also a PerfSpike analytics event (device, cause, fps bucket).
	  server-lag    this server's frame rate under SERVER_LAG_FPS for
	                SERVER_LAG_SECONDS (with heartbeat ms, players, chases).
	  error         a server script error (ScriptContext.Error), or a client
	                one forwarded by PerfController; one row per distinct
	                message per CLIENT_ERROR_DEDUPE_SECONDS.
	  remote-flood  one player refused FLOOD_REJECTS times inside FLOOD_WINDOW
	                by any RateLimiter (the RateLimiter.onReject hook).

	Commas and line breaks inside a field become ";" and " ". Rows are kept
	(the newest PERF_BUFFER_MAX) whether or not Discord is on, so `discordStatus`
	and `perfSpikeTest` show them in Studio. Switch: DiscordConfig.PERF_FEED.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local Stats = game:GetService("Stats")

local PolishConfig = require(ReplicatedStorage.Shared.Config.PolishConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local DiscordConfig = require(script.Parent.Parent.Config.DiscordConfig)
local AnalyticsEvents = require(script.Parent.AnalyticsEvents)
local AnalyticsSession = require(script.Parent.AnalyticsSession)
local DiscordReporter = require(script.Parent.DiscordReporter)
local GuardianService = require(script.Parent.GuardianService)

local PerfFeed = {}

PerfFeed.HEADER = "utc,kind,where,detail,cpu_ms,gpu_ms,drawcalls,tris_k,top_script"

local DEVICES: { [string]: true } = { Phone = true, Tablet = true, Console = true, Desktop = true }
local FX: { [string]: true } = { Full = true, Reduced = true, Low = true, ReducedLow = true }
--- What a client may name as its busiest system (PerfController).
PerfFeed.TOP_SCRIPTS = { "n/a", "Render", "Physics", "Network", "Scripts" } :: { string }
local TOP: { [string]: true } = {}
for _, name in PerfFeed.TOP_SCRIPTS do
	TOP[name] = true
end

local rows: { string } = {}
local recentRows: { string } = {}
local counts = { rows = 0, posted = 0, messages = 0, spikes = 0, clientErrors = 0, serverErrors = 0, lags = 0, floods = 0 }

-- ==========================================================
-- ROWS
-- ==========================================================

--- One CSV cell: no commas, no line breaks, no code fence, bounded.
local function cell(value: any, limit: number?): string
	local text = tostring(if value == nil then "" else value)
	text = string.gsub(text, "[\r\n\t]", " ")
	text = string.gsub(text, ",", ";")
	text = string.gsub(text, "`", "'")
	local max = limit or 200
	if #text > max then
		text = string.sub(text, 1, max - 3) .. "..."
	end
	return text
end

local function number(value: number?, decimals: number?): string
	if value == nil or value ~= value or value < 0 then
		return ""
	end
	if decimals and decimals > 0 then
		return string.format(`%.{decimals}f`, value)
	end
	return tostring(math.floor(value + 0.5))
end

local flush: () -> ()

function PerfFeed.addRow(kind: string, where: string, detail: string, cpuMs: number?, gpuMs: number?, drawcalls: number?, trisK: number?, top: string?)
	local row = table.concat({
		os.date("!%Y-%m-%d %H:%M:%S"),
		cell(kind, 20),
		cell(where, 120),
		cell(detail, 400),
		number(cpuMs, 1),
		number(gpuMs, 1),
		number(drawcalls),
		number(trisK),
		cell(top or "n/a", 40),
	}, ",")
	counts.rows += 1
	table.insert(recentRows, row)
	while #recentRows > 20 do
		table.remove(recentRows, 1)
	end
	if not DiscordConfig.PERF_FEED then
		return
	end
	table.insert(rows, row)
	while #rows > DiscordConfig.PERF_BUFFER_MAX do
		table.remove(rows, 1)
	end
	if #rows >= DiscordConfig.PERF_BATCH_ROWS then
		task.spawn(flush)
	end
end

--- Posts every waiting row: as many messages as it takes to stay under
--- Discord's 2000 characters each.
flush = function()
	if #rows == 0 or not DiscordReporter.isEnabled() then
		return
	end
	local waiting = rows
	rows = {}
	local title = `**{DiscordConfig.GAME_NAME} errors and spikes**`
	local open = `{title}\n` .. "```csv\n" .. PerfFeed.HEADER .. "\n"
	local close = "```"
	local body = open
	local inBody = 0
	for _, row in waiting do
		if #body + #row + 1 + #close > 1950 and inBody > 0 then
			DiscordReporter.postText("errors and spikes", body .. close)
			counts.messages += 1
			body = open
			inBody = 0
		end
		body ..= row .. "\n"
		inBody += 1
		counts.posted += 1
	end
	if inBody > 0 then
		DiscordReporter.postText("errors and spikes", body .. close)
		counts.messages += 1
	end
end

-- ==========================================================
-- CLIENT SPIKES
-- ==========================================================

local function clampNumber(value: any, low: number, high: number): number?
	local n = tonumber(value)
	if n == nil or n ~= n then
		return nil
	end
	return math.clamp(n, low, high)
end

local function fpsBucket(fps: number): string
	if fps < 10 then
		return "<10"
	elseif fps < 15 then
		return "10-15"
	elseif fps < 20 then
		return "15-20"
	elseif fps < 25 then
		return "20-25"
	end
	return "25+"
end

--- The largest measurement / threshold ratio at or above 1 names the cause.
function PerfFeed.causeOf(measured: { [string]: number }): string
	local best, bestRatio = "Unknown", 1
	for cause, limits in DiscordConfig.CAUSE_THRESHOLDS do
		for key, threshold in limits do
			local value = measured[key]
			if value and threshold > 0 then
				local ratio = value / threshold
				if ratio >= bestRatio then
					best, bestRatio = cause, ratio
				end
			end
		end
	end
	return best
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function nearbyCounts(player: Player): (number, number)
	local root = rootOf(player)
	if not root then
		return 0, 0
	end
	local here = root.Position
	local players = 0
	for _, other in Players:GetPlayers() do
		local otherRoot = if other ~= player then rootOf(other) else nil
		if otherRoot and (otherRoot.Position - here).Magnitude <= DiscordConfig.NEARBY_PLAYERS_RADIUS then
			players += 1
		end
	end
	local guards = 0
	for zone = 1, MapConfig.ZONE_COUNT do
		for room = 1, Layout.VAULT_ROOM do
			local at = GuardianService.guardianPosition(zone, room)
			if at and (at - here).Magnitude <= DiscordConfig.NEARBY_GUARDS_RADIUS then
				guards += 1
			end
		end
	end
	return players, guards
end

type PlayerState = { lastSpike: number, spikes: number, errors: number }
local perPlayer: { [Player]: PlayerState } = {}

local function stateOf(player: Player): PlayerState
	local state = perPlayer[player]
	if not state then
		state = { lastSpike = -math.huge, spikes = 0, errors = 0 }
		perPlayer[player] = state
	end
	return state
end

--- A validated spike from `player` (or a test one). Returns the row.
function PerfFeed.spike(player: Player, payload: { [string]: any }, bypassLimits: boolean?): string?
	local state = stateOf(player)
	local now = os.clock()
	if not bypassLimits then
		if now - state.lastSpike < DiscordConfig.SPIKE_COOLDOWN or state.spikes >= PolishConfig.PERF_SESSION_CAP then
			return nil
		end
	end
	local fps = clampNumber(payload.fps, 0, 240)
	local device = payload.device
	local fx = payload.fx
	if not fps or type(device) ~= "string" or not DEVICES[device] or type(fx) ~= "string" or not FX[fx] then
		return nil
	end
	state.lastSpike = now
	state.spikes += 1
	counts.spikes += 1

	local ping = clampNumber(payload.pingMs, 0, 10000) or 0
	local recv = clampNumber(payload.recvKbps, 0, 100000) or 0
	local particles = clampNumber(payload.particles, 0, 10000) or 0
	local effects = clampNumber(payload.effects, 0, 10000) or 0
	local cpu = clampNumber(payload.cpuMs, 0, 1000)
	local gpu = clampNumber(payload.gpuMs, 0, 1000)
	local drawcalls = clampNumber(payload.drawcalls, 0, 1e6)
	local tris = clampNumber(payload.tris, 0, 1e9)
	local trisK = if tris then tris / 1000 else nil
	local top = if type(payload.top) == "string" and TOP[payload.top] then payload.top else "n/a"

	local where = AnalyticsSession.locate(player)
	local nearby, guards = nearbyCounts(player)
	local cause = PerfFeed.causeOf({
		pingMs = ping,
		recvKbps = recv,
		nearby = nearby,
		guards = guards,
		particles = particles,
		effects = effects,
		drawcalls = drawcalls or 0,
		trisK = trisK or 0,
	})
	local detail = `ver={game.PlaceVersion} fps={math.floor(fps + 0.5)} cause={cause} nearby={nearby} guards={guards}`
		.. ` particles={math.floor(particles)} effects={math.floor(effects)} ping={math.floor(ping)} recv={math.floor(recv)} fx={fx}`
	local whereText = `{device} {where} sid={AnalyticsSession.sid(player)}`
	PerfFeed.addRow("fps-drop", whereText, detail, cpu, gpu, drawcalls, trisK, top)
	AnalyticsEvents.custom(player, "PerfSpike", math.floor(fps), { device, cause, fpsBucket(fps) })
	return recentRows[#recentRows]
end

-- ==========================================================
-- ERRORS
-- ==========================================================

local errorSeen: { [string]: number } = {}

local function firstLine(text: string): string
	return string.match(text, "^[^\n]+") or text
end

local function errorRow(side: string, message: string, path: string)
	local key = `{side}|{string.sub(message, 1, 160)}`
	local now = os.clock()
	if now - (errorSeen[key] or -math.huge) < DiscordConfig.CLIENT_ERROR_DEDUPE_SECONDS then
		return
	end
	errorSeen[key] = now
	PerfFeed.addRow("error", `{side}:{path}`, firstLine(message), nil, nil, nil, nil, "n/a")
end

--- A forwarded client error. The player's name is cut out of the path.
local function clientError(player: Player, payload: { [string]: any })
	local state = stateOf(player)
	if state.errors >= PolishConfig.PERF_CLIENT_ERROR_CAP then
		return
	end
	local message = payload.message
	local path = payload.source
	if type(message) ~= "string" or type(path) ~= "string" then
		return
	end
	state.errors += 1
	counts.clientErrors += 1
	message = string.sub(message, 1, 300)
	path = string.sub(path, 1, 150)
	path = string.gsub(path, "[^%w%._%-/ ]", "")
	path = string.gsub(path, player.Name, "<player>")
	message = string.gsub(message, player.Name, "<player>")
	errorRow("client", message, path)
end

-- ==========================================================
-- SERVER LAG AND REMOTE FLOODS
-- ==========================================================

local lastLagRow = -math.huge

local function statNumber(name: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	return if ok and type(value) == "number" then value else nil
end

local function lagRow(fps: number)
	counts.lags += 1
	local heartbeat = statNumber("HeartbeatTimeMs")
	local physics = statNumber("PhysicsStepTimeMs")
	local memory: number? = nil
	pcall(function()
		memory = Stats:GetTotalMemoryUsageMb()
	end)
	local chases = 0
	pcall(function()
		chases = #GuardianService.activeChaseRooms()
	end)
	local detail = `ver={game.PlaceVersion} fps={math.floor(fps + 0.5)} hb_ms={number(heartbeat, 1)} physics_ms={number(physics, 1)}`
		.. ` players={#Players:GetPlayers()} chases={chases} mem_mb={number(memory)}`
	PerfFeed.addRow("server-lag", "Server", detail, nil, nil, nil, nil, "n/a")
end

local rejects: { [Player]: { count: number, since: number, lastRow: number } } = {}

local function onReject(perSecond: number, burst: number, player: Player)
	local now = os.clock()
	local entry = rejects[player]
	if not entry then
		entry = { count = 0, since = now, lastRow = -math.huge }
		rejects[player] = entry
	end
	if now - entry.since > DiscordConfig.FLOOD_WINDOW then
		entry.count = 0
		entry.since = now
	end
	entry.count += 1
	if entry.count >= DiscordConfig.FLOOD_REJECTS and now - entry.lastRow >= DiscordConfig.FLOOD_COOLDOWN then
		entry.lastRow = now
		counts.floods += 1
		local limiter = `limiter {perSecond}/s burst {burst}`
		task.spawn(PerfFeed.addRow, "remote-flood", limiter,
			`user={player.UserId} rejected={entry.count} in {DiscordConfig.FLOOD_WINDOW}s`, nil, nil, nil, nil, "n/a")
	end
end

-- ==========================================================
-- DEBUG
-- ==========================================================

function PerfFeed.status(): { [string]: any }
	return {
		enabled = DiscordConfig.PERF_FEED,
		discordEnabled = DiscordReporter.isEnabled(),
		waiting = #rows,
		counts = table.clone(counts),
		recent = table.clone(recentRows),
	}
end

--- Flushes now (debug).
function PerfFeed.flushNow()
	flush()
end

-- ==========================================================
-- START
-- ==========================================================

function PerfFeed.start()
	local limiter = RateLimiter.new(PolishConfig.PERF_REPORT_PER_SECOND, PolishConfig.PERF_REPORT_BURST)
	Remotes.get("PerfReport").OnServerEvent:Connect(function(player, kind, payload)
		if type(kind) ~= "string" or type(payload) ~= "table" or not limiter:consume(player) then
			return
		end
		local ok: boolean, err: any = (pcall :: any)(function()
			if kind == "spike" then
				PerfFeed.spike(player, payload :: any)
			elseif kind == "error" then
				clientError(player, payload :: any)
			end
		end)
		if not ok then
			warn(`[PerfFeed] report from {player.Name} failed: {err}`)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
		perPlayer[player] = nil
		rejects[player] = nil
	end)

	ScriptContext.Error:Connect(function(message, _trace, scriptInstance)
		pcall(function()
			counts.serverErrors += 1
			errorRow("server", message, if scriptInstance then scriptInstance:GetFullName() else "?")
		end)
	end)

	RateLimiter.onReject = onReject

	-- Server frame rate, averaged per second.
	local frames, elapsed, lowFor = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt)
		frames += 1
		elapsed += dt
		if elapsed < 1 then
			return
		end
		local fps = frames / elapsed
		frames, elapsed = 0, 0
		if fps < DiscordConfig.SERVER_LAG_FPS then
			lowFor += 1
		else
			lowFor = 0
		end
		local now = os.clock()
		if lowFor >= DiscordConfig.SERVER_LAG_SECONDS and now - lastLagRow >= DiscordConfig.SERVER_LAG_COOLDOWN then
			lastLagRow = now
			lowFor = 0
			task.spawn(lagRow, fps)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(DiscordConfig.PERF_FLUSH_SECONDS)
			local ok: boolean, err: any = (pcall :: any)(flush)
			if not ok then
				warn(`[PerfFeed] flush failed: {err}`)
			end
		end
	end)
	game:BindToClose(function()
		pcall(flush)
	end)
end

return PerfFeed
