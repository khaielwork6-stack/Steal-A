--!strict
--[[
	PurchasePolicyController
	Hides the Instant Reveal prompt from players whose region restricts paid
	random items (PolicyService, read by MonetizationService on the server and
	sent in StatePush as `shop.policy`).

	WHY INSTANT REVEAL. It pays to open a container whose content the player
	does not know yet - a paid random item in PolicyService's terms. Paid base
	steals target an item the player can already see, so RobPrompts stay.

	ONE SLOT PROMPT, SEVERAL JOBS. The display slot's single SlotPrompt reads
	Place / Instant Reveal / Reveal / Store by state (PlacementService), and
	BasePromptController turns it on for the owner. So this does not fight
	over the prompt for good: it switches it OFF only while its container is
	still counting (RevealEndsAt in the future), and hands it back - on
	exactly BasePromptController's rule, owned plot and ServerEnabled - the
	moment the timer runs out, when the same prompt reads "Reveal" and is
	free. A restricted player therefore still reveals everything, for free,
	when the timer ends.

	PRESENTATION ONLY. HatchService.promptInstantReveal refuses the purchase
	server-side for the same players (MonetizationService.paidRandomRestricted),
	so a client that ignores this still cannot open the dialog.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local PurchasePolicyController = {}

--- Seconds between passes. The prompt only matters while the player stands
--- at a pad, and a pass is a handful of attribute reads.
local PASS_SECONDS = 0.5

--- True while the server says paid random items are restricted. Starts TRUE:
--- until the first push arrives the safe answer is "restricted", matching
--- the server's own default.
local restricted = true
local plotName: string? = nil

--- Prompts this controller switched off, so only those are handed back.
local suppressed: { [ProximityPrompt]: boolean } = {}

local function handBack(prompt: ProximityPrompt)
	suppressed[prompt] = nil
	-- BasePromptController's own rule: this is only ever the owner's plot.
	prompt.Enabled = prompt:GetAttribute("ServerEnabled") == true
end

local function pass(): boolean
	local plot: Instance? = nil
	if plotName then
		local map = workspace:FindFirstChild("Map")
		local bases = map and map:FindFirstChild("Bases")
		plot = bases and bases:FindFirstChild(plotName)
	end
	local slots = plot and plot:FindFirstChild("DisplaySlots")

	local now = workspace:GetServerTimeNow()
	local seen: { [ProximityPrompt]: boolean } = {}
	if slots and restricted then
		for _, slot in slots:GetChildren() do
			local prompt = slot:FindFirstChild("SlotPrompt")
			if prompt and prompt:IsA("ProximityPrompt") then
				local endsAt = tonumber(prompt:GetAttribute("RevealEndsAt"))
				if endsAt and endsAt > now then
					seen[prompt] = true
					suppressed[prompt] = true
					if prompt.Enabled then
						prompt.Enabled = false
					end
				end
			end
		end
	end

	-- Anything no longer counting (ready, revealed, emptied), no longer on
	-- this plot, or no longer restricted gets its prompt back.
	for prompt in suppressed do
		if not seen[prompt] then
			if prompt.Parent then
				handBack(prompt)
			else
				suppressed[prompt] = nil
			end
		end
	end
	return true
end

function PurchasePolicyController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		plotName = if type(state.plotName) == "string" then state.plotName else nil
		local shop = state.shop
		local policy = if type(shop) == "table" then shop.policy else nil
		if type(policy) == "table" then
			restricted = policy.paidRandomRestricted ~= false
		end
	end)

	task.spawn(function()
		while true do
			task.wait(PASS_SECONDS)
			local ok, err = pcall(pass)
			if not ok then
				warn(`[PurchasePolicyController] pass failed: {err}`)
			end
		end
	end)
end

return PurchasePolicyController
