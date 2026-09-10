--!strict
--[[
	BaseGuardianService
	The animal Guardian a player equips to defend their OWN base: Cat, Dog,
	Panda or Tiger, bought as a Game Pass from the rotating shop
	(GuardianShopService), equipped from Storage, standing in the Guardian
	Bay at the back of the plot.

	WHAT IT IS BUILT FROM. The owner's Toolbox imports, parked in
	ReplicatedStorage.GameAssets.BaseGuardians (so the client can draw them
	in cards too). Each is dressed over the SAME invisible rig the zone
	bosses use (GuardianService.buildRigFrom): the Dog is an R6 rig and
	walks with Roblox's own R6 walk cycle; the Cat (a skinned mesh with no
	Humanoid), the Panda and the Tiger (static props) have no joints an
	Animation could drive, so they run the cartoon way - bobbed, leaned and
	rolled as one piece - exactly like the prop bosses do. No animation id
	is invented for them.

	OWNERSHIP IS THE GAME PASS. `owns` asks MonetizationService's cache,
	which asks Roblox. The profile stores only WHICH owned guardian is
	equipped, and `sync` re-validates that against ownership before a single
	part is spawned. Nothing here can sell, delete or convert a guardian.

	DEFENCE. Idle in the bay (anchored, breathing). Any OTHER player inside
	the plot's boundary is an intruder: "!" (State = Alert), turn, run them
	down at a little over their own speed, hit, launch them OUTWARD FROM THE
	BASE CENTRE, walk back to the bay and stand down. It never touches its
	owner, never chases past the plot's edge plus a short margin (except a
	thief it has been told to HUNT after a paid steal, for a few seconds),
	never chases longer than CHASE_TIMEOUT, and always returns to the exact
	bay CFrame it left. Multiple intruders: the nearest, re-picked as they
	move, with hysteresis so it never dithers between two.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HeistConfig = require(ReplicatedStorage.Shared.Config.HeistConfig)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local MapPalette = require(ReplicatedStorage.Shared.MapPalette)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)
local GuardianService = require(script.Parent.GuardianService)
local MonetizationService = require(script.Parent.MonetizationService)
local RagdollService = require(script.Parent.RagdollService)
local StateService = require(script.Parent.StateService)

local BaseGuardianService = {}

type State = "Idle" | "Alert" | "Chasing" | "Returning"

type Guardian = {
	key: string,
	def: BaseGuardianConfig.GuardianDef,
	owner: Player?,
	ownerUserId: number,
	plot: Instance,
	slab: BasePart,
	halfW: number,
	halfD: number,
	home: CFrame,
	model: Model,
	root: BasePart,
	humanoid: Humanoid,
	shellMotor: Weld?,
	walkTrack: AnimationTrack?,
	idleTrack: AnimationTrack?,
	walkSpeedPerRate: number,
	state: State,
	target: Player?,
	alertAt: number,
	chaseStartedAt: number,
	nextScanAt: number,
	currentSpeed: number,
	lastPosition: Vector3?,
	stuckFor: number,
	sidestepUntil: number,
	sidestepSign: number,
	--- A thief the owner's robbery told us to go after, and for how long the
	--- usual leash is relaxed for them.
	huntTarget: Player?,
	huntUntil: number,
	attackUntil: number,
}

local guardians: { [Guardian]: boolean } = {}
local byOwner: { [Player]: Guardian } = {}

local requestLimiter = RateLimiter.new(GameConfig.RATE_LIMITS.GuardianRequest)

--- Wired by init to HeistService: a hit on a thief carrying the owner's
--- item sends that item home.
BaseGuardianService.onIntruderCaught = function(_intruder: Player, _ownerUserId: number) end

local BAY_NAME = "GuardianBay"
local HOLDER_NAME = "Guardians"

-- Movement feel, shared with the zone bosses' numbers where they apply.
local SPEED_EASE = 3.0
local STUCK_SPEED_FRACTION = 0.25
local STUCK_TRIGGER = 0.3
local SIDESTEP_DURATION = 0.45
local SIDESTEP_STRENGTH = 1.1
--- A hunted thief is followed this far from the bay, no further.
local HUNT_RANGE = 260

-- Cartoon run for the jointless costumes (gentler than the bosses').
local RUN_CYCLE_SPEED = 14
local RUN_BOB = 0.5
local RUN_ROLL = math.rad(12)
local RUN_YAW = math.rad(8)
local RUN_LEAN = math.rad(-16)
local WALK_LEAN = math.rad(-6)
local ATTACK_SECONDS = 0.35

local function notify(player: Player?, kind: string, message: string, detail: string?)
	if player and player.Parent then
		StateService.notify(player, kind, message, detail)
	end
end

-- ==========================================================
-- ASSETS
-- ==========================================================

--- ReplicatedStorage.GameAssets.BaseGuardians, adopting any animal still
--- loose in the workspace (a re-import) on the way.
local function assetsFolder(): Folder
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	if not assets then
		assets = Instance.new("Folder")
		assets.Name = "GameAssets"
		assets.Parent = ReplicatedStorage
	end
	local folder = assets:FindFirstChild("BaseGuardians")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BaseGuardians"
		folder.Parent = assets
	end
	local auras = folder:FindFirstChild("Auras")
	if not auras then
		auras = Instance.new("Folder")
		auras.Name = "Auras"
		auras.Parent = folder
	end
	for _, def in BaseGuardianConfig.Guardians do
		if not folder:FindFirstChild(def.modelName) then
			local loose = workspace:FindFirstChild(def.modelName)
			if loose and loose:IsA("Model") then
				for _, part in loose:GetDescendants() do
					if part:IsA("BasePart") then
						part.Anchored = true
					end
				end
				loose.Parent = folder
			end
		end
		if not auras:FindFirstChild(def.auraName) then
			local aura = workspace:FindFirstChild(def.auraName)
			if aura then
				aura.Parent = auras
			end
		end
	end
	return folder :: Folder
end

function BaseGuardianService.modelFor(key: string): Model?
	local def = BaseGuardianConfig.ByKey[key]
	local found = if def then assetsFolder():FindFirstChild(def.modelName) else nil
	return if found and found:IsA("Model") then found else nil
end

function BaseGuardianService.auraFor(key: string): Model?
	local def = BaseGuardianConfig.ByKey[key]
	local auras = assetsFolder():FindFirstChild("Auras")
	local found = if def and auras then auras:FindFirstChild(def.auraName) else nil
	return if found and found:IsA("Model") then found else nil
end

--- The animal's aura kit, on an invisible part: the kit's Torso attachments
--- (its body glow) cloned across, emitters throttled to `rateScale` so a
--- bay full of guardians stays cheap on a phone.
function BaseGuardianService.applyAura(part: BasePart, key: string, rateScale: number, sizeScale: number?)
	local aura = BaseGuardianService.auraFor(key)
	if not aura then
		return
	end
	local source = aura:FindFirstChild("Torso") or aura:FindFirstChildWhichIsA("BasePart")
	if not source then
		return
	end
	local shrink = sizeScale or 1
	for _, child in source:GetChildren() do
		if child:IsA("Attachment") then
			local copy = child:Clone()
			copy:SetAttribute("GuardianAura", true)
			for _, emitter in copy:GetDescendants() do
				if emitter:IsA("ParticleEmitter") then
					emitter.Enabled = true
					-- A few particles a second per emitter: the kit was authored
					-- to swallow a character, and the animal has to stay readable.
					emitter.Rate = math.min(emitter.Rate * rateScale, 5)
					if shrink ~= 1 then
						local keys = {}
						for _, key in emitter.Size.Keypoints do
							table.insert(keys, NumberSequenceKeypoint.new(key.Time, key.Value * shrink, key.Envelope * shrink))
						end
						emitter.Size = NumberSequence.new(keys)
					end
				end
			end
			copy.Parent = part
		end
	end
end

-- ==========================================================
-- OWNERSHIP
-- ==========================================================

--- TWO WAYS TO OWN AN ANIMAL, and this is the only function that knows about
--- either. Everything downstream - equip, sync, the Storage tab, the shop
--- prompt, the offer - asks this and nothing else, so a guardian won on the
--- wheel behaves exactly like one that was bought.
---
--- 1. THE GAME PASS, which Roblox owns. Asked through MonetizationService's
---    cache, so a refund or a revoke is reflected instead of frozen.
--- 2. THE WHEEL, which we own. A win is written into `GuardiansWon` on the
---    profile because Roblox has no record of it to ask for. Checked FIRST:
---    it is a local table lookup and cannot be cold, whereas the pass cache
---    answers false until it has been warmed.
function BaseGuardianService.owns(player: Player, key: string): boolean
	local def = BaseGuardianConfig.ByKey[key]
	if not def then
		return false
	end
	local profile = DataService.get(player)
	if profile and profile.GuardiansWon[key] then
		return true
	end
	if def.gamePassId <= 0 then
		return false
	end
	return MonetizationService.ownsPassCached(player, def.gamePassId)
end

--- Hands a player an animal for good. The ONE writer of `GuardiansWon`.
---
--- Idempotent by construction: the flag is a set, so a replayed or duplicated
--- grant writes the same true a second time and changes nothing. Returns
--- false when there was nothing to give - an unknown key, or an animal this
--- player already had - so a caller can tell a real prize from a no-op.
function BaseGuardianService.grantWon(player: Player, key: string): boolean
	local def = BaseGuardianConfig.ByKey[key]
	local profile = DataService.get(player)
	if not def or not profile then
		return false
	end
	if BaseGuardianService.owns(player, key) then
		return false
	end
	profile.GuardiansWon[key] = true
	-- An EMPTY bay gets the new animal straight away; one that is already
	-- guarding is left alone, exactly as a bought pass behaves. Storage is
	-- where a player changes their mind.
	if profile.EquippedGuardian == "" or not BaseGuardianService.owns(player, profile.EquippedGuardian) then
		BaseGuardianService.equip(player, key)
	else
		StateService.pushNow(player)
	end
	return true
end

-- ==========================================================
-- THE BAY
-- ==========================================================

local function yawFor(def: BaseGuardianConfig.GuardianDef): number
	local flat = Vector3.new(def.faceLocal.X, 0, def.faceLocal.Z)
	if flat.Magnitude < 0.01 then
		return 0
	end
	return math.atan2(flat.X, -flat.Z)
end

--- Where the bay stands: the GuardianBayPad the builder laid, or - on a
--- plot baked before the pad existed - the same two back-rank cells derived
--- from the plot's own grid. Facing the plot's open front.
local function bayFrame(plot: Instance): CFrame?
	local slab = BaseService.slabOf(plot)
	if not slab then
		return nil
	end
	local position: Vector3
	local pad = plot:FindFirstChild("GuardianBayPad")
	if pad and pad:IsA("BasePart") then
		position = pad.Position + Vector3.new(0, pad.Size.Y / 2, 0)
	else
		local halfW, halfD = slab.Size.X / 2, slab.Size.Z / 2
		local cols = MapConfig.DISPLAY_SLOT_COLS
		local function colX(col: number): number
			return -halfW + slab.Size.X * (col - 0.5) / cols
		end
		local x = (colX(cols - 1) + colX(cols)) / 2
		local z = halfD - MapConfig.DISPLAY_BACK_INSET
		position = (slab.CFrame * CFrame.new(x, slab.Size.Y / 2 + 1, z)).Position
	end
	local forward = slab.CFrame.LookVector
	return CFrame.lookAt(position, position + forward)
end

local function bayPart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function cylinder(name: string, diameter: number, thickness: number, cf: CFrame, color: Color3, parent: Instance): Part
	local part = bayPart(name, Vector3.new(thickness, diameter, diameter), cf * CFrame.Angles(0, 0, math.rad(90)), color, Enum.Material.Neon, parent)
	part.Shape = Enum.PartType.Cylinder
	return part
end

local function setBayLabel(plot: Instance, title: string, sub: string, color: Color3)
	local bay = plot:FindFirstChild(BAY_NAME)
	local anchor = bay and bay:FindFirstChild("LabelAnchor")
	local gui = anchor and anchor:FindFirstChildOfClass("BillboardGui")
	if not gui then
		return
	end
	local titleLabel = gui:FindFirstChild("Title") :: TextLabel?
	local subLabel = gui:FindFirstChild("Sub") :: TextLabel?
	if titleLabel then
		titleLabel.Text = title
		titleLabel.TextColor3 = color
	end
	if subLabel then
		subLabel.Text = sub
	end
end

--- Builds the empty bay on a plot, once: a raised dark platform with the
--- slots' neon language around it, a paw in the middle, two short pillars
--- behind, a trickle of energy off the edge and the GUARDIAN label.
local function ensureBay(plot: Instance): Model?
	local existing = plot:FindFirstChild(BAY_NAME)
	if existing and existing:IsA("Model") then
		return existing
	end
	local frame = bayFrame(plot)
	if not frame then
		return nil
	end

	local size = BaseGuardianConfig.BAY_SIZE
	local thick = BaseGuardianConfig.BAY_THICKNESS
	local neon = MapPalette.SlotNeonEmpty
	local model = Instance.new("Model")
	model.Name = BAY_NAME

	local platform = bayPart("Platform", Vector3.new(size, thick, size), frame * CFrame.new(0, thick / 2, 0), MapPalette.SlotPadEmpty, Enum.Material.SmoothPlastic, model)
	platform.CanCollide = true
	platform.CanQuery = true

	-- Neon frame, inset like the display pads'.
	local inset = 1.2
	local inner = size - inset * 2
	local edgeY = thick + 0.1
	for _, edge in {
		{ "North", Vector3.new(inner, 0.22, 0.5), Vector3.new(0, edgeY, inner / 2) },
		{ "South", Vector3.new(inner, 0.22, 0.5), Vector3.new(0, edgeY, -inner / 2) },
		{ "East", Vector3.new(0.5, 0.22, inner), Vector3.new(inner / 2, edgeY, 0) },
		{ "West", Vector3.new(0.5, 0.22, inner), Vector3.new(-inner / 2, edgeY, 0) },
	} do
		local part = bayPart(edge[1] :: string, edge[2] :: Vector3, frame * CFrame.new(edge[3] :: Vector3), neon, Enum.Material.Neon, model)
		part.Transparency = 0.25
	end

	-- The paw: one pad and four toes, dim neon set into the platform top.
	local pawY = thick + 0.02
	local paw = Color3.fromRGB(70, 150, 180)
	cylinder("PawPad", 4.4, 0.1, frame * CFrame.new(0, pawY, 0.6), paw, model).Transparency = 0.35
	for _, toe in { { -2.6, -2.4 }, { -0.95, -3.2 }, { 0.95, -3.2 }, { 2.6, -2.4 } } do
		cylinder("PawToe", 1.5, 0.1, frame * CFrame.new(toe[1], pawY, toe[2]), paw, model).Transparency = 0.35
	end

	-- Two short pillars at the back corners with neon caps.
	for _, side in { -1, 1 } do
		local x = side * (size / 2 - 1.1)
		local z = size / 2 - 1.1
		bayPart("Pillar", Vector3.new(1.6, 5, 1.6), frame * CFrame.new(x, 2.5 + thick, z), MapPalette.PlotBorder, Enum.Material.SmoothPlastic, model)
		local cap = bayPart("PillarCap", Vector3.new(1.9, 0.4, 1.9), frame * CFrame.new(x, 5.2 + thick, z), neon, Enum.Material.Neon, model)
		cap.Transparency = 0.15
	end

	-- Energy: a slow trickle of sparks rising off the platform.
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Energy"
	emitter.Texture = "rbxassetid://241594419"
	emitter.Color = ColorSequence.new(neon, Color3.fromRGB(255, 255, 255))
	emitter.LightEmission = 0.8
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(1.4, 2.2)
	emitter.Rate = 4
	emitter.Speed = NumberRange.new(1.2, 2.2)
	emitter.SpreadAngle = Vector2.new(12, 12)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Parent = platform

	-- The label, over the back of the bay.
	local anchor = bayPart("LabelAnchor", Vector3.new(1, 1, 1), frame * CFrame.new(0, 8.5, size / 2 - 2), neon, Enum.Material.SmoothPlastic, model)
	anchor.Transparency = 1
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromScale(10, 3.4)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 140
	gui.Adornee = anchor
	gui.Parent = anchor
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.55)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = neon
	title.TextStrokeTransparency = 0.15
	title.TextStrokeColor3 = Color3.fromRGB(10, 18, 32)
	title.Text = "GUARDIAN"
	title.Parent = gui
	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.Size = UDim2.fromScale(1, 0.38)
	sub.Position = UDim2.fromScale(0, 0.6)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.FredokaOne
	sub.TextScaled = true
	sub.TextColor3 = Color3.fromRGB(220, 232, 248)
	sub.TextStrokeTransparency = 0.35
	sub.Text = "Equip a Guardian"
	sub.Parent = gui

	model.Parent = plot
	return model
end

-- ==========================================================
-- SPAWN / DESPAWN
-- ==========================================================

local function setChased(player: Player?, on: boolean)
	if player and player.Parent then
		player:SetAttribute("Chased", on)
	end
end

local function publish(g: Guardian)
	g.model:SetAttribute("State", g.state)
end

local function despawn(g: Guardian)
	guardians[g] = nil
	if g.owner and byOwner[g.owner] == g then
		byOwner[g.owner] = nil
	end
	setChased(g.target, false)
	g.model:Destroy()
	setBayLabel(g.plot, "GUARDIAN", "Equip a Guardian", MapPalette.SlotNeonEmpty)
end

local function spawnFor(owner: Player?, ownerUserId: number, plot: Instance, def: BaseGuardianConfig.GuardianDef): Guardian?
	local source = BaseGuardianService.modelFor(def.key)
	if not source then
		warn(`[BaseGuardianService] no model for {def.key} in ReplicatedStorage.GameAssets.BaseGuardians`)
		return nil
	end
	local frame = bayFrame(plot)
	local slab = BaseService.slabOf(plot)
	if not frame or not slab then
		return nil
	end
	ensureBay(plot)

	local model = GuardianService.buildRigFrom(source, BaseGuardianConfig.HEIGHT, 1, `BaseGuardian_{def.key}`, CFrame.Angles(0, yawFor(def), 0))
	local humanoid = model:FindFirstChildWhichIsA("Humanoid")
	local root = model.PrimaryPart
	if not humanoid or not root then
		model:Destroy()
		return nil
	end

	humanoid.WalkSpeed = BaseGuardianConfig.SPEED_MIN
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)

	local platformTop = frame.Position.Y + BaseGuardianConfig.BAY_THICKNESS
	local home = CFrame.new(frame.Position.X, platformTop + root.Size.Y / 2 + 0.1, frame.Position.Z) * frame.Rotation
	model:PivotTo(home)
	model:SetAttribute("State", "Idle")
	model:SetAttribute("OwnerUserId", ownerUserId)
	model:SetAttribute("PlotName", plot.Name)
	model:SetAttribute("GuardianKey", def.key)
	model:SetAttribute("BaseGuardian", true)

	local holder = workspace:FindFirstChild(HOLDER_NAME) or workspace
	model.Parent = holder
	root.Anchored = true

	local walk, idle, perRate = GuardianService.prepareWalk(model)
	BaseGuardianService.applyAura(root, def.key, 0.15, 0.6)

	-- Materialise: a burst off the bay's own energy emitter.
	local bay = plot:FindFirstChild(BAY_NAME)
	local platform = bay and bay:FindFirstChild("Platform")
	local energy = platform and platform:FindFirstChildOfClass("ParticleEmitter")
	if energy then
		energy:Emit(40)
	end

	local motor = root:FindFirstChild("ShellMotor")
	local g: Guardian = {
		key = def.key,
		def = def,
		owner = owner,
		ownerUserId = ownerUserId,
		plot = plot,
		slab = slab,
		halfW = slab.Size.X / 2,
		halfD = slab.Size.Z / 2,
		home = home,
		model = model,
		root = root,
		humanoid = humanoid,
		shellMotor = if motor and motor:IsA("Weld") then motor else nil,
		walkTrack = walk,
		idleTrack = idle,
		walkSpeedPerRate = perRate,
		state = "Idle",
		alertAt = 0,
		chaseStartedAt = 0,
		nextScanAt = 0,
		currentSpeed = BaseGuardianConfig.SPEED_MIN,
		stuckFor = 0,
		sidestepUntil = 0,
		sidestepSign = 1,
		huntUntil = 0,
		attackUntil = 0,
	}
	guardians[g] = true
	if owner then
		byOwner[owner] = g
	end
	setBayLabel(plot, `{string.upper(def.name)} GUARDIAN`, "On guard", def.color)
	return g
end

--- Makes the world agree with the profile: the equipped, OWNED guardian
--- stands in the bay of the plot the player holds, and nothing else does.
function BaseGuardianService.sync(player: Player)
	local profile = DataService.get(player)
	local plot = BaseService.getPlot(player)
	local wanted = ""
	if profile and plot and profile.EquippedGuardian ~= "" and BaseGuardianService.owns(player, profile.EquippedGuardian) then
		wanted = profile.EquippedGuardian
	end

	local current = byOwner[player]
	if current and (wanted == "" or current.key ~= wanted or current.plot ~= plot) then
		despawn(current)
		current = nil
	end
	if plot then
		ensureBay(plot)
	end
	if wanted ~= "" and not current and plot then
		spawnFor(player, player.UserId, plot, BaseGuardianConfig.ByKey[wanted])
	end
end

-- ==========================================================
-- EQUIP
-- ==========================================================

function BaseGuardianService.equip(player: Player, key: string): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local def = BaseGuardianConfig.ByKey[key]
	if not def then
		return false, "That Guardian does not exist."
	end
	if not BaseGuardianService.owns(player, key) then
		return false, `You don't own the {def.name} Guardian yet.`
	end
	if profile.EquippedGuardian == key and byOwner[player] then
		return true
	end
	profile.EquippedGuardian = key
	BaseGuardianService.sync(player)
	StateService.pushNow(player)
	notify(player, "success", `{string.upper(def.name)} GUARDIAN EQUIPPED!`, "levelup")
	return true
end

--- A guardian pass has just been bought. If the bay is EMPTY the new animal
--- goes straight on guard; an animal already standing there is never
--- replaced - the player picked it, and Storage is where they change it.
--- Idempotent: `equip` returns early when this key is already on guard, so a
--- replayed purchase event cannot equip twice or toast twice.
function BaseGuardianService.autoEquipAfterPurchase(player: Player, gamePassId: number): boolean
	local key: string? = nil
	for _, def in BaseGuardianConfig.Guardians do
		if def.gamePassId == gamePassId then
			key = def.key
			break
		end
	end
	if not key then
		return false
	end
	local profile = DataService.get(player)
	if not profile or not BaseGuardianService.owns(player, key) then
		return false
	end
	-- Something owned is already on guard: leave it.
	if profile.EquippedGuardian ~= "" and BaseGuardianService.owns(player, profile.EquippedGuardian) then
		return false
	end
	local ok = BaseGuardianService.equip(player, key)
	return ok == true
end

function BaseGuardianService.unequip(player: Player): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	if profile.EquippedGuardian == "" then
		return true
	end
	profile.EquippedGuardian = ""
	BaseGuardianService.sync(player)
	StateService.pushNow(player)
	notify(player, "info", "Guardian unequipped - it stays in your Storage.")
	return true
end

--- What the Storage tab, the offer and the shop sign render. Prices are the
--- live ones (nil while still loading); the rotation is derived from the
--- server clock so every client shows the same animal and countdown.
function BaseGuardianService.summarise(player: Player): { [string]: any }
	local profile = DataService.get(player)
	local owned: { [string]: boolean } = {}
	local prices: { [string]: number? } = {}
	local names: { [string]: string } = {}
	for _, def in BaseGuardianConfig.Guardians do
		owned[def.key] = BaseGuardianService.owns(player, def.key)
		prices[def.key] = MonetizationService.livePassPrice(def.gamePassId)
		names[def.key] = def.name
	end
	local key, _, endsAt = BaseGuardianConfig.rotation(workspace:GetServerTimeNow())
	local equipped = if profile then profile.EquippedGuardian else ""
	if equipped ~= "" and not owned[equipped] then
		equipped = ""
	end
	return {
		equipped = equipped,
		owned = owned,
		prices = prices,
		names = names,
		rotationKey = key,
		rotationEndsAt = endsAt,
		rotationSeconds = BaseGuardianConfig.ROTATION_SECONDS,
	}
end

-- ==========================================================
-- TARGETS
-- ==========================================================

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function flatDistance(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

--- Inside the plot's footprint (plus `margin` studs), in the plot's own frame.
local function insidePlot(g: Guardian, position: Vector3, margin: number): boolean
	local offset = g.slab.CFrame:PointToObjectSpace(position)
	return math.abs(offset.X) <= g.halfW + margin and math.abs(offset.Z) <= g.halfD + margin and math.abs(offset.Y) < 60
end

local function isHunting(g: Guardian, player: Player, now: number): boolean
	return g.huntTarget == player and now < g.huntUntil
end

local function isValidTarget(g: Guardian, player: Player, now: number): boolean
	if not player.Parent or player == g.owner or player.UserId == g.ownerUserId then
		return false
	end
	if not alive(player) or RagdollService.isImmune(player) then
		return false
	end
	local root = rootOf(player)
	if not root then
		return false
	end
	if isHunting(g, player, now) then
		return flatDistance(root.Position, g.home.Position) < HUNT_RANGE
	end
	local margin = if g.state == "Chasing" and g.target == player then BaseGuardianConfig.CHASE_MARGIN else 0
	return insidePlot(g, root.Position, margin)
end

local function findTarget(g: Guardian, now: number): Player?
	local hunted = g.huntTarget
	if hunted and isValidTarget(g, hunted, now) then
		return hunted
	end
	local best: Player? = nil
	local bestDistance = math.huge
	for _, player in Players:GetPlayers() do
		if isValidTarget(g, player, now) then
			local root = rootOf(player) :: BasePart
			local distance = flatDistance(root.Position, g.root.Position)
			if distance < bestDistance then
				best, bestDistance = player, distance
			end
		end
	end
	return best
end

-- ==========================================================
-- TRANSITIONS
-- ==========================================================

local function resetSteering(g: Guardian)
	g.lastPosition = nil
	g.stuckFor = 0
	g.sidestepUntil = 0
end

local function standUp(g: Guardian)
	local root = g.root
	root.Anchored = false
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	g.humanoid:Move(Vector3.zero, false)
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
end

local function settle(g: Guardian)
	g.humanoid:Move(Vector3.zero, false)
	g.root.Anchored = true
	g.root.AssemblyLinearVelocity = Vector3.zero
	g.root.AssemblyAngularVelocity = Vector3.zero
	g.root.CFrame = g.home
end

local function beginAlert(g: Guardian, target: Player, now: number)
	standUp(g)
	setChased(g.target, false)
	g.state = "Alert"
	g.target = target
	g.alertAt = now + BaseGuardianConfig.ALERT_DELAY
	resetSteering(g)
	setChased(target, true)
	publish(g)
	Audio.playAt("PoliceWhistle", g.root)
	local root = rootOf(target)
	if root then
		local look = Vector3.new(root.Position.X, g.root.Position.Y, root.Position.Z)
		if (look - g.root.Position).Magnitude > 0.1 then
			g.root.CFrame = CFrame.lookAt(g.root.Position, look)
		end
	end
end

local function beginChase(g: Guardian, now: number)
	g.state = "Chasing"
	g.chaseStartedAt = now
	g.nextScanAt = now
	resetSteering(g)
	publish(g)
end

local function goHome(g: Guardian)
	setChased(g.target, false)
	g.target = nil
	g.state = "Returning"
	resetSteering(g)
	publish(g)
end

local function hit(g: Guardian, target: Player, now: number)
	local root = rootOf(target)
	if not root then
		return
	end
	Audio.playAt("NpcCatch", g.root)
	g.attackUntil = now + ATTACK_SECONDS

	-- OUTWARD FROM THE BASE CENTRE, never a fixed world direction: the launch
	-- always carries the intruder off the plot.
	local centre = g.slab.Position
	RagdollService.launch(target, Vector3.new(centre.X, root.Position.Y, centre.Z), {
		knockback = BaseGuardianConfig.KNOCKBACK,
		lift = BaseGuardianConfig.LIFT,
		stun = BaseGuardianConfig.STUN,
		immunity = BaseGuardianConfig.IMMUNITY,
	})
	BaseGuardianService.onIntruderCaught(target, g.ownerUserId)
	if g.huntTarget == target then
		g.huntTarget = nil
		g.huntUntil = 0
	end
	setChased(target, false)
	notify(target, "error", `The {g.def.name} Guardian caught you!`)
	notify(g.owner, "success", `Your {g.def.name} Guardian sent {target.DisplayName} flying!`)
end

-- ==========================================================
-- STEERING
-- ==========================================================

--- Same idea as the zone bosses' steer (a fresh Humanoid:Move every frame,
--- a sidestep when jammed) without the red line: a base has no red line.
local function steer(g: Guardian, goal: Vector3, now: number, dt: number): number
	local root = g.root
	local from = root.Position
	local flat = Vector3.new(goal.X - from.X, 0, goal.Z - from.Z)
	local distance = flat.Magnitude
	if distance < 0.4 then
		g.humanoid:Move(Vector3.zero, false)
		return distance
	end
	local direction = flat / distance
	if now < g.sidestepUntil then
		local lateral = Vector3.new(-direction.Z, 0, direction.X) * (g.sidestepSign * SIDESTEP_STRENGTH)
		local blended = direction + lateral
		if blended.Magnitude > 0.001 then
			direction = blended.Unit
		end
	end
	g.humanoid:Move(direction, false)

	local previous = g.lastPosition
	g.lastPosition = from
	if previous and dt > 0 then
		local moved = flatDistance(from, previous)
		local expected = g.humanoid.WalkSpeed * dt
		if expected > 0 and moved < expected * STUCK_SPEED_FRACTION then
			g.stuckFor += dt
			if g.stuckFor >= STUCK_TRIGGER and now >= g.sidestepUntil then
				g.stuckFor = 0
				g.sidestepSign = -g.sidestepSign
				g.sidestepUntil = now + SIDESTEP_DURATION
				g.humanoid.Jump = true
			end
		else
			g.stuckFor = 0
		end
	end
	return distance
end

local function driveSpeed(g: Guardian, target: number, dt: number)
	if g.humanoid:GetAttribute("Rooted") then
		return
	end
	local alpha = 1 - math.exp(-SPEED_EASE * dt)
	local eased = g.currentSpeed + (target - g.currentSpeed) * alpha
	if math.abs(eased - target) < 0.05 then
		eased = target
	end
	g.currentSpeed = eased
	g.humanoid.WalkSpeed = eased
end

-- ==========================================================
-- ANIMATION
-- ==========================================================

local function animate(g: Guardian, now: number)
	local motor = g.shellMotor
	if not motor then
		return
	end
	local track, idle = g.walkTrack, g.idleTrack

	-- The swipe: a hard lunge forward, held for the length of the hit.
	if now < g.attackUntil then
		local t = 1 - (g.attackUntil - now) / ATTACK_SECONDS
		local lunge = math.sin(math.min(1, t * 1.6) * math.pi)
		motor.C0 = CFrame.new(0, 0.2 * lunge, -0.9 * lunge) * CFrame.Angles(math.rad(-34) * lunge, 0, 0)
		return
	end

	if g.state == "Idle" then
		if track and track.IsPlaying then
			track:Stop(0.2)
		end
		if idle and not idle.IsPlaying then
			idle:Play(0.4)
		end
		local breathe = math.sin(now * 1.6) * 0.06
		motor.C0 = CFrame.new(0, breathe, 0) * CFrame.Angles(math.sin(now * 0.8) * math.rad(1.5), 0, 0)
		return
	end

	if idle and idle.IsPlaying then
		idle:Stop(0.15)
	end

	if g.state == "Alert" then
		if track and track.IsPlaying then
			track:Stop(0.1)
		end
		local shake = math.sin(now * 46) * math.rad(6)
		motor.C0 = CFrame.new(0, 0.25, 0) * CFrame.Angles(math.rad(-8), shake, shake * 0.6)
		return
	end

	if track then
		if not track.IsPlaying then
			track:Play(0.2)
		end
		local velocity = g.root.AssemblyLinearVelocity
		local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		track:AdjustSpeed(math.clamp(speed / g.walkSpeedPerRate, GuardianService.WALK_RATE_MIN, GuardianService.WALK_RATE_MAX))
		motor.C0 = CFrame.Angles(WALK_LEAN, 0, 0)
		return
	end

	local t = now * RUN_CYCLE_SPEED
	local bob = math.abs(math.sin(t)) * RUN_BOB
	local roll = math.sin(t * 0.5) * RUN_ROLL
	local yaw = math.sin(t * 0.5 + 1.1) * RUN_YAW
	motor.C0 = CFrame.new(0, bob, 0) * CFrame.Angles(RUN_LEAN, yaw, roll)
end

-- ==========================================================
-- STEP
-- ==========================================================

local function step(dt: number)
	local now = os.clock()
	for g in guardians do
		if not g.model.Parent or not g.root.Parent then
			despawn(g)
			continue
		end
		animate(g, now)

		local state = g.state
		if state == "Idle" then
			if now >= g.nextScanAt then
				g.nextScanAt = now + BaseGuardianConfig.SCAN_INTERVAL
				local target = findTarget(g, now)
				if target then
					beginAlert(g, target, now)
				end
			end
		elseif state == "Alert" then
			local target = g.target
			if not target or not isValidTarget(g, target, now) then
				goHome(g)
				continue
			end
			g.humanoid:Move(Vector3.zero, false)
			local root = rootOf(target)
			if root then
				local look = Vector3.new(root.Position.X, g.root.Position.Y, root.Position.Z)
				if (look - g.root.Position).Magnitude > 0.1 then
					g.root.CFrame = g.root.CFrame:Lerp(CFrame.lookAt(g.root.Position, look), math.min(1, dt * 12))
				end
			end
			if now >= g.alertAt then
				beginChase(g, now)
			end
		elseif state == "Chasing" then
			local target = g.target
			local targetRoot = if target then rootOf(target) else nil
			if not target or not targetRoot or not isValidTarget(g, target, now) then
				local next = findTarget(g, now)
				if next then
					setChased(g.target, false)
					g.target = next
					setChased(next, true)
					g.chaseStartedAt = now
				else
					goHome(g)
				end
				continue
			end
			if now - g.chaseStartedAt > BaseGuardianConfig.CHASE_TIMEOUT and not isHunting(g, target, now) then
				goHome(g)
				continue
			end

			-- Someone clearly nearer takes over (hysteresis, so two intruders
			-- at similar range never ping-pong it).
			if now >= g.nextScanAt then
				g.nextScanAt = now + BaseGuardianConfig.SCAN_INTERVAL
				local nearest = findTarget(g, now)
				local nearestRoot = if nearest then rootOf(nearest) else nil
				if nearest and nearest ~= target and nearestRoot then
					local current = flatDistance(g.root.Position, targetRoot.Position)
					local candidate = flatDistance(g.root.Position, nearestRoot.Position)
					if candidate < current * 0.7 and current - candidate > 6 then
						setChased(target, false)
						g.target = nearest
						setChased(nearest, true)
						continue
					end
				end
			end

			local reach = (g.root.Position - targetRoot.Position).Magnitude
			if reach <= BaseGuardianConfig.CATCH_RADIUS then
				hit(g, target, now)
				local next = findTarget(g, now)
				if next then
					g.target = next
					setChased(next, true)
					g.chaseStartedAt = now
				else
					goHome(g)
				end
				continue
			end

			local character = target.Character
			local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
			local pace = math.clamp((if humanoid then humanoid.WalkSpeed else 16) * BaseGuardianConfig.SPEED_FACTOR, BaseGuardianConfig.SPEED_MIN, BaseGuardianConfig.SPEED_MAX)
			driveSpeed(g, pace, dt)
			steer(g, targetRoot.Position, now, dt)
		elseif state == "Returning" then
			if now >= g.nextScanAt then
				g.nextScanAt = now + BaseGuardianConfig.SCAN_INTERVAL
				local target = findTarget(g, now)
				if target then
					beginAlert(g, target, now)
					continue
				end
			end
			driveSpeed(g, BaseGuardianConfig.SPEED_MIN + 6, dt)
			local distance = steer(g, g.home.Position, now, dt)
			if distance < BaseGuardianConfig.HOME_REACH then
				settle(g)
				g.state = "Idle"
				publish(g)
			end
		end
	end
end

-- ==========================================================
-- THE HUNT (a paid steal from this base)
-- ==========================================================

function BaseGuardianService.hunt(owner: Player, intruder: Player)
	local g = byOwner[owner]
	if not g then
		return
	end
	local now = os.clock()
	g.huntTarget = intruder
	g.huntUntil = now + HeistConfig.GUARDIAN_HUNT_SECONDS
	if g.state == "Idle" or g.state == "Returning" then
		if isValidTarget(g, intruder, now) then
			beginAlert(g, intruder, now)
		end
	end
end

function BaseGuardianService.stopHunt(intruder: Player)
	for g in guardians do
		if g.huntTarget == intruder then
			g.huntTarget = nil
			g.huntUntil = 0
		end
	end
end

-- ==========================================================
-- DEBUG
-- ==========================================================

--- Studio only: a guardian on a plot with NO owner (UserId 0), so the one
--- player in the server counts as an intruder and the chase can be seen.
function BaseGuardianService.debugSpawn(plotName: string, key: string): boolean
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	local plot = bases and bases:FindFirstChild(plotName)
	local def = BaseGuardianConfig.ByKey[key]
	if not plot or not def then
		return false
	end
	for g in guardians do
		if g.plot == plot then
			despawn(g)
		end
	end
	return spawnFor(nil, 0, plot, def) ~= nil
end

function BaseGuardianService.debugClear(): number
	local count = 0
	for g in guardians do
		if g.owner == nil then
			despawn(g)
			count += 1
		end
	end
	return count
end

function BaseGuardianService.inspect(player: Player): { [string]: any }?
	local g = byOwner[player]
	if not g then
		for candidate in guardians do
			if candidate.owner == nil then
				g = candidate
				break
			end
		end
	end
	if not g then
		return nil
	end
	local velocity = g.root.AssemblyLinearVelocity
	return {
		key = g.key,
		state = g.state,
		target = if g.target then g.target.Name else nil,
		speed = g.humanoid.WalkSpeed,
		groundSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude,
		distanceHome = flatDistance(g.root.Position, g.home.Position),
		hunting = g.huntTarget ~= nil and os.clock() < g.huntUntil,
	}
end

-- ==========================================================
-- START
-- ==========================================================

function BaseGuardianService.start()
	assetsFolder()

	local map = workspace:WaitForChild("Map", 20)
	local bases = map and map:WaitForChild("Bases", 10)
	if bases then
		for _, plot in bases:GetChildren() do
			ensureBay(plot)
		end
	end

	-- The plot assignment fires a rebuild; so does every display change.
	-- Either way the bay must agree with the profile afterwards.
	BaseService.onRebuilt(function(player)
		BaseGuardianService.sync(player)
	end)

	Remotes.get("GuardianRequest").OnServerEvent:Connect(function(player, action, key)
		if not requestLimiter:consume(player) then
			return
		end
		local ok, reason
		if action == "equip" and type(key) == "string" then
			ok, reason = BaseGuardianService.equip(player, key)
		elseif action == "unequip" then
			ok, reason = BaseGuardianService.unequip(player)
		else
			return
		end
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local g = byOwner[player]
		if g then
			despawn(g)
		end
		for other in guardians do
			if other.target == player then
				goHome(other)
			end
			if other.huntTarget == player then
				other.huntTarget = nil
			end
		end
		requestLimiter:release(player)
	end)

	StateService.addProvider("guardians", BaseGuardianService.summarise)

	RunService.Heartbeat:Connect(step)

	print(`[BaseGuardianService] {#BaseGuardianConfig.Guardians} base guardians available; bays built on {if bases then #bases:GetChildren() else 0} plots`)
end

return BaseGuardianService
