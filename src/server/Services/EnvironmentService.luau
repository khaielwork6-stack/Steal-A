--!strict
--[[
	EnvironmentService
	The world's light, in one place.

	WHY A SERVICE AND NOT JUST THE PLACE FILE
	Lighting's own properties are set by the Rojo project (default.project.json)
	and land in Studio on sync. The post-processing effects under Lighting -
	Bloom, the colour grade, the atmosphere - are instances the place file owns,
	and a value typed into them in Studio survives only if the place is saved.
	Applying the same numbers here at server start makes the grade the code's
	and not the last person's Studio session: the game looks the same on every
	server whether or not the place was saved after a tweak.

	THE GRADE
	Bright, playful, low-poly - and no longer harsh. Brightness and exposure
	come down from the values that blew out the lime floors and white surfaces;
	bloom is reserved for genuine highlights (a higher threshold, a smaller
	size) instead of washing every pale part; saturation is pulled back from
	+22% to a touch, so the zones' own hues do the work. Nothing here goes dark,
	grey or realistic. NightController captures whatever these are on the
	client at start as "day", so the Night grade keys off them automatically.
]]

local Lighting = game:GetService("Lighting")

local EnvironmentService = {}

--- Lighting itself (mirrors default.project.json so a live server and the
--- Studio view agree).
local LIGHTING = {
	Brightness = 2.2,
	ExposureCompensation = -0.05,
	Ambient = Color3.fromRGB(88, 88, 96),
	OutdoorAmbient = Color3.fromRGB(150, 156, 170),
	EnvironmentDiffuseScale = 0.5,
	EnvironmentSpecularScale = 0.3,
	ShadowSoftness = 0.55,
	GlobalShadows = true,
	ClockTime = 14,
	GeographicLatitude = 0,
}

--- Post effects, by instance name under Lighting. Missing ones are created;
--- present ones are set, never duplicated.
local EFFECTS: { [string]: { class: string, props: { [string]: any } } } = {
	Bloom = {
		class = "BloomEffect",
		props = { Intensity = 0.22, Threshold = 2.2, Size = 18, Enabled = true },
	},
	WorldGrade = {
		class = "ColorCorrectionEffect",
		props = { Saturation = 0.06, Contrast = 0.06, Brightness = 0, TintColor = Color3.fromRGB(255, 255, 255), Enabled = true },
	},
	Atmosphere = {
		class = "Atmosphere",
		props = {
			Density = 0.24,
			Offset = 0.3,
			Color = Color3.fromRGB(210, 228, 255),
			Decay = Color3.fromRGB(120, 160, 210),
			Glare = 0,
			Haze = 0.6,
		},
	},
	SunRays = {
		class = "SunRaysEffect",
		props = { Intensity = 0.01, Spread = 0.6, Enabled = true },
	},
}

function EnvironmentService.apply()
	for key, value in LIGHTING do
		(Lighting :: any)[key] = value
	end
	for name, spec in EFFECTS do
		local effect = Lighting:FindFirstChild(name)
		if not effect or effect.ClassName ~= spec.class then
			if effect then
				effect:Destroy()
			end
			effect = Instance.new(spec.class)
			effect.Name = name
			effect.Parent = Lighting
		end
		for key, value in spec.props do
			pcall(function()
				(effect :: any)[key] = value
			end)
		end
	end
	-- Depth of field is left alone but never on: it blurs the far zones the
	-- landmarks are there to advertise.
	local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if dof then
		dof.Enabled = false
	end
end

function EnvironmentService.start()
	EnvironmentService.apply()
	print("[EnvironmentService] world grade applied")
end

return EnvironmentService
