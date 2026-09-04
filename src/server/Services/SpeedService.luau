--!strict
--[[
	SpeedService
	Base activation, treadmill training and the SpeedPower -> WalkSpeed mapping
	(GDD section 9).

	Training is driven by a SERVER timer on a fixed 0.25s tick while the player
	stands inside their own treadmill trigger. We deliberately do not detect
	animation footsteps: that is unreliable across devices and trivially spoofed.
	Client visual effects never control reward frequency.

	SpeedPower persists and can reach the billions. Humanoid.WalkSpeed is always
	recalculated through the compressed formula and is never set equal to
	SpeedPower.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local MapPalette = require(ReplicatedStorage.Shared.MapPalette)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local StateService = require(script.Parent.StateService)

local SpeedService = {}

local upgradeLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.TreadmillUpgradeRequest)

local function notify(player: Player, kind: string, message: string)
	StateService.notify(player, kind, message)
end

-- ==========================================================
-- MOVEMENT
-- ==========================================================

--- Re-derives WalkSpeed from the profile. Routed through CarryService so the
--- carry penalty is applied in one place rather than two.
function SpeedService.applyMovement(player: Player)
	CarryService.applyMovement(player)
end

-- ==========================================================
-- ACTIVATION
-- ==========================================================

--- The $1,000 tutorial Base Activation. This is NOT the $1M capacity upgrade:
--- it unlocks the treadmill and moves the player to treadmill level 1.
function SpeedService.activateBase(player: Player): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	if profile.BaseActivated then
		return false, "Your base is already active."
	end

	if not EconomyService.spend(player, BaseConfig.ACTIVATION_COST) then
		return false, `You need {NumberFormat.cash(BaseConfig.ACTIVATION_COST)}.`
	end

	profile.BaseActivated = true
	profile.TreadmillLevel = math.max(profile.TreadmillLevel, 1)

	SpeedService.refreshTreadmill(player)
	StateService.pushNow(player)
	notify(player, "success", "Base activated! Your treadmill is online.")
	return true
end

-- ==========================================================
-- UPGRADES
-- ==========================================================

function SpeedService.upgradeTreadmill(player: Player): (boolean, string?)
	if not upgradeLimiter:consume(player) then
		return false, "Slow down!"
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	if not profile.BaseActivated then
		return false, "Activate your base first."
	end

	local next = TreadmillConfig.nextTier(profile.TreadmillLevel)
	if not next then
		return false, "Your treadmill is fully upgraded!"
	end

	-- Atomic: only grant the level if the spend actually succeeded.
	if not EconomyService.spend(player, next.cost) then
		return false, `You need {NumberFormat.cash(next.cost)}.`
	end

	profile.TreadmillLevel = next.level
	SpeedService.refreshTreadmill(player)
	StateService.pushNow(player)
	notify(
		player,
		"success",
		`Treadmill {next.name}! +{NumberFormat.short(TreadmillConfig.gainPerSecond(next.level))} Speed/s`
	)
	return true
end

--- Granted by a Developer Product purchase. Idempotency is ProcessReceipt's
--- job (phase 11); this only performs the grant.
function SpeedService.grantTreadmillTier(player: Player, level: number): boolean
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	if level ~= profile.TreadmillLevel + 1 then
		return false
	end
	profile.TreadmillLevel = level
	SpeedService.refreshTreadmill(player)
	StateService.pushNow(player)
	return true
end

-- ==========================================================
-- TREADMILL PRESENTATION
-- ==========================================================

--- Dark and dead until activation, lit and labelled afterwards (GDD section 4).
function SpeedService.refreshTreadmill(player: Player)
	local plot = BaseService.getPlot(player)
	local profile = DataService.get(player)
	if not plot or not profile then
		return
	end

	local treadmill = plot:FindFirstChild("Treadmill")
	local pad = plot:FindFirstChild("BaseActivationPad")
	if not treadmill then
		return
	end

	local active = profile.BaseActivated
	local belt = treadmill:FindFirstChild("Belt")
	local frame = treadmill:FindFirstChild("Frame")

	if belt and belt:IsA("BasePart") then
		belt.Color = if active then MapPalette.TreadmillBelt else Color3.fromRGB(58, 60, 68)
		belt.Material = if active then Enum.Material.SmoothPlastic else Enum.Material.Slate
	end
	if frame and frame:IsA("BasePart") then
		frame.Color = if active then MapPalette.Treadmill else Color3.fromRGB(96, 100, 112)
	end

	-- Activation pad disappears once used.
	if pad and pad:IsA("BasePart") then
		pad.Transparency = if active then 1 else 0
		pad.CanCollide = false
		local prompt = pad:FindFirstChild("ActivatePrompt") :: ProximityPrompt?
		if prompt then
			prompt:SetAttribute("ServerEnabled", not active)
		end
	end

	-- Label above the treadmill.
	local anchor = frame or belt
	if anchor and anchor:IsA("BasePart") then
		local gui = anchor:FindFirstChild("TreadmillLabel") :: BillboardGui?
		if not gui then
			local created = Instance.new("BillboardGui")
			created.Name = "TreadmillLabel"
			created.Size = UDim2.fromScale(12, 3.4)
			created.StudsOffsetWorldSpace = Vector3.new(0, 8, 0)
			created.MaxDistance = 200
			created.Adornee = anchor
			created.Parent = anchor

			local title = Instance.new("TextLabel")
			title.Name = "Title"
			title.Size = UDim2.fromScale(1, 0.55)
			title.BackgroundTransparency = 1
			title.Font = Enum.Font.FredokaOne
			title.TextScaled = true
			title.TextStrokeTransparency = 0.35
			title.Parent = created

			local detail = Instance.new("TextLabel")
			detail.Name = "Detail"
			detail.Size = UDim2.fromScale(1, 0.45)
			detail.Position = UDim2.fromScale(0, 0.55)
			detail.BackgroundTransparency = 1
			detail.Font = Enum.Font.FredokaOne
			detail.TextScaled = true
			detail.TextStrokeTransparency = 0.4
			detail.Parent = created

			gui = created
		end

		local title = (gui :: BillboardGui):FindFirstChild("Title") :: TextLabel
		local detail = (gui :: BillboardGui):FindFirstChild("Detail") :: TextLabel

		if not active then
			title.Text = "TREADMILL LOCKED"
			title.TextColor3 = Color3.fromRGB(190, 195, 205)
			detail.Text = `Activate base · {NumberFormat.cash(BaseConfig.ACTIVATION_COST)}`
			detail.TextColor3 = Color3.fromRGB(255, 214, 120)
		else
			local tier = TreadmillConfig.tier(profile.TreadmillLevel)
			local next = TreadmillConfig.nextTier(profile.TreadmillLevel)
			title.Text = `{if tier then tier.name else "Basic"} · +{NumberFormat.short(TreadmillConfig.gainPerSecond(profile.TreadmillLevel))}/s`
			title.TextColor3 = Color3.fromRGB(126, 236, 255)
			detail.Text = if next
				then `Upgrade · {NumberFormat.cash(next.cost)}`
				else "MAX LEVEL"
			detail.TextColor3 = if next then Color3.fromRGB(255, 214, 120) else Color3.fromRGB(140, 255, 160)
		end
	end

	-- Upgrade prompt lives on the treadmill frame.
	if frame and frame:IsA("BasePart") then
		local prompt = frame:FindFirstChild("TreadmillPrompt") :: ProximityPrompt?
		if not prompt then
			local created = Instance.new("ProximityPrompt")
			created.Name = "TreadmillPrompt"
			created.ActionText = "Upgrade Treadmill"
			created.ObjectText = "Treadmill"
			created.HoldDuration = 0.5
			created.MaxActivationDistance = 14
			created.RequiresLineOfSight = false
			created.Enabled = false -- owner-only, enabled client-side
			created.Parent = frame
			prompt = created
		end
		local p = prompt :: ProximityPrompt
		p:SetAttribute("ServerEnabled", active and TreadmillConfig.nextTier(profile.TreadmillLevel) ~= nil)
	end
end

-- ==========================================================
-- TRAINING
-- ==========================================================

--- True when the player is physically standing in their OWN treadmill trigger.
local function isOnOwnTreadmill(player: Player): boolean
	local plot = BaseService.getPlot(player)
	if not plot then
		return false
	end
	local treadmill = plot:FindFirstChild("Treadmill")
	local trigger = treadmill and treadmill:FindFirstChild("TrainingTrigger")
	if not trigger or not trigger:IsA("BasePart") then
		return false
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end

	local offset = trigger.CFrame:PointToObjectSpace(root.Position)
	local half = trigger.Size / 2
	return math.abs(offset.X) <= half.X
		and math.abs(offset.Y) <= half.Y
		and math.abs(offset.Z) <= half.Z
end

SpeedService.isOnOwnTreadmill = isOnOwnTreadmill

--- One authoritative tick. Every condition is re-checked here; nothing is
--- cached from the client.
local function trainingTick()
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if not profile or not profile.BaseActivated then
			continue
		end

		local character = player.Character
		local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			continue
		end

		if not isOnOwnTreadmill(player) then
			continue
		end

		local tier = TreadmillConfig.tier(profile.TreadmillLevel)
		if not tier then
			continue
		end

		profile.SpeedPower += tier.gainPerTick
		SpeedService.applyMovement(player)
		StateService.markDirty(player)
	end
end

-- ==========================================================
-- START
-- ==========================================================

function SpeedService.start()
	BaseService.onRebuilt(function(player)
		SpeedService.refreshTreadmill(player)
	end)

	-- Activation pads exist in the map; make them interactive.
	local bases = workspace:WaitForChild("Map", 20):WaitForChild("Bases", 10)
	for _, plot in bases:GetChildren() do
		local pad = plot:FindFirstChild("BaseActivationPad")
		if pad and pad:IsA("BasePart") and not pad:FindFirstChild("ActivatePrompt") then
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "ActivatePrompt"
			prompt.ActionText = "Activate Base"
			prompt.ObjectText = NumberFormat.cash(BaseConfig.ACTIVATION_COST)
			prompt.HoldDuration = 0.5
			prompt.MaxActivationDistance = 12
			prompt.RequiresLineOfSight = false
			prompt.Enabled = false -- owner-only, enabled client-side
			prompt:SetAttribute("ServerEnabled", true)
			prompt.Parent = pad
		end
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		local isActivate = prompt.Name == "ActivatePrompt"
		local isUpgrade = prompt.Name == "TreadmillPrompt"
		if not isActivate and not isUpgrade then
			return
		end

		-- Ownership is re-validated here, not trusted from the client's prompt.
		local plot = prompt:FindFirstAncestorOfClass("Folder")
		while plot and plot.Parent ~= bases do
			plot = plot.Parent :: Folder?
		end
		if not plot or BaseService.getPlot(player) ~= plot then
			notify(player, "error", "That is not your base.")
			return
		end

		local ok, reason = if isActivate
			then SpeedService.activateBase(player)
			else SpeedService.upgradeTreadmill(player)

		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	Remotes.get("TreadmillUpgradeRequest").OnServerEvent:Connect(function(player)
		local ok, reason = SpeedService.upgradeTreadmill(player)
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	local function onPlayer(player: Player)
		task.spawn(function()
			DataService.waitForProfile(player)
			SpeedService.refreshTreadmill(player)
			SpeedService.applyMovement(player)
		end)
		player.CharacterAdded:Connect(function()
			task.wait(0.3)
			SpeedService.applyMovement(player)
		end)
	end

	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)

	Players.PlayerRemoving:Connect(function(player)
		upgradeLimiter:release(player)
	end)

	task.spawn(function()
		while true do
			task.wait(TreadmillConfig.TICK_INTERVAL)
			trainingTick()
		end
	end)

	print("[SpeedService] treadmill training online")
end

return SpeedService
