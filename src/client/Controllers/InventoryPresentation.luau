--!strict
-- Reskins the existing Storage card hierarchy without replacing its buttons,
-- thumbnails, or server callbacks. Fusion borrows exactly the same card kit.
local RS = game:GetService("ReplicatedStorage")
local ClipSafe = require(RS.Shared.Util.ClipSafe)
local PanelStyle = require(RS.Shared.Util.PanelStyle)
local InventoryPresentation = {}

function InventoryPresentation.card(card: Frame)
	local body = card:FindFirstChild("Frame")
	if not body or not body:IsA("Frame") then return end
	card.BackgroundTransparency = 1
	body.AnchorPoint = Vector2.zero
	body.Position = UDim2.fromScale(0, 0)
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 0
	body.BackgroundColor3 = Color3.new(1, 1, 1)
	PanelStyle.gradient(body, Color3.fromRGB(56, 71, 136), Color3.fromRGB(27, 31, 75))
	PanelStyle.corner(body, 12)
	local rows: { TextLabel } = {}
	for _,child in body:GetChildren() do
		if child:IsA("TextLabel") and child.Name == "Title" then table.insert(rows, child)
		elseif child:IsA("ImageLabel") then child.ImageTransparency = 0.94 end
	end
	table.sort(rows, function(a, b) return a.Position.Y.Scale < b.Position.Y.Scale end)
	local rarity = if rows[3] then rows[3].TextColor3 else Color3.fromRGB(114, 172, 255)
	for _,root in {card, body} do
		local edge = root:FindFirstChildOfClass("UIStroke")
		if edge then edge.Color, edge.Thickness = rarity, 2 end
	end
	for i,row in rows do
		row.AnchorPoint = Vector2.zero
		row.Position = UDim2.fromScale(0.05, if i == 1 then 0.55 elseif i == 2 then 0.66 else 0.035)
		row.Size = UDim2.fromScale(0.90, if i == 1 then 0.11 else 0.08)
		row.TextScaled, row.TextWrapped = true, i == 1
		row.TextXAlignment = Enum.TextXAlignment.Center
		row.TextTruncate = Enum.TextTruncate.AtEnd
		if i == 2 then
			row.BackgroundTransparency = 0.2
			row.BackgroundColor3 = Color3.fromRGB(17, 20, 49)
			PanelStyle.corner(row, 6)
		elseif i == 3 then
			row.BackgroundTransparency = 0
			row.BackgroundColor3 = rarity:Lerp(Color3.fromRGB(16, 20, 44), 0.55)
			row.TextColor3 = Color3.new(1, 1, 1)
			PanelStyle.corner(row, 6)
		end
	end
	local holder = body:FindFirstChild("BrainrotFrame")
	local slot = holder and holder:FindFirstChild("1")
	if holder and holder:IsA("GuiObject") and slot and slot:IsA("GuiObject") then
		holder.AnchorPoint = Vector2.zero
		holder.Position, holder.Size = UDim2.fromScale(0, 0.13), UDim2.fromScale(1, 0.40)
		holder.BackgroundTransparency = 1
		slot.AnchorPoint, slot.Position, slot.Size = Vector2.zero, UDim2.fromScale(0.05, 0), UDim2.fromScale(0.9, 1)
		local aspect = slot:FindFirstChildOfClass("UIAspectRatioConstraint")
		if aspect then aspect:Destroy() end
		local slotEdge = slot:FindFirstChildOfClass("UIStroke")
		if slotEdge then slotEdge:Destroy() end
		local inner = slot:FindFirstChild("Frame")
		if inner and inner:IsA("GuiObject") then
			inner.AnchorPoint, inner.Position, inner.Size = Vector2.zero, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1)
			inner.BackgroundColor3, inner.BackgroundTransparency = Color3.fromRGB(18, 24, 53), 0
			local icon = inner:FindFirstChild("Icon")
			if icon and icon:IsA("ImageLabel") then
				local ratio = icon:FindFirstChildOfClass("UIAspectRatioConstraint")
				if ratio then ratio:Destroy() end
				icon.BackgroundTransparency = 1
				local border = icon:FindFirstChildOfClass("UIStroke")
				if border then border:Destroy() end
				icon.AnchorPoint, icon.Position, icon.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.45), UDim2.fromScale(0.95, 0.88)
			end
			local edge = inner:FindFirstChildOfClass("UIStroke")
			if edge then edge:Destroy() end
			PanelStyle.corner(inner, 8)
			for _,d in inner:GetChildren() do
				if d:IsA("UIGradient") or d:IsA("UIAspectRatioConstraint") then d:Destroy() end
			end
		end
		local earns = inner and inner:FindFirstChild("Earns")
		if earns and earns:IsA("TextLabel") then
			earns.AnchorPoint = Vector2.new(0.5, 1)
			earns.Position, earns.Size = UDim2.fromScale(0.5, 1), UDim2.fromScale(0.92, 0.23)
			earns.TextScaled = true
		end
	end
	local choose = body:FindFirstChild("Choose")
	if choose and choose:IsA("GuiObject") then
		choose.AnchorPoint, choose.Position = Vector2.zero, UDim2.fromScale(0.05, 0.76)
		choose.Size = UDim2.fromScale(0.90, 0.21)
		local layout = choose:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.Padding = UDim.new(0.04, 0)
		end
		for _,button in choose:GetChildren() do
			if button:IsA("GuiButton") then
				button.Size = UDim2.fromScale(0.48, 1)
				PanelStyle.corner(button, 10)
			end
		end
	end
	-- Imported pack strokes use relative thickness; our pixel borders must opt out.
	for _,d in card:GetDescendants() do
		if d:IsA("UIStroke") and d.Thickness >= 1 then d.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize end
	end
	ClipSafe.sanitize(card)
end

function InventoryPresentation.grid(list: ScrollingFrame)
	local old = list:FindFirstChildOfClass("UIListLayout")
	if old then old:Destroy() end
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = list
	list.ClipsDescendants = true
	ClipSafe.watch(list)
	local function fit()
		local factor = ClipSafe.scaleChain(list)
		local width = list.AbsoluteSize.X - 18
		local columns = math.clamp(math.floor((width + 12) / 220), 1, 4)
		grid.CellPadding = UDim2.fromOffset(12 / factor, 12 / factor)
		grid.CellSize = UDim2.fromOffset(math.max(1, (width - (columns - 1) * 12) / columns / factor), (if workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y < 500 then 220 else 280) / factor)
	end
	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	task.defer(fit)
end

return InventoryPresentation
