--[[
    ================================================
    UI ANIMATION HANDLER (v4 - rebuilt from scratch)
    ================================================
    Script type: LocalScript
    Where to place: StarterGui or StarterPlayer.StarterPlayerScripts

    Expected hierarchy:
    ScreenGui
    ├── Buttons
    │   ├── Left  (Gifts, Index, Settings, Rebirth, Invite, Store, ...)  <- ImageButton/TextButton
    │   └── Right (...)                                                  <- ImageButton/TextButton
    └── Frames
        ├── Rebirth   (Frame)
        ├── Gifts     (Frame)
        │   └── Top
        │       └── Frame
        │           └── Close   <- "X" button that closes THIS frame
        ├── Daily     (Frame)
        └── Inventory (Frame)

    WHAT CHANGED IN THIS VERSION (per request):
    1. Frames no longer pop open with a UIScale tween. They now SLIDE UP
       from below the bottom edge of the screen and slide back down when closed.
    2. Whenever ANY frame opens, EVERY other open frame in the Frames folder
       is force-closed first — only one frame can ever be visible at a time.
    3. A screen-wide blur (Lighting.BlurEffect) fades in while a frame is open
       and fades out again once everything is closed.
    4. All animation logic (buttons, ripple, notifications, hitboxes) has been
       rewritten from scratch, keeping the same feature set as before.
    5. Comments are in English as requested.
--]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================
-- BASIC CONFIG
-- ============================================================
local SCREEN_GUI_NAME = "MainUI" -- change to match your ScreenGui's name
local FRAMES_FOLDER_NAME = "Frames"

local screenGui = playerGui:WaitForChild(SCREEN_GUI_NAME)
local framesFolder = screenGui:WaitForChild(FRAMES_FOLDER_NAME)

-- Keybind that opens one specific frame directly (e.g. "`" -> Inventory)
local INVENTORY_KEYBIND = Enum.KeyCode.F
local INVENTORY_FRAME_NAME = "Inventory"

-- ============================================================
-- NOTIFICATIONS CONFIG (ScreenGui.Notifications)
-- ============================================================
local NOTIFICATIONS_FRAME_NAME = "Notifications"
-- REMOVED: NOTIFICATION_TEST_KEYBIND (was Enum.KeyCode.E). This demo keybind
-- played EVERY notification template in order on each press, which is why
-- interacting with anything fired "??? Spawned" / "Inventory Full!" / etc.
-- Real notifications now come from the server via ToastController.

local NOTIFICATION_DISPLAY_TIME = 1   -- seconds - how long a notification stays before it disappears
local NOTIFICATION_STAGGER_TIME = .3  -- seconds - extra delay AFTER one notification finishes entering, before the next one starts

local notifGrowTweenInfo   = TweenInfo.new(0.4,  Enum.EasingStyle.Back,    Enum.EasingDirection.Out) -- grow-in (pushes the rest down)
local notifPopTweenInfo    = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out) -- springy "pop" of the content
local notifShrinkTweenInfo = TweenInfo.new(0.28, Enum.EasingStyle.Quad,    Enum.EasingDirection.In)  -- shrink before disappearing

-- ============================================================
-- 3D HITBOXES CONFIG (Workspace.guis.<FrameName>.hitbox)
-- ============================================================
local GUIS_FOLDER_NAME = "guis"
local HITBOX_PART_NAME = "hitbox"
local HITBOX_DEBOUNCE_TIME = 1 -- seconds - cooldown to avoid repeated opens on touch

-- ============================================================
-- BUTTON ANIMATION CONFIG
-- ============================================================
local NORMAL_SCALE = 1
local HOVER_SCALE = 1.1
local CLICK_SCALE = 0.88

local hoverTweenInfo   = TweenInfo.new(0.18, Enum.EasingStyle.Back,    Enum.EasingDirection.Out)
local unhoverTweenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad,    Enum.EasingDirection.Out)
local pressTweenInfo   = TweenInfo.new(0.08, Enum.EasingStyle.Sine,    Enum.EasingDirection.Out)
local releaseTweenInfo = TweenInfo.new(0.4,  Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

-- Small rotation "punch" effect on click
local ROTATION_PUNCH_ENABLED = true
local ROTATION_PUNCH_ANGLE = 6 -- degrees

-- Ripple effect at the click/touch point
local RIPPLE_ENABLED = true
local RIPPLE_COLOR = Color3.new(1, 1, 1)
local RIPPLE_START_TRANSPARENCY = 0.45
local RIPPLE_SIZE_MULTIPLIER = 1.6
local RIPPLE_TIME = 0.45
-- The ripple renders inside its own CanvasGroup, BELOW the text/icons (lower ZIndex),
-- so nothing ever gets covered.
local RIPPLE_CONTAINER_ZINDEX = 0

-- ============================================================
-- FRAME ANIMATION CONFIG (slide up from the bottom of the screen)
-- ============================================================
-- Extra padding (in pixels) added below the screen so the frame starts
-- fully off-screen, not just slightly below its final position.
local FRAME_SLIDE_EXTRA_PADDING = 60

local frameOpenSlideInfo  = TweenInfo.new(0.45, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local frameOpenFadeInfo   = TweenInfo.new(0.3,  Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)

local frameCloseSlideInfo = TweenInfo.new(0.3,  Enum.EasingStyle.Quad,  Enum.EasingDirection.In)
local frameCloseFadeInfo  = TweenInfo.new(0.25, Enum.EasingStyle.Quad,  Enum.EasingDirection.In)

local TOGGLE_FRAMES = true -- clicking the same button again closes the frame

-- ============================================================
-- BLUR CONFIG
-- ============================================================
local BLUR_ENABLED = true
local BLUR_SIZE = 18
local blurInTweenInfo  = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local blurOutTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local blurEffect = Lighting:FindFirstChild("UIBlur")
if BLUR_ENABLED and not blurEffect then
	blurEffect = Instance.new("BlurEffect")
	blurEffect.Name = "UIBlur"
	blurEffect.Size = 0
	blurEffect.Parent = Lighting
end

local function updateBlur(shouldShow)
	if not (BLUR_ENABLED and blurEffect) then return end
	local targetSize = shouldShow and BLUR_SIZE or 0
	local info = shouldShow and blurInTweenInfo or blurOutTweenInfo
	TweenService:Create(blurEffect, info, { Size = targetSize }):Play()
end

-- ============================================================
-- "HIDE EVERY OTHER GUI" CONFIG
-- ============================================================
-- When a frame opens:
--   1) every OTHER ScreenGui in the game (chat, other systems' UI, etc.) gets disabled
--   2) everything else INSIDE this ScreenGui (Buttons, HUD elements, anything that
--      isn't the Frames folder) gets hidden too
-- Both are restored automatically once every frame here is closed again.
local HIDE_OTHER_GUIS_ENABLED = true
local HIDE_OWN_HUD_ENABLED = true -- controls point (2) above - set false to only hide OTHER ScreenGuis
local GUI_HIDE_WHITELIST = {
	["Tutorial"] = true, -- our objective banner + world arrow
	-- ["Chat"] = true,
	-- ["CoreGui"] = true,
}
-- Names of objects INSIDE your own ScreenGui that should stay visible even while
-- a frame is open (e.g. keep toast notifications showing over an open panel).
local OWN_HUD_WHITELIST = {
	[NOTIFICATIONS_FRAME_NAME] = true,
}

-- ============================================================
-- INTERNAL STATE
-- ============================================================
local currentlyOpenFrame = nil
local originalFrameData = {} -- [frame] = { Position = UDim2, BackgroundTransparency = number }
local guisWeDisabled = {} -- [ScreenGui] = true, only tracks ones WE turned off (so we don't touch ones the game already had off)
local hudElementsWeHid = {} -- [GuiObject] = true, only tracks elements inside our own ScreenGui that WE hid

-- ============================================================
-- HIDING EVERY OTHER GUI IN THE GAME
-- ============================================================

-- Disables every other ScreenGui under PlayerGui (our own ScreenGui is skipped).
local function hideEveryOtherGui()
	if not HIDE_OTHER_GUIS_ENABLED then return end

	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and gui ~= screenGui and gui.Enabled and not GUI_HIDE_WHITELIST[gui.Name] then
			gui.Enabled = false
			guisWeDisabled[gui] = true
		end
	end
end

-- Re-enables only the ScreenGuis that WE disabled, leaving anything the game
-- itself had turned off untouched.
local function restoreEveryOtherGui()
	if not HIDE_OTHER_GUIS_ENABLED then return end

	for gui in pairs(guisWeDisabled) do
		if gui and gui.Parent then
			gui.Enabled = true
		end
		guisWeDisabled[gui] = nil
	end
end

-- Recursively walks a container. Any visible GuiObject (Frame/Button/Label/...) found
-- gets hidden and remembered; we do NOT recurse further into it once hidden, since
-- hiding a container already visually hides everything inside it.
-- Folders (or anything without a Visible property, like the "Buttons" folder holding
-- "Left"/"Right") aren't renderable themselves, so we recurse through them instead.
local function hideVisibleGuiObjects(container, exceptChild)
	for _, child in ipairs(container:GetChildren()) do
		if child ~= exceptChild and not OWN_HUD_WHITELIST[child.Name] then
			if child:IsA("GuiObject") then
				if child.Visible then
					hudElementsWeHid[child] = true
					child.Visible = false
				end
			elseif child:IsA("Folder") or child:IsA("Configuration") then
				hideVisibleGuiObjects(child, exceptChild)
			end
		end
	end
end

-- Hides everything inside our own ScreenGui EXCEPT the Frames folder itself
-- (the currently open frame lives there and must stay visible).
local function hideOwnHud()
	if not HIDE_OWN_HUD_ENABLED then return end
	hideVisibleGuiObjects(screenGui, framesFolder)
end

-- Restores every HUD element that WE hid.
local function restoreOwnHud()
	if not HIDE_OWN_HUD_ENABLED then return end

	for object in pairs(hudElementsWeHid) do
		if object and object.Parent then
			object.Visible = true
		end
		hudElementsWeHid[object] = nil
	end
end

-- If a new ScreenGui gets added WHILE a frame is open, hide it immediately too.
playerGui.ChildAdded:Connect(function(child)
	task.defer(function()
		if HIDE_OTHER_GUIS_ENABLED and currentlyOpenFrame ~= nil
			and child:IsA("ScreenGui") and child ~= screenGui and child.Enabled
			and not GUI_HIDE_WHITELIST[child.Name] then
			child.Enabled = false
			guisWeDisabled[child] = true
		end
	end)
end)

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function getOrCreateUIScale(guiObject)
	local uiScale = guiObject:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Scale = 1
		uiScale.Parent = guiObject
	end
	return uiScale
end

local function animateScale(uiScale, targetScale, tweenInfo)
	local tween = TweenService:Create(uiScale, tweenInfo, { Scale = targetScale })
	tween:Play()
	return tween
end

-- Small rotation "punch" on click
local function punchRotation(button)
	if not ROTATION_PUNCH_ENABLED then return end

	local originalRotation = button:GetAttribute("_OrigRotation")
	if originalRotation == nil then
		originalRotation = button.Rotation
		button:SetAttribute("_OrigRotation", originalRotation)
	end

	local direction = (math.random(0, 1) == 0) and -1 or 1
	local kickInfo = TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local settleInfo = TweenInfo.new(0.3, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

	local kick = TweenService:Create(button, kickInfo, { Rotation = originalRotation + (ROTATION_PUNCH_ANGLE * direction) })
	kick:Play()
	kick.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			local settle = TweenService:Create(button, settleInfo, { Rotation = originalRotation })
			settle:Play()
		end
	end)
end

-- Creates (once) a separate CanvasGroup that acts as a "drawer" for the ripple.
-- This keeps the ripple from covering text/icons (renders below them, lower ZIndex)
-- and clips it cleanly to the button's shape (including a cloned UICorner),
-- without setting ClipsDescendants on the whole button (which used to cut off other elements).
local function getOrCreateRippleContainer(button)
	local container = button:FindFirstChild("_RippleContainer")
	if container then return container end

	container = Instance.new("CanvasGroup")
	container.Name = "_RippleContainer"
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Size = UDim2.new(1, 0, 1, 0)
	container.Position = UDim2.new(0, 0, 0, 0)
	container.ZIndex = RIPPLE_CONTAINER_ZINDEX
	container.ClipsDescendants = true
	container.Parent = button

	-- If the button has rounded corners (UICorner), copy them onto the container
	-- so the ripple is clipped to the same shape as the button.
	local existingCorner = button:FindFirstChildOfClass("UICorner")
	if existingCorner then
		local cornerClone = existingCorner:Clone()
		cornerClone.Parent = container
	end

	return container
end

-- Ripple effect expanding from the click/touch point
local function createRipple(button, inputPosition)
	if not RIPPLE_ENABLED then return end

	local absPos = button.AbsolutePosition
	local absSize = button.AbsoluteSize
	if absSize.X <= 0 or absSize.Y <= 0 then return end

	local container = getOrCreateRippleContainer(button)

	local relX, relY = 0.5, 0.5
	if inputPosition then
		relX = (inputPosition.X - absPos.X) / absSize.X
		relY = (inputPosition.Y - absPos.Y) / absSize.Y
	end

	local ripple = Instance.new("Frame")
	ripple.Name = "_Ripple"
	ripple.AnchorPoint = Vector2.new(0.5, 0.5)
	ripple.BackgroundColor3 = RIPPLE_COLOR
	ripple.BackgroundTransparency = RIPPLE_START_TRANSPARENCY
	ripple.BorderSizePixel = 0
	ripple.Position = UDim2.new(relX, 0, relY, 0)
	ripple.Size = UDim2.new(0, 0, 0, 0)
	ripple.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ripple

	local maxDimension = math.max(absSize.X, absSize.Y) * RIPPLE_SIZE_MULTIPLIER
	local rippleTween = TweenService:Create(ripple, TweenInfo.new(RIPPLE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(0, maxDimension, 0, maxDimension),
		BackgroundTransparency = 1,
	})
	rippleTween:Play()
	rippleTween.Completed:Connect(function()
		ripple:Destroy()
	end)
end

-- ============================================================
-- OPENING / CLOSING FRAMES
-- ============================================================

local closeFrame
local openFrame
local closeAllFrames

-- Computes how far below the screen the frame needs to start from
-- so it is guaranteed to be fully off-screen before it slides in.
local function getSlideDownOffset(frame)
	local camera = Workspace.CurrentCamera
	local viewportHeight = camera and camera.ViewportSize.Y or 1080
	local framePosY = frame.AbsolutePosition.Y
	local frameHeight = frame.AbsoluteSize.Y
	local distanceToBottom = math.max(0, viewportHeight - framePosY)
	return distanceToBottom + frameHeight + FRAME_SLIDE_EXTRA_PADDING
end

closeFrame = function(frame, skipBlurUpdate)
	local data = originalFrameData[frame]
	if not data or not frame.Visible then return end

	local offset = getSlideDownOffset(frame)

	local slideTween = TweenService:Create(frame, frameCloseSlideInfo, {
		Position = data.Position + UDim2.new(0, 0, 0, offset)
	})
	TweenService:Create(frame, frameCloseFadeInfo, { BackgroundTransparency = 1 }):Play()
	slideTween:Play()

	slideTween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			frame.Visible = false
		end
	end)

	if currentlyOpenFrame == frame then
		currentlyOpenFrame = nil
	end

	if not skipBlurUpdate then
		updateBlur(false)
		restoreEveryOtherGui()
		restoreOwnHud()
	end
end

-- Force-closes every registered frame (used whenever a new one opens,
-- and available to close every panel in the game at once).
closeAllFrames = function()
	for frame in pairs(originalFrameData) do
		if frame.Visible then
			closeFrame(frame, true) -- skip individual blur updates, handled by the caller
		end
	end
	currentlyOpenFrame = nil
end

openFrame = function(frame)
	local data = originalFrameData[frame]
	if not data then return end

	if currentlyOpenFrame == frame and frame.Visible then
		return -- already open
	end

	-- Close absolutely everything else first, so only one frame is ever visible.
	closeAllFrames()

	local offset = getSlideDownOffset(frame)

	frame.Visible = true
	frame.BackgroundTransparency = 1
	frame.Position = data.Position + UDim2.new(0, 0, 0, offset)

	TweenService:Create(frame, frameOpenSlideInfo, { Position = data.Position }):Play()
	TweenService:Create(frame, frameOpenFadeInfo, { BackgroundTransparency = data.BackgroundTransparency }):Play()

	currentlyOpenFrame = frame
	updateBlur(true)
	hideEveryOtherGui()
	hideOwnHud()
end

-- Remembers the frame's original state and wires up its "Close" button
local function setupFrame(frame)
	if originalFrameData[frame] then return end

	originalFrameData[frame] = {
		Position = frame.Position,
		BackgroundTransparency = frame.BackgroundTransparency,
	}

	-- Look for the exact path: Frame.Top.Frame.Close
	local closeButton = nil
	local top = frame:FindFirstChild("Top")
	if top then
		local innerFrame = top:FindFirstChild("Frame")
		if innerFrame then
			closeButton = innerFrame:FindFirstChild("Close")
		end
	end

	-- Fallback: any button named "Close" anywhere inside this frame
	if not (closeButton and closeButton:IsA("GuiButton")) then
		for _, descendant in ipairs(frame:GetDescendants()) do
			if descendant.Name == "Close" and descendant:IsA("GuiButton") then
				closeButton = descendant
				break
			end
		end
	end

	if closeButton and closeButton:IsA("GuiButton") then
		closeButton.MouseButton1Click:Connect(function()
			closeFrame(frame)
		end)
	end
end

-- ============================================================
-- MAIN BUTTON HANDLING
-- ============================================================

local function setupButton(button)
	if button:GetAttribute("_UIHandlerSetup") then return end
	button:SetAttribute("_UIHandlerSetup", true)

	local uiScale = getOrCreateUIScale(button)
	local isHovering = false
	local isPressed = false

	-- Match this button to a frame with the same name
	local matchingFrame = framesFolder:FindFirstChild(button.Name)
	if matchingFrame and matchingFrame:IsA("Frame") then
		setupFrame(matchingFrame)
	end

	button.MouseEnter:Connect(function()
		isHovering = true
		if not isPressed then
			animateScale(uiScale, HOVER_SCALE, hoverTweenInfo)
		end
	end)

	button.MouseLeave:Connect(function()
		isHovering = false
		if not isPressed then
			animateScale(uiScale, NORMAL_SCALE, unhoverTweenInfo)
		end
	end)

	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			isPressed = true
			animateScale(uiScale, CLICK_SCALE, pressTweenInfo)
			createRipple(button, input.Position)
		end
	end)

	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			isPressed = false
			local target = isHovering and HOVER_SCALE or NORMAL_SCALE
			animateScale(uiScale, target, releaseTweenInfo)
		end
	end)

	button.MouseButton1Click:Connect(function()
		punchRotation(button)

		if matchingFrame and matchingFrame:IsA("Frame") then
			if TOGGLE_FRAMES and currentlyOpenFrame == matchingFrame and matchingFrame.Visible then
				closeFrame(matchingFrame)
				updateBlur(false)
				restoreEveryOtherGui()
				restoreOwnHud()
			else
				openFrame(matchingFrame)
			end
		end
	end)
end

-- ============================================================
-- NOTIFICATIONS (ScreenGui.Notifications)
-- ============================================================
--[[
    How it works:
    - Frames like Spawned / PickedUp / InventoryFull / Collected (and any others
      you add) are treated as TEMPLATES - originals are hidden, clones are made on demand.
    - A new notification "enters" at the top of the list (grows from height 0 to full
      height, with a Back/Elastic bounce + fade), and thanks to a UIListLayout in
      Notifications, ALL older notifications are smoothly pushed down.
    - After NOTIFICATION_DISPLAY_TIME seconds the notification shrinks itself away,
      and the ones below it smoothly slide back up (the list layout handles that automatically).
--]]

local notificationsFrame = screenGui:WaitForChild(NOTIFICATIONS_FRAME_NAME)
local notificationTemplates = {}     -- [name] = original template Frame (hidden)
local notificationOrder = {}         -- template order, same as in the Explorer
local notificationLayoutOrder = 0    -- counter, decreases so new items always land on top

for _, child in ipairs(notificationsFrame:GetChildren()) do
	if child:IsA("Frame") or child:IsA("ImageLabel") or child:IsA("CanvasGroup") then
		notificationTemplates[child.Name] = child
		table.insert(notificationOrder, child.Name)
		child.Visible = false -- original only serves as a "template" to clone from
	end
end

local function showNotification(templateName)
	local template = notificationTemplates[templateName]
	if not template then
		warn("[Notifications] No template found named: " .. tostring(templateName))
		return
	end

	local targetSize = template.Size

	-- CanvasGroup container - sits in the UIListLayout and drives the fade of the whole thing
	local container = Instance.new("CanvasGroup")
	container.Name = "_Notification_" .. templateName
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.GroupTransparency = 1
	container.Size = UDim2.new(targetSize.X.Scale, targetSize.X.Offset, 0, 0) -- start at height 0

	notificationLayoutOrder -= 1
	container.LayoutOrder = notificationLayoutOrder -- newest always on top
	container.Parent = notificationsFrame

	-- Clone of the template fills the container completely
	local clone = template:Clone()
	clone.Visible = true
	clone.Size = UDim2.new(1, 0, 1, 0)
	clone.Position = UDim2.new(0, 0, 0, 0)
	clone.Parent = container

	-- Extra "pop" of the content itself (independent of the container's height growth)
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.5
	uiScale.Parent = clone

	-- === ENTER ===
	TweenService:Create(container, notifGrowTweenInfo, {
		Size = targetSize,
		GroupTransparency = 0,
	}):Play()
	TweenService:Create(uiScale, notifPopTweenInfo, { Scale = 1 }):Play()

	-- === EXIT (after waiting) ===
	task.delay(NOTIFICATION_DISPLAY_TIME, function()
		if not container.Parent then return end

		local shrinkTween = TweenService:Create(container, notifShrinkTweenInfo, {
			Size = UDim2.new(targetSize.X.Scale, targetSize.X.Offset, 0, 0),
			GroupTransparency = 1,
		})
		shrinkTween:Play()
		shrinkTween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then
				container:Destroy()
			end
		end)
	end)
end

-- Exposed globally so other scripts (e.g. item pickup handling) can call this directly:
-- _G.ShowNotification("Collected")
_G.ShowNotification = showNotification

_G.CloseAllUIFrames = function()
	-- Exposed in case other scripts need to force-close everything (e.g. on death, cutscene, etc.)
	closeAllFrames()
	updateBlur(false)
	restoreEveryOtherGui()
	restoreOwnHud()
end

-- ============================================================
-- SCANNING + LISTENING FOR NEW OBJECTS
-- ============================================================

local function scanAndSetupButtons(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiButton") then
			setupButton(descendant)
		end
	end
end

-- Register every frame first (so its original state gets remembered)
for _, frame in ipairs(framesFolder:GetChildren()) do
	if frame:IsA("Frame") then
		setupFrame(frame)
	end
end

scanAndSetupButtons(screenGui)

screenGui.DescendantAdded:Connect(function(descendant)
	task.defer(function()
		if descendant:IsA("GuiButton") then
			setupButton(descendant)
		elseif descendant:IsA("Frame") and descendant.Parent == framesFolder then
			setupFrame(descendant)
		end
	end)
end)

-- ============================================================
-- 3D HITBOXES ( Workspace.guis.<FrameName>.hitbox )
-- ============================================================
--[[
    Expected structure:
    Workspace
    └── guis
        ├── Gifts          <- name = name of the Frame under ScreenGui.Frames
        │   └── hitbox     <- BasePart (ideally invisible, CanCollide = false)
        ├── Rebirth
        │   └── hitbox
        └── ...

    Touching a hitbox with the LOCAL player's character (not an NPC, not another
    player) opens the frame that shares the hitbox's parent folder name, using
    the same slide-up + blur animation as a button click.
--]]

local guisFolder = Workspace:FindFirstChild(GUIS_FOLDER_NAME)
local hitboxDebounce = {} -- [hitboxPart] = true while on cooldown

local function isTouchByLocalCharacter(hitPart)
	local character = player.Character
	if not character then return false end
	return hitPart:IsDescendantOf(character)
end

local function setupHitbox(hitboxPart)
	if hitboxPart:GetAttribute("_HitboxSetup") then return end
	hitboxPart:SetAttribute("_HitboxSetup", true)

	local locationFolder = hitboxPart.Parent
	if not locationFolder then return end
	local frameName = locationFolder.Name

	hitboxPart.Touched:Connect(function(hit)
		if hitboxDebounce[hitboxPart] then return end
		if not isTouchByLocalCharacter(hit) then return end

		local frame = framesFolder:FindFirstChild(frameName)
		if not (frame and frame:IsA("Frame")) then return end

		hitboxDebounce[hitboxPart] = true

		setupFrame(frame) -- in case it wasn't registered yet
		openFrame(frame)

		task.delay(HITBOX_DEBOUNCE_TIME, function()
			hitboxDebounce[hitboxPart] = nil
		end)
	end)
end

local function scanGuisFolder()
	if not guisFolder then return end
	for _, locationFolder in ipairs(guisFolder:GetChildren()) do
		local hitbox = locationFolder:FindFirstChild(HITBOX_PART_NAME)
		if hitbox and hitbox:IsA("BasePart") then
			setupHitbox(hitbox)
		end
	end
end

scanGuisFolder()

if guisFolder then
	guisFolder.DescendantAdded:Connect(function(descendant)
		if descendant.Name == HITBOX_PART_NAME and descendant:IsA("BasePart") then
			task.defer(function()
				setupHitbox(descendant)
			end)
		end
	end)
else
	warn("[UIAnimationHandler] Workspace." .. GUIS_FOLDER_NAME .. " not found - 3D hitboxes disabled.")
end

-- ============================================================
-- KEYBINDS ( ` -> Inventory, E -> play all notifications in order )
-- ============================================================

UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then return end -- ignore if another UI element (e.g. chat) consumed the key

	if input.KeyCode == INVENTORY_KEYBIND then
		local inventoryFrame = framesFolder:FindFirstChild(INVENTORY_FRAME_NAME)
		if not (inventoryFrame and inventoryFrame:IsA("Frame")) then return end

		setupFrame(inventoryFrame) -- just in case it wasn't registered yet

		if TOGGLE_FRAMES and currentlyOpenFrame == inventoryFrame and inventoryFrame.Visible then
			closeFrame(inventoryFrame)
			updateBlur(false)
			restoreEveryOtherGui()
			restoreOwnHud()
		else
			openFrame(inventoryFrame)
		end

	end
end)

print("[UIAnimationHandler] Ready - dynamic UI animations active (slide-up frames + blur).")