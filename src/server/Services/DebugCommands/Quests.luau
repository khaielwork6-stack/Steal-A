--!strict
--[[
	DebugCommands.Quests
	Studio-only test commands for the retention pass (daily/weekly quests and
	the season pass). Invoke through
	ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...).

	PROFILE SAFETY. Studio with API access writes to the owner's REAL
	DataStore, and these commands are meant to be used interactively (complete
	a quest, then click CLAIM in the panel). So the first command that changes
	anything takes a SNAPSHOT of every field this area can touch, and:
	  * `questRestore` puts it back (and saves),
	  * leaving the game (or stopping Play) restores it automatically, inside
	    the leave path, before the final save,
	  * a command that throws restores it on the spot.
	`questSnapshot` takes a fresh snapshot explicitly; `questKeep` forgets it
	(keeps the test changes).

	  questShow                         both quest lists + the season record
	  questComplete <daily|weekly> <i>  set quest i's progress to its target
	  questCompleteAll                  every quest in both lists
	  questClaim <daily|weekly> <i>     claim through the real path
	  questNewDay / questNewWeek        move this player's calendar one period
	                                    on (session only) -> a new list
	  questCalendarReset                back to the real calendar
	  questEvent <event> [amount] [info] fire a ProgressEvents event as if the
	                                    game had. Event names are in
	                                    QuestConfig.EVENT_FOR_KIND, e.g.
	                                    stealDelivered, chaseEscape, revealed
	                                    "rarity=Epic", pvpHit "weapon=Bat,
	                                    knockedLoot=true", earn "source=sell"
	  seasonXp <amount>                 add season XP (no caps, no calendar)
	  seasonClaim <tier|all> [free|premium|both]
	                                    claim through the real path
	  seasonPremium <on|off|real>       pin premium ownership (the pass id
	                                    must be > 0 for "on" to matter)
	  seasonActive <on|off>             pretend the season is live / real
	  questSnapshot / questRestore / questKeep
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local SeasonPassConfig = require(ReplicatedStorage.Shared.Config.SeasonPassConfig)

local DataService = require(script.Parent.Parent.DataService)
local ProgressEvents = require(script.Parent.Parent.ProgressEvents)
local QuestService = require(script.Parent.Parent.QuestService)
local SeasonPassService = require(script.Parent.Parent.SeasonPassService)

-- Movement, state pushes, the guardian bay and premium ownership go through
-- the hooks init.server injects (see SeasonPassService.hooks).
local hooks = SeasonPassService.hooks

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

--- Everything a quest or tier claim can change.
local SNAPSHOT_FIELDS = {
	"Quests",
	"Season",
	"Titles",
	"Cash",
	"SpeedPower",
	"GuardiansWon",
	"EquippedGuardian",
	"TrailsOwned",
	"EquippedTrail",
	"Lifetime",
}

local snapshots: { [Player]: { [string]: any } } = {}
local releaseHooked = false

local function restoreInto(player: Player, profile: DataService.Profile, snap: { [string]: any })
	for _, field in SNAPSHOT_FIELDS do
		(profile :: any)[field] = copy(snap[field])
	end
	QuestService.debugResetCalendar(player)
	SeasonPassService.debugForceActive(false)
end

local function hookRelease()
	if releaseHooked then
		return
	end
	releaseHooked = true
	-- Runs inside the leave path immediately before the final save, so a
	-- Studio session that simply stops still leaves the real profile as it was.
	DataService.onBeforeRelease(function(player, profile)
		local snap = snapshots[player]
		if snap then
			snapshots[player] = nil
			restoreInto(player, profile, snap)
			print(`[DebugCommands.Quests] restored {player.Name}'s profile before the leave-save`)
		end
	end)
end

local function takeSnapshot(player: Player, profile: DataService.Profile)
	local snap: { [string]: any } = {}
	for _, field in SNAPSHOT_FIELDS do
		snap[field] = copy((profile :: any)[field])
	end
	snapshots[player] = snap
	hookRelease()
end

local function restore(player: Player): boolean
	local profile = DataService.get(player)
	local snap = snapshots[player]
	if not profile or not snap then
		return false
	end
	snapshots[player] = nil
	restoreInto(player, profile, snap)
	hooks.refreshMovement(player)
	-- A guardian won from a tier leaves the bay again.
	hooks.syncGuardian(player)
	hooks.pushState(player)
	QuestService.pushNow(player, true)
	if DataService.isPersistent() then
		DataService.save(player)
	end
	return true
end

--- Runs `body`, snapshotting first (once) and restoring if it throws.
local function mutating(player: Player, body: (DataService.Profile) -> any): any
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	if not snapshots[player] then
		takeSnapshot(player, profile)
	end
	local ok, result = pcall(body, profile)
	if not ok then
		local restored = restore(player)
		return { error = tostring(result), restored = restored }
	end
	QuestService.pushNow(player, true)
	hooks.pushState(player)
	return { result = result, snapshotHeld = true, note = "run questRestore (or leave) to undo; questKeep to keep" }
end

local function period(value: any): string?
	if value == "daily" or value == "weekly" then
		return value
	end
	return nil
end

local commands: { [string]: (Player, ...any) -> any } = {}

commands.questShow = function(player: Player)
	return {
		quests = QuestService.inspect(player),
		season = SeasonPassService.inspect(player),
		snapshotHeld = snapshots[player] ~= nil,
		premiumPassId = MonetizationConfig.SeasonPremiumPass.gamePassId,
	}
end

commands.questComplete = function(player: Player, kind: any, index: any)
	local which = period(kind)
	local i = tonumber(index)
	if not which or not i then
		return { error = "usage: questComplete <daily|weekly> <index>" }
	end
	return mutating(player, function()
		return QuestService.debugComplete(player, which, i)
	end)
end

commands.questCompleteAll = function(player: Player)
	return mutating(player, function()
		local done = 0
		for _, which in { "daily", "weekly" } do
			for i = 1, 3 do
				if QuestService.debugComplete(player, which, i) then
					done += 1
				end
			end
		end
		return done
	end)
end

commands.questClaim = function(player: Player, kind: any, index: any)
	return mutating(player, function()
		local ok, reason = QuestService.claim(player, kind, tonumber(index))
		return { claimed = ok, reason = reason }
	end)
end

commands.questNewDay = function(player: Player)
	return mutating(player, function()
		return { newPeriod = QuestService.debugAdvance(player, "daily") }
	end)
end

commands.questNewWeek = function(player: Player)
	return mutating(player, function()
		return { newPeriod = QuestService.debugAdvance(player, "weekly") }
	end)
end

commands.questCalendarReset = function(player: Player)
	QuestService.debugResetCalendar(player)
	QuestService.pushNow(player, true)
	return { reset = true, note = "stored lists regenerate for the real period on the next check" }
end

commands.questEvent = function(player: Player, kind: any, amount: any, infoText: any)
	if type(kind) ~= "string" then
		return { error = "usage: questEvent <kind> [amount] [key=value,key=value]" }
	end
	local info: { [string]: any } = {}
	if type(infoText) == "string" then
		for key, value in string.gmatch(infoText, "(%w+)=([^,]+)") do
			if value == "true" then
				info[key] = true
			elseif value == "false" then
				info[key] = false
			else
				info[key] = tonumber(value) or value
			end
		end
	end
	return mutating(player, function()
		ProgressEvents.fire(player, kind, tonumber(amount) or 1, info)
		-- Listeners run on their own threads; give them a frame.
		task.wait()
		return QuestService.inspect(player)
	end)
end

commands.seasonXp = function(player: Player, amount: any)
	local value = tonumber(amount)
	if not value then
		return { error = "usage: seasonXp <amount>" }
	end
	return mutating(player, function()
		return { added = SeasonPassService.debugAddXp(player, value), season = SeasonPassService.inspect(player) }
	end)
end

commands.seasonClaim = function(player: Player, tierArg: any, trackArg: any)
	local tracks: { string } = if trackArg == "free" or trackArg == "premium" then { trackArg } else { "free", "premium" }
	local tiers: { number } = {}
	if tierArg == "all" then
		for tier = 1, SeasonPassConfig.TIER_COUNT do
			table.insert(tiers, tier)
		end
	elseif tonumber(tierArg) then
		table.insert(tiers, tonumber(tierArg) :: number)
	else
		return { error = "usage: seasonClaim <tier|all> [free|premium|both]" }
	end
	return mutating(player, function()
		local results = {}
		for _, tier in tiers do
			for _, track in tracks do
				local ok, reason = SeasonPassService.claim(player, tier, track)
				if ok or reason then
					table.insert(results, { tier = tier, track = track, ok = ok, reason = reason })
				end
			end
		end
		return results
	end)
end

commands.seasonPremium = function(player: Player, mode: any)
	local id = MonetizationConfig.SeasonPremiumPass.gamePassId
	if id <= 0 then
		return { error = "SeasonPremiumPass.gamePassId is 0 (placeholder): premium stays 'coming soon'" }
	end
	if mode == "on" or mode == "off" then
		hooks.setPremiumForTesting(player, mode == "on")
	else
		-- nil: re-read the real answer from Roblox (yields briefly).
		hooks.setPremiumForTesting(player, nil)
	end
	QuestService.pushNow(player, true)
	return { owned = hooks.ownsPremium(player), mode = mode or "real" }
end

commands.seasonActive = function(player: Player, mode: any)
	SeasonPassService.debugForceActive(mode == "on")
	QuestService.pushNow(player, true)
	return { forced = mode == "on", live = SeasonPassConfig.isActive(os.time()) }
end

commands.questSnapshot = function(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	takeSnapshot(player, profile)
	return { snapshotHeld = true }
end

commands.questRestore = function(player: Player)
	return { restored = restore(player) }
end

commands.questKeep = function(player: Player)
	local had = snapshots[player] ~= nil
	snapshots[player] = nil
	QuestService.debugResetCalendar(player)
	return { forgot = had, note = "test changes are kept and will be saved" }
end

return commands
