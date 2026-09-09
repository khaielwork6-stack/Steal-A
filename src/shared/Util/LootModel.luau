--!strict
--[[
	LootModel
	Turns an authored art asset into a usable loot model. ONE resolver, used by
	the world loot (LootService), the base trophies (BaseService) and the base
	steal (HeistService).

	WHY THIS EXISTS
	Both of those built their own copy of "find the asset, else make a
	placeholder", and both required the asset to be a `Model`. Imported art is
	very often NOT a Model - a single MeshPart, a Part, a union, or a legacy Hat -
	so a perfectly good import was silently ignored and the player got a coloured
	block. Everything below accepts whatever the artist actually dropped in.

	THE NAMING CONTRACT (unchanged)
	    ServerStorage.GameAssets.Loot.<ItemId>        e.g. Museum_AncientVase
	Drop art in under the item's id and it is picked up with no code change.

	SCALE IS NORMALISED HERE, EXACTLY ONCE
	Imports arrive at wildly different scales - the crown was 0.5 studs tall and
	the treasure map 14. Every asset is brought to a consistent NORMAL size by
	one per-item multiplier (LootConfig.Normalization, measured by the audit
	below; computed on the fly by the same rule when a row is missing), and the
	instance's own VisualScale (Big 1.6 ... Colossal 16-22) multiplies on top.
	That happens ONCE, on the fresh clone build() makes, and nowhere else: a
	respawn, a steal, a return, a placement, a load and a reparent all either
	build a new clone from the source or move the built one - none of them
	scale a model that is already scaled. `Model:ScaleTo` is ABSOLUTE, which is
	exactly how applying a Big roll to an asset saved at scale 0.22 once made it
	six times too large; every scale here is applied RELATIVE to the clone's
	own current scale.

	WHAT COUNTS AS THE ITEM'S SIZE
	The bounding box of its VISIBLE parts, in world axes. Imports carry
	invisible helpers - hitboxes, root parts, prompt anchors, welded handles
	with Transparency 1 - and measuring those made a small trinket "as big as"
	the box someone drew around it. Particles and attachments are not parts and
	never counted. `Model:GetBoundingBox()` is not used for height either: it
	is aligned to the model's PIVOT, so its `size.Y` is not world height
	whenever the pivot is rotated - which is how an 11-stud import once
	"shrank" to 20 studs. Height is measured from real part corners.
]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local LootModel = {}

-- ==========================================================
-- THE NORMAL SIZE
-- ==========================================================
--
-- One rule, used by the audit that writes LootConfig.Normalization and by the
-- fallback that measures an unlisted asset on the fly, so the two can never
-- disagree about what "Normal" means.
--
-- The target is a HEIGHT (NORMAL_HEIGHT studs) - the sockets and pedestals
-- are seen from standing height, and a height reads at distance. Two limits
-- keep proportions honest:
--   * a flat, wide object is not blown up sideways to reach it: past
--     MAX_WIDTH_RATIO x height across, the width binds instead...
--   * ...but not so hard that a money stack or a crown ends up a coaster:
--     the height never drops below MIN_HEIGHT_RATIO x target, whatever that
--     makes the width - up to HARD_WIDTH_RATIO x target, the absolute cap.
-- Measured against the sockets, the pedestal (8 studs across) and the
-- carry: an upright 5, a flat thing 4 high and up to 18 across.

--- The Normal target height in studs. GameConfig.LOOT_WORLD_HEIGHT mirrors
--- it; build() scales the result by targetHeight / NORMAL_HEIGHT so a caller
--- asking for a different height gets one without a second table.
LootModel.NORMAL_HEIGHT = 5
--- How wide an asset may get, as a ratio of the target height, before width
--- takes over from height as the thing being matched.
LootModel.MAX_WIDTH_RATIO = 1.5
--- The height a flat asset keeps, as a ratio of the target, even when its
--- width is what the rule is matching.
LootModel.MIN_HEIGHT_RATIO = 0.8
--- The widest anything is allowed to be at Normal, as a ratio of the target.
LootModel.HARD_WIDTH_RATIO = 3.6

--- The multiplier that brings an asset of visible size `size` to Normal.
--- Pure; returns 1 for a degenerate box.
function LootModel.normalisationFor(size: Vector3, targetHeight: number?): number
	local target = targetHeight or LootModel.NORMAL_HEIGHT
	local height = size.Y
	local widest = math.max(size.X, size.Z)
	if height <= 0.01 and widest <= 0.01 then
		return 1
	end
	local fit = if height > 0.01 then target / height else math.huge
	if widest > 0.01 then
		local widthFit = (target * LootModel.MAX_WIDTH_RATIO) / widest
		if widthFit < fit then
			-- Wide and flat: match the width, but keep a readable height.
			local floorFit = if height > 0.01 then (target * LootModel.MIN_HEIGHT_RATIO) / height else widthFit
			fit = math.max(widthFit, floorFit)
			-- ...and never past the hard cap on width.
			fit = math.min(fit, (target * LootModel.HARD_WIDTH_RATIO) / widest)
		end
	end
	if fit == math.huge or fit ~= fit or fit <= 0 then
		return 1
	end
	return fit
end

-- ==========================================================
-- MEASUREMENT
-- ==========================================================

local function consumeCorners(part: BasePart, min: Vector3?, max: Vector3?): (Vector3, Vector3)
	local half = part.Size / 2
	-- All eight corners, because a rotated part's world extent is not its
	-- Size on any axis.
	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local p = (part.CFrame * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
				min = if min then Vector3.new(math.min(min.X, p.X), math.min(min.Y, p.Y), math.min(min.Z, p.Z)) else p
				max = if max then Vector3.new(math.max(max.X, p.X), math.max(max.Y, p.Y), math.max(max.Z, p.Z)) else p
			end
		end
	end
	return min :: Vector3, max :: Vector3
end

--- True world-axis-aligned bounding box of EVERY part under `root`, visible
--- or not. Returns nil when there is nothing to measure. This is the box for
--- physics questions (does it fit between the socket and the wall); for the
--- item's SIZE use visibleExtents.
function LootModel.worldExtents(root: Instance): (Vector3?, Vector3?)
	local min: Vector3? = nil
	local max: Vector3? = nil
	if root:IsA("BasePart") then
		min, max = consumeCorners(root, min, max)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			min, max = consumeCorners(descendant, min, max)
		end
	end
	return min, max
end

--- Names imports give to parts that are not the item: collision proxies,
--- root parts, our own prompt anchor.
local HELPER_NAMES = {
	PromptAnchor = true,
	Hitbox = true,
	HitBox = true,
	Root = true,
	RootPart = true,
	HumanoidRootPart = true,
	Collider = true,
	Collision = true,
}

--- Whether a part contributes to the item's perceived size.
function LootModel.isVisiblePart(part: BasePart): boolean
	if part.Transparency >= 0.95 then
		return false
	end
	if HELPER_NAMES[part.Name] then
		return false
	end
	-- A zero-thickness plane or a speck is a helper whatever it is called.
	local size = part.Size
	if size.X < 0.02 or size.Y < 0.02 or size.Z < 0.02 then
		return false
	end
	return true
end

--- World AABB of the parts a player can SEE. Falls back to every part when
--- nothing qualifies (an asset made entirely of near-transparent glass still
--- has a size). Returns nil when there are no parts at all.
function LootModel.visibleExtents(root: Instance): (Vector3?, Vector3?)
	local min: Vector3? = nil
	local max: Vector3? = nil
	local function consider(part: BasePart)
		if LootModel.isVisiblePart(part) then
			min, max = consumeCorners(part, min, max)
		end
	end
	if root:IsA("BasePart") then
		consider(root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			consider(descendant)
		end
	end
	if min and max then
		return min, max
	end
	return LootModel.worldExtents(root)
end

--- World height in studs, or nil when the asset has no parts.
function LootModel.worldHeight(root: Instance): number?
	local min, max = LootModel.worldExtents(root)
	if not min or not max then
		return nil
	end
	return max.Y - min.Y
end

-- ==========================================================
-- RESOLUTION
-- ==========================================================

--- The authored asset for an item id, whatever class it is. Recursive, because
--- imports keep their parts inside nested Models (the meteorite lives at
--- `Zone One Meteor > meteor > OldMeteor`) and a non-recursive lookup finds
--- nothing.
function LootModel.findSource(itemId: string): Instance?
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local folder = assets and assets:FindFirstChild("Loot")
	if not folder then
		return nil
	end
	-- The override, when there is one, is the asset name to look for; the
	-- ItemId is still the save key and still the fallback.
	local wanted = LootConfig.modelNameFor(itemId)
	local found = folder:FindFirstChild(wanted, true)
	if found then
		return found
	end
	return if wanted ~= itemId then folder:FindFirstChild(itemId, true) else nil
end

function LootModel.hasArt(itemId: string): boolean
	return LootModel.findSource(itemId) ~= nil
end

--- Wraps whatever the artist provided into a Model we own.
--- Returns nil when the source contains no parts at all.
local function adopt(source: Instance): Model?
	-- ORDER MATTERS, AND IT IS NOT OBVIOUS. `Tool` INHERITS FROM `Model` in
	-- Roblox's class hierarchy (Tool -> BackpackItem -> Model), so a Tool
	-- answers true to IsA("Model"). With the Model branch first, all eight
	-- Tool-shaped imports - the VIP Passport, the Shawarma, the Golden Key,
	-- the Cash Bag and the rest - were cloned WITH THEIR TOOL WRAPPER and
	-- spawned into the world still a Tool. A Tool with a Handle lying in the
	-- workspace is equipment: walking over one put the loot in the player's
	-- backpack and on their back. The unwrapping branch below has to be
	-- reached first.
	if source:IsA("Accoutrement") or source:IsA("Tool") then
		local model = Instance.new("Model")
		-- EVERY part comes across, not just the Handle. The zone 6-12 imports
		-- include Tools built from several parts welded to a Handle (the Gym's
		-- barbell, the Bank's briefcases, the Lab's containment tank); keeping
		-- only the Handle left a bar with no plates. The parts are flattened
		-- into our Model and anchored by build(), so the welds that held them
		-- together are not needed and are stripped with the rest.
		local shell = source:Clone()
		for _, descendant in shell:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Parent = model
			end
		end
		shell:Destroy()
		-- A Handle carries attachments, welds and (on a Tool) scripts and grip
		-- data meant for a character. On a pedestal they do nothing but can
		-- re-parent the part or run code we never asked for.
		for _, child in model:GetDescendants() do
			if
				child:IsA("Attachment")
				or child:IsA("JointInstance")
				or child:IsA("WeldConstraint")
				or child:IsA("BaseScript")
			then
				child:Destroy()
			end
		end
		local handle = model:FindFirstChild("Handle") or model:FindFirstChildWhichIsA("BasePart")
		if handle and handle:IsA("BasePart") then
			model.PrimaryPart = handle
			return model
		end
		model:Destroy()
		return nil
	end

	if source:IsA("Model") then
		local model = source:Clone()
		if not model.PrimaryPart then
			model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
		end
		return if model.PrimaryPart then model else nil
	end

	-- A bare Part / MeshPart / union.
	if source:IsA("BasePart") then
		local model = Instance.new("Model")
		local part = source:Clone()
		part.Parent = model
		model.PrimaryPart = part
		return model
	end

	return nil
end

--- Strips any Tool or Accessory WRAPPER nested inside a model, keeping its
--- parts. `adopt` handles the outer one; this is for art that has equipment
--- inside it (the Jewelled Shield ships a "DragonSword&Shield" Tool), which
--- lying in a zone is just as pick-up-able as an outer Tool would be.
local function unwrapEquipment(model: Instance)
	local wrappers: { Instance } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Tool") or descendant:IsA("Accoutrement") then
			table.insert(wrappers, descendant)
		end
	end
	for _, wrapper in wrappers do
		if wrapper.Parent then
			for _, child in wrapper:GetChildren() do
				if child:IsA("BasePart") then
					child.Parent = model
				end
			end
			wrapper:Destroy()
		end
	end
end

--- The visible size of an item's authored asset, as the pipeline sees it
--- (adopted and unwrapped, at the asset's own scale). Server only. Nil when
--- the item has no art.
function LootModel.measureSource(itemId: string): Vector3?
	local source = LootModel.findSource(itemId)
	local model = if source then adopt(source) else nil
	if not model then
		return nil
	end
	unwrapEquipment(model)
	local min, max = LootModel.visibleExtents(model)
	model:Destroy()
	if not min or not max then
		return nil
	end
	return max - min
end

-- ==========================================================
-- BUILD
-- ==========================================================

--- The widest a piece of world loot may get, in studs. The lane is 160 wide
--- and the sockets sit 45 studs off centre, so this is the largest thing that
--- still fits between a socket and the wall. HEIGHT IS NOT CAPPED: a Colossal
--- is meant to tower over the walls, and this only ever binds on something
--- both huge and flat.
LootModel.WORLD_MAX_FOOTPRINT = 66
--- RETIRED as a build cap. A trophy is built with the SAME options as the
--- world model (BaseService.buildTrophy), so a Colossal that towered over the
--- lane towers over the plot too - hanging out past the pad is the joke, not a
--- bug. Kept only so nothing that still reads the name errors.
LootModel.TROPHY_MAX_FOOTPRINT = LootModel.WORLD_MAX_FOOTPRINT

export type BuildOptions = {
	itemId: string,
	rarity: string,
	targetHeight: number,
	--- The item's saved VisualScale (Big 1.6 ... Colossal 16-22), applied on
	--- top of the Normal normalisation. Exactly once, on this fresh clone.
	sizeScale: number?,
	--- Largest footprint (the wider of X and Z) this context can show. Only
	--- ever shrinks; never a universal cap.
	maxFootprint: number?,
	placeholderSize: Vector3?,
}

--- The Normal multiplier for a built clone: the audited row when there is
--- one, otherwise the same rule run on the clone's visible box right now. An
--- unlisted item is named once by checkNormalization at start, so build()
--- itself stays quiet.
local function normalMultiplier(itemId: string, built: Model): number
	local listed = LootConfig.normalizationFor(itemId)
	if listed then
		return listed
	end
	local min, max = LootModel.visibleExtents(built)
	if not min or not max then
		return 1
	end
	return LootModel.normalisationFor(max - min, LootModel.NORMAL_HEIGHT)
end

--- How far a part's own up may lean from world up and still count as an
--- upright frame. Generous: what matters is that the frame is not lying on
--- its side or inverted, not that it is perfectly plumb.
local UPRIGHT_DOT = 0.9

--- WHICH PART DEFINES THE MODEL'S PIVOT, and it is not a cosmetic choice.
---
--- `Model:GetPivot()` returns `PrimaryPart.CFrame * PrimaryPart.PivotOffset`
--- (`build` zeroes that offset rotation, see there), and every later
--- `PivotTo(target)` re-seats the whole assembly by `target * pivot:Inverse()`.
--- So if the chosen part's own frame is upside down, the assembly is rotated
--- upside down the moment anything places it upright - which is exactly what
--- happened to the Vanilla Milkshake: `FindFirstChildWhichIsA` picked the one
--- union in the model whose UpVector was (0, -1, 0), and the glass came out
--- above the cream on every pedestal in the game.
---
--- Note that no amount of pivot arithmetic fixes that afterwards. Rotating
--- the model with `PivotTo(GetPivot() * R)` moves the parts AND the pivot
--- together, so the parts' offsets RELATIVE to the pivot never change and the
--- caller's next `PivotTo` discards the whole correction. The frame has to be
--- right at the source, which means choosing a part whose frame is right.
---
--- Preference order: an upright frame first, then the largest such part,
--- because the primary is also what the carry welds a player to and what the
--- other parts hang off.
function LootModel.chooseAnchor(model: Model): BasePart?
	local best: BasePart? = nil
	local bestScore = -math.huge
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local size = descendant.Size
			local volume = size.X * size.Y * size.Z
			local upright = descendant.CFrame.UpVector:Dot(Vector3.yAxis) >= UPRIGHT_DOT
			-- Uprightness dominates: the largest sideways part still loses to
			-- the smallest upright one.
			local score = (if upright then 1e12 else 0) + volume
			if score > bestScore then
				best = descendant
				bestScore = score
			end
		end
	end
	return best
end

--- Rotates the model's GEOMETRY about its own centre, for the few assets
--- whose authored parts really are lying down or inverted as a set (as
--- opposed to the far commoner case above, where the parts are fine and only
--- the chosen frame was wrong).
---
--- This moves the parts in world space BEFORE the anchor is chosen, so the
--- correction is baked into the arrangement rather than into a pivot that the
--- next `PivotTo` would throw away.
local function applyOrientation(model: Model, itemId: string)
	local orientation = LootConfig.orientationFor(itemId)
	if not orientation then
		return
	end
	local min, max = LootModel.worldExtents(model)
	if not min or not max then
		return
	end
	local centre = CFrame.new((min + max) / 2)
	local rotate = centre * orientation * centre:Inverse()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CFrame = rotate * descendant.CFrame
		end
	end
end

--- The one way to get a loot model. Always returns a Model with a PrimaryPart,
--- anchored, non-colliding, and scaled to Normal times any size roll.
function LootModel.build(options: BuildOptions): (Model, boolean)
	local source = LootModel.findSource(options.itemId)
	local model: Model? = if source then adopt(source) else nil
	local isReal = model ~= nil

	if not model then
		local made = Instance.new("Model")
		local part = Instance.new("Part")
		part.Name = "Placeholder"
		part.Size = options.placeholderSize or Vector3.new(6, 7, 6)
		part.Color = RarityConfig.Colors[options.rarity] or Color3.fromRGB(200, 200, 200)
		part.Material = Enum.Material.SmoothPlastic
		part.Parent = made
		made.PrimaryPart = part
		model = made
	end

	local built = model :: Model
	built.Name = options.itemId

	unwrapEquipment(built)
	-- The client animates loot by moving the whole model. With streaming on,
	-- a model that streams in part by part would be pivoted while half here
	-- and torn apart when the rest arrived; atomic models arrive whole.
	built.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	-- SANITISE. Toolbox art arrives with its own physics authority attached and
	-- every bit of it fights the carry:
	--
	--   * Legacy `Weld`/`Motor6D` joints hold C0/C1 offsets that ScaleTo does
	--     NOT scale. The Banker's Briefcase ships two of them; once the model
	--     was scaled 2.17x and unanchored onto a player, those welds pulled its
	--     parts back toward unscaled offsets while our own WeldConstraints held
	--     them at the scaled ones - two rigid constraints demanding different
	--     answers, in an assembly the player's character is welded into.
	--   * Body movers and constraints (AlignPosition, VectorForce, ropes) drive
	--     the assembly directly, and the character comes with it.
	--   * A prompt or ClickDetector inside the art is a second, competing
	--     interaction on top of the one LootService adds.
	--
	-- All of it goes. build() re-welds the pieces itself, further down.
	for _, descendant in built:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			-- VISUAL GEOMETRY NEVER COLLIDES. A Colossal that covers half a
			-- base must not trap, push or block anyone: the steal prompt, the
			-- guardian's targeting and the pedestal seating all work from
			-- measured extents, not from collision, so nothing needs it.
			descendant.CanCollide = false
			descendant.CastShadow = false
			-- An import's throne is a working Seat; brushing past the pedestal
			-- would sit the player on the loot. Disabled stops the sit; CanTouch
			-- stops the Touched-based seat weld from firing at all.
			if descendant:IsA("Seat") or descendant:IsA("VehicleSeat") then
				descendant.Disabled = true
				descendant.CanTouch = false
			end
		elseif
			descendant:IsA("Humanoid")
			or descendant:IsA("BaseScript")
			or descendant:IsA("JointInstance")
			or descendant:IsA("WeldConstraint")
			or descendant:IsA("Constraint")
			or descendant:IsA("BodyMover")
			or descendant:IsA("ProximityPrompt")
			or descendant:IsA("ClickDetector")
		then
			descendant:Destroy()
		end
	end

	-- THE ORIENTATION CORRECTION and THE ANCHOR, in that order and before any
	-- scaling or pivoting: the correction moves parts in world space, and the
	-- anchor is picked from where they finally sit.
	if isReal then
		applyOrientation(built, options.itemId)
		local anchor = LootModel.chooseAnchor(built)
		if anchor then
			-- GetPivot() is PrimaryPart.CFrame * PrimaryPart.PivotOffset, not the
			-- bare CFrame. Five imported assets (Pharaohs Mask, Toy Train, Mutant
			-- Specimen, Grandmas Cookie, Pilots Badge) carry a PivotOffset rotated
			-- 90 degrees about X on EVERY part. That is an importer artifact, not
			-- authoring - the part frames themselves are upright, and the models
			-- look correct in ServerStorage. Left alone it tips the whole assembly
			-- onto its face on the first PivotTo: the Vanilla Milkshake bug in a
			-- different hat, and one chooseAnchor cannot dodge, because there is
			-- no unaffected part left for it to prefer. Keep the offset position,
			-- drop its rotation, so the pivot really is the anchor frame we vetted.
			anchor.PivotOffset = CFrame.new(anchor.PivotOffset.Position)
			built.PrimaryPart = anchor
		end
	end

	-- THE SCALE, ASSEMBLED ONCE:
	--   Normal multiplier (audited per item)  x  the caller's height target
	--   relative to the audited one  x  the instance's own VisualScale.
	-- Only authored art needs normalising; a placeholder is already the size
	-- we asked for.
	local scale = options.sizeScale or 1
	if isReal then
		scale *= normalMultiplier(options.itemId, built)
		scale *= options.targetHeight / LootModel.NORMAL_HEIGHT
	end

	-- The context's footprint limit. Applied to the FINAL scale, size roll
	-- included, and only ever downward: a Colossal barrel is still a tower, a
	-- Colossal carpet is as wide as the lane allows.
	local min, max = LootModel.visibleExtents(built)
	if options.maxFootprint and min and max then
		local widest = math.max(max.X - min.X, max.Z - min.Z) * scale
		if widest > options.maxFootprint and widest > 0.01 then
			scale *= options.maxFootprint / widest
		end
	end

	if math.abs(scale - 1) > 0.001 then
		-- RELATIVE. ScaleTo is absolute, and cloned assets often carry a scale
		-- of their own already.
		built:ScaleTo(built:GetScale() * scale)
	end

	-- (The orientation correction used to live here, applied to the pivot. It
	-- was a no-op: PivotTo moves the parts and the pivot together, so the
	-- offsets never changed and the caller's next PivotTo discarded it. It is
	-- applied to the geometry above instead.)
	-- What this build applied, so a later in-place adjustment (growth) can be
	-- expressed relative to it instead of compounding on an unknown base.
	built:SetAttribute("BuiltScale", built:GetScale())

	-- Hold the pieces together. A multi-part import (a throne, a barbell, the
	-- four-part plasma) is only ever anchored on a pedestal, but a CARRY
	-- unanchors it and welds the PrimaryPart alone to the player - so anything
	-- not welded to that part was left behind or fell through the floor.
	local primary = built.PrimaryPart
	if primary then
		for _, descendant in built:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= primary then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "LootWeld"
				weld.Part0 = primary
				weld.Part1 = descendant
				weld.Parent = primary
			end
		end
	end

	return built, isReal
end

-- ==========================================================
-- THE AUDIT
-- ==========================================================
--
-- Server only. Measures every registered item's authored asset and reports
-- what the pipeline makes of it. `Invoke("lootAudit")` prints the table; the
-- start-up check below turns any drift into a warning.

export type AuditRow = {
	itemId: string,
	name: string,
	zone: number,
	position: number,
	hasArt: boolean,
	--- Visible bounding box of the authored asset, studs.
	source: Vector3?,
	--- The multiplier the rule gives that box today.
	computed: number?,
	--- The multiplier LootConfig.Normalization lists, if any.
	listed: number?,
	--- The box the listed row was measured from, if any.
	listedSource: Vector3?,
	--- Final Normal size: source x the multiplier build() will actually use.
	normal: Vector3?,
	--- "ok", "missing" (art but no row), "stale" (row measured from a
	--- different box), "no art", or "orphan" (row but no art).
	status: string,
}

--- How far the recorded source box may differ from the measured one before
--- the row counts as stale (the art changed under it).
LootModel.AUDIT_DRIFT_TOLERANCE = 0.02

--- THE UPRIGHT AUDIT. Server only.
---
--- Builds every item the way the game does, seats it on an upright frame the
--- way a socket or a pedestal does, and reports whether the part that ends up
--- defining the pivot has an upright frame of its own. An item whose anchor
--- is NOT upright is the shape of the Vanilla Milkshake bug: it will be laid
--- on its side or stood on its head everywhere at once, and it needs either a
--- better anchor or a LootConfig.ModelOrientation row.
---
--- Reports rather than fixes, because "which way up is a Cursed Coin" is a
--- judgement call and this only proves the frame is sane.
export type UprightRow = {
	itemId: string,
	anchor: string,
	anchorUp: number,
	sidewaysParts: number,
	totalParts: number,
	ok: boolean,
}

function LootModel.uprightAudit(): { UprightRow }
	local rows: { UprightRow } = {}
	for _, list in LootConfig.Items do
		for _, def in list do
			if not LootModel.hasArt(def.id) then
				continue
			end
			local built = LootModel.build({
				itemId = def.id,
				rarity = def.rarity,
				targetHeight = LootModel.NORMAL_HEIGHT,
				sizeScale = 1,
			})
			built:PivotTo(CFrame.new(0, 0, 0))
			local anchor = built.PrimaryPart
			local sideways, total = 0, 0
			for _, descendant in built:GetDescendants() do
				if descendant:IsA("BasePart") then
					total += 1
					if descendant.CFrame.UpVector:Dot(Vector3.yAxis) < 0.9 then
						sideways += 1
					end
				end
			end
			local up = if anchor then anchor.CFrame.UpVector:Dot(Vector3.yAxis) else 0
			table.insert(rows, {
				itemId = def.id,
				anchor = if anchor then anchor.Name else "none",
				anchorUp = up,
				sidewaysParts = sideways,
				totalParts = total,
				ok = up >= 0.9,
			})
			built:Destroy()
		end
	end
	return rows
end

--- Every item, in zone and position order.
function LootModel.audit(): { AuditRow }
	local rows: { AuditRow } = {}
	for zoneIndex, items in LootConfig.Items do
		for _, def in items do
			local source = LootModel.measureSource(def.id)
			local row = LootConfig.Normalization[def.id]
			local listed = LootConfig.normalizationFor(def.id)
			local listedSource = if row and #row >= 4 then Vector3.new(row[2], row[3], row[4]) else nil
			local computed = if source then LootModel.normalisationFor(source, LootModel.NORMAL_HEIGHT) else nil
			local used = listed or computed
			local status: string
			if not source then
				status = if listed then "orphan" else "no art"
			elseif not listed then
				status = "missing"
			else
				local drift = 0
				if listedSource then
					local measured = source :: Vector3
					drift = math.max(
						math.abs(measured.X - listedSource.X) / math.max(measured.X, 0.01),
						math.abs(measured.Y - listedSource.Y) / math.max(measured.Y, 0.01),
						math.abs(measured.Z - listedSource.Z) / math.max(measured.Z, 0.01)
					)
				end
				status = if drift > LootModel.AUDIT_DRIFT_TOLERANCE then "stale" else "ok"
			end
			table.insert(rows, {
				itemId = def.id,
				name = def.name,
				zone = zoneIndex,
				position = def.position,
				hasArt = source ~= nil,
				source = source,
				computed = computed,
				listed = listed,
				listedSource = listedSource,
				normal = if source and used then (source :: Vector3) * used else nil,
				status = status,
			})
		end
	end
	return rows
end

--- The LootConfig.Normalization table the measured assets imply, as Luau
--- source ready to paste. Items without art are left out.
function LootModel.auditTableSource(rows: { AuditRow }?): string
	local lines = { "LootConfig.Normalization = {" }
	for _, row in rows or LootModel.audit() do
		if row.source and row.computed then
			local s = row.source
			table.insert(lines, string.format(
				"\t%s = { %.4f, %.3f, %.3f, %.3f }, -- %s: %.2f x %.2f x %.2f -> %.2f x %.2f x %.2f",
				row.itemId, row.computed, s.X, s.Y, s.Z, row.name,
				s.X, s.Y, s.Z, s.X * row.computed, s.Y * row.computed, s.Z * row.computed
			))
		end
	end
	table.insert(lines, "} :: { [string]: { number } }")
	return table.concat(lines, "\n")
end

--- The start-up check: ONE warning per problem class, naming the items, so a
--- new import without a row, a re-import under a stale row, or a row for
--- art that no longer exists is impossible to miss in the output. Returns the
--- counts for the caller's own log line.
function LootModel.checkNormalization(): { [string]: number }
	local counts: { [string]: number } = { ok = 0, missing = 0, stale = 0, orphan = 0, noArt = 0 }
	local byStatus: { [string]: { string } } = {}
	for _, row in LootModel.audit() do
		local key = if row.status == "no art" then "noArt" else row.status
		counts[key] = (counts[key] or 0) + 1
		byStatus[row.status] = byStatus[row.status] or {}
		table.insert(byStatus[row.status], row.itemId)
	end
	if byStatus.missing then
		warn(`[LootModel] {#byStatus.missing} loot asset(s) have NO Normalization row and are being sized on the fly - run Invoke("lootAudit") and paste the table into LootConfig: {table.concat(byStatus.missing, ", ")}`)
	end
	if byStatus.stale then
		warn(`[LootModel] {#byStatus.stale} Normalization row(s) were measured from different art than is now in GameAssets.Loot - re-run Invoke("lootAudit"): {table.concat(byStatus.stale, ", ")}`)
	end
	if byStatus.orphan then
		warn(`[LootModel] {#byStatus.orphan} Normalization row(s) name items with no art: {table.concat(byStatus.orphan, ", ")}`)
	end
	return counts
end

-- ==========================================================
-- PREVIEWS (the Index and Storage thumbnails)
-- ==========================================================
--
-- The art lives in ServerStorage, which no client can read, so the server
-- publishes a sanitised copy of every item under ReplicatedStorage.LootPreviews
-- once at start. A client card then clones its item into a ViewportFrame and
-- draws the REAL model - the same mesh the player steals - instead of a colour
-- swatch. Scripts, sounds, prompts and humanoids are stripped; nothing in the
-- folder can run or make noise.

local PREVIEW_FOLDER = "LootPreviews"

--- Server only. Idempotent: a second call replaces the folder.
function LootModel.publishPreviews(): number
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local source = assets and assets:FindFirstChild("Loot")
	if not source then
		return 0
	end
	local existing = ReplicatedStorage:FindFirstChild(PREVIEW_FOLDER)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = PREVIEW_FOLDER

	-- A preview is published under the ITEM ID it serves, not under the asset's
	-- own name, because previewSource() looks up by id. An item that adopts a
	-- differently-named asset through LootConfig.ModelOverrides would otherwise
	-- publish as (say) "Toy Train", be looked up as "NorthPole_NiceList", miss,
	-- and lose its thumbnail everywhere ItemThumb paints one - storage cards,
	-- Index cards and reveals. An asset no item claims keeps its own name.
	local idForAsset: { [string]: string } = {}
	for itemId in LootConfig.ById do
		idForAsset[LootConfig.modelNameFor(itemId)] = itemId
	end

	-- Two assets can want the SAME published name. An item that adopts new art
	-- through ModelOverrides leaves its original asset in the folder still named
	-- after the item id, and the adopted asset then renames onto that same id.
	-- Both land in the folder and FindFirstChild returns whichever came first,
	-- which is how superseded art went on painting the thumbnails while the
	-- world showed the new model. The claim wins: an asset an item actually
	-- names beats one that merely happens to share the id. The loser is not
	-- published and not touched - it stays in ServerStorage until someone
	-- deletes it deliberately.
	local function superseded(assetName: string): boolean
		return idForAsset[assetName] == nil
			and LootConfig.ById[assetName] ~= nil
			and LootConfig.modelNameFor(assetName) ~= assetName
	end

	local count = 0
	for _, item in source:GetChildren() do
		if superseded(item.Name) then
			continue
		end
		local model = adopt(item)
		if not model then
			continue
		end
		model.Name = idForAsset[item.Name] or item.Name
		unwrapEquipment(model)
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
			elseif
				descendant:IsA("BaseScript")
				or descendant:IsA("Sound")
				or descendant:IsA("ProximityPrompt")
				or descendant:IsA("Humanoid")
				or descendant:IsA("BillboardGui")
				or descendant:IsA("SurfaceGui")
			then
				descendant:Destroy()
			end
		end
		model.Parent = folder
		count += 1
	end
	folder.Parent = ReplicatedStorage
	return count
end

--- The published preview for an item, or nil (no art, or not published yet).
function LootModel.previewSource(itemId: string): Model?
	local folder = ReplicatedStorage:FindFirstChild(PREVIEW_FOLDER)
	local found = folder and folder:FindFirstChild(itemId)
	return if found and found:IsA("Model") then found else nil
end

return LootModel
