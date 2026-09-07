--!strict
--[[
	SettingsController
	Every control on the pack's Settings panel, wired to something real.

	  Music slider         -> the Music mixer bus (lobby and chase music)
	  Sound Effects slider -> the SFX mixer bus (UI, events, world sounds)
	  Shadows ON / OFF     -> Lighting.GlobalShadows on this client
	  VFX ON / OFF         -> Reduced Effects: OFF disables pop-ins, bobbing,
	                          breathing frames, size sparkles and the Night
	                          lighting tween (it snaps instead). Nothing that
	                          carries gameplay information is ever hidden.

	The pack shipped these rows as art with no logic: the third row was even
	labelled "Textures" over a frame named "Shadows". There is no texture
	toggle in this game, so the label now says what the row does.

	Applied locally the instant a control moves; saved through SettingsRequest
	so it survives a rejoin; restored from StatePush.settings on join. Roblox's
	own volume is untouched - these are mixer buses inside the game.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local DisplayFxController = require(script.Parent.DisplayFxController)
local NightController = require(script.Parent.NightController)
local WorldLootFxController = require(script.Parent.WorldLootFxController)

local SettingsController = {}

local player = Players.LocalPlayer

type Settings = { MusicVolume: number, SfxVolume: number, Shadows: boolean, ReducedVFX: boolean }

local current: Settings = { MusicVolume = 0.7, SfxVolume = 0.8, Shadows = true, ReducedVFX = false }
local restored = false

local ON_COLOR = Color3.fromRGB(88, 220, 110)
local OFF_COLOR = Color3.fromRGB(232, 74, 78)
local IDLE_COLOR = Color3.fromRGB(120, 128, 146)

-- ==========================================================
-- APPLY
-- ==========================================================

local function applyMusic(value: number)
	local group = Audio.group(Audio.GROUP_MUSIC)
	if group then
		group.Volume = value
	end
end

local function applySfx(value: number)
	local group = Audio.group(Audio.GROUP_SFX)
	if group then
		group.Volume = value
	end
end

local function applyShadows(on: boolean)
	Lighting.GlobalShadows = on
end

local function applyReduced(reduced: boolean)
	NightController.setReducedEffects(reduced)
	DisplayFxController.setReducedEffects(reduced)
	WorldLootFxController.setReducedEffects(reduced)
end

local function applyAll()
	applyMusic(current.MusicVolume)
	applySfx(current.SfxVolume)
	applyShadows(current.Shadows)
	applyReduced(current.ReducedVFX)
end

local function save()
	Remotes.get("SettingsRequest"):FireServer({
		MusicVolume = current.MusicVolume,
		SfxVolume = current.SfxVolume,
		Shadows = current.Shadows,
		ReducedVFX = current.ReducedVFX,
	})
end

-- ==========================================================
-- SLIDERS
-- ==========================================================

--- The pack's "Zipper": a track Frame holding a fill Frame whose X scale is
--- the value, with a knob (CanvasGroup) pinned to the fill's right edge. A
--- value readout is added on the knob so the number is never a guess.
local function bindSlider(row: Instance, initial: number, onChange: (number) -> (), onCommit: (number) -> ())
	local body = row:FindFirstChild("Frame")
	local track = body and body:FindFirstChild("Zipper")
	local fill = track and track:FindFirstChildOfClass("Frame")
	if not track or not track:IsA("GuiObject") or not fill or not fill:IsA("GuiObject") then
		return
	end

	local knob = fill:FindFirstChildOfClass("CanvasGroup")
	local readout = Instance.new("TextLabel")
	readout.Name = "Value"
	readout.AnchorPoint = Vector2.new(0.5, 0.5)
	readout.Position = UDim2.fromScale(0.5, 0.5)
	readout.Size = UDim2.fromScale(1.6, 0.9)
	readout.BackgroundColor3 = Color3.fromRGB(16, 22, 44)
	readout.BackgroundTransparency = 0.1
	readout.Font = Enum.Font.FredokaOne
	readout.TextScaled = true
	readout.TextColor3 = Color3.fromRGB(160, 255, 170)
	readout.ZIndex = 8
	readout.Parent = if knob then knob else fill
	local readoutCorner = Instance.new("UICorner")
	readoutCorner.CornerRadius = UDim.new(0, 6)
	readoutCorner.Parent = readout
	local readoutStroke = Instance.new("UIStroke")
	readoutStroke.Thickness = 1.5
	readoutStroke.Color = Color3.fromRGB(0, 0, 0)
	readoutStroke.Parent = readout

	local value = math.clamp(initial, 0, 1)
	local function paint()
		fill.Size = UDim2.new(value, 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
		fill.Position = UDim2.new(value / 2, 0, fill.Position.Y.Scale, fill.Position.Y.Offset)
		readout.Text = tostring(math.floor(value * 100 + 0.5))
	end
	paint()

	local dragging = false
	local function fromInput(position: Vector3)
		local left = track.AbsolutePosition.X
		local width = math.max(track.AbsoluteSize.X, 1)
		local next = math.clamp((position.X - left) / width, 0, 1)
		if math.abs(next - value) > 0.0001 then
			value = next
			paint()
			onChange(value)
		end
	end

	local function isPointer(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	-- The whole track is the hit area, not just the knob, so a tap anywhere
	-- along it jumps there - that is what a slider on a phone has to do. An
	-- invisible button over the track takes the input: the pack's fill and
	-- knob sit on top of the track and would otherwise swallow the press.
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.Size = UDim2.fromScale(1, 1.6)
	hit.Position = UDim2.fromScale(0, -0.3)
	hit.ZIndex = 9
	hit.Active = true
	hit:SetAttribute("_UIHandlerSetup", true) -- the pack must not animate it
	hit.Parent = track
	hit.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging = true
			fromInput(input.Position)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			fromInput(input.Position)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and isPointer(input) then
			dragging = false
			onCommit(value)
		end
	end)

	return function(next: number)
		value = math.clamp(next, 0, 1)
		paint()
	end
end

-- ==========================================================
-- TOGGLES
-- ==========================================================

local function bindToggle(row: Instance, label: string?, initial: boolean, onChange: (boolean) -> ())
	local body = row:FindFirstChild("Frame")
	local choose = body and body:FindFirstChild("Choose")
	local onButton = choose and choose:FindFirstChild("ON")
	local offButton = choose and choose:FindFirstChild("OFF")
	if not onButton or not onButton:IsA("GuiButton") or not offButton or not offButton:IsA("GuiButton") then
		return
	end

	local title = body and body:FindFirstChild("Multiplier1")
	if label and title and title:IsA("TextLabel") then
		title.Text = label
	end

	local function face(button: GuiButton): GuiObject?
		local inner = button:FindFirstChild("Frame")
		return if inner and inner:IsA("GuiObject") then inner else nil
	end

	-- The word on each button, since the pack's art carries none.
	for _, pair in { { onButton, "ON" }, { offButton, "OFF" } } do
		local button = pair[1] :: GuiButton
		if not button:FindFirstChild("Word") then
			local word = Instance.new("TextLabel")
			word.Name = "Word"
			word.BackgroundTransparency = 1
			word.Size = UDim2.fromScale(1, 0.7)
			word.Position = UDim2.fromScale(0, 0.15)
			word.Font = Enum.Font.FredokaOne
			word.TextScaled = true
			word.TextColor3 = Color3.fromRGB(255, 255, 255)
			word.TextStrokeTransparency = 0.3
			word.Text = pair[2] :: string
			word.ZIndex = 7
			word.Parent = button
		end
	end

	local state = initial
	local function paint()
		local onFace = face(onButton)
		local offFace = face(offButton)
		if onFace then
			onFace.BackgroundColor3 = if state then ON_COLOR else IDLE_COLOR
		end
		if offFace then
			offFace.BackgroundColor3 = if state then IDLE_COLOR else OFF_COLOR
		end
		onButton.BackgroundTransparency = if state then 0 else 0.35
		offButton.BackgroundTransparency = if state then 0.35 else 0
	end
	paint()

	UIAnim.claimButton(onButton)
	UIAnim.claimButton(offButton)
	onButton.Activated:Connect(function()
		if state then
			return
		end
		state = true
		paint()
		UIAnim.punch(onButton, 0.2)
		onChange(true)
	end)
	offButton.Activated:Connect(function()
		if not state then
			return
		end
		state = false
		paint()
		UIAnim.punch(offButton, 0.2)
		onChange(false)
	end)

	return function(next: boolean)
		state = next
		paint()
	end
end

-- ==========================================================
-- START
-- ==========================================================

function SettingsController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	local frames = ui and ui:FindFirstChild("Frames")
	local panel = frames and frames:FindFirstChild("Settings")
	local list = panel and panel:FindFirstChild("ScrollingFrame")
	if not list then
		warn("[SettingsController] Frames.Settings.ScrollingFrame not found - settings disabled.")
		return
	end

	applyAll()

	local setMusic: ((number) -> ())? = nil
	local setSfx: ((number) -> ())? = nil
	local setShadows: ((boolean) -> ())? = nil
	local setVfx: ((boolean) -> ())? = nil

	local music = list:FindFirstChild("Music")
	if music then
		setMusic = bindSlider(music, current.MusicVolume, function(value)
			current.MusicVolume = value
			applyMusic(value)
		end, function()
			save()
		end)
	end

	local sfx = list:FindFirstChild("Sound_Effects")
	if sfx then
		setSfx = bindSlider(sfx, current.SfxVolume, function(value)
			current.SfxVolume = value
			applySfx(value)
		end, function()
			save()
		end)
	end

	local shadows = list:FindFirstChild("Shadows")
	if shadows then
		setShadows = bindToggle(shadows, "Shadows", current.Shadows, function(on)
			current.Shadows = on
			applyShadows(on)
			save()
		end)
	end

	local vfx = list:FindFirstChild("VFX")
	if vfx then
		setVfx = bindToggle(vfx, "VFX", not current.ReducedVFX, function(on)
			current.ReducedVFX = not on
			applyReduced(not on)
			save()
		end)
	end

	-- Restore from the save on the first push that carries settings; later
	-- pushes echo what we sent, so only a genuine difference repaints.
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		local saved = state and state.settings
		if type(saved) ~= "table" then
			return
		end
		local next: Settings = {
			MusicVolume = if type(saved.MusicVolume) == "number" then saved.MusicVolume else current.MusicVolume,
			SfxVolume = if type(saved.SfxVolume) == "number" then saved.SfxVolume else current.SfxVolume,
			Shadows = if type(saved.Shadows) == "boolean" then saved.Shadows else current.Shadows,
			ReducedVFX = if type(saved.ReducedVFX) == "boolean" then saved.ReducedVFX else current.ReducedVFX,
		}
		local differs = not restored
			or next.MusicVolume ~= current.MusicVolume
			or next.SfxVolume ~= current.SfxVolume
			or next.Shadows ~= current.Shadows
			or next.ReducedVFX ~= current.ReducedVFX
		restored = true
		if not differs then
			return
		end
		current = next
		applyAll()
		if setMusic then
			setMusic(current.MusicVolume)
		end
		if setSfx then
			setSfx(current.SfxVolume)
		end
		if setShadows then
			setShadows(current.Shadows)
		end
		if setVfx then
			setVfx(not current.ReducedVFX)
		end
	end)
end

--- For tests: the settings as this client currently has them.
function SettingsController.get(): Settings
	return table.clone(current)
end

return SettingsController
