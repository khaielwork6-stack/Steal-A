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

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
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
		local firstTime = not profile.Index[def.id]
		profile.Index[def.id] = true

		BaseService.rebuildDisplays(player)
		local income = EconomyService.recalculate(player)
		StateService.pushNow(player)

		-- Mirror the real placement path. Without this the Index grid stays stale
		-- until the panel is next opened, which makes grant-based testing lie.
		if firstTime then
			require(script.Parent.IndexService).onDiscovered(player, def.id)
		end

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

	--- Spawns a stand-in victim rig so the bat and traps can be exercised with
	--- only one real client. It is a plain R6 humanoid, not a Player, so it
	--- proves geometry/cooldown but NOT the Player-targeting path.
	dummy = function(player, distance: number?)
		local existing = workspace:FindFirstChild("_TestDummy")
		if existing then
			existing:Destroy()
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not root then
			return { error = "no character" }
		end

		local model = Instance.new("Model")
		model.Name = "_TestDummy"
		local body = Instance.new("Part")
		body.Name = "HumanoidRootPart"
		body.Size = Vector3.new(2.6, 5, 1.6)
		body.Color = Color3.fromRGB(230, 90, 120)
		body.CFrame = root.CFrame * CFrame.new(0, 0, -(distance or 4))
		body.Parent = model
		local hum = Instance.new("Humanoid")
		hum.Parent = model
		model.PrimaryPart = body
		model.Parent = workspace
		return { spawned = true, at = tostring(body.Position) }
	end,

	swing = function(player)
		local PvPService = require(script.Parent.PvPService)
		local ok, reason = PvPService.trySwing(player)
		return { accepted = ok, reason = reason }
	end,

	placeTrap = function(player, forward: number?)
		local PvPService = require(script.Parent.PvPService)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local target = root and (root.Position + root.CFrame.LookVector * (forward or 8)) or nil
		PvPService.tryPlaceTrap(player, target)
		local profile = DataService.get(player)
		return {
			trapsLeft = profile and profile.TrapCount,
			activeTraps = PvPService.activeTrapCount(),
		}
	end,

	pvpState = function(player)
		local PvPService = require(script.Parent.PvPService)
		local RagdollService = require(script.Parent.RagdollService)
		local profile = DataService.get(player)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local hum = player.Character and player.Character:FindFirstChildWhichIsA("Humanoid")
		return {
			trapCount = profile and profile.TrapCount,
			activeTraps = PvPService.activeTrapCount(),
			immune = RagdollService.isImmune(player),
			rooted = hum and hum:GetAttribute("Rooted") == true,
			walkSpeed = hum and hum.WalkSpeed,
			inSafeZone = root and BaseService.isSafePosition(root.Position),
			hasBat = player.Backpack:FindFirstChild("Bat") ~= nil
				or (player.Character and player.Character:FindFirstChild("Bat") ~= nil),
			hasTrapTool = player.Backpack:FindFirstChild("Trap") ~= nil
				or (player.Character and player.Character:FindFirstChild("Trap") ~= nil),
		}
	end,

	--- Moves the player to a spot, used to test safe-zone gating.
	teleport = function(player, x: number, y: number, z: number)
		local character = player.Character
		if character then
			character:PivotTo(CFrame.new(x, y, z))
		end
		task.wait(0.35)
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return {
			at = root and tostring(root.Position),
			inSafeZone = root and BaseService.isSafePosition(root.Position),
		}
	end,

	tutorial = function(player)
		local TutorialService = require(script.Parent.TutorialService)
		local profile = DataService.get(player)
		local state = TutorialService.getState(player)
		return {
			savedStage = profile and profile.TutorialStage,
			derivedStage = TutorialService.deriveStage(player),
			objective = state and state.objective,
			hint = state and state.hint,
			hasTarget = state ~= nil and state.target ~= nil,
		}
	end,

	--- Index inspection and set-completion shortcut. Completing a set the honest
	--- way costs eight successful steals, which is not a practical test loop.
	---   index()            -> the summary
	---   index("discover", 3) -> marks every Zone 3 item discovered
	---   index("claim", 3)    -> runs the real claim path, validation included
	---   index("wipe")        -> clears discoveries and claims
	index = function(player, action: string?, zoneIndex: number?)
		local IndexService = require(script.Parent.IndexService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end

		if action == "discover" then
			local pool = LootConfig.Items[zoneIndex or 1]
			if not pool then
				return { error = "no such zone" }
			end
			for _, item in pool do
				profile.Index[item.id] = true
			end
			IndexService.push(player)
			StateService.pushNow(player)
		elseif action == "claim" then
			-- Written as a statement, not an if-expression: an if-expression
			-- truncates a multi-return call to its first value, which would
			-- silently drop the refusal reason this command exists to show.
			local ok, reason
			if zoneIndex then
				ok, reason = IndexService.claimZone(player, zoneIndex)
			else
				ok, reason = IndexService.claimAll(player)
			end
			return { claimed = ok, reason = reason, income = EconomyService.getIncome(player) }
		elseif action == "wipe" then
			profile.Index = {}
			profile.ClaimedIndexRewards = {}
			EconomyService.recalculate(player)
			IndexService.push(player)
			StateService.pushNow(player)
		end

		return IndexService.summarise(player)
	end,

	--- Wipes progress the way a fresh account looks, to re-run the tutorial.
	resetTutorial = function(player)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		-- Release any in-flight carry, otherwise the next steal is refused with
		-- "already carrying" and the reset is not really a reset.
		CarryService.releaseCarry(player)
		profile.TutorialStage = 0
		profile.Index = {}
		-- Claims must go with the discoveries that earned them, or the reset
		-- leaves a permanent income multiplier standing on an empty Index.
		profile.ClaimedIndexRewards = {}
		profile.DisplayItems = {}
		profile.Cash = 0
		profile.SpeedPower = 10
		profile.BaseActivated = false
		profile.TreadmillLevel = 0
		profile.TrapCount = GameConfig.STARTING_TRAPS
		BaseService.rebuildDisplays(player)
		EconomyService.recalculate(player)
		StateService.pushNow(player)
		return { reset = true }
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

	--- Exercises the store -> inventory -> sell/equip flow through the real service.
	inventory = function(player, action: string?, argument: any)
		local PlacementService = require(script.Parent.PlacementService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end

		local ok, reason
		if action == "store" then
			ok, reason = PlacementService.store(player, argument or 1)
		elseif action == "sell" then
			ok, reason = PlacementService.sellStored(player, argument)
		elseif action == "equip" then
			ok, reason = PlacementService.equip(player, argument)
		elseif action == "upgrade" then
			ok, reason = PlacementService.upgradeStorage(player)
		end

		local stored = {}
		for _, item in profile.Inventory do
			table.insert(stored, `{item.ItemId} {item.Size}/{item.Mutation} ${item.FinalIncome}/s id={item.InstanceId:sub(1, 8)}`)
		end
		return {
			ok = ok,
			reason = reason,
			displays = #profile.DisplayItems,
			stored = stored,
			capacity = PlacementService.storageCapacity(player),
			income = EconomyService.getIncome(player),
			cash = EconomyService.getCash(player),
			firstStoredId = profile.Inventory[1] and profile.Inventory[1].InstanceId,
		}
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
