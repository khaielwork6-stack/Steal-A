--!strict
--[[
	HatchController  (the REVEAL controller; the module keeps its old name)
	The timer card over a sealed container, the prompt flip when it is ready,
	and the one short scripted reveal.

	NOTHING HERE DECIDES ANYTHING. The server commits the reveal - flips the
	flag, starts the income - before it tells this client to animate, and it
	swaps the container for the item on the pedestal SWAP_AT seconds later.
	This controller draws the wait, then plays the two seconds in between, then
	shows whatever the server put there. If it never finishes, the item is
	already the player's.

	THE ANIMATION RUNS ON A CLONE. The authoritative container is hidden
	locally the moment the sequence starts and is destroyed by the server's
	rebuild on the pop frame; the clone is what levitates, turns and pops. The
	arriving item is concealed the instant it replicates and shown on the pop
	frame together with the clone's dissolve, so there is never a moment with
	nothing on the pedestal.

	ONE SOUND. HatchConfig.POP_SOUND plays once, here, on the first frame of
	the sequence, and nothing else in the reveal makes a noise - the server
	sends no cue for it.

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
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
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
--- focus vignette and the camera pull; the roulette itself still plays,
--- because it IS the feature rather than a flourish on top of one.
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
	local second = math.floor(os.clock())
	if second == lastCardTick then
		return
	end
	lastCardTick = second
	local now = os.time()

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

--- THE SEQUENCE.
-- ==========================================================
-- THE SILHOUETTE ROULETTE
-- ==========================================================
--
-- A run of solid black item shapes that cycles fast and slows onto the prize.
--
-- IT DECIDES NOTHING. The server rolled the reward, committed it, started the
-- income and only then sent the cue this reads. The last silhouette is the
-- payload's itemId; the decoys come from the zone's public loot table, which
-- every client already has. There is no path from anything in this section to
-- what a player receives, so a tampered animation is only ever a tampered
-- animation.

local SILHOUETTE_BLACK = Color3.fromRGB(6, 6, 9)

--- Strips a model to an unlit black shape: no texture, no surface material,
--- no light of its own, nothing that could hint at the colour underneath.
local function blacken(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Color = SILHOUETTE_BLACK
			d.Material = Enum.Material.SmoothPlastic
			d.Reflectance = 0
			d.CastShadow = false
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			-- Anything the artist meant to be seen becomes solid. Glass and
			-- half-transparent parts would otherwise read as holes punched
			-- through the silhouette and give the shape away.
			if d.Transparency < 1 then
				d.Transparency = 0
			end
			if d:IsA("MeshPart") then
				d.TextureID = ""
			end
		elseif d:IsA("SpecialMesh") then
			d.TextureId = ""
		elseif d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture") then
			d:Destroy()
		elseif
			d:IsA("ParticleEmitter")
			or d:IsA("Trail")
			or d:IsA("Beam")
			or d:IsA("Fire")
			or d:IsA("Smoke")
			or d:IsA("Sparkles")
			or d:IsA("Light")
			or d:IsA("Highlight")
		then
			d:Destroy()
		end
	end
end

--- A framed black silhouette of an item, or nil when it has no published art.
--- Built from the ReplicatedStorage previews, so this works on the client.
---
--- sizeClass multiplies the stage span, and is the whole reason the wheel
--- shows tiny through huge rather than one blob flickering in place: every
--- shape is FITTED to the stage, so a Colossal prize and a coin are both
--- readable, and is then deliberately pushed off that size by its class.
local function buildSilhouette(itemId: string, sizeClass: number): Model?
	local source = LootModel.previewSource(itemId)
	if not source then
		return nil
	end
	local model = source:Clone()
	blacken(model)
	local _, size = model:GetBoundingBox()
	local largest = math.max(size.X, size.Y, size.Z)
	if largest > 0.01 then
		local target = HatchConfig.Silhouette.stageSpan * sizeClass
		model:ScaleTo(model:GetScale() * (target / largest))
	end
	return model
end

--- The decoys, in the order they will be shown: this zone's own pool,
--- shuffled, never the prize, and never the same shape twice running - not
--- even across the seam where the bag is refilled. A zone holds eight items
--- and the wheel runs up to twelve, so the bag is drawn from more than once,
--- and a fresh shuffle each time is what stops the run being recognisable.
local function decoyOrder(zoneIndex: number, prizeId: string, count: number): { string }
	local pool: { string } = {}
	for _, def in LootConfig.pool(zoneIndex) do
		if def.id ~= prizeId and LootModel.previewSource(def.id) then
			table.insert(pool, def.id)
		end
	end
	if #pool == 0 then
		return {}
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
	return out
end

--- One shot of the cycle cue. Called BY a silhouette change and never by a
--- clock of its own, which is the whole reason the sound cannot drift from
--- the picture: switch, play, wait, switch.
---
--- alpha is how far through the wheel we are, 0 to 1. The pitch hardens as
--- the wheel slows and drops furthest on the winning frame, so one audio file
--- carries the whole arc from bright flicker to heavy landing.
local function playCycleTick(alpha: number, final: boolean)
	local cfg = HatchConfig.Silhouette
	local sound = Audio.create(cfg.sound)
	if not sound then
		return
	end
	local pitch = if final
		then cfg.pitchFinal
		else cfg.pitchFirst + (cfg.pitchLast - cfg.pitchFirst) * math.clamp(alpha, 0, 1)
	-- A little jitter, or a dozen shots of one file read as a machine.
	sound.PlaybackSpeed = pitch * (0.98 + math.random() * 0.04)
	if final then
		sound.Volume = math.min(sound.Volume * 1.2, 1)
	end
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	-- A shot that never reports Ended (streamed late, cut short) still goes.
	task.delay(4, function()
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
		-- Darkest at the edges and clear through the middle, so the pedestal
		-- the player is actually looking at stays bright.
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

local function playReveal(slot: BasePart, reveal: any, token: number)
	-- The container should still be on the pedestal: the server swaps it out
	-- SWAP_AT seconds from now, not yet. Streaming can make it a frame late.
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
	-- the pop frame. This is the atomic swap: the clone dissolves and the item
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
	local restScale = clone:GetScale()
	local cfg = HatchConfig.Reveal

	local emitters: { ParticleEmitter } = {}
	for _, d in clone:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			table.insert(emitters, d)
		end
	end
	local glow = Instance.new("PointLight")
	glow.Brightness = 0
	glow.Range = span * 1.6
	glow.Color = mutationColor
	glow.Parent = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)

	-- THE CAMERA. A gentle pull in for the wheel and a small push on the pop,
	-- always restored by finish() - including when the sequence is abandoned
	-- half-way, which is why the rest value is taken here and not read back
	-- off a camera that may already have been moved.
	local camera = workspace.CurrentCamera
	local startFov = if camera then camera.FieldOfView else 70

	local function alive(): boolean
		return token == revealToken and clone.Parent ~= nil and slot.Parent ~= nil
	end

	local function finish()
		arrival:Disconnect()
		if clone.Parent then
			clone:Destroy()
		end
		-- The focus and the lens go back however this ended.
		setFocus(false, 0.4)
		if camera then
			TweenService:Create(camera, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				FieldOfView = startFov,
			}):Play()
		end
		-- Whatever is on the pedestal now is shown, whether the swap landed
		-- or not: the base rebuild is the authority on what stands there.
		if sealedModel.Parent then
			unconceal(sealedModel, sealedPaused)
		end
		if incoming and incoming.Parent then
			unconceal(incoming, incomingPaused)
		end
	end

	task.spawn(function()
		-- THE ONE SOUND, on the first frame of the sequence: it scores the
		-- whole reveal rather than stamping the pop two seconds in.
		playPop()

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

		-- PHASE 2 - THE ROULETTE. The container steps aside and a run of black
		-- silhouettes cycles in its place: fast at first, slowing like a wheel
		-- losing momentum, one long fake-out beat, and then the prize.
		--
		-- The last frame is reveal.itemId, which the server sent AFTER it had
		-- already committed the reward. Nothing here picks it.
		local raised = base * CFrame.new(0, lift, 0)
		local sil = HatchConfig.Silhouette
		local prizeId = if type(reveal.itemId) == "string" then reveal.itemId else nil
		local zoneIndex = tonumber(reveal.zoneIndex) or 1
		local rarity = if type(reveal.rarity) == "string" then reveal.rarity else "Common"

		-- THE STAGE. One fixed point above the pedestal, high enough that the
		-- largest size class clears it, so the wheel reads as a single object
		-- changing rather than shapes jumping around the plot.
		local stage = CFrame.new(
			base.Position.X,
			pedestalTop.Position.Y + sil.stageSpan * sil.stageLift,
			base.Position.Z
		)

		-- The container goes dark for the wheel and never returns: what bursts
		-- at the end is the winning silhouette.
		local containerHidden = conceal(clone)
		setFocus(true, 0.35)
		if not reducedEffects then
			TweenService:Create(camera, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				FieldOfView = startFov - 5,
			}):Play()
		end

		local steps = HatchConfig.silhouetteSteps(rarity)
		local delays = HatchConfig.cycleDelays(steps)
		local decoys = decoyOrder(zoneIndex, prizeId or "", math.max(steps - 1, 0))

		--- The one silhouette on the stage. Swapping through here is what
		--- guarantees only ever one exists, however the sequence ends.
		local shown: Model? = nil
		local function show(model: Model?)
			if shown then
				shown:Destroy()
			end
			shown = model
			if model then
				model:PivotTo(stage)
				model.Parent = workspace
			end
		end

		for index = 1, steps do
			if not alive() then
				show(nil)
				return finish()
			end
			local isFinal = index == steps
			local alpha = (index - 1) / math.max(steps - 1, 1)
			local id = if isFinal then prizeId else decoys[index]
			local class = if isFinal
				then sil.finalClass
				else sil.sizeClasses[math.random(#sil.sizeClasses)]

			-- SWITCH, THEN SOUND, THEN WAIT. The change triggers its own cue,
			-- so the two cannot drift apart however long a frame takes.
			show(if id then buildSilhouette(id, class) else nil)
			playCycleTick(alpha, isFinal)

			if isFinal then
				-- The winner holds, turning slowly, while the player reads the
				-- shape and works out what they are about to get.
				local held = shown
				drive(sil.holdSeconds, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, function(t)
					if held and held.Parent then
						held:PivotTo(stage * CFrame.Angles(0, t * math.pi * 0.7, 0))
					end
				end)
			else
				task.wait(delays[index])
			end
		end
		if not alive() then
			show(nil)
			return finish()
		end
		local winner = shown
		local _ = containerHidden

		-- PHASE 4 - THE POP. The server rebuild lands on this frame. Wait for
		-- the item to replicate if it has not yet, then swap atomically: the
		-- winning silhouette flares and dissolves while the real item appears
		-- underneath it, in colour, on the same step.
		local arrivalDeadline = os.clock() + 1.2
		while not incoming and os.clock() < arrivalDeadline and alive() do
			task.wait()
		end
		if not alive() then
			show(nil)
			return finish()
		end

		ring(pedestalTop, accent, span * 1.3, 0.55)
		burstFragments(stage, mutationColor, sil.stageSpan)
		glow.Brightness = 0
		-- The lens pushes back out as the prize lands, and the focus lifts.
		setFocus(false, 0.45)
		if camera and not reducedEffects then
			TweenService:Create(camera, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				FieldOfView = startFov + 3,
			}):Play()
		end

		-- The real item, in colour, on the SAME frame the silhouette begins to
		-- dissolve. This is the swap: at no point is the pedestal empty.
		local item = incoming
		local itemRest = 0
		if item and item.Parent then
			-- The AUTHORED rest scale, stamped by LootModel.build, never the
			-- live one: a scale read while another tween is running would be
			-- baked in as the final size.
			itemRest = tonumber(item:GetAttribute("BuiltScale")) or item:GetScale()
			item:ScaleTo(itemRest * cfg.item.from)
			unconceal(item, incomingPaused)
		end

		-- The winning silhouette flares and fades out. It, not the container,
		-- is what the player has been watching, so it is what has to burst.
		if winner and winner.Parent then
			local popFrom = winner:GetScale()
			local popTo = popFrom * cfg.pop.scale
			drive(cfg.pop.duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, function(t)
				if winner and winner.Parent then
					winner:ScaleTo(popFrom + (popTo - popFrom) * t)
					for _, d in winner:GetDescendants() do
						if d:IsA("BasePart") then
							d.Transparency = t
						end
					end
				end
			end)
		else
			task.wait(cfg.pop.duration)
		end
		show(nil)
		if clone.Parent then
			clone:Destroy()
		end

		-- NO BANNER. The name and the tier used to be thrown across the top of
		-- the screen here; the trophy's own nameplate already carries both, plus
		-- the income, and it does it on the pedestal the player is looking at.
		-- Two labels for one moment is one too many.

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
		local sound = Audio.create(HatchConfig.Silhouette.sound)
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

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
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
					startedAt = if existing then existing.startedAt else os.time(),
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
	for _, thing in workspace:GetDescendants() do
		adopt(thing)
	end
	workspace.DescendantAdded:Connect(adopt)

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
