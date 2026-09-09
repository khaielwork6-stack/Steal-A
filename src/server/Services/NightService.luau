--!strict
--[[
	NightService
	The server-wide reset event: every NightConfig.CYCLE_SECONDS the world closes
	for NightConfig.NIGHT_SECONDS, everyone comes home, the unclaimed loot is
	rerolled, and then the race starts again.

	ONE CLOCK, AUTHORITATIVE TIMESTAMPS
	The cycle is a start timestamp on the server clock (workspace:GetServerTimeNow,
	which every client can also read). Phase changes happen when the clock
	crosses a boundary - not when a `task.wait(240)` wakes up - so a lagging
	server cannot fire two resets, a late joiner reads the current phase and the
	exact remaining time off ReplicatedStorage attributes the moment they arrive,
	and the countdown on every screen agrees with every other.

	WHAT "ALL ITEMS RESET" MEANS
	Unclaimed WORLD loot. Nothing a player has already earned is touched: placed
	trophies, storage, cash, upgrades and purchases are never part of this. A
	player carrying an item when Night falls keeps carrying it - the chase ends,
	they are brought home with everyone else, and they may walk it onto a slot.
	The refresh itself (LootService.refreshAll) only ever rerolls sockets whose
	occupant is sitting quietly in them; anything reserved, carried, dropped or
	returning is left alone. A failed generation is logged and the world still
	reopens with whatever it has.

	NO LEAN
	The Night refresh is LootService.refreshAll() with nothing passed in: the
	same weights, the same Scale bands and the same mutation table a server
	start uses. There is no rarity boost, no size boost, no mutation boost,
	no pity, no reroll and no jackpot. The regression tests assert it.

	GROWTH
	A placed item MATURES before it earns: growth credit accrues on each
	displayed item - one second per real second by day, thirty per second
	during the ten-second Night (300 in total) - and the item starts paying
	once its credit reaches its MaturationSeconds. Growth decides WHEN an item
	earns, never how much. Because it is stored as seconds it can never be
	applied twice to the same model.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local GuardianService = require(script.Parent.GuardianService)
local LootService = require(script.Parent.LootService)
local StateService = require(script.Parent.StateService)

local NightService = {}

export type Phase = "Day" | "Night"

local phase: Phase = "Day"
--- Server-clock time the current cycle began. Day runs from here for
--- CYCLE - NIGHT seconds, Night for the remaining NIGHT seconds.
local cycleStart = workspace:GetServerTimeNow()
--- Which cycle's refresh has run, so a hitch that skips straight past the
--- whole Night still refreshes exactly once and never twice.
local refreshedCycle = -1
local cycleNumber = 0
local warned = false

--- What the announcer will call out when the zones reopen.
type Spotlight = { text: string, style: string, score: number }
local pendingSpotlights: { Spotlight } = {}

-- ==========================================================
-- REPLICATION
-- ==========================================================

local function dayEndsAt(): number
	return cycleStart + NightConfig.CYCLE_SECONDS - NightConfig.NIGHT_SECONDS
end

local function nightEndsAt(): number
	return cycleStart + NightConfig.CYCLE_SECONDS
end

--- Everything a client needs to render the countdown, as attributes: they
--- replicate on their own, arrive with the initial snapshot for a late joiner,
--- and cost nothing per frame.
local function publish()
	ReplicatedStorage:SetAttribute("NightPhase", phase)
	ReplicatedStorage:SetAttribute("NightCycleStart", cycleStart)
	ReplicatedStorage:SetAttribute("NightPhaseEndsAt", if phase == "Day" then dayEndsAt() else nightEndsAt())
	ReplicatedStorage:SetAttribute("NightCycleSeconds", NightConfig.CYCLE_SECONDS)
	ReplicatedStorage:SetAttribute("NightSeconds", NightConfig.NIGHT_SECONDS)
end

function NightService.getPhase(): Phase
	return phase
end

function NightService.isNight(): boolean
	return phase == "Night"
end

--- Seconds until the current phase ends.
function NightService.remaining(): number
	local ends = if phase == "Day" then dayEndsAt() else nightEndsAt()
	return math.max(0, ends - workspace:GetServerTimeNow())
end

-- ==========================================================
-- THE RETURN HOME
-- ==========================================================

local function lobbyCentre(): Vector3
	local map = workspace:FindFirstChild("Map")
	local spawns = map and map:FindFirstChild("SpawnLocations")
	local lobby = spawns and spawns:FindFirstChild("LobbySpawn")
	if lobby and lobby:IsA("BasePart") then
		return lobby.Position
	end
	return Vector3.new(0, 0.5, -95)
end

--- Everyone to the middle of the lobby, spread on a ring so nobody spawns
--- inside anybody, facing up the lane toward the zones.
local function returnEveryone()
	local centre = lobbyCentre()
	local players = Players:GetPlayers()
	local count = math.max(#players, 1)
	for index, player in players do
		local character = player.Character
		local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
		if not character or not humanoid or humanoid.Health <= 0 then
			continue
		end
		local angle = (index - 1) / count * math.pi * 2
		local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * NightConfig.LOBBY_RING_RADIUS
		local at = centre + offset + Vector3.new(0, 4, 0)
		character:PivotTo(CFrame.lookAt(at, Vector3.new(at.X, at.Y, at.Z + 50)))
	end
end

-- ==========================================================
-- SPOTLIGHTS
-- ==========================================================

--- How exciting a spawn is, for ranking. Rarity dominates, then size, then
--- mutation - a Colossal Common and a Legendary Normal both make the cut, and
--- a Secret beats either.
local function score(loot: LootService.LootInstance): number
	return RarityConfig.rank(loot.rarity) * 10
		+ RarityConfig.sizeRank(loot.size) * 6
		+ RarityConfig.mutationRank(RarityConfig.normaliseMutation(loot.mutation)) * 2
end

--- ANNOUNCEMENT ONLY. This reads what the roller produced; nothing here can
--- change a roll, and a Secret rolls at exactly its zone weight whether or
--- not it is called out.
local function qualifies(loot: LootService.LootInstance): boolean
	return RarityConfig.rank(loot.rarity) >= RarityConfig.rank(NightConfig.SPOTLIGHT_MIN_RARITY)
		or RarityConfig.sizeRank(loot.size) >= RarityConfig.sizeRank(NightConfig.SPOTLIGHT_MIN_SIZE)
end

--- The colour treatment the toast wears. Secret and above: magenta. A
--- Colossal: gold. A Titan: violet. Everything else that qualified: gold
--- (Legendary / Mythic / Cosmic).
local function styleFor(loot: LootService.LootInstance): string
	if RarityConfig.rank(loot.rarity) >= RarityConfig.rank("Secret") then
		return "spotlight:magenta"
	end
	if loot.size == "Colossal" then
		return "spotlight:gold"
	end
	if loot.size == "Titan" then
		return "spotlight:violet"
	end
	return "spotlight:gold"
end

--- "A COLOSSAL Golden Teapot spawned in Grandma's House!" - built from the
--- instance's actual fields and the zone's display name, never a template.
local function describe(loot: LootService.LootInstance): string
	local zone = ZoneConfig.Zones[loot.zoneIndex]
	local zoneName = if zone then zone.name else "the world"

	local bits = {}
	if loot.size == "Colossal" then
		table.insert(bits, "COLOSSAL")
	elseif loot.size == "Titan" then
		table.insert(bits, "Titan")
	end
	local mutation = RarityConfig.normaliseMutation(loot.mutation)
	if mutation ~= "Normal" then
		table.insert(bits, mutation)
	end
	if RarityConfig.rank(loot.rarity) >= RarityConfig.rank("Legendary") then
		table.insert(bits, loot.rarity)
	end
	table.insert(bits, loot.name)

	local phrase = table.concat(bits, " ")
	local first = string.lower(string.sub(phrase, 1, 1))
	local article = if first == "a" or first == "e" or first == "i" or first == "o" or first == "u" then "An" else "A"
	return `{article} {phrase} spawned in {zoneName}!`
end

local function selectSpotlights(): { Spotlight }
	local picks: { Spotlight } = {}
	for _, loot in LootService.spawnedLoot() do
		if qualifies(loot) then
			table.insert(picks, { text = describe(loot), style = styleFor(loot), score = score(loot) })
		end
	end
	table.sort(picks, function(a, b)
		return a.score > b.score
	end)
	while #picks > NightConfig.SPOTLIGHT_MAX do
		table.remove(picks)
	end
	return picks
end

-- ==========================================================
-- THE REFRESH
-- ==========================================================

local function runRefresh()
	if refreshedCycle == cycleNumber then
		return
	end
	refreshedCycle = cycleNumber

	-- No arguments, no lean: the Night refresh IS the ordinary roll.
	local ok, result = pcall(LootService.refreshAll)
	if not ok then
		-- The world still reopens with whatever it has. Never leave it closed
		-- or empty over a bad roll.
		warn(`[NightService] loot refresh failed: {result}`)
		pendingSpotlights = {}
		return
	end
	local report = result :: LootService.RefreshReport
	pendingSpotlights = selectSpotlights()
	print(`[NightService] refreshed: {report.rerolled} rerolled, {report.filled} filled, {report.preservedInSocket} preserved, {#pendingSpotlights} spotlight(s)`)
end

--- THE SPAWN CALLS, THREE SECONDS BEFORE DAWN.
---
--- These used to go out after the world reopened, which put "a Mythic Golden
--- Drill spawned in Construction Site!" on screen while the player was already
--- running. They now land in the last SPOTLIGHT_LEAD_SECONDS of the Night, so
--- the player reads them against the barrier and moves the instant it lifts.
---
--- Once per cycle, whoever calls it: the timer fires it at the intended moment,
--- and endNight calls it again as a backstop for a Night that was cut short (a
--- forced day, a server hitch). The cycle guard is what stops the same spawn
--- being announced twice.
local spotlightsFlushedFor: number = -1

local function flushSpotlights()
	if spotlightsFlushedFor == cycleNumber then
		return
	end
	spotlightsFlushedFor = cycleNumber

	local spotlights = pendingSpotlights
	pendingSpotlights = {}
	if #spotlights == 0 then
		return
	end

	-- Everything has to be READ inside the lead, so the gap shrinks to fit
	-- rather than spilling into the day. Two calls at 2.5s apart is the
	-- authored cadence; three or more tighten up.
	local gap = math.min(NightConfig.SPOTLIGHT_GAP_SECONDS, NightConfig.SPOTLIGHT_LEAD_SECONDS / math.max(1, #spotlights))
	task.spawn(function()
		for index, spotlight in spotlights do
			if index > 1 then
				task.wait(gap)
			end
			StateService.announce("success", spotlight.text, spotlight.style, "NightSpawn")
		end
	end)
end

-- ==========================================================
-- TRANSITIONS
-- ==========================================================

local function beginNight()
	if phase == "Night" then
		return
	end
	phase = "Night"
	publish()

	-- Close first, so nothing can be started in the frames between here and
	-- the teleport. Then every steal in progress is cancelled - the item goes
	-- straight back to its socket, nobody carries anything into the lobby -
	-- every chase ends and every guardian is back on its post, and only
	-- then is anyone moved.
	LootService.setClosed(true)
	for _, player in Players:GetPlayers() do
		CarryService.cancelForNight(player)
	end
	GuardianService.resetAll()
	returnEveryone()

	StateService.announce("info", "NIGHT — LOOT REFRESHING", "night")

	-- The reroll happens while the zones are shut, a beat after the lights go
	-- down so the client has finished its transition before the world changes
	-- under it. Guarded so a Night that ends early still refreshes once.
	local thisCycle = cycleNumber
	task.delay(NightConfig.REFRESH_DELAY_SECONDS, function()
		if cycleNumber == thisCycle then
			runRefresh()
		end
	end)

	-- ...and the spawn calls, timed off the SAME clock the Night runs on, at
	-- the intended three seconds before it lifts. Never earlier: the refresh
	-- that decides what to announce has not happened yet.
	local announceAt = math.max(
		NightConfig.REFRESH_DELAY_SECONDS + 0.1,
		NightConfig.NIGHT_SECONDS - NightConfig.SPOTLIGHT_LEAD_SECONDS
	)
	task.delay(announceAt, function()
		if cycleNumber == thisCycle and phase == "Night" then
			flushSpotlights()
		end
	end)
end

local function endNight()
	if phase == "Day" then
		return
	end
	-- If a hitch carried the clock straight through the Night, the refresh
	-- has not happened yet: do it NOW, before reopening, atomically with it.
	runRefresh()

	-- BACKSTOP, AND IT HAS TO BE HERE - before the cycle number moves on.
	-- flushSpotlights is keyed to the cycle it flushed, so calling it after
	-- the increment stamped it with the NEXT cycle and silently suppressed
	-- that night's timed flush. Measured: every night after the first kept
	-- its two spawn calls queued until dawn. In the ordinary case the timer
	-- has already run three seconds ago and this does nothing.
	flushSpotlights()

	phase = "Day"
	cycleNumber += 1
	cycleStart = workspace:GetServerTimeNow()
	warned = false
	publish()

	LootService.setClosed(false)

	StateService.announce("success", "All loot refreshed! Go steal something!", "refresh", "Notification")

end

-- ==========================================================
-- GROWTH
-- ==========================================================

--- Advances every displayed item's growth credit. By day one second of
--- credit per real second; during the Night NIGHT_GROWTH_CREDIT_SECONDS are
--- spread over its NIGHT_SECONDS (thirty per second). Credit stops at the
--- item's own MaturationSeconds - there is nothing past "matured" - and the
--- owner's income is re-derived only in the tick an item crosses that line,
--- so the loop stays cheap.
local function tickGrowth(dt: number)
	local gain = dt * NightConfig.growthCreditPerSecond(phase == "Night")
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if not profile then
			continue
		end
		local matured = false
		for _, item in profile.DisplayItems do
			local needed = tonumber(item.MaturationSeconds) or 0
			local before = tonumber(item.GrowthSeconds) or 0
			if needed <= 0 or before >= needed then
				continue
			end
			local after = math.min(needed, before + gain)
			item.GrowthSeconds = after
			if after >= needed then
				matured = true
			end
		end
		if matured then
			EconomyService.recalculate(player)
			BaseService.rebuildDisplays(player)
			StateService.markDirty(player)
		end
	end
end

-- ==========================================================
-- DEBUG HOOKS
-- ==========================================================

function NightService.status(): { [string]: any }
	return {
		phase = phase,
		remaining = NightService.remaining(),
		cycle = cycleNumber,
		refreshedCycle = refreshedCycle,
		pendingSpotlights = #pendingSpotlights,
		closed = LootService.isClosed(),
	}
end

--- Moves the clock so the current Day ends in `seconds`. Test only.
function NightService.setDayRemaining(seconds: number)
	if phase ~= "Day" then
		return
	end
	cycleStart = workspace:GetServerTimeNow() + seconds - (NightConfig.CYCLE_SECONDS - NightConfig.NIGHT_SECONDS)
	warned = seconds <= NightConfig.WARNING_SECONDS
	publish()
end

function NightService.forceNight()
	-- Re-anchor the cycle so the forced Night lasts exactly NIGHT_SECONDS and
	-- every countdown reads it, instead of whatever was left of the Day.
	cycleStart = workspace:GetServerTimeNow() - (NightConfig.CYCLE_SECONDS - NightConfig.NIGHT_SECONDS)
	beginNight()
end

function NightService.forceDay()
	endNight()
end

-- ==========================================================
-- START
-- ==========================================================

function NightService.start()
	publish()

	-- The scheduler. Polls the server clock four times a second and acts on
	-- boundaries; the phase flag makes every transition idempotent.
	task.spawn(function()
		while true do
			task.wait(0.25)
			local now = workspace:GetServerTimeNow()
			if phase == "Day" then
				local ends = dayEndsAt()
				if not warned and now >= ends - NightConfig.WARNING_SECONDS then
					warned = true
					StateService.announce("info", `NIGHT FALLS IN {NightConfig.WARNING_SECONDS} SECONDS`, "night")
				end
				if now >= ends then
					beginNight()
				end
			else
				if now >= nightEndsAt() then
					endNight()
				end
			end
		end
	end)

	-- Growth, on its own slower cadence.
	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(NightConfig.GROWTH_TICK_SECONDS)
			local now = os.clock()
			tickGrowth(now - last)
			last = now
		end
	end)

	print(`[NightService] cycle {NightConfig.CYCLE_SECONDS}s with a {NightConfig.NIGHT_SECONDS}s Night; first Night in {math.floor(NightService.remaining())}s`)
end

return NightService
