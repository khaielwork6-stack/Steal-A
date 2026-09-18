--!strict
--[[
	RewardUiConfig
	Art keys and a few feel numbers for the two reward reveals: the DAILY
	REWARDS calendar (DailyRewardController) and the WELCOME BACK offline
	earnings popup (OfflineEarningsController). Shared drawing lives in
	Util/RewardFx.

	ART. Every key below is "rbxassetid://0" until Codex uploads the image
	(docs/codex-prompts/round3.md, "Daily rewards & offline earnings"). While a
	key is 0 the UI draws a code placeholder in its place (framed bars for the
	rays, layered teardrops for the flame, a gold plate for the chest, the
	pack's cash stack for the coin), so nothing is ever blank.

	Per-day card art stays where it was: DailyRewardConfig.Days[n].icon.
]]

local RewardUiConfig = {}

RewardUiConfig.NO_ART = "rbxassetid://0"

--- A square, radial sunburst (white rays on transparent). Spun slowly behind
--- the grand prize tile, the claim moment and the offline cash stack.
RewardUiConfig.RAYS_IMAGE = "rbxassetid://0"
--- The streak flame in the calendar header.
RewardUiConfig.FLAME_ICON = "rbxassetid://116397382100155"
--- The day 7 GRAND PRIZE chest (overrides the day's own icon on that tile
--- when set; DailyRewardConfig.Days[7].icon still wins if both are set).
RewardUiConfig.GRAND_PRIZE_ICON = "rbxassetid://140168730782089"
--- One coin, flown from a claimed reward to the HUD cash counter. Falls back
--- to the pack's cash stack.
RewardUiConfig.COIN_ICON = "rbxassetid://83482526445300"
--- The big cash pile on the WELCOME BACK card. Falls back to the pack's cash
--- stack.
RewardUiConfig.CASH_PILE_ICON = "rbxassetid://124885277911990"

--- How many coins fly per claim (Reduced Effects: none).
RewardUiConfig.COIN_COUNT = 12
--- Confetti pieces per claim (Reduced Effects: none).
RewardUiConfig.CONFETTI_COUNT = 22
--- Seconds for one turn of the rays.
RewardUiConfig.RAYS_TURN_SECONDS = 14
--- Seconds the offline amount takes to count up from 0.
RewardUiConfig.OFFLINE_COUNT_SECONDS = 1.3

--- True when an art key holds a real image.
function RewardUiConfig.hasArt(id: string?): boolean
	return type(id) == "string" and id ~= "" and id ~= RewardUiConfig.NO_ART
end

return RewardUiConfig
