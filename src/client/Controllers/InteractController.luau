--!strict
--[[
	InteractController
	The single on-screen interaction prompt, built from the PACK'S OWN
	"Action UI" billboard rather than hand-drawn frames.

	SOURCE OF THE VISUAL
	  StarterGui.MainUI.Surface/Billboards.<the interact billboard>
	    Frame
	      E [TextButton]        <- keycap
	        Frame
	          Studs, Rays       <- decorative art, reused for hold feedback
	          Title             <- the letter shown on the keycap
	      Object                <- item name
	      Action                <- what holding will do

	It is located by SHAPE, not by name - see findActionTemplate. The pack has
	shipped this billboard as both "Action UI" and "Action", and matching on the
	name meant a re-import silently disabled every interact prompt in the game.

	WHY ONE SHARED BILLBOARD
	Roblox draws its default prompt UI for EVERY ProximityPrompt in range. A base
	has fourteen display-slot prompts plus activation, upgrade and treadmill pads
	within twelve studs, so a player at their base saw a dozen overlapping cards.
	Every prompt is therefore switched to Style = Custom (which suppresses
	Roblox's UI entirely) and this controller renders exactly ONE - the nearest -
	reusing a single clone of the pack template. Target changes swap the text in
	place, so there are never clones, stacks or flicker.

	HOLD-TO-STEAL
	Stealing must not fire on a tap. The server sets HoldDuration on the loot
	prompt; this controller renders that hold as a fill climbing the keycap plus
	the pack's "Rays" art spinning up, so the player can see they must keep
	holding. Releasing early rewinds both, and only PromptTriggered - which
	Roblox fires at the end of a completed hold - counts as a steal.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local InteractController = {}

local player = Players.LocalPlayer

local shown: { [ProximityPrompt]: boolean } = {}
local current: ProximityPrompt? = nil

local billboard: BillboardGui? = nil
local idleParent: Instance
local root: Frame
local keycap: GuiObject
local keyLabel: TextLabel
local objectLabel: TextLabel
local actionLabel: TextLabel
local holdFill: Frame
local rays: ImageLabel?

local holdTweens: { Tween } = {}
-- Bumped whenever the billboard changes hands, so a deferred hide can tell that
-- it has been superseded.
local hideToken = 0

local function stopHoldTweens()
	for _, tween in holdTweens do
		tween:Cancel()
	end
	table.clear(holdTweens)
end

--- True when a BillboardGui is the pack's interact prompt: what we actually
--- depend on is its SHAPE, not its name.
local function isActionTemplate(candidate: Instance): boolean
	if not candidate:IsA("BillboardGui") then
		return false
	end
	local panel = candidate:FindFirstChild("Frame")
	if not panel or not panel:IsA("Frame") then
		return false
	end
	local key = panel:FindFirstChild("E")
	local inner = key and key:FindFirstChild("Frame")
	return (key ~= nil and key:IsA("GuiObject"))
		and (inner ~= nil and inner:FindFirstChild("Title") ~= nil)
		and panel:FindFirstChild("Object") ~= nil
		and panel:FindFirstChild("Action") ~= nil
end

--- Finds the pack's interact billboard.
---
--- MATCHED BY SHAPE, NOT BY NAME. This looked up exactly
--- `Surface/Billboards.Action UI`, and when the pack folder was re-imported the
--- billboard came back named just "Action" - so a perfectly good, fully intact
--- prompt sat there while every interact prompt in the game silently turned
--- itself off. The known names are still tried first because they are cheap and
--- unambiguous; the scan is what stops a rename from disabling the feature
--- again.
local function findActionTemplate(mainUi: Instance): BillboardGui?
	local surface = mainUi:FindFirstChild("Surface/Billboards") or mainUi
	for _, name in { "Action UI", "Action", "ActionUI" } do
		local named = surface:FindFirstChild(name) or mainUi:FindFirstChild(name, true)
		if named and isActionTemplate(named) then
			return named :: BillboardGui
		end
	end

	for _, descendant in mainUi:GetDescendants() do
		if isActionTemplate(descendant) then
			warn(`[InteractController] adopted interact billboard by shape: {descendant:GetFullName()}`)
			return descendant :: BillboardGui
		end
	end
	return nil
end

--- Clones the pack's Action UI once. Returns false if the pack is missing, in
--- which case the controller stays inert rather than inventing a replacement.
local function build(): boolean
	local playerGui = player:WaitForChild("PlayerGui")
	local mainUi = playerGui:WaitForChild("MainUI", 20)
	if not mainUi then
		warn("[InteractController] MainUI not found - interact prompt disabled.")
		return false
	end

	local template = findActionTemplate(mainUi)
	if not template then
		warn(
			"[InteractController] no interact billboard found in the pack - prompt disabled. "
				.. "Expected a BillboardGui under MainUI containing Frame > {E > Frame > Title, Object, Action}."
		)
		return false
	end

	-- The template itself must never render. It has no Adornee so it would not
	-- anyway, but being explicit stops a future edit from surprising us.
	template.Enabled = false

	local clone = template:Clone()
	clone.Name = "InteractPrompt"
	-- The pack clips the billboard, which cuts the keycap off: the E button is
	-- 1.15x the panel height on purpose so it overhangs.
	clone.ClipsDescendants = false
	-- LightInfluence 1 (the pack default) lets night-time lighting darken the
	-- prompt into unreadability.
	clone.LightInfluence = 0
	-- The pack leaves this at infinity, which draws prompts across the whole map.
	clone.MaxDistance = 60
	-- AlwaysOnTop must stay FALSE. Re-verified in Studio: with it enabled the
	-- billboard reports Enabled = true, Visible = true and a correct AbsoluteSize
	-- of 255x85, yet draws literally nothing on screen. Depth sorting is also
	-- more honest - a prompt behind a wall should not punch through it - so the
	-- occlusion problem is solved by lifting the billboard instead (see liftFor).
	clone.AlwaysOnTop = false
	-- The pack ships this at 15 studs, which renders the inner panel at roughly
	-- 256x85 - readable at point-blank range and mushy from a few studs back.
	clone.Size = UDim2.fromScale(19, 19)
	-- Positioning is computed per target in apply(); a fixed offset cannot clear
	-- loot models that range from a coin to a statue.
	clone.StudsOffset = Vector3.zero
	-- A BillboardGui is a LayerCollector, so PlayerGui wipes it on respawn unless
	-- this is set. Being caught by a guardian respawns you, which destroyed the
	-- shared prompt and left every later reparent erroring with "Parent property
	-- is locked, current parent: NULL".
	clone.ResetOnSpawn = false
	clone.Enabled = false
	clone.Parent = playerGui
	idleParent = playerGui
	billboard = clone

	local panel = clone:FindFirstChild("Frame")
	if not panel or not panel:IsA("Frame") then
		warn("[InteractController] Action UI has no Frame - interact prompt disabled.")
		return false
	end
	root = panel

	local key = panel:FindFirstChild("E")
	local inner = key and key:FindFirstChild("Frame")
	local title = inner and inner:FindFirstChild("Title")
	local object = panel:FindFirstChild("Object")
	local action = panel:FindFirstChild("Action")

	if
		not (key and key:IsA("GuiObject"))
		or not (inner and inner:IsA("GuiObject"))
		or not (title and title:IsA("TextLabel"))
		or not (object and object:IsA("TextLabel"))
		or not (action and action:IsA("TextLabel"))
	then
		warn("[InteractController] Action UI hierarchy unexpected - interact prompt disabled.")
		return false
	end

	keycap = key
	keyLabel = title
	objectLabel = object
	actionLabel = action

	local raysChild = inner:FindFirstChild("Rays")
	rays = if raysChild and raysChild:IsA("ImageLabel") then raysChild else nil

	-- The keycap is a TextButton in the pack. Nothing should be clickable here -
	-- input comes from the ProximityPrompt - and leaving it active swallows
	-- clicks meant for the world behind it.
	if key:IsA("TextButton") then
		key.Active = false
		key.AutoButtonColor = false
		key.Selectable = false
	end

	-- Hold progress climbs the keycap. Clipped to the inner frame so it cannot
	-- spill past the pack's rounded border, and sits under Title (ZIndex 5) but
	-- over Studs/Rays (1 and 2).
	inner.ClipsDescendants = true

	holdFill = Instance.new("Frame")
	holdFill.Name = "HoldFill"
	holdFill.AnchorPoint = Vector2.new(0, 1)
	holdFill.Position = UDim2.fromScale(0, 1)
	holdFill.Size = UDim2.fromScale(1, 0)
	holdFill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	holdFill.BackgroundTransparency = 0.6
	holdFill.BorderSizePixel = 0
	holdFill.ZIndex = 3
	holdFill.Parent = inner

	return true
end

--- Nearest currently-shown prompt, so walking past a row of slots highlights
--- only the one the player actually means.
local function pickNearest(): ProximityPrompt?
	local character = player.Character
	local origin = character and character:FindFirstChild("HumanoidRootPart")
	if not origin or not origin:IsA("BasePart") then
		return nil
	end

	local best, bestDistance = nil, math.huge
	for prompt in shown do
		local part = prompt.Parent
		if prompt.Enabled and part and part:IsA("BasePart") then
			local distance = (part.Position - origin.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = prompt, distance
			end
		else
			shown[prompt] = nil
		end
	end
	return best
end

-- The pack's panel occupies this fraction of the billboard's height; the rest
-- of the 19x19 square is empty padding.
local PANEL_HEIGHT_SCALE = 0.15

--- How far above the target's origin the prompt should float.
---
--- Two things have to be cleared. First the object itself: loot ranges from a
--- coin to a seven-stud statue, so a fixed offset buries the prompt inside the
--- big ones. Second, any label the object already carries - loot spawns with its
--- own name/rarity/income billboard, and at a fixed offset the two drew straight
--- through each other.
---
--- The prompt sits just above the object and BELOW that label. Stacking it above
--- instead was tried and looked fine in a pinned camera, but in normal
--- third-person play it pushed the prompt off the top of the screen entirely.
--- The call to action belongs nearest the thing it acts on.
local function liftFor(part: BasePart): number
	local height = part.Size.Y

	-- Prefer the whole model's height, so a prompt clears a multi-part object
	-- rather than just the one part it is attached to. Two guards, both learned
	-- the hard way:
	--
	--   * Workspace IS a Model. A part with no model of its own - every base pad,
	--     display slot and treadmill - resolved its "model" to Workspace, whose
	--     bounding box is the entire map. That lifted those prompts about 150
	--     studs into the sky, which is why base and treadmill interactions
	--     worked perfectly while appearing to have no UI at all.
	--   * Even a real model must plausibly describe THIS part; a small part
	--     parented into a large container should not inherit its height.
	local model = part:FindFirstAncestorWhichIsA("Model")
	if model and model ~= workspace then
		local _, size = model:GetBoundingBox()
		if size.Y <= height * 4 + 8 then
			height = math.max(height, size.Y)
		end
	end

	local board = billboard
	local halfPanel = if board then (board.Size.Y.Scale * PANEL_HEIGHT_SCALE) / 2 else 1.5
	local floor = height / 2 + 1
	local lift = height / 2 + 2.2

	-- Duck under anything already adorned to this object.
	local root: Instance = model or part
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BillboardGui") and descendant ~= board then
			-- Scale-only billboard sizes are measured in studs.
			local bottom = descendant.StudsOffsetWorldSpace.Y - descendant.Size.Y.Scale / 2
			lift = math.min(lift, bottom - 0.5 - halfPanel)
		end
	end

	-- ...but never so far down that it sinks into the object itself.
	return math.max(lift, floor)
end

--- Re-applies the lift for whatever the billboard is currently attached to.
---
--- This cannot be computed once when the target changes. A loot model grows
--- after it spawns - mutation effects add parts, and its name/rarity label is
--- parented a moment later - so a lift measured on the first frame is wrong by
--- the time the player reads it. Measured live, the prompt settles correctly no
--- matter what the object does after spawning.
local function refreshLift()
	local board = billboard
	local part = board and board.Adornee
	if board and part and part:IsA("BasePart") then
		board.StudsOffsetWorldSpace = Vector3.new(0, liftFor(part), 0)
	end
end

local function keyNameFor(prompt: ProximityPrompt): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "TAP"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Y"
	end
	return prompt.KeyboardKeyCode.Name
end

local function resetHold()
	stopHoldTweens()
	holdFill.Size = UDim2.fromScale(1, 0)
	if rays then
		rays.BackgroundTransparency = 1
		rays.ImageTransparency = 1
		rays.Rotation = 0
	end
end

--- Swaps content in place. Never creates a second billboard.
local function apply(prompt: ProximityPrompt?)
	if prompt == current then
		return
	end
	current = prompt

	local board = billboard
	-- A destroyed instance is no longer under `game`, and reparenting one throws
	-- "Parent property is locked". Bail rather than error every frame.
	if not board or not board:IsDescendantOf(game) then
		return
	end

	if not prompt then
		if board.Enabled then
			-- Hiding is deferred, so it MUST be cancellable. A plain popOut sets
			-- Visible = false from a tween-completion callback that keeps firing
			-- even after a new target has claimed the billboard, which left the
			-- billboard enabled and correctly positioned but with an invisible
			-- root - the prompt silently never came back. Bumping the token below
			-- makes any in-flight hide a no-op.
			hideToken += 1
			local token = hideToken

			local scale = UIAnim.scaleOf(root)
			if scale then
				TweenService:Create(scale, UIAnim.SNAP, { Scale = 0.85 }):Play()
			end

			task.delay(0.14, function()
				if token ~= hideToken or current or not billboard then
					return -- a new prompt took over mid-hide
				end
				root.Visible = false
				if scale then
					scale.Scale = 1
				end
				billboard.Enabled = false
				-- Park it off the world part so a destroyed slot cannot take the
				-- single shared billboard with it.
				billboard.Parent = idleParent
				billboard.Adornee = nil
			end)
		end
		return
	end

	-- Claiming the billboard cancels any hide still counting down.
	hideToken += 1

	local part = prompt.Parent :: BasePart
	board.Adornee = part
	board.Parent = part
	refreshLift()

	objectLabel.Text = prompt.ObjectText
	-- Say the quiet part out loud: a hold prompt must read as a hold.
	actionLabel.Text = if prompt.HoldDuration > 0
		then `HOLD  {prompt.ActionText}`
		else prompt.ActionText
	keyLabel.Text = keyNameFor(prompt)
	resetHold()

	local wasHidden = not board.Enabled or not root.Visible

	board.Enabled = true
	-- Re-show explicitly as well as bumping the token above: the token stops a
	-- future hide from blanking us, and this repairs the root if an earlier one
	-- already did.
	root.Visible = true
	if wasHidden then
		UIAnim.popIn(root, 0.7)
	else
		-- Same billboard, different target: a small punch reads as a swap.
		UIAnim.punch(root, 0.08)
	end
end

function InteractController.start()
	if not build() then
		return
	end

	-- Suppress Roblox's built-in prompt UI everywhere, including prompts created
	-- later at runtime.
	local function makeCustom(instance: Instance)
		if instance:IsA("ProximityPrompt") then
			instance.Style = Enum.ProximityPromptStyle.Custom
		end
	end
	for _, descendant in workspace:GetDescendants() do
		makeCustom(descendant)
	end
	workspace.DescendantAdded:Connect(makeCustom)

	ProximityPromptService.PromptShown:Connect(function(prompt)
		prompt.Style = Enum.ProximityPromptStyle.Custom
		shown[prompt] = true
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		shown[prompt] = nil
	end)

	ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
		if prompt ~= current or prompt.HoldDuration <= 0 then
			return
		end
		stopHoldTweens()

		local linear = TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear)
		local fill = TweenService:Create(holdFill, linear, { Size = UDim2.fromScale(1, 1) })
		fill:Play()
		table.insert(holdTweens, fill)

		if rays then
			rays.Rotation = 0
			local spin = TweenService:Create(rays, linear, { Rotation = 180, ImageTransparency = 0.25 })
			spin:Play()
			table.insert(holdTweens, spin)
		end
	end)

	-- Fires on release AND on completion, so it must only rewind what the
	-- trigger handler has not already cleared.
	ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt)
		if prompt ~= current then
			return
		end
		stopHoldTweens()
		TweenService:Create(holdFill, UIAnim.SNAP, { Size = UDim2.fromScale(1, 0) }):Play()
		if rays then
			TweenService:Create(rays, UIAnim.SNAP, { ImageTransparency = 1 }):Play()
		end
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt ~= current then
			return
		end
		resetHold()
		UIAnim.punch(keycap, 0.3)
		UIAnim.punch(root, 0.1)
	end)

	-- Re-measuring the lift every frame would mean a GetDescendants per frame for
	-- no benefit; four times a second is well under what the eye notices while
	-- an object is still settling.
	local nextLiftCheck = 0

	RunService.Heartbeat:Connect(function()
		apply(pickNearest())

		if current and os.clock() >= nextLiftCheck then
			nextLiftCheck = os.clock() + 0.25
			refreshLift()
		end
	end)
end

return InteractController
