--!strict
--[[
	TrailShopController
	The Trail Shop panel, constructed from the purchased UI pack.

	THERE WAS NO TRAIL SHOP UI, so this builds one out of the pack's own parts
	rather than drawing a ScrollingFrame full of default buttons:
	    the Shop panel's frame, gradient and stroke  -> the window
	    the Shop panel's Top bar and Close button    -> the header and X
	    the Gamepass card                            -> every trail card
	The result is the pack's shop language applied to a screen the pack never
	shipped, which is what makes it feel native instead of bolted on.

	PAINTED CARDS. A trail whose config carries an `image` is drawn from that
	PNG instead, with invisible buttons over its printed prices (TrailCardPng).
	Today that is the Green Trail only - a test of the method before any other
	card is converted. Both kinds of card speak the same TrailRequest.

	IT OPENS FROM THE WORLD, NOT FROM A BUTTON.
	The server fires `TrailRequest("open")` when the player walks into the glowing
	circle in front of the booth, and "close" when they walk out. There is
	deliberately no Trail entry in the main Shop: this is a place you walk to.

	THE CLIENT DECIDES NOTHING.
	Ownership, equipped state and price all arrive on `StatePush.monetization`.
	Buttons send a trail KEY and the server looks up what it costs, so a tampered
	client can ask to buy Divine but cannot tell the server it is free.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local TrailCardPng = require(ReplicatedStorage.Shared.Util.TrailCardPng)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)
local Device = require(ReplicatedStorage.Shared.Util.Device)

local UIStateController = require(script.Parent.UIStateController)

local TrailShopController = {}

local player = Players.LocalPlayer

--- The panel opens from this scale and closes back to it: a short, confident
--- pop rather than a leap from nothing.
local PANEL_REST_SCALE = 0.92
local PANEL_CLOSE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local panel: Frame? = nil
local grid: Frame? = nil
local cards: { [string]: Frame } = {}
--- Painted cards, by trail key. A trail with an `image` gets one of these
--- INSTEAD of a pack card; see TrailCardPng.
local pngCards: { [string]: TrailCardPng.Card } = {}
--- Whichever open or close tween is running on the panel's UIScale, so the
--- two can cancel each other instead of fighting.
local panelTween: Tween? = nil
--- Re-fits the grid's pixel cells to the scroller; set by build(), run again
--- on every open so a layout pass the panel missed while hidden cannot leave
--- stale cells behind.
local refitCells: (() -> ())? = nil
local open = false
local latest: any = nil
--- Ownership as of the LAST push, so a trail that has just been unlocked can be
--- flashed. nil until the first push: the first one is a baseline, not a
--- purchase, or every card the player already owns would celebrate on open.
local previousOwned: { [string]: boolean }? = nil

local function close()
	if not open then
		return
	end
	open = false
	UIStateController.release("trailshop")
	local frame = panel
	if not frame then
		return
	end
	local scale = frame:FindFirstChildOfClass("UIScale")
	if scale then
		-- A short settle back to the size it opened from, then hide. Reopening
		-- mid-close cancels this, so the panel never snaps to 1 under a pop-in.
		if panelTween then
			panelTween:Cancel()
		end
		local tween = TweenService:Create(scale, PANEL_CLOSE, { Scale = PANEL_REST_SCALE })
		panelTween = tween
		tween.Completed:Once(function()
			if panelTween ~= tween then
				return
			end
			panelTween = nil
			if not open and frame.Parent then
				frame.Visible = false
			end
		end)
		tween:Play()
	else
		frame.Visible = false
	end
end

--- A painted card for a trail that ships as a PNG. The art is the whole look;
--- the buttons underneath route into the SAME TrailRequest the pack cards use,
--- under the same rule: send a key, never a price. The card learns ownership
--- from StatePush in refresh() and nowhere else.
local function buildPngCard(holder: Frame, index: number, trail: MonetizationConfig.TrailDef, layout: PngUiConfig.Layout)
	local remote = Remotes.get("TrailRequest")
	local onRobux: ((TrailCardPng.State) -> ())? = nil
	if trail.gamePassId then
		onRobux = function()
			remote:FireServer("buyRobux", trail.key)
		end
	end
	local card = TrailCardPng.build({
		layout = layout,
		familyAspect = PngUiConfig.Families.Trail,
		accent = RarityConfig.Colors[trail.rarity] or trail.color,
		onCash = function(state)
			if not state.owned then
				remote:FireServer("buyCash", trail.key)
			end
		end,
		onRobux = onRobux,
		-- The one owned-state control: equips, or unequips if it is worn. An
		-- empty key is how the server spells "take it off".
		onToggle = function(state)
			remote:FireServer("equip", if state.equipped then "" else trail.key)
		end,
		-- No sound hooks: AudioController already sounds every button under
		-- MainUI, these included.
	})
	card.frame.Name = `Trail_{trail.key}`
	card.frame.LayoutOrder = index
	card.frame.Parent = holder
	pngCards[trail.key] = card
end

--- The window itself: the pack's Shop frame, emptied and retitled.
local function build(): boolean
	if panel then
		return true
	end
	local ui = ShopKit.mainUi()
	local frames = ui and ui:FindFirstChild("Frames")
	local shop = frames and frames:FindFirstChild("Shop")
	if not ui or not frames or not frames:IsA("GuiObject") or not shop or not shop:IsA("Frame") then
		return false
	end

	-- A LAYER THAT MIRRORS `Frames`, rather than parenting straight to MainUI.
	--
	-- The Shop is sized and positioned in SCALE against `Frames`, which is not the
	-- screen: it is an inset 16:9 box with its own UIAspectRatioConstraint. Cloning
	-- the panel into MainUI therefore resolves those same scales against a larger,
	-- differently-shaped parent - the panel came out 594x335 instead of 566x319 and
	-- its scroll body slid up under its own title bar, hiding the first row of
	-- cards. Copying the container's geometry makes every scale inside the clone
	-- resolve to exactly what the real Shop gets.
	local layer = ui:FindFirstChild("TrailShopLayer")
	if not layer then
		local made = Instance.new("Frame")
		made.Name = "TrailShopLayer"
		made.BackgroundTransparency = 1
		made.Size = frames.Size
		made.Position = frames.Position
		made.AnchorPoint = frames.AnchorPoint
		made.ZIndex = 10
		local ratio = frames:FindFirstChildOfClass("UIAspectRatioConstraint")
		if ratio then
			ratio:Clone().Parent = made
		end
		made.Parent = ui
		layer = made
	end

	local clone = shop:Clone()
	clone.Name = "TrailShop"
	clone.Visible = false

	-- THE ROOT OF "THE TRAIL SHOP RANDOMLY NEVER OPENS". The pack closes a
	-- panel by sliding it BELOW the screen and fading its background to 1, and
	-- it leaves the frame parked there while hidden (openFrame resets it). This
	-- panel is a CLONE of the Shop, so it inherited whatever state the Shop was
	-- in at the moment of cloning - and when the player had opened and closed
	-- the Shop before their first visit to the booth, that state was
	-- "off-screen and transparent". show() then set Visible = true on a panel
	-- sitting sixty pixels under the bottom edge: the HUD hid, nothing appeared.
	-- Geometry is taken from the PRISTINE copy in StarterGui instead, which the
	-- pack never touches, and build() now runs at start rather than lazily.
	local pristine = StarterGui:FindFirstChild("MainUI")
	local pristineFrames = pristine and pristine:FindFirstChild("Frames")
	local pristineShop = pristineFrames and pristineFrames:FindFirstChild("Shop")
	if pristineShop and pristineShop:IsA("Frame") then
		clone.Position = pristineShop.Position
		clone.AnchorPoint = pristineShop.AnchorPoint
		clone.Size = pristineShop.Size
		clone.BackgroundTransparency = pristineShop.BackgroundTransparency
	end

	-- TOUCH: the same growth every panel in `Frames` gets from
	-- HUDLayoutController (this clone lives outside `Frames`, so that pass
	-- never reached it and the booth stayed a half-size box with buttons too
	-- small to tap). The layer already mirrors the enlarged container; the
	-- panel fills it, and the clone's aspect constraint keeps its shape.
	if Device.isTouch() then
		clone.AnchorPoint = Vector2.new(0.5, 0.5)
		clone.Position = UDim2.fromScale(0.5, 0.52)
		clone.Size = UDim2.fromScale(0.94, 0.9)
		for _, label in clone:GetDescendants() do
			if (label:IsA("TextLabel") or label:IsA("TextButton")) and label.TextScaled and not label:FindFirstChildOfClass("UITextSizeConstraint") then
				local limit = Instance.new("UITextSizeConstraint")
				limit.MaxTextSize = 26
				limit.Parent = label
			end
		end
	end

	-- Parented OUTSIDE `Frames`. The pack opens whichever frame in `Frames`
	-- matches a clicked button's name; leaving it there would let the pack try to
	-- manage a panel it knows nothing about.
	clone.Parent = layer

	-- Strip the cloned shop's contents, keeping its chrome.
	local scroller = clone:FindFirstChild("ScrollingFrame")
	if scroller then
		for _, child in scroller:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end

	local top = clone:FindFirstChild("Top")
	local title = top and top:FindFirstChild("Frame") and top.Frame:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = "Trail Shop"
	end
	local closeButton = top and top:FindFirstChild("Frame") and top.Frame:FindFirstChild("Close")
		or (top and top:FindFirstChild("Close"))
	if closeButton and closeButton:IsA("TextButton") then
		UIAnim.claimButton(closeButton)
		closeButton.Activated:Connect(close)
	end

	local holder = Instance.new("Frame")
	holder.Name = "TrailGrid"
	holder.BackgroundTransparency = 1
	-- Height is fitted to the rows below; AutomaticCanvasSize measures the
	-- holder rather than what spills out of it, so it must be exactly as tall
	-- as its rows.
	holder.Size = UDim2.new(1, 0, 0, 100)
	holder.Parent = scroller

	-- A little air above the first row so nothing kisses the scroll frame's
	-- top edge.
	local inset = Instance.new("UIPadding")
	inset.PaddingTop = UDim.new(0, 8)
	inset.Parent = holder

	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.new(0.02, 0, 0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = holder

	-- CELLS SHAPED TO THE ART. Two columns, every cell the painted cards'
	-- family aspect, sized in PIXELS from the scroller's real width and
	-- re-fitted when it changes. That is what makes ten separately painted
	-- banners come out the same shape in one grid at any resolution.
	local function fitCells()
		if not scroller or not scroller:IsA("ScrollingFrame") then
			return
		end
		local width = scroller.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local cellWidth = width * 0.47
		local cellHeight = cellWidth / PngUiConfig.Families.Trail
		layout.CellSize = UDim2.fromOffset(cellWidth, cellHeight)
		local rows = math.ceil(#MonetizationConfig.Trails / 2)
		holder.Size = UDim2.new(1, 0, 0, 8 + rows * cellHeight + (rows - 1) * 8 + 8)
	end
	fitCells()
	if scroller and scroller:IsA("ScrollingFrame") then
		scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitCells)
	end
	refitCells = fitCells

	if scroller and scroller:IsA("ScrollingFrame") then
		scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroller.CanvasSize = UDim2.fromScale(0, 0)
		scroller.ScrollBarThickness = 6
	end

	panel = clone
	grid = holder

	-- One card per tier, in progression order. A trail with painted art gets
	-- the PNG card; everything else is built from the pack.
	for index, trail in MonetizationConfig.Trails do
		local layout = if trail.image then PngUiConfig.card(`Trail_{trail.key}`) else nil
		if layout then
			buildPngCard(holder, index, trail, layout)
			continue
		end
		local card = ShopKit.card()
		if card then
			card.Name = `Trail_{trail.key}`
			card.LayoutOrder = index
			card.Parent = holder
			ShopKit.bindBuy(card, function()
				local row = latest and latest.trails and latest.trails[index]
				UIAnim.punch(card, 0.14)
				if row and row.equipped then
					Remotes.get("TrailRequest"):FireServer("equip", "")
				elseif row and row.owned then
					-- Owned: the button equips instead of selling again.
					Remotes.get("TrailRequest"):FireServer("equip", trail.key)
				else
					Remotes.get("TrailRequest"):FireServer("buyCash", trail.key)
				end
			end)

			-- Robux is the ALTERNATIVE route, so it gets its own button beside
			-- the cash one rather than replacing it.
			if trail.gamePassId then
				local body = card:FindFirstChild("Frame")
				local choose = body and body:FindFirstChild("Choose")
				local buy = choose and choose:FindFirstChild("Buy")
				if buy and buy:IsA("TextButton") then
					local robux = buy:Clone()
					robux.Name = "BuyRobux"
					robux.LayoutOrder = 2
					robux.Parent = choose
					-- The pack calls this label `Price`, not `Title`. Looking for the
					-- wrong name failed silently and left the pack's own demo price
					-- on every card, so all ten trails advertised R$ 67.
					local label = robux:FindFirstChild("Price", true)
						or robux:FindFirstChild("Title", true)
					if label and label:IsA("TextLabel") then
						label.Text = `R$ {trail.robux}`
					end
					-- Same struck-through demo "was" price the shop cards drop.
					for _, extra in { "Promo", "Line" } do
						local found = robux:FindFirstChild(extra, true)
						if found and found:IsA("GuiObject") then
							found.Visible = false
						end
					end
					UIAnim.claimButton(robux)
					robux.Activated:Connect(function()
						UIAnim.punch(card, 0.14)
						Remotes.get("TrailRequest"):FireServer("buyRobux", trail.key)
					end)
				end
			end

			cards[trail.key] = card
		end
	end

	return true
end

--- Repaints every card from the server's own view of ownership.
local function refresh()
	if not latest or not latest.trails then
		return
	end

	-- Which trails have only just become owned, so the card that sold one can
	-- flash. Read from the server's own ownership view, so a client that lies to
	-- itself gets a sparkle and nothing else.
	local nowOwned: { [string]: boolean } = {}
	local unlocked: { [string]: boolean } = {}
	for index, trail in MonetizationConfig.Trails do
		local row = latest.trails[index]
		local owned = row ~= nil and row.owned == true
		nowOwned[trail.key] = owned
		if previousOwned and owned and not previousOwned[trail.key] then
			unlocked[trail.key] = true
		end
	end
	previousOwned = nowOwned

	for index, trail in MonetizationConfig.Trails do
		local row = latest.trails[index]
		local png = pngCards[trail.key]
		if png and row then
			-- Painted card: the art never changes, only the state pills over the
			-- printed prices, and a bounce on the one that just sold.
			png.setState({ owned = row.owned == true, equipped = row.equipped == true })
			if unlocked[trail.key] then
				UIAnim.punch(png.frame, 0.2)
			end
			continue
		end
		local card = cards[trail.key]
		if card and row then
			local body = card:FindFirstChild("Frame")
			local choose = body and body:FindFirstChild("Choose")
			local robux = choose and choose:FindFirstChild("BuyRobux")

			local description
			if row.equipped then
				description = `EQUIPPED  ·  x{trail.multiplier} Speed  ·  tap to unequip`
			elseif row.owned then
				description = `x{trail.multiplier} Speed  ·  tap to equip`
			else
				description = `x{trail.multiplier} Speed  ·  {trail.rarity}`
			end

			ShopKit.fillCard(card, {
				title = trail.name,
				description = description,
				-- Owned cards carry the toggle instead of a price they cannot
				-- pay again.
				price = if row.equipped then "UNEQUIP" elseif row.owned then "EQUIP" else NumberFormat.cash(trail.cash),
				icon = ShopKit.Icons.Speed,
				color = trail.color,
				accent = trail.accent,
			})

			-- The Robux route disappears once it is owned by either route.
			if robux then
				robux.Visible = not row.owned
			end

			-- The equipped card wears its RARITY colour rather than the muted accent,
			-- so the current choice is obvious at a glance.
			--
			-- COLOUR ONLY - NEVER THICKNESS. The pack authors this stroke at 0.025,
			-- and raising it to a plain pixel value (2, 4) makes the engine draw the
			-- border as an enormous filled slab that swallows the whole scroll body:
			-- every trail card came out as a full-width block of flat colour. The
			-- authored thickness is load-bearing; leave it exactly as it ships.
			local stroke = card:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = if row.equipped
					then (RarityConfig.Colors[trail.rarity] or trail.color)
					else trail.accent
			end

			-- Just unlocked: sweep and bounce the card that sold it. The toast
			-- already says GREEN TRAIL UNLOCKED; this is what ties that message to
			-- the thing on screen the player just pressed.
			if unlocked[trail.key] then
				ShopKit.shine(card)
				UIAnim.punch(card, 0.2)
			end
		end
	end
end

local function show()
	if not build() then
		return
	end
	local frame = panel :: Frame
	if open and frame.Visible then
		return
	end
	open = true
	refresh()
	if refitCells then
		refitCells()
	end

	-- Mutually exclusive with the pack's panels: whatever the player had open
	-- closes cleanly (the pack restores the HUD it hid), THEN this claims the
	-- HUD for itself. Without this the pack's hideOwnHud could be holding our
	-- whole layer invisible while we "open" inside it.
	local closeAll = _G.CloseAllUIFrames
	if type(closeAll) == "function" then
		pcall(closeAll)
	end
	local layer = frame.Parent
	if layer and layer:IsA("GuiObject") then
		layer.Visible = true
	end

	UIStateController.claim("trailshop")
	frame.Visible = true
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	if panelTween then
		panelTween:Cancel()
	end
	scale.Scale = PANEL_REST_SCALE
	local pop = TweenService:Create(scale, UIAnim.POP, { Scale = 1 })
	panelTween = pop
	pop.Completed:Once(function()
		if panelTween == pop then
			panelTween = nil
		end
	end)
	pop:Play()

	-- Cards stagger in behind the panel, painted and pack-built alike.
	local list: { GuiObject } = {}
	for _, trail in MonetizationConfig.Trails do
		local png = pngCards[trail.key]
		local card: GuiObject? = if png then png.frame else cards[trail.key]
		if card then
			table.insert(list, card)
		end
	end
	ShopKit.cascadeIn(list, 0.03)
end

function TrailShopController.start()
	-- Built NOW, before the player can have opened and closed anything, so the
	-- clone is taken from a panel in its resting state (see build()).
	build()

	-- The server watches the booth's circle: "open" once on the way in, "close"
	-- once on the way out. Nothing here polls position or decides it is at the
	-- shop; the close X still works for anyone who wants it gone sooner.
	Remotes.get("TrailRequest").OnClientEvent:Connect(function(action)
		if action == "open" then
			show()
		elseif action == "close" then
			close()
		end
	end)

	-- A pack panel opening on top (Shop, Index, Storage, Upgrades, Settings)
	-- closes this one, so two shop windows never fight and the pack's own
	-- hide-the-HUD pass can never strand a half-open trail shop.
	local ui = ShopKit.mainUi()
	local frames = ui and ui:FindFirstChild("Frames")
	if frames then
		local function watch(frame: Instance)
			if not frame:IsA("GuiObject") then
				return
			end
			frame:GetPropertyChangedSignal("Visible"):Connect(function()
				if frame.Visible and open then
					close()
				end
			end)
		end
		for _, frame in frames:GetChildren() do
			watch(frame)
		end
		frames.ChildAdded:Connect(watch)
	end

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if not state then
			return
		end
		latest = state.monetization
		if open then
			refresh()
		end
	end)

	-- Walking away or dying with the shop open must not strand the HUD. The
	-- panel is not modal, so this is purely tidiness - but a shop left open
	-- across a respawn looks like a bug.
	player.CharacterAdded:Connect(close)
end

return TrailShopController
