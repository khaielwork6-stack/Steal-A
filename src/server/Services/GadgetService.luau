--!strict
--[[
	GadgetService
	Consumable heist gadgets bought with Cash (docs/handoff-parts/gadgets-patrols.md).

	    Smoke Bomb     GuardianService.confuse: chasing guards lose the user.
	    Laser Jammer   LaserService.jam: the detector ignores the user.
	    Grappling Hook a server-applied pull to a surface the SERVER found
	                   with its own raycast, paid for in the anti-cheat budget
	                   by MovementService.allowBurst. Refused while carrying.

	SERVER-AUTHORITATIVE, LIKE THE BAT. The client sends a gadget KEY (and, for
	the hook, an aim point it may lie about). Everything else is decided here:
	whether the player owns one, the cooldown, where they really are
	(MovementService.verifiedPosition), whether that is inside the museum, and
	for the hook where the rope actually lands. A use is validated completely
	BEFORE anything is committed, and the charge is spent only once the effect
	has been applied, in the same frame - a refused use never costs a gadget.

	OWNERSHIP: profile.Gadgets[key] = count (DataService, GADGETS-PATROLS
	block). Tools appear in the Backpack while the count is above zero, the
	way PvPService hands out the Bat and the Trap, and HotbarController gives
	them fixed keys 3-5 (GadgetConfig.hotbarSlot). The shop section lives in
	the main Shop panel (GadgetShopController); the price is the server's
	(GadgetConfig.priceFor on HighestZoneReached), shown through StatePush
	`gadgets`.

	VISUALS are presentation only and are drawn by each client
	(GadgetFxController), so Reduced Effects / Low Graphics are honoured per
	viewer: the server drops an invisible marker part in workspace.GadgetFx
	for the smoke cloud, a replicated `GadgetJamUntil` attribute for the jam
	(LaserService), and a real Beam for the rope.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local GuardianService = require(script.Parent.GuardianService)
local LaserService = require(script.Parent.LaserService)
local LootService = require(script.Parent.LootService)
local MovementService = require(script.Parent.MovementService)
local StateService = require(script.Parent.StateService)

local GadgetService = {}

local useLimiter = RateLimiter.new(GadgetConfig.USE_PER_SECOND)
local buyLimiter = RateLimiter.new(GadgetConfig.BUY_PER_SECOND)

--- os.clock of this player's last accepted use, per gadget and of any gadget.
local lastUse: { [Player]: { [string]: number } } = {}
local lastAny: { [Player]: number } = {}
--- Server time each gadget is usable again, for the client's cooldown ring.
--- Stamped once per use, so the pushed value is stable between uses.
local readyAt: { [Player]: { [string]: number } } = {}
--- The grapple currently pulling this player, so a second can never stack.
local pulling: { [Player]: Instance } = {}

local fxFolder: Folder? = nil
local mapParams: RaycastParams? = nil

local NO_ASSET = "rbxassetid://0"

local function notify(player: Player, kind: string, message: string)
	StateService.notify(player, kind, message)
end

local function folder(): Folder
	local existing = fxFolder
	if existing and existing.Parent then
		return existing
	end
	local made = Instance.new("Folder")
	made.Name = "GadgetFx"
	made.Parent = workspace
	fxFolder = made
	return made
end

--- Map geometry only, collidable only: players, loot, guards and the
--- non-colliding museum dressing are never a grapple surface or a blocker.
local function geometryParams(): RaycastParams
	local params = mapParams
	if params then
		return params
	end
	local built = RaycastParams.new()
	built.FilterType = Enum.RaycastFilterType.Include
	built.FilterDescendantsInstances = { workspace:FindFirstChild("Map") or workspace.Terrain }
	built.RespectCanCollide = true
	mapParams = built
	return built
end

local function bodyOf(player: Player): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return nil, nil, nil
	end
	return character, root, humanoid
end

--- The museum's danger side: past the red line, inside the lane, not on a plot.
local function inMuseum(position: Vector3): boolean
	return position.Z >= 0
		and position.Z <= MapConfig.LANE_END_Z
		and math.abs(position.X) <= MapConfig.LANE_HALF
		and not BaseService.isSafePosition(position)
end

-- ==========================================================
-- COUNTS AND PRICES
-- ==========================================================

function GadgetService.count(player: Player, key: string): number
	local profile = DataService.get(player)
	local gadgets = profile and profile.Gadgets
	return if gadgets then gadgets[key] or 0 else 0
end

--- The Cash price of one `key` for this player right now.
function GadgetService.priceFor(player: Player, key: string): number
	local profile = DataService.get(player)
	return GadgetConfig.priceFor(key, if profile then profile.HighestZoneReached else 1)
end

local function setCount(player: Player, key: string, value: number)
	local profile = DataService.get(player)
	if not profile then
		return
	end
	if type(profile.Gadgets) ~= "table" then
		profile.Gadgets = {}
	end
	local def = GadgetConfig.Gadgets[key]
	local clamped = math.clamp(math.floor(value), 0, if def then def.maxCarried else 0)
	-- nil, not 0, for none: the saved table only lists what is carried.
	local gadgets: any = profile.Gadgets
	gadgets[key] = if clamped > 0 then clamped else nil
end

--- What the shop and the hotbar render (StatePush `gadgets`). Small and
--- stable between uses: counts, this player's prices, the carry limits and
--- when each is ready again (server time).
function GadgetService.summarise(player: Player): { [string]: any }?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local counts, prices, limits = {}, {}, {}
	for key, def in GadgetConfig.Gadgets do
		counts[key] = (profile.Gadgets and profile.Gadgets[key]) or 0
		prices[key] = GadgetConfig.priceFor(key, profile.HighestZoneReached)
		limits[key] = def.maxCarried
	end
	return { counts = counts, prices = prices, max = limits, ready = readyAt[player] or {} }
end

-- ==========================================================
-- TOOLS
-- ==========================================================

local function weldTo(handle: BasePart, part: BasePart, offset: CFrame)
	part.CFrame = handle.CFrame * offset
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = part
	weld.Parent = handle
end

local function piece(tool: Tool, name: string, size: Vector3, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		part.Shape = shape
	end
	part.Parent = tool
	return part
end

--- A gadget Tool. With a mesh in GadgetConfig the Handle is a SpecialMesh
--- over a small part (MeshPart.MeshId cannot be set from a script); without
--- one it is a readable placeholder built from parts. Codex replaces the
--- placeholder by filling meshId / textureId (docs/codex-prompts).
local function buildTool(def: GadgetConfig.GadgetDef): Tool
	local tool = Instance.new("Tool")
	tool.Name = def.toolName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = `{def.label} - {def.description}`
	tool:SetAttribute("Gadget", def.key)
	if def.icon ~= NO_ASSET then
		tool.TextureId = def.icon
	end

	local handle: Part
	if def.meshId ~= NO_ASSET then
		handle = piece(tool, "Handle", Vector3.new(1, 1, 1), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = def.meshId
		if def.textureId ~= NO_ASSET then
			mesh.TextureId = def.textureId
		end
		mesh.Parent = handle
	elseif def.key == "Smoke" then
		handle = piece(tool, "Handle", Vector3.new(1.3, 1.3, 1.3), def.accent, Enum.Material.Metal, Enum.PartType.Ball)
		weldTo(handle, piece(tool, "Band", Vector3.new(0.35, 1.36, 1.36), def.color, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder), CFrame.identity)
		weldTo(handle, piece(tool, "Fuse", Vector3.new(0.18, 0.5, 0.18), Color3.fromRGB(120, 90, 60), Enum.Material.Fabric), CFrame.new(0, 0.85, 0))
		weldTo(handle, piece(tool, "Spark", Vector3.new(0.22, 0.22, 0.22), Color3.fromRGB(255, 170, 60), Enum.Material.Neon, Enum.PartType.Ball), CFrame.new(0, 1.15, 0))
	elseif def.key == "Jammer" then
		handle = piece(tool, "Handle", Vector3.new(0.9, 1.4, 0.45), def.accent, Enum.Material.Metal)
		weldTo(handle, piece(tool, "Screen", Vector3.new(0.7, 0.5, 0.05), def.color, Enum.Material.Neon), CFrame.new(0, 0.25, -0.24))
		weldTo(handle, piece(tool, "Antenna", Vector3.new(0.1, 0.9, 0.1), Color3.fromRGB(40, 44, 56), Enum.Material.Metal), CFrame.new(0.3, 1.1, 0))
		weldTo(handle, piece(tool, "AntennaTip", Vector3.new(0.2, 0.2, 0.2), def.color, Enum.Material.Neon, Enum.PartType.Ball), CFrame.new(0.3, 1.58, 0))
	else
		handle = piece(tool, "Handle", Vector3.new(0.45, 1.6, 0.45), Color3.fromRGB(60, 44, 36), Enum.Material.Wood)
		weldTo(handle, piece(tool, "Barrel", Vector3.new(0.6, 0.6, 1.6), def.accent, Enum.Material.Metal), CFrame.new(0, 0.9, -0.5))
		weldTo(handle, piece(tool, "Hook", Vector3.new(0.9, 0.2, 0.9), def.color, Enum.Material.Metal), CFrame.new(0, 0.9, -1.45))
		weldTo(handle, piece(tool, "HookTip", Vector3.new(0.25, 0.6, 0.25), def.color, Enum.Material.Metal), CFrame.new(0, 1.1, -1.8))
	end
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	tool.Grip = CFrame.new(0, -0.2, 0)
	return tool
end

--- Brings the Backpack in line with the profile: a Tool per gadget the
--- player holds at least one of, labelled with the count; none otherwise.
local function syncTools(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	local profile = DataService.get(player)
	if not backpack or not profile then
		return
	end
	local character = player.Character
	for _, key in GadgetConfig.Order do
		local def = GadgetConfig.Gadgets[key]
		local count = (profile.Gadgets and profile.Gadgets[key]) or 0
		local existing: Tool? = nil
		local containers: { Instance } = { backpack }
		if character then
			table.insert(containers, character)
		end
		for _, container in containers do
			local found = container:FindFirstChild(def.toolName)
			if found and found:IsA("Tool") then
				if existing or count <= 0 then
					found:Destroy() -- a duplicate, or none left
				else
					existing = found
				end
			end
		end
		if count > 0 then
			local tool = existing or buildTool(def)
			tool:SetAttribute("HotbarLabel", `{def.key} x{count}`)
			tool:SetAttribute("GadgetCount", count)
			if not tool.Parent then
				tool.Parent = backpack
			end
		end
	end
end

GadgetService.syncTools = syncTools

-- ==========================================================
-- EFFECTS
-- ==========================================================

local function spawnSmoke(at: Vector3)
	local marker = Instance.new("Part")
	marker.Name = "SmokeCloud"
	marker.Size = Vector3.new(1, 1, 1)
	marker.Transparency = 1
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.CastShadow = false
	marker.CFrame = CFrame.new(at)
	marker:SetAttribute("Gadget", "Smoke")
	marker:SetAttribute("Radius", GadgetConfig.SMOKE_RADIUS)
	marker:SetAttribute("EndsAt", workspace:GetServerTimeNow() + GadgetConfig.SMOKE_CLOUD_SECONDS)
	marker.Parent = folder()
	Debris:AddItem(marker, GadgetConfig.SMOKE_CLOUD_SECONDS + 1)
end

--- Ends a pull early (arrival timer, death, a steal mid-pull, leaving).
local function endPull(player: Player)
	local holder = pulling[player]
	pulling[player] = nil
	if holder then
		holder:Destroy()
	end
end

--- The grapple's validation. Returns the stop point and the surface hit, or
--- a reason. Nothing is changed here.
local function grappleTarget(player: Player, root: BasePart, humanoid: Humanoid, origin: Vector3, requested: Vector3?): (Vector3?, Vector3?, string?)
	if not GadgetConfig.GRAPPLE_WHILE_CARRYING and CarryService.getCarried(player) then
		return nil, nil, "You can't grapple while carrying loot."
	end
	if humanoid.PlatformStand or humanoid.Sit or humanoid:GetAttribute("Rooted") then
		return nil, nil, "You can't grapple right now."
	end
	if pulling[player] then
		return nil, nil, "Already grappling."
	end
	local point = Validate.vector3(requested)
	if not point then
		return nil, nil, "Aim at a wall, floor or ceiling."
	end
	-- From the chest of where the server believes the player is.
	local eye = origin + Vector3.new(0, 1.5, 0)
	local offset = point - eye
	local range = GadgetConfig.GRAPPLE_RANGE
	local tolerance = GadgetConfig.GRAPPLE_TARGET_TOLERANCE
	if offset.Magnitude < 3 then
		return nil, nil, "Too close."
	end
	if offset.Magnitude > range + tolerance then
		return nil, nil, `Too far - the hook reaches {range} studs.`
	end
	local hit = workspace:Raycast(eye, offset.Unit * (range + tolerance), geometryParams())
	if not hit or (hit.Position - point).Magnitude > tolerance then
		return nil, nil, "No clear line to that spot."
	end
	if (hit.Position - eye).Magnitude > range then
		return nil, nil, `Too far - the hook reaches {range} studs.`
	end
	if GadgetConfig.MUSEUM_ONLY and not inMuseum(hit.Position) then
		return nil, nil, "The hook only works inside the museum."
	end
	-- The pull ends where a body fits: off a wall by the standoff, and on a
	-- floor at standing height (root centre above the feet), so the
	-- constraint never presses the character into the ground.
	local offsetOut = GadgetConfig.GRAPPLE_STANDOFF
	if hit.Normal.Y > 0.5 then
		local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else 0
		offsetOut = math.max(offsetOut, humanoid.HipHeight + root.Size.Y / 2 + legs + 0.5)
	end
	local stop = hit.Position + hit.Normal * offsetOut
	return stop, hit.Position, nil
end

local function startPull(player: Player, root: BasePart, stop: Vector3, anchorAt: Vector3)
	local seconds = GadgetConfig.GRAPPLE_PULL_SECONDS
	local distance = (stop - root.Position).Magnitude
	local speed = distance / seconds
	-- Paid for in the anti-cheat budget for the pull, plus the tail of late
	-- packets; anything beyond it is still a strike.
	MovementService.allowBurst(player, speed + GadgetConfig.GRAPPLE_BURST_SLACK, seconds + 0.6)

	-- Everything the pull made lives under one holder, so one Destroy ends it.
	local holder = Instance.new("Folder")
	holder.Name = `Grapple_{player.UserId}`

	local anchor = Instance.new("Part")
	anchor.Name = "HookAnchor"
	anchor.Size = Vector3.new(0.4, 0.4, 0.4)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = CFrame.new(anchorAt)
	anchor.Parent = holder
	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Parent = anchor

	-- The body-side pieces must sit under the character to act on it; they
	-- are tagged with the holder's name and destroyed with it below.
	local attachment = Instance.new("Attachment")
	attachment.Name = "GadgetGrappleAttachment"
	attachment.Parent = root

	local align = Instance.new("AlignPosition")
	align.Name = "GadgetGrapple"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.Position = stop
	align.MaxForce = 200000
	align.MaxVelocity = speed * 1.15
	align.Responsiveness = 60
	align.ApplyAtCenterOfMass = true
	align.Parent = root

	-- The rope, visible to everyone. A Beam, not a part: nothing to collide.
	local rope = Instance.new("Beam")
	rope.Name = "Rope"
	rope.Attachment0 = attachment
	rope.Attachment1 = anchorAttachment
	rope.Width0 = 0.18
	rope.Width1 = 0.18
	rope.Color = ColorSequence.new(Color3.fromRGB(214, 190, 140))
	rope.FaceCamera = true
	rope.Segments = 1
	rope.Parent = anchor

	holder.Parent = folder()
	pulling[player] = holder
	holder.Destroying:Connect(function()
		align:Destroy()
		attachment:Destroy()
	end)

	local character = player.Character
	local started = os.clock()
	local watch: RBXScriptConnection? = nil
	watch = RunService.Heartbeat:Connect(function()
		local done = os.clock() - started >= seconds
			or pulling[player] ~= holder
			or not holder.Parent
			or player.Character ~= character
			or not root.Parent
			or CarryService.getCarried(player) ~= nil
			or (root.Position - stop).Magnitude < 1.5
		if done then
			if watch then
				watch:Disconnect()
			end
			if pulling[player] == holder then
				endPull(player)
			elseif holder.Parent then
				holder:Destroy()
			end
		end
	end)
end

--- Applies one gadget's effect. Validates everything first and commits only
--- when it returns true. `target` is the client's aim hint (hook only).
local function apply(player: Player, def: GadgetConfig.GadgetDef, target: Vector3?, root: BasePart, humanoid: Humanoid, origin: Vector3): (boolean, string?)
	if def.key == "Smoke" then
		local lost = GuardianService.confuse(player, GadgetConfig.SMOKE_CONFUSE_SECONDS)
		local feet = origin - Vector3.new(0, humanoid.HipHeight + root.Size.Y / 2, 0)
		spawnSmoke(feet)
		notify(player, "success", if lost > 0 then "SMOKE! The guard lost you." else "Smoke bomb!")
		return true
	elseif def.key == "Jammer" then
		if not LaserService.jam(player, GadgetConfig.JAM_SECONDS) then
			return false, "The jammer failed."
		end
		notify(player, "success", `LASERS JAMMED for {GadgetConfig.JAM_SECONDS}s!`)
		return true
	elseif def.key == "Grapple" then
		local stop, anchorAt, reason = grappleTarget(player, root, humanoid, origin, target)
		if not stop or not anchorAt then
			return false, reason
		end
		startPull(player, root, stop, anchorAt)
		return true
	end
	return false, "Unknown gadget."
end

-- ==========================================================
-- USE AND BUY
-- ==========================================================

--- One use. `requireHeld`: the Tool must be in the hand (the remote path).
function GadgetService.use(player: Player, key: string, target: Vector3?, requireHeld: boolean?): (boolean, string?)
	local def = GadgetConfig.Gadgets[key]
	if not def then
		return false, "Unknown gadget."
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	if GadgetService.count(player, key) <= 0 then
		return false, `You have no {def.label}.`
	end
	if LootService.isClosed() then
		return false, "The museum is closed."
	end
	local character, root, humanoid = bodyOf(player)
	if not character or not root or not humanoid then
		return false, "You can't use that right now."
	end
	if requireHeld and not character:FindFirstChild(def.toolName) then
		return false, `Hold the {def.label} to use it.`
	end
	local now = os.clock()
	local mine = lastUse[player]
	if mine and now - (mine[key] or -math.huge) < def.cooldown then
		return false, `{def.label} is recharging.`
	end
	if now - (lastAny[player] or -math.huge) < GadgetConfig.SHARED_COOLDOWN then
		return false, "Too fast."
	end
	local origin = MovementService.verifiedPosition(player) or root.Position
	if GadgetConfig.MUSEUM_ONLY and not inMuseum(origin) then
		return false, "Gadgets only work inside the museum."
	end

	local ok, reason = apply(player, def, target, root, humanoid, origin)
	if not ok then
		return false, reason
	end

	-- Committed: spend the charge and start the clocks, in the same frame.
	setCount(player, key, GadgetService.count(player, key) - 1)
	local stamps: { [string]: number } = mine or {}
	lastUse[player] = stamps
	stamps[key] = now
	lastAny[player] = now
	local ready = readyAt[player] or {}
	readyAt[player] = ready
	ready[key] = workspace:GetServerTimeNow() + def.cooldown
	syncTools(player)
	StateService.pushNow(player)
	return true
end

--- One purchase with Cash. The price is the server's; the client sent a key.
function GadgetService.buy(player: Player, key: string): (boolean, string?)
	local def = GadgetConfig.Gadgets[key]
	if not def then
		return false, "Unknown gadget."
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local count = GadgetService.count(player, key)
	if count >= def.maxCarried then
		return false, `You can carry {def.maxCarried} at most.`
	end
	local price = GadgetService.priceFor(player, key)
	if not EconomyService.spend(player, price) then
		return false, "Not enough Cash."
	end
	setCount(player, key, count + 1)
	syncTools(player)
	StateService.pushNow(player)
	notify(player, "success", `{string.upper(def.label)} x{count + 1}`)
	return true
end

--- Studio only: the effect of `key` on this player, without spending one,
--- the held-tool check or the cooldowns (still fully validated otherwise).
function GadgetService.debugApply(player: Player, key: string, target: Vector3?): (boolean, string?)
	if not RunService:IsStudio() then
		return false, "Studio only"
	end
	local def = GadgetConfig.Gadgets[key]
	local _, root, humanoid = bodyOf(player)
	if not def or not root or not humanoid then
		return false, "no gadget or no character"
	end
	return apply(player, def, target, root, humanoid, MovementService.verifiedPosition(player) or root.Position)
end

--- Studio only: set a count directly (debug give / restore), clamped.
function GadgetService.debugSetCount(player: Player, key: string, value: number)
	if not RunService:IsStudio() then
		return
	end
	setCount(player, key, value)
	syncTools(player)
	StateService.pushNow(player)
end

--- Studio only: clears this player's cooldown stamps.
function GadgetService.debugResetCooldowns(player: Player)
	if RunService:IsStudio() then
		lastUse[player] = nil
		lastAny[player] = nil
		readyAt[player] = nil
	end
end

function GadgetService.isPulling(player: Player): boolean
	return (pulling :: any)[player] ~= nil
end

-- ==========================================================
-- START
-- ==========================================================

function GadgetService.start()
	folder()
	StateService.addProvider("gadgets", GadgetService.summarise)

	Remotes.get("GadgetRequest").OnServerEvent:Connect(function(player, action, key, target)
		if type(action) ~= "string" or type(key) ~= "string" or not GadgetConfig.Gadgets[key] then
			return
		end
		if action == "buy" then
			if not buyLimiter:consume(player) then
				return
			end
			local ok, reason = GadgetService.buy(player, key)
			if not ok and reason then
				notify(player, "error", reason)
			end
		elseif action == "use" then
			if not useLimiter:consume(player) then
				return
			end
			-- A malformed aim point is simply no aim point.
			local aim = if target ~= nil then Validate.vector3(target) else nil
			local ok, reason = GadgetService.use(player, key, aim, true)
			if not ok and reason then
				notify(player, "error", reason)
			end
		end
	end)

	local function onPlayer(player: Player)
		task.spawn(function()
			DataService.waitForProfile(player)
			if player.Parent then
				syncTools(player)
			end
		end)
		player.CharacterAdded:Connect(function()
			endPull(player)
			-- After PvPService's own 0.4 s, so the weapon keeps slot 1.
			task.wait(0.5)
			if player.Parent then
				syncTools(player)
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)

	Players.PlayerRemoving:Connect(function(player)
		useLimiter:release(player)
		buyLimiter:release(player)
		endPull(player)
		lastUse[player] = nil
		lastAny[player] = nil
		readyAt[player] = nil
	end)

	print("[GadgetService] smoke, jammer and grapple online")
end

return GadgetService
