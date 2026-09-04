--!strict
--[[
	HUDController
	PLACEHOLDER HUD - renders replicated state only, never calculates anything.

	This exists so the economy, base assignment and (later) treadmill are fully
	testable before real UI art arrives. It is intentionally plain: replace the
	visuals wholesale when the designed UI lands, but keep the StatePush contract.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local HUDController = {}

local player = Players.LocalPlayer

local function label(parent: Instance, name: string, order: number, size: number, color: Color3): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(1, 0, 0, size)
	text.LayoutOrder = order
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextColor3 = color
	text.TextStrokeTransparency = 0.35
	text.Text = ""
	text.Parent = parent
	return text
end

function HUDController.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "HUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local stack = Instance.new("Frame")
	stack.Name = "Stats"
	stack.BackgroundTransparency = 1
	stack.Position = UDim2.new(0, 18, 0, 18)
	stack.Size = UDim2.new(0, 340, 0, 190)
	stack.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = stack

	local cash = label(stack, "Cash", 1, 46, Color3.fromRGB(126, 255, 148))
	local income = label(stack, "Income", 2, 26, Color3.fromRGB(198, 255, 208))
	local speed = label(stack, "Speed", 3, 34, Color3.fromRGB(120, 208, 255))
	local slots = label(stack, "Slots", 4, 24, Color3.fromRGB(255, 226, 128))
	local plot = label(stack, "Plot", 5, 22, Color3.fromRGB(226, 226, 236))

	-- Toast area for Notify messages.
	local toast = Instance.new("TextLabel")
	toast.Name = "Toast"
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, 26)
	toast.Size = UDim2.new(0, 520, 0, 44)
	toast.BackgroundTransparency = 1
	toast.Font = Enum.Font.FredokaOne
	toast.TextScaled = true
	toast.TextStrokeTransparency = 0.3
	toast.TextTransparency = 1
	toast.Text = ""
	toast.Parent = gui

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		cash.Text = NumberFormat.cash(state.cash)
		income.Text = NumberFormat.income(state.income)
		speed.Text = `Speed {NumberFormat.short(state.speedPower)}  ({string.format("%.1f", state.walkSpeed)} ws)`
		slots.Text = `Displays {state.slotsUsed}/{state.slotsUnlocked}   Traps {state.trapCount}   Index {state.indexCount}/96`
		plot.Text = if state.baseActivated
			then `{state.plotName or "-"}  ·  Treadmill Lv{state.treadmillLevel}`
			else `{state.plotName or "-"}  ·  Base locked`
	end)

	local toastToken = 0
	Remotes.get("Notify").OnClientEvent:Connect(function(kind: string, message: string)
		toastToken += 1
		local token = toastToken

		toast.Text = message
		toast.TextColor3 = if kind == "error"
			then Color3.fromRGB(255, 132, 132)
			elseif kind == "success" then Color3.fromRGB(140, 255, 160)
			else Color3.fromRGB(255, 244, 214)
		toast.TextTransparency = 0

		task.delay(2.5, function()
			if toastToken == token then
				toast.TextTransparency = 1
			end
		end)
	end)
end

return HUDController
