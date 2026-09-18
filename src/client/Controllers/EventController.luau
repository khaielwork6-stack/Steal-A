--!strict
--[[
	EventController  (polish-events-analytics pass)
	Draws the timed events the server says are running (StateStore `events`):

	  THE PILL      a small HUD pill next to the Nightfall timer: the event's
	                title and a countdown to its end, or "starts in" for the
	                next one inside EventConfig.UPCOMING_WINDOW_SECONDS. Several
	                running events take turns every few seconds.
	  THE CARD      a short announcement at the top of the screen the first
	                time this client sees an event running (on join, or when it
	                starts). Held back while the loading screen or the
	                first-join flyover is up.
	  HOLIDAY TINT  a running holiday blends its colour into the museum decor
	                lights (the same Decorations lights Graphics LOW switches
	                off; each room's RoomFill is left alone), and puts every
	                light back exactly when it ends.

	Everything is derived from server timestamps (workspace:GetServerTimeNow),
	so every client counts down to the same second. Nothing here changes an
	outcome; the server applies the event.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Device = require(ReplicatedStorage.Shared.Util.Device)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local EventConfig = require(ReplicatedStorage.Shared.Config.EventConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local EventController = {}

local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local WHITE = Color3.new(1, 1, 1)
local ROTATE_SECONDS = 5

type Active = { key: string, title: string, banner: string, kind: string, color: Color3, icon: string, endsAt: number }
type Upcoming = { key: string, title: string, startsAt: number }

local active: { Active } = {}
local upcoming: Upcoming? = nil
local announced: { [string]: true } = {}
local pendingCards: { Active } = {}

local pill: Frame? = nil
local pillLabel: TextLabel? = nil
local pillIcon: ImageLabel? = nil
local pillStroke: UIStroke? = nil
local shownKey = ""

local function isSet(asset: string?): boolean
	return type(asset) == "string" and asset ~= "" and asset ~= "rbxassetid://0"
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function countdown(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	if whole >= 86400 then
		return `{whole // 86400}d {(whole % 86400) // 3600}h`
	elseif whole >= 3600 then
		return `{whole // 3600}h {(whole % 3600) // 60}m`
	end
	return string.format("%d:%02d", whole // 60, whole % 60)
end

-- ==========================================================
-- THE PILL
-- ==========================================================

local function buildPill(ui: Instance)
	local touch = Device.isTouch()
	local frame = Instance.new("Frame")
	frame.Name = "EventPill"
	-- COMPACT, and stacked on the Nightfall pill (NightController): directly
	-- above it on touch (bottom-right, left of the jump button), to its left
	-- on desktop (bottom-right), same height. Icon and time only.
	frame.AnchorPoint = Vector2.new(1, 1)
	if touch then
		frame.Position = UDim2.new(1, -132, 1, -46)
		frame.Size = UDim2.fromOffset(104, 28)
	else
		frame.Position = UDim2.new(1, -156, 1, -12)
		frame.Size = UDim2.fromOffset(132, 36)
	end
	frame.BackgroundColor3 = Color3.fromRGB(30, 22, 58)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 5
	frame.Parent = ui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = WHITE
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 6, 0.5, 0)
	icon.Size = UDim2.fromOffset(26, 26)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Visible = false
	icon.ZIndex = 6
	icon.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(10, 0)
	label.Size = UDim2.new(1, -20, 1, 0)
	label.Font = FONT
	label.TextScaled = true
	label.TextColor3 = WHITE
	label.TextStrokeTransparency = 0.5
	label.Text = ""
	label.ZIndex = 6
	label.Parent = frame
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 10
	limit.MaxTextSize = 20
	limit.Parent = label

	pill, pillLabel, pillIcon, pillStroke = frame, label, icon, stroke
end

local function hudSuppressed(): boolean
	local ok, suppressed = pcall(function()
		return require(script.Parent.UIStateController).isSuppressed()
	end)
	return ok and suppressed == true
end

local function paintPill()
	local frame, label, icon, stroke = pill, pillLabel, pillIcon, pillStroke
	if not frame or not label or not icon or not stroke then
		return
	end
	local now = serverNow()
	local text: string? = nil
	local color = WHITE
	local key = ""
	local image = ""

	if #active > 0 then
		local event = active[(math.floor(os.clock() / ROTATE_SECONDS) % #active) + 1]
		key = event.key
		color = event.color
		image = event.icon
		-- The time alone; the event's own icon is its name. No icon
		-- configured: a lightning bolt, the one glyph every event shares.
		text = if event.endsAt > 0 then countdown(event.endsAt - now) else "ON"
	elseif upcoming and upcoming.startsAt > now then
		key = "next:" .. upcoming.key
		color = Color3.fromRGB(190, 190, 210)
		local def = EventConfig.ByKey[upcoming.key]
		image = if def then def.icon else ""
		text = countdown(upcoming.startsAt - now)
	end

	local show = text ~= nil and not hudSuppressed() and player:GetAttribute("FlyoverActive") ~= true
	if not show then
		frame.Visible = false
		return
	end
	stroke.Color = color
	local hasIcon = isSet(image)
	icon.Visible = hasIcon
	if hasIcon then
		icon.Image = image
		label.Text = text :: string
		label.Position = UDim2.fromOffset(34, 0)
		label.Size = UDim2.new(1, -40, 1, 0)
	else
		label.Text = `⚡ {text :: string}`
		label.Position = UDim2.fromOffset(8, 0)
		label.Size = UDim2.new(1, -16, 1, 0)
	end
	local wasVisible = frame.Visible
	frame.Visible = true
	if key ~= shownKey or not wasVisible then
		shownKey = key
		if not Effects.isReduced() then
			UIAnim.popIn(frame, 0.85)
		end
	end
end

-- ==========================================================
-- THE ANNOUNCEMENT CARD
-- ==========================================================

local cardGui: ScreenGui? = nil
local cardBusy = false

local function ensureCardGui(): ScreenGui
	if cardGui and cardGui.Parent then
		return cardGui
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "EventAnnounce"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 40
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.Parent = player:WaitForChild("PlayerGui")
	cardGui = gui
	return gui
end

local function readyForCards(): boolean
	return player:GetAttribute("LoadingScreenDone") == true and player:GetAttribute("FlyoverActive") ~= true
end

local function showCard(event: Active)
	local gui = ensureCardGui()
	local reduced = Effects.isReduced()

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Size = UDim2.fromOffset(if Device.isPhone() then 300 else 420, 86)
	card.Position = UDim2.new(0.5, 0, 0, if reduced then 64 else -100)
	card.BackgroundColor3 = Color3.fromRGB(30, 22, 58)
	card.BorderSizePixel = 0
	card.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = event.color
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card

	local hasIcon = isSet(event.icon)
	if hasIcon then
		local icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.Position = UDim2.fromOffset(10, 11)
		icon.Size = UDim2.fromOffset(64, 64)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = event.icon
		icon.Parent = card
	end
	local left = if hasIcon then 84 else 14
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(left, 8)
	title.Size = UDim2.new(1, -left - 14, 0, 38)
	title.Font = FONT
	title.TextScaled = true
	title.TextColor3 = event.color
	title.TextStrokeTransparency = 0.3
	title.Text = `{event.title} IS ON!`
	title.Parent = card
	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(left, 48)
	body.Size = UDim2.new(1, -left - 14, 0, 28)
	body.Font = FONT
	body.TextScaled = true
	body.TextColor3 = WHITE
	body.Text = event.banner
	body.Parent = card

	if not reduced then
		TweenService:Create(card, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0, 64),
		}):Play()
	end
	task.wait(4.5)
	if reduced then
		card:Destroy()
		return
	end
	local out = TweenService:Create(card, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(0.5, 0, 0, -100),
	})
	out:Play()
	out.Completed:Wait()
	card:Destroy()
end

local function pumpCards()
	if cardBusy then
		return
	end
	cardBusy = true
	task.spawn(function()
		while #pendingCards > 0 do
			if not readyForCards() then
				task.wait(0.5)
				continue
			end
			local event = table.remove(pendingCards, 1)
			if event then
				local ok, err = pcall(function()
					showCard(event)
				end)
				if not ok then
					warn(`[EventController] announcement failed: {err}`)
				end
				task.wait(0.4)
			end
		end
		cardBusy = false
	end)
end

-- ==========================================================
-- HOLIDAY TINT
-- ==========================================================

local zonesFolder: Instance? = nil
local tinted: { [Light]: Color3 } = {}
local tintColor: Color3? = nil

local function tintOne(instance: Instance)
	local color = tintColor
	if not color or not instance:IsA("Light") or tinted[instance] then
		return
	end
	local parent = instance.Parent
	if parent and parent.Name == "RoomFill" then
		return
	end
	if not instance:FindFirstAncestor("Decorations") then
		return
	end
	tinted[instance] = instance.Color
	instance.Color = instance.Color:Lerp(color, EventConfig.HOLIDAY_LIGHT_BLEND)
end

local function setTint(color: Color3?)
	if color == tintColor then
		return
	end
	for light, original in tinted do
		if light.Parent then
			light.Color = original
		end
	end
	table.clear(tinted)
	tintColor = color
	local zones = zonesFolder
	if color and zones then
		for _, descendant in zones:GetDescendants() do
			tintOne(descendant)
		end
	end
end

local function holidayColor(): Color3?
	for _, event in active do
		local def = EventConfig.ByKey[event.key]
		if def and def.kind == "holiday" and def.lightColor then
			return def.lightColor
		end
	end
	return nil
end

-- ==========================================================
-- STATE
-- ==========================================================

local function onEvents(value: any)
	local nextActive: { Active } = {}
	local nextUpcoming: Upcoming? = nil
	if type(value) == "table" then
		if type(value.active) == "table" then
			for _, row in value.active do
				if type(row) == "table" and type(row.key) == "string" then
					table.insert(nextActive, {
						key = row.key,
						title = tostring(row.title or row.key),
						banner = tostring(row.banner or ""),
						kind = tostring(row.kind or ""),
						color = if typeof(row.color) == "Color3" then row.color else WHITE,
						icon = if type(row.icon) == "string" then row.icon else "",
						endsAt = tonumber(row.endsAt) or 0,
					})
				end
			end
		end
		local nextRow = value.upcoming
		if type(nextRow) == "table" and type(nextRow.key) == "string" and tonumber(nextRow.startsAt) then
			nextUpcoming = {
				key = nextRow.key,
				title = tostring(nextRow.title or nextRow.key),
				startsAt = tonumber(nextRow.startsAt) :: number,
			}
		end
	end
	active = nextActive
	upcoming = nextUpcoming

	for _, event in nextActive do
		if not announced[event.key] then
			announced[event.key] = true
			table.insert(pendingCards, event)
		end
	end
	-- An event that ended may be announced again if it comes back.
	for key in table.clone(announced) do
		local still = false
		for _, event in nextActive do
			if event.key == key then
				still = true
				break
			end
		end
		if not still then
			announced[key] = nil
		end
	end
	if #pendingCards > 0 then
		pumpCards()
	end
	setTint(holidayColor())
	paintPill()
end

function EventController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local mainUi = playerGui:WaitForChild("MainUI", 30)
	if mainUi then
		buildPill(mainUi)
	end

	require(script.Parent.Parent.StateStore).onKeyChanged("events", function(value)
		onEvents(value)
	end)

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 30)
		local zones = map and map:WaitForChild("Zones", 15)
		if not zones then
			return
		end
		zonesFolder = zones
		zones.DescendantAdded:Connect(function(descendant)
			if tintColor and descendant:IsA("Light") then
				local light: Instance = descendant
				-- Deferred: its Decorations ancestry may still be assembling.
				task.defer(function()
					if light.Parent then
						tintOne(light)
					end
				end)
			end
		end)
		zones.DescendantRemoving:Connect(function(descendant)
			if descendant:IsA("Light") then
				tinted[descendant] = nil
			end
		end)
		-- A holiday that was already running before the map arrived.
		local color = tintColor
		if color then
			tintColor = nil
			setTint(color)
		end
	end)

	-- The countdown ticks locally.
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(function()
				paintPill()
			end)
			if not ok then
				warn(`[EventController] pill failed: {err}`)
			end
		end
	end)
end

return EventController
