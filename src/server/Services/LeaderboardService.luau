--!strict
--[[
	LeaderboardService
	The two WORLD boards in the plaza: highest Money and highest Speed across
	the whole experience, not this server.

	THE BOARDS ARE THE PACK'S. `Workspace.Leaderboard Money` and
	`Workspace.Leaderboard Speed` were placed by hand from the UI pack; each is
	one plate carrying a SurfaceGui with eight authored rows (Top1 gold, Top2
	silver, Top3 bronze, five plain). This service moves them to where players
	walk past, gives each a header, and writes real data into those rows. It
	builds no board of its own.

	HOW IT STAYS GLOBAL AND CHEAP
	  * One OrderedDataStore per stat. Each player's score is SUBMITTED on a slow
	    timer and once more when they leave; the value written is the profile's
	    own number, never anything a client sent.
	  * The top rows are FETCHED on the same slow timer, once per server, and
	    painted onto both boards. Sixty seconds between fetches is plenty for a
	    board people glance at, and keeps a full server well inside budget.
	  * Names and avatars are resolved once per user id and cached. A failed
	    lookup falls back to the id and the pack's placeholder icon rather than
	    blanking the row.
	  * Every DataStore call is pcall'd. A failure leaves the last good rows on
	    the board; it never clears them and never throws.

	IN STUDIO WITHOUT API ACCESS the stores are unavailable. The boards then show
	the players on THIS server, ranked, so the layout can be seen and tested; the
	header says so.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

local DataService = require(script.Parent.DataService)

local LeaderboardService = {}

-- ==========================================================
-- TUNING
-- ==========================================================

--- Seconds between submitting scores and repainting the boards.
local REFRESH_INTERVAL = 60
--- Rows the pack authored per board. More than the store returns is padded with
--- "-"; fewer would leave data unshown.
local ROW_COUNT = 8

local STORES = {
	Money = { key = "GlobalMoney_v1", header = "TOP MONEY", format = NumberFormat.cash },
	Speed = { key = "GlobalSpeed_v1", header = "TOP SPEED", format = NumberFormat.short },
}

--- Where the two boards stand: flanking the Zone 01 gate on the safe side of
--- the red line, facing back at the spawn so a player walking out toward the
--- zones reads them on approach. One table (MapConfig.HUB) composes the whole
--- hub; the height keeps the plate's foot on the floor.
local BOARD_POSITIONS = MapConfig.HUB.leaderboards

-- ==========================================================
-- STATE
-- ==========================================================

type Entry = { userId: number, value: number }

local stores: { [string]: OrderedDataStore } = {}
local useStores = false
local boards: { [string]: Model } = {}
--- Last good rows per stat, so a failed fetch repaints the previous answer.
local lastRows: { [string]: { Entry } } = { Money = {}, Speed = {} }
--- What each player last submitted, so an unchanged score is not re-written.
local lastSubmitted: { [Player]: { Money: number, Speed: number } } = {}

local nameCache: { [number]: string } = {}
local iconCache: { [number]: string } = {}

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
	local spec = STORES[stat]
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

local function currentScores(player: Player): (number?, number?)
	local profile = DataService.get(player)
	if not profile then
		return nil, nil
	end
	return math.max(0, math.floor(profile.Cash)), math.max(0, math.floor(profile.SpeedPower))
end

--- Writes one player's scores. Only when they changed since the last write, so
--- an idle server costs nothing.
local function submit(player: Player)
	if not useStores then
		return
	end
	local cash, speed = currentScores(player)
	if not cash then
		return
	end
	local last = lastSubmitted[player]
	if last and last.Money == cash and last.Speed == speed then
		return
	end
	local key = tostring(player.UserId)
	local okMoney = pcall(function()
		stores.Money:SetAsync(key, cash)
	end)
	local okSpeed = pcall(function()
		stores.Speed:SetAsync(key, speed)
	end)
	if okMoney and okSpeed then
		lastSubmitted[player] = { Money = cash, Speed = speed }
	end
end

--- Top rows for one stat. Falls back to this server's players when the store
--- is unavailable so the boards still demonstrate themselves in Studio.
local function fetch(stat: string): { Entry }?
	if not useStores then
		local entries: { Entry } = {}
		for _, player in Players:GetPlayers() do
			local cash, speed = currentScores(player)
			if cash then
				table.insert(entries, { userId = player.UserId, value = if stat == "Money" then cash else speed })
			end
		end
		table.sort(entries, function(a, b)
			return a.value > b.value
		end)
		return entries
	end

	local ok, page = pcall(function()
		return stores[stat]:GetSortedAsync(false, ROW_COUNT)
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

local function refresh()
	for _, player in Players:GetPlayers() do
		submit(player)
	end
	for stat in STORES do
		local entries = fetch(stat)
		if entries then
			lastRows[stat] = entries
		end
		paint(stat, lastRows[stat])
	end
end

-- ==========================================================
-- PLACEMENT
-- ==========================================================

--- A header plate above the board, in the same warm plastic as the board
--- itself so the pair reads as one object rather than a sign hung on a sign.
local function ensureHeader(board: Model, plate: BasePart, text: string)
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

--- Stands a board where it belongs. The plate's SurfaceGui is on its BACK face,
--- so the plate is turned to put that face toward the plaza (-Z).
local function place(stat: string, board: Model)
	local plate = board:FindFirstChildWhichIsA("BasePart")
	if not plate then
		return
	end
	local position = BOARD_POSITIONS[stat]
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

	local suffix = if useStores then "" else "  (this server)"
	ensureHeader(board, plate, STORES[stat].header .. suffix)
end

-- ==========================================================
-- START
-- ==========================================================

function LeaderboardService.start()
	-- The stores. `DataService.isPersistent` already answered "can Studio reach
	-- DataStores"; the ordered stores share that answer.
	if DataService.isPersistent() then
		local ok = pcall(function()
			for stat, spec in STORES do
				stores[stat] = DataStoreService:GetOrderedDataStore(spec.key)
			end
		end)
		useStores = ok
	end

	for stat in STORES do
		local board = workspace:FindFirstChild(`Leaderboard {stat}`)
		if board and board:IsA("Model") then
			boards[stat] = board
			place(stat, board)
		else
			warn(`[LeaderboardService] Workspace."Leaderboard {stat}" not found - that board will stay empty.`)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		-- Their final score, so a session's progress is on the board before the
		-- profile is released.
		submit(player)
		lastSubmitted[player] = nil
	end)

	task.spawn(function()
		-- First paint soon after start so the boards are not blank for a minute;
		-- then the slow cadence.
		task.wait(5)
		while true do
			refresh()
			task.wait(REFRESH_INTERVAL)
		end
	end)

	print(`[LeaderboardService] world boards online ({if useStores then "OrderedDataStore" else "server-only fallback"})`)
end

--- Debug: force a refresh now.
function LeaderboardService.refreshNow()
	refresh()
end

return LeaderboardService
