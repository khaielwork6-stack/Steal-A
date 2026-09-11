--!strict
--[[
	SpinWheelConfig
	The recurring free spin: the wheel art, the twelve segments, the odds and
	every timing the animation runs on.

	THE IMAGE ID LIVES HERE AND NOWHERE ELSE.
	`SpinWheelConfig.WHEEL_IMAGE` is the only place the wheel's art is named.
	Swapping the wheel is one line, and the segment table below must be re-read
	against the new picture when you do - the odds and the picture have to agree
	or the pointer will land on the wrong words.

	THE ODDS ARE THE SERVER'S. `weight` is the authoritative RNG: twelve weights
	summing to exactly 10,000, checked at start-up by `validate`. Nothing else in
	the game rolls this wheel, and no percentage is stored - a percentage is a
	rounded weight and would drift away from the thing it describes.

	SEGMENT NUMBERING follows the picture: segment 12 is at the TOP under the
	pointer, and the numbers run CLOCKWISE from there (1 at one o'clock, 3 at
	three o'clock, 6 at the bottom, 9 at nine o'clock). `angleFor` is that
	sentence written as arithmetic, and IMAGE_OFFSET_DEG is the one knob to turn
	if a re-exported wheel is rotated a few degrees inside its own square.

	Duplicated rewards keep their own segments on purpose: the wheel is a
	PICTURE with twelve physical wedges, so three separate "$1,500" slices have
	to be three separate entries or the pointer cannot land on the one the
	player is looking at.
]]

local SpinWheelConfig = {}

-- ==========================================================
-- THE ART
-- ==========================================================

--- THE WHEEL IMAGE. Change this one line to change the wheel's face.
---
--- IT IS THE IMAGE ID, NOT THE DECAL ID. Uploading a picture to Roblox
--- produces a DECAL, and a decal wraps an image; the id the website shows you
--- is the decal's. An ImageLabel cannot draw a decal - it silently renders
--- nothing at all, with no error and no warning, which is exactly what this
--- wheel did with the id it was first given (decal 122986758743506).
---
--- To get the image id out of a new decal, run this once in Studio:
---     local m = game:GetService("InsertService"):LoadAsset(<decal id>)
---     print(m:FindFirstChildWhichIsA("Decal").Texture)
--- and paste what it prints here.
---
--- Currently: the wheel decal 122986758743506, uploaded by 99 Dreams Studio
--- on 2026-09-10, whose image is the id below.
SpinWheelConfig.WHEEL_IMAGE = "rbxassetid://89920250248309"

--- The model the owner placed on every plot, and the spinning disc inside it.
SpinWheelConfig.MODEL_NAME = "Spin Wheel System"
SpinWheelConfig.WHEEL_PART_NAME = "Wheel"
--- The non-rotating part the countdown sign hangs from. The disc itself spins,
--- and a billboard adorned to it swings out of place with every landing angle.
SpinWheelConfig.SIGN_ANCHOR_NAME = "SignAnchor"

--- Sharper than the import's 50: the disc is ~13 studs across and the segment
--- text has to stay legible from where the prompt appears.
SpinWheelConfig.PIXELS_PER_STUD = 80

-- ==========================================================
-- THE TIMER
-- ==========================================================

--- Ten minutes of ACTUAL PLAY between spins. Accrued while the player is in
--- the server and nowhere else - see SpinWheelService, which is why this is a
--- duration and not a wall-clock interval.
SpinWheelConfig.PLAY_SECONDS = 600

--- How often the server folds elapsed play into the saved progress.
SpinWheelConfig.TICK_SECONDS = 1

-- ==========================================================
-- THE PROMPT
-- ==========================================================

SpinWheelConfig.PROMPT_HOLD = 0.6
SpinWheelConfig.PROMPT_RANGE = 16
SpinWheelConfig.PROMPT_ACTION = "Spin"
SpinWheelConfig.PROMPT_OBJECT = "Free Spin"

-- ==========================================================
-- THE SEGMENTS
-- ==========================================================

export type Kind = "cash" | "speed" | "guardian"
--- How loud the win is. `jackpot` and `rare` get the long celebration.
export type Tier = "normal" | "rare" | "jackpot"

export type Segment = {
	index: number,
	kind: Kind,
	--- Cash or Speed amount. Zero for a guardian.
	amount: number,
	--- BaseGuardianConfig key, for `kind == "guardian"` only.
	guardianKey: string?,
	--- What the wheel's own picture says on this wedge.
	label: string,
	--- The line the win banner shows: "YOU WON {won}!"
	won: string,
	tier: Tier,
	--- Out of 10,000.
	weight: number,
}

--- Clockwise from segment 1, exactly as the wheel is drawn.
SpinWheelConfig.Segments = {
	{ index = 1, kind = "cash", amount = 1500, label = "$1,500", won = "$1,500", tier = "normal", weight = 1500 },
	{ index = 2, kind = "speed", amount = 250, label = "250 Speed", won = "250 SPEED", tier = "normal", weight = 1000 },
	{ index = 3, kind = "cash", amount = 15000, label = "$15,000", won = "$15,000", tier = "normal", weight = 750 },
	{ index = 4, kind = "speed", amount = 250, label = "250 Speed", won = "250 SPEED", tier = "normal", weight = 1000 },
	{
		index = 5,
		kind = "guardian",
		amount = 0,
		guardianKey = "Panda",
		label = "Panda Guardian",
		won = "THE PANDA GUARDIAN",
		tier = "rare",
		weight = 120,
	},
	{ index = 6, kind = "cash", amount = 1500, label = "$1,500", won = "$1,500", tier = "normal", weight = 1500 },
	{ index = 7, kind = "speed", amount = 2500, label = "2,500 Speed", won = "2,500 SPEED", tier = "normal", weight = 800 },
	{ index = 8, kind = "cash", amount = 15000, label = "$15,000", won = "$15,000", tier = "normal", weight = 750 },
	{
		index = 9,
		kind = "guardian",
		amount = 0,
		guardianKey = "Tiger",
		label = "Tiger Guardian",
		won = "THE TIGER GUARDIAN",
		tier = "rare",
		weight = 50,
	},
	{ index = 10, kind = "speed", amount = 250, label = "250 Speed", won = "250 SPEED", tier = "normal", weight = 1000 },
	{ index = 11, kind = "cash", amount = 1500, label = "$1,500", won = "$1,500", tier = "normal", weight = 1500 },
	{
		index = 12,
		kind = "speed",
		amount = 1000000000,
		label = "1B SPEED",
		won = "1B SPEED",
		tier = "jackpot",
		weight = 30,
	},
} :: { Segment }

--- A guardian wedge landing on an animal the player ALREADY owns. Guardian
--- ownership is a set, not a count - there is no such thing as a second Tiger
--- - so a repeat pays this instead of silently landing on nothing.
SpinWheelConfig.DUPLICATE_GUARDIAN_SPEED = 5000

SpinWheelConfig.SEGMENT_COUNT = #SpinWheelConfig.Segments
SpinWheelConfig.SEGMENT_ARC = 360 / SpinWheelConfig.SEGMENT_COUNT

--- The weights sum to this exactly. Asserted by `validate`, not assumed.
SpinWheelConfig.TOTAL_WEIGHT = 10000

--- Colour per tier, for the win banner and the burst. Pulled from the palette
--- the rest of the game already uses for gold / rare / jackpot moments.
SpinWheelConfig.TierColors = {
	normal = Color3.fromRGB(255, 208, 96),
	rare = Color3.fromRGB(190, 130, 255),
	jackpot = Color3.fromRGB(126, 255, 214),
}

function SpinWheelConfig.segment(index: number): Segment?
	return SpinWheelConfig.Segments[index]
end

--- THE ROLL. `rng` is a Random the SERVER owns; there is no client path to it.
--- Walks the weights in order, so the mapping from a roll to a segment is
--- stable and reproducible with a seeded Random in a test.
function SpinWheelConfig.roll(rng: Random): number
	local ticket = rng:NextInteger(1, SpinWheelConfig.TOTAL_WEIGHT)
	local running = 0
	for _, segment in SpinWheelConfig.Segments do
		running += segment.weight
		if ticket <= running then
			return segment.index
		end
	end
	-- Unreachable while the weights sum to TOTAL_WEIGHT, which validate pins.
	return SpinWheelConfig.SEGMENT_COUNT
end

-- ==========================================================
-- THE GEOMETRY
-- ==========================================================
--
-- The disc is a Block part with a Cylinder mesh: its axis is the part's own
-- X, the art sits on the +X face, and rotating the part about that axis by a
-- POSITIVE angle turns the face anticlockwise as the player sees it.
--
-- A segment drawn at clockwise-angle f from the top appears, after a rotation
-- of t, at clockwise-angle (f - t). Landing it under the pointer therefore
-- means t = f, and the whole of the mapping is working out f.
--
-- THE HALF-WEDGE. The art's BOUNDARIES sit on the multiples of 30 - at zero
-- rotation the pointer is on the line between 12 and 1, not on the middle of
-- anything. So a segment's CENTRE is half a wedge back from its boundary:
--
--     f(i) = i x 30 - 15
--
-- which puts 1 at 15 degrees, 3 just above three o'clock, 6 just right of the
-- bottom and 9 just below nine o'clock - measured off the rendered wheel, not
-- assumed. Drop the -15 and every prize lands on the line between itself and
-- its neighbour, which is the one failure a wheel cannot get away with.

--- The one knob for a re-exported wheel whose art is rotated inside its own
--- square. Positive turns the LANDING anticlockwise. Leave at 0 for the
--- shipped image, whose half-wedge offset is already handled above.
SpinWheelConfig.IMAGE_OFFSET_DEG = 0

--- Radians the disc must be turned from its resting pose for the CENTRE of
--- `index` to sit under the pointer at the top.
function SpinWheelConfig.angleFor(index: number): number
	local centre = index * SpinWheelConfig.SEGMENT_ARC - SpinWheelConfig.SEGMENT_ARC / 2
	return math.rad(centre + SpinWheelConfig.IMAGE_OFFSET_DEG)
end

-- ==========================================================
-- THE SPIN
-- ==========================================================

--- THE LENGTH OF THE SPIN. Long enough to build and release, short enough
--- that a player earning one of these every ten minutes is never waiting on
--- it. Five turns in three and a half seconds is a genuine whip round the
--- wheel - the first turn is gone in under half a second - not a slow drift.
SpinWheelConfig.SPIN_SECONDS = 3.4
--- Whole turns before the landing angle.
SpinWheelConfig.SPIN_TURNS = 5
--- Fraction of the spin spent getting up to speed.
SpinWheelConfig.ACCEL_FRACTION = 0.13
--- The settle: the disc overshoots by this and rocks back. Well inside a
--- 30-degree wedge, so the bounce can never read as the wrong segment.
SpinWheelConfig.BOUNCE_DEG = 3.2
SpinWheelConfig.BOUNCE_SECONDS = 0.42
--- How long the win banner holds before it clears.
SpinWheelConfig.RESULT_SECONDS = 2.4

--- THE REVEAL, measured from the moment the owner's client starts the spin:
--- the whole spin, then the settle. The disc has stopped rocking and is at
--- rest on the winning wedge before anything names the prize - the banner,
--- the celebration and the prize itself all wait for this.
SpinWheelConfig.REVEAL_SECONDS = SpinWheelConfig.SPIN_SECONDS + SpinWheelConfig.BOUNCE_SECONDS
--- The server grants a beat after REVEAL_SECONDS. The client starts spinning
--- when SpinResult ARRIVES, up to a one-way trip after the server sent it, so
--- a grant timed to the server's own clock alone would land a few frames
--- before the wheel on a laggy connection - the Cash counter ticking up while
--- the disc is still settling. This keeps the order "lands, shows, pays".
SpinWheelConfig.GRANT_LATENCY_ALLOWANCE = 0.25

--- Everything the server must hold the wheel closed for: the spin, the
--- bounce, the banner and a beat.
SpinWheelConfig.LOCK_SECONDS = SpinWheelConfig.SPIN_SECONDS
	+ SpinWheelConfig.BOUNCE_SECONDS
	+ SpinWheelConfig.RESULT_SECONDS
	+ 0.6

--- Pitch the looping spin cue is played at, first frame to last. It rides the
--- wheel's own speed, so the ticking slows with the picture.
SpinWheelConfig.PITCH_FAST = 1.18
SpinWheelConfig.PITCH_SLOW = 0.72

-- ==========================================================
-- THE EASING
-- ==========================================================
--
-- A single named easing style cannot do what a wheel does: Quint-Out starts at
-- full speed (no launch) and Back-Out overshoots past the wedge. So the curve
-- is built from its VELOCITY instead - a short ramp up, then a long fifth-power
-- fall to zero - and integrated once, here, into a normalised lookup table.
--
-- Integrating and normalising is what makes the landing EXACT: whatever the
-- curve does in the middle, the table ends at precisely 1, so the disc always
-- stops on the angle the server chose.

local SAMPLES = 256

local function velocity(s: number): number
	local ramp = math.clamp(s / SpinWheelConfig.ACCEL_FRACTION, 0, 1)
	-- Smoothstep up, so the launch has no kink in it.
	ramp = ramp * ramp * (3 - 2 * ramp)
	local fall = (1 - s) ^ 5
	return ramp * fall
end

local curve: { number } = table.create(SAMPLES + 1)
do
	curve[1] = 0
	local running = 0
	for i = 1, SAMPLES do
		local a = velocity((i - 1) / SAMPLES)
		local b = velocity(i / SAMPLES)
		running += (a + b) / 2
		curve[i + 1] = running
	end
	local total = curve[SAMPLES + 1]
	for i = 1, SAMPLES + 1 do
		curve[i] /= total
	end
end

--- Fraction of the total spin travelled at time fraction `s`. 0 at 0, exactly
--- 1 at 1, and zero velocity at both ends.
function SpinWheelConfig.progress(s: number): number
	if s <= 0 then
		return 0
	end
	if s >= 1 then
		return 1
	end
	local scaled = s * SAMPLES
	local low = math.floor(scaled)
	local alpha = scaled - low
	return curve[low + 1] + (curve[low + 2] - curve[low + 1]) * alpha
end

return SpinWheelConfig
