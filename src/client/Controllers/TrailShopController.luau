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

	IT OPENS FROM THE WORLD, NOT FROM A BUTTON.
	The server fires `TrailRequest("open")` when the keeper's Hold-E prompt is
	triggered. There is deliberately no Trail entry in the main Shop: this is a
	place you walk to.

	THE CLIENT DECIDES NOTHING.
	Ownership, equipped state and price all arrive on `StatePush.monetization`.
	Buttons send a trail KEY and the server looks up what it costs, so a tampered
	client can ask to buy Divine but cannot tell the server it is free.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = require(script.Parent.UIStateController)

local TrailShopController = {}

local player = Players.LocalPlayer

local panel: Frame? = nil
local grid: Frame? = nil
local cards: { [string]: Frame } = {}
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
		local tween = TweenService:Create(scale, UIAnim.SHRINK, { Scale = 0.85 })
		tween:Play()
		tween.Completed:Once(function()
			if not open and frame.Parent then
				frame.Visible = false
			end
			scale.Scale = 1
		end)
	else
		frame.Visible = false
	end
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
	-- Ten trails, two to a row. The holder is sized so five rows PLUS their padding
	-- fit inside it - overflow would be clipped, because AutomaticCanvasSize
	-- measures the holder rather than what spills out of it.
	holder.Size = UDim2.fromScale(1, 1.75)
	holder.Parent = scroller

	-- The pack's card hangs its title a few pixels ABOVE its own body, so the top
	-- row's names get sliced off against the scroll frame's edge. Rows after the
	-- first are saved by the cell padding; the first row needs this.
	local inset = Instance.new("UIPadding")
	inset.PaddingTop = UDim.new(0, 8)
	inset.Parent = holder

	local layout = Instance.new("UIGridLayout")
	-- Five rows of two. A trail card carries a name, a rarity and two buttons, so
	-- it needs the same wide shape the shop cards use rather than a square tile.
	layout.CellSize = UDim2.fromScale(0.47, 0.17)
	layout.CellPadding = UDim2.fromScale(0.02, 0.02)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = holder

	if scroller and scroller:IsA("ScrollingFrame") then
		scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroller.CanvasSize = UDim2.fromScale(0, 0)
		scroller.ScrollBarThickness = 6
	end

	panel = clone
	grid = holder

	-- One card per tier, in progression order.
	for index, trail in MonetizationConfig.Trails do
		local card = ShopKit.card()
		if card then
			card.Name = `Trail_{trail.key}`
			card.LayoutOrder = index
			card.Parent = holder
			ShopKit.bindBuy(card, function()
				local row = latest and latest.trails and latest.trails[index]
				UIAnim.punch(card, 0.14)
				if row and row.owned then
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
		local card = cards[trail.key]
		local row = latest.trails[index]
		if card and row then
			local body = card:FindFirstChild("Frame")
			local choose = body and body:FindFirstChild("Choose")
			local robux = choose and choose:FindFirstChild("BuyRobux")

			local description
			if row.equipped then
				description = `EQUIPPED  ·  x{trail.multiplier} Speed`
			elseif row.owned then
				description = `OWNED  ·  tap to equip  ·  x{trail.multiplier}`
			else
				description = `x{trail.multiplier} Speed  ·  {trail.rarity}`
			end

			ShopKit.fillCard(card, {
				title = trail.name,
				description = description,
				-- Owned cards show EQUIP instead of a price they cannot pay again.
				price = if row.owned then "EQUIP" else NumberFormat.cash(trail.cash),
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
	if open then
		return
	end
	open = true
	refresh()

	UIStateController.claim("trailshop")
	frame.Visible = true
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	scale.Scale = 0.85
	TweenService:Create(scale, UIAnim.POP, { Scale = 1 }):Play()

	local list = {}
	for _, trail in MonetizationConfig.Trails do
		local card = cards[trail.key]
		if card then
			table.insert(list, card)
		end
	end
	ShopKit.cascadeIn(list, 0.03)
end

function TrailShopController.start()
	Remotes.get("TrailRequest").OnClientEvent:Connect(function(action)
		if action == "open" then
			show()
		end
	end)

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
