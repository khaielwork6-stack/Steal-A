--!strict
--[[
	FusionController
	The FUSE page of the Storage panel, and the short fusion animation.

	A PAGE, NOT A PANEL. InventoryController owns the Storage window, its tabs
	and its card factory; it hands this module a small kit (blank cards,
	button layout, thumbnails, mounting) and calls `render` while the FUSE tab
	is open. So a fusion card is a Storage card, pixel for pixel.

	WHAT THE PAGE SHOWS
	  no item picked   one card per item with >= 3 revealed stored copies
	  item picked      a summary card (result size, cost, FUSE / BACK), a card
	                   with the mutation odds AFTER the floor (what can come
	                   out, and how likely), then every copy with USE /
	                   USING - exactly three are used, and the player picks
	                   which. The default pick is the best copy (it decides
	                   the result's size and mutation floor) plus the two
	                   weakest.

	NOTHING HERE DECIDES ANYTHING. The price and odds shown come from
	FusionConfig, the same functions the server uses; the server re-checks
	every input, charges, rolls and only then sends FusionResult, which is
	all the animation plays.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local FusionConfig = require(ReplicatedStorage.Shared.Config.FusionConfig)
local ItemThumb = require(ReplicatedStorage.Shared.Util.ItemThumb)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ScaleConfig = require(ReplicatedStorage.Shared.Config.ScaleConfig)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)

local FusionController = {}

local player = Players.LocalPlayer

--- What InventoryController lends this page.
export type Kit = {
	blankCard: (name: string, index: number) -> (Frame?, TextLabel?, TextLabel?, TextLabel?),
	layoutActions: (card: Frame, primary: string, secondary: string) -> (TextButton?, TextButton?),
	tintButton: (button: TextButton, base: Color3, top: Color3, bottom: Color3) -> (),
	flatten: (label: TextLabel?, color: Color3) -> (),
	paintThumb: (card: Frame, itemId: string?, rarity: string?, caption: string?, stroke: Color3?) -> (),
	mountCard: (card: Frame, key: string, index: number) -> (),
	setEmpty: (visible: boolean, title: string, hint: string) -> (),
	refresh: () -> (),
}

local GREEN = { Color3.fromRGB(0, 158, 40), Color3.fromRGB(120, 240, 130), Color3.fromRGB(0, 150, 40) }
local BLUE = { Color3.fromRGB(46, 70, 150), Color3.fromRGB(140, 170, 255), Color3.fromRGB(60, 90, 200) }
local GREY = { Color3.fromRGB(70, 80, 100), Color3.fromRGB(160, 172, 196), Color3.fromRGB(96, 108, 136) }
local PURPLE = { Color3.fromRGB(110, 40, 170), Color3.fromRGB(210, 150, 255), Color3.fromRGB(130, 60, 200) }
local WHITE = Color3.fromRGB(255, 255, 255)
local SUB = Color3.fromRGB(206, 216, 232)
local USING_GREEN = Color3.fromRGB(120, 255, 160)

local selectedItem: string? = nil
local chosen: { string } = {}
--- A FUSE press waits for the server (FusionResult or a toast); no second
--- press until then or until the timeout.
local pendingUntil = 0
local PENDING_TIMEOUT = 3

-- ==========================================================
-- DATA
-- ==========================================================

type Copy = any

--- Revealed stored copies, grouped by ItemId.
local function groups(inventory: { Copy }): { [string]: { Copy } }
	local out: { [string]: { Copy } } = {}
	for _, item in inventory do
		if type(item) == "table" and type(item.ItemId) == "string" and item.Hatched ~= false then
			local list = out[item.ItemId]
			if not list then
				list = {}
				out[item.ItemId] = list
			end
			table.insert(list, item)
		end
	end
	return out
end

local function sizeClass(item: Copy): number
	return FusionConfig.classOf(tonumber(item.Scale) or 1)
end

local function mutationRank(item: Copy): number
	return RarityConfig.mutationRank(RarityConfig.normaliseMutation(item.Mutation))
end

--- Strongest first: size class, then mutation, then income.
local function stronger(a: Copy, b: Copy): boolean
	local ca, cb = sizeClass(a), sizeClass(b)
	if ca ~= cb then
		return ca > cb
	end
	local ma, mb = mutationRank(a), mutationRank(b)
	if ma ~= mb then
		return ma > mb
	end
	return (tonumber(a.FinalIncome) or 0) > (tonumber(b.FinalIncome) or 0)
end

--- The default three: the best copy plus the two weakest others.
local function defaultPick(copies: { Copy }): { string }
	local sorted = table.clone(copies)
	table.sort(sorted, stronger)
	local pick = { sorted[1].InstanceId }
	for index = #sorted, 2, -1 do
		if #pick >= FusionConfig.INPUTS then
			break
		end
		table.insert(pick, sorted[index].InstanceId)
	end
	return pick
end

type Preview = { cost: number, target: number, targetSize: string, floor: string, outcomes: { { id: string, chance: number } } }

--- The same numbers FusionService.previewFor computes.
local function preview(itemId: string, inputs: { Copy }): Preview?
	local def = LootConfig.ById[itemId]
	if not def or #inputs == 0 then
		return nil
	end
	local best = 1
	local floor = "Normal"
	for _, item in inputs do
		best = math.max(best, sizeClass(item))
		local mutation = RarityConfig.normaliseMutation(item.Mutation)
		if RarityConfig.mutationRank(mutation) > RarityConfig.mutationRank(floor) then
			floor = mutation
		end
	end
	local target = FusionConfig.targetClass(best)
	local variant = ScaleConfig.Variants[target]
	return {
		cost = FusionConfig.costFor(def.income, target),
		target = target,
		targetSize = if variant then variant.id else "Normal",
		floor = floor,
		outcomes = FusionConfig.mutationOutcomes(floor),
	}
end

local function formatChance(chance: number): string
	if chance >= 10 or chance == math.floor(chance) then
		return `{math.floor(chance + 0.5)}%`
	end
	return string.format("%.1f%%", chance)
end

--- Drops a selection that no longer makes sense (copies fused / sold).
local function reconcileSelection(byItem: { [string]: { Copy } })
	if not selectedItem then
		return
	end
	local copies = byItem[selectedItem :: string]
	if not copies or #copies < FusionConfig.INPUTS then
		selectedItem = nil
		table.clear(chosen)
		return
	end
	local present: { [string]: boolean } = {}
	for _, item in copies do
		present[item.InstanceId] = true
	end
	for index = #chosen, 1, -1 do
		if not present[chosen[index]] then
			table.remove(chosen, index)
		end
	end
end

-- ==========================================================
-- PAGE
-- ==========================================================

--- What the page was built from. InventoryController rebuilds when it moves.
function FusionController.signature(state: any): string
	local inventory = if state and type(state.inventory) == "table" then state.inventory else {}
	local byItem = groups(inventory)
	reconcileSelection(byItem)
	local parts: { string } = { "F", tostring(selectedItem), table.concat(chosen, ",") }
	local keys: { string } = {}
	for itemId, copies in byItem do
		if #copies >= FusionConfig.INPUTS then
			table.insert(keys, itemId)
		end
	end
	table.sort(keys)
	for _, itemId in keys do
		local rows: { string } = {}
		for _, item in byItem[itemId] do
			table.insert(rows, `{item.InstanceId}:{item.Size}:{item.Mutation}:{item.FinalIncome}`)
		end
		table.insert(parts, `{itemId}={table.concat(rows, ";")}`)
	end
	-- Affordability only (not the balance), so income ticks do not rebuild.
	if selectedItem then
		local copies: { Copy } = byItem[selectedItem :: string] or {}
		local inputs: { Copy } = {}
		for _, item in copies do
			if table.find(chosen, item.InstanceId) then
				table.insert(inputs, item)
			end
		end
		local p = preview(selectedItem :: string, inputs)
		table.insert(parts, tostring(p ~= nil and (state.cash or 0) >= p.cost))
	end
	return table.concat(parts, "|")
end

local function toggle(instanceId: string, kit: Kit)
	local at = table.find(chosen, instanceId)
	if at then
		table.remove(chosen, at)
	else
		if #chosen >= FusionConfig.INPUTS then
			-- Replace the oldest pick, so a tap always does something.
			table.remove(chosen, 1)
		end
		table.insert(chosen, instanceId)
	end
	kit.refresh()
end

local function listPage(kit: Kit, byItem: { [string]: { Copy } })
	local rows: { { itemId: string, copies: { Copy } } } = {}
	for itemId, copies in byItem do
		if #copies >= FusionConfig.INPUTS then
			table.insert(rows, { itemId = itemId, copies = copies })
		end
	end
	table.sort(rows, function(a, b)
		local da, db = LootConfig.ById[a.itemId], LootConfig.ById[b.itemId]
		local ra = if da then RarityConfig.rank(da.rarity) else 0
		local rb = if db then RarityConfig.rank(db.rarity) else 0
		if ra ~= rb then
			return ra > rb
		end
		return a.itemId < b.itemId
	end)
	kit.setEmpty(
		#rows == 0,
		"Nothing To Fuse",
		`Store {FusionConfig.INPUTS} revealed copies of the same item to fuse them into a bigger one.`
	)
	for index, row in rows do
		local def = LootConfig.ById[row.itemId]
		local rarity = if def then def.rarity else "Common"
		local card, nameRow, variantRow, tagRow = kit.blankCard(`Fuse_{row.itemId}`, index)
		if not card then
			continue
		end
		kit.flatten(nameRow, WHITE)
		kit.flatten(variantRow, SUB)
		kit.flatten(tagRow, RarityConfig.Colors[rarity] or WHITE)
		if nameRow then
			nameRow.Text = if def then def.name else row.itemId
		end
		if variantRow then
			variantRow.Text = `{#row.copies} COPIES STORED`
		end
		if tagRow then
			tagRow.Text = "FUSE 3 INTO 1 BIGGER"
		end
		kit.paintThumb(card, row.itemId, rarity, `x{#row.copies}`, nil)
		local primary, secondary = kit.layoutActions(card, "FUSE", "")
		if primary then
			kit.tintButton(primary, PURPLE[1], PURPLE[2], PURPLE[3])
			primary.Activated:Connect(function()
				selectedItem = row.itemId
				chosen = defaultPick(row.copies)
				kit.refresh()
			end)
		end
		if secondary then
			secondary.Visible = false
		end
		kit.mountCard(card, `F_{row.itemId}`, index)
	end
end

local function detailPage(kit: Kit, state: any, itemId: string, copies: { Copy })
	kit.setEmpty(false, "", "")
	local def = LootConfig.ById[itemId]
	local rarity = if def then def.rarity else "Common"
	local rarityColor = RarityConfig.Colors[rarity] or WHITE
	local inputs: { Copy } = {}
	for _, item in copies do
		if table.find(chosen, item.InstanceId) then
			table.insert(inputs, item)
		end
	end
	local ready = #inputs == FusionConfig.INPUTS
	local p = preview(itemId, inputs)
	local cost = if p then p.cost else 0
	local affordable = (state.cash or 0) >= cost
	local pending = os.clock() < pendingUntil

	-- ---------- summary ----------
	local card, nameRow, variantRow, tagRow = kit.blankCard("FuseSummary", 1)
	if card then
		kit.flatten(nameRow, WHITE)
		kit.flatten(variantRow, Color3.fromRGB(255, 214, 64))
		kit.flatten(tagRow, if affordable then USING_GREEN else Color3.fromRGB(255, 120, 120))
		if nameRow then
			nameRow.Text = `FUSE {FusionConfig.INPUTS}x {if def then def.name else itemId}`
		end
		if variantRow then
			variantRow.Text = if p and ready
				then `RESULT: {string.upper(p.targetSize)} (+1 SIZE)`
				else `PICK {FusionConfig.INPUTS - #inputs} MORE BELOW`
		end
		if tagRow then
			tagRow.Text = if ready then `COST {NumberFormat.cash(cost)}` else `USING {#inputs}/{FusionConfig.INPUTS}`
		end
		kit.paintThumb(card, itemId, rarity, if p then string.upper(p.targetSize) else nil, rarityColor)
		local fuse, back = kit.layoutActions(card, if pending then "FUSING..." else "FUSE!", "BACK")
		if fuse then
			local enabled = ready and affordable and not pending
			local colors = if enabled then GREEN else GREY
			kit.tintButton(fuse, colors[1], colors[2], colors[3])
			fuse.AutoButtonColor = enabled
			fuse.Activated:Connect(function()
				if not ready or os.clock() < pendingUntil then
					return
				end
				if not affordable then
					UIAnim.punch(card, 0.05)
					return
				end
				pendingUntil = os.clock() + PENDING_TIMEOUT
				Remotes.get("FusionRequest"):FireServer("fuse", itemId, table.clone(chosen))
				kit.refresh()
				task.delay(PENDING_TIMEOUT + 0.1, kit.refresh)
			end)
		end
		if back then
			kit.tintButton(back, BLUE[1], BLUE[2], BLUE[3])
			back.Activated:Connect(function()
				selectedItem = nil
				table.clear(chosen)
				kit.refresh()
			end)
		end
		kit.mountCard(card, "FuseSummary", 1)
	end

	-- ---------- odds ----------
	local odds, oddsTitle, oddsA, oddsB = kit.blankCard("FuseOdds", 2)
	if odds and p then
		kit.flatten(oddsTitle, WHITE)
		kit.flatten(oddsA, SUB)
		kit.flatten(oddsB, SUB)
		local words: { string } = {}
		for _, row in p.outcomes do
			if row.chance > 0 then
				table.insert(words, `{string.upper(row.id)} {formatChance(row.chance)}`)
			end
		end
		local half = math.ceil(#words / 2)
		if oddsTitle then
			oddsTitle.Text = "MUTATION ODDS"
		end
		if oddsA then
			oddsA.Text = if half >= 1 then table.concat(words, "  ", 1, half) else ""
		end
		if oddsB then
			oddsB.Text = if #words > half then table.concat(words, "  ", half + 1, #words) else "NEVER BELOW YOUR BEST COPY"
		end
		local floorColor = RarityConfig.MutationColors[p.floor] or SUB
		kit.paintThumb(odds, nil, nil, "ODDS", floorColor)
		local a, b = kit.layoutActions(odds, "", "")
		if a then
			a.Visible = false
		end
		if b then
			b.Visible = false
		end
		kit.mountCard(odds, "FuseOdds", 2)
	end

	-- ---------- the copies ----------
	local sorted = table.clone(copies)
	table.sort(sorted, stronger)
	for index, item in sorted do
		local using = table.find(chosen, item.InstanceId) ~= nil
		local copyCard, copyName, copyVariant, copyTag = kit.blankCard(`FuseCopy_{item.InstanceId}`, index + 2)
		if not copyCard then
			continue
		end
		kit.flatten(copyName, WHITE)
		kit.flatten(copyVariant, SUB)
		kit.flatten(copyTag, if using then USING_GREEN else Color3.fromRGB(126, 255, 148))
		if copyName then
			copyName.Text = if def then def.name else itemId
		end
		if copyVariant then
			local mutation = RarityConfig.normaliseMutation(item.Mutation)
			copyVariant.Text = `{string.upper(item.Size or "Normal")} - {string.upper(mutation)}`
		end
		if copyTag then
			copyTag.Text = NumberFormat.income(tonumber(item.FinalIncome) or 0)
		end
		kit.paintThumb(copyCard, itemId, rarity, if using then "USING" else nil, if using then USING_GREEN else rarityColor)
		local use, _spare = kit.layoutActions(copyCard, if using then "USING" else "USE", "")
		if use then
			local colors = if using then GREEN else BLUE
			kit.tintButton(use, colors[1], colors[2], colors[3])
			use.Activated:Connect(function()
				toggle(item.InstanceId, kit)
			end)
		end
		if _spare then
			_spare.Visible = false
		end
		local stroke = copyCard:FindFirstChildOfClass("UIStroke")
		if stroke and using then
			stroke.Color = USING_GREEN
		end
		kit.mountCard(copyCard, `FC_{item.InstanceId}`, index + 2)
	end
end

local lastKit: Kit? = nil

--- Builds the page into the (already cleared) list.
function FusionController.render(kit: Kit, state: any)
	lastKit = kit
	local inventory = if state and type(state.inventory) == "table" then state.inventory else {}
	local byItem = groups(inventory)
	reconcileSelection(byItem)
	if selectedItem then
		detailPage(kit, state, selectedItem :: string, byItem[selectedItem :: string] or {})
	else
		listPage(kit, byItem)
	end
end

-- ==========================================================
-- THE ANIMATION
-- ==========================================================

local function thumb(parent: Instance, itemId: string?, rarity: string?, size: number): ImageLabel
	local icon = Instance.new("ImageLabel")
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Size = UDim2.fromOffset(size, size)
	icon.BackgroundTransparency = 0
	icon.ZIndex = 5
	icon.Parent = parent
	ItemThumb.apply(icon, rarity, itemId)
	return icon
end

local function label(parent: Instance, text: string, y: number, height: number, color: Color3): TextLabel
	local out = Instance.new("TextLabel")
	out.AnchorPoint = Vector2.new(0.5, 0.5)
	out.Position = UDim2.new(0.5, 0, 0.5, y)
	out.Size = UDim2.fromOffset(340, height)
	out.BackgroundTransparency = 1
	out.Font = Enum.Font.FredokaOne
	out.TextScaled = true
	out.TextColor3 = color
	out.Text = text
	out.ZIndex = 6
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(12, 14, 24)
	stroke.Parent = out
	out.Parent = parent
	return out
end

local playing: ScreenGui? = nil

function FusionController.play(payload: any)
	if type(payload) ~= "table" or type(payload.result) ~= "table" then
		return
	end
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if not gui then
		return
	end
	if playing then
		playing:Destroy()
	end
	local reduced = Effects.isReduced()
	local cfg = FusionConfig.Animation
	local result = payload.result
	local rarity = if type(result.rarity) == "string" then result.rarity else "Common"
	local accent = RarityConfig.Colors[rarity] or WHITE

	local screen = Instance.new("ScreenGui")
	screen.Name = "FusionAnimation"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 50
	screen.Parent = gui
	playing = screen

	local shade = Instance.new("TextButton")
	shade.Name = "Shade"
	shade.Text = ""
	shade.AutoButtonColor = false
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 1
	shade.ZIndex = 1
	shade.Parent = screen
	TweenService:Create(shade, TweenInfo.new(0.2), { BackgroundTransparency = 0.35 }):Play()

	local centre = Instance.new("Frame")
	centre.Name = "Stage"
	centre.AnchorPoint = Vector2.new(0.5, 0.5)
	centre.Position = UDim2.fromScale(0.5, 0.45)
	centre.Size = UDim2.fromOffset(0, 0)
	centre.BackgroundTransparency = 1
	centre.ZIndex = 2
	centre.Parent = screen
	-- Same shrink the HUD uses on phones, so the stage fits a small screen.
	local scale = Instance.new("UIScale")
	local camera = workspace.CurrentCamera
	local shortEdge = if camera then math.min(camera.ViewportSize.X, camera.ViewportSize.Y) else 720
	scale.Scale = math.clamp(shortEdge / 620, 0.6, 1.2)
	scale.Parent = centre

	local function close()
		if playing == screen then
			playing = nil
		end
		TweenService:Create(shade, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		task.delay(0.2, function()
			screen:Destroy()
		end)
	end

	task.spawn(function()
		if not reduced then
			-- THE SPIN: the consumed copies orbit inward and merge.
			local consumed = if type(payload.consumed) == "table" then payload.consumed else {}
			local icons: { ImageLabel } = {}
			for index = 1, math.max(#consumed, 1) do
				local row = consumed[index]
				local icon = thumb(centre, if row then row.itemId else result.itemId, if row then row.rarity else rarity, 92)
				table.insert(icons, icon)
			end
			local started = os.clock()
			local loop = RunService.RenderStepped:Connect(function()
				local t = math.clamp((os.clock() - started) / cfg.spin, 0, 1)
				local eased = t * t
				local radius = 150 * (1 - eased)
				local angle = eased * math.pi * 4
				for index, icon in icons do
					local a = angle + (index - 1) * (math.pi * 2 / #icons)
					icon.Position = UDim2.fromOffset(math.cos(a) * radius, math.sin(a) * radius)
					local size = 92 * (1 - 0.5 * eased)
					icon.Size = UDim2.fromOffset(size, size)
				end
			end)
			task.wait(cfg.spin)
			loop:Disconnect()
			for _, icon in icons do
				icon:Destroy()
			end
			-- THE FLASH.
			local flash = Instance.new("Frame")
			flash.AnchorPoint = Vector2.new(0.5, 0.5)
			flash.Size = UDim2.fromOffset(40, 40)
			flash.BackgroundColor3 = accent
			flash.ZIndex = 4
			local round = Instance.new("UICorner")
			round.CornerRadius = UDim.new(0.5, 0)
			round.Parent = flash
			flash.Parent = centre
			TweenService:Create(flash, TweenInfo.new(cfg.flash, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.fromOffset(420, 420),
				BackgroundTransparency = 1,
			}):Play()
			task.delay(cfg.flash, function()
				flash:Destroy()
			end)
		end

		-- THE RESULT.
		local def = LootConfig.ById[result.itemId]
		local hero = thumb(centre, result.itemId, rarity, 150)
		hero.Position = UDim2.fromOffset(0, -30)
		local edge = hero:FindFirstChildOfClass("UIStroke")
		if edge then
			edge.Thickness = 4
			edge.Color = accent
		end
		local mutation = RarityConfig.normaliseMutation(result.mutation)
		local title = label(centre, if def then def.name else tostring(result.itemId), 70, 40, accent)
		local tags = { string.upper(tostring(result.size or "Normal")) }
		if mutation ~= "Normal" then
			table.insert(tags, string.upper(mutation))
		end
		local variant = label(centre, table.concat(tags, " - "), 108, 28, RarityConfig.MutationColors[mutation] or WHITE)
		local income = label(centre, NumberFormat.income(tonumber(result.income) or 0), 140, 26, Color3.fromRGB(126, 255, 148))
		local heading = label(centre, "FUSION COMPLETE!", -135, 34, Color3.fromRGB(255, 214, 64))
		if FusionConfig.ICON ~= "rbxassetid://0" then
			local machine = Instance.new("ImageLabel")
			machine.AnchorPoint = Vector2.new(0.5, 0.5)
			machine.Position = UDim2.fromOffset(0, -190)
			machine.Size = UDim2.fromOffset(72, 72)
			machine.BackgroundTransparency = 1
			machine.Image = FusionConfig.ICON
			machine.ZIndex = 6
			machine.Parent = centre
		end
		if reduced then
			for _, thing in { title, variant, income, heading } do
				thing.TextTransparency = 1
				TweenService:Create(thing, TweenInfo.new(cfg.reduced), { TextTransparency = 0 }):Play()
			end
		else
			UIAnim.popIn(hero, 0.4)
			UIAnim.popIn(heading, 0.6)
		end
		shade.Activated:Connect(close)
		task.wait(cfg.hold)
		if screen.Parent then
			close()
		end
	end)
end

function FusionController.start()
	Remotes.get("FusionResult").OnClientEvent:Connect(function(payload)
		pendingUntil = 0
		selectedItem = nil
		table.clear(chosen)
		if lastKit then
			lastKit.refresh()
		end
		FusionController.play(payload)
	end)
end

return FusionController
