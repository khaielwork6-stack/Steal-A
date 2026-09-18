--!strict
-- Landscape HUD geometry only. Existing buttons retain their original handlers.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local MobileHudLayout = {}

function MobileHudLayout.start(ui: ScreenGui)
	local function fit()
		local camera = workspace.CurrentCamera
		if not camera or not Device.isTouch() or camera.ViewportSize.Y >= 500 then return end
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
			place(stats, 8, 58, 144, 38)
			local boosts = stats:FindFirstChild("SocialBoosts")
			if boosts and boosts:IsA("GuiObject") then
				boosts.AnchorPoint = Vector2.zero
				boosts.Position = UDim2.new(1, 8 / factor, 0, 0)
				boosts.Size = UDim2.fromOffset(106 / factor, 24 / factor)
			end
		end
		local buttons = ui:FindFirstChild("Buttons")
		local left = buttons and buttons:FindFirstChild("Left")
		if buttons and buttons:IsA("GuiObject") and left and left:IsA("GuiObject") then
			local scale = buttons:FindFirstChildOfClass("UIScale")
			if scale then scale.Scale = 1 end
			place(buttons, 8, 102, 164, 104)
			local padding = buttons:FindFirstChildOfClass("UIPadding")
			if padding then
				padding.PaddingLeft, padding.PaddingRight = UDim.new(), UDim.new()
				padding.PaddingTop, padding.PaddingBottom = UDim.new(), UDim.new()
			end
			left.AnchorPoint, left.Position, left.Size = Vector2.zero, UDim2.new(), UDim2.fromScale(1, 1)
			local grid = left:FindFirstChildOfClass("UIGridLayout")
			if grid then
				grid.FillDirectionMaxCells = 3
				grid.CellSize = UDim2.fromOffset(48 / factor, 48 / factor)
				grid.CellPadding = UDim2.fromOffset(8 / factor, 8 / factor)
			end
			for _, button in left:GetChildren() do
				if button:IsA("GuiButton") then
					button.Active = true
					local title = button:FindFirstChild("Title")
					if title and title:IsA("TextLabel") then
						title.AnchorPoint, title.Position = Vector2.new(0.5, 1), UDim2.fromScale(0.5, 0.97)
						title.Size, title.ZIndex = UDim2.fromScale(0.97, 0.24), 8
					end
					local icon = button:FindFirstChild("Icon", true)
					if icon and icon:IsA("ImageLabel") then
						icon.AnchorPoint, icon.Position, icon.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.38), UDim2.fromScale(0.67, 0.67)
					end
				end
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
		local crew = ui:FindFirstChild("CrewCard")
		if crew and crew:IsA("GuiObject") then
			place(crew, -8, 70, 112, 56, true)
			crew.AutomaticSize = Enum.AutomaticSize.None
			local rows = crew:FindFirstChild("Rows")
			if rows and rows:IsA("GuiObject") then rows.Visible = false end -- Full roster/invites remain in the Crew panel.
			local opener = crew:FindFirstChild("Crew")
			if opener and opener:IsA("GuiButton") then opener.Active = true; opener.Size = UDim2.new(1, 0, 0, 48 / factor) end
		end
		for _, rail in ui:GetChildren() do
			if rail:IsA("GuiObject") and rail.Name:find("UI FOR ANIMAL", 1, true) == 1 then
				place(rail, -8, 138, 112, 52, true)
				local grid = rail:FindFirstChildOfClass("UIGridLayout")
				if grid then
					grid.FillDirection, grid.FillDirectionMaxCells = Enum.FillDirection.Horizontal, 2
					grid.CellSize, grid.CellPadding = UDim2.fromOffset(52 / factor, 52 / factor), UDim2.fromOffset(8 / factor, 0)
				end
			end
		end
		for _, spec in { {"NightTimer", 76}, {"EventPill", 108} } do
			local pill = ui:FindFirstChild(spec[1] :: string)
			if pill and pill:IsA("GuiObject") then place(pill, -136, spec[2] :: number, 164, 26, true) end
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
