--!strict
--[[
	UpgradesController
	The Upgrades panel: buy the next treadmill tier with Cash or with Robux.

	The pack already ships everything this needs. `MainUI.Frames.Upgrades` is a
	full panel, and its card template carries BOTH a green `Money` button and a
	purple `Robux` button inside one `Choose` list, plus a `Boost` row that reads
	`Lvl 1 -> Lvl 2`. That is exactly the dual-currency shape the GDD asks for,
	so nothing here is drawn from scratch - the card is filled in.

	WHAT THIS CONTROLLER IS NOT ALLOWED TO DO
	It never names a product id and never calls PromptProductPurchase. It sends
	`PurchaseRequest("treadmill")` and the server decides which product that means
	and whether it is configured at all. A tampered client therefore cannot make
	the game prompt for an arbitrary product.

	THE UNCONFIGURED RULE
	Every product id defaults to 0. The GDD is explicit that an unconfigured id
	must hide or disable the Robux button rather than open a broken dialog, so
	the button is hidden unless `MonetizationConfig` has a real id for the tier
	being sold right now. With none configured, the panel is Cash-only and looks
	deliberate rather than broken.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TreadmillConfig = require(ReplicatedStorage.Shared.Config.TreadmillConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UpgradesController = {}

local player = Players.LocalPlayer

local panel: Frame? = nil
local list: ScrollingFrame? = nil
local cardTemplate: Frame? = nil
local card: Frame? = nil
local latestState: any = nil

-- Robux prices live in the Creator Dashboard, not in our config, so they are
-- fetched once per product and cached. A failure just leaves the fallback text.
local priceCache: { [number]: string } = {}

-- ==========================================================
-- SMALL HELPERS
-- ==========================================================

local function labelIn(parent: Instance?, name: string): TextLabel?
	if not parent then
		return nil
	end
	local found = parent:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

--- The pack's currency buttons carry a strike-through cross-sell (`Promo` plus
--- a red `Line`). We sell one price per button, so both go.
local function stripPromo(button: Instance)
	local body = button:FindFirstChild("Frame")
	if not body then
		return
	end
	for _, name in { "Promo", "Line" } do
		local extra = body:FindFirstChild(name)
		if extra then
			extra:Destroy()
		end
	end
end

local function setDimmed(button: GuiObject, dimmed: boolean)
	button.BackgroundTransparency = if dimmed then 0.4 else 0
	local price = labelIn(button, "Price")
	if price then
		price.TextTransparency = if dimmed then 0.4 else 0
	end
end

--- Asks Roblox what a Developer Product costs. Cached, and never fatal.
local function robuxPriceText(productId: number): string
	local cached = priceCache[productId]
	if cached then
		return cached
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
	end)
	local text = "ROBUX"
	if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
		text = `R${info.PriceInRobux}`
	end
	priceCache[productId] = text
	return text
end

-- ==========================================================
-- RENDER
-- ==========================================================

local function render(state: any)
	latestState = state
	local frame, treadmill = panel, card
	if not frame or not treadmill or not state then
		return
	end

	local level = state.treadmillLevel or 0
	local nextTier = TreadmillConfig.nextTier(level)

	local body = treadmill:FindFirstChild("Frame")
	local boost = body and body:FindFirstChild("Boost")
	local choose = body and body:FindFirstChild("Choose")
	local money = choose and choose:FindFirstChild("Money")
	local robux = choose and choose:FindFirstChild("Robux")

	local title = labelIn(body, "Title")
	if title then
		title.Text = if nextTier then `Treadmill - {nextTier.name}` else "Treadmill - MAX"
	end

	local from = labelIn(boost, "Multiplier1")
	local to = labelIn(boost, "Multiplier2")
	if from then
		from.Text = `Lvl {level}`
	end
	if to then
		to.Text = if nextTier then `Lvl {nextTier.level}` else "MAX"
	end

	-- Nothing left to sell.
	if not nextTier then
		if money then
			(money :: GuiObject).Visible = false
		end
		if robux then
			(robux :: GuiObject).Visible = false
		end
		return
	end

	-- Cash: always offered, dimmed when it cannot be afforded so the player can
	-- still see the price they are working toward.
	if money and money:IsA("GuiButton") then
		money.Visible = state.baseActivated == true
		local price = labelIn(money, "Price")
		if price then
			price.Text = NumberFormat.cash(nextTier.cost)
		end
		setDimmed(money, (state.cash or 0) < nextTier.cost)
	end

	-- Robux: only when this exact tier has a real product id behind it.
	if robux and robux:IsA("GuiButton") then
		local productId = MonetizationConfig.productIdFor(nextTier.robuxProductKey)
		robux.Visible = productId ~= nil and state.baseActivated == true
		if productId then
			local price = labelIn(robux, "Price")
			if price then
				price.Text = robuxPriceText(productId)
			end
			setDimmed(robux, false)
		end
	end
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function buildPanel(ui: ScreenGui): boolean
	local frames = ui:FindFirstChild("Frames")
	local found = frames and frames:FindFirstChild("Upgrades")
	if not found or not found:IsA("Frame") then
		warn("[UpgradesController] Frames.Upgrades not found - the Upgrades panel is disabled.")
		return false
	end
	panel = found

	local scroll = found:FindFirstChild("ScrollingFrame")
	if not scroll or not scroll:IsA("ScrollingFrame") then
		warn("[UpgradesController] Upgrades panel has no ScrollingFrame.")
		return false
	end
	list = scroll

	-- The pack ships four demo cards. Keep the first, drop the rest and the
	-- zero-size spacer.
	local kept: Frame? = nil
	for _, child in scroll:GetChildren() do
		if child:IsA("Frame") then
			if child.Name == "Upgrade1" and not kept then
				kept = child
			else
				child:Destroy()
			end
		end
	end
	if not kept then
		warn("[UpgradesController] no Upgrade1 card template in the pack.")
		return false
	end

	kept.Name = "TreadmillUpgrade"
	card = kept

	local body = kept:FindFirstChild("Frame")
	local choose = body and body:FindFirstChild("Choose")
	local money = choose and choose:FindFirstChild("Money")
	local robux = choose and choose:FindFirstChild("Robux")

	if money and money:IsA("TextButton") then
		stripPromo(money)
		money.LayoutOrder = 1
		-- claimButton, not bindButton: pack buttons ship Active = false and
		-- already carry _UIHandlerSetup, so Activated would never fire.
		UIAnim.claimButton(money)
		money.Activated:Connect(function()
			Remotes.get("TreadmillUpgradeRequest"):FireServer()
		end)
	end

	if robux and robux:IsA("TextButton") then
		stripPromo(robux)
		robux.LayoutOrder = 2
		robux.Visible = false -- until a configured product proves otherwise
		UIAnim.claimButton(robux)
		robux.Activated:Connect(function()
			-- Intent only. The server picks the product and refuses if unset.
			Remotes.get("PurchaseRequest"):FireServer("treadmill")
		end)
	end

	-- Rows are only meaningful while the panel is up, and the pack owns opening.
	found:GetPropertyChangedSignal("Visible"):Connect(function()
		if found.Visible then
			render(latestState)
		end
	end)

	local layout = scroll:FindFirstChildOfClass("UIListLayout")
	if layout then
		local function resize()
			scroll.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
		end
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize)
		resize()
	end

	return true
end

--- The pack has no Upgrades button, so one is cloned from an existing menu
--- button. The pack pairs a button with the panel of the SAME NAME, which is
--- what makes it open with the pack's own slide + blur.
local function buildOpener(ui: ScreenGui)
	local buttons = ui:FindFirstChild("Buttons")
	local left = buttons and buttons:FindFirstChild("Left")
	local source = left and left:FindFirstChild("Index")
	if not left or not source or not source:IsA("TextButton") then
		warn("[UpgradesController] pack menu buttons not found - Upgrades opener not built.")
		return
	end
	if left:FindFirstChild("Upgrades") then
		return
	end

	local opener = source:Clone()
	opener.Name = "Upgrades"
	opener.LayoutOrder = 2

	-- The source has already been stamped by the pack, and a clone inherits it.
	-- Leaving it set makes the pack skip our button, so it animates but opens
	-- nothing. Clear both stamps and any mid-animation leftovers.
	opener:SetAttribute("_UIHandlerSetup", nil)
	opener:SetAttribute("AnimBound", nil)
	local staleRipple = opener:FindFirstChild("_RippleContainer")
	if staleRipple then
		staleRipple:Destroy()
	end
	local scale = opener:FindFirstChildOfClass("UIScale")
	if scale then
		scale.Scale = 1
	end

	local label = opener:FindFirstChild("Title")
	if label and label:IsA("TextLabel") then
		label.Text = "Upgrades"
	end
	local body = opener:FindFirstChild("Frame")
	local icon = body and body:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		-- The icon the pack already ships on this panel's own header.
		icon.Image = "rbxassetid://102080723305863"
	end

	opener.Parent = left

	-- If the pack ever declines the button it is silently dead, so say so.
	task.delay(2, function()
		if opener.Parent and opener:GetAttribute("_UIHandlerSetup") ~= true then
			warn("[UpgradesController] the pack did not bind the Upgrades button - it will not open.")
		end
	end)
end

function UpgradesController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		warn("[UpgradesController] MainUI not found - Upgrades disabled.")
		return
	end

	-- Panel first: the pack matches a button to a frame by name when the button
	-- is registered, so the frame has to exist before the opener appears.
	if not buildPanel(ui) then
		return
	end
	buildOpener(ui)

	Remotes.get("StatePush").OnClientEvent:Connect(render)
end

return UpgradesController
