--!strict
--[[
	TradeConfig
	Every number the player-to-player trade and the gift packs run on
	(trading-gifting-boards pass). TradeService / GiftService and their client
	controllers read these; validate.luau checks their shape.

	THE TRADE, IN ONE PARAGRAPH
	Both players are in THIS server. A asks B (a prompt on B's character, or
	the player list in the Trade panel); B has REQUEST_TIMEOUT seconds to
	accept. Each side offers up to MAX_ITEMS STORED, revealed items plus some
	Cash. Both press READY; any change to either offer un-readies both. Once
	both are ready a COUNTDOWN_SECONDS countdown runs, and only after it can
	both press CONFIRM. The server then re-checks everything and swaps the two
	offers in memory in one step, saves both profiles and logs the trade.
]]

local TradeConfig = {}

-- ==========================================================
-- THE WINDOW
-- ==========================================================

--- Items each side may put in one trade.
TradeConfig.MAX_ITEMS = 6
--- Seconds between "both ready" and CONFIRM becoming available. Any change
--- restarts the whole handshake, so a last-second swap cannot slip through.
TradeConfig.COUNTDOWN_SECONDS = 3
--- A trade window nobody has touched for this long is closed.
TradeConfig.SESSION_IDLE_SECONDS = 180
--- How often the server re-checks an open window (items still owned, nobody
--- carrying, both still here).
TradeConfig.SESSION_CHECK_SECONDS = 0.5
--- The most Cash one side may put in (also clamped to their balance). A
--- DataStore number is a double; this keeps it far from precision trouble.
TradeConfig.MAX_CASH = 1e15

-- ==========================================================
-- REQUESTS AND ABUSE LIMITS
-- ==========================================================

--- A request not answered in this many seconds lapses.
TradeConfig.REQUEST_TIMEOUT = 20
--- After asking a player (or being declined by them), wait this long before
--- asking the SAME player again.
TradeConfig.REQUEST_COOLDOWN = 10
--- Open requests one player may have waiting at once.
TradeConfig.MAX_PENDING_PER_TARGET = 3
--- No trading in the first seconds after joining: a scammer hopping servers
--- gets nothing done before the room has had a look at them.
TradeConfig.JOIN_GRACE_SECONDS = 30
--- Completed trades per player per window.
TradeConfig.TRADES_PER_WINDOW = 8
TradeConfig.TRADE_WINDOW_SECONDS = 600
--- The TradeRequest remote: sustained requests per second, and the burst.
TradeConfig.REMOTE_PER_SECOND = 6
TradeConfig.REMOTE_BURST = 14

--- LOPSIDED WARNING. When the income a side GIVES is at least this many
--- times what it GETS (and at least LOPSIDED_MIN_INCOME per second), that
--- side sees a warning over its CONFIRM button. A warning only - a gift
--- between friends is allowed.
TradeConfig.LOPSIDED_RATIO = 4
TradeConfig.LOPSIDED_MIN_INCOME = 10

-- ==========================================================
-- THE WORLD PROMPT
-- ==========================================================

--- The "Trade" prompt the CLIENT puts on other players' characters. Kept
--- short-ranged and only on the lobby apron (between the plots and the red
--- line), so it never competes with the display-slot, steal or rob prompts.
TradeConfig.PROMPT_DISTANCE = 7
TradeConfig.PROMPT_HOLD_SECONDS = 0.3

-- ==========================================================
-- CLIENT
-- ==========================================================

--- Put a TRADE opener in the HUD's menu rail (MainUI.Buttons.Left). Off =
--- the world prompt is the only way to start a trade.
TradeConfig.HUD_BUTTON = true

--- Art for the trade/gift UI. "rbxassetid://0" = not made yet: the UI draws
--- a text glyph instead. Codex fills these (docs/codex-prompts/trading-gifting-boards.md).
TradeConfig.Icons = {
	--- The HUD rail button's icon (square, transparent background).
	Trade = "rbxassetid://0",
	--- The Shop's gift toggle / Gift-to button icon (square).
	Gift = "rbxassetid://0",
	--- The trade window's header badge (square).
	TradeHeader = "rbxassetid://0",
	--- Shown on a side that has pressed READY / CONFIRM (square).
	Ready = "rbxassetid://0",
}

--- True when an icon id has been filled in.
function TradeConfig.hasIcon(id: string?): boolean
	return type(id) == "string" and id ~= "" and id ~= "rbxassetid://0"
end

-- ==========================================================
-- GIFTING
-- ==========================================================

--- How long the recipient a buyer picked is remembered while the Robux
--- dialog is open (and while Roblox delivers the receipt). A receipt with no
--- remembered recipient - a server restart, a very late retry - is granted
--- to the buyer instead, and the buyer is told.
TradeConfig.GIFT_INTENT_SECONDS = 15 * 60
--- The GiftRequest remote.
TradeConfig.GIFT_PER_SECOND = 1
TradeConfig.GIFT_BURST = 3

-- ==========================================================
-- MODERATION LOG
-- ==========================================================

--- DataStore every completed trade is written to. Keys:
---   "t_<unix>_<tradeId>"  the full record
---   "u_<userId>"          the last TRADE_LOG_PER_USER trade ids of that user
TradeConfig.TRADE_LOG_STORE = "TradeLog_v1"
TradeConfig.TRADE_LOG_PER_USER = 50

return TradeConfig
