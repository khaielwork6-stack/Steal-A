--!strict
--[[
	PortalController
	The client's share of the two portals (PortalService owns the rules):

	  * World2Portal turns slowly in its own plane, its light breathes, and
	    the WORLD 2 / COMING SOON sign carries a moving rainbow and a gentle
	    float. All local: an anchored part's CFrame set on this client, one
	    gradient offset, one BillboardGui offset - no replication, no tweens
	    piling up.
	  * Backtobase floats its sign and breathes its light the same way.
	  * `PortalFx("teleport")` from the server: a short black dip that covers
	    the cut when the back-to-base portal moves the character.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local PortalController = {}

local player = Players.LocalPlayer

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 106, 122)),
	ColorSequenceKeypoint.new(0.18, Color3.fromRGB(255, 176, 92)),
	ColorSequenceKeypoint.new(0.36, Color3.fromRGB(255, 238, 120)),
	ColorSequenceKeypoint.new(0.54, Color3.fromRGB(122, 236, 148)),
	ColorSequenceKeypoint.new(0.72, Color3.fromRGB(112, 196, 255)),
	ColorSequenceKeypoint.new(0.86, Color3.fromRGB(186, 142, 255)),
	ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 106, 122)),
})
local RAINBOW_PERIOD = 4
local SPIN = 0.35 -- radians per second, the ring in its own plane
local FLOAT = 0.6 -- studs of sign float

type Portal = {
	part: BasePart,
	base: CFrame,
	spin: boolean,
	sign: BillboardGui?,
	signRest: Vector3?,
	gradient: UIGradient?,
	light: PointLight?,
	phase: number,
}

local portals: { Portal } = {}
local fade: Frame? = nil

local function adopt(part: BasePart, signName: string, spin: boolean)
	-- Recursive: the sign hangs off its own non-rotating anchor part now, so it
	-- is a grandchild of the portal rather than a child. See PortalService -
	-- a billboard adorned to the SPINNING ring orbited it instead of sitting
	-- over it.
	local sign = part:FindFirstChild(signName, true)
	local title = sign and sign:FindFirstChild("Title")
	local gradient = title and title:FindFirstChild("Rainbow")
	if gradient and gradient:IsA("UIGradient") then
		gradient.Color = RAINBOW
	end
	local light = part:FindFirstChild("PortalGlow")
	table.insert(portals, {
		part = part,
		base = part.CFrame,
		spin = spin,
		sign = if sign and sign:IsA("BillboardGui") then sign else nil,
		signRest = if sign and sign:IsA("BillboardGui") then sign.StudsOffsetWorldSpace else nil,
		gradient = if gradient and gradient:IsA("UIGradient") then gradient else nil,
		light = if light and light:IsA("PointLight") then light else nil,
		phase = math.random() * math.pi * 2,
	})
end

--- The server dresses a portal on start; a client that arrives later finds
--- it dressed, one that arrives first waits for the sign.
local function watchPortal(name: string, signName: string, spin: boolean)
	task.spawn(function()
		local part = workspace:WaitForChild(name, 120)
		if not part or not part:IsA("BasePart") then
			return
		end
		-- The sign is nested under its anchor, so WaitForChild cannot see it.
		-- Poll briefly instead; the server dresses the portal at start-up.
		local deadline = os.clock() + 60
		while not part:FindFirstChild(signName, true) and os.clock() < deadline do
			task.wait(0.25)
		end
		adopt(part, signName, spin)
	end)
end

local function tick()
	local now = os.clock()
	for _, portal in portals do
		local part = portal.part
		if not part.Parent then
			continue
		end
		if portal.spin then
			-- The ring is thin along its X; turning about that axis spins it
			-- in its own plane.
			part.CFrame = portal.base * CFrame.Angles(now * SPIN, 0, 0)
		end
		if portal.sign and portal.signRest then
			portal.sign.StudsOffsetWorldSpace = portal.signRest + Vector3.new(0, math.sin(now * 1.3 + portal.phase) * FLOAT, 0)
		end
		if portal.gradient then
			local t = now / RAINBOW_PERIOD
			portal.gradient.Offset = Vector2.new((t % 1) * 2 - 1, 0)
			portal.gradient.Rotation = math.sin(t * math.pi * 2) * 10
		end
		if portal.light then
			portal.light.Brightness = 1.3 + math.sin(now * 2.2 + portal.phase) * 0.45
		end
	end
end

local function buildFade(): Frame
	local existing = fade
	if existing and existing.Parent then
		return existing
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "PortalFade"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = player:WaitForChild("PlayerGui")
	local frame = Instance.new("Frame")
	frame.Name = "Dip"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(6, 10, 20)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Parent = gui
	fade = frame
	return frame
end

--- A quick dip to black and back over the teleport.
local function teleportDip()
	local frame = buildFade()
	frame.BackgroundTransparency = 0.15
	Audio.play("UiOpen")
	TweenService:Create(frame, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
end

function PortalController.start()
	watchPortal("World2Portal", "ComingSoonSign", true)
	watchPortal("Backtobase", "BackSign", false)

	Remotes.get("PortalFx").OnClientEvent:Connect(function(kind)
		if kind == "teleport" then
			teleportDip()
		end
	end)

	RunService.RenderStepped:Connect(tick)
end

return PortalController
