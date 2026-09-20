--!strict
--[[
	HeldItemFxController  [hold-items]
	The small "name / rarity / income per second" billboard that floats over
	a player while they are holding a trophy in their hands.

	WHY THIS IS CLIENT-SIDE, NOT SERVER-BUILT
	HoldService (server) welds the small held-item MODEL onto the holder's
	character - that has to be server-authoritative, it is gameplay geometry
	everyone must see the same way. The billboard is pure decoration read off
	that model's attributes (HeldItem, HeldItemName, HeldRarity,
	HeldIncomePerSec), so it is built here instead: every viewer can then
	skip it under their OWN Low Graphics setting, and BillboardGui.MaxDistance
	gives "hide it while other players are far" for free, per viewer, with no
	server logic at all.

	Runs once per character that ever shows a HeldItemVisual model - the
	server destroys and rebuilds that model on every pickup/place/equip
	(never mutates one in place), so `character.ChildAdded` alone is enough
	to catch every appearance; nothing needs to poll.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local HoldConfig = require(ReplicatedStorage.Shared.Config.HoldConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local HeldItemFxController = {}

local BILLBOARD_NAME = "HeldItemInfo"

local function findAnchor(model: Model): BasePart?
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

local function rarityOf(model: Model): string
	local attr = model:GetAttribute("HeldRarity")
	return if type(attr) == "string" then attr else "Common"
end

--- Builds the billboard on `model` (a HeldItemVisual), unless one is already
--- there or the viewer has Low Graphics on. Kept deliberately light: static
--- text, no tween, no per-frame work - "keep it light" from the brief.
local function buildBillboard(model: Model)
	if Effects.isLowGraphics() or model:FindFirstChild(BILLBOARD_NAME) then
		return
	end
	local anchor = findAnchor(model)
	if not anchor then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = BILLBOARD_NAME
	gui.Size = UDim2.fromScale(6, 2.2)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	-- Hides itself past this range - the "far players don't see it" rule,
	-- enforced by the engine, per viewer, for free.
	gui.MaxDistance = HoldConfig.HELD_BILLBOARD_MAX_DISTANCE
	gui.AlwaysOnTop = false
	gui.Adornee = anchor
	gui.Parent = model

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.Size = UDim2.fromScale(1, 0.56)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextStrokeTransparency = 0.2
	name.TextStrokeColor3 = Color3.fromRGB(10, 12, 20)
	name.Parent = gui

	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.Size = UDim2.fromScale(1, 0.44)
	sub.Position = UDim2.fromScale(0, 0.56)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.GothamBold
	sub.TextScaled = true
	sub.TextColor3 = Color3.fromRGB(215, 224, 238)
	sub.TextStrokeTransparency = 0.35
	sub.TextStrokeColor3 = Color3.fromRGB(10, 12, 20)
	sub.Parent = gui

	local function refresh()
		local rarity = rarityOf(model)
		name.Text = tostring(model:GetAttribute("HeldItemName") or "")
		name.TextColor3 = RarityConfig.Colors[rarity] or Color3.new(1, 1, 1)
		local income = tonumber(model:GetAttribute("HeldIncomePerSec")) or 0
		sub.Text = `{rarity}  ·  {NumberFormat.income(income)}`
	end
	refresh()
	model.AttributeChanged:Connect(refresh)
end

local function onCharacterChild(model: Instance)
	if model.Name ~= "HeldItemVisual" or not model:IsA("Model") or model:GetAttribute("HeldItem") ~= true then
		return
	end
	buildBillboard(model)
end

local function watchCharacter(character: Model)
	local existing = character:FindFirstChild("HeldItemVisual")
	if existing then
		onCharacterChild(existing)
	end
	character.ChildAdded:Connect(onCharacterChild)
end

function HeldItemFxController.start()
	for _, player in Players:GetPlayers() do
		if player.Character then
			watchCharacter(player.Character)
		end
		player.CharacterAdded:Connect(watchCharacter)
	end
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(watchCharacter)
	end)

	-- Low Graphics can be flipped mid-session (SettingsController); an
	-- already-built billboard should not have to wait for the next pickup
	-- to respect it.
	Effects.graphicsChanged:Connect(function(low)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local model = character and character:FindFirstChild("HeldItemVisual")
			if not model or not model:IsA("Model") then
				continue
			end
			local existing = model:FindFirstChild(BILLBOARD_NAME)
			if low then
				if existing then
					existing:Destroy()
				end
			elseif not existing then
				buildBillboard(model)
			end
		end
	end)
end

return HeldItemFxController
