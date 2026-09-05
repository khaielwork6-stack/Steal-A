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
	--- A boss landing a hit. Deliberately replaces NpcCatch rather than stacking.
	BossHit = { id = asset(112515497365718), volume = 1.0, category = "world", rollOff = 160 },
	--- A regular hostile NPC landing a hit.
	NpcCatch = { id = asset(114303603199822), volume = 0.95, category = "world", rollOff = 160 },
	--- Bat connecting with another player.
	BatHit = { id = asset(115569575216445), volume = 0.9, category = "world", rollOff = 140 },
	--- Loops only while a guardian is asleep. Stops the instant it wakes.
	Snoring = { id = asset(97721920245356), volume = 0.55, category = "world", looped = true, rollOff = 70 },

	-- ---------- event: personal gameplay moments ----------
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
	UiToggle = { id = asset(127877437691780), volume = 0.5, category = "ui" },
	UiDenied = { id = asset(87047730068459), volume = 0.6, category = "ui" },

	-- ---------- music ----------
	--- Plays only while the player is behind the red line. Faded, never cut.
	LobbyMusic = { id = asset(92804804272270), volume = 0.28, category = "music", looped = true, fade = 1.2 },
} :: { [string]: Cue }

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
