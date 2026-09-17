--!strict
--[[
	OwnerCommandService
	Chat commands for the owner of a PRIVATE server:

	    /night          start the Night now (ends in the normal world refresh)
	    /day            end the Night now
	    /resetguards    send every museum guard back to its post, asleep
	    /refill         fill every EMPTY display socket (nothing is rerolled)
	    /kick <name>    remove a player (private servers only)

	WHO: game.PrivateServerOwnerId in a private server. In Studio also the
	game's owner (or a member of the owning group at OWNER_GROUP_MIN_RANK+),
	so the commands can be tested. Everyone else gets a short refusal.

	HOW: TextChatCommand instances created HERE, on the server, so Triggered
	fires on the server with the sender's TextSource. Nothing a command does
	grants Cash, Speed or items; the world commands have cooldowns
	(OWNER_COMMAND_COOLDOWN, OWNER_NIGHT_COOLDOWN) so a private server cannot
	be used as a socket reroll machine. They use the same service APIs as
	DebugService's forceNight / forceDay.

	Skipped entirely when the place is not on TextChatService (legacy chat).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local SocialConfig = require(ReplicatedStorage.Shared.Config.SocialConfig)
local ZoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig)

local GuardianService = require(script.Parent.GuardianService)
local LootService = require(script.Parent.LootService)
local NightService = require(script.Parent.NightService)
local StateService = require(script.Parent.StateService)

local OwnerCommandService = {}

--- Sockets per zone are 8 today; the loop stops at the first missing one.
local MAX_SOCKETS_PER_ZONE = 32

local lastUsed: { [string]: number } = {}

local function isPrivateServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId ~= 0
end

local function isStudioOwner(player: Player): boolean
	if not RunService:IsStudio() then
		return false
	end
	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(function()
			return player:GetRankInGroupAsync(game.CreatorId)
		end)
		return ok and (tonumber(rank) or 0) >= SocialConfig.OWNER_GROUP_MIN_RANK
	end
	-- An unpublished place has CreatorId 0: whoever is testing it owns it.
	return game.CreatorId == 0 or player.UserId == game.CreatorId
end

--- May `player` use the owner commands here?
function OwnerCommandService.isOwner(player: Player): boolean
	if isPrivateServer() and player.UserId == game.PrivateServerOwnerId then
		return true
	end
	return isStudioOwner(player)
end

local function reply(player: Player, kind: string, message: string)
	StateService.notify(player, kind, message)
end

local function cooledDown(player: Player, name: string, seconds: number): boolean
	local now = os.clock()
	local last = lastUsed[name]
	if last and now - last < seconds then
		reply(player, "error", `/{name} is ready again in {math.ceil(seconds - (now - last))}s.`)
		return false
	end
	lastUsed[name] = now
	return true
end

--- Fills every empty socket. Returns how many were filled.
function OwnerCommandService.refillEmpty(): number
	local filled = 0
	for zoneIndex = 1, ZoneConfig.COUNT do
		for socketIndex = 1, MAX_SOCKETS_PER_ZONE do
			local socket = LootService.getSocket(zoneIndex, socketIndex) :: any
			if not socket then
				break
			end
			if socket.loot == nil and LootService.fillSocket(socket) then
				filled += 1
			end
		end
	end
	return filled
end

--- The player `query` names: exact Name / DisplayName first, then a unique
--- prefix of either. nil plus a reason otherwise.
local function findTarget(query: string): (Player?, string?)
	local wanted = string.lower(query)
	if wanted == "" then
		return nil, "Usage: /kick <name>"
	end
	local prefixMatches: { Player } = {}
	for _, candidate in Players:GetPlayers() do
		local name = string.lower(candidate.Name)
		local display = string.lower(candidate.DisplayName)
		if name == wanted or display == wanted then
			return candidate, nil
		end
		if string.sub(name, 1, #wanted) == wanted or string.sub(display, 1, #wanted) == wanted then
			table.insert(prefixMatches, candidate)
		end
	end
	if #prefixMatches == 1 then
		return prefixMatches[1], nil
	end
	if #prefixMatches > 1 then
		return nil, `"{query}" matches {#prefixMatches} players - type more of the name.`
	end
	return nil, `No player called "{query}".`
end

type Handler = (Player, string) -> ()

local HANDLERS: { [string]: Handler } = {
	night = function(player)
		if NightService.isNight() then
			reply(player, "error", "It is already Night.")
			return
		end
		if cooledDown(player, "night", SocialConfig.OWNER_NIGHT_COOLDOWN) then
			NightService.forceNight()
			reply(player, "success", "Night started.")
		end
	end,
	day = function(player)
		if not NightService.isNight() then
			reply(player, "error", "It is already Day.")
			return
		end
		if cooledDown(player, "day", SocialConfig.OWNER_COMMAND_COOLDOWN) then
			NightService.forceDay()
			reply(player, "success", "Day is back.")
		end
	end,
	resetguards = function(player)
		if cooledDown(player, "resetguards", SocialConfig.OWNER_COMMAND_COOLDOWN) then
			GuardianService.resetAll()
			reply(player, "success", "Every guard is back at its post.")
		end
	end,
	refill = function(player)
		if NightService.isNight() or LootService.isClosed() then
			reply(player, "error", "The museum is closed right now.")
			return
		end
		if cooledDown(player, "refill", SocialConfig.OWNER_COMMAND_COOLDOWN) then
			local filled = OwnerCommandService.refillEmpty()
			reply(player, "success", `Refilled {filled} empty display case(s).`)
		end
	end,
	kick = function(player, argument)
		if not isPrivateServer() then
			reply(player, "error", "/kick only works in a private server.")
			return
		end
		local target, why = findTarget(argument)
		if not target then
			reply(player, "error", why or "No such player.")
			return
		end
		if target == player or target.UserId == game.PrivateServerOwnerId then
			reply(player, "error", "You can't kick yourself.")
			return
		end
		target:Kick("You were removed by the private server's owner.")
		reply(player, "success", `Kicked {target.DisplayName}.`)
	end,
}

--- Runs `name` for `player` with the text after the command. Also the
--- entry point for the Studio debug command.
function OwnerCommandService.run(player: Player, name: string, argument: string?): boolean
	local handler = HANDLERS[name]
	if not handler then
		return false
	end
	if not OwnerCommandService.isOwner(player) then
		reply(player, "error", "Only the private server's owner can use that command.")
		return false
	end
	local ok: boolean, err: any = (pcall :: any)(handler, player, argument or "")
	if not ok then
		warn(`[OwnerCommandService] /{name} failed: {err}`)
		reply(player, "error", "That command failed.")
	end
	return ok
end

function OwnerCommandService.start()
	if not SocialConfig.OWNER_COMMANDS_ENABLED then
		return
	end
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		warn("[OwnerCommandService] legacy chat in use - owner commands are off")
		return
	end
	-- Nobody can ever use them in a public live server; do not even list
	-- them in chat autocomplete there.
	if not isPrivateServer() and not RunService:IsStudio() then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "OwnerCommands"
	folder.Parent = TextChatService

	for name in HANDLERS do
		local command = Instance.new("TextChatCommand")
		command.Name = "Owner_" .. name
		command.PrimaryAlias = "/" .. name
		command.Parent = folder
		command.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if not player then
				return
			end
			-- Everything after the alias, trimmed ("/kick  Bob " -> "Bob").
			local argument = string.match(text, "^%S+%s*(.-)%s*$") or ""
			OwnerCommandService.run(player, name, argument)
		end)
	end
end

return OwnerCommandService
