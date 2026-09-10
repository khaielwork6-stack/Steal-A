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

--- A TICK OF TRAINING THAT ACTUALLY PAID. Fired from the authoritative tick
--- below, after the Speed has landed on the profile - so it means "this player
--- ran on their own treadmill and was paid for it", never "a client said so".
--- Injected for the same reason as the multiplier above; the beginner
--- checklist is the current listener.
function SpeedService.onTrained(_player: Player) end

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
		-- The price lives on the upgrade board beside the treadmill now; the
		-- floating label only says when there is nothing left to buy.
		detail.Text = if next then "" else "MAX LEVEL"
		detail.TextColor3 = Color3.fromRGB(140, 255, 160)
	end

	-- The old Hold-E prompt is gone: the board beside the treadmill is the
	-- upgrade. A prompt left on a baked plot is removed on sight.
	if frame and frame:IsA("BasePart") then
		local stale = frame:FindFirstChild("TreadmillPrompt")
		if stale then
			stale:Destroy()
		end
		SpeedService.refreshUpgradeBoard(plot, frame, profile.TreadmillLevel)
	end
end

-- ==========================================================
-- THE UPGRADE BOARD
-- ==========================================================
--
-- A sign beside the treadmill, in the base upgrade sign's own kit (post,
-- edge, navy board, studs): "Upgrade", "Level N > Level N+1", a red Cash
-- button and a purple Robux button. Each button is its own part with a
-- ClickDetector - a click or a tap on a phone, no hold - answered ONLY for
-- the plot's owner, through the same upgradeTreadmill / product prompt the
-- old Hold-E prompt used. Server-built once per plot, repainted on every
-- refresh, so what it shows is always the profile.

local BOARD_NAME = "TreadmillUpgradeBoard"
local BOARD_WIDTH = 11
local BOARD_HEIGHT = 6.4
local BOARD_DEPTH = 0.8
local BOARD_LIFT = 5.6
--- Studs off the deck's side, along its RightVector.
local BOARD_SIDE_OFFSET = 9.4
local BOARD_CLICK_RANGE = 40

--- Live Robux price for a treadmill product key. Injected by init from
--- MonetizationService (which requires this service, so it cannot be
--- required back). Nil until prices have landed.
function SpeedService.robuxPriceFor(_productKey: string): number?
	return nil
end

--- Opens the Robux purchase for the NEXT tier. Injected by init for the
--- same reason.
function SpeedService.promptRobuxUpgrade(_player: Player): (boolean, string?)
	return false, "Not available yet."
end

local function boardSlab(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance, hittable: boolean?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = hittable == true
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function boardText(parent: Instance, name: string, size: UDim2, position: UDim2, color: Color3, zIndex: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Size = size
	text.Position = position
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = color
	text.TextStrokeTransparency = 0
	text.TextStrokeColor3 = Color3.fromRGB(12, 16, 32)
	text.ZIndex = zIndex
	text.Parent = parent
	return text
end

--- One of the two purchase buttons: a raised block on the board's face with
--- its own SurfaceGui (icon + price) and ClickDetector.
local function boardButton(model: Model, name: string, cf: CFrame, size: Vector3, color: Color3, edge: Color3, icon: string): (Part, TextLabel)
	local edgePart = boardSlab(name .. "Edge", size + Vector3.new(0.5, 0.5, -0.1), cf, edge, model)
	edgePart.CanQuery = false
	local part = boardSlab(name, size, cf * CFrame.new(0, 0, -0.08), color, model, true)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.LightInfluence = 0
	gui.Adornee = part
	gui.Parent = part

	local glyph = boardText(gui, "Icon", UDim2.fromScale(0.26, 0.7), UDim2.fromScale(0.03, 0.15), Color3.fromRGB(255, 255, 255), 3)
	glyph.Text = icon
	-- Named per button ("CashPrice" / "RobuxPrice") so a rebuild can find it.
	local price = boardText(gui, name .. "Price", UDim2.fromScale(0.66, 0.72), UDim2.fromScale(0.3, 0.14), Color3.fromRGB(255, 255, 255), 3)
	price.TextXAlignment = Enum.TextXAlignment.Left

	local detector = Instance.new("ClickDetector")
	detector.Name = "Click"
	detector.MaxActivationDistance = BOARD_CLICK_RANGE
	detector.Parent = part
	return part, price
end

--- Builds the board once per plot and returns its labels.
local function ensureBoard(plot: Instance, deck: BasePart): (Model, { [string]: TextLabel })
	local existing = plot:FindFirstChild(BOARD_NAME)
	if existing and existing:IsA("Model") then
		local labels: { [string]: TextLabel } = {}
		for key, name in { Title = "Title", Level = "Level", CashPrice = "CashButtonPrice", RobuxPrice = "RobuxButtonPrice" } do
			local found = existing:FindFirstChild(name, true)
			if found and found:IsA("TextLabel") then
				labels[key] = found
			end
		end
		return existing, labels
	end

	local model = Instance.new("Model")
	model.Name = BOARD_NAME

	-- Beside the deck (its -Right side, the side the base sign is not on),
	-- facing the corridor the player walks in from.
	local facing = CFrame.lookAt(
		deck.Position - deck.CFrame.RightVector * BOARD_SIDE_OFFSET,
		deck.Position - deck.CFrame.RightVector * BOARD_SIDE_OFFSET + deck.CFrame.LookVector
	)
	local floorY = deck.Position.Y - deck.Size.Y / 2
	local base = CFrame.new(facing.Position.X, floorY + BOARD_LIFT, facing.Position.Z) * facing.Rotation

	local postTop = BOARD_LIFT - BOARD_HEIGHT / 2
	boardSlab("Post", Vector3.new(1.4, postTop, 1.4), CFrame.new(base.Position.X, floorY + postTop / 2, base.Position.Z) * facing.Rotation, MapPalette.SignPost, model)
	boardSlab("Edge", Vector3.new(BOARD_WIDTH + 0.8, BOARD_HEIGHT + 0.8, BOARD_DEPTH), base, MapPalette.SignEdge, model)
	local board = boardSlab("Board", Vector3.new(BOARD_WIDTH, BOARD_HEIGHT, BOARD_DEPTH + 0.1), base, MapPalette.SignBody, model)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.LightInfluence = 0
	gui.Adornee = board
	gui.Parent = board
	local studs = Instance.new("ImageLabel")
	studs.Name = "Studs"
	studs.BackgroundTransparency = 1
	studs.Image = "rbxassetid://76728843491214"
	studs.ImageTransparency = 0.86
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(40, 40)
	studs.Size = UDim2.fromScale(1, 1)
	studs.ZIndex = 1
	studs.Parent = gui

	local labels: { [string]: TextLabel } = {}
	labels.Title = boardText(gui, "Title", UDim2.fromScale(0.94, 0.24), UDim2.fromScale(0.03, 0.04), MapPalette.SignTitle, 2)
	labels.Title.Text = "Upgrade"
	labels.Level = boardText(gui, "Level", UDim2.fromScale(0.94, 0.2), UDim2.fromScale(0.03, 0.29), MapPalette.SignProgress, 2)

	-- The two buttons stand proud of the board's face, side by side.
	local faceZ = -(BOARD_DEPTH + 0.1) / 2 - 0.16
	local buttonY = -BOARD_HEIGHT * 0.22
	local buttonHeight = BOARD_HEIGHT * 0.34
	local cashWidth = BOARD_WIDTH * 0.52
	local robuxWidth = BOARD_WIDTH * 0.3
	local gap = BOARD_WIDTH * 0.04
	local cashX = -BOARD_WIDTH / 2 + 0.5 + cashWidth / 2
	local robuxX = cashX + cashWidth / 2 + gap + robuxWidth / 2
	local _, cashPrice = boardButton(model, "CashButton", base * CFrame.new(cashX, buttonY, faceZ), Vector3.new(cashWidth, buttonHeight, 0.3), MapPalette.SignButton, MapPalette.SignButtonEdge, "🏃")
	local _, robuxPrice = boardButton(model, "RobuxButton", base * CFrame.new(robuxX, buttonY, faceZ), Vector3.new(robuxWidth, buttonHeight, 0.3), Color3.fromRGB(190, 70, 235), Color3.fromRGB(110, 30, 150), utf8.char(0xE002))
	labels.CashPrice = cashPrice
	labels.RobuxPrice = robuxPrice

	-- Clicks: owner only, and never twice for one press (upgradeLimiter and
	-- the purchase prompt's own limiter sit behind both).
	local cashButton = model:FindFirstChild("CashButton") :: Part
	local robuxButton = model:FindFirstChild("RobuxButton") :: Part
	;(cashButton:FindFirstChild("Click") :: ClickDetector).MouseClick:Connect(function(player)
		if BaseService.getPlot(player) ~= plot then
			return
		end
		local ok, reason = SpeedService.upgradeTreadmill(player)
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)
	;(robuxButton:FindFirstChild("Click") :: ClickDetector).MouseClick:Connect(function(player)
		if BaseService.getPlot(player) ~= plot then
			return
		end
		local ok, reason = SpeedService.promptRobuxUpgrade(player)
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	model.Parent = plot
	return model, labels
end

--- Repaints the board for the level the profile is at.
function SpeedService.refreshUpgradeBoard(plot: Instance, deck: BasePart, level: number)
	local model, labels = ensureBoard(plot, deck)
	local next = TreadmillConfig.nextTier(level)
	local cashButton = model:FindFirstChild("CashButton")
	local robuxButton = model:FindFirstChild("RobuxButton")

	if next then
		if labels.Level then
			labels.Level.Text = `Level {level} > Level {next.level}`
			labels.Level.TextColor3 = MapPalette.SignProgress
		end
		if labels.CashPrice then
			labels.CashPrice.Text = NumberFormat.cash(next.cost)
		end
		local robux = if next.robuxProductKey then SpeedService.robuxPriceFor(next.robuxProductKey) else nil
		if labels.RobuxPrice then
			labels.RobuxPrice.Text = if robux then tostring(robux) else "..."
		end
		if cashButton and cashButton:IsA("BasePart") then
			cashButton.Color = MapPalette.SignButton
		end
		if robuxButton and robuxButton:IsA("BasePart") then
			robuxButton.Color = Color3.fromRGB(190, 70, 235)
			robuxButton.Transparency = if next.robuxProductKey then 0 else 0.6
		end
	else
		if labels.Level then
			labels.Level.Text = "MAX LEVEL"
			labels.Level.TextColor3 = MapPalette.SignMaxed
		end
		if labels.CashPrice then
			labels.CashPrice.Text = "MAXED"
		end
		if labels.RobuxPrice then
			labels.RobuxPrice.Text = "-"
		end
		if cashButton and cashButton:IsA("BasePart") then
			cashButton.Color = MapPalette.SignButtonEdge
		end
		if robuxButton and robuxButton:IsA("BasePart") then
			robuxButton.Color = Color3.fromRGB(110, 30, 150)
		end
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

-- ==========================================================
-- WHO IS RUNNING, FOR EVERYONE ELSE TO SEE
-- ==========================================================
--
-- The runner's own client plays its run cycle locally the frame it steps on
-- (TreadmillController). Nobody else can rely on that: a client-started
-- track on an Animator the default Animate script also drives does not
-- reliably reach other clients, so from across the plot a training player
-- looked parked. The SERVER already knows who is training - it is the thing
-- paying them - so it publishes that fact ONCE per change as an attribute on
-- the character, and every client plays the run cycle on every OTHER
-- character that carries it (TreadmillSpectateController). No RemoteEvent,
-- nothing per frame: the attribute is written when a session starts, when
-- the stride rate crosses a step, and cleared when the session ends -
-- through this tick's own detection, which is the same one the reward uses,
-- so a jump-off, a walk-off, a death, a teleport or a reset all clear it
-- within one tick. A disconnect destroys the character, attribute and all.

--- Characters currently published as running: which Model carries the flag
--- and the rate written last. The Model is remembered so a respawn (a new
--- character, no flag) that steps straight back on at the same rate is
--- still written - the previous rate belonged to a character that is gone.
local runningRate: { [Player]: number } = {}
local runningCharacter: { [Player]: Model } = {}

local function publishRunning(player: Player, character: Model?, rate: number?)
	local previous = runningRate[player]
	local previousCharacter = runningCharacter[player]
	if rate == nil then
		if previous ~= nil then
			runningRate[player] = nil
			runningCharacter[player] = nil
			if previousCharacter then
				previousCharacter:SetAttribute(TreadmillConfig.RUN_ATTRIBUTE, nil)
			end
		end
		return
	end
	if not character then
		return
	end
	-- Quantised so the steady trickle of treadmill ticks does not become a
	-- steady trickle of attribute writes: a change reaches the spectators
	-- only when the stride rate moves by a visible step.
	local stepped = math.floor(rate / TreadmillConfig.RUN_RATE_STEP + 0.5) * TreadmillConfig.RUN_RATE_STEP
	if previous ~= stepped or previousCharacter ~= character then
		runningRate[player] = stepped
		runningCharacter[player] = character
		character:SetAttribute(TreadmillConfig.RUN_ATTRIBUTE, stepped)
	end
end

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
			publishRunning(player, character, nil)
			continue
		end

		if not isOnOwnTreadmill(player) then
			publishRunning(player, character, nil)
			continue
		end

		local tier = TreadmillConfig.tier(profile.TreadmillLevel)
		if not tier then
			publishRunning(player, character, nil)
			continue
		end

		-- Visible to everyone: the stride rate is the SAME function of the
		-- player's real WalkSpeed the runner's own client uses, so the runner
		-- and the spectators see the same pace.
		publishRunning(player, character, TreadmillConfig.runAnimationRate(GameConfig.walkSpeedFromPower(profile.SpeedPower)))

		local before = profile.SpeedPower
		-- THE TRAINING CALCULATION (TreadmillConfig.gainPerTick):
		--
		--     gain = TRAINING_BASE_GAIN x treadmill.factor x (1 + (trail - 1) + (pass - 1))
		--
		-- The treadmill factor multiplies on its own; the equipped trail's factor
		-- and the Speed-pass tier ADD above their base of 1 and never multiply
		-- each other. Nothing here touches `profile.SpeedPower` except the gain:
		-- multiplying the saved total would compound on every purchase.
		local bonus = TreadmillConfig.bonusFactor(CarryService.trailMultiplierFor(player), SpeedService.trainingMultiplier(player))
		profile.SpeedPower += TreadmillConfig.gainPerTick(profile.TreadmillLevel, bonus)
		SpeedService.applyMovement(player)
		StateService.markDirty(player)

		-- The training has been PAID. Anything watching for "they used the
		-- treadmill" hears about it here and nowhere earlier. In a pcall so
		-- one listener cannot break the tick for every player on the server.
		local trained, trainedErr = pcall(SpeedService.onTrained, player)
		if not trained then
			warn(`[SpeedService] training listener failed for {player.Name}: {trainedErr}`)
		end

		-- Crossing a zone's recommended Speed is the single moment the long
		-- treadmill grind pays off, so it gets its own cue. THE CUE ONLY: the
		-- "<ZONE> UNLOCKED" toast used to land mid-screen over the runner and
		-- the reward popups; the zone gate's sign and the Index still show
		-- the unlock. Compared against the value BEFORE the tick, so it fires
		-- exactly once per gate however large the increment was.
		for _, zone in ZoneConfig.Zones do
			if zone.recommendedSpeed > before and zone.recommendedSpeed <= profile.SpeedPower then
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

	-- The Hold-E treadmill prompt is retired (the board beside the treadmill
	-- is the upgrade); any left on a baked plot is removed in refreshTreadmill.

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
		-- The character goes with the player, attribute and all; only the
		-- bookkeeping needs clearing so a rejoin starts unpublished.
		runningRate[player] = nil
		runningCharacter[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(TreadmillConfig.TICK_INTERVAL)
			trainingTick()
		end
	end)

	-- The map is baked into the place, so MapBuilder's change to the cosmetic
	-- Belt strip does not reach plots that already exist. Hide every one here:
	-- it carries no gameplay (the invisible Frame deck is the standing surface
	-- and TrainingTrigger is the detector) and on unassigned plots it was a navy
	-- slab floating in the corridor.
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if bases then
		for _, plot in bases:GetChildren() do
			local treadmill = plot:FindFirstChild("Treadmill")
			local belt = treadmill and treadmill:FindFirstChild("Belt")
			if belt and belt:IsA("BasePart") then
				belt.Transparency = 1
			end
		end
	end

	print("[SpeedService] treadmill training online")
end

return SpeedService
