--!strict
--[[
	LoadingConfig
	The loading screen's text and art (polish-events-analytics pass).

	Lives in ReplicatedFirst next to the LoadingScreen LocalScript: that script
	runs before ReplicatedStorage.Shared exists, so it cannot read the normal
	Config folder. validate.luau checks this module from the server.

	Asset ids come from docs/codex-prompts/polish-events-analytics.md.
	"rbxassetid://0" = not made yet: the screen falls back to the gradient /
	a text title / no icon.
]]

export type Tip = { text: string, icon: string }

local LoadingConfig = {}

LoadingConfig.TITLE = "STEAL & RUN!"
LoadingConfig.SUBTITLE = "Break in. Grab it. Get out."

--- 16:9 background (desktop, tablet landscape) and 9:16 (phone portrait).
LoadingConfig.BACKGROUND_WIDE = "rbxassetid://71586324904614"
LoadingConfig.BACKGROUND_TALL = "rbxassetid://106780645977439"
--- The game logo. 0 = the TITLE text is drawn instead.
LoadingConfig.LOGO = "rbxassetid://0"

--- The placeholder gradient (top -> bottom), used when there is no art and
--- underneath the art while it loads.
LoadingConfig.GRADIENT_TOP = Color3.fromRGB(38, 28, 86)
LoadingConfig.GRADIENT_BOTTOM = Color3.fromRGB(12, 10, 30)
LoadingConfig.ACCENT = Color3.fromRGB(255, 208, 64)

--- Seconds before the SKIP button appears.
LoadingConfig.SKIP_AFTER = 3
--- Seconds each tip stays up.
LoadingConfig.TIP_SECONDS = 4.5
--- The screen always shows at least this long (no flash on a warm cache).
LoadingConfig.MIN_SECONDS = 1.5
--- Hard cap: fade out even if the client never reports ready.
LoadingConfig.MAX_SECONDS = 60
LoadingConfig.FADE_SECONDS = 0.6

LoadingConfig.TIPS = {
	{ icon = "rbxassetid://86946041675183", text = "Touching a laser wakes that room's guard instantly!" },
	{ icon = "rbxassetid://86946041675183", text = "Crouch under high beams and jump over low ones." },
	{ icon = "rbxassetid://78917459454723", text = "Crouching makes you slower - only crouch when a beam is in the way." },
	{ icon = "rbxassetid://117053812199694", text = "Grabbing a container is quiet. The guard wakes when you carry it out the door - so RUN!" },
	{ icon = "rbxassetid://89705702085201", text = "You get a short grace period at the doorway before the guard notices you." },
	{ icon = "rbxassetid://117053812199694", text = "Cross the red safe line to escape a chasing guard." },
	{ icon = "rbxassetid://76730471536319", text = "Every few minutes Night falls: everyone goes home and every case is refilled." },
	{ icon = "rbxassetid://109736568255684", text = "Stolen containers stay sealed. Wait for the timer on your base, then reveal them!" },
	{ icon = "rbxassetid://109736568255684", text = "Shiny, Golden, Flaming and Corrupted loot earns more Cash every second." },
	{ icon = "rbxassetid://70402015527894", text = "Train Speed on your treadmill to reach the deeper, richer zones." },
	{ icon = "rbxassetid://70402015527894", text = "Trails make you faster. Find them in the Trail shop." },
	{ icon = "rbxassetid://86189194981847", text = "Your trophies keep earning a share of their Cash while you're offline." },
	{ icon = "rbxassetid://86189194981847", text = "Mutation Weekend: mutation chances are doubled every Saturday and Sunday (UTC)." },
	{ icon = "rbxassetid://86189194981847", text = "Keep an eye on our group and updates for free reward codes!" },
} :: { Tip }

return LoadingConfig
