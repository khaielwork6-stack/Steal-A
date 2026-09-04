--!strict
--[[
	Client bootstrap.

	Controllers render replicated state and send intent. They never decide
	rewards, ownership or outcomes (GDD section 16).
]]

local HUDController = require(script.Controllers.HUDController)
local GuardianFxController = require(script.Controllers.GuardianFxController)
local BasePromptController = require(script.Controllers.BasePromptController)
local TutorialController = require(script.Controllers.TutorialController)
local CombatController = require(script.Controllers.CombatController)
local InteractController = require(script.Controllers.InteractController)
local InventoryController = require(script.Controllers.InventoryController)

HUDController.start()
GuardianFxController.start()
BasePromptController.start()
TutorialController.start()
CombatController.start()
InteractController.start()
InventoryController.start()

print("[Client] controllers started")
