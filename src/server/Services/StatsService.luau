--!strict
--[[
	StatsService
	Roblox's OWN player list, showing   Username | Speed | Money.

	NOT A CUSTOM LEADERBOARD. This fills the standard `leaderstats` folder and
	lets the CoreGui player list render it, which is exactly what the brief asks
	for. The world boards are LeaderboardService's; this is the Tab key.

	ONE SOURCE OF TRUTH
	Nothing here reads a stat from anywhere but the profile, and nothing here is
	polled. StateService already builds a snapshot from the profile every time
	anything changes it - cash, a treadmill tick, a receipt, a sale - so this
	simply mirrors each of those snapshots into the two values. Money and Speed
	in the player list can therefore never disagree with the HUD, because they
	are the same number from the same push.

	WHY Speed IS FIRST
	The player list sorts on the FIRST child of leaderstats. Speed is the game's
	progression axis (zones gate on it; Money is spent down constantly), so the
	fastest players sit at the top, with Money alongside as the second column.

	WHY NumberValue AND NOT A FORMATTED STRING
	Late-game Money runs past 2^31 and a StringValue would sort alphabetically -
	"$9B" above "$1.2T". NumberValue keeps numeric sorting and holds the full
	range; the cost is that Roblox renders the raw digits. That trade is made
	deliberately: a correctly-ordered list matters more than abbreviations, and
	the CoreGui list offers no way to have both.
]]

local Players = game:GetService("Players")

local StatsService = {}

local READY_ATTRIBUTE = "StatsReady"

local function ensureStats(player: Player): (NumberValue, NumberValue)
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
	end

	-- Creation ORDER is display order. Speed first so the list ranks by it.
	local speed = folder:FindFirstChild("Speed")
	if not speed then
		speed = Instance.new("NumberValue")
		speed.Name = "Speed"
		speed.Parent = folder
	end
	local money = folder:FindFirstChild("Money")
	if not money then
		money = Instance.new("NumberValue")
		money.Name = "Money"
		money.Parent = folder
	end
	return speed :: NumberValue, money :: NumberValue
end

--- Mirrors one state snapshot into the player list. Cheap enough to run on
--- every push: two property writes, replicated only when the value changes.
function StatsService.reflect(player: Player, cash: number, speedPower: number)
	if not player.Parent then
		return
	end
	local speed, money = ensureStats(player)
	local roundedSpeed = math.floor(speedPower + 0.5)
	local roundedCash = math.floor(cash + 0.5)
	if speed.Value ~= roundedSpeed then
		speed.Value = roundedSpeed
	end
	if money.Value ~= roundedCash then
		money.Value = roundedCash
	end
	if not player:GetAttribute(READY_ATTRIBUTE) then
		player:SetAttribute(READY_ATTRIBUTE, true)
	end
end

function StatsService.start()
	-- The folder exists from the first frame so the list never shows a player
	-- with no columns; the values fill in on the first push.
	local function onPlayer(player: Player)
		ensureStats(player)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
end

return StatsService
