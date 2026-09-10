--!strict
--[[
	AttractionSign
	The ONE floating "look at this" marker used by every purchasable feature on
	the safe-zone apron: the Trail Shop, the rotating Guardian pedestal, the
	Gift Chest, the Slap cage.

	WHY THIS EXISTS
	Every one of those already had a sign, and each had been drawn by hand in
	its own service: different fonts sizes, different strokes, different
	heights above the floor, and no two agreeing on how a heading should look.
	From the spawn circle they read as four unrelated bits of scenery rather
	than as four things to walk over to. Built from here they are literally the
	same component with different words, so a fifth attraction added later
	cannot look foreign, and the whole hub can be restyled by editing one file.

	THE HIERARCHY, LARGEST TO SMALLEST
	  title     what the thing IS. The only line readable across the apron, so
	            it is the biggest by a wide margin and carries the heaviest
	            outline.
	  subtitle  the hook - a price, a countdown, "FREE!". Half the title's
	            size and a colour that belongs to that attraction.
	  arrow     a down chevron that says "here, underneath". Deliberately the
	            smallest element: it is a pointer, not a heading.

	WHY THE ARROW IS NOT ANIMATED HERE
	This runs on the server, and tweening a GUI property server-side replicates
	every step of it to every client. The bob is done once per frame on each
	client instead (AttractionSignController), which finds these by the
	`AttractionSign` attribute. A sign built by this file and never animated
	still reads correctly - it just sits still.

	SIZE DISCIPLINE
	Billboards are sized in STUDS, so a sign is the same physical size to
	everyone and does not swell as a phone's field of view narrows. MaxDistance
	keeps them off the screen entirely from across the map, and the pixel caps
	stop a sign standing two studs away from filling the display. The brief
	asked for obvious, not enormous.
]]

local AttractionSign = {}

--- Marks the arrow label the client controller bobs.
AttractionSign.ARROW_TAG = "AttractionArrow"
--- Marks the whole billboard, so the controller can find signs without
--- knowing which service built them.
AttractionSign.TAG = "AttractionSign"

--- Studs the arrow travels, and how many seconds a full up-and-down takes.
--- Read by the controller so the motion is described in one place.
AttractionSign.BOB_STUDS = 0.55
AttractionSign.BOB_PERIOD = 1.6

local TITLE_COLOR = Color3.fromRGB(255, 255, 255)
local OUTLINE = Color3.fromRGB(12, 14, 28)
local ARROW_COLOR = Color3.fromRGB(255, 255, 255)

export type Options = {
	--- What the attraction is. Kept short: this is a heading, not a sentence.
	title: string,
	--- The hook under it. Optional; without one the title simply sits lower.
	subtitle: string?,
	--- The accent for the subtitle and the arrow. Defaults to white.
	accent: Color3?,
	--- Studs above the adornee's origin that the sign floats at.
	height: number,
	--- Overall billboard width in studs. The default suits a two-word title.
	width: number?,
	--- How far away the sign is still drawn.
	maxDistance: number?,
}

--- Builds the sign onto `adornee` and returns it. Any sign this function
--- previously built on the same part is replaced, so a service may call it
--- again on a rotation or a restyle without stacking billboards.
function AttractionSign.build(adornee: BasePart, options: Options): BillboardGui
	local existing = adornee:FindFirstChild("AttractionSign")
	if existing then
		existing:Destroy()
	end

	local hasSubtitle = options.subtitle ~= nil and options.subtitle ~= ""
	local width = options.width or 16
	-- Taller when there is a subtitle to fit, so the title never has to shrink
	-- to make room for it.
	local height = if hasSubtitle then 6.4 else 5

	local gui = Instance.new("BillboardGui")
	gui.Name = "AttractionSign"
	gui.Size = UDim2.fromScale(width, height)
	gui.StudsOffsetWorldSpace = Vector3.new(0, options.height, 0)
	-- NOT AlwaysOnTop. These stand in the open on the apron where nothing
	-- occludes them, and a hub sign punching through the lobby wall from
	-- inside a zone is exactly the through-geometry problem this pass is
	-- removing elsewhere.
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = options.maxDistance or 260
	gui.Adornee = adornee
	gui:SetAttribute(AttractionSign.TAG, true)
	gui.Parent = adornee

	local accent = options.accent or Color3.fromRGB(255, 255, 255)

	-- THE TITLE. Bottom-anchored inside its band so a one-line and a two-line
	-- title both sit at the same distance above the subtitle.
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, if hasSubtitle then 0.46 else 0.62)
	title.Position = UDim2.fromScale(0, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = TITLE_COLOR
	title.TextStrokeColor3 = OUTLINE
	-- Fully opaque outline: these are read against a bright green floor, a
	-- sand wall and the skybox depending on where the player stands, and a
	-- soft stroke disappears against at least one of them.
	title.TextStrokeTransparency = 0
	title.Text = string.upper(options.title)
	title.Parent = gui
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = 64
	titleCap.Parent = title

	if hasSubtitle then
		local subtitle = Instance.new("TextLabel")
		subtitle.Name = "Subtitle"
		subtitle.Size = UDim2.fromScale(1, 0.26)
		subtitle.Position = UDim2.fromScale(0, 0.46)
		subtitle.BackgroundTransparency = 1
		subtitle.Font = Enum.Font.FredokaOne
		subtitle.TextScaled = true
		subtitle.TextColor3 = accent
		subtitle.TextStrokeColor3 = OUTLINE
		subtitle.TextStrokeTransparency = 0
		subtitle.Text = options.subtitle :: string
		subtitle.Parent = gui
		local subCap = Instance.new("UITextSizeConstraint")
		subCap.MaxTextSize = 34
		subCap.Parent = subtitle
	end

	-- THE ARROW. Its own label rather than a line of the title, because the
	-- client moves it independently of everything above it.
	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.AnchorPoint = Vector2.new(0.5, 0)
	arrow.Size = UDim2.fromScale(0.34, if hasSubtitle then 0.28 else 0.38)
	arrow.Position = UDim2.fromScale(0.5, if hasSubtitle then 0.72 else 0.62)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.FredokaOne
	arrow.TextScaled = true
	arrow.TextColor3 = ARROW_COLOR
	arrow.TextStrokeColor3 = OUTLINE
	arrow.TextStrokeTransparency = 0
	arrow.Text = "▼"
	arrow:SetAttribute(AttractionSign.ARROW_TAG, true)
	-- The rest position the client bobs around, stored so the controller does
	-- not have to assume the layout above.
	arrow:SetAttribute("RestY", arrow.Position.Y.Scale)
	arrow.Parent = gui
	local arrowCap = Instance.new("UITextSizeConstraint")
	arrowCap.MaxTextSize = 46
	arrowCap.Parent = arrow

	return gui
end

--- Retexts a sign already built on `adornee` without rebuilding it, for the
--- lines that change while the player is looking at them (a live price, a
--- countdown). Silently does nothing when there is no sign yet.
function AttractionSign.retext(adornee: BasePart, title: string?, subtitle: string?)
	local gui = adornee:FindFirstChild("AttractionSign")
	if not gui then
		return
	end
	if title then
		local label = gui:FindFirstChild("Title")
		if label and label:IsA("TextLabel") then
			label.Text = string.upper(title)
		end
	end
	if subtitle then
		local label = gui:FindFirstChild("Subtitle")
		if label and label:IsA("TextLabel") then
			label.Text = subtitle
		end
	end
end

return AttractionSign
