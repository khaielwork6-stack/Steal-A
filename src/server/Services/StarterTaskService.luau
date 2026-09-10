--!strict
--[[
	StarterTaskService
	The three-row beginner checklist: Steal 1 Item, Reveal 1 Item, Train Once.

	COMPLETION IS AN EVENT, NOT A POLL. Each row is completed by the one
	service that already knows the real thing happened, calling `complete` from
	inside the successful path:

	    steal   CarryService.trySteal, after the item is reserved, attached and
	            the carry is live. Not a touch, not a prompt, not a request -
	            the point past which the player is genuinely carrying it.
	    reveal  HatchService.commit, after `Hatched` has been flipped. The
	            reveal is real by then and cannot be un-done.
	    train   SpeedService's training tick, on a tick that actually paid
	            Speed on the player's own treadmill.

	Wiring it that way rather than watching counters is what makes the rows
	honest: there is no state a client can put itself into that looks like a
	steal, and no way to complete "Train Once" without the server having
	already paid for a tick of training.

	EACH ROW PAYS ONCE, EVER. The flag is written into `Profile.StarterTasks`
	BEFORE the reward is granted, so a duplicate call - a re-entrant trigger, a
	rejoin mid-grant, two events in one frame - finds it set and returns. The
	profile is saved immediately after, so a crash cannot lose a row that has
	already paid.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local StarterTaskConfig = require(ReplicatedStorage.Shared.Config.StarterTaskConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local SpeedService = require(script.Parent.SpeedService)
local StateService = require(script.Parent.StateService)

local StarterTaskService = {}

--- Players whose closing delay is already running, so the third completion
--- cannot start two of them.
local closing: { [Player]: boolean } = {}

-- ==========================================================
-- THE ROWS
-- ==========================================================

--- Completes one row and pays it. Safe to call from anywhere, as often as the
--- gameplay path happens to fire: everything after the first time is a no-op.
function StarterTaskService.complete(player: Player, key: string)
	-- SWITCHED OFF: nothing is granted AND nothing is flagged. Returning before
	-- the write is what makes the pause free - a row is not silently spent
	-- while the checklist is not there to show it being earned.
	if not StarterTaskConfig.ENABLED then
		return
	end
	local task_ = StarterTaskConfig.ByKey[key]
	if not task_ then
		return
	end
	local profile = DataService.get(player)
	if not profile or profile.StarterTasksClosed then
		return
	end
	if profile.StarterTasks[key] then
		return
	end

	-- FLAG FIRST, and with no yield before it. Everything below is the reward;
	-- a second caller arriving mid-grant finds this set and stops.
	profile.StarterTasks[key] = true

	if task_.kind == "cash" then
		-- Exactly the figure the row advertises. Not `earn`: the 2x Cash pass
		-- would turn a "$500" row into $1,000 and the checklist would be
		-- telling a lie to the players most likely to notice.
		EconomyService.award(player, task_.amount, "other")
	else
		profile.SpeedPower += task_.amount
		SpeedService.applyMovement(player)
	end

	local reward = if task_.kind == "cash"
		then NumberFormat.cash(task_.amount)
		else `+{NumberFormat.short(task_.amount)} Speed`
	StateService.notify(player, "success", `{string.upper(task_.text)}  ·  {reward}`, "levelup")
	StateService.pushNow(player)

	-- Durable the moment it has paid, rather than at the next autosave.
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end

	-- THE LAST ROW. The checklist stays on the push for a moment so the
	-- client's completion animation has something to animate, and is then
	-- retired for good.
	if StarterTaskConfig.isComplete(profile.StarterTasks) and not closing[player] then
		closing[player] = true
		task.delay(StarterTaskConfig.CLOSE_DELAY, function()
			closing[player] = nil
			local current = DataService.get(player)
			if not current or current.StarterTasksClosed then
				return
			end
			current.StarterTasksClosed = true
			if player.Parent then
				StateService.pushNow(player)
			end
			if DataService.isPersistent() then
				task.spawn(DataService.save, player)
			end
		end)
	end
end

-- ==========================================================
-- REPLICATION
-- ==========================================================

--- What the checklist renders, on the same push everything else rides.
--- Returns nil once the checklist is finished and gone, which is what tells
--- the client to remove it - and, on a later session, never to build it.
function StarterTaskService.summarise(player: Player): { [string]: any }?
	-- Nil is already the client's "this checklist is gone" answer, so the
	-- switch needs no client change at all: a panel that is up is torn down on
	-- the next push and one that never existed is never built.
	if not StarterTaskConfig.ENABLED then
		return nil
	end
	local profile = DataService.get(player)
	if not profile or profile.StarterTasksClosed then
		return nil
	end
	local done: { [string]: boolean } = {}
	for _, task_ in StarterTaskConfig.Tasks do
		done[task_.key] = profile.StarterTasks[task_.key] == true
	end
	return { done = done, complete = StarterTaskConfig.isComplete(profile.StarterTasks) }
end

function StarterTaskService.start()
	StateService.addProvider("starter", StarterTaskService.summarise)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		closing[player] = nil
	end)

	if StarterTaskConfig.ENABLED then
		print(`[StarterTaskService] {#StarterTaskConfig.Tasks} beginner tasks online`)
	else
		print("[StarterTaskService] beginner tasks DISABLED (StarterTaskConfig.ENABLED = false)")
	end
end

--- Debug only: puts the checklist back so it can be walked through again.
function StarterTaskService.debugReset(player: Player): boolean
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	profile.StarterTasks = {}
	profile.StarterTasksClosed = false
	closing[player] = nil
	StateService.pushNow(player)
	return true
end

return StarterTaskService
