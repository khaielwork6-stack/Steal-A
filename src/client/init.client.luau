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
local IndexController = require(script.Controllers.IndexController)
local UpgradesController = require(script.Controllers.UpgradesController)
local TreadmillController = require(script.Controllers.TreadmillController)
local DropController = require(script.Controllers.DropController)
local UIStateController = require(script.Controllers.UIStateController)
local ShopController = require(script.Controllers.ShopController)
local TreadmillOfferController = require(script.Controllers.TreadmillOfferController)
local BossOfferController = require(script.Controllers.BossOfferController)
local TrailShopController = require(script.Controllers.TrailShopController)
local AudioController = require(script.Controllers.AudioController)

HUDController.start()
GuardianFxController.start()
BasePromptController.start()
TutorialController.start()
CombatController.start()
InteractController.start()
InventoryController.start()
IndexController.start()
UpgradesController.start()
TreadmillController.start()
DropController.start()
-- UI visibility first: the treadmill card and the trail shop both claim through
-- it, and a claim made before it is listening would never be released.
UIStateController.start()
ShopController.start()
TreadmillOfferController.start()
BossOfferController.start()
TrailShopController.start()
AudioController.start()

print("[Client] controllers started")
