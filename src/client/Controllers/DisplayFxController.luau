--!strict
--[[
	DisplayFxController
	The ONE animation manager for base displays: trophies turn and bob, empty
	slots breathe, new pedestals pop in, and the owner sign says YOUR BASE on
	the plot that is yours.

	WHY ONE MANAGER
	Seven plots x fourteen slots is ninety-eight displays. A script per pedestal
	(the simulator default) is ninety-eight loops; this is one RenderStepped
	connection over a registry, and it only animates what is near the camera.
	Distant plots are re-checked twice a second and otherwise cost nothing.

	COSMETIC ONLY, CLIENT ONLY
	The server places every trophy and never moves it again (except a growth
	re-seat). Everything here is a local offset from that authored pose:
	rotation about the pedestal's axis and a small vertical bob. Nothing is
	replicated, nothing is physics, and nothing here can change what an item
	is or who owns it.

	REDUCED EFFECTS
	With the setting on: no pop-in, no bob, no breathing, sparkles off. The slow
	rotation stays - it is the one motion that makes a collection read as alive
	and it costs a CFrame per frame.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DisplayFxController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- TUNING
-- ==========================================================

--- Only displays within this many studs of the camera are animated.
local ANIMATE_DISTANCE = 260
--- How often the near/far set is re-evaluated.
local CULL_INTERVAL = 0.5

--- Radians per second for a Normal-sized item. Bigger items turn slower - a
--- Colossal should feel heavy, not spin like a coin.
local SPIN_BASE = 0.55
--- Bob amplitude in studs for a Normal-sized item; nothing above a Giant bobs.
local BOB_AMPLITUDE = 0.14
local BOB_PERIOD = 2.6
local BOB_MAX_SCALE = 2.6

--- Breathing on an empty slot's neon frame: transparency swings this far
--- either side of its rest value, over this period.
local BREATHE_SWING = 0.22
local BREATHE_PERIOD = 2.2

local POP = TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- ==========================================================
-- STATE
-- ==========================================================

type Display = {
	model: Model,
	slot: BasePart,
	base: CFrame?, -- the server's authored pivot, captured once
	growthSeen: number?, -- re-capture the base if the server re-seats it
	angle: number,
	phase: number,
	spin: number,
	bob: number,
	near: boolean,
}

local displays: { [Model]: Display } = {}
local emptySlots: { [BasePart]: boolean } = {}
local nearSlots: { [BasePart]: boolean } = {}
local reducedEffects = false
local lastCull = 0

function DisplayFxController.setReducedEffects(value: boolean)
	reducedEffects = value
	-- Sparkles are ParticleEmitters the server authored; switching them
	-- locally is a client-only change.
	for model in displays do
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("ParticleEmitter") and descendant.Name == "SizeSparkle" then
				descendant.Enabled = not value
			end
		end
	end
end

-- ==========================================================
-- REGISTRY
-- ==========================================================

local function popIn(model: Model)
	if reducedEffects then
		return
	end
	-- A trophy arriving under a reveal gets its entrance from the reveal
	-- itself (HatchController marks it the frame it replicates). Popping it
	-- in here as well would fight that bounce and could leave the item at the
	-- wrong size: this reads the rest scale mid-tween, that one settles last.
	if model:GetAttribute("RevealHold") then
		return
	end
	-- A local scale-in about the pivot. The server's sizes replicate back over
	-- ours if they change later, which is exactly the right thing.
	local from = model:GetScale()
	model:ScaleTo(from * 0.55)
	local value = Instance.new("NumberValue")
	value.Value = 0.55
	local tween = TweenService:Create(value, POP, { Value = 1 })
	value.Changed:Connect(function(v)
		if model.Parent then
			model:ScaleTo(from * v)
		end
	end)
	tween.Completed:Once(function()
		if model.Parent then
			model:ScaleTo(from)
		end
		value:Destroy()
	end)
	tween:Play()
end

local function registerTrophy(model: Model)
	local slot = model.Parent
	if not slot or not slot:IsA("BasePart") or displays[model] then
		return
	end
	local visual = tonumber(model:GetAttribute("VisualScale")) or 1
	displays[model] = {
		model = model,
		slot = slot,
		base = nil,
		growthSeen = tonumber(model:GetAttribute("GrowthApplied")),
		angle = math.random() * math.pi * 2,
		phase = math.random() * math.pi * 2,
		spin = SPIN_BASE / math.max(1, math.sqrt(visual)),
		bob = if visual <= BOB_MAX_SCALE then BOB_AMPLITUDE / math.max(1, visual) else 0,
		near = false,
	}
	if reducedEffects then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("ParticleEmitter") and descendant.Name == "SizeSparkle" then
				descendant.Enabled = false
			end
		end
	end
	popIn(model)
end

local function unregisterTrophy(model: Model)
	displays[model] = nil
end

local function watchSlot(slot: BasePart)
	local function refresh()
		emptySlots[slot] = slot:GetAttribute("SlotState") == "Empty"
	end
	refresh()
	slot:GetAttributeChangedSignal("SlotState"):Connect(refresh)
end

-- ==========================================================
-- OWNER SIGN
-- ==========================================================

local function refreshYourBase(plot: Instance)
	local sign = plot:FindFirstChild("OwnerSign")
	local board = sign and sign:FindFirstChild("Board")
	local gui = board and board:FindFirstChildOfClass("SurfaceGui")
	local badge = gui and gui:FindFirstChild("YourBase")
	if badge and badge:IsA("GuiObject") then
		badge.Visible = plot:GetAttribute("OwnerUserId") == player.UserId
	end
end

local function watchPlot(plot: Instance)
	local slots = plot:FindFirstChild("DisplaySlots")
	if slots then
		for _, slot in slots:GetChildren() do
			if slot:IsA("BasePart") then
				watchSlot(slot)
			end
		end
	end
	refreshYourBase(plot)
	plot:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		refreshYourBase(plot)
	end)
	plot.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "OwnerSign" or descendant.Name == "YourBase" then
			task.defer(refreshYourBase, plot)
		end
	end)
end

-- ==========================================================
-- THE LOOP
-- ==========================================================

local function cull(cameraPosition: Vector3)
	for _, display in displays do
		display.near = (display.slot.Position - cameraPosition).Magnitude <= ANIMATE_DISTANCE
	end
	table.clear(nearSlots)
	for slot, empty in emptySlots do
		if empty and (slot.Position - cameraPosition).Magnitude <= ANIMATE_DISTANCE then
			nearSlots[slot] = true
		end
	end
end

local function step(_dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local now = os.clock()
	if now - lastCull >= CULL_INTERVAL then
		lastCull = now
		cull(camera.CFrame.Position)
	end

	for model, display in displays do
		if not model.Parent then
			displays[model] = nil
			continue
		end
		-- EVERY display turns, near or far. The angle is a function of the
		-- clock, not a counter that only advanced while the camera was close,
		-- so a pedestal seen from the avenue is at exactly the angle it would
		-- have reached had it been watched the whole time - no frozen pose,
		-- no jump on approach. The near set still gates the extras below.

		-- Capture the authored pose the first time we touch it, and again if
		-- the server re-seated the model for growth.
		local growth = tonumber(model:GetAttribute("GrowthApplied"))
		if not display.base or growth ~= display.growthSeen then
			display.base = model:GetPivot()
			display.growthSeen = growth
			-- Continuous from the first frame: the turn starts from the
			-- authored pose and the bob from zero, so nothing jumps when a
			-- trophy begins to move.
			display.angle = -display.spin * now
			display.phase = -(now / BOB_PERIOD) * math.pi * 2
		end
		local base = display.base :: CFrame

		local angle = display.angle + display.spin * now
		local bob = if reducedEffects or display.bob <= 0 or not display.near
			then 0
			else math.sin((now / BOB_PERIOD) * math.pi * 2 + display.phase) * display.bob
		-- Turn about the pedestal's vertical axis (the slot centre), not the
		-- model's own pivot, so an off-centre import still orbits its stand.
		local slotX, slotZ = display.slot.Position.X, display.slot.Position.Z
		local about = CFrame.new(slotX, base.Position.Y, slotZ)
		local relative = about:ToObjectSpace(base)
		model:PivotTo(about * CFrame.Angles(0, angle, 0) * relative + Vector3.new(0, bob, 0))
	end

	if reducedEffects then
		return
	end
	-- Breathing frames, only on empty slots that are near.
	local swing = (math.sin((now / BREATHE_PERIOD) * math.pi * 2) * 0.5 + 0.5) * BREATHE_SWING
	for slot in nearSlots do
		local frame = slot:FindFirstChild("NeonFrame")
		if not frame then
			continue
		end
		local rest = tonumber(slot:GetAttribute("NeonRest")) or 0.2
		local transparency = math.clamp(rest - BREATHE_SWING / 2 + swing, 0, 1)
		for _, edge in frame:GetChildren() do
			if edge:IsA("BasePart") then
				edge.Transparency = transparency
			end
		end
	end
end

-- ==========================================================
-- START
-- ==========================================================

function DisplayFxController.start()
	local map = workspace:WaitForChild("Map", 30)
	local bases = map and map:WaitForChild("Bases", 15)
	if not bases then
		return
	end

	for _, plot in bases:GetChildren() do
		task.spawn(watchPlot, plot)
	end
	bases.ChildAdded:Connect(function(plot)
		task.spawn(watchPlot, plot)
	end)

	-- Trophies and pedestals arrive and leave as the server redraws a plot.
	for _, descendant in bases:GetDescendants() do
		if descendant:IsA("Model") and descendant.Name == "Trophy" then
			registerTrophy(descendant)
		end
	end
	bases.DescendantAdded:Connect(function(descendant)
		if not descendant:IsA("Model") then
			return
		end
		if descendant.Name == "Trophy" then
			-- A frame later: the server sets the pivot right after parenting.
			task.delay(0.05, function()
				if descendant.Parent then
					registerTrophy(descendant)
				end
			end)
		elseif descendant.Name == "Pedestal" then
			task.delay(0.05, function()
				if descendant.Parent then
					popIn(descendant)
				end
			end)
		end
	end)
	bases.DescendantRemoving:Connect(function(descendant)
		if descendant:IsA("Model") and descendant.Name == "Trophy" then
			unregisterTrophy(descendant)
		end
	end)

	-- Heartbeat, like the world crates: the turn keeps its full rate even when
	-- rendering is throttled (an unfocused Studio window, a phone in the
	-- background), and the one-frame latency against the render step is
	-- invisible at half a radian a second.
	RunService.Heartbeat:Connect(step)
end

return DisplayFxController
