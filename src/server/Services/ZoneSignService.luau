--!strict
--[[
	ZoneSignService
	A recommended-Speed sign at the entrance of every zone (GDD section 6/phase 6).

	The recommendation is a SOFT gate. Nothing here blocks entry - the sign only
	tells the player what they are walking into, and the guardian tuning does the
	rest. That is what preserves "I almost made it" moments.

	Signs are generated from ZoneConfig rather than authored into the map, so
	changing a gate value never means re-editing geometry.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local ZoneSignService = {}

local POST_HEIGHT = 26

local function buildSign(zone: ZoneConfig.ZoneDef, parent: Instance)
	local startZ = MapConfig.zoneStartZ(zone.index)

	local model = Instance.new("Model")
	model.Name = `Sign_{zone.id}`

	-- One sign each side of the lane so it reads whichever way you run past.
	for _, sign in { -1, 1 } do
		local x = sign * (MapConfig.LANE_HALF - 16)

		local post = Instance.new("Part")
		post.Name = "Post"
		post.Size = Vector3.new(1.6, POST_HEIGHT, 1.6)
		post.Position = Vector3.new(x, POST_HEIGHT / 2, startZ + 2)
		post.Anchored = true
		post.CanCollide = false
		post.CastShadow = false
		post.Color = Color3.fromRGB(120, 82, 48)
		post.Material = Enum.Material.Wood
		post.Parent = model

		local board = Instance.new("Part")
		board.Name = "Board"
		board.Size = Vector3.new(30, 12, 1)
		board.Position = Vector3.new(x, POST_HEIGHT + 5, startZ + 2)
		board.Anchored = true
		board.CanCollide = false
		board.CastShadow = false
		board.Color = Color3.fromRGB(250, 248, 238)
		board.Material = Enum.Material.SmoothPlastic
		board.Parent = model

		-- Faces back down the lane, toward an approaching player.
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Face"
		gui.Face = Enum.NormalId.Back
		gui.CanvasSize = Vector2.new(600, 240)
		gui.LightInfluence = 0
		gui.Parent = board

		local title = Instance.new("TextLabel")
		title.Size = UDim2.fromScale(1, 0.5)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.FredokaOne
		title.TextScaled = true
		title.TextColor3 = Color3.fromRGB(38, 44, 60)
		title.Text = `{string.format("%02d", zone.index)}. {zone.name}`
		title.Parent = gui

		local speed = Instance.new("TextLabel")
		speed.Size = UDim2.fromScale(1, 0.5)
		speed.Position = UDim2.fromScale(0, 0.5)
		speed.BackgroundTransparency = 1
		speed.Font = Enum.Font.FredokaOne
		speed.TextScaled = true
		speed.TextColor3 = if zone.recommendedSpeed > 0
			then Color3.fromRGB(206, 62, 78)
			else Color3.fromRGB(58, 158, 74)
		speed.Text = if zone.recommendedSpeed > 0
			then `Speed {NumberFormat.short(zone.recommendedSpeed)}`
			else "Starter Zone"
		speed.Parent = gui

		-- A rarity-coloured cap so zones read as escalating from a distance.
		local cap = Instance.new("Part")
		cap.Name = "Cap"
		cap.Size = Vector3.new(30, 1.4, 1.4)
		cap.Position = Vector3.new(x, POST_HEIGHT + 11.5, startZ + 2)
		cap.Anchored = true
		cap.CanCollide = false
		cap.CastShadow = false
		cap.Material = Enum.Material.Neon
		cap.Color = RarityConfig.Colors[
			if zone.index <= 2 then "Common"
			elseif zone.index <= 4 then "Uncommon"
			elseif zone.index <= 6 then "Rare"
			elseif zone.index <= 8 then "Epic"
			elseif zone.index <= 10 then "Legendary"
			else "Secret"
		]
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
