--!strict
--[[
	AutoRevealService
	The Auto Reveal Game Pass: a pass owner's sealed containers reveal
	themselves when their timer ends, WHILE THE OWNER IS ONLINE.

	IT ONLY PRESSES THE BUTTON. Every reveal goes through HatchService.commit,
	the one place a container becomes an item, with all of its checks
	(ownership, readiness, robbery, the reveal lock). Nothing here grants,
	rolls or decides anything; a revealed-for-free container is what the
	player would have got by walking up and holding the prompt.

	ONE AT A TIME, SPACED. A ready container is revealed only when the
	owner's client has finished the previous reveal (HatchConfig
	.autoRevealSpacing), and never while any reveal is already running on
	their base, so every reveal plays in full.

	NEAR OR AWAY. On (or near) their own plot the owner gets the normal reveal
	with the camera fly-in. Anywhere else the commit is `quick`: the
	HatchReveal payload carries `skipCamera`, the client plays a small pop on
	the pedestal instead, and a toast names what was revealed.

	OFF SWITCH. Settings.AutoRevealOff (SettingsService) pauses it.

	PLACEHOLDER. MonetizationConfig.AutoRevealPass.gamePassId is 0 until the
	owner creates the pass; while it is 0 nobody owns it (Studio can fake it
	with `setOwnedForTesting`) and the shop card is hidden.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local HatchConfig = require(ReplicatedStorage.Shared.Config.HatchConfig)
local LootConfig = require(ReplicatedStorage.Shared.Config.LootConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.Config.MonetizationConfig)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local BaseService = require(script.Parent.BaseService)
local DataService = require(script.Parent.DataService)
local HatchService = require(script.Parent.HatchService)
local MonetizationService = require(script.Parent.MonetizationService)
local StateService = require(script.Parent.StateService)

local AutoRevealService = {}

local limiter = RateLimiter.new(2)

--- os.clock before which this player's next auto reveal may not start.
local nextAt: { [Player]: number } = {}
--- Studio-only ownership override (the pass id is a placeholder 0).
local studioOverride: { [Player]: boolean? } = {}
--- A container with an Instant Reveal dialog open is left alone for a while
--- (the receipt reveals it); InstanceId -> os.clock first seen pending.
local pendingSeen: { [string]: number } = {}
local PENDING_GRACE = 60

--- The live price, once fetched (only for a configured pass).
local livePrice: number? = nil

-- ==========================================================
-- OWNERSHIP AND THE SWITCH
-- ==========================================================

function AutoRevealService.isConfigured(): boolean
	return MonetizationConfig.AutoRevealPass.gamePassId > 0
end

function AutoRevealService.owns(player: Player): boolean
	local override = studioOverride[player]
	if override ~= nil and RunService:IsStudio() then
		return override == true
	end
	local id = MonetizationConfig.AutoRevealPass.gamePassId
	if id <= 0 then
		return false
	end
	return MonetizationService.ownsPassCached(player, id)
end

--- The Settings switch. A missing key reads as ON.
function AutoRevealService.isSwitchedOn(player: Player): boolean
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	return (profile.Settings :: any).AutoRevealOff ~= true
end

function AutoRevealService.isActive(player: Player): boolean
	return AutoRevealService.owns(player) and AutoRevealService.isSwitchedOn(player)
end

--- STUDIO ONLY. `nil` removes the override (back to Roblox's answer).
function AutoRevealService.setOwnedForTesting(player: Player, owned: boolean?)
	if not RunService:IsStudio() then
		return
	end
	studioOverride[player] = owned
	local id = MonetizationConfig.AutoRevealPass.gamePassId
	if id > 0 and owned ~= nil then
		MonetizationService.setOwnedForTesting(player, id, owned)
	end
	StateService.pushNow(player)
end

--- Studio only: forgets the spacing so a test can reveal at once.
function AutoRevealService.debugResetPacing(player: Player)
	nextAt[player] = nil
end

--- What the client needs: rides StatePush as `autoReveal`.
function AutoRevealService.summarise(player: Player): { [string]: any }
	return {
		owned = AutoRevealService.owns(player),
		enabled = AutoRevealService.isSwitchedOn(player),
		-- The shop card shows only for a real pass (or in Studio, disabled).
		configured = AutoRevealService.isConfigured(),
		robux = livePrice or MonetizationConfig.AutoRevealPass.robux,
	}
end

-- ==========================================================
-- THE LOOP
-- ==========================================================

--- STUDIO ONLY: forces the near/away answer for the debug commands
--- (nil = measure it).
AutoRevealService.nearOverride = nil :: boolean?

--- Is the owner on or near their plot? Decides full reveal vs quick pop.
function AutoRevealService.isNearBase(player: Player): boolean
	if AutoRevealService.nearOverride ~= nil and RunService:IsStudio() then
		return AutoRevealService.nearOverride == true
	end
	local plot = BaseService.getPlot(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not plot or not root or not root:IsA("BasePart") then
		return false
	end
	if BaseService.plotAt(root.Position) == (plot :: Instance) then
		return true
	end
	local slab = BaseService.slabOf(plot)
	if not slab then
		return false
	end
	return (root.Position - slab.Position).Magnitude <= HatchConfig.AUTO_REVEAL_NEAR_STUDS
end

--- One pass for one player. Returns true when a reveal was started.
function AutoRevealService.step(player: Player): boolean
	if (nextAt[player] or 0) > os.clock() then
		return false
	end
	if not AutoRevealService.isActive(player) then
		return false
	end
	local profile = DataService.get(player)
	if not profile or not BaseService.getPlot(player) then
		return false
	end

	local pendingId: string? = nil
	local pending = profile.PendingReveal
	if type(pending) == "table" and type(pending.instanceId) == "string" then
		pendingId = pending.instanceId
	end

	local candidate: DataService.DisplayItem? = nil
	for _, item in profile.DisplayItems do
		-- Any reveal already running on this base: wait for it to finish.
		if HatchService.isRevealing(item.InstanceId) then
			return false
		end
		if candidate or item.Hatched ~= false or item.RobbedBy or HatchService.remaining(item) > 0 then
			continue
		end
		if item.InstanceId == pendingId then
			local since = pendingSeen[item.InstanceId]
			if not since then
				pendingSeen[item.InstanceId] = os.clock()
				continue
			elseif os.clock() - since < PENDING_GRACE then
				continue
			end
		end
		candidate = item
	end
	if not candidate then
		return false
	end

	local item = candidate :: DataService.DisplayItem
	local quick = not AutoRevealService.isNearBase(player)
	local ok = HatchService.commit(player, item.InstanceId, { auto = true, quick = quick })
	if not ok then
		-- Refused (a race with a manual reveal): try again next poll.
		nextAt[player] = os.clock() + HatchConfig.AUTO_REVEAL_POLL
		return false
	end
	pendingSeen[item.InstanceId] = nil
	nextAt[player] = os.clock() + HatchConfig.autoRevealSpacing(item.Rarity, quick)
	if quick then
		-- The pop is on a base the player cannot see: say what it was.
		local def = LootConfig.ById[item.ItemId]
		StateService.notify(player, "success", `AUTO REVEAL: {if def then def.name else item.ItemId} ({item.Rarity})`)
	end
	return true
end

-- ==========================================================
-- START
-- ==========================================================

function AutoRevealService.start()
	StateService.addProvider("autoReveal", AutoRevealService.summarise)

	Remotes.get("AutoRevealRequest").OnServerEvent:Connect(function(player, action)
		if not limiter:consume(player) or action ~= "buy" then
			return
		end
		local id = MonetizationConfig.AutoRevealPass.gamePassId
		if id <= 0 then
			StateService.notify(player, "error", "Auto Reveal is not available yet.")
			return
		end
		if AutoRevealService.owns(player) then
			StateService.notify(player, "info", "You already own Auto Reveal! Toggle it in Settings.")
			return
		end
		local ok, err = pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, id)
		end)
		if not ok then
			warn(`[AutoRevealService] PromptGamePassPurchase failed for {player.Name}: {err}`)
			StateService.notify(player, "error", "Could not open the purchase.")
		end
		-- Ownership is re-read by MonetizationService on
		-- PromptGamePassPurchaseFinished (the id is in allGamePassIds), which
		-- pushes state; the loop below picks it up on its next pass.
	end)

	if AutoRevealService.isConfigured() then
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(MonetizationConfig.AutoRevealPass.gamePassId, Enum.InfoType.GamePass)
			end)
			if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
				livePrice = info.PriceInRobux
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		limiter:release(player)
		nextAt[player] = nil
		studioOverride[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(HatchConfig.AUTO_REVEAL_POLL)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(AutoRevealService.step, player)
				if not ok then
					warn(`[AutoRevealService] step failed for {player.Name}: {err}`)
				end
			end
			-- Forget pending marks for containers that are gone.
			for instanceId, since in pendingSeen do
				if os.clock() - since > PENDING_GRACE * 4 then
					pendingSeen[instanceId] = nil
				end
			end
		end
	end)
end

return AutoRevealService
