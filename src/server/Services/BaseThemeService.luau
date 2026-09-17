--!strict
--[[
	BaseThemeService
	Plot themes and pedestal skins (BaseThemeConfig): buying, equipping and
	painting them onto the owner's plot.

	PAINT, DON'T REBUILD. A theme recolours / re-materials the parts
	MapBuilder.buildBase names on the plot (PlotFloor.Slab, Paving.*,
	Fence.Post / GatePost / Rail / GateCap), retints the neon frame of every
	EMPTY display pad, and hangs a few decor props on the fence posts. A
	pedestal skin recolours each `Pedestal` model BaseService cloned onto an
	occupied pad and adds a trim ring. No trophy is rebuilt for either.

	SURVIVING REBUILDS. BaseService destroys and re-creates pedestals and
	restyles pads on every rebuildDisplays / rebuildSlot, and then fires its
	onRebuilt listeners - this service is one, and re-applies there. The plot
	parts themselves are never touched by a rebuild, so a theme already on a
	plot is not repainted (no needless replication on every placement).

	RELEASE. When a plot's OwnerUserId changes (BaseService.setOwner), every
	part this service changed is put back exactly as it was and the decor is
	removed, so the next owner starts from the map's own look.

	VISITORS see the theme because the server paints it; nothing is local.

	OWNERSHIP. Free rows: everyone. Cash rows: profile.BaseTheme.owned.
	Robux rows: their Game Pass (MonetizationConfig.ThemePasses), re-read by
	MonetizationService; a pass that is no longer owned falls back to the
	default look at the next apply. Placeholder ids (0) are hidden outside
	Studio and can be faked in Studio with `setPassOwnedForTesting`.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local BaseThemeConfig = require(ReplicatedStorage.Shared.Config.BaseThemeConfig)
local LootModel = require(ReplicatedStorage.Shared.Util.LootModel)
local MapPalette = require(ReplicatedStorage.Shared.MapPalette)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local MonetizationService = require(script.Parent.MonetizationService)
local StateService = require(script.Parent.StateService)

local BaseThemeService = {}

local limiter = RateLimiter.new(BaseThemeConfig.REQUESTS_PER_SECOND)

local DECOR_FOLDER = "ThemeDecor"
local TRIM_NAME = "SkinTrim"
local STASH_NAME = "SkinStash"

-- ==========================================================
-- OWNERSHIP
-- ==========================================================

--- Studio-only: pass key -> owned, per player (placeholder ids are 0).
local passOverride: { [Player]: { [string]: boolean? } } = {}
--- Studio-only: a theme / pedestal shown regardless of ownership (debug cycle).
local previewOverride: { [Player]: { theme: string?, pedestal: string? } } = {}

local function passOwned(player: Player, passKey: string): boolean
	local override = passOverride[player]
	local forced = if override then override[passKey] else nil
	if forced ~= nil and RunService:IsStudio() then
		return forced
	end
	local pass = MonetizationConfig.ThemePassByKey[passKey]
	if not pass or pass.gamePassId <= 0 then
		return false
	end
	return MonetizationService.ownsPassCached(player, pass.gamePassId)
end

--- Whether a Robux row may be shown at all: a real pass, or Studio.
local function passOffered(passKey: string): boolean
	local pass = MonetizationConfig.ThemePassByKey[passKey]
	return pass ~= nil and (pass.gamePassId > 0 or RunService:IsStudio())
end

type Row = { key: string, cash: number, passKey: string? }

local function rowFor(key: string): Row?
	return (BaseThemeConfig.ThemeByKey[key] :: any) or (BaseThemeConfig.PedestalByKey[key] :: any)
end

function BaseThemeService.owns(player: Player, key: string): boolean
	local row = rowFor(key)
	if not row then
		return false
	end
	if row.passKey then
		return passOwned(player, row.passKey)
	end
	if row.cash <= 0 then
		return true
	end
	local profile = DataService.get(player)
	return profile ~= nil and profile.BaseTheme.owned[key] == true
end

--- The theme / skin actually painted: the equipped one if still owned,
--- otherwise the default. A Studio preview override wins.
function BaseThemeService.effective(player: Player): (BaseThemeConfig.Theme, BaseThemeConfig.PedestalSkin)
	local profile = DataService.get(player)
	local themeKey = if profile then profile.BaseTheme.equippedTheme else BaseThemeConfig.DEFAULT_THEME
	local pedestalKey = if profile then profile.BaseTheme.equippedPedestal else BaseThemeConfig.DEFAULT_PEDESTAL
	if not BaseThemeService.owns(player, themeKey) then
		themeKey = BaseThemeConfig.DEFAULT_THEME
	end
	if not BaseThemeService.owns(player, pedestalKey) then
		pedestalKey = BaseThemeConfig.DEFAULT_PEDESTAL
	end
	local preview = previewOverride[player]
	if preview and RunService:IsStudio() then
		themeKey = preview.theme or themeKey
		pedestalKey = preview.pedestal or pedestalKey
	end
	local theme = BaseThemeConfig.ThemeByKey[themeKey] or BaseThemeConfig.ThemeByKey[BaseThemeConfig.DEFAULT_THEME]
	local skin = BaseThemeConfig.PedestalByKey[pedestalKey] or BaseThemeConfig.PedestalByKey[BaseThemeConfig.DEFAULT_PEDESTAL]
	return theme, skin
end

-- ==========================================================
-- PAINTING THE PLOT
-- ==========================================================

type Original = { color: Color3, material: Enum.Material, transparency: number }

--- Every plot part this service changed, with its look before the change.
--- Weak keys: a destroyed part simply drops out.
local originals: { [BasePart]: Original } = setmetatable({}, { __mode = "k" }) :: any
--- Plot -> the theme key currently painted on its parts and decor.
local painted: { [Instance]: string } = {}
--- Plot -> the OwnerUserId it was painted for. The ownership watcher only
--- resets a plot whose owner is no longer this one: attribute signals may be
--- DEFERRED, so the "owner changed" handler for an assignment can run after
--- the new owner's rebuild has already painted their theme.
local paintedFor: { [Instance]: number } = {}

local function remember(part: BasePart)
	if not originals[part] then
		originals[part] = { color = part.Color, material = part.Material, transparency = part.Transparency }
	end
end

local function paint(part: BasePart, color: Color3?, material: Enum.Material?)
	if not color and not material then
		return
	end
	remember(part)
	if color then
		part.Color = color
	end
	if material then
		part.Material = material
	end
end

--- Puts every changed part under `plot` back and removes the decor.
local function restorePlot(plot: Instance)
	for part, original in originals do
		if part:IsDescendantOf(plot) then
			part.Color = original.color
			part.Material = original.material
			part.Transparency = original.transparency
			originals[part] = nil
		end
	end
	local decor = plot:FindFirstChild(DECOR_FOLDER)
	if decor then
		decor:Destroy()
	end
	painted[plot] = nil
	paintedFor[plot] = nil
end

local function partsNamed(folder: Instance?, names: { [string]: boolean }): { BasePart }
	local out: { BasePart } = {}
	if not folder then
		return out
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and names[child.Name] then
			table.insert(out, child)
		end
	end
	return out
end

--- A decor prop: the authored model when ServerStorage has one, else the
--- config primitive. Anchored, walk-through, never queried.
local function buildProp(def: BaseThemeConfig.Decor): Instance
	local assets = ServerStorage:FindFirstChild("GameAssets")
	local library = assets and assets:FindFirstChild("ThemeDecor")
	local authored = if def.modelName and library then library:FindFirstChild(def.modelName) else nil
	local prop: Instance
	if authored and authored:IsA("Model") then
		prop = authored:Clone()
	else
		local part = Instance.new("Part")
		part.Shape = if def.shape == "Ball"
			then Enum.PartType.Ball
			elseif def.shape == "Cylinder" then Enum.PartType.Cylinder
			else Enum.PartType.Block
		part.Size = def.size
		part.Color = def.color
		part.Material = def.material
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		if def.light > 0 then
			local light = Instance.new("PointLight")
			light.Color = def.color
			light.Range = def.light
			light.Brightness = 1.2
			light.Shadows = false
			light.Parent = part
		end
		prop = part
	end
	local descendants = prop:GetDescendants()
	table.insert(descendants, prop)
	for _, d in descendants do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
		elseif d:IsA("BaseScript") then
			d:Destroy()
		end
	end
	prop.Name = def.modelName or "Prop"
	return prop
end

--- Seats `prop` with its bottom on `top` (a world point) facing like `frame`.
local function seat(prop: Instance, frame: CFrame, top: Vector3, height: number)
	local cf = CFrame.new(top + Vector3.new(0, height / 2, 0)) * frame.Rotation
	if prop:IsA("Model") then
		local _, size = prop:GetBoundingBox()
		prop:PivotTo(CFrame.new(top + Vector3.new(0, size.Y / 2, 0)) * frame.Rotation)
	elseif prop:IsA("Part") and (prop :: Part).Shape == Enum.PartType.Cylinder then
		-- A cylinder's axis is X: stand it up.
		local part = prop :: Part
		part.CFrame = CFrame.new(top + Vector3.new(0, part.Size.X / 2, 0)) * frame.Rotation * CFrame.Angles(0, 0, math.rad(90))
	elseif prop:IsA("BasePart") then
		(prop :: BasePart).CFrame = cf
	end
end

local function buildDecor(plot: Instance, theme: BaseThemeConfig.Theme)
	local list = theme.decor
	if not list or #list == 0 then
		return
	end
	local fence = plot:FindFirstChild("Fence")
	local slab = BaseService.slabOf(plot)
	if not fence or not slab then
		return
	end
	-- Anchors from the fence's own parts, in the slab's frame.
	local gates = partsNamed(fence, { GateCap = true })
	local backCorners: { BasePart } = {}
	local half = slab.Size / 2
	for _, post in partsNamed(fence, { Post = true }) do
		local rel = slab.CFrame:PointToObjectSpace(post.Position)
		if math.abs(math.abs(rel.X) - half.X) < 3 and math.abs(rel.Z - half.Z) < 3 then
			table.insert(backCorners, post)
		end
	end

	local folder = Instance.new("Folder")
	folder.Name = DECOR_FOLDER
	for _, def in list do
		local anchors: { BasePart } = if def.anchor == "gate" then gates else backCorners
		for _, anchor in anchors do
			local prop = buildProp(def)
			local top = anchor.Position + Vector3.new(0, anchor.Size.Y / 2, 0)
			seat(prop, slab.CFrame, top, def.size.Y)
			prop.Parent = folder
		end
	end
	folder.Parent = plot
end

local function paintPlotParts(plot: Instance, theme: BaseThemeConfig.Theme)
	local floor = plot:FindFirstChild("PlotFloor")
	for _, slab in partsNamed(floor, { Slab = true }) do
		paint(slab, theme.floorColor, theme.floorMaterial)
	end
	local paving = plot:FindFirstChild("Paving")
	if paving and theme.pavingColor then
		for _, part in paving:GetChildren() do
			if part:IsA("BasePart") then
				paint(part, theme.pavingColor, nil)
			end
		end
	end
	local fence = plot:FindFirstChild("Fence")
	for _, post in partsNamed(fence, { Post = true, GatePost = true }) do
		paint(post, theme.fenceColor, theme.fenceMaterial)
	end
	for _, rail in partsNamed(fence, { Rail = true }) do
		paint(rail, theme.railColor, nil)
	end
	if theme.accentColor then
		for _, cap in partsNamed(fence, { GateCap = true }) do
			paint(cap, theme.accentColor, Enum.Material.Neon)
		end
	end
	buildDecor(plot, theme)
end

--- Empty pads breathe in the theme's accent. styleSlot repaints them on
--- every rebuild, so this runs after every rebuild; the client's breathing
--- reads the NeonColor attribute, so that is set too.
local function paintEmptyPads(plot: Instance, theme: BaseThemeConfig.Theme)
	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return
	end
	local accent = theme.accentColor or MapPalette.SlotNeonEmpty
	for _, slot in slots:GetChildren() do
		if slot:GetAttribute("SlotState") ~= "Empty" then
			continue
		end
		local frame = slot:FindFirstChild("NeonFrame")
		if frame then
			for _, edge in frame:GetChildren() do
				if edge:IsA("BasePart") and edge.Color ~= accent then
					edge.Color = accent
				end
			end
		end
		if slot:GetAttribute("NeonColor") ~= accent then
			slot:SetAttribute("NeonColor", accent)
		end
	end
end

-- ==========================================================
-- PEDESTAL SKINS
-- ==========================================================

--- Puts a pedestal part back to the look it was cloned with.
local function unskinPart(part: BasePart)
	local color = part:GetAttribute("SkinBaseColor")
	if typeof(color) == "Color3" then
		part.Color = color
	end
	local material = part:GetAttribute("SkinBaseMaterial")
	if type(material) == "string" then
		local ok, value = pcall(function()
			return (Enum.Material :: any)[material]
		end)
		if ok and typeof(value) == "EnumItem" then
			part.Material = value :: any
		end
	end
	local transparency = part:GetAttribute("SkinBaseTransparency")
	if type(transparency) == "number" then
		part.Transparency = transparency
	end
	if part:IsA("MeshPart") then
		local texture = part:GetAttribute("SkinBaseTexture")
		if type(texture) == "string" then
			part.TextureID = texture
		end
	end
	local stash = part:FindFirstChild(STASH_NAME)
	if stash then
		for _, held in stash:GetChildren() do
			held.Parent = part
		end
		stash:Destroy()
	end
end

local function skinPart(part: BasePart, skin: BaseThemeConfig.PedestalSkin)
	if part:GetAttribute("SkinBaseColor") == nil then
		part:SetAttribute("SkinBaseColor", part.Color)
		part:SetAttribute("SkinBaseMaterial", part.Material.Name)
		part:SetAttribute("SkinBaseTransparency", part.Transparency)
		if part:IsA("MeshPart") then
			part:SetAttribute("SkinBaseTexture", part.TextureID)
		end
	end
	-- A SurfaceAppearance or a mesh texture would hide the new colour: parked
	-- (not destroyed) so the default skin can put it back.
	local appearance = part:FindFirstChildOfClass("SurfaceAppearance")
	if appearance then
		local stash: Instance? = part:FindFirstChild(STASH_NAME)
		if not stash then
			local created = Instance.new("Folder")
			created.Name = STASH_NAME
			created.Parent = part
			stash = created
		end
		appearance.Parent = stash
	end
	if part:IsA("MeshPart") then
		part.TextureID = ""
	end
	if skin.color then
		part.Color = skin.color
	end
	if skin.material then
		part.Material = skin.material
	end
	if skin.transparency then
		part.Transparency = skin.transparency
	end
end

local function applySkin(pedestal: Model, skin: BaseThemeConfig.PedestalSkin)
	if pedestal:GetAttribute("Skin") == skin.key then
		return
	end
	local trim = pedestal:FindFirstChild(TRIM_NAME)
	if trim then
		trim:Destroy()
	end
	local isDefault = skin.color == nil and skin.material == nil
	for _, d in pedestal:GetDescendants() do
		-- The rarity Accent disc carries information; it keeps its colour.
		if d:IsA("BasePart") and d.Name ~= "Accent" then
			if isDefault then
				unskinPart(d)
			else
				skinPart(d, skin)
			end
		end
	end
	if skin.trimColor then
		local minCorner, maxCorner = LootModel.worldExtents(pedestal)
		if minCorner and maxCorner then
			local footprint = math.max(maxCorner.X - minCorner.X, maxCorner.Z - minCorner.Z)
			local ring = Instance.new("Part")
			ring.Name = TRIM_NAME
			ring.Shape = Enum.PartType.Cylinder
			ring.Size = Vector3.new(0.32, footprint * 1.08, footprint * 1.08)
			local centre = (minCorner + maxCorner) / 2
			ring.CFrame = CFrame.new(centre.X, minCorner.Y + 0.16, centre.Z) * CFrame.Angles(0, 0, math.rad(90))
			ring.Color = skin.trimColor
			ring.Material = skin.trimMaterial or Enum.Material.SmoothPlastic
			ring.Anchored = true
			ring.CanCollide = false
			ring.CanQuery = false
			ring.CanTouch = false
			ring.CastShadow = false
			ring.Parent = pedestal
		end
	end
	pedestal:SetAttribute("Skin", skin.key)
end

local function paintPedestals(plot: Instance, skin: BaseThemeConfig.PedestalSkin)
	local slots = plot:FindFirstChild("DisplaySlots")
	if not slots then
		return
	end
	for _, slot in slots:GetChildren() do
		local pedestal = slot:FindFirstChild("Pedestal")
		if pedestal and pedestal:IsA("Model") then
			applySkin(pedestal, skin)
		end
	end
end

-- ==========================================================
-- APPLY
-- ==========================================================

--- Paints the owner's plot with their effective theme and skin. Safe to call
--- any time (idempotent); called on every rebuild and on every change.
function BaseThemeService.apply(player: Player)
	local plot = BaseService.getPlot(player)
	if not plot or not DataService.get(player) then
		return
	end
	local theme, skin = BaseThemeService.effective(player)
	if painted[plot] ~= theme.key or paintedFor[plot] ~= player.UserId then
		restorePlot(plot)
		paintPlotParts(plot, theme)
		painted[plot] = theme.key
		paintedFor[plot] = player.UserId
	end
	paintEmptyPads(plot, theme)
	paintPedestals(plot, skin)
end

--- Ownership may have changed (a pass bought or refunded): re-apply and push.
function BaseThemeService.refresh(player: Player)
	BaseThemeService.apply(player)
	StateService.markDirty(player)
end

--- The plot's own look, back as the map had it. Pads and pedestals are
--- BaseService's to reset (styleUnowned).
function BaseThemeService.reset(plot: Instance)
	restorePlot(plot)
end

-- ==========================================================
-- REQUESTS
-- ==========================================================

local function save(player: Player)
	if DataService.isPersistent() then
		task.spawn(DataService.save, player)
	end
end

function BaseThemeService.equip(player: Player, key: string): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local isTheme = BaseThemeConfig.ThemeByKey[key] ~= nil
	local isPedestal = BaseThemeConfig.PedestalByKey[key] ~= nil
	if not isTheme and not isPedestal then
		return false
	end
	if not BaseThemeService.owns(player, key) then
		return false, "You don't own that yet."
	end
	if isTheme then
		profile.BaseTheme.equippedTheme = key
	else
		profile.BaseTheme.equippedPedestal = key
	end
	BaseThemeService.apply(player)
	StateService.pushNow(player)
	save(player)
	return true
end

function BaseThemeService.buy(player: Player, key: string): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local row = rowFor(key)
	if not row or row.passKey then
		return false
	end
	if BaseThemeService.owns(player, key) then
		return BaseThemeService.equip(player, key)
	end
	-- Atomic: the Cash check and the unlock happen with no yield between.
	if not EconomyService.spend(player, row.cash) then
		return false, `You need {NumberFormat.cash(row.cash)}.`
	end
	profile.BaseTheme.owned[key] = true
	local def = BaseThemeConfig.ThemeByKey[key]
	local skin = BaseThemeConfig.PedestalByKey[key]
	StateService.notify(player, "success", `Unlocked {if def then def.name else if skin then skin.name else key}!`, "levelup")
	-- A purchase is meant to be seen: it goes straight on.
	return BaseThemeService.equip(player, key)
end

function BaseThemeService.promptPass(player: Player, key: string): (boolean, string?)
	local row = rowFor(key)
	local passKey = row and row.passKey
	if not passKey then
		return false
	end
	local pass = MonetizationConfig.ThemePassByKey[passKey]
	if not pass or pass.gamePassId <= 0 then
		return false, "That theme is not available yet."
	end
	if passOwned(player, passKey) then
		return BaseThemeService.equip(player, key)
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, pass.gamePassId)
	end)
	if not ok then
		warn(`[BaseThemeService] PromptGamePassPurchase failed for {player.Name}: {err}`)
		return false, "Could not open the purchase."
	end
	return true
end

--- What the Upgrades panel's BASE section needs. Compact on purpose: it
--- rides every StatePush.
function BaseThemeService.summarise(player: Player): { [string]: any }?
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local owned: { string } = {}
	local offered: { string } = {}
	local function consider(row: Row)
		if BaseThemeService.owns(player, row.key) then
			table.insert(owned, row.key)
		end
		if row.passKey and passOffered(row.passKey) then
			table.insert(offered, row.key)
		end
	end
	for _, theme in BaseThemeConfig.Themes do
		consider(theme :: any)
	end
	for _, skin in BaseThemeConfig.Pedestals do
		consider(skin :: any)
	end
	return {
		owned = table.concat(owned, ","),
		offered = table.concat(offered, ","),
		theme = profile.BaseTheme.equippedTheme,
		pedestal = profile.BaseTheme.equippedPedestal,
	}
end

-- ==========================================================
-- STUDIO TESTING
-- ==========================================================

function BaseThemeService.setPassOwnedForTesting(player: Player, passKey: string, owned: boolean?)
	if not RunService:IsStudio() then
		return
	end
	local forPlayer = passOverride[player] or {}
	passOverride[player] = forPlayer
	forPlayer[passKey] = owned
	BaseThemeService.refresh(player)
end

--- Shows a theme / skin on the caller's plot regardless of ownership.
--- `nil, nil` clears the preview.
function BaseThemeService.previewForTesting(player: Player, themeKey: string?, pedestalKey: string?)
	if not RunService:IsStudio() then
		return
	end
	if themeKey == nil and pedestalKey == nil then
		previewOverride[player] = nil
	else
		previewOverride[player] = { theme = themeKey, pedestal = pedestalKey }
	end
	BaseThemeService.apply(player)
end

-- ==========================================================
-- START
-- ==========================================================

function BaseThemeService.start()
	StateService.addProvider("baseTheme", BaseThemeService.summarise)

	-- Every rebuild (full or one slot) re-creates pedestals and restyles pads.
	BaseService.onRebuilt(BaseThemeService.apply)

	-- A plot changing hands (assigned or released) starts from the map's look;
	-- the new owner's rebuild paints their theme right after.
	local map = workspace:WaitForChild("Map", 20)
	local bases = map and map:WaitForChild("Bases", 10)
	if bases then
		local function watch(plot: Instance)
			plot:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
				local owner = plot:GetAttribute("OwnerUserId")
				if paintedFor[plot] ~= nil and paintedFor[plot] ~= owner then
					BaseThemeService.reset(plot)
				end
			end)
		end
		for _, plot in bases:GetChildren() do
			watch(plot)
		end
		bases.ChildAdded:Connect(watch)
	end

	Remotes.get("BaseThemeRequest").OnServerEvent:Connect(function(player, action, key)
		if not limiter:consume(player) then
			return
		end
		if type(action) ~= "string" or type(key) ~= "string" or #key > 40 then
			return
		end
		local ok, reason
		if action == "buy" then
			ok, reason = BaseThemeService.buy(player, key)
		elseif action == "equip" then
			ok, reason = BaseThemeService.equip(player, key)
		elseif action == "buyPass" then
			ok, reason = BaseThemeService.promptPass(player, key)
		else
			return
		end
		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
		passOverride[player] = nil
		previewOverride[player] = nil
	end)

	-- Catch-up for plots assigned before this started (normally none: it is
	-- started before BaseService hands any out).
	for _, player in Players:GetPlayers() do
		BaseThemeService.apply(player)
	end
end

return BaseThemeService
