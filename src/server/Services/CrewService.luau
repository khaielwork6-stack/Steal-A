--!strict
--[[
	CrewService
	Crew heists (vaults-crews area; docs/handoff-parts/vaults-crews.md).

	A CREW is up to CrewConfig.MAX_MEMBERS players in this server. Anyone may
	invite a player who is not in a crew; accepting creates the crew (the
	inviter leads it) or joins the inviter's. A crew's leader invites and
	kicks; anyone may leave. When fewer than two members remain the crew is
	dissolved. Nothing is saved: a crew lives for the session, and the server
	only remembers each player's last crew mates so the panel can mark them.

	The crew is replicated two ways:
	  * the Player attribute `CrewId` (everyone sees it: nameplate tags,
	    and the Rob prompt is hidden between crew mates);
	  * the StatePush field `crew` (provider, wired in init) with the member
	    list and this player's open invites.

	CREW ASSIST: see CrewConfig. Driven by ProgressEvents "delivered" (fired
	by CarryService.consumeCarry). Crew mates never rob each other
	(HeistService.areCrewmates).

	Remote: CrewRequest(action, targetUserId?) - action is one of
	"invite" | "accept" | "decline" | "leave" | "kick". Validated and
	rate-limited here; the client never names a crew, only a player.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrewConfig = require(ReplicatedStorage.Shared.Config.CrewConfig)
local MapConfig = require(ReplicatedStorage.Shared.MapConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Validate = require(ReplicatedStorage.Shared.Util.Validate)

local EconomyService = require(script.Parent.EconomyService)
local GuardianService = require(script.Parent.GuardianService)
local ProgressEvents = require(script.Parent.ProgressEvents)
local StateService = require(script.Parent.StateService)

local CrewService = {}

type Crew = { id: string, leader: Player, members: { Player } }

local crews: { [string]: Crew } = {}
local crewOf: { [Player]: Crew? } = {}
--- invitee -> inviter -> os.clock the invite expires
local invites: { [Player]: { [Player]: number } } = {}
--- userId -> the user ids of their last crew mates (session memory only)
local lastCrew: { [number]: { number } } = {}
--- player -> zone -> os.clock last seen inside that zone
local presence: { [Player]: { [number]: number } } = {}
--- player -> zone -> os.clock last chased by that zone's guard
local chasedIn: { [Player]: { [number]: number } } = {}

local limiter = RateLimiter.new(CrewConfig.REQUESTS_PER_SECOND)

local ACTIONS = { invite = true, accept = true, decline = true, leave = true, kick = true }

-- ==========================================================
-- HELPERS
-- ==========================================================

local function notify(player: Player, kind: string, message: string)
	StateService.notify(player, kind, message, "crew")
end

local function refresh(player: Player)
	if player.Parent then
		StateService.pushNow(player)
	end
end

local function refreshCrew(crew: Crew)
	for _, member in crew.members do
		refresh(member)
	end
end

local function openInvites(player: Player): { [Player]: number }
	local list = invites[player]
	if not list then
		list = {}
		invites[player] = list
	end
	local now = os.clock()
	for inviter, expires in list do
		if expires <= now or not inviter.Parent then
			list[inviter] = nil
		end
	end
	return list
end

local function outgoingCount(inviter: Player): number
	local count, now = 0, os.clock()
	for _, list in invites do
		local expires = list[inviter]
		if expires and expires > now then
			count += 1
		end
	end
	return count
end

local function remember(crew: Crew)
	for _, member in crew.members do
		local mates = {}
		for _, other in crew.members do
			if other ~= member then
				table.insert(mates, other.UserId)
			end
		end
		lastCrew[member.UserId] = mates
	end
end

local function setMember(player: Player, crew: Crew?)
	crewOf[player] = crew
	player:SetAttribute("CrewId", if crew then crew.id else nil)
end

local function dissolve(crew: Crew)
	crews[crew.id] = nil
	for _, member in crew.members do
		setMember(member, nil)
		if member.Parent then
			notify(member, "info", "Your crew has disbanded.")
			refresh(member)
		end
	end
	table.clear(crew.members)
end

--- Takes a player out of their crew (leave, kick or disconnect).
local function removeMember(player: Player, reason: string?)
	local crew = crewOf[player]
	if not crew then
		return
	end
	local index = table.find(crew.members, player)
	if index then
		table.remove(crew.members, index)
	end
	setMember(player, nil)
	refresh(player)
	if #crew.members < 2 then
		dissolve(crew)
		return
	end
	if crew.leader == player then
		crew.leader = crew.members[1]
		notify(crew.leader, "info", "You now lead the crew.")
	end
	for _, member in crew.members do
		notify(member, "info", `{player.DisplayName} {reason or "left the crew"}.`)
	end
	refreshCrew(crew)
end

-- ==========================================================
-- PUBLIC
-- ==========================================================

function CrewService.crewOf(player: Player): { Player }?
	local crew = crewOf[player]
	return if crew then table.clone(crew.members) else nil
end

function CrewService.areCrewmates(a: Player, b: Player): boolean
	local crew = crewOf[a]
	return crew ~= nil and a ~= b and crewOf[b] == crew
end

--- StatePush field `crew`. Small: at most four members and a few invites.
function CrewService.summarise(player: Player): any
	local crew = crewOf[player]
	local list = openInvites(player)
	local pending = {}
	for inviter, expires in list do
		table.insert(pending, {
			userId = inviter.UserId,
			name = inviter.DisplayName,
			expiresIn = math.max(0, math.floor(expires - os.clock())),
		})
	end
	local sent = {}
	for invitee, their in invites do
		if their[player] and their[player] > os.clock() then
			table.insert(sent, invitee.UserId)
		end
	end
	local members = {}
	if crew then
		for _, member in crew.members do
			table.insert(members, { userId = member.UserId, name = member.DisplayName, leader = member == crew.leader })
		end
	end
	return {
		id = if crew then crew.id else nil,
		leader = if crew then crew.leader == player else false,
		members = members,
		invites = pending,
		sent = sent,
		recent = lastCrew[player.UserId] or {},
		max = CrewConfig.MAX_MEMBERS,
	}
end

function CrewService.invite(player: Player, target: Player): (boolean, string?)
	if target == player then
		return false, "You can't invite yourself."
	end
	local crew = crewOf[player]
	if crew and crew.leader ~= player then
		return false, "Only the crew leader can invite."
	end
	if crew and #crew.members >= CrewConfig.MAX_MEMBERS then
		return false, "Your crew is full."
	end
	if crewOf[target] then
		return false, `{target.DisplayName} is already in a crew.`
	end
	local list = openInvites(target)
	if list[player] then
		return false, "Invite already sent."
	end
	if outgoingCount(player) >= CrewConfig.MAX_OUTGOING_INVITES then
		return false, "Too many open invites - wait a moment."
	end
	list[player] = os.clock() + CrewConfig.INVITE_SECONDS
	notify(target, "info", `{player.DisplayName} invited you to their crew! Open CREW to accept.`)
	notify(player, "success", `Invite sent to {target.DisplayName}.`)
	refresh(target)
	refresh(player)
	return true
end

function CrewService.accept(player: Player, inviter: Player): (boolean, string?)
	local list = openInvites(player)
	if not list[inviter] then
		return false, "That invite has expired."
	end
	if crewOf[player] then
		return false, "Leave your crew first."
	end
	local crew = crewOf[inviter]
	if crew and crew.leader ~= inviter then
		list[inviter] = nil
		refresh(player)
		return false, "That invite is no longer valid."
	end
	if crew and #crew.members >= CrewConfig.MAX_MEMBERS then
		return false, "That crew is full."
	end
	list[inviter] = nil
	if not crew then
		local made: Crew = { id = HttpService:GenerateGUID(false), leader = inviter, members = { inviter } }
		crews[made.id] = made
		setMember(inviter, made)
		crew = made
	end
	local joined = crew :: Crew
	table.insert(joined.members, player)
	setMember(player, joined)
	-- One crew at a time: every other invite this player holds is void.
	table.clear(list)
	remember(joined)
	for _, member in joined.members do
		notify(member, "success", if member == player then "You joined the crew!" else `{player.DisplayName} joined the crew!`)
	end
	refreshCrew(joined)
	return true
end

function CrewService.decline(player: Player, inviter: Player): (boolean, string?)
	local list = openInvites(player)
	list[inviter] = nil
	refresh(player)
	refresh(inviter)
	return true
end

function CrewService.leave(player: Player): (boolean, string?)
	if not crewOf[player] then
		return false, "You are not in a crew."
	end
	removeMember(player, "left the crew")
	notify(player, "info", "You left the crew.")
	return true
end

function CrewService.kick(player: Player, target: Player): (boolean, string?)
	local crew = crewOf[player]
	if not crew or crew.leader ~= player then
		return false, "Only the crew leader can kick."
	end
	if target == player or crewOf[target] ~= crew then
		return false, "They are not in your crew."
	end
	removeMember(target, "was kicked")
	notify(target, "error", "You were removed from the crew.")
	return true
end

-- ==========================================================
-- CREW ASSIST
-- ==========================================================

--- Where a position is on the lane, by zone band (rooms, corridor and a
--- vault's wing all count as their band). Nil in the lobby.
local function zoneAt(position: Vector3): number?
	if position.Z < 0 or position.Z > MapConfig.LANE_END_Z or math.abs(position.X) > MapConfig.LANE_HALF then
		return nil
	end
	for index = 1, MapConfig.ZONE_COUNT do
		if position.Z <= MapConfig.zoneEndZ(index) then
			return index
		end
	end
	return nil
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function stamp(book: { [Player]: { [number]: number } }, player: Player, zoneIndex: number, at: number)
	local row = book[player]
	if not row then
		row = {}
		book[player] = row
	end
	row[zoneIndex] = at
end

local function track()
	local now = os.clock()
	for player in crewOf do
		local root = rootOf(player)
		local zone = root and zoneAt(root.Position)
		if zone then
			stamp(presence, player, zone, now)
		end
	end
	for _, chase in GuardianService.activeChaseRooms() do
		local target = chase.target
		if target and crewOf[target] then
			stamp(chasedIn, target, chase.zoneIndex, now)
		end
	end
end

--- Test hook (DebugCommands/Vaults): mark a player as chased in a zone now.
function CrewService.noteChased(player: Player, zoneIndex: number)
	stamp(chasedIn, player, zoneIndex, os.clock())
end

--- Test hook: mark a player as present in a zone now.
function CrewService.notePresence(player: Player, zoneIndex: number)
	stamp(presence, player, zoneIndex, os.clock())
end

export type AssistResult = { paid: { [string]: number }, reason: string? }

--- Pays the crew assist for one delivery, if it qualifies. `members` and
--- `positions` default to the live crew; the debug command passes a
--- synthetic mate (a plain table with a `Name`), which counts toward the
--- assist but is never paid. Returns who was paid what (by name).
function CrewService.resolveAssist(deliverer: Player, info: any, members: { any }?, positions: { [any]: Vector3 }?): AssistResult
	local result: AssistResult = { paid = {} }
	local zoneIndex = if type(info) == "table" then info.zoneIndex else nil
	local income = if type(info) == "table" then info.income else nil
	if type(info) == "table" and info.heist then
		result.reason = "base steal"
		return result
	end
	if not Validate.finite(zoneIndex) or zoneIndex < 1 or not Validate.finite(income) or income <= 0 then
		result.reason = "not museum loot"
		return result
	end
	local crew: { any }? = members or (CrewService.crewOf(deliverer) :: any)
	if not crew or #crew < 2 then
		result.reason = "no crew"
		return result
	end
	local function positionOf(member: any): Vector3?
		if positions and positions[member] then
			return positions[member]
		end
		local root = if typeof(member) == "Instance" and member:IsA("Player") then rootOf(member) else nil
		return if root then root.Position else nil
	end
	local now = os.clock()
	local home = positionOf(deliverer)
	local assisted = false
	local eligible: { any } = { deliverer }
	for _, member in crew do
		if member == deliverer then
			continue
		end
		local at = positionOf(member)
		local near = home ~= nil and at ~= nil and (at - home).Magnitude <= CrewConfig.ASSIST_RADIUS
		local chased = now - ((chasedIn[member] or {})[zoneIndex] or -math.huge) <= CrewConfig.CHASE_ASSIST_SECONDS
		local present = now - ((presence[member] or {})[zoneIndex] or -math.huge) <= CrewConfig.PRESENCE_SECONDS
		if near or chased then
			assisted = true
		end
		if near or chased or present then
			table.insert(eligible, member)
		end
	end
	if not assisted then
		result.reason = "no crew mate nearby or distracting"
		return result
	end
	local bonus = math.floor(income * CrewConfig.BONUS_INCOME_SECONDS * CrewConfig.BONUS_FRACTION)
	if bonus <= 0 then
		result.reason = "bonus rounds to 0"
		return result
	end
	for _, member in eligible do
		if typeof(member) == "Instance" and member:IsA("Player") and member.Parent then
			EconomyService.earn(member, bonus, "crew")
			StateService.notify(member, "success", `CREW ASSIST! +{NumberFormat.cash(bonus)}`, "crew")
			result.paid[member.Name] = bonus
		else
			result.paid[`{member.Name} (synthetic, unpaid)`] = bonus
		end
	end
	return result
end

-- ==========================================================
-- START
-- ==========================================================

function CrewService.start()
	Remotes.get("CrewRequest").OnServerEvent:Connect(function(player: Player, action: any, targetUserId: any)
		if not limiter:consume(player) then
			return
		end
		if type(action) ~= "string" or not ACTIONS[action] then
			return
		end
		local target: Player? = nil
		if action ~= "leave" then
			local userId = Validate.integer(targetUserId, 1)
			local found = if userId then Players:GetPlayerByUserId(userId) else nil
			if not found then
				notify(player, "error", "That player isn't in this server.")
				return
			end
			target = found
		end
		local ok, reason
		if action == "leave" then
			ok, reason = CrewService.leave(player)
		elseif action == "invite" then
			ok, reason = CrewService.invite(player, target :: Player)
		elseif action == "accept" then
			ok, reason = CrewService.accept(player, target :: Player)
		elseif action == "decline" then
			ok, reason = CrewService.decline(player, target :: Player)
		else
			ok, reason = CrewService.kick(player, target :: Player)
		end
		if not ok and reason then
			notify(player, "error", reason)
		end
	end)

	ProgressEvents.on("delivered", function(player, _amount, info)
		if crewOf[player] then
			CrewService.resolveAssist(player, info)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		removeMember(player, "left the server")
		invites[player] = nil
		for _, list in invites do
			list[player] = nil
		end
		presence[player] = nil
		chasedIn[player] = nil
		limiter:release(player)
		-- Anyone who had an invite from this player should see it vanish.
		for _, other in Players:GetPlayers() do
			if other ~= player then
				StateService.markDirty(other)
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(CrewConfig.TRACK_INTERVAL)
			local ok, err = pcall(function()
				track()
				return true
			end)
			if not ok then
				warn(`[CrewService] tracking failed: {err}`)
			end
		end
	end)
end

--- Test hook: makes `members` a crew led by the first (Studio debug only;
--- the players must be real and in this server).
function CrewService.debugForm(members: { Player }): boolean
	for _, member in members do
		if crewOf[member] then
			removeMember(member)
		end
	end
	if #members < 2 then
		return false
	end
	local crew: Crew = { id = HttpService:GenerateGUID(false), leader = members[1], members = table.clone(members) }
	crews[crew.id] = crew
	for _, member in members do
		setMember(member, crew)
	end
	remember(crew)
	refreshCrew(crew)
	return true
end

return CrewService
