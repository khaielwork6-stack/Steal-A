--!strict
--[[
	DropController
	The DROP button: hidden until the player is carrying stolen loot, then it
	slides up from the bottom of the screen.

	THE BUTTON IS THE PACK'S, NOT OURS
	`StarterGui.MainUI["DROP BUTTON NEW"]` is a real button out of the purchased
	UI pack - the same Frame / Studs / Rays / UIStroke / UIGradient construction
	as Shop and Index. It shipped as a spare SHOP button; everything here does is
	retitle it, move it to the bottom of the screen and drive its visibility.
	Nothing is drawn from scratch, and if the pack is ever re-imported this picks
	the button back up by name and by SHAPE (see findButton) rather than dying.

	WHY IT IS NOT JUST `button.Visible = true`
	Pack buttons ship `Active = false` and already carry the `_UIHandlerSetup`
	attribute, because the pack drives them from `InputBegan` and opens whichever
	panel in `MainUI.Frames` shares the button's name. A clone bound with
	`Activated` therefore never fires, and `UIAnim.bindButton` silently bails on
	anything already stamped. `UIAnim.claimButton` clears both attributes, binds
	hover/press/ripple, and re-enables Active - in that order. This has bitten
	twice before (the Index tabs, then the Storage buttons); route through it.

	THE SERVER OWNS THE DROP
	Clicking fires `DropLootRequest` with no arguments. The server already knows
	what this player is carrying; asking the client to name the item would hand it
	a decision it has no business making. The button is also NOT hidden optimistically
	on click - it disappears when StatePush says the carry is gone, so a refused
	drop leaves the button exactly where it was.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local DropController = {}

local player = Players.LocalPlayer

local button: TextButton? = nil
local scale: UIScale? = nil
local carrying = false
local shownAt = 0

-- ==========================================================
-- LAYOUT
-- ==========================================================

--- Bottom centre, above the pack's currency bar. Anchored to the BOTTOM edge so
--- the resting position is a fixed distance off the bottom of the screen on any
--- aspect ratio, rather than drifting with the height of the viewport.
local RESTING_POSITION = UDim2.new(0.5, 0, 0.86, 0)
--- Where it sits while hidden: below the screen edge, so the entrance is a slide
--- up rather than a pop out of nowhere.
local HIDDEN_POSITION = UDim2.new(0.5, 0, 1.12, 0)

--- Width as a fraction of the viewport, then clamped in pixels. Scale alone gets
--- unreadable on a phone and absurd on a 4K monitor; the pack's own buttons are
--- pixel-sized for the same reason.
local WIDTH_SCALE = 0.15
local MIN_WIDTH = 132
local MAX_WIDTH = 260

local SLIDE_IN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

--- Idle motion. Deliberately tiny - it should read as "alive", never as bouncing.
local IDLE_AMPLITUDE = 0.014
local IDLE_SPEED = 2.2

-- ==========================================================
-- LOOKUP
-- ==========================================================

--- The pack's spare button, by name first and then by shape.
---
--- Matching on name alone is what silently disabled the interact prompt when the
--- pack was re-imported under a different name, so the fallback scan looks for
--- the construction instead: a TextButton carrying a `Title` label and the
--- pack's `Frame > Studs` art, sitting outside the `Buttons` rail.
local function findButton(mainUi: Instance): TextButton?
	local named = mainUi:FindFirstChild("DROP BUTTON NEW", true)
	if named and named:IsA("TextButton") then
		return named
	end

	for _, descendant in mainUi:GetDescendants() do
		if descendant:IsA("TextButton") and descendant.Name:upper():find("DROP") then
			local frame = descendant:FindFirstChild("Frame")
			if frame and frame:FindFirstChild("Studs") and descendant:FindFirstChild("Title") then
				warn(`[DropController] adopted the drop button by shape: {descendant:GetFullName()}`)
				return descendant
			end
		end
	end
	return nil
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function build(): boolean
	local playerGui = player:WaitForChild("PlayerGui")
	local mainUi = playerGui:WaitForChild("MainUI", 20)
	if not mainUi then
		warn("[DropController] MainUI not found - drop button disabled.")
		return false
	end

	local found = findButton(mainUi)
	if not found then
		warn(
			"[DropController] no DROP button in the pack - the drop button is disabled. "
				.. 'Expected a TextButton named "DROP BUTTON NEW" under MainUI.'
		)
		return false
	end

	button = found

	-- Retitle. The pack shipped it as a SHOP button; the art is reused verbatim
	-- and only the word changes.
	local title = found:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = "DROP"
	end
	found.Text = ""

	-- Position and size. The pack's own UIAspectRatioConstraint keeps the shape,
	-- so only the width is set here and the height follows it.
	found.AnchorPoint = Vector2.new(0.5, 0.5)
	found.Position = HIDDEN_POSITION
	found.Size = UDim2.fromScale(WIDTH_SCALE, WIDTH_SCALE)
	found.Visible = false
	-- Above the currency bar, below the notification stack.
	found.ZIndex = 6

	if not found:FindFirstChildOfClass("UISizeConstraint") then
		local limit = Instance.new("UISizeConstraint")
		limit.MinSize = Vector2.new(MIN_WIDTH, 0)
		limit.MaxSize = Vector2.new(MAX_WIDTH, math.huge)
		limit.Parent = found
	end

	-- One UIScale, reused by the pop, the press feedback and the idle motion.
	local existing = found:FindFirstChildOfClass("UIScale")
	if not existing then
		local created = Instance.new("UIScale")
		created.Parent = found
		existing = created
	end
	scale = existing

	-- Hover, press and ripple, in the order the pack requires. See the header.
	UIAnim.claimButton(found)

	found.Activated:Connect(function()
		if not carrying then
			return
		end
		-- Feedback is immediate; the state change is not. The button hides when
		-- the server says the carry is gone, so a refused drop leaves it up.
		UIAnim.punch(found, 0.16)
		Remotes.get("DropLootRequest"):FireServer()
	end)

	return true
end

-- ==========================================================
-- SHOW / HIDE
-- ==========================================================

local function show()
	local target = button
	local uiScale = scale
	if not target or not uiScale then
		return
	end

	shownAt = os.clock()
	target.Visible = true
	target.Position = HIDDEN_POSITION
	uiScale.Scale = 0.82

	TweenService:Create(target, SLIDE_IN, { Position = RESTING_POSITION }):Play()
	TweenService:Create(uiScale, SLIDE_IN, { Scale = 1 }):Play()
end

local function hide()
	local target = button
	local uiScale = scale
	if not target or not uiScale then
		return
	end

	local slide = TweenService:Create(target, SLIDE_OUT, { Position = HIDDEN_POSITION })
	TweenService:Create(uiScale, SLIDE_OUT, { Scale = 0.86 }):Play()
	slide:Play()
	slide.Completed:Once(function()
		-- Only actually hide if we are still meant to be hidden: a fast
		-- steal-drop-steal must not have its entrance cancelled by the tail of
		-- the previous exit.
		if not carrying and target.Parent then
			target.Visible = false
		end
	end)
end

-- ==========================================================
-- START
-- ==========================================================

function DropController.start()
	if not build() then
		return
	end

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if not state then
			return
		end
		local nowCarrying = state.carrying ~= nil
		if nowCarrying == carrying then
			return
		end
		carrying = nowCarrying
		if carrying then
			show()
		else
			hide()
		end
	end)

	-- Idle breathe, only while shown and only after the entrance has settled, so
	-- it never fights the slide-in.
	RunService.RenderStepped:Connect(function()
		local target = button
		local uiScale = scale
		if not target or not uiScale or not carrying or not target.Visible then
			return
		end
		local since = os.clock() - shownAt
		if since < 0.45 then
			return
		end
		uiScale.Scale = 1 + math.sin(since * IDLE_SPEED) * IDLE_AMPLITUDE
	end)
end

return DropController
