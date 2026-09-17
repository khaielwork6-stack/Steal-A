--!strict
-- Presentation shared by the Round 3 panels. Sizes below are SCREEN pixels,
-- so MainUI's phone UIScale cannot quietly shrink a 44px action into a 30px one.
local ClipSafe = require(script.Parent.ClipSafe)
local PanelStyle = {}

function PanelStyle.corner(object: GuiObject, radius: number)
	local c = object:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = object
end

function PanelStyle.gradient(object: GuiObject, top: Color3, bottom: Color3)
	local g = object:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(top, bottom)
	g.Parent = object
end

function PanelStyle.window(frame: Frame, width: number, height: number)
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.BackgroundTransparency = 0
	PanelStyle.gradient(frame, Color3.fromRGB(43, 56, 116), Color3.fromRGB(21, 23, 60))
	PanelStyle.corner(frame, 16)
	-- The pack fades the outer frame during opening; keep its content plate opaque.
	local plate = Instance.new("Frame")
	plate.Name, plate.BorderSizePixel = "PanelPlate", 0
	plate.Size = UDim2.fromScale(1, 1)
	plate.BackgroundColor3 = Color3.new(1, 1, 1)
	plate.ZIndex = 20
	PanelStyle.corner(plate, 16)
	PanelStyle.gradient(plate, Color3.fromRGB(43, 56, 116), Color3.fromRGB(21, 23, 60))
	plate.Parent = frame
	-- Global ZIndex in the purchased pack otherwise leaves the cash/hotbar above cards.
	local function layer(d: Instance)
		if d:IsA("GuiObject") and d ~= plate and not d:GetAttribute("PanelLayered") then
			d:SetAttribute("PanelLayered", true)
			d.ZIndex += 20
		end
	end
	layer(frame)
	for _,d in frame:GetDescendants() do layer(d) end
	frame.DescendantAdded:Connect(function(d) task.defer(layer, d) end)
	for _,d in frame:GetChildren() do
		if d:IsA("ImageLabel") then d.ImageTransparency = 1 end
	end
	local edge = frame:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	edge.Color, edge.Thickness = Color3.fromRGB(15, 12, 30), 3
	edge.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
	edge.Parent = frame
	local aspect = frame:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then aspect:Destroy() end
	local function fit()
		local camera = workspace.CurrentCamera
		if not camera or not frame.Parent then return end
		local viewport = camera.ViewportSize
		local factor = ClipSafe.scaleChain(frame)
		frame.Size = UDim2.fromOffset(math.min(width, viewport.X - 32) / factor, math.min(height, viewport.Y - (if viewport.Y < 500 then 16 else 88)) / factor)
		local top = frame:FindFirstChild("Top")
		if top and top:IsA("GuiObject") then
			local ratio = top:FindFirstChildOfClass("UIAspectRatioConstraint")
			if ratio then ratio:Destroy() end
			top.AnchorPoint, top.Position = Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0)
			top.Size = UDim2.new(1, 0, 0, (if viewport.Y < 500 then 52 else 64) / factor)
			local close = top:FindFirstChild("Close", true)
			if close and close:IsA("GuiButton") then
				close.Size = UDim2.fromOffset(48 / factor, 48 / factor)
			end
		end
	end
	frame:GetPropertyChangedSignal("Visible"):Connect(fit)
	local camera = workspace.CurrentCamera
	if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit) end
	frame.AncestryChanged:Connect(fit)
	task.defer(fit)
end

-- Reflow a ShopKit clone; its existing buy button and handlers remain intact.
function PanelStyle.productCard(card: Frame)
	local aspect = card:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then aspect:Destroy() end
	PanelStyle.corner(card, 12)
	local body = card:FindFirstChild("Frame")
	if not body or not body:IsA("Frame") then return end
	PanelStyle.corner(body, 10)
	for _,d in body:GetChildren() do
		if d:IsA("ImageLabel") then d.ImageTransparency = 0.93 end
	end
	local title = body:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.AnchorPoint = Vector2.zero
		title.Position, title.Size = UDim2.fromScale(0.05, 0.035), UDim2.fromScale(0.9, 0.18)
		title.TextWrapped = true
	end
	local description = body:FindFirstChild("Description")
	if description and description:IsA("TextLabel") then
		description.AnchorPoint = Vector2.zero
		description.Position, description.Size = UDim2.fromScale(0.40, 0.26), UDim2.fromScale(0.56, 0.35)
	end
	local icons = body:FindFirstChild("Icon")
	if icons then for _,d in icons:GetChildren() do
		if d:IsA("ImageLabel") then
			d.AnchorPoint = Vector2.new(0.5, 0.5)
			d.Position, d.Size = UDim2.fromScale(0.21, 0.58), UDim2.fromScale(0.32, 0.62)
			d.ScaleType = Enum.ScaleType.Fit
		end
	end end
	local choose = body:FindFirstChild("Choose")
	if choose and choose:IsA("GuiObject") then
		choose.AnchorPoint = Vector2.zero
		choose.Position, choose.Size = UDim2.fromScale(0.4, 0.70), UDim2.fromScale(0.55, 0.27)
		local buy = choose:FindFirstChild("Buy")
		if buy and buy:IsA("GuiButton") then
			local ratio = buy:FindFirstChildOfClass("UIAspectRatioConstraint")
			if ratio then ratio:Destroy() end
			buy.Size = UDim2.fromScale(1, 1)
		end
	end
	ClipSafe.sanitize(card)
end

return PanelStyle
