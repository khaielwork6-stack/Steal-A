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
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

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

	--- Forces the carried item onto the ground exactly as a PvP bat hit does.
	--- Exists because trySwing needs a second real Player, which a solo Studio
	--- session cannot provide - this exercises the same CarryService path the bat
	--- calls into, so the drop/reclaim rules can be tested without one.
	drop = function(player)
		local loot = CarryService.getCarried(player)
		if not loot then
			return { error = "not carrying anything" }
		end
		CarryService.forceDrop(loot)
		return {
			item = loot.name,
			state = loot.state,
			zone = loot.zoneIndex,
			socket = loot.socketIndex,
			reclaimWindow = GameConfig.DROPPED_RECLAIM_WINDOW,
		}
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

	--- Treadmill inspection and re-measurement.
	---   treadmills()            -> what the library holds vs what config expects
	---   treadmills(nil,"measure") -> raycast every model and print paste-ready
	---                                scale/deckHeight rows for TreadmillConfig
	---   treadmills(nil,"set",N)   -> jump this player to treadmill level N
	treadmills = function(player, action: string?, level: number?)
		local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
		local TreadmillModel = require(ReplicatedStorage.Shared.Util.TreadmillModel)

		if action == "set" and level then
			local profile = DataService.get(player)
			if not profile then
				return { error = "no profile" }
			end
			profile.TreadmillLevel = math.clamp(math.floor(level), 1, TreadmillConfig.MAX_LEVEL)
			profile.BaseActivated = true
			require(script.Parent.SpeedService).refreshTreadmill(player)
			StateService.pushNow(player)
			return { level = profile.TreadmillLevel, name = TreadmillConfig.tier(profile.TreadmillLevel).name }
		end

		if action == "measure" then
			-- Raycasting needs the mesh solid and in the world, so each model is
			-- measured in a scratch clone far from anything and then removed.
			local rows = {}
			for _, tier in TreadmillConfig.Tiers do
				local source = TreadmillModel.source(tier.modelKey)
				if not source then
					table.insert(rows, `{tier.modelKey} = MISSING`)
					continue
				end
				local probe = source:Clone()
				for _, d in probe:GetDescendants() do
					if d:IsA("BasePart") then
						d.Anchored, d.CanCollide, d.CanQuery = true, true, true
					end
				end
				probe.Parent = workspace
				probe:PivotTo(CFrame.new(0, 5000, 0))

				local mn, mx = TreadmillModel.worldExtents(probe)
				local size = mx - mn
				local long = math.max(size.X, size.Z)
				local scale = TreadmillConfig.STANDARD_LENGTH / long

				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Include
				params.FilterDescendantsInstances = { probe }

				local lows, RES = {}, 28
				for r = 1, RES do
					local z = mn.Z + (r - 0.5) / RES * size.Z
					for c = 1, RES do
						local x = mn.X + (c - 0.5) / RES * size.X
						local hit = workspace:Raycast(Vector3.new(x, mx.Y + 5, z), Vector3.new(0, -(size.Y + 10), 0), params)
						if hit then
							local h = hit.Position.Y - mn.Y
							-- The belt is the large FLAT LOW area; the upper half is
							-- arches, wings and handlebars.
							if h <= size.Y * 0.55 then
								table.insert(lows, h)
							end
						end
					end
				end
				table.sort(lows)
				local deck = (lows[math.max(1, math.floor(#lows * 0.5))] or 0) * scale
				probe:Destroy()

				table.insert(rows, string.format("%s = { scale = %.4f, deckHeight = %.3f },", tier.modelKey, scale, deck))
			end
			return { measured = rows }
		end

		local report = {}
		for _, tier in TreadmillConfig.Tiers do
			table.insert(report, string.format("%d %-10s art=%s", tier.level, tier.name,
				tostring(TreadmillModel.source(tier.modelKey) ~= nil)))
		end
		return { tiers = report, standardLength = TreadmillConfig.STANDARD_LENGTH,
			deckHeight = TreadmillConfig.STANDARD_DECK_HEIGHT }
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

	--- Robux receipts, which cannot be produced for real in Studio.
	---
	---   receipt("configure")                 give every treadmill product a fake id
	---   receipt("clear")                     put every id back to 0 (unconfigured)
	---   receipt("deliver", productId, purchaseId)
	---                                        hand ProcessReceipt a synthetic receipt
	---
	--- "deliver" is the only way to exercise replay safety, the unconfigured
	--- refusal and the already-maxed path.
	receipt = function(player, mode: string?, a: any, b: any)
		local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
		local MonetizationService = require(script.Parent.MonetizationService)
		local profile = DataService.get(player)

		if mode == "configure" then
			local assigned = {}
			local base = 9000000
			for key in MonetizationConfig.Products do
				base += 1
				MonetizationConfig.Products[key] = base
				assigned[key] = base
			end
			return { configured = assigned }
		elseif mode == "clear" then
			for key in MonetizationConfig.Products do
				MonetizationConfig.Products[key] = 0
			end
			return { cleared = true }
		elseif mode == "seed" then
			-- Pushes dummy ids straight into the durable list so the trim in
			-- rememberGrant can be exercised. A player can only ever make eight
			-- real treadmill purchases, so the cap is otherwise unreachable.
			if profile then
				for i = 1, tonumber(a) or 0 do
					table.insert(profile.ProcessedReceipts, "seed-" .. i)
				end
			end
			return { receiptsStored = profile and #profile.ProcessedReceipts }
		elseif mode == "setlevel" then
			if profile then
				profile.TreadmillLevel = math.clamp(tonumber(a) or 1, 0, 9)
			end
			return { treadmillLevel = profile and profile.TreadmillLevel }
		elseif mode == "deliver" then
			local decision = MonetizationService.processReceipt({
				PlayerId = player.UserId,
				ProductId = tonumber(a) or 0,
				PurchaseId = tostring(b),
				CurrencySpent = 0,
				CurrencyType = Enum.CurrencyType.Robux,
				PlaceIdWherePurchased = game.PlaceId,
			})
			return {
				decision = decision.Name,
				treadmillLevel = profile and profile.TreadmillLevel,
				receiptsStored = profile and #profile.ProcessedReceipts,
			}
		end

		-- Default: report the current state.
		local ids = {}
		for key, id in MonetizationConfig.Products do
			table.insert(ids, `{key}={id}`)
		end
		table.sort(ids)
		local nextId, nextKey, nextLevel = MonetizationService.nextTreadmillProduct(player)
		return {
			products = ids,
			treadmillLevel = profile and profile.TreadmillLevel,
			receiptsStored = profile and #profile.ProcessedReceipts,
			nextProductId = nextId,
			nextProductKey = nextKey,
			nextLevel = nextLevel,
		}
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

	-- ==========================================================
	-- ECONOMY / SPAWN PACING TEST BRIDGE
	-- ==========================================================

	--- Runs the real global refresh immediately, jackpot roll and all.
	---   Invoke("refresh")            one refresh now
	---   Invoke("refresh", nil, "warn")  fire the countdown first
	refresh = function(_player, mode: string?)
		if mode == "warn" then
			LootService.refreshWarning()
		end
		local before = LootService.occupancy()
		local report = LootService.refreshAll()
		local after = LootService.occupancy()
		return {
			before = before,
			after = after,
			rerolled = report.rerolled,
			filled = report.filled,
			preservedInSocket = report.preservedInSocket,
			jackpot = if report.jackpot
				then `{report.jackpot.name} [{report.jackpot.rarity}] zone {report.jackpot.zoneIndex} socket {report.jackpot.socketIndex}`
				else nil,
		}
	end,

	--- Socket occupancy right now. Used by the "the socket MUST still be empty"
	--- test - steal something, wait, and confirm this does not go back up.
	occupancy = function()
		return LootService.occupancy()
	end,

	--- Forces a jackpot injection regardless of the 10% roll, to exercise the
	--- placement and announcement path without waiting for luck.
	forceJackpot = function()
		local loot = LootService.injectJackpot()
		if not loot then
			return { error = "no eligible zone/socket" }
		end
		LootService.onJackpot(loot)
		return {
			item = loot.name,
			rarity = loot.rarity,
			zone = loot.zoneIndex,
			socket = loot.socketIndex,
			size = loot.size,
			mutation = loot.mutation,
			income = loot.finalIncome,
		}
	end,

	--- Statistical check on the WORLD-LEVEL jackpot roll. Counts how many of
	--- `trials` refreshes would inject a jackpot, WITHOUT touching the world.
	---   Invoke("jackpotSim", nil, 20000)
	jackpotSim = function(_player, trials: number?)
		local n = math.floor(trials or 20000)
		local hits = 0
		for _ = 1, n do
			if math.random() < GameConfig.JACKPOT_REFRESH_CHANCE then
				hits += 1
			end
		end
		return {
			trials = n,
			hits = hits,
			observed = hits / n,
			configured = GameConfig.JACKPOT_REFRESH_CHANCE,
			note = "one roll per WORLD refresh, never one per socket",
		}
	end,

	--- Statistical check on the normal per-socket roller, run against the LIVE
	--- rollItem with nothing excluded - so what comes out is the raw weight curve
	--- rather than the without-replacement one four occupied sockets produce.
	---
	--- "expected" is the weight table renormalised over the tiers this zone's
	--- normal pool actually contains. Zones 5-12 map one item to each of the
	--- seven tiers and should land on 35/27/18/11/6/2.5/0.5 exactly. Zones 1-4
	--- top out at Cosmic (their Cosmic item IS the jackpot and is excluded), so
	--- that 0.5% has nowhere to go and is redistributed - and those zones carry
	--- two Common items sharing the 35%.
	---   Invoke("raritySim", nil, 5, 200000)
	raritySim = function(_player, zoneIndex: number?, trials: number?)
		local zone = math.floor(zoneIndex or 5)
		local n = math.floor(trials or 200000)

		local pool = LootConfig.normalPool(zone)
		local weightTotal = 0
		local expectedByRarity: { [string]: number } = {}
		for _, item in pool do
			local weight = RarityConfig.NormalWeights[item.rarity] or 0
			weightTotal += weight
			expectedByRarity[item.rarity] = (expectedByRarity[item.rarity] or 0) + weight
		end

		local counts: { [string]: number } = {}
		local jackpotHits = 0
		local jackpot = LootConfig.jackpotFor(zone)
		local jackpotId = if jackpot then jackpot.id else nil

		-- Empty exclusion set: measure the roller, not the live socket state.
		local none: { [string]: boolean } = {}
		for _ = 1, n do
			local def = LootService.rollItem(zone, none)
			if def then
				counts[def.rarity] = (counts[def.rarity] or 0) + 1
				if def.id == jackpotId then
					jackpotHits += 1
				end
			end
		end

		local rows = {}
		local worstDelta = 0
		for _, rarity in RarityConfig.Order do
			local expected = 100 * (expectedByRarity[rarity] or 0) / weightTotal
			local observed = 100 * (counts[rarity] or 0) / n
			if expected > 0 or observed > 0 then
				worstDelta = math.max(worstDelta, math.abs(observed - expected))
				table.insert(rows, string.format(
					"%-10s observed %6.3f%%  expected %6.3f%%  delta %+.3f",
					rarity,
					observed,
					expected,
					observed - expected
				))
			end
		end

		return {
			zone = zone,
			trials = n,
			distribution = rows,
			worstDeltaPercentagePoints = worstDelta,
			jackpotsFromNormalRolls = jackpotHits,
			note = "jackpotsFromNormalRolls MUST be 0",
		}
	end,

	--- Dumps the resolved economy for one zone, or the anchors for all twelve.
	---   Invoke("economy", nil, 1)   zone 1 in full
	---   Invoke("economy")           every zone's first/last item
	economy = function(_player, zoneIndex: number?)
		if zoneIndex then
			local rows = {}
			for _, item in LootConfig.Items[math.floor(zoneIndex)] or {} do
				table.insert(rows, string.format(
					"%d. %-22s %-10s %12s%s",
					item.position,
					item.name,
					item.rarity,
					NumberFormat.income(item.income),
					if item.jackpot then "  JACKPOT" else ""
				))
			end
			return rows
		end

		local rows = {}
		for index = 1, ZoneConfig.COUNT do
			local pool = LootConfig.Items[index]
			local jackpot = LootConfig.jackpotFor(index)
			table.insert(rows, string.format(
				"Zone %2d %-18s worst %12s   jackpot %-10s %14s",
				index,
				ZoneConfig.Zones[index].name,
				NumberFormat.income(pool[1].income),
				jackpot.rarity,
				NumberFormat.income(jackpot.income)
			))
		end
		return rows
	end,

	--- Data-migration test. Writes a deliberately STALE trophy straight into the
	--- profile - old economy income, an obsolete mutation id, a wrong rarity -
	--- then runs the same reconcile path a real load takes, twice, and reports
	--- whether the values landed on the new economy and then stayed put.
	---   Invoke("migrationTest")
	migrationTest = function(player)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end

		local stale = {
			InstanceId = HttpService:GenerateGUID(false),
			ItemId = "Museum_AncientVase",
			ZoneId = 99,
			Rarity = "Legendary",
			Size = "Normal",
			Mutation = "Neon", -- retired name; must map to Flaming
			BaseIncome = 967,
			FinalIncome = 967,
			SlotIndex = 0,
		}

		local firstChanged = DataService.reconcileItem(stale)
		local afterFirst = {
			base = stale.BaseIncome,
			final = stale.FinalIncome,
			rarity = stale.Rarity,
			mutation = stale.Mutation,
			zone = stale.ZoneId,
		}

		local secondChanged = DataService.reconcileItem(stale)
		local afterSecond = {
			base = stale.BaseIncome,
			final = stale.FinalIncome,
			rarity = stale.Rarity,
			mutation = stale.Mutation,
			zone = stale.ZoneId,
		}

		local def = LootConfig.ById["Museum_AncientVase"]
		local expectedFinal = RarityConfig.finalIncome(def.income, "Normal", "Flaming")

		return {
			firstPassChanged = firstChanged,
			secondPassChanged = secondChanged,
			afterFirst = afterFirst,
			afterSecond = afterSecond,
			expectedBase = def.income,
			expectedFinal = expectedFinal,
			idempotent = secondChanged == false,
			correct = stale.BaseIncome == def.income
				and stale.FinalIncome == expectedFinal
				and stale.Rarity == def.rarity
				and stale.Mutation == "Flaming"
				and stale.ZoneId == 1,
		}
	end,

	--- Progression model. Answers the question the Cash rebalance actually has to
	--- answer: with the new incomes, does the treadmill ladder still get paid for?
	---
	--- For each zone it computes the EXPECTED income of one ordinary socket roll
	--- (rarity weights renormalised over that zone's normal pool, times the mean
	--- Size and Mutation multipliers), scales it to a full display base, and then
	--- reports how long that base takes to pay for each treadmill tier and how
	--- long that tier takes to walk to each zone's Speed gate.
	---
	--- Jackpots are deliberately EXCLUDED from this model: it is the floor, not
	--- the expected experience. A single Cursed Coin beats this entire table.
	progressionSim = function(_player, slots: number?)
		local displaySlots = math.floor(slots or GameConfig.STARTING_DISPLAY_SLOTS)

		local meanSize = 0
		for _, v in RarityConfig.Sizes do
			meanSize += (v.chance / 100) * v.multiplier
		end
		local meanMutation = 0
		for _, v in RarityConfig.Mutations do
			meanMutation += (v.chance / 100) * v.multiplier
		end
		local variantFactor = meanSize * meanMutation

		local zoneRows = {}
		local perSlot: { number } = {}
		for zoneIndex = 1, ZoneConfig.COUNT do
			local pool = LootConfig.normalPool(zoneIndex)
			local total, expected = 0, 0
			for _, item in pool do
				total += RarityConfig.NormalWeights[item.rarity] or 0
			end
			for _, item in pool do
				local weight = RarityConfig.NormalWeights[item.rarity] or 0
				expected += (weight / total) * item.income
			end
			expected *= variantFactor
			perSlot[zoneIndex] = expected

			local jackpot = LootConfig.jackpotFor(zoneIndex)
			table.insert(zoneRows, string.format(
				"Zone %2d %-18s  ordinary roll %12s   full base %12s   jackpot x%.0f",
				zoneIndex,
				ZoneConfig.Zones[zoneIndex].name,
				NumberFormat.income(expected),
				NumberFormat.income(expected * displaySlots),
				jackpot.income / math.max(expected / variantFactor, 1)
			))
		end

		--- Seconds to bank `cost` on a full base of zone-N loot.
		local function secondsFor(cost: number, zoneIndex: number): number
			local rate = perSlot[zoneIndex] * displaySlots
			return if rate > 0 then cost / rate else math.huge
		end

		local function pretty(seconds: number): string
			if seconds ~= seconds or seconds == math.huge then
				return "never"
			elseif seconds < 90 then
				return string.format("%.0fs", seconds)
			elseif seconds < 5400 then
				return string.format("%.1f min", seconds / 60)
			elseif seconds < 86400 * 2 then
				return string.format("%.1f h", seconds / 3600)
			end
			return string.format("%.1f days", seconds / 86400)
		end

		-- Which zone a player is plausibly looting when they buy each tier: the
		-- highest zone whose Speed gate they have already cleared.
		local treadmillRows = {}
		local speed = GameConfig.STARTING_SPEED_POWER
		for level = 2, TreadmillConfig.MAX_LEVEL do
			local tier = TreadmillConfig.Tiers[level]
			local lootZone = 1
			for _, zone in ZoneConfig.Zones do
				if speed >= zone.recommendedSpeed then
					lootZone = zone.index
				end
			end
			table.insert(treadmillRows, string.format(
				"Lvl %d %-10s %12s   earned in %-10s on zone %2d loot   then +%s Speed/s",
				level,
				tier.name,
				NumberFormat.cash(tier.cost),
				pretty(secondsFor(tier.cost, lootZone)),
				lootZone,
				NumberFormat.short(TreadmillConfig.gainPerSecond(level))
			))
			-- Assume they then train to the next gate they can reach.
			for _, zone in ZoneConfig.Zones do
				if zone.recommendedSpeed > speed then
					speed = zone.recommendedSpeed
					break
				end
			end
		end

		-- Pure training time to each gate, at the tier a player is likely to hold.
		local gateRows = {}
		local from = GameConfig.STARTING_SPEED_POWER
		for _, zone in ZoneConfig.Zones do
			if zone.recommendedSpeed <= 0 then
				continue
			end
			local level = math.min(zone.index, TreadmillConfig.MAX_LEVEL)
			local rate = TreadmillConfig.gainPerSecond(level)
			table.insert(gateRows, string.format(
				"Gate %-18s %10s Speed   %-10s at Lvl %d (+%s/s)",
				zone.name,
				NumberFormat.short(zone.recommendedSpeed),
				pretty((zone.recommendedSpeed - from) / math.max(rate, 1)),
				level,
				NumberFormat.short(rate)
			))
			from = zone.recommendedSpeed
		end

		return {
			displaySlots = displaySlots,
			meanSizeMultiplier = meanSize,
			meanMutationMultiplier = meanMutation,
			zones = zoneRows,
			treadmills = treadmillRows,
			speedGates = gateRows,
			note = "ordinary loot only - jackpots are excluded, they are the upside",
		}
	end,

	--- Audits the Index rewards against the CURRENT economy, which is the check
	--- the rebalance needs: the rewards are ratios, so they should have scaled
	--- down with it rather than becoming a billion-dollar bypass.
	indexAudit = function()
		local IndexConfig = require(ReplicatedStorage.Shared.Config.IndexConfig)
		local rows = {}
		local firstTreadmill = TreadmillConfig.Tiers[2].cost

		for index = 1, ZoneConfig.COUNT do
			local reward = IndexConfig.zoneReward(index)
			local setIncome = 0
			for _, item in LootConfig.Items[index] do
				setIncome += item.income
			end
			table.insert(rows, string.format(
				"Zone %2d  set %12s   claim %12s (= %.0fs of the set, %.1fx the $15K upgrade)   +%s Speed",
				index,
				NumberFormat.income(setIncome),
				NumberFormat.cash(reward.cash),
				if setIncome > 0 then reward.cash / setIncome else 0,
				reward.cash / firstTreadmill,
				NumberFormat.short(reward.speed)
			))
		end

		local completionist = IndexConfig.completionistReward()
		return {
			cashSeconds = IndexConfig.CASH_SECONDS,
			speedFraction = IndexConfig.SPEED_FRACTION,
			zones = rows,
			completionistCash = NumberFormat.cash(completionist.cash),
			completionistSpeed = NumberFormat.short(completionist.speed),
			topTreadmillCost = NumberFormat.cash(TreadmillConfig.Tiers[TreadmillConfig.MAX_LEVEL].cost),
			maxIncomeMultiplier = IndexConfig.incomeMultiplier((function()
				local all = {}
				for index = 1, ZoneConfig.COUNT do
					all[IndexConfig.zoneKey(index)] = true
				end
				all[IndexConfig.ALL_ZONES_KEY] = true
				return all
			end)()),
		}
	end,

	--- Inspects, resets, or attacks the one-time tutorial Cash bridge.
	---   Invoke("bridge")                report the flag
	---   Invoke("bridge", nil, "reset")  clear it, to re-run onboarding
	---   Invoke("bridge", nil, "spam", 50)
	---        hammer the real grant path 50 times and report the total paid out,
	---        which must be 0 once the flag is set. This has to run in the SERVER
	---        VM - a require from the command bar gets a fresh module with an
	---        empty profile table and would report a meaningless zero.
	bridge = function(player, mode: string?, times: number?)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end

		if mode == "reset" then
			profile.TutorialBridgeGranted = false
		elseif mode == "spam" then
			local PlacementService = require(script.Parent.PlacementService)
			local before = profile.Cash
			local paid = 0
			for _ = 1, math.floor(times or 50) do
				paid += PlacementService.grantTutorialBridge(player)
			end
			return {
				attempts = math.floor(times or 50),
				totalPaidOut = paid,
				cashBefore = before,
				cashAfter = profile.Cash,
				granted = profile.TutorialBridgeGranted,
			}
		end

		return {
			granted = profile.TutorialBridgeGranted,
			cash = profile.Cash,
			target = GameConfig.TUTORIAL_CASH_BRIDGE,
		}
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
