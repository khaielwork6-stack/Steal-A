--!strict
--[[
	BasePromptController
	Hides base interaction prompts on plots the local player does not own.

	ProximityPrompt visibility is global on the server, so without this every
	player would see fourteen "Place" prompts on every one of the seven plots
	they walk past. `Enabled` set on the client is local-only, which is exactly
	the per-player filtering we want. The server still re-validates ownership on
	every trigger, so this is presentation, not security.
]]

local Players = game:GetService("Players")

local BasePromptController = {}

local player = Players.LocalPlayer

local function refresh(plot: Instance, prompt: ProximityPrompt)
	local owned = plot:GetAttribute("OwnerUserId") == player.UserId
	prompt.Enabled = owned and prompt:GetAttribute("ServerEnabled") == true
end

local function apply(plot: Instance)
	for _, descendant in plot:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			refresh(plot, descendant)
		end
	end
end

local function track(plot: Instance, prompt: ProximityPrompt)
	refresh(plot, prompt)
	-- A slot's lock state changes when capacity is bought.
	prompt:GetAttributeChangedSignal("ServerEnabled"):Connect(function()
		refresh(plot, prompt)
	end)
end

local function watch(plot: Instance)
	for _, descendant in plot:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			track(plot, descendant)
		end
	end

	plot:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		apply(plot)
	end)

	plot.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") then
			task.defer(track, plot, descendant)
		end
	end)
end

function BasePromptController.start()
	local map = workspace:WaitForChild("Map", 30)
	if not map then
		return
	end
	local bases = map:WaitForChild("Bases", 15)
	if not bases then
		return
	end

	for _, plot in bases:GetChildren() do
		task.spawn(watch, plot)
	end
	bases.ChildAdded:Connect(function(plot)
		task.spawn(watch, plot)
	end)
end

return BasePromptController
