--!strict
-- Server-owned Animator tracks for the authored Round 3 pet rigs. No IDs are
-- invented: absent/unloaded tracks leave the existing procedural pose in charge.
local PetAnimationTracks = {}

export type Clips = { idle: string, walk: string, run: string, attack: string, celebrate: string }
export type Player = {
	update: (state: string, speed: number, now: number) -> boolean,
	defend: (now: number) -> (),
	destroy: () -> (),
}

function PetAnimationTracks.attach(model: Model, clips: Clips?): Player?
	local shell = model:FindFirstChild("Shell")
	if not clips or not shell or not shell:IsA("Model") or shell:GetAttribute("PetRig") ~= true then return nil end
	local humanoid = shell:FindFirstChildWhichIsA("Humanoid", true)
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then return nil end
	local tracks: { [string]: AnimationTrack } = {}
	for key, id in clips :: { [string]: string } do
		if id == "rbxassetid://0" or not id:match("^rbxassetid://%d+$") then continue end
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, result = pcall(function() return animator:LoadAnimation(animation) end)
		animation:Destroy()
		if ok then
			local track = result :: AnimationTrack
			track.Looped = key == "idle" or key == "walk" or key == "run"
			track.Priority = if key == "idle" then Enum.AnimationPriority.Idle
				elseif track.Looped then Enum.AnimationPriority.Movement else Enum.AnimationPriority.Action
			tracks[key] = track
		else
			warn(`[PetAnimationTracks] {model.Name} {key}: {result}`)
		end
	end
	if next(tracks) == nil then return nil end
	local current: AnimationTrack? = nil
	local attackUntil = 0
	local celebrateUntil = 0
	local celebratePending = false
	local destroyed = false
	local function ready(key: string): AnimationTrack?
		local track = tracks[key]
		return if track and track.Length > 0 then track else nil
	end
	local function switch(track: AnimationTrack?, rate: number): boolean
		if current ~= track then
			if current then current:Stop(0.15) end
			current = track
			if track then track:Play(0.15, 1, rate) end
		elseif track and math.abs(track.Speed - rate) > 0.05 then
			track:AdjustSpeed(rate)
		end
		local active = track ~= nil
		if model:GetAttribute("PetAnimationActive") ~= active then model:SetAttribute("PetAnimationActive", active) end
		return active
	end
	return {
		update = function(state: string, speed: number, now: number): boolean
			if destroyed then return false end
			if now < attackUntil then return switch(ready("attack"), 1) end
			if state == "Idle" and celebratePending then
				celebratePending = false
				local track = ready("celebrate")
				if track then celebrateUntil = now + track.Length end
			end
			if state == "Idle" and now < celebrateUntil then return switch(ready("celebrate"), 1) end
			if state == "Idle" or state == "Alert" or speed < 0.5 then return switch(ready("idle"), 1) end
			-- Animation cadence only; actual chase speed remains with the service.
			local running = speed >= 22
			local track = if running then ready("run") or ready("walk") else ready("walk") or ready("run")
			local nominal = if track == tracks.run then 28 else 12
			return switch(track, math.clamp(speed / nominal, 0.5, 2))
		end,
		defend = function(now: number)
			celebratePending = true
			local track = ready("attack")
			attackUntil = now + (if track then track.Length else 0)
			if track then
				if current == track then
					track:Stop(0)
					current = nil
				end
				switch(track, 1)
			end
		end,
		destroy = function()
			destroyed = true
			for _, track in tracks do
				track:Stop(0)
				track:Destroy()
			end
			table.clear(tracks)
		end,
	}
end

return PetAnimationTracks
