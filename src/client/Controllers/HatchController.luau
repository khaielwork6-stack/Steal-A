--!strict
--[[
	HatchController  (the REVEAL controller; the module keeps its old name)
	The timer card over a sealed container, the prompt flip when it is ready,
	and the one short scripted reveal.

	NOTHING HERE DECIDES ANYTHING. The server commits the reveal - flips the
	flag, starts the income - before it tells this client to animate, and it
	swaps the container for the item on the pedestal swapAt seconds later.
	This controller draws the wait, then plays the roulette in between, then
	shows whatever the server put there. If it never finishes, the item is
	already the player's.

	THE ROULETTE (2026-09-17). The camera flies in to a stage above the
	pedestal, a run of real items in every size blurs past with a tick on each
	change, brakes, fakes a stop on the zone's rarest item, and clicks over
	onto the prize; the camera drops to the real item, holds, and flies home.

	THE ANIMATION RUNS ON A CLONE. The authoritative container is hidden
	locally the moment the sequence starts and is destroyed by the server's
	rebuild on the pop frame; the clone is what levitates, turns and pops. The
	arriving item is concealed the instant it replicates and shown on the pop
	frame together with the clone's dissolve, so there is never a moment with
	nothing on the pedestal.

	SOUND. HatchConfig.POP_SOUND, a 4.5s build-up, plays once on the first
	frame and peaks on the pop; each roulette change plays one tick. The
	server sends no cue for either.

	WHAT IT REFUSES TO SHOW
	Nothing in this file reads or renders an item name, rarity, income, size
	word or mutation word for a SEALED container. The card is a clock and a
	bar. The reveal's colours arrive only after the commit.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local HatchConfig = require(ReplicatedStorage.Shared.Config.HatchConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local ItemArtReady = require(ReplicatedStorage.Shared.Util.ItemArtReady)
local MysteryConfig = require(ReplicatedStorage.Shared.Config.MysteryConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local HatchController = {}

local player = Players.LocalPlayer

--- Sealed containers this client knows about, from StatePush. InstanceId ->
--- { endsAt, startedAt }. Never carries anything about the reward.
local sealed: { [string]: { endsAt: number, startedAt: number } } = {}

--- One reveal at a time, and one token per reveal: a late tween from an
--- abandoned sequence checks its token and stops rather than touching a
--- pedestal that has moved on.
local revealToken = 0

local GOLD = Color3.fromRGB(255, 208, 96)
local WHITE = Color3.fromRGB(255, 255, 255)

--- Reduced Effects, mirrored from the settings panel. It switches off the
--- focus vignette and the camera shake; the roulette and the camera fly-in
--- still play, because they ARE the feature rather than a flourish on top.
local reducedEffects = false

function HatchController.setReducedEffects(value: boolean)
	reducedEffects = value
end

-- ==========================================================
-- THE OWNER'S SLOTS
-- ==========================================================

local function formatRemaining(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	if total >= 3600 then
		return string.format("%dh %02dm", total // 3600, (total % 3600) // 60)
	elseif total >= 60 then
		return string.format("%02d:%02d", total // 60, total % 60)
	end
	return string.format("%ds", total)
end

-- ==========================================================
-- WHOSE COUNTDOWN IS IT
-- ==========================================================
--
-- The reveal card is built SERVER-side on the pedestal, so it replicates to
-- everyone standing on the plot. It should not: how long is left on somebody
-- else's container is their business, it is the only thing on a visiting
-- player's screen they can do nothing about, and a base with six of them
-- reads as a wall of clocks belonging to a stranger.
--
-- Hidden locally rather than not built at all: the card carries the absolute
-- end stamp the owner's own client counts down from, and moving it to a
-- per-client build would mean replicating that stamp a second way.

--- The plot a thing sits on, if any - the child of Map.Bases above it.
local function plotOf(thing: Instance): Instance?
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return nil
	end
	local node: Instance? = thing
	while node do
		local parent = node.Parent
		if parent == bases then
			return node
		end
		node = parent
	end
	return nil
end

--- Shows a reveal card only to the player whose container it is.
local function applyCardOwnership(card: BillboardGui)
	local plot = plotOf(card)
	card.Enabled = plot ~= nil and plot:GetAttribute("OwnerUserId") == player.UserId
end

--- Every display slot on the plot the local player owns.
local function eachOwnedSlot(): { BasePart }
	local out: { BasePart } = {}
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("Bases")
	if not bases then
		return out
	end
	for _, plot in bases:GetChildren() do
		if plot:GetAttribute("OwnerUserId") ~= player.UserId then
			continue
		end
		local slots = plot:FindFirstChild("DisplaySlots")
		if not slots then
			continue
		end
		for _, slot in slots:GetChildren() do
			if slot:IsA("BasePart") then
				table.insert(out, slot)
			end
		end
	end
	return out
end

-- ==========================================================
-- THE TIMER CARD
-- ==========================================================
--
-- The server builds the card once per rebuild with an absolute end stamp on
-- it. This retimes the text and the bar ONCE A SECOND - never per frame - so a
-- twelve-hour wait costs nothing and the clock is still right to the second.

local lastCardTick = -1

local function repaintCards()
	-- The SERVER's clock, not this device's: HatchEndsAt is stamped with the
	-- server's os.time(), and a phone whose clock is a minute off used to show
	-- a countdown a minute wrong (or READY before the server agreed). Ticks
	-- are also aligned to the server's whole seconds, so the text changes on
	-- the second it should rather than up to a second late.
	local now = workspace:GetServerTimeNow()
	local second = math.floor(now)
	if second == lastCardTick then
		return
	end
	lastCardTick = second

	for _, slot in eachOwnedSlot() do
		local card = slot:FindFirstChild("RevealCard")
		if not card or not card:IsA("BillboardGui") then
			continue
		end
		local plate = card:FindFirstChild("Plate")
		local caption = plate and plate:FindFirstChild("Caption") :: TextLabel?
		local clock = plate and plate:FindFirstChild("Clock") :: TextLabel?
		local outline = plate and plate:FindFirstChild("Outline") :: UIStroke?
		local track = plate and plate:FindFirstChild("Track")
		local fill = track and track:FindFirstChild("Fill") :: Frame?
		if not clock or not caption then
			continue
		end

		local endsAt = tonumber(card:GetAttribute("HatchEndsAt")) or 0
		local remaining = endsAt - now

		if remaining <= 0 then
			caption.Text = ""
			clock.Text = "READY TO REVEAL!"
			-- A restrained gold-to-green breath, once a second.
			local warm = second % 2 == 0
			clock.TextColor3 = if warm then MysteryConfig.READY_TINT else GOLD
			if outline then
				outline.Color = if warm then MysteryConfig.READY_TINT else GOLD
			end
			if fill then
				fill.Size = UDim2.fromScale(1, 1)
				fill.BackgroundColor3 = MysteryConfig.READY_TINT
			end
		else
			caption.Text = "REVEAL IN"
			clock.Text = formatRemaining(remaining)
			-- The final ten seconds pulse softly between white and gold.
			if remaining <= HatchConfig.CARD_PULSE_FROM then
				clock.TextColor3 = if second % 2 == 0 then GOLD else WHITE
			else
				clock.TextColor3 = WHITE
			end
			if outline then
				outline.Color = GOLD
			end
			local id = card:GetAttribute("InstanceId")
			local entry = if type(id) == "string" then sealed[id] else nil
			if fill and entry then
				-- The bar needs a start as well as an end. The only honest one
				-- the client has is "when this client first saw it", so a fresh
				-- join shows a bar already partly full rather than one that
				-- lies about the total wait.
				local total = math.max(entry.endsAt - entry.startedAt, 1)
				fill.Size = UDim2.fromScale(math.clamp(1 - remaining / total, 0, 1), 1)
			end
		end

		-- THE PROMPT FLIPS WITH THE CLOCK. The slot has one prompt; the
		-- server titled it "Instant Reveal" while there was time left, and the
		-- second there is none it reads "Reveal". Local text only - the
		-- server re-derives the real state on every trigger.
		local prompt = slot:FindFirstChild("SlotPrompt")
		if prompt and prompt:IsA("ProximityPrompt") then
			local promptEnds = tonumber(prompt:GetAttribute("RevealEndsAt"))
			if promptEnds and promptEnds - now <= 0 and prompt.ActionText == "Instant Reveal" then
				prompt.ActionText = "Reveal"
			end
		end
	end
end

-- ==========================================================
-- THE REVEAL
-- ==========================================================

local function playPop()
	local sound = Audio.create(HatchConfig.POP_SOUND)
	if not sound then
		return
	end
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(6, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

--- Hides a model on this client only: parts, particles, lights and any GUI.
--- Returns the emitters and lights it switched off so they can be restored.
local function conceal(model: Model): { Instance }
	local paused: { Instance } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 1
		elseif d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("Beam") or d:IsA("Trail") then
			if (d :: any).Enabled then
				(d :: any).Enabled = false
				table.insert(paused, d)
			end
		elseif d:IsA("BillboardGui") then
			if d.Enabled then
				d.Enabled = false
				table.insert(paused, d)
			end
		end
	end
	return paused
end

local function unconceal(model: Model, paused: { Instance })
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 0
		end
	end
	for _, d in paused do
		if d.Parent then
			(d :: any).Enabled = true
		end
	end
end

--- Decorative, non-collidable fragments. Capped, and capped harder on a
--- phone: a Colossal reveal must still be a reveal at thirty frames.
local function burstFragments(origin: CFrame, color: Color3, span: number)
	local count = if Device.isTouch() then HatchConfig.MAX_FRAGMENTS_MOBILE else HatchConfig.MAX_FRAGMENTS
	local folder = Instance.new("Folder")
	folder.Name = "RevealFragments"
	folder.Parent = workspace
	for _ = 1, count do
		local shard = Instance.new("Part")
		shard.Size = Vector3.one * span * 0.06
		shard.CFrame = origin * CFrame.new((math.random() - 0.5) * span * 0.3, (math.random() - 0.5) * span * 0.3, (math.random() - 0.5) * span * 0.3)
		shard.Color = color
		shard.Material = Enum.Material.Neon
		shard.Anchored = true
		shard.CanCollide = false
		shard.CanQuery = false
		shard.CanTouch = false
		shard.CastShadow = false
		shard.Parent = folder
		local direction = Vector3.new(math.random() - 0.5, math.random() * 0.8 + 0.2, math.random() - 0.5).Unit
		TweenService:Create(shard, TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			CFrame = (shard.CFrame + direction * span * (0.7 + math.random() * 0.6)) * CFrame.Angles(math.random() * 6, math.random() * 6, 0),
			Transparency = 1,
			Size = Vector3.new(0.05, 0.05, 0.05),
		}):Play()
	end
	task.delay(1.2, function()
		folder:Destroy()
	end)
end

--- One ring on the pedestal. Expanding for the shockwave; contracting, when
--- `inward` is set, for the breath before the pop.
local function ring(at: CFrame, color: Color3, span: number, time: number, inward: boolean?)
	local disc = Instance.new("Part")
	disc.Name = "RevealRing"
	disc.Shape = Enum.PartType.Cylinder
	local from = if inward then span * 2.0 else span * 0.5
	local to = if inward then span * 0.4 else span * 2.4
	disc.Size = Vector3.new(0.2, from, from)
	disc.CFrame = at * CFrame.Angles(0, 0, math.rad(90))
	disc.Color = color
	disc.Material = Enum.Material.Neon
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	disc.Transparency = if inward then 0.7 else 0.25
	disc.Parent = workspace
	local tween = TweenService:Create(disc, TweenInfo.new(time, Enum.EasingStyle.Quint, if inward then Enum.EasingDirection.In else Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, to, to),
		Transparency = if inward then 0.2 else 1,
	})
	tween:Play()
	tween.Completed:Once(function()
		disc:Destroy()
	end)
end

--- Drives a 0..1 value through a tween and calls back every frame.
local function drive(duration: number, style: Enum.EasingStyle, direction: Enum.EasingDirection, onStep: (number) -> ())
	local value = Instance.new("NumberValue")
	value.Value = 0
	local connection = value.Changed:Connect(onStep)
	local tween = TweenService:Create(value, TweenInfo.new(duration, style, direction), { Value = 1 })
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	onStep(1)
	value:Destroy()
end

-- ==========================================================
-- THE ROULETTE
-- ==========================================================
--
-- A casino run of real items, in colour and in every size, that blurs past
-- and brakes onto the prize while the camera sits right on the stage.
--
-- IT DECIDES NOTHING. The server rolled the reward, committed it, started the
-- income and only then sent the cue this reads. The last item is the
-- payload's itemId; the decoys come from the public loot tables, which every
-- client already has. There is no path from anything in this section to what
-- a player receives, so a tampered animation is only ever a tampered
-- animation.

--- A roulette item: anchored, untouchable, no effects of its own (two dozen
--- emitters flicking on and off is noise, and a phone pays for every one).
local function prepareRouletteItem(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
		elseif
			d:IsA("ParticleEmitter")
			or d:IsA("Trail")
			or d:IsA("Beam")
			or d:IsA("Fire")
			or d:IsA("Smoke")
			or d:IsA("Sparkles")
			or d:IsA("Light")
			or d:IsA("Highlight")
			or d:IsA("BillboardGui")
			or d:IsA("ProximityPrompt")
			or d:IsA("LuaSourceContainer")
		then
			d:Destroy()
		end
	end
end

--- A framed, full-colour copy of an item, or nil when it has no published art.
--- Built from the ReplicatedStorage previews, so this works on the client.
---
--- The pivot is moved to the centre of the item's box, so every item sits
--- dead centre on the stage and scales about its own middle. sizeClass
--- multiplies the stage span: every item is FITTED to the stage first, so a
--- Colossal prize and a coin are both readable, and is then deliberately
--- pushed off that size by its class.
local function buildRouletteItem(itemId: string, sizeClass: number): Model?
	local source = LootModel.previewSource(itemId)
	if not source then
		return nil
	end
	local model = source:Clone()
	prepareRouletteItem(model)
	local box, size = model:GetBoundingBox()
	local pivot = model:GetPivot()
	model.PrimaryPart = nil
	model.WorldPivot = CFrame.new(box.Position) * pivot.Rotation
	local largest = math.max(size.X, size.Y, size.Z)
	if largest > 0.01 then
		local target = HatchConfig.Roulette.stageSpan * sizeClass
		model:ScaleTo(model:GetScale() * (target / largest))
	end
	return model
end

--- The decoys, in the order they will be shown, and the TEASER for the
--- fake-out frame.
---
--- The pool is this zone's items plus its neighbours', so the wheel shows far
--- more than eight things and flashes past a few the player cannot get here
--- yet. Never the prize, never the same item twice running - not even across
--- the seam where the bag is refilled. The teaser is the rarest decoy: the
--- wheel appears to stop on it and then clicks over, which is the moment the
--- whole sequence is built around.
local function decoyOrder(zoneIndex: number, prizeId: string, count: number): ({ string }, string?)
	local reach = HatchConfig.Roulette.neighbourZones
	local pool: { string } = {}
	local teaser: string? = nil
	local teaserRank = -1
	for zone = zoneIndex - reach, zoneIndex + reach do
		for _, def in LootConfig.pool(zone) do
			if def.id ~= prizeId and LootModel.previewSource(def.id) then
				table.insert(pool, def.id)
				-- Only this zone's own items can tease: the "almost" has to be
				-- something the player could genuinely have won here.
				local rank = RarityConfig.rank(def.rarity)
				if zone == zoneIndex and rank > teaserRank then
					teaser = def.id
					teaserRank = rank
				end
			end
		end
	end
	if #pool == 0 then
		return {}, nil
	end

	local out = table.create(count)
	local bag: { string } = {}
	local last: string? = nil
	for _ = 1, count do
		if #bag == 0 then
			table.move(pool, 1, #pool, 1, bag)
			for index = #bag, 2, -1 do
				local swap = math.random(index)
				bag[index], bag[swap] = bag[swap], bag[index]
			end
			-- The next draw comes off the END of the bag; if that repeats what
			-- is already on screen, trade it with the front.
			if #bag > 1 and bag[#bag] == last then
				bag[#bag], bag[1] = bag[1], bag[#bag]
			end
		end
		local id = table.remove(bag) :: string
		last = id
		table.insert(out, id)
	end
	return out, teaser
end

--- A size class for every change, never the same one twice running, so the
--- run jumps tiny - huge - medium instead of drifting.
local function sizeOrder(count: number): { number }
	local classes = HatchConfig.Roulette.sizeClasses
	local out = table.create(count)
	local last = 0
	for index = 1, count do
		local pick = math.random(#classes)
		if pick == last and #classes > 1 then
			pick = (pick % #classes) + 1
		end
		last = pick
		out[index] = classes[pick]
	end
	return out
end

--- One shot of the tick. Called BY a change and never by a clock of its own,
--- which is the whole reason the sound cannot drift from the picture:
--- switch, tick, wait, switch.
---
--- alpha is how far through the wheel we are, 0 to 1. The pitch drops and the
--- shot gets louder as the wheel slows, and the winning frame is the heaviest,
--- so one short file carries the whole arc from rattle to landing.
local function playCycleTick(alpha: number, final: boolean)
	local cfg = HatchConfig.Roulette
	local sound = Audio.create(cfg.sound)
	if not sound then
		return
	end
	local a = math.clamp(alpha, 0, 1)
	local pitch = if final then cfg.pitchFinal else cfg.pitchFirst + (cfg.pitchLast - cfg.pitchFirst) * a
	-- A little jitter, or thirty shots of one file read as a machine.
	sound.PlaybackSpeed = pitch * (0.97 + math.random() * 0.06)
	local share = if final then 1.25 else cfg.volumeFirst + (cfg.volumeLast - cfg.volumeFirst) * a
	sound.Volume = math.min(sound.Volume * share, 1)
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	-- A shot that never reports Ended (streamed late, cut short) still goes.
	task.delay(3, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

--- The dark focus the roulette plays against: a soft vignette that fades in
--- for the wheel and out on the reveal. One frame, reused, and switched off
--- entirely under Reduced Effects.
local function setFocus(on: boolean, seconds: number)
	local gui = player:FindFirstChild("PlayerGui")
	local main = gui and gui:FindFirstChild("MainUI")
	if not main then
		return
	end
	local screen = main:FindFirstChild("RevealFocus") :: ScreenGui?
	if not screen then
		if not on or reducedEffects then
			return
		end
		screen = Instance.new("ScreenGui")
		screen.Name = "RevealFocus"
		screen.ResetOnSpawn = false
		screen.IgnoreGuiInset = true
		-- Under every panel: this is atmosphere, not a layer the player has to
		-- click through, and it must never sit over the HUD.
		screen.DisplayOrder = -5
		screen.Parent = main

		local shade = Instance.new("Frame")
		shade.Name = "Shade"
		shade.Size = UDim2.fromScale(1, 1)
		shade.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		shade.BackgroundTransparency = 1
		shade.BorderSizePixel = 0
		shade.ZIndex = 0
		shade.Parent = screen
		-- Darkest at the edges and clear through the middle, so the stage
		-- the camera is sitting on stays bright.
		local fade = Instance.new("UIGradient")
		fade.Rotation = 90
		fade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(0.5, 0.8),
			NumberSequenceKeypoint.new(1, 0.25),
		})
		fade.Parent = shade
	end

	local shade = screen:FindFirstChild("Shade") :: Frame?
	if not shade then
		return
	end
	TweenService:Create(shade, TweenInfo.new(seconds, Enum.EasingStyle.Quad), {
		BackgroundTransparency = if on and not reducedEffects then 0.35 else 1,
	}):Play()
end

-- ==========================================================
-- THE REVEAL CAMERA
-- ==========================================================
--
-- The camera leaves the player for the reveal: it flies in to the stage from
-- the side the player was already looking from, creeps closer while the wheel
-- runs, shakes on the pop, admires the item, and flies back.
--
-- ONE OWNER. The player's own camera is saved once, by the first reveal to
-- take it, and handed back only by the reveal that holds it now. A second
-- reveal starting mid-flight takes the camera over WITHOUT re-saving, which is
-- what stops it "restoring" the player to a scripted shot.

type SavedCamera = {
	cameraType: Enum.CameraType,
	cframe: CFrame,
	fov: number,
	--- Where the camera sat relative to the character, so the flight home
	--- lands behind a player who walked away during the reveal.
	offset: Vector3?,
}

local savedCamera: SavedCamera? = nil
local cameraOwner = 0
--- The shot the reveal is flying. Heartbeat copies it to the camera, adding
--- the shake on top, so a tween and a shake never fight over CFrame.
local cameraShot = Instance.new("CFrameValue")
local shakeUntil = 0
local shakeStrength = 0
local cameraTween: Tween? = nil
local cameraLoop: RBXScriptConnection? = nil

local function characterRoot(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function flyCamera(to: CFrame, seconds: number, style: Enum.EasingStyle, direction: Enum.EasingDirection): Tween
	if cameraTween then
		cameraTween:Cancel()
	end
	local tween = TweenService:Create(cameraShot, TweenInfo.new(seconds, style, direction), { Value = to })
	cameraTween = tween
	tween:Play()
	return tween
end

--- Takes the camera for reveal `token`. Returns false when there is no
--- camera to take.
local function takeCamera(token: number): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end
	if not savedCamera then
		local root = characterRoot()
		savedCamera = {
			cameraType = camera.CameraType,
			cframe = camera.CFrame,
			fov = camera.FieldOfView,
			offset = if root then camera.CFrame.Position - root.Position else nil,
		}
		cameraShot.Value = camera.CFrame
	end
	cameraOwner = token
	camera.CameraType = Enum.CameraType.Scriptable
	if not cameraLoop then
		cameraLoop = RunService.RenderStepped:Connect(function()
			local current = workspace.CurrentCamera
			if not current or not savedCamera then
				return
			end
			local shot = cameraShot.Value
			local now = os.clock()
			if now < shakeUntil and not reducedEffects then
				local k = (shakeUntil - now) * shakeStrength
				shot *= CFrame.Angles(
					(math.random() - 0.5) * 0.02 * k,
					(math.random() - 0.5) * 0.02 * k,
					(math.random() - 0.5) * 0.015 * k
				)
			end
			current.CameraType = Enum.CameraType.Scriptable
			current.CFrame = shot
		end)
	end
	return true
end

-- [polish-events-analytics] The first-join flyover (FlyoverController) also
-- scripts the camera. A reveal always wins: listeners here are told,
-- synchronously, BEFORE a reveal takes the camera, so the flyover can hand
-- the player's own camera back first and the reveal saves the right one.
local revealStartingListeners: { () -> () } = {}

function HatchController.onRevealStarting(fn: () -> ())
	table.insert(revealStartingListeners, fn)
end

--- True while a reveal holds (or is handing back) the camera.
function HatchController.cameraBusy(): boolean
	return savedCamera ~= nil
end

--- The shot that frames `stage` from the player's side, `distance` away.
local function stageShot(stage: Vector3, distance: number, height: number): CFrame
	local camera = workspace.CurrentCamera
	local from = if camera then camera.CFrame.Position else stage + Vector3.zAxis
	local flat = Vector3.new(from.X - stage.X, 0, from.Z - stage.Z)
	if flat.Magnitude < 0.1 and camera then
		local look = camera.CFrame.LookVector
		flat = -Vector3.new(look.X, 0, look.Z)
	end
	local dir = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zAxis
	local eye = stage + dir * distance + Vector3.yAxis * height
	return CFrame.lookAt(eye, stage)
end

local function shakeCamera(strength: number, seconds: number)
	shakeStrength = strength / math.max(seconds, 0.01)
	shakeUntil = os.clock() + seconds
end

--- Hands the camera back, if `token` still owns it: flies to where the
--- player's own camera should now be, then gives control back to it.
local function releaseCamera(token: number, seconds: number)
	if token ~= cameraOwner or not savedCamera then
		return
	end
	local saved = savedCamera :: SavedCamera
	local home = saved.cframe
	local root = characterRoot()
	if root and saved.offset then
		home = CFrame.new(root.Position + saved.offset) * saved.cframe.Rotation
	end
	local tween = flyCamera(home, seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	local camera = workspace.CurrentCamera
	if camera then
		TweenService:Create(camera, TweenInfo.new(seconds, Enum.EasingStyle.Quad), { FieldOfView = saved.fov }):Play()
	end
	task.delay(seconds, function()
		-- A newer reveal took the camera during the flight home: it is theirs.
		if token ~= cameraOwner or savedCamera ~= saved then
			return
		end
		if tween.PlaybackState == Enum.PlaybackState.Playing then
			tween:Cancel()
		end
		if cameraLoop then
			cameraLoop:Disconnect()
			cameraLoop = nil
		end
		savedCamera = nil
		local current = workspace.CurrentCamera
		if current then
			current.CFrame = cameraShot.Value
			current.CameraType = if saved.cameraType == Enum.CameraType.Scriptable
				then Enum.CameraType.Custom
				else saved.cameraType
		end
	end)
end

--- THE SEQUENCE.
local function playReveal(slot: BasePart, reveal: any, token: number)
	-- The container should still be on the pedestal: the server swaps it out
	-- swapAt seconds from now, not yet. Streaming can make it a frame late.
	local container = slot:FindFirstChild("Trophy")
	local waitedUntil = os.clock() + 0.5
	while (not container or not container:IsA("Model")) and os.clock() < waitedUntil do
		task.wait()
		container = slot:FindFirstChild("Trophy")
	end
	if not container or not container:IsA("Model") then
		return
	end
	local sealedModel = container :: Model

	local accent = if reveal and reveal.rarityColor then reveal.rarityColor else WHITE
	local mutationColor = if reveal and reveal.mutationColor then reveal.mutationColor else MysteryConfig.MYSTERY_TINT

	-- The card goes first: the countdown is over.
	local card = slot:FindFirstChild("RevealCard")
	if card and card:IsA("BillboardGui") then
		card.Enabled = false
	end

	-- THE CLONE animates; the real container is hidden underneath it until the
	-- server destroys it on the pop frame.
	local clone = sealedModel:Clone()
	clone.Name = "RevealVisual"
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("BillboardGui") then
			d:Destroy()
		end
	end
	clone.Parent = workspace
	local sealedPaused = conceal(sealedModel)

	-- THE ARRIVING ITEM is concealed the instant it replicates, and shown on
	-- the pop frame. This is the atomic swap: the winner dissolves and the item
	-- appears in the same step, whichever of the two events lands first.
	local incoming: Model? = nil
	local incomingPaused: { Instance } = {}
	local arrival = slot.ChildAdded:Connect(function(child)
		if child:IsA("Model") and child.Name == "Trophy" and child ~= sealedModel and not incoming then
			incoming = child
			-- Local-only flag, read by DisplayFxController: the reveal owns
			-- this model's entrance, so its own pop-in must stand down.
			child:SetAttribute("RevealHold", true)
			incomingPaused = conceal(child)
		end
	end)

	local base = clone:GetPivot()
	local _, size = clone:GetBoundingBox()
	local span = math.max(size.X, size.Y, size.Z)
	local pedestalTop = CFrame.new(base.Position.X, base.Position.Y - size.Y / 2, base.Position.Z)
	local cfg = HatchConfig.Reveal
	local rc = HatchConfig.Roulette

	local prizeId = if type(reveal.itemId) == "string" then reveal.itemId else nil
	local zoneIndex = tonumber(reveal.zoneIndex) or 1
	local rarity = if type(reveal.rarity) == "string" then reveal.rarity else "Common"

	-- THE STAGE. One fixed point above the pedestal, high enough that the
	-- largest size class clears it, so the wheel reads as one slot changing
	-- rather than things jumping around the plot.
	local stage = CFrame.new(base.Position.X, pedestalTop.Position.Y + rc.stageSpan * rc.stageLift, base.Position.Z)

	-- The stage light and the neon plate under the items. Both take the
	-- rarity colour of whatever is on the stage, which is what makes a flash
	-- of gold mid-spin feel like a near miss.
	local fx = Instance.new("Folder")
	fx.Name = "RevealRoulette"
	fx.Parent = workspace
	local plate = Instance.new("Part")
	plate.Name = "Plate"
	plate.Shape = Enum.PartType.Cylinder
	plate.Size = Vector3.new(0.25, rc.stageSpan * 1.5, rc.stageSpan * 1.5)
	plate.CFrame = CFrame.new(stage.Position - Vector3.yAxis * rc.stageSpan * 0.95) * CFrame.Angles(0, 0, math.rad(90))
	plate.Material = Enum.Material.Neon
	plate.Color = WHITE
	plate.Transparency = 1
	plate.Anchored = true
	plate.CanCollide = false
	plate.CanQuery = false
	plate.CanTouch = false
	plate.CastShadow = false
	plate.Parent = fx
	local light = Instance.new("PointLight")
	light.Range = rc.stageSpan * 2.4
	light.Brightness = 0
	light.Shadows = false
	light.Parent = plate
	local outline = Instance.new("Highlight")
	outline.FillTransparency = 1
	outline.OutlineTransparency = 0.1
	outline.DepthMode = Enum.HighlightDepthMode.Occluded
	outline.Enabled = false
	outline.Parent = fx

	local function alive(): boolean
		return token == revealToken and clone.Parent ~= nil and slot.Parent ~= nil
	end

	--- The one item on the stage, and the prebuilt run.
	local shown: Model? = nil
	local shownRest = 1
	local punchAt = -1
	local angle = 0
	local spinSpeed = rc.spinFast
	local built: { Model | false } = {}
	local spinLoop: RBXScriptConnection? = nil

	local function show(model: Model?, punch: boolean)
		if shown and shown ~= model then
			shown:Destroy()
		end
		shown = model
		if model then
			shownRest = model:GetScale()
			punchAt = if punch then os.clock() else -1
			model:PivotTo(stage * CFrame.Angles(0, angle, 0))
			model.Parent = fx
			outline.Adornee = model
			outline.Enabled = true
		else
			outline.Adornee = nil
			outline.Enabled = false
		end
	end

	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		arrival:Disconnect()
		if spinLoop then
			spinLoop:Disconnect()
		end
		show(nil, false)
		for _, model in built do
			if model then
				model:Destroy()
			end
		end
		fx:Destroy()
		if clone.Parent then
			clone:Destroy()
		end
		-- The focus and the camera go back however this ended.
		setFocus(false, 0.4)
		releaseCamera(token, rc.cameraOut)
		-- Whatever is on the pedestal now is shown, whether the swap landed
		-- or not: the base rebuild is the authority on what stands there.
		if sealedModel.Parent then
			unconceal(sealedModel, sealedPaused)
		end
		if incoming and incoming.Parent then
			unconceal(incoming, incomingPaused)
			incoming:SetAttribute("RevealHold", nil)
		end
	end

	task.spawn(function()
		-- THE BUILD-UP, on the first frame of the sequence: it is timed to
		-- peak on the pop four seconds from now.
		playPop()

		local delays = HatchConfig.rouletteDelays(rarity)
		local steps = #delays
		local decoys, teaser = decoyOrder(zoneIndex, prizeId or "", math.max(steps - 1, 0))
		if teaser and steps >= 2 then
			decoys[steps - 1] = teaser
			-- The frame before the teaser must not be the teaser too.
			if steps >= 3 and decoys[steps - 2] == teaser then
				decoys[steps - 2] = decoys[1]
			end
		end
		local classes = sizeOrder(steps)
		classes[steps] = rc.finalClass
		-- The teaser is shown big: the near miss has to look like a win.
		if steps >= 2 then
			classes[steps - 1] = rc.finalClass
		end
		local ids: { string? } = table.create(steps)
		for index = 1, steps - 1 do
			ids[index] = decoys[index]
		end
		ids[steps] = prizeId

		-- PREBUILD while the container lifts, a few a frame, so the blur does
		-- not stall on clones. Anything not ready yet is built on the spot.
		task.spawn(function()
			for index = 1, steps do
				if finished then
					return
				end
				if built[index] == nil then
					local id = ids[index]
					built[index] = (if id then buildRouletteItem(id, classes[index]) else nil) or false
				end
				if index % 4 == 0 then
					task.wait()
				end
			end
		end)
		local function modelFor(index: number): Model?
			if built[index] == nil then
				local id = ids[index]
				built[index] = (if id then buildRouletteItem(id, classes[index]) else nil) or false
			end
			local model = built[index]
			built[index] = false
			return if model then model else nil
		end

		-- THE CAMERA flies in while the container lifts.
		local haveCamera = takeCamera(token)
		local closeShot = stageShot(stage.Position, rc.stageSpan * rc.cameraDistance, rc.stageSpan * rc.cameraHeight)
		if haveCamera then
			flyCamera(closeShot, rc.cameraIn, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		end
		setFocus(true, 0.35)

		-- PHASE 1 - LEVITATE. Eased out, mutation and size VFX still running.
		local lift = cfg.lift.studs * math.clamp(size.Y / 5, 0.7, 2.0)
		drive(cfg.lift.duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, function(t)
			if alive() then
				clone:PivotTo(base * CFrame.new(0, lift * t, 0))
			end
		end)
		if not alive() then
			return finish()
		end

		-- PHASE 2 - THE ROULETTE. The container vanishes and the stage lights
		-- up; the run blurs, brakes, fakes a stop on the teaser, and clicks
		-- over onto the prize.
		conceal(clone)
		plate.Transparency = 0.35
		light.Brightness = 2.5

		local spinSeconds = 0
		for index = 1, steps - 1 do
			spinSeconds += delays[index]
		end
		-- The camera creeps in across the whole spin.
		if haveCamera then
			local pushed = closeShot + closeShot.LookVector * (rc.stageSpan * rc.cameraDistance * rc.cameraCreep)
			task.delay(rc.cameraIn, function()
				if token == cameraOwner and alive() then
					flyCamera(pushed, math.max(spinSeconds - rc.cameraIn + 0.2, 0.3), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
				end
			end)
		end

		-- The spin and the punch run on one loop, so a change, the turn and
		-- the scale never disagree about the item's CFrame.
		spinLoop = RunService.RenderStepped:Connect(function(dt)
			angle += dt * spinSpeed
			local model = shown
			if not model or not model.Parent then
				return
			end
			if punchAt >= 0 then
				local k = math.clamp((os.clock() - punchAt) / rc.punchSeconds, 0, 1)
				local grow = 1 + (rc.punch - 1) * (1 - k) * (1 - k)
				model:ScaleTo(shownRest * grow)
				if k >= 1 then
					punchAt = -1
				end
			end
			model:PivotTo(stage * CFrame.Angles(0, angle, 0))
		end)

		for index = 1, steps do
			if not alive() then
				return finish()
			end
			local isFinal = index == steps
			local alpha = (index - 1) / math.max(steps - 1, 1)
			local delay = delays[index]
			spinSpeed = if isFinal then rc.spinSlow else rc.spinFast + (rc.spinSlow - rc.spinFast) * alpha

			-- SWITCH, THEN SOUND, THEN WAIT. The change triggers its own cue,
			-- so the two cannot drift apart however long a frame takes.
			local model = modelFor(index)
			show(model, isFinal or delay >= 0.09)
			local id = ids[index]
			local def = if id then LootConfig.ById[id] else nil
			local tint = if isFinal
				then accent
				else (if def then RarityConfig.Colors[def.rarity] else nil) or WHITE
			plate.Color = tint
			light.Color = tint
			outline.OutlineColor = tint
			playCycleTick(alpha, isFinal)

			if isFinal then
				ring(stage * CFrame.new(0, -rc.stageSpan * 0.95, 0), accent, rc.stageSpan, 0.35, true)
				light.Brightness = 5
				task.wait(rc.holdSeconds)
			else
				-- The slow clicks get a small kick of the camera; the blur
				-- does not, or the whole spin would be a tremor.
				if delay >= 0.25 then
					shakeCamera(rc.shake * 0.3, 0.12)
				end
				task.wait(delay)
			end
		end
		if not alive() then
			return finish()
		end
		local winner = shown

		-- PHASE 3 - THE POP. The server rebuild lands on this frame. Wait for
		-- the item to replicate if it has not yet, then swap atomically: the
		-- winner flares and dissolves while the real item appears underneath
		-- it, in colour, on the same step.
		local arrivalDeadline = os.clock() + 1.2
		while not incoming and os.clock() < arrivalDeadline and alive() do
			task.wait()
		end
		if not alive() then
			return finish()
		end

		ring(pedestalTop, accent, span * 1.3, 0.55)
		ring(stage * CFrame.new(0, -rc.stageSpan * 0.95, 0), accent, rc.stageSpan, 0.6)
		burstFragments(stage, mutationColor, rc.stageSpan)
		shakeCamera(rc.shake, rc.shakeSeconds)
		setFocus(false, 0.45)
		if spinLoop then
			spinLoop:Disconnect()
			spinLoop = nil
		end

		-- The real item, in colour, on the SAME frame the winner begins to
		-- dissolve. This is the swap: at no point is the pedestal empty.
		local item = incoming
		local itemRest = 0
		-- New multipart art must be completely replicated before ScaleTo caches
		-- its reference dimensions. On a slow connection reveal it without a bounce.
		if item and not ItemArtReady.waitFor(item, 1.2) then
			unconceal(item, incomingPaused)
			item:SetAttribute("RevealHold", nil)
			item = nil
		end
		if item and item.Parent then
			-- The AUTHORED rest scale, stamped by LootModel.build, never the
			-- live one: a scale read while another tween is running would be
			-- baked in as the final size.
			itemRest = tonumber(item:GetAttribute("BuiltScale")) or item:GetScale()
			item:ScaleTo(itemRest * cfg.item.from)
			unconceal(item, incomingPaused)
		end

		-- The camera drops from the stage to the pedestal, where the real item
		-- now stands, and holds on it.
		if haveCamera and token == cameraOwner then
			local focus = pedestalTop.Position + Vector3.yAxis * size.Y / 2
			local itemSpan = math.max(span, 3)
			if item and item.Parent then
				local box, itemSize = item:GetBoundingBox()
				-- The item is at 70% right now and settles at 100%.
				local scaleUp = 1 / cfg.item.from
				focus = box.Position
				itemSpan = math.max(itemSize.X * scaleUp, itemSize.Y * scaleUp, itemSize.Z * scaleUp, 3)
			end
			flyCamera(
				stageShot(focus, itemSpan * rc.cameraDistance * 0.9, itemSpan * rc.cameraHeight),
				0.5,
				Enum.EasingStyle.Quart,
				Enum.EasingDirection.Out
			)
		end

		-- The winner flares and fades out, in place, above the real item.
		if winner and winner.Parent then
			local popFrom = winner:GetScale()
			local popTo = popFrom * cfg.pop.scale
			local winnerPivot = winner:GetPivot()
			drive(cfg.pop.duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, function(t)
				if winner and winner.Parent then
					winner:ScaleTo(popFrom + (popTo - popFrom) * t)
					winner:PivotTo(winnerPivot)
					for _, d in winner:GetDescendants() do
						if d:IsA("BasePart") then
							d.LocalTransparencyModifier = t
						end
					end
				end
			end)
		else
			task.wait(cfg.pop.duration)
		end
		show(nil, false)
		plate.Transparency = 1
		light.Brightness = 0
		if clone.Parent then
			clone:Destroy()
		end

		-- NO BANNER. The trophy's own nameplate already carries the name, the
		-- tier and the income, on the pedestal the camera is looking at.

		-- THE BOUNCE: 70% -> 110% -> 100%, scale only, so DisplayFx's own idle
		-- turn keeps ownership of the pivot.
		if item and item.Parent then
			drive(cfg.item.grow, Enum.EasingStyle.Back, Enum.EasingDirection.Out, function(t)
				if item.Parent then
					item:ScaleTo(itemRest * (cfg.item.from + (cfg.item.overshoot - cfg.item.from) * t))
				end
			end)
			drive(cfg.item.settle, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, function(t)
				if item.Parent then
					item:ScaleTo(itemRest * (cfg.item.overshoot + (1 - cfg.item.overshoot) * t))
				end
			end)
			if item.Parent then
				item:ScaleTo(itemRest)
				item:SetAttribute("RevealHold", nil)
			end
		end

		-- Let the player look at what they won before the camera goes home.
		if token == revealToken then
			task.wait(rc.cameraHold)
		end
		finish()
	end)
end

-- ==========================================================
-- START
-- ==========================================================

--- Fetches the roulette cue once, at start-up, so the first silhouette of the
--- first reveal ticks on time instead of playing silence while Roblox streams
--- the file. Spawned and pcall-ed: a preload that fails or hangs must never
--- stop the controller from starting.
local function preloadCycleCue()
	task.spawn(function()
		local sound = Audio.create(HatchConfig.Roulette.sound)
		if not sound then
			return
		end
		sound.Parent = SoundService
		pcall(function()
			game:GetService("ContentProvider"):PreloadAsync({ sound })
		end)
		sound:Destroy()
	end)
end

function HatchController.start()
	preloadCycleCue()

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		if not state then
			return
		end
		local list = state.sealed
		if type(list) ~= "table" then
			return
		end
		local seen: { [string]: boolean } = {}
		for _, row in list do
			if type(row) == "table" and type(row.instanceId) == "string" then
				local existing = sealed[row.instanceId]
				sealed[row.instanceId] = {
					endsAt = row.endsAt or 0,
					-- Server time, to be comparable with endsAt (see repaintCards).
					startedAt = if existing then existing.startedAt else workspace:GetServerTimeNow(),
				}
				seen[row.instanceId] = true
			end
		end
		for id in sealed do
			if not seen[id] then
				sealed[id] = nil
			end
		end
	end)

	-- The reveal cue. Arrives ONLY after the server has committed, and is the
	-- first moment this client is told anything about the reward.
	Remotes.get("HatchReveal").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local slot = payload.slot
		if not slot or not slot:IsA("BasePart") then
			return
		end
		-- One sequence at a time. A second cue for the same container cannot
		-- happen (the server refuses it), and one for another container while
		-- this plays takes over: the abandoned one checks its token and stops.
		-- [polish-events-analytics] the flyover gives the camera back first.
		for _, listener in revealStartingListeners do
			local ok, err = pcall(function()
				listener()
			end)
			if not ok then
				warn(`[HatchController] reveal-start listener failed: {err}`)
			end
		end
		revealToken += 1
		playReveal(slot, payload, revealToken)
	end)

	RunService.Heartbeat:Connect(repaintCards)

	-- REVEAL CARDS ARE PRIVATE. Applied the moment one replicates in, which is
	-- what stops another player's countdown ever being drawn for a frame...
	local function adopt(thing: Instance)
		if thing:IsA("BillboardGui") and thing.Name == "RevealCard" then
			applyCardOwnership(thing)
		end
	end
	-- Through the shared WorldIndex (one workspace scan for all controllers).
	require(script.Parent.Parent.WorldIndex).watch("BillboardGui", adopt)

	-- ...and re-applied on a slow sweep, because a PLOT can change hands under
	-- a card that never moved. Cheap: a handful of billboards, once a second.
	task.spawn(function()
		while true do
			task.wait(1)
			local map = workspace:FindFirstChild("Map")
			local bases = map and map:FindFirstChild("Bases")
			if bases then
				for _, plot in bases:GetChildren() do
					local mine = plot:GetAttribute("OwnerUserId") == player.UserId
					local slots = plot:FindFirstChild("DisplaySlots")
					if slots then
						for _, slot in slots:GetChildren() do
							local card = slot:FindFirstChild("RevealCard")
							if card and card:IsA("BillboardGui") and card.Enabled ~= mine then
								card.Enabled = mine
							end
						end
					end
				end
			end
		end
	end)
end

return HatchController
