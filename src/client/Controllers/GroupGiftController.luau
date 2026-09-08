--!strict
--[[
	GroupGiftController
	The "Free Gift!" popup: +10,000 Speed for joining the group.

	THE PANEL IS ONE PAINTED PNG (PngUiConfig.Gift).
	The whole interface - header, art, the three steps, the CLAIM button - is
	drawn in the image. Roblox supplies what has to work: an invisible button
	exactly over the printed CLAIM, one over the printed X, one over the
	printed "Join Community", a breathing glow on CLAIM so it reads as live, a
	CLAIMED! pill once the server says so, and the open/close motion.

	The previous, pack-built version of this screen is preserved verbatim at
	`Client/Backups/FreeGiftUI_Backup_PrePNG` (never required, never started).
	To roll back, copy it over this file.

	WHAT THE CLIENT DOES AND DOES NOT DO - unchanged
	  * It shows Roblox's OWN group prompt (GroupService:PromptJoinAsync). There
	    is no imitation of that prompt anywhere here.
	  * When that prompt closes, it sends `GroupGiftRequest`. Empty. A knock.
	  * It renders CLAIMED when `StatePush.groupGift.claimed` says so - which is
	    the server's word, saved with the profile, so it survives a rejoin.
	  It never grants, never decides membership, and never marks anything.

	THE OPENER
	A small "GIFT" button sits in the HUD. It is NOT placed under `Buttons`, and
	deliberately does not share a name with any frame in `Frames`, so the pack's
	button script animates it but does not try to open a panel for it.
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PngCard = require(ReplicatedStorage.Shared.Util.PngCard)
local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ShopKit = require(ReplicatedStorage.Shared.Util.ShopKit)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local UIStateController = require(script.Parent.UIStateController)

local GroupGiftController = {}

local player = Players.LocalPlayer

local panel: Frame? = nil
local backdrop: TextButton? = nil
local png: PngCard.Card? = nil
local claimPill: TextLabel? = nil
local claimGlow: Frame? = nil
local glowTween: Tween? = nil
local opener: GuiButton? = nil
local open = false
local closing = false
local prompting = false
local latest: any = nil

local GIFT_COLOR = Color3.fromRGB(96, 200, 255)
local GIFT_ACCENT = Color3.fromRGB(24, 110, 200)
--- THE RAINBOW. Six stops around the wheel, ending where it started so the
--- sweep is seamless, and every one of them kept light enough that the white
--- GIFT text on top stays readable. This is a moving gradient, not a glow: the
--- button is the same size and shape it always was.
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 106, 122)),
	ColorSequenceKeypoint.new(0.18, Color3.fromRGB(255, 176, 92)),
	ColorSequenceKeypoint.new(0.36, Color3.fromRGB(255, 238, 120)),
	ColorSequenceKeypoint.new(0.54, Color3.fromRGB(122, 236, 148)),
	ColorSequenceKeypoint.new(0.72, Color3.fromRGB(112, 196, 255)),
	ColorSequenceKeypoint.new(0.86, Color3.fromRGB(186, 142, 255)),
	ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 106, 122)),
})
--- Seconds for one full sweep. Slow enough to read as a shimmer rather than a
--- strobe, which matters on a button a child is looking at all session.
local RAINBOW_PERIOD = 3.6
local rainbowConnection: RBXScriptConnection? = nil
local chestSignConnection: RBXScriptConnection? = nil
local CLAIMED_COLOR = Color3.fromRGB(150, 156, 170)
local CLAIMED_ACCENT = Color3.fromRGB(70, 74, 88)

--- The panel's footprint inside the 16:9 layer. PngCard keeps it to the art's
--- own aspect inside this box, so the number that matters is the smaller one.
local PANEL_SIZE = UDim2.fromScale(0.62, 0.88)
local PANEL_POSITION = UDim2.fromScale(0.5, 0.5)
--- Opens from a touch lower and a touch smaller; closes back the same way.
local PANEL_ENTER_FROM = UDim2.fromScale(0.5, 0.545)
local PANEL_LEAVE_TO = UDim2.fromScale(0.5, 0.535)
local BACKDROP_DIM = 0.45

local ENTER_SCALE = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ENTER_MOVE = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local ENTER_FADE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LEAVE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BACKDROP_IN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
--- CLAIM breathes while the panel is open: a slow, soft rise and fall of a
--- white wash over the printed button. Stopped the moment the panel closes.
local BREATHE = TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BREATHE_REST = 0.93
local BREATHE_PEAK = 0.8
--- After a successful claim the panel celebrates, then leaves on its own.
local SUCCESS_LINGER = 1.4

-- ==========================================================
-- HELPERS
-- ==========================================================

local function mainUi(): ScreenGui?
	local found = ShopKit.mainUi()
	return if found and found:IsA("ScreenGui") then found else nil
end

--- The layer that mirrors `Frames`, shared with the Trail Shop so both panels
--- resolve their scale against the same box the real Shop does.
local function layerFor(ui: ScreenGui): Frame?
	local frames = ui:FindFirstChild("Frames")
	if not frames or not frames:IsA("GuiObject") then
		return nil
	end
	local existing = ui:FindFirstChild("TrailShopLayer")
	if existing and existing:IsA("Frame") then
		return existing
	end
	local made = Instance.new("Frame")
	made.Name = "TrailShopLayer"
	made.BackgroundTransparency = 1
	made.Size = frames.Size
	made.Position = frames.Position
	made.AnchorPoint = frames.AnchorPoint
	made.ZIndex = 10
	local ratio = frames:FindFirstChildOfClass("UIAspectRatioConstraint")
	if ratio then
		ratio:Clone().Parent = made
	end
	made.Parent = ui
	return made
end

local function claimedState(): boolean
	return latest ~= nil and latest.claimed == true
end

local function stopBreathing()
	if glowTween then
		glowTween:Cancel()
		glowTween = nil
	end
	if claimGlow then
		claimGlow.BackgroundTransparency = 1
	end
end

local function startBreathing()
	local glow = claimGlow
	if not glow or claimedState() then
		return
	end
	stopBreathing()
	glow.BackgroundTransparency = BREATHE_REST
	local tween = TweenService:Create(glow, BREATHE, { BackgroundTransparency = BREATHE_PEAK })
	glowTween = tween
	tween:Play()
end

-- ==========================================================
-- CLOSE / OPEN
-- ==========================================================

local function close()
	if not open or closing then
		return
	end
	open = false
	closing = true
	UIStateController.release("gift")
	stopBreathing()
	local frame = panel
	local built = png
	local dim = backdrop
	if not frame then
		closing = false
		return
	end
	-- Nothing takes a click while the panel is on its way out.
	if built then
		built.setInteractive(false)
		TweenService:Create(built.artwork, LEAVE, { ImageTransparency = 1 }):Play()
	end
	if dim then
		dim.Active = false
		TweenService:Create(dim, LEAVE, { BackgroundTransparency = 1 }):Play()
	end
	TweenService:Create(frame, LEAVE, { Position = PANEL_LEAVE_TO }):Play()
	local scale = frame:FindFirstChildOfClass("UIScale")
	if scale then
		local tween = TweenService:Create(scale, LEAVE, { Scale = 0.92 })
		tween:Play()
		tween.Completed:Once(function()
			closing = false
			if not open then
				frame.Visible = false
				if dim then
					dim.Visible = false
				end
			end
		end)
	else
		closing = false
		frame.Visible = false
		if dim then
			dim.Visible = false
		end
	end
end

-- ==========================================================
-- CLAIM FLOW
-- ==========================================================

--- Roblox's own group prompt. Returns once it closes, whatever was chosen.
local function promptJoin(): boolean
	local groupId = latest and tonumber(latest.groupId) or 0
	if groupId <= 0 then
		return false
	end
	local ok, status = pcall(function()
		return GroupService:PromptJoinAsync(groupId)
	end)
	if not ok then
		warn("[GroupGiftController] group prompt failed:", status)
	end
	return ok
end

--- CLAIM pressed. Shows Roblox's group prompt, then knocks on the server. If
--- the player is already in the group the prompt returns AlreadyMember at once
--- and the knock still goes out - which is exactly right for someone who joined
--- from the website.
local function claim()
	if prompting or closing or claimedState() then
		return
	end
	local groupId = latest and tonumber(latest.groupId) or 0
	if groupId <= 0 then
		return
	end
	prompting = true
	local built = png
	if built then
		UIAnim.punch(built.artwork, 0.08)
	end
	task.spawn(function()
		promptJoin()
		prompting = false
		-- Whatever the prompt said, the SERVER decides. It re-checks membership
		-- itself and either pays out once or explains why not.
		Remotes.get("GroupGiftRequest"):FireServer()
	end)
end

--- The printed "Join Community" button: the group prompt on its own, no
--- knock. CLAIM is still the thing that pays.
local function joinOnly()
	if prompting or closing then
		return
	end
	prompting = true
	task.spawn(function()
		promptJoin()
		prompting = false
	end)
end

-- ==========================================================
-- BUILD
-- ==========================================================

local function build(): boolean
	if panel and png then
		return true
	end
	local ui = mainUi()
	local layer = ui and layerFor(ui)
	local layout = PngUiConfig.card("Gift")
	if not ui or not layer or not layout then
		if not layout then
			warn("[GroupGiftController] PngUiConfig has no Gift card - gift panel disabled.")
		end
		return false
	end

	-- A dim over the whole screen, under the layer. Tapping it closes.
	local dim = Instance.new("TextButton")
	dim.Name = "GiftBackdrop"
	dim.Size = UDim2.fromScale(1, 1)
	dim.Position = UDim2.fromScale(0, 0)
	dim.BackgroundColor3 = Color3.fromRGB(4, 8, 16)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Text = ""
	dim.TextTransparency = 1
	dim.AutoButtonColor = false
	dim.Visible = false
	dim.ZIndex = 9
	dim.Parent = ui
	dim.Activated:Connect(close)

	local built = PngCard.build({
		name = "GroupGift",
		layout = layout,
		familyAspect = PngUiConfig.Families.Gift,
		regions = {
			claim = { onActivated = claim },
			close = { onActivated = close },
			join = { onActivated = joinOnly },
		},
		hoverLift = 1.008,
	})
	local frame = built.frame
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = PANEL_POSITION
	frame.Size = PANEL_SIZE
	frame.Visible = false
	frame.ZIndex = 11
	frame.Parent = layer

	-- CLAIMED! over the printed CLAIM once the server says so.
	claimPill = built.pill("claim", "CLAIMED!", Color3.fromRGB(150, 255, 170))

	-- The breathing glow: a soft rounded wash a hair larger than the printed
	-- button, under the hit region so it never takes a click.
	local position, size = built.rectFor("claim")
	if position and size then
		local glow = Instance.new("Frame")
		glow.Name = "ClaimGlow"
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.Position = UDim2.fromScale(position.X.Scale + size.X.Scale / 2, position.Y.Scale + size.Y.Scale / 2)
		glow.Size = UDim2.fromScale(size.X.Scale * 1.03, size.Y.Scale * 1.12)
		glow.BackgroundColor3 = Color3.fromRGB(190, 255, 200)
		glow.BackgroundTransparency = 1
		glow.BorderSizePixel = 0
		glow.Active = false
		glow.ZIndex = 3
		glow.Parent = built.artwork
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.35, 0)
		corner.Parent = glow
		claimGlow = glow
	end

	panel = frame
	backdrop = dim
	png = built
	return true
end

--- Repaints from the server's word: CLAIMED! over the button and no more
--- clicks once it has been paid; the opener dims to match.
local function repaint()
	local built = png
	local claimed = claimedState()
	if built then
		built.setRegionEnabled("claim", not claimed)
		if claimPill then
			claimPill.Visible = claimed
		end
		if claimed then
			stopBreathing()
		elseif open and not glowTween then
			startBreathing()
		end
	end
	if opener then
		-- GONE once the gift is claimed. There is nothing behind it any more,
		-- and the claim is on the profile, so it does not come back on a
		-- rejoin either. The chest keeps its own entrance for anyone who has
		-- not claimed yet; a player who has sees the panel's CLAIMED state.
		opener.Visible = not claimed
		if claimed and rainbowConnection then
			rainbowConnection:Disconnect()
			rainbowConnection = nil
		end
	end
	-- The world chest, locally: this client has claimed, so its sign says so.
	-- A client-side edit of a replicated instance stays on this client, which
	-- is exactly the scope wanted - the sign is per player, not per server.
	if claimed then
		local map = workspace:FindFirstChild("Map")
		local chest = map and map:FindFirstChild("GiftChest")
		local sign = chest and chest:FindFirstChild("Chest") and chest.Chest:FindFirstChild("FreeSign")
		local text = sign and sign:FindFirstChild("Text")
		if text and text:IsA("TextLabel") and text.Text ~= "CLAIMED" then
			text.Text = "CLAIMED"
			text.TextColor3 = Color3.fromRGB(214, 226, 244)
			-- Grey means grey: the rainbow comes off with the offer.
			local rainbow = text:FindFirstChild("Rainbow")
			if rainbow then
				rainbow:Destroy()
			end
			if chestSignConnection then
				chestSignConnection:Disconnect()
				chestSignConnection = nil
			end
		end
	end
end

-- ==========================================================
-- THE CHEST'S FREE! SIGN
-- ==========================================================
--
-- The server builds the sign white under a gradient; this sweeps the same
-- rainbow the GIFT button wears across it and lets it breathe, so the word
-- reads as the same offer from across the lobby. One RenderStepped, one
-- gradient offset, one UIScale - and it stops the moment the gift is
-- claimed (see repaint).

local function dressChestSign()
	local map = workspace:WaitForChild("Map", 120)
	local chest = map and map:WaitForChild("GiftChest", 120)
	local body = chest and chest:WaitForChild("Chest", 30)
	local sign = body and body:WaitForChild("FreeSign", 30)
	local text = sign and sign:FindFirstChild("Text")
	if not text or not text:IsA("TextLabel") or claimedState() then
		return
	end
	local rainbow = text:FindFirstChild("Rainbow")
	if not rainbow or not rainbow:IsA("UIGradient") then
		return
	end
	rainbow.Color = RAINBOW
	local scale = text:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = text
	local phase = math.random() * math.pi * 2
	chestSignConnection = RunService.RenderStepped:Connect(function()
		if not text.Parent then
			return
		end
		local t = os.clock() / RAINBOW_PERIOD
		rainbow.Offset = Vector2.new((t % 1) * 2 - 1, 0)
		rainbow.Rotation = math.sin(t * math.pi * 2) * 14
		scale.Scale = 1 + math.sin(os.clock() * 2.2 + phase) * 0.05
	end)
end

local function show()
	if open or closing or not build() then
		return
	end
	open = true
	local frame = panel :: Frame
	local built = png :: PngCard.Card
	local dim = backdrop
	UIStateController.claim("gift")

	-- Backdrop first, then the panel rises into it: a touch small, a touch
	-- low, scaling up with a small overshoot while it fades in.
	if dim then
		dim.Visible = true
		dim.Active = true
		dim.BackgroundTransparency = 1
		TweenService:Create(dim, BACKDROP_IN, { BackgroundTransparency = BACKDROP_DIM }):Play()
	end
	frame.Visible = true
	frame.Position = PANEL_ENTER_FROM
	local scale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = frame
	scale.Scale = 0.88
	built.artwork.ImageTransparency = 1
	built.setInteractive(true)
	repaint()

	TweenService:Create(frame, ENTER_MOVE, { Position = PANEL_POSITION }):Play()
	TweenService:Create(scale, ENTER_SCALE, { Scale = 1 }):Play()
	TweenService:Create(built.artwork, ENTER_FADE, { ImageTransparency = 0 }):Play()
	-- CLAIM comes alive once the panel has landed.
	task.delay(0.32, function()
		if open and not closing then
			startBreathing()
		end
	end)
end

--- The HUD opener. Cloned from the Top "BASE" button so it matches, retitled,
--- recoloured, and hung under it on the right.
local function buildOpener(ui: ScreenGui)
	if opener then
		return
	end
	local top = ui:FindFirstChild("Top")
	local source = top and top:FindFirstChild("Base")
	if not source or not source:IsA("TextButton") then
		return
	end
	local button = source:Clone()
	button.Name = "GiftOpener"
	button.LayoutOrder = 2
	button:SetAttribute("_UIHandlerSetup", nil)
	button:SetAttribute("AnimBound", nil)
	for _, extra in button:GetChildren() do
		if extra.Name == "_RippleContainer" or extra:IsA("UIScale") then
			extra:Destroy()
		end
	end
	local label = button:FindFirstChild("Title")
	if label and label:IsA("TextLabel") then
		label.Text = "GIFT"
	end
	button.BackgroundColor3 = GIFT_ACCENT
	local face = button:FindFirstChild("Frame")
	local gradient = face and face:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(GIFT_COLOR, GIFT_ACCENT)
	end
	local stroke = face and face:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = Color3.fromRGB(170, 230, 255)
	end
	button.Parent = top
	UIAnim.claimButton(button)

	-- THE RAINBOW SWEEP. One gradient offset moved per frame - no tween
	-- objects, no instances created, nothing to clean up but this connection -
	-- plus a slow breathing scale so the button reads as alive rather than
	-- flashing. Both stop the moment the gift is claimed.
	if gradient then
		gradient.Color = RAINBOW
		gradient.Rotation = 0
		local scale = Instance.new("UIScale")
		scale.Parent = button
		if rainbowConnection then
			rainbowConnection:Disconnect()
		end
		rainbowConnection = RunService.RenderStepped:Connect(function()
			if not button.Parent or not button.Visible then
				return
			end
			local t = os.clock() / RAINBOW_PERIOD
			gradient.Offset = Vector2.new((t % 1) * 2 - 1, 0)
			gradient.Rotation = math.sin(t * math.pi * 2) * 12
			scale.Scale = 1 + math.sin(os.clock() * 2.4) * 0.018
		end)
	end
	button.Activated:Connect(function()
		-- A press the finger can feel: the button dips, then the panel opens.
		UIAnim.punch(button, 0.12)
		if open then
			close()
		else
			show()
		end
	end)
	opener = button

	-- BASE is retired. It only ever teleported the player home, which the
	-- respawn already does, and it was the one thing in the strip pulling
	-- attention from GIFT. It survives just long enough to donate its look.
	source:Destroy()
end

-- ==========================================================
-- START
-- ==========================================================

function GroupGiftController.start()
	-- The hub chest is a second door onto THIS panel. It carries no payload and
	-- grants nothing; every claim still goes out as GroupGiftRequest and is
	-- decided by the server.
	Remotes.get("GiftMenuOpen").OnClientEvent:Connect(function()
		if claimedState() then
			-- Already claimed: still open, so the player can read the panel and
			-- see it is done, but nothing here asks for a second payout.
			show()
			return
		end
		if not open then
			show()
		end
	end)

	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		local ui = mainUi()
		if ui then
			buildOpener(ui)
		end
		local previous = latest
		latest = state.groupGift
		repaint()
		-- The moment the server says claimed, celebrate on the button itself,
		-- then let the panel leave on its own.
		if previous and not previous.claimed and claimedState() and png then
			local built = png :: PngCard.Card
			if claimPill then
				ShopKit.shine(claimPill)
				UIAnim.punch(claimPill, 0.22)
			end
			UIAnim.punch(built.artwork, 0.06)
			if open then
				task.delay(SUCCESS_LINGER, function()
					if open and claimedState() then
						close()
					end
				end)
			end
		end
	end)

	player.CharacterAdded:Connect(close)

	task.spawn(dressChestSign)
end

return GroupGiftController
