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
	Bright, playful, low-poly - and no longer harsh. The harshness and the
	washed-out look are two different problems and this grade fixes them
	separately:

	  * OVEREXPOSURE is handled by exposure and bloom. Exposure sits slightly
	    negative and bloom only lifts genuine highlights (threshold 2.6), so
	    white paving and snow stop blooming into the sky.
	  * COLOUR comes from saturation, contrast and a lower outdoor ambient - a
	    high sky-fill was bleaching the greens flat. Saturation is +22% and
	    contrast +14%, which is what makes the grass read as grass.

	The previous pass fixed the first by attacking the second (saturation +6%,
	outdoor ambient 150) and the world went pastel. Nothing here goes dark,
	grey or realistic. NightController captures whatever these are on the
	client at start as "day", so the Night grade keys off them automatically.
]]

local Lighting = game:GetService("Lighting")

local EnvironmentService = {}

--- Lighting itself (mirrors default.project.json so a live server and the
--- Studio view agree).
local LIGHTING = {
	Brightness = 2.6,
	ExposureCompensation = -0.15,
	Ambient = Color3.fromRGB(78, 80, 92),
	OutdoorAmbient = Color3.fromRGB(128, 136, 152),
	EnvironmentDiffuseScale = 0.4,
	EnvironmentSpecularScale = 0.2,
	ShadowSoftness = 0.35,
	GlobalShadows = true,
	ClockTime = 14,
	GeographicLatitude = 0,
}

--- Post effects, by instance name under Lighting. Missing ones are created;
--- present ones are set, never duplicated.
local EFFECTS: { [string]: { class: string, props: { [string]: any } } } = {
	Bloom = {
		class = "BloomEffect",
		props = { Intensity = 0.16, Threshold = 2.6, Size = 20, Enabled = true },
	},
	WorldGrade = {
		class = "ColorCorrectionEffect",
		props = { Saturation = 0.22, Contrast = 0.14, Brightness = 0, TintColor = Color3.fromRGB(255, 255, 255), Enabled = true },
	},
	Atmosphere = {
		class = "Atmosphere",
		props = {
			-- Haze is what makes a far zone look grey. Kept light: enough for
			-- depth down a 2400-stud world, not enough to fog the colour out.
			Density = 0.15,
			Offset = 0.3,
			Color = Color3.fromRGB(200, 222, 255),
			Decay = Color3.fromRGB(110, 150, 205),
			Glare = 0,
			Haze = 0.3,
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
