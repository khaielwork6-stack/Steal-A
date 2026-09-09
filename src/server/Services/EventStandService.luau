--!strict
--[[
	EventStandService
	The "Next Update - Notify Here!" stand in the lobby.

	THE OWNER'S PIECES. The board is the model dropped into the place as
	`NextUpdate` (one part, the studded board); its face is the `NextUpdate`
	SurfaceGui the UI pack ships under MainUI.Surface/Billboards, and the
	floating "Next Update! / Notify Here!" title is the pack's billboard from
	the same folder. This service finds those, stands the board on two posts
	beside the lobby spawn facing it, and adds the prompt. Nothing is drawn
	from scratch and nothing is duplicated: the board is MOVED, not cloned.

	THE PROMPT is an ordinary ProximityPrompt named NotifyPrompt. Holding E
	on it is answered on the CLIENT (EventStandController), because the RSVP
	prompt is a local-player API: SocialService:PromptRsvpToEventAsync opens
	Roblox's own follow-this-event dialog for GameConfig.NEXT_UPDATE_EVENT_ID.
	The server never needs to know who followed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LobbyLayout = require(ReplicatedStorage.Shared.LobbyLayout)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local EventStandService = {}

--- Where the stand goes: composed with the rest of the hub in MapConfig.HUB,
--- right of the spawn circle and turned to face it. The board's bottom edge
--- sits BOARD_LIFT high on two posts.
--- Both resolved at start from Workspace.LobbyMarkers (EventStand, Spawn),
--- falling back to MapConfig.HUB. See LobbyLayout.
local function standPosition(): Vector3
	return LobbyLayout.position("EventStand", MapConfig.HUB.eventStand)
end
local function faceToward(): Vector3
	return LobbyLayout.position("Spawn", MapConfig.HUB.spawn)
end
local BOARD_LIFT = 3.4
--- Gap between the wall face and the board's back, along the wall's normal.
--- Two studs forward of the wall: clear of the wall's own trim, readable
--- from the spawn circle, and the Notify prompt reachable without pressing
--- the character into the wall.
local WALL_STANDOFF = 4.0
local POST_COLOR = Color3.fromRGB(46, 50, 68)

local PROMPT_RANGE = 14
local PROMPT_HOLD = 0.35

local function findBoardModel(): Model?
	for _, container in { workspace, workspace:FindFirstChild("Folder") } do
		local found = container and container:FindFirstChild("NextUpdate")
		if found and found:IsA("Model") and found:FindFirstChildWhichIsA("BasePart") then
			return found
		end
	end
	return nil
end

local function billboardsFolder(): Instance?
	local ui = StarterGui:FindFirstChild("MainUI")
	return ui and ui:FindFirstChild("Surface/Billboards")
end

--- The pack's board face, if it ships; otherwise nil and the board stays as
--- authored.
local function findFace(): SurfaceGui?
	local folder = billboardsFolder()
	local gui = folder and folder:FindFirstChild("NextUpdate")
	return if gui and gui:IsA("SurfaceGui") then gui else nil
end

--- The pack's "Next Update! / Notify Here!" billboard: the one in Titles
--- whose text says so.
local function findTitle(): BillboardGui?
	local folder = billboardsFolder()
	local titles = folder and folder:FindFirstChild("Titles")
	if not titles then
		return nil
	end
	for _, gui in titles:GetChildren() do
		if gui:IsA("BillboardGui") then
			for _, label in gui:GetDescendants() do
				if label:IsA("TextLabel") and string.find(label.Text, "Next Update", 1, true) then
					return gui
				end
			end
		end
	end
	return nil
end

--- A quiet sparkle off the face of the board, cloned from the Shiny
--- mutation's authored effect (ReplicatedStorage.GameAssets.Mutations.Shiny).
--- The original is only ever read; the copies are throttled to a few
--- particles a second, sized to the board and pointed off its front face.
local SHINE_RATE_SCALE = 0.35
local SHINE_RATE_CAP = 6
local SHINE_SIZE_SCALE = 1.8

local function tameShine(emitter: ParticleEmitter)
	emitter.Enabled = true
	emitter.Rate = math.min(emitter.Rate * SHINE_RATE_SCALE, SHINE_RATE_CAP)
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.LightEmission = math.min(emitter.LightEmission, 0.6)
	local keys = {}
	for _, key in emitter.Size.Keypoints do
		table.insert(keys, NumberSequenceKeypoint.new(key.Time, key.Value * SHINE_SIZE_SCALE, key.Envelope * SHINE_SIZE_SCALE))
	end
	emitter.Size = NumberSequence.new(keys)
end

--- The board's picture. The pack's SurfaceGui ships an advert for the UI
--- pack itself ("DM ... TO BUY"), which is not this game's sign. With
--- GameConfig.NEXT_UPDATE_IMAGE set, that image goes on the face; without
--- one, a drawn "NEXT UPDATE" face in the HUD's own kit replaces it.
local function dressFace(gui: SurfaceGui)
	local frame = gui:FindFirstChildWhichIsA("Frame")
	local picture = frame and frame:FindFirstChildWhichIsA("ImageLabel")
	local image = GameConfig.NEXT_UPDATE_IMAGE
	if picture and type(image) == "number" and image > 0 then
		picture.Image = `rbxassetid://{image}`
		return
	end
	if picture then
		picture:Destroy()
	end
	local host: Instance = frame or gui
	if frame then
		frame.BackgroundTransparency = 0
		frame.BackgroundColor3 = Color3.fromRGB(16, 22, 44)
		frame.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 18)
		corner.Parent = frame
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color = ColorSequence.new(Color3.fromRGB(44, 58, 104), Color3.fromRGB(18, 24, 48))
		gradient.Parent = frame
		local studs = Instance.new("ImageLabel")
		studs.Name = "Studs"
		studs.BackgroundTransparency = 1
		studs.Image = "rbxassetid://76728843491214"
		studs.ImageTransparency = 0.86
		studs.ScaleType = Enum.ScaleType.Tile
		studs.TileSize = UDim2.fromOffset(40, 40)
		studs.Size = UDim2.fromScale(1, 1)
		studs.ZIndex = 1
		studs.Parent = frame
	end
	local function text(name: string, value: string, y: number, h: number, color: Color3, size: number)
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, y)
		label.Size = UDim2.fromScale(0.92, h)
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.Text = value
		label.TextColor3 = color
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.fromRGB(12, 16, 32)
		label.ZIndex = 3
		label.Parent = host
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = size
		limit.Parent = label
	end
	text("Bell", "🔔", 0.2, 0.26, Color3.fromRGB(255, 226, 120), 110)
	text("Headline", "NEXT UPDATE!", 0.5, 0.3, Color3.fromRGB(255, 255, 255), 120)
	text("Sub", "Notify me when it drops", 0.78, 0.18, Color3.fromRGB(126, 236, 255), 70)
end

--- One additive sparkle off the board's face. The Shiny mutation's emitters
--- were borrowed here before; one of their textures fails to stream on some
--- clients and a failed particle texture draws as a BLACK square, which is
--- the flashing black flake the stand kept showing. This is the engine's own
--- sparkle texture (the one the treadmill streaks and the gift chest use)
--- at full LightEmission, so it can only ever add light.
local function addShine(board: BasePart)
	for _, child in board:GetChildren() do
		if child:GetAttribute("StandShine") then
			child:Destroy()
		end
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "StandShine"
	emitter:SetAttribute("StandShine", true)
	emitter.Texture = "rbxassetid://241594419"
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 240, 170), Color3.fromRGB(255, 255, 255))
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(0.5, 0.6), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(1.2, 2)
	emitter.Rate = SHINE_RATE_CAP
	emitter.Speed = NumberRange.new(0.6, 1.4)
	emitter.SpreadAngle = Vector2.new(25, 25)
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Enabled = true
	emitter.Parent = board
end

local function post(parent: Instance, at: CFrame, height: number)
	local part = Instance.new("Part")
	part.Name = "Post"
	part.Size = Vector3.new(1.2, height, 1.2)
	part.CFrame = at
	part.Anchored = true
	part.CanCollide = true
	part.CastShadow = false
	part.Color = POST_COLOR
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = parent
end

function EventStandService.start()
	local model = findBoardModel()
	if not model then
		warn("[EventStandService] no NextUpdate board in the place - the stand is not built")
		return
	end
	local board = model:FindFirstChildWhichIsA("BasePart") :: BasePart
	local map = workspace:FindFirstChild("Map") or workspace

	model.Name = "NextUpdateStand"
	model.Parent = map
	board.Name = "Board"
	board.Anchored = true
	board.CanCollide = true
	-- The board was authored with Studs on every side, and a studded surface
	-- draws OVER a SurfaceGui: the face never showed. Smooth all round.
	board.FrontSurface = Enum.SurfaceType.Smooth
	board.BackSurface = Enum.SurfaceType.Smooth
	board.TopSurface = Enum.SurfaceType.Smooth
	board.BottomSurface = Enum.SurfaceType.Smooth
	board.LeftSurface = Enum.SurfaceType.Smooth
	board.RightSurface = Enum.SurfaceType.Smooth

	-- AGAINST THE WALL. The marker says roughly where and which way; a ray
	-- cast back from it finds the wall behind and the board is seated flat on
	-- that face, a hair proud of it, facing straight out along the wall's
	-- normal - so it can never float, never sit at an odd angle to the wall
	-- and never intersect it, wherever the marker is nudged. With no wall
	-- within reach it stands where the marker is, facing the way it faces.
	local height = board.Size.Y
	local standAt = standPosition()
	local marker = LobbyLayout.frame("EventStand", CFrame.lookAt(standAt, standAt + Vector3.new(0, 0, -40)))
	local facing = Vector3.new(marker.LookVector.X, 0, marker.LookVector.Z)
	if facing.Magnitude < 0.01 then
		local toward = faceToward()
		facing = Vector3.new(toward.X - standAt.X, 0, toward.Z - standAt.Z)
	end
	facing = if facing.Magnitude > 0.01 then facing.Unit else Vector3.new(0, 0, -1)
	local centre = Vector3.new(standAt.X, BOARD_LIFT + height / 2, standAt.Z)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	local hit = workspace:Raycast(centre, -facing * 24, params)
	if hit and hit.Instance.Anchored then
		local normal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
		if normal.Magnitude > 0.01 then
			facing = normal.Unit
		end
		-- A clear half stud off the wall face. At 0.15 the board's back face
		-- and the studded wall fought for the same pixels and shimmered.
		centre = hit.Position + facing * (board.Size.Z / 2 + WALL_STANDOFF)
		centre = Vector3.new(centre.X, BOARD_LIFT + height / 2, centre.Z)
	end
	board.CFrame = CFrame.lookAt(centre, centre + facing)
	model.PrimaryPart = board

	local half = board.Size.X / 2 - 1.5
	for _, side in { -1, 1 } do
		local footY = (BOARD_LIFT + height * 0.6) / 2
		post(model, board.CFrame * CFrame.new(side * half, -(BOARD_LIFT + height / 2) + footY, 0), BOARD_LIFT + height * 0.6)
	end

	for _, child in board:GetChildren() do
		if child:IsA("SurfaceGui") or child:IsA("BillboardGui") or child:IsA("ProximityPrompt") then
			child:Destroy()
		end
	end

	local face = findFace()
	if face then
		local clone = face:Clone()
		clone.Name = "Face"
		clone.Face = Enum.NormalId.Front
		clone.Adornee = nil
		clone.Enabled = true
		clone.LightInfluence = 0
		dressFace(clone)
		clone.Parent = board
	end

	local title = findTitle()
	if title then
		local clone = title:Clone()
		clone.Name = "Title"
		clone.Adornee = board
		clone.StudsOffset = Vector3.new(0, height / 2 + 4, 0)
		clone.MaxDistance = 120
		clone.Enabled = true
		clone.Parent = board
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "NotifyPrompt"
	prompt.ActionText = "Notify Me"
	prompt.ObjectText = "Next Update"
	prompt.HoldDuration = PROMPT_HOLD
	prompt.MaxActivationDistance = PROMPT_RANGE
	prompt.RequiresLineOfSight = false
	prompt.Parent = board

	addShine(board)

	print(`[EventStandService] stand posted at {board.Position} for event {GameConfig.NEXT_UPDATE_EVENT_ID}`)
end

return EventStandService
