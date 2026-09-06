--!strict
--[[
	TrailService
	Trail ownership, equipping, the movement bonus and the visual effect.

	TWO ROUTES TO THE SAME UNLOCK
	Cash and Robux are ALTERNATIVES, not a two-step purchase. A trail is owned if
	EITHER is true:
	  * `profile.TrailsOwned[key]` - bought with Cash, saved by us.
	  * the trail's gamepass - bought with Robux, owned by ROBLOX.

	The Robux half is deliberately not mirrored into the profile. Roblox already
	knows, it can change (refunds, revokes), and a saved copy would be a second
	source of truth that silently goes stale. We ask, and we cache the answer.

	EXACTLY ONE EQUIPPED
	`profile.EquippedTrail` is a single key, not a set. Equipping replaces, so the
	multipliers can never add up - equipping Blue after Green is x2.5, not x4.5.

	WHERE THE MULTIPLIER LANDS
	`CarryService.applyMovement`, and nowhere else. It scales the effective Speed
	fed into the conversion, so it rides the same curve as everything else and can
	never break the WalkSpeed clamp. It does NOT touch training gain - that is the
	Speed gamepass tier's job - and it does NOT touch the saved stat.

	THE VISUAL IS BUILT, NOT IMPORTED
	No trail assets were supplied, and a shipped asset id is one more thing that
	can come back "not approved for the requester" the way the lobby music did. So
	each tier is a real `Trail` instance coloured from its own config row: no
	asset dependency, no per-tier art to maintain, and adding a tier is a config
	row rather than an import.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local MonetizationService = require(script.Parent.MonetizationService)
local StateService = require(script.Parent.StateService)

local TrailService = {}

local buyLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.TrailRequest)

local ATTACHMENT_TOP = "TrailTop"
local ATTACHMENT_BOTTOM = "TrailBottom"
local TRAIL_NAME = "EquippedTrail"

-- ==========================================================
-- OWNERSHIP
-- ==========================================================

--- Owned by EITHER route. The server is the only thing that answers this.
function TrailService.owns(player: Player, trailKey: string): boolean
	local trail = MonetizationConfig.TrailByKey[trailKey]
	if not trail then
		return false
	end
	local profile = DataService.get(player)
	if profile and profile.TrailsOwned[trailKey] then
		return true
	end
	return MonetizationService.ownsTrailPass(player, trailKey)
end

--- The equipped trail's multiplier, or 1. Read by CarryService.applyMovement.
---
--- Verifies ownership rather than trusting the saved key: a Robux trail that has
--- been refunded should stop applying, and it should do so without needing a
--- migration pass over everyone's save.
function TrailService.multiplierFor(player: Player): number
	local profile = DataService.get(player)
	if not profile or profile.EquippedTrail == "" then
		return 1
	end
	local trail = MonetizationConfig.TrailByKey[profile.EquippedTrail]
	if not trail or not TrailService.owns(player, profile.EquippedTrail) then
		return 1
	end
	return trail.multiplier
end

-- ==========================================================
-- VISUAL
-- ==========================================================

local function clearTrail(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	for _, name in { TRAIL_NAME, ATTACHMENT_TOP, ATTACHMENT_BOTTOM } do
		local existing = root:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
end

--- Attaches the equipped trail's effect. Always clears first, so switching
--- trails cannot leave the old one behind and a double-equip cannot stack two.
function TrailService.applyVisual(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	clearTrail(character)

	local profile = DataService.get(player)
	if not profile or profile.EquippedTrail == "" then
		return
	end
	local trail = MonetizationConfig.TrailByKey[profile.EquippedTrail]
	if not trail or not TrailService.owns(player, profile.EquippedTrail) then
		return
	end

	local top = Instance.new("Attachment")
	top.Name = ATTACHMENT_TOP
	top.Position = Vector3.new(0, 1.4, 0)
	top.Parent = root

	local bottom = Instance.new("Attachment")
	bottom.Name = ATTACHMENT_BOTTOM
	bottom.Position = Vector3.new(0, -1.4, 0)
	bottom.Parent = root

	local effect = Instance.new("Trail")
	effect.Name = TRAIL_NAME
	effect.Attachment0 = top
	effect.Attachment1 = bottom
	effect.Color = ColorSequence.new(trail.color, trail.accent)
	effect.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	-- Longer and brighter as the tier climbs, so prestige reads while moving.
	-- Bounded deliberately: this is one Trail instance per player, not a particle
	-- system, so it costs effectively nothing however many players are on.
	effect.Lifetime = math.clamp(0.35 + trail.multiplier * 0.06, 0.35, 1.1)
	effect.MinLength = 0.05
	effect.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	effect.LightEmission = math.clamp(0.2 + trail.multiplier * 0.05, 0.2, 0.9)
	effect.FaceCamera = true
	effect.Parent = root
end

-- ==========================================================
-- PURCHASE AND EQUIP
-- ==========================================================

--- Buys a trail with CASH. The client sends a KEY, never a price: the server
--- looks the cost up in its own config, so a tampered client can ask for a trail
--- but can never name what it costs.
function TrailService.buyWithCash(player: Player, trailKey: string): (boolean, string?)
	if not buyLimiter:consume(player) then
		return false, "Slow down!"
	end

	local trail = MonetizationConfig.TrailByKey[trailKey]
	if not trail then
		return false, "That trail does not exist."
	end

	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	if TrailService.owns(player, trailKey) then
		return false, "You already own that trail."
	end

	-- Atomic: spend first, and only record the unlock if the spend succeeded.
	if not EconomyService.spend(player, trail.cash) then
		return false, `NOT ENOUGH CASH - you need {NumberFormat.cash(trail.cash)}.`
	end

	profile.TrailsOwned[trailKey] = true
	TrailService.equip(player, trailKey)

	StateService.notify(player, "success", `{string.upper(trail.name)} UNLOCKED!`, "levelup")
	StateService.pushNow(player)
	return true
end

--- Equips an owned trail. Replaces whatever was equipped - never adds.
function TrailService.equip(player: Player, trailKey: string): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end

	-- "" unequips.
	if trailKey == "" then
		profile.EquippedTrail = ""
		TrailService.applyVisual(player)
		TrailService.refreshMovement(player)
		StateService.pushNow(player)
		return true
	end

	if not MonetizationConfig.TrailByKey[trailKey] then
		return false, "That trail does not exist."
	end
	if not TrailService.owns(player, trailKey) then
		return false, "You do not own that trail."
	end

	profile.EquippedTrail = trailKey
	TrailService.applyVisual(player)
	TrailService.refreshMovement(player)
	StateService.pushNow(player)
	return true
end

--- Overridden by init so this service need not require SpeedService/CarryService.
function TrailService.refreshMovement(_player: Player) end

--- What the Trail Shop needs to draw itself, computed server-side. The client
--- renders this; it never decides ownership or price for itself.
function TrailService.summarise(player: Player): { [string]: any }
	local profile = DataService.get(player)
	local rows = {}
	for _, trail in MonetizationConfig.Trails do
		table.insert(rows, {
			key = trail.key,
			owned = TrailService.owns(player, trail.key),
			equipped = profile ~= nil and profile.EquippedTrail == trail.key,
		})
	end
	return rows
end

-- ==========================================================
-- START
-- ==========================================================

-- ==========================================================
-- THE PHYSICAL SHOP
-- ==========================================================
--
-- Trails are NOT a tab on the main Shop. The player walks to a keeper standing
-- in the base plaza and holds E, using the same ProximityPrompt language every
-- other interaction in the game uses - so it needs no new input teaching, and
-- InteractController renders it with the pack's own prompt automatically.
--
-- The kiosk is built from parts rather than an imported model because no NPC
-- asset was supplied. It reuses the sign construction the base upgrade station
-- already uses, so it reads as part of the same world.

local KEEPER_NAME = "TrailShopKeeper"

local function slab(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function buildKeeper()
	local map = workspace:FindFirstChild("Map")
	if not map or map:FindFirstChild(KEEPER_NAME) then
		return
	end

	-- In the plaza, on the safe side of the red line, off to one side of the
	-- corridor mouth so it is passed on the way out but never blocks the run.
	local base = CFrame.new(-70, 0, -30) * CFrame.Angles(0, math.rad(35), 0)

	local model = Instance.new("Model")
	model.Name = KEEPER_NAME

	slab("Pad", Vector3.new(14, 0.6, 14), base * CFrame.new(0, 0.3, 0), Color3.fromRGB(58, 46, 96), model)
	slab("Post", Vector3.new(1.4, 7, 1.4), base * CFrame.new(0, 3.5, 0), Color3.fromRGB(150, 100, 58), model)
	local board = slab("Board", Vector3.new(11, 4.4, 0.9), base * CFrame.new(0, 8.4, 0), Color3.fromRGB(78, 38, 128), model)
	slab("Edge", Vector3.new(11.8, 5.2, 0.6), base * CFrame.new(0, 8.4, 0.25), Color3.fromRGB(38, 16, 68), model)

	-- A ribbon of every tier's colour: the shop advertises what it sells without
	-- needing a single piece of authored art.
	for index, trail in MonetizationConfig.Trails do
		local offset = (index - (#MonetizationConfig.Trails + 1) / 2) * 1.0
		slab(
			`Swatch{index}`,
			Vector3.new(0.85, 0.85, 0.85),
			base * CFrame.new(offset, 5.4, 0),
			trail.color,
			model
		)
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.LightInfluence = 0
	gui.Adornee = board
	gui.Parent = board

	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(0.94, 0.5)
	title.Position = UDim2.fromScale(0.03, 0.06)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextStrokeTransparency = 0
	title.TextStrokeColor3 = Color3.fromRGB(24, 8, 44)
	title.Text = "TRAIL SHOP"
	title.Parent = gui

	local sub = Instance.new("TextLabel")
	sub.Size = UDim2.fromScale(0.94, 0.34)
	sub.Position = UDim2.fromScale(0.03, 0.58)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.FredokaOne
	sub.TextScaled = true
	sub.TextColor3 = Color3.fromRGB(126, 236, 255)
	sub.TextStrokeTransparency = 0.3
	sub.Text = "Run faster - hold E"
	sub.Parent = gui

	-- The interaction volume. Queryable and collidable-free: you walk up to it,
	-- you do not walk into it.
	local trigger = Instance.new("Part")
	trigger.Name = "Trigger"
	trigger.Size = Vector3.new(10, 10, 10)
	trigger.CFrame = base * CFrame.new(0, 5, 0)
	trigger.Transparency = 1
	trigger.Anchored = true
	trigger.CanCollide = false
	trigger.CastShadow = false
	trigger.Parent = model

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TrailShopPrompt"
	prompt.ActionText = "Trail Shop"
	prompt.ObjectText = "Trails"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = trigger

	model.PrimaryPart = board
	model.Parent = map
end

function TrailService.start()
	buildKeeper()

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name ~= "TrailShopPrompt" then
			return
		end
		-- The server opens it. The client cannot decide it is at the shop.
		Remotes.get("TrailRequest"):FireClient(player, "open")
		StateService.pushNow(player)
	end)

	Remotes.get("TrailRequest").OnServerEvent:Connect(function(player, action, argument)
		if type(action) ~= "string" then
			return
		end

		local ok, reason
		if action == "buyCash" and type(argument) == "string" then
			ok, reason = TrailService.buyWithCash(player, argument)
		elseif action == "equip" and type(argument) == "string" then
			ok, reason = TrailService.equip(player, argument)
		elseif action == "buyRobux" and type(argument) == "string" then
			-- The server picks the gamepass id from its own config. The client
			-- names a trail, never an id, so it cannot make the game prompt for
			-- an arbitrary product.
			ok, reason = MonetizationService.promptTrailPass(player, argument)
		elseif action == "sync" then
			StateService.pushNow(player)
			return
		else
			return
		end

		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
	end)

	-- The trail has to come back on a new character: respawning, dying and being
	-- launched by a guardian all replace the model the effect was parented to.
	local function hook(player: Player)
		player.CharacterAdded:Connect(function()
			task.wait(0.3) -- let the rig finish assembling
			TrailService.applyVisual(player)
		end)
	end
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)

	print("[TrailService] trails online")
end

return TrailService
