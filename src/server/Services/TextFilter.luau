--!strict
--[[
	TextFilter
	The ONE place player-typed text is filtered before anyone else sees it
	(polish-events-analytics pass; Roblox community rules require it).

	AUDIT (2026-09-17). Nothing in the game shows player-typed text to OTHER
	players today:
	  * the CODES box (CodesController -> CodeService) only answers the
	    typer, with fixed messages that never echo the code;
	  * owner chat commands (OwnerCommandService) echo the typed name only
	    back to the owner ("No player called ...");
	  * plot signs, kick/steal toasts and reveal announcements use
	    `player.DisplayName` / usernames (already Roblox-moderated);
	  * Mailbox notes are written by services, never by players.
	Any feature that ADDS shared typed text - crew names, trade
	notes, sign or pet names, a codes box that echoes the code - must pass it
	through here on the SERVER before storing, replicating or broadcasting it.

	USE
	  TextFilter.forBroadcast(text, fromUserId)
	      Text everyone can see (crew name, plot sign, trade note on a public
	      board). Returns the filtered string.
	  TextFilter.forUser(text, fromUserId, toUserId)
	      Text one specific player sees (a trade note in a private offer).
	  TextFilter.filterResult(text, fromUserId)
	      The raw TextFilterResult (nil on failure) when a caller must render
	      one message per viewer.

	FAIL CLOSED. Any error (service down, rate limit, a player who has left)
	returns a row of "#" the same length as the input, never the input.
	Both calls yield; never call them on a render or physics path.

	Filtered results must not be cached for long: re-filter stored text on
	load (Roblox may change the verdict), which is what `forBroadcast` on the
	way out does.
]]

local TextService = game:GetService("TextService")

local TextFilter = {}

--- Longest text this module accepts; longer input is cut first.
TextFilter.MAX_LENGTH = 200

local function hashes(text: string): string
	local length = utf8.len(text) or #text
	return string.rep("#", math.clamp(length, 1, TextFilter.MAX_LENGTH))
end

local function clean(text: any): string?
	if type(text) ~= "string" then
		return nil
	end
	if not utf8.len(text) then
		return nil -- invalid UTF-8 is refused outright
	end
	local trimmed = string.gsub(text, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	if #trimmed == 0 then
		return nil
	end
	if #trimmed > TextFilter.MAX_LENGTH then
		trimmed = string.sub(trimmed, 1, TextFilter.MAX_LENGTH)
		-- Do not leave a cut multi-byte character behind.
		while #trimmed > 0 and not utf8.len(trimmed) do
			trimmed = string.sub(trimmed, 1, #trimmed - 1)
		end
	end
	return trimmed
end

--- The TextFilterResult for `text` typed by `fromUserId`, or nil.
function TextFilter.filterResult(text: string, fromUserId: number): TextFilterResult?
	local input = clean(text)
	if not input then
		return nil
	end
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(input, fromUserId, Enum.TextFilterContext.PublicChat)
	end)
	if not ok then
		warn(`[TextFilter] FilterStringAsync failed: {result}`)
		return nil
	end
	return result
end

--- Text shown to everyone. Fails closed.
function TextFilter.forBroadcast(text: string, fromUserId: number): string
	local result = TextFilter.filterResult(text, fromUserId)
	if not result then
		return hashes(if type(text) == "string" then text else "")
	end
	local ok, filtered = pcall(function()
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(filtered) == "string" then
		return filtered
	end
	warn(`[TextFilter] broadcast filter failed: {filtered}`)
	return hashes(text)
end

--- Text shown to one player. Fails closed.
function TextFilter.forUser(text: string, fromUserId: number, toUserId: number): string
	local result = TextFilter.filterResult(text, fromUserId)
	if not result then
		return hashes(if type(text) == "string" then text else "")
	end
	local ok, filtered = pcall(function()
		return result:GetNonChatStringForUserAsync(toUserId)
	end)
	if ok and type(filtered) == "string" then
		return filtered
	end
	warn(`[TextFilter] per-user filter failed: {filtered}`)
	return hashes(text)
end

return TextFilter
