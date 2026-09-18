-- Edit-only animation and skinning proof. Caller provides MODEL_NAME.
assert(not game:GetService("RunService"):IsRunning())
local source = game.ServerStorage.GameAssets.Guardians:FindFirstChild(MODEL_NAME)
assert(source, "Production model missing")
local clone = source:Clone()
clone.Name = "GuardianPlaybackProbe"
local part = clone:FindFirstChild("Body")
part.Anchored = true
clone.Parent = workspace
local animator = clone.AnimationController.Animator
local mesh = game:GetService("AssetService"):CreateEditableMeshAsync(part.MeshContent)
local samples, boneInstances = {}, {}
for _, bone in part:GetDescendants() do
    if bone:IsA("Bone") then boneInstances[bone.Name] = bone end
end
for _, vertex in mesh:GetVertices() do
    local world = part.CFrame:PointToWorldSpace(mesh:GetPosition(vertex) * (part.Size / part.MeshSize))
    local bones, weights = mesh:GetVertexBones(vertex), mesh:GetVertexBoneWeights(vertex)
    local bindings = {}
    for index, id in bones do
        local name = mesh:GetBoneName(id)
        local bone = assert(boneInstances[name], "Missing bone " .. name)
        table.insert(bindings, {bone=bone, weight=weights[index], localPoint=bone.WorldCFrame:PointToObjectSpace(world)})
    end
    table.insert(samples, bindings)
end
local report = {name=MODEL_NAME, vertices=#samples, clips={}}
for _, kind in {"Walk", "Idle"} do
    local animation = Instance.new("Animation")
    animation.AnimationId = source:GetAttribute(kind .. "AnimationId")
    local track = animator:LoadAnimation(animation)
    local deadline = os.clock() + 10
    while track.Length == 0 and os.clock() < deadline do task.wait(.1) end
    assert(track.Length > 0, "Animation did not load: " .. kind)
    track.Looped = true
    track:Play(0, 1, 0)
    local row = {kind=kind, length=track.Length, poses={}}
    for _, phase in {0, .25, .5, .75} do
        track.TimePosition = track.Length * phase
        animator:StepAnimations(.00001)
        local low, changed = math.huge, 0
        for _, bone in boneInstances do
            if bone.Transform ~= CFrame.identity then changed += 1 end
        end
        for _, bindings in samples do
            local position = Vector3.zero
            for _, binding in bindings do
                position += binding.bone.TransformedWorldCFrame:PointToWorldSpace(binding.localPoint) * binding.weight
            end
            low = math.min(low, position.Y)
        end
        table.insert(row.poses, {phase=phase, minimumY=low, changedBones=changed})
    end
    table.insert(report.clips, row)
    track:Stop(0)
    animator:StepAnimations(.00001)
    track:Destroy()
    animation:Destroy()
end
mesh:Destroy()
clone:Destroy()
return report
