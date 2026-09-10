--!strict
--[[
	EscapeFlashController
	The screen flash that fires the instant a thief crosses the red line with
	an item.

	WHY IT HANGS OFF THE SOUND CUE
	The server already sends exactly one "Escape" cue per successful run, on
	all three paths that count as getting away with something: crossing the
	safe line mid-chase, walking an item home with no guardian ever waking
	(the "SAFE!" case in init.server), and escaping a base heist
	(HeistService). Listening to that cue means the flash and the sting are
	the same event by construction and can never drift apart - and no new
	remote, payload or server bookkeeping had to be added to get it.

	ChaseAudioController listens to the same cue to stop the chase music, so
	the music cut, the sting and the flash all land on one frame.

	WHY IT CANNOT BLOCK PLAY
	The whole thing is roughly a third of a second, and it is inert for input
	the entire time: a plain Frame is not a GuiButton, `Active` is false and
	every layer sets `Interactable = false`, so taps and clicks pass straight
	through to the game underneath. That matters most on touch, where the
	flash covers the jump button and the thumbstick.

	THE SHAPE OF IT
	Two layers, because a single fading rectangle reads as a dip in
	brightness rather than as a hit:

	  wash  a light-yellow full-screen sheet. Snaps in over PUNCH_IN, holds
	        for nothing at all, then eases away over WASH_OUT.
	  core  a brighter, near-white sheet over the top of it that is gone twice
	        as fast. This is the part that reads as impact; the wash is what
	        makes it feel warm rather than like a camera flash.

	Both are plain frames. A radial bloom would look better still, but it
	would mean an image asset, and this experience already has one asset that
	fails to load at runtime - a full-screen flash is exactly the wrong place
	to risk a second one.

	Both are driven from ONE tween pair rather than a heartbeat loop, so the
	cost is two tweens per escape and nothing at all in between.

	Overlapping escapes (a fast player banking two items, or a heist landing
	on top of a line crossing) restart the same instance instead of stacking
	a second sheet over the first - stacked alpha is what turns a tasteful
	flash into a whiteout.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared").Remotes)

local EscapeFlashController = {}

local player = Players.LocalPlayer

-- ==========================================================
-- TUNING
-- ==========================================================

--- Light yellow, deliberately warm rather than white: this is a reward, and
--- pure white at this alpha reads as damage or as a screenshot flash.
local WASH_COLOR = Color3.fromRGB(255, 244, 176)
local CORE_COLOR = Color3.fromRGB(255, 252, 226)

--- Peak opacity. Bright enough to be unmistakable in peripheral vision,
--- nowhere near enough to hide the lane the player is still running down.
local WASH_PEAK = 0.62
local CORE_PEAK = 0.42

--- The rise. Short enough to read as a hit rather than a fade-in.
local PUNCH_IN = 0.05
--- The falls. The core clears first so the frame settles into warmth before
--- it lets go, which is what stops the tail reading as a lag spike.
local CORE_OUT = 0.16
local WASH_OUT = 0.34

--- With Reduced Effects on: same timing, a third of the intensity. The cue
--- is feedback the player needs, so it is dimmed rather than removed.
local REDUCED_SCALE = 0.34

-- ==========================================================
-- STATE
-- ==========================================================

local screen: ScreenGui? = nil
local wash: Frame? = nil
local core: Frame? = nil
local active: { Tween } = {}
local reducedEffects = false

function EscapeFlashController.setReducedEffects(value: boolean)
	reducedEffects = value
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- Built once, on the first escape, and then reused for the life of the
--- session. ResetOnSpawn is off: a player who dies the moment they cross the
--- line still gets the flash, and the GUI is not rebuilt on every respawn.
local function ensureGui(): (Frame?, Frame?)
	if wash and core and screen and screen.Parent then
		return wash, core
	end

	local playerGui = player:FindFirstChildWhichIsA("PlayerGui")
	if not playerGui then
		return nil, nil
	end

	local existing = playerGui:FindFirstChild("EscapeFlash")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "EscapeFlash"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Over the HUD and the carry UI, under nothing: this is the topmost thing
	-- the game draws for the third of a second it exists.
	gui.DisplayOrder = 500
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = playerGui

	local sheet = Instance.new("Frame")
	sheet.Name = "Wash"
	-- Oversized and centred: on a phone the safe-area inset would otherwise
	-- leave an unlit strip down one edge in landscape.
	sheet.AnchorPoint = Vector2.new(0.5, 0.5)
	sheet.Position = UDim2.fromScale(0.5, 0.5)
	sheet.Size = UDim2.fromScale(1.05, 1.05)
	sheet.BackgroundColor3 = WASH_COLOR
	sheet.BackgroundTransparency = 1
	sheet.BorderSizePixel = 0
	sheet.Active = false
	sheet.Interactable = false
	sheet.ZIndex = 1
	sheet.Parent = gui

	local bloom = Instance.new("Frame")
	bloom.Name = "Core"
	bloom.AnchorPoint = Vector2.new(0.5, 0.5)
	bloom.Position = UDim2.fromScale(0.5, 0.5)
	bloom.Size = UDim2.fromScale(1.05, 1.05)
	bloom.BackgroundColor3 = CORE_COLOR
	bloom.BackgroundTransparency = 1
	bloom.BorderSizePixel = 0
	bloom.Active = false
	bloom.Interactable = false
	bloom.ZIndex = 2
	bloom.Parent = gui

	screen, wash, core = gui, sheet, bloom
	return sheet, bloom
end

-- ==========================================================
-- PLAY
-- ==========================================================

local function cancelActive()
	for _, tween in active do
		tween:Cancel()
	end
	table.clear(active)
end

function EscapeFlashController.play()
	local sheet, bloom = ensureGui()
	if not sheet or not bloom then
		return
	end
	local gui = screen
	if not gui then
		return
	end

	-- A second escape inside the tail of the first restarts it rather than
	-- layering on top of it.
	cancelActive()

	local scale = if reducedEffects then REDUCED_SCALE else 1
	gui.Enabled = true
	sheet.BackgroundTransparency = 1
	bloom.BackgroundTransparency = 1

	local punch = TweenInfo.new(PUNCH_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local washIn = TweenService:Create(sheet, punch, { BackgroundTransparency = 1 - WASH_PEAK * scale })
	local coreIn = TweenService:Create(bloom, punch, { BackgroundTransparency = 1 - CORE_PEAK * scale })

	table.insert(active, washIn)
	table.insert(active, coreIn)
	washIn:Play()
	coreIn:Play()

	-- Quint on the way out: it leaves the peak immediately and then lets go
	-- very gently, which is what makes the tail read as smooth rather than as
	-- a linear wipe.
	coreIn.Completed:Once(function(state)
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		local out = TweenService:Create(
			bloom,
			TweenInfo.new(CORE_OUT, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		table.insert(active, out)
		out:Play()
	end)

	washIn.Completed:Once(function(state)
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		local out = TweenService:Create(
			sheet,
			TweenInfo.new(WASH_OUT, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		table.insert(active, out)
		out:Play()
		out.Completed:Once(function(finished)
			-- Disabled between flashes so the layers cost nothing to draw and
			-- cannot be left faintly tinting the screen if a tween is cut.
			if finished == Enum.PlaybackState.Completed and gui.Parent then
				gui.Enabled = false
			end
		end)
	end)
end

function EscapeFlashController.start()
	Remotes.get("SoundCue").OnClientEvent:Connect(function(name: string)
		-- "EscapeSting" is the retired pair to "Escape"; ChaseAudioController
		-- still accepts both, so this does too rather than being the one place
		-- that disagrees about what an escape sounds like.
		if name == "Escape" or name == "EscapeSting" then
			EscapeFlashController.play()
		end
	end)
end

return EscapeFlashController
