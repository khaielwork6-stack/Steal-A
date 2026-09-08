--!strict
--[[
	PortalService
	The two portals the owner dropped into the place:

	  World2Portal   the fire ring in the lobby corner. World 2 is not out, so
	                 it teleports nobody: it wears a WORLD 2 / COMING SOON
	                 sign and answers a touch with one polished notice.
	  Backtobase     at the far end of the lane. A real shortcut home - the
	                 same teleport the base button used - refused while the
	                 player carries ANY item, zone loot or a stolen trophy,
	                 because carrying it home on foot is the whole game.

	Both are touched, not prompted, and both are debounced per player so
	standing inside one produces one message, not a stream.

	The portal parts themselves were placed by hand and are left where they
	are. The only geometry touched is what makes them work: collision off so
	a player can walk into them, and the back-to-base cube seated on the
	floor (it had been dropped at fifteen studs, out of reach).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseService = require(script.Parent.BaseService)
local CarryService = require(script.Parent.CarryService)
local StateService = require(script.Parent.StateService)

local PortalService = {}

local WORLD2_NAME = "World2Portal"
local BACK_NAME = "Backtobase"
local WORLD2_DEBOUNCE = 4
local BACK_DEBOUNCE = 3
local CARRY_DEBOUNCE = 3
--- A portal whose underside is higher than this off the floor cannot be
--- walked into; it is re-seated.
local REACHABLE_HEIGHT = 6

local lastWorld2: { [Player]: number } = {}
local lastBack: { [Player]: number } = {}
local lastCarryRefusal: { [Player]: number } = {}

local function playerFromHit(hit: BasePart): Player?
	local character = hit:FindFirstAncestorWhichIsA("Model")
	return if character then Players:GetPlayerFromCharacter(character) else nil
end

local function makeTouchable(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = true
end

local function sign(part: BasePart, title: string, sub: string, titleColor: Color3, subColor: Color3, lift: number, name: string)
	local existing = part:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Size = UDim2.fromScale(20, 8)
	gui.StudsOffsetWorldSpace = Vector3.new(0, lift, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 240
	gui.Adornee = part
	gui.Parent = part

	local top = Instance.new("TextLabel")
	top.Name = "Title"
	top.Size = UDim2.fromScale(1, 0.58)
	top.BackgroundTransparency = 1
	top.Font = Enum.Font.FredokaOne
	top.TextScaled = true
	top.TextColor3 = titleColor
	top.TextStrokeTransparency = 0
	top.TextStrokeColor3 = Color3.fromRGB(24, 10, 40)
	top.Text = title
	top.Parent = gui
	-- The client (PortalController) sweeps a rainbow across this gradient.
	local gradient = Instance.new("UIGradient")
	gradient.Name = "Rainbow"
	gradient.Parent = top

	local bottom = Instance.new("TextLabel")
	bottom.Name = "Sub"
	bottom.Size = UDim2.fromScale(1, 0.36)
	bottom.Position = UDim2.fromScale(0, 0.62)
	bottom.BackgroundTransparency = 1
	bottom.Font = Enum.Font.FredokaOne
	bottom.TextScaled = true
	bottom.TextColor3 = subColor
	bottom.TextStrokeTransparency = 0.1
	bottom.TextStrokeColor3 = Color3.fromRGB(24, 10, 40)
	bottom.Text = sub
	bottom.Parent = gui
end

local function glow(part: BasePart, color: Color3, range: number)
	local existing = part:FindFirstChild("PortalGlow")
	if existing then
		existing:Destroy()
	end
	local light = Instance.new("PointLight")
	light.Name = "PortalGlow"
	light.Color = color
	light.Brightness = 1.3
	light.Range = range
	light.Shadows = false
	light.Parent = part
end

local function setupWorld2(part: BasePart)
	makeTouchable(part)
	part:SetAttribute("Portal", "World2")
	sign(part, "WORLD 2", "COMING SOON", Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 226, 120), part.Size.Y / 2 + 4.5, "ComingSoonSign")
	glow(part, Color3.fromRGB(255, 150, 60), 24)

	part.Touched:Connect(function(hit)
		local player = playerFromHit(hit)
		if not player then
			return
		end
		local now = os.clock()
		if now - (lastWorld2[player] or 0) < WORLD2_DEBOUNCE then
			return
		end
		lastWorld2[player] = now
		StateService.notify(player, "info", "WORLD 2 — COMING SOON!", "refresh")
	end)
end

local function setupBack(part: BasePart)
	makeTouchable(part)
	part:SetAttribute("Portal", "BackToBase")

	-- Reachable: its underside on the floor it stands over.
	local bottom = part.Position.Y - part.Size.Y / 2
	if bottom > REACHABLE_HEIGHT then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { part }
		local hit = workspace:Raycast(part.Position, Vector3.new(0, -200, 0), params)
		local floorY = if hit then hit.Position.Y else 0
		part.CFrame = CFrame.new(part.Position.X, floorY + part.Size.Y / 2 + 0.5, part.Position.Z) * part.CFrame.Rotation
		warn(`[PortalService] {BACK_NAME} was {math.floor(bottom)} studs in the air - seated on the floor at {part.Position}`)
	end

	sign(part, "BACK TO BASE", "Walk in to return home", Color3.fromRGB(255, 255, 255), Color3.fromRGB(180, 255, 200), part.Size.Y / 2 + 4, "BackSign")
	glow(part, Color3.fromRGB(120, 255, 160), 20)

	part.Touched:Connect(function(hit)
		local player = playerFromHit(hit)
		if not player then
			return
		end
		local now = os.clock()

		-- THE SERVER decides whether they are carrying; the client's opinion
		-- is not asked. Any carried state at all refuses: zone loot, a base
		-- steal, whatever CarryService is holding for them.
		if CarryService.getCarried(player) then
			if now - (lastCarryRefusal[player] or 0) >= CARRY_DEBOUNCE then
				lastCarryRefusal[player] = now
				StateService.notify(player, "error", "You can't teleport while carrying an item!")
			end
			return
		end

		if now - (lastBack[player] or 0) < BACK_DEBOUNCE then
			return
		end
		lastBack[player] = now

		local ok, reason = BaseService.teleportHome(player)
		if ok then
			Remotes.get("PortalFx"):FireClient(player, "teleport")
			StateService.notify(player, "success", "Back to base!")
		elseif reason then
			StateService.notify(player, "error", reason)
		end
	end)
end

function PortalService.start()
	local world2 = workspace:FindFirstChild(WORLD2_NAME)
	if world2 and world2:IsA("BasePart") then
		setupWorld2(world2)
	else
		warn(`[PortalService] no {WORLD2_NAME} part in the workspace`)
	end

	local back = workspace:FindFirstChild(BACK_NAME)
	if back and back:IsA("BasePart") then
		setupBack(back)
	else
		warn(`[PortalService] no {BACK_NAME} part in the workspace`)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastWorld2[player] = nil
		lastBack[player] = nil
		lastCarryRefusal[player] = nil
	end)

	print("[PortalService] portals online")
end

return PortalService
