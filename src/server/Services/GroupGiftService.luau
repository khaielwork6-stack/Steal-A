--!strict
--[[
	GroupGiftService
	The one-time +10,000 Speed for joining the game's group.

	THE FLOW
	  1. The client presses CLAIM and shows Roblox's OWN group prompt
	     (GroupService:PromptJoinAsync). Nothing is built to imitate it.
	  2. When that prompt closes, the client sends `GroupGiftRequest`. It carries
	     nothing; it is a knock on the door.
	  3. THIS SERVICE asks Roblox whether the player is in the group. Not the
	     client - the client could say anything.
	  4. If they are, and they have never claimed, the Speed is granted, the
	     profile is marked, and the state is pushed so the popup flips to
	     CLAIMED. The mark is saved with the profile, so a rejoin or a new server
	     cannot pay it out twice.

	WHY TWO MEMBERSHIP CHECKS
	`Player:IsInGroupAsync` is the fast path, but Roblox caches its answer per
	server session - a player who joins the group WHILE playing can read as "not
	a member" from it for the rest of that session, which is precisely the moment
	this feature cares about. `GroupService:GetGroupsAsync` is a fresh web call
	against the player's live memberships and is not subject to that cache, so a
	"no" from the fast path is confirmed against it before the claim is refused.
	Both are pcall'd: a web failure is "try again in a moment", never a grant and
	never a permanent refusal.

	WHY THE GROUP ID IS READ FROM THE PLACE
	`game.CreatorId` when the experience is group-owned. This place is owned by
	group 3774675 and that is the community players are asked to join; reading it
	from the place means moving the experience to another group moves the gift
	with it, and there is no id here to go stale.
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DataService = require(script.Parent.DataService)
local StateService = require(script.Parent.StateService)

local GroupGiftService = {}

--- The reward. Speed, not Cash: Speed is the progression axis and 10,000 is a
--- meaningful early boost without being a zone skip (zone 2 gates at 900, so
--- this lands a brand new player comfortably into the second zone and no
--- further).
GroupGiftService.REWARD_SPEED = 10000

--- Resolved once at start. 0 means "not group-owned" and the gift stays
--- unavailable rather than pointing at a group that does not exist.
GroupGiftService.GROUP_ID = 0

local limiter = RateLimiter.new(GameConfig.RATE_LIMITS.GroupGiftRequest)

--- A claim already in flight for this player. A second knock while the first
--- is still waiting on Roblox is ignored, not queued, so two web calls cannot
--- race each other into a double grant.
local claiming: { [Player]: boolean } = {}

--- Overridden by init: applies a changed SpeedPower to movement.
GroupGiftService.refreshMovement = function(_player: Player) end

-- ==========================================================
-- MEMBERSHIP
-- ==========================================================

--- True only when Roblox says so. Fast path first, fresh path to confirm a no.
local function isMember(player: Player): (boolean, string?)
	local groupId = GroupGiftService.GROUP_ID
	if groupId <= 0 then
		return false, "This experience is not owned by a group."
	end

	local okFast, fast = pcall(function()
		return player:IsInGroupAsync(groupId)
	end)
	if okFast and fast == true then
		return true
	end

	local okFresh, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if not okFresh then
		-- Neither answer arrived. Do not refuse and do not grant.
		if not okFast then
			return false, "Roblox did not answer - try again in a moment."
		end
		return false
	end
	for _, entry in groups :: { any } do
		if type(entry) == "table" and entry.Id == groupId then
			return true
		end
	end
	return false
end

-- ==========================================================
-- CLAIM
-- ==========================================================

--- Grants the gift if, and only if, the player is in the group and has never
--- had it. Returns whether it was granted, and a reason when it was not.
function GroupGiftService.tryClaim(player: Player): (boolean, string?)
	local profile = DataService.get(player)
	if not profile then
		return false, "Still loading - try again in a moment."
	end
	if profile.GroupGiftClaimed then
		return false, "Already claimed!"
	end
	if claiming[player] then
		return false
	end

	claiming[player] = true
	local member, reason = isMember(player)
	claiming[player] = nil

	if not member then
		return false, reason or "Join the group first, then claim!"
	end

	-- Re-read after the yield: the profile could have been claimed by a racing
	-- request that beat this one to the membership answer.
	local fresh = DataService.get(player)
	if not fresh or fresh.GroupGiftClaimed then
		return false, "Already claimed!"
	end

	fresh.GroupGiftClaimed = true
	fresh.SpeedPower += GroupGiftService.REWARD_SPEED
	GroupGiftService.refreshMovement(player)

	-- Durable BEFORE it is celebrated, for the same reason a receipt is: a
	-- server that dies between the grant and the save must not re-grant.
	if DataService.isPersistent() then
		DataService.save(player)
	end

	StateService.notify(player, "success", "+10,000 SPEED! Thanks for joining!", "levelup")
	StateService.sound(player, "TreadmillUnlock")
	StateService.pushNow(player)
	return true
end

--- What the popup renders. Rides StatePush so a reconnect shows CLAIMED.
function GroupGiftService.summarise(player: Player): { [string]: any }
	local profile = DataService.get(player)
	return {
		claimed = profile ~= nil and profile.GroupGiftClaimed == true,
		reward = GroupGiftService.REWARD_SPEED,
		groupId = GroupGiftService.GROUP_ID,
	}
end

function GroupGiftService.start()
	if game.CreatorType == Enum.CreatorType.Group then
		GroupGiftService.GROUP_ID = game.CreatorId
	end

	Remotes.get("GroupGiftRequest").OnServerEvent:Connect(function(player)
		if not limiter:consume(player) then
			return
		end
		local ok, reason = GroupGiftService.tryClaim(player)
		if not ok and reason then
			StateService.notify(player, "error", reason)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
		claiming[player] = nil
	end)

	print(`[GroupGiftService] group gift online (group {GroupGiftService.GROUP_ID}, +{GroupGiftService.REWARD_SPEED} Speed)`)
end

return GroupGiftService
