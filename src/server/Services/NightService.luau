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

	THE LEAN
	The Night refresh rolls with NightConfig.refreshBoosts(): a modest multiplier
	on high rarities and on Huge-or-larger sizes, renormalised, applied for that
	one generation and removed before this function returns. The independence of
	rarity, mutation and size is untouched.

	GROWTH
	Owned trophies mature: seconds of effective growth accrue on each displayed
	item (five times faster during Night), capped, saved on the item, and turned
	into a small income and size bonus by EconomyService / BaseService. Because
	it is stored as seconds it can never be applied twice to the same model.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local BaseService = require(script.Parent.BaseService)
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

local function qualifies(loot: LootService.LootInstance): boolean
	if loot.jackpot then
		return false -- already announced, loudly, by LootService.onJackpot
	end
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

	local ok, result = pcall(LootService.refreshAll, NightConfig.refreshBoosts())
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
	-- the teleport. Then every chase ends and every guardian is back on its
	-- post before anyone is moved.
	LootService.setClosed(true)
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
end

local function endNight()
	if phase == "Day" then
		return
	end
	-- If a hitch carried the clock straight through the Night, the refresh
	-- has not happened yet: do it NOW, before reopening, atomically with it.
	runRefresh()

	phase = "Day"
	cycleNumber += 1
	cycleStart = workspace:GetServerTimeNow()
	warned = false
	publish()

	LootService.setClosed(false)

	StateService.announce("success", "All loot refreshed! Go steal something!", "refresh", "Notification")

	-- Then the best of what actually spawned, one at a time, so each lands.
	local spotlights = pendingSpotlights
	pendingSpotlights = {}
	if #spotlights > 0 then
		task.spawn(function()
			for _, spotlight in spotlights do
				task.wait(NightConfig.SPOTLIGHT_GAP_SECONDS)
				StateService.announce("success", spotlight.text, spotlight.style, "NewDiscovery")
			end
		end)
	end
end

-- ==========================================================
-- GROWTH
-- ==========================================================

local function growthBucket(seconds: number): number
	return math.floor(math.clamp(seconds / NightConfig.GROWTH_FULL_SECONDS, 0, 1) * NightConfig.GROWTH_STEPS)
end

local function tickGrowth(dt: number)
	local rate = if phase == "Night" then NightConfig.GROWTH_NIGHT_MULTIPLIER else 1
	local gain = dt * rate
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if not profile then
			continue
		end
		local changed = false
		for _, item in profile.DisplayItems do
			local before = tonumber(item.GrowthSeconds) or 0
			if before >= NightConfig.GROWTH_FULL_SECONDS then
				continue
			end
			local after = math.min(NightConfig.GROWTH_FULL_SECONDS, before + gain)
			item.GrowthSeconds = after
			if growthBucket(after) ~= growthBucket(before) then
				changed = true
			end
		end
		-- Income and the visual are only re-derived when an item crosses a
		-- growth step, so the loop stays cheap and the trophies do not jitter.
		if changed then
			EconomyService.recalculate(player)
			BaseService.applyGrowth(player)
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
