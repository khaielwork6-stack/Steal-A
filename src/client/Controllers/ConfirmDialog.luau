--!strict
--[[
	ConfirmDialog
	One "Are you sure?" card for anything destructive: a dim, a centred card, a
	YES (or any label) button and a CANCEL button. Built on demand and gone on
	every exit path (confirm, cancel, Escape, tapping the dim, the caller's own
	`close()`), so nothing is left behind and a second call while one is open
	simply replaces it.

	    ConfirmDialog.ask({
	        title = "Are you sure?",
	        message = "Sell all 43 items for about $12.4K?",
	        detail = "Items in your hands are kept.",   -- optional, smaller
	        confirmText = "YES",                         -- default "YES"
	        cancelText = "CANCEL",                       -- default "CANCEL"
	        onConfirm = function() ... end,
	    })
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ConfirmDialog = {}

export type Options = {
	title: string?,
	message: string,
	detail: string?,
	confirmText: string?,
	cancelText: string?,
	onConfirm: () -> (),
	onCancel: (() -> ())?,
}

local player = Players.LocalPlayer
local open: Instance? = nil
--- Every element sits at BASE + n, so the card is above the panel it was
--- opened from in EITHER ZIndexBehavior.
local BASE = 900
local closers: { () -> () } = {}

local function label(parent: Instance, text: string, size: UDim2, position: UDim2, textSize: number, color: Color3, font: Enum.Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Position = position
	l.Size = size
	l.Font = font
	l.Text = text
	l.TextColor3 = color
	l.TextSize = textSize
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.ZIndex = BASE + 3
	l.Parent = parent
	return l
end

local function button(parent: Instance, text: string, position: UDim2, top: Color3, bottom: Color3): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.AnchorPoint = Vector2.new(0.5, 1)
	b.Position = position
	b.Size = UDim2.new(0.42, 0, 0, 48)
	b.BackgroundColor3 = bottom
	b.Text = text
	b.Font = Enum.Font.FredokaOne
	b.TextSize = 24
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.TextStrokeTransparency = 0.4
	b.ZIndex = BASE + 3
	b.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(12, 14, 26)
	stroke.Parent = b
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Rotation = 90
	gradient.Parent = b
	UIAnim.bindButton(b)
	return b
end

--- Closes the dialog that is open, if any, WITHOUT running either callback.
function ConfirmDialog.close()
	local screen = open
	open = nil
	for _, undo in closers do
		undo()
	end
	table.clear(closers)
	if screen then
		screen:Destroy()
	end
end

function ConfirmDialog.isOpen(): boolean
	return open ~= nil
end

function ConfirmDialog.ask(options: Options)
	ConfirmDialog.close()
	local gui = player:WaitForChild("PlayerGui")

	-- WHERE IT LIVES. The pack's own script (StarterGui.MainUI.LocalScript)
	-- switches OFF every other ScreenGui the moment a panel opens, and also
	-- when one is added while a panel is open - so a ScreenGui of ours, made
	-- while Storage is showing, is created already disabled (found in Studio,
	-- 2026-09-20: the dialog existed and was never drawn). Inside MainUI the
	-- pack leaves it alone, so it goes there; a ScreenGui of its own is only
	-- the fallback for a place without MainUI.
	local main = gui:FindFirstChild("MainUI")
	local screen: Instance
	if main and main:IsA("ScreenGui") then
		local host = Instance.new("Frame")
		host.Name = "ConfirmDialog"
		host.BackgroundTransparency = 1
		host.BorderSizePixel = 0
		host.Size = UDim2.fromScale(1, 1)
		host.ZIndex = BASE
		host.Parent = main
		screen = host
	else
		local own = Instance.new("ScreenGui")
		own.Name = "ConfirmDialog"
		own.ResetOnSpawn = false
		own.IgnoreGuiInset = true
		own.DisplayOrder = 80
		own.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		own.Parent = gui
		screen = own
	end
	open = screen

	-- The dim also catches taps, so a stray tap cancels rather than clicking
	-- through to the panel underneath.
	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.AutoButtonColor = false
	dim.Text = ""
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = if Effects.isReduced() then 0.45 else 1
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = BASE + 1
	dim.Parent = screen
	if not Effects.isReduced() then
		TweenService:Create(dim, TweenInfo.new(0.18, Enum.EasingStyle.Quad), { BackgroundTransparency = 0.45 }):Play()
	end

	local hasDetail = options.detail ~= nil and options.detail ~= ""
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(380, if hasDetail then 268 else 236)
	card.BackgroundColor3 = Color3.fromRGB(28, 28, 40)
	card.BorderSizePixel = 0
	card.ZIndex = BASE + 2
	card.Parent = screen
	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 16)
	cardCorner.Parent = card
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Thickness = 3
	cardStroke.Color = Color3.fromRGB(255, 200, 70)
	cardStroke.Parent = card
	-- A phone is narrower than the card: scale it down to fit, never up.
	local fit = Instance.new("UIScale")
	fit.Parent = card
	local function refit()
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
		fit.Scale = math.clamp(math.min((viewport.X - 24) / 380, (viewport.Y - 24) / 268), 0.5, 1)
	end
	refit()

	label(card, options.title or "Are you sure?", UDim2.new(0.9, 0, 0, 40), UDim2.new(0.5, 0, 0, 16), 32, Color3.fromRGB(255, 208, 96), Enum.Font.FredokaOne)
	label(card, options.message, UDim2.new(0.86, 0, 0, 64), UDim2.new(0.5, 0, 0, 64), 20, Color3.fromRGB(240, 240, 246), Enum.Font.GothamBold)
	if hasDetail then
		label(card, options.detail :: string, UDim2.new(0.86, 0, 0, 40), UDim2.new(0.5, 0, 0, 128), 15, Color3.fromRGB(170, 176, 196), Enum.Font.Gotham)
	end

	local yes = button(card, options.confirmText or "YES", UDim2.new(0.27, 0, 1, -18), Color3.fromRGB(110, 232, 130), Color3.fromRGB(46, 170, 78))
	yes.Name = "Confirm"
	local no = button(card, options.cancelText or "CANCEL", UDim2.new(0.73, 0, 1, -18), Color3.fromRGB(196, 200, 214), Color3.fromRGB(110, 114, 134))
	no.Name = "Cancel"

	if not Effects.isReduced() then
		-- Pop the card in on its own fit-to-screen UIScale.
		local target = fit.Scale
		fit.Scale = target * 0.86
		TweenService:Create(fit, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()
	end

	local done = false
	local function finish(confirmed: boolean)
		if done then
			return
		end
		done = true
		ConfirmDialog.close()
		local callback = if confirmed then options.onConfirm else options.onCancel
		if callback then
			task.spawn(callback)
		end
	end
	yes.Activated:Connect(function()
		Audio.play("UiClick")
		finish(true)
	end)
	no.Activated:Connect(function()
		Audio.play("UiClick")
		finish(false)
	end)
	dim.Activated:Connect(function()
		finish(false)
	end)
	local escape = UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.Escape then
			finish(false)
		end
	end)
	table.insert(closers, function()
		escape:Disconnect()
	end)
	Audio.play("UiOpen")
end

return ConfirmDialog
