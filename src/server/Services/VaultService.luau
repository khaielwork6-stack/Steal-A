--!strict
--[[
	VaultService
	The zone vaults (vaults-crews area; docs/handoff-parts/vaults-crews.md).
	VaultBuilder built the rooms; this service runs them.

	  THE LOCK  [vault-minigames] The door answers to ONE flag: has this player
	            cracked this vault's lock. The "Crack the Lock" prompt at the
	            door starts an ATTEMPT: the server rolls which of the two
	            minigames it is (VaultConfig.MINIGAMES, equal odds), builds the
	            parameters, sends them to the client, and watches. The client
	            plays it and reports a verdict; the server believes a FAILURE
	            at once and a SUCCESS only if the token matches, the attempt is
	            still alive, and it did not come back impossibly fast. Dying,
	            walking off, leaving, a timeout, or Roblox reporting a failure
	            all end the attempt the same way: a LOCKOUT from every vault
	            until the next Nightfall, saved on the profile so a rejoin
	            cannot shed it. Night clears every lockout and every unlock.
	            Speed has no say anywhere in here.
	  STOCK     registers each vault pedestal with LootService (a socket with
	            its own roll table) and restocks it: RESTOCK_SECONDS after it
	            was emptied, with a server-wide toast, and at every Night when
	            VaultConfig.RESTOCK_AT_NIGHT is on.
	  DOOR      the door opens (DoorOpen attribute, animated by the clients)
	            while an unlocked player is near it or inside. The doorway
	            barrier never collides on the server; VaultController makes it
	            solid on the client of a player the door refuses, and this
	            service EJECTS any such player who is inside anyway (an
	            exploit, or a tag-along through an open door).
	  STEAL     CarryService.pickupVeto (wired in init): vault loot needs the
	            lock cracked, and a pedestal steal needs the thief inside the
	            laser ring (from the movement-verified position).
	  LASERS    one moving field per vault in LaserService; the arms are
	            functions of the server clock (LaserGeometry.sweepAt).
	  GUARD     GuardianService posts a Vault Guardian from the vault's post.

	Only the lockout stamp is saved. The server owns every outcome; the client
	draws the door, the arms, the sign and the minigame.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local VaultConfig = require(ReplicatedStorage.Shared.Config.VaultConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)

local DataService = require(script.Parent.DataService)
local LaserService = require(script.Parent.LaserService)
local LootService = require(script.Parent.LootService)
local MovementService = require(script.Parent.MovementService)
local StateService = require(script.Parent.StateService)

local VaultService = {}

export type DoorMode = "open" | "closed"
export type Method = "Cut" | "Pins"

type Vault = {
	zoneIndex: number,
	folder: Instance,
	frame: CFrame,
	ring: VaultConfig.Ring,
	--- Server time the empty pedestal restocks; nil while stocked.
	restockAt: number?,
	--- Debug override of the door (DebugCommands/Vaults).
	forced: DoorMode?,
}

type Attempt = {
	zoneIndex: number,
	method: Method,
	token: string,
	startedAt: number,
	--- A success reported sooner than this is a lie (the minigame cannot be
	--- finished that fast), and is treated as a failure.
	minSeconds: number,
}

local vaults: { [number]: Vault } = {}
--- Studio only: players the door and the ring ignore (debug teleports).
local bypass: { [Player]: boolean } = {}
--- os.clock of the last "the door refused you" toast, per player.
local lastRefusal: { [Player]: number } = {}
--- Vaults this player has cracked since the last Night, per zone.
local unlocked: { [Player]: { [number]: true } } = {}
--- The one attempt a player may have running.
local attempts: { [Player]: Attempt } = {}
--- Seconds until the next Nightfall begins, injected by init from
--- NightService (which this leaf-ish service must not require).
local secondsToNightfall: (() -> number)? = nil

-- ==========================================================
-- RULES
-- ==========================================================

local function now(): number
	return workspace:GetServerTimeNow()
end

--- True while the profile says every vault refuses this player.
function VaultService.isLockedOut(player: Player): boolean
	local profile = DataService.get(player)
	return profile ~= nil and (tonumber(profile.VaultLockoutUntil) or 0) > now()
end

--- Whether the vault door lets this player through: the lock is cracked.
function VaultService.qualifies(player: Player, zoneIndex: number): boolean
	if bypass[player] then
		return true
	end
	local mine = unlocked[player]
	return mine ~= nil and mine[zoneIndex] == true
end

--- What the client reads: the cracked vaults, the lockout, the live attempt.
local function publish(player: Player)
	local list = {}
	for zone in unlocked[player] or {} do
		table.insert(list, zone)
	end
	table.sort(list)
	player:SetAttribute("VaultUnlocked", table.concat(list, ";"))
	player:SetAttribute("VaultLockedOut", VaultService.isLockedOut(player))
	local attempt = attempts[player]
	player:SetAttribute("VaultAttempt", if attempt then attempt.zoneIndex else 0)
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character.Parent ~= nil
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

--- CarryService.pickupVeto: nil to allow, else the reason shown to the player.
function VaultService.pickupVeto(player: Player, loot: any): string?
	if not LootService.isVaultLoot(loot) then
		return nil
	end
	local zoneIndex = loot.zoneIndex
	if not VaultService.qualifies(player, zoneIndex) then
		return if VaultService.isLockedOut(player) then VaultConfig.LOCKOUT_MESSAGE else "Crack the vault's lock first!"
	end
	if loot.state == "Spawned" and not bypass[player] then
		local vault = vaults[zoneIndex]
		local root = rootOf(player)
		local at = MovementService.verifiedPosition(player) or (if root then root.Position else nil)
		if not vault or not at or flatDistance(at, vault.ring.pivot) > vault.ring.inner + VaultConfig.STEAL_REACH_MARGIN then
			return "Get inside the laser ring to take it!"
		end
	end
	return nil
end

-- ==========================================================
-- DOOR AND INTRUDERS
-- ==========================================================

local function eject(player: Player, vault: Vault)
	local character = player.Character
	if not character then
		return
	end
	-- A legitimate server move (security pass B1).
	MovementService.allowTeleport(player)
	-- Just outside the door, facing the corridor.
	character:PivotTo(vault.frame * CFrame.new(0, 4, -8) * CFrame.Angles(0, math.pi, 0))
	local clock = os.clock()
	if clock - (lastRefusal[player] or 0) > 3 then
		lastRefusal[player] = clock
		StateService.notify(player, "error", if VaultService.isLockedOut(player) then VaultConfig.LOCKOUT_MESSAGE else "Crack the lock to enter the vault!")
	end
end

local function doorPass()
	local players = Players:GetPlayers()
	local roots: { [Player]: BasePart } = {}
	local inside: { [Player]: number } = {}
	for _, player in players do
		local root = rootOf(player)
		if root then
			roots[player] = root
			local zone = Layout.inVault(root.Position)
			if zone then
				inside[player] = zone
			end
		end
	end
	for zoneIndex, vault in vaults do
		local open = false
		if vault.forced then
			open = vault.forced == "open"
		elseif VaultConfig.ENABLED then
			local doorAt = vault.frame.Position
			for player, root in roots do
				if (inside[player] == zoneIndex or flatDistance(root.Position, doorAt) <= VaultConfig.DOOR_OPEN_RADIUS)
					and VaultService.qualifies(player, zoneIndex) then
					open = true
					break
				end
			end
		end
		if vault.folder:GetAttribute("DoorOpen") ~= open then
			vault.folder:SetAttribute("DoorOpen", open)
		end
		if vault.forced ~= "open" then
			for player, zone in inside do
				if zone == zoneIndex and not VaultService.qualifies(player, zoneIndex) then
					eject(player, vault)
				end
			end
		end
	end
end

-- ==========================================================
-- THE LOCK: ATTEMPTS, VERDICTS, LOCKOUT
-- ==========================================================

--- One of the two methods, by weight. Rolled HERE so the client cannot pick.
local function rollMethod(): Method
	local total = 0
	for _, method in VaultConfig.MINIGAMES do
		total += method.weight
	end
	local pick = math.random() * total
	for _, method in VaultConfig.MINIGAMES do
		pick -= method.weight
		if pick <= 0 then
			return method.key :: Method
		end
	end
	return "Cut"
end

--- Everything the client needs to draw the chosen minigame. Randomness lives
--- here so every attempt is a fresh puzzle and the client cannot replay a
--- known one.
local function paramsFor(method: Method, zoneIndex: number): ({ [string]: any }, number)
	if method == "Cut" then
		local cut = VaultConfig.CUT
		return {
			rotationSeconds = cut.rotationSeconds,
			targetRadius = cut.targetRadius,
			touchScale = cut.touchScale,
			graceSeconds = cut.graceSeconds,
			wobble = cut.wobble,
			startAngle = math.random() * 360,
			direction = if math.random() < 0.5 then 1 else -1,
		}, cut.rotationSeconds * 0.85
	end
	local pins = VaultConfig.PINS
	local band = math.clamp(math.ceil(zoneIndex / 4), 1, #pins.countByBand)
	local count = pins.countByBand[band]
	local list = {}
	for index = 1, count do
		list[index] = {
			height = pins.heightMin + math.random() * (pins.heightMax - pins.heightMin),
			amplitude = pins.amplitudeMin + math.random() * (pins.amplitudeMax - pins.amplitudeMin),
			period = pins.periodMin + math.random() * (pins.periodMax - pins.periodMin),
			phase = math.random() * math.pi * 2,
		}
	end
	return { pins = list, notchFraction = pins.notchFraction }, 1.2 + count * 0.3
end

local function endAttempt(player: Player)
	attempts[player] = nil
	publish(player)
end

--- The one punishment, for every way of failing.
local function lockOut(player: Player)
	local profile = DataService.get(player)
	local seconds = if secondsToNightfall then secondsToNightfall() else NightConfig.CYCLE_SECONDS
	if profile then
		profile.VaultLockoutUntil = now() + math.max(seconds, 1)
	end
	unlocked[player] = nil
	-- A failure the SERVER decided (walked off, died, timed out) reaches a
	-- client whose minigame is still open; it has to be told, first, so it
	-- can drop the HUD claim before the lockout toast tries to show.
	local attempt = attempts[player]
	if attempt then
		Remotes.get("VaultMinigame"):FireClient(player, "fail", attempt.token)
	end
	endAttempt(player)
	StateService.notify(player, "error", VaultConfig.LOCKOUT_MESSAGE, "vaultLockout")
	StateService.sound(player, "UiDenied")
	-- Locked out and standing inside a vault is the same as any intruder.
	local root = rootOf(player)
	local zone = root and Layout.inVault(root.Position)
	if zone and vaults[zone] and vaults[zone].forced ~= "open" then
		eject(player, vaults[zone])
	end
end

local function succeed(player: Player, zoneIndex: number)
	local mine = unlocked[player] or {}
	mine[zoneIndex] = true
	unlocked[player] = mine
	endAttempt(player)
	StateService.notify(player, "success", `Zone {zoneIndex} vault cracked - the door is yours!`, "vaultOpen")
	StateService.sound(player, "VaultDoor")
end

--- Ends an attempt WITHOUT a verdict (Nightfall cancelled it): no lockout.
local function abort(player: Player, attempt: Attempt)
	Remotes.get("VaultMinigame"):FireClient(player, "abort", attempt.token)
	endAttempt(player)
end

--- The prompt at a door. Every refusal is a toast, so the player always
--- knows why nothing happened.
local function beginAttempt(player: Player, zoneIndex: number)
	local vault = vaults[zoneIndex]
	if not vault or not VaultConfig.ENABLED then
		return
	end
	if attempts[player] then
		return -- one at a time; the running one decides
	end
	if VaultService.isLockedOut(player) then
		StateService.notify(player, "error", VaultConfig.LOCKOUT_MESSAGE, "vaultLockout")
		return
	end
	if VaultService.qualifies(player, zoneIndex) then
		StateService.notify(player, "info", "This vault is already open for you.")
		return
	end
	if not alive(player) then
		return
	end
	local root = rootOf(player)
	if not root or flatDistance(root.Position, vault.frame.Position) > VaultConfig.ATTEMPT_LEASH then
		return
	end
	local method = rollMethod()
	local params, minSeconds = paramsFor(method, zoneIndex)
	local attempt: Attempt = {
		zoneIndex = zoneIndex,
		method = method,
		token = HttpService:GenerateGUID(false),
		startedAt = os.clock(),
		minSeconds = minSeconds,
	}
	attempts[player] = attempt
	publish(player)
	Remotes.get("VaultMinigame"):FireClient(player, "start", attempt.token, zoneIndex, method, params)
end

--- The client's verdict. A failure is believed; a success has to be earned.
local function onResult(player: Player, token: any, success: any)
	local attempt = attempts[player]
	if not attempt or type(token) ~= "string" or token ~= attempt.token then
		return
	end
	if success ~= true then
		lockOut(player)
		return
	end
	local elapsed = os.clock() - attempt.startedAt
	local root = rootOf(player)
	local vault = vaults[attempt.zoneIndex]
	if elapsed < attempt.minSeconds or not alive(player) or not root or not vault
		or flatDistance(root.Position, vault.frame.Position) > VaultConfig.ATTEMPT_LEASH then
		lockOut(player)
		return
	end
	succeed(player, attempt.zoneIndex)
end

--- Everything that ends an attempt from OUTSIDE the minigame: death, walking
--- away, a timeout. All of it is a failure.
local function attemptPass()
	for player, attempt in attempts do
		local vault = vaults[attempt.zoneIndex]
		local root = rootOf(player)
		local away = not root or not vault or flatDistance(root.Position, vault.frame.Position) > VaultConfig.ATTEMPT_LEASH
		if not alive(player) or away or os.clock() - attempt.startedAt > VaultConfig.ATTEMPT_TIMEOUT then
			lockOut(player)
		end
	end
end

--- Nightfall: every lockout ends, every door re-locks, every running attempt
--- is cancelled without blame (the Night reset is nobody's fault).
local function clearForNight()
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if profile then
			profile.VaultLockoutUntil = 0
		end
		unlocked[player] = nil
		local attempt = attempts[player]
		if attempt then
			abort(player, attempt)
		else
			publish(player)
		end
	end
end

--- init injects NightService's clock so this file need not require it.
function VaultService.setNightfallClock(fn: () -> number)
	secondsToNightfall = fn
end

-- ==========================================================
-- STOCK
-- ==========================================================

local function publishStock(vault: Vault, stocked: boolean)
	vault.folder:SetAttribute("Stocked", stocked)
	vault.folder:SetAttribute("RestockAt", vault.restockAt or 0)
end

local function vaultName(zoneIndex: number): string
	return `Zone {zoneIndex}`
end

local function restockPass()
	if not VaultConfig.ENABLED then
		return
	end
	local clock = now()
	for zoneIndex, vault in vaults do
		local socket = LootService.getSocket(zoneIndex, Layout.VAULT_SOCKET)
		if not socket then
			continue
		end
		if socket.loot then
			if vault.restockAt then
				vault.restockAt = nil
			end
			publishStock(vault, true)
		elseif not vault.restockAt then
			vault.restockAt = clock + VaultConfig.RESTOCK_SECONDS
			publishStock(vault, false)
		elseif clock >= vault.restockAt and not LootService.isClosed() then
			local loot = LootService.restockVault(zoneIndex, false)
			if loot then
				vault.restockAt = nil
				publishStock(vault, true)
				StateService.announce("success", `The {vaultName(zoneIndex)} vault has restocked!`, "vault", "NightSpawn")
			end
		end
	end
end

--- Restocks every vault now. `reroll` also replaces containers still sitting
--- on their pedestals. Returns how many EMPTY vaults were filled.
function VaultService.restockAll(reroll: boolean): number
	local filled = 0
	for zoneIndex, vault in vaults do
		local loot, wasEmpty = LootService.restockVault(zoneIndex, reroll)
		if loot then
			vault.restockAt = nil
			publishStock(vault, true)
			if wasEmpty then
				filled += 1
			end
		end
	end
	return filled
end

local function onNight()
	clearForNight()
	if not VaultConfig.ENABLED or not VaultConfig.RESTOCK_AT_NIGHT then
		return
	end
	-- After the carries the Night cancelled have gone back to their
	-- pedestals, like the ordinary refresh.
	task.delay(NightConfig.REFRESH_DELAY_SECONDS + 0.5, function()
		local ok, result = pcall(VaultService.restockAll, true)
		if not ok then
			warn(`[VaultService] Night restock failed: {result}`)
		elseif (result :: number) > 0 then
			StateService.announce("success", "The vaults have restocked!", "vault")
		end
	end)
end

-- ==========================================================
-- DEBUG API (DebugCommands/Vaults; Studio only where it matters)
-- ==========================================================

--- Restocks one vault (or all) at once. `reroll` replaces a sitting container.
function VaultService.forceRestock(zoneIndex: number?, reroll: boolean?): { [string]: any }
	local out = {}
	for index, vault in vaults do
		if zoneIndex == nil or zoneIndex == index then
			local loot, wasEmpty = LootService.restockVault(index, reroll == true)
			if loot then
				vault.restockAt = nil
				publishStock(vault, true)
				if wasEmpty then
					StateService.announce("success", `The {vaultName(index)} vault has restocked!`, "vault", "NightSpawn")
				end
			end
			out[`zone{index}`] = if loot then `{loot.name} [{loot.rarity}] {loot.state}` else "<empty>"
		end
	end
	return out
end

--- Forces a door open or closed; nil hands it back to the lock rule.
function VaultService.setDoor(zoneIndex: number?, mode: DoorMode?)
	for index, vault in vaults do
		if zoneIndex == nil or zoneIndex == index then
			vault.forced = mode
			vault.folder:SetAttribute("DoorForced", mode)
		end
	end
end

--- Studio only: the door, the ejector and the ring ignore this player.
function VaultService.setBypass(player: Player, on: boolean)
	if RunService:IsStudio() then
		bypass[player] = if on then true else nil
	end
end

--- Studio only: cracks a vault for a player without the minigame.
function VaultService.debugCrack(player: Player, zoneIndex: number)
	if RunService:IsStudio() then
		succeed(player, zoneIndex)
	end
end

--- Studio only: applies or clears the lockout by hand.
function VaultService.debugLockout(player: Player, on: boolean)
	if not RunService:IsStudio() then
		return
	end
	if on then
		lockOut(player)
	else
		local profile = DataService.get(player)
		if profile then
			profile.VaultLockoutUntil = 0
		end
		publish(player)
	end
end

--- Moves a player just inside (or just outside) a vault's door.
function VaultService.teleport(player: Player, zoneIndex: number, outside: boolean?): boolean
	local vault = vaults[zoneIndex]
	local character = player.Character
	if not vault or not character then
		return false
	end
	MovementService.allowTeleport(player)
	local target = if outside
		then vault.frame * CFrame.new(0, 4, -8) * CFrame.Angles(0, math.pi, 0)
		else vault.frame * CFrame.new(0, 4, 8) * CFrame.Angles(0, math.pi, 0)
	character:PivotTo(target)
	return true
end

--- The pedestal's centre and ring, for tests.
function VaultService.ringOf(zoneIndex: number): VaultConfig.Ring?
	local vault = vaults[zoneIndex]
	return if vault then vault.ring else nil
end

--- Everything a tester wants to see, per vault.
function VaultService.states(): { [string]: any }
	local clock = now()
	local out = {}
	for zoneIndex, vault in vaults do
		local socket = LootService.getSocket(zoneIndex, Layout.VAULT_SOCKET)
		local loot = socket and socket.loot
		local arms = {}
		for _, arm in VaultConfig.beamsFor(zoneIndex) do
			local sweep: Geometry.SweepArm = {
				pivot = vault.ring.pivot, inner = vault.ring.inner, outer = vault.ring.outer,
				height = arm.height, period = arm.period, phase = arm.phase,
				onSeconds = arm.onSeconds, offSeconds = arm.offSeconds,
			}
			table.insert(arms, string.format("h=%.1f period=%.2fs angle=%.0fdeg lit=%s",
				arm.height, arm.period, math.deg(Geometry.sweepAngle(sweep, clock)) % 360, tostring(Geometry.sweepLit(sweep, clock))))
		end
		local crackedBy = {}
		for player, mine in unlocked do
			if mine[zoneIndex] then
				table.insert(crackedBy, player.Name)
			end
		end
		out[`zone{zoneIndex}`] = {
			host = vault.folder:GetAttribute("HostZone"),
			crackedBy = crackedBy,
			doorOpen = vault.folder:GetAttribute("DoorOpen"),
			doorForced = vault.forced,
			loot = if loot then `{loot.name} [{loot.rarity}] ({loot.state})` else nil,
			restockIn = if vault.restockAt then math.max(0, math.floor(vault.restockAt - clock)) else nil,
			ringInner = vault.ring.inner,
			ringOuter = vault.ring.outer,
			arms = arms,
		}
	end
	local live = {}
	for player, attempt in attempts do
		live[player.Name] = `{attempt.method} at zone {attempt.zoneIndex}, {math.floor(os.clock() - attempt.startedAt)}s`
	end
	out.attempts = live
	return out
end

-- ==========================================================
-- START
-- ==========================================================

function VaultService.start()
	local map = workspace:WaitForChild("Map", 20)
	local zones = map and map:WaitForChild("Zones", 10)
	if not zones then
		warn("[VaultService] no Map.Zones - vaults disabled")
		return
	end
	for zoneIndex, def in ZoneConfig.Zones do
		local zone = zones:FindFirstChild(def.id)
		local folder = zone and zone:FindFirstChild("Vault")
		local sockets = folder and folder:FindFirstChild("SpawnSockets")
		local part = sockets and sockets:FindFirstChild(string.format("Socket%02d", Layout.VAULT_SOCKET))
		if not folder or not part or not part:IsA("BasePart") then
			warn(`[VaultService] {def.id} has no vault - rebuild the map`)
			continue
		end
		local ring = VaultConfig.ring(zoneIndex)
		vaults[zoneIndex] = { zoneIndex = zoneIndex, folder = folder, frame = Layout.vaultFrame(zoneIndex), ring = ring }
		LootService.addVaultSocket(zoneIndex, part)

		local arms: { Geometry.SweepArm } = {}
		for _, arm in VaultConfig.beamsFor(zoneIndex) do
			table.insert(arms, {
				pivot = ring.pivot, inner = ring.inner, outer = ring.outer,
				height = arm.height, period = arm.period, phase = arm.phase,
				onSeconds = arm.onSeconds, offSeconds = arm.offSeconds,
			})
		end
		local index = zoneIndex
		LaserService.addMovingField(zoneIndex, Layout.VAULT_ROOM, arms, function(position: Vector3): boolean
			return Layout.inVault(position) == index
		end)
	end

	if VaultConfig.ENABLED then
		VaultService.restockAll(false)
	end

	-- THE PROMPT. Only the vault's own lock prompt; its zone is the folder's.
	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name ~= "VaultLockPrompt" then
			return
		end
		local anchor = prompt.Parent
		local folder = anchor and anchor.Parent
		local zoneIndex = folder and tonumber(folder:GetAttribute("VaultZone"))
		if zoneIndex then
			beginAttempt(player, zoneIndex)
		end
	end)
	Remotes.get("VaultMinigameResult").OnServerEvent:Connect(onResult)

	ReplicatedStorage:GetAttributeChangedSignal("NightPhase"):Connect(function()
		if ReplicatedStorage:GetAttribute("NightPhase") == "Night" then
			onNight()
		end
	end)

	-- The saved lockout rides in with the profile.
	local function onPlayer(player: Player)
		task.spawn(function()
			if DataService.waitForProfile(player) then
				publish(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		-- Leaving mid-attempt is a failure; the stamp is on the profile
		-- before it saves.
		if attempts[player] then
			lockOut(player)
		end
		bypass[player] = nil
		lastRefusal[player] = nil
		unlocked[player] = nil
		attempts[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(VaultConfig.DOOR_CHECK_INTERVAL)
			local ok, err = pcall(function()
				doorPass()
				attemptPass()
				return true
			end)
			if not ok then
				warn(`[VaultService] door pass failed: {err}`)
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(function()
				restockPass()
				return true
			end)
			if not ok then
				warn(`[VaultService] restock pass failed: {err}`)
			end
		end
	end)

	local count = 0
	for _ in vaults do
		count += 1
	end
	print(`[VaultService] {count} vaults open for business`)
end

return VaultService
