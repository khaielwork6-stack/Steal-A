--!strict
--[[
	ActivityController
	Tells the server, now and then, that this player is actually here.

	WHAT IT IS FOR. The free spin is earned by five minutes of PLAY, and play
	used to mean "connected" - a player parked on a treadmill overnight banked
	288 spins a day. SpinWheelService now only runs a player's spin clock while
	they are active (SpinWheelConfig THE AFK PAUSE), and this is the client's
	half of "active": one tiny `ActivityPing` at most every
	ACTIVITY_PING_SECONDS, sent only while real input arrived within
	IDLE_SECONDS. No input, no pings, and the clock pauses two minutes later.

	WHAT COUNTS AS INPUT. Keys, mouse buttons, touches, gamepad buttons and
	sticks - and MOUSE MOVEMENT too, deliberately. A player reading the shop
	or the Index moves the mouse without pressing anything, and they are not
	AFK. Excluding it would not stop anyone determined anyway: a mouse
	jiggler moves the mouse, and a macro presses keys. What this stops is the
	common case - a player who walked away - and it stops that completely.

	THE SERVER IS NOT TOLD ANYTHING IT TRUSTS. The ping carries nothing and is
	rate-limited on arrival; the server also watches the character move on its
	own, so a moving player whose ping is late is never paused.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)

local ActivityController = {}

--- os.clock() of the last real input, and of the last ping sent.
local lastInput = os.clock()
local lastPing = -math.huge

--- Input types that mean a human is at the controls. Everything else
--- (focus changes, text-input internals, accelerometer noise) is ignored.
local COUNTED: { [Enum.UserInputType]: boolean } = {
	[Enum.UserInputType.Keyboard] = true,
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.MouseButton2] = true,
	[Enum.UserInputType.MouseButton3] = true,
	[Enum.UserInputType.MouseWheel] = true,
	[Enum.UserInputType.MouseMovement] = true,
	[Enum.UserInputType.Touch] = true,
	[Enum.UserInputType.Gamepad1] = true,
	[Enum.UserInputType.Gamepad2] = true,
	[Enum.UserInputType.Gamepad3] = true,
	[Enum.UserInputType.Gamepad4] = true,
}

local function ping()
	lastPing = os.clock()
	local ok, err = pcall(function()
		Remotes.get("ActivityPing"):FireServer()
	end)
	if not ok then
		warn(`[ActivityController] ping failed: {err}`)
	end
end

local function onInput(input: InputObject)
	if not COUNTED[input.UserInputType] then
		return
	end
	lastInput = os.clock()
	-- Coming back from idle: tell the server at once rather than on the next
	-- loop tick, so the countdown resumes the moment the player does.
	if lastInput - lastPing >= SpinWheelConfig.ACTIVITY_PING_SECONDS then
		ping()
	end
end

function ActivityController.start()
	UserInputService.InputBegan:Connect(onInput)
	UserInputService.InputChanged:Connect(onInput)

	-- The steady cadence while the player keeps playing. Cheap: one clock
	-- compare every few seconds, and a remote at most twice a minute.
	task.spawn(function()
		while true do
			task.wait(5)
			local now = os.clock()
			if now - lastInput <= SpinWheelConfig.IDLE_SECONDS and now - lastPing >= SpinWheelConfig.ACTIVITY_PING_SECONDS then
				ping()
			end
		end
	end)
end

return ActivityController
