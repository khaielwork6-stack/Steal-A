--!strict
--[[
	RetentionRewards
	The one place codes (CodeService) and the daily streak
	(DailyRewardService) turn a reward spec into Cash, Speed and guardians.
	Not a service: no start(), no state. Both callers require it.

	THE SPEC is the shared shape of CodesConfig.Rewards and
	DailyRewardConfig.Day: fixed `cash` / `speed`, scaled `cashMinutes` /
	`speedGateFraction` with floors and caps, and `guardianKey`.

	HOW IT PAYS - the same paths as the rest of the game:
	  Cash      EconomyService.award (exact figure; never the 2x pass - the
	            amount is already computed from BASE income, like a Cash pack)
	  Speed     profile.SpeedPower += amount, then SpeedService.applyMovement
	            (the spin wheel / group gift / mailbox path)
	  Guardian  BaseGuardianService.grantWon (the spin wheel's path). An
	            animal the player already owns pays Speed instead:
	            the spec's `duplicate` amount if it has one, otherwise
	            SpinWheelConfig.DUPLICATE_GUARDIAN_SPEED.

	`resolve` computes the figures WITHOUT paying, so the panel preview and the
	payout are the same numbers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseGuardianConfig = require(ReplicatedStorage.Shared.Config.BaseGuardianConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)

local BaseGuardianService = require(script.Parent.BaseGuardianService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local SpeedService = require(script.Parent.SpeedService)

local RetentionRewards = {}

--- Any table carrying the optional reward fields. Typed loosely on purpose:
--- both config shapes are accepted without a cast at every call site.
export type Spec = { [string]: any }

export type Context = {
	--- $/s without the 2x pass or boosts (MonetizationConfig.baseIncome).
	baseIncome: number,
	highestZone: number,
}

--- What a spec pays this player right now. `guardianOwned` tells the caller
--- which branch a guardian reward will take.
export type Resolved = {
	cash: number,
	speed: number,
	guardianKey: string?,
	guardianOwned: boolean,
}

--- What was actually paid.
export type Paid = {
	cash: number,
	speed: number,
	guardian: string?,
	--- True when a guardian reward was converted to Speed.
	converted: boolean,
}

local function finite(value: any): number
	local n = tonumber(value) or 0
	if n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return n
end

function RetentionRewards.context(player: Player, profile: DataService.Profile): Context
	return {
		baseIncome = MonetizationConfig.baseIncome(EconomyService.getIncome(player), EconomyService.cashMultiplierFor(player)),
		highestZone = profile.HighestZoneReached,
	}
end

--- Cash for `spec`: fixed + max(floor, minutes of base income). Whole dollars.
function RetentionRewards.cashFor(spec: Spec, context: Context): number
	local total = math.max(0, finite(spec.cash))
	local minutes = finite(spec.cashMinutes)
	if minutes > 0 then
		local scaled = math.max(0, finite(context.baseIncome)) * minutes * 60
		total += math.max(math.max(0, finite(spec.cashFloor)), scaled)
	end
	return math.floor(total)
end

--- Speed from the scaled fields of `spec` (fraction / floor / max).
local function scaledSpeed(spec: Spec, context: Context): number
	local fraction = finite(spec.speedGateFraction)
	if fraction <= 0 then
		return 0
	end
	local scaled = SpinWheelConfig.nextGate(context.highestZone) * fraction
	local cap = finite(spec.speedMax)
	if cap > 0 then
		scaled = math.min(scaled, cap)
	end
	return math.max(math.max(0, finite(spec.speedFloor)), scaled)
end

--- Speed for `spec`: fixed + scaled. Whole numbers.
function RetentionRewards.speedFor(spec: Spec, context: Context): number
	return math.floor(math.max(0, finite(spec.speed)) + scaledSpeed(spec, context))
end

--- The Speed a guardian reward pays when the animal is already owned.
function RetentionRewards.duplicateSpeedFor(spec: Spec, context: Context): number
	local duplicate = spec.duplicate
	if type(duplicate) == "table" then
		local amount = math.floor(scaledSpeed(duplicate, context) + math.max(0, finite(duplicate.speed)))
		if amount > 0 then
			return amount
		end
	end
	return SpinWheelConfig.DUPLICATE_GUARDIAN_SPEED
end

--- The figures `spec` pays `player` right now, without paying anything.
function RetentionRewards.resolve(player: Player, profile: DataService.Profile, spec: Spec): Resolved
	local context = RetentionRewards.context(player, profile)
	local resolved: Resolved = {
		cash = RetentionRewards.cashFor(spec, context),
		speed = RetentionRewards.speedFor(spec, context),
		guardianKey = nil,
		guardianOwned = false,
	}
	local key = spec.guardianKey
	if type(key) == "string" and BaseGuardianConfig.ByKey[key] then
		resolved.guardianKey = key
		if BaseGuardianService.owns(player, key) then
			resolved.guardianOwned = true
			resolved.speed += RetentionRewards.duplicateSpeedFor(spec, context)
		end
	end
	return resolved
end

--- Pays `spec` to `player`. Call with the profile already marked as having
--- received it (the callers' idempotency record), and inside a pcall - a
--- throw here must be able to roll that mark back.
function RetentionRewards.grant(player: Player, profile: DataService.Profile, spec: Spec, source: EconomyService.CashSource): Paid
	local context = RetentionRewards.context(player, profile)
	local paid: Paid = { cash = 0, speed = 0, guardian = nil, converted = false }

	local cash = RetentionRewards.cashFor(spec, context)
	local speed = RetentionRewards.speedFor(spec, context)

	local key = spec.guardianKey
	if type(key) == "string" and BaseGuardianConfig.ByKey[key] then
		-- grantWon answers false for an animal already owned (by pass or an
		-- earlier win); that is the conversion case, never a blank.
		if BaseGuardianService.grantWon(player, key) then
			paid.guardian = key
		else
			paid.converted = true
			speed += RetentionRewards.duplicateSpeedFor(spec, context)
		end
	end

	if cash > 0 then
		EconomyService.award(player, cash, source)
		paid.cash = cash
	end
	if speed > 0 then
		-- Added to the saved total, never multiplied: the Speed pass scales
		-- training gain only.
		profile.SpeedPower += speed
		SpeedService.applyMovement(player)
		paid.speed = speed
	end
	return paid
end

--- "+$12.5K", "+500 Speed", "the Panda Guardian" joined with " & ".
function RetentionRewards.describe(paid: Paid): string
	local parts: { string } = {}
	if paid.guardian then
		table.insert(parts, `the {paid.guardian} Guardian`)
	end
	if paid.cash > 0 then
		table.insert(parts, "+" .. NumberFormat.cash(paid.cash))
	end
	if paid.speed > 0 then
		table.insert(parts, `+{NumberFormat.short(paid.speed)} Speed`)
	end
	if #parts == 0 then
		return "nothing"
	end
	return table.concat(parts, " & ")
end

return RetentionRewards
