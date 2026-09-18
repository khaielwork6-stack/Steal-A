--!strict
--[[
	GuardianFxController
	The floating Zzz while a guardian sleeps, the "!" pop when it wakes, and the
	red alert flash across its whole body.

	Runs entirely on the client, driven by the guardian model's `State`
	attribute. Twelve looping effects therefore cost the server nothing and
	generate no network traffic.

	HEIGHT IS MEASURED, NOT ASSUMED. Both billboards used to hang a fixed 3.4
	and 4.2 studs over the HumanoidRootPart. That is right for a stock R6 rig
	and wrong for every imported boss: the Mummy, the Bodybuilder and the rest
	are far taller, so their Zzz sat inside the chest and read as missing. The
	offset now comes from the model's own bounding box, once, when it is first
	seen.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GuardianFxController = {}

local SLEEP_COLOR = Color3.fromRGB(180, 226, 255)
local ALERT_COLOR = Color3.fromRGB(255, 74, 74)
--- Clear air over the tallest point of the rig, for the Zzz.
local ZZZ_HEADROOM = 1.6
--- The "!" sits a little higher again so the two never overlap on a wake.
local ALERT_HEADROOM = 2.6
--- How red the body goes at the peak of the alert. 0 is opaque paint; this is
--- a wash that still shows the costume underneath.
local FLASH_FILL = 0.45
local FLASH_PULSE = 0.28
--- Matches the Zzz billboard's MaxDistance: beyond this nothing would render.
local PUFF_VISIBLE_DISTANCE = 320

-- ==========================================================
-- THE COSTUME POSE (moved here from the server, security pass B8b)
-- ==========================================================
--
-- The server used to write every guardian's ShellMotor.C0 every frame - a
-- replicated property change per guard per frame for a purely cosmetic sway.
-- It now writes only a rest pose when the state changes, and each client
-- plays the motion locally from the replicated `State` attribute. The numbers
-- are the server's old ones, unchanged: MUSEUM_POSE for the zone guards
-- (GuardianService), BASE_POSE for the base animals (BaseGuardianService).
-- A local write to a Weld's C0 moves only this client's view of the costume;
-- physics and the catch stay on the server's invisible root.

type PoseTuning = { cycle: number, bob: number, roll: number, yaw: number, lean: number, walkLean: number }
local MUSEUM_POSE: PoseTuning = {
	cycle = 15, bob = 0.85, roll = math.rad(17), yaw = math.rad(11), lean = math.rad(-24), walkLean = math.rad(-7),
}
local BASE_POSE: PoseTuning = {
	cycle = 14, bob = 0.5, roll = math.rad(12), yaw = math.rad(8), lean = math.rad(-16), walkLean = math.rad(-6),
}
--- BaseGuardianService.ATTACK_SECONDS: the swipe after an `AttackAt` stamp.
local BASE_ATTACK_SECONDS = 0.35
--- Guardians further than this from the camera are not animated at all.
local POSE_DISTANCE = 400

type Posed = { model: Model, root: BasePart, motor: Weld, base: boolean }
local posed: { [Model]: Posed } = {}

local function poseFor(entry: Posed, now: number): CFrame
	local model = entry.model
	if model:GetAttribute("PetAnimationActive") == true then return CFrame.identity end
	local state = model:GetAttribute("State")
	local walking = model:GetAttribute("PoseWalkTrack") == true
	local tuning = if entry.base then BASE_POSE else MUSEUM_POSE

	if entry.base then
		local attackAt = model:GetAttribute("AttackAt")
		if type(attackAt) == "number" then
			local since = workspace:GetServerTimeNow() - attackAt
			if since >= 0 and since < BASE_ATTACK_SECONDS then
				local t = since / BASE_ATTACK_SECONDS
				local lunge = math.sin(math.min(1, t * 1.6) * math.pi)
				return CFrame.new(0, 0.2 * lunge, -0.9 * lunge) * CFrame.Angles(math.rad(-34) * lunge, 0, 0)
			end
		end
		if state == "Idle" then
			local breathe = math.sin(now * 1.6) * 0.06
			return CFrame.new(0, breathe, 0) * CFrame.Angles(math.sin(now * 0.8) * math.rad(1.5), 0, 0)
		elseif state == "Alert" then
			local shake = math.sin(now * 46) * math.rad(6)
			return CFrame.new(0, 0.25, 0) * CFrame.Angles(math.rad(-8), shake, shake * 0.6)
		end
	else
		if state == "Sleeping" then
			local breathe = math.sin(now * 1.5) * 0.07
			return CFrame.new(0, breathe, 0) * CFrame.Angles(math.rad(14), 0, 0)
		elseif state == "Waking" then
			local shake = math.sin(now * 46) * math.rad(7)
			return CFrame.new(0, 0.25, 0) * CFrame.Angles(math.rad(-8), shake, shake * 0.6)
		elseif state == "Searching" then
			-- gadgets-patrols: lost the thief in the smoke, peering about.
			return CFrame.new(0, 0.1, 0) * CFrame.Angles(math.rad(-4), math.sin(now * 3) * math.rad(18), 0)
		elseif state == "Patrolling" and not walking then
			-- A stroll, not the comic sprint: slow, small bob, no lean.
			local t = now * tuning.cycle * 0.35
			return CFrame.new(0, math.abs(math.sin(t)) * tuning.bob * 0.3, 0)
				* CFrame.Angles(tuning.walkLean, math.sin(t * 0.5) * tuning.yaw * 0.4, math.sin(t * 0.5) * tuning.roll * 0.3)
		end
	end

	if walking then
		return CFrame.Angles(tuning.walkLean, 0, 0)
	end
	local t = now * tuning.cycle
	local bob = math.abs(math.sin(t)) * tuning.bob
	local roll = math.sin(t * 0.5) * tuning.roll
	local yaw = math.sin(t * 0.5 + 1.1) * tuning.yaw
	return CFrame.new(0, bob, 0) * CFrame.Angles(tuning.lean, yaw, roll)
end

local function stepPoses()
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else nil
	local now = os.clock()
	for model, entry in posed do
		if not model.Parent or not entry.root.Parent or not entry.motor.Parent then
			posed[model] = nil
			continue
		end
		if eye and (entry.root.Position - eye).Magnitude > POSE_DISTANCE then
			continue
		end
		entry.motor.C0 = poseFor(entry, now)
	end
end

--- One rising, fading "Z" / "Zz" / "Zzz" puff.
local function puff(adornee: BasePart, stage: number, headY: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "ZzzPuff"
	gui.Size = UDim2.fromScale(4, 4)
	gui.StudsOffsetWorldSpace = Vector3.new(0.6, headY, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 320
	gui.Adornee = adornee
	gui.Parent = adornee

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = SLEEP_COLOR
	text.TextStrokeTransparency = 0.4
	text.Text = string.rep("z", stage - 1) ~= "" and ("Z" .. string.rep("z", stage - 1)) or "Z"
	text.Parent = gui

	-- Drift up and to the side while fading out.
	local rise = TweenService:Create(gui, TweenInfo.new(2.2, Enum.EasingStyle.Linear), {
		StudsOffsetWorldSpace = Vector3.new(2.4, headY + 5, 0),
	})
	local fade = TweenService:Create(text, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	rise:Play()
	fade:Play()

	task.delay(2.3, function()
		gui:Destroy()
	end)
end

local function alertPop(adornee: BasePart, headY: number, symbol: string?, color: Color3?)
	local gui = Instance.new("BillboardGui")
	gui.Name = "AlertPop"
	gui.Size = UDim2.fromScale(0.5, 0.5)
	gui.StudsOffsetWorldSpace = Vector3.new(0, headY, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 400
	gui.Adornee = adornee
	gui.Parent = adornee

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = color or ALERT_COLOR
	text.TextStrokeTransparency = 0.15
	text.Text = symbol or "!"
	text.Parent = gui

	TweenService:Create(gui, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(4.5, 4.5),
	}):Play()

	task.delay(1.4, function()
		local out = TweenService:Create(text, TweenInfo.new(0.3), { TextTransparency = 1, TextStrokeTransparency = 1 })
		out:Play()
		out.Completed:Wait()
		gui:Destroy()
	end)
end

--- gadgets-patrols: the grey "?" over a guard that lost its thief in smoke.
local SEARCH_COLOR = Color3.fromRGB(200, 206, 220)
local function searchPop(adornee: BasePart, headY: number)
	alertPop(adornee, headY, "?", SEARCH_COLOR)
end

--- The whole body goes red for a beat. A Highlight covers every part of a rig
--- at once, including accessories, and touches none of their own colours or
--- materials - so nothing can be left red if this is interrupted. One per
--- model: a second alert while the first is still fading reuses it rather than
--- stacking a brighter one.
local function alertFlash(model: Model)
	local existing = model:FindFirstChild("AlertFlash")
	local highlight = if existing and existing:IsA("Highlight") then existing else Instance.new("Highlight")
	highlight.Name = "AlertFlash"
	highlight.FillColor = ALERT_COLOR
	highlight.OutlineColor = ALERT_COLOR
	highlight.FillTransparency = FLASH_FILL
	highlight.OutlineTransparency = 0.2
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = model

	local token = (model:GetAttribute("AlertFlashToken") or 0) + 1
	model:SetAttribute("AlertFlashToken", token)

	task.spawn(function()
		-- Two pulses, then out. Tweened rather than set, so it reads as a
		-- heartbeat instead of a strobe.
		for _ = 1, 2 do
			if model:GetAttribute("AlertFlashToken") ~= token or not highlight.Parent then
				return
			end
			TweenService:Create(highlight, TweenInfo.new(FLASH_PULSE), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
			task.wait(FLASH_PULSE)
			if model:GetAttribute("AlertFlashToken") ~= token or not highlight.Parent then
				return
			end
			TweenService:Create(highlight, TweenInfo.new(FLASH_PULSE), { FillTransparency = FLASH_FILL, OutlineTransparency = 0.2 }):Play()
			task.wait(FLASH_PULSE)
		end
		if model:GetAttribute("AlertFlashToken") ~= token then
			return
		end
		local out = TweenService:Create(highlight, TweenInfo.new(0.35), { FillTransparency = 1, OutlineTransparency = 1 })
		out:Play()
		out.Completed:Wait()
		if model:GetAttribute("AlertFlashToken") == token and highlight.Parent then
			highlight:Destroy()
		end
	end)
end

local function clearPuffs(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BillboardGui") and descendant.Name == "ZzzPuff" then
			descendant:Destroy()
		end
	end
end

--- One guardian, for as long as it exists. The inner loop runs while its parts
--- are here; the outer loop waits for them to come back if they go away.
---
--- WHY THE OUTER LOOP EXISTS. This used to be a single `WaitForChild(root, 15)`
--- and a Heartbeat connection, and it is why the far bosses had no Zzz: with
--- streaming on, a guardian at the end of the world has NO PARTS on a client
--- standing in the lobby - measured, Grandma, the Foreman and Airport Security
--- all replicate as an empty model - so the wait timed out, the watcher
--- returned, and that boss never slept again for the rest of the session, even
--- once the player walked up to it. Waiting again is the whole fix.
local function runEffects(model: Model, root: BasePart)
	-- MEASURED WHEN USED, not once. GetBoundingBox covers the whole rig, hats
	-- included, so a 5-stud Cop and a 37-stud boss both get their billboard in
	-- clear air over the top of the model - but a model that is still
	-- STREAMING IN measures short (the Foreman came out 4 studs low when this
	-- was cached at stream-in), so it is re-read at the moment a billboard is
	-- made. That is once per 0.85s per visible guardian, and only when the
	-- camera is close enough to draw one.
	local function headroom(): number
		local boxCFrame, boxSize = model:GetBoundingBox()
		return (boxCFrame.Position.Y + boxSize.Y / 2) - root.Position.Y
	end

	-- The costume pose, if this rig has one (placeholder bodies do not).
	local motor = root:FindFirstChild("ShellMotor")
	if motor and motor:IsA("Weld") then
		posed[model] = { model = model, root = root, motor = motor, base = model:GetAttribute("BaseGuardian") == true }
	end

	local stage = 0
	local previous = model:GetAttribute("State")
	local base = model:GetAttribute("BaseGuardian") == true

	-- STATE CHANGES ARE EVENTS, not a per-frame poll (security pass B8b):
	-- this used to read the attribute on every Heartbeat for every guardian.
	local changed = model:GetAttributeChangedSignal("State"):Connect(function()
		local state = model:GetAttribute("State")
		if state == previous then
			return
		end
		local wasSleeping = previous == "Sleeping"
		local wasAlert = previous == "Alert"
		previous = state

		-- A base guardian never sleeps; it goes from Idle straight to Alert
		-- when an intruder steps onto the plot. Same "!" and the same red
		-- flash as a boss waking, once per alert.
		if state == "Alert" and not wasAlert then
			alertPop(root, headroom() + ALERT_HEADROOM)
			alertFlash(model)
		end
		if wasSleeping and state ~= "Sleeping" then
			-- Woke up: kill the Zzz immediately, then react. Going out on
			-- patrol (gadgets-patrols) is not an alert.
			clearPuffs(model)
			if state ~= "Patrolling" then
				alertPop(root, headroom() + ALERT_HEADROOM)
				alertFlash(model)
			end
		elseif (state :: any) == "Waking" and not base then
			-- A patrolling (or walking-home) guard raising the alarm gets
			-- the same "!" a sleeping one does.
			alertPop(root, headroom() + ALERT_HEADROOM)
			alertFlash(model)
		end
		if state == "Searching" then
			searchPop(root, headroom() + ALERT_HEADROOM)
		end
	end)

	-- The Zzz cadence is the only timed thing left: one puff every 0.85s
	-- while asleep, and a cheap wait otherwise.
	while model.Parent and root.Parent do
		if model:GetAttribute("State") == "Sleeping" then
			stage = stage % 3 + 1
			-- Twelve sleepers each spawning a billboard every 0.85s is a
			-- steady trickle of instances for the whole session, and the
			-- ones past the billboard's own MaxDistance are never drawn.
			-- Keep the cadence, skip the object.
			local camera = workspace.CurrentCamera
			if not camera or (camera.CFrame.Position - root.Position).Magnitude <= PUFF_VISIBLE_DISTANCE then
				puff(root, stage, headroom() + ZZZ_HEADROOM)
			end
		end
		task.wait(0.85)
	end

	changed:Disconnect()
	if posed[model] and posed[model].root == root then
		posed[model] = nil
	end
end

local function watch(model: Model)
	while model.Parent do
		local root = model:FindFirstChild("HumanoidRootPart")
		if not root then
			-- No timeout: a guardian twenty zones away simply has not streamed
			-- in yet, and will.
			root = model:WaitForChild("HumanoidRootPart", 20)
		end
		if root and root:IsA("BasePart") then
			runEffects(model, root)
		end
		task.wait(1)
	end
end

function GuardianFxController.start()
	local holder = workspace:WaitForChild("Guardians", 30)
	if not holder then
		return
	end

	-- One loop poses every nearby guardian's costume, before the frame renders.
	RunService.RenderStepped:Connect(stepPoses)

	for _, model in holder:GetChildren() do
		if model:IsA("Model") then
			task.spawn(watch, model)
		end
	end
	holder.ChildAdded:Connect(function(model)
		if model:IsA("Model") then
			task.spawn(watch, model)
		end
	end)
end

return GuardianFxController
