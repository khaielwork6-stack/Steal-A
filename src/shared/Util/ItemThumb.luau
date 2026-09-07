--!strict
--[[
	ItemThumb
	How a loot item is drawn inside a UI card.

	THE REAL MODEL, NOT A SWATCH. The server publishes every item's art under
	ReplicatedStorage.LootPreviews (LootModel.publishPreviews); a card clones
	its item into a ViewportFrame laid over the pack's icon plate and frames it
	from a three-quarter angle. What the Index shows is the thing the player
	steals. An item with no published art (two ids ship without a model) falls
	back to the rarity-coloured plate it always had.

	UNDISCOVERED ITEMS ARE SILHOUETTES. The same model, lit with black light
	on a dark plate: the shape is there to tease, the detail is not, and the
	plate never takes the rarity colour - that would give away how rare a thing
	is before it has been found.

	Both the Storage panel and the Loot Index route through here, so the two
	can never draw the same item differently.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local ItemThumb = {}

local DEFAULT = Color3.fromRGB(198, 205, 216)
local EDGE = Color3.fromRGB(18, 20, 26)
local PLATE_UNKNOWN = Color3.fromRGB(44, 48, 58)
local PLATE_KNOWN = Color3.fromRGB(28, 32, 44)

--- Camera framing: field of view and the three-quarter direction the item is
--- seen from (a little from above, from the front-right).
local FOV = 38
local VIEW_DIRECTION = Vector3.new(1, 0.75, 1.15).Unit
local FIT = 1.12

local function plate(icon: ImageLabel, color: Color3)
	icon.Image = ""
	icon.ImageTransparency = 0
	icon.BackgroundTransparency = 0
	icon.BackgroundColor3 = color

	if not icon:FindFirstChildOfClass("UICorner") then
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0.18, 0)
		round.Parent = icon
	end
	if not icon:FindFirstChildOfClass("UIStroke") then
		local edge = Instance.new("UIStroke")
		edge.Thickness = 2
		edge.Color = EDGE
		edge.Parent = icon
	end
end

--- The viewport inside the plate, made once per icon and reused.
local function viewportOf(icon: ImageLabel): ViewportFrame
	local existing = icon:FindFirstChild("Preview")
	if existing and existing:IsA("ViewportFrame") then
		return existing
	end
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview"
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.fromScale(0.92, 0.92)
	viewport.Position = UDim2.fromScale(0.5, 0.5)
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.ZIndex = icon.ZIndex + 1
	viewport.Ambient = Color3.fromRGB(140, 140, 150)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.6, -1, -0.4)
	viewport.Parent = icon
	local camera = Instance.new("Camera")
	camera.Name = "PreviewCamera"
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	return viewport
end

--- Frames the model: camera on the view direction, far enough back that the
--- model's bounding sphere fits the field of view with a little air.
local function frame(viewport: ViewportFrame, model: Model)
	local camera = viewport.CurrentCamera
	if not camera then
		return
	end
	local min, max = LootModel.worldExtents(model)
	if not min or not max then
		return
	end
	local centre = (min + max) / 2
	local radius = math.max((max - min).Magnitude / 2, 0.5)
	local distance = radius / math.sin(math.rad(FOV) / 2) * FIT
	camera.CFrame = CFrame.lookAt(centre + VIEW_DIRECTION * distance, centre)
end

--- Puts (or replaces) the item's model in the icon's viewport. Returns the
--- clone so a caller may turn it; nil when the item has no published art.
local function place(icon: ImageLabel, itemId: string, silhouette: boolean): Model?
	local source = LootModel.previewSource(itemId)
	if not source then
		return nil
	end
	local viewport = viewportOf(icon)
	for _, child in viewport:GetChildren() do
		if child:IsA("Model") then
			child:Destroy()
		end
	end

	local clone = source:Clone()
	clone.Name = "Item"
	if silhouette then
		-- Black light on every surface: textures multiply to black, so the
		-- outline reads and nothing else does. Neon and glowing materials
		-- ignore light, so they are flattened too.
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Color = Color3.new(0, 0, 0)
				descendant.Material = Enum.Material.SmoothPlastic
				descendant.Transparency = math.min(descendant.Transparency, 0.1)
			elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
				descendant.Transparency = 1
			elseif descendant:IsA("SurfaceAppearance") or descendant:IsA("ParticleEmitter") or descendant:IsA("Light") then
				descendant:Destroy()
			end
		end
		viewport.Ambient = Color3.new(0, 0, 0)
		viewport.LightColor = Color3.new(0, 0, 0)
	else
		viewport.Ambient = Color3.fromRGB(140, 140, 150)
		viewport.LightColor = Color3.fromRGB(255, 250, 240)
	end
	clone:PivotTo(CFrame.new())
	clone.Parent = viewport
	frame(viewport, clone)
	return clone
end

--- Paints `icon` as the thumbnail for an item. With an `itemId` whose art is
--- published, the real model on a dark plate; otherwise the rarity swatch.
--- Idempotent: safe to call on a card that has already been painted.
function ItemThumb.apply(icon: ImageLabel, rarity: string?, itemId: string?): Model?
	local color = RarityConfig.Colors[rarity or "Common"] or DEFAULT
	local model = if itemId then place(icon, itemId, false) else nil
	if model then
		plate(icon, PLATE_KNOWN)
		local edge = icon:FindFirstChildOfClass("UIStroke")
		if edge then
			edge.Color = color
		end
		return model
	end
	local stale = icon:FindFirstChild("Preview")
	if stale then
		stale:Destroy()
	end
	plate(icon, color)
	return nil
end

--- The undiscovered state: the model as a black silhouette on an unlit plate,
--- or the plain unlit plate when there is no art. Deliberately never a dimmed
--- rarity colour - that would leak how rare an item is before it is found.
function ItemThumb.applyUnknown(icon: ImageLabel, itemId: string?): Model?
	local model = if itemId then place(icon, itemId, true) else nil
	if not model then
		local stale = icon:FindFirstChild("Preview")
		if stale then
			stale:Destroy()
		end
	end
	plate(icon, PLATE_UNKNOWN)
	local edge = icon:FindFirstChildOfClass("UIStroke")
	if edge then
		edge.Color = EDGE
	end
	return model
end

--- Turns a placed model in its viewport. Cheap enough to run on the handful
--- of cards a panel shows at once; callers own the cadence.
function ItemThumb.turn(model: Model, radians: number)
	if model.Parent then
		model:PivotTo(model:GetPivot() * CFrame.Angles(0, radians, 0))
	end
end

return ItemThumb
