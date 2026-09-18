--!strict
--[[
	InteractController
	Roblox's OWN prompt UI, kept small and predictable.

	WHAT THIS REPLACED. This file used to draw a custom interaction card - a
	BillboardGui with a radial hold ring that, on touch, was itself the button
	you pressed and held. The owner pulled it: it was big, it sat over the
	item, and a finger already down on the screen that slid across it started
	a hold. Roblox's built-in prompt has none of those problems: it is small,
	it only begins a hold from a touch that STARTS on it, and it is what every
	reference game the owner pointed at uses.

	WHAT STILL HAS TO BE TRUE
	  ONE AT A TIME. A base has fourteen display-slot prompts plus the
	  treadmill within twelve studs. Roblox shows one prompt per key when
	  every prompt is OnePerButton, so this enforces that on every prompt in
	  the world, including ones created later, and never lets one slip back
	  to Custom (the style that hid Roblox's UI for the old card).

	  CARRYING. While the player carries loot, the only prompts that matter
	  are the display slots it can be placed on. Every other prompt is hidden
	  on this client for the length of the carry (Style = Custom draws
	  nothing) and shown again the moment it ends. The server refuses a steal
	  during a carry anyway; this just keeps the screen honest.

	  A LITTLE LOWER. The prompt sits a touch under its anchor (UIOffset) so
	  it hangs below the item rather than across it.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")

local UIStateController = require(script.Parent.UIStateController)

local InteractController = {}

local player = Players.LocalPlayer

--- Pixels below the prompt's anchor the card is drawn.
local PROMPT_DROP = Vector2.new(0, 28)

--- Every prompt seen so far, so a carry can hide and restore them.
local known: { [ProximityPrompt]: true } = {}
local carrying = false

local function styleFor(prompt: ProximityPrompt): Enum.ProximityPromptStyle
	if carrying and prompt.Name ~= "SlotPrompt" then
		return Enum.ProximityPromptStyle.Custom
	end
	return Enum.ProximityPromptStyle.Default
end

local function adopt(instance: Instance)
	if not instance:IsA("ProximityPrompt") then
		return
	end
	known[instance] = true
	instance.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	instance.UIOffset = PROMPT_DROP
	instance.Style = styleFor(instance)
	instance.Destroying:Once(function()
		known[instance] = nil
	end)
end

local function restyleAll()
	for prompt in known do
		if prompt.Parent then
			prompt.Style = styleFor(prompt)
		else
			known[prompt] = nil
		end
	end
end

--- The pack's demo billboards ("Top Cash", "Gamepasses", "Next Update!",
--- the Action template) ship ENABLED with no Adornee, and a BillboardGui
--- with no Adornee draws at the world origin - the red line in front of the
--- spawn, dead centre of a new player's first view. The server clones what
--- it needs from StarterGui; the copies in PlayerGui are leftovers.
local function silencePackBillboards()
	local playerGui = player:WaitForChild("PlayerGui")
	local mainUi = playerGui:WaitForChild("MainUI", 20)
	local surface = mainUi and mainUi:FindFirstChild("Surface/Billboards")
	if not surface then
		return
	end
	for _, gui in surface:GetDescendants() do
		if gui:IsA("BillboardGui") and gui.Adornee == nil then
			gui.Enabled = false
		end
	end
end

function InteractController.start()
	task.spawn(silencePackBillboards)

	-- Through the shared WorldIndex (one workspace scan for all controllers),
	-- so prompts created later are adopted too.
	require(script.Parent.Parent.WorldIndex).watch("ProximityPrompt", adopt)

	-- Backstop: anything that reaches the screen is ours to style, even if
	-- the index missed it.
	ProximityPromptService.PromptShown:Connect(function(prompt)
		if not known[prompt] then
			adopt(prompt)
		end
	end)

	-- The carry claim comes and goes with StatePush; a cheap poll follows it
	-- rather than every controller telling this one.
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 0.2 then
			return
		end
		elapsed = 0
		local now = UIStateController.hasClaim("carry")
		if now ~= carrying then
			carrying = now
			restyleAll()
		end
	end)
end

return InteractController
