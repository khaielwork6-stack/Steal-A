--!strict
--[[
	AttractionSignController
	The up-and-down on every attraction sign's arrow.

	WHY THE MOTION IS HERE AND NOT ON THE SERVER
	AttractionSign builds the signs server-side so every player sees the same
	hub. Tweening a GUI property there would replicate every step of the bob to
	every client forever - a permanent trickle of network traffic for a purely
	cosmetic wobble. One local loop over a handful of signs costs nothing and
	replicates nothing, exactly as WorldLootFxController does for the crates.

	WHY THE ANGLE COMES FROM THE CLOCK
	The offset is a function of os.clock() plus a per-sign phase, never a
	counter that advances only while the sign is on screen. A sign approached
	from across the apron is already at the point in its bob it would have
	reached had it been watched the whole time, so there is no frozen arrow
	and no jump as it comes into range.

	The phase is derived from the sign's world position, so neighbouring
	attractions are visibly out of step with each other rather than pulsing in
	unison like one animated billboard.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AttractionSign = require(ReplicatedStorage:WaitForChild("Shared").Util.AttractionSign)

local AttractionSignController = {}

type Entry = {
	arrow: TextLabel,
	restY: number,
	phase: number,
}

local entries: { [TextLabel]: Entry } = {}
local reducedEffects = false

function AttractionSignController.setReducedEffects(value: boolean)
	reducedEffects = value
end

-- ==========================================================
-- REGISTRY
-- ==========================================================

local function register(arrow: TextLabel)
	if entries[arrow] then
		return
	end
	local restY = tonumber(arrow:GetAttribute("RestY")) or arrow.Position.Y.Scale

	-- Out of step with its neighbours: the sign's own position, wrapped, is a
	-- stable per-sign number that needs no counter and no shared registry.
	local phase = 0
	local gui = arrow.Parent
	if gui and gui:IsA("BillboardGui") and gui.Adornee then
		local at = (gui.Adornee :: BasePart).Position
		phase = (at.X * 0.13 + at.Z * 0.29) % (math.pi * 2)
	end

	entries[arrow] = { arrow = arrow, restY = restY, phase = phase }
	arrow.AncestryChanged:Connect(function()
		if not arrow:IsDescendantOf(game) then
			entries[arrow] = nil
		end
	end)
end

local function scan(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") and descendant:GetAttribute(AttractionSign.ARROW_TAG) then
			register(descendant)
		end
	end
end

-- ==========================================================
-- FRAME
-- ==========================================================

local function step()
	if reducedEffects then
		return
	end
	local now = os.clock()
	local rate = (math.pi * 2) / AttractionSign.BOB_PERIOD

	for arrow, entry in entries do
		if not arrow.Parent then
			entries[arrow] = nil
			continue
		end
		-- Scale units, because the label is positioned in scale: converting the
		-- stud amplitude through the billboard's own height keeps the travel
		-- the same physical distance whatever size the sign is.
		local gui = arrow.Parent :: BillboardGui
		local heightStuds = gui.Size.Y.Scale
		if heightStuds <= 0 then
			continue
		end
		local amplitude = AttractionSign.BOB_STUDS / heightStuds
		local offset = math.sin(now * rate + entry.phase) * amplitude
		arrow.Position = UDim2.fromScale(arrow.Position.X.Scale, entry.restY + offset)
	end
end

-- ==========================================================
-- START
-- ==========================================================

function AttractionSignController.start()
	local map = workspace:WaitForChild("Map", 60)
	if not map then
		return
	end

	scan(map)
	-- Signs arrive late and are rebuilt in place: the Guardian pedestal
	-- replaces its sign on every rotation, and the whole hub is built after
	-- the client has already started.
	map.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("TextLabel") and descendant:GetAttribute(AttractionSign.ARROW_TAG) then
			register(descendant)
		end
	end)

	RunService.Heartbeat:Connect(step)
end

return AttractionSignController
