--!strict
--[[
	ItemThumb
	How a loot item is drawn inside a UI card.

	THE PROJECT HAS NO PER-ITEM ART.
	World loot and base trophies are both a `Placeholder` part tinted by rarity
	(see LootService and BaseService), so a card showing the UI pack's demo
	creature would be borrowed artwork that matches nothing in the game. A flat
	rarity swatch at least tells the truth: it is the item's actual in-world
	colour.

	THIS IS THE SWAP POINT. When per-item thumbnails exist, give this module a
	lookup from item id to asset and every card in every panel picks it up - the
	Storage panel and the Loot Index both route through here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local ItemThumb = {}

local DEFAULT = Color3.fromRGB(198, 205, 216)
local EDGE = Color3.fromRGB(18, 20, 26)

--- Paints `icon` as the thumbnail for an item of this rarity. Idempotent: safe
--- to call on a card that has already been painted.
function ItemThumb.apply(icon: ImageLabel, rarity: string?)
	local color = RarityConfig.Colors[rarity or "Common"] or DEFAULT

	icon.Image = ""
	icon.ImageTransparency = 0
	icon.BackgroundTransparency = 0
	icon.BackgroundColor3 = color

	if not icon:FindFirstChildOfClass("UICorner") then
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0.18, 0)
		round.Parent = icon
	end
	if not icon:FindFirstChildOfClass("UIStroke") then
		local edge = Instance.new("UIStroke")
		edge.Thickness = 2
		edge.Color = EDGE
		edge.Parent = icon
	end
end

--- The undiscovered state: the same plate, unlit. Deliberately not just a dimmed
--- rarity colour - that would leak how rare an item is before it is found.
function ItemThumb.applyUnknown(icon: ImageLabel)
	ItemThumb.apply(icon, nil)
	icon.BackgroundColor3 = Color3.fromRGB(44, 48, 58)
end

return ItemThumb
