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
local StateStore = require(script.StateStore)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PngCard = require(ReplicatedStorage.Shared.Util.PngCard)
local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)

-- Warm the painted UI (trail cards, shop cards, boss offer, gift) in the
-- background from the first frame, so the first shop opened never shows a
-- blank card popping in. A courtesy, not a gate: nothing waits on it.
PngCard.preload(PngUiConfig.allImages())

-- The ONE listener of StatePush / InventoryPush / IndexSummaryPush. Started
-- before any controller subscribes; a controller that subscribes later still
-- gets the latest state replayed, so start order no longer decides whether a
-- panel ever sees the join push.
StateStore.start()

-- ==========================================================
-- STARTING CONTROLLERS
-- ==========================================================
--
-- Each start() used to be a plain call in sequence, so ONE throw stopped every
-- controller after it, and a start() that waits on the world (several wait
-- 30-60 s for a model) held up everything below it.
--
-- Now:
--   * boot() runs a start() under xpcall and warns with a traceback.
--   * The HUD and its layout pass still run first and IN ORDER on this thread:
--     everything below reads MainUI, and the layout pass must run before
--     anything clones a nav button (Upgrades, Storage). This is the one
--     deliberate gate, and it was already a gate before.
--   * Every other controller starts in its own thread, spawned in the original
--     order. task.spawn runs the new thread immediately up to its first yield,
--     so controllers that do not yield still finish in the order written (the
--     comments below that say "after X" still hold); one that yields simply
--     stops blocking the rest.

local function boot(name: string, start: () -> ())
	local ok: boolean, err: any = (xpcall :: any)(start, debug.traceback)
	if not ok then
		warn(`[Client] {name}.start failed: {err}`)
	end
end

local function startLater(name: string, start: () -> ())
	task.spawn(boot, name, start)
end

boot("HUDController", HUDController.start)
-- Right after the HUD binds, before anything clones a nav button: the layout
-- pass moves Settings out of the rail and recolours the buttons the Upgrades
-- and Storage openers are cloned from.
boot("HUDLayoutController", HUDLayoutController.start)
startLater("GuardianFxController", GuardianFxController.start)
startLater("BasePromptController", BasePromptController.start)
startLater("TutorialController", TutorialController.start)
startLater("CombatController", CombatController.start)
startLater("InteractController", InteractController.start)
startLater("InventoryController", InventoryController.start)
startLater("IndexController", IndexController.start)
startLater("UpgradesController", UpgradesController.start)
startLater("TreadmillController", TreadmillController.start)
startLater("DropController", DropController.start)
-- UI visibility first: the treadmill card and the trail shop both claim through
-- it, and a claim made before it is listening would never be released.
-- (UIStateController.start does not yield, so spawn order keeps this true.)
startLater("UIStateController", UIStateController.start)
startLater("ChaseWarningController", ChaseWarningController.start)
startLater("GroupGiftController", GroupGiftController.start)
startLater("BaseSignController", BaseSignController.start)
startLater("ShopController", ShopController.start)
startLater("TreadmillOfferController", TreadmillOfferController.start)
startLater("BossOfferController", BossOfferController.start)
startLater("TrailShopController", TrailShopController.start)
startLater("AudioController", AudioController.start)
startLater("NightController", NightController.start)
-- DisplayFx and ItemArtMotion share one per-frame driver now (DisplayFx owns
-- the loop and calls ItemArtMotion after it has moved the trophies), so their
-- relative start order no longer matters for correctness.
startLater("DisplayFxController", DisplayFxController.start)
startLater("ItemArtMotionController", function()
	require(script.Controllers.ItemArtMotionController).start()
end)
startLater("WorldLootFxController", WorldLootFxController.start)
startLater("ChaseAudioController", ChaseAudioController.start)
startLater("ZonePopupController", ZonePopupController.start)
startLater("HotbarController", HotbarController.start)
startLater("EventStandController", EventStandController.start)
startLater("OfferRailController", OfferRailController.start)
startLater("GuardianShopController", GuardianShopController.start)
startLater("RobPromptController", RobPromptController.start)
startLater("PortalController", PortalController.start)
startLater("SlapDisplayController", SlapDisplayController.start)
startLater("SettingsController", SettingsController.start)
-- Applies the Settings panel's Graphics HIGH / LOW to the world (decorative
-- lights and particles). Listens to the shared Effects flag, so it does not
-- matter whether it starts before or after the saved setting arrives.
startLater("GraphicsQualityController", function()
	require(script.Controllers.GraphicsQualityController).start()
end)
-- Touch only: forces landscape and adds the shift-lock button. A no-op on
-- desktop.
startLater("ShiftLockController", ShiftLockController.start)
-- The character never trips into FallingDown / Ragdoll at this game's speeds.
startLater("TripGuardController", function()
	require(script.Controllers.TripGuardController).start()
end)
startLater("CrouchController", function()
	require(script.Controllers.CrouchController).start()
end)
-- Listens to the state store for a pending offline payout; shows nothing
-- otherwise.
startLater("OfflineEarningsController", OfflineEarningsController.start)
-- Mirrors "carrying" into the one HUD claim that leaves only DROP on screen.
startLater("CarryUIController", CarryUIController.start)
-- Plays the run cycle on OTHER players' characters while the server says
-- they are training, so a treadmill session is visible from across the plot.
startLater("TreadmillSpectateController", TreadmillSpectateController.start)
-- The pedestal countdowns, the HATCH! prompt and the scripted reveal. Draws
-- only; the server has already committed before any of it plays.
startLater("HatchController", HatchController.start)
-- The light-yellow screen flash on a successful escape. Hangs off the same
-- "Escape" sound cue the chase music stops on, so the two always agree.
startLater("EscapeFlashController", EscapeFlashController.start)
-- The per-item "+$1,512" over your own base, on the income tick that pays it.
startLater("BaseEarningsController", BaseEarningsController.start)
-- The bob on every safe-zone attraction arrow. The signs themselves are built
-- server-side; only the motion is local.
startLater("AttractionSignController", AttractionSignController.start)
-- The free spin: hides every wheel but the one on this player's own plot,
-- draws its countdown, and plays the spin the server has already decided.
-- AFTER HUDController, which is what starts EffectsController for the burst
-- (HUDController runs on this thread above, so that is guaranteed).
startLater("SpinWheelController", SpinWheelController.start)
-- The three-row beginner checklist, bottom-right. Renders StatePush.starter
-- and disappears for good when the server stops sending it.
startLater("StarterTaskController", StarterTaskController.start)
-- [monetization pass] The free spin's AFK pause needs to hear that a human is
-- at the controls; and Instant Reveal is hidden where PolicyService restricts
-- paid random items (the server refuses it there too).
startLater("ActivityController", function()
	require(script.Controllers.ActivityController).start()
end)
startLater("PurchasePolicyController", function()
	require(script.Controllers.PurchasePolicyController).start()
end)
-- [polish-events-analytics] the timed-event pill / cards / holiday tint, the
-- first-join flyover and the shop-open funnel step.
startLater("EventController", function()
	require(script.Controllers.EventController).start()
end)
startLater("FlyoverController", function()
	require(script.Controllers.FlyoverController).start()
end)
startLater("AnalyticsController", function()
	require(script.Controllers.AnalyticsController).start()
end)
-- [retention-codes-daily] The CODES row at the top of Settings, and the
-- Daily Rewards panel + its top-strip button (after UIStateController and
-- OfflineEarningsController, whose claims / modal the popup waits for).
startLater("CodesController", function()
	require(script.Controllers.CodesController).start()
end)
startLater("DailyRewardController", function()
	require(script.Controllers.DailyRewardController).start()
end)
-- [social pass] The Invite button, the friend / Premium boost pills and the
-- one-time favourite / notification prompts after a reveal; and the
-- server-wide banner + chat line for Mythic-or-better reveals.
startLater("SocialController", function()
	require(script.Controllers.SocialController).start()
end)
startLater("RevealAnnounceController", function()
	require(script.Controllers.RevealAnnounceController).start()
end)
-- GADGETS-PATROLS AREA: gadget tool input (hotbar keys 3-5), the smoke /
-- jam visuals (honour Reduced Effects and Low Graphics), and the GADGETS
-- section of the Shop panel.
startLater("GadgetController", function()
	require(script.Controllers.GadgetController).start()
end)
startLater("GadgetFxController", function()
	require(script.Controllers.GadgetFxController).start()
end)
startLater("GadgetShopController", function()
	require(script.Controllers.GadgetShopController).start()
end)
-- [lasers-rework] The rooms' moving / blinking beams (posed from the server
-- clock), the flash on a touched beam and the thrown player's camera shake.
startLater("LaserFxController", function()
	require(script.Controllers.LaserFxController).start()
end)
-- [fusion-autoreveal-bases] The fusion animation (the FUSE page itself is
-- drawn inside Storage by InventoryController; the BASE page is attached to
-- the Upgrades panel by UpgradesController; the Auto Reveal shop card is
-- built by ShopController).
startLater("FusionController", function()
	require(script.Controllers.FusionController).start()
end)
-- [retention-quests-pass] The Quests panel (daily/weekly quests + season
-- pass) and its HUD button with the red "claimable" dot.
startLater("QuestController", function()
	require(script.Controllers.QuestController).start()
end)
-- [trading-gifting-boards] The Trade panel + HUD opener, the world "Trade"
-- prompt, the request popup and the trade window. After Index/Storage/
-- Upgrades (it clones the Index panel's shell and button).
startLater("TradeController", function()
	require(script.Controllers.TradeController).start()
end)

-- [vaults-crews] The vault doors, barriers, rotating lasers and signs; the
-- crew card, panel and nameplates. The crew panel clones the Sell skeleton
-- InventoryController parks in MainUI.Templates, so it waits for it itself.
-- [vault-minigames] The lock minigames the server starts at a vault door.
startLater("VaultMinigameController", function()
	require(script.Controllers.VaultMinigameController).start()
end)
startLater("VaultController", function()
	require(script.Controllers.VaultController).start()
end)
startLater("CrewController", function()
	require(script.Controllers.CrewController).start()
end)

-- [round3-gameplay] The lobby GADGETS stand: its "Shop" prompt opens the
-- gadget panel, and its three displays turn (still under Reduced Effects).
startLater("GadgetStoreController", function()
	require(script.Controllers.GadgetStoreController).start()
end)

-- [analytics-discord] The FPS-spike sampler and the client error forwarder
-- (PerfReport remote; the server's PerfFeed decides what to keep).
startLater("PerfController", function()
	require(script.Controllers.PerfController).start()
end)

print("[Client] controllers started")
-- THE LOADING SCREEN IS GONE (owner, 2026-09-18). Roblox's own default one
-- is left in place, and `LoadingScreenDone` is set here with `ClientReady`:
-- two things still wait on it - the first-join flyover and the event banner
-- - and what they actually mean by it is "the client has finished starting",
-- which is this line.
local localPlayer = game:GetService("Players").LocalPlayer
localPlayer:SetAttribute("ClientReady", true)
localPlayer:SetAttribute("LoadingScreenDone", true)
