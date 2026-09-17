--!strict
--[[
	LeaderboardService
	The WORLD boards in the plaza: highest Money and highest Speed across the
	whole experience, not this server - plus (trading-gifting-boards pass)
	Total Steals, Index %, Time Played and a WEEKLY Cash Earned board.

	THE BOARDS ARE THE PACK'S. `Workspace.Leaderboard Money` and
	`Workspace.Leaderboard Speed` were placed by hand from the UI pack; each is
	one plate carrying a SurfaceGui with eight authored rows (Top1 gold, Top2
	silver, Top3 bronze, five plain). This service moves them to where players
	walk past, gives each a header, and writes real data into those rows.
	The four newer boards are CLONES of the Money board, taken at start before
	anything is added to it, and stood beside the two originals (BoardConfig
	says where; a `LobbyMarkers.Leaderboard<Key>` part overrides it). A model
	the owner has already put in Workspace under the same name
	("Leaderboard Steals", ...) is used instead of a clone.

	HOW IT STAYS GLOBAL AND CHEAP
	  * One OrderedDataStore per stat. The weekly board's store is named after
	    the ISO week ("WeeklyEarned_2026W38"), so a new week is simply a new,
	    empty store - nothing is ever reset.
	  * Each player's scores are SUBMITTED on a slow timer, spread across the
	    interval (one player at a time), ONLY for the values that changed, and
	    once more when they leave. Time Played changes for everyone every
	    minute, so it is written at most every PLAYTIME_SUBMIT_SECONDS. A
	    write is skipped while the ordered-store write budget is low. The value
	    written is the profile's own number, never anything a client sent.
	  * The top rows are FETCHED on the same slow timer, once per server, and
	    painted onto the boards.
	  * Names and avatars are resolved once per user id and cached. A failed
	    lookup falls back to the id and the pack's placeholder icon rather than
	    blanking the row.
	  * Every DataStore call is pcall'd. A failure leaves the last good rows on
	    the board; it never clears them and never throws.

	WHAT COUNTS
	  Money      profile.Cash (the HUD's number - see HANDOFF 30.1)
	  Speed      profile.SpeedPower
	  Steals     profile.Lifetime.Steals
	  Index      discovered items (shown as a % of IndexConfig.TOTAL_ITEMS)
	  PlayTime   profile.Lifetime.PlaySeconds, accrued here while in game
	  Weekly     profile.WeeklyEarned for the current ISO week: gameplay Cash
	             only (BoardConfig.WEEKLY_SOURCES), added from
	             EconomyService.onAwarded

	IN STUDIO WITHOUT API ACCESS the stores are unavailable. The boards then show
	the players on THIS server, ranked, so the layout can be seen and tested; the
	header says so.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoardConfig = require(ReplicatedStorage.Shared.Config.BoardConfig)
local IndexConfig = require(ReplicatedStorage.Shared.Config.IndexConfig)
local LobbyLayout = require(ReplicatedStorage.Shared.LobbyLayout)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)

local LeaderboardService = {}

-- ==========================================================
-- TUNING
-- ==========================================================

--- Seconds between submitting scores and repainting the boards.
local REFRESH_INTERVAL = 60
--- Rows the pack authored per board. More than the store returns is padded with
--- "-"; fewer would leave data unshown.
local ROW_COUNT = 8

type Profile = DataService.Profile

type StatSpec = {
	--- OrderedDataStore name (the weekly one: a prefix, the week is appended).
	store: string,
	header: string,
	headerImage: string?,
	format: (number) -> string,
	value: (Profile) -> number,
	weekly: boolean?,
	--- Minimum seconds between two writes of this stat for one player.
	submitEvery: number?,
}

--- The current ISO week, e.g. "2026W38".
local function currentWeek(): string
	return BoardConfig.isoWeek(os.time())
end

local function indexCount(profile: Profile): number
	local count = 0
	if type(profile.Index) == "table" then
		for itemId, found in profile.Index do
			if found == true and LootConfig.ById[itemId] then
				count += 1
			end
		end
	end
	return math.min(count, IndexConfig.TOTAL_ITEMS)
end

local function percentOfIndex(count: number): string
	local pct = math.floor(count / math.max(IndexConfig.TOTAL_ITEMS, 1) * 100)
	return `{pct}% ({math.floor(count)}/{IndexConfig.TOTAL_ITEMS})`
end

local STATS: { [string]: StatSpec } = {
	Money = {
		store = "GlobalMoney_v1",
		header = "TOP MONEY",
		format = NumberFormat.cash,
		value = function(profile)
			return profile.Cash
		end,
	},
	Speed = {
		store = "GlobalSpeed_v1",
		header = "TOP SPEED",
		format = NumberFormat.short,
		value = function(profile)
			return profile.SpeedPower
		end,
	},
	Steals = {
		store = BoardConfig.STORE_KEYS.Steals,
		header = "TOP STEALS",
		format = NumberFormat.comma,
		value = function(profile)
			return profile.Lifetime.Steals
		end,
	},
	Index = {
		store = BoardConfig.STORE_KEYS.Index,
		header = "TOP INDEX %",
		format = percentOfIndex,
		value = indexCount,
	},
	PlayTime = {
		store = BoardConfig.STORE_KEYS.PlayTime,
		header = "MOST TIME PLAYED",
		format = BoardConfig.formatDuration,
		value = function(profile)
			return profile.Lifetime.PlaySeconds or 0
		end,
		submitEvery = BoardConfig.PLAYTIME_SUBMIT_SECONDS,
	},
	Weekly = {
		store = BoardConfig.STORE_KEYS.Weekly,
		header = "TOP EARNERS THIS WEEK",
		format = NumberFormat.cash,
		value = function(profile)
			local weekly = profile.WeeklyEarned
			if type(weekly) ~= "table" or weekly.Week ~= currentWeek() then
				return 0
			end
			return weekly.Amount
		end,
		weekly = true,
	},
}

--- Paint and submit order. The originals first.
local ORDER = { "Money", "Speed", "Steals", "Weekly", "Index", "PlayTime" }

-- The new boards' titles and art come from BoardConfig.
for _, def in BoardConfig.Boards do
	local spec = STATS[def.key]
	if spec then
		spec.header = def.header
		spec.headerImage = def.headerImage
	end
end

--- Where the two ORIGINAL boards stand: flanking the Zone 01 gate on the
--- safe side of the red line, facing back at the spawn so a player walking
--- out toward the zones reads them on approach. Resolved when a board is
--- placed: Workspace.LobbyMarkers.LeaderboardMoney / LeaderboardSpeed if the
--- owner has them, else MapConfig.HUB. See LobbyLayout.
local function originalPosition(stat: string): Vector3
	return LobbyLayout.position("Leaderboard" .. stat, MapConfig.HUB.leaderboards[stat])
end

-- ==========================================================
-- STATE
-- ==========================================================

type Entry = { userId: number, value: number }

--- Store name -> store (the weekly one gains a new entry each week).
local stores: { [string]: OrderedDataStore } = {}
local useStores = false
local boards: { [string]: Model } = {}
--- Last good rows per stat, so a failed fetch repaints the previous answer.
local lastRows: { [string]: { Entry } } = {}
--- The week `lastRows.Weekly` belongs to: a new week blanks the board.
local lastRowsWeek = ""
--- What each player last submitted per stat key ("Weekly@2026W38" for the
--- weekly one), and when, so an unchanged score is not re-written.
local lastSubmitted: { [Player]: { [string]: number } } = {}
local lastSubmitAt: { [Player]: { [string]: number } } = {}
--- Fractional play seconds not yet added to the profile, and the last tick.
local playCarry: { [Player]: number } = {}
local playTickAt: { [Player]: number } = {}
--- Where each new board ended up, for the debug status.
local placedAt: { [string]: Vector3 } = {}
--- Writes skipped for budget, for the debug status.
local skippedForBudget = 0

local nameCache: { [number]: string } = {}
local iconCache: { [number]: string } = {}

for stat in STATS do
	lastRows[stat] = {}
end

-- ==========================================================
-- LOOKUPS
-- ==========================================================

local function displayNameFor(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local online = Players:GetPlayerByUserId(userId)
	local name: string
	if online then
		name = online.DisplayName
	else
		local ok, result = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		name = if ok and type(result) == "string" then result else `#{userId}`
	end
	nameCache[userId] = name
	return name
end

local function iconFor(userId: number): string?
	local cached = iconCache[userId]
	if cached then
		return cached
	end
	local ok, content = pcall(function()
		return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
	end)
	if ok and type(content) == "string" and content ~= "" then
		iconCache[userId] = content
		return content
	end
	return nil
end

--- The store name a stat writes to and reads from right now.
local function storeNameFor(stat: string): string
	local spec = STATS[stat]
	return if spec.weekly then spec.store .. currentWeek() else spec.store
end

local function storeFor(stat: string): OrderedDataStore?
	if not useStores then
		return nil
	end
	local name = storeNameFor(stat)
	local cached = stores[name]
	if cached then
		return cached
	end
	local ok, opened = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	if ok and opened then
		stores[name] = opened
		return opened
	end
	return nil
end

-- ==========================================================
-- PAINTING
-- ==========================================================

--- The authored rows, in display order. Top1..Top3 are named; the plain rows
--- all share the name "Top4", so they are taken in child order.
local function rowsOf(board: Model): { Frame }
	local plate = board:FindFirstChildWhichIsA("BasePart")
	local gui = plate and plate:FindFirstChildOfClass("SurfaceGui")
	local list = gui and gui:FindFirstChild("Frame")
	if not list then
		return {}
	end
	local named: { Frame } = {}
	local plain: { Frame } = {}
	for _, child in list:GetChildren() do
		if child:IsA("Frame") and child.Name ~= "Empty" then
			if child.Name == "Top1" or child.Name == "Top2" or child.Name == "Top3" then
				table.insert(named, child)
			else
				table.insert(plain, child)
			end
		end
	end
	table.sort(named, function(a, b)
		return a.Name < b.Name
	end)
	for _, row in plain do
		table.insert(named, row)
	end
	return named
end

local function setText(row: Instance, name: string, text: string)
	local label = row:FindFirstChild(name)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function paint(stat: string, entries: { Entry })
	local board = boards[stat]
	if not board then
		return
	end
	local spec = STATS[stat]
	local rows = rowsOf(board)
	for index, row in rows do
		local entry = entries[index]
		-- Rows past the data stay visible and blank rather than vanishing, so the
		-- board keeps its shape while the world is still filling it in.
		row.LayoutOrder = index
		if entry then
			setText(row, "Place", `#{index}`)
			setText(row, "PlayerName", displayNameFor(entry.userId))
			setText(row, "Amount", spec.format(entry.value))
			local icon = row:FindFirstChild("PlayerIcon")
			if icon and icon:IsA("ImageLabel") then
				local content = iconFor(entry.userId)
				if content then
					icon.Image = content
				end
			end
		else
			setText(row, "Place", `#{index}`)
			setText(row, "PlayerName", "-")
			setText(row, "Amount", "-")
		end
	end
end

-- ==========================================================
-- STORE I/O
-- ==========================================================

--- The largest value written to an OrderedDataStore. Its values are int64;
--- 9e18 sits just under 2^63 (about 9.22e18) and is exactly representable.
local MAX_STORABLE = 9e18

--- A score as an OrderedDataStore will accept it: a finite whole number in
--- [0, MAX_STORABLE]. Without this one enormous (or NaN) Cash value made
--- every SetAsync for that player fail, forever, and the board froze them
--- at whatever it last accepted.
local function storable(value: any): number
	local n = tonumber(value)
	if n == nil or n ~= n then
		return 0
	end
	if n >= MAX_STORABLE then
		return MAX_STORABLE
	end
	if n <= 0 then
		return 0
	end
	return math.floor(n)
end

local function scoreOf(profile: Profile, stat: string): number
	local ok, value = pcall(STATS[stat].value, profile)
	return if ok then storable(value) else 0
end

--- True while the ordered-store write budget has room. An unanswerable
--- budget query counts as room (the write itself is pcall'd).
local function writeBudgetOk(): boolean
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementSortedAsync)
	end)
	return not ok or budget >= BoardConfig.MIN_WRITE_BUDGET
end

--- Writes one player's changed scores. `force` ignores the per-stat
--- minimum gap (the leave write).
local function submit(player: Player, force: boolean?)
	if not useStores then
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return
	end
	local last = lastSubmitted[player] or {}
	lastSubmitted[player] = last
	local lastAt = lastSubmitAt[player] or {}
	lastSubmitAt[player] = lastAt
	local key = tostring(player.UserId)
	local clock = os.clock()

	for _, stat in ORDER do
		local spec = STATS[stat]
		local value = scoreOf(profile, stat)
		local memo = if spec.weekly then `{stat}@{currentWeek()}` else stat
		if last[memo] == value then
			continue
		end
		-- An unearned week is not written: the store only lists real earners.
		if spec.weekly and value <= 0 then
			continue
		end
		local every = spec.submitEvery
		if every and not force and lastAt[stat] and clock - lastAt[stat] < every then
			continue
		end
		if not writeBudgetOk() then
			skippedForBudget += 1
			continue
		end
		local store = storeFor(stat)
		if not store then
			continue
		end
		local ok = pcall(function()
			store:SetAsync(key, value)
		end)
		if ok then
			last[memo] = value
			lastAt[stat] = clock
		end
	end
end

--- Top rows for one stat. Falls back to this server's players when the store
--- is unavailable so the boards still demonstrate themselves in Studio.
local function fetch(stat: string): { Entry }?
	if not useStores then
		local entries: { Entry } = {}
		for _, player in Players:GetPlayers() do
			local profile = DataService.get(player)
			if profile then
				table.insert(entries, { userId = player.UserId, value = scoreOf(profile, stat) })
			end
		end
		table.sort(entries, function(a, b)
			return a.value > b.value
		end)
		return entries
	end

	local store = storeFor(stat)
	if not store then
		return nil
	end
	local ok, page = pcall(function()
		return store:GetSortedAsync(false, ROW_COUNT)
	end)
	if not ok or not page then
		return nil
	end
	local entries: { Entry } = {}
	for _, item in page:GetCurrentPage() do
		local userId = tonumber(item.key)
		local value = tonumber(item.value)
		if userId and value then
			table.insert(entries, { userId = userId, value = value })
		end
	end
	return entries
end

local function repaintAll()
	local week = currentWeek()
	if week ~= lastRowsWeek then
		-- A new week: last week's winners must not linger on this week's board.
		lastRows.Weekly = {}
		lastRowsWeek = week
	end
	for _, stat in ORDER do
		if boards[stat] then
			local entries = fetch(stat)
			if entries then
				lastRows[stat] = entries
			end
			paint(stat, lastRows[stat])
		end
	end
end

local function refresh()
	-- One player at a time, spread over part of the interval, so a full
	-- server's writes do not all land in the same second.
	local players = Players:GetPlayers()
	local gap = if #players > 0 then math.min(2, (REFRESH_INTERVAL / 3) / #players) else 0
	for _, player in players do
		if player.Parent then
			submit(player, false)
		end
		if gap > 0 then
			task.wait(gap)
		end
	end
	repaintAll()
end

-- ==========================================================
-- ACCRUAL (play time, weekly earnings)
-- ==========================================================

local function accruePlayTime(player: Player, profile: Profile)
	local clock = os.clock()
	local since = playTickAt[player]
	playTickAt[player] = clock
	if not since then
		return
	end
	local carry = (playCarry[player] or 0) + math.max(0, clock - since)
	local whole = math.floor(carry)
	playCarry[player] = carry - whole
	if whole > 0 then
		profile.Lifetime.PlaySeconds = (profile.Lifetime.PlaySeconds or 0) + whole
	end
end

local function onAwarded(_player: Player, profile: Profile, amount: number, source: string)
	if not BoardConfig.WEEKLY_SOURCES[source] then
		return
	end
	local week = currentWeek()
	local weekly = profile.WeeklyEarned
	if type(weekly) ~= "table" or weekly.Week ~= week then
		weekly = { Week = week, Amount = 0 }
		profile.WeeklyEarned = weekly
	end
	local add = tonumber(amount) or 0
	if add == add and add > 0 and add < math.huge then
		weekly.Amount += add
	end
end

-- ==========================================================
-- PLACEMENT
-- ==========================================================

--- A header plate above the board, in the same warm plastic as the board
--- itself so the pair reads as one object rather than a sign hung on a sign.
--- `image` (a painted title) replaces the text when it is set.
local function ensureHeader(board: Model, plate: BasePart, text: string, image: string?)
	if board:FindFirstChild("Header") then
		return
	end
	local header = Instance.new("Part")
	header.Name = "Header"
	header.Size = Vector3.new(plate.Size.X, 2.2, plate.Size.Z)
	header.Color = plate.Color
	header.Material = plate.Material
	header.Anchored = true
	header.CanCollide = false
	header.CanQuery = false
	header.CanTouch = false
	header.CastShadow = false
	header.TopSurface = Enum.SurfaceType.Smooth
	header.BottomSurface = Enum.SurfaceType.Smooth
	header.CFrame = plate.CFrame * CFrame.new(0, plate.Size.Y / 2 + header.Size.Y / 2 + 0.2, 0)
	header.Parent = board

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Adornee = header
	gui.Parent = header

	if image and image ~= "" and image ~= "rbxassetid://0" then
		local art = Instance.new("ImageLabel")
		art.Name = "HeaderArt"
		art.Size = UDim2.fromScale(1, 1)
		art.BackgroundTransparency = 1
		art.ScaleType = Enum.ScaleType.Fit
		art.Image = image
		art.Parent = gui
		return
	end

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.94, 0.8)
	label.Position = UDim2.fromScale(0.03, 0.1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(40, 20, 8)
	label.Text = text
	label.Parent = gui
end

--- Stands a board at `position`. The plate's SurfaceGui is on its BACK face,
--- so the plate is turned to put that face toward the plaza (-Z).
local function place(stat: string, board: Model, position: Vector3)
	local plate = board:FindFirstChildWhichIsA("BasePart")
	if not plate then
		return
	end
	plate.Anchored = true
	plate.CanCollide = true
	plate.CFrame = CFrame.lookAt(position, position + Vector3.new(0, 0, 1))

	-- A short post so the plate is not floating.
	if not board:FindFirstChild("Post") then
		local post = Instance.new("Part")
		post.Name = "Post"
		post.Size = Vector3.new(1.4, position.Y - plate.Size.Y / 2 + 0.5, 1.4)
		post.Color = Color3.fromRGB(150, 100, 58)
		post.Material = Enum.Material.SmoothPlastic
		post.Anchored = true
		post.CanCollide = false
		post.CastShadow = false
		post.CFrame = CFrame.new(position.X, post.Size.Y / 2, position.Z)
		post.Parent = board
	end

	local spec = STATS[stat]
	local suffix = if useStores then "" else "  (this server)"
	ensureHeader(board, plate, spec.header .. suffix, if useStores then spec.headerImage else nil)
end

--- Neighbour slots already handed out, "Money:1:1".
local slotsTaken: { [string]: boolean } = {}

--- True when nothing but the floor/map and the markers occupies the space a
--- plate of `size` would take at `position` (the trail booth, the event
--- stand, the gift chest and the boards already stood are all built before
--- this runs). Keeps a new board out of a prop and its walkway.
local function spotIsFree(position: Vector3, size: Vector3, ignore: { Instance }): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	-- From a stud above the floor to the plate's top, padded by the gap.
	local bottom = 1
	local top = position.Y + size.Y / 2
	local box = Vector3.new(size.X + BoardConfig.GAP, math.max(top - bottom, 1), math.max(size.Z, 1) + BoardConfig.GAP)
	local centre = Vector3.new(position.X, (top + bottom) / 2, position.Z)
	local ok, hits = pcall(function()
		return workspace:GetPartBoundsInBox(CFrame.new(centre), box, params)
	end)
	if not ok then
		return true
	end
	for _, part in hits :: { BasePart } do
		-- Invisible, non-colliding helpers (triggers, zones) do not block.
		if part.Transparency < 1 or part.CanCollide then
			return false
		end
	end
	return true
end

--- Where a NEW board stands when the owner has no marker for it: beside its
--- original, on its preferred side, one plate-width plus BoardConfig.GAP per
--- slot, kept inside the lobby's side edge and outside the lane mouth, and
--- only where nothing else already stands.
local function neighbourPosition(def: BoardConfig.BoardDef, size: Vector3, ignore: { Instance }): Vector3?
	local anchor = originalPosition(def.besides)
	local towardCentre = if anchor.X > 0 then -1 else 1
	local width = size.X
	local pitch = width + BoardConfig.GAP
	local outerLimit = MapConfig.LOBBY_WIDTH / 2 - BoardConfig.EDGE_CLEARANCE
	local innerLimit = MapConfig.LANE_WIDTH / 2 + BoardConfig.EDGE_CLEARANCE
	for _, side in { def.side, -def.side } do
		local direction = if side > 0 then towardCentre else -towardCentre
		for slot = def.slot, def.slot + 2 do
			local tag = `{def.besides}:{side}:{slot}`
			local position = anchor + Vector3.new(direction * pitch * slot, 0, 0)
			local x = math.abs(position.X)
			if
				not slotsTaken[tag]
				and x + width / 2 <= outerLimit
				and x - width / 2 >= innerLimit
				and spotIsFree(position, size, ignore)
			then
				slotsTaken[tag] = true
				return position
			end
		end
	end
	return nil
end

--- Finds or clones the model for one new board and stands it.
local function buildNewBoard(def: BoardConfig.BoardDef, template: Model?)
	local name = `Leaderboard {def.key}`
	local board: Model? = nil
	local existing = workspace:FindFirstChild(name)
	if existing and existing:IsA("Model") then
		board = existing
	elseif template then
		local clone = template:Clone()
		clone.Name = name
		board = clone
	end
	if not board then
		warn(`[LeaderboardService] no template for "{name}" - that board is not built.`)
		return
	end
	local plate = board:FindFirstChildWhichIsA("BasePart")
	if not plate then
		warn(`[LeaderboardService] "{name}" has no plate - not built.`)
		return
	end

	local marker = LobbyLayout.cframe("Leaderboard" .. def.key)
	local ignore: { Instance } = { board }
	for _, skip in { "Map", LobbyLayout.FOLDER_NAME, "Terrain" } do
		local found = workspace:FindFirstChild(skip)
		if found then
			table.insert(ignore, found)
		end
	end
	local position = if marker then marker.Position else neighbourPosition(def, plate.Size, ignore)
	if not position then
		warn(`[LeaderboardService] no free spot beside the {def.besides} board for "{name}" - add a LobbyMarkers.Leaderboard{def.key} part.`)
		if board ~= existing then
			board:Destroy()
		end
		return
	end
	board.Parent = workspace
	boards[def.key] = board
	placedAt[def.key] = position
	place(def.key, board, position)
end

-- ==========================================================
-- START
-- ==========================================================

function LeaderboardService.start()
	-- The stores. `DataService.isPersistent` already answered "can Studio reach
	-- DataStores"; the ordered stores share that answer.
	if DataService.isPersistent() then
		useStores = true
		for _, stat in ORDER do
			if not storeFor(stat) then
				useStores = false
				break
			end
		end
	end

	-- The template for the new boards, lifted BEFORE the Money board gets
	-- its post and header, so the clones get their own.
	local template: Model? = nil
	local money = workspace:FindFirstChild("Leaderboard Money")
	if money and money:IsA("Model") then
		template = money:Clone()
	end

	for _, stat in { "Money", "Speed" } do
		local board = workspace:FindFirstChild(`Leaderboard {stat}`)
		if board and board:IsA("Model") then
			boards[stat] = board
			place(stat, board, originalPosition(stat))
		else
			warn(`[LeaderboardService] Workspace."Leaderboard {stat}" not found - that board will stay empty.`)
		end
	end
	for _, def in BoardConfig.Boards do
		if STATS[def.key] then
			local ok, err = (pcall :: any)(buildNewBoard, def, template)
			if not ok then
				warn(`[LeaderboardService] building the {def.key} board failed: {err}`)
			end
		end
	end
	if template then
		template:Destroy()
	end

	-- Weekly earnings: gameplay Cash only, straight from the award path.
	EconomyService.onAwarded(onAwarded)

	-- Play time: the remainder since the last tick goes into the final save.
	DataService.onBeforeRelease(function(player, profile)
		accruePlayTime(player, profile)
		local carry = playCarry[player] or 0
		if carry >= 0.5 then
			profile.Lifetime.PlaySeconds = (profile.Lifetime.PlaySeconds or 0) + 1
		end
		playCarry[player] = 0
	end)
	DataService.onAfterRelease(function(player)
		playCarry[player] = nil
		playTickAt[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(BoardConfig.PLAYTIME_TICK_SECONDS)
			for _, player in Players:GetPlayers() do
				local profile = DataService.get(player)
				if profile then
					local ok, err = (pcall :: any)(accruePlayTime, player, profile)
					if not ok then
						warn(`[LeaderboardService] play time tick failed for {player.Name}: {err}`)
					end
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Their final scores, so a session's progress is on the boards before
		-- the profile is released.
		submit(player, true)
		lastSubmitted[player] = nil
		lastSubmitAt[player] = nil
	end)

	task.spawn(function()
		-- First paint soon after start so the boards are not blank for a minute;
		-- then the slow cadence.
		task.wait(5)
		while true do
			local ok, err = (pcall :: any)(refresh)
			if not ok then
				warn(`[LeaderboardService] refresh failed: {err}`)
			end
			task.wait(REFRESH_INTERVAL)
		end
	end)

	local built = 0
	for _ in boards do
		built += 1
	end
	print(`[LeaderboardService] {built} world boards online ({if useStores then "OrderedDataStore" else "server-only fallback"})`)
end

--- Debug: force a refresh now.
function LeaderboardService.refreshNow()
	refresh()
end

--- Debug: what the boards are doing, and `player`'s current scores.
function LeaderboardService.status(player: Player?): { [string]: any }
	local placed = {}
	for stat, board in boards do
		local plate = board:FindFirstChildWhichIsA("BasePart")
		placed[stat] = {
			model = board:GetFullName(),
			position = if plate then tostring(plate.Position) else "?",
			width = if plate then plate.Size.X else nil,
			rowsShown = #(lastRows[stat] or {}),
			top = if lastRows[stat] and lastRows[stat][1] then lastRows[stat][1] else nil,
		}
	end
	local budget: any = nil
	pcall(function()
		budget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementSortedAsync)
	end)
	local out: { [string]: any } = {
		useStores = useStores,
		week = currentWeek(),
		weeklyStore = storeNameFor("Weekly"),
		boards = placed,
		newBoardSpots = placedAt,
		writeBudget = budget,
		skippedForBudget = skippedForBudget,
	}
	if player then
		local profile = DataService.get(player)
		if profile then
			local scores = {}
			for _, stat in ORDER do
				scores[stat] = { value = scoreOf(profile, stat), shown = STATS[stat].format(scoreOf(profile, stat)) }
			end
			out.you = {
				scores = scores,
				lastSubmitted = lastSubmitted[player],
				weeklyEarned = profile.WeeklyEarned,
				playSeconds = profile.Lifetime.PlaySeconds,
			}
		end
	end
	return out
end

return LeaderboardService
