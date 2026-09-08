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
	part) is cloned, stood on a glowing disc and dressed with the FREE! sign,
	sparkles and a light. Nothing is authored here that the owner already
	supplied, and no asset id is invented.

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

local GiftChestService = {}

local CHEST_NAME = "GiftChest"
--- Studs across, for the chest itself. The supplied mesh is small.
local CHEST_SCALE = 3.4
local DISC_COLOR = Color3.fromRGB(120, 255, 140)
local FREE_COLOR = Color3.fromRGB(140, 255, 150)
--- Seconds a player must wait between opens. One menu per press.
local OPEN_COOLDOWN = 1.2

local lastOpen: { [Player]: number } = {}

local function chestTemplate(): BasePart?
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local found = assets and assets:FindFirstChild("GiftrewardChest")
	return if found and found:IsA("BasePart") then found else nil
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

	-- THE GLOWING PAD. A flat disc under the chest, so it reads as a thing to
	-- walk up to rather than a prop someone left in the plaza.
	local disc = Instance.new("Part")
	disc.Name = "Pad"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.4, 13, 13)
	disc.CFrame = CFrame.new(spot.X, 0.35, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	disc.Material = Enum.Material.Neon
	disc.Color = DISC_COLOR
	disc.Transparency = 0.35
	disc.Parent = model

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
	local restY = chest.Size.Y / 2 + 0.6
	chest.CFrame = CFrame.new(spot.X, restY, spot.Z) * CFrame.Angles(0, math.rad(180), 0)
	chest.Parent = model
	model.PrimaryPart = chest

	-- Sparkles and a light: built-in effects, no texture id to go missing.
	local sparkles = Instance.new("Sparkles")
	sparkles.Name = "ChestSparkles"
	sparkles.SparkleColor = Color3.fromRGB(255, 240, 150)
	sparkles.Parent = chest

	local light = Instance.new("PointLight")
	light.Name = "ChestGlow"
	light.Color = FREE_COLOR
	light.Brightness = 1.6
	light.Range = 16
	light.Shadows = false
	light.Parent = chest

	-- FREE! over the top, sized in studs so it is the same on every screen.
	local sign = Instance.new("BillboardGui")
	sign.Name = "FreeSign"
	sign.Size = UDim2.fromScale(9, 3.2)
	sign.StudsOffsetWorldSpace = Vector3.new(0, chest.Size.Y / 2 + 3.4, 0)
	sign.AlwaysOnTop = false
	sign.LightInfluence = 0
	sign.MaxDistance = 220
	sign.Adornee = chest
	sign.Parent = chest

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = "FREE!"
	label.TextColor3 = FREE_COLOR
	label.TextStrokeTransparency = 0.1
	label.TextStrokeColor3 = Color3.fromRGB(10, 40, 16)
	label.Parent = sign

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

	-- A slow bob and turn. One anchored model, two tweens, no per-frame work.
	local rest = chest.CFrame
	local bob = TweenService:Create(
		chest,
		TweenInfo.new(1.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ CFrame = rest * CFrame.new(0, 0.7, 0) * CFrame.Angles(0, math.rad(12), 0) }
	)
	bob:Play()

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
