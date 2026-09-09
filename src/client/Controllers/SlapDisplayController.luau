--!strict
--[[
	SlapDisplayController
	The Slap in its lobby cage, alive: the hand-on-a-stick turns slowly and
	bobs, SLAM! sweeps a rainbow, and the prompt says Buy / Owned / Equipped
	for THIS player from StatePush.

	The three display parts (the invisible Item, the Hand and the Stick) are
	anchored on the server; their offsets from the Item are measured once and
	re-applied around a turning base every frame, locally. Nothing drifts:
	the motion is a function of time from a fixed origin, never accumulated.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local SlapDisplayController = {}

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
local RAINBOW_PERIOD = 3.4
local TURN_SPEED = 0.6
local BOB = 0.35

local display: Model? = nil
local origin: CFrame? = nil
local parts: { { part: BasePart, offset: CFrame } } = {}
local gradient: UIGradient? = nil
local latest: any = nil

local function prompt(): ProximityPrompt?
	local anchor = display and display:FindFirstChild("PromptAnchor")
	local found = anchor and anchor:FindFirstChild("SlapBuyPrompt")
	return if found and found:IsA("ProximityPrompt") then found else nil
end

local function paintPrompt()
	local p = prompt()
	if not p or type(latest) ~= "table" or type(latest.weapons) ~= "table" then
		return
	end
	local weapons = latest.weapons
	if not (weapons.owned and weapons.owned.Slap) then
		p.ActionText = "Buy"
	elseif weapons.equipped == "Slap" then
		p.ActionText = "Equipped"
	else
		p.ActionText = "Owned"
	end
end

local function attach(model: Model)
	display = model
	local item = model:FindFirstChild("Item")
	if item and item:IsA("BasePart") then
		origin = item.CFrame
		parts = { { part = item, offset = CFrame.identity } }
		for _, child in item:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(parts, { part = child, offset = item.CFrame:ToObjectSpace(child.CFrame) })
			end
		end
	end

	local function findGradient()
		local anchor = model:FindFirstChild("SignAnchor")
		local sign = anchor and anchor:FindFirstChild("Sign")
		local slam = sign and sign:FindFirstChild("Slam")
		local found = slam and slam:FindFirstChild("Rainbow")
		if found and found:IsA("UIGradient") then
			found.Color = RAINBOW
			gradient = found
		end
	end
	findGradient()
	if not gradient then
		model.DescendantAdded:Connect(function(descendant)
			if descendant.Name == "Rainbow" and not gradient then
				task.defer(findGradient)
			end
		end)
	end
	paintPrompt()
end

function SlapDisplayController.start()
	Remotes.get("StatePush").OnClientEvent:Connect(function(state)
		if type(state) == "table" then
			latest = state
			paintPrompt()
		end
	end)

	task.spawn(function()
		local found = workspace:WaitForChild("Slap", 120)
		if found and found:IsA("Model") then
			-- The server dresses it a moment after start; the prompt and the
			-- sign may land after the model itself.
			if not found:FindFirstChild("PromptAnchor") then
				found:WaitForChild("PromptAnchor", 60)
			end
			attach(found)
		end
	end)

	RunService.RenderStepped:Connect(function()
		local base = origin
		if not base or #parts == 0 then
			return
		end
		local now = os.clock()
		-- Turn and bob in WORLD axes. `base` is the import's own frame, whose
		-- local Y is not up (the hand is authored on its side), so spinning
		-- about local Y rolled the hand under the disc. A world-Y yaw about
		-- the item's position keeps it standing and turning a full 360.
		local frame = CFrame.new(base.Position + Vector3.new(0, math.sin(now * 1.5) * BOB, 0))
			* CFrame.Angles(0, now * TURN_SPEED, 0)
			* base.Rotation
		for _, entry in parts do
			if entry.part.Parent then
				entry.part.CFrame = frame * entry.offset
			end
		end
		if gradient then
			local t = now / RAINBOW_PERIOD
			gradient.Offset = Vector2.new((t % 1) * 2 - 1, 0)
			gradient.Rotation = math.sin(t * math.pi * 2) * 12
		end
	end)
end

return SlapDisplayController
