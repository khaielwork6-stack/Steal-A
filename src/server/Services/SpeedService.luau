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

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local TreadmillModel = require(ReplicatedStorage.Shared.Util.TreadmillModel)
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

local function notify(player: Player, kind: string, message: string, detail: string?)
	StateService.notify(player, kind, message, detail)
end

-- ==========================================================
-- MOVEMENT
-- ==========================================================

--- Re-derives WalkSpeed from the profile. Routed through CarryService so the
--- carry penalty is applied in one place rather than two.
function SpeedService.applyMovement(player: Player)
	CarryService.applyMovement(player)
end

--- The permanent Speed gamepass multiplier on TRAINING GAIN. Overridden by init
--- so this service does not have to require MonetizationService; returns 1 until
--- ownership is warmed, which is the safe direction.
function SpeedService.trainingMultiplier(_player: Player): number
	return 1
end

-- ==========================================================
-- ACTIVATION - REMOVED ON PURPOSE
-- ==========================================================
--
-- There is no longer a Base Activation step. Being assigned a plot IS the
-- activation: `DataService` sets BaseActivated true in the default profile AND
-- forces it true in `reconcile` on every load, so a player's base is claimed,
-- active and fully usable from their first frame, and every system that gates
-- on it (placement, storage, income, the treadmill, prompts, the tutorial)
-- initialises correctly with nothing to unlock.
--
-- The old flow charged $1,000 for it, which is why the onboarding Cash bridge
-- existed; both are gone together. `BaseConfig.ACTIVATION_COST` is retired and
-- the activation pad is now hidden by refreshTreadmill.
--
-- Deliberately NOT left as a stub that flips the flag: nothing should be able to
-- put a base into an inactive state, so there is no code path that can.

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
		`Treadmill {next.name}! +{NumberFormat.short(TreadmillConfig.gainPerSecond(next.level))} Speed/s`,
		"levelup"
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

--- Lit and labelled. There is no inactive state any more - a base is active
--- from assignment, so the treadmill is always live (see the ACTIVATION section).
function SpeedService.refreshTreadmill(player: Player)
	local plot = BaseService.getPlot(player)
	local profile = DataService.get(player)
	if not plot or not profile then
		return
	end

	local treadmill = plot:FindFirstChild("Treadmill")
	if not treadmill then
		return
	end

	local belt = treadmill:FindFirstChild("Belt")
	local frame = treadmill:FindFirstChild("Frame")

	if belt and belt:IsA("BasePart") then
		belt.Color = MapPalette.TreadmillBelt
		belt.Material = Enum.Material.SmoothPlastic
	end
	if frame and frame:IsA("BasePart") then
		frame.Color = MapPalette.Treadmill
	end

	-- Dress the rig with the art for this tier. The invisible deck and trigger
	-- never move, so an upgrade is purely a model swap and the player's standing
	-- height and position are identical on every tier.
	if frame and frame:IsA("BasePart") then
		local wanted = math.max(profile.TreadmillLevel, 1)
		local existing = treadmill:FindFirstChild(TreadmillModel.MODEL_NAME)

		-- Rebuilding an unchanged model every push would churn parts under a
		-- player who is standing on it, so only swap on an actual change.
		if not existing or existing:GetAttribute("TreadmillLevel") ~= wanted then
			if existing then
				existing:Destroy()
			end
			local built = TreadmillModel.build(wanted)
			if built then
				local deckTop = frame.Position.Y + frame.Size.Y / 2
				TreadmillModel.align(built, frame.Position, deckTop, frame.CFrame)
				built.Parent = treadmill
				existing = built
			end
		end

		-- The authored look is restored from the attributes stashed at build
		-- time, never from the part's current colour - an older build greyed
		-- these out while the base was inactive, so a part reloaded from a saved
		-- place may still be carrying the grey.
		if existing then
			for _, part in existing:GetDescendants() do
				if part:IsA("BasePart") then
					local lit = part:GetAttribute("LitColor")
					if typeof(lit) == "Color3" then
						part.Color = lit
					end
					local material = part:GetAttribute("LitMaterial")
					if type(material) == "string" then
						part.Material = (Enum.Material :: any)[material] or part.Material
					end
				end
			end
		end
	end

	-- Label above the treadmill. Its height is derived from whatever model is
	-- attached, not fixed: the tiers range from a low 8-stud frame to an 11-stud
	-- ice arch, and a constant offset left the name and price buried inside the
	-- taller ones.
	local anchor = frame or belt
	if anchor and anchor:IsA("BasePart") then
		local labelY = 8
		local attached = treadmill:FindFirstChild(TreadmillModel.MODEL_NAME)
		if attached and attached:IsA("Model") then
			local _, top = TreadmillModel.worldExtents(attached)
			if top then
				labelY = (top.Y - anchor.Position.Y) + 3
			end
		end

		local gui = anchor:FindFirstChild("TreadmillLabel") :: BillboardGui?
		if not gui then
			local created = Instance.new("BillboardGui")
			created.Name = "TreadmillLabel"
			created.Size = UDim2.fromScale(12, 3.4)
			created.StudsOffsetWorldSpace = Vector3.new(0, labelY, 0)
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

		-- Re-applied every refresh, not just on creation: the model underneath it
		-- changes with the tier, so a height fixed at creation would be wrong for
		-- every subsequent upgrade.
		;(gui :: BillboardGui).StudsOffsetWorldSpace = Vector3.new(0, labelY, 0)

		local title = (gui :: BillboardGui):FindFirstChild("Title") :: TextLabel
		local detail = (gui :: BillboardGui):FindFirstChild("Detail") :: TextLabel

		local tier = TreadmillConfig.tier(profile.TreadmillLevel)
		local next = TreadmillConfig.nextTier(profile.TreadmillLevel)
		title.Text = `{if tier then tier.name else "Basic"} · +{NumberFormat.short(TreadmillConfig.gainPerSecond(profile.TreadmillLevel))}/s`
		title.TextColor3 = Color3.fromRGB(126, 236, 255)
		detail.Text = if next
			then `Upgrade · {NumberFormat.cash(next.cost)}`
			else "MAX LEVEL"
		detail.TextColor3 = if next then Color3.fromRGB(255, 214, 120) else Color3.fromRGB(140, 255, 160)
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
		p:SetAttribute("ServerEnabled", TreadmillConfig.nextTier(profile.TreadmillLevel) ~= nil)
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
		if not profile then
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

		local before = profile.SpeedPower
		-- Base treadmill gain x the permanent Speed gamepass tier.
		--
		-- The multiplier scales what is EARNED from here on. It deliberately does
		-- NOT touch `profile.SpeedPower` itself: multiplying the saved total on
		-- purchase would compound every time they bought a tier and corrupt the
		-- stat permanently.
		--
		-- Trails are NOT in this line. A trail multiplies MOVEMENT, not training
		-- (see CarryService.applyMovement) - keeping them in separate formulas is
		-- what stops the two from silently multiplying together.
		profile.SpeedPower += tier.gainPerTick * SpeedService.trainingMultiplier(player)
		SpeedService.applyMovement(player)
		StateService.markDirty(player)

		-- Crossing a zone's recommended Speed is the single moment the long
		-- treadmill grind pays off, so it gets its own cue and a toast. Compared
		-- against the value BEFORE the tick, so it fires exactly once per gate
		-- however large the increment was.
		for _, zone in ZoneConfig.Zones do
			if zone.recommendedSpeed > before and zone.recommendedSpeed <= profile.SpeedPower then
				notify(player, "success", `{string.upper(zone.name)} UNLOCKED`, "unlock")
				StateService.sound(player, "ZoneUnlock")
				break
			end
		end
	end
end

-- ==========================================================
-- START
-- ==========================================================

function SpeedService.start()
	BaseService.onRebuilt(function(player)
		SpeedService.refreshTreadmill(player)
	end)

	-- The activation pad is retired. Any prompt left on one by an older build is
	-- removed here rather than left hanging around offering an action that no
	-- longer exists - the map is baked into the place file, so a stale prompt
	-- would otherwise survive indefinitely.
	local bases = workspace:WaitForChild("Map", 20):WaitForChild("Bases", 10)
	for _, plot in bases:GetChildren() do
		local pad = plot:FindFirstChild("BaseActivationPad")
		local stale = pad and pad:FindFirstChild("ActivatePrompt")
		if stale then
			stale:Destroy()
		end
		if pad and pad:IsA("BasePart") then
			pad.Transparency = 1
			pad.CanCollide = false
			pad.CanQuery = false
		end
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name ~= "TreadmillPrompt" then
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

		local ok, reason = SpeedService.upgradeTreadmill(player)
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
