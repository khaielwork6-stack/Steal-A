--!strict
-- Restyles bound rows; the mixer, save and toggle callbacks stay with SettingsController.
local RS = game:GetService("ReplicatedStorage")
local PanelStyle = require(RS.Shared.Util.PanelStyle)
local UiArtConfig = require(RS.Shared.Config.UiArtConfig)
local SettingsPresentation = {}

function SettingsPresentation.row(row: GuiObject)
	local body = row:FindFirstChild("Frame")
	if not body or not body:IsA("Frame") then return end
	row.BackgroundTransparency = 1
	body.BackgroundColor3, body.BackgroundTransparency = Color3.new(1, 1, 1), 0
	PanelStyle.corner(body, 12)
	PanelStyle.gradient(body, Color3.fromRGB(62, 81, 155), Color3.fromRGB(35, 42, 93))
	for _,p in body:GetChildren() do
		if p:IsA("ImageLabel") then p.ImageTransparency = if p.Name == "Studs" then 0.94 else 1 end
	end
	local icons = body:FindFirstChild("Icon")
	if icons and icons:IsA("CanvasGroup") then
		local holder = Instance.new("Frame")
		holder.Name, holder.BackgroundTransparency = "Icon", 1
		holder.Size, holder.Position, holder.AnchorPoint, holder.ZIndex = icons.Size, icons.Position, icons.AnchorPoint, icons.ZIndex
		for _,child in icons:GetChildren() do child.Parent = holder end
		icons:Destroy()
		holder.Parent = body
		icons = holder
	end
	if icons then for _,icon in icons:GetChildren() do
		if icon:IsA("ImageLabel") then
			local art = (UiArtConfig.Settings :: { [string]: string })[row.Name]
			if art and art ~= "rbxassetid://0" then icon.Image = art end
			icon.Size, icon.Position = UDim2.fromScale(0.09, 0.7), UDim2.fromScale(0.07, 0.5)
			icon.ScaleType = Enum.ScaleType.Fit
		end
	end end
	local title = body:FindFirstChild("Multiplier1")
	if title and title:IsA("TextLabel") then
		title.AnchorPoint = Vector2.new(0, 0.5)
		title.Position, title.Size = UDim2.fromScale(0.14, 0.5), UDim2.fromScale(0.39, 0.6)
		title.TextXAlignment = Enum.TextXAlignment.Left
	end
	local choose = body:FindFirstChild("Choose")
	if choose and choose:IsA("GuiObject") then
		choose.AnchorPoint = Vector2.new(1, 0.5)
		choose.Position, choose.Size = UDim2.fromScale(0.97, 0.5), UDim2.fromScale(0.4, 0.70)
		for _,layout in choose:GetChildren() do if layout:IsA("UILayout") then layout:Destroy() end end
		for i,name in {"ON", "OFF"} do
			local b = choose:FindFirstChild(name)
			if b and b:IsA("GuiButton") then
				local aspect = b:FindFirstChildOfClass("UIAspectRatioConstraint")
				if aspect then aspect:Destroy() end
				b.AnchorPoint, b.Position = Vector2.zero, UDim2.fromScale((i - 1) * 0.52, 0)
				b.Size = UDim2.fromScale(0.48, 1)
				PanelStyle.corner(b, 20)
				for _,d in b:GetDescendants() do
					if d:IsA("ImageLabel") then d.ImageTransparency = 1
					elseif d:IsA("GuiObject") and d.Name == "Frame" then
						d.AnchorPoint, d.Position, d.Size = Vector2.zero, UDim2.new(), UDim2.fromScale(1, 1)
						PanelStyle.corner(d, 20)
					end
				end
				for _,d in b:GetDescendants() do
					if d:IsA("TextLabel") and d.Name ~= "Word" then d.Visible = false end
				end
			end
		end
	end
	local track = body:FindFirstChild("Zipper")
	if track and track:IsA("GuiObject") then
		track.Position, track.Size = UDim2.fromScale(0.59, 0.6), UDim2.fromScale(0.7, 0.22)
		local fill = track:FindFirstChildOfClass("Frame")
		if fill then
			local knob = fill:FindFirstChildOfClass("CanvasGroup")
			if knob then
				knob.Size = UDim2.fromOffset(36, 36)
				knob.BackgroundTransparency = 0
				knob.BackgroundColor3 = Color3.fromRGB(245, 252, 255)
				PanelStyle.corner(knob, 18)
				for _,d in knob:GetChildren() do
					if d:IsA("GuiButton") then d.Visible = false
					elseif d:IsA("TextLabel") then
						d.BackgroundTransparency = 1
						d.TextColor3 = Color3.fromRGB(23, 38, 88)
						d.Size = UDim2.fromScale(0.85, 0.85)
					end
				end
			end
		end
		local titleLabel = Instance.new("TextLabel")
		titleLabel.Name = "SettingName"
		titleLabel.BackgroundTransparency = 1
		titleLabel.Position, titleLabel.Size = UDim2.fromScale(0.22, 0.05), UDim2.fromScale(0.7, 0.25)
		titleLabel.Text = if row.Name == "Music" then "MUSIC VOLUME" else "SOUND EFFECTS"
		titleLabel.Font, titleLabel.TextSize = Enum.Font.FredokaOne, 14
		titleLabel.TextColor3 = Color3.fromRGB(215, 236, 255)
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.ZIndex = 7
		titleLabel.Parent = body
	end
end

return SettingsPresentation
