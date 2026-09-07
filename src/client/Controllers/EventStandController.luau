--!strict
--[[
	EventStandController
	Answers the "Notify Me" prompt on the Next Update stand.

	Holding E on the stand's NotifyPrompt (EventStandService) opens Roblox's
	own follow-this-event dialog for the configured event, through
	SocialService:PromptRsvpToEventAsync - a local-player API, which is why
	this lives on the client. The prompt's own label reflects the player's
	current RSVP so a follower sees "Following" instead of being asked twice,
	and a toast confirms what happened.

	Studio and old clients can refuse the call; every use is pcall'd and a
	refusal becomes a quiet toast rather than an error.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ToastController = require(script.Parent.ToastController)

local EventStandController = {}

local player = Players.LocalPlayer
local EVENT_ID = GameConfig.NEXT_UPDATE_EVENT_ID

local busy = false

local function going(status: any): boolean
	return status == Enum.RsvpStatus.Going or tostring(status) == "Enum.RsvpStatus.Going"
end

local function paintPrompt(prompt: ProximityPrompt, status: any)
	prompt.ActionText = if going(status) then "Following ✓" else "Notify Me"
end

local function currentStatus(): any
	local ok, status = pcall(function()
		return SocialService:GetEventRsvpStatusAsync(EVENT_ID)
	end)
	return if ok then status else nil
end

--- Roblox's dialog yields this call until it closes; a watchdog frees the
--- prompt again if the dialog never comes back (Studio, an old client).
local PROMPT_WATCHDOG = 20

local function onTriggered(prompt: ProximityPrompt)
	if busy then
		return
	end
	busy = true
	local token = os.clock()
	task.delay(PROMPT_WATCHDOG, function()
		if busy then
			busy = false
		end
	end)
	task.spawn(function()
		local ok, status = pcall(function()
			return SocialService:PromptRsvpToEventAsync(EVENT_ID)
		end)
		busy = false
		if not ok then
			warn(`[EventStandController] RSVP prompt refused: {status}`)
			ToastController.show("info", "Update alerts are not available right now.")
			return
		end
		paintPrompt(prompt, status)
		if going(status) then
			ToastController.show("success", "You'll be notified when the update drops!")
		else
			ToastController.show("info", "You won't be notified about the update.")
		end
	end)
end

function EventStandController.start()
	if type(EVENT_ID) ~= "string" or EVENT_ID == "" then
		return
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt, who)
		if who == player and prompt.Name == "NotifyPrompt" then
			onTriggered(prompt)
		end
	end)

	-- Label the prompt with the player's standing answer once it exists.
	ProximityPromptService.PromptShown:Connect(function(prompt)
		if prompt.Name == "NotifyPrompt" and prompt:GetAttribute("_RsvpPainted") ~= true then
			prompt:SetAttribute("_RsvpPainted", true)
			task.spawn(function()
				paintPrompt(prompt, currentStatus())
			end)
		end
	end)
end

return EventStandController
