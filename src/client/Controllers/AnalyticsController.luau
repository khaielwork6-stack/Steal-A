--!strict
--[[
	AnalyticsController  (polish-events-analytics pass)
	The funnel steps only the client can see, reported through the
	rate-limited AnalyticsClientEvent remote. Today that is one step: the
	Shop panel opening (MainUI.Frames.Shop becoming visible - the place
	script opens it; ShopController fills it). The server decides everything
	else (AnalyticsEvents); this names a step key and nothing more.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local AnalyticsController = {}

local player = Players.LocalPlayer

--- A panel flicking open and shut is one visit.
local MIN_GAP = 5

function AnalyticsController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local mainUi = playerGui:WaitForChild("MainUI", 60)
	local frames = mainUi and mainUi:WaitForChild("Frames", 30)
	local shop = frames and frames:WaitForChild("Shop", 30)
	if not shop or not shop:IsA("GuiObject") then
		return
	end
	local remote = Remotes.get("AnalyticsClientEvent")
	local lastSent = -math.huge
	shop:GetPropertyChangedSignal("Visible"):Connect(function()
		if shop.Visible and os.clock() - lastSent >= MIN_GAP then
			lastSent = os.clock()
			remote:FireServer("shopOpened")
		end
	end)
end

return AnalyticsController
