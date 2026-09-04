--!strict
--[[
	HUDController
	Binds the imported UI pack to live game state.

	The pack supplies the art and its own animation LocalScript (slide-up panels,
	one-at-a-time, blur, ripples). This controller supplies the DATA and the
	game-specific wiring. Keeping that split means the pack can be restyled
	without touching gameplay code, and gameplay can change without re-authoring
	the UI.

	Every value here comes from StatePush. The client renders; it never computes.

	Expected hierarchy (after the audit restructure):
	  MainUI
	    Bottom.Currencies.{Cash, Income, Speed}.Amount
	    Bottom.Hotbar.Hotbar.<slot>.Frame.{Icon, Count, Earns}
	    Buttons.Left.{Shop, Backpack, Index, Settings}
	    Top.Base
	    ZoneProgress.Frame.{LEVEL, AMOUNT, Frame}
	    Frames.{Shop, Backpack, Index, Upgrades, Settings}
	    Notifications.{Spawned, PickedUp, InventoryFull, Collected}
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local EffectsController = require(script.Parent.EffectsController)
local ToastController = require(script.Parent.ToastController)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local HUDController = {}

local player = Players.LocalPlayer

local ui: ScreenGui
local cashLabel: TextLabel?
local incomeLabel: TextLabel?
local speedLabel: TextLabel?
local zoneTitle: TextLabel?
local zoneAmount: TextLabel?
local zoneFill: Frame?

local lastCash = 0

local function findLabel(container: Instance?, name: string): TextLabel?
	if not container then
		return nil
	end
	local found = container:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

-- ==========================================================
-- CURRENCY CHIPS
-- ==========================================================

--- Little pop when Cash increases, so passive income feels alive without a
--- separate floating-text system.
local function pulse(label: TextLabel?)
	if not label then
		return
	end
	UIAnim.flashColor(label, Color3.fromRGB(190, 255, 200))
	UIAnim.punch(label, 0.06)
end

-- ==========================================================
-- ZONE PROGRESS
-- ==========================================================

--- Repurposed from the pack's boss bar: shows progress toward the NEXT zone's
--- recommended Speed, which is the game's actual long-term goal.
local function updateZoneProgress(speedPower: number)
	if not zoneTitle or not zoneAmount or not zoneFill then
		return
	end

	local nextZone: ZoneConfig.ZoneDef? = nil
	for _, zone in ZoneConfig.Zones do
		if zone.recommendedSpeed > speedPower then
			nextZone = zone
			break
		end
	end

	if not nextZone then
		zoneTitle.Text = "MAX"
		zoneAmount.Text = "All zones unlocked"
		zoneFill.Size = UDim2.fromScale(1, zoneFill.Size.Y.Scale)
		return
	end

	-- Progress runs from the previous gate to the next one, not from zero, so
	-- the bar actually moves instead of sitting near-empty for hours.
	local previous = 0
	for _, zone in ZoneConfig.Zones do
		if zone.index == nextZone.index - 1 then
			previous = zone.recommendedSpeed
		end
	end

	local span = math.max(nextZone.recommendedSpeed - previous, 1)
	local progress = math.clamp((speedPower - previous) / span, 0, 1)

	zoneTitle.Text = `NEXT: {nextZone.name}`
	zoneAmount.Text = `{NumberFormat.short(speedPower)} / {NumberFormat.short(nextZone.recommendedSpeed)} Speed`

	-- The pack's fill was centre-anchored, so it grew outward from the middle
	-- instead of filling left to right. Anchor left and tween the width.
	UIAnim.setBarFill(zoneFill, progress)
end

-- ==========================================================
-- HOTBAR
-- ==========================================================

--- Compact "displays filled" readout. The pack's five numbered slots were
--- removed entirely: they duplicated Roblox's own tool hotbar (which already
--- shows exactly the two tools we have, Bat and Trap) and misrepresented
--- capacity, which runs to fourteen.
local function updateDisplayCount(state)
	local strip = ui:FindFirstChild("Bottom")
	local label = strip and strip:FindFirstChild("DisplayCount")
	if label and label:IsA("TextLabel") then
		label.Text = `Displays  {state.slotsUsed}/{state.slotsUnlocked}`
		label.TextColor3 = if state.slotsUsed >= state.slotsUnlocked
			then Color3.fromRGB(255, 176, 46)
			else Color3.fromRGB(226, 230, 240)
	end
end

-- ==========================================================
-- PANELS
-- ==========================================================

--- The pack's LocalScript opens a panel whose name matches the button. We only
--- need to keep panel CONTENT in sync, plus close anything that no longer
--- applies.
local function refreshPanels(state)
	local frames = ui:FindFirstChild("Frames")
	if not frames then
		return
	end

	local index = frames:FindFirstChild("Index")
	local indexCounter = index and findLabel(index:FindFirstChild("Features"), "Title")
	if indexCounter then
		indexCounter.Text = `{state.indexCount}/96 Discovered`
	end
end

-- ==========================================================
-- START
-- ==========================================================

--- Phones get a slightly smaller UI so the side menu and the currency stack do
--- not eat the play area. Driven off viewport width rather than TouchEnabled,
--- because a small window on desktop has the same problem.
local function applyScale()
	local camera = workspace.CurrentCamera
	local scale = ui:FindFirstChildWhichIsA("UIScale")
	if not camera or not scale then
		return
	end
	local width = camera.ViewportSize.X
	scale.Scale = if width < 700 then 0.72 elseif width < 1000 then 0.85 else 1
end

function HUDController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local found = playerGui:WaitForChild("MainUI", 20)
	if not found or not found:IsA("ScreenGui") then
		warn("[HUDController] MainUI not found - is the UI pack in StarterGui?")
		return
	end
	ui = found

	ui.ResetOnSpawn = false
	ui.IgnoreGuiInset = true
	ui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local currencies = ui:FindFirstChild("Bottom") and ui.Bottom:FindFirstChild("Currencies")
	cashLabel = findLabel(currencies and currencies:FindFirstChild("Cash"), "Amount")
	incomeLabel = findLabel(currencies and currencies:FindFirstChild("Income"), "Amount")
	speedLabel = findLabel(currencies and currencies:FindFirstChild("Speed"), "Amount")

	local bar = ui:FindFirstChild("ZoneProgress")
	local barFrame = bar and bar:FindFirstChild("Frame")
	zoneTitle = barFrame and findLabel(barFrame, "LEVEL")
	zoneAmount = barFrame and findLabel(barFrame, "AMOUNT")
	local fill = barFrame and barFrame:FindFirstChild("Frame")
	zoneFill = if fill and fill:IsA("Frame") then fill else nil

	-- The Income chip inherited a Rebirths icon; drop it so the number owns the
	-- chip and stays readable on a phone.
	local incomeIcon = currencies
		and currencies:FindFirstChild("Income")
		and currencies.Income:FindFirstChild("Icon")
	if incomeIcon then
		incomeIcon:Destroy()
	end

	-- "BASE" teleports you home. Long map, one plot: this earns its place.
	local baseButton = ui:FindFirstChild("Top") and ui.Top:FindFirstChild("Base")
	if baseButton and baseButton:IsA("GuiButton") then
		baseButton.Activated:Connect(function()
			Remotes.get("TeleportHomeRequest"):FireServer()
		end)
	end

	-- Buttons inside MainUI are deliberately NOT bound here. The pack's own
	-- animation script already gives every button under this ScreenGui its
	-- hover/press/ripple treatment, and it additionally pairs a button with the
	-- panel of the same name to open it. Binding them ourselves would stamp them
	-- as already-handled, the pack would skip them, and buttons like Storage
	-- would animate but never open anything. UIAnim is for the UI we build
	-- outside this pack.

	applyScale()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
	end

	EffectsController.start()
	ToastController.start(ui)

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if cashLabel then
			-- Count toward the new balance rather than snapping, so passive
			-- income visibly ticks up instead of flickering between values.
			UIAnim.countTo(cashLabel, state.cash, NumberFormat.cash)
			if state.cash > lastCash then
				pulse(cashLabel)
			end
			lastCash = state.cash
		end
		if incomeLabel then
			incomeLabel.Text = NumberFormat.income(state.income)
		end
		if speedLabel then
			speedLabel.Text = `Speed {NumberFormat.short(state.speedPower)}`
		end

		updateZoneProgress(state.speedPower)
		updateDisplayCount(state)
		refreshPanels(state)
	end)

	Remotes.get("Notify").OnClientEvent:Connect(function(kind: string, message: string, detail: string?)
		ToastController.show(kind, message)

		-- `detail` lets the server ask for a world effect without needing to know
		-- what the effect is. Gold for anything bought, blue for an unlock.
		if detail == "levelup" then
			EffectsController.burstOnPlayer("Gold")
		elseif detail == "unlock" then
			EffectsController.burstOnPlayer("Blue")
		end
	end)
end

return HUDController
