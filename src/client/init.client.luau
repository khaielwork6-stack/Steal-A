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
local ChaseWarningController = require(script.Controllers.ChaseWarningController)
local GroupGiftController = require(script.Controllers.GroupGiftController)
local HUDLayoutController = require(script.Controllers.HUDLayoutController)
local BaseSignController = require(script.Controllers.BaseSignController)
local AudioController = require(script.Controllers.AudioController)
local NightController = require(script.Controllers.NightController)
local DisplayFxController = require(script.Controllers.DisplayFxController)
local ChaseAudioController = require(script.Controllers.ChaseAudioController)
local SettingsController = require(script.Controllers.SettingsController)
local WorldLootFxController = require(script.Controllers.WorldLootFxController)
local ZonePopupController = require(script.Controllers.ZonePopupController)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PngCard = require(ReplicatedStorage.Shared.Util.PngCard)
local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)

-- Warm the painted UI (trail cards, shop cards, boss offer, gift) in the
-- background from the first frame, so the first shop opened never shows a
-- blank card popping in. A courtesy, not a gate: nothing waits on it.
PngCard.preload(PngUiConfig.allImages())

HUDController.start()
-- Right after the HUD binds, before anything clones a nav button: the layout
-- pass moves Settings out of the rail and recolours the buttons the Upgrades
-- and Storage openers are cloned from.
HUDLayoutController.start()
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
ChaseWarningController.start()
GroupGiftController.start()
BaseSignController.start()
ShopController.start()
TreadmillOfferController.start()
BossOfferController.start()
TrailShopController.start()
AudioController.start()
NightController.start()
DisplayFxController.start()
WorldLootFxController.start()
ChaseAudioController.start()
ZonePopupController.start()
SettingsController.start()

print("[Client] controllers started")
