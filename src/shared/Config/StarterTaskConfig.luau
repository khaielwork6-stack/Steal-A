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
