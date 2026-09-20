--!strict
--[[
	HoldConfig  [hold-items]
	"Hold it in your hands": picking a trophy up off your own display pad,
	carrying it around small in front of you, and placing it back down.

	See docs/handoff-parts/hold-items.md for the full design writeup - what a
	held item is, why it lives inside Inventory rather than a new list, and
	every rule the owner's brief left for this pass to decide.
]]

local StorageConfig = require(script.Parent.StorageConfig)

local HoldConfig = {}

--- Sanity ceiling on held items, NOT a hand limit any more: a held item is
--- an Inventory (Storage) entry flagged Held, so the real bound is Storage
--- capacity. This equals the biggest Storage tier so the two can never
--- disagree; it exists as an upper bound for validation and the UI only.
HoldConfig.MAX_HELD_ITEMS = StorageConfig.Tiers[#StorageConfig.Tiers].capacity

--- The hotbar draws at most this many slots (keys 1-9 and 0 = the 10th).
--- Positions are compact: [tools and owned gadgets][held items in pickup
--- order]. Held items past what is left of these go to the overflow
--- inventory (backtick), decided by position alone.
HoldConfig.HOTBAR_SLOTS = 10

--- The overflow inventory panel opens/closes on this key.
HoldConfig.OVERFLOW_KEY = Enum.KeyCode.Backquote

--- The longest side (X, Y or Z, whichever is biggest) a held model is scaled
--- to, in studs, REGARDLESS of the item's real placed size. A Titan that
--- covers a whole pedestal shrinks to a trinket in the hand; the pad shows it
--- full size again the moment it is placed (BaseService.displayScale, never
--- touched by this pass).
HoldConfig.HELD_TARGET_LONGEST_SIDE = 2

--- Never let a degenerate (near-zero) bounding box blow the scale up to
--- something absurd.
HoldConfig.HELD_MIN_LONGEST_SIDE = 0.05

--- Where the held model sits relative to the character's upper torso: a
--- little low and forward, like something carried at chest height rather
--- than raised overhead (that silhouette is CarryService's stolen-loot carry,
--- and deliberately different from this one).
HoldConfig.HELD_OFFSET = CFrame.new(0, -0.35, -1.55)

--- The rarity-coloured outline drawn around a held item (Highlight.OutlineColor,
--- FillTransparency = 1 so it never becomes an x-ray silhouette).
HoldConfig.HELD_OUTLINE_TRANSPARENCY = 0.15

--- How far the little name/rarity/income billboard over the holder's head
--- can be seen from. Roblox hides a BillboardGui past MaxDistance on its own,
--- which is the "hide it while other players are far" rule for free.
HoldConfig.HELD_BILLBOARD_MAX_DISTANCE = 55

return HoldConfig
