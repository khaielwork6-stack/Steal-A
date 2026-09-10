--!strict
--[[
	BaseEarningsController
	The floating "+$1,512" that rises off every earning trophy on YOUR base,
	once a second, in step with the income tick that actually pays it.

	WHY ONLY YOUR OWN BASE
	Seven plots x fourteen slots is ninety-eight pedestals. Popping a number
	over all of them would put a hundred labels a second over the plaza and
	make every base unreadable - including the one the player came to look at.
	The number is feedback about YOUR money, so it is drawn on the plot whose
	OwnerUserId is this player and nowhere else. A visitor still sees the
	nameplate rate on each trophy, which is what tells them what a collection
	is worth.

	WHY IT LINES UP WITH THE MONEY
	The figure comes from the `IncomeRate` attribute the server stamps on each
	trophy (BaseService), which is EconomyService.maturedRate - the real paid
	rate with the money pass and both boosts folded in. It is not
	item.FinalIncome, which is the card rate at moneyPass 1 and would show a
	smaller number than the one landing in Cash. The cadence is
	GameConfig.INCOME_TICK, the same second the server grants on, so fourteen
	trophies popping "+$1,512" add up on screen to the "$/s" on the HUD.

	A GROWING TROPHY STAYS SILENT
	`MaturationRemaining` is stamped at build time and counted down locally, so
	a trophy starts popping numbers the moment it matures rather than waiting
	for the next base rebuild - and never advertises income it is not paying.

	HOW OVERLAP IS AVOIDED
	Two rules, and between them numbers never pile up:
	  1. ONE label per trophy, reused. The label lives as long as it takes to
	     rise and fade (just under a tick), so a trophy can never have two of
	     its own numbers in the air at once. It is also why nothing is created
	     or destroyed per second - fourteen BillboardGuis exist and are
	     re-run, rather than fourteen a second being built and thrown away.
	  2. A per-slot phase offset. Without it all fourteen fire on the same
	     frame and the base reads as one wall of green. Spread across the
	     tick, they read as a base that is working.

	Cosmetic and client-only, like DisplayFxController: nothing here decides
	or reports what anything earns, and the server has already paid it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.GameConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

local BaseEarningsController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- TUNING
-- ==========================================================

--- One number per income tick, because that is when the Cash actually lands.
local TICK = GameConfig.INCOME_TICK

--- How long a single number is in the air. Just under the tick, so each one
--- has finished before that trophy's next is due.
local LIFETIME = 0.92
--- Studs it climbs over its life.
local RISE = 3
--- Studs above the top of the item that the number STARTS at.
---
--- Clear of the nameplate, not level with it. BaseService seats TrophyLabel
--- 2.4 studs over the item and it is 3.6 studs tall, so it occupies roughly
--- 0.6 to 4.2 above the top; a number starting under that and rising would
--- pass straight through the name and the rate on its way up, which is
--- exactly the "overlapping messily" this is supposed to avoid. Starting
--- above the card means the two never share space at any point in the rise.
--- The billboard is CARD_SIZE tall and centred on this point, so the clearance
--- has to cover half of that too, which is why it is not simply 4.2.
local START_LIFT = 5.8

--- The punch at the start: it appears slightly large and settles, which is
--- what makes it read as a hit rather than as a label fading in.
local POP_SCALE = 1.35
local POP_FRACTION = 0.18 -- of LIFETIME spent settling

--- It holds full opacity for this fraction of its life, then fades. Fading
--- from the first frame makes the number hard to read at exactly the moment
--- the player wants to read it.
local HOLD_FRACTION = 0.45

--- Billboard size in studs, and the pixel ceiling on the text so a Colossal's
--- label is not four times the size of a coin's.
local CARD_SIZE = UDim2.fromScale(7.5, 2.1)
local MAX_TEXT = 44

local BRIGHT = Color3.fromRGB(126, 255, 148)
local OUTLINE = Color3.fromRGB(10, 46, 18)

--- Only trophies this close to the camera animate at all.
local ANIMATE_DISTANCE = 220
--- How often the near/far set and the plot ownership are re-checked.
local CULL_INTERVAL = 0.5

-- ==========================================================
-- STATE
-- ==========================================================

type Entry = {
	trophy: Model,
	anchor: BasePart,
	gui: BillboardGui,
	label: TextLabel,
	--- World Y of the item's top, so the number starts just above it.
	lift: number,
	--- Absolute clock of this trophy's next number. Scheduled rather than
	--- sampled from a modulo window: at a low frame rate a window narrow
	--- enough not to double-fire is also narrow enough to be stepped over,
	--- and the base would drop numbers exactly when it was busiest.
	nextFireAt: number,
	--- Absolute clock of the current number's start, or nil when idle.
	startedAt: number?,
	--- Countdown stamped by the server, and the clock it was read at.
	maturesAt: number,
	rate: number,
}

local entries: { [Model]: Entry } = {}
local reducedEffects = false
local nextCull = 0

function BaseEarningsController.setReducedEffects(value: boolean)
	reducedEffects = value
end

-- ==========================================================
-- REGISTRY
-- ==========================================================

--- The plot this player owns, or nil while they have none yet.
local function ownPlot(): Instance?
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return nil
	end
	for _, plot in bases:GetChildren() do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			return plot
		end
	end
	return nil
end

local function release(trophy: Model)
	local entry = entries[trophy]
	if entry then
		entry.gui:Destroy()
		entries[trophy] = nil
	end
end

--- Builds the one reusable label for a trophy. Returns nil for anything that
--- is not an earning trophy: a sealed container (no IncomeRate), a robbed one,
--- or an item whose rate rounds to nothing.
local function register(trophy: Model, index: number): Entry?
	if entries[trophy] then
		return entries[trophy]
	end
	local rate = tonumber(trophy:GetAttribute("IncomeRate"))
	if not rate or rate <= 0 then
		return nil
	end
	local anchor = trophy.PrimaryPart or trophy:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		return nil
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "EarningsPop"
	gui.Size = CARD_SIZE
	-- Never AlwaysOnTop: a number that draws through the pedestal in front of
	-- it (or through a wall from the avenue) is the same class of problem as
	-- loot glowing through geometry.
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = ANIMATE_DISTANCE
	gui.Adornee = anchor
	gui.Enabled = false
	gui.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Name = "Amount"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = BRIGHT
	label.TextStrokeColor3 = OUTLINE
	label.TextStrokeTransparency = 0
	label.Text = ""
	label.Parent = gui
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = MAX_TEXT
	cap.Parent = label

	-- The top of the item, so a coin and a Colossal both get their number just
	-- clear of themselves rather than buried inside. visibleExtents, not
	-- GetBoundingBox: the same measure BaseService seats the nameplate from, so
	-- the number and the nameplate agree about where the item ends and neither
	-- is thrown off by an invisible prompt anchor welded inside the model.
	local _, maxCorner = LootModel.visibleExtents(trophy)
	local top = if maxCorner then maxCorner.Y else anchor.Position.Y

	local remaining = tonumber(trophy:GetAttribute("MaturationRemaining")) or 0

	local entry: Entry = {
		trophy = trophy,
		anchor = anchor,
		gui = gui,
		label = label,
		lift = top - anchor.Position.Y + START_LIFT,
		-- Spread across the tick by slot, so neighbours never fire together.
		nextFireAt = os.clock() + (index * 0.137) % TICK,
		startedAt = nil,
		maturesAt = os.clock() + math.max(0, remaining),
		rate = rate,
	}
	entries[trophy] = entry

	trophy.AncestryChanged:Connect(function()
		if not trophy:IsDescendantOf(workspace) then
			release(trophy)
		end
	end)
	-- A growth re-seat or a boost change restamps the rate; the label follows
	-- rather than paying out a figure captured when it was first placed.
	trophy:GetAttributeChangedSignal("IncomeRate"):Connect(function()
		local updated = tonumber(trophy:GetAttribute("IncomeRate"))
		if updated and updated > 0 then
			entry.rate = updated
		else
			release(trophy)
		end
	end)

	return entry
end

--- Re-scans the owned plot. Cheap enough twice a second: it walks fourteen
--- slots, and every trophy it has already seen short-circuits in `register`.
local function rescan()
	local plot = ownPlot()
	if not plot then
		for trophy in entries do
			release(trophy)
		end
		return
	end
	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return
	end

	local seen: { [Model]: true } = {}
	local index = 0
	for _, slot in slots:GetChildren() do
		index += 1
		local trophy = slot:FindFirstChild("Trophy")
		if trophy and trophy:IsA("Model") then
			if register(trophy, index) then
				seen[trophy] = true
			end
		end
	end
	-- Anything that left its slot (sold, stored, robbed, rebuilt) goes with it.
	for trophy in entries do
		if not seen[trophy] then
			release(trophy)
		end
	end
end

-- ==========================================================
-- FRAME
-- ==========================================================

local function step()
	local now = os.clock()

	if now >= nextCull then
		nextCull = now + CULL_INTERVAL
		rescan()
	end

	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero

	for _, entry in entries do
		local anchor = entry.anchor
		if not anchor.Parent then
			continue
		end

		local far = (anchor.Position - eye).Magnitude > ANIMATE_DISTANCE
		local started = entry.startedAt

		if not started then
			-- Idle: start one when this trophy's slot in the tick comes round,
			-- and only once it is actually earning and actually on screen.
			if far or reducedEffects or now < entry.maturesAt then
				continue
			end
			if now >= entry.nextFireAt then
				entry.nextFireAt = now + TICK
				entry.startedAt = now
				entry.label.Text = `+${NumberFormat.comma(entry.rate)}`
				entry.gui.Enabled = true
			end
			continue
		end

		local elapsed = now - started
		if elapsed >= LIFETIME or far then
			entry.startedAt = nil
			entry.gui.Enabled = false
			continue
		end

		local t = elapsed / LIFETIME

		-- Rise: fast at first, easing out, so it leaves the item with intent
		-- and drifts to a stop rather than travelling at a constant crawl.
		local ease = 1 - (1 - t) * (1 - t)
		entry.gui.StudsOffsetWorldSpace = Vector3.new(0, entry.lift + RISE * ease, 0)

		-- Pop: oversized on the first frames, settling to 1.
		local scale = 1
		if t < POP_FRACTION then
			scale = POP_SCALE + (1 - POP_SCALE) * (t / POP_FRACTION)
		end
		entry.gui.Size = UDim2.fromScale(CARD_SIZE.X.Scale * scale, CARD_SIZE.Y.Scale * scale)

		-- Fade: full opacity while it is worth reading, then out. The stroke
		-- fades WITH the text; a stroke left behind reads as a smudge.
		local alpha = 0
		if t > HOLD_FRACTION then
			alpha = (t - HOLD_FRACTION) / (1 - HOLD_FRACTION)
		end
		entry.label.TextTransparency = alpha
		entry.label.TextStrokeTransparency = alpha
	end
end

-- ==========================================================
-- START
-- ==========================================================

function BaseEarningsController.start()
	RunService.Heartbeat:Connect(step)
end

return BaseEarningsController
