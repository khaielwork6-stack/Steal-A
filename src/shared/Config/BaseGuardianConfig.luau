--!strict
--[[
	BaseGuardianConfig
	The four animal Guardians a player can buy for their BASE: which models
	they are, how the three-hour global rotation is derived, how the Guardian
	Bay is sized, and how a base guardian chases.

	NOT the zone guardians (the Cop, the Pirate Captain...). Those live in
	ZoneConfig / GuardianService and wake on a steal. These stand in a bay at
	the back of a player's plot and defend it against other players.

	GAME PASS IDS LIVE IN MonetizationConfig.GuardianPasses, because that file
	is the one place every Robux id is kept. Prices are NEVER typed here: the
	live PriceInRobux from MarketplaceService is what every sign and card
	shows (MonetizationService.livePrices), so the Creator Dashboard is the
	only place a price is decided.

	THE ROTATION IS A FUNCTION OF UNIX TIME. Nothing starts a timer when a
	server boots: `rotation(now)` divides the Unix clock into three-hour
	slots and every server, and every client through GetServerTimeNow, gets
	the same answer for the same second. That is what makes the countdown
	identical everywhere and correct across restarts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)

local BaseGuardianConfig = {}

export type GuardianDef = {
	key: string,
	name: string,
	gamePassId: number,
	--- The imported model's name (ReplicatedStorage.GameAssets.BaseGuardians.<modelName>).
	modelName: string,
	--- The owner's aura VFX kit for this animal (...BaseGuardians.Auras.<auraName>).
	auraName: string,
	color: Color3,
	accent: Color3,
	--- Which way the import FACES, as a direction in the model pivot's own
	--- space: measured in Studio as the offset from the body centre to the
	--- head/eyes. The rig turns the costume so this points along its forward
	--- axis, so a cat authored looking down +X still runs nose-first.
	faceLocal: Vector3,
	--- One line for the shop sign.
	tagline: string,
}

local function pass(key: string): number
	local def = MonetizationConfig.GuardianPassByKey[key]
	return if def then def.gamePassId else 0
end

BaseGuardianConfig.Guardians = {
	{
		key = "Cat",
		name = "Cat",
		gamePassId = pass("Cat"),
		modelName = "Cat",
		auraName = "CatAura",
		color = Color3.fromRGB(255, 176, 92),
		accent = Color3.fromRGB(196, 96, 24),
		faceLocal = Vector3.new(-2.95, 1.28, -1.21),
		tagline = "Quick on its paws",
	},
	{
		key = "Dog",
		name = "Dog",
		gamePassId = pass("Dog"),
		modelName = "Dog",
		auraName = "DogAura",
		color = Color3.fromRGB(122, 196, 255),
		accent = Color3.fromRGB(38, 96, 200),
		faceLocal = Vector3.new(0.07, 3.01, -2.96),
		tagline = "Loyal to the last",
	},
	{
		key = "Panda",
		name = "Panda",
		gamePassId = pass("Panda"),
		modelName = "Panda",
		auraName = "PandaAura",
		color = Color3.fromRGB(150, 236, 160),
		accent = Color3.fromRGB(40, 150, 80),
		faceLocal = Vector3.new(3.93, 2.1, -0.3),
		tagline = "Soft, until you trespass",
	},
	{
		key = "Tiger",
		name = "Tiger",
		gamePassId = pass("Tiger"),
		modelName = "Tiger",
		auraName = "TigerAura",
		color = Color3.fromRGB(255, 140, 60),
		accent = Color3.fromRGB(190, 60, 20),
		faceLocal = Vector3.new(-9.0, 2.25, 0.05),
		tagline = "Nobody walks past a tiger",
	},
} :: { GuardianDef }

BaseGuardianConfig.ByKey = {} :: { [string]: GuardianDef }
for _, def in BaseGuardianConfig.Guardians do
	BaseGuardianConfig.ByKey[def.key] = def
end

-- ==========================================================
-- ROTATION
-- ==========================================================

BaseGuardianConfig.ROTATION_ORDER = { "Cat", "Dog", "Panda", "Tiger" }
BaseGuardianConfig.ROTATION_SECONDS = 3 * 60 * 60
--- Unix second the cycle counts from. 0 means the Unix epoch itself; move it
--- to shift which animal is up at a given hour without touching the order.
BaseGuardianConfig.ROTATION_EPOCH = 0

--- The guardian on offer at Unix time `now`, the slot index it occupies and
--- the Unix second the slot ends. Pure arithmetic: identical on every
--- server and every client for the same input.
function BaseGuardianConfig.rotation(now: number): (string, number, number)
	local order = BaseGuardianConfig.ROTATION_ORDER
	local length = BaseGuardianConfig.ROTATION_SECONDS
	local elapsed = math.max(0, now - BaseGuardianConfig.ROTATION_EPOCH)
	local slot = math.floor(elapsed / length)
	local index = (slot % #order) + 1
	local endsAt = BaseGuardianConfig.ROTATION_EPOCH + (slot + 1) * length
	return order[index], index, endsAt
end

--- "02:59:59" for a number of seconds: never negative, never over 99 hours.
function BaseGuardianConfig.formatCountdown(seconds: number): string
	local total = math.max(0, math.floor(seconds + 0.5))
	local hours = math.min(99, total // 3600)
	local minutes = (total % 3600) // 60
	local secs = total % 60
	return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

-- ==========================================================
-- SIZE AND THE BAY
-- ==========================================================

--- Costume height in studs, in the bay and on the shop pedestal. A little
--- taller than a player so it reads as a defender, well under the Cop's 7.
BaseGuardianConfig.HEIGHT = 6
--- The bay platform: square, at the back corner of the plot on the two pad
--- cells the display grid leaves empty (see MapBuilder.buildBase).
BaseGuardianConfig.BAY_SIZE = 14
BaseGuardianConfig.BAY_THICKNESS = 0.6

-- ==========================================================
-- DEFENCE
-- ==========================================================

--- Beat between spotting an intruder (the "!") and setting off after them.
BaseGuardianConfig.ALERT_DELAY = 0.45
--- How often an idle guardian looks for intruders, and a chasing one asks
--- whether someone nearer should be its target.
BaseGuardianConfig.SCAN_INTERVAL = 0.3
--- Pace: a fraction over the intruder's own WalkSpeed, clamped. Threatening
--- inside a base, never a teleport, and it cannot outrun the physics clamp.
BaseGuardianConfig.SPEED_FACTOR = 1.15
BaseGuardianConfig.SPEED_MIN = 24
BaseGuardianConfig.SPEED_MAX = 96
--- Root-to-root distance at which the hit lands.
BaseGuardianConfig.CATCH_RADIUS = 5.5
--- Studs past the plot's own boundary a guardian will follow before it
--- gives up and walks home. It defends the base; it does not tour the map.
BaseGuardianConfig.CHASE_MARGIN = 14
--- Longest a single chase may run before the guardian returns regardless.
BaseGuardianConfig.CHASE_TIMEOUT = 15
--- The launch. Outward from the BASE CENTRE, so the intruder always leaves.
BaseGuardianConfig.KNOCKBACK = 58
BaseGuardianConfig.LIFT = 40
BaseGuardianConfig.STUN = 1.4
--- Immunity after a hit doubles as the per-target hit cooldown.
BaseGuardianConfig.IMMUNITY = 2.4
--- A guardian this close to home is home.
BaseGuardianConfig.HOME_REACH = 3

return BaseGuardianConfig
