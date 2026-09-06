--!strict
--[[
	TrailCardPng
	A trail card whose entire LOOK is a painted PNG. This is the card that
	proved the method on the Green Trail; the general machinery it grew has
	since moved into PngCard, and this module is the trail-specific layer on
	top of it:

	    two SEPARATE buttons over the printed $ and R$ prices (two different
	    purchases, never one big hit region), and

	    the runtime state pills - EQUIP / EQUIPPED over the cash price and
	    OWNED over the Robux price once the trail is owned.

	THE CARD DECIDES NOTHING. It reports which printed button was pressed and
	what the server last said about ownership; the caller turns that into a
	TrailRequest, and the server decides whether anything is bought or worn.

	Geometry (crop, aspect, hitboxes) comes from PngUiConfig, measured off the
	asset's pixels. DEBUG_HITBOXES is PngCard's; it ships FALSE.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PngCard = require(ReplicatedStorage.Shared.Util.PngCard)
local PngUiConfig = require(ReplicatedStorage.Shared.Config.PngUiConfig)

local TrailCardPng = {}

export type State = { owned: boolean, equipped: boolean }

export type Options = {
	layout: PngUiConfig.Layout,
	--- Cell aspect the art is fitted into. Defaults to the Trail family.
	familyAspect: number?,
	--- Fired for the printed cash button, with the last server-reported state,
	--- so the caller can turn "buy" into "equip" once the trail is owned.
	onCash: (State) -> (),
	--- Fired for the printed Robux button. Omit for a cash-only trail; the
	--- region then gets no button at all (and Grey's art has no such button).
	onRobux: ((State) -> ())?,
}

export type Card = {
	frame: Frame,
	artwork: ImageLabel,
	setState: (State) -> (),
	destroy: () -> (),
}

local EQUIPPED_COLOR = Color3.fromRGB(120, 255, 160)
local EQUIP_COLOR = Color3.fromRGB(255, 255, 255)
local OWNED_COLOR = Color3.fromRGB(200, 208, 220)

function TrailCardPng.build(options: Options): Card
	local layout = options.layout
	local state: State = { owned = false, equipped = false }

	local regions: { [string]: PngCard.RegionSpec } = {
		cash = { onActivated = function()
			options.onCash(state)
		end },
	}
	local hasRobux = options.onRobux ~= nil and layout.regions.robux ~= nil
	if hasRobux then
		regions.robux = { onActivated = function()
			(options.onRobux :: (State) -> ())(state)
		end }
	end

	local card = PngCard.build({
		name = "TrailCard",
		layout = layout,
		familyAspect = options.familyAspect,
		regions = regions,
	})

	-- State overlays. Over the printed prices ONLY, and only once they stop
	-- being true: an owned trail's cash button becomes EQUIP / EQUIPPED, and its
	-- Robux button is retired under a small OWNED tag.
	local cashState = card.pill("cash", "EQUIP", EQUIPPED_COLOR)
	local robuxState = if hasRobux then card.pill("robux", "OWNED", OWNED_COLOR) else nil

	local function setState(next: State)
		state = { owned = next.owned == true, equipped = next.equipped == true }
		if state.equipped then
			cashState.Text = "✓ EQUIPPED"
			cashState.TextColor3 = EQUIPPED_COLOR
			cashState.Visible = true
		elseif state.owned then
			cashState.Text = "EQUIP"
			cashState.TextColor3 = EQUIP_COLOR
			cashState.Visible = true
		else
			cashState.Visible = false
		end
		if robuxState then
			robuxState.Visible = state.owned
		end
		if hasRobux then
			-- Owned by either route: the Robux button stops taking input.
			card.setRegionEnabled("robux", not state.owned)
		end
	end

	return {
		frame = card.frame,
		artwork = card.artwork,
		setState = setState,
		destroy = card.destroy,
	}
end

return TrailCardPng
