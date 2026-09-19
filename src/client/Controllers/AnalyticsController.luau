--!strict
--[[
	AnalyticsController  (polish-events-analytics pass)
	The funnel steps only the client can see, reported through the
	rate-limited AnalyticsClientEvent remote. Today that is one step: the
	Shop panel opening (MainUI.Frames.Shop becoming visible - the place
	script opens it; ShopController fills it). The server decides everything
	else (AnalyticsEvents); this names a step key and nothing more.

	[analytics-discord] Also the OPEN PANEL: whenever the MainUI panel that
	is open changes, ("panel", name) is sent - a name from
	PolishConfig.ANALYTICS_PANELS, or "None". Settled for a moment first, so
	flicking through panels is one report, and only a real change is sent.
	The server uses it for the quit context ("QuitInPanel") and the
	per-product purchase funnels' "shown" step.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PolishConfig = require(ReplicatedStorage.Shared.Config.PolishConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local AnalyticsController = {}

local player = Players.LocalPlayer

--- A panel flicking open and shut is one visit.
local MIN_GAP = 5
--- [analytics-discord] The open panel must hold this long to be reported.
local PANEL_SETTLE = 1

local function watchPanels(frames: Instance, remote: RemoteEvent)
	local listed: { [string]: true } = {}
	for _, name in PolishConfig.ANALYTICS_PANELS do
		listed[name] = true
	end
	-- Most recently opened last, so two open panels report the newer one.
	local openOrder: { string } = {}
	local lastSent = "None"
	local pending = false

	local function current(): string
		for index = #openOrder, 1, -1 do
			local frame = frames:FindFirstChild(openOrder[index])
			if frame and frame:IsA("GuiObject") and frame.Visible then
				return openOrder[index]
			end
		end
		return "None"
	end

	local function schedule()
		if pending then
			return
		end
		pending = true
		task.delay(PANEL_SETTLE, function()
			pending = false
			local now = current()
			if now ~= lastSent then
				lastSent = now
				remote:FireServer("panel", now)
			end
		end)
	end

	local function track(child: Instance)
		if not listed[child.Name] or not child:IsA("GuiObject") then
			return
		end
		local frame = child :: GuiObject
		frame:GetPropertyChangedSignal("Visible"):Connect(function()
			local at = table.find(openOrder, frame.Name)
			if at then
				table.remove(openOrder, at)
			end
			if frame.Visible then
				table.insert(openOrder, frame.Name)
			end
			schedule()
		end)
		if frame.Visible then
			table.insert(openOrder, frame.Name)
			schedule()
		end
	end

	for _, child in frames:GetChildren() do
		track(child)
	end
	frames.ChildAdded:Connect(track)
end

function AnalyticsController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local mainUi = playerGui:WaitForChild("MainUI", 60)
	local frames = mainUi and mainUi:WaitForChild("Frames", 30)
	if not frames then
		return
	end
	local remote = Remotes.get("AnalyticsClientEvent")
	-- [analytics-discord]
	task.spawn(watchPanels, frames, remote)

	local shop = frames:WaitForChild("Shop", 30)
	if not shop or not shop:IsA("GuiObject") then
		return
	end
	local lastSent = -math.huge
	shop:GetPropertyChangedSignal("Visible"):Connect(function()
		if shop.Visible and os.clock() - lastSent >= MIN_GAP then
			lastSent = os.clock()
			remote:FireServer("shopOpened")
		end
	end)
end

return AnalyticsController
