--!strict
--[[
	DebugCommands/Vaults
	Studio test commands for the zone vaults and crew heists (vaults-crews).
	Call through ServerStorage.DebugInvoke (second argument: player name or nil):

	    DebugInvoke:Invoke("vaultStates")                      -- every vault: door, loot, restock, arm timing
	    DebugInvoke:Invoke("vaultTeleport", nil, 7)            -- just inside zone 7's vault door (bypass on)
	    DebugInvoke:Invoke("vaultTeleport", nil, 7, true)      -- just outside it (bypass unchanged)
	    DebugInvoke:Invoke("vaultBypass", nil, false)          -- let the lock judge you again
	    DebugInvoke:Invoke("vaultRestock", nil, 7)             -- restock zone 7 now (nil = all)
	    DebugInvoke:Invoke("vaultRestock", nil, nil, true)     -- reroll every sitting container too
	    DebugInvoke:Invoke("vaultDoor", nil, 7, "open")        -- force open / "closed" / nil = lock rule
	    DebugInvoke:Invoke("vaultVeto", nil, 7)                -- would a steal be refused right now, and why
	    DebugInvoke:Invoke("crewAssistSim", nil, "near", 7)    -- synthetic crew mate: "near" | "chased" | "present" | "none"
	    DebugInvoke:Invoke("crewForm", nil, "OtherPlayer")     -- Team Test: put two real players in a crew
	    DebugInvoke:Invoke("crewState")                        -- the crew StatePush field for this player

	PROFILE SAFETY. crewAssistSim pays real Cash through EconomyService; it
	puts Cash and Lifetime.CashEarned back exactly, even on error. Nothing else
	here writes the profile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Layout = require(ReplicatedStorage.Shared.MuseumLayout)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)

local Services = script.Parent.Parent

local function vaultService(): any
	return require(Services.VaultService)
end

local function crewService(): any
	return require(Services.CrewService)
end

local function zoneArg(value: any): number?
	local n = tonumber(value)
	return if n and n >= 1 and n <= 12 then math.floor(n) else nil
end

local Vaults = {}

Vaults.vaultStates = function(_player: Player)
	return vaultService().states()
end

Vaults.vaultTeleport = function(player: Player, zone: any, outside: any): any
	local index = zoneArg(zone)
	if not index then
		return { error = "zone 1-12 required" }
	end
	if outside ~= true then
		-- The tester has not cracked the lock: let the door through.
		vaultService().setBypass(player, true)
	end
	return { ok = vaultService().teleport(player, index, outside == true), bypass = outside ~= true }
end

Vaults.vaultBypass = function(player: Player, on: any)
	vaultService().setBypass(player, on ~= false)
	return { bypass = on ~= false }
end

--- [vault-minigames] Cracks a vault for the tester without the minigame.
Vaults.vaultCrack = function(player: Player, zone: any)
	local index = zoneArg(zone)
	if not index then
		return { error = "zone 1-12 required" }
	end
	vaultService().debugCrack(player, index)
	return { cracked = index }
end

--- Applies (true) or clears (false) the until-Nightfall lockout by hand.
Vaults.vaultLockout = function(player: Player, on: any)
	vaultService().debugLockout(player, on ~= false)
	return { lockedOut = vaultService().isLockedOut(player) }
end

Vaults.vaultRestock = function(_player: Player, zone: any, reroll: any)
	return vaultService().forceRestock(zoneArg(zone), reroll == true)
end

Vaults.vaultDoor = function(_player: Player, zone: any, mode: any)
	local value = if mode == "open" or mode == "closed" then mode else nil
	vaultService().setDoor(zoneArg(zone), value)
	return { zone = zoneArg(zone) or "all", mode = value or "lock rule" }
end

Vaults.vaultVeto = function(player: Player, zone: any): any
	local index = zoneArg(zone) or 1
	local LootService = require(Services.LootService)
	local socket = LootService.getSocket(index, Layout.VAULT_SOCKET)
	local loot = socket and socket.loot
	if not loot then
		return { error = "vault is empty" }
	end
	local ring = vaultService().ringOf(index)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return {
		loot = `{loot.name} [{loot.rarity}]`,
		qualifies = vaultService().qualifies(player, index),
		distanceFromPedestal = if ring and root then math.floor(Vector3.new(root.Position.X - ring.pivot.X, 0, root.Position.Z - ring.pivot.Z).Magnitude * 10) / 10 else nil,
		ringInner = if ring then ring.inner else nil,
		veto = vaultService().pickupVeto(player, loot) or "none - the steal would be allowed",
	}
end

Vaults.crewAssistSim = function(player: Player, mode: any, zone: any, income: any): any
	local Data = require(Services.DataService)
	local profile = Data.get(player)
	if not profile then
		return { error = "profile not loaded" }
	end
	local index = zoneArg(zone) or 1
	local itemIncome = tonumber(income) or LootConfig.pool(index)[1].income
	local savedCash, savedEarned = profile.Cash, profile.Lifetime.CashEarned
	local mate: any = { Name = "SyntheticMate" }
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local home = if root then root.Position else Vector3.zero
	local positions: { [any]: Vector3 } = { [player] = home }
	local how = if type(mode) == "string" then mode else "near"
	if how == "near" then
		positions[mate] = home + Vector3.new(20, 0, 0)
	else
		positions[mate] = home + Vector3.new(500, 0, 0)
		if how == "chased" then
			crewService().noteChased(mate, index)
		elseif how == "present" then
			crewService().notePresence(mate, index)
		end
	end
	local ok, result = pcall(function()
		return crewService().resolveAssist(player, { itemId = "debug", zoneIndex = index, income = itemIncome, heist = false }, { player, mate }, positions)
	end)
	local cashAfter = profile.Cash
	profile.Cash, profile.Lifetime.CashEarned = savedCash, savedEarned
	require(Services.StateService).markDirty(player)
	return {
		mode = how,
		zone = index,
		income = itemIncome,
		result = if ok then result else nil,
		error = if ok then nil else tostring(result),
		cashDelta = cashAfter - savedCash,
		restoredCash = profile.Cash == savedCash,
		expect = "near/chased: paid; present/none: reason = no crew mate nearby or distracting",
	}
end

Vaults.crewForm = function(player: Player, otherName: any): any
	local other = if type(otherName) == "string" then Players:FindFirstChild(otherName) else nil
	if not other or not other:IsA("Player") or other == player then
		return { error = "name another player in this server" }
	end
	return { ok = crewService().debugForm({ player, other }) }
end

Vaults.crewState = function(player: Player)
	return crewService().summarise(player)
end

return Vaults
