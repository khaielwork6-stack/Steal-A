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
local HotbarController = require(script.Controllers.HotbarController)
local EventStandController = require(script.Controllers.EventStandController)
local OfferRailController = require(script.Controllers.OfferRailController)
local GuardianShopController = require(script.Controllers.GuardianShopController)
local RobPromptController = require(script.Controllers.RobPromptController)
local PortalController = require(script.Controllers.PortalController)
local SlapDisplayController = require(script.Controllers.SlapDisplayController)
local ShiftLockController = require(script.Controllers.ShiftLockController)
local OfflineEarningsController = require(script.Controllers.OfflineEarningsController)
local CarryUIController = require(script.Controllers.CarryUIController)
local TreadmillSpectateController = require(script.Controllers.TreadmillSpectateController)
local HatchController = require(script.Controllers.HatchController)
local EscapeFlashController = require(script.Controllers.EscapeFlashController)
local BaseEarningsController = require(script.Controllers.BaseEarningsController)
local AttractionSignController = require(script.Controllers.AttractionSignController)
local SpinWheelController = require(script.Controllers.SpinWheelController)
local StarterTaskController = require(script.Controllers.StarterTaskController)

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
HotbarController.start()
EventStandController.start()
OfferRailController.start()
GuardianShopController.start()
RobPromptController.start()
PortalController.start()
SlapDisplayController.start()
SettingsController.start()
-- Touch only: forces landscape and adds the shift-lock button. A no-op on
-- desktop.
ShiftLockController.start()
-- Listens to StatePush for a pending offline payout; shows nothing otherwise.
OfflineEarningsController.start()
-- Mirrors "carrying" into the one HUD claim that leaves only DROP on screen.
CarryUIController.start()
-- Plays the run cycle on OTHER players' characters while the server says
-- they are training, so a treadmill session is visible from across the plot.
TreadmillSpectateController.start()
-- The pedestal countdowns, the HATCH! prompt and the scripted reveal. Draws
-- only; the server has already committed before any of it plays.
HatchController.start()
-- The light-yellow screen flash on a successful escape. Hangs off the same
-- "Escape" sound cue the chase music stops on, so the two always agree.
EscapeFlashController.start()
-- The per-item "+$1,512" over your own base, on the income tick that pays it.
BaseEarningsController.start()
-- The bob on every safe-zone attraction arrow. The signs themselves are built
-- server-side; only the motion is local.
AttractionSignController.start()
-- The free spin: hides every wheel but the one on this player's own plot,
-- draws its countdown, and plays the spin the server has already decided.
-- AFTER HUDController, which is what starts EffectsController for the burst.
SpinWheelController.start()
-- The three-row beginner checklist, bottom-right. Renders StatePush.starter
-- and disappears for good when the server stops sending it.
StarterTaskController.start()

print("[Client] controllers started")
