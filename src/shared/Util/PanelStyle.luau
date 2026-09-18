--!strict
-- Presentation shared by the Round 3 panels. Sizes below are SCREEN pixels,
-- so MainUI's phone UIScale cannot quietly shrink a 44px action into a 30px one.
local ClipSafe = require(script.Parent.ClipSafe)
local Device = require(script.Parent.Device)
local PanelStyle = {}

function PanelStyle.corner(object: GuiObject, radius: number)
	local c = object:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = object
end

function PanelStyle.gradient(object: GuiObject, top: Color3, bottom: Color3)
	local g = object:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(top, bottom)
	g.Parent = object
end

-- ==========================================================
-- ONE BORDER PER ELEMENT
-- ==========================================================
--
-- THE BUG THIS EXISTS FOR. Every pack component is a solid outer plate with an
-- inset body inside it, and the pack puts a UIStroke on BOTH: a dark one on the
-- plate and a coloured one on the body. They draw a couple of pixels apart, so
-- each card, nav button and header reads as two borders - a thick dark edge with
-- a thin line hugging it. Worse, `ShopKit.fillCard` only ever re-tinted the
-- first stroke it found, so a recoloured card kept the pack's magenta on the
-- other one: a green CLAIMED quest row ringed in purple.
--
-- THE RULE. A border is a duplicate only when its object is an inset body that
-- FILLS a parent which is itself bordered - which is exactly the plate/body
-- pair and nothing else. The inner one is switched off; the plate keeps its
-- edge, in the colour our code sets.
--
-- WHY "FILLS", AND NOT "HAS A BORDERED ANCESTOR". The first cut of this walked
-- the whole ancestor chain, and a dry run over the live UI showed it switching
-- off 365 borders and keeping 39: because a panel frame carries an edge of its
-- own, EVERY card inside it counted as enclosed and lost its outline too. Two
-- borders only read as one doubled line when they are drawn a couple of pixels
-- apart, and that only happens when the inner rectangle is the outer one. The
-- same dry run with this rule disables 81 and keeps 323 - the inset bodies go,
-- every card plate, panel edge, buy button and badge stays.
--
-- A TextLabel's UIStroke is its legibility outline, not a border, so text is
-- skipped on both sides of the test - it neither loses its outline nor counts as
-- the owner of one.

local BORDER_HANDLED = "_SingleBorder"

local function isText(object: Instance): boolean
	return object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox")
end

--- The stroke that is this object's BORDER, or nil. A Contextual stroke on
--- a text object outlines its glyphs, not its box, so it is not a border -
--- but a Border-mode stroke on a TextButton is exactly that: the pack's nav
--- tiles, QUESTS and DISPLAY / SELL are TextButtons used as plates, and the
--- first cut of this skipped every TextButton outright, so those kept their
--- second edge.
local function borderOf(object: Instance): UIStroke?
	if not object:IsA("GuiObject") then
		return nil
	end
	for _, child in object:GetChildren() do
		if child:IsA("UIStroke") then
			if isText(object) and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
				return nil
			end
			return child
		end
	end
	return nil
end

--- True when `object` covers essentially the whole of `parent`, so a border on
--- each would draw as one doubled line. AbsoluteSize is authoritative, but it
--- is zero until the frame has been laid out, so the declared scale carries the
--- test on the first pass.
--- Returns true / false, or nil when it cannot tell yet (the element has not
--- been laid out), so the caller does not mark a stroke as judged on a
--- measurement that was really a zero.
local function fills(object: GuiObject, parent: GuiObject): boolean?
	local size = object.Size
	if size.X.Scale < 0.85 or size.Y.Scale < 0.85 then
		return false
	end
	-- A pure scale size IS the answer: the pack's bodies are (1, 0.935) and
	-- (1, 0.967), and no layout pass can change what that covers. Only a size
	-- with an offset component needs the rendered rectangle to be sure.
	if size.X.Offset == 0 and size.Y.Offset == 0 then
		return true
	end
	local outer = parent.AbsoluteSize
	local inner = object.AbsoluteSize
	if outer.X < 1 or outer.Y < 1 or inner.X < 1 or inner.Y < 1 then
		return nil
	end
	return inner.X / outer.X >= 0.82 and inner.Y / outer.Y >= 0.82
end

--- The body is stretched over the whole plate. The pack insets it a few
--- percent at the bottom (Size.Y 0.935-0.967, anchored just above centre) so
--- the plate shows as a lip - which, next to the plate's own stroke, reads as
--- a second thin outline even once the body's stroke is off. One border means
--- one: the body covers the plate edge to edge and takes the plate's corner
--- radius so no plate peeks out at the corners.
local function coverPlate(body: GuiObject, plate: GuiObject)
	if body.AutomaticSize ~= Enum.AutomaticSize.None or not body:IsA("Frame") then
		return
	end
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.5)
	body.Size = UDim2.fromScale(1, 1)
	local plateCorner = plate:FindFirstChildOfClass("UICorner")
	if plateCorner then
		local corner = body:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
		corner.CornerRadius = plateCorner.CornerRadius
		corner.Parent = body
	end
end

--- Switches off the inner border of every plate/body pair under `root`, and
--- stretches the body over the plate (see coverPlate).
function PanelStyle.singleBorder(root: Instance)
	local function apply(object: Instance)
		local stroke = borderOf(object)
		if not stroke or stroke:GetAttribute(BORDER_HANDLED) then
			return
		end
		local parent = object.Parent
		if not (parent and parent:IsA("GuiObject") and borderOf(parent)) then
			stroke:SetAttribute(BORDER_HANDLED, true)
			return
		end
		local inset = fills(object :: GuiObject, parent)
		if inset == nil then
			-- Not laid out yet. Leave it UNMARKED so a later pass judges it;
			-- the first version of this marked it here, on a zero-sized
			-- measurement, and every nav tile kept its second edge for good.
			return
		end
		stroke:SetAttribute(BORDER_HANDLED, true)
		if inset then
			stroke.Enabled = false
			coverPlate(object :: GuiObject, parent)
		end
	end
	apply(root)
	for _, descendant in root:GetDescendants() do
		apply(descendant)
	end
end

--- singleBorder now, and again for anything built later (rows are rebuilt, and
--- ShopKit clones a fresh card per product).
---
--- Two shapes of arrival, and only the second is obvious: a whole card is
--- parented in at once (judge it and its subtree), or a UIStroke is added to a
--- frame that was already there (judge that frame ALONE - walking its subtree
--- on every stroke added would re-scan a whole grid per row).
function PanelStyle.watchBorders(root: Instance): RBXScriptConnection
	PanelStyle.singleBorder(root)
	-- Sweeps again once layout has settled, for anything the first pass had
	-- to leave unjudged (see apply), and once more for the late touch
	-- layout. Cheap: judged strokes are skipped by their attribute.
	task.delay(1, PanelStyle.singleBorder, root)
	task.delay(4, PanelStyle.singleBorder, root)
	return root.DescendantAdded:Connect(function(descendant)
		-- Deferred: a builder parents the frame first and sets its size and
		-- stroke after, so an immediate pass would judge an unfinished element.
		task.defer(function()
			local parent = descendant.Parent
			if not parent then
				return
			end
			if descendant:IsA("UIStroke") then
				PanelStyle.singleBorder(parent)
			else
				PanelStyle.singleBorder(descendant)
			end
		end)
	end)
end

function PanelStyle.window(frame: Frame, width: number, height: number)
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.BackgroundTransparency = 0
	PanelStyle.gradient(frame, Color3.fromRGB(43, 56, 116), Color3.fromRGB(21, 23, 60))
	PanelStyle.corner(frame, 16)
	-- The pack fades the outer frame during opening; keep its content plate opaque.
	local plate = Instance.new("Frame")
	plate.Name, plate.BorderSizePixel = "PanelPlate", 0
	plate.Size = UDim2.fromScale(1, 1)
	plate.BackgroundColor3 = Color3.new(1, 1, 1)
	plate.ZIndex = 20
	PanelStyle.corner(plate, 16)
	PanelStyle.gradient(plate, Color3.fromRGB(43, 56, 116), Color3.fromRGB(21, 23, 60))
	plate.Parent = frame
	-- Global ZIndex in the purchased pack otherwise leaves the cash/hotbar above cards.
	local function layer(d: Instance)
		if d:IsA("GuiObject") and d ~= plate and not d:GetAttribute("PanelLayered") then
			d:SetAttribute("PanelLayered", true)
			d.ZIndex += 20
		end
	end
	layer(frame)
	for _,d in frame:GetDescendants() do layer(d) end
	frame.DescendantAdded:Connect(function(d) task.defer(layer, d) end)
	for _,d in frame:GetChildren() do
		if d:IsA("ImageLabel") then d.ImageTransparency = 1 end
	end
	local edge = frame:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	edge.Color, edge.Thickness = Color3.fromRGB(15, 12, 30), 3
	edge.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
	edge.Parent = frame
	local aspect = frame:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then aspect:Destroy() end
	local function fit()
		local camera = workspace.CurrentCamera
		if not camera or not frame.Parent then return end
		local viewport = camera.ViewportSize
		local factor = ClipSafe.scaleChain(frame)
		-- On touch a panel stops short of the screen edges (86% x 84%): the
		-- Roblox top-left buttons, the jump button and the thumbstick all stay
		-- reachable around it, and a panel that fills the phone edge to edge
		-- reads as a new screen rather than a window over the game.
		local maxWidth = if Device.isTouch() then viewport.X * 0.86 else viewport.X - 32
		local maxHeight = if Device.isTouch() then viewport.Y * 0.84 else viewport.Y - (if viewport.Y < 500 then 16 else 88)
		frame.Size = UDim2.fromOffset(math.min(width, maxWidth) / factor, math.min(height, maxHeight) / factor)
		local top = frame:FindFirstChild("Top")
		if top and top:IsA("GuiObject") then
			local ratio = top:FindFirstChildOfClass("UIAspectRatioConstraint")
			if ratio then ratio:Destroy() end
			top.AnchorPoint, top.Position = Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0)
			local headerHeight = if frame.Name == "Storage" and viewport.X < 500 then 112
				else if viewport.Y < 500 then 52 else 64
			top.Size = UDim2.new(1, 0, 0, headerHeight / factor)
			local close = top:FindFirstChild("Close", true)
			if close and close:IsA("GuiButton") then
				close.Active = true
				close.Size = UDim2.fromOffset(48 / factor, 48 / factor)
			end
		end
	end
	-- Device scaling can settle after ViewportSize changes. Refitting on the
	-- ancestor scales keeps the window and close target at their screen size.
	local watched: { [UIScale]: boolean } = {}
	local function watchScales()
		local node: Instance? = frame
		while node do
			local scale = node:FindFirstChildOfClass("UIScale")
			if scale and not watched[scale] then
				watched[scale] = true
				scale:GetPropertyChangedSignal("Scale"):Connect(fit)
			end
			if node:IsA("LayerCollector") then break end
			node = node.Parent
		end
	end
	frame:GetPropertyChangedSignal("Visible"):Connect(fit)
	local camera = workspace.CurrentCamera
	if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit) end
	frame.AncestryChanged:Connect(function()
		watchScales()
		fit()
	end)
	watchScales()
	task.defer(fit)
end

-- Reflow a ShopKit clone; its existing buy button and handlers remain intact.
function PanelStyle.productCard(card: Frame)
	local aspect = card:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then aspect:Destroy() end
	PanelStyle.corner(card, 12)
	local body = card:FindFirstChild("Frame")
	if not body or not body:IsA("Frame") then return end
	PanelStyle.corner(body, 10)
	for _,d in body:GetChildren() do
		if d:IsA("ImageLabel") then d.ImageTransparency = 0.93 end
	end
	local title = body:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.AnchorPoint = Vector2.zero
		title.Position, title.Size = UDim2.fromScale(0.05, 0.035), UDim2.fromScale(0.9, 0.18)
		title.TextWrapped = true
	end
	local description = body:FindFirstChild("Description")
	if description and description:IsA("TextLabel") then
		description.AnchorPoint = Vector2.zero
		description.Position, description.Size = UDim2.fromScale(0.40, 0.26), UDim2.fromScale(0.56, 0.35)
	end
	local icons = body:FindFirstChild("Icon")
	if icons then for _,d in icons:GetChildren() do
		if d:IsA("ImageLabel") then
			d.AnchorPoint = Vector2.new(0.5, 0.5)
			d.Position, d.Size = UDim2.fromScale(0.21, 0.58), UDim2.fromScale(0.32, 0.62)
			d.ScaleType = Enum.ScaleType.Fit
		end
	end end
	local choose = body:FindFirstChild("Choose")
	if choose and choose:IsA("GuiObject") then
		choose.AnchorPoint = Vector2.zero
		choose.Position, choose.Size = UDim2.fromScale(0.4, 0.70), UDim2.fromScale(0.55, 0.27)
		local buy = choose:FindFirstChild("Buy")
		if buy and buy:IsA("GuiButton") then
			local ratio = buy:FindFirstChildOfClass("UIAspectRatioConstraint")
			if ratio then ratio:Destroy() end
			buy.Size = UDim2.fromScale(1, 1)
		end
	end
	ClipSafe.sanitize(card)
end

return PanelStyle
