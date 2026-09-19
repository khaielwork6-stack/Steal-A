--!strict
--[[
	TutorialController
	The first-minute onboarding, drawn from `state.tutorial` and nothing else:

	  1. ONE OBJECTIVE LINE at the top of the screen saying what to do now.
	  2. A TRAIL OF CHEVRONS on the ground from the player's feet to the
	     objective, flowing toward it.
	  3. A RING WITH A VERB in the world at the exact spot to interact with,
	     for the two steps that need a button press rather than a walk.

	WHY THERE ARE NO STAGE BANNERS - AND WHY THERE IS ONE LINE
	Every stage used to announce itself as a toast, and with the reveal
	system's own feedback they stacked into a wall of text over the player.
	That decision is reversed for exactly ONE fixed, non-stacking line: it is
	replaced in place, never queued, and nothing here goes through
	ToastController. The one opening popup stays gone; the server still sends
	`showIntro` and it is ignored.

	NOT A RUN BANNER. ChaseWarningController owns the chase warning, gated on
	the server's `Chased` attribute plus a live carry. The tutorial's part of
	that beat is the objective line changing and the trail turning red.

	PRESENTATION ONLY. TutorialService decides every step and pushes it
	through StateService; nothing here can advance the tutorial.

	ONE LOOP, ONE POOL. A single Heartbeat, a single StateStore.subscribe, a
	single CharacterAdded. Every part is made ONCE, into one folder, and
	shown or hidden by moving it and setting Transparency: 8 chevrons x 4
	wedges + 1 ring anchor = 33 parts, forever. Nothing in the loop calls
	Instance.new. Nothing here is a GuiButton and nothing eats input.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local PolishConfig = require(ReplicatedStorage.Shared.Config.PolishConfig)

local TutorialController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- NUMBERS
-- ==========================================================

--- Trail colours: gold is the tutorial's existing accent, and the museum's
--- lasers already own "red means danger", so the trail is gold until a
--- guardian is actually on the player - the reference keeps its chevrons red
--- always; if the owner wants that, it is this one constant.
local FILL_CALM = Color3.fromRGB(255, 204, 56)
local FILL_CHASED = Color3.fromRGB(238, 52, 44)
local OUTLINE = Color3.fromRGB(46, 8, 6)
--- Seconds the fill takes to cross between the two.
local CHASE_BLEND_SECONDS = 0.25

--- Chevron geometry, in studs.
local CHEVRON_WIDTH = 4.5
local CHEVRON_LENGTH = 5
local CHEVRON_THICK = 0.3
--- The outline pair is the fill pair scaled up and dropped a hair, so it
--- reads as a thick stroke from any angle.
local OUTLINE_SCALE = 1.18
local OUTLINE_DROP = 0.02
--- How far above the surface a chevron floats.
local HOVER = 0.35

--- Pool size, and the smaller pool Low Graphics runs on.
local MAX_CHEVRONS = 8
local LOW_CHEVRONS = 5
--- Studs from the player's feet to the first chevron, and between chevrons.
local ORIGIN_PUSH = 5
local SPACING = 6
--- Nearer than this the trail is hidden and the ring stands alone: a trail
--- pointing at something you are standing on reads as a bug.
local NEAR_HIDE = 8
--- Farther than this the trail is a fixed runway in the target's direction
--- rather than a line that tries to span the museum.
local RUNWAY_BEYOND = 90
--- Studs per second the chain scrolls toward the target.
local SCROLL_SPEED = 9
--- Studs over which a chevron fades in at the far end and out at the near.
local FADE_STUDS = 0.8
--- The downward ray each chevron sits on: from this high, this far.
local RAY_UP = 20
local RAY_LENGTH = 60

--- The ring, in studs of billboard.
local RING_STUDS = 6
local RING_HEIGHT_STUDS = 8.5
local RING_COLOR = Color3.fromRGB(240, 70, 60)
local RING_PERIOD = 1.4
local RING_SCALE_MAX = 1.08
local RING_STROKE_MIN = 0.1
local RING_STROKE_MAX = 0.35
local RING_MAX_DISTANCE = 220

--- The objective line.
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local TEXT_STROKE = Color3.fromRGB(16, 12, 10)
local TEXT_STROKE_THICKNESS = 3.5
local LINE_TOP_DESKTOP = 84
local LINE_TOP_TOUCH = 58
local LINE_HEIGHT_DESKTOP = 44
local LINE_HEIGHT_PHONE = 34
local LINE_MAX_TEXT_DESKTOP = 34
local LINE_MAX_TEXT_PHONE = 26
local OUT_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local IN_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0)
local FADE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OUT_RISE = 12
local IN_DROP = 14

--- Just under the pack's MainUI (DisplayOrder 0), so a toast is never hidden
--- by the line.
local LINE_DISPLAY_ORDER = -1

local NO_ART = "rbxassetid://0"

-- ==========================================================
-- STATE
-- ==========================================================

type Chevron = {
	fillA: WedgePart,
	fillB: WedgePart,
	outlineA: WedgePart,
	outlineB: WedgePart,
}

local started = false
local reduced = false
local lowGraphics = false

local currentTitle: string? = nil
local currentTarget: Vector3? = nil
local currentPointer: string? = nil

local fxFolder: Folder? = nil
local chevrons: { Chevron } = {}
local ringAnchor: Part? = nil
local ringScale: UIScale? = nil
local ringStroke: UIStroke? = nil
local ringVerb: TextLabel? = nil
local ringGui: BillboardGui? = nil

--- 0 = calm gold, 1 = chase red; slid toward the Chased flag every frame.
local chaseBlend = 0
--- Reused every frame; its filter list is rewritten, never a new params.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
-- Only what a player can stand on: the museum's ramps, the lobby steps, the
-- plot slab. Walk-through dressing - treadmill art, a pedestal's glow disc -
-- is skipped, or a chevron would perch on a rail twelve studs up.
rayParams.RespectCanCollide = true
local rayFilter: { Instance } = {}

local lineLabels: { TextLabel } = {}
local lineStrokes: { UIStroke } = {}
local lineFront = 1
local lineTweens: { Tween } = {}
local lineTop = LINE_TOP_DESKTOP

-- ==========================================================
-- THE OBJECTIVE LINE
-- ==========================================================

local function lineTopFor(): number
	local inset = GuiService:GetGuiInset().Y
	return inset + (if Device.isTouch() then LINE_TOP_TOUCH else LINE_TOP_DESKTOP)
end

local function placeLine()
	lineTop = lineTopFor()
	local height = if Device.isPhone() then LINE_HEIGHT_PHONE else LINE_HEIGHT_DESKTOP
	for _, label in lineLabels do
		label.Size = UDim2.new(0.9, 0, 0, height)
		local limit = label:FindFirstChildOfClass("UITextSizeConstraint")
		if limit then
			limit.MaxTextSize = if Device.isPhone() then LINE_MAX_TEXT_PHONE else LINE_MAX_TEXT_DESKTOP
		end
	end
	-- The resting label sits on the line; the other is parked wherever its
	-- last tween left it and is repositioned when it next comes in.
	local front = lineLabels[lineFront]
	if front then
		front.Position = UDim2.new(0.5, 0, 0, lineTop)
	end
end

local function buildLine()
	local gui = Instance.new("ScreenGui")
	gui.Name = "TutorialObjective"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = LINE_DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	for index = 1, 2 do
		local label = Instance.new("TextLabel")
		label.Name = "Line" .. index
		label.Active = false
		label.Interactable = false
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(0.5, 0, 0, LINE_TOP_DESKTOP)
		label.Size = UDim2.new(0.9, 0, 0, LINE_HEIGHT_DESKTOP)
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextColor3 = TEXT_COLOR
		label.TextTransparency = 1
		label.Text = ""
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = LINE_MAX_TEXT_DESKTOP
		limit.Parent = label
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = TEXT_STROKE_THICKNESS
		stroke.Color = TEXT_STROKE
		stroke.LineJoinMode = Enum.LineJoinMode.Miter
		stroke.Transparency = 1
		stroke.Parent = label
		label.Parent = gui
		lineLabels[index] = label
		lineStrokes[index] = stroke
	end

	gui.Parent = player:WaitForChild("PlayerGui")
	placeLine()
end

local function cancelLineTweens()
	for _, tween in lineTweens do
		tween:Cancel()
	end
	table.clear(lineTweens)
end

local function play(target: Instance, info: TweenInfo, goal: { [string]: any })
	local tween = TweenService:Create(target, info, goal)
	table.insert(lineTweens, tween)
	tween:Play()
end

--- Replaces the line in place. A second change mid-transition cancels the
--- first and replaces it; nothing ever queues, and there is never an empty
--- frame - the outgoing text is still fading while the incoming slides in.
local function showTitle(title: string?)
	if title == currentTitle then
		return
	end
	currentTitle = title
	local outgoing, outStroke = lineLabels[lineFront], lineStrokes[lineFront]
	if not outgoing or not outStroke then
		return
	end
	cancelLineTweens()

	if title == nil then
		play(outgoing, FADE_TWEEN, { TextTransparency = 1 })
		play(outStroke, FADE_TWEEN, { Transparency = 1 })
		return
	end

	local nextIndex = if lineFront == 1 then 2 else 1
	local incoming, inStroke = lineLabels[nextIndex], lineStrokes[nextIndex]
	incoming.Text = title
	incoming.TextTransparency = 1
	inStroke.Transparency = 1

	if reduced then
		-- Straight cross-fade, no slide.
		incoming.Position = UDim2.new(0.5, 0, 0, lineTop)
		play(outgoing, FADE_TWEEN, { TextTransparency = 1 })
		play(outStroke, FADE_TWEEN, { Transparency = 1 })
		play(incoming, FADE_TWEEN, { TextTransparency = 0 })
		play(inStroke, FADE_TWEEN, { Transparency = 0 })
	else
		play(outgoing, OUT_TWEEN, { Position = UDim2.new(0.5, 0, 0, lineTop - OUT_RISE), TextTransparency = 1 })
		play(outStroke, OUT_TWEEN, { Transparency = 1 })
		incoming.Position = UDim2.new(0.5, 0, 0, lineTop + IN_DROP)
		play(incoming, IN_TWEEN, { Position = UDim2.new(0.5, 0, 0, lineTop), TextTransparency = 0 })
		play(inStroke, IN_TWEEN, { Transparency = 0 })
	end
	lineFront = nextIndex
end

-- ==========================================================
-- THE POOL
-- ==========================================================

local function prepare(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Locked = true
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 1
end

--- One wedge of a chevron. A WedgePart's triangle lies in its own YZ plane;
--- turned a quarter about Z it lies flat, height along world X and length
--- along world Z, thickness being the wedge's width. Two mirrored halves,
--- right angles at the outer back corners, make an isoceles triangle whose
--- apex points along local +Z.
local function wedge(name: string, halfWidth: number, length: number, color: Color3, parent: Instance): WedgePart
	local part = Instance.new("WedgePart")
	part.Name = name
	part.Size = Vector3.new(CHEVRON_THICK, halfWidth, length)
	part.Color = color
	prepare(part)
	part.Parent = parent
	return part
end

local function buildPool()
	if fxFolder then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "TutorialFx"
	folder.Parent = workspace
	fxFolder = folder

	local half = CHEVRON_WIDTH / 2
	for index = 1, MAX_CHEVRONS do
		chevrons[index] = {
			fillA = wedge(`Chevron{index}FillA`, half, CHEVRON_LENGTH, FILL_CALM, folder),
			fillB = wedge(`Chevron{index}FillB`, half, CHEVRON_LENGTH, FILL_CALM, folder),
			outlineA = wedge(`Chevron{index}OutlineA`, half * OUTLINE_SCALE, CHEVRON_LENGTH * OUTLINE_SCALE, OUTLINE, folder),
			outlineB = wedge(`Chevron{index}OutlineB`, half * OUTLINE_SCALE, CHEVRON_LENGTH * OUTLINE_SCALE, OUTLINE, folder),
		}
	end

	-- The ring anchor: one invisible part the billboard hangs from.
	local anchor = Instance.new("Part")
	anchor.Name = "TutorialRingAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	prepare(anchor)
	anchor.Parent = folder
	ringAnchor = anchor

	local gui = Instance.new("BillboardGui")
	gui.Name = "TargetRing"
	gui.AlwaysOnTop = false
	gui.MaxDistance = RING_MAX_DISTANCE
	gui.Size = UDim2.fromScale(RING_STUDS, RING_HEIGHT_STUDS)
	gui.StudsOffset = Vector3.new(0, RING_HEIGHT_STUDS / 2 - 1, 0)
	gui.Active = false
	gui.Enabled = false
	gui.Adornee = anchor
	gui.Parent = anchor
	ringGui = gui

	-- A true circle outline with no image: a square frame, fully rounded,
	-- with only its stroke drawn.
	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.Active = false
	ring.Interactable = false
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.4)
	ring.Size = UDim2.fromScale(0.7, 0.7)
	local square = Instance.new("UIAspectRatioConstraint")
	square.AspectRatio = 1
	square.Parent = ring
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ring
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = RING_COLOR
	stroke.Transparency = RING_STROKE_MIN
	stroke.Parent = ring
	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = ring
	ring.Parent = gui
	ringScale = scale
	ringStroke = stroke

	-- The pointing hand the reference draws inside the ring: only once the
	-- owner's art exists (PolishConfig.TUTORIAL_POINTER_ICON); the ring and
	-- the verb read fine on their own.
	if PolishConfig.TUTORIAL_POINTER_ICON ~= NO_ART then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.Active = false
		icon.Interactable = false
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.62, 0.62)
		icon.Image = PolishConfig.TUTORIAL_POINTER_ICON
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Parent = ring
	end

	-- The verb, one size under the objective line, same treatment.
	local verb = Instance.new("TextLabel")
	verb.Name = "Verb"
	verb.Active = false
	verb.Interactable = false
	verb.BackgroundTransparency = 1
	verb.BorderSizePixel = 0
	verb.AnchorPoint = Vector2.new(0.5, 1)
	verb.Position = UDim2.fromScale(0.5, 1)
	verb.Size = UDim2.fromScale(1, 0.2)
	verb.Font = Enum.Font.FredokaOne
	verb.TextScaled = true
	verb.TextColor3 = TEXT_COLOR
	verb.Text = ""
	local verbStroke = Instance.new("UIStroke")
	verbStroke.Thickness = 3
	verbStroke.Color = TEXT_STROKE
	verbStroke.LineJoinMode = Enum.LineJoinMode.Miter
	verbStroke.Parent = verb
	verb.Parent = gui
	ringVerb = verb
end

-- ==========================================================
-- THE TRAIL
-- ==========================================================

local function hideChevron(chevron: Chevron)
	chevron.fillA.Transparency = 1
	chevron.fillB.Transparency = 1
	chevron.outlineA.Transparency = 1
	chevron.outlineB.Transparency = 1
end

local function hideTrail()
	for _, chevron in chevrons do
		hideChevron(chevron)
	end
end

local function hideRing()
	if ringGui and ringGui.Enabled then
		ringGui.Enabled = false
	end
end

--- Lays one chevron flat on the ground at `hit`, apex toward `direction`,
--- at opacity `alpha` (0 = hidden).
local function placeChevron(chevron: Chevron, hit: Vector3, direction: Vector3, alpha: number, fill: Color3)
	-- lookAt puts the look direction on -Z, and a WedgePart's apex (its thin
	-- edge) is on its own -Z too, so the look frame IS the chevron frame:
	-- apex toward the target. Checked on the rendered trail, not assumed.
	local base = CFrame.lookAt(hit + Vector3.new(0, HOVER, 0), hit + Vector3.new(0, HOVER, 0) + direction)
	local half = CHEVRON_WIDTH / 2
	local outHalf = half * OUTLINE_SCALE
	local transparency = 1 - alpha
	chevron.fillA.CFrame = base * CFrame.new(-half / 2, 0, 0) * CFrame.Angles(0, 0, math.pi / 2)
	chevron.fillB.CFrame = base * CFrame.new(half / 2, 0, 0) * CFrame.Angles(0, 0, -math.pi / 2)
	chevron.outlineA.CFrame = base * CFrame.new(-outHalf / 2, -OUTLINE_DROP, 0) * CFrame.Angles(0, 0, math.pi / 2)
	chevron.outlineB.CFrame = base * CFrame.new(outHalf / 2, -OUTLINE_DROP, 0) * CFrame.Angles(0, 0, -math.pi / 2)
	chevron.fillA.Color = fill
	chevron.fillB.Color = fill
	chevron.fillA.Transparency = transparency
	chevron.fillB.Transparency = transparency
	chevron.outlineA.Transparency = transparency
	chevron.outlineB.Transparency = transparency
end

--- Rewrites the raycast ignore list: the pool's own folder and every
--- character in the server. A table rewrite, never a new params object.
local function refreshRayFilter()
	table.clear(rayFilter)
	if fxFolder then
		table.insert(rayFilter, fxFolder)
	end
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character then
			table.insert(rayFilter, character)
		end
	end
	rayParams.FilterDescendantsInstances = rayFilter
end

local function updateTrail(root: BasePart, target: Vector3, dt: number)
	local flat = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
	local distance = flat.Magnitude
	if distance < NEAR_HIDE or distance < 0.01 then
		hideTrail()
		return
	end
	local direction = flat.Unit
	local origin = Vector3.new(root.Position.X, root.Position.Y, root.Position.Z) + direction * ORIGIN_PUSH

	-- The fill colour slides between calm and chased, never snaps.
	local wantRed = player:GetAttribute("Chased") == true
	local step = dt / CHASE_BLEND_SECONDS
	chaseBlend = if wantRed then math.min(1, chaseBlend + step) else math.max(0, chaseBlend - step)
	local fill = FILL_CALM:Lerp(FILL_CHASED, chaseBlend)

	-- How many chevrons, and over what length. A far target gets a fixed
	-- runway; a near one only the chevrons that fit before it.
	local poolCount = if lowGraphics then LOW_CHEVRONS else MAX_CHEVRONS
	local span: number
	local count: number
	if distance > RUNWAY_BEYOND then
		count = poolCount
		span = SPACING * count
	else
		local usable = distance - ORIGIN_PUSH
		count = math.clamp(math.floor(usable / SPACING), 1, poolCount)
		span = SPACING * count
	end

	-- The whole chain scrolls toward the target; a chevron that wraps past
	-- the far end fades in over its first stretch and the one at the near
	-- end fades out over its last, so nothing pops.
	local phase = if reduced then 0 else (os.clock() * SCROLL_SPEED) % span
	refreshRayFilter()

	for index, chevron in chevrons do
		if index > count then
			hideChevron(chevron)
			continue
		end
		local along = ((index - 1) * SPACING + phase) % span
		local alpha = 1
		if not reduced then
			if along < FADE_STUDS then
				alpha = along / FADE_STUDS
			elseif span - along < FADE_STUDS then
				alpha = (span - along) / FADE_STUDS
			end
		end
		local at = origin + direction * along
		local hit = workspace:Raycast(at + Vector3.new(0, RAY_UP, 0), Vector3.new(0, -RAY_LENGTH, 0), rayParams)
		if hit then
			placeChevron(chevron, hit.Position, direction, alpha, fill)
		else
			-- A miss is hidden, never dropped at Y = 0.
			hideChevron(chevron)
		end
	end
end

-- ==========================================================
-- THE RING
-- ==========================================================

local function updateRing(target: Vector3, pointer: string)
	local anchor, gui, scale, stroke, verb = ringAnchor, ringGui, ringScale, ringStroke, ringVerb
	if not anchor or not gui or not scale or not stroke or not verb then
		return
	end
	anchor.CFrame = CFrame.new(target)
	if verb.Text ~= pointer then
		verb.Text = pointer
	end
	if not gui.Enabled then
		gui.Enabled = true
	end
	if reduced then
		scale.Scale = 1
		stroke.Transparency = RING_STROKE_MIN
	else
		-- 1.0 -> 1.08 -> 1.0 on a sine, the stroke breathing in step.
		local wave = (math.sin(os.clock() / RING_PERIOD * math.pi * 2) + 1) / 2
		scale.Scale = 1 + (RING_SCALE_MAX - 1) * wave
		stroke.Transparency = RING_STROKE_MIN + (RING_STROKE_MAX - RING_STROKE_MIN) * wave
	end
end

-- ==========================================================
-- THE LOOP
-- ==========================================================

--- True while the trail and ring must not exist: no objective, the flyover,
--- no living character, or the reveal camera. HatchController announces the
--- last the same way it does to FlyoverController.
local function hidden(): (boolean, BasePart?)
	if not currentTarget or player:GetAttribute("FlyoverActive") == true then
		return true, nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return true, nil
	end
	if require(script.Parent.HatchController).cameraBusy() then
		return true, nil
	end
	return false, root
end

local function tick(dt: number)
	local off, root = hidden()
	local target = currentTarget
	if off or not root or not target then
		hideTrail()
		hideRing()
		return
	end
	updateTrail(root, target, dt)
	local pointer = currentPointer
	if pointer then
		updateRing(target, pointer)
	else
		hideRing()
	end
end

function TutorialController.start()
	-- Guarded: a second start must not double the loop or the pool.
	if started then
		return
	end
	started = true

	buildLine()
	buildPool()

	Effects.watchReduced(function(value)
		reduced = value
	end)
	Effects.watchGraphics(function(value)
		lowGraphics = value
	end)

	-- The line rides the notch and the inset: recompute on a rotation or a
	-- safe-area change, so a phone turning never leaves it under the notch.
	-- (GuiService.SafeZoneOffsetsChanged itself is RobloxScript-only and
	-- throws for a LocalScript; the property's changed signal is not.)
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(placeLine)
	end
	pcall(function()
		GuiService:GetPropertyChangedSignal("SafeZoneOffsets"):Connect(placeLine)
	end)

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		local tutorial = state and state.tutorial
		if not tutorial then
			currentTarget, currentPointer = nil, nil
			showTitle(nil)
			return
		end
		currentTarget = tutorial.target
		currentPointer = tutorial.pointer
		showTitle(if type(tutorial.title) == "string" then tutorial.title else nil)
	end)

	-- A respawn needs nothing rebuilt: the pool is not the character's, and
	-- the loop re-reads the new root on its next frame. Hide at once so the
	-- old trail is not left standing over the death spot for a frame.
	player.CharacterAdded:Connect(function()
		hideTrail()
		hideRing()
	end)

	RunService.Heartbeat:Connect(tick)
end

return TutorialController
