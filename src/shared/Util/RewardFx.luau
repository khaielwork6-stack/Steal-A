--!strict
--[[
	RewardFx
	The shared look and motion of the two reward reveals: the DAILY REWARDS
	calendar and the WELCOME BACK offline popup (round3-ui-rewards).

	WHY A MODULE
	Both screens are "you got paid" moments and have to feel like one game:
	the same glossy plates, the same outline, the same rays, the same coins
	flying into the HUD cash counter. Drawn twice they would drift.

	THE LOOK (the purchased pack's, rebuilt in code)
	  * a dark outline plate with a bright two-tone gradient face inset 4 px,
	    a white gloss over the top half and the pack's studs texture;
	  * text in the pack's own FontFace (read off the pristine Index header),
	    white or gold, with a thick dark UIStroke;
	  * code placeholders (rays, flame, check mark, lock, clock) for art that
	    Codex will supply - RewardUiConfig keys switch each one to an image.

	MOTION RULES
	  * Short tweens only (0.15-0.5 s, Back / Quad); the only repeating ones
	    are infinite TweenService tweens and slow task loops, all owned by a
	    LoopSet that the caller stops when its panel hides.
	  * Nothing here runs per frame. Coin and confetti instances destroy
	    themselves when their tween ends.
	  * Callers check Effects.isReduced() before bursts; the helpers that are
	    pure decoration (confetti, coins) also no-op under it, as a backstop.

	CLIPPING. Decoration lives inside a caller-supplied, unrotated frame with
	ClipsDescendants (rotated children are clipped by an unrotated ancestor).
	The only thing drawn outside a panel is the coin flight, on its own
	transient overlay ScreenGui (RewardFxUI), because its whole point is to
	travel from the panel to the HUD.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local RewardUiConfig = require(ReplicatedStorage.Shared.Config.RewardUiConfig)
local Effects = require(script.Parent.Effects)
local ShopKit = require(script.Parent.ShopKit)
local UIAnim = require(script.Parent.UIAnim)

local RewardFx = {}

RewardFx.OUTLINE = Color3.fromRGB(20, 12, 36)
RewardFx.WHITE = Color3.fromRGB(255, 255, 255)
RewardFx.GOLD = Color3.fromRGB(255, 214, 64)
RewardFx.STUDS = "rbxassetid://76728843491214"

local CONFETTI_COLORS = {
	Color3.fromRGB(255, 214, 64),
	Color3.fromRGB(255, 94, 120),
	Color3.fromRGB(96, 240, 150),
	Color3.fromRGB(110, 190, 255),
	Color3.fromRGB(200, 130, 255),
	Color3.fromRGB(255, 255, 255),
}

-- ==========================================================
-- FONT
-- ==========================================================

local cachedFont: Font? = nil

--- The pack's header font, read off the PRISTINE Index panel in StarterGui
--- (a live panel may have been restyled). Falls back to FredokaOne, which is
--- what every older panel of ours uses.
function RewardFx.font(): Font
	local held = cachedFont
	if held then
		return held
	end
	local main = StarterGui:FindFirstChild("MainUI")
	local frames = main and main:FindFirstChild("Frames")
	local index = frames and frames:FindFirstChild("Index")
	local top = index and index:FindFirstChild("Top")
	local title = top and top:FindFirstChild("Title", true)
	local font = if title and title:IsA("TextLabel") then title.FontFace else Font.fromEnum(Enum.Font.FredokaOne)
	cachedFont = font
	return font
end

-- ==========================================================
-- PRIMITIVES
-- ==========================================================

function RewardFx.corner(parent: Instance, pixels: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, pixels)
	corner.Parent = parent
	return corner
end

function RewardFx.round(parent: Instance): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = parent
	return corner
end

function RewardFx.stroke(parent: Instance, thickness: number, color: Color3?): UIStroke
	local edge = Instance.new("UIStroke")
	edge.Thickness = thickness
	edge.Color = color or RewardFx.OUTLINE
	edge.LineJoinMode = Enum.LineJoinMode.Round
	if parent:IsA("GuiButton") then
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	end
	edge.Parent = parent
	return edge
end

function RewardFx.gradient(parent: Instance, top: Color3, bottom: Color3): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Parent = parent
	return gradient
end

function RewardFx.aspect(parent: Instance, ratio: number): UIAspectRatioConstraint
	local constraint = Instance.new("UIAspectRatioConstraint")
	constraint.AspectRatio = ratio
	constraint.Parent = parent
	return constraint
end

--- A plain, invisible container.
function RewardFx.box(parent: Instance, name: string, z: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.ZIndex = z
	frame.Parent = parent
	return frame
end

--- Centres `item` at (x, y) with size (w, h), all in scale.
function RewardFx.place(item: GuiObject, x: number, y: number, w: number, h: number)
	item.AnchorPoint = Vector2.new(0.5, 0.5)
	item.Position = UDim2.fromScale(x, y)
	item.Size = UDim2.fromScale(w, h)
end

--- Bold pack-font text with a thick dark outline.
function RewardFx.label(parent: Instance, name: string, text: string, color: Color3, maxSize: number, z: number): TextLabel
	local item = Instance.new("TextLabel")
	item.Name = name
	item.BackgroundTransparency = 1
	item.FontFace = RewardFx.font()
	item.Text = text
	item.TextColor3 = color
	item.TextScaled = true
	item.TextWrapped = true
	item.ZIndex = z
	local outline = Instance.new("UIStroke")
	outline.Thickness = if maxSize >= 28 then 3 else 2
	outline.Color = RewardFx.OUTLINE
	outline.LineJoinMode = Enum.LineJoinMode.Round
	outline.Parent = item
	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 8
	limit.MaxTextSize = maxSize
	limit.Parent = item
	item.Parent = parent
	return item
end

--- White-to-gold text fill (a gradient on a TextLabel tints its glyphs).
function RewardFx.goldText(item: TextLabel)
	item.TextColor3 = RewardFx.WHITE
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 220)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 226, 90)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 170, 30)),
	})
	gradient.Parent = item
end

function RewardFx.image(parent: Instance, name: string, id: string, z: number): ImageLabel
	local item = Instance.new("ImageLabel")
	item.Name = name
	item.BackgroundTransparency = 1
	item.Image = id
	item.ScaleType = Enum.ScaleType.Fit
	item.ZIndex = z
	item.Parent = parent
	return item
end

--- The pack plate: dark outline frame, bright gradient face inset by `inset`
--- pixels, a gloss over the top and the studs texture. Returns (plate, face,
--- faceGradient). Children go on the face.
function RewardFx.plate(parent: Instance, name: string, top: Color3, bottom: Color3, z: number, radius: number, inset: number?): (Frame, Frame, UIGradient)
	local pad = inset or 4
	local plate = Instance.new("Frame")
	plate.Name = name
	plate.BackgroundColor3 = RewardFx.OUTLINE
	plate.BorderSizePixel = 0
	plate.Size = UDim2.fromScale(1, 1)
	plate.ZIndex = z
	RewardFx.corner(plate, radius)

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.new(1, -pad * 2, 1, -pad * 2)
	face.BackgroundColor3 = RewardFx.WHITE
	face.BorderSizePixel = 0
	face.ZIndex = z + 1
	face.Parent = plate
	RewardFx.corner(face, math.max(2, radius - pad + 1))
	local gradient = RewardFx.gradient(face, top, bottom)

	local studs = RewardFx.image(face, "Studs", RewardFx.STUDS, z + 1)
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(26, 26)
	studs.ImageTransparency = 0.88
	studs.Size = UDim2.fromScale(1, 1)
	RewardFx.corner(studs, math.max(2, radius - pad + 1))

	local gloss = Instance.new("Frame")
	gloss.Name = "Gloss"
	gloss.BackgroundColor3 = RewardFx.WHITE
	gloss.BorderSizePixel = 0
	gloss.Size = UDim2.fromScale(1, 0.48)
	gloss.ZIndex = z + 1
	gloss.Parent = face
	RewardFx.corner(gloss, math.max(2, radius - pad + 1))
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.62),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = gloss

	plate.Parent = parent
	return plate, face, gradient
end

-- ==========================================================
-- LOOPS
-- ==========================================================

export type LoopSet = {
	--- Plays a (usually repeating) tween owned by this set. `reset` runs when
	--- the set stops, to put the property back at rest.
	play: (tween: Tween, reset: (() -> ())?) -> Tween,
	--- Runs fn, then waits `seconds`, until the set stops. fn may yield.
	every: (seconds: number, fn: () -> ()) -> (),
	--- True while a loop started before now should keep going.
	alive: (token: number) -> boolean,
	token: () -> number,
	stop: () -> (),
}

--- A bag of running decoration. stop() cancels every tween and ends every
--- loop (each checks its token), then runs the resets.
function RewardFx.loopSet(): LoopSet
	local tweens: { Tween } = {}
	local resets: { () -> () } = {}
	local generation = 0
	local function play(tween: Tween, reset: (() -> ())?): Tween
		table.insert(tweens, tween)
		if reset then
			table.insert(resets, reset)
		end
		tween:Play()
		return tween
	end
	local function every(seconds: number, fn: () -> ())
		local mine = generation
		task.spawn(function()
			while generation == mine do
				fn()
				if generation ~= mine then
					break
				end
				task.wait(seconds)
			end
		end)
	end
	local function alive(token: number): boolean
		return token == generation
	end
	local function token(): number
		return generation
	end
	local function stop()
		generation += 1
		for _, tween in tweens do
			tween:Cancel()
		end
		table.clear(tweens)
		for _, reset in resets do
			pcall(reset)
		end
		table.clear(resets)
	end
	return {
		play = play,
		every = every,
		alive = alive,
		token = token,
		stop = stop,
	}
end

--- An endless back-and-forth tween of `props` (Sine).
function RewardFx.yoyo(target: Instance, seconds: number, props: { [string]: any }): Tween
	return TweenService:Create(target, TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), props)
end

--- An endless linear turn.
function RewardFx.spin(target: GuiObject, seconds: number): Tween
	target.Rotation = 0
	return TweenService:Create(target, TweenInfo.new(seconds, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), { Rotation = 360 })
end

-- ==========================================================
-- DECORATION (code placeholders for Codex art)
-- ==========================================================

--- A sunburst, square, centred in `parent`. Rotate the returned frame.
function RewardFx.rays(parent: Instance, name: string, color: Color3, z: number, transparency: number?): Frame
	local holder = RewardFx.box(parent, name, z)
	RewardFx.place(holder, 0.5, 0.5, 1, 1)
	RewardFx.aspect(holder, 1)
	local alpha = transparency or 0.35
	if RewardUiConfig.hasArt(RewardUiConfig.RAYS_IMAGE) then
		local art = RewardFx.image(holder, "Art", RewardUiConfig.RAYS_IMAGE, z)
		art.Size = UDim2.fromScale(1, 1)
		art.ImageColor3 = color
		art.ImageTransparency = alpha
		return holder
	end
	-- Placeholder: 9 bars through the centre = 18 rays, each fading out
	-- towards its tip.
	local count = 9
	for index = 1, count do
		local bar = Instance.new("Frame")
		bar.Name = "Ray"
		bar.BackgroundColor3 = color
		bar.BorderSizePixel = 0
		bar.ZIndex = z
		RewardFx.place(bar, 0.5, 0.5, 0.075, 1)
		bar.Rotation = (index - 1) * (180 / count)
		local fade = Instance.new("UIGradient")
		fade.Rotation = 90
		fade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, alpha + (1 - alpha) * 0.35),
			NumberSequenceKeypoint.new(0.5, alpha),
			NumberSequenceKeypoint.new(0.7, alpha + (1 - alpha) * 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		fade.Parent = bar
		bar.Parent = holder
	end
	return holder
end

--- A soft round glow (a circle whose edge fades out).
function RewardFx.glow(parent: Instance, name: string, color: Color3, z: number, transparency: number): Frame
	local disc = Instance.new("Frame")
	disc.Name = name
	disc.BackgroundColor3 = color
	disc.BackgroundTransparency = transparency
	disc.BorderSizePixel = 0
	disc.ZIndex = z
	RewardFx.place(disc, 0.5, 0.5, 1, 1)
	RewardFx.aspect(disc, 1)
	RewardFx.round(disc)
	local fade = Instance.new("UIGradient")
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = disc
	disc.Parent = parent
	return disc
end

--- A diagonal highlight strip clipped to `parent` (which should have a
--- UICorner-free rectangle or be small enough that the corners don't show).
--- Sweep it with RewardFx.sweep.
function RewardFx.sheen(parent: Instance, z: number): Frame
	local clip = RewardFx.box(parent, "SheenClip", z)
	clip.ClipsDescendants = true
	local bar = Instance.new("Frame")
	bar.Name = "Sheen"
	bar.BackgroundColor3 = RewardFx.WHITE
	bar.BorderSizePixel = 0
	bar.ZIndex = z
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromScale(-0.35, 0.5)
	bar.Size = UDim2.fromScale(0.16, 2)
	bar.Rotation = 20
	local fade = Instance.new("UIGradient")
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = bar
	bar.Parent = clip
	return bar
end

--- One pass of a sheen across its clip. Yields until it has crossed.
function RewardFx.sweep(bar: Frame, seconds: number?)
	bar.Position = UDim2.fromScale(-0.35, 0.5)
	local tween = TweenService:Create(bar, TweenInfo.new(seconds or 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Position = UDim2.fromScale(1.35, 0.5),
	})
	tween:Play()
	tween.Completed:Wait()
end

--- One teardrop layer: a circle with a 45-degree square on top whose upper
--- corner is the tip. `d` is the circle diameter and (cx, cy) its centre, in
--- fractions of the square holder.
local function drop(holder: Frame, name: string, d: number, cx: number, cy: number, color: Color3, z: number)
	local ball = Instance.new("Frame")
	ball.Name = name .. "Ball"
	ball.BackgroundColor3 = color
	ball.BorderSizePixel = 0
	ball.ZIndex = z
	RewardFx.place(ball, cx, cy, d, d)
	RewardFx.round(ball)
	ball.Parent = holder
	local tip = Instance.new("Frame")
	tip.Name = name .. "Tip"
	tip.BackgroundColor3 = color
	tip.BorderSizePixel = 0
	tip.ZIndex = z
	tip.Rotation = 45
	RewardFx.place(tip, cx, cy - d * 0.2, d * 0.66, d * 0.66)
	RewardFx.corner(tip, 3)
	tip.Parent = holder
end

--- The streak flame: art when RewardUiConfig.FLAME_ICON is set, otherwise
--- three layered teardrops (red-orange, orange, yellow) on a dark outline.
function RewardFx.flame(parent: Instance, z: number): Frame
	local holder = RewardFx.box(parent, "Flame", z)
	RewardFx.aspect(holder, 1)
	if RewardUiConfig.hasArt(RewardUiConfig.FLAME_ICON) then
		local art = RewardFx.image(holder, "Art", RewardUiConfig.FLAME_ICON, z)
		art.Size = UDim2.fromScale(1, 1)
		return holder
	end
	drop(holder, "Outline", 0.72, 0.5, 0.6, RewardFx.OUTLINE, z)
	drop(holder, "Outer", 0.6, 0.5, 0.6, Color3.fromRGB(255, 84, 36), z + 1)
	drop(holder, "Middle", 0.42, 0.5, 0.68, Color3.fromRGB(255, 160, 40), z + 2)
	drop(holder, "Core", 0.24, 0.5, 0.76, Color3.fromRGB(255, 238, 110), z + 3)
	return holder
end

--- A round green stamp with a white check mark (two bars).
function RewardFx.checkMark(parent: Instance, z: number): Frame
	local holder = RewardFx.box(parent, "Check", z)
	RewardFx.aspect(holder, 1)
	local disc = Instance.new("Frame")
	disc.Name = "Disc"
	disc.BackgroundColor3 = RewardFx.WHITE
	disc.BorderSizePixel = 0
	disc.ZIndex = z
	disc.Size = UDim2.fromScale(1, 1)
	RewardFx.round(disc)
	RewardFx.gradient(disc, Color3.fromRGB(110, 245, 140), Color3.fromRGB(24, 170, 80))
	RewardFx.stroke(disc, 3)
	disc.Parent = holder
	local function bar(x: number, y: number, length: number, angle: number)
		local stick = Instance.new("Frame")
		stick.Name = "Stroke"
		stick.BackgroundColor3 = RewardFx.WHITE
		stick.BorderSizePixel = 0
		stick.ZIndex = z + 1
		RewardFx.place(stick, x, y, length, 0.13)
		stick.Rotation = angle
		RewardFx.round(stick)
		stick.Parent = holder
	end
	bar(0.36, 0.585, 0.25, 45)
	bar(0.585, 0.5, 0.48, -48)
	return holder
end

--- A small padlock.
function RewardFx.lock(parent: Instance, z: number): Frame
	local holder = RewardFx.box(parent, "Lock", z)
	RewardFx.aspect(holder, 1)
	local shackle = Instance.new("Frame")
	shackle.Name = "Shackle"
	shackle.BackgroundTransparency = 1
	shackle.ZIndex = z
	RewardFx.place(shackle, 0.5, 0.36, 0.46, 0.5)
	RewardFx.round(shackle)
	RewardFx.stroke(shackle, 3, Color3.fromRGB(200, 206, 220))
	shackle.Parent = holder
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundColor3 = RewardFx.WHITE
	body.BorderSizePixel = 0
	body.ZIndex = z + 1
	RewardFx.place(body, 0.5, 0.68, 0.74, 0.52)
	RewardFx.corner(body, 4)
	RewardFx.gradient(body, Color3.fromRGB(230, 234, 244), Color3.fromRGB(140, 148, 168))
	RewardFx.stroke(body, 2)
	body.Parent = holder
	local hole = Instance.new("Frame")
	hole.Name = "Keyhole"
	hole.BackgroundColor3 = RewardFx.OUTLINE
	hole.BorderSizePixel = 0
	hole.ZIndex = z + 2
	RewardFx.place(hole, 0.5, 0.45, 0.22, 0.3)
	RewardFx.round(hole)
	hole.Parent = body
	return holder
end

--- A clock face with two hands.
function RewardFx.clock(parent: Instance, z: number): Frame
	local holder = RewardFx.box(parent, "Clock", z)
	RewardFx.aspect(holder, 1)
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.BackgroundColor3 = RewardFx.WHITE
	face.BorderSizePixel = 0
	face.ZIndex = z
	face.Size = UDim2.fromScale(1, 1)
	RewardFx.round(face)
	RewardFx.gradient(face, Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 220, 255))
	RewardFx.stroke(face, 2.5)
	face.Parent = holder
	-- A GuiObject turns about its own centre, so each hand sits in a
	-- full-size holder that does the turning.
	local function hand(length: number, angle: number)
		local pivot = RewardFx.box(holder, "Hand", z + 1)
		pivot.Rotation = angle
		local stick = Instance.new("Frame")
		stick.Name = "Stick"
		stick.BackgroundColor3 = RewardFx.OUTLINE
		stick.BorderSizePixel = 0
		stick.ZIndex = z + 1
		stick.AnchorPoint = Vector2.new(0.5, 1)
		stick.Position = UDim2.fromScale(0.5, 0.54)
		stick.Size = UDim2.fromScale(0.11, length)
		RewardFx.round(stick)
		stick.Parent = pivot
	end
	hand(0.34, 0)
	hand(0.26, 90)
	return holder
end

-- ==========================================================
-- BURSTS
-- ==========================================================

--- Confetti thrown out of (x, y) (scale in `layer`, which must clip).
function RewardFx.confetti(layer: GuiObject, x: number, y: number, count: number)
	if Effects.isReduced() or count <= 0 then
		return
	end
	local size = layer.AbsoluteSize
	local unit = math.max(4, math.min(size.X, size.Y) * 0.022)
	for _ = 1, count do
		local piece = Instance.new("Frame")
		piece.Name = "Confetti"
		piece.BackgroundColor3 = CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)]
		piece.BorderSizePixel = 0
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = UDim2.fromScale(x, y)
		piece.Size = UDim2.fromOffset(unit, unit * 1.8)
		piece.Rotation = math.random(0, 180)
		piece.ZIndex = layer.ZIndex + 2
		piece.Parent = layer
		local angle = math.random() * math.pi * 2
		local reach = 0.12 + math.random() * 0.22
		local aspect = if size.X > 0 then size.Y / size.X else 1
		local target = UDim2.fromScale(x + math.cos(angle) * reach * aspect, y + math.sin(angle) * reach - 0.05)
		local fly = TweenService:Create(piece, TweenInfo.new(0.5 + math.random() * 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = target,
			Rotation = piece.Rotation + math.random(-260, 260),
		})
		fly:Play()
		fly.Completed:Once(function()
			local fall = TweenService:Create(piece, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = target + UDim2.fromScale(0, 0.08),
				BackgroundTransparency = 1,
			})
			fall:Play()
			fall.Completed:Once(function()
				piece:Destroy()
			end)
		end)
	end
end

--- A sunburst that flares behind (x, y) in `layer` and fades.
function RewardFx.flare(layer: GuiObject, x: number, y: number, diameter: number, color: Color3)
	if Effects.isReduced() then
		return
	end
	local holder = RewardFx.box(layer, "Flare", layer.ZIndex + 1)
	RewardFx.place(holder, x, y, diameter, diameter)
	RewardFx.aspect(holder, 1)
	local rays = RewardFx.rays(holder, "Rays", color, layer.ZIndex + 1, 0.25)
	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = holder
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	TweenService:Create(rays, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Rotation = 70 }):Play()
	task.delay(0.55, function()
		for _, bar in rays:GetDescendants() do
			if bar:IsA("Frame") then
				TweenService:Create(bar, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
			elseif bar:IsA("ImageLabel") then
				TweenService:Create(bar, TweenInfo.new(0.5), { ImageTransparency = 1 }):Play()
			end
		end
		task.delay(0.55, function()
			holder:Destroy()
		end)
	end)
end

--- "+$1.2M" rising out of (x, y) in `layer`, counting up from 0.
function RewardFx.risingAmount(layer: GuiObject, x: number, y: number, amount: number, format: (number) -> string, color: Color3)
	local text = RewardFx.label(layer, "Gain", format(0), color, 44, layer.ZIndex + 5)
	RewardFx.place(text, x, y, 0.5, 0.16)
	text:SetAttribute("_CountValue", 0)
	local reduced = Effects.isReduced()
	if reduced then
		text.Text = format(amount)
	else
		UIAnim.countTo(text, amount, format, 0.7)
		UIAnim.punch(text, 0.3)
		TweenService:Create(text, TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(x, y - 0.12),
		}):Play()
	end
	task.delay(if reduced then 1.2 else 1.3, function()
		local stroke = text:FindFirstChildOfClass("UIStroke")
		if stroke then
			TweenService:Create(stroke, TweenInfo.new(0.35), { Transparency = 1 }):Play()
		end
		local fade = TweenService:Create(text, TweenInfo.new(0.35), { TextTransparency = 1 })
		fade:Play()
		fade.Completed:Once(function()
			text:Destroy()
		end)
	end)
end

-- ==========================================================
-- COINS TO THE HUD
-- ==========================================================

local overlay: ScreenGui? = nil

local function fxOverlay(): ScreenGui?
	local held = overlay
	if held and held.Parent then
		return held
	end
	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "RewardFxUI"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 60
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = playerGui
	overlay = screen
	return screen
end

--- The centre of a GuiObject in full-screen (inset-ignoring) pixels.
function RewardFx.screenCenter(gui: GuiObject): Vector2
	local center = gui.AbsolutePosition + gui.AbsoluteSize / 2
	local screen = gui:FindFirstAncestorOfClass("ScreenGui")
	if screen and not screen.IgnoreGuiInset then
		local inset = GuiService:GetGuiInset()
		center += inset
	end
	return center
end

--- The HUD counter a reward lands in: MainUI.Bottom.Currencies.<name>
--- ("Cash" or "Speed"), or nil when the pack layout is not there.
function RewardFx.hudCounter(name: string): GuiObject?
	local ui = ShopKit.mainUi()
	local bottom = ui and ui:FindFirstChild("Bottom")
	local currencies = bottom and bottom:FindFirstChild("Currencies", true)
	local counter = currencies and currencies:FindFirstChild(name)
	if counter and counter:IsA("GuiObject") and counter.AbsoluteSize.X > 0 then
		return counter
	end
	return nil
end

--- Coins burst out of `from` and fly into the HUD counter `counterName`
--- (the top of the screen if it is missing). The counter gets a punch as the
--- first coin lands. No-op under Reduced Effects.
function RewardFx.flyToHud(from: Vector2, counterName: string, image: string, count: number)
	if Effects.isReduced() or count <= 0 then
		return
	end
	local screen = fxOverlay()
	if not screen then
		return
	end
	local counter = RewardFx.hudCounter(counterName)
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local to = if counter then RewardFx.screenCenter(counter) else Vector2.new(viewport.X / 2, 40)
	local side = math.clamp(math.floor(math.min(viewport.X, viewport.Y) * 0.05), 22, 44)
	local landed = false
	for index = 1, count do
		local coin = Instance.new("ImageLabel")
		coin.Name = "Coin"
		coin.BackgroundTransparency = 1
		coin.Image = image
		coin.ScaleType = Enum.ScaleType.Fit
		coin.AnchorPoint = Vector2.new(0.5, 0.5)
		coin.Position = UDim2.fromOffset(from.X, from.Y)
		coin.Size = UDim2.fromOffset(side * 0.4, side * 0.4)
		coin.Rotation = math.random(-30, 30)
		coin.ZIndex = 5
		coin.Parent = screen
		local angle = math.random() * math.pi * 2
		local reach = side * (1.2 + math.random() * 1.6)
		local spread = from + Vector2.new(math.cos(angle), math.sin(angle)) * reach
		local out = TweenService:Create(coin, TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.fromOffset(spread.X, spread.Y),
			Size = UDim2.fromOffset(side, side),
		})
		out:Play()
		out.Completed:Once(function()
			task.wait(0.05 + index * 0.035)
			if not coin.Parent then
				return
			end
			local home = TweenService:Create(coin, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.fromOffset(to.X, to.Y),
				Size = UDim2.fromOffset(side * 0.55, side * 0.55),
				Rotation = coin.Rotation + math.random(-90, 90),
			})
			home:Play()
			home.Completed:Once(function()
				coin:Destroy()
				if counter and not landed then
					landed = true
					UIAnim.punch(counter, 0.14)
				end
			end)
		end)
	end
end

--- The coin art: Codex's coin, else the pack's cash stack.
function RewardFx.coinImage(): string
	return if RewardUiConfig.hasArt(RewardUiConfig.COIN_ICON) then RewardUiConfig.COIN_ICON else ShopKit.Icons.Cash
end

return RewardFx
