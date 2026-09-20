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

	  Graphics HIGH / LOW  -> a row added in code (a copy of Shadows): LOW
	                          switches decorative lights / particles off and
	                          stops the trophy and crate spin. See
	                          GraphicsQualityController. Saved as LowGraphics.
	VFX also sets the shared Effects.isReduced() flag (Shared.Util.Effects).

	The pack shipped these rows as art with no logic: the third row was even
	labelled "Textures" over a frame named "Shadows". There is no texture
	toggle in this game, so the label now says what the row does.

	Applied locally the instant a control moves; saved through SettingsRequest
	so it survives a rejoin; restored from StatePush.settings on join. Roblox's
	own volume is untouched - these are mixer buses inside the game.

	PANEL LAYOUT (round3-ui-base-settings, see `arrange`)
	  * CODES is a bar pinned ABOVE the list (CodesController.attach), so it
	    is always first and its TextBox stays out of the clip guard.
	  * The list is Music, Sound Effects, Shadows, VFX, Graphics, Auto Reveal
	    - forced by LayoutOrder with SortOrder = LayoutOrder (the pack's
	    order is not trusted: sorted by Name, "AutoReveal" came first).
	  * Every row keeps the width / height ratio the pack authored (measured
	    once), written as a pixel height so the list can use
	    AutomaticCanvasSize without the rows growing with the canvas; rows
	    never go below a touch-safe height. The canvas therefore always fits
	    the rows, including the added ones.
	  * The list is wrapped by ClipSafe.guard and watched by ClipSafe.watch:
	    the stray green "ON" over the title was a pack toggle drawing outside
	    the list; nothing inside the list can do that any more.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)
local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local DisplayFxController = require(script.Parent.DisplayFxController)
local ItemArtMotionController = require(script.Parent.ItemArtMotionController)
local NightController = require(script.Parent.NightController)
local WorldLootFxController = require(script.Parent.WorldLootFxController)
local EscapeFlashController = require(script.Parent.EscapeFlashController)
local BaseEarningsController = require(script.Parent.BaseEarningsController)
local AttractionSignController = require(script.Parent.AttractionSignController)
local HatchController = require(script.Parent.HatchController)
local SpinWheelController = require(script.Parent.SpinWheelController)
local CodesController = require(script.Parent.CodesController)

local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)

local SettingsPresentation = require(script.Parent.SettingsPresentation)
local SettingsController = {}

local player = Players.LocalPlayer

--- LowGraphics: the Graphics HIGH / LOW row (false = HIGH, the default). A
--- save made before the row existed has no such key and reads as HIGH.
--- AutoRevealOff: [fusion-autoreveal-bases] the Auto Reveal pass's switch
--- (false = ON, the default; the row only shows to a pass owner).
type Settings = { MusicVolume: number, SfxVolume: number, Shadows: boolean, ReducedVFX: boolean, LowGraphics: boolean, AutoRevealOff: boolean }

local current: Settings = { MusicVolume = 0.7, SfxVolume = 0.8, Shadows = true, ReducedVFX = false, LowGraphics = false, AutoRevealOff = false }
local restored = false

local ON_COLOR = Color3.fromRGB(88, 220, 110)
local OFF_COLOR = Color3.fromRGB(232, 74, 78)
local IDLE_COLOR = Color3.fromRGB(96, 104, 124)

-- [round3-ui-base-settings] Row geometry (see `arrange`).
--- Row order in the list; anything else keeps its order after these.
local ROW_ORDER: { [string]: number } = { Music = 10, Sound_Effects = 20, Shadows = 30, VFX = 40, Graphics = 50, AutoReveal = 60, WatchTutorial = 70 }
--- Width / height used when a row could not be measured.
local DEFAULT_RATIO = 6.5
--- Smallest row height in screen pixels (the toggles sit inside it).
local MIN_ROW_TOUCH = 62
local MIN_ROW_DESKTOP = 42
--- The CODES bar is this much taller than a toggle row (box + result line).
local CODES_HEIGHT = 1.45
local MIN_CODES_TOUCH = 92
local MIN_CODES_DESKTOP = 66
local LIST_GAP = 8

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
	-- The shared flag first: everything that reads Effects.isReduced() (UIAnim
	-- punches and pop-ins, the chase pulse, the gift rainbow, the portal /
	-- slap / guardian-shop spins, the DROP breathe, the treadmill sheen, the
	-- particle bursts) follows it. The explicit setters below are kept for the
	-- controllers that already had one.
	Effects.setReduced(reduced)
	NightController.setReducedEffects(reduced)
	DisplayFxController.setReducedEffects(reduced)
	ItemArtMotionController.setReducedEffects(reduced)
	WorldLootFxController.setReducedEffects(reduced)
	EscapeFlashController.setReducedEffects(reduced)
	BaseEarningsController.setReducedEffects(reduced)
	AttractionSignController.setReducedEffects(reduced)
	HatchController.setReducedEffects(reduced)
	-- The spin itself always plays - it is the feature, not a flourish on one.
	-- What this drops is the confetti, the bounce and the rainbow drift.
	SpinWheelController.setReducedEffects(reduced)
end

--- Graphics LOW: GraphicsQualityController switches decorative lights and
--- particles off, and the trophy / crate animators stop turning.
local function applyGraphics(low: boolean)
	Effects.setLowGraphics(low)
end

local function applyAll()
	applyMusic(current.MusicVolume)
	applySfx(current.SfxVolume)
	applyShadows(current.Shadows)
	applyReduced(current.ReducedVFX)
	applyGraphics(current.LowGraphics)
end

local function save()
	Remotes.get("SettingsRequest"):FireServer({
		MusicVolume = current.MusicVolume,
		SfxVolume = current.SfxVolume,
		Shadows = current.Shadows,
		ReducedVFX = current.ReducedVFX,
		LowGraphics = current.LowGraphics,
		AutoRevealOff = current.AutoRevealOff,
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
	hit.AnchorPoint = Vector2.new(0, 0.5)
	hit.Size = UDim2.new(1, 0, 0, 48 / ClipSafe.scaleChain(track))
	track:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		hit.Size = UDim2.new(1, 0, 0, 48 / ClipSafe.scaleChain(track))
	end)
	hit.Position = UDim2.fromScale(0, 0.5)
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

--- `words` replaces the ON / OFF captions (the Graphics row says HIGH / LOW);
--- the left button is always the `true` state.
local function bindToggle(row: Instance, label: string?, initial: boolean, onChange: (boolean) -> (), words: { string }?)
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
	-- [round3-ui-base-settings] Readable at the 0.72 phone scale.
	if title and title:IsA("TextLabel") then
		local limit = title:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
		limit.MinTextSize = 12
		limit.MaxTextSize = math.max(limit.MaxTextSize, 30)
		limit.Parent = title
	end

	local function face(button: GuiButton): GuiObject?
		local inner = button:FindFirstChild("Frame")
		return if inner and inner:IsA("GuiObject") then inner else nil
	end

	-- The word on each button, since the pack's art carries none.
	local onWord = if words then words[1] else "ON"
	local offWord = if words then words[2] else "OFF"
	local wordLabels: { [GuiButton]: TextLabel } = {}
	for _, pair in { { onButton, onWord }, { offButton, offWord } } do
		local button = pair[1] :: GuiButton
		local existing = button:FindFirstChild("Word")
		if existing and existing:IsA("TextLabel") then
			wordLabels[button] = existing
			-- A row cloned from Shadows carries its "ON"/"OFF" words; set ours.
			existing.Text = pair[2] :: string
		else
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
			wordLabels[button] = word
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
		-- The chosen word is bright, the other one clearly faded.
		local onLabel = wordLabels[onButton]
		local offLabel = wordLabels[offButton]
		if onLabel then
			onLabel.TextTransparency = if state then 0 else 0.5
		end
		if offLabel then
			offLabel.TextTransparency = if state then 0.5 else 0
		end
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

--- [tutorial-film] A plain action button, built from the same Shadows-shaped
--- row `bindToggle` uses. SettingsPresentation.row (run later, by `arrange`)
--- repaints every row's ON/OFF pair to its fixed 48%-width layout regardless
--- of what a binder does, so rather than fight that layout this keeps BOTH
--- halves - they just do the same thing (replay) instead of two opposite
--- states. Reads exactly like every other row; there is nothing to save.
local function bindAction(row: Instance, label: string, words: { string }, onPress: () -> ())
	local body = row:FindFirstChild("Frame")
	local choose = body and body:FindFirstChild("Choose")
	local onButton = choose and choose:FindFirstChild("ON")
	local offButton = choose and choose:FindFirstChild("OFF")
	if not onButton or not onButton:IsA("GuiButton") or not offButton or not offButton:IsA("GuiButton") then
		return
	end

	local title = body and body:FindFirstChild("Multiplier1")
	if title and title:IsA("TextLabel") then
		title.Text = label
		local limit = title:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
		limit.MinTextSize = 12
		limit.MaxTextSize = math.max(limit.MaxTextSize, 30)
		limit.Parent = title
	end

	local function face(button: GuiButton): GuiObject?
		local inner = button:FindFirstChild("Frame")
		return if inner and inner:IsA("GuiObject") then inner else nil
	end

	for _, pair in { { onButton, words[1] or "WATCH" }, { offButton, words[2] or "AGAIN" } } do
		local button = pair[1] :: GuiButton
		local buttonFace = face(button)
		if buttonFace then
			buttonFace.BackgroundColor3 = Color3.fromRGB(90, 110, 220)
		end
		button.BackgroundTransparency = 0
		local existing = button:FindFirstChild("Word")
		local wordLabel: TextLabel
		if existing and existing:IsA("TextLabel") then
			wordLabel = existing
		else
			wordLabel = Instance.new("TextLabel")
			wordLabel.Name = "Word"
			wordLabel.BackgroundTransparency = 1
			wordLabel.Size = UDim2.fromScale(1, 0.7)
			wordLabel.Position = UDim2.fromScale(0, 0.15)
			wordLabel.Font = Enum.Font.FredokaOne
			wordLabel.TextScaled = true
			wordLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			wordLabel.TextStrokeTransparency = 0.3
			wordLabel.ZIndex = 7
			wordLabel.Parent = button
		end
		wordLabel.Text = pair[2] :: string
		wordLabel.TextTransparency = 0

		UIAnim.claimButton(button)
		button.Activated:Connect(function()
			UIAnim.punch(button, 0.2)
			onPress()
		end)
	end
end

-- ==========================================================
-- LAYOUT  (round3-ui-base-settings)
-- ==========================================================

local function authoredRatio(row: GuiObject): number?
	local size = row.AbsoluteSize
	if size.X > 4 and size.Y > 4 then
		return size.X / size.Y
	end
	return nil
end

--- Orders and sizes the rows, pins the CODES bar above the list and wraps
--- the list in the clip guard. Yields until the pack's own layout has been
--- computed once, because the row proportions are read from it.
local function arrange(panel: GuiObject, list: ScrollingFrame, codesTemplate: GuiObject?)
	-- Sizes are computed for a closed panel too; if they are not yet, wait
	-- for the first open.
	for _ = 1, 30 do
		local shadows = list:FindFirstChild("Shadows")
		if list.AbsoluteSize.X > 0 and shadows and shadows:IsA("GuiObject") and shadows.AbsoluteSize.Y > 0 then
			break
		end
		task.wait()
	end
	if list.AbsoluteSize.X <= 0 and not panel.Visible then
		panel:GetPropertyChangedSignal("Visible"):Wait()
		task.wait()
	end

	-- ---------- measure (before anything moves) ----------
	local shadows = list:FindFirstChild("Shadows")
	local base = if shadows and shadows:IsA("GuiObject") then authoredRatio(shadows) else nil
	local baseRatio = base or DEFAULT_RATIO
	local ratios: { [GuiObject]: number } = {}
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			-- Copies of Shadows share its shape even while still hidden.
			local copy = child.Name == "Graphics" or child.Name == "AutoReveal"
			ratios[child] = if copy then baseRatio else (authoredRatio(child) or baseRatio)
		end
	end

	-- ---------- order + layout ----------
	for row in ratios do
		SettingsPresentation.row(row)
		local order = ROW_ORDER[row.Name]
		row.LayoutOrder = order or (100 + row.LayoutOrder)
		-- The height is ours now; an aspect lock would fight it.
		for _, constraint in row:GetChildren() do
			if constraint:IsA("UIAspectRatioConstraint") then
				constraint:Destroy()
			end
		end
	end
	local grid = list:FindFirstChildOfClass("UIGridLayout")
	if grid then
		grid:Destroy() -- fixed cells would override the row heights
	end
	local layout = list:FindFirstChildOfClass("UIListLayout")
	if not layout then
		local made = Instance.new("UIListLayout")
		made.HorizontalAlignment = Enum.HorizontalAlignment.Center
		made.Padding = UDim.new(0, LIST_GAP)
		made.Parent = list
		layout = made
	end
	;(layout :: UIListLayout).SortOrder = Enum.SortOrder.LayoutOrder
	if not list:FindFirstChildOfClass("UIPadding") then
		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 6)
		padding.PaddingBottom = UDim.new(0, 12)
		padding.Parent = list
	end
	list.ScrollingEnabled = true
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ScrollBarThickness = if Device.isTouch() then 8 else 6
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ClipsDescendants = true

	-- ---------- clip guard + pinned CODES bar ----------
	local group = ClipSafe.guard(list)
	local inner: GuiObject = group or list
	local holder = Instance.new("Frame")
	holder.Name = "SettingsBody"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = inner.AnchorPoint
	holder.Position = UDim2.fromScale(0.5, 0.57)
	holder.Size = UDim2.fromScale(0.98, 0.82)
	holder.ZIndex = inner.ZIndex
	holder.Parent = inner.Parent
	inner.AnchorPoint = Vector2.zero
	inner.Position = UDim2.new()
	inner.Size = UDim2.fromScale(1, 1)
	inner.Parent = holder
	ClipSafe.watch(list)

	local shadowsRow = if shadows and shadows:IsA("GuiObject") then shadows else nil
	local rowWidth = if shadowsRow then shadowsRow.Size.X else UDim.new(0.95, 0)
	local bar = Instance.new("Frame")
	bar.Name = "CodesBar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 2)
	bar.Size = UDim2.new(rowWidth.Scale, rowWidth.Offset, 0, 80)
	bar.ZIndex = holder.ZIndex
	bar.Parent = holder
	local built = pcall(function()
		CodesController.attach(bar, codesTemplate)
	end)
	if not built then
		warn("[SettingsController] the CODES bar could not be built.")
		bar:Destroy()
	end

	-- ---------- heights (pixel-exact, follow the panel's size) ----------
	local lastSignature = ""
	local function resize()
		local window = list.AbsoluteWindowSize.X
		if window <= 0 then
			return
		end
		local factor = ClipSafe.scaleChain(list)
		local touch = Device.isTouch()
		local minRow = if touch then MIN_ROW_TOUCH else MIN_ROW_DESKTOP
		local heights: { [GuiObject]: number } = {}
		local parts = {}
		for row, ratio in ratios do
			if row.Parent == list then
				local widthPx = window * row.Size.X.Scale + row.Size.X.Offset * factor
				local height = math.floor(math.clamp(widthPx / ratio, math.max(minRow, 72), 82) / factor + 0.5)
				heights[row] = height
				table.insert(parts, height)
			end
		end
		local shadowsHeight = if shadowsRow and heights[shadowsRow] then heights[shadowsRow] * factor else minRow
		local minCodes = if touch then MIN_CODES_TOUCH else MIN_CODES_DESKTOP
		local codesHeight = math.floor(math.max(math.min(shadowsHeight * CODES_HEIGHT, 100), minCodes) / factor + 0.5)
		table.insert(parts, codesHeight)
		local signature = table.concat(parts, ",")
		if signature == lastSignature then
			return
		end
		lastSignature = signature
		for row, height in heights do
			row.Size = UDim2.new(row.Size.X.Scale, row.Size.X.Offset, 0, height)
		end
		if bar.Parent then
			bar.Size = UDim2.new(rowWidth.Scale, rowWidth.Offset, 0, codesHeight)
			inner.Position = UDim2.fromOffset(0, codesHeight + LIST_GAP)
			inner.Size = UDim2.new(1, 0, 1, -(codesHeight + LIST_GAP))
		else
			inner.Position = UDim2.new()
			inner.Size = UDim2.fromScale(1, 1)
		end
	end
	task.wait()
	resize()
	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		task.defer(resize)
	end)
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
	if not panel or not panel:IsA("GuiObject") or not list or not list:IsA("ScrollingFrame") then
		warn("[SettingsController] Frames.Settings.ScrollingFrame not found - settings disabled.")
		return
	end

	applyAll()

	-- [round3-ui-base-settings] A pristine copy of the Shadows row for the
	-- CODES bar's look, taken before any row is bound (no captions, no
	-- connections). Parented nowhere.
	local shadowsSource = list:FindFirstChild("Shadows")
	local codesTemplate: GuiObject? = if shadowsSource and shadowsSource:IsA("GuiObject") then shadowsSource:Clone() else nil

	local setMusic: ((number) -> ())? = nil
	local setSfx: ((number) -> ())? = nil
	local setShadows: ((boolean) -> ())? = nil
	local setVfx: ((boolean) -> ())? = nil
	local setGraphics: ((boolean) -> ())? = nil

	-- The Graphics row does not exist in the pack: it is a copy of the
	-- Shadows toggle row, made BEFORE that row is bound so the copy carries no
	-- captions or connections of its own. Placed right after VFX.
	local shadowsTemplate = list:FindFirstChild("Shadows")
	local graphicsRow: Instance? = list:FindFirstChild("Graphics")
	if not graphicsRow and shadowsTemplate then
		local copy = shadowsTemplate:Clone()
		copy.Name = "Graphics"
		local after = list:FindFirstChild("VFX") or shadowsTemplate
		if copy:IsA("GuiObject") and after:IsA("GuiObject") then
			copy.LayoutOrder = after.LayoutOrder + 1
		end
		copy.Parent = list
		graphicsRow = copy
	end
	-- [fusion-autoreveal-bases] The Auto Reveal row: another Shadows copy,
	-- after Graphics, shown only while the player owns the pass.
	local setAutoReveal: ((boolean) -> ())? = nil
	local autoRevealRow: Instance? = list:FindFirstChild("AutoReveal")
	if not autoRevealRow and shadowsTemplate then
		local copy = shadowsTemplate:Clone()
		copy.Name = "AutoReveal"
		local after = graphicsRow or list:FindFirstChild("VFX") or shadowsTemplate
		if copy:IsA("GuiObject") and after:IsA("GuiObject") then
			copy.LayoutOrder = after.LayoutOrder + 1
			copy.Visible = false
		end
		copy.Parent = list
		autoRevealRow = copy
	end
	-- [tutorial-film] "Watch tutorial again": another Shadows copy, after
	-- Auto Reveal, but a plain button (bindAction) rather than a toggle -
	-- there is nothing to save, it only replays the short film.
	local watchTutorialRow: Instance? = list:FindFirstChild("WatchTutorial")
	if not watchTutorialRow and shadowsTemplate then
		local copy = shadowsTemplate:Clone()
		copy.Name = "WatchTutorial"
		local after = autoRevealRow or graphicsRow or list:FindFirstChild("VFX") or shadowsTemplate
		if copy:IsA("GuiObject") and after:IsA("GuiObject") then
			copy.LayoutOrder = after.LayoutOrder + 1
		end
		copy.Parent = list
		watchTutorialRow = copy
	end
	if watchTutorialRow then
		bindAction(watchTutorialRow, "Tutorial", { "WATCH", "REPLAY" }, function()
			local TutorialFilmController = require(script.Parent.TutorialFilmController)
			TutorialFilmController.replay()
		end)
	end

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

	if graphicsRow then
		-- Left button = HIGH = `true`, so the state is "not low".
		setGraphics = bindToggle(graphicsRow, "Graphics", not current.LowGraphics, function(high)
			current.LowGraphics = not high
			applyGraphics(not high)
			save()
		end, { "HIGH", "LOW" })
	end

	if autoRevealRow then
		-- Left button = ON = `true`, so the state is "not off".
		setAutoReveal = bindToggle(autoRevealRow, "Auto Reveal", not current.AutoRevealOff, function(on)
			current.AutoRevealOff = not on
			save()
		end)
		require(script.Parent.Parent.StateStore).subscribe(function(state)
			local info = state and state.autoReveal
			local owned = type(info) == "table" and info.owned == true
			local row = autoRevealRow
			if row and row:IsA("GuiObject") and row.Visible ~= owned then
				row.Visible = owned
			end
		end)
	end

	-- [round3-ui-base-settings] Order, sizes, canvas, CODES bar, clip guard.
	local settingsPanel = panel :: GuiObject
	if settingsPanel:IsA("Frame") then PanelStyle.window(settingsPanel, 760, 620) end
	local settingsList = list :: ScrollingFrame
	task.spawn(function()
		local ok, err = pcall(function()
			arrange(settingsPanel, settingsList, codesTemplate)
		end)
		if not ok then
			warn(`[SettingsController] panel layout failed: {err}`)
		end
	end)

	-- Studio UI review changes only local effects, never the saved preferences.
	if game:GetService("RunService"):IsStudio() then
		local function previewEffects()
			local mode = player:GetAttribute("EffectsUiPreview")
			local preview = mode == "Full" or mode == "Reduced" or mode == "Low" or mode == "Both"
			applyReduced(if preview then mode == "Reduced" or mode == "Both" else current.ReducedVFX)
			applyGraphics(if preview then mode == "Low" or mode == "Both" else current.LowGraphics)
			player:SetAttribute("EffectsUiPreviewApplied", if preview then mode else nil)
		end
		player:GetAttributeChangedSignal("EffectsUiPreview"):Connect(previewEffects)
	end

	-- Restore from the save on the first push that carries settings; later
	-- pushes echo what we sent, so only a genuine difference repaints.
	require(script.Parent.Parent.StateStore).subscribe(function(state)
		local saved = state and state.settings
		if type(saved) ~= "table" then
			return
		end
		local next: Settings = {
			MusicVolume = if type(saved.MusicVolume) == "number" then saved.MusicVolume else current.MusicVolume,
			SfxVolume = if type(saved.SfxVolume) == "number" then saved.SfxVolume else current.SfxVolume,
			Shadows = if type(saved.Shadows) == "boolean" then saved.Shadows else current.Shadows,
			ReducedVFX = if type(saved.ReducedVFX) == "boolean" then saved.ReducedVFX else current.ReducedVFX,
			LowGraphics = if type(saved.LowGraphics) == "boolean" then saved.LowGraphics else current.LowGraphics,
			AutoRevealOff = if type(saved.AutoRevealOff) == "boolean" then saved.AutoRevealOff else current.AutoRevealOff,
		}
		local differs = not restored
			or next.MusicVolume ~= current.MusicVolume
			or next.SfxVolume ~= current.SfxVolume
			or next.Shadows ~= current.Shadows
			or next.ReducedVFX ~= current.ReducedVFX
			or next.LowGraphics ~= current.LowGraphics
			or next.AutoRevealOff ~= current.AutoRevealOff
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
		if setGraphics then
			setGraphics(not current.LowGraphics)
		end
		if setAutoReveal then
			setAutoReveal(not current.AutoRevealOff)
		end
	end)
end

--- For tests: the settings as this client currently has them.
function SettingsController.get(): Settings
	return table.clone(current)
end

return SettingsController
