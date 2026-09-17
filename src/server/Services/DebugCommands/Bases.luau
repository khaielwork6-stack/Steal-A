--!strict
--[[
	DebugCommands.Bases
	Studio-only test commands for item fusion, Auto Reveal and base themes
	(docs/handoff-parts/fusion-autoreveal-bases.md). Invoke through
	ServerStorage.DebugInvoke:Invoke("<name>", "<PlayerName>", ...).

	EVERY COMMAND THAT CHANGES A PROFILE PUTS IT BACK, EVEN ON ERROR (Studio
	with API access writes to the owner's REAL DataStore): the touched fields
	are deep-copied first, the body runs in pcall, the copy is restored, the
	base redrawn and the profile saved again.

	  fuseTest [itemId] [mutationRoll]
	      gives 3 stored copies (Normal / Big / Normal-Shiny) and the Cash,
	      fuses them, checks the result and three refusals (duplicate ids, a
	      sealed input, a missing copy), then restores everything.
	      mutationRoll 0..1 pins the roll (e.g. 0.999 -> Corrupted).
	  fuseOdds [rolls]
	      samples FusionConfig.rollMutation for every floor and compares it
	      with the odds the panel shows. Changes nothing.
	  autoRevealOwn [on|off|clear]
	      Studio ownership override for the Auto Reveal pass.
	  autoRevealTest [full|quick|off]
	      puts a READY sealed container on a free pad, owns the pass, and
	      runs one Auto Reveal step: `full` as if at the base (camera
	      fly-in), `quick` as if away (small pop, toast), `off` with the
	      Settings switch off (must NOT reveal). Waits for the reveal, then
	      restores everything (the pad, Index, Cash, checklist, ownership).
	  themeShow <themeKey|-> [pedestalKey]
	      previews a theme / skin on the caller's plot regardless of
	      ownership; `themeClear` removes the preview.
	  themeCycle [seconds]
	      previews every theme, then every pedestal skin, `seconds` apart
	      (default 2), and restores the real look. Needs an occupied pad to
	      show the skins.
	  themePassOwn <passKey> [on|off|clear]
	      Studio ownership override for a Robux theme pass.
	  themeBuyTest
	      buys Sunset and Marble with granted Cash, checks ownership, the
	      equip and the painted slab, then restores the profile and the look.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseThemeConfig = require(ReplicatedStorage.Shared.Config.BaseThemeConfig)
local FusionConfig = require(ReplicatedStorage.Shared.Config.FusionConfig)
local HatchConfig = require(ReplicatedStorage.Shared.Config.HatchConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)

local AutoRevealService = require(script.Parent.Parent.AutoRevealService)
local BaseService = require(script.Parent.Parent.BaseService)
local BaseThemeService = require(script.Parent.Parent.BaseThemeService)
local DataService = require(script.Parent.Parent.DataService)
local EconomyService = require(script.Parent.Parent.EconomyService)
local FusionService = require(script.Parent.Parent.FusionService)
local HatchService = require(script.Parent.Parent.HatchService)
local StateService = require(script.Parent.Parent.StateService)

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

local FIELDS = {
	"Cash",
	"SpeedPower",
	"Lifetime",
	"Index",
	"ClaimedIndexRewards",
	"DisplayItems",
	"Inventory",
	"StarterTasks",
	"StarterTasksClosed",
	"HighestZoneReached",
	"BaseTheme",
	"Settings",
}

--- Runs `body` against the caller's profile and ALWAYS restores it.
local function withRestore(player: Player, body: (DataService.Profile) -> any): any
	local profile = DataService.get(player)
	if not profile then
		return { error = "no profile" }
	end
	local snap: { [string]: any } = {}
	for _, field in FIELDS do
		snap[field] = copy((profile :: any)[field])
	end
	local ok, result = pcall(body, profile)
	for _, field in FIELDS do
		(profile :: any)[field] = copy(snap[field])
	end
	BaseService.rebuildDisplays(player)
	EconomyService.recalculate(player)
	StateService.pushNow(player, true)
	if DataService.isPersistent() then
		DataService.save(player)
	end
	if not ok then
		return { error = tostring(result), restored = true }
	end
	return result
end

local function defaultItemId(): string
	local pool = LootConfig.pool(1)
	return if pool[1] then pool[1].id else "unknown"
end

--- A revealed stored copy with the given size class and mutation.
local function storedCopy(itemId: string, class: number, mutation: string): DataService.DisplayItem
	local def = LootConfig.ById[itemId]
	local variant = ScaleConfig.Variants[class]
	local item: DataService.DisplayItem = {
		InstanceId = game:GetService("HttpService"):GenerateGUID(false),
		ItemId = itemId,
		ZoneId = if def then def.zoneIndex else 1,
		Rarity = if def then def.rarity else "Common",
		Size = variant.id,
		Mutation = mutation,
		BaseIncome = if def then def.income else 1,
		FinalIncome = 0,
		SlotIndex = 0,
		Scale = variant.min,
		Hatched = true,
	}
	DataService.reconcileItem(item)
	return item
end

local function findIn(list: { DataService.DisplayItem }, instanceId: string): DataService.DisplayItem?
	for _, item in list do
		if item.InstanceId == instanceId then
			return item
		end
	end
	return nil
end

local function onOff(value: any): boolean?
	if value == "on" or value == true then
		return true
	elseif value == "off" or value == false then
		return false
	end
	return nil
end

return {
	-- ==========================================================
	-- FUSION
	-- ==========================================================

	fuseTest = function(player: Player, itemIdArg: any, rollArg: any): any
		local itemId = if type(itemIdArg) == "string" and LootConfig.ById[itemIdArg] then itemIdArg else defaultItemId()
		local pinned = tonumber(rollArg)
		local realRandom = FusionService.random
		if pinned then
			FusionService.random = function(kind: string): number
				return if kind == "mutation" then math.clamp(pinned :: number, 0, 0.9999) else 0.5
			end
		end
		local result = withRestore(player, function(profile)
			local a = storedCopy(itemId, 1, "Normal")
			local b = storedCopy(itemId, 2, "Normal")
			local c = storedCopy(itemId, 1, "Shiny")
			local sealed = storedCopy(itemId, 1, "Normal")
			sealed.Hatched = false
			for _, item in { a, b, c, sealed } do
				table.insert(profile.Inventory, item)
			end
			local preview = FusionService.previewFor(itemId, { a, b, c }) :: FusionService.Preview
			profile.Cash = preview.cost

			local refusals = {}
			local _, dup = FusionService.fuse(player, itemId, { a.InstanceId, a.InstanceId, b.InstanceId })
			refusals.duplicate = dup
			local _, sealedReason = FusionService.fuse(player, itemId, { a.InstanceId, b.InstanceId, sealed.InstanceId })
			refusals.sealed = sealedReason
			local _, missing = FusionService.fuse(player, itemId, { a.InstanceId, b.InstanceId, "not-a-real-id" })
			refusals.missing = missing
			local cashBefore = profile.Cash
			local countBefore = #profile.Inventory

			local made, reason = FusionService.fuse(player, itemId, { a.InstanceId, b.InstanceId, c.InstanceId })
			if not made then
				return { error = reason, refusals = refusals }
			end
			local classOk = FusionConfig.classOf(made.Scale or 1) == preview.targetClass
			local floorOk = RarityConfig.mutationRank(made.Mutation) >= RarityConfig.mutationRank("Shiny")
			local def = LootConfig.ById[itemId]
			local incomeOk = def ~= nil and made.FinalIncome == RarityConfig.finalIncome(def.income, made.Scale or 1, made.Mutation)
			local inputsGone = findIn(profile.Inventory, a.InstanceId) == nil
				and findIn(profile.Inventory, b.InstanceId) == nil
				and findIn(profile.Inventory, c.InstanceId) == nil
			return {
				pass = classOk and floorOk and incomeOk and inputsGone
					and cashBefore - profile.Cash == preview.cost
					and #profile.Inventory == countBefore - 2
					and dup ~= nil and sealedReason ~= nil and missing ~= nil,
				item = itemId,
				cost = preview.cost,
				cashSpent = cashBefore - profile.Cash,
				targetSize = preview.targetSize,
				result = { size = made.Size, scale = made.Scale, mutation = made.Mutation, income = made.FinalIncome },
				classOk = classOk,
				mutationFloorOk = floorOk,
				incomeMatchesRarityConfig = incomeOk,
				inputsGone = inputsGone,
				storageDelta = #profile.Inventory - countBefore,
				refusals = refusals,
				restored = true,
			}
		end)
		FusionService.random = realRandom
		return result
	end,

	fuseOdds = function(_player: Player, rollsArg: any): any
		local rolls = math.clamp(math.floor(tonumber(rollsArg) or 20000), 100, 200000)
		local report = {}
		for _, floor in RarityConfig.Mutations do
			local counts: { [string]: number } = {}
			for _ = 1, rolls do
				local id = FusionConfig.rollMutation(floor.id, math.random())
				counts[id] = (counts[id] or 0) + 1
			end
			local rows = {}
			local worst = 0
			for _, row in FusionConfig.mutationOutcomes(floor.id) do
				local seen = (counts[row.id] or 0) / rolls * 100
				worst = math.max(worst, math.abs(seen - row.chance))
				rows[row.id] = { shown = row.chance, sampled = math.floor(seen * 100) / 100 }
			end
			local below = false
			for id in counts do
				if RarityConfig.mutationRank(id) < RarityConfig.mutationRank(floor.id) then
					below = true
				end
			end
			report[floor.id] = { rows = rows, worstGapPercent = worst, neverBelowFloor = not below }
		end
		return report
	end,

	-- ==========================================================
	-- AUTO REVEAL
	-- ==========================================================

	autoRevealOwn = function(player: Player, mode: any): any
		local value = onOff(mode)
		AutoRevealService.setOwnedForTesting(player, value)
		return { override = if value == nil then "cleared" else value, owns = AutoRevealService.owns(player) }
	end,

	autoRevealTest = function(player: Player, modeArg: any): any
		local mode = if modeArg == "quick" or modeArg == "off" then modeArg else "full"
		local result = withRestore(player, function(profile)
			local free = BaseService.freeSlots(player)
			if #free == 0 then
				return { error = "no free display pad - store something first" }
			end
			local itemId = defaultItemId()
			local def = LootConfig.ById[itemId]
			local item: DataService.DisplayItem = {
				InstanceId = game:GetService("HttpService"):GenerateGUID(false),
				ItemId = itemId,
				ZoneId = if def then def.zoneIndex else 1,
				Rarity = if def then def.rarity else "Common",
				Size = "Normal",
				Mutation = "Normal",
				BaseIncome = if def then def.income else 1,
				FinalIncome = 0,
				SlotIndex = free[1],
				Scale = 1,
				Hatched = false,
				HatchEndsAt = os.time() - 1,
			}
			DataService.reconcileItem(item)
			table.insert(profile.DisplayItems, item)
			BaseService.rebuildSlot(player, item.SlotIndex)
			;(profile.Settings :: any).AutoRevealOff = mode == "off"
			AutoRevealService.setOwnedForTesting(player, true)
			AutoRevealService.nearOverride = mode ~= "quick"
			AutoRevealService.debugResetPacing(player)
			task.wait(0.6) -- the container replicates before the cue

			local started = AutoRevealService.step(player)
			local waitFor = if mode == "quick" then HatchConfig.QuickReveal.lock else HatchConfig.lockSeconds(item.Rarity)
			task.wait(waitFor + 0.5)
			local after = findIn(profile.DisplayItems, item.InstanceId)
			local revealed = after ~= nil and after.Hatched == true
			local expected = mode ~= "off"
			return {
				pass = revealed == expected and started == expected and not HatchService.isRevealing(item.InstanceId),
				mode = mode,
				slot = item.SlotIndex,
				started = started,
				revealed = revealed,
				lockReleased = not HatchService.isRevealing(item.InstanceId),
				spacingSeconds = HatchConfig.autoRevealSpacing(item.Rarity, mode == "quick"),
				note = "watch the client: full = camera fly-in + roulette; quick = small pop + toast; off = nothing",
			}
		end)
		AutoRevealService.nearOverride = nil
		AutoRevealService.setOwnedForTesting(player, nil)
		AutoRevealService.debugResetPacing(player)
		return result
	end,

	-- ==========================================================
	-- BASE THEMES
	-- ==========================================================

	themeShow = function(player: Player, themeArg: any, pedestalArg: any): any
		local theme = if type(themeArg) == "string" and BaseThemeConfig.ThemeByKey[themeArg] then themeArg else nil
		local pedestal = if type(pedestalArg) == "string" and BaseThemeConfig.PedestalByKey[pedestalArg] then pedestalArg else nil
		if not theme and not pedestal then
			local themes, pedestals = {}, {}
			for _, row in BaseThemeConfig.Themes do
				table.insert(themes, row.key)
			end
			for _, row in BaseThemeConfig.Pedestals do
				table.insert(pedestals, row.key)
			end
			return { error = "unknown keys", themes = themes, pedestals = pedestals }
		end
		BaseThemeService.previewForTesting(player, theme, pedestal)
		return { showing = { theme = theme, pedestal = pedestal }, clearWith = "themeClear" }
	end,

	themeClear = function(player: Player): any
		BaseThemeService.previewForTesting(player, nil, nil)
		return { cleared = true }
	end,

	themeCycle = function(player: Player, secondsArg: any): any
		local seconds = math.clamp(tonumber(secondsArg) or 2, 0.2, 10)
		local shown = {}
		local ok, err = pcall(function()
			for _, theme in BaseThemeConfig.Themes do
				BaseThemeService.previewForTesting(player, theme.key, nil)
				table.insert(shown, theme.key)
				task.wait(seconds)
			end
			for _, skin in BaseThemeConfig.Pedestals do
				BaseThemeService.previewForTesting(player, nil, skin.key)
				table.insert(shown, skin.key)
				task.wait(seconds)
			end
		end)
		BaseThemeService.previewForTesting(player, nil, nil)
		return { shown = shown, restored = true, error = if ok then nil else tostring(err) }
	end,

	themePassOwn = function(player: Player, passKey: any, mode: any): any
		if type(passKey) ~= "string" then
			return { error = "passKey required (ThemeNeonNight / ThemeRoyalGold)" }
		end
		local value = onOff(mode)
		BaseThemeService.setPassOwnedForTesting(player, passKey, value)
		return { passKey = passKey, override = if value == nil then "cleared" else value }
	end,

	themeBuyTest = function(player: Player): any
		local result = withRestore(player, function(profile)
			local sunset = BaseThemeConfig.ThemeByKey.Sunset
			local marble = BaseThemeConfig.PedestalByKey.Marble
			profile.BaseTheme = { owned = {}, equippedTheme = BaseThemeConfig.DEFAULT_THEME, equippedPedestal = BaseThemeConfig.DEFAULT_PEDESTAL }
			profile.Cash = sunset.cash + marble.cash
			local refusedEquip = not BaseThemeService.equip(player, "Sunset")
			local boughtTheme = BaseThemeService.buy(player, "Sunset")
			local boughtSkin = BaseThemeService.buy(player, "Marble")
			local plot = BaseService.getPlot(player)
			local slab = if plot then BaseService.slabOf(plot) else nil
			local painted = slab ~= nil and sunset.floorColor ~= nil and slab.Color == sunset.floorColor
			local noCashLeft = profile.Cash == 0
			local refusedPoor = not BaseThemeService.buy(player, "Midnight")
			return {
				pass = refusedEquip and boughtTheme and boughtSkin and painted and noCashLeft and refusedPoor
					and profile.BaseTheme.owned.Sunset == true
					and profile.BaseTheme.equippedTheme == "Sunset"
					and profile.BaseTheme.equippedPedestal == "Marble",
				refusedEquipBeforeBuying = refusedEquip,
				boughtTheme = boughtTheme,
				boughtSkin = boughtSkin,
				slabPainted = painted,
				cashSpentExactly = noCashLeft,
				refusedWithoutCash = refusedPoor,
				restored = true,
			}
		end)
		-- The profile is back; put the plot's look back with it.
		BaseThemeService.apply(player)
		return result
	end,
}
