--!strict
--[[
	BoardConfig
	The world leaderboards added by the trading-gifting-boards pass: Total
	Steals, Index %, Time Played and the weekly Cash Earned board. The two
	original boards (Money, Speed) keep their own definitions in
	LeaderboardService; the new ones are described here so the owner can
	retitle, re-order or re-art them without reading the service.

	WHERE THEY STAND
	Each new board is a CLONE of the pack's `Workspace.Leaderboard Money`
	model, stood beside one of the two original boards (`besides`, `side`:
	+1 = toward the lane mouth, -1 = toward the side wall; a board that would
	not fit on its side flips to the other). To place one by hand, add an
	anchored part named `Leaderboard<Key>` (e.g. LeaderboardSteals) under
	Workspace.LobbyMarkers in Studio and save: the marker wins, exactly like
	the Money and Speed markers.
]]

local BoardConfig = {}

export type BoardDef = {
	--- Stat key: the Workspace model is "Leaderboard <key>", the marker
	--- "Leaderboard<key>".
	key: string,
	header: string,
	--- A painted header image to use instead of the text header.
	--- "rbxassetid://0" = keep the text. See the Codex prompt file.
	headerImage: string,
	--- The original board it stands next to ("Money" or "Speed"), and which
	--- neighbouring spot (1 = first, 2 = the one after).
	besides: string,
	side: number,
	slot: number,
}

BoardConfig.Boards = {
	{ key = "Steals", header = "TOP STEALS", headerImage = "rbxassetid://80926532451649", besides = "Money", side = 1, slot = 1 },
	{ key = "Weekly", header = "TOP EARNERS THIS WEEK", headerImage = "rbxassetid://89651521516052", besides = "Money", side = -1, slot = 1 },
	{ key = "Index", header = "TOP INDEX %", headerImage = "rbxassetid://110600193223369", besides = "Speed", side = 1, slot = 1 },
	{ key = "PlayTime", header = "MOST TIME PLAYED", headerImage = "rbxassetid://115916291082817", besides = "Speed", side = -1, slot = 1 },
} :: { BoardDef }

--- Clear gap between neighbouring boards, in studs.
BoardConfig.GAP = 3
--- A board is kept this far inside the lobby floor's side edge (and outside
--- the lane mouth); one that would reach past it, or whose spot is already
--- taken by a prop (LeaderboardService checks the space), moves one slot
--- further or to the other side of its neighbour instead.
BoardConfig.EDGE_CLEARANCE = 4

--- OrderedDataStore names. The weekly one gets the ISO week appended
--- ("WeeklyEarned_2026W38"), so each week starts on a fresh, empty store and
--- nothing has to be reset.
BoardConfig.STORE_KEYS = {
	Steals = "GlobalSteals_v1",
	Index = "GlobalIndex_v1",
	PlayTime = "GlobalPlayTime_v1",
	Weekly = "WeeklyEarned_",
}

--- Cash sources (EconomyService tags) that count as EARNED for the weekly
--- board. Purchases, gifts, trades, debug grants and one-off rewards
--- ("other": spin wheel, starter tasks) do not.
BoardConfig.WEEKLY_SOURCES = {
	passive = true,
	sell = true,
	discovery = true,
	index = true,
	offline = true,
} :: { [string]: boolean }

--- Play time is added to the profile this often (and once more on leave).
BoardConfig.PLAYTIME_TICK_SECONDS = 15
--- Play time is written to its board at most this often per player: it
--- changes for everyone every minute, and minute precision is plenty.
BoardConfig.PLAYTIME_SUBMIT_SECONDS = 300
--- Below this many requests left in the ordered-store write budget, board
--- writes are skipped until the next pass (profile saves use another
--- budget, but a starved board must never pile up retries).
BoardConfig.MIN_WRITE_BUDGET = 8

--- ISO-8601 week of a Unix time, e.g. "2026W38". Weeks start on Monday
--- (UTC); week 1 is the week with the year's first Thursday.
function BoardConfig.isoWeek(unix: number): string
	local t = os.date("!*t", unix) :: any
	-- os.date's wday: Sunday = 1. ISO: Monday = 1 ... Sunday = 7.
	local isoDay = ((t.wday + 5) % 7) + 1
	local thursday = os.date("!*t", unix + (4 - isoDay) * 86400) :: any
	local week = math.floor((thursday.yday - 1) / 7) + 1
	return string.format("%dW%02d", thursday.year, week)
end

--- "12h 05m" / "45m" for the Time Played board.
function BoardConfig.formatDuration(seconds: number): string
	local total = math.max(0, math.floor(tonumber(seconds) or 0))
	local hours = math.floor(total / 3600)
	local minutes = math.floor((total % 3600) / 60)
	if hours >= 1000 then
		return string.format("%dh", hours)
	elseif hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	end
	return string.format("%dm", minutes)
end

return BoardConfig
