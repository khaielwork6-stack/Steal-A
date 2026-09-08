--!strict
--[[
	ModelPreview
	A real 3D model inside a UI card: the Guardian and Weapon cards in
	Storage and the two right-side offers.

	ONE FRAMING FOR EVERY ANIMAL. Every preview is shot from the same
	three-quarter direction, with the same field of view and the same padding
	around the model's bounding sphere, so a cat and a tiger sit in their
	cards at the same apparent size and nothing clips.

	ONE LOOP FOR ALL OF THEM. Previews that ask to animate share a single
	RenderStepped connection that turns each model slowly about its own
	centre and bobs it; the connection exists only while at least one such
	preview is mounted.
]]

local RunService = game:GetService("RunService")

local ModelPreview = {}

local FOV = 34
local VIEW_DIRECTION = Vector3.new(1, 0.62, 1.25).Unit
local FIT = 1.15
local TURN_SPEED = 0.55 -- radians per second
local BOB_STUDS = 0.06

export type Handle = {
	viewport: ViewportFrame,
	model: Model,
	destroy: () -> (),
}

export type Options = {
	--- Extra room around the model (1 = tight). Default FIT.
	fit: number?,
	--- Slow turn and bob. Default true.
	animate: boolean?,
	--- Yaw, in radians, the source should be turned so it faces the camera's
	--- side. The animals are authored facing different axes; see
	--- BaseGuardianConfig.faceLocal and ModelPreview.yawFor.
	faceYaw: number?,
	--- Transparent background (default) or a plate colour.
	background: Color3?,
}

type Live = { model: Model, centre: Vector3, phase: number, baseYaw: number, rotation: CFrame }

local live: { [Live]: boolean } = {}
local loop: RBXScriptConnection? = nil

local function extents(root: Instance): (Vector3?, Vector3?)
	local min: Vector3? = nil
	local max: Vector3? = nil
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			local half = descendant.Size / 2
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local p = (descendant.CFrame * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
						min = if min then Vector3.new(math.min(min.X, p.X), math.min(min.Y, p.Y), math.min(min.Z, p.Z)) else p
						max = if max then Vector3.new(math.max(max.X, p.X), math.max(max.Y, p.Y), math.max(max.Z, p.Z)) else p
					end
				end
			end
		end
	end
	return min, max
end

local function step()
	local now = os.clock()
	for entry in live do
		local model = entry.model
		if not model.Parent then
			live[entry] = nil
			continue
		end
		local yaw = now * TURN_SPEED + entry.phase
		local bob = math.sin(now * 1.7 + entry.phase) * BOB_STUDS
		-- The pivot was moved onto the bounding centre when the preview was
		-- mounted, so this turns the model in place.
		model:PivotTo(CFrame.new(entry.centre + Vector3.new(0, bob, 0)) * CFrame.Angles(0, yaw, 0) * entry.rotation)
	end
	if next(live) == nil and loop then
		loop:Disconnect()
		loop = nil
	end
end

--- Strips anything that could run, make noise or draw UI out of a clone.
local function sanitise(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		elseif
			descendant:IsA("BaseScript")
			or descendant:IsA("Sound")
			or descendant:IsA("ProximityPrompt")
			or descendant:IsA("BillboardGui")
			or descendant:IsA("SurfaceGui")
			or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam")
			or descendant:IsA("Trail")
			or descendant:IsA("Light")
			or descendant:IsA("Humanoid")
		then
			descendant:Destroy()
		end
	end
end

--- Puts a clone of `source` into a ViewportFrame filling `host`, framed.
--- Returns nil when the source has no parts.
function ModelPreview.mount(host: GuiObject, source: Model, options: Options?): Handle?
	local opts: Options = options or {}

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "ModelPreview"
	viewport.BackgroundTransparency = if opts.background then 0 else 1
	viewport.BackgroundColor3 = opts.background or Color3.new(0, 0, 0)
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.Position = UDim2.fromScale(0.5, 0.5)
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.ZIndex = host.ZIndex + 1
	viewport.Ambient = Color3.fromRGB(150, 150, 160)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.6, -1, -0.4)
	local camera = Instance.new("Camera")
	camera.Name = "PreviewCamera"
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local model = source:Clone()
	model.Name = "Preview"
	sanitise(model)
	local rotation = CFrame.Angles(0, opts.faceYaw or 0, 0)
	model:PivotTo(rotation)
	model.Parent = world

	local min, max = extents(model)
	if not min or not max then
		viewport:Destroy()
		return nil
	end
	local centre = (min + max) / 2
	local radius = math.max((max - min).Magnitude / 2, 0.5)
	local distance = radius / math.sin(math.rad(FOV) / 2) * (opts.fit or FIT)
	camera.CFrame = CFrame.lookAt(centre + VIEW_DIRECTION * distance, centre)

	-- Pivot onto the bounding centre (the parts do not move), so the shared
	-- loop can turn the model in place rather than orbit it around wherever
	-- the import's pivot happened to be.
	model.WorldPivot = CFrame.new(centre) * rotation

	viewport.Parent = host

	local entry: Live? = nil
	if opts.animate ~= false then
		entry = { model = model, centre = centre, phase = math.random() * math.pi * 2, baseYaw = opts.faceYaw or 0, rotation = rotation }
		live[entry :: Live] = true
		if not loop then
			loop = RunService.RenderStepped:Connect(step)
		end
	end

	local handle: Handle = {
		viewport = viewport,
		model = model,
		destroy = function()
			if entry then
				live[entry :: Live] = nil
			end
			viewport:Destroy()
		end,
	}
	return handle
end

--- Yaw, in radians, that turns a model authored facing `faceLocal` (in its
--- own pivot space) to face -Z: the direction every rig treats as forward.
function ModelPreview.yawFor(faceLocal: Vector3?): number
	if not faceLocal then
		return 0
	end
	local flat = Vector3.new(faceLocal.X, 0, faceLocal.Z)
	if flat.Magnitude < 0.01 then
		return 0
	end
	return math.atan2(flat.X, -flat.Z)
end

return ModelPreview
