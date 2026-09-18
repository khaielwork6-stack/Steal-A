--!strict
--[[
	CrewConfig
	Crew heists (vaults-crews area): a session-only party of up to MAX_MEMBERS
	players in one server. Notes in docs/handoff-parts/vaults-crews.md.

	CREW ASSIST. When a crew member delivers stolen museum loot home (the item
	becomes a trophy) and ANOTHER member either
	  * is within ASSIST_RADIUS studs of them, or
	  * was chased by a guard of the item's zone in the last
	    CHASE_ASSIST_SECONDS ("distraction assist"),
	then every member who took part - the deliverer, anyone within the
	radius, and anyone who was inside that zone in the last PRESENCE_SECONDS -
	earns
	    item income x BONUS_INCOME_SECONDS x BONUS_FRACTION
	(through EconomyService.earn, so the 2x Cash pass applies once) and sees a
	"CREW ASSIST!" toast. Base steals (heists) never pay an assist.
]]

local CrewConfig = {}

CrewConfig.MAX_MEMBERS = 4
--- Seconds an invite stays open.
CrewConfig.INVITE_SECONDS = 60
--- Open invites one player may have sent at once.
CrewConfig.MAX_OUTGOING_INVITES = 6
--- Crew requests (invite / accept / decline / leave / kick) per second.
CrewConfig.REQUESTS_PER_SECOND = 3

CrewConfig.ASSIST_RADIUS = 60
CrewConfig.CHASE_ASSIST_SECONDS = 20
CrewConfig.PRESENCE_SECONDS = 45
CrewConfig.BONUS_INCOME_SECONDS = 60
CrewConfig.BONUS_FRACTION = 0.25
--- How often the server samples who is in which zone and who is chased.
CrewConfig.TRACK_INTERVAL = 0.5

--- Crew tags over crew mates' heads (client only).
CrewConfig.NAMEPLATE_MAX_DISTANCE = 150

--- Placeholder art: "rbxassetid://0" = not made yet, the UI uses text.
--- See docs/codex-prompts/vaults-crews.md.
CrewConfig.Icons = {
	Crew = "rbxassetid://91226244660515",
	Leader = "rbxassetid://122735442625813",
	Invite = "rbxassetid://81513139298073",
	Assist = "rbxassetid://111666852027338",
}

return CrewConfig
