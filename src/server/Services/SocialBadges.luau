--!strict
--[[
	SocialBadges
	The stable entry point other features use to award a badge:

	    require(Services.SocialBadges).award(player, "Streak7")

	A thin facade over BadgeAwardService so a caller never depends on how
	awarding is queued, cached or retried. Keys are BadgeConfig keys; an id of
	0 (badge not created yet) is a silent no-op.
]]

local BadgeAwardService = require(script.Parent.BadgeAwardService)

local SocialBadges = {}

--- Queues `key` for `player`. Never yields. false = nothing to do.
function SocialBadges.award(player: Player, key: string): boolean
	return BadgeAwardService.award(player, key)
end

return SocialBadges
