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
-- rebuilt on the exact frame the winning silhouette bursts.
--
-- The old constants above are kept because they still describe the reveal's
-- own phases; nothing should read them for scheduling.

--- Seconds from the reveal cue to the pop frame, for a prize of this rarity.
--- The server rebuilds the pedestal exactly here.
function HatchConfig.swapAt(rarity: string): number
	local steps = HatchConfig.silhouetteSteps(rarity)
	local delays = HatchConfig.cycleDelays(steps)
	-- Every wait EXCEPT the last. The final change lands on the prize and is
	-- held for holdSeconds instead of waiting delays[steps], so counting that
	-- entry would schedule the swap half a second after the burst and leave
	-- the client staring at a held silhouette waiting for an item to arrive.
	local roulette = 0
	for index = 1, steps - 1 do
		roulette += delays[index]
	end
	return HatchConfig.Reveal.lift.duration + roulette + HatchConfig.Silhouette.holdSeconds
end

--- The whole sequence, pop and item bounce included.
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

--- The single sound of the reveal, played by the owner's client on the pop
--- frame and nowhere else.
HatchConfig.POP_SOUND = "RevealPop"

-- ==========================================================
-- THE SILHOUETTE ROULETTE
-- ==========================================================
--
-- Between the lift and the pop, the container is replaced by a run of solid
-- black item silhouettes that cycles fast and slows to a stop on the real
-- reward.
--
-- IT IS PURE PRESENTATION. The server rolled the prize, committed it, started
-- the income and only then told the client to animate. The last silhouette is
-- READ from that payload, never chosen here, so nothing in this file or in
-- the controller that consumes it can change what a player receives, reroll
-- it, or alter the odds. A player who tampers with the animation gets a
-- tampered animation and the same item.

HatchConfig.Silhouette = {
	--- Cue played on every silhouette change. Never on a timer of its own.
	sound = "RevealCycle",
	--- Steps at the bottom and top of the rarity ladder. A Common settles
	--- quickly; a Divine keeps the player guessing for as long as the design
	--- allows. Both stay inside the eight-to-twelve the brief asks for.
	minSteps = 8,
	maxSteps = 12,
	--- The delay ramp, first switch to last. A ramp above 1 holds the fast
	--- flicker for longer and then slows hard, which is what reads as a wheel
	--- losing momentum rather than as a linear slideshow.
	firstDelay = 0.09,
	lastDelay = 0.50,
	ramp = 2.1,
	--- THE FAKE-OUT: one beat longer than the ramp would give, then one more
	--- change. The wheel looks like it has stopped, and has not.
	fakeOutDelay = 0.74,
	--- How long the winning silhouette holds before it becomes the item.
	holdSeconds = 0.62,
	--- Largest dimension a silhouette is fitted to before its size class is
	--- applied. Everything is framed against this, so a Colossal reward and a
	--- coin both arrive on screen at a readable size.
	stageSpan = 7,
	--- Size classes the decoys are drawn from. The brief asks for tiny through
	--- huge in the same cycle; without this every silhouette is fitted to the
	--- same box and the run reads as one shape flickering in place.
	sizeClasses = { 0.40, 0.60, 0.85, 1.0, 1.3, 1.65 },
	--- The winner is always shown at hero size, whatever size it really is.
	finalClass = 1.0,
	--- How high above the pedestal the stage floats, in stage spans.
	stageLift = 0.85,
	--- PlaybackSpeed of the cue: bright and quick at the start, heavier as the
	--- wheel slows, heaviest on the winning frame.
	pitchFirst = 1.16,
	pitchLast = 0.86,
	pitchFinal = 0.72,
	--- A reveal cannot be skipped before this much of it has played.
	minBeforeSkip = 1.2,
}

--- How many silhouettes this rarity's roulette runs through. A rarer prize
--- earns a longer wheel; the range is the brief's eight to twelve either way.
function HatchConfig.silhouetteSteps(rarity: string): number
	local rank = RarityConfig.rank(rarity)
	local top = math.max(#RarityConfig.Order, 1)
	local alpha = math.clamp((rank - 1) / math.max(top - 1, 1), 0, 1)
	local cfg = HatchConfig.Silhouette
	return math.floor(cfg.minSteps + (cfg.maxSteps - cfg.minSteps) * alpha + 0.5)
end

--- The delay AFTER each silhouette change, in order, including the fake-out
--- beat. Returned as a list so the caller simply walks it: change, play the
--- cue, wait delays[index]. Pure, so the pacing can be read off without
--- running a reveal.
function HatchConfig.cycleDelays(steps: number): { number }
	local cfg = HatchConfig.Silhouette
	local count = math.max(math.floor(steps), 3)
	local out = table.create(count)
	for index = 1, count do
		local alpha = (index - 1) / (count - 1)
		out[index] = cfg.firstDelay + (cfg.lastDelay - cfg.firstDelay) * (alpha ^ cfg.ramp)
	end
	-- The fake-out replaces the penultimate wait: the wheel appears to stop,
	-- then turns once more onto the prize.
	out[count - 1] = cfg.fakeOutDelay
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
