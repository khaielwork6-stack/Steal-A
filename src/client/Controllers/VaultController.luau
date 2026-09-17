--!strict
--[[
	VaultController
	Draws the zone vaults (vaults-crews). Presentation only - the server
	decides who may enter, what is stolen and when a vault restocks.

	  DOOR      slides aside while the vault's `DoorOpen` attribute is true.
	  BARRIER   the doorway's invisible `VaultBarrier` never collides on the
	            server. Here it is made solid LOCALLY when this player lacks
	            the zone's Speed (or the door is forced shut), so an honest
	            client is simply stopped at the door. The server ejects anyone
	            who gets in anyway.
	  LASERS    each `VaultBeam` is posed every frame from its attributes and
	            the server clock (LaserGeometry.sweepAt), the same function the
	            server tests. Only vaults near the camera are animated.
	  SIGN      the plaque's status line: needs X Speed / restocks in m:ss.
	  BANNER    the "vault restocked" image (VaultConfig.Art.RestockBanner)
	            with the restock toast, once the art exists.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)
local Geometry = require(ReplicatedStorage.Shared.Util.LaserGeometry)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIAnim = require(ReplicatedStorage.Shared.Util.UIAnim)
local VaultConfig = require(ReplicatedStorage.Shared.Config.VaultConfig)
local StateStore = require(script.Parent.Parent.StateStore)

local VaultController = {}

local player = Players.LocalPlayer

--- Beyond this the arms are not animated (they are inside a closed room).
local ANIMATE_RANGE = 260

type Beam = { part: BasePart, arm: Geometry.SweepArm }
type Entry = {
	folder: Instance,
	barrier: BasePart?,
	door: Model?,
	closedPivot: CFrame?,
	doorValue: CFrameValue?,
	beams: { Beam },
	center: Vector3,
	status: TextLabel?,
}

local entries: { Entry } = {}
local speedPower = 0

local function qualifies(entry: Entry): boolean
	local required = tonumber(entry.folder:GetAttribute("RequiredSpeed")) or math.huge
	return speedPower >= required
end

local function refreshBarrier(entry: Entry)
	local barrier = entry.barrier
	if not barrier then
		return
	end
	local forced = entry.folder:GetAttribute("DoorForced")
	local solid = if forced == "closed" then true elseif forced == "open" then false else not qualifies(entry)
	barrier.CanCollide = solid
end

local function refreshDoor(entry: Entry)
	local door, closed, value = entry.door, entry.closedPivot, entry.doorValue
	if not door or not closed or not value then
		return
	end
	local open = entry.folder:GetAttribute("DoorOpen") == true
	local slide = tonumber(door:GetAttribute("SlideDistance")) or 20
	local target = if open then closed * CFrame.new(slide, 0, 0) else closed
	if Effects.isReduced() then
		value.Value = target
	else
		TweenService:Create(value, TweenInfo.new(if open then 0.9 else 1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Value = target }):Play()
	end
end

local function formatClock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function refreshSign(entry: Entry)
	local label = entry.status
	if not label then
		return
	end
	local required = tonumber(entry.folder:GetAttribute("RequiredSpeed")) or 0
	local need = if required > 0 then `NEEDS {NumberFormat.short(required)} SPEED` else "OPEN TO ALL"
	if not VaultConfig.ENABLED then
		label.Text = "CLOSED"
	elseif entry.folder:GetAttribute("Stocked") == true then
		label.Text = `STOCKED - {need}`
	else
		local at = tonumber(entry.folder:GetAttribute("RestockAt")) or 0
		label.Text = if at > 0 then `RESTOCKS IN {formatClock(at - workspace:GetServerTimeNow())}` else "EMPTY"
	end
	label.TextColor3 = if qualifies(entry) then Color3.fromRGB(140, 255, 160) else Color3.fromRGB(255, 150, 140)
end

local function register(folder: Instance)
	local door = folder:FindFirstChild("Door")
	local barrier = folder:FindFirstChild("VaultBarrier")
	local entry: Entry = {
		folder = folder,
		barrier = if barrier and barrier:IsA("BasePart") then barrier else nil,
		door = if door and door:IsA("Model") then door else nil,
		beams = {},
		center = Vector3.zero,
	}
	local socket = folder:FindFirstChild("SpawnSockets")
	local anchor = socket and socket:FindFirstChildWhichIsA("BasePart")
	entry.center = if anchor then anchor.Position else (if entry.barrier then entry.barrier.Position else Vector3.zero)
	if entry.door then
		local model = entry.door :: Model
		local closed = model:GetPivot()
		entry.closedPivot = closed
		local value = Instance.new("CFrameValue")
		value.Value = closed
		value.Changed:Connect(function(cf: CFrame)
			model:PivotTo(cf)
		end)
		entry.doorValue = value
	end
	local lasers = folder:FindFirstChild("Lasers")
	local parts: { Instance } = if lasers then lasers:GetChildren() else {}
	for _, part in parts do
		if not part:IsA("BasePart") then
			continue
		end
		local pivot = part:GetAttribute("Pivot")
		if typeof(pivot) ~= "Vector3" then
			continue
		end
		table.insert(entry.beams, {
			part = part,
			arm = {
				pivot = pivot,
				inner = tonumber(part:GetAttribute("Inner")) or 0,
				outer = tonumber(part:GetAttribute("Outer")) or 0,
				height = tonumber(part:GetAttribute("Height")) or 0,
				period = tonumber(part:GetAttribute("Period")) or 0,
				phase = tonumber(part:GetAttribute("Phase")) or 0,
				onSeconds = tonumber(part:GetAttribute("OnSeconds")),
				offSeconds = tonumber(part:GetAttribute("OffSeconds")),
			},
		})
	end
	local decorations = folder:FindFirstChild("Decorations")
	local plate = decorations and decorations:FindFirstChild("Sign")
	local gui = plate and plate:FindFirstChildOfClass("SurfaceGui")
	local status = gui and gui:FindFirstChild("Status")
	entry.status = if status and status:IsA("TextLabel") then status else nil

	folder:GetAttributeChangedSignal("DoorOpen"):Connect(function()
		refreshDoor(entry)
	end)
	folder:GetAttributeChangedSignal("DoorForced"):Connect(function()
		refreshBarrier(entry)
	end)
	for _, name in { "Stocked", "RestockAt" } do
		folder:GetAttributeChangedSignal(name):Connect(function()
			refreshSign(entry)
		end)
	end
	table.insert(entries, entry)
	refreshBarrier(entry)
	refreshDoor(entry)
	refreshSign(entry)
end

local function animate()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local now = workspace:GetServerTimeNow()
	for _, entry in entries do
		if (entry.center - eye).Magnitude > ANIMATE_RANGE then
			continue
		end
		for _, beam in entry.beams do
			local lit = Geometry.sweepLit(beam.arm, now)
			beam.part.Transparency = if lit then 0 else 1
			if lit then
				local a, b = Geometry.sweepAt(beam.arm, now)
				beam.part.CFrame = CFrame.lookAt((a + b) / 2, b)
			end
		end
	end
end

--- The restock banner, once Codex has made it.
local function showBanner()
	local image = VaultConfig.Art.RestockBanner
	if image == "rbxassetid://0" or image == "" then
		return
	end
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then
		return
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "VaultRestockBanner"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 5
	local banner = Instance.new("ImageLabel")
	banner.BackgroundTransparency = 1
	banner.Image = image
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.fromScale(0.5, 0.12)
	banner.Size = UDim2.fromScale(0.42, 0.14)
	banner.ScaleType = Enum.ScaleType.Fit
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 4
	aspect.Parent = banner
	banner.Parent = screen
	screen.Parent = gui
	UIAnim.popIn(banner)
	task.delay(2.8, function()
		UIAnim.popOut(banner)
		task.delay(0.4, function()
			screen:Destroy()
		end)
	end)
end

function VaultController.start()
	StateStore.onKeyChanged("speedPower", function(value)
		speedPower = tonumber(value) or 0
		for _, entry in entries do
			refreshBarrier(entry)
			refreshSign(entry)
		end
	end)

	Remotes.get("Notify").OnClientEvent:Connect(function(_kind: string, _message: string, detail: any)
		if detail == "vault" then
			showBanner()
		end
	end)

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 60)
		local zones = map and map:WaitForChild("Zones", 30)
		if not zones then
			return
		end
		-- Every zone folder replicates with the map; give late ones a moment.
		for _, zone in zones:GetChildren() do
			local folder = zone:WaitForChild("Vault", 10)
			if folder then
				register(folder)
			end
		end
		RunService.RenderStepped:Connect(animate)
		while true do
			task.wait(1)
			for _, entry in entries do
				if (tonumber(entry.folder:GetAttribute("RestockAt")) or 0) > 0 then
					refreshSign(entry)
				end
			end
		end
	end)
end

return VaultController
