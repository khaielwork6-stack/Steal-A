--!strict
--[[
	DevToolsController  (STUDIO ONLY)
	A small "DEV" pill at the top-centre of the screen that opens a panel with
	the owner's two testing tools:

	  GIVE CASH      an amount box (1e9, 250000, 5e12 ... anything tonumber
	                 reads) and one-tap $1M / $1B / $1T / $1Qa buttons.
	  RESET ALL DATA back to a brand-new player, behind an "Are you sure?".

	It builds nothing outside Studio (`start` returns at once), and the server
	side (DevService) has no listener outside Studio either, so nothing here can
	reach a live game. See DevService for what a reset does to the saved data.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local ConfirmDialog = require(script.Parent.ConfirmDialog)

local DevToolsController = {}

local player = Players.LocalPlayer

local INK = Color3.fromRGB(14, 16, 30)
local PANEL = Color3.fromRGB(24, 26, 44)
local ORANGE = Color3.fromRGB(255, 150, 60)
local GREEN_TOP, GREEN_BOTTOM = Color3.fromRGB(110, 232, 130), Color3.fromRGB(46, 170, 78)
local RED_TOP, RED_BOTTOM = Color3.fromRGB(255, 108, 112), Color3.fromRGB(170, 24, 32)
local GREY_TOP, GREY_BOTTOM = Color3.fromRGB(120, 130, 170), Color3.fromRGB(70, 78, 118)

local QUICK_AMOUNTS = { 1e6, 1e9, 1e12, 1e15 }

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number, color: Color3)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color
	s.Parent = parent
end

local function button(parent: Instance, text: string, size: UDim2, position: UDim2, top: Color3, bottom: Color3, textSize: number): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = bottom
	b.Text = text
	b.Font = Enum.Font.FredokaOne
	b.TextSize = textSize
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.TextStrokeTransparency = 0.5
	b.Parent = parent
	corner(b, 8)
	stroke(b, 2, INK)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = 90
	g.Parent = b
	return b
end

local function label(parent: Instance, text: string, position: UDim2, size: UDim2, textSize: number, color: Color3, font: Enum.Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = position
	l.Size = size
	l.Font = font
	l.Text = text
	l.TextColor3 = color
	l.TextSize = textSize
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

function DevToolsController.start()
	if not RunService:IsStudio() then
		return
	end
	local gui = player:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "DevTools"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 500
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = gui

	local pill = button(screen, "DEV", UDim2.fromOffset(64, 30), UDim2.new(0.5, -32, 0, 8), Color3.fromRGB(255, 190, 110), ORANGE, 18)
	pill.Name = "Toggle"

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 44)
	panel.Size = UDim2.fromOffset(320, 268)
	panel.BackgroundColor3 = PANEL
	panel.Visible = false
	panel.Parent = screen
	corner(panel, 12)
	stroke(panel, 3, ORANGE)

	label(panel, "DEV TOOLS", UDim2.fromOffset(14, 8), UDim2.fromOffset(180, 24), 20, ORANGE, Enum.Font.FredokaOne)
	label(panel, "Studio only", UDim2.new(1, -94, 0, 12), UDim2.fromOffset(80, 18), 13, Color3.fromRGB(150, 156, 184), Enum.Font.Gotham).TextXAlignment = Enum.TextXAlignment.Right

	-- ---------- GIVE CASH ----------
	label(panel, "GIVE CASH", UDim2.fromOffset(14, 42), UDim2.fromOffset(200, 18), 14, Color3.fromRGB(230, 232, 246), Enum.Font.GothamBold)
	local box = Instance.new("TextBox")
	box.Name = "Amount"
	box.Position = UDim2.fromOffset(14, 64)
	box.Size = UDim2.new(1, -28 - 96, 0, 34)
	box.BackgroundColor3 = INK
	box.ClearTextOnFocus = false
	box.Text = "1e9"
	box.PlaceholderText = "amount, e.g. 5e12"
	box.Font = Enum.Font.GothamBold
	box.TextSize = 18
	box.TextColor3 = Color3.fromRGB(255, 255, 255)
	box.PlaceholderColor3 = Color3.fromRGB(120, 126, 156)
	box.Parent = panel
	corner(box, 8)
	stroke(box, 2, Color3.fromRGB(70, 76, 110))

	local function give(amount: number)
		Remotes.get("DevRequest"):FireServer("grantCash", amount)
	end
	local giveButton = button(panel, "GIVE $", UDim2.fromOffset(88, 34), UDim2.new(1, -102, 0, 64), GREEN_TOP, GREEN_BOTTOM, 18)
	giveButton.Activated:Connect(function()
		local amount = tonumber(box.Text)
		if amount and amount > 0 then
			give(amount)
		else
			box.Text = "1e9"
		end
	end)

	local quickWidth = (320 - 28 - 3 * 6) / 4
	for index, amount in QUICK_AMOUNTS do
		local quick = button(panel, `+{NumberFormat.cash(amount)}`, UDim2.fromOffset(quickWidth, 32), UDim2.fromOffset(14 + (index - 1) * (quickWidth + 6), 106), GREY_TOP, GREY_BOTTOM, 14)
		quick.Activated:Connect(function()
			give(amount)
		end)
	end

	-- ---------- RESET ----------
	label(panel, "RESET", UDim2.fromOffset(14, 158), UDim2.fromOffset(200, 18), 14, Color3.fromRGB(230, 232, 246), Enum.Font.GothamBold)
	local reset = button(panel, "RESET ALL DATA", UDim2.new(1, -28, 0, 44), UDim2.fromOffset(14, 182), RED_TOP, RED_BOTTOM, 22)
	reset.Name = "ResetAll"
	reset.Activated:Connect(function()
		ConfirmDialog.ask({
			title = "Reset ALL data?",
			message = "Your progress goes back to a brand-new player.",
			detail = "Studio plays on your REAL save, so the live game's save is reset too. The version saved just before stays recoverable for about 30 days.",
			confirmText = "YES, RESET",
			cancelText = "CANCEL",
			onConfirm = function()
				Remotes.get("DevRequest"):FireServer("resetAll", "RESET")
			end,
		})
	end)
	label(panel, "Saves the current data first.", UDim2.fromOffset(14, 232), UDim2.new(1, -28, 0, 18), 12, Color3.fromRGB(150, 156, 184), Enum.Font.Gotham)

	pill.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
end

return DevToolsController
