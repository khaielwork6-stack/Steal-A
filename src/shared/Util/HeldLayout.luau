--!strict
--[[
	HeldLayout  [hold-items]
	The one place that says how held items are ORDERED and how many of them the
	hotbar has room for. The server (HoldService) and the client
	(HotbarController, HeldOverflowController) both read it, so they can never
	disagree about which held item is on which hotbar position and which is in
	the overflow inventory.

	POSITIONAL AND COMPACT. The hotbar is [tools + owned gadgets][held items],
	numbered 1..N with no gaps. The held items are the Inventory entries
	flagged Held, ranked by HeldOrder ascending (rank 1 = oldest). Given how
	many positions the tools took, the first `capacity` ranks sit on the hotbar
	and every later rank is in the overflow. Nothing but position decides it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HoldConfig = require(ReplicatedStorage.Shared.Config.HoldConfig)

local HeldLayout = {}

--- The Held entries of an inventory (any array of item tables), oldest pickup
--- first. HeldOrder ties (never expected) fall back to InstanceId so both
--- sides still sort identically.
function HeldLayout.rank(inventory: any): { any }
	local list: { any } = {}
	if type(inventory) ~= "table" then
		return list
	end
	for _, item in inventory do
		if type(item) == "table" and item.Held then
			table.insert(list, item)
		end
	end
	table.sort(list, function(a, b)
		local orderA, orderB = tonumber(a.HeldOrder) or 0, tonumber(b.HeldOrder) or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return tostring(a.InstanceId) < tostring(b.InstanceId)
	end)
	return list
end

--- How many hotbar positions are left for held items once `toolCount`
--- positions are taken by tools and gadgets.
function HeldLayout.capacity(toolCount: number): number
	return math.max(0, HoldConfig.HOTBAR_SLOTS - math.max(0, toolCount))
end

return HeldLayout
