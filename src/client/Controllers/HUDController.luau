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
	    Buttons.Left.{Shop, Upgrades, Index, Storage}
	    Top.{SettingsGear, GiftOpener}
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

local HUDController = {}

local player = Players.LocalPlayer

local ui: ScreenGui
local cashLabel: TextLabel?
local incomeLabel: TextLabel?
local speedLabel: TextLabel?

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

-- Panel CONTENT has an owner per panel: Storage is InventoryController's and the
-- Loot Index is IndexController's. The HUD deliberately writes to neither - two
-- writers on one label is how the Index counter would start fighting itself.

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

	-- The pack's boss bar used to be repurposed as a "NEXT: <zone>" Speed
	-- progress readout across the top of the screen. Retired: the top-centre now
	-- belongs to the chase warning and the loss offer, and zone gating itself is
	-- server-side (ZoneConfig.recommendedSpeed) and unaffected by this.
	local bar = ui:FindFirstChild("ZoneProgress")
	if bar then
		bar:Destroy()
	end

	-- The Income chip inherited a Rebirths icon; drop it so the number owns the
	-- chip and stays readable on a phone.
	local incomeIcon = currencies
		and currencies:FindFirstChild("Income")
		and currencies.Income:FindFirstChild("Icon")
	if incomeIcon then
		incomeIcon:Destroy()
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

		updateDisplayCount(state)
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
