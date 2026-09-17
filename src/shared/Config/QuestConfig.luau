--!strict
--[[
	QuestConfig
	Daily and weekly quests (retention pass): the template pools, how targets
	and rewards scale, and the calendar the two lists reset on.

	HOW A PERIOD'S LIST IS CHOSEN
	`generate` is a pure function of (template pool, seed, player context).
	The seed is derived from the UserId and the period number, so the same
	player sees the same three quests however often they rejoin that day - and
	the list is ALSO saved in the profile (QuestService), so a later change to
	their progress (a new zone, a higher income) cannot reshuffle quests they
	have already started. At most one quest per `kind` is picked per list.

	CALENDAR (all UTC, from os.time):
	  daily   resets at 00:00 UTC. Period = whole days since the Unix epoch.
	  weekly  resets on Monday 00:00 UTC. Period = whole weeks since the
	          Monday before the epoch (1970-01-01 was a Thursday, hence +3).

	TEMPLATE IDS ARE DURABLE. They are saved on the profile; renaming one
	drops that quest from any list that holds it (QuestService discards
	unknown ids). Add a template rather than repurposing an id.

	REWARDS ARE READ AT CLAIM TIME, like the Cash packs: cash is minutes of
	the player's BASE income (MonetizationConfig.baseIncome - no 2x pass, no
	server boosts), Speed a fraction of the next zone gate
	(SpinWheelConfig.nextGate), each with a floor and (Speed) a cap. The caps
	match the spin wheel's so quests never move the Zone 8+ wall.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local QuestConfig = {}

--- THE SWITCH. False: no quests are generated, nothing progresses, the HUD
--- button and panel are not built. Saved progress is left untouched.
QuestConfig.ENABLED = true

QuestConfig.DAILY_COUNT = 3
QuestConfig.WEEKLY_COUNT = 3

--- Season pass XP paid by one claimed quest (SeasonPassConfig reads these).
QuestConfig.SEASON_XP = { daily = 100, weekly = 400 }

--- Which EconomyService source tags count towards "earn $X". Gameplay only:
--- purchases, offline earnings, debug grants and quest/season rewards do not.
QuestConfig.EARN_SOURCES = { passive = true, sell = true, discovery = true } :: { [string]: boolean }

--- Remote limits (token bucket per player: per second, burst).
QuestConfig.CLAIM_PER_SECOND = 2
QuestConfig.CLAIM_BURST = 4
QuestConfig.SYNC_PER_SECOND = 1
QuestConfig.SYNC_BURST = 3

--- Seconds between QuestPush flushes for a player whose quest state changed.
--- Progress from income ticks changes every second; this keeps the panel
--- live without sending more than one packet a second.
QuestConfig.PUSH_INTERVAL = 1

-- ==========================================================
-- REWARDS
-- ==========================================================

--- "daily" or "weekly". A plain string: singleton unions do not survive
--- table literals in the type checker, and every entry point validates it.
export type Period = string

export type RewardScale = {
	--- Cash = max(cashFloor, baseIncome x cashMinutes x 60).
	cashMinutes: number,
	cashFloor: number,
	--- Speed = min(speedCap, max(speedFloor, nextGate x speedFraction)).
	speedFraction: number,
	speedFloor: number,
	speedCap: number,
}

QuestConfig.Rewards = {
	daily = { cashMinutes = 10, cashFloor = 2500, speedFraction = 0.005, speedFloor = 250, speedCap = 500e3 },
	weekly = { cashMinutes = 60, cashFloor = 15000, speedFraction = 0.02, speedFloor = 2500, speedCap = 5e6 },
} :: { [Period]: RewardScale }

-- ==========================================================
-- TEMPLATES
-- ==========================================================

--- What a quest counts. Each maps to one ProgressEvents kind.
export type Kind = "steal" | "escape" | "reveal" | "train" | "earn" | "bat" | "trap" | "discover" | "spin"

--- The event names are this pass's own (ProgressEvents is shared with the
--- social pass, whose "steal" / "escape" / "reveal" fire at other moments;
--- reusing those names would count every event twice after the merge):
---   stealDelivered  PlacementService.place - a museum container placed at home
---   chaseEscape     GuardianService - the chasing guard sees the red line
---   revealed        HatchService.commit's swap moment { rarity, itemId }
---   train           SpeedService tick that paid (amount = seconds)
---   earn            EconomyService.award { source }
---   pvpHit          PvPService.resolveSwing { weapon, knockedLoot }
---   trapPlaced      PvPService.tryPlaceTrap
---   discover        IndexService.onDiscovered { itemId }
---   spin            SpinWheelService spin spent { index }
--- QuestService / SeasonPassService also fire questCompleted, questClaimed
--- and seasonTier for other listeners.
QuestConfig.EVENT_FOR_KIND = {
	steal = "stealDelivered",
	escape = "chaseEscape",
	reveal = "revealed",
	train = "train",
	earn = "earn",
	bat = "pvpHit",
	trap = "trapPlaced",
	discover = "discover",
	spin = "spin",
} :: { [string]: string }

export type Template = {
	--- Durable id (saved on the profile).
	id: string,
	kind: Kind,
	--- "{n}" is replaced with the formatted target, "{rarity}" with minRarity.
	text: string,
	weight: number,
	--- Target range, inclusive, in `step`s. For "train" these are seconds; for
	--- "earn" they are ignored in favour of `earnMinutes`.
	min: number,
	max: number,
	step: number?,
	--- earn: target = max(min, baseIncome x earnMinutes x 60), rounded.
	earnMinutes: number?,
	--- steal: only containers of at least this rarity count. Such a quest is
	--- counted when the container is REVEALED (the rarity is sealed until
	--- then - see QuestConfig.eventFor), so it reads "Steal & reveal".
	minRarity: string?,
	--- bat: only hits that knocked carried loot loose count.
	requireLoot: boolean?,
	--- Not offered until the player's HighestZoneReached is at least this.
	minZone: number?,
	--- Multiplies both rewards (harder quests pay more).
	rewardScale: number?,
	--- A placeholder art key for the quest-type icon (QuestConfig.Icons).
	icon: string?,
}

QuestConfig.Daily = {
	{ id = "d_steal", kind = "steal", text = "Steal {n} containers", weight = 10, min = 3, max = 6 },
	{ id = "d_steal_rare", kind = "steal", text = "Steal & reveal {n} {rarity}+ containers", weight = 5, min = 1, max = 2, minRarity = "Rare", minZone = 2, rewardScale = 1.25 },
	{ id = "d_escape", kind = "escape", text = "Escape a guard chase {n} times", weight = 8, min = 2, max = 4 },
	{ id = "d_reveal", kind = "reveal", text = "Reveal {n} containers", weight = 8, min = 2, max = 5 },
	{ id = "d_train", kind = "train", text = "Train on your treadmill for {n}", weight = 8, min = 120, max = 300, step = 60 },
	{ id = "d_earn", kind = "earn", text = "Earn {n}", weight = 8, min = 2000, max = 2000, earnMinutes = 10 },
	{ id = "d_bat", kind = "bat", text = "Hit players with your bat {n} times", weight = 4, min = 3, max = 5 },
	{ id = "d_knock", kind = "bat", text = "Knock loot out of a thief's hands {n} time(s)", weight = 2, min = 1, max = 1, requireLoot = true, minZone = 2, rewardScale = 1.5 },
	{ id = "d_trap", kind = "trap", text = "Place {n} traps", weight = 4, min = 2, max = 3 },
	{ id = "d_discover", kind = "discover", text = "Discover {n} new Index item(s)", weight = 3, min = 1, max = 1, rewardScale = 1.25 },
	{ id = "d_spin", kind = "spin", text = "Spin the free wheel {n} time(s)", weight = 6, min = 1, max = 2 },
} :: { Template }

QuestConfig.Weekly = {
	{ id = "w_steal", kind = "steal", text = "Steal {n} containers", weight = 10, min = 25, max = 40, step = 5 },
	{ id = "w_steal_epic", kind = "steal", text = "Steal & reveal {n} {rarity}+ containers", weight = 5, min = 3, max = 5, minRarity = "Epic", minZone = 3, rewardScale = 1.25 },
	{ id = "w_escape", kind = "escape", text = "Escape a guard chase {n} times", weight = 8, min = 15, max = 25, step = 5 },
	{ id = "w_reveal", kind = "reveal", text = "Reveal {n} containers", weight = 8, min = 20, max = 30, step = 5 },
	{ id = "w_train", kind = "train", text = "Train on your treadmill for {n}", weight = 8, min = 1800, max = 3600, step = 600 },
	{ id = "w_earn", kind = "earn", text = "Earn {n}", weight = 8, min = 50000, max = 50000, earnMinutes = 120 },
	{ id = "w_bat", kind = "bat", text = "Hit players with your bat {n} times", weight = 4, min = 20, max = 30, step = 5 },
	{ id = "w_trap", kind = "trap", text = "Place {n} traps", weight = 4, min = 10, max = 15, step = 5 },
	{ id = "w_discover", kind = "discover", text = "Discover {n} new Index items", weight = 3, min = 3, max = 5 },
	{ id = "w_spin", kind = "spin", text = "Spin the free wheel {n} times", weight = 6, min = 8, max = 12, step = 2 },
} :: { Template }

QuestConfig.Pools = { daily = QuestConfig.Daily, weekly = QuestConfig.Weekly } :: { [Period]: { Template } }
QuestConfig.COUNTS = { daily = QuestConfig.DAILY_COUNT, weekly = QuestConfig.WEEKLY_COUNT } :: { [Period]: number }

QuestConfig.ById = {} :: { [string]: Template }
for _, pool in { QuestConfig.Daily, QuestConfig.Weekly } do
	for _, template in pool do
		QuestConfig.ById[template.id] = template
	end
end

--- Quest-type icons. "rbxassetid://0" means "no art yet": the client draws a
--- short text glyph instead. Codex fills these (docs/codex-prompts/
--- retention-quests-pass.md, section "Quest type icons").
QuestConfig.Icons = {
	steal = "rbxassetid://0",
	escape = "rbxassetid://0",
	reveal = "rbxassetid://0",
	train = "rbxassetid://0",
	earn = "rbxassetid://0",
	bat = "rbxassetid://0",
	trap = "rbxassetid://0",
	discover = "rbxassetid://0",
	spin = "rbxassetid://0",
} :: { [string]: string }

--- The HUD "Quests" button icon. 0 = keep the art of the BASE button it is
--- cloned from (QuestController).
QuestConfig.HUD_ICON = "rbxassetid://0"

--- The text glyph drawn while an icon is still 0.
QuestConfig.Glyphs = {
	steal = "STEAL",
	escape = "RUN",
	reveal = "OPEN",
	train = "TRAIN",
	earn = "$",
	bat = "BAT",
	trap = "TRAP",
	discover = "NEW",
	spin = "SPIN",
} :: { [string]: string }

-- ==========================================================
-- CALENDAR
-- ==========================================================

local DAY = 86400
local WEEK = 7 * DAY

--- Whole UTC days since the epoch.
function QuestConfig.dayOf(t: number): number
	return math.floor(t / DAY)
end

--- Whole Monday-based weeks since the epoch. The epoch was a Thursday, so
--- day 4 (Monday 1970-01-05) starts week 1.
function QuestConfig.weekOf(t: number): number
	return math.floor((QuestConfig.dayOf(t) + 3) / 7)
end

function QuestConfig.periodOf(kind: Period, t: number): number
	return if kind == "daily" then QuestConfig.dayOf(t) else QuestConfig.weekOf(t)
end

--- Unix second at which `period` ENDS (the next reset).
function QuestConfig.resetAt(kind: Period, period: number): number
	if kind == "daily" then
		return (period + 1) * DAY
	end
	return (period + 1) * WEEK - 3 * DAY
end

-- ==========================================================
-- GENERATION
-- ==========================================================

export type Context = {
	highestZone: number,
	--- MonetizationConfig.baseIncome at generation time.
	baseIncome: number,
	--- Index items not yet discovered.
	undiscovered: number,
}

export type Entry = { id: string, target: number }

--- A deterministic seed from the player and the period. Kept well inside the
--- 2^53 range Random.new accepts exactly.
function QuestConfig.seedFor(userId: number, kind: Period, period: number): number
	local salt = if kind == "daily" then 7919 else 104729
	return (math.abs(math.floor(userId)) % 2147483647) * 131 + period * 1000003 + salt
end

--- Rounds a Cash target to two significant figures so it reads cleanly.
local function roundNice(value: number): number
	if value < 100 then
		return math.max(1, math.floor(value + 0.5))
	end
	local magnitude = 10 ^ (math.floor(math.log10(value)) - 1)
	return math.floor(value / magnitude + 0.5) * magnitude
end

local function eligible(template: Template, context: Context): boolean
	if template.weight <= 0 then
		return false
	end
	if template.minZone and context.highestZone < template.minZone then
		return false
	end
	if template.kind == "discover" and context.undiscovered < template.min then
		return false
	end
	return true
end

local function targetFor(template: Template, rng: Random, context: Context): number
	if template.kind == "earn" then
		local scaled = math.max(0, tonumber(context.baseIncome) or 0) * (template.earnMinutes or 0) * 60
		if scaled ~= scaled or scaled == math.huge then
			scaled = 0
		end
		return roundNice(math.max(template.min, scaled))
	end
	local step = math.max(1, template.step or 1)
	local steps = math.max(0, math.floor((template.max - template.min) / step))
	local value = template.min + rng:NextInteger(0, steps) * step
	if template.kind == "discover" then
		value = math.min(value, context.undiscovered)
	end
	return math.max(1, math.floor(value))
end

--- Picks `count` quests from `pool`: weighted, without replacement, at most
--- one per kind. Pure: the same inputs always give the same list.
function QuestConfig.generate(pool: { Template }, count: number, seed: number, context: Context): { Entry }
	local rng = Random.new(seed)
	local candidates: { Template } = {}
	for _, template in pool do
		if eligible(template, context) then
			table.insert(candidates, template)
		end
	end
	local out: { Entry } = {}
	local usedKinds: { [string]: boolean } = {}
	while #out < count do
		local total = 0
		for _, template in candidates do
			if not usedKinds[template.kind] then
				total += template.weight
			end
		end
		if total <= 0 then
			break
		end
		local roll = rng:NextNumber() * total
		local picked: Template? = nil
		for _, template in candidates do
			if not usedKinds[template.kind] then
				roll -= template.weight
				if roll <= 0 then
					picked = template
					break
				end
			end
		end
		if not picked then
			-- Floating-point remainder: take the last unused one.
			for index = #candidates, 1, -1 do
				if not usedKinds[candidates[index].kind] then
					picked = candidates[index]
					break
				end
			end
		end
		if not picked then
			break
		end
		usedKinds[picked.kind] = true
		table.insert(out, { id = picked.id, target = targetFor(picked, rng, context) })
	end
	return out
end

-- ==========================================================
-- PRESENTATION + FILTERS
-- ==========================================================

local function duration(seconds: number): string
	if seconds >= 3600 and seconds % 3600 == 0 then
		return `{seconds // 3600}h`
	elseif seconds >= 3600 then
		return `{seconds // 3600}h {(seconds % 3600) // 60}m`
	elseif seconds >= 60 then
		return `{seconds // 60}m`
	end
	return `{seconds}s`
end
QuestConfig.formatDuration = duration

--- A target or progress figure, in the unit its kind counts.
function QuestConfig.formatAmount(template: Template, value: number): string
	if template.kind == "train" then
		return duration(math.floor(value))
	elseif template.kind == "earn" then
		return NumberFormat.cash(math.floor(value))
	end
	return tostring(math.floor(value))
end

function QuestConfig.describe(template: Template, target: number): string
	-- `%` is special in a gsub replacement; escape it in the inserted text.
	local amount = string.gsub(QuestConfig.formatAmount(template, target), "%%", "%%%%")
	local rarity = string.gsub(template.minRarity or "", "%%", "%%%%")
	local text = string.gsub(template.text, "{n}", amount)
	text = string.gsub(text, "{rarity}", rarity)
	return text
end

--- The ProgressEvents kind that advances `template`. A rarity-filtered steal
--- listens to "reveal": a sealed container's rarity is secret until then, and
--- every container revealed on a base was stolen from the museum.
function QuestConfig.eventFor(template: Template): string
	if template.kind == "steal" and template.minRarity then
		return QuestConfig.EVENT_FOR_KIND.reveal
	end
	return QuestConfig.EVENT_FOR_KIND[template.kind]
end

--- Whether one ProgressEvents payload counts for `template`.
function QuestConfig.accepts(template: Template, info: { [string]: any }): boolean
	if template.kind == "steal" and template.minRarity then
		return RarityConfig.rank(info.rarity) >= RarityConfig.rank(template.minRarity)
	elseif template.kind == "bat" then
		if info.weapon ~= "Bat" and info.weapon ~= "Slap" then
			return false
		end
		if template.requireLoot then
			return info.knockedLoot == true
		end
		return true
	elseif template.kind == "earn" then
		return QuestConfig.EARN_SOURCES[tostring(info.source)] == true
	end
	return true
end

--- The reward one claim pays right now.
function QuestConfig.rewardFor(period: Period, template: Template?, baseIncome: number, nextGate: number): (number, number)
	local scale = QuestConfig.Rewards[period] or QuestConfig.Rewards.daily
	local factor = if template and template.rewardScale then template.rewardScale else 1
	local income = tonumber(baseIncome) or 0
	if income ~= income or income == math.huge or income < 0 then
		income = 0
	end
	local cash = math.max(scale.cashFloor, income * scale.cashMinutes * 60) * factor
	local gate = tonumber(nextGate) or 0
	if gate ~= gate or gate == math.huge or gate < 0 then
		gate = 0
	end
	-- The cap applies AFTER the harder-quest factor, so no quest can pay more
	-- Speed than the cap however it is scaled.
	local speed = math.min(scale.speedCap, math.max(scale.speedFloor, gate * scale.speedFraction) * factor)
	return math.floor(cash), math.floor(speed)
end

return QuestConfig
