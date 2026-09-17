--!strict
--[[
	Audit debug commands (Studio only, read-only).

	profileHistory(count?, maxPages?)
	    Lists the saved versions of the caller's profile (PlayerProfiles_v1,
	    key player_<UserId>), newest first, with the Cash, SpeedPower and
	    display count stored in each. Used to tell a player's own spending from
	    a test that failed to restore what it touched. Writes nothing.
]]

local DataStoreService = game:GetService("DataStoreService")

local commands: { [string]: (Player, ...any) -> any } = {}

commands.profileHistory = function(player: Player, count: any, maxPages: any)
	local wanted = math.clamp(tonumber(count) or 40, 1, 200)
	local pages = math.clamp(tonumber(maxPages) or 10, 1, 50)
	local store = DataStoreService:GetDataStore("PlayerProfiles_v1")
	local key = `player_{player.UserId}`
	local ok, listing = pcall(function()
		return store:ListVersionsAsync(key, Enum.SortDirection.Descending, nil, nil, 100)
	end)
	if not ok then
		return { error = tostring(listing) }
	end
	local rows = {}
	local seenPages = 0
	while #rows < wanted and seenPages < pages do
		seenPages += 1
		for _, info in (listing :: DataStoreVersionPages):GetCurrentPage() do
			if #rows >= wanted then
				break
			end
			local got, value = pcall(function()
				return store:GetVersionAsync(key, info.Version)
			end)
			local profile = if got and type(value) == "table" then value :: any else nil
			table.insert(rows, {
				at = DateTime.fromUnixTimestampMillis(info.CreatedTime):ToIsoDate(),
				version = info.Version,
				cash = profile and profile.Cash,
				speed = profile and profile.SpeedPower,
				displays = profile and type(profile.DisplayItems) == "table" and #profile.DisplayItems or nil,
				stored = profile and type(profile.Inventory) == "table" and #profile.Inventory or nil,
			})
		end
		if (listing :: DataStoreVersionPages).IsFinished then
			break
		end
		local advanced = pcall(function()
			(listing :: DataStoreVersionPages):AdvanceToNextPageAsync()
		end)
		if not advanced then
			break
		end
	end
	return rows
end

return commands
