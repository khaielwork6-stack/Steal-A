--!strict
--[[
	ZoneSignService
	A recommended-Speed sign at the entrance of every zone (GDD section 6/phase 6).

	The recommendation is a SOFT gate. Nothing here blocks entry - the sign only
	tells the player what they are walking into, and the guardian tuning does the
	rest. That is what preserves "I almost made it" moments.

	Signs are generated from ZoneConfig rather than authored into the map, so
	changing a gate value never means re-editing geometry.

	WHERE THEY STAND AND WHICH WAY THEY FACE
	One per zone, on the LEFT of the entrance from the approaching player's
	point of view, planted SIGN_LEAD studs BEFORE the zone's near edge and
	turned SIGN_YAW degrees in toward the lane centre.
	The face is drawn on the board's Front (its -Z side), which is the side an
	approaching player sees: they come up the lane from -Z. The old signs sat
	just inside the zone with the face on the Back, so they read only after
	the player had walked past them.

	THE LOOK
	A dark rounded panel with the zone's emoji, number and name across the top,
	"RECOMMENDED SPEED" in small caps, the figure large in the colour of the
	best rarity the zone can produce, and a neon cap in that same colour so the
	lane reads as escalating from a distance. The board part itself is
	invisible; the SurfaceGui's rounded frame is the whole visible sign.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local ZoneSignService = {}

local POST_HEIGHT = 24
local BOARD_SIZE = Vector3.new(34, 14, 1)
--- Studs before the zone's near edge.
local SIGN_LEAD = 16
--- Degrees each board turns in toward the lane centre.
local SIGN_YAW = 20
--- Distance in from the wall face: inside the gate pylon, clear of it.
local SIGN_INSET = 30

local PANEL = Color3.fromRGB(18, 22, 36)
local PANEL_EDGE = Color3.fromRGB(34, 40, 62)
local INK = Color3.fromRGB(240, 244, 252)
local INK_SOFT = Color3.fromRGB(150, 160, 190)
local STARTER = Color3.fromRGB(96, 224, 120)

local function label(parent: Instance, name: string, position: UDim2, size: UDim2, text: string, color: Color3, font: Enum.Font?): TextLabel
	local made = Instance.new("TextLabel")
	made.Name = name
	made.BackgroundTransparency = 1
	made.AnchorPoint = Vector2.new(0.5, 0.5)
	made.Position = position
	made.Size = size
	made.Font = font or Enum.Font.FredokaOne
	made.TextScaled = true
	made.Text = text
	made.TextColor3 = color
	made.TextStrokeTransparency = 0.75
	made.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	made.ZIndex = 2
	made.Parent = parent
	return made
end

local function buildFace(board: BasePart, zone: ZoneConfig.ZoneDef, accent: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.Parent = board

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = PANEL
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.12, 0)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 6
	stroke.Color = accent
	stroke.Transparency = 0.2
	stroke.Parent = panel
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(PANEL_EDGE, PANEL)
	gradient.Parent = panel

	-- A band of the zone colour across the top, under the title.
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.Position = UDim2.fromScale(0, 0)
	band.Size = UDim2.fromScale(1, 0.34)
	band.BackgroundColor3 = accent
	band.BackgroundTransparency = 0.72
	band.BorderSizePixel = 0
	band.Parent = panel
	local bandCorner = Instance.new("UICorner")
	bandCorner.CornerRadius = UDim.new(0.35, 0)
	bandCorner.Parent = band

	label(panel, "Title", UDim2.fromScale(0.5, 0.18), UDim2.fromScale(0.9, 0.22), `{zone.emoji}  {zone.index}. {zone.name}`, INK)

	local gated = zone.recommendedSpeed > 0
	label(panel, "Caption", UDim2.fromScale(0.5, 0.44), UDim2.fromScale(0.8, 0.11), if gated then "RECOMMENDED SPEED" else "NO GUARD PRESSURE", INK_SOFT)
	label(
		panel,
		"Value",
		UDim2.fromScale(0.5, 0.71),
		UDim2.fromScale(0.86, 0.36),
		if gated then NumberFormat.short(zone.recommendedSpeed) else "STARTER ZONE",
		if gated then accent else STARTER
	)
end

local function buildSign(zone: ZoneConfig.ZoneDef, parent: Instance)
	local startZ = MapConfig.zoneStartZ(zone.index)
	local z = startZ - SIGN_LEAD

	local model = Instance.new("Model")
	model.Name = `Sign_{zone.id}`

	-- Wear the colour of the best thing this zone can produce, read from the
	-- rarity ladder rather than from a hand-written zone->rarity table that
	-- would silently disagree with it the first time a band boundary moves.
	local accent = RarityConfig.Colors[RarityConfig.jackpotRarityFor(zone.index)] or RarityConfig.Colors.Common

	-- ONE sign per zone, on the LEFT of the entrance as the player approaches.
	-- They come up the lane along +Z, and a character facing +Z has +X on
	-- its LEFT (Roblox is right-handed: RightVector = Look x Up = -X). The
	-- earlier pass put the board at -X believing that was left; a Play
	-- screenshot from the spawn circle showed it on the right. The gate's
	-- lintel carries the zone's name across the lane; this board carries the
	-- number.
	for _, side in { 1 } do
		local x = side * (MapConfig.LANE_HALF - SIGN_INSET)
		-- Turned in toward the centre line: the left sign looks a little
		-- right, the right sign a little left. Front (-Z) faces the approach.
		local facing = CFrame.new(x, 0, z) * CFrame.Angles(0, side * math.rad(SIGN_YAW), 0)

		local post = Instance.new("Part")
		post.Name = "Post"
		post.Size = Vector3.new(1.4, POST_HEIGHT, 1.4)
		post.CFrame = facing * CFrame.new(0, POST_HEIGHT / 2, 0)
		post.Anchored = true
		post.CanCollide = false
		post.CastShadow = false
		post.Color = Color3.fromRGB(46, 50, 68)
		post.Material = Enum.Material.SmoothPlastic
		post.Parent = model

		local board = Instance.new("Part")
		board.Name = "Board"
		board.Size = BOARD_SIZE
		board.CFrame = facing * CFrame.new(0, POST_HEIGHT + BOARD_SIZE.Y / 2 - 1, 0)
		board.Anchored = true
		board.CanCollide = false
		board.CanQuery = false
		board.CastShadow = false
		board.Transparency = 1
		board.Parent = model
		buildFace(board, zone, accent)

		-- A rarity-coloured cap so zones read as escalating from a distance.
		local cap = Instance.new("Part")
		cap.Name = "Cap"
		cap.Size = Vector3.new(BOARD_SIZE.X - 4, 1.2, 1.2)
		cap.CFrame = facing * CFrame.new(0, POST_HEIGHT + BOARD_SIZE.Y - 0.2, 0)
		cap.Anchored = true
		cap.CanCollide = false
		cap.CastShadow = false
		cap.Material = Enum.Material.Neon
		cap.Color = accent
		cap.Parent = model
	end

	model.Parent = parent
end

function ZoneSignService.start()
	local map = workspace:WaitForChild("Map", 20)

	local existing = map:FindFirstChild("ZoneSigns")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "ZoneSigns"
	folder.Parent = map

	for _, zone in ZoneConfig.Zones do
		buildSign(zone, folder)
	end

	print(`[ZoneSignService] {ZoneConfig.COUNT} zone signs posted`)
end

return ZoneSignService
