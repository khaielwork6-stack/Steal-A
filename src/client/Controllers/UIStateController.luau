--!strict
--[[
	UIStateController
	The ONE thing allowed to hide and restore the normal HUD.

	WHY IT IS CENTRAL
	The treadmill wants the HUD out of the way; a full-screen shop wants the
	same; a player carrying loot wants nothing but DROP. If each did it
	themselves, two overlapping requests would fight and whichever restored
	last would win - which is exactly how a player ends up with a permanently
	missing HUD and no way to get it back.

	HOW IT AVOIDS THAT
	Callers do not hide things. They CLAIM a named suppressor ("treadmill",
	"trailshop", "carry"). The HUD is hidden while at least one claim is held
	and restored when the last one is released, so overlapping claims behave
	correctly however they interleave.

	RESTORE IS TO REMEMBERED STATE, NOT TO `true`.
	Each element's own Visible is captured the first time it is hidden and put
	back verbatim. Forcing everything visible on restore would resurrect UI the
	game had deliberately hidden for its own reasons - the tutorial arrow, an
	empty-state label, a panel that was closed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = {}

local player = Players.LocalPlayer

--- Top-level MainUI children that make up "the normal HUD". Panels the player
--- opens themselves (Frames) are NOT in this list: hiding those would fight the
--- pack's own open/close logic. The DROP button is not in it either - it is
--- the one thing a carrier keeps. The offer rail is matched by prefix because
--- the pack named it with a trailing space.
local HUD_ELEMENTS = { "Buttons", "Bottom", "Top", "StatHUD", "Notifications", "NightTimer" }
local HUD_PREFIXES = { "UI FOR ANIMAL" }
--- Whole ScreenGuis of ours that are HUD too (the hotbar).
local HUD_SCREENS = { "HotbarUI" }
--- Claims a screen stays up for (round3-gameplay): a carrier keeps the
--- hotbar so the gadgets on 3-5 stay usable (HotbarController shows only the
--- gadget slots during a carry). Any OTHER claim still hides it.
local SCREEN_KEEP: { [string]: { [string]: true } } = { HotbarUI = { carry = true } }

--- Claims tied to the character's life, released on respawn. Everything else
--- (panel claims) is released by its panel.
local CHARACTER_CLAIMS: { [string]: true } = { carry = true, treadmill = true }

local claims: { [string]: boolean } = {}
local remembered: { [Instance]: boolean } = {}

local function mainUi(): Instance?
	local gui = player:FindFirstChild("PlayerGui")
	return if gui then gui:FindFirstChild("MainUI") else nil
end

local function elements(): { GuiObject }
	local ui = mainUi()
	if not ui then
		return {}
	end
	local found = {}
	for _, name in HUD_ELEMENTS do
		local child = ui:FindFirstChild(name)
		if child and child:IsA("GuiObject") then
			table.insert(found, child)
		end
	end
	for _, child in ui:GetChildren() do
		if child:IsA("GuiObject") then
			for _, prefix in HUD_PREFIXES do
				if child.Name:find(prefix, 1, true) == 1 then
					table.insert(found, child)
				end
			end
		end
	end
	return found
end

local function screens(): { ScreenGui }
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then
		return {}
	end
	local found = {}
	for _, name in HUD_SCREENS do
		local screen = gui:FindFirstChild(name)
		if screen and screen:IsA("ScreenGui") then
			table.insert(found, screen)
		end
	end
	return found
end

local function anyClaim(): boolean
	for _, held in claims do
		if held then
			return true
		end
	end
	return false
end

--- Whether some held claim hides this screen (one not in its keep list).
local function screenSuppressed(screen: ScreenGui): boolean
	local keep = SCREEN_KEEP[screen.Name]
	for reason, held in claims do
		if held and not (keep and keep[reason]) then
			return true
		end
	end
	return false
end

--- Screens are settled on EVERY claim change, not only on the first claim
--- and the last release: a screen kept up for one claim must still go when
--- another claim joins, and come back when that one leaves.
local function refreshScreens()
	for _, screen in screens() do
		local hide = screenSuppressed(screen)
		if hide then
			if remembered[screen] == nil then
				remembered[screen] = screen.Enabled
			end
			screen.Enabled = false
		elseif remembered[screen] ~= nil then
			local was = remembered[screen]
			remembered[screen] = nil
			if was == true then
				screen.Enabled = true
			end
		end
	end
end

local function applyHidden()
	for _, element in elements() do
		if remembered[element] == nil then
			remembered[element] = element.Visible
		end
		if element.Visible then
			-- Scale away rather than snapping off, and only then stop drawing.
			local scale = element:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
			scale.Parent = element
			local tween = TweenService:Create(scale, UIAnim.SHRINK, { Scale = 0.8 })
			tween:Play()
			tween.Completed:Once(function()
				if anyClaim() then
					element.Visible = false
				end
				scale.Scale = 1
			end)
		end
	end
	refreshScreens()
end

local function applyRestored()
	for _, element in elements() do
		local was = remembered[element]
		remembered[element] = nil
		-- Back to what it WAS. An element the game had hidden for its own reason
		-- stays hidden. `nil` means applyHidden never touched it (it did not
		-- exist yet when the HUD was hidden), so there is nothing to undo -
		-- forcing it visible used to resurrect UI that was never ours to show.
		if was == true then
			element.Visible = true
			UIAnim.popIn(element, 0.85)
		end
	end
	refreshScreens()
end

--- Hides the normal HUD for as long as `reason` is held.
function UIStateController.claim(reason: string)
	if claims[reason] then
		return
	end
	local wasSuppressed = anyClaim()
	claims[reason] = true
	if not wasSuppressed then
		applyHidden()
	else
		refreshScreens()
	end
end

--- Releases one claim. The HUD returns only when the last one is gone.
function UIStateController.release(reason: string)
	if not claims[reason] then
		return
	end
	claims[reason] = nil
	if not anyClaim() then
		applyRestored()
	else
		refreshScreens()
	end
end

function UIStateController.isSuppressed(): boolean
	return anyClaim()
end

function UIStateController.hasClaim(reason: string): boolean
	return claims[reason] == true
end

function UIStateController.start()
	-- A respawn rebuilds nothing here (MainUI has ResetOnSpawn = false), but a
	-- claim held across one would leave the HUD hidden with the thing that
	-- claimed it gone. Only the claims that belong to the CHARACTER are
	-- dropped (the carry, the treadmill run): a panel claim (gift, trail shop)
	-- belongs to a panel that is still open after the respawn, and clearing it
	-- used to bring the HUD back over the open panel - and then the panel's
	-- own release found nothing to release.
	player.CharacterAdded:Connect(function()
		local dropped = false
		for reason in CHARACTER_CLAIMS do
			if claims[reason] then
				claims[reason] = nil
				dropped = true
			end
		end
		if dropped and not anyClaim() then
			applyRestored()
		elseif dropped then
			refreshScreens()
		end
	end)
end

return UIStateController
