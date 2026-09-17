--!strict
--[[
	WorldIndex
	One pass over the workspace, one DescendantAdded, shared by every client
	controller that needs "every X in the world, now and later".

	WHY
	AudioController (Sounds -> SFX group), InteractController (ProximityPrompts
	-> Custom style) and HatchController (RevealCard billboards -> owner only)
	each ran workspace:GetDescendants() at start and kept their own
	workspace.DescendantAdded connection - three full scans of a map with tens
	of thousands of instances, and three handlers on every instance that ever
	replicates. Sounds and prompts can live anywhere (lobby models, the Slap
	cage, guardians), so scoping each scan to one folder was not safe; one
	shared index is.

	HOW
	The watched classes are declared here. The first watch() does the one
	scan and connects the one listener; every instance of a watched class is
	kept in a set (removed again when it leaves the workspace), so a
	controller that starts later replays from the set instead of rescanning.
	Matching is by exact ClassName, which is O(1) per replicated instance.

	  WorldIndex.watch("Sound", fn)   fn(instance) for every Sound now in
	                                   the workspace and every one added later.
]]

local WorldIndex = {}

--- The classes anyone may watch. Add a class here before watching it.
local CLASSES = { "Sound", "ProximityPrompt", "BillboardGui" }

local sets: { [string]: { [Instance]: true } } = {}
local handlers: { [string]: { (Instance) -> () } } = {}
for _, className in CLASSES do
	sets[className] = {}
	handlers[className] = {}
end

local built = false

local function build()
	if built then
		return
	end
	built = true
	for _, descendant in workspace:GetDescendants() do
		local set = sets[descendant.ClassName]
		if set then
			set[descendant] = true
		end
	end
	workspace.DescendantAdded:Connect(function(descendant)
		local className = descendant.ClassName
		local set = sets[className]
		if not set then
			return
		end
		set[descendant] = true
		for _, fn in handlers[className] do
			task.spawn(fn, descendant)
		end
	end)
	workspace.DescendantRemoving:Connect(function(descendant)
		local set = sets[descendant.ClassName]
		if set then
			set[descendant] = nil
		end
	end)
end

function WorldIndex.watch(className: string, fn: (Instance) -> ())
	local set = sets[className]
	assert(set, `WorldIndex: "{className}" is not a watched class - add it to CLASSES`)
	build()
	table.insert(handlers[className], fn)
	for instance in set do
		task.spawn(fn, instance)
	end
end

return WorldIndex
