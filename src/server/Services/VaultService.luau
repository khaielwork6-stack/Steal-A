--!strict
--[[
	VaultService
	The zone vaults (vaults-crews area; docs/handoff-parts/vaults-crews.md).
	VaultBuilder built the rooms; this service runs them.

	  STOCK     registers each vault pedestal with LootService (a socket with
	            its own roll table) and restocks it: RESTOCK_SECONDS after it
	            was emptied, with a server-wide toast, and at every Night when
	            VaultConfig.RESTOCK_AT_NIGHT is on.
	  DOOR      the door opens (DoorOpen attribute, animated by the clients)
	            while a player with the zone's Speed is near it or inside. The
	            doorway barrier never collides on the server; VaultController
	            makes it solid on the client of a player the door refuses, and
	            this service EJECTS any such player who is inside anyway (an
	            exploit, or a tag-along through an open door).
	  STEAL     CarryService.pickupVeto (wired in init): vault loot needs the
	            zone's Speed, and a pedestal steal needs the thief inside the
	            laser ring (from the movement-verified position).
	  LASERS    one moving field per vault in LaserService; the arms are
	            functions of the server clock (LaserGeometry.sweepAt).
	  GUARD     GuardianService posts a Vault Guardian from the vault's post.

	Nothing here is saved. The server owns every outcome; the client only
	draws the door, the arms and the sign.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local NightConfig = require(ReplicatedStorage.Shared.Config.NightConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
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

local vaults: { [number]: Vault } = {}
--- Studio only: players the door and the ring ignore (debug teleports).
local bypass: { [Player]: boolean } = {}
--- os.clock of the last "the door refused you" toast, per player.
local lastRefusal: { [Player]: number } = {}

-- ==========================================================
-- RULES
-- ==========================================================

function VaultService.requiredSpeed(zoneIndex: number): number
	local zone = ZoneConfig.Zones[zoneIndex]
	return if zone then zone.recommendedSpeed * VaultConfig.SPEED_GATE_FRACTION else math.huge
end

--- Whether the vault door lets this player through.
function VaultService.qualifies(player: Player, zoneIndex: number): boolean
	if bypass[player] then
		return true
	end
	local profile = DataService.get(player)
	return profile ~= nil and profile.SpeedPower >= VaultService.requiredSpeed(zoneIndex)
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
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
		return `You need {NumberFormat.short(VaultService.requiredSpeed(zoneIndex))} Speed for this vault!`
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
	local now = os.clock()
	if now - (lastRefusal[player] or 0) > 3 then
		lastRefusal[player] = now
		StateService.notify(player, "error", `The vault door needs {NumberFormat.short(VaultService.requiredSpeed(vault.zoneIndex))} Speed!`)
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
	local now = workspace:GetServerTimeNow()
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
			vault.restockAt = now + VaultConfig.RESTOCK_SECONDS
			publishStock(vault, false)
		elseif now >= vault.restockAt and not LootService.isClosed() then
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

--- Forces a door open or closed; nil hands it back to the Speed rule.
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
	local now = workspace:GetServerTimeNow()
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
				arm.height, arm.period, math.deg(Geometry.sweepAngle(sweep, now)) % 360, tostring(Geometry.sweepLit(sweep, now))))
		end
		out[`zone{zoneIndex}`] = {
			host = vault.folder:GetAttribute("HostZone"),
			requiredSpeed = VaultService.requiredSpeed(zoneIndex),
			doorOpen = vault.folder:GetAttribute("DoorOpen"),
			doorForced = vault.forced,
			loot = if loot then `{loot.name} [{loot.rarity}] ({loot.state})` else nil,
			restockIn = if vault.restockAt then math.max(0, math.floor(vault.restockAt - now)) else nil,
			ringInner = vault.ring.inner,
			ringOuter = vault.ring.outer,
			arms = arms,
		}
	end
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

	ReplicatedStorage:GetAttributeChangedSignal("NightPhase"):Connect(function()
		if ReplicatedStorage:GetAttribute("NightPhase") == "Night" then
			onNight()
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		bypass[player] = nil
		lastRefusal[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(VaultConfig.DOOR_CHECK_INTERVAL)
			local ok, err = pcall(function()
				doorPass()
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
