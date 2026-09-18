--!strict
--[[
	AutoRevealPassCard
	The Auto Reveal Game Pass card in the Shop's PASSES section.

	Kept out of ShopController on purpose (that file is shared): the shop
	calls `build(grid)` once and adds the returned count to its grid size;
	everything else - ownership, price, the purchase intent - lives here.

	Same component as the 2x Cash card when that one has no painted art
	(ShopKit.card + fillCard), same OWNED treatment.

	HIDDEN WHILE THE PASS ID IS 0 (MonetizationConfig.AutoRevealPass). In
	Studio the card is shown anyway, greyed and labelled NOT SET UP, so the
	layout can be checked before the pass exists.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local AutoRevealPassCard = {}

local COLOR = Color3.fromRGB(180, 120, 255)
local ACCENT = Color3.fromRGB(96, 40, 170)
local OWNED_COLOR = Color3.fromRGB(96, 104, 124)

--- Pass icon (Codex prompt: docs/codex-prompts/fusion-autoreveal-bases.md).
--- "rbxassetid://0" = keep the pack's own card art.
AutoRevealPassCard.ICON = "rbxassetid://98876576301515"

local card: Frame? = nil
local lastOwned: boolean? = nil
local lastPrice: number? = nil

local function paint(owned: boolean, configured: boolean, robux: number)
	local frame = card
	if not frame then
		return
	end
	local icon = if AutoRevealPassCard.ICON ~= "rbxassetid://0" then AutoRevealPassCard.ICON else ShopKit.Icons.Shop
	-- Owned means gone from the shop (ShopController re-fits the section);
	-- the toggle lives in Settings, where an owner goes looking for it.
	frame.Visible = not owned
	if owned then
		return
	else
		ShopKit.fillCard(frame, {
			title = MonetizationConfig.AutoRevealPass.label,
			description = if configured
				then "Containers reveal themselves when ready - while you're online."
				else "NOT SET UP (pass id is 0)",
			price = `R$ {NumberFormat.comma(robux)}`,
			icon = icon,
			color = if configured then COLOR else OWNED_COLOR,
			accent = ACCENT,
		})
	end
end

--- Adds the card to `grid` at `order`. Returns how many cards it added (0
--- while the pass is not configured outside Studio).
function AutoRevealPassCard.build(grid: Frame, order: number): number
	local configured = MonetizationConfig.AutoRevealPass.gamePassId > 0
	if not configured and not RunService:IsStudio() then
		return 0
	end
	local built = ShopKit.card()
	if not built then
		return 0
	end
	require(ReplicatedStorage.Shared.Util.PanelStyle).productCard(built)
	built.Name = "Card_AutoReveal"
	built.LayoutOrder = order
	built.Parent = grid
	card = built
	paint(false, configured, MonetizationConfig.AutoRevealPass.robux)
	ShopKit.bindBuy(built, function()
		UIAnim.punch(built, 0.14)
		Remotes.get("AutoRevealRequest"):FireServer("buy")
	end)

	require(script.Parent.Parent.StateStore).subscribe(function(state)
		local info = state and state.autoReveal
		if type(info) ~= "table" then
			return
		end
		local owned = info.owned == true
		local price = tonumber(info.robux) or MonetizationConfig.AutoRevealPass.robux
		if owned == lastOwned and price == lastPrice then
			return
		end
		local wasOwned = lastOwned
		lastOwned = owned
		lastPrice = price
		paint(owned, info.configured == true, price)
		if wasOwned == false and owned then
			ShopKit.shine(built)
			UIAnim.punch(built, 0.2)
		end
	end)
	return 1
end

return AutoRevealPassCard
