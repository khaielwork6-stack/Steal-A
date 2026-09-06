--!strict
--[[
	ShopKit
	The ONE place new shop UI is built, by cloning components out of the purchased
	UI pack rather than drawing rectangles.

	WHY THIS EXISTS
	Four surfaces need product cards - the main Shop, the treadmill offer, the
	boss-loss popup and the Trail Shop. Built independently they would drift into
	four dialects of the same idea. Built from here they are literally the same
	pack components with different text, so they cannot look foreign to each other
	or to the rest of the game.

	WHAT IT CLONES
	  MainUI.Frames.Shop.ScrollingFrame.Gamepassees.Gamepass  the product card
	  MainUI.Frames.Shop.ScrollingFrame.GamepassesTitle       the section header
	  MainUI.Frames.Shop.Top                                  header bar + close X
	Each already carries the pack's gradient, stroke, studs texture, rays burst,
	corner radius and font, which is exactly the look we are asked to match.

	THE TWO PACK RULES THIS FILE OBEYS
	  1. A cloned pack button is INERT until `_UIHandlerSetup` and `AnimBound` are
	     cleared and Active is re-enabled - the pack drives its own buttons from
	     InputBegan and stamps the ones it owns. `UIAnim.claimButton` does it in
	     the right order; nothing here binds `Activated` directly. This has bitten
	     this project twice already.
	  2. Never mutate a template. Everything is cloned first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local ShopKit = {}

--- Icons LIFTED FROM THE PACK'S OWN HUD BUTTONS, not sourced from elsewhere.
--- Reusing the exact art the player already associates with money and upgrades
--- is what keeps a shop card reading as part of this game; a stock Robux glyph
--- or a random catalogue decal would not.
ShopKit.Icons = {
	Cash = "rbxassetid://112931960147028", -- the Storage button's cash stack
	Speed = "rbxassetid://102080723305863", -- the Upgrades button's arrow
	Shop = "rbxassetid://109523362330544", -- the Shop button's crate
}

-- ==========================================================
-- RESOLUTION
-- ==========================================================

function ShopKit.mainUi(): Instance?
	local player = Players.LocalPlayer
	local gui = player and player:FindFirstChild("PlayerGui")
	return if gui then gui:FindFirstChild("MainUI") else nil
end

local function shopFrame(): Instance?
	local ui = ShopKit.mainUi()
	local frames = ui and ui:FindFirstChild("Frames")
	return if frames then frames:FindFirstChild("Shop") else nil
end

-- ==========================================================
-- TEMPLATE CACHE
-- ==========================================================
--
-- Templates are LIFTED OUT OF THE PACK ONCE and kept privately, because the
-- first thing the main Shop does is clear the pack's demo contents - and the
-- card template lives inside one of the frames being cleared. Reading the
-- template live would work exactly once and then silently return nil, which is
-- how the shop came up with a header and an empty body the first time.
--
-- Cached copies are parented nowhere, so they never render and cannot be
-- mutated by anything walking the UI tree.

local cache: { [string]: Instance } = {}

local function template(name: string, find: () -> Instance?): Instance?
	local held = cache[name]
	if held then
		return held
	end
	local found = find()
	if not found then
		return nil
	end
	local copy = found:Clone()
	cache[name] = copy
	return copy
end

--- A fresh, cleaned product card. Returns nil if the pack is missing, so every
--- caller degrades to "no card" rather than to a hand-drawn substitute.
function ShopKit.card(): Frame?
	local source = template("card", function()
		local shop = shopFrame()
		local scroller = shop and shop:FindFirstChild("ScrollingFrame")
		local group = scroller and scroller:FindFirstChild("Gamepassees")
		return group and group:FindFirstChild("Gamepass")
	end)
	if not source or not source:IsA("Frame") then
		return nil
	end

	local clone = source:Clone()

	-- The card ships with UIAspectRatioConstraint = 2, sized for the one grid the
	-- pack authored it in. Left on, it OVERRIDES whatever cell it is placed in and
	-- shrinks to the smaller of the two axes - which turned a full-width shop card
	-- into a 60px thumbnail. Every consumer here places it in its own layout, so
	-- the layout owns the size and the constraint has to go. Everything inside the
	-- card is scale-based and reflows on its own.
	local aspect = clone:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then
		aspect:Destroy()
	end

	-- The pack ships this card with a limited-time badge and a gift button; both
	-- are demo furniture for a product we are not selling.
	local body = clone:FindFirstChild("Frame")
	if body then
		local timer = body:FindFirstChild("Timer")
		if timer then
			timer:Destroy()
		end
		local choose = body:FindFirstChild("Choose")
		local gift = choose and choose:FindFirstChild("Gift")
		if gift then
			gift:Destroy()
		end
	end
	return clone
end

--- A section header ("CASH", "SPEED", "PASSES").
function ShopKit.header(): Frame?
	local source = template("header", function()
		local shop = shopFrame()
		local scroller = shop and shop:FindFirstChild("ScrollingFrame")
		return scroller and scroller:FindFirstChild("GamepassesTitle")
	end)
	if not source or not source:IsA("Frame") then
		return nil
	end
	return source:Clone()
end

--- The pack's header bar, complete with its close button.
function ShopKit.topBar(): Frame?
	local source = template("top", function()
		local shop = shopFrame()
		return shop and shop:FindFirstChild("Top")
	end)
	if not source or not source:IsA("Frame") then
		return nil
	end
	return source:Clone()
end

--- Lifts every template out of the pack before anything clears it. Call once,
--- early, from whichever controller is going to modify the Shop panel.
function ShopKit.warm()
	ShopKit.card()
	ShopKit.header()
	ShopKit.topBar()
end

-- ==========================================================
-- WRITING TO A CARD
-- ==========================================================

export type CardOptions = {
	title: string,
	description: string?,
	price: string,
	--- Tints the card body. Used for trail rarity and for the Cash/Speed split.
	color: Color3?,
	accent: Color3?,
	--- Replaces the pack's product art. Left alone when nil.
	icon: string?,
	--- Hides the price button entirely (an OWNED or MAXED state).
	hidePrice: boolean?,
}

local function firstText(root: Instance, name: string): TextLabel?
	local found = root:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

--- Retexts and recolours a cloned card. Never creates a second card.
function ShopKit.fillCard(card: Frame, options: CardOptions)
	local body = card:FindFirstChild("Frame")
	if not body then
		return
	end

	local title = firstText(body, "Title")
	if title then
		title.Text = string.upper(options.title)
	end

	local description = firstText(body, "Description")
	if description then
		description.Text = options.description or ""
		description.Visible = (options.description or "") ~= ""
	end

	-- Tint through the pack's OWN gradient rather than flattening the fill, so
	-- the card keeps its depth instead of turning into a solid rectangle.
	if options.color then
		local gradient = body:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = ColorSequence.new(options.color, options.accent or options.color)
		end
		local stroke = card:FindFirstChildOfClass("UIStroke") or body:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = options.accent or options.color
		end
		-- The card's OUTER frame is a solid plate the inner body is inset into, so
		-- it reads as the card's border. The pack ships it magenta; left alone, a
		-- green cash card comes out ringed in purple.
		card.BackgroundColor3 = options.accent or options.color
	end

	-- The pack stacks TWO ImageLabels inside the Icon canvas - a back plate and the
	-- product art over it. Retexturing only one leaves the demo art showing behind
	-- ours, so both layers take the same image.
	if options.icon then
		local iconGroup = body:FindFirstChild("Icon")
		if iconGroup then
			for _, layer in iconGroup:GetDescendants() do
				if layer:IsA("ImageLabel") then
					layer.Image = options.icon
				end
			end
		end
	end

	local choose = body:FindFirstChild("Choose")
	local buy = choose and choose:FindFirstChild("Buy")
	if buy and buy:IsA("TextButton") then
		if options.hidePrice then
			choose.Visible = false
		else
			choose.Visible = true
			-- The pack puts the price in the button's own label; it ships with a
			-- Robux icon beside it, which is exactly what a Robux price wants.
			local label = firstText(buy, "Title") or firstText(buy, "Price")
			if label then
				label.Text = options.price
			else
				buy.Text = options.price
			end
			-- The pack's button ships a struck-through "was" price - a `Promo` label
			-- and the `Line` drawn across it - for a sale it invented. We are not
			-- running one, and a strikethrough over a real price reads as a bug.
			for _, name in { "Promo", "Line" } do
				local extra = buy:FindFirstChild(name, true)
				if extra and extra:IsA("GuiObject") then
					extra.Visible = false
				end
			end
		end
	end
end

--- The card's purchase button, already claimed from the pack and wired.
--- ALWAYS route through this: a raw `Activated` connection on a pack button
--- silently never fires, because the pack ships them with Active = false.
function ShopKit.bindBuy(card: Frame, onClick: () -> ()): TextButton?
	local body = card:FindFirstChild("Frame")
	local choose = body and body:FindFirstChild("Choose")
	local buy = choose and choose:FindFirstChild("Buy")
	if not buy or not buy:IsA("TextButton") then
		return nil
	end
	UIAnim.claimButton(buy)
	buy.Activated:Connect(onClick)
	return buy
end

-- ==========================================================
-- POLISH
-- ==========================================================

--- A one-off highlight sweep across a card. Used for a successful purchase.
--- Cleans itself up, so it cannot leak an instance per press.
function ShopKit.shine(target: GuiObject)
	local sweep = Instance.new("Frame")
	sweep.Name = "Shine"
	sweep.BackgroundColor3 = Color3.new(1, 1, 1)
	sweep.BackgroundTransparency = 0.55
	sweep.BorderSizePixel = 0
	sweep.Rotation = 18
	sweep.Size = UDim2.fromScale(0.22, 1.8)
	sweep.Position = UDim2.fromScale(-0.35, -0.4)
	sweep.ZIndex = 20
	sweep.Parent = target

	local tween = TweenService:Create(
		sweep,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(1.2, -0.4), BackgroundTransparency = 1 }
	)
	tween:Play()
	tween.Completed:Once(function()
		sweep:Destroy()
	end)
end

--- Stagger helper: cards cascade in rather than all appearing at once.
function ShopKit.cascadeIn(cards: { GuiObject }, step: number?)
	local delayStep = step or 0.035
	for index, card in cards do
		local scale = card:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Parent = card
		scale.Scale = 0.85
		card.Visible = true
		task.delay(delayStep * (index - 1), function()
			if card.Parent then
				TweenService:Create(scale, UIAnim.POP, { Scale = 1 }):Play()
			end
		end)
	end
end

--- Slow idle float. Deliberately tiny - this runs on an offer card that sits on
--- screen, and anything bigger reads as spam rather than life.
function ShopKit.idleFloat(target: GuiObject, connection: RBXScriptConnection?): RBXScriptConnection
	if connection then
		connection:Disconnect()
	end
	local scale = target:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = target
	local start = os.clock()
	return game:GetService("RunService").RenderStepped:Connect(function()
		if not target.Parent or not target.Visible then
			return
		end
		scale.Scale = 1 + math.sin((os.clock() - start) * 2.1) * 0.018
	end)
end

return ShopKit
