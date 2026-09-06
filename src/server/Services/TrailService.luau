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
local TweenService = game:GetService("TweenService")
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

-- ==========================================================
-- THE BOOTH
-- ==========================================================
--
-- A small market stall, not a sign on a stick: four posts, a counter, a yellow
-- and white striped awning, a TRAILS SHOP board across the front, and a ribbon
-- of every tier's colour under it. In front of it, a glowing yellow circle on
-- the floor. WALK INTO THE CIRCLE and the shop opens; walk out and it closes.
-- There is no prompt and no key to hold.
--
-- Everything here is decorative and non-colliding except the counter and the
-- posts, which a player can lean on but never get stuck in.

--- Where the booth stands: in the plaza apron on the safe side of the red line,
--- off to one side of the corridor mouth so it is passed on the way out but
--- never blocks the run.
local BOOTH_CFRAME = CFrame.new(-72, 0, -30) * CFrame.Angles(0, math.rad(35), 0)
--- The interaction circle sits in FRONT of the counter, where a customer stands.
local ZONE_OFFSET = CFrame.new(0, 0, 9)
local ZONE_RADIUS = 8.5
--- Poll cadence for who is standing in the circle. Five times a second is well
--- under a stride at any Speed and costs one distance check per player.
local ZONE_POLL = 0.2

local ZONE_YELLOW = Color3.fromRGB(255, 226, 70)
local AWNING_YELLOW = Color3.fromRGB(255, 208, 48)
local AWNING_WHITE = Color3.fromRGB(250, 250, 245)
local WOOD = Color3.fromRGB(142, 92, 52)
local WOOD_DARK = Color3.fromRGB(96, 60, 32)
local COUNTER_TOP = Color3.fromRGB(196, 150, 96)

local function solid(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance, collide: boolean): Part
	local part = slab(name, size, cf, color, parent)
	part.Material = material
	part.CanCollide = collide
	part.CanQuery = collide
	part.CastShadow = true
	return part
end

local function buildKeeper()
	local map = workspace:FindFirstChild("Map")
	if not map or map:FindFirstChild(KEEPER_NAME) then
		return
	end

	local model = Instance.new("Model")
	model.Name = KEEPER_NAME
	local base = BOOTH_CFRAME

	-- Footprint: 12 wide (X), 7 deep (Z). Counter along the front edge.
	local width, depth = 12, 7
	local postHeight = 9.5

	-- Four posts at the corners.
	for _, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		solid(
			"Post",
			Vector3.new(0.9, postHeight, 0.9),
			base * CFrame.new(corner[1] * (width / 2 - 0.45), postHeight / 2, corner[2] * (depth / 2 - 0.45)),
			WOOD,
			Enum.Material.Wood,
			model,
			true
		)
	end

	-- Counter across the front: a body, a lighter top, a dark base rail.
	solid("CounterBody", Vector3.new(width, 3.0, 1.6), base * CFrame.new(0, 1.5, depth / 2 - 0.8), WOOD_DARK, Enum.Material.WoodPlanks, model, true)
	solid("CounterTop", Vector3.new(width + 0.6, 0.4, 2.2), base * CFrame.new(0, 3.2, depth / 2 - 0.8), COUNTER_TOP, Enum.Material.Wood, model, true)
	solid("CounterRail", Vector3.new(width + 0.2, 0.3, 1.8), base * CFrame.new(0, 0.15, depth / 2 - 0.8), WOOD_DARK, Enum.Material.Wood, model, false)
	-- A shelf behind the counter, so the stall has an inside.
	solid("Shelf", Vector3.new(width - 1.8, 0.3, 1.4), base * CFrame.new(0, 4.6, -depth / 2 + 1.0), WOOD, Enum.Material.Wood, model, false)

	-- Awning: a shallow pitched roof of alternating yellow and white strips,
	-- overhanging the front, with a scalloped edge suggested by a row of short
	-- tabs hanging off it.
	local awningDepth = depth + 3
	local stripCount = 9
	local stripWidth = (width + 1.4) / stripCount
	local pitch = math.rad(-12)
	for index = 1, stripCount do
		local x = -(width + 1.4) / 2 + stripWidth * (index - 0.5)
		local color = if index % 2 == 1 then AWNING_YELLOW else AWNING_WHITE
		solid(
			"Awning",
			Vector3.new(stripWidth + 0.02, 0.28, awningDepth),
			base * CFrame.new(x, postHeight + 0.6, 0.6) * CFrame.Angles(pitch, 0, 0),
			color,
			Enum.Material.Fabric,
			model,
			false
		)
		solid(
			"Scallop",
			Vector3.new(stripWidth + 0.02, 1.1, 0.28),
			base * CFrame.new(x, postHeight - 0.05, depth / 2 + 2.05),
			color,
			Enum.Material.Fabric,
			model,
			false
		)
	end

	-- The TRAILS SHOP board across the front, above the counter.
	local board = solid("Board", Vector3.new(width - 1.0, 2.4, 0.5), base * CFrame.new(0, postHeight - 2.0, depth / 2 - 0.2), Color3.fromRGB(38, 16, 68), Enum.Material.SmoothPlastic, model, false)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	-- The customer stands on the booth's +Z side (where the circle is), which is
	-- a part's BACK face. Front would paint the title toward the shelf.
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.LightInfluence = 0
	gui.Adornee = board
	gui.Parent = board
	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(0.94, 0.86)
	title.Position = UDim2.fromScale(0.03, 0.07)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 226, 70)
	title.TextStrokeTransparency = 0
	title.TextStrokeColor3 = Color3.fromRGB(24, 8, 44)
	title.Text = "TRAILS SHOP"
	title.Parent = gui

	-- A ribbon of every tier's colour along the counter front: the stall
	-- advertises what it sells without a single piece of authored art.
	for index, trail in MonetizationConfig.Trails do
		local offset = (index - (#MonetizationConfig.Trails + 1) / 2) * 1.05
		local swatch = solid(`Swatch{index}`, Vector3.new(0.8, 0.8, 0.3), base * CFrame.new(offset, 1.7, depth / 2 + 0.05), trail.color, Enum.Material.Neon, model, false)
		swatch.CastShadow = false
	end

	-- THE CIRCLE. A flat neon disc on the floor with a brighter ring around it,
	-- pulsing gently. Non-colliding, unqueryable: it is a picture of the zone;
	-- the zone itself is the distance check below.
	local centre = (base * ZONE_OFFSET).Position
	local disc = solid("Zone", Vector3.new(0.12, ZONE_RADIUS * 2, ZONE_RADIUS * 2), CFrame.new(centre + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, 0, math.rad(90)), ZONE_YELLOW, Enum.Material.Neon, model, false)
	disc.Shape = Enum.PartType.Cylinder
	disc.Transparency = 0.55
	disc.CastShadow = false
	local ring = solid("ZoneRing", Vector3.new(0.16, ZONE_RADIUS * 2 + 0.9, ZONE_RADIUS * 2 + 0.9), CFrame.new(centre + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, 0, math.rad(90)), ZONE_YELLOW, Enum.Material.Neon, model, false)
	ring.Shape = Enum.PartType.Cylinder
	ring.Transparency = 0.15
	ring.CastShadow = false
	-- A few sparkles rising off the disc. Low rate; this runs forever.
	local attachment = Instance.new("Attachment")
	attachment.Parent = disc
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "Sparkle"
	sparkle.Texture = "rbxassetid://241594419"
	sparkle.Color = ColorSequence.new(ZONE_YELLOW, Color3.fromRGB(255, 255, 220))
	sparkle.LightEmission = 0.8
	sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	sparkle.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	sparkle.Lifetime = NumberRange.new(1.2, 1.8)
	sparkle.Rate = 6
	sparkle.Speed = NumberRange.new(1.5, 2.5)
	sparkle.SpreadAngle = Vector2.new(20, 20)
	sparkle.EmissionDirection = Enum.NormalId.Right
	sparkle.Parent = attachment

	model:SetAttribute("ZoneRadius", ZONE_RADIUS)
	model.Parent = map

	-- The pulse: the disc and ring breathe between two transparencies. One tween
	-- each, looped forever by the engine, costs nothing per frame.
	TweenService:Create(disc, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.3 }):Play()
	TweenService:Create(ring, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.4 }):Play()
end

-- ==========================================================
-- THE ZONE
-- ==========================================================
--
-- Who is standing in the circle, polled. Entering fires "open" ONCE; leaving
-- fires "close" ONCE. Standing still inside fires nothing, so the panel cannot
-- be reopened or reset every tick.

local inZone: { [Player]: boolean } = {}

local function stepZone()
	local centre = (BOOTH_CFRAME * ZONE_OFFSET).Position
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local inside = false
		if root and root:IsA("BasePart") then
			local offset = root.Position - centre
			inside = Vector3.new(offset.X, 0, offset.Z).Magnitude <= ZONE_RADIUS and math.abs(offset.Y) < 12
		end
		local was = inZone[player] == true
		if inside and not was then
			inZone[player] = true
			-- The server opens it. The client cannot decide it is at the shop.
			Remotes.get("TrailRequest"):FireClient(player, "open")
			StateService.pushNow(player)
		elseif not inside and was then
			inZone[player] = nil
			Remotes.get("TrailRequest"):FireClient(player, "close")
		end
	end
end

local function startZoneWatch()
	task.spawn(function()
		while true do
			task.wait(ZONE_POLL)
			stepZone()
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		inZone[player] = nil
	end)
end

function TrailService.start()
	buildKeeper()

	startZoneWatch()

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
