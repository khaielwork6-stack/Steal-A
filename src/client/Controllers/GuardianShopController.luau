--!strict
--[[
	GuardianShopController
	The client half of the rotating Guardian shop in the lobby.

	  * The countdown on each sign, from GetServerTimeNow and the RotationEndsAt
	    attribute the server stamps - so every player's clock reads the same and
	    nothing is replicated per second.
	  * The slow presentation turn of the animal on each pedestal (a local
	    CFrame on an anchored root; the server never moves it).
	  * Each prompt's wording for THIS player: Buy, Equip, or Equipped, from the
	    ownership in StatePush. The server decides what a trigger does either
	    way; this is the label.

	ONE RECORD PER PEDESTAL. This file used to hold a single `shop`, a single
	display root and a single countdown, and to attach only to the model named
	exactly "GuardianShop" - which was correct while there was one. The server
	grew a second sale slot ("GuardianShop2") and this did not, so the second
	sign's countdown never started and sat on its placeholder forever, its
	animal never turned, and its prompt never said Equip.

	The same fix the SERVICE got: everything that was a singleton is a field on
	a Shop record, and every pedestal in the map gets one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local GuardianShopController = {}

local TURN_SPEED = 0.45
local BOB = 0.12

--- Every pedestal is named GuardianShop, GuardianShop2, ... so one test finds
--- them all and a third slot would need no change here.
local MODEL_PREFIX = "GuardianShop"

type Shop = {
	model: Model,
	displayRoot: BasePart?,
	displayBase: CFrame?,
	--- The whole second last written to this sign, so the text is re-set only
	--- when the number it shows actually changes.
	shownSecond: number,
}

local shops: { Shop } = {}
local latest: any = nil

local function isShopModel(child: Instance): boolean
	return child:IsA("Model") and string.match(child.Name, "^" .. MODEL_PREFIX) ~= nil
end

local function signLabel(shop: Shop, name: string): TextLabel?
	local anchor = shop.model:FindFirstChild("SignAnchor")
	local gui = anchor and anchor:FindFirstChild("Sign")
	local label = gui and gui:FindFirstChild(name)
	return if label and label:IsA("TextLabel") then label else nil
end

local function promptOf(shop: Shop): ProximityPrompt?
	local anchor = shop.model:FindFirstChild("PromptAnchor")
	local found = anchor and anchor:FindFirstChild("GuardianBuyPrompt")
	return if found and found:IsA("ProximityPrompt") then found else nil
end

--- What the prompt says for THIS player, for one pedestal. Each slot is
--- showing a different animal, so this has to be answered per shop and never
--- from a shared "current" key.
local function paintPrompt(shop: Shop)
	local p = promptOf(shop)
	if not p or type(latest) ~= "table" or type(latest.guardians) ~= "table" then
		return
	end
	local key = shop.model:GetAttribute("RotationKey")
	if type(key) ~= "string" then
		return
	end
	local guardians = latest.guardians
	local owned = guardians.owned and guardians.owned[key] == true
	if not owned then
		p.ActionText = "Buy"
	elseif guardians.equipped == key then
		p.ActionText = "Equipped"
	else
		p.ActionText = "Equip"
	end
end

local function paintAllPrompts()
	for _, shop in shops do
		paintPrompt(shop)
	end
end

local function adoptDisplay(shop: Shop, display: Instance)
	if not display:IsA("Model") then
		return
	end
	local root = display.PrimaryPart or display:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		shop.displayRoot = root
		shop.displayBase = root.CFrame
	end
	paintPrompt(shop)
end

local function pulseLimited(shop: Shop)
	local label = signLabel(shop, "Limited")
	if not label then
		return
	end
	local scale = label:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = label
	TweenService:Create(
		scale,
		TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.08 }
	):Play()
end

local function attach(model: Model)
	for _, existing in shops do
		if existing.model == model then
			return
		end
	end

	local shop: Shop = { model = model, displayRoot = nil, displayBase = nil, shownSecond = -1 }
	table.insert(shops, shop)

	local display = model:FindFirstChild("Display")
	if display then
		adoptDisplay(shop, display)
	end
	model.ChildAdded:Connect(function(child)
		if child.Name == "Display" then
			task.defer(adoptDisplay, shop, child)
		end
	end)
	model.ChildRemoved:Connect(function(child)
		if child.Name == "Display" then
			shop.displayRoot = nil
			shop.displayBase = nil
		end
	end)
	model:GetAttributeChangedSignal("RotationKey"):Connect(function()
		paintPrompt(shop)
	end)
	pulseLimited(shop)
	paintPrompt(shop)
end

-- ==========================================================
-- THE COUNTDOWN
-- ==========================================================
--
-- Driven off Heartbeat and re-texted only when the SECOND it would display
-- actually changes, rather than from a `task.wait(1)` loop.
--
-- `task.wait(1)` does not sleep for one second, it sleeps for AT LEAST one
-- second, so a loop drifts a little further behind the clock on every pass and
-- the sign visibly holds a value for two beats and then skips one. Sampling
-- the real clock every frame and writing only on a change costs one comparison
-- a frame, never drifts, and cannot skip.
--
-- ONE connection for every pedestal rather than one each: the work is a
-- subtraction per sign, and a connection per shop would mean a connection left
-- running for every shop that is ever destroyed.
local function tickCountdowns()
	for _, shop in shops do
		if shop.model.Parent then
			local label = signLabel(shop, "Timer")
			local endsAt = tonumber(shop.model:GetAttribute("RotationEndsAt"))
			if label and endsAt then
				local remaining = math.max(0, endsAt - workspace:GetServerTimeNow())
				local whole = math.floor(remaining)
				if whole ~= shop.shownSecond then
					shop.shownSecond = whole
					label.Text = `New Guardian In: {BaseGuardianConfig.formatCountdown(remaining)}`
				end
			end
		end
	end
end

local function turnDisplays()
	local now = os.clock()
	for _, shop in shops do
		local root, base = shop.displayRoot, shop.displayBase
		if root and base and root.Parent then
			root.CFrame = base * CFrame.new(0, math.sin(now * 1.4) * BOB, 0) * CFrame.Angles(0, now * TURN_SPEED, 0)
		end
	end
end

function GuardianShopController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) == "table" then
			latest = state
			paintAllPrompts()
		end
	end)

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 60)
		if not map then
			return
		end
		-- Whatever is already there, and whatever the server builds afterwards.
		-- The pedestals are created at start-up, so a client that loads first
		-- has to pick them up as they arrive.
		for _, child in map:GetChildren() do
			if isShopModel(child) then
				attach(child :: Model)
			end
		end
		map.ChildAdded:Connect(function(child)
			if isShopModel(child) then
				attach(child :: Model)
			end
		end)
	end)

	RunService.Heartbeat:Connect(tickCountdowns)
	RunService.RenderStepped:Connect(turnDisplays)
end

return GuardianShopController
