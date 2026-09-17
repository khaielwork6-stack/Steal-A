--!strict
--[[
	HatchConfig
	How long a stolen container incubates, and the beats of the reveal.

	EVERY TIMING NUMBER IN THE HATCH SYSTEM LIVES HERE. Nothing else in the
	project may hard-code a hatch duration or an animation beat.

	    hatchSeconds = rarityBase x sizeFactor x mutationFactor,  clamped to CAP

	Rarity is the primary axis; size and mutation are small modifiers, so a
	Colossal Corrupted Common is still a fast hatch and a Normal Divine is
	still a long one. The competitor audit supplied no verified hatch-time
	table (its GrowthTime lives in a per-creature catalog that was not
	reachable from this project), so the rarity ladder below is the brief's
	own fallback, applied to this game's ten ordered rarity tiers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.Config.RarityConfig)

local HatchConfig = {}

--- Declared so the parity/report tooling can say which numbers are traced and
--- which are this project's own.
HatchConfig.SOURCE_STATUS = "FALLBACK_TABLE_NO_VERIFIED_COMPETITOR_TIMES"

-- ==========================================================
-- RARITY BASE TIMES
-- ==========================================================
--
-- Indexed by the rarity's position in RarityConfig.Order (Common = 1 ...
-- Divine = 10), so adding a tier to that ladder is the only edit needed here.

HatchConfig.RarityBaseSeconds = {
	5, -- 1  Common       5s
	15, -- 2  Uncommon     15s
	45, -- 3  Rare         45s
	120, -- 4  Epic         2m
	300, -- 5  Legendary    5m
	900, -- 6  Mythic       15m
	2700, -- 7  Cosmic       45m
	7200, -- 8  Secret       2h
	21600, -- 9  Eternal      6h
	43200, -- 10 Divine       12h
} :: { number }

--- Nothing incubates longer than this, whatever the modifiers multiply out to.
HatchConfig.MAX_SECONDS = 12 * 60 * 60

--- Size modifiers. HATCH DURATION ONLY - these never touch income, which is
--- ScaleConfig.sizeFactor and is not duplicated here.
HatchConfig.SizeFactors = {
	Normal = 1.00,
	Big = 1.08,
	Huge = 1.20,
	Giant = 1.35,
	Titan = 1.60,
	Colossal = 2.00,
} :: { [string]: number }

--- Mutation modifiers, by the mutation's position in RarityConfig.Mutations,
--- so a mutation added to that ladder maps by ORDER rather than being ignored.
--- HATCH DURATION ONLY - mutation economics are untouched and locked.
HatchConfig.MutationFactorsByRank = {
	1.00, -- 1  Normal
	1.05, -- 2  Shiny
	1.10, -- 3  Golden
	1.20, -- 4  Flaming
	1.35, -- 5  Corrupted
} :: { number }

--- A mutation past the end of the table (a future sixth) keeps climbing by
--- this step rather than silently reverting to 1.
HatchConfig.MUTATION_FACTOR_STEP = 0.15

function HatchConfig.rarityBaseSeconds(rarity: string): number
	local rank = RarityConfig.rank(rarity)
	if rank <= 0 then
		return HatchConfig.RarityBaseSeconds[1]
	end
	return HatchConfig.RarityBaseSeconds[rank] or HatchConfig.RarityBaseSeconds[#HatchConfig.RarityBaseSeconds]
end

function HatchConfig.sizeFactor(sizeLabel: string?): number
	return (sizeLabel and HatchConfig.SizeFactors[sizeLabel]) or 1
end

function HatchConfig.mutationFactor(mutationId: string?): number
	local rank = RarityConfig.mutationRank(RarityConfig.normaliseMutation(mutationId)) + 1
	local listed = HatchConfig.MutationFactorsByRank[rank]
	if listed then
		return listed
	end
	local last = HatchConfig.MutationFactorsByRank[#HatchConfig.MutationFactorsByRank]
	local beyond = rank - #HatchConfig.MutationFactorsByRank
	return last + HatchConfig.MUTATION_FACTOR_STEP * math.max(beyond, 0)
end

--- THE ONE hatch-duration function. Whole seconds, at least one, never past
--- the cap. Server-authoritative: only HatchService calls this, once, when the
--- container is accepted onto a pedestal.
function HatchConfig.hatchSeconds(rarity: string, sizeLabel: string?, mutationId: string?): number
	local seconds = HatchConfig.rarityBaseSeconds(rarity)
		* HatchConfig.sizeFactor(sizeLabel)
		* HatchConfig.mutationFactor(mutationId)
	return math.clamp(math.floor(seconds + 0.5), 1, HatchConfig.MAX_SECONDS)
end

-- ==========================================================
-- THE REVEAL
-- ==========================================================
--
-- One short scripted sequence, played by the owner's client on a local clone
-- of the container: levitate, exactly one full turn, a breath in, and the pop
-- that swaps the container for the item. There is no AnimationId anywhere in
-- it. The server has already committed the result before the first frame, so
-- an abandoned animation can never cost or duplicate a reward.
--
-- Times are seconds from the start. The whole thing runs ~2.0s.

HatchConfig.Reveal = {
	--- Phase 1: the container rises off its pedestal, eased out.
	lift = { duration = 0.45, studs = 1.25 },
	--- Phase 2: exactly one 360, with a slight swell and a brighter glow.
	turn = { duration = 0.85, scale = 1.06 },
	--- Phase 3: a held breath - it squeezes in and pulls its sparkle inward.
	squeeze = { duration = 0.30, scale = 0.93 },
	--- Phase 4: the pop. It flares to this scale as it dissolves, and the item
	--- appears underneath on the same frame.
	pop = { duration = 0.16, scale = 1.18 },
	--- The revealed item: from 70% through 110% back to 100%, one bounce.
	item = { from = 0.70, overshoot = 1.10, grow = 0.28, settle = 0.22 },
}

--- When the server swaps the container for the item, measured from the moment
--- it tells the client to start. This is the START of the pop; the server's
--- rebuild lands here and the client reveals whatever it finds on that frame.
HatchConfig.SWAP_AT = HatchConfig.Reveal.lift.duration
	+ HatchConfig.Reveal.turn.duration
	+ HatchConfig.Reveal.squeeze.duration

--- Total length of the sequence, pop and item bounce included.
HatchConfig.TOTAL_SECONDS = HatchConfig.SWAP_AT
	+ HatchConfig.Reveal.pop.duration
	+ HatchConfig.Reveal.item.grow
	+ HatchConfig.Reveal.item.settle

--- The reveal LOCK. From the trigger until this many seconds later the slot
--- accepts no interaction at all, server and client alike, so a held key
--- cannot start a second sequence and a state refresh cannot re-arm the
--- prompt mid-animation. A little longer than the animation on purpose.
HatchConfig.LOCK_SECONDS = HatchConfig.TOTAL_SECONDS + 0.6

-- ==========================================================
-- RARITY-AWARE TIMING
-- ==========================================================
--
-- The roulette above sits BETWEEN the lift and the pop, and its length
-- depends on the prize's rarity, so the two timings the server needs cannot
-- be constants any more. They are derived from the very same numbers the
-- client animates to, which is what keeps the swap atomic: the pedestal is
-- rebuilt on the exact frame the winning item bursts.
--
-- The old constants above are kept because they still describe the reveal's
-- own phases; nothing should read them for scheduling.

--- Seconds from the reveal cue to the pop frame, for a prize of this rarity.
--- The server rebuilds the pedestal exactly here.
function HatchConfig.swapAt(rarity: string): number
	local delays = HatchConfig.rouletteDelays(rarity)
	-- Every wait EXCEPT the last. The final change lands on the prize and is
	-- held for holdSeconds instead, so counting that entry (always 0 anyway)
	-- would only obscure where the swap lands.
	local roulette = 0
	for index = 1, #delays - 1 do
		roulette += delays[index]
	end
	return HatchConfig.Reveal.lift.duration + roulette + HatchConfig.Roulette.holdSeconds
end

--- The whole sequence, pop and item bounce included. The camera's admiring
--- hold and return run after this on the client and lock nothing.
function HatchConfig.totalSeconds(rarity: string): number
	return HatchConfig.swapAt(rarity)
		+ HatchConfig.Reveal.pop.duration
		+ HatchConfig.Reveal.item.grow
		+ HatchConfig.Reveal.item.settle
end

--- The reveal LOCK. From the trigger until this many seconds later the slot
--- accepts no interaction at all, server and client alike, so a held key
--- cannot start a second sequence and a state refresh cannot re-arm the
--- prompt mid-animation. Deliberately a little longer than the animation.
function HatchConfig.lockSeconds(rarity: string): number
	return HatchConfig.totalSeconds(rarity) + 0.6
end

--- The build-up under the whole reveal (4.5s long), played by the owner's
--- client on the first frame so its peak lands on the pop.
HatchConfig.POP_SOUND = "RevealPop"

-- ==========================================================
-- THE ROULETTE
-- ==========================================================
--
-- Between the lift and the pop, the container is replaced by a casino-style
-- run of items, in full colour and in wildly different sizes, flicking past
-- faster than the eye can name them and then slowing, tick by tick, onto the
-- real reward. The camera flies in to the stage for it (2026-09-17, owner:
-- "lottery / casino feeling", about three seconds, fast ticking slowing to
-- the reveal).
--
-- IT IS PURE PRESENTATION. The server rolled the prize, committed it, started
-- the income and only then told the client to animate. The last item is READ
-- from that payload, never chosen here, so nothing in this file or in the
-- controller that consumes it can change what a player receives, reroll it,
-- or alter the odds. A player who tampers with the animation gets a tampered
-- animation and the same item.

HatchConfig.Roulette = {
	--- Cue played on every change. Never on a timer of its own.
	sound = "RevealCycle",
	--- How long the wheel runs at full speed-to-slow before the fake-out, for
	--- the weakest and the strongest rarity. A rarer prize spins longer.
	spinCommon = 2.2,
	spinDivine = 2.6,
	--- The delay curve: first change to last. A ramp well above 1 keeps the
	--- blur going for most of the spin and then brakes hard, which reads as a
	--- wheel losing momentum rather than as a slideshow slowing down.
	firstDelay = 0.045,
	lastDelay = 0.5,
	ramp = 2.8,
	--- THE FAKE-OUT: the wheel appears to stop on a tempting item, holds, and
	--- then clicks over once more onto the prize.
	fakeOutDelay = 0.6,
	--- How long the winner holds, turning, before it becomes the real item.
	holdSeconds = 0.5,
	--- Largest dimension an item is fitted to before its size class applies.
	stageSpan = 7,
	--- Size classes the decoys are drawn from, tiny to huge, never the same
	--- class twice running.
	sizeClasses = { 0.35, 0.5, 0.7, 0.9, 1.15, 1.35, 1.6 },
	--- The winner is shown at hero size, whatever size it really is.
	finalClass = 1.15,
	--- How high above the pedestal the stage floats, in stage spans. Clears
	--- the largest class.
	stageLift = 1.0,
	--- Each change lands with a punch: it appears this much bigger and snaps
	--- down over punchSeconds (only once the wheel is slow enough to see it).
	punch = 1.25,
	punchSeconds = 0.12,
	--- The stage turns continuously, faster while the wheel is fast.
	spinFast = 9,
	spinSlow = 1.2,
	--- PlaybackSpeed of the tick: bright and quick at the start, heavier as the
	--- wheel slows, heaviest on the winning frame.
	pitchFirst = 1.35,
	pitchLast = 0.9,
	pitchFinal = 0.75,
	--- Tick loudness, as a share of the cue's own volume: quieter in the blur,
	--- where two dozen shots overlap, full as each change becomes distinct.
	volumeFirst = 0.45,
	volumeLast = 1.0,
	--- Neighbouring zones whose items join the decoys, each side.
	neighbourZones = 1,
	--- THE CAMERA. Distance from the stage in stage spans, height above it,
	--- the fly-in and fly-back times, how long it stays on the revealed item,
	--- how much closer it creeps during the spin, and the shake on the pop.
	cameraDistance = 2.4,
	cameraHeight = 0.35,
	cameraIn = 0.45,
	cameraOut = 0.5,
	cameraHold = 0.9,
	cameraCreep = 0.18,
	shake = 0.35,
	shakeSeconds = 0.3,
}

--- The delay AFTER each change, in order: the braking curve, then the
--- fake-out beat, then 0 for the winner (which is held, not waited on). Pure
--- and deterministic, so the server and the client agree to the frame on
--- where the swap lands.
function HatchConfig.rouletteDelays(rarity: string): { number }
	local cfg = HatchConfig.Roulette
	local rank = RarityConfig.rank(rarity)
	local top = math.max(#RarityConfig.Order, 1)
	local alpha = math.clamp((rank - 1) / math.max(top - 1, 1), 0, 1)
	local spin = cfg.spinCommon + (cfg.spinDivine - cfg.spinCommon) * alpha

	local out: { number } = {}
	local elapsed = 0
	while elapsed < spin and #out < 80 do
		local t = math.min(elapsed / spin, 1)
		local delay = cfg.firstDelay + (cfg.lastDelay - cfg.firstDelay) * (t ^ cfg.ramp)
		table.insert(out, delay)
		elapsed += delay
	end
	table.insert(out, cfg.fakeOutDelay)
	table.insert(out, 0)
	return out
end

--- Decorative fragments on the pop. Never collidable; fewer on a phone.
HatchConfig.MAX_FRAGMENTS = 12
HatchConfig.MAX_FRAGMENTS_MOBILE = 6

--- A reveal the client never finishes (crash, leave, destroyed pedestal) is
--- abandoned after this; the server result already stands.
HatchConfig.CLIENT_TIMEOUT = 8

-- ==========================================================
-- THE TIMER CARD
-- ==========================================================

--- How far above the container's highest visible point the card floats, and
--- how far away it is still drawn.
HatchConfig.CARD_CLEARANCE = 1.6
HatchConfig.CARD_MAX_DISTANCE = 140
--- The card pulses through its last ten seconds.
HatchConfig.CARD_PULSE_FROM = 10

return HatchConfig
