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
local LootService = require(script.Parent.LootService)
local CarryService = require(script.Parent.CarryService)

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

	--- Teleports next to a socket and runs the real steal path, prompt aside.
	steal = function(player, zoneIndex: number, socketIndex: number?)
		local socket = LootService.getSocket(zoneIndex, socketIndex or 1)
		if not socket then
			return { error = "no such socket" }
		end
		local loot = socket.loot
		if not loot then
			return { error = "socket is empty" }
		end

		local character = player.Character
		if character then
			character:PivotTo(socket.part.CFrame * CFrame.new(0, 4, 6))
			task.wait(0.35)
		end

		local ok = CarryService.trySteal(player, loot)
		return {
			accepted = ok,
			item = loot.name,
			rarity = loot.rarity,
			variant = `{loot.size}/{loot.mutation}`,
			income = loot.finalIncome,
			state = loot.state,
		}
	end,

	carry = function(player)
		local loot = CarryService.getCarried(player)
		if not loot then
			return { carrying = false }
		end
		local humanoid = player.Character and player.Character:FindFirstChildWhichIsA("Humanoid")
		return {
			carrying = true,
			item = loot.name,
			state = loot.state,
			size = loot.size,
			walkSpeed = if humanoid then humanoid.WalkSpeed else -1,
		}
	end,

	--- Drops the player next to their own base so the safe-zone stop can be seen.
	goHome = function(player)
		local plot = BaseService.getPlot(player)
		local spawn = plot and plot:FindFirstChild("Spawn")
		if not spawn or not spawn:IsA("BasePart") then
			return { error = "no plot" }
		end
		local character = player.Character
		if character then
			character:PivotTo(spawn.CFrame * CFrame.new(0, 4, 0))
		end
		task.wait(0.5)
		return { inOwnSafeZone = BaseService.isInOwnSafeZone(player) }
	end,

	lootSnapshot = function()
		return LootService.snapshot()
	end,

	--- Runs the real placement path (validation included) into a chosen slot.
	place = function(player, slotIndex: number?)
		local PlacementService = require(script.Parent.PlacementService)
		local free = BaseService.freeSlots(player)
		local target = slotIndex or free[1]
		if not target then
			return { error = "no free slot" }
		end
		local ok, reason = PlacementService.place(player, target)
		return { placed = ok, reason = reason, slot = target, income = EconomyService.getIncome(player) }
	end,

	sell = function(player, slotIndex: number)
		local PlacementService = require(script.Parent.PlacementService)
		local ok, reason = PlacementService.sell(player, slotIndex)
		return { sold = ok, reason = reason, cash = EconomyService.getCash(player), income = EconomyService.getIncome(player) }
	end,

	upgradeBase = function(player)
		local PlacementService = require(script.Parent.PlacementService)
		local ok, reason = PlacementService.upgradeCapacity(player)
		return { upgraded = ok, reason = reason, slots = BaseService.unlockedSlots(player) }
	end,

	--- Re-runs the display rebuild + income recalculation, which is exactly what
	--- a reconnect does. Income and trophy count must not drift.
	rebuild = function(player, times: number?)
		local incomes, trophies = {}, {}
		for _ = 1, times or 1 do
			BaseService.rebuildDisplays(player)
			table.insert(incomes, EconomyService.recalculate(player))

			local plot = BaseService.getPlot(player)
			local n = 0
			if plot then
				local slots = plot:FindFirstChild("DisplaySlots")
				if slots then
					for _, slot in slots:GetChildren() do
						if slot:FindFirstChild("Trophy") then
							n += 1
						end
					end
				end
			end
			table.insert(trophies, n)
			task.wait(0.15)
		end
		return { incomes = incomes, trophies = trophies }
	end,

	--- Cheat: flips the flag without paying. Use activateBase for the real path.
	activate = function(player)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		profile.BaseActivated = true
		StateService.pushNow(player)
		return { activated = true }
	end,

	activateBase = function(player)
		local SpeedService = require(script.Parent.SpeedService)
		local ok, reason = SpeedService.activateBase(player)
		local profile = DataService.get(player)
		return {
			activated = ok,
			reason = reason,
			cash = EconomyService.getCash(player),
			treadmillLevel = profile and profile.TreadmillLevel,
		}
	end,

	upgradeTreadmill = function(player)
		local SpeedService = require(script.Parent.SpeedService)
		local ok, reason = SpeedService.upgradeTreadmill(player)
		local profile = DataService.get(player)
		return {
			upgraded = ok,
			reason = reason,
			level = profile and profile.TreadmillLevel,
			cash = EconomyService.getCash(player),
		}
	end,

	--- Parks the player on their treadmill and reports whether the server agrees.
	standOnTreadmill = function(player)
		local SpeedService = require(script.Parent.SpeedService)
		local plot = BaseService.getPlot(player)
		local trigger = plot and plot:FindFirstChild("Treadmill") and plot.Treadmill:FindFirstChild("TrainingTrigger")
		if not trigger then
			return { error = "no treadmill" }
		end
		local character = player.Character
		if character then
			character:PivotTo(trigger.CFrame)
		end
		task.wait(0.4)
		return { onTreadmill = SpeedService.isOnOwnTreadmill(player) }
	end,

	stepOff = function(player)
		local SpeedService = require(script.Parent.SpeedService)
		local plot = BaseService.getPlot(player)
		local trigger = plot and plot.Treadmill.TrainingTrigger
		local character = player.Character
		if character and trigger then
			character:PivotTo(trigger.CFrame * CFrame.new(0, 0, 70))
		end
		task.wait(0.4)
		return { onTreadmill = SpeedService.isOnOwnTreadmill(player) }
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
