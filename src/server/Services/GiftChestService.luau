--!strict
--[[
	GiftChestService
	The second way into the Gift menu: a chest standing in the hub.

	IT IS A DOOR, NOT A REWARD. Interacting with the chest opens the SAME panel
	the GIFT button opens - GroupGiftController's, painted from the same PNG -
	and nothing here grants anything. The claim still goes through
	GroupGiftService, which checks group membership with Roblox's own API and
	pays out exactly once per profile. A chest that granted its own gift would
	be a second reward path to keep in sync, and the first thing an exploiter
	would look for.

	THE ART IS THE OWNER'S. `ServerStorage.GameAssets.GiftrewardChest` (a mesh
	part) is cloned and stood on the podium below. Nothing here is an uploaded
	asset: the podium, the spotlights, the floating gifts and the sparkle are
	parts, beams and the engine's own particle texture.

	THE PRESENTATION (owner, 2026-09-18). The chest used to be a mesh on a
	green neon disc with a small floating "Gift Chest" sign - and from the
	spawn circle it read as a prop, not a prize. It is staged now, the way the
	reference draws it: a three-tier gold podium, three spotlight beams from
	above converging on it, four wrapped gifts floating and bobbing around it,
	a rising gold sparkle, and one billboard in three lines - a red FREE
	REWARD ribbon, the GIFT CHEST title in gold, and a CLAIM NOW! pill with a
	bobbing chevron under it. The pill's label is the one GroupGiftController
	flips to CLAIMED for a player who has already collected (it looks the sign
	up by name: Chest.FreeSign.Text), so those names are load-bearing.

	ONE PROMPT, ONE MENU. The prompt is a ProximityPrompt, so keyboard, touch
	and gamepad all work without a line of input code; a short cooldown per
	player stops a held key from firing the open remote repeatedly.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local LobbyLayout = require(ReplicatedStorage.Shared.LobbyLayout)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local AttractionSign = require(ReplicatedStorage.Shared.Util.AttractionSign)

local GiftChestService = {}

local CHEST_NAME = "GiftChest"
--- Studs across, for the chest itself. The supplied mesh is small.
local CHEST_SCALE = 3.4
--- Seconds a player must wait between opens. One menu per press.
local OPEN_COOLDOWN = 1.2

--- The palette: the gold of the reference's podium and beams, the red of its
--- ribbon, the near-black outline every piece of this UI pack carries.
local GOLD = Color3.fromRGB(255, 200, 48)
local GOLD_DEEP = Color3.fromRGB(214, 150, 22)
local GOLD_PALE = Color3.fromRGB(255, 236, 140)
local GOLD_GLOW = Color3.fromRGB(255, 226, 110)
local RED = Color3.fromRGB(232, 44, 52)
local RED_DEEP = Color3.fromRGB(168, 18, 30)
local OUTLINE = Color3.fromRGB(38, 22, 6)
local WHITE = Color3.fromRGB(255, 255, 255)
local GIFT_WHITE = Color3.fromRGB(250, 246, 236)

--- The podium's three tiers, top to bottom: radius and height in studs.
local TIERS = { { 4.4, 0.7 }, { 5.6, 0.55 }, { 6.8, 0.5 } }
--- Where the gifts hover, relative to the chest's spot: x, rest height, z,
--- and the bob's own period so no two move in step.
local GIFTS = {
	{ -6.2, 6.4, -1.2, 2.3 },
	{ 6.4, 7.1, -0.8, 2.7 },
	{ -5.6, 3.4, 1.6, 2.1 },
	{ 5.8, 3.8, 1.4, 2.5 },
}
--- The engine's own sparkle texture: it ships with the client, so it is not
--- an uploaded asset that can go missing.
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local lastOpen: { [Player]: number } = {}

local function chestTemplate(): BasePart?
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local found = assets and assets:FindFirstChild("GiftrewardChest")
	return if found and found:IsA("BasePart") then found else nil
end

--- A decorative part: anchored, walk-through, never in a raycast.
local function prop(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

--- One tier of the podium: a gold drum with a brighter neon rim just under
--- its lip, so the edges catch the eye the way the reference's do.
local function tier(parent: Instance, spot: Vector3, radius: number, height: number, baseY: number): number
	local drum = prop("Tier", parent)
	drum.Shape = Enum.PartType.Cylinder
	drum.Size = Vector3.new(height, radius * 2, radius * 2)
	drum.CFrame = CFrame.new(spot.X, baseY + height / 2, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
	drum.Material = Enum.Material.SmoothPlastic
	drum.Color = GOLD
	drum.CastShadow = true

	local rim = prop("Rim", parent)
	rim.Shape = Enum.PartType.Cylinder
	rim.Size = Vector3.new(0.12, radius * 2 + 0.18, radius * 2 + 0.18)
	rim.CFrame = CFrame.new(spot.X, baseY + height - 0.1, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
	rim.Material = Enum.Material.Neon
	rim.Color = GOLD_PALE
	rim.Transparency = 0.15
	return baseY + height
end

--- One spotlight: a beam from a point high above, widening down to the
--- chest, with the light itself at the top so the podium is lit for real.
local function spotlight(parent: Instance, from: Vector3, to: Vector3)
	local top = prop("SpotTop", parent)
	top.Size = Vector3.new(0.4, 0.4, 0.4)
	top.Transparency = 1
	top.CFrame = CFrame.lookAt(from, to)
	local bottom = prop("SpotBottom", parent)
	bottom.Size = Vector3.new(0.4, 0.4, 0.4)
	bottom.Transparency = 1
	bottom.CFrame = CFrame.new(to)

	local a0 = Instance.new("Attachment")
	a0.Parent = top
	local a1 = Instance.new("Attachment")
	a1.Parent = bottom

	local beam = Instance.new("Beam")
	beam.Name = "Cone"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = 0.9
	beam.Width1 = 7.5
	beam.Color = ColorSequence.new(GOLD_PALE, GOLD_GLOW)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.7, 0.85),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Brightness = 2.5
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Parent = top

	local light = Instance.new("SpotLight")
	light.Angle = 42
	light.Brightness = 1.4
	light.Range = 26
	light.Color = GOLD_GLOW
	light.Face = Enum.NormalId.Front
	light.Shadows = false
	light.Parent = top
end

--- A wrapped gift: a cream box, a red ribbon each way, a red bow, bobbing on
--- its own clock. Four of these float around the chest.
local function gift(parent: Instance, at: Vector3, period: number)
	local box = prop("Gift", parent)
	box.Size = Vector3.new(1.7, 1.5, 1.7)
	box.CFrame = CFrame.new(at) * CFrame.Angles(0, math.rad(20), 0)
	box.Material = Enum.Material.SmoothPlastic
	box.Color = GIFT_WHITE
	box.CastShadow = true

	local function ribbon(size: Vector3, offset: CFrame)
		local strip = prop("Ribbon", parent)
		strip.Size = size
		strip.CFrame = box.CFrame * offset
		strip.Material = Enum.Material.SmoothPlastic
		strip.Color = RED
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = box
		weld.Part1 = strip
		weld.Parent = strip
		strip.Anchored = false
	end
	ribbon(Vector3.new(0.42, 1.56, 1.76), CFrame.new())
	ribbon(Vector3.new(1.76, 1.56, 0.42), CFrame.new())
	local bow = prop("Bow", parent)
	bow.Shape = Enum.PartType.Ball
	bow.Size = Vector3.new(0.7, 0.7, 0.7)
	bow.CFrame = box.CFrame * CFrame.new(0, 0.95, 0)
	bow.Material = Enum.Material.SmoothPlastic
	bow.Color = RED_DEEP
	local bowWeld = Instance.new("WeldConstraint")
	bowWeld.Part0 = box
	bowWeld.Part1 = bow
	bowWeld.Parent = bow
	bow.Anchored = false

	-- One tween on the box; the welded ribbon and bow ride along.
	local rest = box.CFrame
	TweenService:Create(
		box,
		TweenInfo.new(period, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ CFrame = rest * CFrame.new(0, 0.55, 0) * CFrame.Angles(0, math.rad(14), 0) }
	):Play()
end

--- A text label in the pack's voice: FredokaOne, scaled, a heavy dark
--- outline. `Active = false` so the billboard can never take a touch.
local function words(name: string, parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3, strokeWidth: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Active = false
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = size
	label.Position = position
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = strokeWidth
	stroke.Color = OUTLINE
	stroke.LineJoinMode = Enum.LineJoinMode.Miter
	stroke.Parent = label
	label.Parent = parent
	return label
end

--- THE BANNER: three lines over the chest, sized in studs so it is the same
--- physical size on every screen. Named FreeSign with a Text label inside
--- because GroupGiftController looks for exactly that to flip it to CLAIMED.
local function banner(chest: BasePart)
	local sign = Instance.new("BillboardGui")
	sign.Name = "FreeSign"
	sign.Active = false
	-- Sized to the STAGE, not the chest: seen from the spawn circle the
	-- title has to read across the apron, the way the reference's does.
	sign.Size = UDim2.fromScale(19, 10.4)
	sign.StudsOffsetWorldSpace = Vector3.new(0, chest.Size.Y / 2 + 7.6, 0)
	sign.AlwaysOnTop = false
	sign.LightInfluence = 0
	sign.MaxDistance = 240
	sign.Adornee = chest
	sign:SetAttribute(AttractionSign.TAG, true)
	sign.Parent = chest

	-- Line 1: the red ribbon, stars either side.
	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.Active = false
	ribbon.AnchorPoint = Vector2.new(0.5, 0.5)
	ribbon.Position = UDim2.fromScale(0.5, 0.13)
	ribbon.Size = UDim2.fromScale(0.62, 0.2)
	ribbon.BackgroundColor3 = WHITE
	ribbon.BorderSizePixel = 0
	local ribbonCorner = Instance.new("UICorner")
	ribbonCorner.CornerRadius = UDim.new(0.28, 0)
	ribbonCorner.Parent = ribbon
	local ribbonPaint = Instance.new("UIGradient")
	ribbonPaint.Rotation = 90
	ribbonPaint.Color = ColorSequence.new(RED, RED_DEEP)
	ribbonPaint.Parent = ribbon
	local ribbonEdge = Instance.new("UIStroke")
	ribbonEdge.Thickness = 2.5
	ribbonEdge.Color = OUTLINE
	ribbonEdge.Parent = ribbon
	ribbon.Parent = sign
	words("Label", ribbon, "FREE REWARD", UDim2.fromScale(0.86, 0.72), UDim2.fromScale(0.5, 0.5), WHITE, 2)
	words("StarL", sign, "★", UDim2.fromScale(0.09, 0.2), UDim2.fromScale(0.15, 0.13), GOLD, 2)
	words("StarR", sign, "★", UDim2.fromScale(0.09, 0.2), UDim2.fromScale(0.85, 0.13), GOLD, 2)

	-- Line 2: the title, gold on gold, the biggest thing on the apron.
	local title = words("Title", sign, "GIFT CHEST", UDim2.fromScale(1, 0.36), UDim2.fromScale(0.5, 0.4), WHITE, 4)
	local titlePaint = Instance.new("UIGradient")
	titlePaint.Rotation = 90
	titlePaint.Color = ColorSequence.new(GOLD_PALE, GOLD_DEEP)
	titlePaint.Parent = title

	-- Line 3: the pill. Its label is THE label GroupGiftController flips.
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.Active = false
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromScale(0.5, 0.7)
	pill.Size = UDim2.fromScale(0.56, 0.2)
	pill.BackgroundColor3 = WHITE
	pill.BorderSizePixel = 0
	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(1, 0)
	pillCorner.Parent = pill
	local pillPaint = Instance.new("UIGradient")
	pillPaint.Rotation = 90
	pillPaint.Color = ColorSequence.new(GOLD, GOLD_DEEP)
	pillPaint.Parent = pill
	local pillEdge = Instance.new("UIStroke")
	pillEdge.Thickness = 2.5
	pillEdge.Color = OUTLINE
	pillEdge.Parent = pill
	pill.Parent = sign
	local claim = words("Text", pill, "CLAIM NOW!", UDim2.fromScale(0.88, 0.74), UDim2.fromScale(0.5, 0.5), WHITE, 2.2)
	-- The controller pulls this off when it greys the sign; it has to exist.
	local rainbow = Instance.new("UIGradient")
	rainbow.Name = "Rainbow"
	rainbow.Color = ColorSequence.new(WHITE, GOLD_PALE)
	rainbow.Parent = claim

	-- The chevron, bobbed by AttractionSignController like every other
	-- attraction's arrow (it finds them by this attribute).
	local arrow = words("Arrow", sign, "▼", UDim2.fromScale(0.12, 0.16), UDim2.fromScale(0.5, 0.91), WHITE, 2)
	arrow:SetAttribute(AttractionSign.ARROW_TAG, true)
	arrow:SetAttribute("RestY", 0.91)
end

function GiftChestService.start()
	local template = chestTemplate()
	if not template then
		warn("[GiftChestService] ServerStorage.GameAssets.GiftrewardChest not found - no chest built")
		return
	end

	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local existing = map:FindFirstChild(CHEST_NAME)
	if existing then
		existing:Destroy()
	end

	-- The owner's marker first (Workspace.LobbyMarkers.GiftChest), the config
	-- default second. See LobbyLayout.
	local spot = LobbyLayout.position("GiftChest", MapConfig.HUB.giftChest)
	local model = Instance.new("Model")
	model.Name = CHEST_NAME

	-- THE PODIUM: three gold tiers with lit rims, and a soft gold glow disc
	-- under the whole thing so it reads as a stage, not a pile of drums.
	local glow = prop("Pad", model)
	glow.Shape = Enum.PartType.Cylinder
	glow.Size = Vector3.new(0.3, 17, 17)
	glow.CFrame = CFrame.new(spot.X, 0.16, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
	glow.Material = Enum.Material.Neon
	glow.Color = GOLD_GLOW
	glow.Transparency = 0.6
	local top = 0.3
	for index = #TIERS, 1, -1 do
		top = tier(model, spot, TIERS[index][1], TIERS[index][2], top)
	end

	local chest = template:Clone()
	chest.Name = "Chest"
	chest.Anchored = true
	chest.CanCollide = false
	chest.CanQuery = true -- the prompt needs the part to answer a ray
	chest.CanTouch = false
	chest.CastShadow = true
	local mesh = chest:FindFirstChildWhichIsA("SpecialMesh")
	if mesh then
		mesh.Scale *= CHEST_SCALE
	end
	chest.Size *= CHEST_SCALE
	local restY = top + chest.Size.Y / 2 + 0.2
	chest.CFrame = CFrame.new(spot.X, restY, spot.Z)
	chest.Parent = model
	model.PrimaryPart = chest

	-- THE LIGHT ON IT: three beams from above converging on the chest, and
	-- the gold point glow it always had.
	local focus = Vector3.new(spot.X, top + 0.5, spot.Z)
	spotlight(model, Vector3.new(spot.X - 11, 21, spot.Z - 4), focus)
	spotlight(model, Vector3.new(spot.X, 24, spot.Z - 5), focus)
	spotlight(model, Vector3.new(spot.X + 11, 21, spot.Z - 4), focus)
	local light = Instance.new("PointLight")
	light.Name = "ChestGlow"
	light.Color = GOLD_GLOW
	light.Brightness = 1.8
	light.Range = 18
	light.Shadows = false
	light.Parent = chest

	-- THE SPARKLE: the engine's own star texture rising off the podium, and
	-- the built-in Sparkles on the chest itself.
	local emitterHost = prop("SparkleHost", model)
	emitterHost.Size = Vector3.new(9, 0.2, 9)
	emitterHost.Transparency = 1
	emitterHost.CFrame = CFrame.new(spot.X, top + 0.3, spot.Z)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(GOLD_PALE, GOLD)
	emitter.LightEmission = 1
	emitter.Rate = 9
	emitter.Lifetime = NumberRange.new(1.4, 2.2)
	emitter.Speed = NumberRange.new(1.6, 2.8)
	emitter.SpreadAngle = Vector2.new(25, 25)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.3, 0.75),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-40, 40)
	emitter.Parent = emitterHost
	local sparkles = Instance.new("Sparkles")
	sparkles.Name = "ChestSparkles"
	sparkles.SparkleColor = GOLD_PALE
	sparkles.Parent = chest

	-- THE GIFTS, floating either side.
	for _, spec in GIFTS do
		gift(model, Vector3.new(spot.X + spec[1], spec[2], spot.Z + spec[3]), spec[4])
	end

	banner(chest)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "GiftPrompt"
	prompt.ObjectText = "Free Gift"
	prompt.ActionText = "Open"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Parent = chest

	model.Parent = map

	-- A slow bob and turn. One anchored part, one tween, no per-frame work.
	local rest = chest.CFrame
	TweenService:Create(
		chest,
		TweenInfo.new(1.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ CFrame = rest * CFrame.new(0, 0.6, 0) * CFrame.Angles(0, math.rad(12), 0) }
	):Play()

	local open = Remotes.get("GiftMenuOpen")
	prompt.Triggered:Connect(function(player)
		local now = os.clock()
		if lastOpen[player] and now - lastOpen[player] < OPEN_COOLDOWN then
			return
		end
		lastOpen[player] = now
		-- The client opens ITS existing panel. No reward decision happens here.
		open:FireClient(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastOpen[player] = nil
	end)

	print(`[GiftChestService] gift chest at {spot} opens the group gift panel`)
end

return GiftChestService
