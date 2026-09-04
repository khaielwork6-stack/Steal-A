--!strict
--[[
	EffectsController
	One-shot world VFX bursts, played on the client that earned them.

	THE LEVEL-UP ASSETS
	The pack's two "LVLUP!" parts turned out to be the same effect in two
	colourways - blue and gold - and neither contains any literal text, so
	nothing had to be stripped. Both are kept: gold for anything bought with
	Cash, blue for unlocks.

	Every emitter in them ships Enabled = false and is named "Emit-1" / "Emit-6".
	That is the author telling us the emit COUNT: these are burst effects driven
	by ParticleEmitter:Emit(n), not looping ones. Enabling them instead would
	produce a permanent fountain, so the name is parsed and used.

	Played client-side: a purchase effect is feedback for the buyer, and running
	it on the server would replicate twelve copies of it to everyone.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EffectsController = {}

local player = Players.LocalPlayer

-- Long enough for the slowest particle to finish, short enough to never pile up.
local CLEANUP_AFTER = 5

local templates: { [string]: BasePart } = {}

--- "Emit-6" -> 6. Falls back to a single puff if the name carries no count.
local function emitCount(emitter: ParticleEmitter): number
	local n = tonumber(string.match(emitter.Name, "(%d+)$"))
	return if n and n > 0 then n else 1
end

--- Plays a burst at a world position. `variant` picks the colourway.
function EffectsController.burst(variant: string, position: Vector3)
	local template = templates[variant] or templates.Gold or templates.Blue
	if not template then
		return
	end

	local effect = template:Clone()
	effect.Name = "Burst"
	effect.Anchored = true
	effect.CanCollide = false
	effect.CanQuery = false
	effect.CanTouch = false
	effect.Transparency = 1
	effect.CFrame = CFrame.new(position)
	effect.Parent = workspace

	for _, descendant in effect:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			-- Emit() ignores Enabled, but a disabled emitter that is later
			-- toggled would spew; leave it false and fire the burst explicitly.
			descendant:Emit(emitCount(descendant))
		end
	end

	Debris:AddItem(effect, CLEANUP_AFTER)
end

--- Convenience: burst on the local character, which is where the player is
--- looking when they buy something.
function EffectsController.burstOnPlayer(variant: string)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		EffectsController.burst(variant, root.Position + Vector3.new(0, 1.5, 0))
	end
end

function EffectsController.start()
	local assets = ReplicatedStorage:WaitForChild("GameAssets", 20)
	local folder = assets and assets:FindFirstChild("Effects")
	if not folder then
		warn("[EffectsController] ReplicatedStorage.GameAssets.Effects missing - bursts disabled.")
		return
	end

	for _, name in { "Gold", "Blue" } do
		local template = folder:FindFirstChild("LevelUp" .. name)
		if template and template:IsA("BasePart") then
			templates[name] = template
		end
	end
end

return EffectsController
