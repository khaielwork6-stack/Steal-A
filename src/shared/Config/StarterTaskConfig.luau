--!strict
--[[
	StarterTaskConfig
	The three-row beginner checklist: what it asks for, what it pays, and the
	order the rows appear in.

	ONE-TIME AND PER-PLAYER. Each key is written into `Profile.StarterTasks`
	the moment its reward is granted and is never granted again - see
	StarterTaskService, which is the only thing allowed to complete one.

	The keys are DURABLE. They are saved on the profile, so renaming one
	silently un-completes that row for everybody who had already done it. Add
	a row rather than repurposing a key.
]]

local StarterTaskConfig = {}

--- THE SWITCH. Set this back to true to bring the checklist back.
---
--- While it is false the feature is inert rather than removed: no panel is
--- built, no row is completed and NO REWARD IS GRANTED. That last part is the
--- point - nothing is quietly consumed while it is off, so a player who had
--- ticked one row before it was disabled still has exactly that row ticked
--- when it comes back, and a player who joined during the pause starts with
--- all three still to earn. Turning it off and on again costs nobody a reward.
---
--- Everything below stays as it is: the rows, the wording, the amounts, the
--- profile fields and the three gameplay hooks in init.server. This is the
--- only line that decides whether any of it runs.
---
--- Back ON (owner decision, 2026-09-11) as part of the early-progression pass:
--- three small rewards for three things every new player does in their first
--- minute. Desktop keeps its original bottom-right block; touch shows one task
--- at a time in the top strip (StarterTaskController).
StarterTaskConfig.ENABLED = true

export type Kind = "cash" | "speed"

export type Task = {
	key: string,
	--- The row's instruction, as the player reads it.
	text: string,
	--- The reward chip beside it.
	reward: string,
	kind: Kind,
	amount: number,
}

StarterTaskConfig.Tasks = {
	{ key = "steal", text = "Steal 1 Item", reward = "$500", kind = "cash", amount = 500 },
	{ key = "reveal", text = "Reveal 1 Item", reward = "500 Speed", kind = "speed", amount = 500 },
	{ key = "train", text = "Train Once", reward = "250 Speed", kind = "speed", amount = 250 },
} :: { Task }

StarterTaskConfig.HEADING = "STARTER TASKS"

--- Seconds the finished checklist stays on screen after the last row is
--- ticked, so the completion animation has somewhere to play. The server
--- stops sending the checklist once this has elapsed and it never returns.
StarterTaskConfig.CLOSE_DELAY = 3.4

StarterTaskConfig.ByKey = {} :: { [string]: Task }
for _, task in StarterTaskConfig.Tasks do
	StarterTaskConfig.ByKey[task.key] = task
end

function StarterTaskConfig.isComplete(done: { [string]: boolean }?): boolean
	if not done then
		return false
	end
	for _, task in StarterTaskConfig.Tasks do
		if not done[task.key] then
			return false
		end
	end
	return true
end

return StarterTaskConfig
