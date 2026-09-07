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
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)

local EventStandService = {}

--- Where the stand goes: composed with the rest of the hub in MapConfig.HUB,
--- right of the spawn circle and turned to face it. The board's bottom edge
--- sits BOARD_LIFT high on two posts.
local STAND_POSITION = MapConfig.HUB.eventStand
local FACE_TOWARD = MapConfig.HUB.spawn
local BOARD_LIFT = 3.4
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

	-- Stood on the floor, facing the spawn. lookAt points the part's -Z at
	-- the target, which is the face a SurfaceGui on Front draws on.
	local height = board.Size.Y
	local centre = STAND_POSITION + Vector3.new(0, BOARD_LIFT + height / 2, 0)
	board.CFrame = CFrame.lookAt(centre, Vector3.new(FACE_TOWARD.X, centre.Y, FACE_TOWARD.Z))
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

	print(`[EventStandService] stand posted at {STAND_POSITION} for event {GameConfig.NEXT_UPDATE_EVENT_ID}`)
end

return EventStandService
