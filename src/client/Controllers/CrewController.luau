--!strict
--[[
	CrewController
	The crew UI (vaults-crews). Renders StatePush.crew (CrewService.summarise)
	and sends CrewRequest intents; the server decides everything.

	  CREW CARD   a small list on the right edge of the HUD (inside MainUI, so
	              it hides with the rest of the HUD when a panel opens): a
	              "CREW" header button, the members, and any invites with
	              accept / decline buttons.
	  CREW PANEL  Frames.Crew, cloned from the pack's Sell panel skeleton (the
	              template InventoryController parks in MainUI.Templates).
	              The header button is NAMED "Crew", so the pack's own script
	              pairs it with this frame (slide-up, blur, close X). One row
	              per other player in the server: INVITE / KICK / ACCEPT.
	  NAMEPLATES  a "CREW" tag over each crew mate's head, local only.

	Touch targets are at least 68 px before MainUI's phone UIScale (>= 44
	effective). Every button we drive is claimed (UIAnim.claimButton) except
	the opener, which the pack must own to open the panel.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrewConfig = require(ReplicatedStorage.Shared.Config.CrewConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)
local StateStore = require(script.Parent.Parent.StateStore)

local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)

local CrewController = {}

local player = Players.LocalPlayer

local FONT = Enum.Font.FredokaOne
local WHITE = Color3.fromRGB(255, 255, 255)
local TEAL = Color3.fromRGB(40, 190, 170)
local RED = Color3.fromRGB(220, 60, 80)
local GREY = Color3.fromRGB(90, 96, 110)
local PANEL = Color3.fromRGB(24, 30, 44)
local GOLD = Color3.fromRGB(255, 210, 90)

local ROW_HEIGHT = 68

local crew: any = nil
local panelList: ScrollingFrame? = nil
local leaveButton: TextButton? = nil

local function send(action: string, userId: number?)
	Remotes.get("CrewRequest"):FireServer(action, userId)
end

-- ==========================================================
-- BUILDING BLOCKS
-- ==========================================================

local function round(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number)
	local line = Instance.new("UIStroke")
	line.Color, line.Thickness = color, thickness
	line.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	line.Parent = parent
end

local function label(parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font, l.TextScaled, l.TextColor3 = FONT, true, color or WHITE
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text, l.Size, l.Position = text, size, position
	local outline = Instance.new("UIStroke")
	outline.Thickness = 1.5
	outline.Parent = l
	l.Parent = parent
	return l
end

--- A button we drive ourselves: claimed before it is parented, so the pack's
--- scanner leaves it alone.
local function button(parent: Instance, name: string, text: string, color: Color3, size: UDim2, position: UDim2, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AutoButtonColor = false
	b.BackgroundColor3 = color
	b.Font, b.TextScaled, b.TextColor3 = FONT, true, WHITE
	b.Text, b.Size, b.Position = text, size, position
	b.AnchorPoint = Vector2.new(0, 0.5)
	round(b, 10)
	stroke(b, color:Lerp(Color3.new(0, 0, 0), 0.4), 2)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0.18, 0), UDim.new(0.18, 0)
	pad.Parent = b
	UIAnim.claimButton(b)
	b.Activated:Connect(onClick)
	b.Parent = parent
	return b
end

local function clear(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- ==========================================================
-- PANEL (Frames.Crew)
-- ==========================================================

local function findTemplate(ui: Instance): Frame?
	local templates = ui:WaitForChild("Templates", 30)
	local sell = templates and templates:WaitForChild("Sell", 10)
	if not sell then
		local frames = ui:FindFirstChild("Frames")
		sell = frames and frames:FindFirstChild("Sell")
	end
	return if sell and sell:IsA("Frame") then sell else nil
end

local function firstLabel(root: Instance): TextLabel?
	return root:FindFirstChildWhichIsA("TextLabel", true)
end

local function buildPanel(ui: Instance): boolean
	local frames = ui:FindFirstChild("Frames")
	local template = findTemplate(ui)
	if not frames or not template then
		warn("[CrewController] no panel skeleton - the Crew panel is disabled")
		return false
	end
	local panel = template:Clone()
	panel.Name = "Crew"
	panel.Visible = false
	local top = panel:FindFirstChild("Top")
	local header = top and top:FindFirstChild("Frame")
	local list = panel:FindFirstChild("ScrollingFrame")
	if not header or not list or not list:IsA("ScrollingFrame") then
		warn("[CrewController] panel skeleton hierarchy unexpected - the Crew panel is disabled")
		return false
	end
	local title = header:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = "Crew"
	end
	-- The pack's SELL ALL becomes LEAVE CREW.
	local action = header:FindFirstChild("SellAll")
	if action and action:IsA("TextButton") then
		action.Name = "CrewLeave"
		local text = firstLabel(action)
		if text then
			text.Text = "LEAVE"
		end
		UIAnim.claimButton(action)
		action.Activated:Connect(function()
			send("leave")
		end)
		leaveButton = action
	end
	-- Empty the list, keeping its layout objects.
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local layout: UIListLayout = list:FindFirstChildOfClass("UIListLayout") or Instance.new("UIListLayout")
	layout.Parent = list
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	panelList = list
	panel.Parent = frames
	PanelStyle.window(panel, 780, 540)
	return true
end

local function renderPanel()
	local list = panelList
	if not list then
		return
	end
	clear(list)
	local inCrew = crew ~= nil and crew.id ~= nil
	local leader = inCrew and crew.leader == true
	if leaveButton then
		leaveButton.Visible = inCrew
	end
	local members: { [number]: boolean } = {}
	local invitedMe: { [number]: boolean } = {}
	local sent: { [number]: boolean } = {}
	local recent: { [number]: boolean } = {}
	if crew then
		for _, member in crew.members or {} do
			members[member.userId] = true
		end
		for _, invite in crew.invites or {} do
			invitedMe[invite.userId] = true
		end
		for _, id in crew.sent or {} do
			sent[id] = true
		end
		for _, id in crew.recent or {} do
			recent[id] = true
		end
	end
	local full = inCrew and #(crew.members or {}) >= (crew.max or CrewConfig.MAX_MEMBERS)

	local others = Players:GetPlayers()
	table.sort(others, function(a, b)
		local am, bm = members[a.UserId] and 0 or 1, members[b.UserId] and 0 or 1
		if am ~= bm then
			return am < bm
		end
		return a.DisplayName < b.DisplayName
	end)
	local order = 0
	for _, other in others do
		if other == player then
			continue
		end
		order += 1
		local id = other.UserId
		local row = Instance.new("Frame")
		row.Name = "CrewRow"
		row.LayoutOrder = order
		row.Size = UDim2.new(0.94, 0, 0, ROW_HEIGHT + 8)
		row.BackgroundColor3 = PANEL
		row.BackgroundTransparency = 0.15
		round(row, 12)
		stroke(row, if members[id] then TEAL else GREY, 2)
		local tag = if members[id] then "IN YOUR CREW"
			elseif other:GetAttribute("CrewId") ~= nil then "IN A CREW"
			elseif recent[id] then "RECENT CREW MATE"
			else ""
		label(row, other.DisplayName, UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.04, 0.08))
		label(row, tag, UDim2.fromScale(0.5, 0.32), UDim2.fromScale(0.04, 0.6), if members[id] then TEAL else Color3.fromRGB(190, 196, 210))
		local wide = UDim2.new(0.34, 0, 0, ROW_HEIGHT)
		if invitedMe[id] and not inCrew then
			local half = UDim2.new(0.17, -2, 0, ROW_HEIGHT)
			button(row, "CrewAccept", "JOIN", TEAL, half, UDim2.fromScale(0.62, 0.5), function()
				send("accept", id)
			end)
			button(row, "CrewDecline", "NO", RED, half, UDim2.fromScale(0.80, 0.5), function()
				send("decline", id)
			end)
		elseif members[id] then
			if leader then
				button(row, "CrewKick", "KICK", RED, wide, UDim2.fromScale(0.62, 0.5), function()
					send("kick", id)
				end)
			end
		elseif sent[id] then
			label(row, "INVITED", UDim2.fromScale(0.3, 0.4), UDim2.fromScale(0.66, 0.3), GOLD)
		elseif other:GetAttribute("CrewId") == nil and (not inCrew or (leader and not full)) then
			button(row, "CrewInvite", "INVITE", TEAL, wide, UDim2.fromScale(0.62, 0.5), function()
				send("invite", id)
			end)
		end
		row.Parent = list
	end
	if order == 0 then
		local empty = Instance.new("Frame")
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.new(0.94, 0, 0, ROW_HEIGHT)
		label(empty, "Nobody else is in this server yet.", UDim2.fromScale(1, 0.6), UDim2.fromScale(0, 0.2))
		empty.Parent = list
	end
end

-- ==========================================================
-- NAMEPLATES
-- ==========================================================

local TAG_NAME = "CrewTag"

local function tagCharacter(other: Player, leaderFlag: boolean?)
	local character = other.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return
	end
	local existing = head:FindFirstChild(TAG_NAME)
	if leaderFlag == nil then
		if existing then
			existing:Destroy()
		end
		return
	end
	local gui = existing :: BillboardGui?
	if not gui then
		local made = Instance.new("BillboardGui")
		made.Name = TAG_NAME
		made.Size = UDim2.fromOffset(110, 26)
		made.StudsOffset = Vector3.new(0, 3.4, 0)
		made.MaxDistance = CrewConfig.NAMEPLATE_MAX_DISTANCE
		made.AlwaysOnTop = false
		made.LightInfluence = 0
		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.BackgroundColor3 = TEAL
		text.BackgroundTransparency = 0.1
		text.Size = UDim2.fromScale(1, 1)
		text.Font, text.TextScaled, text.TextColor3 = FONT, true, WHITE
		round(text, 8)
		text.Parent = made
		made.Parent = head
		gui = made
	end
	local text = (gui :: BillboardGui):FindFirstChild("Text")
	if text and text:IsA("TextLabel") then
		text.Text = if leaderFlag then "★ CREW LEAD" else "CREW"
	end
end

local function renderTags()
	local byId: { [number]: boolean } = {}
	if crew then
		for _, member in crew.members or {} do
			byId[member.userId] = member.leader == true
		end
	end
	for _, other in Players:GetPlayers() do
		if other ~= player then
			tagCharacter(other, byId[other.UserId])
		end
	end
end

local function render()
	-- (the HUD card is gone; the roster lives in the panel)
	renderPanel()
	renderTags()
end

-- ==========================================================
-- START
-- ==========================================================

function CrewController.start()
	local gui = player:WaitForChild("PlayerGui")
	local ui = gui:WaitForChild("MainUI", 60)
	if not ui then
		warn("[CrewController] MainUI missing - crew UI disabled")
		return
	end
	-- NO HUD CARD. The "CREW +" button under QUESTS is gone on every device
	-- (owner's call). The panel is still built so an existing crew keeps its
	-- tags, invites and the Frames.Crew panel; nothing on the HUD opens it now.
	buildPanel(ui)

	-- The provider builds a fresh table every push; redraw only when its
	-- content changed, or every button would be rebuilt under the finger.
	local lastSignature = ""
	StateStore.onKeyChanged("crew", function(value)
		local ok, signature = pcall(HttpService.JSONEncode, HttpService, value)
		local key = if ok then signature else tostring(os.clock())
		-- The invite countdown changes every second; it is not drawn.
		key = string.gsub(key, '"expiresIn":%d+', "")
		if key == lastSignature then
			return
		end
		lastSignature = key
		crew = value
		render()
	end)
	local function watch(other: Player)
		other.CharacterAdded:Connect(function()
			task.wait(0.5)
			renderTags()
		end)
		other:GetAttributeChangedSignal("CrewId"):Connect(renderPanel)
	end
	for _, other in Players:GetPlayers() do
		watch(other)
	end
	Players.PlayerAdded:Connect(function(other)
		watch(other)
		renderPanel()
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(renderPanel)
	end)
	render()
	-- The invite countdowns and nameplates stay current without a push.
	while true do
		task.wait(5)
		renderTags()
	end
end

return CrewController
