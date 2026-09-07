--!strict
--[[
	CarryService
	Steal reservation, weld, movement penalty and delivery (GDD section 11).

	Every transition checks the current state AND the expected owner, so two
	prompt callbacks racing or a spammed remote cannot duplicate a reward.

	Carried loot has collisions and mass disabled: Size changes visual scale and
	a movement multiplier only, so physics can never fling or duplicate a carry.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local LootService = require(script.Parent.LootService)
local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)

local CarryService = {}

local carrying: { [Player]: LootService.LootInstance } = {}
local stealLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.StealRequest)
local dropLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.DropLootRequest)

local notify: (Player, string, string) -> () = function() end
local onDelivered: (Player, LootService.LootInstance) -> () = function() end

--- Injected from init rather than required, so GuardianService can depend on
--- CarryService without the two forming a require cycle.
local isZoneBusy: (number) -> boolean = function()
	return false
end

function CarryService.setZoneBusyCheck(fn: (number) -> boolean)
	isZoneBusy = fn
end

function CarryService.setNotifier(fn: (Player, string, string) -> ())
	notify = fn
end

--- Called whenever `carrying[player]` gains or loses an entry, so the DROP
--- button appears on the same frame the steal lands rather than on whatever
--- unrelated change happens to dirty the state next. Injected rather than
--- required for the same reason as `notify`: StateService must not become a
--- dependency of this file.
local onCarryChanged: (Player) -> () = function() end

function CarryService.setCarryChangedHandler(fn: (Player) -> ())
	onCarryChanged = fn
end

--- Called when a carrier crosses into their own safe zone. TutorialService and
--- the placement flow hook this.
function CarryService.setDeliveredHandler(fn: (Player, LootService.LootInstance) -> ())
	onDelivered = fn
end

function CarryService.getCarried(player: Player): LootService.LootInstance?
	return carrying[player]
end

--- What StatePush tells the client about the carry. Deliberately a summary, not
--- the instance: the client needs to know THAT it is carrying something and what
--- to call it, and nothing else it could be tempted to act on.
export type CarrySummary = { name: string, rarity: string }

function CarryService.summariseCarry(player: Player): CarrySummary?
	local loot = carrying[player]
	if not loot then
		return nil
	end
	return { name = loot.name, rarity = loot.rarity }
end

--- The player's own DROP button.
---
--- Routes into the SAME `forceDrop` the PvP bat uses rather than adding a second
--- drop path: one set of rules for where the item lands, how long it can be
--- reclaimed, and how it gets home if nobody takes it.
function CarryService.dropCarried(player: Player): (boolean, string?)
	if not dropLimiter:consume(player) then
		return false, "Slow down!"
	end
	local loot = carrying[player]
	if not loot then
		return false, "You are not carrying anything."
	end
	CarryService.forceDrop(loot)
	return true
end

-- ==========================================================
-- MOVEMENT
-- ==========================================================

--- The equipped trail's movement multiplier. Overridden by init so this service
--- need not require TrailService; 1 means no trail, which is also the safe
--- answer before a profile has loaded.
function CarryService.trailMultiplierFor(_player: Player): number
	return 1
end

--- Applies the carry penalty on top of the compressed Speed formula. Bigger
--- loot demands a real Speed buffer rather than being free to haul.
function CarryService.applyMovement(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	local profile = DataService.get(player)
	if not humanoid or not profile then
		return
	end

	-- A rooted player stays rooted. Dropping loot and the 0.25s training tick
	-- both call this, and either would otherwise silently cancel a trap's root
	-- the instant it landed - exactly when the trap matters most.
	if humanoid:GetAttribute("Rooted") then
		return
	end

	-- THE EQUIPPED TRAIL MULTIPLIES MOVEMENT, and it does so by scaling the
	-- effective Speed fed into the conversion rather than the finished WalkSpeed.
	--
	-- That matters. WalkSpeed is logarithmic in Speed and hard-clamped, so a x14
	-- trail applied to the OUTPUT would slam straight into WALKSPEED_MAX and every
	-- tier above about x2 would feel identical. Applied to the INPUT it stays on
	-- the same smooth curve the whole progression uses, and it can never break the
	-- clamp.
	--
	-- It scales the effective value only - `profile.SpeedPower` is untouched, so
	-- equipping and unequipping a trail can never inflate the saved stat. And it
	-- is the ONLY place a trail is applied; training gain is a separate formula.
	local effective = profile.SpeedPower * CarryService.trailMultiplierFor(player)
	local speed = GameConfig.walkSpeedFromPower(effective)

	local loot = carrying[player]
	if loot then
		local size = RarityConfig.SizeById[loot.size]
		if size and size.movePenalty then
			speed *= (1 - size.movePenalty)
		end
	end

	humanoid.WalkSpeed = speed
end

-- ==========================================================
-- ATTACH / DETACH
-- ==========================================================

--- Where a carried item rides. Up to a Giant it is held in front, as it always
--- was. Anything bigger is hoisted OVERHEAD: the model's lowest point sits just
--- above the head, so a Titan or Colossal - shown at RarityConfig.carryVisualScale,
--- a compressed but still enormous size - towers above the player instead of
--- filling the camera, and the player can see where they are running.
local CARRY_FRONT_OFFSET = CFrame.new(0, 0.5, -3.5)
local CARRY_OVERHEAD_CLEARANCE = 2.6

local function attach(player: Player, loot: LootService.LootInstance): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local model = loot.model
	if not root or not root:IsA("BasePart") or not model or not model.PrimaryPart then
		return false
	end

	local prompt = LootService.promptOf(loot)
	if prompt then
		prompt.Enabled = false
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "CarryAttachment"
	attachment.Position = Vector3.new(0, 0.5, -3.5)
	attachment.Parent = root

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.Massless = true
			-- The camera's occlusion popper raycasts against CanQuery parts. A
			-- big item behind the player would otherwise zoom the camera into
			-- their back on every turn.
			descendant.CanQuery = false
		end
	end

	-- PRESENTATION SCALE. The world model is built at the item's true visual
	-- scale; the carry shows the compressed one. Applied RELATIVE, remembered
	-- on the instance, and undone exactly by detach() - so it can never leak
	-- into the saved size, the income, or the next build.
	local shown = RarityConfig.carryVisualScale(loot.visualScale)
	local factor = if loot.visualScale > 0 then shown / loot.visualScale else 1
	if math.abs(factor - 1) > 0.001 then
		model:ScaleTo(model:GetScale() * factor)
		loot.carryScale = factor
	else
		loot.carryScale = nil
	end

	model.Parent = character
	if loot.visualScale > RarityConfig.CARRY_SCALE_KNEE then
		-- Overhead: centre it over the player, lowest point just above the head.
		model:PivotTo(root.CFrame)
		local minCorner = select(1, LootModel.worldExtents(model))
		local lift = if minCorner then (root.Position.Y + CARRY_OVERHEAD_CLEARANCE) - minCorner.Y else CARRY_OVERHEAD_CLEARANCE
		model:PivotTo(root.CFrame * CFrame.new(0, lift, -1))
	else
		model:PivotTo(root.CFrame * CARRY_FRONT_OFFSET)
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = root
	weld.Part1 = model.PrimaryPart
	weld.Parent = model.PrimaryPart

	return true
end

--- Unwelds and re-anchors. Safe to call on an already-detached carry.
local function detach(loot: LootService.LootInstance)
	local model = loot.model
	if not model then
		return
	end

	local weld = model.PrimaryPart and model.PrimaryPart:FindFirstChild("CarryWeld")
	if weld then
		weld:Destroy()
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.Massless = false
			descendant.CanQuery = true
		end
	end

	-- Back to the world scale, by exactly the factor attach() applied.
	local factor = loot.carryScale
	if factor and factor > 0 then
		model:ScaleTo(model:GetScale() / factor)
		loot.carryScale = nil
	end
end

local function clearCarry(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local attachment = root and root:FindFirstChild("CarryAttachment")
	if attachment then
		attachment:Destroy()
	end
	carrying[player] = nil
	CarryService.applyMovement(player)
	onCarryChanged(player)
end

-- ==========================================================
-- STEAL
-- ==========================================================

--- Server-side validation for a steal attempt. Returns nil on success, or a
--- player-facing reason string.
local function validateSteal(player: Player, loot: LootService.LootInstance): string?
	if not stealLimiter:consume(player) then
		return "Slow down!"
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return "You cannot steal right now."
	end

	if carrying[player] then
		return "You are already carrying something!"
	end

	if LootService.isClosed() then
		return LootService.closedReason()
	end

	if loot.state ~= "Spawned" then
		return "Someone beat you to it!"
	end

	local model = loot.model
	local reach = LootService.interactionPart(loot)
	if not model or not model.PrimaryPart or not reach then
		return "That item is gone."
	end

	-- Never trust the prompt's own distance check alone. Measured to the same
	-- part the prompt sits on, with the same range the prompt was given, so a
	-- giant's ground anchor and its wide footprint count the same way here.
	local distance = (root.Position - reach.Position).Magnitude
	if distance > loot.interactRange * 1.6 then
		return "Too far away."
	end

	if BaseService.isFull(player) then
		return "BASE FULL - sell something or upgrade your base."
	end

	-- One chase per zone: the single zone guardian cannot hold two targets, so
	-- a second theft here waits until it has fully reset.
	if isZoneBusy(loot.zoneIndex) then
		return "The guard is already chasing someone here!"
	end

	return nil
end

function CarryService.trySteal(player: Player, loot: LootService.LootInstance): boolean
	local reason = validateSteal(player, loot)
	if reason then
		notify(player, "error", reason)
		return false
	end

	-- Reserve first: this is the line that stops a double claim.
	LootService.setState(loot, "Reserved")

	if not attach(player, loot) then
		LootService.returnToOrigin(loot)
		notify(player, "error", "Could not pick that up.")
		return false
	end

	loot.carrier = player
	carrying[player] = loot
	LootService.setState(loot, "Carried")
	-- The socket is now EMPTY and stays empty until the global refresh. If the
	-- guardian takes this item back, returnToOrigin puts THIS instance back into
	-- it; nothing rolls a replacement.
	LootService.detach(loot)
	CarryService.applyMovement(player)
	onCarryChanged(player)

	local profile = DataService.get(player)
	if profile then
		profile.Lifetime.Steals += 1
	end

	-- A CONFIRMATION, not an instruction. The standing tutorial objective already
	-- reads "GET BACK TO YOUR BASE!", and this toast used to repeat it verbatim -
	-- two messages saying the same thing at the same moment. One instructional
	-- objective at a time, plus a short event toast, is the rule.
	notify(player, "success", `STOLEN: {loot.name}!`)
	return true
end

-- ==========================================================
-- LOSS PATHS
-- ==========================================================

--- Guardian catch: carrier loses it and the item goes home.
function CarryService.reclaim(loot: LootService.LootInstance)
	local player = loot.carrier
	if player then
		detach(loot)
		clearCarry(player)
		notify(player, "error", `The guardian took back the {loot.name}!`)
	end
	LootService.returnToOrigin(loot, GameConfig.GUARDIAN_RETURN_DELAY)
end

--- Whether a dropped item goes STRAIGHT HOME instead of lying where it fell.
--- Overridden by init with TutorialService's answer: true only for the pinned
--- tutorial vase while its carrier is still in the tutorial. Everywhere else a
--- drop stays a drop, reclaimable for the usual window.
function CarryService.returnsHomeOnDrop(_player: Player, _loot: LootService.LootInstance): boolean
	return false
end

--- PvP hit or the DROP button: the item drops where the carrier stood and is
--- reclaimable for 8s.
function CarryService.forceDrop(loot: LootService.LootInstance)
	local player = loot.carrier
	if not player then
		return
	end

	-- THE TUTORIAL VASE NEVER LIES ON THE GROUND. The tutorial keeps a vase
	-- pinned in its socket for whoever still needs one, and a steal empties that
	-- socket - so a vase left on the floor plus a socket that wants filling was
	-- how a new player could steal, drop, steal, drop and mint a pile of them.
	-- For that one item the drop is a cancel: the SAME instance goes back to the
	-- pedestal it came from, immediately, and nothing is ever cloned.
	if CarryService.returnsHomeOnDrop(player, loot) then
		detach(loot)
		clearCarry(player)
		loot.carrier = nil
		notify(player, "info", `The {loot.name} went back to its pedestal.`)
		LootService.returnToOrigin(loot)
		return
	end

	local model = loot.model
	local position = if model and model.PrimaryPart then model.PrimaryPart.Position else nil
	local floorY: number? = nil
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		-- Where the CARRIER stands, not where the model's pivot happens to be: an
		-- overhead Colossal's pivot is twenty studs up.
		position = root.Position
		floorY = root.Position.Y - 3
	end

	detach(loot)
	clearCarry(player)
	loot.carrier = nil

	if model and position then
		model.Parent = workspace
		model:PivotTo(CFrame.new(position + Vector3.new(0, 2, 0)))
		-- Feet on the floor, whatever its pivot: a dropped Colossal must not be
		-- left half underground or hanging in the air.
		local minCorner = select(1, LootModel.worldExtents(model))
		if minCorner and floorY then
			model:PivotTo(model:GetPivot() + Vector3.new(0, floorY - minCorner.Y, 0))
		end
		local prompt = LootService.promptOf(loot)
		if prompt then
			prompt.Enabled = not LootService.isClosed()
			prompt.ActionText = "Grab"
		end
	end

	loot.droppedAt = os.clock()
	LootService.setState(loot, "Dropped")
	notify(player, "error", `You dropped the {loot.name}!`)

	task.delay(GameConfig.DROPPED_RECLAIM_WINDOW, function()
		if loot.state == "Dropped" then
			LootService.returnToOrigin(loot)
		end
	end)
end

--- Picking a dropped item back up. Same validation as a fresh steal minus the
--- state check, which must be Dropped rather than Spawned.
function CarryService.tryGrabDropped(player: Player, loot: LootService.LootInstance): boolean
	if loot.state ~= "Dropped" then
		return false
	end
	if carrying[player] then
		notify(player, "error", "You are already carrying something!")
		return false
	end
	if LootService.isClosed() then
		notify(player, "error", LootService.closedReason())
		return false
	end
	if BaseService.isFull(player) then
		notify(player, "error", "BASE FULL - sell something or upgrade your base.")
		return false
	end

	LootService.setState(loot, "Reserved")
	if not attach(player, loot) then
		LootService.returnToOrigin(loot)
		return false
	end

	loot.carrier = player
	loot.droppedAt = nil
	carrying[player] = loot
	LootService.setState(loot, "Carried")
	CarryService.applyMovement(player)
	onCarryChanged(player)
	notify(player, "info", `Grabbed the {loot.name}!`)
	return true
end

--- Hands the carried item off to the base. Unlike releaseCarry this does NOT
--- send the item home: PlacementService has already turned it into a trophy.
function CarryService.consumeCarry(player: Player)
	local loot = carrying[player]
	if not loot then
		return
	end
	detach(loot)
	clearCarry(player)
	loot.carrier = nil
end

--- Death, reset, disconnect or any invalidation must always release the item.
function CarryService.releaseCarry(player: Player)
	local loot = carrying[player]
	if not loot then
		return
	end
	detach(loot)
	clearCarry(player)
	LootService.returnToOrigin(loot)
end

-- ==========================================================
-- DELIVERY
-- ==========================================================

--- Watches carriers for entry into their own safe zone. Once home, the guardian
--- is cleared permanently for that item (simplest MVP rule from the GDD).
local function watchDelivery()
	while true do
		task.wait(0.2)
		for player, loot in carrying do
			if loot.state == "Carried" and BaseService.isInOwnSafeZone(player) then
				onDelivered(player, loot)
			end
		end
	end
end

function CarryService.start()
	-- ProximityPrompt gives us hold-to-steal on desktop, mobile and gamepad for
	-- free, which the GDD requires from the start. The prompt is only the input
	-- path: every rule is still validated server-side in trySteal.
	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name ~= "StealPrompt" then
			return
		end
		-- Walks up for the LootId attribute rather than for the nearest Model:
		-- imported art nests its parts inside sub-Models, so the nearest Model is
		-- the artist's own group and carries no id. See LootService.fromDescendant.
		local loot = LootService.fromDescendant(prompt)
		if not loot then
			-- Never fail silently here. An unresolvable steal prompt means the
			-- player is holding E on a real object and nothing at all happens,
			-- which is indistinguishable from the game being frozen.
			warn(`[CarryService] StealPrompt at {prompt:GetFullName()} resolved to no loot`)
			return
		end

		if loot.state == "Dropped" then
			CarryService.tryGrabDropped(player, loot)
		else
			CarryService.trySteal(player, loot)
		end
	end)

	LootService.onStateChanged(function(loot, _previous, next)
		if next == "Spawned" then
			local prompt = LootService.promptOf(loot)
			if prompt then
				prompt.Enabled = not LootService.isClosed()
				prompt.ActionText = "Steal"
			end
		end
	end)

	-- The DROP button. No payload: the server already knows what this player is
	-- carrying, and letting the client name a target would be handing it a
	-- decision it has no business making.
	Remotes.get("DropLootRequest").OnServerEvent:Connect(function(player)
		local ok, reason = CarryService.dropCarried(player)
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		CarryService.releaseCarry(player)
		stealLimiter:release(player)
		dropLimiter:release(player)
	end)

	local function hookCharacter(player: Player, character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				CarryService.releaseCarry(player)
			end)
		end
		CarryService.applyMovement(player)
	end

	local function onPlayer(player: Player)
		if player.Character then
			task.spawn(hookCharacter, player, player.Character)
		end
		player.CharacterAdded:Connect(function(character)
			CarryService.releaseCarry(player)
			task.spawn(hookCharacter, player, character)
		end)
	end

	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)

	task.spawn(watchDelivery)
end

return CarryService
