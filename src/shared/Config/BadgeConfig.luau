--!strict
--[[
	BadgeConfig
	Every badge the game can award: key -> BadgeService id.

	ALL IDS ARE 0 UNTIL THE OWNER CREATES THE BADGES (Creator Dashboard >
	the experience > Engagement > Badges). BadgeAwardService skips an id of 0
	silently, so the game runs normally with none of them created. Paste each
	real id into `id` below; the image prompt for every badge is in
	docs/codex-prompts/social.md (same key).

	Keys are stable: code awards by KEY, never by id.
]]

local BadgeConfig = {}

export type BadgeDef = {
	key: string,
	id: number,
	name: string,
	description: string,
}

--- Built below so each zone gets its own row without twelve hand-written ones.
local list: { BadgeDef } = {
	{ key = "FirstSteal", id = 1818392205990812, name = "Sticky Fingers", description = "Steal your first container." },
	{ key = "FirstEscape", id = 0, name = "Clean Getaway", description = "Escape the museum with stolen loot." },
	{ key = "FirstReveal", id = 1330539549462491, name = "What's Inside?", description = "Reveal your first container." },
	{ key = "FirstMythicReveal", id = 2377234696063353, name = "Myth Maker", description = "Reveal a Mythic or better item." },
	{ key = "FirstSecretReveal", id = 0, name = "Top Secret", description = "Reveal a Secret or better item." },
	{ key = "IndexZoneComplete", id = 0, name = "Curator", description = "Complete every item of one zone in the Index." },
	{ key = "IndexComplete", id = 0, name = "Master Curator", description = "Complete the whole Index." },
	{ key = "Steals100", id = 1618938884680217, name = "Career Thief", description = "Steal 100 containers." },
	{ key = "Steals1000", id = 0, name = "Legendary Thief", description = "Steal 1,000 containers." },
	{ key = "FirstHeist", id = 0, name = "Base Raider", description = "Steal an item from another player's base." },
	{ key = "Streak7", id = 2862874232095580, name = "Regular", description = "Claim the daily reward 7 days in a row." },
}

--- Zone badges: "Zone01" ... "Zone12". Zone ids live here, one per row.
BadgeConfig.ZONE_BADGE_IDS = {
	0, -- Zone01
	0, -- Zone02
	0, -- Zone03
	0, -- Zone04
	0, -- Zone05
	0, -- Zone06
	0, -- Zone07
	0, -- Zone08
	0, -- Zone09
	0, -- Zone10
	0, -- Zone11
	0, -- Zone12
} :: { number }

--- The key of zone `zone`'s badge.
function BadgeConfig.zoneKey(zone: number): string
	return string.format("Zone%02d", zone)
end

for zone, id in BadgeConfig.ZONE_BADGE_IDS do
	table.insert(list, {
		key = BadgeConfig.zoneKey(zone),
		id = id,
		name = string.format("Zone %d Explorer", zone),
		description = string.format("Steal from Zone %d.", zone),
	})
end

--- Steal-count milestones: count -> badge key.
BadgeConfig.STEAL_MILESTONES = {
	{ count = 100, key = "Steals100" },
	{ count = 1000, key = "Steals1000" },
}

--- The daily-streak badge: awarded when a streak event reports this many days.
BadgeConfig.STREAK_DAYS = 7

BadgeConfig.List = list
BadgeConfig.ByKey = {} :: { [string]: BadgeDef }
for _, def in list do
	BadgeConfig.ByKey[def.key] = def
end

--- The id for `key`, or 0 when the key is unknown or not created yet.
function BadgeConfig.idFor(key: string): number
	local def = BadgeConfig.ByKey[key]
	return if def then def.id else 0
end

return BadgeConfig
