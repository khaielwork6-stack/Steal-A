--!strict
--[[
	Effects
	The two client-wide visual preferences, readable from anywhere.

	  isReduced()      the Settings panel's VFX OFF ("Reduced Effects"):
	                   decorative motion stops or goes static. Nothing that
	                   carries gameplay information is ever hidden.
	  isLowGraphics()  the Settings panel's Graphics LOW: decorative lights and
	                   particles off, trophy/crate spin stopped, far decor
	                   culled. For weak phones and tablets.

	WHY A SHARED FLAG
	Reduced Effects used to be a list of `X.setReducedEffects` calls inside
	SettingsController, so every new animated thing had to be added there by
	hand and most were not (the red chase pulse, the gift rainbow, the portal
	spin, UIAnim's punches). A controller can now simply ask - or listen - and
	the per-controller setters keep working for the ones that already had one.

	SettingsController is the only writer. Both flags default OFF, and on the
	server (which also requires UIAnim) they simply stay off.
]]

local Effects = {}

local reduced = false
local lowGraphics = false

local reducedEvent = Instance.new("BindableEvent")
local graphicsEvent = Instance.new("BindableEvent")

--- Fires (reduced: boolean) when Reduced Effects changes.
Effects.reducedChanged = reducedEvent.Event
--- Fires (low: boolean) when the graphics quality changes.
Effects.graphicsChanged = graphicsEvent.Event

function Effects.isReduced(): boolean
	return reduced
end

function Effects.isLowGraphics(): boolean
	return lowGraphics
end

function Effects.setReduced(value: boolean)
	if value == reduced then
		return
	end
	reduced = value
	reducedEvent:Fire(value)
end

function Effects.setLowGraphics(value: boolean)
	if value == lowGraphics then
		return
	end
	lowGraphics = value
	graphicsEvent:Fire(value)
end

--- Calls fn(reduced) now and on every change. Returns the connection.
function Effects.watchReduced(fn: (boolean) -> ()): RBXScriptConnection
	task.spawn(fn, reduced)
	return reducedEvent.Event:Connect(fn)
end

--- Calls fn(low) now and on every change. Returns the connection.
function Effects.watchGraphics(fn: (boolean) -> ()): RBXScriptConnection
	task.spawn(fn, lowGraphics)
	return graphicsEvent.Event:Connect(fn)
end

return Effects
