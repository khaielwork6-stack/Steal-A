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
	--- Fires once when a steal wakes a regular (police) guardian - Zone 1's Cop.
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

	-- ---------- event: personal gameplay moments ----------
	--- Crossing the red line with loot: the sting, then Escape half a second
	--- later (ChaseAudioController sequences the two).
	EscapeSting = { id = asset(138891370077088), volume = 1.0, category = "event" },
	--- The safe-zone confirmation: after the sting on an escape, or alone on a
	--- delivery that had no chase behind it.
	Escape = { id = asset(78351077296798), volume = 1.0, category = "event" },
	Notification = { id = asset(131661992591924), volume = 0.7, category = "event" },
	--- A genuinely NEW item entering the Index. Never on a repeat pickup.
	NewDiscovery = { id = asset(136182414783063), volume = 1.0, category = "event" },
	Sell = { id = asset(138979515680965), volume = 0.85, category = "event" },
	TreadmillUnlock = { id = asset(93360393539898), volume = 0.95, category = "event" },
	UpgradePurchase = { id = asset(80736831159506), volume = 0.9, category = "event" },
	ZoneUnlock = { id = asset(17648982831), volume = 0.95, category = "event" },

	-- ---------- ui ----------
	UiHover = { id = asset(136108770017536), volume = 0.35, category = "ui" },
	UiClick = { id = asset(15675059323), volume = 0.5, category = "ui" },
	--- A panel successfully OPENING. Plays on open only - never on close, and
	--- never for a refused action (that is UiDenied).
	UiOpen = { id = asset(97861038165143), volume = 0.55, category = "ui" },
	UiDenied = { id = asset(87047730068459), volume = 0.6, category = "ui" },

	-- ---------- music ----------
	--- Plays only while the player is behind the red line. Faded, never cut.
	LobbyMusic = { id = asset(1848354536), volume = 0.28, category = "music", looped = true, fade = 1.2 },
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
	[1] = 4817107360, -- Cop
	[2] = 82006088019283, -- Pirate Captain
	[3] = 132851203831922, -- King / Royal Guard
	[4] = 109316755832781, -- Agent
	[5] = 146163493, -- Santa
	[6] = 135076986499326, -- Mummy
	[7] = 84636875169658, -- Bodybuilder
	[8] = 132610889906698, -- Bank Guard
	[9] = 18891669527, -- Mad Scientist
	[10] = 126619107266979, -- Grandma
	[11] = 139965044905843, -- Foreman
	[12] = 111155812664366, -- Airport Security
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

--- How close to the red line the music crossfade triggers, and the hysteresis
--- band that stops it flapping when a player stands exactly on the boundary.
AudioConfig.MUSIC_BOUNDARY_MARGIN = 12

function AudioConfig.get(name: string): Cue?
	return AudioConfig.Cues[name]
end

return AudioConfig
