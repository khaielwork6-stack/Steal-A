--!strict
-- Landscape HUD geometry only. Existing buttons retain their original handlers.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local MobileHudLayout = {}

function MobileHudLayout.start(ui: ScreenGui)
	local function fit()
		local camera = workspace.CurrentCamera
		-- A PHONE by its short edge, not by a 500 px height: a Galaxy S24
		-- reports a taller logical viewport than an iPhone and was skipping
		-- this compact layout entirely (owner, 2026-09-18).
		if not camera or not Device.isPhone() then return end
		local factor = ClipSafe.scaleChain(ui)
		local function place(object: GuiObject, x: number, y: number, w: number, h: number, right: boolean?)
			object.AnchorPoint = Vector2.new(if right then 1 else 0, 0)
			object.Position = UDim2.new(if right then 1 else 0, x / factor, 0, y / factor)
			object.Size = UDim2.fromOffset(w / factor, h / factor)
		end
		local stats = ui:FindFirstChild("StatHUD")
		if stats and stats:IsA("GuiObject") then
			local limit = stats:FindFirstChildOfClass("UISizeConstraint")
			if limit then limit.MinSize, limit.MaxSize = Vector2.zero, Vector2.new(math.huge, math.huge) end
			-- Placed with the clocks below, once the viewport height is known.
		end
		local buttons = ui:FindFirstChild("Buttons")
		local left = buttons and buttons:FindFirstChild("Left")
		if buttons and buttons:IsA("GuiObject") and left and left:IsA("GuiObject") then
			local scale = buttons:FindFirstChildOfClass("UIScale")
			if scale then scale.Scale = 1 end
			-- One column of 44 px icon tiles under Roblox's buttons (the
			-- reference HUD), sized so five of them clear the pill at the
			-- bottom on a 320 px-tall landscape phone.
			local tiles = 0
			for _, button in left:GetChildren() do
				if button:IsA("GuiButton") then tiles += 1; button.Active = true end
			end
			local tile, gap = 44, 6
			place(buttons, 8, 50, tile, tile * math.max(tiles, 1) + gap * math.max(tiles - 1, 0))
			local padding = buttons:FindFirstChildOfClass("UIPadding")
			if padding then padding:Destroy() end
			left.AnchorPoint, left.Position, left.Size = Vector2.zero, UDim2.new(), UDim2.fromScale(1, 1)
			local grid = left:FindFirstChildOfClass("UIGridLayout")
			if grid then
				grid.FillDirectionMaxCells = 1
				grid.CellSize = UDim2.fromOffset(tile / factor, tile / factor)
				grid.CellPadding = UDim2.fromOffset(0, gap / factor)
			end
		end
		local top = ui:FindFirstChild("Top")
		if top and top:IsA("GuiObject") then
			place(top, -8, 8, 274, 48, true)
			local layout = top:FindFirstChildOfClass("UIListLayout")
			if layout then
				layout.FillDirection = Enum.FillDirection.Horizontal
				layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
				layout.Padding = UDim.new(0, 6 / factor)
			end
			for _, child in top:GetChildren() do
				if child:IsA("GuiObject") then
					child.Size = UDim2.fromOffset((if child.Name == "Quests" then 112 else 48) / factor, 48 / factor)
					if child:IsA("GuiButton") then child.Active = true end
					for _, b in child:GetDescendants() do
						if b:IsA("GuiButton") and (b.Name == "Daily" or b.Name == "Invite" or b.Name == "Settings") then
							b.Active = true
							b.Size = UDim2.fromOffset(48 / factor, 48 / factor)
						end
					end
				end
			end
		end
		for _, rail in ui:GetChildren() do
			if rail:IsA("GuiObject") and rail.Name:find("UI FOR ANIMAL", 1, true) == 1 then
				-- Straight under the top strip now that the CREW card is gone.
				place(rail, -8, 64, 112, 52, true)
				local grid = rail:FindFirstChildOfClass("UIGridLayout")
				if grid then
					grid.FillDirection, grid.FillDirectionMaxCells = Enum.FillDirection.Horizontal, 2
					grid.CellSize, grid.CellPadding = UDim2.fromOffset(52 / factor, 52 / factor), UDim2.fromOffset(8 / factor, 0)
				end
			end
		end
		-- The two clocks (NightTimer, EventPill) place THEMSELVES centre-right
		-- on touch and are left alone here (owner, 2026-09-18); this only
		-- needs the viewport height for the stat figures below.
		local height = camera.ViewportSize.Y
		-- The stat figures (no box) sit bottom-left; the boost pills above
		-- them, small, so neither reaches the thumbstick's resting spot.
		if stats and stats:IsA("GuiObject") then
			-- The economy pill: bottom-left, 28 px tall, as wide as its text.
			place(stats, 8, height - 8 - 28, 0, 28)
			stats.AutomaticSize = Enum.AutomaticSize.X
			for _, label in stats:GetDescendants() do
				if label:IsA("TextLabel") then label.TextSize = 13 / factor end
			end
			local boosts = ui:FindFirstChild("SocialBoosts")
			if boosts and boosts:IsA("GuiObject") then
				boosts.AnchorPoint = Vector2.new(0, 1)
				boosts.Size = UDim2.fromOffset(200 / factor, 20 / factor)
				boosts.Position = UDim2.fromOffset(8 / factor, (height - 8 - 28 - 4) / factor)
			end
		end
	end
	local function schedule() task.defer(fit) end
	ui.ChildAdded:Connect(function(child)
		if child.Name == "Top" or child.Name == "Buttons" then child.DescendantAdded:Connect(schedule) end
		schedule()
	end)
	for _, name in { "Top", "Buttons" } do
		local child = ui:FindFirstChild(name)
		if child then child.DescendantAdded:Connect(schedule) end
	end
	local scale = ui:FindFirstChildOfClass("UIScale")
	if scale then scale:GetPropertyChangedSignal("Scale"):Connect(schedule) end
	local camera = workspace.CurrentCamera
	if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(schedule) end
	Device.onTouchChanged(schedule)
	task.defer(fit)
	task.delay(2, fit)
	task.delay(5, fit)
end

return MobileHudLayout
