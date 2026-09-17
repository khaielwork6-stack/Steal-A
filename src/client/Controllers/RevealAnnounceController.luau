--!strict
--[[
	RevealAnnounceController
	The server-wide "X pulled a DIVINE Private Jet!" moment.

	The server sends RevealAnnounce at the SWAP of a Mythic-or-better reveal
	(never at the commit), so by the time this draws, the revealer's own
	roulette has already landed. Display only.

	  * A banner, top-centre, ANNOUNCE_BANNER_SECONDS each, one at a time.
	    Bursts queue; beyond ANNOUNCE_QUEUE_MAX the oldest waiting banner is
	    dropped. The revealer does not get a banner for their own reveal (they
	    are watching the full reveal already).
	  * A system line in the general chat channel (TextChatService only),
	    for everyone including the revealer.
	  * Reduced Effects: the banner appears and disappears with no slide or
	    fade.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)
local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local RevealAnnounceController = {}

local player = Players.LocalPlayer

type Announcement = { userId: number, name: string, itemName: string, rarity: string, mutation: string }

local queue: { Announcement } = {}
local showing = false

local banner: Frame? = nil
local bannerText: TextLabel? = nil
local bannerStroke: UIStroke? = nil

local SLIDE = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local REST = UDim2.fromScale(0.5, 0.14)
local HIDDEN = UDim2.new(0.5, 0, 0.14, -30)

local function escape(text: string): string
	return (string.gsub(text, "[&<>\"']", {
		["&"] = "&amp;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		['"'] = "&quot;",
		["'"] = "&apos;",
	}))
end

local function hex(color: Color3): string
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

--- "<b>Name</b> pulled a <font>DIVINE</font> Golden Private Jet!"
local function richLine(entry: Announcement): string
	local color = RarityConfig.Colors[entry.rarity] or Color3.new(1, 1, 1)
	local what = entry.itemName
	if entry.mutation ~= "Normal" and entry.mutation ~= "" then
		what = `{entry.mutation} {what}`
	end
	local article = "a"
	local first = string.sub(entry.rarity, 1, 1)
	if string.find("AEIOU", first, 1, true) then
		article = "an"
	end
	return `<b>{escape(entry.name)}</b> pulled {article} <font color="{hex(color)}"><b>{string.upper(escape(entry.rarity))}</b></font> {escape(what)}!`
end

local function buildBanner(): Frame
	local gui = Instance.new("ScreenGui")
	gui.Name = "RevealAnnounceUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 40
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Banner"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = REST
	frame.Size = UDim2.new(0.5, 0, 0, 52)
	frame.BackgroundColor3 = Color3.fromRGB(14, 16, 32)
	frame.BackgroundTransparency = 0.1
	frame.Visible = false
	frame.Parent = gui
	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = Vector2.new(300, 44)
	limit.MaxSize = Vector2.new(640, 60)
	limit.Parent = frame
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, 14)
	round.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	bannerStroke = stroke

	if SocialConfig.ANNOUNCE_FRAME_IMAGE ~= "" and SocialConfig.ANNOUNCE_FRAME_IMAGE ~= "rbxassetid://0" then
		local art = Instance.new("ImageLabel")
		art.Name = "FrameArt"
		art.BackgroundTransparency = 1
		art.Image = SocialConfig.ANNOUNCE_FRAME_IMAGE
		art.ScaleType = Enum.ScaleType.Slice
		art.SliceCenter = Rect.new(64, 64, 448, 448)
		art.Size = UDim2.fromScale(1, 1)
		art.ZIndex = 1
		art.Parent = frame
		frame.BackgroundTransparency = 1
	end

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -24, 1, -8)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Font = Enum.Font.GothamBold
	label.RichText = true
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.ZIndex = 2
	label.Parent = frame
	local textLimit = Instance.new("UITextSizeConstraint")
	textLimit.MinTextSize = 12
	textLimit.MaxTextSize = 24
	textLimit.Parent = label
	local textStroke = Instance.new("UIStroke")
	textStroke.Thickness = 1.5
	textStroke.Color = Color3.new(0, 0, 0)
	textStroke.Parent = label
	bannerText = label

	return frame
end

local function show(entry: Announcement)
	local frame = banner
	local label = bannerText
	if not frame or not label then
		return
	end
	label.Text = richLine(entry)
	if bannerStroke then
		bannerStroke.Color = RarityConfig.Colors[entry.rarity] or Color3.new(1, 1, 1)
	end
	local reduced = Effects.isReduced()
	frame.BackgroundTransparency = if frame:FindFirstChild("FrameArt") then 1 else 0.1
	label.TextTransparency = 0
	if reduced then
		frame.Position = REST
		frame.Visible = true
		task.wait(SocialConfig.ANNOUNCE_BANNER_SECONDS)
		frame.Visible = false
		return
	end
	frame.Position = HIDDEN
	frame.Visible = true
	TweenService:Create(frame, SLIDE, { Position = REST }):Play()
	task.wait(SocialConfig.ANNOUNCE_BANNER_SECONDS)
	TweenService:Create(label, FADE, { TextTransparency = 1 }):Play()
	local out = TweenService:Create(frame, FADE, { Position = HIDDEN })
	out:Play()
	out.Completed:Wait()
	frame.Visible = false
end

local function pump()
	if showing then
		return
	end
	showing = true
	while #queue > 0 do
		local entry = table.remove(queue, 1) :: Announcement
		local ok: boolean, err: any = (pcall :: any)(show, entry)
		if not ok then
			warn(`[RevealAnnounceController] banner failed: {err}`)
		end
		task.wait(0.2)
	end
	showing = false
end

local function postChat(entry: Announcement)
	if not SocialConfig.ANNOUNCE_CHAT_MESSAGE then
		return
	end
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return
	end
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	if not general or not general:IsA("TextChannel") then
		return
	end
	local ok, err = pcall(general.DisplaySystemMessage, general, richLine(entry))
	if not ok then
		warn(`[RevealAnnounceController] chat line failed: {err}`)
	end
end

local function sanitise(payload: any): Announcement?
	if type(payload) ~= "table" then
		return nil
	end
	local rarity = if type(payload.rarity) == "string" then payload.rarity else ""
	if RarityConfig.Rank[rarity] == nil then
		return nil
	end
	return {
		userId = tonumber(payload.userId) or 0,
		name = if type(payload.name) == "string" then payload.name else "Someone",
		itemName = if type(payload.itemName) == "string" then payload.itemName else "item",
		rarity = rarity,
		mutation = if type(payload.mutation) == "string" then payload.mutation else "Normal",
	}
end

function RevealAnnounceController.start()
	banner = buildBanner()
	Remotes.get("RevealAnnounce").OnClientEvent:Connect(function(payload)
		local entry = sanitise(payload)
		if not entry then
			return
		end
		postChat(entry)
		if entry.userId == player.UserId then
			return
		end
		table.insert(queue, entry)
		while #queue > SocialConfig.ANNOUNCE_QUEUE_MAX do
			table.remove(queue, 1)
		end
		task.spawn(pump)
	end)
end

return RevealAnnounceController
