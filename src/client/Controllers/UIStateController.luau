--!strict
--[[
	UIStateController
	The ONE thing allowed to hide and restore the normal HUD.

	WHY IT IS CENTRAL
	The treadmill wants the HUD out of the way; a full-screen shop wants the same.
	If each did it themselves, two overlapping requests would fight and whichever
	restored last would win - which is exactly how a player ends up with a
	permanently missing HUD and no way to get it back.

	HOW IT AVOIDS THAT
	Callers do not hide things. They CLAIM a named suppressor
	("treadmill", "trailshop"). The HUD is hidden while at least one claim is
	held and restored when the last one is released, so two overlapping claims
	behave correctly however they interleave.

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
--- pack's own open/close logic.
local HUD_ELEMENTS = { "Buttons", "Bottom", "Top", "ZoneProgress" }

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
end

local function applyRestored()
	for _, element in elements() do
		local was = remembered[element]
		remembered[element] = nil
		-- Back to what it WAS. An element the game had hidden for its own reason
		-- stays hidden.
		if was == nil or was == true then
			element.Visible = true
			UIAnim.popIn(element, 0.85)
		end
	end
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
	end
end

function UIStateController.isSuppressed(): boolean
	return anyClaim()
end

function UIStateController.start()
	-- A respawn rebuilds nothing here (MainUI has ResetOnSpawn = false), but a
	-- claim held across one would leave the HUD hidden with the thing that
	-- claimed it gone. Dropping every claim on respawn is the safe direction:
	-- the worst case is a treadmill card that has to re-claim on the next frame.
	player.CharacterAdded:Connect(function()
		if anyClaim() then
			table.clear(claims)
			applyRestored()
		end
	end)
end

return UIStateController
