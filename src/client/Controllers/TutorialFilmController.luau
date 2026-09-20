--!strict
--[[
	TutorialFilmController  (tutorial-film pass)
	The short in-engine film that replaces the old objective-line tutorial
	(TutorialService's presentation layer / TutorialController, both
	retired). Plays automatically once for a new profile, and on demand from
	Settings ("Watch tutorial again").

	WHY IT IS SELF-CONTAINED. The old tutorial depended on live server
	objects and stage timing, which the owner called unreliable. This film
	builds its own small "stage" - a folder of LOCAL, CLIENT-ONLY instances
	parented under `workspace` far from the real map (see
	TutorialFilmConfig.STAGE_ORIGIN) - from CLONES of real replicated art
	where it exists (a live workspace guardian, a live laser beam,
	TreadmillModel, the player's own character) and simple parts where
	nothing replicated exists (the chest, the pedestal, the floor - see
	docs/codex-prompts/tutorial-film.md). It never reads or writes any real
	guard, laser, container, plot or profile field, and never requires a
	single other controller to be in a particular state.

	THE CAMERA - the same ownership rules as FlyoverController /
	HatchController's reveal camera: the player's own camera is saved once
	and given back once; a Scriptable save is restored as Custom; one owner
	writes the frame every RenderStepped from a CFrameValue that tweens move,
	so a tween and the frame loop never fight.

	SAFETY. Every step is pcall-guarded (buildStage, each beat, the whole
	play() sequence); any failure calls stop() immediately, which always:
	restores the camera, unfreezes controls, releases the HUD claim,
	destroys the stage, and tells the server the film is over (so the
	server-side "in cinematic" mark - see TutorialFilmService - never
	outlives the client). The server ALSO hard-caps the mark on its own, so
	a client that never reports back cannot leave a player anchored.

	Reduced Effects / Low Graphics (Effects.luau) drop the sparkle
	particles and cash-number flourish; nothing that carries the story
	(camera moves, captions, the jump) is ever skipped.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TreadmillModel = require(ReplicatedStorage.Shared.Util.TreadmillModel)
local TutorialFilmConfig = require(ReplicatedStorage.Shared.Config.TutorialFilmConfig)

local FlyoverController = require(script.Parent.FlyoverController)
local HatchController = require(script.Parent.HatchController)
local UIStateController = require(script.Parent.UIStateController)

local TutorialFilmController = {}

local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local CLAIM = "tutorialFilm"
local FREEZE_ACTION = "TutorialFilmFreeze"

-- ==========================================================
-- STAGE GEOMETRY (relative to TutorialFilmConfig.STAGE_ORIGIN)
-- ==========================================================

local ORIGIN = TutorialFilmConfig.STAGE_ORIGIN
local HOME_SPAWN = Vector3.new(0, 0, 46)
local HOME_PAD = Vector3.new(5, 0, 40)
local HOME_TREADMILL = Vector3.new(-6, 0, 47)
--- Just short of the guard post, so the hero is close enough for the
--- "notice" turn to clearly land on them rather than on empty stage.
local LOBBY_POINT = Vector3.new(0, 0, -2)
local GUARD_POST = Vector3.new(0, 0, -8)
local LASER_POINT = Vector3.new(0, 0, -24)
local PEDESTAL_POINT = Vector3.new(0, 0, -46)

local function world(offset: Vector3): Vector3
	return ORIGIN + offset
end

-- ==========================================================
-- STATE
-- ==========================================================

type Saved = { cameraType: Enum.CameraType, cframe: CFrame, fov: number }

local played = false
local running = false
--- Bumped on every stop; a sequence step that sees a newer token quits
--- instead of touching instances the next run already owns.
local token = 0
local saved: Saved? = nil
local shot = Instance.new("CFrameValue")
local shotTween: Tween? = nil
local frameLoop: RBXScriptConnection? = nil
local controlsDisabled = false

local gui: ScreenGui? = nil
local fade: Frame? = nil
local caption: TextLabel? = nil
local endCard: Frame? = nil

local stageFolder: Folder? = nil

-- ==========================================================
-- CAMERA OWNERSHIP  (same rules as FlyoverController)
-- ==========================================================

local function takeCamera(): boolean
	local camera = workspace.CurrentCamera
	-- Never contest the camera with the reveal or the first-join flyover -
	-- both are also Scriptable-camera cutscenes and would fight this one
	-- frame for frame if they ever owned it at the same time.
	if not camera or HatchController.cameraBusy() or FlyoverController.isPlaying() then
		return false
	end
	saved = { cameraType = camera.CameraType, cframe = camera.CFrame, fov = camera.FieldOfView }
	shot.Value = camera.CFrame
	camera.CameraType = Enum.CameraType.Scriptable
	frameLoop = RunService.RenderStepped:Connect(function()
		local current = workspace.CurrentCamera
		if current and saved then
			current.CameraType = Enum.CameraType.Scriptable
			current.CFrame = shot.Value
		end
	end)
	return true
end

local function releaseCamera()
	if shotTween then
		shotTween:Cancel()
		shotTween = nil
	end
	if frameLoop then
		frameLoop:Disconnect()
		frameLoop = nil
	end
	local was = saved
	saved = nil
	local camera = workspace.CurrentCamera
	if was and camera then
		camera.FieldOfView = was.fov
		camera.CFrame = was.cframe
		camera.CameraType = if was.cameraType == Enum.CameraType.Scriptable then Enum.CameraType.Custom else was.cameraType
	end
end

--- Tweens the camera to `to` over `seconds`; 0 cuts instantly. Never fights a
--- tween already in flight - a new call always cancels the last one first.
local function cameraTo(to: CFrame, seconds: number, style: Enum.EasingStyle?): Tween?
	if shotTween then
		shotTween:Cancel()
		shotTween = nil
	end
	if seconds <= 0 then
		shot.Value = to
		return nil
	end
	local tween = TweenService:Create(shot, TweenInfo.new(seconds, style or Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Value = to })
	shotTween = tween
	tween:Play()
	return tween
end

-- ==========================================================
-- CONTROLS FREEZE (same technique as FlyoverController)
-- ==========================================================

local function playerControls(): any
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("PlayerModule")
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, playerModule = pcall(require, module)
	if not ok or type(playerModule) ~= "table" or type((playerModule :: any).GetControls) ~= "function" then
		return nil
	end
	local got, controls = pcall(function()
		return (playerModule :: any):GetControls()
	end)
	return if got then controls else nil
end

local function freeze(on: boolean)
	if on == controlsDisabled then
		return
	end
	controlsDisabled = on
	local controls = playerControls()
	if controls then
		pcall(function()
			if on then
				controls:Disable()
			else
				controls:Enable()
			end
		end)
	end
	if on then
		ContextActionService:BindActionAtPriority(FREEZE_ACTION, function()
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 50, Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward, Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight, Enum.PlayerActions.CharacterJump)
	else
		ContextActionService:UnbindAction(FREEZE_ACTION)
	end
end

-- ==========================================================
-- GENERIC MOVEMENT HELPER
-- ==========================================================

--- Drives a Model's pivot through a tween without fighting physics: a
--- CFrameValue is tweened and every change is copied onto the model with
--- PivotTo. Returns the Tween so a caller can `.Completed:Wait()`.
local function tweenPivot(model: Model, to: CFrame, seconds: number, style: Enum.EasingStyle?): Tween
	local value = Instance.new("CFrameValue")
	value.Value = model:GetPivot()
	local connection: RBXScriptConnection
	connection = value.Changed:Connect(function()
		if model.Parent then
			model:PivotTo(value.Value)
		end
	end)
	local tween = TweenService:Create(value, TweenInfo.new(math.max(seconds, 0.01), style or Enum.EasingStyle.Linear), { Value = to })
	tween.Completed:Once(function()
		connection:Disconnect()
		value:Destroy()
	end)
	tween:Play()
	return tween
end

-- ==========================================================
-- STAGE BUILDING
-- ==========================================================

--- One flat, clean part. Simple geometry stand-in per the brief - nothing
--- here impersonates a specific real prop, it just reads clearly on camera.
local function part(size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): BasePart
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = true
	p.Parent = stageFolder
	return p
end

--- The player's own run/jump animation ids, read straight off their OWN
--- live character's Animate script (the same trick TreadmillController
--- uses) - reused rather than duplicated because it is already proven to
--- degrade quietly (nil) when a rig has no Animate. Nil either id just
--- means the clone glides without a leg-cycle; the CFrame move still reads
--- as a run.
local function findAnimationId(character: Model, group: string, animName: string): string?
	local animate = character:FindFirstChild("Animate")
	local set = animate and animate:FindFirstChild(group)
	local anim = set and set:FindFirstChild(animName)
	if anim and anim:IsA("Animation") and anim.AnimationId ~= "" then
		return anim.AnimationId
	end
	return nil
end

--- A known-good public default, used only when the player's own character
--- has none of its own to borrow (see findAnimationId) - never a made-up id.
local FALLBACK_RUN_ANIM = "rbxassetid://913376220"

type Hero = {
	model: Model,
	humanoid: Humanoid?,
	animator: Animator?,
	runTrack: AnimationTrack?,
}

--- Builds the stand-in hero: a stripped, non-scripted CLONE of the player's
--- own real character when one exists (their actual avatar - the brief's
--- "copy of the player's own avatar", built the reliable way: from the rig
--- they are already wearing, rather than re-fetching it), or a simple
--- stylised block rig otherwise. Either way the result carries no scripts,
--- no tools, no collision with the real world, and cannot be mistaken for
--- the player's real character by anything else in the game (it is a local,
--- unreplicated instance under the stage folder).
local function buildHero(): Hero
	local source = player.Character
	if source and source:FindFirstChildOfClass("Humanoid") then
		-- A character is Archivable = false, and Clone() of one returns NIL
		-- (no error), which sent every run to the block-rig fallback. Opened
		-- for the length of the clone only.
		local ok, clone = pcall(function()
			local was = source.Archivable
			source.Archivable = true
			local copy = source:Clone()
			source.Archivable = was
			return copy
		end)
		if ok and clone then
			local runId = findAnimationId(clone, "run", "RunAnim") or findAnimationId(clone, "walk", "WalkAnim")
			-- Strip every script: the clone must never run the real Animate/
			-- Health/etc. logic. Animation is driven by this controller only.
			for _, descendant in clone:GetDescendants() do
				if descendant:IsA("BaseScript") or descendant:IsA("Tool") then
					descendant:Destroy()
				elseif descendant:IsA("BasePart") then
					-- ANCHORED: the whole rig is moved by PivotTo every frame
					-- (tweenPivot), never by physics, so nothing may fall,
					-- ragdoll or collide with the stage while it "runs".
					descendant.Anchored = true
					descendant.CanCollide = false
					descendant.CanTouch = false
					descendant.CanQuery = false
					descendant.Massless = true
				end
			end
			local humanoid = clone:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = 0 -- driven by CFrame tweens, never by Move
				humanoid.PlatformStand = true -- belt and braces on top of Anchored
				humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
				humanoid.RequiresNeck = false
			end
			local root = clone.PrimaryPart or clone:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				clone.PrimaryPart = root
			end
			clone.Name = "TutorialFilmHero"
			clone.Parent = stageFolder
			local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
			local track: AnimationTrack? = nil
			if animator and (runId or FALLBACK_RUN_ANIM) then
				local animation = Instance.new("Animation")
				animation.AnimationId = runId or FALLBACK_RUN_ANIM
				local loaded = pcall(function()
					track = animator:LoadAnimation(animation)
				end)
				if not loaded then
					track = nil
				end
			end
			return { model = clone, humanoid = humanoid, animator = animator, runTrack = track }
		end
	end

	-- STYLISED STAND-IN (placeholder - see docs/codex-prompts/tutorial-film.md
	-- for a proper mascot rig): a simple upright capsule with a head, in the
	-- brand's gold accent, moved by CFrame alone. No Humanoid, no animation.
	local model = Instance.new("Model")
	model.Name = "TutorialFilmHeroPlaceholder"
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Cylinder
	body.Size = Vector3.new(3, 1.4, 1.4)
	body.Orientation = Vector3.new(0, 0, 90)
	body.Color = Color3.fromRGB(255, 204, 56)
	body.Material = Enum.Material.SmoothPlastic
	body.Anchored = true -- moved by PivotTo only, same as every stage part
	body.CanCollide = false
	body.Massless = true
	body.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.1, 1.1, 1.1)
	head.Color = Color3.fromRGB(255, 224, 150)
	head.Anchored = true
	head.CanCollide = false
	head.Massless = true
	head.Parent = model
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body
	weld.Part1 = head
	weld.Parent = body
	model.PrimaryPart = body
	model.Parent = stageFolder
	return { model = model, humanoid = nil, animator = nil, runTrack = nil }
end

--- Clones a live guardian straight out of `workspace.Guardians` (built once
--- at server boot, plain replicated instances - see GuardianService). A
--- stylised stand-in if none exists yet (a server that has not finished its
--- first boot pass, or a museum layout change).
local function buildGuard(): Model?
	local holder = workspace:FindFirstChild("Guardians")
	local source: Model? = nil
	if holder then
		for _, child in holder:GetChildren() do
			if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then
				source = child
				break
			end
		end
	end
	if source then
		local ok, clone = pcall(function()
			return (source :: Model):Clone()
		end)
		if ok and clone then
			for _, descendant in clone:GetDescendants() do
				if descendant:IsA("BaseScript") then
					descendant:Destroy()
				elseif descendant:IsA("BasePart") then
					-- ANCHORED, same reasoning as the hero clone: moved by
					-- PivotTo only, never by physics.
					descendant.Anchored = true
					descendant.CanCollide = false
					descendant.CanTouch = false
					descendant.CanQuery = false
					descendant.Massless = true
				end
			end
			local humanoid = clone:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.PlatformStand = true
				humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			end
			clone.Name = "TutorialFilmGuard"
			clone.Parent = stageFolder
			return clone
		end
	end

	-- STYLISED STAND-IN - see docs/codex-prompts/tutorial-film.md.
	local model = Instance.new("Model")
	model.Name = "TutorialFilmGuardPlaceholder"
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(2.4, 4.4, 1.6)
	body.Color = Color3.fromRGB(70, 80, 100)
	body.Anchored = true
	body.CanCollide = false
	body.Massless = true
	body.Parent = model
	model.PrimaryPart = body
	model.Parent = stageFolder
	return model
end

--- A live laser beam cloned straight out of a museum zone's `Lasers` folder
--- (built once at server boot - see LaserService / MuseumGallery). A plain
--- Neon bar if the map has not built one yet.
local function buildLaser(zonesFolder: Instance?): BasePart
	if zonesFolder then
		for _, zone in zonesFolder:GetChildren() do
			local lasers = zone:FindFirstChild("Lasers")
			if lasers then
				for _, beam in lasers:GetChildren() do
					if beam:IsA("BasePart") then
						local ok, clone = pcall(function()
							return beam:Clone()
						end)
						if ok and clone then
							clone.Anchored = true -- a static prop; placed once, never tweened
							clone.CanCollide = false
							clone.CanTouch = false
							clone.CanQuery = false
							clone.Massless = true
							clone.Name = "TutorialFilmLaser"
							clone.Parent = stageFolder
							return clone
						end
					end
				end
			end
		end
	end
	return part(Vector3.new(10, 0.16, 0.16), CFrame.new(world(LASER_POINT) + Vector3.new(0, 1.6, 0)), Color3.fromRGB(255, 35, 49), Enum.Material.Neon)
end

--- The sealed chest. MysteryModel's real container art lives in
--- ServerStorage and is never replicated to the client (see
--- MysteryModel.folder), so this is a stylised stand-in, not a clone - see
--- docs/codex-prompts/tutorial-film.md for a proper asset.
local function buildChest(): Model
	local model = Instance.new("Model")
	model.Name = "TutorialFilmChest"
	local base = part(Vector3.new(2.2, 1.4, 1.6), CFrame.new(0, 0.7, 0), Color3.fromRGB(120, 78, 40), Enum.Material.Wood)
	local lid = part(Vector3.new(2.3, 0.5, 1.7), CFrame.new(0, 1.5, 0), Color3.fromRGB(150, 100, 55), Enum.Material.Wood)
	local band = part(Vector3.new(2.35, 0.25, 1.75), CFrame.new(0, 0.7, 0), Color3.fromRGB(255, 204, 56), Enum.Material.Metal)
	base.Parent, lid.Parent, band.Parent = model, model, model
	local weld1 = Instance.new("WeldConstraint")
	weld1.Part0, weld1.Part1, weld1.Parent = base, lid, base
	local weld2 = Instance.new("WeldConstraint")
	weld2.Part0, weld2.Part1, weld2.Parent = base, band, base
	model.PrimaryPart = base

	if not (Effects.isReduced() or Effects.isLowGraphics()) then
		local attachment = Instance.new("Attachment")
		attachment.Position = Vector3.new(0, 0.9, 0)
		attachment.Parent = base
		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 236, 160))
		sparkle.LightEmission = 0.6
		sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
		sparkle.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		sparkle.Lifetime = NumberRange.new(0.6, 1.1)
		sparkle.Rate = 6
		sparkle.Speed = NumberRange.new(0.5, 1)
		sparkle.Parent = attachment
	end
	return model
end

--- Cash gaining while placed: a few floating "+$" labels on a BillboardGui.
--- Skipped under Reduced Effects / Low Graphics - it is a flourish, not the
--- story (the caption alone says "it earns money while you're away").
local function floatCash(anchor: BasePart)
	if Effects.isReduced() or Effects.isLowGraphics() then
		return
	end
	task.spawn(function()
		for i = 1, 4 do
			if not anchor.Parent then
				return
			end
			local billboard = Instance.new("BillboardGui")
			billboard.Size = UDim2.fromOffset(120, 40)
			billboard.StudsOffset = Vector3.new(math.random(-10, 10) / 10, 1.4, math.random(-10, 10) / 10)
			billboard.AlwaysOnTop = true
			billboard.Parent = anchor
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.Font = FONT
			label.Text = "+$"
			label.TextColor3 = Color3.fromRGB(120, 255, 140)
			label.TextStrokeTransparency = 0.2
			label.TextScaled = true
			label.Parent = billboard
			TweenService:Create(billboard, TweenInfo.new(1.1, Enum.EasingStyle.Sine), {
				StudsOffset = billboard.StudsOffset + Vector3.new(0, 3, 0),
			}):Play()
			TweenService:Create(label, TweenInfo.new(1.1, Enum.EasingStyle.Sine), { TextTransparency = 1 }):Play()
			task.delay(1.1, function()
				billboard:Destroy()
			end)
			task.wait(0.5 + i * 0.15)
		end
	end)
end

--- Builds the whole self-contained stage. Returns the pieces later beats
--- need; nothing here is parented anywhere but `stageFolder`, which is
--- created fresh every run and destroyed on every exit path.
local function buildStage()
	local existing = workspace:FindFirstChild(TutorialFilmConfig.STAGE_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = TutorialFilmConfig.STAGE_FOLDER_NAME
	folder.Parent = workspace
	stageFolder = folder

	-- ---------- floor ----------
	part(Vector3.new(24, 1, 130), CFrame.new(world(Vector3.new(0, -0.5, 0))), Color3.fromRGB(200, 205, 215), Enum.Material.SmoothPlastic) -- museum-to-home strip
	part(Vector3.new(24, 1, 24), CFrame.new(world(Vector3.new(0, -0.4, 44))), Color3.fromRGB(150, 195, 150), Enum.Material.Grass) -- the base pad

	-- ---------- base props ----------
	part(Vector3.new(4.5, 0.3, 4.5), CFrame.new(world(HOME_PAD) + Vector3.new(0, 0.05, 0)), Color3.fromRGB(90, 110, 200), Enum.Material.Neon) -- display pad
	local treadmillDeck = part(Vector3.new(4, 0.4, 8), CFrame.new(world(HOME_TREADMILL)), Color3.fromRGB(60, 60, 70), Enum.Material.Metal)
	local treadmillArt = TreadmillModel.build(1)
	if treadmillArt then
		treadmillArt.Parent = stageFolder
		local min, max = TreadmillModel.worldExtents(treadmillArt)
		if min and max then
			local lift = treadmillDeck.Position.Y + treadmillDeck.Size.Y / 2 - min.Y
			treadmillArt:PivotTo(treadmillArt:GetPivot() + Vector3.new(0, lift, 0))
			treadmillArt:PivotTo(CFrame.new(treadmillDeck.Position.X, treadmillArt:GetPivot().Position.Y, treadmillDeck.Position.Z) * treadmillArt:GetPivot().Rotation)
		end
	end

	-- ---------- museum props ----------
	local pedestal = part(Vector3.new(2.4, 3, 2.4), CFrame.new(world(PEDESTAL_POINT) + Vector3.new(0, 1.5, 0)), Color3.fromRGB(225, 220, 205), Enum.Material.Marble)
	local chest = buildChest()
	chest:PivotTo(CFrame.new(pedestal.Position + Vector3.new(0, pedestal.Size.Y / 2 + 0.75, 0)))
	chest.Parent = stageFolder

	local zonesFolder = workspace:FindFirstChild("Map")
	zonesFolder = zonesFolder and zonesFolder:FindFirstChild("Zones")
	local laser = buildLaser(zonesFolder)
	laser.CFrame = CFrame.new(world(LASER_POINT) + Vector3.new(0, 1.8, 0))
	laser.Size = Vector3.new(10, laser.Size.Y, laser.Size.Z)

	local guard = buildGuard()
	if guard then
		local root = guard.PrimaryPart or guard:FindFirstChild("HumanoidRootPart")
		local height = 5
		if root and root:IsA("BasePart") then
			height = root.Size.Y
		end
		guard:PivotTo(CFrame.new(world(GUARD_POST) + Vector3.new(2.5, height / 2, 0), world(GUARD_POST)))
	end

	local hero = buildHero()
	hero.model:PivotTo(CFrame.new(world(HOME_SPAWN), world(LOBBY_POINT)))

	return {
		hero = hero,
		guard = guard,
		laser = laser,
		chest = chest,
		pedestal = pedestal,
		treadmillDeck = treadmillDeck,
	}
end

local function destroyStage()
	if stageFolder then
		stageFolder:Destroy()
		stageFolder = nil
	end
end

-- ==========================================================
-- GUI
-- ==========================================================

local function outline(label: TextLabel)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(20, 14, 40)
	stroke.Parent = label
end

local function buildGui(onSkip: () -> (), onEndCardTap: () -> ())
	local screen = Instance.new("ScreenGui")
	screen.Name = "TutorialFilmUI"
	screen.IgnoreGuiInset = true
	screen.ScreenInsets = Enum.ScreenInsets.None
	screen.DisplayOrder = 950
	screen.ResetOnSpawn = false

	for _, top in { true, false } do
		local bar = Instance.new("Frame")
		bar.Name = if top then "BarTop" else "BarBottom"
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0, if top then 0 else 1)
		bar.Position = UDim2.fromScale(0, if top then 0 else 1)
		bar.Size = UDim2.fromScale(1, 0.1)
		bar.ZIndex = 2
		bar.Parent = screen
	end

	local captionLabel = Instance.new("TextLabel")
	captionLabel.Name = "Caption"
	captionLabel.BackgroundTransparency = 1
	captionLabel.AnchorPoint = Vector2.new(0.5, 1)
	captionLabel.Position = UDim2.fromScale(0.5, 0.87)
	captionLabel.Size = UDim2.fromScale(0.86, 0.1)
	captionLabel.Font = FONT
	captionLabel.TextScaled = true
	captionLabel.TextColor3 = Color3.new(1, 1, 1)
	captionLabel.TextTransparency = 1
	captionLabel.Text = ""
	captionLabel.Parent = screen
	outline(captionLabel)
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 46
	limit.MinTextSize = 18
	limit.Parent = captionLabel

	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.AnchorPoint = Vector2.new(1, 0)
	skip.Position = UDim2.new(1, -20, 0.1, 12)
	skip.Size = UDim2.fromOffset(120, 48)
	skip.BackgroundColor3 = Color3.fromRGB(30, 24, 60)
	skip.BackgroundTransparency = 0.15
	skip.Font = FONT
	skip.Text = "Skip"
	skip.TextSize = 22
	skip.TextColor3 = Color3.new(1, 1, 1)
	skip.ZIndex = 5
	skip.Parent = screen
	local skipCorner = Instance.new("UICorner")
	skipCorner.CornerRadius = UDim.new(0, 12)
	skipCorner.Parent = skip
	local skipStroke = Instance.new("UIStroke")
	skipStroke.Thickness = 2
	skipStroke.Color = Color3.new(1, 1, 1)
	skipStroke.Parent = skip
	skip.Activated:Connect(onSkip)

	local black = Instance.new("Frame")
	black.Name = "Fade"
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	-- Opaque from the first frame: the stage and camera cut both happen a
	-- moment after this GUI exists, and nothing of the real world (or the
	-- half-built stage) may show through before the film explicitly fades
	-- itself in.
	black.BackgroundTransparency = 0
	black.BorderSizePixel = 0
	black.Size = UDim2.fromScale(1, 1)
	black.ZIndex = 10
	black.Parent = screen

	-- ---------- end card ----------
	local card = Instance.new("Frame")
	card.Name = "EndCard"
	card.BackgroundColor3 = Color3.fromRGB(20, 16, 40)
	card.BackgroundTransparency = 1
	card.BorderSizePixel = 0
	card.Size = UDim2.fromScale(1, 1)
	card.Visible = false
	-- Above the fade frame (ZIndex 10): the end card must read as fully
	-- covering the stage on its own, whatever state the fade is in.
	card.ZIndex = 11
	card.Parent = screen

	local cardButton = Instance.new("TextButton")
	cardButton.Name = "TapCatcher"
	cardButton.BackgroundTransparency = 1
	cardButton.Size = UDim2.fromScale(1, 1)
	cardButton.Text = ""
	cardButton.ZIndex = 11
	cardButton.Parent = card
	cardButton.Activated:Connect(onEndCardTap)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.4)
	title.Size = UDim2.fromScale(0.86, 0.16)
	title.Font = FONT
	title.TextScaled = true
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Text = TutorialFilmConfig.END_CAPTION
	title.ZIndex = 12
	title.Parent = card
	outline(title)

	local play = Instance.new("TextButton")
	play.Name = "Play"
	play.AnchorPoint = Vector2.new(0.5, 0.5)
	play.Position = UDim2.fromScale(0.5, 0.62)
	play.Size = UDim2.fromOffset(220, 64)
	play.BackgroundColor3 = Color3.fromRGB(76, 200, 96)
	play.Font = FONT
	play.Text = "PLAY"
	play.TextScaled = true
	play.TextColor3 = Color3.new(1, 1, 1)
	play.ZIndex = 12
	play.Parent = card
	local playCorner = Instance.new("UICorner")
	playCorner.CornerRadius = UDim.new(0, 16)
	playCorner.Parent = play
	play.Activated:Connect(onEndCardTap)

	screen.Parent = player:WaitForChild("PlayerGui")
	fade = black
	caption = captionLabel
	endCard = card
	return screen
end

--- `transparency` is the overlay's own BackgroundTransparency: 0 covers the
--- stage in black, 1 reveals it. Blocks until the tween finishes (or
--- applies instantly at `seconds <= 0`).
local function fadeTo(transparency: number, seconds: number)
	local black = fade
	if not black then
		return
	end
	if seconds <= 0 then
		black.BackgroundTransparency = transparency
		return
	end
	local tween = TweenService:Create(black, TweenInfo.new(seconds, Enum.EasingStyle.Quad), { BackgroundTransparency = transparency })
	tween:Play()
	tween.Completed:Wait()
end

local function setCaption(text: string)
	local label = caption
	if not label then
		return
	end
	if Effects.isReduced() then
		label.Text = text
		label.TextTransparency = 0
		return
	end
	local out = TweenService:Create(label, TweenInfo.new(0.15), { TextTransparency = 1 })
	out:Play()
	out.Completed:Wait()
	label.Text = text
	TweenService:Create(label, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
end

-- ==========================================================
-- BEATS
-- ==========================================================

local function holdFor(key: string): number
	for _, beat in TutorialFilmConfig.BEATS do
		if beat.key == key then
			return beat.hold
		end
	end
	return 3
end

local function captionFor(key: string): string
	for _, beat in TutorialFilmConfig.BEATS do
		if beat.key == key then
			return beat.caption
		end
	end
	return ""
end

--- Runs the whole script against a freshly built stage. `alive()` lets a
--- concurrent stop() (skip, error, respawn) cut a beat short cleanly.
local function runBeats(stage: any, alive: () -> boolean)
	local hero = stage.hero :: Hero
	local heroModel = hero.model

	local function playRun(loop: boolean)
		local track = hero.runTrack
		if track and not track.IsPlaying then
			track.Looped = loop
			track:Play()
		end
	end
	local function stopRun()
		local track = hero.runTrack
		if track and track.IsPlaying then
			track:Stop(0.15)
		end
	end

	-- ---------- spawn ----------
	-- Camera cut FIRST, while the fade is still fully opaque, so the reveal
	-- never shows a frame of the real world or a half-built stage.
	cameraTo(CFrame.lookAt(world(HOME_SPAWN) + Vector3.new(12, 9, 14), world(HOME_SPAWN)), 0)
	fadeTo(1, TutorialFilmConfig.FADE_SECONDS) -- reveal
	if not alive() then
		return
	end
	setCaption(captionFor("spawn"))
	task.wait(holdFor("spawn"))
	if not alive() then
		return
	end

	-- ---------- sneak: lobby -> museum edge ----------
	setCaption(captionFor("sneak"))
	playRun(true)
	local sneakTarget = CFrame.new(world(LOBBY_POINT), world(GUARD_POST))
	local sneakTween = tweenPivot(heroModel, sneakTarget, holdFor("sneak") - 0.3, Enum.EasingStyle.Sine)
	cameraTo(CFrame.lookAt(world(LOBBY_POINT) + Vector3.new(-9, 7, 6), world(LOBBY_POINT)), holdFor("sneak") * 0.5)
	sneakTween.Completed:Wait()
	stopRun()
	if not alive() then
		return
	end

	-- ---------- guard notices ----------
	setCaption(captionFor("guard"))
	local guard = stage.guard :: Model?
	cameraTo(CFrame.lookAt(world(GUARD_POST) + Vector3.new(9, 6, -6), world(GUARD_POST)), 0.6)
	if guard and guard.PrimaryPart then
		-- A menacing-but-harmless "notice": turn to face the hero, one quick
		-- beat, nothing that reads as an attack.
		tweenPivot(guard, CFrame.new(guard:GetPivot().Position, heroModel:GetPivot().Position), 0.5, Enum.EasingStyle.Back)
		pcall(Audio.play, "PoliceWhistle")
	end
	task.wait(holdFor("guard"))
	if not alive() then
		return
	end

	-- ---------- laser jump ----------
	setCaption(captionFor("laser"))
	cameraTo(CFrame.lookAt(world(LASER_POINT) + Vector3.new(-9, 5, 0), world(LASER_POINT)), 0.6)
	playRun(true)
	local approach = CFrame.new(world(LASER_POINT) + Vector3.new(0, 0, 5), world(PEDESTAL_POINT))
	tweenPivot(heroModel, approach, 0.8, Enum.EasingStyle.Linear).Completed:Wait()
	if not alive() then
		return
	end
	stopRun()
	-- The jump: a simple two-part arc (up-and-over, then down) - "CFrame-
	-- driven poses" per the brief when no dedicated jump clip is available.
	local overFrom = heroModel:GetPivot()
	local overApex = overFrom + Vector3.new(0, 5, -3)
	local overLand = CFrame.new(world(LASER_POINT) + Vector3.new(0, 0, -5), world(PEDESTAL_POINT))
	tweenPivot(heroModel, overApex, 0.3, Enum.EasingStyle.Quad).Completed:Wait()
	if not alive() then
		return
	end
	tweenPivot(heroModel, overLand, 0.3, Enum.EasingStyle.Quad).Completed:Wait()
	if not alive() then
		return
	end
	playRun(true)
	local toChest = CFrame.new(world(PEDESTAL_POINT) + Vector3.new(0, 0, 3), world(PEDESTAL_POINT))
	tweenPivot(heroModel, toChest, math.max(holdFor("laser") - 1.4, 0.6), Enum.EasingStyle.Sine).Completed:Wait()
	stopRun()
	if not alive() then
		return
	end

	-- ---------- grab the chest ----------
	setCaption(captionFor("grab"))
	cameraTo(CFrame.lookAt(world(PEDESTAL_POINT) + Vector3.new(4, 4, 4), world(PEDESTAL_POINT) + Vector3.new(0, 1, 0)), 0.6)
	pcall(Audio.play, "Grab")
	local chest = stage.chest :: Model
	local heroRoot = heroModel.PrimaryPart
	if heroRoot then
		-- Carried: welded a step above and in front of the hero's root for
		-- the rest of the run home, exactly like the real carry silhouette.
		chest:PivotTo(heroRoot.CFrame * CFrame.new(0, 2, -1.4))
	end
	task.wait(holdFor("grab"))
	if not alive() then
		return
	end

	-- ---------- run home, guard chasing ----------
	setCaption(captionFor("run"))
	pcall(Audio.play, "PoliceWhistle")
	playRun(true)
	local runSeconds = holdFor("run")
	-- Arriving just short of the pad, facing it, so "place" is a small final
	-- step rather than a jump-cut between two far-apart positions.
	local runTarget = CFrame.new(world(HOME_PAD) + Vector3.new(-4, 0, -3), world(HOME_PAD))
	local carryConnection: RBXScriptConnection? = nil
	if heroRoot then
		carryConnection = RunService.RenderStepped:Connect(function()
			if chest.Parent and heroRoot.Parent then
				chest:PivotTo(heroRoot.CFrame * CFrame.new(0, 2, -1.4))
			end
		end)
	end
	local heroRunTween = tweenPivot(heroModel, runTarget, runSeconds, Enum.EasingStyle.Sine)
	if guard and guard.PrimaryPart then
		-- The chase: the guard follows a few studs back, never quite closing
		-- the gap - it reads as pursuit without ever "catching" the hero.
		local chaseTarget = CFrame.new(world(HOME_SPAWN) + Vector3.new(0, 0, 6), world(HOME_PAD))
		tweenPivot(guard, chaseTarget, runSeconds + 0.6, Enum.EasingStyle.Sine)
	end
	cameraTo(CFrame.lookAt(world(Vector3.new(-10, 8, 30)), world(Vector3.new(0, 2, 30))), runSeconds * 0.6)
	heroRunTween.Completed:Wait()
	if carryConnection then
		carryConnection:Disconnect()
	end
	stopRun()
	if not alive() then
		return
	end

	-- ---------- place it ----------
	setCaption(captionFor("place"))
	cameraTo(CFrame.lookAt(world(HOME_PAD) + Vector3.new(6, 5, 6), world(HOME_PAD)), 0.6)
	pcall(Audio.play, "PlaceItem")
	chest:PivotTo(CFrame.new(world(HOME_PAD) + Vector3.new(0, 1, 0)))
	task.wait(holdFor("place"))
	if not alive() then
		return
	end

	-- ---------- income ----------
	setCaption(captionFor("income"))
	local chestBase = chest.PrimaryPart
	if chestBase then
		floatCash(chestBase)
	end
	task.wait(holdFor("income"))
	if not alive() then
		return
	end

	-- ---------- train ----------
	setCaption(captionFor("train"))
	cameraTo(CFrame.lookAt(world(HOME_TREADMILL) + Vector3.new(6, 4, -4), world(HOME_TREADMILL)), 0.6)
	local hopTo = CFrame.new(world(HOME_TREADMILL) + Vector3.new(0, 1.2, 0), world(HOME_TREADMILL) + Vector3.new(0, 1.2, -10))
	tweenPivot(heroModel, hopTo, 0.5, Enum.EasingStyle.Back).Completed:Wait()
	if not alive() then
		return
	end
	playRun(true)
	pcall(Audio.play, "TreadmillUnlock")
	-- A simple ticking Speed counter above the treadmill.
	local counterAnchor = stage.treadmillDeck :: BasePart?
	if counterAnchor then
		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.fromOffset(160, 50)
		billboard.StudsOffset = Vector3.new(0, 4, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = counterAnchor
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = FONT
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 224, 90)
		label.TextStrokeTransparency = 0.2
		label.Parent = billboard
		outline(label)
		local shown = 0
		local speedHold = holdFor("train")
		local speedStart = os.clock()
		while alive() and os.clock() - speedStart < speedHold do
			shown = math.min(shown + math.random(8, 20), 999)
			label.Text = `SPEED +{shown}`
			task.wait(0.18)
		end
		billboard:Destroy()
	else
		task.wait(holdFor("train"))
	end
	stopRun()
end

-- ==========================================================
-- RUN / STOP
-- ==========================================================

local function report(action: string, arg: any)
	pcall(function()
		Remotes.get("TutorialFilmRequest"):FireServer(action, arg)
	end)
end

--- Ends the film. `instant` skips the fade (an error or a reveal taking
--- over). `skipped` only matters the first time stop() runs per play().
local function stop(instant: boolean, skipped: boolean)
	if not running then
		return
	end
	running = false
	token += 1
	local screen = gui
	gui = nil
	if not instant and screen and screen.Parent and not HatchController.cameraBusy() then
		fadeTo(0, TutorialFilmConfig.FADE_SECONDS) -- cover before the stage disappears
	end
	releaseCamera()
	freeze(false)
	UIStateController.release(CLAIM)
	destroyStage()
	if screen then
		screen:Destroy()
	end
	fade, caption, endCard = nil, nil, nil
	report("done", skipped)
end

local function showEndCard(onContinue: () -> ())
	local card = endCard
	if not card then
		onContinue()
		return
	end
	card.Visible = true
	if Effects.isReduced() then
		card.BackgroundTransparency = 0.1
	else
		TweenService:Create(card, TweenInfo.new(0.3), { BackgroundTransparency = 0.1 }):Play()
	end
	local mine = token
	task.delay(TutorialFilmConfig.END_CARD_SECONDS, function()
		if token == mine then
			onContinue()
		end
	end)
end

local function play(replay: boolean)
	if running or (played and not replay) then
		return
	end
	if not takeCamera() then
		return
	end
	played = true
	running = true
	token += 1
	local mine = token
	local function alive(): boolean
		return running and token == mine
	end

	report(if replay then "replay" else "start", nil)
	-- Whatever panel is open goes first. The Settings replay is pressed FROM a
	-- panel, and the HUD claim below hides the HUD, not the pack's Frames: the
	-- first Studio run played the whole film behind the Settings panel.
	local closeAll = (_G :: any).CloseAllUIFrames
	if type(closeAll) == "function" then
		pcall(closeAll)
	end
	UIStateController.claim(CLAIM)
	freeze(true)

	local skippedFlag = false
	local ended = false
	local function finish(skip: boolean)
		if ended then
			return
		end
		ended = true
		skippedFlag = skip
		stop(skip, skippedFlag)
	end

	-- The REAL character dying mid-film ends it at once (the respawn hook in
	-- start() would only catch it seconds later). Once: a dead humanoid
	-- never fires again, and a connection on a destroyed character is
	-- collected with it.
	local realCharacter = player.Character
	local realHumanoid = realCharacter and realCharacter:FindFirstChildOfClass("Humanoid")
	if realHumanoid then
		realHumanoid.Died:Once(function()
			if alive() then
				finish(true)
			end
		end)
	end

	gui = buildGui(function()
		finish(true)
	end, function()
		finish(false)
	end)

	local ok, err = pcall(function(): boolean
		local stage = buildStage()
		if not alive() then
			return true
		end
		runBeats(stage, alive)
		if not alive() then
			return true
		end
		-- ---------- end card ----------
		fadeTo(0, TutorialFilmConfig.FADE_SECONDS) -- cover the stage; the card itself is what is then shown
		if caption then
			caption.Text = ""
		end
		showEndCard(function()
			finish(false)
		end)
		return true
	end)
	if not ok then
		warn(`[TutorialFilmController] film failed: {err}`)
		finish(true)
	end
end

function TutorialFilmController.isPlaying(): boolean
	return running
end

--- The Settings "Watch tutorial again" button. A plain module-level
--- function (not assigned inside start()) so it exists the instant this
--- module is required, whatever order controllers start in. Touches no
--- profile flag - see TutorialFilmService's "replay" action.
function TutorialFilmController.replay()
	if not TutorialFilmConfig.ENABLED or running then
		return
	end
	play(true)
end

-- ==========================================================
-- START
-- ==========================================================

function TutorialFilmController.start()
	if not TutorialFilmConfig.ENABLED then
		return
	end

	-- A reveal takes the camera: hand it back now, without a fade. The film
	-- never restarts on its own afterwards - the player is left exactly
	-- where TutorialFilmService's due flag says they were.
	HatchController.onRevealStarting(function()
		if running then
			stop(true, true)
		end
	end)

	-- A respawn or death mid-film ends it cleanly rather than leaving the
	-- stage running against a character that no longer exists.
	player.CharacterAdded:Connect(function()
		if running then
			stop(true, true)
		end
	end)

	local StateStore = require(script.Parent.Parent.StateStore)
	local wanted = false
	local waiting = false

	local function tryAutoPlay()
		if waiting or played or not wanted then
			return
		end
		waiting = true
		task.spawn(function()
			local deadline = os.clock() + TutorialFilmConfig.LOADING_WAIT
			while player:GetAttribute("LoadingScreenDone") ~= true and os.clock() < deadline do
				task.wait(0.25)
			end
			local character = player.Character or player.CharacterAdded:Wait()
			character:WaitForChild("HumanoidRootPart", 15)
			-- Never race the first-join flyover for the camera: wait for
			-- `firstSession` itself (the server flag Flyover watches) rather
			-- than Flyover's own client-side `isPlaying`, so the film only
			-- ever attempts to start once the flyover is truly done (or was
			-- never owed) - not merely "not this exact frame". Bounded, so a
			-- flyover that somehow never finishes cannot strand the film
			-- forever.
			local flyoverDeadline = os.clock() + TutorialFilmConfig.LOADING_WAIT
			while os.clock() < flyoverDeadline
				and (HatchController.cameraBusy()
					or FlyoverController.isPlaying()
					or (StateStore.get() ~= nil and (StateStore.get() :: any).firstSession == true)) do
				task.wait(0.5)
			end
			task.wait(0.5)
			waiting = false
			if wanted and not played then
				play(false)
			end
		end)
	end

	StateStore.onKeyChanged("tutorialFilmDue", function(value)
		local was = wanted
		wanted = value == true
		-- The server only turns this back on for a Studio test
		-- (`filmForceStart`): allow one more automatic run.
		if wanted and not was and played and not running then
			played = false
		end
		tryAutoPlay()
	end)
end

return TutorialFilmController
