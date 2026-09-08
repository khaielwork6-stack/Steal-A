--!strict
--[[
	RobPromptController
	Shows the STEAL prompts on OTHER players' trophies and hides them on
	your own. HeistService creates one disabled RobPrompt per occupied
	display slot; `Enabled` set on the client is local, so every player sees
	exactly the prompts that apply to them:

	  * never on a plot you own,
	  * never on an unowned plot,
	  * never while the item's protection (ProtectedUntil) has not run out.

	Presentation only: the server re-checks every rule when the hold lands.
	BasePromptController does the same job for the owner's own prompts and
	skips these by name.
]]

local Players = game:GetService("Players")

local RobPromptController = {}

local player = Players.LocalPlayer

local PROMPT_NAME = "RobPrompt"
--- How often protection expiry is re-checked. Prompts also refresh the
--- moment the server re-stamps them, so this only catches the countdown.
local RECHECK = 2

local tracked: { [ProximityPrompt]: Instance } = {}

local function refresh(plot: Instance, prompt: ProximityPrompt)
	local owner = plot:GetAttribute("OwnerUserId")
	local mine = owner == player.UserId
	local unowned = owner == nil or owner == 0
	local protectedUntil = tonumber(prompt:GetAttribute("ProtectedUntil")) or 0
	local protected = protectedUntil > workspace:GetServerTimeNow()
	prompt.Enabled = not mine and not unowned and not protected
end

local function track(plot: Instance, prompt: ProximityPrompt)
	tracked[prompt] = plot
	refresh(plot, prompt)
	prompt:GetAttributeChangedSignal("ProtectedUntil"):Connect(function()
		refresh(plot, prompt)
	end)
	prompt.AncestryChanged:Connect(function()
		if not prompt:IsDescendantOf(workspace) then
			tracked[prompt] = nil
		end
	end)
end

local function watch(plot: Instance)
	for _, descendant in plot:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and descendant.Name == PROMPT_NAME then
			track(plot, descendant)
		end
	end
	plot.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") and descendant.Name == PROMPT_NAME then
			task.defer(track, plot, descendant)
		end
	end)
	plot:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		for prompt, owner in tracked do
			if owner == plot then
				refresh(plot, prompt)
			end
		end
	end)
end

function RobPromptController.start()
	task.spawn(function()
		local map = workspace:WaitForChild("Map", 60)
		local bases = map and map:WaitForChild("Bases", 30)
		if not bases then
			return
		end
		for _, plot in bases:GetChildren() do
			task.spawn(watch, plot)
		end
		bases.ChildAdded:Connect(function(plot)
			task.spawn(watch, plot)
		end)

		while true do
			task.wait(RECHECK)
			for prompt, plot in tracked do
				if prompt.Parent then
					refresh(plot, prompt)
				else
					tracked[prompt] = nil
				end
			end
		end
	end)
end

return RobPromptController
