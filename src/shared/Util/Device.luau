--!strict
--[[
	Device
	One answer to "is this a touch layout?" so every controller that lays
	itself out for a phone agrees with every other one.

	TOUCH means: a touchscreen and no keyboard. A laptop with a touchscreen
	keeps the desktop layout; a phone or a tablet gets the compact one. The
	Studio device emulator reports exactly this, so the mobile layout can be
	checked without a phone.

	PHONE narrows that further by the shortest viewport edge, for the few
	places where a tablet has room a phone does not.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Device = {}

function Device.isTouch(): boolean
	if GuiService:IsTenFootInterface() then
		return false
	end
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

--- Shortest edge of the current viewport, in pixels (0 before a camera exists).
function Device.shortEdge(): number
	local camera = workspace.CurrentCamera
	if not camera then
		return 0
	end
	local size = camera.ViewportSize
	return math.min(size.X, size.Y)
end

--- A touch device with a phone-sized screen. Tablets are touch but not phone.
function Device.isPhone(): boolean
	return Device.isTouch() and Device.shortEdge() < 620
end

-- ==========================================================
-- CHANGES (client performance / touch pass)
-- ==========================================================
--
-- isTouch() can change mid-session: a tablet gains a keyboard, the Studio
-- emulator is switched. Controllers that decided their layout once at start
-- can listen here instead. The signal is built lazily and only on the client.

local changedEvent: BindableEvent? = nil
local lastTouch: boolean? = nil

--- Calls fn(isTouch) whenever isTouch() flips. Returns the connection.
function Device.onTouchChanged(fn: (boolean) -> ()): RBXScriptConnection
	local event = changedEvent
	if not event then
		local created = Instance.new("BindableEvent")
		changedEvent = created
		event = created
		lastTouch = Device.isTouch()
		local function check()
			local now = Device.isTouch()
			if now ~= lastTouch then
				lastTouch = now
				created:Fire(now)
			end
		end
		UserInputService.LastInputTypeChanged:Connect(check)
		UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(check)
		UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(check)
	end
	return (event :: BindableEvent).Event:Connect(fn)
end

--- The default touch controls' Jump button, when the PlayerModule has built
--- it, plus the ScreenGui it lives in. Buttons that sit beside Jump should
--- be laid out from its real rectangle: it is much bigger on a tablet than on
--- a phone, so fixed offsets overlap it there.
function Device.jumpButton(): (GuiObject?, ScreenGui?)
	local player = game:GetService("Players").LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local jump = frame and frame:FindFirstChild("JumpButton")
	if jump and jump:IsA("GuiObject") and jump.Visible and touchGui and touchGui:IsA("ScreenGui") then
		return jump, touchGui
	end
	return nil, nil
end

return Device
