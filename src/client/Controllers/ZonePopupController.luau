--!strict
--[[
	ZonePopupController
	"Gym 💪" at the top of the screen when the player walks into a zone.

	GEOMETRY, NOT NETWORK. The lane is a straight run of twelve bands along +Z
	(MapConfig.zoneStartZ / zoneEndZ), so which zone the character is in is a
	comparison the client can make for free; no remote, no server work. The
	pop-up is one of the pack's own toasts (ToastController) with a zone colour
	treatment, so it is the same shape and motion as everything else up there.

	DEBOUNCED ON PURPOSE. A zone counts as entered only after the character has
	been inside it for SETTLE_SECONDS without leaving, and the same zone is not
	announced again until the player has genuinely been somewhere else - the
	lobby, or another zone. Dancing on a boundary shows nothing; a transition
	strip between two zones belongs to neither.

	A steal or a chase can drop other toasts into the same stack; the list
	layout handles that, and this one's short dwell keeps it out of the way.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)
local ToastController = require(script.Parent.ToastController)

local ZonePopupController = {}

local player = Players.LocalPlayer

--- How long the character must stay in a zone before it counts as entered.
local SETTLE_SECONDS = 0.45
--- How far inside a zone's band the character must be: keeps the transition
--- strips and the exact boundary lines from flapping the reading.
local EDGE_INSET = 3
--- How often the position is sampled.
local SAMPLE_INTERVAL = 0.12

local candidate: number? = nil
local candidateSince = 0
local announced: number? = nil
local accumulator = 0

--- Which zone a world position is inside, or nil (lobby, walls, a transition
--- strip, or the Night lobby).
local function zoneAt(position: Vector3): number?
	if math.abs(position.X) > MapConfig.LANE_HALF then
		return nil
	end
	local z = position.Z
	if z < EDGE_INSET then
		return nil
	end
	for index = 1, ZoneConfig.COUNT do
		if z >= MapConfig.zoneStartZ(index) + EDGE_INSET and z <= MapConfig.zoneEndZ(index) - EDGE_INSET then
			return index
		end
	end
	return nil
end

local function announce(index: number)
	local zone = ZoneConfig.Zones[index]
	if not zone then
		return
	end
	ToastController.show("info", `{zone.name} {zone.emoji}`, "zone")
end

local function sample()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		candidate = nil
		return
	end

	local now = os.clock()
	local here = zoneAt(root.Position)
	if here ~= candidate then
		candidate = here
		candidateSince = now
		return
	end
	-- Out of every zone for the settle time: the next zone entered is new
	-- again, even if it is the one just left.
	if here == nil then
		if now - candidateSince >= SETTLE_SECONDS then
			announced = nil
		end
		return
	end
	if here ~= announced and now - candidateSince >= SETTLE_SECONDS then
		announced = here
		announce(here)
	end
end

function ZonePopupController.start()
	player.CharacterAdded:Connect(function()
		candidate = nil
		announced = nil
	end)
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < SAMPLE_INTERVAL then
			return
		end
		accumulator = 0
		sample()
	end)
end

return ZonePopupController
