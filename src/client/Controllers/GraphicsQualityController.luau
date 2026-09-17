--!strict
--[[
	GraphicsQualityController
	What the Settings panel's "Graphics: LOW" does to the world, on this client
	only, and how it is undone.

	LOW
	  * Decorative lights in the museum zones are switched off: every Light
	    (PointLight / SpotLight / SurfaceLight) under a zone's `Decorations`
	    folder - the sconce lamps, vitrine glows - EXCEPT each room's
	    `RoomFill` light, which is what actually lights the room.
	  * Non-essential particles are switched off: ParticleEmitter / Sparkles /
	    Fire / Smoke under a zone's `Decorations` and its `Weather` part (the
	    rain, snow and dust).
	  * Trophy and crate spin stops (DisplayFx, WorldLootFx, ItemArtMotion read
	    Effects.isLowGraphics() themselves, including the item-art sparkles).
	Nothing that carries gameplay information is touched: loot, lasers,
	guardians, prompts, the Night barrier and every player effect are outside
	those folders.

	HIGH (the default)
	Only what LOW switched off is switched back on - an emitter the game had
	disabled for its own reason stays disabled.

	The folder names come from MuseumGallery.build / MapBuilder (Map.Zones.
	<zone>.Decorations, <zone>.Rooms.<side>.Decorations, <zone>.Weather).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Effects = require(ReplicatedStorage.Shared.Util.Effects)

local GraphicsQualityController = {}

--- A room's main light. Keeping it is what stops LOW from being "dark mode".
local KEEP_LIGHT_PARENTS: { [string]: true } = { RoomFill = true }

-- Everything LOW switched off, so HIGH restores exactly that.
local switchedOff: { [Instance]: true } = {}
local zonesFolder: Instance? = nil

local function isParticle(instance: Instance): boolean
	return instance:IsA("ParticleEmitter")
		or instance:IsA("Sparkles")
		or instance:IsA("Fire")
		or instance:IsA("Smoke")
end

local function isTarget(instance: Instance): boolean
	if instance:IsA("Light") then
		local parent = instance.Parent
		if parent and KEEP_LIGHT_PARENTS[parent.Name] then
			return false
		end
		return instance:FindFirstAncestor("Decorations") ~= nil
	end
	if isParticle(instance) then
		return instance:FindFirstAncestor("Decorations") ~= nil or instance:FindFirstAncestor("Weather") ~= nil
	end
	return false
end

local function switchOff(instance: Instance)
	if switchedOff[instance] or not isTarget(instance) then
		return
	end
	-- Only what is currently on, so HIGH never turns on something that was
	-- off for a reason of its own.
	local target = instance :: any
	if target.Enabled == true then
		target.Enabled = false
		switchedOff[instance] = true
	end
end

local function apply(low: boolean)
	local zones = zonesFolder
	if not zones then
		return
	end
	if low then
		-- One scan per toggle, not per frame.
		for _, descendant in zones:GetDescendants() do
			if descendant:IsA("Light") or isParticle(descendant) then
				switchOff(descendant)
			end
		end
	else
		for instance in switchedOff do
			if instance.Parent then
				(instance :: any).Enabled = true
			end
		end
		table.clear(switchedOff)
	end
end

function GraphicsQualityController.start()
	local map = workspace:WaitForChild("Map", 30)
	local zones = map and map:WaitForChild("Zones", 15)
	if not zones then
		return
	end
	zonesFolder = zones

	-- Decor that arrives while LOW is on (a rebuilt room) is switched off too.
	zones.DescendantAdded:Connect(function(descendant)
		if Effects.isLowGraphics() and (descendant:IsA("Light") or isParticle(descendant)) then
			-- Deferred: the ancestry (Decorations / Weather) may still be
			-- assembling in the same replication step.
			task.defer(function()
				if descendant.Parent and Effects.isLowGraphics() then
					switchOff(descendant)
				end
			end)
		end
	end)
	zones.DescendantRemoving:Connect(function(descendant)
		switchedOff[descendant] = nil
	end)

	-- Applies the current value now (the saved setting may already be in)
	-- and every change after.
	Effects.watchGraphics(apply)
end

return GraphicsQualityController
