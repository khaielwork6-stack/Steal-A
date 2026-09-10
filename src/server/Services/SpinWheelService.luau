--!strict
--[[
	SpinWheelService
	The recurring free spin standing on every plot.

	ONE WHEEL PER PLOT, and it belongs to whoever holds that plot right now.
	The models were placed by hand in the world (`SpinWheelConfig.MODEL_NAME`);
	this service finds them, works out which plot each one is standing inside,
	and from then on treats the pair as one thing. Nothing is built or moved -
	the art is the owner's, and rebuilding it here would throw their placement
	away on the next start-up.

	WHAT THE SERVER OWNS
	  * The clock. `Profile.SpinProgress` is seconds of ACTUAL PLAY, folded in
	    once a second from real elapsed time while the player is in the server.
	    Nothing accrues while they are away, and the ten minutes cannot be
	    served by leaving.
	  * The roll. `SpinWheelConfig.roll` against a Random this module owns.
	  * The prize. Granted the moment the roll lands, before the owner's client
	    has drawn a single frame.
	The client is sent one number - which segment won - and draws that.

	HOW A SPIN IS ASKED FOR
	A ProximityPrompt, and deliberately not a RemoteEvent. `Triggered` arrives
	with the Player Roblox resolved, on the prompt they physically walked up
	to, so "whose wheel is this" is answered by the world rather than by
	anything a client said. A tampered client can trigger any prompt it likes;
	`onTriggered` refuses every one that is not the trigger's own wheel.

	WHY THE PROMPT IS NEVER DISABLED SERVER-SIDE
	`Enabled` is one value shared by every client, and this wheel is ready for
	exactly one of them. So the server leaves it true and each CLIENT decides
	whether to show it - off for everyone but the owner, off for the owner
	until their own countdown reaches zero (SpinWheelController). That is a
	presentation decision and is treated as one: readiness, ownership and the
	spin lock are all re-checked here on every trigger, so nothing a client
	shows or hides can produce a spin.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)

local BaseGuardianService = require(script.Parent.BaseGuardianService)
local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local SpeedService = require(script.Parent.SpeedService)
local StateService = require(script.Parent.StateService)

local SpinWheelService = {}

--- One wheel, and the plot it stands on.
type Wheel = {
	model: Model,
	disc: BasePart,
	prompt: ProximityPrompt,
	plot: Instance?,
	--- The UserId currently published on the model. Held so ownership is only
	--- written when it actually changes.
	ownerUserId: number,
	--- os.clock() until which this wheel is mid-spin and accepts nothing.
	lockedUntil: number,
}

local wheels: { Wheel } = {}
local wheelByPrompt: { [ProximityPrompt]: Wheel } = {}

--- THE ONLY randomness in this feature. Seeded by Roblox per server.
local rng = Random.new()

--- Player -> os.clock() of the last accrual, so progress is folded in from
--- REAL elapsed time rather than from how often the loop happened to run. A
--- throttled server therefore under-counts nothing and over-counts nothing.
local lastAccrual: { [Player]: number } = {}

-- ==========================================================
-- ATTRIBUTES  (what the client reads)
-- ==========================================================

local ATTR_OWNER = "OwnerUserId"
local ATTR_READY_AT = "SpinReadyAt"
local ATTR_SPINNING = "Spinning"

--- Seconds of play still owed before this profile's next spin.
local function remainingFor(profile: DataService.Profile): number
	return math.max(0, SpinWheelConfig.PLAY_SECONDS - (tonumber(profile.SpinProgress) or 0))
end

--- Publishes the countdown as an ABSOLUTE server-time stamp, so the client
--- renders it locally and nothing has to be replicated once a second.
---
--- This is safe precisely because the stamp is only ever written while the
--- player is here: progress and wall-clock advance together for as long as
--- the wheel is theirs, so the two can never disagree. The moment they leave,
--- the wheel is unowned and the stamp is cleared rather than left running.
local function publishClock(wheel: Wheel, profile: DataService.Profile?)
	if not profile then
		wheel.model:SetAttribute(ATTR_READY_AT, 0)
		return
	end
	wheel.model:SetAttribute(ATTR_READY_AT, workspace:GetServerTimeNow() + remainingFor(profile))
end

--- Makes the wheel agree with who holds its plot. Cheap enough to call on a
--- tick: it writes only on a real change.
local function refreshOwner(wheel: Wheel)
	local plot = wheel.plot
	local owner = if plot then BaseService.getOwner(plot) else nil
	local userId = if owner then owner.UserId else 0
	if userId == wheel.ownerUserId then
		return
	end
	wheel.ownerUserId = userId
	wheel.model:SetAttribute(ATTR_OWNER, userId)
	-- A wheel that changes hands is not mid-spin for its new owner.
	wheel.lockedUntil = 0
	wheel.model:SetAttribute(ATTR_SPINNING, false)
	publishClock(wheel, if owner then DataService.get(owner) else nil)
end

local function wheelFor(player: Player): Wheel?
	local plot = BaseService.getPlot(player)
	if not plot then
		return nil
	end
	for _, wheel in wheels do
		if wheel.plot == plot then
			return wheel
		end
	end
	return nil
end

--- Re-publishes one player's countdown. Called after a spin and whenever a
--- plot is handed out.
function SpinWheelService.refresh(player: Player)
	local wheel = wheelFor(player)
	if not wheel then
		return
	end
	refreshOwner(wheel)
	publishClock(wheel, DataService.get(player))
end

-- ==========================================================
-- THE PRIZE
-- ==========================================================

--- Pays out one segment. Called exactly once per spin, from `onTriggered`,
--- with the wheel already locked - so there is no path where this runs twice
--- for one spin and no path where a client reaches it at all.
local function grant(player: Player, profile: DataService.Profile, segment: SpinWheelConfig.Segment)
	if segment.kind == "cash" then
		-- EXACTLY what the wedge says. Not `earn`: that applies the 2x Cash
		-- pass, and a wheel promising $1,500 must pay $1,500 to everybody.
		EconomyService.award(player, segment.amount, "other")
		StateService.notify(player, "success", `FREE SPIN: {NumberFormat.cash(segment.amount)}!`, "levelup")
	elseif segment.kind == "speed" then
		-- Added to the saved total, never multiplied into it. The Speed pass
		-- multiplies TRAINING GAIN and nothing else (see SpeedService), so a
		-- flat prize stays flat for everyone.
		profile.SpeedPower += segment.amount
		SpeedService.applyMovement(player)
		StateService.notify(player, "success", `FREE SPIN: +{NumberFormat.short(segment.amount)} SPEED!`, "levelup")
	elseif segment.kind == "guardian" and segment.guardianKey then
		local key = segment.guardianKey
		-- `grantWon` is idempotent and answers false when the player already
		-- had this animal - by pass or by a previous win. A repeat therefore
		-- cannot corrupt anything; it pays a consolation instead of nothing,
		-- so a rare wedge never lands as a blank.
		if BaseGuardianService.grantWon(player, key) then
			StateService.notify(player, "success", `FREE SPIN: THE {string.upper(key)} GUARDIAN IS YOURS!`, "levelup")
		else
			profile.SpeedPower += SpinWheelConfig.DUPLICATE_GUARDIAN_SPEED
			SpeedService.applyMovement(player)
			StateService.notify(
				player,
				"success",
				`You already own the {key} Guardian - have +{NumberFormat.short(SpinWheelConfig.DUPLICATE_GUARDIAN_SPEED)} Speed instead!`,
				"levelup"
			)
		end
	end
end

-- ==========================================================
-- THE SPIN
-- ==========================================================

local function onTriggered(player: Player, wheel: Wheel)
	-- 1. THIS PLAYER'S OWN WHEEL. The prompt was walked up to, but a tampered
	--    client can still fire any prompt in the world at any range, so the
	--    plot is re-read here rather than trusted from the trigger.
	if wheel.plot == nil or BaseService.getPlot(player) ~= wheel.plot then
		return
	end

	-- 2. NOT ALREADY SPINNING. Covers a held key, a double activation and two
	--    triggers arriving in the same frame: the lock is taken below before
	--    anything yields.
	if os.clock() < wheel.lockedUntil then
		return
	end

	local profile = DataService.get(player)
	if not profile then
		StateService.notify(player, "error", "Your data is still loading.")
		return
	end

	-- 3. THE CLOCK, re-checked against the profile at the exact moment of the
	--    spin. The client's countdown is a picture of this and never an input.
	--
	--    NO TOAST. The owner's client already knows the answer - it is drawing
	--    the same countdown - and it says so on the prompt card the moment the
	--    hold completes, which is where the player is looking. A toast across
	--    the screen for "not yet" is noise. The refusal itself still happens
	--    here, because a client that has been told to stop asking is not the
	--    same thing as a client that cannot.
	local remaining = remainingFor(profile)
	if remaining > 0 then
		return
	end

	-- LOCK AND SPEND, with no yield between them. From here the spin has
	-- happened: the progress is gone even if everything below fails, which is
	-- the safe direction - a lost spin is recoverable in ten minutes, a
	-- double-paid one is not.
	wheel.lockedUntil = os.clock() + SpinWheelConfig.LOCK_SECONDS
	wheel.model:SetAttribute(ATTR_SPINNING, true)
	profile.SpinProgress = 0
	lastAccrual[player] = os.clock()
	publishClock(wheel, profile)

	local index = SpinWheelConfig.roll(rng)
	local segment = SpinWheelConfig.segment(index)
	if not segment then
		return
	end

	grant(player, profile, segment)
	StateService.pushNow(player)

	-- The animation is told what already happened. One number: the client
	-- reads the rest out of the shared config, and there is nothing in the
	-- payload that could be replayed into a second prize.
	local ok, err = pcall(function()
		Remotes.get("SpinResult"):FireClient(player, index)
	end)
	if not ok then
		warn(`[SpinWheelService] result cue failed for {player.Name}: {err}`)
	end

	-- Durable immediately. A spin is the one action here that both spends and
	-- pays, so it must not be sitting in memory when the server goes down.
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end

	task.delay(SpinWheelConfig.LOCK_SECONDS, function()
		wheel.lockedUntil = 0
		if wheel.model.Parent then
			wheel.model:SetAttribute(ATTR_SPINNING, false)
		end
	end)

	print(`[SpinWheelService] {player.Name} spun {segment.label} (segment {index})`)
end

--- "9:59", "0:07". The countdown's own formatting, matched to what the
--- billboard shows so a refused spin and the sign never disagree.
function SpinWheelService.formatRemaining(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", total // 60, total % 60)
end

-- ==========================================================
-- THE CLOCK
-- ==========================================================

local function accrue()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local profile = DataService.get(player)
		if not profile then
			-- Still loading: start their clock when the profile lands, not at
			-- the moment they connected, so a slow load is not free progress.
			lastAccrual[player] = now
			continue
		end
		local previous = lastAccrual[player]
		lastAccrual[player] = now
		if not previous then
			continue
		end
		local progress = tonumber(profile.SpinProgress) or 0
		if progress >= SpinWheelConfig.PLAY_SECONDS then
			continue
		end
		-- Real elapsed seconds, clamped: a server that hitched for a minute
		-- pays a minute, and one that resumed from a suspended machine does
		-- not hand out a spin for time nobody played.
		local elapsed = math.clamp(now - previous, 0, SpinWheelConfig.TICK_SECONDS * 4)
		profile.SpinProgress = math.min(progress + elapsed, SpinWheelConfig.PLAY_SECONDS)
	end

	for _, wheel in wheels do
		refreshOwner(wheel)
	end
end

-- ==========================================================
-- FINDING THE WHEELS
-- ==========================================================

--- The plot whose floor this position stands on, if any.
local function plotUnder(position: Vector3): Instance?
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return nil
	end
	for _, plot in bases:GetChildren() do
		local slab = BaseService.slabOf(plot)
		if slab then
			local offset = slab.CFrame:PointToObjectSpace(position)
			if math.abs(offset.X) <= slab.Size.X / 2 and math.abs(offset.Z) <= slab.Size.Z / 2 then
				return plot
			end
		end
	end
	return nil
end

--- Dresses one hand-placed model: the current wheel art on its face, a prompt
--- in front of it, and a disc nothing can be shoved by.
local function prepare(model: Model): Wheel?
	local disc = model:FindFirstChild(SpinWheelConfig.WHEEL_PART_NAME)
	if not disc or not disc:IsA("BasePart") then
		warn(`[SpinWheelService] "{model:GetFullName()}" has no {SpinWheelConfig.WHEEL_PART_NAME} part - skipped`)
		return nil
	end

	-- THE SPINNING DISC IS SCENERY. It turns, and a turning solid part on a
	-- plot is something to be caught on and launched by. Still raycastable so
	-- the prompt's line-of-sight check behaves.
	disc.CanCollide = false
	disc.CanQuery = true
	disc.CanTouch = false
	disc.Anchored = true

	-- THE ART. The image lives in SpinWheelConfig and is re-applied on every
	-- start-up, so swapping the wheel is one line there and never a hunt
	-- through five hand-placed copies in the place file.
	local face = disc:FindFirstChildOfClass("SurfaceGui")
	if face then
		face.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		face.PixelsPerStud = SpinWheelConfig.PIXELS_PER_STUD
		face.LightInfluence = 0
		face.AlwaysOnTop = false
		local image = face:FindFirstChildOfClass("ImageLabel")
		if image then
			image.Image = SpinWheelConfig.WHEEL_IMAGE
			image.BackgroundTransparency = 1
			image.ScaleType = Enum.ScaleType.Fit
			image.Size = UDim2.fromScale(1, 1)
			image.Position = UDim2.fromScale(0.5, 0.5)
			image.AnchorPoint = Vector2.new(0.5, 0.5)
		end
	end

	-- The prompt stands in the clear air in front of the wheel, at head
	-- height, on the side a player approaches from. NAMED "PromptAnchor" on
	-- purpose: InteractController's card reads that name and skips its usual
	-- lift, so the card appears exactly here rather than above the disc.
	local existing = model:FindFirstChild("PromptAnchor")
	if existing then
		existing:Destroy()
	end
	local anchor = Instance.new("Part")
	anchor.Name = "PromptAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	-- Out from the face the art is on (the disc's own +X), and only slightly
	-- below the hub - which puts the card in clear air BETWEEN the player and
	-- the wheel. Lower and it hides behind their own head; higher and it
	-- collides with the countdown sign above the wheel.
	anchor.CFrame = CFrame.new(disc.Position + disc.CFrame.RightVector * 6.5 - Vector3.new(0, 0.6, 0))
	anchor.Parent = model

	-- A STILL POINT FOR THE COUNTDOWN. The disc SPINS, and a BillboardGui's
	-- StudsOffsetWorldSpace turns with its adornee - so a sign offset straight
	-- up off the disc sat above the wheel only while the wheel happened to be
	-- at rest, and swung out to the side for every angle it landed on. This
	-- anchor is a separate part that nothing rotates; the client adorns to it
	-- with no offset at all, so there is nothing left to turn.
	local stale = model:FindFirstChild(SpinWheelConfig.SIGN_ANCHOR_NAME)
	if stale then
		stale:Destroy()
	end
	local signAnchor = Instance.new("Part")
	signAnchor.Name = SpinWheelConfig.SIGN_ANCHOR_NAME
	signAnchor.Size = Vector3.new(1, 1, 1)
	signAnchor.Transparency = 1
	signAnchor.Anchored = true
	signAnchor.CanCollide = false
	signAnchor.CanQuery = false
	signAnchor.CanTouch = false
	signAnchor.CastShadow = false
	signAnchor.CFrame = CFrame.new(disc.Position + Vector3.new(0, math.max(disc.Size.Y, disc.Size.Z) / 2 + 3, 0))
	signAnchor.Parent = model

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SpinPrompt"
	prompt.ActionText = SpinWheelConfig.PROMPT_ACTION
	prompt.ObjectText = SpinWheelConfig.PROMPT_OBJECT
	prompt.HoldDuration = SpinWheelConfig.PROMPT_HOLD
	prompt.MaxActivationDistance = SpinWheelConfig.PROMPT_RANGE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	-- Left TRUE for everyone and hidden per client. See the header.
	prompt.Enabled = true
	prompt.Parent = anchor

	model:SetAttribute(ATTR_OWNER, 0)
	model:SetAttribute(ATTR_READY_AT, 0)
	model:SetAttribute(ATTR_SPINNING, false)

	local wheel: Wheel = {
		model = model,
		disc = disc,
		prompt = prompt,
		plot = plotUnder(model:GetPivot().Position),
		ownerUserId = -1, -- forces the first refreshOwner to publish
		lockedUntil = 0,
	}
	wheelByPrompt[prompt] = wheel
	return wheel
end

-- ==========================================================
-- START
-- ==========================================================

function SpinWheelService.start()
	workspace:WaitForChild("Map", 20)

	table.clear(wheels)
	table.clear(wheelByPrompt)
	for _, child in workspace:GetDescendants() do
		if child:IsA("Model") and child.Name == SpinWheelConfig.MODEL_NAME then
			local wheel = prepare(child)
			if wheel then
				table.insert(wheels, wheel)
			end
		end
	end

	local unplaced = 0
	for _, wheel in wheels do
		refreshOwner(wheel)
		if not wheel.plot then
			unplaced += 1
			warn(`[SpinWheelService] "{wheel.model:GetFullName()}" is not standing on any plot - it will never be owned`)
		end
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		local wheel = wheelByPrompt[prompt]
		if wheel then
			onTriggered(player, wheel)
		end
	end)

	-- A plot changing hands is a rebuild, so the wheel follows the same
	-- signal every other per-plot system follows.
	BaseService.onRebuilt(function(player)
		SpinWheelService.refresh(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastAccrual[player] = nil
		-- The plot is released on this same event; the accrual tick below
		-- notices and clears the wheel either way.
	end)

	task.spawn(function()
		while true do
			task.wait(SpinWheelConfig.TICK_SECONDS)
			local ok, err = pcall(accrue)
			if not ok then
				warn(`[SpinWheelService] clock tick failed: {err}`)
			end
		end
	end)

	print(
		`[SpinWheelService] {#wheels} wheel(s) online, {#wheels - unplaced} bound to plots; `
			.. `{SpinWheelConfig.PLAY_SECONDS}s of play per spin`
	)
end

-- ==========================================================
-- DEBUG
-- ==========================================================

--- Studio only: hands a player their next spin immediately.
function SpinWheelService.debugReady(player: Player): boolean
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	profile.SpinProgress = SpinWheelConfig.PLAY_SECONDS
	SpinWheelService.refresh(player)
	return true
end

function SpinWheelService.inspect(player: Player): { [string]: any }
	local profile = DataService.get(player)
	local wheel = wheelFor(player)
	return {
		progress = if profile then profile.SpinProgress else nil,
		required = SpinWheelConfig.PLAY_SECONDS,
		remaining = if profile then remainingFor(profile) else nil,
		wheels = #wheels,
		plot = if wheel and wheel.plot then wheel.plot.Name else nil,
		ownerUserId = if wheel then wheel.ownerUserId else nil,
		readyAt = if wheel then wheel.model:GetAttribute(ATTR_READY_AT) else nil,
		locked = if wheel then os.clock() < wheel.lockedUntil else nil,
		guardiansWon = if profile then profile.GuardiansWon else nil,
	}
end

--- Studio only: pays out ONE named segment through the same `grant` a real
--- spin uses, so the rare wedges can be tested without waiting for a 1-in-200
--- roll. It deliberately skips the gate rather than reimplementing it - the
--- thing under test is the payout, and a second copy of the payout would test
--- nothing.
function SpinWheelService.debugGrant(player: Player, index: number): { [string]: any }
	local profile = DataService.get(player)
	local segment = SpinWheelConfig.segment(index)
	if not profile or not segment then
		return { error = "no profile or no such segment" }
	end
	local before = { cash = profile.Cash, speed = profile.SpeedPower, equipped = profile.EquippedGuardian }
	grant(player, profile, segment)
	StateService.pushNow(player)
	return {
		segment = segment.label,
		before = before,
		after = { cash = profile.Cash, speed = profile.SpeedPower, equipped = profile.EquippedGuardian },
		guardiansWon = profile.GuardiansWon,
	}
end

--- Studio only: rolls the wheel `count` times WITHOUT granting anything, so
--- the odds can be checked against the table rather than taken on trust.
function SpinWheelService.debugOdds(count: number): { [string]: any }
	local tally: { [number]: number } = {}
	for _ = 1, count do
		local index = SpinWheelConfig.roll(rng)
		tally[index] = (tally[index] or 0) + 1
	end
	local rows = {}
	for _, segment in SpinWheelConfig.Segments do
		local hits = tally[segment.index] or 0
		table.insert(rows, {
			index = segment.index,
			label = segment.label,
			weight = segment.weight,
			expected = segment.weight / SpinWheelConfig.TOTAL_WEIGHT,
			actual = hits / count,
		})
	end
	return { rolls = count, rows = rows }
end

return SpinWheelService
