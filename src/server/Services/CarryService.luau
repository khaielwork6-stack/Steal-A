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
local SecurityConfig = require(ReplicatedStorage.Shared.Config.SecurityConfig)

local LootService = require(script.Parent.LootService)
local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)
-- A leaf (config only): the server-side movement record. See MovementService.
local MovementService = require(script.Parent.MovementService)

local CarryService = {}

local carrying: { [Player]: LootService.LootInstance } = {}
--- Where and when (os.clock) THIS carrier took hold of what they carry: the
--- steal, the grab of a drop, or the hand-over of a base steal. One of the two
--- delivery timings in deliveryCheck (security pass B1).
type Pickup = { position: Vector3, at: number }
local pickups: { [Player]: Pickup } = {}
local stealLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.StealRequest)
local dropLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.DropLootRequest)

local notify: (Player, string, string) -> () = function() end
local onDelivered: (Player, LootService.LootInstance) -> () = function() end

--- Whether the zone's guardian can walk to a dropped item and bring it home.
--- Injected from init rather than required, so GuardianService can depend on
--- CarryService without the two forming a require cycle. False means the old
--- instant return is the only way home for that drop.
local canRecover: (LootService.LootInstance) -> boolean = function()
	return false
end

function CarryService.setRecoveryCheck(fn: (LootService.LootInstance) -> boolean)
	canRecover = fn
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

--- A STEAL THAT ACTUALLY HAPPENED. Fired at the end of `trySteal`, once the
--- item is reserved, welded to the thief and the carry is live - never on a
--- request, a prompt or a touch. Injected rather than required so this file
--- gains no dependency on whatever happens to be listening; the beginner
--- checklist is the current listener.
local onStolen: (Player, LootService.LootInstance) -> () = function() end

function CarryService.setStolenHandler(fn: (Player, LootService.LootInstance) -> ())
	onStolen = fn
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

--- 1, or SecurityConfig.CROUCH_SPEED_MULTIPLIER while LaserService has
--- accepted a crouch (security pass B13). Overridden by init so this service
--- need not require LaserService, which already requires half the world.
function CarryService.crouchMultiplierFor(_player: Player): number
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
	local unencumbered = GameConfig.walkSpeedFromPower(effective)
	local speed = unencumbered

	local loot = carrying[player]
	if loot then
		local size = RarityConfig.SizeById[loot.size]
		if size and size.movePenalty then
			speed *= (1 - size.movePenalty)
		end
	end

	-- CROUCHING COSTS SPEED (security pass B13). A crouch is what gets a
	-- player under a high beam; for free, a client could simply stay crouched
	-- for the whole run. Applied here, on the server's own WalkSpeed, so the
	-- movement check below records the slower value too.
	local crouch = CarryService.crouchMultiplierFor(player)
	if crouch > 0 and crouch < 1 then
		speed *= crouch
	end

	humanoid.WalkSpeed = speed
	-- The ONE record of what the server allowed. MovementService never reads
	-- Humanoid.WalkSpeed, which the client can change locally.
	MovementService.noteSpeed(player, speed, unencumbered)
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
--- HumanoidRootPart to the soles, for an R15 at default scale.
local CARRY_FEET_DROP = 2.7
--- How far above the soles the lowest point of a front-carried item sits.
local CARRY_GROUND_CLEARANCE = 0.4
--- Taller than this, or wider than CARRY_OVERHEAD_FOOTPRINT, and the item is
--- carried over the head however small its size roll was. These are avatar
--- proportions: a Roblox character is about 5 studs tall and 2 wide.
local CARRY_OVERHEAD_HEIGHT = 7
local CARRY_OVERHEAD_FOOTPRINT = 9
--- Prints where every carry ended up. Off in the shipped game; flip it on when
--- an item looks wrong in the hand.
local DEBUG_CARRY = false

--- Where carried loot lives while it is being carried: in the world, never in
--- the character. See the note in attach().
local function carryHolder(): Instance
	local map = workspace:FindFirstChild("Map") or workspace
	local holder = map:FindFirstChild("CarriedLoot")
	if not holder then
		holder = Instance.new("Folder")
		holder.Name = "CarriedLoot"
		holder.Parent = map
	end
	return holder
end

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
			-- And nothing carried may fire a Touched: a briefcase swinging at
			-- knee height through a treadmill trigger, a trap or a safe-zone
			-- volume is an event those systems believe.
			descendant.CanTouch = false
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

	-- NOT INSIDE THE CHARACTER. This is the whole "loot drags you into the
	-- ground" bug, and it is worth spelling out because the fix looks like a
	-- detail:
	--
	--   A Humanoid reads the BaseParts of the model it lives in as its own
	--   body. Park a briefcase in there - non-colliding, massless, welded,
	--   everything correct - and the humanoid decides the rig it is balancing
	--   has fallen over: state goes to FallingDown, the root drops to ankle
	--   height, FloorMaterial reads Air and the player cannot walk. Measured:
	--   root Y 2.70 -> 0.53 the moment the model is parented in, and back to
	--   2.70 the moment it is parented out, with the same weld holding.
	--
	-- So the item lives in the world and is WELDED to the root instead. It
	-- follows the player exactly the way it did, and the humanoid never sees
	-- it. CarryHolder keeps the workspace tidy and gives drop/place one place
	-- to look.
	model.Parent = carryHolder()
	-- WHERE THE ITEM RIDES.
	--
	-- Entirely in the ROOT'S OWN SPACE, from the model's measured box. Placing
	-- it by world height was wrong in a way that only showed up in play: a
	-- player who steals mid-jump - or in the same frame they were moved to the
	-- socket - is a stud or two above where they will be standing a moment
	-- later, and the item, welded rigidly, keeps that error forever and ends up
	-- dragged through the floor. Relative placement cannot drift.
	--
	--   up      the box centre, so the BOTTOM sits just above the soles
	--   forward far enough that the box never reaches the player's own body
	--
	-- And anything genuinely bigger than a person goes OVERHEAD instead of in
	-- front, whatever its size roll says: a 22-stud Shawarma held at arm's
	-- length is a wall the player is standing inside. Overhead, it reads as
	-- what it is - something enormous being carried home.
	local boxCFrame, boxSize = model:GetBoundingBox()
	local footprint = math.max(boxSize.X, boxSize.Z)
	local overhead = loot.visualScale > RarityConfig.CARRY_SCALE_KNEE
		or boxSize.Y > CARRY_OVERHEAD_HEIGHT
		or footprint > CARRY_OVERHEAD_FOOTPRINT

	local up: number, forward: number
	if overhead then
		up = CARRY_FEET_DROP + CARRY_OVERHEAD_CLEARANCE + boxSize.Y / 2
		forward = 1
	else
		up = boxSize.Y / 2 - CARRY_FEET_DROP + CARRY_GROUND_CLEARANCE
		forward = math.max(3.5, boxSize.Z / 2 + 2.4)
	end

	-- Orient with the player first, then translate so the model's CENTRE lands
	-- on the target - not its pivot, which on an import is wherever the artist
	-- left it (the Banker's Briefcase's is the top of the case).
	local target = root.CFrame * CFrame.new(0, up, -forward)
	model:PivotTo(root.CFrame * CFrame.new(0, 0, -forward))
	boxCFrame = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + (target.Position - boxCFrame.Position))

	-- FINAL CORRECTION, in world axes. GetBoundingBox measures in the model's
	-- own pivot frame, and an import whose pivot is rotated (several are: the
	-- pedestal comment in BaseService is about the same trap) reports its
	-- height on the wrong axis. One world-space measurement afterwards costs
	-- nothing and is the only number that is always true.
	local worldMin, worldMax = LootModel.visibleExtents(model)
	if worldMin and worldMax then
		local floor = root.Position.Y - CARRY_FEET_DROP + CARRY_GROUND_CLEARANCE
		local wanted = if overhead then root.Position.Y + CARRY_OVERHEAD_CLEARANCE else floor
		local shift = wanted - worldMin.Y
		if math.abs(shift) > 0.05 then
			model:PivotTo(model:GetPivot() + Vector3.new(0, shift, 0))
		end
		if DEBUG_CARRY then
			local m2 = select(1, LootModel.visibleExtents(model))
			print(string.format("[CarryService] %s overhead=%s up=%.2f fwd=%.2f box=%.1fx%.1fx%.1f rootY=%.2f bottom %.2f -> %.2f (want %.2f)",
				model.Name, tostring(overhead), up, forward, boxSize.X, boxSize.Y, boxSize.Z, root.Position.Y, worldMin.Y, m2 and m2.Y or -99, wanted))
		end
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = root
	weld.Part1 = model.PrimaryPart
	weld.Parent = model.PrimaryPart

	-- A model that has just been unanchored keeps whatever velocity the engine
	-- last gave it. Welded to a character, that is a shove.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end

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
			descendant.CanTouch = true
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
	pickups[player] = nil
	CarryService.applyMovement(player)
	onCarryChanged(player)
end

--- Remembers where this carrier took hold of their item (see `pickups`).
--- Measured from the server's verified position, never a raw client claim.
local function notePickup(player: Player, loot: LootService.LootInstance, root: BasePart)
	local position = MovementService.verifiedPosition(player) or root.Position
	local now = os.clock()
	pickups[player] = { position = position, at = now }
	-- The run's origin is set once, by whoever first takes it out of its
	-- socket (or is handed a base steal), and survives drops and re-grabs.
	if not loot.stolenAt then
		loot.stolenFrom = position
		loot.stolenAt = now
		loot.stolenBy = player
	end
end

-- ==========================================================
-- STEAL
-- ==========================================================

--- Server-side validation for taking hold of world loot: a steal from a
--- socket (`expected` = "Spawned") or a grab of a drop (`expected` =
--- "Dropped"). ONE validator for both (security pass B4): the grab used to
--- skip the alive, distance, rate-limit and tutorial-reservation checks a
--- steal makes. Returns nil on success, or a player-facing reason string.
local function validatePickup(player: Player, loot: LootService.LootInstance, expected: LootService.LootState): string?
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

	if loot.state ~= expected then
		return if expected == "Dropped" then "Someone grabbed it first!" else "Someone beat you to it!"
	end

	-- A stale reference (retired by the Night, rerolled, placed) is not world
	-- loot any more, whatever its state field still says.
	if not LootService.isLive(loot) then
		return "That item is gone."
	end

	if not CarryService.mayTakeLoot(player, loot) then
		return "That one's saved for a new player - try another crate!"
	end

	-- [vaults-crews] The vault's own rules (Speed gate, laser ring).
	local veto = CarryService.pickupVeto(player, loot)
	if veto then
		return veto
	end

	local model = loot.model
	local reach = LootService.interactionPart(loot)
	if not model or not model.PrimaryPart or not reach then
		return "That item is gone."
	end

	-- Never trust the prompt's own distance check alone. Measured to the same
	-- part the prompt sits on, with the same range the prompt was given, so a
	-- giant's ground anchor and its wide footprint count the same way here.
	-- From the VERIFIED position: a client that teleported next to the item
	-- is measured from where it last legitimately was (MovementService).
	local from = MovementService.verifiedPosition(player) or (root :: BasePart).Position
	local distance = (from - reach.Position).Magnitude
	if distance > loot.interactRange * 1.6 then
		return "Too far away."
	end

	if BaseService.isFull(player) then
		return "BASE FULL - sell something or upgrade your base."
	end

	-- Several thieves may carry a zone's loot at once. The guardian chases the
	-- nearest and switches when another is clearly closer (GuardianService);
	-- nothing here needs to know whether it is awake.
	return nil
end

function CarryService.trySteal(player: Player, loot: LootService.LootInstance): boolean
	local reason = validatePickup(player, loot, "Spawned")
	if reason then
		notify(player, "error", reason)
		return false
	end

	-- Reserve first: this is the line that stops a double claim.
	LootService.setState(loot, "Reserved")

	if not attach(player, loot) then
		-- EMPTY THE SOCKET FIRST (security pass B7). returnToOrigin only
		-- rebuilds into an EMPTY socket; with the socket still pointing at this
		-- instance it retired it instead and the socket stayed "occupied" by a
		-- dead item until the next Night.
		LootService.detach(loot)
		LootService.returnToOrigin(loot)
		notify(player, "error", "Could not pick that up.")
		return false
	end

	loot.carrier = player
	carrying[player] = loot
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		notePickup(player, loot, root)
	end
	LootService.setState(loot, "Carried")
	-- The socket is now EMPTY and stays empty until the global refresh (or, in
	-- Zone 1 only, its own 60-90s respawn - see LootService.detach). If the
	-- guardian takes this item back first, returnToOrigin puts THIS instance
	-- back into it; nothing rolls a replacement.
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
	-- Last, and in a pcall: a listener that throws must not undo a steal that
	-- has already happened.
	local ok, err = pcall(onStolen, player, loot)
	if not ok then
		warn(`[CarryService] steal listener failed for {player.Name}: {err}`)
	end
	return true
end

-- ==========================================================
-- LOSS PATHS
-- ==========================================================

--- Guardian catch: the carrier loses the item and it GOES STRAIGHT HOME.
---
--- It used to be handed to the guardian (state Escorted) to physically carry
--- back to its socket. That walk is retired - see GuardianService, "THE ESCORT
--- IS RETIRED" - and the item is returned here on the same frame it is taken.
--- `LootService.returnToOrigin` puts the SAME instance back in the SAME socket
--- with its own rolled values, so nothing about the reward changes; only the
--- journey is gone.
function CarryService.reclaim(loot: LootService.LootInstance)
	local player = loot.carrier
	if loot.heist then
		-- A base steal has no socket to go back to: HeistService decides.
		if player then
			detach(loot)
			clearCarry(player)
		end
		loot.carrier = nil
		if loot.onLost then
			loot.onLost("caught")
		end
		return
	end
	if player then
		detach(loot)
		clearCarry(player)
		notify(player, "error", `The guardian took back the {loot.name}!`)
	end
	loot.carrier = nil
	loot.droppedAt = nil

	-- Home, now. A short delay so the catch reads as the guardian taking it
	-- rather than the item blinking out of existence mid-ragdoll.
	LootService.returnToOrigin(loot, GameConfig.GUARDIAN_RETURN_DELAY)
end

--- Whether a dropped item goes STRAIGHT HOME instead of lying where it fell.
--- Overridden by init with TutorialService's answer: true only for the pinned
--- tutorial item while its carrier is still in the tutorial. Everywhere else a
--- drop stays a drop, reclaimable for the usual window.
function CarryService.returnsHomeOnDrop(_player: Player, _loot: LootService.LootInstance): boolean
	return false
end

--- Whether `player` may steal this particular item. Overridden by init with
--- TutorialService.mayTakeLoot: the pinned tutorial item is reserved for
--- players still in the tutorial, and everything else is fair game. Injected
--- rather than required, so CarryService keeps no dependency on the tutorial.
function CarryService.mayTakeLoot(_player: Player, _loot: LootService.LootInstance): boolean
	return true
end

--- A player-facing reason this pickup is refused, or nil. Overridden by init
--- with VaultService.pickupVeto (vaults-crews): vault loot needs the zone's
--- Speed and, on the pedestal, a thief standing inside the laser ring.
function CarryService.pickupVeto(_player: Player, _loot: LootService.LootInstance): string?
	return nil
end

--- Lays an item on the ground at `position` (feet at `floorY`) and marks it
--- Dropped. From here the zone's guardian comes to fetch it and any player may
--- grab it first. Two timers stand under that: a drop the guardian cannot
--- reach goes home after the reclaim window, and ANY drop still lying there
--- at the orphan timeout goes home regardless - nothing is ever left behind.
local function dropLoose(loot: LootService.LootInstance, position: Vector3?, floorY: number?)
	local model = loot.model
	if model and position then
		model.Parent = workspace
		model:PivotTo(CFrame.new(position + Vector3.new(0, 2, 0)))
		-- Feet on the floor, whatever its pivot: a dropped Colossal must not be
		-- left half underground or hanging in the air.
		local minCorner = select(1, LootModel.visibleExtents(model))
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
	-- THIS drop's generation (security pass B5). Grabbed and dropped again,
	-- the item is on its second drop, and the first drop's timers must not
	-- send it home 8 seconds into the second one.
	local generation = (loot.dropGeneration or 0) + 1
	loot.dropGeneration = generation
	LootService.setState(loot, "Dropped")

	if not model or not position then
		-- Nothing on the ground to fetch; straight home.
		LootService.returnToOrigin(loot)
		return
	end

	-- Every timer re-checks three things when it fires: the item is still
	-- lying on the ground, from THIS drop, and still live world loot (the
	-- Night retires loose drops; see LootService.retireLoose).
	local function stillThisDrop(): boolean
		return loot.state == "Dropped" and loot.dropGeneration == generation and LootService.isLive(loot)
	end
	task.delay(GameConfig.DROPPED_RECLAIM_WINDOW, function()
		if stillThisDrop() and not canRecover(loot) then
			LootService.returnToOrigin(loot)
		end
	end)
	task.delay(GameConfig.DROPPED_ORPHAN_TIMEOUT, function()
		if stillThisDrop() then
			LootService.returnToOrigin(loot)
		end
	end)
end

--- PvP hit or the DROP button: the item drops where the carrier stood. The
--- guardian comes for it; the thief may grab it back first.
function CarryService.forceDrop(loot: LootService.LootInstance)
	local player = loot.carrier
	if not player then
		return
	end

	-- A STOLEN BASE ITEM NEVER LIES ON THE GROUND EITHER. Dropped, knocked
	-- loose or trapped out of the thief's hands, it goes straight back to the
	-- player it was taken from (HeistService.fail); nobody else can pick it
	-- up off the floor, so a robbery can never turn into a free-for-all.
	if loot.heist then
		detach(loot)
		clearCarry(player)
		loot.carrier = nil
		if loot.onLost then
			loot.onLost("dropped")
		end
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

	dropLoose(loot, position, floorY)
	notify(player, "error", `You dropped the {loot.name}!`)
end

--- Picking a dropped item back up. The SAME validation as a fresh steal
--- (validatePickup) except that the state must be Dropped rather than Spawned.
function CarryService.tryGrabDropped(player: Player, loot: LootService.LootInstance): boolean
	local reason = validatePickup(player, loot, "Dropped")
	if reason then
		notify(player, "error", reason)
		return false
	end

	LootService.setState(loot, "Reserved")
	if not attach(player, loot) then
		-- A dropped item is already out of its socket, so returnToOrigin can
		-- put it straight back.
		LootService.returnToOrigin(loot)
		return false
	end

	loot.carrier = player
	loot.droppedAt = nil
	carrying[player] = loot
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		notePickup(player, loot, root)
	end
	LootService.setState(loot, "Carried")
	CarryService.applyMovement(player)
	onCarryChanged(player)
	notify(player, "info", `Grabbed the {loot.name}!`)
	return true
end

--- Puts an already-built item into a player's hands: the base steal path
--- (HeistService), where the "item" is another player's trophy rather than a
--- socket's loot. Same weld, same movement penalty, same DROP button; the
--- only thing it skips is the socket bookkeeping, which does not apply.
--- Returns false, with nothing changed, if the player cannot carry right now.
function CarryService.beginCarry(player: Player, loot: LootService.LootInstance): boolean
	if carrying[player] then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	if not attach(player, loot) then
		return false
	end
	loot.carrier = player
	loot.state = "Carried"
	carrying[player] = loot
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		-- The delivery timer starts at the victim's pad (HeistService.fulfil
		-- has already checked the buyer is standing there).
		notePickup(player, loot, root)
	end
	CarryService.applyMovement(player)
	onCarryChanged(player)
	return true
end

--- Hands the carried item off to the base. Unlike releaseCarry this does NOT
--- send the item home: PlacementService has already turned it into a trophy.
function CarryService.consumeCarry(player: Player)
	local loot = carrying[player]
	if not loot then
		return
	end
	require(script.Parent.ProgressEvents).fire(player, "delivered", 1, { itemId = loot.itemId, zoneIndex = loot.zoneIndex, income = loot.finalIncome, heist = loot.heist == true })
	detach(loot)
	clearCarry(player)
	loot.carrier = nil
end

--- THE NIGHT CANCELS EVERY STEAL. Whatever the carrier was doing - mid-lane,
--- mid-chase, standing in the safe zone about to place - the item comes
--- out of their hands and goes STRAIGHT back to its socket (a base steal
--- goes back to its owner through onLost). Nothing is left on the floor
--- for the refresh to find, and nothing rides home with the player.
--- Returns true when something was taken away.
function CarryService.cancelForNight(player: Player): boolean
	local loot = carrying[player]
	if not loot then
		return false
	end
	detach(loot)
	clearCarry(player)
	loot.carrier = nil
	loot.droppedAt = nil
	if loot.heist then
		if loot.onLost then
			loot.onLost("night")
		end
	else
		LootService.returnToOrigin(loot)
	end
	notify(player, "error", "NIGHT FELL - the item went back!")
	return true
end

--- Death, reset, disconnect or any invalidation must always release the item.
--- It falls where the carrier was, as a drop: the guardian then brings it
--- back to its socket exactly as it does for a deliberate drop. If there is
--- nothing left to fall (the character is already gone), or it is the pinned
--- tutorial item, it goes straight home.
function CarryService.releaseCarry(player: Player)
	local loot = carrying[player]
	if not loot then
		return
	end

	if loot.heist then
		detach(loot)
		clearCarry(player)
		loot.carrier = nil
		if loot.onLost then
			loot.onLost("released")
		end
		return
	end

	local model = loot.model
	local position = if model and model.Parent and model.PrimaryPart then model.PrimaryPart.Position else nil
	local floorY: number? = nil
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		position = root.Position
		floorY = root.Position.Y - 3
	end

	detach(loot)
	clearCarry(player)
	loot.carrier = nil

	if CarryService.returnsHomeOnDrop(player, loot) or not position then
		LootService.returnToOrigin(loot)
		return
	end
	dropLoose(loot, position, floorY)
end

-- ==========================================================
-- DELIVERY
-- ==========================================================

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

--- Whether a carry that has only just begun could legally be home already.
--- `origin` is where and when a run began; the straight line from there to
--- `home` at the fastest unencumbered speed this player had since is the
--- least time any real run can take. Waived only for Studio debug teleports
--- (MovementService.serverMovedSince, always false live).
local function tooSoon(player: Player, origin: Pickup, home: Vector3, now: number): boolean
	if MovementService.serverMovedSince(player, origin.at) then
		return false
	end
	local speed = MovementService.peakSpeedSince(player, origin.at, true) * SecurityConfig.DELIVERY_SPEED_TOLERANCE
	local needed = flatDistance(origin.position, home) / math.max(speed, 1) - SecurityConfig.DELIVERY_SLACK_SECONDS
	return now - origin.at < needed
end

export type DeliveryVerdict = "home" | "away" | "early"

--- IS THIS CARRIER REALLY HOME? (security pass B1)
---   "away"  not in their own safe zone - by the live position OR by the last
---           position the movement check trusted. Both must agree.
---   "early" home, but sooner than any legal run from where the item was
---           taken: a teleport the movement check missed.
---   "home"  delivered.
--- Two runs are timed: THIS carrier's own pickup, and - when they are also
--- the player who first took it out of its socket - the whole run since, so
--- dropping an item at home and re-grabbing it does not reset the clock.
local function deliveryCheck(player: Player, loot: LootService.LootInstance): DeliveryVerdict
	if not BaseService.isInOwnSafeZone(player) then
		return "away"
	end
	local trusted = MovementService.trustedPosition(player)
	local plot = BaseService.getPlot(player)
	if not trusted or not plot or BaseService.plotAt(trusted) ~= (plot :: Instance) then
		return "away"
	end
	if MovementService.isExempt(player) then
		return "home"
	end
	local now = os.clock()
	local pickup = pickups[player]
	if pickup and tooSoon(player, pickup, trusted, now) then
		return "early"
	end
	local from, at = loot.stolenFrom, loot.stolenAt
	if loot.stolenBy == player and from and at and tooSoon(player, { position = from, at = at }, trusted, now) then
		return "early"
	end
	return "home"
end

--- A delivery nobody could have run: the item is taken away, never left on
--- the floor at the base (where the same player could simply grab it again).
--- World loot goes straight back to its socket; a base steal goes back to its
--- owner through its own loss path. Then the character is snapped back.
local function confiscate(player: Player, loot: LootService.LootInstance)
	if loot.heist then
		CarryService.forceDrop(loot)
	else
		detach(loot)
		clearCarry(player)
		loot.carrier = nil
		loot.droppedAt = nil
		LootService.returnToOrigin(loot)
	end
	notify(player, "error", `The {loot.name} went back - that was too fast!`)
	MovementService.flag(player, `delivered {loot.name} faster than any legal run`)
end

--- For PlacementService.place: may this player hand their carry to the base
--- right now? Returns false plus a player-facing reason. An impossible
--- delivery is confiscated here, exactly as the watcher below does.
function CarryService.deliveryReady(player: Player): (boolean, string?)
	local loot = carrying[player]
	if not loot then
		return false, "You are not carrying anything."
	end
	local verdict = deliveryCheck(player, loot)
	if verdict == "early" then
		confiscate(player, loot)
		return false, nil
	elseif verdict == "away" then
		return false, "Get back to your base first!"
	end
	return true
end

--- Watches carriers for entry into their own safe zone. Once home, the guardian
--- is cleared permanently for that item (simplest MVP rule from the GDD).
local function watchDelivery()
	while true do
		task.wait(0.2)
		for player, loot in carrying do
			-- One player's failure must not stop delivery for everyone else
			-- (security pass B11).
			local ok, err = pcall(function()
				if loot.state ~= "Carried" then
					return true
				end
				local verdict = deliveryCheck(player, loot)
				if verdict == "home" then
					onDelivered(player, loot)
				elseif verdict == "early" then
					confiscate(player, loot)
				end
				return true
			end)
			if not ok then
				warn(`[CarryService] delivery check failed for {player.Name}: {err}`)
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
