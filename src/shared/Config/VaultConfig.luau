--!strict
--[[
	VaultConfig
	Every number the zone vaults are tuned by (vaults-crews area; notes in
	docs/handoff-parts/vaults-crews.md). Geometry lives in MuseumLayout
	(VAULTS); this file is the gameplay.

	A VAULT is a third, gated room per zone with ONE pedestal. Its sealed
	container is rolled from the zone's TOP TWO rarities only (a table of its
	own, below - the ordinary socket weights are untouched), and it is guarded
	by:
	  * a heavy round door that lets through only players with at least
	    SPEED_GATE_FRACTION of the zone's recommended Speed (ZoneConfig),
	  * rotating laser arms around the pedestal (beamsFor, computed from the
	    server clock so the server and every client agree),
	  * a Vault Guardian: the zone's guard with the GUARDIAN profile below.
	An emptied vault restocks after RESTOCK_SECONDS, and at every Night when
	RESTOCK_AT_NIGHT is on.
]]

local LootConfig = require(script.Parent.LootConfig)
local RarityConfig = require(script.Parent.RarityConfig)

local VaultConfig = {}

--- Master switch. False: the vaults stand empty with their doors shut and
--- nothing restocks (the geometry is still built).
VaultConfig.ENABLED = true

--- Seconds an EMPTIED vault waits before it restocks (from the moment its
--- container left the pedestal; a container brought back by the guard stops
--- the clock, since the vault is full again).
VaultConfig.RESTOCK_SECONDS = 600
--- The Night refresh also restocks: unclaimed vault containers are rerolled
--- and empty vaults refilled. NOTE: the Night comes every
--- NightConfig.CYCLE_SECONDS (270 s), so while this is on it, not the timer
--- above, is what usually refills a vault.
--- OFF (lead, 2026-09-17): at every Night that would be a guaranteed
--- top-two-rarity container per zone every 4.5 minutes - far too generous.
--- Vaults refill on RESTOCK_SECONDS only.
VaultConfig.RESTOCK_AT_NIGHT = false

--- The door opens for players whose SpeedPower is at least this fraction of
--- the zone's recommendedSpeed. Zone 1 recommends 0, so its vault is open to
--- everyone.
VaultConfig.SPEED_GATE_FRACTION = 1
--- The door swings open (for everyone to see) while a qualified player is
--- this close to it, or inside the vault.
VaultConfig.DOOR_OPEN_RADIUS = 22
--- Seconds between the server's door / intruder passes.
VaultConfig.DOOR_CHECK_INTERVAL = 0.25

--- Widest side of the vault container, in studs (the room cases use up to
--- 12). Smaller so the laser ring fits the narrowest vault (Zone 3's wing).
VaultConfig.DISPLAY_FOOTPRINT = 7
--- Clear floor between the pedestal and the laser ring's inner edge. A
--- player (2.2 studs wide) must be able to stand there without touching an
--- arm while holding the steal.
VaultConfig.RING_GAP = 3.5
--- Width of the laser ring (outer radius minus inner), capped by the room.
VaultConfig.RING_WIDTH = 9
--- A container can be taken only from inside the ring: at most the ring's
--- inner radius plus this from the pedestal's centre, horizontally, measured
--- from the verified position.
VaultConfig.STEAL_REACH_MARGIN = 0.5
--- Height of the pedestal's top (the container stands on it).
VaultConfig.PEDESTAL_HEIGHT = 3.5

--- Relative weights of the zone's TOP rarity and its SECOND rarity. Within a
--- tier, items keep their ordinary zone weights relative to each other.
VaultConfig.TIER_WEIGHTS = { 25, 75 }

--- The Vault Guardian: the zone's own guard (same AI, GuardianService) with
--- this profile.
export type GuardProfile = {
	--- Multiplies the per-thief chase speed (GuardianService.speedForChase).
	speedScale: number,
	--- Multiplies the wake beat and the doorway grace (shorter = faster wake).
	wakeScale: number,
	--- Multiplies the catch radius.
	catchScale: number,
	--- Seconds a LASER chase lasts before it gives up (room guards:
	--- SecurityConfig.LASER_CHASE_TIMEOUT).
	laserLeash: number,
	--- The costume is scaled to min(zone guard height, this): the vault's
	--- door is 20 studs tall and its ceiling 30.
	maxHeight: number,
	--- Looked up first in ServerStorage.GameAssets.Guardians as
	--- `Zone{NN}_{costumeName}` then `{costumeName}`; the zone's own costume
	--- is the fallback.
	costumeName: string,
}
VaultConfig.GUARDIAN = {
	speedScale = 1.08,
	wakeScale = 0.5,
	catchScale = 1.35,
	laserLeash = 45,
	maxHeight = 18,
	costumeName = "VaultGuardian",
} :: GuardProfile

-- ==========================================================
-- THE ROTATING LASERS
-- ==========================================================
--
-- Each arm is a beam from the ring's inner radius to its outer radius that
-- turns around the pedestal. Its angle is a pure function of the SERVER
-- clock (workspace:GetServerTimeNow), so LaserService and every client draw
-- and test the same beam at the same moment:
--     angle = phase + 2*pi * (t mod period) / period      (period < 0 turns the other way)
-- An arm with onSeconds/offSeconds is lit only for the first onSeconds of
-- every (onSeconds + offSeconds) cycle.
--   height 0.8  ankle beam: jump it
--   height 4.5  head beam: crouch under it
--   height 2.5  waist beam: neither clears it - time it

export type Arm = {
	height: number,
	period: number,
	phase: number,
	onSeconds: number?,
	offSeconds: number?,
}

export type Ring = {
	--- World position of the pedestal's centre, on the floor.
	pivot: Vector3,
	pedestalRadius: number,
	inner: number,
	outer: number,
}

--- Where a vault's pedestal and laser ring are. Derived from the vault's
--- geometry (MuseumLayout) and the numbers above; shared by VaultBuilder,
--- VaultService, LaserService and VaultController.
function VaultConfig.ring(zoneIndex: number): Ring
	local Layout = require(script.Parent.Parent.MuseumLayout)
	local pedestalRadius = VaultConfig.DISPLAY_FOOTPRINT * math.sqrt(2) / 2 + 0.5
	local inner = pedestalRadius + VaultConfig.RING_GAP
	-- The side walls' inner faces are 2 studs in from the vault's ends.
	local halfX = Layout.vaultLength(zoneIndex) / 2 - 2
	local outer = math.min(inner + VaultConfig.RING_WIDTH, halfX - 1)
	-- Toward the back of the vault, leaving the front as an antechamber.
	local depth = Layout.DEPTH - 2 - outer - 3
	return {
		pivot = Layout.vaultFrame(zoneIndex):PointToWorldSpace(Vector3.new(0, 0, depth)),
		pedestalRadius = pedestalRadius,
		inner = inner,
		outer = outer,
	}
end

function VaultConfig.beamsFor(zoneIndex: number): { Arm }
	local period = math.max(3.2, 7 - zoneIndex * 0.3)
	local arms: { Arm } = {}
	local low = if zoneIndex >= 8 then 3 else 2
	for n = 1, low do
		table.insert(arms, { height = 0.8, period = period, phase = (n - 1) * 2 * math.pi / low })
	end
	if zoneIndex >= 4 then
		table.insert(arms, { height = 4.5, period = -period * 1.3, phase = math.pi / 2 })
	end
	if zoneIndex >= 11 then
		table.insert(arms, { height = 2.5, period = period * 1.7, phase = math.pi / 4, onSeconds = 3, offSeconds = 2 })
	end
	return arms
end

-- ==========================================================
-- THE ROLL
-- ==========================================================

--- The zone's two highest rarities present in its pool, best first.
function VaultConfig.topRarities(zoneIndex: number): { string }
	local seen: { [string]: boolean } = {}
	local list: { string } = {}
	for _, item in LootConfig.pool(zoneIndex) do
		if not seen[item.rarity] then
			seen[item.rarity] = true
			table.insert(list, item.rarity)
		end
	end
	table.sort(list, function(a, b)
		return RarityConfig.rank(a) > RarityConfig.rank(b)
	end)
	return { list[1], list[2] }
end

export type RollRow = { item: LootConfig.ItemDef, chance: number }

--- The vault roll table: every item of the top two rarities with its chance
--- (the chances sum to 1).
function VaultConfig.rollTable(zoneIndex: number): { RollRow }
	local tiers = VaultConfig.topRarities(zoneIndex)
	local rows: { RollRow } = {}
	local tierTotal = 0
	for tier, rarity in tiers do
		local weight = VaultConfig.TIER_WEIGHTS[tier] or 0
		local sum = 0
		for _, item in LootConfig.pool(zoneIndex) do
			if item.rarity == rarity then
				sum += item.weight
			end
		end
		if sum <= 0 or weight <= 0 then
			continue
		end
		tierTotal += weight
		for _, item in LootConfig.pool(zoneIndex) do
			if item.rarity == rarity then
				table.insert(rows, { item = item, chance = weight * item.weight / sum })
			end
		end
	end
	for _, row in rows do
		row.chance /= math.max(tierTotal, 1e-9)
	end
	return rows
end

--- One vault roll. `roll` is a number in [0, 1).
function VaultConfig.pick(zoneIndex: number, roll: number): LootConfig.ItemDef?
	local rows = VaultConfig.rollTable(zoneIndex)
	local cursor = 0
	for _, row in rows do
		cursor += row.chance
		if roll < cursor then
			return row.item
		end
	end
	local last = rows[#rows]
	return if last then last.item else nil
end

-- ==========================================================
-- ART (placeholders; see docs/codex-prompts/vaults-crews.md)
-- ==========================================================

--- "rbxassetid://0" means "not made yet": the code skips it.
VaultConfig.Art = {
	--- MeshPart replacing the placeholder round door (ServerStorage.GameAssets.Vault.VaultDoor).
	DoorModelName = "VaultDoor",
	--- Interior decor set (ServerStorage.GameAssets.Vault.VaultDecor), optional.
	DecorModelName = "VaultDecor",
	--- The "VAULT RESTOCKED!" banner image shown with the restock toast.
	RestockBanner = "rbxassetid://0",
}

return VaultConfig
