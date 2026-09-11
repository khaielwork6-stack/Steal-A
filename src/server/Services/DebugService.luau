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
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
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

	--- THE PARITY TOOL. Rolls the live roller with a seeded Random and reports
	--- per-socket odds, at-least-once-in-five, occurrences/hour, income
	--- percentiles, time-to-cash / time-to-Speed by cohort, every Cash source
	--- and every BLOCKED value. Prints a summary and returns the full table.
	---   paritySim()                    1,000,000 rolls per parity zone
	---   paritySim(200000)              fewer rolls
	---   paritySim(200000, true)        include the post-game zone (flagged)
	paritySim = function(_player, rolls: number?, includePostgame: boolean?)
		local ParitySim = require(script.Parent.ParitySim)
		local result = ParitySim.run({ rolls = tonumber(rolls), includePostgame = includePostgame == true })
		ParitySim.print(result)
		return result
	end,

	--- THE REGRESSION SUITE: config validation, the locked mutation snapshot,
	--- Night-never-modifies, the save migration, the income funnel and the
	--- number formatter. Prints every failure and returns the report.
	economyTests = function()
		local EconomyTests = require(script.Parent.EconomyTests)
		return EconomyTests.run()
	end,

	-- ==========================================================
	-- MYSTERY / HATCH TEST BRIDGE
	-- ==========================================================

	--- Every sealed container on this player's base, with the SECRET the
	--- client is never told, so a test can prove the reward survived the
	--- steal, the escape and the wait unchanged.
	---   sealed()
	sealed = function(player)
		local HatchService = require(script.Parent.HatchService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local rows = {}
		for _, item in profile.DisplayItems do
			if item.Hatched == false then
				table.insert(rows, string.format(
					"slot%d %s [%s] %s s=%.4f/%s  ready in %s  income-if-hatched %s  token=%s",
					item.SlotIndex, item.ItemId, item.Rarity, item.Size, item.Scale, item.Mutation,
					HatchService.formatRemaining(HatchService.remaining(item)),
					NumberFormat.income(item.FinalIncome),
					tostring(item.SpawnToken and string.sub(item.SpawnToken, 1, 8))
				))
			end
		end
		return { sealed = rows, income = EconomyService.getIncome(player) }
	end,

	--- Fast-forwards one sealed container so a long hatch can be tested
	--- without waiting hours:   ripen()  /  ripen(slotIndex)
	ripen = function(player, slotIndex: number?)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local touched = {}
		for _, item in profile.DisplayItems do
			if item.Hatched == false and (slotIndex == nil or item.SlotIndex == slotIndex) then
				item.HatchEndsAt = os.time() - 1
				table.insert(touched, item.SlotIndex)
			end
		end
		BaseService.rebuildDisplays(player)
		StateService.pushNow(player)
		return { ripened = touched }
	end,

	--- Runs the real hatch commit, exactly as the remote does:
	---   hatch()             the first ready container
	---   hatch(slotIndex)    that slot
	hatch = function(player, slotIndex: number?)
		local HatchService = require(script.Parent.HatchService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local target = nil
		for _, item in profile.DisplayItems do
			if item.Hatched == false and (slotIndex == nil or item.SlotIndex == slotIndex) then
				target = item
				break
			end
		end
		if not target then
			return { error = "no sealed container" }
		end
		local before = EconomyService.getIncome(player)
		local ok, reason = HatchService.commit(player, target.InstanceId)
		-- Fire it a SECOND time to prove a replay pays nothing.
		local okAgain, reasonAgain = HatchService.commit(player, target.InstanceId)
		return {
			hatched = ok,
			reason = reason,
			replayAccepted = okAgain,
			replayReason = reasonAgain,
			item = target.ItemId,
			rarity = target.Rarity,
			size = target.Size,
			mutation = target.Mutation,
			incomeBefore = before,
			incomeAfter = EconomyService.getIncome(player),
			itemIncome = target.FinalIncome,
			indexed = profile.Index[target.ItemId] == true,
		}
	end,

	--- The container-size roll, per zone, against its configured odds. Proves
	--- every roll returns exactly one variant, that no variant is impossible,
	--- and that the early zones really are stingier than the endgame ones.
	---   sizeOdds()          all twelve zones, 200k rolls each
	---   sizeOdds(nil, n)    n rolls each
	sizeOdds = function(_player, trials: number?)
		local n = math.clamp(tonumber(trials) or 200000, 1000, 1000000)
		local rng = Random.new(20260909)
		local rows = {}
		local worst = 0
		for zoneIndex = 1, ZoneConfig.COUNT do
			local counts: { [string]: number } = {}
			local invalid = 0
			for _ = 1, n do
				local scale = ScaleConfig.rollScale(zoneIndex, rng)
				local label = RarityConfig.sizeLabelFor(scale)
				if not RarityConfig.SizeById[label] then
					invalid += 1
				end
				counts[label] = (counts[label] or 0) + 1
			end
			local odds = ScaleConfig.variantOdds(zoneIndex)
			local parts = {}
			local rolled = 0
			for _, variant in ScaleConfig.Variants do
				local observed = (counts[variant.id] or 0) / n * 100
				local expected = (odds[variant.id] or 0) * 100
				worst = math.max(worst, math.abs(observed - expected))
				rolled += counts[variant.id] or 0
				table.insert(parts, string.format("%s %.3f/%.3f", string.sub(variant.id, 1, 4), observed, expected))
			end
			table.insert(rows, string.format("Z%02d %-8s %s  invalid=%d missing=%d",
				zoneIndex, ScaleConfig.bandFor(zoneIndex).id, table.concat(parts, "  "), invalid, n - rolled))
		end
		return { trials = n, worstDeltaPercentagePoints = worst, zones = rows }
	end,

	--- The trap cooldown, end to end:  traps()  reports; traps("place")
	--- places one;  traps("reset")  clears the cooldown.
	traps = function(player, mode: string?)
		local PvPService = require(script.Parent.PvPService)
		local PvPConfig = require(ReplicatedStorage.Shared.Config.PvPConfig)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		if mode == "place" then
			PvPService.tryPlaceTrap(player, nil)
		elseif mode == "reset" then
			profile.TrapReadyAt = 0
		elseif mode == "refill" then
			-- Back-dates the refill stamp so the clip comes back on the next
			-- sweep, rather than making the tester wait two minutes for it.
			profile.TrapReadyAt = os.time() - 1
			task.wait(1.2)
		elseif mode == "expire" then
			-- Back-dates the live traps past TRAP_LIFETIME and lets one sweep
			-- run, so the expiry is observed rather than assumed.
			PvPService.debugAgeTraps(PvPConfig.TRAP_LIFETIME + 1)
			task.wait(0.5)
		end
		return {
			trapCount = profile.TrapCount,
			trapReadyAt = profile.TrapReadyAt,
			cooldownRemaining = PvPService.trapCooldownRemaining(player),
			canPlace = PvPService.canPlaceTrap(player),
			activeInWorld = PvPService.activeTrapCount(),
			configuredCooldown = PvPConfig.TRAP_COOLDOWN,
			configuredLifetime = PvPConfig.TRAP_LIFETIME,
		}
	end,

	--- The Scientist (and every other guardian) against a carrying thief.
	--- Reports the real chase speed beside the thief's real WalkSpeed for a
	--- range of Speed stats and carried sizes, so the sign can be checked
	---   guardianAudit()  /  guardianAudit(nil, zoneIndex)
	guardianAudit = function(_player, zoneIndex: number?)
		local GuardianService = require(script.Parent.GuardianService)
		local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
		local zone = math.floor(zoneIndex or 9)
		local def = ZoneConfig.Zones[zone]
		local rows = {}
		local sizes = { "Normal", "Big", "Huge", "Giant", "Titan", "Colossal" }
		local powers = { def.recommendedSpeed * 0.5, def.recommendedSpeed * 0.75, def.recommendedSpeed, def.recommendedSpeed * 1.43, def.recommendedSpeed * 2.86, def.recommendedSpeed * 4.29 }
		for _, power in powers do
			local parts = {}
			for _, sizeId in sizes do
				local size = RarityConfig.SizeById[sizeId]
				local penalty = if size and size.movePenalty then size.movePenalty else 0
				local thief = GameConfig.walkSpeedFromPower(power) * (1 - penalty)
				local guard = GuardianService.speedForChase(zone, power, penalty)
				table.insert(parts, string.format("%s %+.1f", string.sub(sizeId, 1, 4), thief - guard))
			end
			table.insert(rows, string.format("%14s  %s", NumberFormat.short(power), table.concat(parts, "  ")))
		end
		return {
			zone = zone,
			name = def.name,
			recommended = NumberFormat.short(def.recommendedSpeed),
			runDistance = math.floor(MapConfig.zoneCenterZ(zone)),
			note = "margin = thief WalkSpeed minus guardian chase speed; positive escapes",
			rows = rows,
		}
	end,

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

	--- THE REJOIN, without one. Serialises this player's live profile exactly
	--- as a DataStore would, reads it back, and runs the real migrate and
	--- reconcile over it - so a hatch deadline that would not survive a save,
	--- a shutdown or a rejoin fails here instead of on a live server.
	---   persistTest()
	persistTest = function(player)
		local HatchService = require(script.Parent.HatchService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end

		local before = {}
		for _, item in profile.DisplayItems do
			before[item.InstanceId] = {
				hatched = item.Hatched,
				endsAt = item.HatchEndsAt,
				remaining = HatchService.remaining(item),
				token = item.SpawnToken,
				scale = item.Scale,
				income = item.FinalIncome,
			}
		end
		local trapBefore = profile.TrapReadyAt

		-- The round trip a DataStore really performs: encode, decode, migrate,
		-- reconcile. JSON is where a nil, a NaN or an infinity would be lost.
		local encoded = HttpService:JSONEncode(profile)
		local decoded = HttpService:JSONDecode(encoded)
		local restored = DataService.migrate(decoded)
		DataService.reconcile(restored)

		local rows = {}
		local mismatches = {}
		for _, item in restored.DisplayItems do
			local was = before[item.InstanceId]
			if not was then
				table.insert(mismatches, `{item.InstanceId} appeared from nowhere`)
				continue
			end
			if item.Hatched ~= was.hatched then
				table.insert(mismatches, `{item.InstanceId} hatch flag {tostring(was.hatched)} -> {tostring(item.Hatched)}`)
			end
			if item.HatchEndsAt ~= was.endsAt then
				table.insert(mismatches, `{item.InstanceId} deadline {tostring(was.endsAt)} -> {tostring(item.HatchEndsAt)}`)
			end
			if item.SpawnToken ~= was.token then
				table.insert(mismatches, `{item.InstanceId} token changed`)
			end
			if item.Scale ~= was.scale or item.FinalIncome ~= was.income then
				table.insert(mismatches, `{item.InstanceId} reward changed`)
			end
			before[item.InstanceId] = nil
			table.insert(rows, string.format(
				"slot%d %s hatched=%s ready in %s (was %s)",
				item.SlotIndex, item.ItemId, tostring(item.Hatched),
				HatchService.formatRemaining(HatchService.remaining(item)),
				HatchService.formatRemaining(was.remaining)
			))
		end
		for id in before do
			table.insert(mismatches, `{id} was lost in the save`)
		end
		if restored.TrapReadyAt ~= trapBefore then
			table.insert(mismatches, `trap cooldown {tostring(trapBefore)} -> {tostring(restored.TrapReadyAt)}`)
		end

		return {
			bytes = #encoded,
			schemaVersion = restored.SchemaVersion,
			survived = #mismatches == 0,
			mismatches = mismatches,
			items = rows,
			trapReadyAt = restored.TrapReadyAt,
		}
	end,

	--- INSTANT REVEAL through the real receipt path. Selects the container on
	--- slotIndex, saves the pending purchase the way the prompt would (the
	--- Studio dialog cannot complete a purchase), then delivers a synthetic
	--- receipt through the live MonetizationService.processReceipt - which
	--- calls HatchService.fulfil, marks the container ready and commits it.
	---   instantReveal(slotIndex)                the tier for its remaining time
	---   instantReveal(slotIndex, purchaseId)    replay a specific receipt id
	---   instantReveal(slotIndex, nil, productId) deliver a wrong-tier receipt
	instantReveal = function(player, slotIndex: number, purchaseId: string?, forcedProductId: number?)
		local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
		local MonetizationService = require(script.Parent.MonetizationService)
		local HatchService = require(script.Parent.HatchService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local target = nil
		for _, item in profile.DisplayItems do
			if item.SlotIndex == slotIndex then
				target = item
				break
			end
		end
		if not target then
			return { error = "nothing on that slot" }
		end
		local remaining = HatchService.remaining(target)
		local product = MonetizationConfig.revealProductFor(remaining)
		local productId = forcedProductId or (product and product.productId) or 0
		if not forcedProductId and product then
			profile.PendingReveal = { instanceId = target.InstanceId, productId = product.productId }
		end
		local id = purchaseId or ("test-reveal-" .. HttpService:GenerateGUID(false))
		local decision = MonetizationService.processReceipt({
			PlayerId = player.UserId,
			ProductId = productId,
			PurchaseId = id,
			CurrencySpent = product and product.robux or 0,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = game.PlaceId,
		})
		return {
			remainingBefore = remaining,
			tier = product and product.key,
			productId = productId,
			purchaseId = id,
			decision = tostring(decision),
			hatched = target.Hatched,
			pendingCleared = profile.PendingReveal == nil,
			income = EconomyService.getIncome(player),
		}
	end,

	--- Lets the opening popup be observed again:   introReset()
	introReset = function(player)
		local TutorialService = require(script.Parent.TutorialService)
		TutorialService.resetIntro(player)
		return { reset = true }
	end,

	--- Puts SEALED containers on the base the way PlacementService does, so the
	--- incubation, the base rebuild and the hatch can be tested without running
	--- a steal per container:
	---   sealGrant(itemId, count?, scale?, mutation?)
	sealGrant = function(player, itemId: string, count: number?, scale: number?, mutation: string?)
		local HatchService = require(script.Parent.HatchService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local def = LootConfig.ById[itemId]
		if not def then
			return { error = `unknown ItemId "{itemId}"` }
		end
		local wanted = math.clamp(math.floor(tonumber(count) or 1), 1, 24)
		local rolled = ScaleConfig.clampScale(tonumber(scale) or ScaleConfig.rollScale(LootConfig.ZoneOf[def.id]))
		local mutationId = mutation or "Normal"
		local placed = {}
		for _ = 1, wanted do
			local free = BaseService.freeSlots(player)
			if #free == 0 then
				break
			end
			local item = {
				InstanceId = HttpService:GenerateGUID(false),
				ItemId = def.id,
				ZoneId = LootConfig.ZoneOf[def.id],
				Rarity = def.rarity,
				Size = RarityConfig.sizeLabelFor(rolled),
				Mutation = mutationId,
				BaseIncome = def.income,
				FinalIncome = RarityConfig.finalIncome(def.income, rolled, mutationId),
				SlotIndex = free[1],
				Scale = rolled,
				VisualScale = rolled,
				SizeVisualVersion = RarityConfig.SIZE_VISUAL_VERSION,
				EconomyScaleVersion = ScaleConfig.ECONOMY_SCALE_VERSION,
				MaturationSeconds = ScaleConfig.maturationSeconds(def.growthSeconds, rolled),
				GrowthSeconds = 0,
				Hatched = false,
				SpawnToken = HttpService:GenerateGUID(false),
			}
			table.insert(profile.DisplayItems, item)
			HatchService.beginIncubation(player, item)
			table.insert(placed, { slot = item.SlotIndex, id = item.InstanceId, endsAt = item.HatchEndsAt })
		end
		BaseService.rebuildDisplays(player)
		EconomyService.recalculate(player)
		StateService.pushNow(player)
		return {
			sealed = #placed,
			slots = placed,
			size = RarityConfig.sizeLabelFor(rolled),
			scale = rolled,
			income = EconomyService.getIncome(player),
			freeSlotsLeft = #BaseService.freeSlots(player),
		}
	end,

	--- Fires the REAL HatchRequest handler `times` in a burst, from the server,
	--- to prove the rate limiter and the commit guard together let exactly one
	--- reward through:   spamHatch(instanceId?, times?)
	spamHatch = function(player, instanceId: string?, times: number?)
		local HatchService = require(script.Parent.HatchService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local target = instanceId
		if not target then
			for _, item in profile.DisplayItems do
				if item.Hatched == false then
					target = item.InstanceId
					break
				end
			end
		end
		if not target then
			return { error = "no sealed container" }
		end
		local burst = math.clamp(math.floor(tonumber(times) or 20), 1, 200)
		local accepted, refused = 0, 0
		local reasons: { [string]: number } = {}
		-- Same frame, no yields: this is the two-players-one-container race and
		-- the button-masher, in the shape the server actually sees them.
		for _ = 1, burst do
			local ok, reason = HatchService.commit(player, target :: string)
			if ok then
				accepted += 1
			else
				refused += 1
				local key = reason or "(silent)"
				reasons[key] = (reasons[key] or 0) + 1
			end
		end
		return {
			burst = burst,
			accepted = accepted,
			refused = refused,
			reasons = reasons,
			income = EconomyService.getIncome(player),
		}
	end,

	--- grant(itemId, size?, mutation?, visualScale?) - an exact scale inside the
	--- tier's range may be pinned (a 20x Colossal for a screenshot); otherwise
	--- one is rolled exactly as a real spawn would.
	grant = function(player, itemId: string, size: string?, mutation: string?, visualScale: number?)
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

		-- `size` is the economy SCALE (a number); a size word is accepted and
		-- mapped to the low edge of its label for convenience.
		local labelToScale = { Normal = 1, Big = 1.5, Huge = 3, Giant = 6, Titan = 10, Colossal = 20 }
		local scale = ScaleConfig.clampScale(tonumber(size) or (if type(size) == "string" then labelToScale[size] else nil) or visualScale or 1)
		local mutationId = mutation or "Normal"
		local final = RarityConfig.finalIncome(def.income, scale, mutationId)

		table.insert(profile.DisplayItems, {
			InstanceId = HttpService:GenerateGUID(false),
			ItemId = def.id,
			ZoneId = LootConfig.ZoneOf[def.id],
			Rarity = def.rarity,
			Size = RarityConfig.sizeLabelFor(scale),
			Mutation = mutationId,
			BaseIncome = def.income,
			FinalIncome = final,
			SlotIndex = free[1],
			Scale = scale,
			VisualScale = scale,
			SizeVisualVersion = RarityConfig.SIZE_VISUAL_VERSION,
			EconomyScaleVersion = ScaleConfig.ECONOMY_SCALE_VERSION,
			MaturationSeconds = ScaleConfig.maturationSeconds(def.growthSeconds, scale),
			GrowthSeconds = 0,
			-- A granted trophy is a REVEALED one. Stated rather than left nil,
			-- so a debug grant and a real hatch produce the same record.
			Hatched = true,
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

		return { placed = def.name, slot = free[1], finalIncome = final, totalIncome = income, visualScale = scale }
	end,

	--- Pins an instance of an exact SCALE into a world socket, through the real
	--- forceSocket path, so a Titan or Colossal can be met without waiting for
	--- the roll:   spawnSize(zone, socket, scale, itemId?)   (scale defaults to 20)
	spawnSize = function(_player, zoneIndex: number, socketIndex: number, scale: number?, itemId: string?)
		local socket = LootService.getSocket(zoneIndex, socketIndex)
		if not socket then
			return { error = "no such socket" }
		end
		local id = itemId or (socket.loot and socket.loot.itemId) or LootConfig.pool(zoneIndex)[1].id
		local loot = LootService.forceSocket(zoneIndex, socketIndex, id, tonumber(scale) or 20, nil)
		if not loot then
			return { error = "socket refused (mid-steal?)" }
		end
		local model = loot.model
		local minCorner: Vector3?, maxCorner: Vector3? = nil, nil
		if model then
			minCorner, maxCorner = LootModel.visibleExtents(model)
		end
		local extent = if minCorner and maxCorner then maxCorner - minCorner else Vector3.zero
		local reach = LootService.interactionPart(loot)
		return {
			item = loot.name,
			size = loot.size,
			visualScale = loot.visualScale,
			income = loot.finalIncome,
			height = extent.Y,
			footprint = math.max(extent.X, extent.Z),
			lowestY = if minCorner then minCorner.Y else nil,
			socketTopY = socket.part.Position.Y + socket.part.Size.Y / 2,
			promptOn = if reach then reach.Name else "?",
			promptY = if reach then reach.Position.Y else nil,
			interactRange = loot.interactRange,
		}
	end,

	--- THE LOOT SIZE AUDIT. Measures every registered item's authored asset
	--- (visible parts only), reports its original box, the Normal multiplier
	--- and the resulting Normal size, and prints the LootConfig.Normalization
	--- table ready to paste:   lootAudit()   /   lootAudit("rows")
	lootAudit = function(_player, mode: string?)
		local rows = LootModel.audit()
		local source = LootModel.auditTableSource(rows)
		print(source)
		local out = {}
		local counts: { [string]: number } = {}
		for _, row in rows do
			counts[row.status] = (counts[row.status] or 0) + 1
			local s = row.source
			local n = row.normal
			table.insert(out, string.format(
				"%-30s z%02d p%d %-8s src %6.2f x %6.2f x %6.2f  x%-7s  normal %6.2f x %6.2f x %6.2f",
				row.itemId, row.zone, row.position, row.status,
				if s then s.X else 0, if s then s.Y else 0, if s then s.Z else 0,
				if row.listed then string.format("%.4f", row.listed) elseif row.computed then string.format("%.4f*", row.computed) else "-",
				if n then n.X else 0, if n then n.Y else 0, if n then n.Z else 0
			))
		end
		return { items = #rows, counts = counts, rows = if mode == "rows" then out else nil, note = "* = computed on the fly (no row yet); the paste-ready table was printed to the output" }
	end,

	--- THE UPRIGHT AUDIT. Names every item whose pivot frame is not upright,
	--- which is the shape of the Vanilla Milkshake bug:  upright()
	upright = function(_player, mode: string?)
		local rows = LootModel.uprightAudit()
		local bad, out = {}, {}
		for _, row in rows do
			local line = string.format("%-30s anchor=%-22s up=%+.2f sideways=%d/%d %s",
				row.itemId, row.anchor, row.anchorUp, row.sidewaysParts, row.totalParts, row.ok and "" or "  <-- NOT UPRIGHT")
			table.insert(out, line)
			if not row.ok then
				table.insert(bad, line)
			end
		end
		return {
			items = #rows,
			notUpright = #bad,
			offenders = bad,
			all = if mode == "all" then out else nil,
		}
	end,

	-- RETIRED: scaleSim. It reported against ScaleConfig.Bands, totalWeight()
	-- and SIZE_ODDS_STATUS, none of which survived the move to the label-first
	-- zone-biased roll, and it called rollScale with the Random in the zone
	-- slot. Its job is done by sizeOdds above, which checks the same rolls
	-- against the per-zone odds they are actually drawn from.

	--- The Night cycle.
	---   night()                 status
	---   night("in", seconds)    make the current Day end in N seconds
	---   night("begin")          force Night now
	---   night("end")            force the Night to end now
	night = function(_player, action: string?, seconds: number?)
		local NightService = require(script.Parent.NightService)
		if action == "in" then
			NightService.setDayRemaining(tonumber(seconds) or 20)
		elseif action == "begin" then
			NightService.forceNight()
		elseif action == "end" then
			NightService.forceDay()
		end
		return NightService.status()
	end,

	--- Sets the growth clock on a displayed slot's item, to see the maturity
	--- bonus without waiting twenty minutes:   growth(slotIndex, seconds)
	growth = function(player, slotIndex: number, seconds: number)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		for _, item in profile.DisplayItems do
			if item.SlotIndex == slotIndex then
				item.GrowthSeconds = math.max(0, tonumber(seconds) or 0)
				BaseService.rebuildDisplays(player)
				local income = EconomyService.recalculate(player)
				StateService.pushNow(player)
				return { item = item.ItemId, growthSeconds = item.GrowthSeconds, maturationSeconds = item.MaturationSeconds, matured = EconomyService.isMatured(item), totalIncome = income }
			end
		end
		return { error = `slot {slotIndex} is empty` }
	end,

	cash = function(player, amount: number)
		EconomyService.award(player, amount, "debug")
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
			introSeen = profile and profile.TutorialIntroSeen,
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
		profile.BaseActivated = true -- always active; a base cannot be un-claimed
		profile.TreadmillLevel = 1
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

	--- Sells the item displayed in `slotIndex` the way a player would: store it
	--- first, then sell it out of Storage. There is no direct sell-from-display
	--- path in the game (PlacementService.sell was retired with it), which is
	--- why this used to error with "attempt to call a nil value".
	sell = function(player, slotIndex: number)
		local PlacementService = require(script.Parent.PlacementService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local instanceId: string? = nil
		for _, item in profile.DisplayItems do
			if item.SlotIndex == slotIndex then
				instanceId = item.InstanceId
			end
		end
		if not instanceId then
			return { sold = false, reason = `slot {slotIndex} is empty` }
		end
		local stored, storeReason = PlacementService.store(player, slotIndex)
		if not stored then
			return { sold = false, reason = storeReason }
		end
		local ok, reason = PlacementService.sellStored(player, instanceId)
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
				profile.TreadmillLevel = math.clamp(tonumber(a) or 1, 0, TreadmillConfig.MAX_LEVEL)
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
		}
	end,

	--- Socket occupancy right now. Used by the "the socket MUST still be empty"
	--- test - steal something, wait, and confirm this does not go back up.
	occupancy = function()
		return LootService.occupancy()
	end,

	--- Dumps the resolved economy for one zone, or the anchors for all twelve.
	---   Invoke("economy", nil, 1)   zone 1 in full
	---   Invoke("economy")           every zone's first/last item
	economy = function(_player, zoneIndex: number?)
		if zoneIndex then
			local rows = {}
			for _, item in LootConfig.Items[math.floor(zoneIndex)] or {} do
				table.insert(rows, string.format(
					"%d. %-22s %-10s %12s  weight %9.6f (%6.3f%%)%s",
					item.position,
					item.name,
					item.rarity,
					NumberFormat.income(item.income),
					item.weight,
					LootConfig.weightShare(item.id) * 100,
					if item.postgame then "  POSTGAME" else ""
				))
			end
			return rows
		end

		local rows = {}
		for index = 1, ZoneConfig.COUNT do
			local pool = LootConfig.Items[index]
			local top = pool[#pool]
			table.insert(rows, string.format(
				"Zone %2d %-18s worst %12s   top %-10s %14s at %6.3f%%%s",
				index,
				ZoneConfig.Zones[index].name,
				NumberFormat.income(pool[1].income),
				top.rarity,
				NumberFormat.income(top.income),
				LootConfig.weightShare(top.id) * 100,
				if ZoneConfig.isParityZone(index) then "" else "  POSTGAME"
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
		local expectedFinal = RarityConfig.finalIncome(def.income, 1, "Flaming")

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

	--- Monetization test bridge. Robux cannot be spent in Studio, so gamepass
	--- ownership is faked into the SERVER's cache (never the client's) and
	--- products are delivered as synthetic receipts through the real
	--- ProcessReceipt - the paths that must be proven are the grant and the
	--- replay, not Roblox's dialog.
	---   Invoke("monetize")                       config integrity + current state
	---   Invoke("monetize", nil, "own", "Speed8x")  fake ownership of a pass
	---   Invoke("monetize", nil, "clear")           forget all faked ownership
	monetize = function(player, action: string?, key: string?)
		local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
		local MonetizationService = require(script.Parent.MonetizationService)
		local TrailService = require(script.Parent.TrailService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end

		if action == "own" and key then
			local id
			local pass = MonetizationConfig.SpeedPassByKey[key]
			if pass then
				id = pass.gamePassId
			elseif key == "Cash2x" then
				id = MonetizationConfig.CashPass.gamePassId
			elseif MonetizationConfig.GuardianPassByKey[key] then
				id = MonetizationConfig.GuardianPassByKey[key].gamePassId
			elseif key == "Slap" then
				id = MonetizationConfig.SlapPass.gamePassId
			else
				local trail = MonetizationConfig.TrailByKey[key]
				id = trail and trail.gamePassId
			end
			if not id then
				return { error = `no gamepass for key "{key}"` }
			end
			MonetizationService.setOwnedForTesting(player, id, true)
			return { faked = key, id = id, speedMultiplier = MonetizationService.speedMultiplier(player) }
		elseif action == "clear" then
			MonetizationService.clearOwnedForTesting(player)
			return { cleared = true, speedMultiplier = MonetizationService.speedMultiplier(player) }
		elseif action == "disown" then
			-- FORCES "owns nothing", which `clear` cannot do.
			--
			-- Roblox reports the place's own creator as owning every gamepass they
			-- published, so on this account `clear` is immediately undone by the
			-- next real ownership check and the treadmill card is permanently
			-- MAXED. Pinning every pass to false is the only way to see the tier
			-- ladder the way a new player sees it.
			for _, tier in MonetizationConfig.SpeedMultiplierPasses do
				MonetizationService.setOwnedForTesting(player, tier.gamePassId, false)
			end
			MonetizationService.setOwnedForTesting(player, MonetizationConfig.CashPass.gamePassId, false)
			for _, trail in MonetizationConfig.Trails do
				if trail.gamePassId then
					MonetizationService.setOwnedForTesting(player, trail.gamePassId, false)
				end
			end
			for _, pass in MonetizationConfig.GuardianPasses do
				MonetizationService.setOwnedForTesting(player, pass.gamePassId, false)
			end
			MonetizationService.setOwnedForTesting(player, MonetizationConfig.SlapPass.gamePassId, false)
			local tier = MonetizationService.nextSpeedTier(player)
			return {
				disowned = true,
				speedMultiplier = MonetizationService.speedMultiplier(player),
				nextSpeedTierOffered = if tier then tier.label else "MAXED",
			}
		end

		-- Config integrity: every id present, non-zero and unique.
		local seen, dupes, zeros = {}, {}, {}
		local function check(label, id)
			if not id or id <= 0 then table.insert(zeros, label) end
			if seen[id] then table.insert(dupes, `{label} shares id {id} with {seen[id]}`) end
			seen[id] = label
		end
		for _, t in MonetizationConfig.SpeedMultiplierPasses do check(t.key, t.gamePassId) end
		check("Cash2x", MonetizationConfig.CashPass.gamePassId)
		for _, t in MonetizationConfig.Trails do
			if t.gamePassId then check(t.key .. "Trail", t.gamePassId) end
		end
		for id, p in MonetizationConfig.ProductById do check(p.key, id) end

		local nextTier = MonetizationService.nextSpeedTier(player)
		return {
			speedPasses = #MonetizationConfig.SpeedMultiplierPasses,
			trails = #MonetizationConfig.Trails,
			products = (function() local n = 0 for _ in MonetizationConfig.ProductById do n += 1 end return n end)(),
			duplicateIds = dupes,
			unconfiguredIds = zeros,
			speedMultiplier = MonetizationService.speedMultiplier(player),
			cashMultiplier = MonetizationService.cashMultiplier(player),
			trailMultiplier = TrailService.multiplierFor(player),
			nextSpeedTierOffered = if nextTier then `{nextTier.label} for {nextTier.robux} R$` else "MAXED",
			equippedTrail = profile.EquippedTrail,
			trailsOwnedByCash = profile.TrailsOwned,
		}
	end,

	--- The group-join gift, through the REAL claim path (membership check and
	--- all). `gift` reports; `gift claim` attempts a claim; `gift reset` clears the
	--- claimed flag so the flow can be run again in Studio.
	gift = function(player, action: string?)
		local GroupGiftService = require(script.Parent.GroupGiftService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		if action == "claim" then
			local ok, reason = GroupGiftService.tryClaim(player)
			return { granted = ok, reason = reason, speedPower = profile.SpeedPower, claimed = profile.GroupGiftClaimed }
		elseif action == "reset" then
			profile.GroupGiftClaimed = false
			return { reset = true }
		end
		local summary = GroupGiftService.summarise(player)
		return { claimed = summary.claimed, reward = summary.reward, groupId = summary.groupId, speedPower = profile.SpeedPower }
	end,

	--- Repaints the world boards now instead of on the next timer tick.
	leaderboard = function(_player)
		local LeaderboardService = require(script.Parent.LeaderboardService)
		LeaderboardService.refreshNow()
		return { refreshed = true }
	end,

	--- Fires the boss-loss offer through the real MonetizationService path for a
	--- zone, without needing a guardian to catch anyone.
	offer = function(player, zoneIndex: number?)
		local MonetizationService = require(script.Parent.MonetizationService)
		MonetizationService.offerAfterCatch(player, tonumber(zoneIndex) or 1)
		return { fired = true, zone = tonumber(zoneIndex) or 1 }
	end,

	--- The chase flag and every guardian's state, for the RUN!! warning.
	chase = function(player)
		local states = {}
		for _, model in workspace:GetDescendants() do
			if model:IsA("Model") and model:GetAttribute("State") ~= nil and model:FindFirstChildWhichIsA("Humanoid") then
				states[model.Name] = model:GetAttribute("State")
			end
		end
		return { chased = player:GetAttribute("Chased") == true, guardians = states }
	end,

	--- One guardian, in detail: state, target, pace, distance, what it carries.
	guardian = function(_player, zoneIndex: number)
		local GuardianService = require(script.Parent.GuardianService)
		local info = GuardianService.inspect(zoneIndex)
		if info and info.position then
			info.position = tostring(info.position)
		end
		return info or { error = "no such guardian" }
	end,

	--- What sits in a socket right now, by identity, so a test can prove the
	--- SAME instance came back after a catch or a drop.
	socket = function(_player, zoneIndex: number, socketIndex: number?)
		local socket = LootService.getSocket(zoneIndex, socketIndex or 1)
		if not socket then
			return { error = "no such socket" }
		end
		local loot = socket.loot
		return {
			occupied = loot ~= nil,
			id = loot and loot.id,
			name = loot and loot.name,
			state = loot and loot.state,
			modelInSocket = loot ~= nil and loot.model ~= nil and loot.model.Parent == socket.part,
		}
	end,

	--- One instance by id, wherever it is.
	lootState = function(_player, lootId: string)
		local loot = LootService.get(lootId)
		if not loot then
			return { gone = true }
		end
		local model = loot.model
		return {
			state = loot.state,
			name = loot.name,
			zone = loot.zoneIndex,
			socket = loot.socketIndex,
			modelParent = if model and model.Parent then model.Parent:GetFullName() else nil,
			position = if model and model.PrimaryPart then tostring(model.PrimaryPart.Position) else nil,
		}
	end,

	--- Buys / equips a trail through the REAL server paths, so validation,
	--- deduction and persistence are all exercised.
	trail = function(player, action: string?, key: string?)
		local TrailService = require(script.Parent.TrailService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		local ok, reason
		if action == "buy" and key then
			ok, reason = TrailService.buyWithCash(player, key)
		elseif action == "equip" and key then
			ok, reason = TrailService.equip(player, key)
		elseif action == "unequip" then
			ok, reason = TrailService.equip(player, "")
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
		return {
			ok = ok,
			reason = reason,
			cash = profile.Cash,
			equipped = profile.EquippedTrail,
			owned = profile.TrailsOwned,
			multiplier = TrailService.multiplierFor(player),
			visualAttached = root ~= nil and root:FindFirstChild("EquippedTrail") ~= nil,
			walkSpeed = if humanoid then humanoid.WalkSpeed else -1,
		}
	end,

	--- Audits EVERY zone guardian against the recommendation its sign displays.
	---
	--- This is the check the "127K outruns a 170K Santa" bug failed. For each
	--- zone it reports the guardian's WalkSpeed alongside a player at 75%, 100%
	--- and 150% of that zone's recommendation, and states who is faster. The
	--- sign must be: below loses, at the recommendation narrowly wins, above
	--- clearly wins.
	speedAudit = function()
		local rows = {}
		for index = 1, ZoneConfig.COUNT do
			local zone = ZoneConfig.Zones[index]
			local recommended = math.max(zone.recommendedSpeed, GameConfig.STARTING_SPEED_POWER)
			local guardian = require(script.Parent.GuardianService).speedForZone(index)

			-- Compared against the speed the guardian ACTUALLY runs at for a thief
			-- of that Speed, deficit catch-up included - not the static baseline.
			local function verdict(fraction: number): string
				local power = recommended * fraction
				local ws = GameConfig.walkSpeedFromPower(power)
				local chaser = require(script.Parent.GuardianService).speedForChase(index, power)
				local margin = ws - chaser
				return string.format("%5.2f vs %5.2f (%+.2f %s)", ws, chaser, margin,
					if margin > 0 then "escapes" else "CAUGHT")
			end

			table.insert(rows, string.format(
				"Zone %2d %-18s rec %8s | guard %6.2f | 75%% %s | 100%% %s | 150%% %s",
				index, zone.name, NumberFormat.short(zone.recommendedSpeed), guardian,
				verdict(0.75), verdict(1.0), verdict(1.5)))
		end
		return {
			gateMargin = ZoneConfig.GUARDIAN_GATE_MARGIN,
			deficitCatchup = ZoneConfig.GUARDIAN_DEFICIT_CATCHUP,
			wakeDelay = GameConfig.GUARDIAN_WAKE_DELAY,
			rows = rows,
			rule = "75% must be CAUGHT, 100% must escape (narrowly), 150% must escape clearly",
		}
	end,

	--- The physical-movement curve, old versus new, so the progression feel can
	--- be checked without guessing.
	speedCurve = function()
		local rows = {}
		local samples = { 10, 100, 900, 10e3, 40e3, 127e3, 170e3, 700e3, 2.5e6, 18e6, 700e6, 2.5e9, 7e9, 20e9, 100e9 }
		for _, power in samples do
			-- What the previous (boosted) curve produced, for comparison.
			local old = GameConfig.legacyWalkSpeedFromPower(power)
			local new = GameConfig.walkSpeedFromPower(power)
			table.insert(rows, string.format(
				"Speed %10s | was %6.2f | now %6.2f | x%.3f | progression %3.0f%%",
				NumberFormat.short(power), old, new, new / old, GameConfig.progressionAlpha(power) * 100))
		end
		return rows
	end,

	--- Sets SpeedPower directly, so the "a player below the gate gets caught, a
	--- player at the gate escapes" acceptance test can be run without grinding a
	--- treadmill for it. Server-side only, exactly like every other grant.
	--- The Night, on demand: `night begin` / `night end`, else the status.
	night = function(_player, action: string?)
		local NightService = require(script.Parent.NightService)
		if action == "begin" then
			NightService.forceNight()
		elseif action == "end" then
			NightService.forceDay()
		end
		return NightService.status()
	end,

	--- Offline earnings without the wait. `simulate <secondsAway> <rate>`
	--- stamps a fake departure and settles it (negative seconds = never
	--- left); `claim` asks OfflineService to pay exactly as the remote does;
	--- `state` reads the three profile fields.
	offline = function(player, action: string?, secondsAway: number?, rate: number?)
		local OfflineService = require(script.Parent.OfflineService)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		if action == "simulate" then
			local pending = OfflineService.debugSimulate(player, secondsAway or 0, rate or 0)
			return { pending = pending, cash = profile.Cash }
		elseif action == "claim" then
			local before = profile.Cash
			local ok, reason = OfflineService.claim(player)
			return { claimed = ok, reason = reason, paid = profile.Cash - before, pending = profile.PendingOfflineCash }
		end
		return {
			lastLeave = profile.LastLeaveTimestamp,
			rate = profile.OfflineCashRate,
			pending = profile.PendingOfflineCash,
			cash = profile.Cash,
			now = os.time(),
		}
	end,

	setSpeed = function(player, power: number)
		local profile = DataService.get(player)
		if not profile then
			return { error = "no profile" }
		end
		profile.SpeedPower = math.max(GameConfig.STARTING_SPEED_POWER, math.floor(power or 10))
		require(script.Parent.SpeedService).applyMovement(player)
		StateService.pushNow(player)
		local humanoid = player.Character and player.Character:FindFirstChildWhichIsA("Humanoid")
		return {
			speedPower = profile.SpeedPower,
			walkSpeed = if humanoid then humanoid.WalkSpeed else -1,
		}
	end,

	--- Inspects, resets, or attacks the one-time tutorial Cash bridge.
	--- Base guardians. `bayTest Base01 Tiger` spawns a guardian on that plot
	--- owned by NOBODY, so the one player in a Studio server counts as an
	--- intruder to it; `bayTest clear` removes every such test guardian.
	bayTest = function(player, plotName: string?, key: string?)
		local BaseGuardianService = require(script.Parent.BaseGuardianService)
		if plotName == "clear" then
			return { cleared = BaseGuardianService.debugClear() }
		end
		local ok = BaseGuardianService.debugSpawn(plotName or "Base01", key or "Tiger")
		return { spawned = ok, guardian = BaseGuardianService.inspect(player) }
	end,

	--- The player's own (or the test) base guardian, this frame.
	guardianState = function(player)
		local BaseGuardianService = require(script.Parent.BaseGuardianService)
		return BaseGuardianService.inspect(player) or { none = true }
	end,

	--- Equip / unequip an OWNED base guardian through the real path.
	guardianEquip = function(player, key: string?)
		local BaseGuardianService = require(script.Parent.BaseGuardianService)
		if key == nil or key == "" then
			local ok, reason = BaseGuardianService.unequip(player)
			return { ok = ok, reason = reason }
		end
		local ok, reason = BaseGuardianService.equip(player, key)
		return { ok = ok, reason = reason, state = BaseGuardianService.inspect(player) }
	end,

	--- The rotation clock: what is on sale now and at the next three boundaries.
	--- The two Guardian sale slots as the LIVE services see them: what each
	--- pedestal is showing, and whether the purchase path will honour a key.
	--- Run through the bridge, never a fresh require - a command-bar require
	--- gets an empty copy of the service and reports no slots at all.
	guardianSlots = function(player, probeKey: string?)
		local GuardianShopService = require(script.Parent.GuardianShopService)
		local MonetizationService = require(script.Parent.MonetizationService)
		local onSale = GuardianShopService.onSaleKeys()
		local out = { onSale = onSale, slots = {} }
		for _, m in workspace.Map:GetChildren() do
			if m:IsA("Model") and string.match(m.Name, "^GuardianShop") then
				table.insert(out.slots, string.format("%s slot=%s key=%s price=%s",
					m.Name, tostring(m:GetAttribute("SlotIndex")),
					tostring(m:GetAttribute("RotationKey")), tostring(m:GetAttribute("Price"))))
			end
		end
		-- The refusal path: a key that is not on a pedestal must never open a
		-- dialog, whoever asks and however it is spelled.
		if probeKey and player then
			local ok, reason = MonetizationService.promptGuardianPass(player, probeKey)
			out.probe = { key = probeKey, opened = ok, reason = reason }
		end
		return out
	end,

	--- THE FREE SPIN, as the live service sees it: the caller's accrued play
	--- time, which wheel is theirs and whether it is locked.
	spin = function(player)
		local SpinWheelService = require(script.Parent.SpinWheelService)
		return SpinWheelService.inspect(player)
	end,

	--- Hands the caller their next spin immediately, so the wheel can be
	--- tested without playing for ten minutes. Grants nothing itself: the
	--- prompt, the roll and the payout all still go through the real path.
	spinReady = function(player)
		local SpinWheelService = require(script.Parent.SpinWheelService)
		return { ok = SpinWheelService.debugReady(player), state = SpinWheelService.inspect(player) }
	end,

	--- Pays out ONE segment through the wheel's real grant path, so the rare
	--- wedges - the two guardians and the 1B jackpot - can be checked without
	--- waiting for the roll that would produce them.
	spinGrant = function(player, index: any)
		local SpinWheelService = require(script.Parent.SpinWheelService)
		local BaseGuardianService = require(script.Parent.BaseGuardianService)
		local result = SpinWheelService.debugGrant(player, math.clamp(tonumber(index) or 1, 1, 12))
		result.ownsPanda = BaseGuardianService.owns(player, "Panda")
		result.ownsTiger = BaseGuardianService.owns(player, "Tiger")
		result.ownsCat = BaseGuardianService.owns(player, "Cat")
		return result
	end,

	--- Rolls the wheel `count` times WITHOUT granting anything, so the odds
	--- can be measured against the weight table rather than trusted.
	spinOdds = function(_player, count: any)
		local SpinWheelService = require(script.Parent.SpinWheelService)
		return SpinWheelService.debugOdds(math.clamp(tonumber(count) or 100000, 1, 2000000))
	end,

	--- Runs the LEAVE path's release hooks on the caller without actually
	--- releasing them - the only way to exercise "left mid-spin" in a solo
	--- Studio session. Spin first, call this while the wheel is turning, and
	--- the pending prize should be paid here and NOT again when it lands.
	spinRelease = function(player)
		local SpinWheelService = require(script.Parent.SpinWheelService)
		local profile = DataService.get(player)
		local before = SpinWheelService.inspect(player).pendingPrize
		local cash, speed = profile and profile.Cash, profile and profile.SpeedPower
		DataService.runBeforeRelease(player)
		return {
			pendingBefore = before,
			pendingAfter = SpinWheelService.inspect(player).pendingPrize,
			cashBefore = cash,
			cashAfter = profile and profile.Cash,
			speedBefore = speed,
			speedAfter = profile and profile.SpeedPower,
		}
	end,

	--- The beginner checklist: what the caller has done, and a reset so the
	--- three rows can be walked through again.
	starter = function(player, reset: any)
		local StarterTaskService = require(script.Parent.StarterTaskService)
		local DataService = require(script.Parent.DataService)
		if reset == true or reset == "reset" then
			StarterTaskService.debugReset(player)
		end
		local profile = DataService.get(player)
		return {
			summary = StarterTaskService.summarise(player),
			closed = if profile then profile.StarterTasksClosed else nil,
		}
	end,

	rotation = function()
		local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
		local now = workspace:GetServerTimeNow()
		local rows = {}
		for step = 0, 3 do
			local at = now + step * BaseGuardianConfig.ROTATION_SECONDS
			local key, index, endsAt = BaseGuardianConfig.rotation(at)
			table.insert(rows, { at = math.floor(at), key = key, index = index, endsAt = endsAt, countdown = BaseGuardianConfig.formatCountdown(endsAt - at) })
		end
		return rows
	end,

	--- Live Roblox prices against the brief's intended ones.
	prices = function()
		local MonetizationService = require(script.Parent.MonetizationService)
		MonetizationService.refreshLivePrices()
		return MonetizationService.livePriceReport()
	end,

	--- Weapons: `weapon` reports; `weapon equip Slap` through the real path.
	weapon = function(player, action: string?, name: string?)
		local PvPService = require(script.Parent.PvPService)
		if action == "equip" and name then
			local ok, reason = PvPService.setWeapon(player, name)
			return { ok = ok, reason = reason, equipped = PvPService.equippedWeapon(player) }
		end
		return PvPService.summarise(player)
	end,

	--- Base stealing state for this player.
	heist = function(player)
		local HeistService = require(script.Parent.HeistService)
		return HeistService.snapshot(player)
	end,

	---   Invoke("bridge")                report the flag
	---   Invoke("bridge", nil, "reset")  clear it, to re-run onboarding
	---   Invoke("bridge", nil, "spam", 50)
	---        hammer the real grant path 50 times and report the total paid out,
	---        which must be 0 once the flag is set. This has to run in the SERVER
	---        VM - a require from the command bar gets a fresh module with an
	---        empty profile table and would report a meaningless zero.
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
