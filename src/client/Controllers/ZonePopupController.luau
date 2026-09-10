--!strict
--[[
	ZonePopupController
	"Gym 💪" high at the top of the screen when the player walks into a zone,
	in that zone's own colour.

	GEOMETRY, NOT NETWORK. The lane is a straight run of twelve bands along +Z
	(MapConfig.zoneStartZ / zoneEndZ), so which zone the character is in is a
	comparison the client can make for free; no remote, no server work.

	ITS OWN LABEL, NOT A TOAST. The pack's notification stack sits in the
	middle of the screen, which put the zone name in the player's face. This
	is a single label near the top edge, below the RUN!! warning's slot, with
	the pack's heavy face and outline and a white-to-zone-colour gradient. It
	pops in, holds briefly, and slides away; a new zone replaces it in place.

	DEBOUNCED ON PURPOSE. A zone counts as entered only after the character has
	been inside it for SETTLE_SECONDS without leaving, and the same zone is not
	announced again until the player has genuinely been somewhere else - the
	lobby, or another zone. Dancing on a boundary shows nothing; a transition
	strip between two zones belongs to neither.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local ZonePopupController = {}

local player = Players.LocalPlayer

--- How long the character must stay in a zone before it counts as entered.
local SETTLE_SECONDS = 0.45
--- How far inside a zone's band the character must be: keeps the transition
--- strips and the exact boundary lines from flapping the reading.
local EDGE_INSET = 3
--- How often the position is sampled.
local SAMPLE_INTERVAL = 0.12
--- On screen for this long at full size, then away.
local HOLD_SECONDS = 1.7

--- Just under the RUN!! slot (0.085), well clear of the notification stack.
local POSITION = UDim2.fromScale(0.5, 0.16)
local SIZE = UDim2.fromScale(0.5, 0.075)

local POP_IN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local candidate: number? = nil
local candidateSince = 0
--- The furthest zone this life has already been announced. The pop-up is a
--- PROGRESS beat - "you have reached the Castle" - so it fires on the way out
--- and never on the way back:
---
---   * entering a higher zone than anything announced  -> pop-up
---   * walking back into an earlier zone               -> silent
---   * returning to the Safe Zone                      -> silent
---   * standing on a boundary                          -> silent after the first
---
--- This is presentation history ONLY. `candidate` below still tracks the real
--- current zone every sample, and everything that reads the player's zone keeps
--- reading it; suppressing the banner never suppresses the zone itself.
local highWater = 0
local accumulator = 0

local label: TextLabel? = nil
local gradient: UIGradient? = nil
local scale: UIScale? = nil
local showToken = 0

-- ==========================================================
-- THE LABEL
-- ==========================================================

local function build(ui: ScreenGui)
	local text = Instance.new("TextLabel")
	text.Name = "ZonePopup"
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = POSITION
	text.Size = SIZE
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.Text = ""
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeColor3 = Color3.fromRGB(12, 14, 24)
	text.TextStrokeTransparency = 0
	text.Visible = false
	text.ZIndex = 30
	text.Parent = ui

	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 22
	limit.MaxTextSize = 58
	limit.Parent = text

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(12, 14, 24)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = text

	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Parent = text

	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 1
	uiScale.Parent = text

	label = text
	gradient = grad
	scale = uiScale
end

--- Which zone a world position is inside, or nil (lobby, walls, a transition
--- strip).
local function zoneAt(position: Vector3): number?
	if math.abs(position.X) > MapConfig.LANE_HALF then
		return nil
	end
	local z = position.Z
	if z < EDGE_INSET then
		return nil
	end
	for index = 1, ZoneConfig.COUNT do
		if z >= MapConfig.zoneStartZ(index) + EDGE_INSET and z <= MapConfig.zoneEndZ(index) - EDGE_INSET then
			return index
		end
	end
	return nil
end

--- The zone the banner is currently showing, so `sample` can take it away the
--- moment the player is somewhere else.
local showing: number? = nil

--- Off, now, with no tween to wait on. Every path out of the banner ends here,
--- which is the point: the old code hid it ONLY from inside a tween's
--- Completed callback, so anything that stopped that tween from finishing left
--- the zone name on screen for the rest of the session.
local function hide()
	showing = nil
	showToken += 1
	local text, uiScale = label, scale
	if not text then
		return
	end
	text.Visible = false
	text.TextTransparency = 0
	text.TextStrokeTransparency = 0
	if uiScale then
		uiScale.Scale = 1
	end
end

local function announce(index: number)
	local zone = ZoneConfig.Zones[index]
	local text, grad, uiScale = label, gradient, scale
	if not zone or not text or not grad or not uiScale then
		return
	end
	showToken += 1
	local token = showToken
	showing = index

	text.Text = `{zone.name} {zone.emoji}`
	-- THE WORD CARRIES THE ZONE'S COLOUR, with a white sheen across the top.
	-- It used to be white for the first 45% and only tinted at the very bottom
	-- of the glyphs, which on a warm zone like the Bank read as plain white
	-- text - the colour was there and simply could not be seen.
	local sheen = zone.color:Lerp(Color3.new(1, 1, 1), 0.55)
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(0.32, sheen),
		ColorSequenceKeypoint.new(1, zone.color),
	})
	text.TextTransparency = 0
	text.TextStrokeTransparency = 0
	text.Visible = true
	uiScale.Scale = 0.6
	TweenService:Create(uiScale, POP_IN, { Scale = 1 }):Play()

	task.delay(HOLD_SECONDS, function()
		if showToken ~= token then
			return -- replaced by a newer zone, or already taken away
		end
		TweenService:Create(text, POP_OUT, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(uiScale, POP_OUT, { Scale = 0.85 }):Play()
		-- A PLAIN DEADLINE, not the tween's own Completed. The tween is the
		-- fade; this is what guarantees the label is gone whatever the tween
		-- does, and it is the whole fix for a zone name that never left.
		task.delay(POP_OUT.Time + 0.05, function()
			if showToken == token then
				hide()
			end
		end)
	end)
end

-- ==========================================================
-- SAMPLING
-- ==========================================================

local function sample()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		candidate = nil
		return
	end

	local now = os.clock()
	local here = zoneAt(root.Position)

	-- LEFT THE ZONE, LOST THE BANNER. The pop-up names where the player IS; it
	-- has no business still saying "North Pole" once they are back at their
	-- base. This runs every sample, so it takes the label away on the way out
	-- whatever state the fade happens to be in.
	if showing ~= nil and here ~= showing then
		hide()
	end

	if here ~= candidate then
		candidate = here
		candidateSince = now
		return
	end
	-- The Safe Zone and the transition strips are "no zone". Being there is not
	-- progress and says nothing; it also must not re-arm the zone the player
	-- just came from, which is what used to make walking home and back in
	-- announce the same zone twice.
	if here == nil then
		return
	end
	if here > highWater and now - candidateSince >= SETTLE_SECONDS then
		highWater = here
		announce(here)
	end
end

function ZonePopupController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("MainUI", 20)
	if not ui or not ui:IsA("ScreenGui") then
		return
	end
	build(ui)

	player.CharacterAdded:Connect(function()
		-- A fresh character starts at the base, so the ladder starts again -
		-- but the reset happens HERE, on a real respawn, not every time the
		-- player steps out of a zone. Spawning in does not announce anything on
		-- its own: the first sample only sets the candidate.
		candidate = nil
		highWater = 0
		-- Being caught and respawning at base is one of the ways the banner used
		-- to be left behind: the character it was announced for no longer exists.
		hide()
	end)
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < SAMPLE_INTERVAL then
			return
		end
		accumulator = 0
		sample()
	end)
end

return ZonePopupController
