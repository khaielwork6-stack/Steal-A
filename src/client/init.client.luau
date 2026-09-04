--!strict
--[[
	Client bootstrap.

	Controllers render replicated state and send intent. They never decide
	rewards, ownership or outcomes (GDD section 16).
]]

local HUDController = require(script.Controllers.HUDController)
local GuardianFxController = require(script.Controllers.GuardianFxController)
local BasePromptController = require(script.Controllers.BasePromptController)

HUDController.start()
GuardianFxController.start()
BasePromptController.start()

print("[Client] controllers started")
