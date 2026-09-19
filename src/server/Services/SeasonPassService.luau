--!strict
--[[
	SeasonPassService
	Season XP, tiers and the free / premium reward tracks (retention pass).
	Tuning lives in SeasonPassConfig; the UI is QuestController's PASS tab and
	its data rides QuestService's QuestPush.

	PROFILE: `Profile.Season`
	    id              SeasonPassConfig.SEASON_ID this record belongs to. A
	                    different id (a new season) resets the whole record.
	    xp              season XP
	    claimedFree     { ["<tier>"] = true }   STRING keys: a sparse table
	    claimedPremium  { ["<tier>"] = true }   with number keys does not
	                                            survive a DataStore round trip
	    xpDay           the UTC day dayXp / dayStealXp belong to
	    dayXp           XP counted against DAILY_XP_CAP today
	    dayStealXp      steal XP counted against DAILY_STEAL_XP_CAP today

	EACH TIER REWARD PAYS ONCE PER SEASON. The claimed flag is written BEFORE
	the reward is granted, with no yield in between, and the profile is saved
	straight after - the StarterTaskService rule. A reward whose grant throws
	stays flagged (lost, not doubled), the same trade the spin wheel makes.

	PREMIUM is read from MonetizationService.ownsSeasonPremium (a cached Game
	Pass check, injected as `hooks.ownsPremium`). It is never stored here, so a refund is honoured, and a
	mid-season purchase makes every premium tier already reached claimable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local SeasonPassConfig = require(ReplicatedStorage.Shared.Config.SeasonPassConfig)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ProgressEvents = require(script.Parent.ProgressEvents)

local SeasonPassService = {}

--- EVERYTHING ELSE IS INJECTED by init.server (the codebase's usual pattern)
--- by setting the FIELDS of this table (never replacing the table itself),
--- so the retention services depend only on DataService / EconomyService and
--- no gameplay service ever depends on them. QuestService uses the same
--- hooks. The defaults are safe no-ops ("owns nothing", "granted nothing").
export type Hooks = {
	notify: (Player, string, string, string?) -> (),
	pushState: (Player) -> (),
	markStateDirty: (Player) -> (),
	refreshMovement: (Player) -> (),
	ownsPremium: (Player) -> boolean,
	ownsTrail: (Player, string) -> boolean,
	--- BaseGuardianService.grantWon: false when already owned.
	grantGuardian: (Player, string) -> boolean,
	--- Debug only: re-seat the guardian bay after a restore.
	syncGuardian: (Player) -> (),
	--- Debug only: MonetizationService.setOwnedForTesting / refreshOwnership.
	setPremiumForTesting: (Player, boolean?) -> (),
}

SeasonPassService.hooks = {
	notify = function(_player: Player, _kind: string, _message: string, _cue: string?) end,
	pushState = function(_player: Player) end,
	markStateDirty = function(_player: Player) end,
	refreshMovement = function(_player: Player) end,
	ownsPremium = function(_player: Player): boolean
		return false
	end,
	ownsTrail = function(_player: Player, _key: string): boolean
		return false
	end,
	grantGuardian = function(_player: Player, _key: string): boolean
		return false
	end,
	syncGuardian = function(_player: Player) end,
	setPremiumForTesting = function(_player: Player, _owned: boolean?) end,
} :: Hooks

local hooks = SeasonPassService.hooks

export type Track = "free" | "premium"

export type Season = {
	id: string,
	xp: number,
	claimedFree: { [string]: boolean },
	claimedPremium: { [string]: boolean },
	xpDay: number,
	dayXp: number,
	dayStealXp: number,
}

--- Called whenever a player's season state changes. Installed by
--- QuestService (which owns the QuestPush); injected to keep the two acyclic.
SeasonPassService.onChanged = function(_player: Player) end

--- Records already sanitised this session (weak: a replaced record is
--- simply checked again).
local checked: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- Studio only: pretend the season is live whatever the calendar says.
local forceActive = false

-- ==========================================================
-- THE RECORD
-- ==========================================================

local function finite(value: any): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return value
end

local function cleanClaims(value: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(value) ~= "table" then
		return out
	end
	for key, flag in value do
		local tier = tonumber(key)
		if flag == true and tier and tier == math.floor(tier) and tier >= 1 and tier <= SeasonPassConfig.TIER_COUNT then
			out[tostring(tier)] = true
		end
	end
	return out
end

local function fresh(): Season
	return {
		id = SeasonPassConfig.SEASON_ID,
		xp = 0,
		claimedFree = {},
		claimedPremium = {},
		xpDay = 0,
		dayXp = 0,
		dayStealXp = 0,
	}
end

--- This season's record for `profile`, created or reset as needed.
local function current(profile: DataService.Profile): Season
	local raw: any = profile.Season
	if type(raw) ~= "table" or raw.id ~= SeasonPassConfig.SEASON_ID then
		local season = fresh()
		profile.Season = season :: any
		checked[season] = true
		return season
	end
	if not checked[raw] then
		raw.xp = math.max(0, math.floor(finite(raw.xp)))
		raw.claimedFree = cleanClaims(raw.claimedFree)
		raw.claimedPremium = cleanClaims(raw.claimedPremium)
		raw.xpDay = math.floor(finite(raw.xpDay))
		raw.dayXp = math.max(0, finite(raw.dayXp))
		raw.dayStealXp = math.max(0, finite(raw.dayStealXp))
		checked[raw] = true
	end
	return raw :: Season
end

local function isActive(): boolean
	return forceActive or SeasonPassConfig.isActive(os.time())
end

local function premiumAvailable(): boolean
	return MonetizationConfig.SeasonPremiumPass.gamePassId > 0
end

local function ownsPremium(player: Player): boolean
	return hooks.ownsPremium(player)
end

local function baseIncome(player: Player): number
	return MonetizationConfig.baseIncome(EconomyService.getIncome(player), EconomyService.cashMultiplierFor(player))
end

-- ==========================================================
-- XP
-- ==========================================================

--- "daily" | "weekly" | "steal" | "debug" (a plain string for the checker).
export type XpSource = string

--- Adds season XP and returns how much was actually added (0 outside the
--- season, or once a daily cap is reached). Weekly-quest and debug XP are
--- exempt from the caps.
function SeasonPassService.addXp(player: Player, amount: number, source: XpSource): number
	if not SeasonPassConfig.ENABLED or not isActive() then
		return 0
	end
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	local value = math.floor(finite(amount))
	if value <= 0 then
		return 0
	end
	local season = current(profile)

	local today = QuestConfig.dayOf(os.time())
	if season.xpDay ~= today then
		season.xpDay = today
		season.dayXp = 0
		season.dayStealXp = 0
	end
	if source == "steal" then
		value = math.min(value, SeasonPassConfig.DAILY_STEAL_XP_CAP - season.dayStealXp)
	end
	if source == "daily" or source == "steal" then
		value = math.min(value, SeasonPassConfig.DAILY_XP_CAP - season.dayXp)
	end
	if value <= 0 then
		return 0
	end

	local before = SeasonPassConfig.tierFor(season.xp)
	season.xp += value
	if source == "steal" then
		season.dayStealXp += value
	end
	if source == "daily" or source == "steal" then
		season.dayXp += value
	end
	local after = SeasonPassConfig.tierFor(season.xp)
	if after > before then
		hooks.notify(player, "success", `SEASON PASS TIER {after} REACHED! Claim it in Quests.`, "levelup")
		-- The HUD red dot rides StatePush.
		hooks.markStateDirty(player)
	end
	SeasonPassService.onChanged(player)
	return value
end


--- A PAID TIER SKIP (owner, 2026-09-18). Sets the season XP to the next
--- tier's threshold, so the reward on that tier is claimable at once. Called
--- only from a delivered receipt (MonetizationService, kind "Skip"); refuses
--- with a reason when there is nothing to deliver, and the receipt then
--- converts to Cash rather than being swallowed.
---
--- Both tracks share the ONE tier ladder, so the two products advance the
--- same number; the premium skip additionally requires premium, because the
--- reward it is advertising is on the premium track.
function SeasonPassService.skipTier(player: Player, track: string): (boolean, string?)
	if not SeasonPassConfig.ENABLED or not isActive() then
		return false, "the season is not running"
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "no profile"
	end
	if track == "premium" and not ownsPremium(player) then
		return false, "premium skip without premium"
	end
	local season = current(profile)
	local tier = SeasonPassConfig.tierFor(season.xp)
	if tier >= SeasonPassConfig.TIER_COUNT then
		return false, "already at the top tier"
	end
	season.xp = math.max(season.xp, SeasonPassConfig.Thresholds[tier + 1])
	hooks.notify(player, "success", `TIER {tier + 1} UNLOCKED! Claim it in the Season Pass.`, "levelup")
	hooks.markStateDirty(player)
	SeasonPassService.onChanged(player)
	return true
end

-- ==========================================================
-- CLAIMS
-- ==========================================================

--- Pays one reward. Returns the player-facing line.
local function grant(player: Player, profile: DataService.Profile, reward: SeasonPassConfig.Reward): string
	if reward.kind == "cash" then
		local amount = SeasonPassConfig.amountFor(reward, baseIncome(player), SpinWheelConfig.nextGate(profile.HighestZoneReached))
		-- Exactly the figure shown: `award`, not `earn` (no 2x pass on a reward).
		EconomyService.award(player, amount, "season")
		return NumberFormat.cash(amount)
	elseif reward.kind == "speed" then
		local amount = SeasonPassConfig.amountFor(reward, baseIncome(player), SpinWheelConfig.nextGate(profile.HighestZoneReached))
		profile.SpeedPower += amount
		hooks.refreshMovement(player)
		return `+{NumberFormat.short(amount)} Speed`
	elseif reward.kind == "guardian" and reward.guardianKey then
		local key = reward.guardianKey
		if hooks.grantGuardian(player, key) then
			return `the {key} Guardian`
		end
		-- Already owned (pass, wheel or an earlier season): never a blank.
		profile.SpeedPower += SeasonPassConfig.DUPLICATE_GUARDIAN_SPEED
		hooks.refreshMovement(player)
		return `+{NumberFormat.short(SeasonPassConfig.DUPLICATE_GUARDIAN_SPEED)} Speed (you own the {key} Guardian)`
	elseif reward.kind == "trail" and reward.trailKey then
		local key = reward.trailKey
		local def = MonetizationConfig.TrailByKey[key]
		if def and not hooks.ownsTrail(player, key) then
			profile.TrailsOwned[key] = true
			return `the {def.name}`
		end
		profile.SpeedPower += SeasonPassConfig.DUPLICATE_GUARDIAN_SPEED
		hooks.refreshMovement(player)
		return `+{NumberFormat.short(SeasonPassConfig.DUPLICATE_GUARDIAN_SPEED)} Speed (trail already owned)`
	elseif reward.kind == "title" and reward.title then
		profile.Titles[reward.title] = true
		return `the title "{reward.title}"`
	end
	return "nothing"
end

--- Claims one tier's reward on one track. Returns false plus an optional
--- player-facing reason. Idempotent: a second claim is a silent no-op.
function SeasonPassService.claim(player: Player, tierArg: any, trackArg: any): (boolean, string?)
	if not SeasonPassConfig.ENABLED then
		return false
	end
	local tier = Validate.integer(tierArg, 1, SeasonPassConfig.TIER_COUNT)
	if not tier or (trackArg ~= "free" and trackArg ~= "premium") then
		return false
	end
	local track: Track = trackArg
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local season = current(profile)
	local def = SeasonPassConfig.Tiers[tier]
	if not def then
		return false
	end
	if SeasonPassConfig.tierFor(season.xp) < tier then
		return false, `Reach tier {tier} first!`
	end
	if track == "premium" then
		if not premiumAvailable() then
			return false, "Season Pass Premium is coming soon!"
		end
		if not ownsPremium(player) then
			return false, "That reward is for Season Pass Premium owners."
		end
	end
	local claims = if track == "free" then season.claimedFree else season.claimedPremium
	local key = tostring(tier)
	if claims[key] then
		return false
	end

	-- FLAG FIRST, no yield before it.
	claims[key] = true
	local reward = if track == "free" then def.free else def.premium
	local ok, result = pcall(grant, player, profile, reward)
	if not ok then
		warn(`[SeasonPassService] tier {tier} {track} grant failed for {player.Name}: {result}`)
		return false, "Something went wrong - please tell the developers."
	end

	hooks.notify(player, "success", `TIER {tier} REWARD  ·  {result}`, "levelup")
	ProgressEvents.fire(player, "seasonTier", tier, { track = track })
	hooks.pushState(player)
	SeasonPassService.onChanged(player)
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
	return true
end

-- ==========================================================
-- REPLICATION
-- ==========================================================

--- Rewards waiting to be claimed (the HUD red dot).
function SeasonPassService.claimableCount(player: Player): number
	if not SeasonPassConfig.ENABLED then
		return 0
	end
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	local season = current(profile)
	local reached = SeasonPassConfig.tierFor(season.xp)
	local premium = premiumAvailable() and ownsPremium(player)
	local count = 0
	for tier = 1, reached do
		local key = tostring(tier)
		if not season.claimedFree[key] then
			count += 1
		end
		if premium and not season.claimedPremium[key] then
			count += 1
		end
	end
	return count
end

--- The PASS tab's data. Reward wording comes from the shared config; only
--- the live cash / speed figures are computed here.
function SeasonPassService.summarise(player: Player): { [string]: any }?
	if not SeasonPassConfig.ENABLED then
		return nil
	end
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local season = current(profile)
	local income = baseIncome(player)
	local gate = SpinWheelConfig.nextGate(profile.HighestZoneReached)
	local freeAmounts: { number } = {}
	local premiumAmounts: { number } = {}
	local claimedFree: { boolean } = {}
	local claimedPremium: { boolean } = {}
	for tier, def in SeasonPassConfig.Tiers do
		freeAmounts[tier] = SeasonPassConfig.amountFor(def.free, income, gate)
		premiumAmounts[tier] = SeasonPassConfig.amountFor(def.premium, income, gate)
		claimedFree[tier] = season.claimedFree[tostring(tier)] == true
		claimedPremium[tier] = season.claimedPremium[tostring(tier)] == true
	end
	return {
		id = SeasonPassConfig.SEASON_ID,
		active = isActive(),
		startsAt = SeasonPassConfig.STARTS_AT,
		endsAt = SeasonPassConfig.ENDS_AT,
		xp = season.xp,
		tier = SeasonPassConfig.tierFor(season.xp),
		dayXp = season.dayXp,
		premiumAvailable = premiumAvailable(),
		premiumOwned = ownsPremium(player),
		freeAmounts = freeAmounts,
		premiumAmounts = premiumAmounts,
		claimedFree = claimedFree,
		claimedPremium = claimedPremium,
	}
end

function SeasonPassService.start()
	if not SeasonPassConfig.ENABLED then
		print("[SeasonPassService] season pass DISABLED (SeasonPassConfig.ENABLED = false)")
		return
	end
	-- A completed museum steal is worth a little season XP.
	-- The DELIVERED steal (QuestConfig.EVENT_FOR_KIND), not the pickup.
	ProgressEvents.on(QuestConfig.EVENT_FOR_KIND.steal, function(player, amount)
		SeasonPassService.addXp(player, SeasonPassConfig.STEAL_XP * math.clamp(tonumber(amount) or 0, 0, 10), "steal")
	end)
	print(
		`[SeasonPassService] season {SeasonPassConfig.SEASON_ID} "{SeasonPassConfig.SEASON_NAME}" online`
			.. ` ({if isActive() then "live" else "not live"}; premium id {MonetizationConfig.SeasonPremiumPass.gamePassId})`
	)
end

-- ==========================================================
-- DEBUG (DebugCommands/Quests)
-- ==========================================================

--- Adds XP with no caps and no calendar check. Studio only (the caller is).
function SeasonPassService.debugAddXp(player: Player, amount: number): number
	local wasForced = forceActive
	forceActive = true
	local added = SeasonPassService.addXp(player, amount, "debug")
	forceActive = wasForced
	return added
end

function SeasonPassService.debugForceActive(on: boolean)
	forceActive = on
end

function SeasonPassService.inspect(player: Player): { [string]: any }?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local season = current(profile)
	return {
		record = season,
		titles = profile.Titles,
		claimable = SeasonPassService.claimableCount(player),
		premiumAvailable = premiumAvailable(),
		premiumOwned = ownsPremium(player),
		active = isActive(),
	}
end

return SeasonPassService
