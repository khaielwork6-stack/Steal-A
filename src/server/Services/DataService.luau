--!strict
--[[
	DataService
	Profile load / save / migration (GDD section 17).

	Single responsibility: owning the durable player profile. No gameplay logic
	lives here - other services read and mutate the profile table they are handed
	and DataService decides when it reaches the DataStore.

	Durability rules:
	  * Placed display items are the durable truth.
	  * World loot and in-progress carries are session state and are NEVER saved.
	    A player who disconnects mid-carry loses the carry; the item returns to
	    its origin socket.
	  * Autosave on an interval, on PlayerRemoving, and on BindToClose.

	SESSION LOCKING
	  Roblox does NOT guarantee one server per user: on a fast server hop the
	  new server's join can read the profile before the old server's leave-save
	  has landed, and a plain "last writer wins" save then rolls the player back
	  (or duplicates what they carried across). So every stored document names
	  the ONE session allowed to write it:

	      document.SessionLock = { JobId = <session id>, PlaceId, At = os.time() }

	  The document is still the profile table itself (plus that one field), so
	  every save written before locking existed loads unchanged - it simply has
	  no lock, which reads as "free".

	  LOAD (UpdateAsync). Absent, ours, or stale lock (At older than
	  DATA_LOCK_STALE_SECONDS) -> take it and read the profile in the same
	  atomic step. Held by another LIVE session -> write nothing, wait
	  DATA_LOCK_RETRY_SECONDS and look again; that server's leave-save clears
	  the lock within seconds. After DATA_LOCK_WAIT_SECONDS it is taken over
	  anyway (the other server is hung or the player is genuinely in two
	  places); from that moment every save the old session attempts is refused
	  below, so nothing it writes can overwrite the newer session.

	  SAVE (UpdateAsync). The stored lock must still be OURS, else the write is
	  cancelled (the transform returns nil), the session is marked LOST, the
	  player is kicked with an explanation and that profile is never written by
	  this server again. Otherwise the profile is written with a refreshed At.
	  A lock that is simply MISSING also counts as "not ours": only a release
	  (ours or another server's) clears it, so a missing lock means another
	  session has been and gone since we loaded.

	  RELEASE (leave / shutdown), in this order:
	      1. before-release hooks  (state held back during play is committed)
	      2. save with the lock CLEARED, retried with backoff
	      3. drop the profile from memory, then the after-release hooks
	  The lock is cleared in the SAME write that stores the final profile, so
	  a new server can never read the profile between "lock gone" and "final
	  data written".

	  STUDIO. game.JobId is "" there, so the session id is "studio-<GUID>",
	  generated once per server run: two Studio test servers are two sessions.

	  The lock lives ONLY in the stored document. The in-memory profile never
	  carries it (it is stripped on load and added to a shallow copy on save),
	  so it cannot leak to a client, a push, or a persistTest round trip.

	SAVE COALESCING
	  At most ONE UpdateAsync per player is in flight. A save requested while one
	  is running is queued; however many arrive, exactly one more write runs
	  after the current one, and every caller waiting on it gets THAT write's
	  result - which, having started after their call, covers their state.
	  `save` therefore still yields and still answers "is the state as of my
	  call durable?", which is what ProcessReceipt relies on.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HatchConfig = require(ReplicatedStorage.Shared.Config.HatchConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local PvPConfig = require(ReplicatedStorage.Shared.Config.PvPConfig)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)
local StarterTaskConfig = require(ReplicatedStorage.Shared.Config.StarterTaskConfig)

local SCHEMA_VERSION = 13
local STORE_NAME = "PlayerProfiles_v1"

--- The longest a growth value may claim. NightService stops crediting an
--- item at its own MaturationSeconds; this is only the sanity bound a corrupt
--- save is clamped to on load.
local GROWTH_SECONDS_SANITY = 86400

local DataService = {}

export type DisplayItem = {
	InstanceId: string,
	ItemId: string,
	ZoneId: number,
	Rarity: string,
	Size: string,
	Mutation: string,
	BaseIncome: number,
	FinalIncome: number,
	SlotIndex: number,
	--- The exact visual scale rolled inside the Size tier when the instance
	--- spawned (v6). Absent on older saves; reconcile fills the tier's default.
	VisualScale: number?,
	--- Which visual ladder VisualScale was rolled inside (v9). Equal to
	--- RarityConfig.SIZE_VISUAL_VERSION once the item has been rolled or
	--- migrated into the current ranges; anything lower (or absent, on a
	--- pre-v9 profile) is a legacy roll the v9 migration maps EXACTLY ONCE.
	SizeVisualVersion: number?,
	--- THE ECONOMY SCALE (v10). One continuous, server-rolled number; income
	--- is a function of it (ScaleConfig.sizeFactor) and of nothing else about
	--- size. A legacy item gets the Scale whose sizeFactor equals its old
	--- word's multiplier, so its income is preserved to the dollar.
	Scale: number?,
	--- v10. A legacy item's pre-rebuild look, kept so it still stands at the
	--- size it always did while earning from its (much smaller) Scale. Nil on
	--- everything rolled since the rebuild: those look exactly their Scale.
	LegacyVisualScale: number?,
	--- v10. Growth credit the item needs before it earns (base growth time x
	--- ScaleConfig.growthMultiplier). 0 = earns from placement.
	MaturationSeconds: number?,
	--- v10. Stamped ScaleConfig.ECONOMY_SCALE_VERSION when Scale was rolled
	--- or migrated onto the current ladder, so the migration never runs twice.
	EconomyScaleVersion: number?,
	--- v11. THE MYSTERY LOOP. False while the item is still a sealed container
	--- incubating on its pedestal; true once it has been hatched and revealed.
	--- An item that is not hatched shows a container, earns NOTHING, and keeps
	--- its identity hidden from every client. Every item saved before v11 is
	--- already hatched and is migrated as such - nobody re-hatches a collection
	--- they already own.
	Hatched: boolean?,
	--- v11. Unix second (os.time) the incubation finishes. Server-authoritative
	--- and absolute, so the timer runs while the player is offline, across a
	--- server hop and through a shutdown. Nil once hatched.
	HatchEndsAt: number?,
	--- v11. The spawn token the container carried out of its zone. Lets a hatch
	--- request name exactly one container and makes a replayed or racing
	--- request identifiable.
	SpawnToken: string?,
	--- Seconds of effective growth accrued while on display (v6). Capped by
	--- NightService; drives the maturity income/size bonus.
	GrowthSeconds: number?,
	--- Unix second until which no other player may steal this item (v7).
	--- Set on a successful robbery; travels with the item through store and
	--- re-display, so it cannot be shaken off by moving it. Nil = unprotected.
	ProtectedUntil: number?,
	--- SESSION ONLY: the UserId of the thief currently carrying this item
	--- away. While set the item earns nothing and its slot shows as robbed.
	--- Cleared on every load - a robbery never survives a session - and
	--- resolved by HeistService before the owner's profile is saved on leave.
	RobbedBy: number?,
}

export type Profile = {
	SchemaVersion: number,
	Cash: number,
	SpeedPower: number,
	BaseActivated: boolean,
	BaseCapacityTier: number,
	TreadmillLevel: number,
	TrapCount: number,
	TutorialStage: number,
	HighestZoneReached: number,
	Index: { [string]: boolean },
	ClaimedIndexRewards: { [string]: boolean },
	DisplayItems: { DisplayItem },
	Inventory: { DisplayItem }, -- stored, not earning; SlotIndex is unused here
	StorageTier: number,
	Lifetime: { Steals: number, PvPSteals: number, Secrets: number, CashEarned: number },
	--- The Settings panel. Volumes are 0-1 mixer levels; Shadows drives
	--- Lighting.GlobalShadows on the client; ReducedVFX is the Reduced Effects
	--- switch (no pop-ins, bobbing, breathing, sparkles or lighting tweens).
	Settings: {
		ReducedVFX: boolean,
		ScreenShake: boolean,
		MusicVolume: number?,
		SfxVolume: number?,
		Shadows: boolean?,
	},
	-- Robux purchase ids already granted. This MUST be durable: ProcessReceipt is
	-- retried across sessions and servers, so an in-memory set would re-grant a
	-- replayed receipt after a rejoin. Bounded - see MonetizationService.
	ProcessedReceipts: { string },
	-- The one-time onboarding Cash bridge (GameConfig.TUTORIAL_CASH_BRIDGE).
	-- Durable for the same reason as the receipt list: an in-memory flag would
	-- hand out another $1,000 on every rejoin.
	TutorialBridgeGranted: boolean,
	-- Trails bought with CASH. Robux trails are not listed here - Roblox owns
	-- that answer and MonetizationService asks it, so a refund or a revoke is
	-- reflected instead of being frozen into the save.
	TrailsOwned: { [string]: boolean },
	-- The equipped trail's key, or "" for none. Exactly one at a time.
	EquippedTrail: string,
	-- The one-time +10,000 Speed for joining the group. Durable for the same
	-- reason as the receipt list: an in-memory flag would pay out again on every
	-- rejoin. See GroupGiftService.
	GroupGiftClaimed: boolean,
	-- v7. Which OWNED base guardian stands in the bay ("" = none). Ownership
	-- is otherwise not stored: the Game Pass is the source of truth and
	-- BaseGuardianService re-checks it before spawning anything.
	EquippedGuardian: string,
	-- v13. Base guardians WON on the spin wheel, by key. The one exception to
	-- the rule above, and it has to be durable for the same reason the receipt
	-- list is: Roblox cannot be asked about a guardian it never sold, so if
	-- this were in memory a rejoin would take the prize back.
	--
	-- It is only ever ADDED to, and only by SpinWheelService. Losing it is the
	-- one failure this schema cannot repair, so nothing clears it.
	GuardiansWon: { [string]: boolean },
	-- v7. "Bat" or "Slap". The Slap is validated against its Game Pass on
	-- every join; an unowned selection falls back to the Bat.
	EquippedWeapon: string,
	-- v7. A base steal whose purchase prompt was opened and not yet resolved:
	-- kept durable so a Developer Product receipt that lands after a rejoin
	-- can still be matched to the item it paid for. See HeistService.
	PendingSteal: any?,
	-- v12. An Instant Reveal whose purchase prompt was opened and not yet
	-- resolved: { instanceId, productId }. Durable so a receipt that lands
	-- after a rejoin still reveals the container it paid for. See HatchService.
	PendingReveal: any?,
	-- v12. The one-time opening popup has been shown. Durable so it never
	-- returns after a respawn or a rejoin.
	TutorialIntroSeen: boolean,
	-- v8. Offline earnings (OfflineService). All three are written by the
	-- SERVER only. `LastLeaveTimestamp` is the os.time() of the last save;
	-- `OfflineCashRate` the authoritative $/s at that moment; and
	-- `PendingOfflineCash` the capped payout computed on the next load, held
	-- until the player claims it. 0 / 0 / 0 means "nothing owed".
	LastLeaveTimestamp: number,
	OfflineCashRate: number,
	PendingOfflineCash: number,
	-- SESSION ONLY, despite living here. Unix second the empty trap clip
	-- refills (0 = traps available now). `reconcile` forces this to 0 and
	-- TrapCount to full on every load, so a rejoin is always a clean clip -
	-- see the TRAPS block there for why it stopped being durable.
	TrapReadyAt: number,
	-- [monetization pass] A free-spin prize that has been rolled and spent but
	-- not yet paid: { Index, Kind, Amount, GuardianKey, At }. Saved with the
	-- spend and cleared at the landing, so a crash mid-spin pays it on the
	-- next join instead of losing it. Additive (nil = nothing owed), so no
	-- schema bump. Written and read only by SpinWheelService.
	PendingSpinPrize: any?,
	-- v13. Seconds of ACTUAL PLAY accrued toward the next free spin, 0 to
	-- SpinWheelConfig.PLAY_SECONDS.
	--
	-- Deliberately a DURATION and not a deadline - the exact opposite of
	-- TrapReadyAt above. The trap recharges on the wall clock and should keep
	-- ticking while the player is away; the spin is earned by playing, so it
	-- must not. A timestamp would hand a spin to anyone who left for ten
	-- minutes, so what is saved is how far they got and the clock is rebuilt
	-- from it on every join. See SpinWheelService.
	SpinProgress: number,
	-- v13. The beginner checklist: task key -> true once its reward has been
	-- granted. Durable because the reward is one-time; an in-memory set would
	-- pay all three again on every rejoin.
	StarterTasks: { [string]: boolean },
	-- v13. The checklist is finished AND its celebration has been seen, so it
	-- is gone for good. Separate from "all three done" so the completion
	-- animation gets a moment to play before the panel is retired forever.
	StarterTasksClosed: boolean,
	-- The ids of MailboxService entries already granted to this profile, newest
	-- last, capped at GameConfig.MAILBOX_DELIVERED_MEMORY. Durable because it
	-- is what makes delivery idempotent: an entry granted and saved but not
	-- yet removed from the mailbox (a crash in between) is recognised here
	-- and only removed the second time, never granted again. Added by
	-- `reconcile` (an empty list is the only correct value for an old save),
	-- so no schema bump was needed.
	DeliveredMail: { string },
	-- [polish-events-analytics] The first-join camera flyover has been seen
	-- (or skipped). A profile saved before the flyover existed reads as seen
	-- if its player had ever started (see reconcile), so only brand-new
	-- players get it.
	FlyoverSeen: boolean,
	-- [polish-events-analytics] Onboarding funnel steps already logged to
	-- AnalyticsService, by step key. Durable because Roblox counts each step
	-- once per player. `{ legacy = true }` marks a profile that existed
	-- before analytics: those players are not new and are never logged.
	AnalyticsOnboarding: { [string]: boolean },
	-- STORED DOCUMENT ONLY - always nil on an in-memory profile. See the
	-- SESSION LOCKING section in the header.
	SessionLock: SessionLock?,
}

export type SessionLock = {
	JobId: string,
	PlaceId: number,
	At: number,
}

local store: DataStore? = nil
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}

--- True when saves go to a DataStore. A LIVE server always does: an outage
--- there is handled by load's retry-and-kick path, never by quietly running
--- on blank in-memory profiles (players would look wiped and receipts would
--- be granted unsaved). Only Studio without API access falls back to memory,
--- decided by the probe in `start`.
local useDataStore = not RunService:IsStudio()

--- This server's session id for the lock. JobId is empty in Studio, so
--- Studio gets a GUID of its own, fixed for the life of this server.
local sessionId: string = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local function defaultProfile(): Profile
	return {
		SchemaVersion = SCHEMA_VERSION,
		Cash = GameConfig.STARTING_CASH,
		SpeedPower = GameConfig.STARTING_SPEED_POWER,
		-- A base is ACTIVE from the moment it is assigned. There is no longer a
		-- separate "activate your base" purchase - being given a plot IS the
		-- activation. `reconcile` forces this true on every load, including for
		-- profiles saved back when it was something you had to buy.
		BaseActivated = true,
		BaseCapacityTier = 0,
		-- Level 1 comes with the base, for the same reason.
		TreadmillLevel = 1,
		TrapCount = GameConfig.STARTING_TRAPS,
		TutorialStage = 0,
		HighestZoneReached = 1,
		Index = {},
		ClaimedIndexRewards = {},
		DisplayItems = {},
		Inventory = {},
		StorageTier = 0,
		Lifetime = { Steals = 0, PvPSteals = 0, Secrets = 0, CashEarned = 0 },
		Settings = { ReducedVFX = false, ScreenShake = true, MusicVolume = 0.7, SfxVolume = 0.8, Shadows = true },
		ProcessedReceipts = {},
		TutorialBridgeGranted = false,
		TrailsOwned = {},
		EquippedTrail = "",
		GroupGiftClaimed = false,
		EquippedGuardian = "",
		GuardiansWon = {},
		EquippedWeapon = "Bat",
		PendingSteal = nil,
		PendingReveal = nil,
		TutorialIntroSeen = false,
		LastLeaveTimestamp = 0,
		OfflineCashRate = 0,
		PendingOfflineCash = 0,
		TrapReadyAt = 0,
		-- A brand-new player starts the full five minutes from their first spin.
		SpinProgress = 0,
		StarterTasks = {},
		StarterTasksClosed = false,
		DeliveredMail = {},
		-- [polish-events-analytics] A brand-new profile is the only kind
		-- that starts unseen / un-logged.
		FlyoverSeen = false,
		AnalyticsOnboarding = {},
		-- Never set in memory; see SessionLock above.
		SessionLock = nil,
	}
end

--- Explicit, additive migrations. Never silently drop unknown fields.
local function migrate(profile: Profile): Profile
	local version = profile.SchemaVersion or 0

	if version < 1 then
		-- Pre-versioned saves: fill anything the schema expects.
		local defaults = defaultProfile()
		for key, value in defaults :: any do
			if (profile :: any)[key] == nil then
				(profile :: any)[key] = value
			end
		end
		profile.SchemaVersion = 1
	end

	if version < 2 then
		-- v2 introduced storage: taking an item off display now stores it rather
		-- than selling it, so existing saves need somewhere to put it.
		if type(profile.Inventory) ~= "table" then
			profile.Inventory = {}
		end
		if type(profile.StorageTier) ~= "number" then
			profile.StorageTier = 0
		end
		profile.SchemaVersion = 2
	end

	if version < 3 then
		-- v3 introduced Robux purchases. An existing player has never had a
		-- receipt granted, so an empty list is correct and cannot re-grant.
		if type(profile.ProcessedReceipts) ~= "table" then
			profile.ProcessedReceipts = {}
		end
		profile.SchemaVersion = 3
	end

	if version < 4 then
		-- v4 is the economy rebalance.
		--
		-- The one-time tutorial Cash bridge used to be seeded here. It is now
		-- retired entirely (base activation is free, so there was nothing left
		-- for it to pay for) and `reconcile` marks every profile as having had
		-- it, so nothing can be granted retroactively.
		--
		-- Stored per-item income is NOT migrated here: `reconcile` recomputes
		--    BaseIncome, Rarity and FinalIncome from the live config on EVERY
		--    load, for every profile, at every version. Doing it as a one-shot
		--    migration would freeze today's numbers into the save and leave the
		--    next economy change with the same problem this one had.
		profile.SchemaVersion = 4
	end

	if version < 5 then
		-- v5 adds the group-join gift. Nobody has claimed it yet, so false is the
		-- only correct value; a nil here would be read as unclaimed anyway, but
		-- the field is written so the schema is explicit.
		if type(profile.GroupGiftClaimed) ~= "boolean" then
			profile.GroupGiftClaimed = false
		end
		profile.SchemaVersion = 5
	end

	if version < 6 then
		-- v6 adds the exact visual scale and the growth clock to every saved item.
		-- An old item never rolled a scale, so it gets its tier's low end (what it
		-- was shown at until now - no saved collection changes size), and starts
		-- its growth from zero. Additive: nothing else on the item is touched.
		for _, list in { profile.DisplayItems, profile.Inventory } do
			if type(list) == "table" then
				for _, item in list do
					if type(item) == "table" then
						if type(item.VisualScale) ~= "number" then
							-- The LEGACY low end, not today's: this value is then carried
							-- through the v9 mapping below like any other pre-v9 roll, and
							-- lands on the new tier's low end.
							local legacy = RarityConfig.LegacySizeRanges[item.Size]
							item.VisualScale = if legacy then legacy[1] else 1
						end
						if type(item.GrowthSeconds) ~= "number" then
							item.GrowthSeconds = 0
						end
					end
				end
			end
		end
		profile.SchemaVersion = 6
	end

	if version < 7 then
		-- v7 adds base guardians, the weapon choice and base stealing. A player
		-- from before owns whatever Game Passes Roblox says they own (never
		-- stored here), has nothing equipped, and carries the Bat.
		if type(profile.EquippedGuardian) ~= "string" then
			profile.EquippedGuardian = ""
		end
		if type(profile.EquippedWeapon) ~= "string" then
			profile.EquippedWeapon = "Bat"
		end
		profile.SchemaVersion = 7
	end

	if version < 8 then
		-- v8 adds offline earnings. A player from before has no recorded
		-- departure, so their first load after this pays NOTHING: a zero
		-- timestamp is "never left", never "left at the epoch".
		if type(profile.LastLeaveTimestamp) ~= "number" then
			profile.LastLeaveTimestamp = 0
		end
		if type(profile.OfflineCashRate) ~= "number" then
			profile.OfflineCashRate = 0
		end
		if type(profile.PendingOfflineCash) ~= "number" then
			profile.PendingOfflineCash = 0
		end
		profile.SchemaVersion = 8
	end

	if version < 9 then
		-- v9: the size visual ladder moved (Big 1.35 -> 1.6, Huge 1.8 -> 2.5,
		-- Giant 2.6 -> 4, Titan 6-8 -> 7-10, Colossal 15-20 -> 16-22). Every
		-- saved item is mapped ONCE: fixed tiers to their new fixed scale, a
		-- ranged tier to the SAME relative position inside the new range, so
		-- the uniqueness of every existing Titan and Colossal survives. The
		-- item is then stamped SizeVisualVersion so this can never run twice,
		-- whatever version the profile says. Size tier, mutation, rarity,
		-- income, slot, protection and growth are not touched. Additive.
		for _, list in { profile.DisplayItems, profile.Inventory } do
			if type(list) == "table" then
				for _, item in list do
					if type(item) == "table" and (tonumber(item.SizeVisualVersion) or 0) < RarityConfig.SIZE_VISUAL_VERSION then
						item.VisualScale = RarityConfig.migrateVisualScale(item.Size, item.VisualScale)
						item.SizeVisualVersion = RarityConfig.SIZE_VISUAL_VERSION
					end
				end
			end
		end
		profile.SchemaVersion = 9
	end

	if version < 10 then
		-- v10: the continuous economy Scale replaces the six discrete size
		-- multipliers. Every saved item is mapped ONCE:
		--   * Scale = the value whose sizeFactor equals the multiplier its
		--     size WORD carried (1 / 1.35 / 2 / 3.5 / 4.5 / 6), solved through
		--     the inverse curve - so the income it earned before this patch
		--     is the income it earns after, to the dollar. The old visual scale
		--     is NOT used for this: a 22x Colossal read as Scale 22 would earn
		--     nearly twenty times what it did.
		--   * LegacyVisualScale = its old VisualScale, so it still LOOKS the
		--     size it always did on the pedestal.
		--   * MaturationSeconds = 0: it was already earning, so it keeps earning.
		--   * EconomyScaleVersion stamped, so this can never run twice.
		-- Size word, mutation, rarity, income fields, slot, protection and
		-- growth are not touched. Additive.
		for _, list in { profile.DisplayItems, profile.Inventory } do
			if type(list) == "table" then
				for _, item in list do
					if type(item) == "table" and (tonumber(item.EconomyScaleVersion) or 0) < ScaleConfig.ECONOMY_SCALE_VERSION then
						local multiplier = RarityConfig.LegacySizeIncomeMultipliers[item.Size] or 1
						item.Scale = ScaleConfig.roundScale(ScaleConfig.inverseSizeFactor(multiplier))
						if type(item.VisualScale) == "number" and item.VisualScale == item.VisualScale then
							item.LegacyVisualScale = item.VisualScale
						end
						if type(item.MaturationSeconds) ~= "number" then
							item.MaturationSeconds = 0
						end
						item.EconomyScaleVersion = ScaleConfig.ECONOMY_SCALE_VERSION
					end
				end
			end
		end
		profile.SchemaVersion = 10
	end

	if version < 11 then
		-- The trap becomes a recharging ability. A player from before has no
		-- cooldown to serve, so their trap is ready the moment they arrive.
		if type(profile.TrapReadyAt) ~= "number" then
			profile.TrapReadyAt = 0
		end
		-- v11 introduces the mystery container and the hatch timer. EVERY item
		-- that already existed is a revealed, earning trophy: it is stamped
		-- Hatched and given no timer, so an existing collection keeps earning
		-- exactly as it did and nobody is asked to re-hatch what they own.
		for _, list in { profile.DisplayItems, profile.Inventory } do
			if type(list) == "table" then
				for _, item in list do
					if type(item) == "table" and item.Hatched == nil then
						item.Hatched = true
						item.HatchEndsAt = nil
					end
				end
			end
		end
		profile.SchemaVersion = 11
	end

	if version < 12 then
		-- The opening popup is new. A player who has already stolen anything
		-- has already started, and is not shown a first-start message now.
		if type(profile.TutorialIntroSeen) ~= "boolean" then
			profile.TutorialIntroSeen = (tonumber(profile.TutorialStage) or 0) > 0
		end
		-- Storing a sealed container is refused from v12, and the raw
		-- Inventory list is what the storage panel renders - so a container
		-- that reached storage under v11 would name its reward there. Nothing
		-- released ever wrote one (v11 and v12 shipped together); a Studio
		-- save that did is revealed in place rather than left to leak.
		if type(profile.Inventory) == "table" then
			for _, item in profile.Inventory do
				if type(item) == "table" and item.Hatched == false then
					item.Hatched = true
					item.HatchEndsAt = nil
					warn(`[DataService] v12: sealed container {tostring(item.InstanceId)} found in storage; revealed in place`)
				end
			end
		end
		profile.SchemaVersion = 12
	end

	if version < 13 then
		-- v13 adds the recurring free spin and the beginner checklist.
		--
		-- An existing player has won no guardian on the wheel, has earned no
		-- spin progress, and has completed no checklist row - all three are
		-- empty rather than back-filled. In particular the checklist is NOT
		-- pre-completed for a veteran: it is three small rewards for three
		-- things they do in the first minute of any session anyway, and
		-- guessing which ones they have "already done" from lifetime counters
		-- would hand out rewards for actions taken before the feature existed.
		if type(profile.GuardiansWon) ~= "table" then
			profile.GuardiansWon = {}
		end
		if type(profile.SpinProgress) ~= "number" then
			profile.SpinProgress = 0
		end
		if type(profile.StarterTasks) ~= "table" then
			profile.StarterTasks = {}
		end
		if type(profile.StarterTasksClosed) ~= "boolean" then
			profile.StarterTasksClosed = false
		end
		profile.SchemaVersion = 13
	end

	-- Future migrations chain here: if version < 14 then ... end

	return profile
end

--- Rebuilds one saved item's economy fields from the live configs.
---
--- The DURABLE identity of a trophy is ItemId + Size + Mutation (+ InstanceId and
--- SlotIndex for bookkeeping). Its income is NOT durable and is never trusted
--- from the save: a $967/s Ancient Vase in an old profile must become a $1/s
--- Ancient Vase the moment it loads, or the old economy simply carries on inside
--- existing accounts.
---
--- Deterministic and idempotent: the output depends only on the item's identity
--- and the current config, so repeated joins - and a join after a failed save -
--- converge on exactly the same numbers instead of drifting.
local function reconcileItem(item: DisplayItem): boolean
	local def = LootConfig.ById[item.ItemId]
	if not def then
		-- An id we no longer ship. Leave it completely alone rather than zeroing
		-- someone's trophy; it is still theirs and may come back.
		return false
	end

	local changed = false
	local mutation = RarityConfig.normaliseMutation(item.Mutation)
	if mutation ~= item.Mutation then
		item.Mutation = mutation
		changed = true
	end
	if type(item.Size) ~= "string" or not RarityConfig.SizeById[item.Size] then
		item.Size = "Normal"
		changed = true
	end

	-- THE SCALE must be a finite number inside the roll's range. An item that
	-- arrives without one on a current-schema profile (built by a path that
	-- forgot it) is a Scale-1 copy - never remapped from its word, because the
	-- v10 migration is the only place that mapping may happen, and it stamps.
	local scale = if type(item.Scale) == "number" then ScaleConfig.clampScale(item.Scale) else 1
	if item.Scale ~= scale then
		item.Scale = scale
		changed = true
	end
	if item.EconomyScaleVersion ~= ScaleConfig.ECONOMY_SCALE_VERSION then
		item.EconomyScaleVersion = ScaleConfig.ECONOMY_SCALE_VERSION
		changed = true
	end
	-- A legacy look, if it has one, is a finite positive number; otherwise
	-- the item is shown at its Scale and VisualScale mirrors it.
	local legacyVisual = tonumber(item.LegacyVisualScale)
	if legacyVisual ~= nil and (legacyVisual ~= legacyVisual or legacyVisual <= 0 or legacyVisual == math.huge) then
		item.LegacyVisualScale = nil
		legacyVisual = nil
		changed = true
	end
	local displayScale = legacyVisual or scale
	if item.VisualScale ~= displayScale then
		item.VisualScale = displayScale
		changed = true
	end
	if item.SizeVisualVersion ~= RarityConfig.SIZE_VISUAL_VERSION then
		item.SizeVisualVersion = RarityConfig.SIZE_VISUAL_VERSION
		changed = true
	end
	-- The size WORD: derived from Scale for everything rolled since the
	-- rebuild; a legacy item keeps the word it was saved with, which matches
	-- the size it still shows.
	if legacyVisual == nil then
		local label = RarityConfig.sizeLabelFor(scale)
		if item.Size ~= label then
			item.Size = label
			changed = true
		end
	end
	-- THE HATCH STATE. An item with no flag at all is a pre-v11 trophy that
	-- reached reconcile without passing migrate (a hand-built record, a debug
	-- grant): treat it as hatched, because an item that is already on a
	-- pedestal earning is never a sealed container.
	if type(item.Hatched) ~= "boolean" then
		item.Hatched = true
		changed = true
	end
	-- A hatched item carries no timer, and an incubating one carries a finite
	-- absolute second. Anything else is repaired rather than trusted: a
	-- corrupt timestamp must not strand a container forever.
	if item.Hatched then
		if item.HatchEndsAt ~= nil then
			item.HatchEndsAt = nil
			changed = true
		end
	else
		local ends = tonumber(item.HatchEndsAt)
		if ends == nil or ends ~= ends or ends == math.huge or ends <= 0 then
			-- No usable end time: it is ready NOW rather than never.
			item.HatchEndsAt = os.time()
			changed = true
		else
			-- NOTHING INCUBATES LONGER THAN THE CAP. A stamp further out than
			-- that cannot have been written by beginIncubation, so it is a
			-- corrupt or tampered value: pull it back to the longest wait the
			-- game can legitimately ask for rather than strand the container.
			local latest = os.time() + HatchConfig.MAX_SECONDS
			local repaired = math.min(ends, latest)
			if item.HatchEndsAt ~= repaired then
				item.HatchEndsAt = repaired
				changed = true
			end
		end
	end

	-- Maturation is seconds, finite and non-negative.
	local maturation = tonumber(item.MaturationSeconds) or 0
	if maturation ~= maturation or maturation == math.huge or maturation < 0 then
		maturation = 0
	end
	if item.MaturationSeconds ~= maturation then
		item.MaturationSeconds = maturation
		changed = true
	end

	-- Growth is seconds, finite, non-negative, and never absurd.
	local growth = tonumber(item.GrowthSeconds) or 0
	if growth ~= growth or growth == math.huge or growth == -math.huge then
		growth = 0
	end
	growth = math.clamp(growth, 0, GROWTH_SECONDS_SANITY)
	if item.GrowthSeconds ~= growth then
		item.GrowthSeconds = growth
		changed = true
	end

	-- A robbery is session state. Whatever the save says, nobody is carrying
	-- this item away when it loads.
	if item.RobbedBy ~= nil then
		item.RobbedBy = nil
		changed = true
	end
	-- Protection is an absolute Unix second, finite and in the future or gone.
	local protectedUntil = tonumber(item.ProtectedUntil)
	if protectedUntil == nil or protectedUntil ~= protectedUntil or protectedUntil <= os.time() then
		if item.ProtectedUntil ~= nil then
			item.ProtectedUntil = nil
			changed = true
		end
	elseif item.ProtectedUntil ~= protectedUntil then
		item.ProtectedUntil = protectedUntil
		changed = true
	end

	local zoneId = LootConfig.ZoneOf[item.ItemId]
	if item.ZoneId ~= zoneId then
		item.ZoneId = zoneId
		changed = true
	end
	if item.Rarity ~= def.rarity then
		item.Rarity = def.rarity
		changed = true
	end
	if item.BaseIncome ~= def.income then
		item.BaseIncome = def.income
		changed = true
	end

	-- The card rate: base x sizeFactor(Scale) x mutation at moneyPass 1,
	-- rebuilt from the live curve on every load. Never trusted from the save.
	local final = RarityConfig.finalIncome(def.income, scale, item.Mutation)
	if item.FinalIncome ~= final then
		item.FinalIncome = final
		changed = true
	end

	return changed
end

DataService.reconcileItem = reconcileItem
--- Exposed for the regression tests only: the same migration chain a load runs.
DataService.migrate = migrate

--- Repairs a loaded profile so a corrupt or partial save cannot crash services.
local function reconcile(profile: Profile): Profile
	-- [polish-events-analytics] BEFORE the defaults are copied in: a save
	-- that predates these fields belongs to a player who has already joined,
	-- so it must not pick up the brand-new-player defaults below. A save
	-- with any tutorial progress (or the intro seen) counts as started.
	do
		local raw = profile :: any
		local started = (tonumber(raw.TutorialStage) or 0) > 0 or raw.TutorialIntroSeen == true
		if type(raw.FlyoverSeen) ~= "boolean" then
			raw.FlyoverSeen = started
		end
		if type(raw.AnalyticsOnboarding) ~= "table" then
			raw.AnalyticsOnboarding = if started then { legacy = true } else {}
		end
	end

	local defaults = defaultProfile()
	for key, value in defaults :: any do
		if (profile :: any)[key] == nil then
			(profile :: any)[key] = value
		end
	end

	profile.Cash = math.max(0, tonumber(profile.Cash) or 0)
	profile.SpeedPower = math.max(GameConfig.STARTING_SPEED_POWER, tonumber(profile.SpeedPower) or 0)

	-- TRAPS ARE SESSION STATE. Both fields are forced on EVERY load, whatever
	-- the save says: joining a server hands over a full clip and a clear
	-- refill clock, exactly like a robbery is never carried across a session.
	--
	-- They used to be durable, and that was the bug. Placing a trap never
	-- decremented the count, so the only way a profile could hold a number was
	-- to have been left at one by an older build - and a zero left there was
	-- permanent. Players joined to "You have no traps left" having never
	-- placed one, with nothing that could ever give them back.
	--
	-- The fields stay in the schema so old saves load cleanly and so the value
	-- has somewhere to live during a session; nothing reads them off the disk.
	profile.TrapCount = PvPConfig.TRAP_CAPACITY
	profile.TrapReadyAt = 0
	profile.HighestZoneReached = math.clamp(math.floor(tonumber(profile.HighestZoneReached) or 1), 1, 12)

	if type(profile.DisplayItems) ~= "table" then
		profile.DisplayItems = {}
	end
	if type(profile.Inventory) ~= "table" then
		profile.Inventory = {}
	end
	profile.StorageTier = math.max(0, math.floor(tonumber(profile.StorageTier) or 0))

	-- A corrupt receipt list must never be silently replaced with an empty one:
	-- that would let every past receipt be granted a second time. Only repair it
	-- when it is not a table at all, which means there is nothing to lose.
	if type(profile.ProcessedReceipts) ~= "table" then
		profile.ProcessedReceipts = {}
	end

	-- THE BASE IS ALWAYS ACTIVE. Forced here rather than only in the default
	-- profile, so a save written while activation was still a purchase loads as
	-- active too. Everything that gates on this - placement, storage, income,
	-- the treadmill, prompts, the tutorial - therefore initialises correctly on
	-- the very first push, with no separate unlock step to go wrong.
	profile.BaseActivated = true
	profile.TreadmillLevel = math.max(1, math.floor(tonumber(profile.TreadmillLevel) or 1))

	-- Deprecated. The one-time onboarding grant existed only to pay for the
	-- $1,000 base activation; with activation free it has nothing to buy, so it
	-- is no longer awarded. The field is kept so old saves still load cleanly.
	if type(profile.TutorialBridgeGranted) ~= "boolean" then
		profile.TutorialBridgeGranted = true
	end

	-- Settings: every field present, typed and in range, whatever the save says.
	if type(profile.Settings) ~= "table" then
		profile.Settings = defaults.Settings
	end
	local settings = profile.Settings
	local function level(value: any, fallback: number): number
		if type(value) ~= "number" or value ~= value then
			return fallback
		end
		return math.clamp(value, 0, 1)
	end
	settings.MusicVolume = level(settings.MusicVolume, 0.7)
	settings.SfxVolume = level(settings.SfxVolume, 0.8)
	if type(settings.Shadows) ~= "boolean" then
		settings.Shadows = true
	end
	if type(settings.ReducedVFX) ~= "boolean" then
		settings.ReducedVFX = false
	end
	if type(settings.ScreenShake) ~= "boolean" then
		settings.ScreenShake = true
	end

	-- Trails. Only CASH unlocks live here; Robux trails are answered by Roblox
	-- ownership so a refund is reflected rather than frozen into the save.
	if type(profile.TrailsOwned) ~= "table" then
		profile.TrailsOwned = {}
	end
	if type(profile.EquippedTrail) ~= "string" then
		profile.EquippedTrail = ""
	end

	-- Base guardian and weapon selections: strings, validated against what
	-- the player actually OWNS by the services that spawn them, never here.
	if type(profile.EquippedGuardian) ~= "string" then
		profile.EquippedGuardian = ""
	end
	-- Guardians won on the wheel. Repaired only when it is not a table at all,
	-- for the same reason as the receipt list above: replacing a damaged one
	-- with an empty one would silently take a prize back, and unlike a Game
	-- Pass there is nobody else to ask.
	if type(profile.GuardiansWon) ~= "table" then
		profile.GuardiansWon = {}
	end
	if type(profile.EquippedWeapon) ~= "string" or profile.EquippedWeapon == "" then
		profile.EquippedWeapon = "Bat"
	end
	if type(profile.PendingSteal) ~= "table" then
		profile.PendingSteal = nil
	end
	if type(profile.PendingReveal) ~= "table" then
		profile.PendingReveal = nil
	end
	-- [monetization pass] Only a table can be a pending spin prize; its
	-- contents are re-validated by SpinWheelService before anything is paid.
	if type(profile.PendingSpinPrize) ~= "table" then
		profile.PendingSpinPrize = nil
	end
	if type(profile.TutorialIntroSeen) ~= "boolean" then
		profile.TutorialIntroSeen = false
	end

	-- The free spin's accrued play time. Finite, non-negative and never past a
	-- full cycle: a corrupt value must not bank several spins at once, and the
	-- safe direction for a broken clock here is "not ready yet".
	local spinProgress = tonumber(profile.SpinProgress) or 0
	if spinProgress ~= spinProgress or spinProgress == math.huge or spinProgress < 0 then
		spinProgress = 0
	end
	profile.SpinProgress = math.min(spinProgress, SpinWheelConfig.PLAY_SECONDS)

	-- The beginner checklist. Unknown keys are dropped (a row that no longer
	-- exists), and every kept value is a real boolean.
	if type(profile.StarterTasks) ~= "table" then
		profile.StarterTasks = {}
	end
	local tasks: { [string]: boolean } = {}
	for _, task in StarterTaskConfig.Tasks do
		if (profile.StarterTasks :: any)[task.key] == true then
			tasks[task.key] = true
		end
	end
	profile.StarterTasks = tasks
	if type(profile.StarterTasksClosed) ~= "boolean" then
		profile.StarterTasksClosed = false
	end
	-- A closed checklist stays closed; one that is closed without being
	-- finished (an older build, a hand-edited save) is simply finished.
	if profile.StarterTasksClosed then
		for _, task in StarterTaskConfig.Tasks do
			tasks[task.key] = true
		end
	end

	-- Offline earnings: finite, non-negative numbers, whatever the save says.
	-- A timestamp in the future (a clock skew, a tampered store) reads as
	-- "just left" so it can never pay for time that has not happened.
	local function finite(value: any): number
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return 0
		end
		return math.max(value, 0)
	end
	profile.LastLeaveTimestamp = math.min(finite(profile.LastLeaveTimestamp), os.time())
	profile.OfflineCashRate = math.floor(finite(profile.OfflineCashRate))
	profile.PendingOfflineCash = math.floor(finite(profile.PendingOfflineCash))

	-- MAILBOX IDEMPOTENCY. Only string ids are kept, newest last, capped. A
	-- non-table is replaced with an empty list - the worst that costs is one
	-- mailbox entry that was granted AND is still in the mailbox being granted
	-- again, which needs a crash in a sub-second window on top of a corrupt
	-- save.
	local delivered: { string } = {}
	if type(profile.DeliveredMail) == "table" then
		for _, id in profile.DeliveredMail do
			if type(id) == "string" then
				table.insert(delivered, id)
			end
		end
	end
	while #delivered > GameConfig.MAILBOX_DELIVERED_MEMORY do
		table.remove(delivered, 1)
	end
	profile.DeliveredMail = delivered

	-- The session lock is document metadata, never profile state. `load`
	-- strips it before this runs; clearing it here as well means a profile
	-- reconciled from any other source (a test round trip, a hand-built
	-- record) can never carry one into memory or out to a client.
	profile.SessionLock = nil

	-- Recompute every stored item's economy from the live config. Runs on EVERY
	-- load, deliberately: saved income is a cache of a config value, never a
	-- source of truth, so this is what stops an old economy living on inside
	-- existing accounts. Aggregate $/s is rebuilt by EconomyService.recalculate
	-- once the player is set up, from these repaired values.
	local repaired = 0
	for _, item in profile.DisplayItems do
		if reconcileItem(item) then
			repaired += 1
		end
	end
	for _, item in profile.Inventory do
		if reconcileItem(item) then
			repaired += 1
		end
	end
	if repaired > 0 then
		print(`[DataService] rebuilt income on {repaired} saved item(s) from the current economy`)
	end

	return profile
end

--- Exposed for the regression tests only: the same repair pass a load runs.
DataService.reconcile = reconcile

local function keyFor(userId: number): string
	return "player_" .. userId
end

local function key(player: Player): string
	return keyFor(player.UserId)
end

--- How many times a load retries a DataStore ERROR (not a held lock) before
--- the player is kicked.
local LOAD_ATTEMPTS = 4

--- Fires (player) whenever a load FINISHES - loaded, failed or abandoned -
--- so waitForProfile can wake on the event instead of polling.
local loadFinished = Instance.new("BindableEvent")

--- Players whose session was taken over by another server. Never saved again.
local sessionLost: { [Player]: boolean } = {}

--- UserIds with a lock-clearing write in flight on THIS server (a release, or
--- an abandoned load unlocking). A rejoin of the same user waits for it: that
--- write carries our own session id, so without the wait the new load would
--- take "our" lock and the old write would then clear it under the new session.
local releasing: { [number]: boolean } = {}

--- Players whose `release` is running, so PlayerRemoving and BindToClose never
--- both write the same profile.
local releasingPlayers: { [Player]: boolean } = {}

--- UpdateAsync calls made by saves this server run. Read by the coalescing test.
local writeCount = 0

--- Blocks until the profile is available. Returns nil if the load failed, the
--- player left first, or the optional timeout passed.
---
--- Event-based: wakes the moment the load finishes (however long it takes -
--- a join waiting on another server's session lock can take 20s) or the
--- player leaves. With no timeout it cannot hang: every load ends in a stored
--- profile or a kick, and both wake this.
function DataService.waitForProfile(player: Player, timeout: number?): Profile?
	local ready = profiles[player]
	if ready then
		return ready
	end
	if not player.Parent then
		return nil
	end

	-- Nothing between the check above and these connections yields, so a load
	-- that finishes cannot slip between them.
	local thread = coroutine.running()
	local finished = false
	local connections: { RBXScriptConnection } = {}
	local timer: thread? = nil
	local function finish()
		if finished then
			return
		end
		finished = true
		for _, connection in connections do
			connection:Disconnect()
		end
		if timer and timer ~= coroutine.running() then
			pcall(task.cancel, timer)
		end
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
	table.insert(
		connections,
		loadFinished.Event:Connect(function(who: Player)
			if who == player then
				finish()
			end
		end)
	)
	table.insert(
		connections,
		player.AncestryChanged:Connect(function()
			if not player.Parent then
				finish()
			end
		end)
	)
	if timeout then
		timer = task.delay(timeout, finish)
	end
	coroutine.yield()
	return profiles[player]
end

function DataService.get(player: Player): Profile?
	return profiles[player]
end

--- True when saves actually reach a DataStore.
---
--- ProcessReceipt must only report a purchase granted once the grant is durable,
--- so it needs to distinguish "the save failed" from "there is no DataStore in
--- this environment". Studio without API access is the latter: nothing can be
--- persisted, and refusing every receipt there would make purchases untestable.
---
--- ALWAYS true on a live server, even while the DataStore is down: there a
--- failed save must read as a failed save (receipt left open), never as "no
--- persistence here". So `not isPersistent()` can only ever be true in Studio.
function DataService.isPersistent(): boolean
	return useDataStore
end

--- True only in Studio with DataStore access off: profiles live in memory and
--- nothing is saved. The exact complement of isPersistent, named for callers
--- that want to say "this shortcut is Studio-only" out loud.
function DataService.isStudioMemoryMode(): boolean
	return not useDataStore
end

--- True once another server has taken this player's save over. Nothing of
--- theirs is written by this server again; they are being kicked.
function DataService.isSessionLost(player: Player): boolean
	return sessionLost[player] == true
end

-- ==========================================================
-- SESSION LOCK PRIMITIVES
-- ==========================================================
--
-- Both take the store and key explicitly so the Studio test
-- (DebugCommands/Data) can exercise them on a THROWAWAY key instead of a
-- real player's save.

local function openStore(): DataStore?
	if store then
		return store
	end
	local ok, opened = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = opened
	end
	return store
end

local function newLock(): SessionLock
	return { JobId = sessionId, PlaceId = game.PlaceId, At = os.time() }
end

--- True when `lock` belongs to ANOTHER session that is still fresh enough to
--- be alive. Absent, ours, unreadable or stale all read as free.
local function heldByOther(lock: any, now: number): boolean
	if type(lock) ~= "table" or lock.JobId == sessionId then
		return false
	end
	local at = tonumber(lock.At)
	if at == nil or at ~= at then
		return false
	end
	return now - at < GameConfig.DATA_LOCK_STALE_SECONDS
end

type ClaimOutcome = "taken" | "held" | "corrupt"

--- ONE atomic read-and-lock. "taken" returns the stored document (the lock
--- now ours; a brand-new key gets a locked default profile written straight
--- away so a second server cannot also believe it is empty). "held" writes
--- nothing. "corrupt" (a stored value that is not a table) writes nothing.
local function claim(target: DataStore, storeKey: string, takeover: boolean): (ClaimOutcome, any, any)
	local outcome: ClaimOutcome = "corrupt"
	local document: any = nil
	local holder: any = nil
	target:UpdateAsync(storeKey, function(stored: any): any
		-- UpdateAsync may run this more than once (a write conflict retries
		-- it), so every run decides from scratch.
		document = nil
		holder = nil
		if stored == nil then
			local fresh = defaultProfile() :: any
			fresh.SessionLock = newLock()
			outcome = "taken"
			document = fresh
			return fresh
		end
		if type(stored) ~= "table" then
			outcome = "corrupt"
			return nil
		end
		local lock = stored.SessionLock
		if heldByOther(lock, os.time()) then
			holder = lock.JobId
			if not takeover then
				outcome = "held"
				return nil
			end
		end
		stored.SessionLock = newLock()
		outcome = "taken"
		document = stored
		return stored
	end)
	return outcome, document, holder
end

--- ONE guarded write. Writes `profile` (a shallow copy, plus the lock) only
--- if the stored lock is still ours. Returns (written, rejected, holder):
--- `rejected` means the lock was someone else's or missing and nothing was
--- written; an ERROR is thrown, so callers pcall this.
local function writeGuarded(target: DataStore, storeKey: string, profile: any, clearLock: boolean): (boolean, boolean, any)
	local rejected = false
	local holder: any = nil
	writeCount += 1
	target:UpdateAsync(storeKey, function(stored: any): any
		rejected = false
		holder = nil
		local lock = if type(stored) == "table" then stored.SessionLock else nil
		if type(lock) ~= "table" or lock.JobId ~= sessionId then
			rejected = true
			holder = if type(lock) == "table" then lock.JobId else nil
			return nil
		end
		-- A SHALLOW copy, so the live profile never carries the lock. The copy
		-- shares every nested table with the live profile, exactly as the old
		-- "return profile" did; the value is encoded before this call returns.
		local document = table.clone(profile)
		document.SessionLock = if clearLock then nil else newLock()
		return document
	end)
	return not rejected, rejected, holder
end

--- Clears our lock without writing any profile data. Used when a load took
--- the lock but the profile never went live (the player left mid-load, or
--- the document could not be read), so their next join is not made to wait.
local function unlockOnly(userId: number)
	local target = store
	if not target then
		return
	end
	releasing[userId] = true
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			target:UpdateAsync(keyFor(userId), function(stored: any): any
				if type(stored) ~= "table" or type(stored.SessionLock) ~= "table" or stored.SessionLock.JobId ~= sessionId then
					return nil
				end
				stored.SessionLock = nil
				return stored
			end)
		end)
		if ok then
			break
		end
		warn(`[DataService] unlock attempt {attempt} failed for user {userId}: {err}`)
		if attempt < 3 then
			task.wait(attempt)
		end
	end
	releasing[userId] = nil
end

--- Marks a player's session as lost and removes them. Idempotent.
local function loseSession(player: Player, holder: any)
	if sessionLost[player] then
		return
	end
	sessionLost[player] = true
	warn(
		`[DataService] {player.Name}'s save is now owned by another session ({tostring(holder or "lock released")}); `
			.. "this server will never write it again"
	)
	if player.Parent then
		pcall(function()
			player:Kick("Your progress was opened in another server. Please rejoin to keep playing.")
		end)
	end
end

--- Waits for any lock-clearing write for this user on this server, then
--- takes the lock (waiting out another live session, then taking it over).
--- Returns ("ok", document) | ("left", nil) | ("failed", reason).
local function acquire(player: Player): (string, any)
	local userId = player.UserId

	local releaseDeadline = os.clock() + 60
	while releasing[userId] do
		if not player.Parent then
			return "left", nil
		end
		if os.clock() >= releaseDeadline then
			return "failed", "an earlier leave-save for this player is still running"
		end
		task.wait(0.1)
	end

	local storeKey = key(player)
	local waitStarted = os.clock()
	local failures = 0
	local toldWaiting = false
	while true do
		if not player.Parent then
			return "left", nil
		end
		local takeover = os.clock() - waitStarted >= GameConfig.DATA_LOCK_WAIT_SECONDS
		local target = openStore()
		local ok: boolean, outcome: any, document: any, holder: any
		if target then
			ok, outcome, document, holder = pcall(claim, target, storeKey, takeover)
		else
			ok, outcome = false, "the DataStore could not be opened"
		end

		if ok and outcome == "taken" then
			if holder ~= nil then
				warn(`[DataService] took over {player.Name}'s save from session {tostring(holder)} after waiting {GameConfig.DATA_LOCK_WAIT_SECONDS}s`)
			end
			return "ok", document
		elseif ok and outcome == "held" then
			if not toldWaiting then
				toldWaiting = true
				print(`[DataService] {player.Name}'s save is still held by session {tostring(holder)}; waiting for it to be released`)
			end
			task.wait(GameConfig.DATA_LOCK_RETRY_SECONDS)
		elseif ok then
			return "failed", "the stored profile is not a table"
		else
			failures += 1
			warn(`[DataService] load attempt {failures} failed for {player.Name}: {outcome}`)
			if failures >= LOAD_ATTEMPTS then
				-- No sleep after the last attempt: the kick goes out now.
				return "failed", tostring(outcome)
			end
			task.wait(2 ^ failures)
		end
	end
end

function DataService.load(player: Player)
	if profiles[player] or loading[player] then
		return
	end
	loading[player] = true

	local profile: Profile? = nil
	local failure: string? = nil
	local lockTaken = false

	if useDataStore then
		local status, detail = acquire(player)
		if status == "ok" then
			lockTaken = true
			-- migrate and reconcile run PROTECTED: a malformed document used to
			-- throw here, leave `loading` set forever and soft-lock the player.
			local ok, result = pcall(function(): Profile
				local document = detail :: any
				document.SessionLock = nil
				return reconcile(migrate(document :: Profile))
			end)
			if ok then
				profile = result
			else
				failure = `the stored profile could not be read: {result}`
			end
		elseif status == "failed" then
			failure = tostring(detail)
		end
		-- "left": nothing was locked and there is nobody to kick.
	else
		local ok, result = pcall(function(): Profile
			return reconcile(defaultProfile())
		end)
		if ok then
			profile = result
		else
			failure = tostring(result)
		end
	end

	loading[player] = nil

	-- The read above yields, and a player can join and leave inside that window
	-- (a mis-click, a bad connection). PlayerRemoving has already fired for
	-- them, so `release` already ran and nothing will ever run it again: a
	-- profile stored now would sit in memory for the life of the server and be
	-- re-saved on every autosave, spending DataStore budget on a ghost.
	if profile and player.Parent then
		profiles[player] = profile
		loadFinished:Fire(player)
		return
	end

	if lockTaken then
		-- The lock is ours but the profile never went live: give it back so the
		-- next join does not wait DATA_LOCK_WAIT_SECONDS for nothing.
		task.spawn(unlockOnly, player.UserId)
	end
	if failure then
		-- Never hand out a fresh profile after a failed read: that would let
		-- a save overwrite real progress. Kick instead.
		warn(`[DataService] giving up loading {player.Name} ({failure}); removing to protect their save`)
		if player.Parent then
			player:Kick("Could not load your save. Please rejoin in a moment.")
		end
	end
	loadFinished:Fire(player)
end

-- ==========================================================
-- SAVING
-- ==========================================================

--- Runs on the profile immediately before EVERY save - autosave, leave and
--- shutdown alike - so a service can stamp last-moment state (the offline
--- earnings clock) without having to know which save path this is.
local beforeSave: { (Player, Profile) -> () } = {}

function DataService.onBeforeSave(fn: (Player, Profile) -> ())
	table.insert(beforeSave, fn)
end

local function runBeforeSave(player: Player, profile: Profile)
	for _, fn in beforeSave do
		local ok, err = pcall(fn, player, profile)
		if not ok then
			warn(`[DataService] before-save hook failed for {player.Name}: {err}`)
		end
	end
end

type SaveWaiter = { id: number, thread: thread }
type SaveQueue = {
	--- The newest request id handed out.
	requested: number,
	running: boolean,
	waiters: { SaveWaiter },
	--- A release has begun: every write from here on clears the lock.
	releasing: boolean,
	--- A lock-clearing write has landed: nothing more may be written.
	released: boolean,
}
local saveQueues: { [Player]: SaveQueue } = {}

--- The one writer per player. Each pass covers every request made before it
--- started; requests made while it runs are covered by exactly one more pass.
local function runQueue(player: Player, queue: SaveQueue)
	while true do
		local covering = queue.requested
		local ok = false
		local profile = profiles[player]
		local target = openStore()
		if profile and target and not sessionLost[player] and not queue.released then
			-- The hooks run per WRITE, right before it, so what they stamp (the
			-- offline clock) is as fresh as the data it is saved with.
			runBeforeSave(player, profile)
			local clearLock = queue.releasing
			local called, written, rejected, holder = pcall(writeGuarded, target, key(player), profile, clearLock)
			if not called then
				warn(`[DataService] save failed for {player.Name}: {written}`)
			elseif rejected then
				loseSession(player, holder)
			else
				ok = written == true
				if ok and clearLock then
					queue.released = true
				end
			end
		elseif profile and not target then
			warn(`[DataService] save skipped for {player.Name}: the DataStore could not be opened`)
		end

		-- Answer everyone this pass covered. Detached first: a woken caller may
		-- call save again straight away, and must land in the fresh list.
		local current = queue.waiters
		queue.waiters = {}
		local wake: { thread } = {}
		for _, waiter in current do
			if waiter.id <= covering then
				table.insert(wake, waiter.thread)
			else
				table.insert(queue.waiters, waiter)
			end
		end
		for _, thread in wake do
			-- A caller cancelled while waiting is dead; resuming it would throw
			-- and stop this writer for good.
			if coroutine.status(thread) == "suspended" then
				task.spawn(thread, ok)
			end
		end

		if queue.requested == covering then
			break
		end
	end
	queue.running = false
end

--- Queues a write and yields for the result of the write that covers it.
local function requestSave(player: Player, release: boolean): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	if not useDataStore then
		-- Studio memory mode: the hooks still run (they keep session state
		-- consistent), nothing is written.
		runBeforeSave(player, profile)
		return false
	end
	if sessionLost[player] then
		return false
	end

	local queue = saveQueues[player]
	if not queue then
		queue = { requested = 0, running = false, waiters = {}, releasing = false, released = false }
		saveQueues[player] = queue
	end
	if release then
		queue.releasing = true
	end
	if queue.released then
		return false
	end

	queue.requested += 1
	table.insert(queue.waiters, { id = queue.requested, thread = coroutine.running() })
	if not queue.running then
		queue.running = true
		-- DEFERRED, never spawned: the writer may finish without yielding (no
		-- store), and it must not try to wake this thread before it has
		-- yielded below.
		task.defer(runQueue, player, queue)
	end
	local written = coroutine.yield()
	return written == true
end

--- Saves the profile. Yields; true once the profile AS IT WAS AT THIS CALL is
--- durably written. Concurrent calls are coalesced (see the header).
function DataService.save(player: Player): boolean
	return requestSave(player, false)
end

--- Saves made by this server so far. Studio test support only.
function DataService.debugWriteCount(): number
	return writeCount
end

--- The lock primitives, for the Studio test on a THROWAWAY key only.
function DataService.debugLockApi(): { [string]: any }
	return {
		sessionId = sessionId,
		claim = claim,
		writeGuarded = writeGuarded,
		heldByOther = heldByOther,
	}
end

--- Runs on a profile when its player LEAVES, before the leave-save writes it.
---
--- For state that is deliberately held back while the player is here and must
--- not be lost when they go - a free-spin prize still waiting for its wheel
--- to land (SpinWheelService). Hooked here rather than on PlayerRemoving
--- because this is guaranteed to run before the save, whatever order Roblox
--- fires its PlayerRemoving connections in. Unlike `onBeforeSave` it does NOT
--- run on autosaves, so nothing held back is ever flushed early just because
--- a routine save happened to land mid-spin.
local beforeRelease: { (Player, Profile) -> () } = {}

function DataService.onBeforeRelease(fn: (Player, Profile) -> ())
	table.insert(beforeRelease, fn)
end

--- Runs AFTER a player's profile has been saved and dropped (or, if it never
--- loaded, when they leave). The place to clear per-player caches that the
--- leave-save still reads - EconomyService's income cache feeds the offline
--- rate stamped by that save, so it must outlive it, and a plain
--- PlayerRemoving handler has no guaranteed order relative to this one.
local afterRelease: { (Player) -> () } = {}

function DataService.onAfterRelease(fn: (Player) -> ())
	table.insert(afterRelease, fn)
end

local function runAfterRelease(player: Player)
	for _, fn in afterRelease do
		local ok, err = pcall(function()
			fn(player)
		end)
		if not ok then
			warn(`[DataService] after-release hook failed for {player.Name}: {err}`)
		end
	end
end

--- Runs the release hooks without releasing. Exposed for the debug bridge, so
--- the leave path can be exercised in a solo Studio session.
function DataService.runBeforeRelease(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	for _, fn in beforeRelease do
		local ok, err = pcall(fn, player, profile)
		if not ok then
			warn(`[DataService] before-release hook failed for {player.Name}: {err}`)
		end
	end
end

--- The leave path. ORDER MATTERS:
---   1. before-release hooks - commit anything held back during play, so the
---      final write includes it;
---   2. the final save, which CLEARS the lock in the same write, retried with
---      backoff (a transient DataStore error must not lose the session);
---   3. drop the profile, then the after-release hooks (cache cleanup).
--- Idempotent: a second call (PlayerRemoving racing BindToClose) waits for the
--- first instead of writing again.
function DataService.release(player: Player)
	if releasingPlayers[player] then
		while releasingPlayers[player] do
			task.wait(0.1)
		end
		return
	end
	if not profiles[player] then
		-- Never loaded, or already released. Nothing to write; the caches may
		-- still hold something for them.
		loading[player] = nil
		runAfterRelease(player)
		return
	end

	local userId = player.UserId
	releasingPlayers[player] = true
	releasing[userId] = true

	-- 1.
	DataService.runBeforeRelease(player)

	-- 2.
	if useDataStore then
		local attempts = GameConfig.DATA_RELEASE_SAVE_ATTEMPTS
		for attempt = 1, attempts do
			if sessionLost[player] then
				-- Another server owns the save; retrying could only be refused.
				break
			end
			if requestSave(player, true) then
				break
			end
			if sessionLost[player] then
				break
			end
			if attempt == attempts then
				warn(
					`[DataService] leave-save for {player.Name} failed {attempts} times; their lock stays until the next join takes it over`
				)
				break
			end
			warn(`[DataService] leave-save attempt {attempt} failed for {player.Name}; retrying`)
			task.wait(math.min(2 ^ attempt, 8))
		end
	else
		requestSave(player, true)
	end

	-- 3.
	profiles[player] = nil
	loading[player] = nil
	saveQueues[player] = nil
	sessionLost[player] = nil
	releasing[userId] = nil
	releasingPlayers[player] = nil
	runAfterRelease(player)
end

function DataService.start()
	if RunService:IsStudio() then
		-- The in-memory fallback exists for STUDIO ONLY: without API access the
		-- probe throws, and the game must still boot and be playable.
		local ok = pcall(function()
			local opened = DataStoreService:GetDataStore(STORE_NAME)
			opened:GetAsync("__probe")
			store = opened
		end)
		useDataStore = ok
		if not ok then
			warn("[DataService] DataStores unavailable (Studio API access off) - running with in-memory profiles")
		end
	else
		-- A LIVE server always persists. The probe is diagnostics only and runs
		-- in the background so boot is never held up; if the DataStore really is
		-- down, each join retries and kicks rather than handing out a blank
		-- profile that a later save would write over real progress.
		useDataStore = true
		openStore()
		task.spawn(function()
			for attempt = 1, 5 do
				local target = openStore()
				local ok, err = pcall(function()
					if not target then
						error("GetDataStore failed")
					end
					target:GetAsync("__probe")
				end)
				if ok then
					return
				end
				warn(`[DataService] DataStore probe {attempt}/5 failed: {err}`)
				task.wait(2 ^ attempt)
			end
			warn("[DataService] DataStores still unreachable - joins will retry and kick rather than load blank profiles")
		end)
	end

	for _, player in Players:GetPlayers() do
		task.spawn(DataService.load, player)
	end
	Players.PlayerAdded:Connect(function(player)
		DataService.load(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		DataService.release(player)
	end)

	-- Autosave. Each write also refreshes the session lock's stamp, which is
	-- what keeps a live session well inside DATA_LOCK_STALE_SECONDS.
	task.spawn(function()
		while true do
			task.wait(GameConfig.AUTOSAVE_INTERVAL)
			local due: { Player } = {}
			for player in profiles do
				table.insert(due, player)
			end
			for _, player in due do
				task.spawn(DataService.save, player)
			end
		end
	end)

	-- SHUTDOWN. Every loaded profile goes through the full release (hooks,
	-- lock-clearing save, retries), and the close waits until they have all
	-- finished - including leave-saves PlayerRemoving had already started -
	-- or DATA_SHUTDOWN_WAIT_SECONDS pass. `release` is idempotent, so the
	-- PlayerRemoving the shutdown itself triggers does not write again.
	game:BindToClose(function()
		if not useDataStore then
			return
		end
		local due: { Player } = {}
		for player in profiles do
			table.insert(due, player)
		end
		local pending = #due
		for _, player in due do
			task.spawn(function()
				local ok, err = pcall(function()
					DataService.release(player)
				end)
				if not ok then
					warn(`[DataService] shutdown release failed for {player.Name}: {err}`)
				end
				pending -= 1
			end)
		end
		local deadline = os.clock() + GameConfig.DATA_SHUTDOWN_WAIT_SECONDS
		while (pending > 0 or next(releasingPlayers) ~= nil or next(releasing) ~= nil) and os.clock() < deadline do
			task.wait(0.1)
		end
		if pending > 0 or next(releasingPlayers) ~= nil then
			warn(`[DataService] shutdown: {pending} final save(s) still running after {GameConfig.DATA_SHUTDOWN_WAIT_SECONDS}s`)
		end
	end)
end

return DataService
