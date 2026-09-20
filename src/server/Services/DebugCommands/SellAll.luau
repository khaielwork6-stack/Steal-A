--!strict
--[[
	DebugCommands.SellAll
	Studio-only test for the Storage "SELL ALL" action (PlacementService.
	sellAllStored). Invoke through ServerStorage.DebugInvoke:Invoke("sellAllTest", "<PlayerName>").

	STUDIO WRITES TO THE OWNER'S REAL DATASTORE. The whole Inventory and the
	Cash are deep-copied first, the body runs in pcall, and both are put back
	before this returns, error or not.

	sellAllTest
	    Adds one HELD item, one UNREVEALED container and two ordinary items to
	    Storage (so every rule is exercised whatever the tester owns), then sells all:
	    the held item and the container must still be there, every other item
	    must be gone, the Cash must rise by AT LEAST the sum of the per-item
	    payouts (the 2x Cash pass, which earn applies, may add to it), and a
	    second call straight after must be refused ("Nothing to sell." or
	    "Slow down!") without changing anything.
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Services = script.Parent.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local PlacementService = require(Services.PlacementService)
local StateService = require(Services.StateService)

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, inner in value :: { [any]: any } do
		out[key] = deepCopy(inner)
	end
	return out
end

local commands: { [string]: (Player, ...any) -> any } = {}

commands.sellAllTest = function(player: Player)
	assert(RunService:IsStudio(), "Studio only")
	local profile = assert(DataService.get(player), "no profile")
	local savedInventory = deepCopy(profile.Inventory)
	local savedCash = EconomyService.getCash(player)

	local ok, result = pcall(function()
		local template = profile.Inventory[1]
		assert(template, "the tester's Storage is empty: nothing to test with")
		-- A held item and a sealed container, both copies of a real item so the
		-- record has every field a real one has.
		local held = deepCopy(template)
		held.InstanceId = HttpService:GenerateGUID(false)
		held.Held = true
		held.HeldOrder = 999
		held.Hatched = true
		local sealed = deepCopy(template)
		sealed.InstanceId = HttpService:GenerateGUID(false)
		sealed.Held = nil
		sealed.Hatched = false
		table.insert(profile.Inventory, held)
		table.insert(profile.Inventory, sealed)
		-- Two ordinary sellable items, so the test has something to sell
		-- whatever the tester owns.
		for _ = 1, 2 do
			local plain = deepCopy(template)
			plain.InstanceId = HttpService:GenerateGUID(false)
			plain.Held = nil
			plain.HeldOrder = nil
			plain.HeldActive = nil
			plain.Hatched = true
			table.insert(profile.Inventory, plain)
		end

		local expectedSold, expectedTotal = 0, 0
		for _, item in profile.Inventory do
			if item.Hatched ~= false and not item.Held then
				expectedSold += 1
				expectedTotal += PlacementService.sellPayoutOf(item)
			end
		end

		local expectedKept = #profile.Inventory - expectedSold
		local cashBefore = EconomyService.getCash(player)
		local first, firstReason = PlacementService.sellAllStored(player)
		local cashAfter = EconomyService.getCash(player)
		local remainingHeld, remainingSealed, sellableLeft = 0, 0, 0
		for _, item in profile.Inventory do
			if item.InstanceId == held.InstanceId then
				remainingHeld += 1
			elseif item.InstanceId == sealed.InstanceId then
				remainingSealed += 1
			end
			if item.Hatched ~= false and not item.Held then
				sellableLeft += 1
			end
		end
		local inventoryAfterFirst = #profile.Inventory
		local second, secondReason = PlacementService.sellAllStored(player)

		return {
			pass = first == true
				and remainingHeld == 1
				and remainingSealed == 1
				and sellableLeft == 0
				and #profile.Inventory == expectedKept
				and cashAfter - cashBefore >= expectedTotal
				and second == false
				and #profile.Inventory == inventoryAfterFirst,
			soldExpected = expectedSold,
			payoutExpected = expectedTotal,
			cashGained = cashAfter - cashBefore,
			firstReason = firstReason,
			heldKept = remainingHeld == 1,
			sealedKept = remainingSealed == 1,
			nothingSellableLeft = sellableLeft == 0,
			keptCount = expectedKept,
			secondRefused = second == false,
			secondReason = secondReason,
		}
	end)

	-- Put everything back, even on error.
	profile.Inventory = savedInventory
	local now = EconomyService.getCash(player)
	if now > savedCash then
		EconomyService.spend(player, now - savedCash, "debug-restore")
	elseif now < savedCash then
		EconomyService.earn(player, savedCash - now, "debug-restore")
	end

	if not ok then
		return { pass = false, error = tostring(result), restored = true }
	end
	(result :: any).restored = true
	return result
end

--- For LOOKING at the Sell All bar: adds `count` (default 3) ordinary
--- sellable copies of the tester's first Storage item, marked DebugSellAllUi,
--- and pushes state so the panel shows them. `sellAllUiClean` removes exactly
--- those (and only those), so nothing of the tester's own is touched. They are
--- never saved on purpose: clean up before leaving.
commands.sellAllUiSetup = function(player: Player, count: any)
	assert(RunService:IsStudio(), "Studio only")
	local profile = assert(DataService.get(player), "no profile")
	local template = assert(profile.Inventory[1], "the tester's Storage is empty: nothing to copy")
	for _ = 1, math.clamp(math.floor(tonumber(count) or 3), 1, 20) do
		local plain = deepCopy(template)
		plain.InstanceId = HttpService:GenerateGUID(false)
		plain.Held, plain.HeldOrder, plain.HeldActive = nil, nil, nil
		plain.Hatched = true
		plain.DebugSellAllUi = true
		table.insert(profile.Inventory, plain)
	end
	StateService.pushNow(player)
	return { stored = #profile.Inventory }
end

commands.sellAllUiClean = function(player: Player)
	assert(RunService:IsStudio(), "Studio only")
	local profile = assert(DataService.get(player), "no profile")
	local kept: { any } = {}
	local removed = 0
	for _, item in profile.Inventory do
		if (item :: any).DebugSellAllUi then
			removed += 1
		else
			table.insert(kept, item)
		end
	end
	profile.Inventory = kept
	StateService.pushNow(player)
	return { removed = removed, stored = #profile.Inventory }
end

return commands
