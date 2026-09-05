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
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)

local LootService = require(script.Parent.LootService)
local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)

local CarryService = {}

local carrying: { [Player]: LootService.LootInstance } = {}
local stealLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.StealRequest)

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

--- Called when a carrier crosses into their own safe zone. TutorialService and
--- the placement flow hook this.
function CarryService.setDeliveredHandler(fn: (Player, LootService.LootInstance) -> ())
	onDelivered = fn
end

function CarryService.getCarried(player: Player): LootService.LootInstance?
	return carrying[player]
end

-- ==========================================================
-- MOVEMENT
-- ==========================================================

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

	local speed = GameConfig.walkSpeedFromPower(profile.SpeedPower)

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

local function attach(player: Player, loot: LootService.LootInstance): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local model = loot.model
	if not root or not root:IsA("BasePart") or not model or not model.PrimaryPart then
		return false
	end

	local prompt = model.PrimaryPart:FindFirstChildWhichIsA("ProximityPrompt")
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
		end
	end

	model.Parent = character
	model:PivotTo(root.CFrame * CFrame.new(0, 0.5, -3.5))

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
		end
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

	if loot.state ~= "Spawned" then
		return "Someone beat you to it!"
	end

	local model = loot.model
	if not model or not model.PrimaryPart then
		return "That item is gone."
	end

	-- Never trust the prompt's own distance check alone.
	local distance = (root.Position - model.PrimaryPart.Position).Magnitude
	if distance > GameConfig.STEAL_INTERACTION_RANGE * 1.6 then
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

--- PvP hit: the item drops where the carrier stood and is reclaimable for 8s.
function CarryService.forceDrop(loot: LootService.LootInstance)
	local player = loot.carrier
	if not player then
		return
	end

	local model = loot.model
	local position = if model and model.PrimaryPart then model.PrimaryPart.Position else nil

	detach(loot)
	clearCarry(player)
	loot.carrier = nil

	if model and position then
		model.Parent = workspace
		model:PivotTo(CFrame.new(position + Vector3.new(0, 2, 0)))
		local prompt = model.PrimaryPart and model.PrimaryPart:FindFirstChildWhichIsA("ProximityPrompt")
		if prompt then
			prompt.Enabled = true
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
			local model = loot.model
			local prompt = model and model.PrimaryPart and model.PrimaryPart:FindFirstChildWhichIsA("ProximityPrompt")
			if prompt then
				prompt.Enabled = true
				prompt.ActionText = "Steal"
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		CarryService.releaseCarry(player)
		stealLimiter:release(player)
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
