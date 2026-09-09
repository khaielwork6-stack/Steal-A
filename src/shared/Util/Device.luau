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

return Device
