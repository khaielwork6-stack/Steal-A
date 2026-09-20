--!strict
--[[
	AudioConfig
	Every sound in the game, in one table.

	Nothing anywhere else should contain a `rbxassetid://`. Call sites name a cue
	("BossAlert") and this decides which asset that is, how loud it plays, and
	whether it loops. Retuning the mix, swapping an asset, or muting a category
	while testing is then a change here and nowhere else.

	CATEGORIES exist so a future settings toggle can drop music or UI clicks
	without touching gameplay cues:
	  ui        button feedback and panel transitions
	  event     one-shot gameplay moments (steal, escape, sell, upgrade)
	  world     3D sounds positioned on a part (guardians, impacts)
	  music     long looping beds

	`rollOff` only means anything for `world` cues, which are parented to a part
	and heard positionally. Everything else plays flat, on the local client.
]]

local AudioConfig = {}

export type Cue = {
	id: string,
	volume: number,
	category: "ui" | "event" | "world" | "music",
	looped: boolean?,
	rollOff: number?, -- studs; world cues only
	fade: number?, -- seconds; music only
	pitch: number?, -- PlaybackSpeed; 1 when absent
}

local function asset(id: string | number): string
	return `rbxassetid://{id}`
end

AudioConfig.Cues = {
	-- ---------- world: guardians and impacts ----------
	--- Fires once when a steal wakes a BOSS zone guardian.
	BossAlert = { id = asset(81845122657643), volume = 1.0, category = "world", rollOff = 220 },
	--- Fires once when a steal wakes a regular (police) guardian - Zone 1's Night Watchman.
	PoliceWhistle = { id = asset(9125775207), volume = 0.9, category = "world", rollOff = 220 },
	--- Fallbacks for a guardian catch when a zone has no entry in GuardianHits.
	BossHit = { id = asset(112515497365718), volume = 1.0, category = "world", rollOff = 160 },
	NpcCatch = { id = asset(114303603199822), volume = 0.95, category = "world", rollOff = 160 },
	--- Bat connecting with another player.
	BatHit = { id = asset(106511269477863), volume = 0.9, category = "world", rollOff = 140 },
	--- The Slap connecting. No slap sound was supplied and none is invented:
	--- this is the bat's own impact asset played sharper and higher, which
	--- reads as a smack rather than a thud. Swap the id when a real one lands.
	SlapHit = { id = asset(106511269477863), volume = 1.0, category = "world", rollOff = 150, pitch = 1.35 },
	--- Loops only while a guardian is asleep. Stops the instant it wakes.
	Snoring = { id = asset(97721920245356), volume = 0.55, category = "world", looped = true, rollOff = 70 },

	-- ---------- world: weapons, gadgets and security ----------
	--- The bat (and the Slap) cutting the air, on the frame the swing starts.
	--- The HIT is a separate cue and often does not happen: a miss should still
	--- be heard, or the weapon feels broken rather than dodged.
	BatSwing = { id = asset(138283030240531), volume = 0.7, category = "world", rollOff = 90 },
	--- A trap being set down on the ground, at the trap.
	TrapPlace = { id = asset(9091607929), volume = 0.85, category = "world", rollOff = 90 },
	--- A smoke bomb going off at the thrower's feet.
	SmokeBomb = { id = asset(136838602519365), volume = 0.95, category = "world", rollOff = 120 },
	--- The laser jammer coming on.
	JammerUse = { id = asset(137510557013265), volume = 0.9, category = "world", rollOff = 110 },
	--- The grappling hook firing.
	GrappleFire = { id = asset(119530429495654), volume = 0.9, category = "world", rollOff = 130 },
	--- THE ROOM ALARM, for a few seconds after a beam is broken - a static
	--- laser or one of the vault's rotating arms, both of which raise the same
	--- alarm. Looped and positioned in the room that was tripped, so it tells
	--- everyone nearby WHERE it happened; GuardianService stops and destroys it
	--- after AudioConfig.ALARM_SECONDS.
	LaserAlarm = { id = asset(7084812679), volume = 0.7, category = "world", looped = true, rollOff = 180 },

	-- ---------- event: personal gameplay moments ----------
	--- Crossing the red line with loot, and a chase-free delivery: the ONE
	--- escape sound. The old sting that used to precede it is retired - not
	--- muted, not layered - so an escape is exactly one sound.
	Escape = { id = asset(114542988141330), volume = 1.0, category = "event" },
	--- The ordinary notification beep. Deferred a frame by AudioController so a
	--- more specific cue for the same moment replaces it instead of layering.
	Notification = { id = asset(78340041384722), volume = 0.7, category = "event" },
	--- An owned item landing on one of the player's display slots.
	PlaceItem = { id = asset(139670424345585), volume = 0.9, category = "event" },
	--- An item entering Storage (taken off display, or a robbery's fallback).
	StoredItem = { id = asset(101163709235612), volume = 0.85, category = "event" },
	--- The Nightfall spotlight: something special has spawned in the refresh.
	NightSpawn = { id = asset(87846239038276), volume = 1.0, category = "event" },
	--- A genuinely NEW item entering the Index. Never on a repeat pickup.
	-- THE REVEAL POP. The one sound of a reveal, played by the owner's client on
	-- the pop frame and nowhere else (HatchConfig.POP_SOUND).
	RevealPop = { id = asset(92415130454101), volume = 1.0, category = "event" },
	--- THE SILHOUETTE TICK. One shot per silhouette change during the reveal
	--- roulette, played BY the change rather than on a timer of its own, so
	--- picture and sound cannot drift apart. Its PlaybackSpeed is set per
	--- shot by HatchController: bright and fast early, heavy on the last.
	RevealCycle = { id = asset(107511012621133), volume = 0.75, category = "event" },
	--- THE SPIN WHEEL'S TICKING, for the length of one spin and no longer.
	--- The asset is only 0.7s, so it is LOOPED rather than re-triggered: one
	--- Sound instance, no timer to drift and nothing to leave a second copy
	--- behind. SpinWheelController rides its PlaybackSpeed down as the wheel
	--- slows, so the ticking decelerates with the picture, and stops and
	--- destroys it on the landing frame.
	SpinLoop = { id = asset(9120658649), volume = 0.6, category = "event", looped = true },
	--- The free spin becoming available. Deliberately the treadmill's unlock
	--- chime rather than a new asset: it already means "something of yours is
	--- ready" everywhere else in the game.
	SpinReady = { id = asset(93360393539898), volume = 0.7, category = "event" },
	Sell = { id = asset(138979515680965), volume = 0.85, category = "event" },
	TreadmillUnlock = { id = asset(93360393539898), volume = 0.95, category = "event" },
	UpgradePurchase = { id = asset(80736831159506), volume = 0.9, category = "event" },
	ZoneUnlock = { id = asset(17648982831), volume = 0.95, category = "event" },
	--- THE STEAL. An item coming off its stand and into the player's hands -
	--- the most-repeated sound in the game, so it is kept short and dry.
	Grab = { id = asset(138580733622165), volume = 0.9, category = "event" },
	--- Anything bought with IN-GAME CASH: a gadget, a trail, a base or storage
	--- upgrade. A coin sound, so it reads as "you spent money" wherever it is
	--- used and never as "you were given something".
	CashPurchase = { id = asset(73310199041612), volume = 0.85, category = "event" },
	--- A purchase that could NOT go through - refused, unaffordable, or a
	--- receipt that could not be delivered. Distinct from UiDenied, which is
	--- every other refusal; buying is the one refusal worth its own sound.
	PurchaseFail = { id = asset(128827503277042), volume = 0.8, category = "event" },
	--- Progression: a base or storage upgrade, a season tier, an unlock. The
	--- toast tag "levelup" plays this, which is ~29 call sites at once.
	LevelUp = { id = asset(103427717192369), volume = 0.95, category = "event" },
	--- A daily or weekly quest reaching its target, and the claim that follows.
	QuestComplete = { id = asset(92757451615296), volume = 0.95, category = "event" },
	--- The wheel's prize landing, after the disc has stopped and the banner has
	--- named it. Not the ticking (SpinLoop) and not the wheel becoming ready
	--- (SpinReady) - this is the payout itself.
	SpinReward = { id = asset(78678697833241), volume = 0.95, category = "event" },
	--- The vault door giving way once the lock is cracked.
	VaultDoor = { id = asset(7757282096), volume = 0.95, category = "event" },

	-- ---------- ui ----------
	UiHover = { id = asset(136108770017536), volume = 0.35, category = "ui" },
	UiClick = { id = asset(15675059323), volume = 0.5, category = "ui" },
	--- A panel successfully OPENING. Plays on open only - never on close, and
	--- never for a refused action (that is UiDenied).
	UiOpen = { id = asset(97861038165143), volume = 0.55, category = "ui" },
	UiDenied = { id = asset(87047730068459), volume = 0.6, category = "ui" },
	--- THE VAULT LOCK, per pin. One tumbler dropping into place - the single
	--- most satisfying moment in the minigame, and until now it was a menu
	--- click layered under the item-placed sound.
	VaultNotch = { id = asset(92927842693188), volume = 0.85, category = "ui" },
	--- A pin tapped off its notch: the lock jamming, and the attempt over.
	VaultFail = { id = asset(108601872025792), volume = 0.8, category = "ui" },

	-- ---------- music ----------
	--- Plays only while the player is behind the red line. Faded, never cut.
	--- The id is the playlist's FIRST track; the bed itself is
	--- AudioConfig.LobbyPlaylist below (volume/fade still come from here).
	LobbyMusic = { id = asset(1841647093), volume = 0.28, category = "music", looped = true, fade = 1.6 },
	--- Plays while the player is out in the zones and NOT being chased: the
	--- chase loop replaces it the moment a guardian wakes, and the lobby bed
	--- replaces it the moment they are back behind the line. Looped.
	--- Kept SUBTLE - a bed under the zone, never over it - with a long fade
	--- both ways so the handoffs to the chase loop and the lobby bed are
	--- never heard as a cut.
	ZoneMusic = { id = asset(134553946879697), volume = 0.16, category = "music", looped = true, fade = 1.8 },
	--- Loops for the CHASED player only, from 0.4s after the alert until the
	--- chase ends however it ends. Client-owned; see ChaseAudioController.
	ChaseMusic = { id = asset(113688019858504), volume = 0.45, category = "music", looped = true, fade = 0.35 },
} :: { [string]: Cue }

-- ==========================================================
-- GUARDIAN CATCH SOUNDS
-- ==========================================================
--
-- One per zone, keyed by zone index, played positionally at the guardian when
-- it lands a hit. Registered as ordinary world cues named GuardianHit_<zone>
-- so Audio.playAt pools and replicates them like everything else.

AudioConfig.GuardianHits = {
	[1] = 4817107360, -- Night Watchman
	[2] = 82006088019283, -- Ghost Captain
	[3] = 132851203831922, -- Iron Knight
	[4] = 109316755832781, -- Grey Agent
	[5] = 146163493, -- Frost Yeti
	[6] = 135076986499326, -- Mummy
	[7] = 84636875169658, -- Iron Titan
	[8] = 132610889906698, -- Vault Bot
	[9] = 18891669527, -- Lab Mutant
	[10] = 126619107266979, -- Granny
	[11] = 139965044905843, -- Wrecking Foreman
	[12] = 111155812664366, -- Sky Marshal
} :: { [number]: number }

for zoneIndex, id in AudioConfig.GuardianHits do
	AudioConfig.Cues[`GuardianHit_{zoneIndex}`] = { id = asset(id), volume = 1.0, category = "world", rollOff = 160 }
end

--- The cue a guardian plays on a catch: its own, or the boss/regular fallback.
function AudioConfig.guardianHitCue(zoneIndex: number): string
	local name = `GuardianHit_{zoneIndex}`
	if AudioConfig.Cues[name] then
		return name
	end
	return if zoneIndex > 1 then "BossHit" else "NpcCatch"
end

--- Hover fires on every mouse-over, so it needs a floor between plays or a
--- cursor dragged along a menu machine-guns it.
AudioConfig.HOVER_COOLDOWN = 0.06

--- How long the room alarm rings after a beam is broken. Long enough to say
--- "someone tripped it over there", short enough not to become the room tone.
AudioConfig.ALARM_SECONDS = 4

--- How close to the red line the music crossfade triggers, and the hysteresis
--- band that stops it flapping when a player stands exactly on the boundary.
AudioConfig.MUSIC_BOUNDARY_MARGIN = 12

--- THE LOBBY PLAYLIST, in the owner's order, then round to the first again.
--- `gains` trim each track to the same perceived loudness (measured with
--- PlaybackLoudness in Studio; 1 = untouched) and multiply the cue's volume.
--- `crossfade` seconds: the next track starts this long before the current
--- one ends, so there is never a gap and never a hard cut.
AudioConfig.LobbyPlaylist = {
	ids = { 1841647093, 1840684529, 1845756489, 1845341094, 1840384233, 9045832226 },
	-- Measured 2026-09-20 (average PlaybackLoudness at one volume):
	-- 221, 127, 120, 91, 80, 126. Trimmed toward ~125.
	gains = { 0.6, 1, 1.05, 1.3, 1.45, 1 },
	crossfade = 3,
} :: { ids: { number }, gains: { number }, crossfade: number }

function AudioConfig.get(name: string): Cue?
	return AudioConfig.Cues[name]
end

return AudioConfig
