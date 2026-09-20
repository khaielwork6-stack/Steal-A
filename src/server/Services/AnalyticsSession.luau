--!strict
--[[
	AnalyticsSession  (analytics-discord)
	"Why do players leave?" - sessions, the context a player quit in, and the
	core-loop / feature-use custom events. Everything goes out through
	AnalyticsEvents (its budgets, its Studio gate, its dump); this module only
	decides WHAT to log. Started by AnalyticsEvents.start.

	HOW IT KNOWS THINGS - no service depends on it:
	  * ProgressEvents kinds, fired at each service's committed success path
	    (one line each): caught, robbed, storageFull, steal, revealed,
	    dailyStreak, questClaimed, seasonTier, tradeCompleted, fused,
	    gadgetUsed, spin, codeRedeemed.
	  * The laser trip's player attributes (LaserService sets LastLaserZone /
	    LastLaserRoom / LastLaserTrip) - watched, not hooked.
	  * A 2-second poll per player: where they are (zone and room, their own
	    base, someone else's base, the lobby), whether they carry loot, their
	    tutorial step, and when they last moved. The quit context is read from
	    this snapshot, because by PlayerRemoving the carry and the tutorial may
	    already have been torn down.
	  * The open MainUI panel, reported by the client (AnalyticsController)
	    through the existing rate-limited remote, name-checked by the server.

	THE QUIT EVENT. On leave exactly ONE of these is logged, first match wins,
	each with three fields a dashboard can break down by:
	  QuitInTutorial     step,        session length, session number
	  QuitAfterCatch     zone,        cause,          session number   (caught <= 60 s before)
	  QuitAfterRobbed    rarity lost, session length, session number   (robbed <= 120 s before)
	  QuitWhileCarrying  zone,        session length, session number
	  QuitInPanel        panel,       where,          session number
	  QuitIdle           where,       idle time,      session number   (no movement >= 120 s)
	  QuitActive         where,       session length, session number
	plus SessionEnd (value = seconds): session length, session number, the
	quit event's name - so one chart shows the split and each Quit* event
	shows the detail.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local AnalyticsEvents = require(script.Parent.AnalyticsEvents)
local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local ProgressEvents = require(script.Parent.ProgressEvents)
local TutorialService = require(script.Parent.TutorialService)

local AnalyticsSession = {}

local POLL_SECONDS = 2
local CATCH_WINDOW = 60
local ROBBED_WINDOW = 120
local IDLE_SECONDS = 120
local MOVE_STUDS = 4
local LASER_THROTTLE = 30
local STORAGE_THROTTLE = 30
local EPIC_RANK = RarityConfig.rank("Epic")

type Session = {
	player: Player,
	sid: string,
	started: number,
	number: number,
	kind: string,
	where: string,
	coarse: string,
	zone: number?,
	lastPosition: Vector3?,
	lastMoveAt: number,
	carrying: boolean,
	tutorialStep: string?,
	panel: string,
	lastCatch: { at: number, zone: string, cause: string }?,
	lastRobbed: { at: number, rarity: string }?,
	underSpeed: { [string]: true },
	laserAt: { [string]: number },
	storageAt: { [string]: number },
	ended: boolean,
}

local sessions: { [Player]: Session } = {}
local recentEnds: { any } = {}

-- ==========================================================
-- WHERE
-- ==========================================================

--- The zone band of a lane position (rooms, corridor and vault wings).
local function bandAt(position: Vector3): number?
	if position.Z < 0 or position.Z > MapConfig.LANE_END_Z or math.abs(position.X) > MapConfig.LANE_HALF then
		return nil
	end
	for index = 1, MapConfig.ZONE_COUNT do
		if position.Z <= MapConfig.zoneEndZ(index) then
			return index
		end
	end
	return nil
end

--- (fine label, coarse label, zone). Fine: "Z3-R2", "Z3-Vault",
--- "Z3-Corridor", "Base", "OtherBase", "Lobby", "None". Coarse (the analytics
--- field): "Z03", "Base", "OtherBase", "Lobby", "None".
function AnalyticsSession.locate(player: Player): (string, string, number?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return "None", "None", nil
	end
	local position = root.Position
	local band = bandAt(position)
	if band then
		local zone, room = Layout.locate(position)
		if zone and room then
			local fine = if room == Layout.VAULT_ROOM then `Z{zone}-Vault` else `Z{zone}-R{room}`
			return fine, AnalyticsEvents.zoneLabel(zone), zone
		end
		return `Z{band}-Corridor`, AnalyticsEvents.zoneLabel(band), band
	end
	local ok, plot = pcall(BaseService.plotAt, position)
	if ok and plot then
		if BaseService.getOwner(plot) == player then
			return "Base", "Base", nil
		end
		return "OtherBase", "OtherBase", nil
	end
	return "Lobby", "Lobby", nil
end

--- This player's short session id (Discord rows), or "none".
function AnalyticsSession.sid(player: Player): string
	local session = sessions[player]
	return if session then session.sid else "none"
end

local function gapBucket(power: number, recommended: number): string
	local ratio = if recommended > 0 then power / recommended else 1
	if ratio < 0.25 then
		return "<25%"
	elseif ratio < 0.5 then
		return "25-50%"
	elseif ratio < 0.75 then
		return "50-75%"
	end
	return "75-100%"
end

--- UnderSpeedAttempt once per zone and action per session.
local function checkUnderSpeed(session: Session, zone: number, action: string)
	local def = ZoneConfig.Zones[zone]
	local profile = DataService.get(session.player)
	if not def or not profile then
		return
	end
	local power = tonumber(profile.SpeedPower) or 0
	if def.recommendedSpeed <= 0 or power >= def.recommendedSpeed then
		return
	end
	local key = `{zone}:{action}`
	if session.underSpeed[key] then
		return
	end
	session.underSpeed[key] = true
	AnalyticsEvents.custom(session.player, "UnderSpeedAttempt", zone, {
		AnalyticsEvents.zoneLabel(zone),
		action,
		gapBucket(power, def.recommendedSpeed),
	})
end

local function poll(session: Session)
	local player = session.player
	local fine, coarse, zone = AnalyticsSession.locate(player)
	local previousZone = session.zone
	session.where = fine
	session.coarse = coarse
	session.zone = zone
	if zone and zone ~= previousZone then
		checkUnderSpeed(session, zone, "entered")
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local last = session.lastPosition
		if not last or (root.Position - last).Magnitude >= MOVE_STUDS then
			session.lastMoveAt = os.clock()
			session.lastPosition = root.Position
		end
	end

	session.carrying = CarryService.getCarried(player) ~= nil
	local state = TutorialService.getState(player)
	session.tutorialStep = if state and type(state.step) == "string" then state.step else nil
end

-- ==========================================================
-- SESSION START / END
-- ==========================================================

local function begin(player: Player)
	if sessions[player] or not DataService.waitForProfile(player) or not player.Parent then
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return
	end
	local life = (profile :: any).AnalyticsLife
	if type(life) ~= "table" then
		return
	end

	local firstJoin = tonumber(life.FirstJoin) or 0
	local isNew = (tonumber(life.Sessions) or 0) == 0 and firstJoin > 0
	life.Sessions = (tonumber(life.Sessions) or 0) + 1
	local today = os.time() // 86400
	local d1 = false
	if firstJoin > 0 and not life.D1Counted and today - firstJoin // 86400 == 1 then
		life.D1Counted = true
		d1 = true
	end
	local kind = if isNew then "new" elseif d1 then "d1return" elseif firstJoin > 0 then "returning" else "legacy"

	local session: Session = {
		player = player,
		sid = string.lower(string.sub(string.gsub(HttpService:GenerateGUID(false), "-", ""), 1, 10)),
		started = os.clock(),
		number = life.Sessions,
		kind = kind,
		where = "None",
		coarse = "None",
		zone = nil,
		lastPosition = nil,
		lastMoveAt = os.clock(),
		carrying = false,
		tutorialStep = nil,
		panel = "None",
		lastCatch = nil,
		lastRobbed = nil,
		underSpeed = {},
		laserAt = {},
		storageAt = {},
		ended = false,
	}
	sessions[player] = session
	poll(session)

	AnalyticsEvents.custom(player, "SessionStart", session.number, {
		AnalyticsEvents.sessionBucket(session.number),
		kind,
		AnalyticsEvents.zoneLabel(profile.HighestZoneReached),
	})
	AnalyticsEvents.emit("SessionStart", player, { number = session.number, kind = kind, new = isNew, d1 = d1 })
end

--- Picks the ONE quit event for this leave. Returns (name, fields).
local function quitContext(session: Session, seconds: number): (string, { string })
	local now = os.clock()
	local length = AnalyticsEvents.durationBucket(seconds)
	local number = AnalyticsEvents.sessionBucket(session.number)
	local step = session.tutorialStep
	if step then
		return "QuitInTutorial", { step, length, number }
	end
	local catch = session.lastCatch
	if catch and now - catch.at <= CATCH_WINDOW then
		return "QuitAfterCatch", { catch.zone, catch.cause, number }
	end
	local robbed = session.lastRobbed
	if robbed and now - robbed.at <= ROBBED_WINDOW then
		return "QuitAfterRobbed", { robbed.rarity, length, number }
	end
	if session.carrying then
		return "QuitWhileCarrying", { session.coarse, length, number }
	end
	if session.panel ~= "None" then
		return "QuitInPanel", { session.panel, session.coarse, number }
	end
	local idle = now - session.lastMoveAt
	if idle >= IDLE_SECONDS then
		return "QuitIdle", { session.coarse, AnalyticsEvents.durationBucket(idle), number }
	end
	return "QuitActive", { session.coarse, length, number }
end

local function finish(player: Player)
	local session = sessions[player]
	sessions[player] = nil
	if not session or session.ended then
		return
	end
	session.ended = true
	local seconds = math.max(0, math.floor(os.clock() - session.started))
	local name, fields = quitContext(session, seconds)
	AnalyticsEvents.custom(player, name, seconds, fields)
	AnalyticsEvents.custom(player, "SessionEnd", seconds, {
		AnalyticsEvents.durationBucket(seconds),
		AnalyticsEvents.sessionBucket(session.number),
		name,
	})
	local row = {
		player = player.Name,
		seconds = seconds,
		number = session.number,
		kind = session.kind,
		context = name,
		fields = fields,
		where = session.where,
	}
	table.insert(recentEnds, row)
	while #recentEnds > 20 do
		table.remove(recentEnds, 1)
	end
	AnalyticsEvents.emit("SessionEnd", player, {
		seconds = seconds,
		number = session.number,
		kind = session.kind,
		context = name,
		where = session.coarse,
	})
end

-- ==========================================================
-- CLIENT PANEL
-- ==========================================================

--- The open MainUI panel (already checked by AnalyticsEvents).
function AnalyticsSession.setPanel(player: Player, panel: string)
	local session = sessions[player]
	if session then
		session.panel = panel
	end
end

-- ==========================================================
-- CORE LOOP AND FEATURE LISTENERS
-- ==========================================================

local function sessionOf(player: Player): Session?
	return sessions[player]
end

local function onCaught(player: Player, _amount: number, info: { [string]: any })
	local zone = if info.zone == "Base" then "Base" else AnalyticsEvents.zoneLabel(info.zone)
	local cause = if type(info.cause) == "string" then info.cause else "guard"
	AnalyticsEvents.custom(player, "Caught", 1, { zone, cause, if info.carrying == true then "carrying" elseif info.carrying == false then "empty" else "unknown" })
	local session = sessionOf(player)
	if session then
		session.lastCatch = { at = os.clock(), zone = zone, cause = cause }
	end
	AnalyticsEvents.emit("Caught", player, { zone = zone, cause = cause })
end

local function onLaser(player: Player)
	local session = sessionOf(player)
	local zone = player:GetAttribute("LastLaserZone")
	local room = player:GetAttribute("LastLaserRoom")
	if not session or type(zone) ~= "number" then
		return
	end
	local roomLabel = if room == Layout.VAULT_ROOM then "Vault" elseif type(room) == "number" then `R{room}` else "R?"
	local key = `{zone}:{roomLabel}`
	local now = os.clock()
	if now - (session.laserAt[key] or -math.huge) < LASER_THROTTLE then
		return
	end
	session.laserAt[key] = now
	AnalyticsEvents.custom(player, "LaserTouched", 1, { AnalyticsEvents.zoneLabel(zone), roomLabel })
end

local function onStorageFull(player: Player, _amount: number, info: { [string]: any })
	local where = if type(info.where) == "string" then info.where else "unknown"
	local session = sessionOf(player)
	local now = os.clock()
	if session then
		if now - (session.storageAt[where] or -math.huge) < STORAGE_THROTTLE then
			return
		end
		session.storageAt[where] = now
	end
	AnalyticsEvents.custom(player, "StorageFullBlocked", 1, {
		where,
		if info.zone then AnalyticsEvents.zoneLabel(info.zone) else (if session then session.coarse else "None"),
	})
end

local function onSteal(player: Player, _amount: number, info: { [string]: any })
	local zone = tonumber(info.zone)
	local session = sessionOf(player)
	if zone and session then
		session.carrying = true
		checkUnderSpeed(session, zone, "stole")
	end
	if zone and info.vault == true then
		AnalyticsEvents.custom(player, "VaultSteal", zone, { AnalyticsEvents.zoneLabel(zone) })
	end
end

local function onRevealed(player: Player, _amount: number, info: { [string]: any })
	local rarity = if type(info.rarity) == "string" then info.rarity else "Unknown"
	local zone = AnalyticsEvents.zoneLabel(info.zone)
	local how = if info.auto == true then "auto" elseif info.quick == true then "quick" else "manual"
	AnalyticsEvents.custom(player, "Revealed", 1, { rarity, zone, how })
	local waited = tonumber(info.waited)
	if waited and waited >= 0 then
		AnalyticsEvents.custom(player, "RevealWait", waited, { AnalyticsEvents.waitBucket(waited), how, rarity })
	end
	AnalyticsEvents.emit("Revealed", player, { rarity = rarity, zone = zone, itemId = info.itemId, mutation = info.mutation })

	-- The once-in-a-life timings, for players whose first join is known.
	local profile = DataService.get(player)
	local life = if profile then (profile :: any).AnalyticsLife else nil
	if type(life) ~= "table" or (tonumber(life.FirstJoin) or 0) <= 0 then
		return
	end
	local since = math.max(0, os.time() - life.FirstJoin)
	if not life.FirstReveal then
		life.FirstReveal = true
		AnalyticsEvents.custom(player, "TimeToFirstReveal", since, { AnalyticsEvents.durationBucket(since), rarity })
	end
	if not life.FirstEpic and RarityConfig.rank(rarity) >= EPIC_RANK then
		life.FirstEpic = true
		AnalyticsEvents.custom(player, "FirstEpicReveal", since, { AnalyticsEvents.durationBucket(since), rarity })
	end
end

local function onRobbed(player: Player, _amount: number, info: { [string]: any })
	local rarity = if type(info.rarity) == "string" then info.rarity else "Unknown"
	AnalyticsEvents.custom(player, "Robbed", 1, { rarity })
	local session = sessionOf(player)
	if session then
		session.lastRobbed = { at = os.clock(), rarity = rarity }
	end
end

-- ==========================================================
-- DEBUG
-- ==========================================================

function AnalyticsSession.snapshot(): { [string]: any }
	local live = {}
	for player, session in sessions do
		local seconds = math.floor(os.clock() - session.started)
		local name, fields = quitContext(session, seconds)
		live[player.Name] = {
			sid = session.sid,
			number = session.number,
			kind = session.kind,
			seconds = seconds,
			where = session.where,
			carrying = session.carrying,
			tutorialStep = session.tutorialStep,
			panel = session.panel,
			idleSeconds = math.floor(os.clock() - session.lastMoveAt),
			lastCatch = session.lastCatch,
			lastRobbed = session.lastRobbed,
			wouldQuitAs = { name = name, fields = fields },
		}
	end
	return { live = live, recentEnds = table.clone(recentEnds) }
end

--- Studio: logs this player's quit event as if they left now, without
--- ending the session (the counters and the profile are untouched).
function AnalyticsSession.debugQuit(player: Player): { [string]: any }?
	local session = sessions[player]
	if not session then
		return nil
	end
	poll(session)
	local seconds = math.floor(os.clock() - session.started)
	local name, fields = quitContext(session, seconds)
	AnalyticsEvents.custom(player, name, seconds, fields)
	return { event = name, fields = fields, seconds = seconds }
end

-- ==========================================================
-- START
-- ==========================================================

function AnalyticsSession.start()
	AnalyticsEvents.onPanel = AnalyticsSession.setPanel
	ProgressEvents.on("caught", onCaught)
	ProgressEvents.on("storageFull", onStorageFull)
	ProgressEvents.on("steal", onSteal)
	ProgressEvents.on("revealed", onRevealed)
	ProgressEvents.on("robbed", onRobbed)
	ProgressEvents.on("dailyStreak", function(player, streak, info)
		local day = tonumber(info.day)
		AnalyticsEvents.custom(player, "DailyClaim", streak, { if day then `D{day}` else "D?", if streak >= 7 then "7+" else tostring(streak) })
	end)
	ProgressEvents.on("questClaimed", function(player, _amount, info)
		AnalyticsEvents.custom(player, "QuestClaim", 1, { tostring(info.period or "unknown") })
	end)
	ProgressEvents.on("seasonTier", function(player, tier, info)
		AnalyticsEvents.custom(player, "SeasonTier", tier, { `T{tier}`, tostring(info.track or "free") })
	end)
	ProgressEvents.on("tradeCompleted", function(player, _amount, info)
		local items = tonumber(info.items) or 0
		AnalyticsEvents.custom(player, "TradeCompleted", items, { if items <= 1 then `{items} items` elseif items <= 3 then "2-3 items" else "4+ items" })
	end)
	ProgressEvents.on("fused", function(player, _amount, info)
		AnalyticsEvents.custom(player, "Fusion", 1, { tostring(info.rarity or "Unknown") })
	end)
	ProgressEvents.on("gadgetUsed", function(player, _amount, info)
		local session = sessionOf(player)
		AnalyticsEvents.custom(player, "GadgetUsed", 1, { tostring(info.gadget or "unknown"), if session then session.coarse else "None" })
	end)
	ProgressEvents.on("spin", function(player)
		AnalyticsEvents.custom(player, "SpinUsed", 1)
	end)
	ProgressEvents.on("codeRedeemed", function(player, _amount, info)
		AnalyticsEvents.custom(player, "CodeRedeemed", 1, { tostring(info.code or "unknown") })
	end)
	-- [relic-roll] amount = roll count; info { bestRarity, bestItemId }.
	ProgressEvents.on("relicRoll", function(player, amount, info)
		AnalyticsEvents.custom(player, "RelicRoll", amount, { tostring(info.bestRarity or "Common"), tostring(info.bestItemId or "unknown"), `x{math.floor(amount)}` })
	end)

	local function onPlayer(player: Player)
		player:GetAttributeChangedSignal("LastLaserTrip"):Connect(function()
			local ok: boolean, err: any = (pcall :: any)(onLaser, player)
			if not ok then
				warn(`[AnalyticsSession] laser event failed: {err}`)
			end
		end)
		task.spawn(begin, player)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function(player)
		local ok: boolean, err: any = (pcall :: any)(finish, player)
		if not ok then
			warn(`[AnalyticsSession] session end failed for {player.Name}: {err}`)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(POLL_SECONDS)
			for _, session in table.clone(sessions) do
				local ok: boolean, err: any = (pcall :: any)(poll, session)
				if not ok then
					warn(`[AnalyticsSession] poll failed for {session.player.Name}: {err}`)
				end
			end
		end
	end)
end

return AnalyticsSession
