--!strict
--[[
	GadgetStoreService
	The physical GADGETS stand in the lobby (round3-gameplay).

	A market stall built from parts in the style of the Trail Shop booth: a
	platform, four posts, a counter with a neon trim, a back wall, a striped
	awning, a "GADGETS" board, and three pedestals on the counter each showing
	one gadget's model (the same builder as the Backpack Tool,
	GadgetService.buildDisplay). An AttractionSign billboard floats over it.

	THE PROMPT ONLY OPENS A PANEL. `GadgetStorePrompt` ("Shop", hold
	GadgetConfig.STORE_PROMPT_HOLD) is answered on the CLIENT
	(GadgetStoreController), which opens the gadget panel; every purchase goes
	through the existing GadgetRequest("buy", key), validated and priced by
	GadgetService. Nothing here touches Cash or the profile.

	WHERE IT STANDS
	  1. Workspace.LobbyMarkers.<GadgetConfig.STORE_MARKER> ("GadgetStore") if
	     the owner has placed one: its position and facing win (the front of
	     the stall is the marker's LookVector).
	  2. Otherwise the first of CANDIDATES whose footprint (plus the customer
	     space in front) is clear of every visible or colliding part already
	     standing - the trail booth, gift chest, Slap cage, Guardian pedestals,
	     event stand and every leaderboard are all built before this runs.
	     Candidates face the spawn circle.
	  3. None free: nothing is built, and a warning names the marker to add.

	MOTION is client-side (GadgetStoreController spins the displays, still
	under Reduced Effects / Low Graphics); the server builds everything
	anchored and still.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttractionSign = require(ReplicatedStorage.Shared.Util.AttractionSign)
local GadgetConfig = require(ReplicatedStorage.Shared.Config.GadgetConfig)
local LobbyLayout = require(ReplicatedStorage.Shared.LobbyLayout)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local GadgetService = require(script.Parent.GadgetService)

local GadgetStoreService = {}

GadgetStoreService.MODEL_NAME = "GadgetStore"
GadgetStoreService.PROMPT_NAME = "GadgetStorePrompt"

-- Footprint (local): X across the front, Z front (-) to back (+).
local WIDTH = 16
local DEPTH = 9
local POST_HEIGHT = 10.5
--- Studs in front of the counter kept clear for customers (checked, and
--- where the prompt stands).
local FRONT_CLEAR = 7
local COUNTER_Z = -DEPTH / 2 + 1.1
local COUNTER_TOP_Y = 3.4
local DISPLAY_SCALE = 2.2
local DISPLAY_HEIGHT = 0.6 -- studs between the pedestal top and the model
local PEDESTAL_X = { -4.6, 0, 4.6 }
local AWNING_PITCH = 8 -- degrees; the front lip is the high edge
--- Floor to the top of the roof board, for the free-space check.
local TOTAL_HEIGHT = 16

local NAVY = Color3.fromRGB(30, 36, 70)
local NAVY_DARK = Color3.fromRGB(18, 22, 44)
local CYAN = Color3.fromRGB(96, 230, 255)
local AWNING_LIGHT = Color3.fromRGB(236, 244, 252)
local STEEL = Color3.fromRGB(120, 128, 150)
local GOLD = Color3.fromRGB(255, 208, 70)

--- Fallback spots on the apron (Y = floor), clear of the walkway from the
--- spawn circle to the lane mouth and of the treadmill row (Z <= -51):
--- the +X wing between the Guardian pedestal (104, -24) and the Speed board
--- (178, -12) first, then its mirror, then nearer the centre.
local CANDIDATES: { Vector3 } = {
	Vector3.new(150, 0, -38),
	Vector3.new(-150, 0, -40),
	Vector3.new(150, 0, -28),
	Vector3.new(-62, 0, -44),
	Vector3.new(62, 0, -44),
}

local model: Model? = nil
local builtAt: CFrame? = nil

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance, collide: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = collide
	p.CanQuery = collide
	p.CanTouch = false
	p.CastShadow = collide
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- A floor-level CFrame at `position` whose LookVector points at the spawn.
local function facingSpawn(position: Vector3): CFrame
	local spawn = LobbyLayout.position("Spawn", MapConfig.HUB.spawn)
	local flat = Vector3.new(spawn.X, 0, spawn.Z)
	local at = Vector3.new(position.X, 0, position.Z)
	if (flat - at).Magnitude < 0.5 then
		return CFrame.new(at)
	end
	return CFrame.lookAt(at, flat)
end

--- True when nothing visible or colliding (other than the floor and the
--- markers) stands in the stall's footprint plus the customer space.
function GadgetStoreService.spotIsFree(base: CFrame, ignore: { Instance }?): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip: { Instance } = {}
	for _, name in { LobbyLayout.FOLDER_NAME, "Terrain", "GadgetFx" } do
		local found = workspace:FindFirstChild(name)
		if found then
			table.insert(skip, found)
		end
	end
	local extras: { Instance } = ignore or {}
	for _, extra in extras do
		table.insert(skip, extra)
	end
	params.FilterDescendantsInstances = skip
	-- From a stud above the floor (the floor, paint and flat discs never
	-- count) to the top of the roof board, padded two studs all round.
	local depth = DEPTH + FRONT_CLEAR + 4
	local box = Vector3.new(WIDTH + 4, TOTAL_HEIGHT, depth)
	local centre = base * CFrame.new(0, 1 + TOTAL_HEIGHT / 2, -FRONT_CLEAR / 2)
	local ok, hits = pcall(function()
		return workspace:GetPartBoundsInBox(centre, box, params)
	end)
	if not ok then
		return false
	end
	for _, hit in hits :: { BasePart } do
		-- Invisible, non-colliding helpers (safe volumes, triggers) do not block.
		if hit.Transparency < 1 or hit.CanCollide then
			return false
		end
	end
	return true
end

--- Where the stall stands, or nil.
local function chooseFrame(): (CFrame?, string)
	local marker = LobbyLayout.cframe(GadgetConfig.STORE_MARKER)
	if marker then
		-- Flat on the floor, facing where the marker faces.
		local look = Vector3.new(marker.LookVector.X, 0, marker.LookVector.Z)
		local at = Vector3.new(marker.Position.X, 0, marker.Position.Z)
		if look.Magnitude < 0.01 then
			return CFrame.new(at), "marker"
		end
		return CFrame.lookAt(at, at + look.Unit), "marker"
	end
	for index, position in CANDIDATES do
		local frame = facingSpawn(position)
		if GadgetStoreService.spotIsFree(frame) then
			return frame, `candidate {index}`
		end
	end
	return nil, "none free"
end

local function buildDisplays(parent: Instance, base: CFrame)
	for index, key in GadgetConfig.Order do
		local def = GadgetConfig.Gadgets[key]
		local x = PEDESTAL_X[index] or 0
		local pedestalAt = base * CFrame.new(x, COUNTER_TOP_Y + 0.2 + 0.45, COUNTER_Z)
		local pedestal = part(`Pedestal_{key}`, Vector3.new(0.9, 2.6, 2.6), pedestalAt * CFrame.Angles(0, 0, math.rad(90)), NAVY_DARK, Enum.Material.Metal, parent, false)
		pedestal.Shape = Enum.PartType.Cylinder
		local ring = part(`PedestalRing_{key}`, Vector3.new(0.2, 2.9, 2.9), (pedestalAt + Vector3.new(0, 0.42, 0)) * CFrame.Angles(0, 0, math.rad(90)), def.color, Enum.Material.Neon, parent, false)
		ring.Shape = Enum.PartType.Cylinder

		local display = GadgetService.buildDisplay(key)
		if display then
			display.Name = `Display_{key}`
			display:ScaleTo(DISPLAY_SCALE)
			display:PivotTo(CFrame.new(pedestalAt.Position) * base.Rotation)
			-- Seat it on the box, not the pivot (a tool's pivot is its grip):
			-- bottom DISPLAY_HEIGHT above the pedestal top, centred over it.
			local box, size = display:GetBoundingBox()
			local centre = pedestalAt.Position + Vector3.new(0, 0.45 + DISPLAY_HEIGHT + size.Y / 2, 0)
			display:PivotTo(display:GetPivot() + (centre - box.Position))
			display:SetAttribute("GadgetDisplay", key)
			display:SetAttribute("SpinOrigin", display:GetPivot())
			display.Parent = parent
		end
	end
end

local function build(map: Instance, base: CFrame): Model
	local stall = Instance.new("Model")
	stall.Name = GadgetStoreService.MODEL_NAME

	-- Platform and back wall.
	part("Platform", Vector3.new(WIDTH, 0.6, DEPTH), base * CFrame.new(0, 0.3, 0), NAVY_DARK, Enum.Material.DiamondPlate, stall, true)
	part("BackWall", Vector3.new(WIDTH, POST_HEIGHT - 0.6, 0.6), base * CFrame.new(0, 0.6 + (POST_HEIGHT - 0.6) / 2, DEPTH / 2 - 0.3), NAVY, Enum.Material.SmoothPlastic, stall, true)
	-- A wall stripe and a shelf of spare boxes, so the stall has an inside.
	part("WallStripe", Vector3.new(WIDTH - 0.4, 0.5, 0.1), base * CFrame.new(0, 5.2, DEPTH / 2 - 0.65), CYAN, Enum.Material.Neon, stall, false)
	part("Shelf", Vector3.new(WIDTH - 2, 0.3, 1.4), base * CFrame.new(0, 4.2, DEPTH / 2 - 1.3), STEEL, Enum.Material.Metal, stall, false)
	for index, x in { -5, -2.2, 1.6, 4.8 } do
		local color = GadgetConfig.Gadgets[GadgetConfig.Order[(index - 1) % #GadgetConfig.Order + 1]].color
		part(`Crate{index}`, Vector3.new(1.6, 1.2, 1.1), base * CFrame.new(x, 4.95, DEPTH / 2 - 1.3), color, Enum.Material.SmoothPlastic, stall, false)
	end

	-- Posts.
	for _, corner in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		part("Post", Vector3.new(0.9, POST_HEIGHT, 0.9), base * CFrame.new(corner[1] * (WIDTH / 2 - 0.45), POST_HEIGHT / 2, corner[2] * (DEPTH / 2 - 0.45)), STEEL, Enum.Material.Metal, stall, true)
	end

	-- Counter with a neon trim along its front.
	part("CounterBody", Vector3.new(WIDTH - 1.8, 3, 1.8), base * CFrame.new(0, 0.6 + 1.5 - 0.1, COUNTER_Z), NAVY, Enum.Material.SmoothPlastic, stall, true)
	part("CounterTop", Vector3.new(WIDTH - 1.2, 0.4, 2.4), base * CFrame.new(0, COUNTER_TOP_Y, COUNTER_Z), STEEL, Enum.Material.Metal, stall, true)
	part("CounterTrim", Vector3.new(WIDTH - 1.8, 0.35, 0.1), base * CFrame.new(0, 2.5, COUNTER_Z - 0.95), CYAN, Enum.Material.Neon, stall, false)
	for index, key in GadgetConfig.Order do
		local def = GadgetConfig.Gadgets[key]
		part(`Swatch_{key}`, Vector3.new(2.4, 0.9, 0.1), base * CFrame.new(PEDESTAL_X[index] or 0, 1.5, COUNTER_Z - 0.95), def.color, Enum.Material.Neon, stall, false)
	end

	-- Striped awning rising toward the front (like the Trail Shop's), with a
	-- scalloped edge hanging from its front lip. The back edge stays above the
	-- post tops.
	local stripCount = 9
	local span = WIDTH + 1.4
	local stripWidth = span / stripCount
	local awningDepth = DEPTH + 3
	local pitch = math.rad(AWNING_PITCH)
	local awningY = POST_HEIGHT + 0.9
	local awningZ = -0.6
	local frontY = awningY + awningDepth / 2 * math.sin(pitch)
	local frontZ = awningZ - awningDepth / 2 * math.cos(pitch)
	for index = 1, stripCount do
		local x = -span / 2 + stripWidth * (index - 0.5)
		local color = if index % 2 == 1 then CYAN else AWNING_LIGHT
		part("Awning", Vector3.new(stripWidth + 0.02, 0.28, awningDepth), base * CFrame.new(x, awningY, awningZ) * CFrame.Angles(pitch, 0, 0), color, Enum.Material.Fabric, stall, false)
		part("Scallop", Vector3.new(stripWidth + 0.02, 1.1, 0.28), base * CFrame.new(x, frontY - 0.6, frontZ), color, Enum.Material.Fabric, stall, false)
	end

	-- The GADGETS board stands on the awning's front lip, above the displays
	-- (never in front of them). The customer is on the stall's -Z side, which
	-- is a part's FRONT face.
	local board = part("Board", Vector3.new(WIDTH - 2, 2.6, 0.5), base * CFrame.new(0, frontY + 1.45, frontZ + 0.4), NAVY_DARK, Enum.Material.SmoothPlastic, stall, false)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 48
	gui.LightInfluence = 0
	gui.Adornee = board
	gui.Parent = board
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(0.94, 0.86)
	title.Position = UDim2.fromScale(0.03, 0.07)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = CYAN
	title.TextStrokeTransparency = 0
	title.TextStrokeColor3 = Color3.fromRGB(6, 10, 30)
	title.Text = "GADGETS"
	title.Parent = gui
	local trim = part("BoardTrim", Vector3.new(WIDTH - 1.6, 3, 0.3), board.CFrame * CFrame.new(0, 0, 0.2), GOLD, Enum.Material.SmoothPlastic, stall, false)
	trim.CastShadow = false

	buildDisplays(stall, base)

	-- The prompt, where a customer stands in front of the counter.
	local anchor = part("PromptAnchor", Vector3.new(1, 1, 1), base * CFrame.new(0, 3, COUNTER_Z - 3), NAVY, Enum.Material.SmoothPlastic, stall, false)
	anchor.Transparency = 1
	anchor.CastShadow = false
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = GadgetStoreService.PROMPT_NAME
	prompt.ActionText = "Shop"
	prompt.ObjectText = "Gadgets"
	prompt.HoldDuration = GadgetConfig.STORE_PROMPT_HOLD
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Parent = anchor

	-- The floating title, the same component as every other lobby attraction.
	-- Anchored above the board, so the billboard never covers it.
	local signAnchor = part("SignAnchor", Vector3.new(1, 1, 1), base * CFrame.new(0, frontY + 4, 0), NAVY, Enum.Material.SmoothPlastic, stall, false)
	signAnchor.Transparency = 1
	signAnchor.CastShadow = false
	AttractionSign.build(signAnchor, {
		title = "Gadgets",
		subtitle = "SMOKE · JAMMER · HOOK",
		accent = CYAN,
		height = 5.2,
		width = 17,
	})

	stall:SetAttribute("PromptName", GadgetStoreService.PROMPT_NAME)
	stall.PrimaryPart = stall:FindFirstChild("Platform") :: BasePart
	stall.Parent = map
	return stall
end

--- Studio / tests: the built stall and where it stands.
function GadgetStoreService.get(): (Model?, CFrame?)
	local current = model
	if current and current.Parent then
		return current, builtAt
	end
	return nil, nil
end

function GadgetStoreService.start()
	local map = workspace:WaitForChild("Map", 20)
	if not map then
		warn("[GadgetStoreService] no Map - the gadget stand is not built.")
		return
	end
	local stale = map:FindFirstChild(GadgetStoreService.MODEL_NAME)
	if stale then
		stale:Destroy()
	end
	local frame, source = chooseFrame()
	if not frame then
		warn(`[GadgetStoreService] no free spot for the gadget stand - add a part named "{GadgetConfig.STORE_MARKER}" under Workspace.{LobbyLayout.FOLDER_NAME}.`)
		return
	end
	local ok, result = pcall(build, map, frame)
	if not ok then
		warn(`[GadgetStoreService] building the stand failed: {result}`)
		return
	end
	model = result
	builtAt = frame
	print(`[GadgetStoreService] gadget stand at {math.floor(frame.Position.X)}, {math.floor(frame.Position.Z)} ({source})`)
end

return GadgetStoreService
