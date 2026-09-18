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
local Effects = require(ReplicatedStorage.Shared.Util.Effects)

local UIStateController = {}

local player = Players.LocalPlayer

--- Top-level MainUI children that make up "the normal HUD". Panels the player
--- opens themselves (Frames) are NOT in this list: hiding those would fight the
--- pack's own open/close logic. The DROP button is not in it either - it is
--- the one thing a carrier keeps. The offer rail is matched by prefix because
--- the pack named it with a trailing space.
local HUD_ELEMENTS = { "Buttons", "Bottom", "Top", "StatHUD", "SocialBoosts", "Notifications", "NightTimer", "EventPill" }
local HUD_PREFIXES = { "UI FOR ANIMAL" }
--- Whole ScreenGuis of ours that are HUD too (the hotbar).
local HUD_SCREENS = { "HotbarUI", "TouchGui", "ShiftLockUI" }
--- Claims a screen stays up for (round3-gameplay): a carrier keeps the
--- hotbar so the gadgets on 3-5 stay usable (HotbarController shows only the
--- gadget slots during a carry). Any OTHER claim still hides it.
local SCREEN_KEEP: { [string]: { [string]: true } } = {
	HotbarUI = { carry = true }, TouchGui = { carry = true }, ShiftLockUI = { carry = true },
}
--- How often the watchdog below checks that a held claim still has an owner.
local WATCHDOG_SECONDS = 1

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
			if Effects.isReduced() then
				element.Visible = false
				continue
			end
			-- Scale away rather than snapping off, and only then stop drawing.
			local scale = element:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
			scale.Parent = element
			local tween = TweenService:Create(scale, UIAnim.SHRINK, { Scale = 0.8 })
			tween:Play()
			tween.Completed:Once(function()
				-- Only finish hiding what is STILL ours to hide. `Completed`
				-- also fires when a later popIn cancels this tween, and a claim
				-- taken in the meantime by someone else must not turn that
				-- cancelled shrink into a hide that nobody remembers to undo.
				if anyClaim() and remembered[element] ~= nil then
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
	-- Device switches and respawns may create or re-enable touch screens
	-- while a modal is already open. Apply the current claims immediately.
	task.spawn(function()
		local pg = player:WaitForChild("PlayerGui")
		local function watchScreen(child: Instance)
			if not child:IsA("ScreenGui") or not table.find(HUD_SCREENS, child.Name) then return end
			child:GetPropertyChangedSignal("Enabled"):Connect(function()
				if child.Enabled and screenSuppressed(child) then
					remembered[child] = true
					child.Enabled = false
				end
			end)
			child.Destroying:Connect(function() remembered[child] = nil end)
			refreshScreens()
		end
		for _, child in pg:GetChildren() do watchScreen(child) end
		pg.ChildAdded:Connect(watchScreen)
	end)
	-- A pack panel is a modal too: hotbar/cash/night HUD must not cover its controls.
	task.spawn(function()
		local pg = player:WaitForChild("PlayerGui")
		local ui = pg:WaitForChild("MainUI", 30)
		local frames = ui and ui:WaitForChild("Frames", 30)
		if not frames then return end
		-- HUD controllers can repaint visibility after a modal opens (notably
		-- the night timer). Keep the claim effective until the modal closes.
		local function watchHud(child: Instance)
			if not child:IsA("GuiObject") then return end
			local matched = table.find(HUD_ELEMENTS, child.Name) ~= nil
			for _, prefix in HUD_PREFIXES do
				matched = matched or child.Name:find(prefix, 1, true) == 1
			end
			if not matched then return end
			local function suppress()
				if child.Visible and anyClaim() then
					remembered[child] = true
					child.Visible = false
				end
			end
			child:GetPropertyChangedSignal("Visible"):Connect(suppress)
			child.Destroying:Connect(function() remembered[child] = nil end)
			suppress()
		end
		if ui then
			for _, child in ui:GetChildren() do watchHud(child) end
			ui.ChildAdded:Connect(watchHud)
		end
		local function watch(frame: Instance)
			if not frame:IsA("GuiObject") then return end
			local reason = "panel:" .. frame.Name
			local function sync()
				if frame.Parent == frames and frame.Visible then UIStateController.claim(reason)
				else UIStateController.release(reason) end
			end
			frame:GetPropertyChangedSignal("Visible"):Connect(sync)
			frame.AncestryChanged:Connect(sync)
			sync()
		end
		for _,frame in frames:GetChildren() do watch(frame) end
		frames.ChildAdded:Connect(watch)

		-- THE WATCHDOG. "All the UI vanished after a reveal and never came
		-- back" is, every time, a claim whose owner is gone: a panel that was
		-- destroyed or re-parented without its Visible ever flipping, a
		-- controller whose release path errored mid-flight. The HUD then
		-- stays hidden for the rest of the session with nothing left to
		-- release it. Once a second: a panel claim whose frame is no longer
		-- a visible child of Frames is dropped, and if that leaves no claim
		-- at all, the HUD is restored exactly as a release would have.
		task.spawn(function()
			while true do
				task.wait(WATCHDOG_SECONDS)
				local dropped = false
				for reason, held in claims do
					if held and reason:sub(1, 6) == "panel:" then
						local frame = frames:FindFirstChild(reason:sub(7))
						if not (frame and frame:IsA("GuiObject") and frame.Visible and frame.Parent == frames) then
							claims[reason] = nil
							dropped = true
						end
					end
				end
				if dropped and not anyClaim() then
					applyRestored()
				elseif dropped then
					refreshScreens()
				end
				-- Belt and braces: nothing claimed, yet something we hid is
				-- still hidden (a restore that was interrupted). Put it back.
				if not anyClaim() then
					for element, was in remembered do
						if element:IsA("GuiObject") and was == true and not element.Visible and element.Parent then
							remembered[element] = nil
							element.Visible = true
						end
					end
				end
			end
		end)
	end)
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
