--!strict
--[[
	DebugService
	Studio-only test bridge.

	The Play-mode command bar runs with its own module registry, so a plain
	`require` from there gets a fresh, empty copy of every service. This exposes
	a BindableFunction the command bar CAN reach, which then calls into the real
	running services.

	Guarded by RunService:IsStudio(), so it never exists in a live server.
]]

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local BaseService = require(script.Parent.BaseService)
local StateService = require(script.Parent.StateService)

local DebugService = {}

local function firstPlayer(name: string?): Player?
	if name then
		return Players:FindFirstChild(name) :: Player?
	end
	return Players:GetPlayers()[1]
end

--- Named commands the command bar can invoke:
---   Invoke("snapshot")                      current profile + economy summary
---   Invoke("grant", nil, itemId, size, mut) place a trophy in the next free slot
---   Invoke("cash", nil, amount)             award Cash
---   Invoke("clearDisplays")                 empty the base
local COMMANDS: { [string]: (Player, ...any) -> any } = {

	snapshot = function(player)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local items = {}
		for _, item in profile.DisplayItems do
			table.insert(items, `{item.ItemId} {item.Size}/{item.Mutation} slot{item.SlotIndex} ${item.FinalIncome}/s`)
		end
		return {
			plot = if BaseService.getPlot(player) then BaseService.getPlot(player).Name else "none",
			cash = profile.Cash,
			income = EconomyService.getIncome(player),
			speedPower = profile.SpeedPower,
			baseActivated = profile.BaseActivated,
			slotsUnlocked = BaseService.unlockedSlots(player),
			freeSlots = #BaseService.freeSlots(player),
			inOwnSafeZone = BaseService.isInOwnSafeZone(player),
			displays = items,
		}
	end,

	grant = function(player, itemId: string, size: string?, mutation: string?)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local def = LootConfig.ById[itemId]
		if not def then
			return { error = `unknown ItemId "{itemId}"` }
		end
		local free = BaseService.freeSlots(player)
		if #free == 0 then
			return { error = "base full" }
		end

		local sizeId = size or "Normal"
		local mutationId = mutation or "Normal"
		local final = RarityConfig.finalIncome(def.income, sizeId, mutationId)

		table.insert(profile.DisplayItems, {
			InstanceId = HttpService:GenerateGUID(false),
			ItemId = def.id,
			ZoneId = LootConfig.ZoneOf[def.id],
			Rarity = def.rarity,
			Size = sizeId,
			Mutation = mutationId,
			BaseIncome = def.income,
			FinalIncome = final,
			SlotIndex = free[1],
		})
		profile.Index[def.id] = true

		BaseService.rebuildDisplays(player)
		local income = EconomyService.recalculate(player)
		StateService.pushNow(player)

		return { placed = def.name, slot = free[1], finalIncome = final, totalIncome = income }
	end,

	cash = function(player, amount: number)
		EconomyService.award(player, amount)
		StateService.pushNow(player)
		return { cash = EconomyService.getCash(player) }
	end,

	clearDisplays = function(player)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		profile.DisplayItems = {}
		BaseService.rebuildDisplays(player)
		EconomyService.recalculate(player)
		StateService.pushNow(player)
		return { cleared = true }
	end,
}

function DebugService.start()
	if not RunService:IsStudio() then
		return
	end

	local bridge = ServerStorage:FindFirstChild("DebugInvoke")
	if bridge then
		bridge:Destroy()
	end

	local fn = Instance.new("BindableFunction")
	fn.Name = "DebugInvoke"
	fn.Parent = ServerStorage

	fn.OnInvoke = function(command: string, playerName: string?, ...)
		local handler = COMMANDS[command]
		if not handler then
			local names = {}
			for name in COMMANDS do
				table.insert(names, name)
			end
			return { error = `unknown command "{command}"`, available = names }
		end

		local player = firstPlayer(playerName)
		if not player then
			return { error = "no player in server" }
		end

		local ok, result = pcall(handler, player, ...)
		if not ok then
			return { error = tostring(result) }
		end
		return result
	end

	print("[DebugService] Studio bridge ready at ServerStorage.DebugInvoke")
end

return DebugService
