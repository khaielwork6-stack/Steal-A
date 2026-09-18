-- Compare sparse authored UV/position probes with the imported world geometry.
local specs = game:GetService("HttpService"):JSONDecode(INPUT_JSON)
local report = {}
for _, spec in specs do
    local model = game.ServerStorage.GameAssets.Guardians:FindFirstChild(spec.name)
    local part = model.Body
    local mesh = game:GetService("AssetService"):CreateEditableMeshAsync(part.MeshContent)
    local corners = {}
    for _, face in mesh:GetFaces() do
        local vs, us = mesh:GetFaceVertices(face), mesh:GetFaceUVs(face)
        for i, v in vs do
            table.insert(corners, {uv=mesh:GetUV(us[i]), position=part.CFrame:PointToWorldSpace(mesh:GetPosition(v) * (part.Size / part.MeshSize))})
        end
    end
    local bestError, bestFlip = math.huge, false
    for _, flip in {false, true} do
        local maximum = 0
        for _, probe in spec.probes do
            local uv = Vector2.new(probe.uv[1], flip and 1-probe.uv[2] or probe.uv[2])
            local target = Vector3.new(unpack(probe.position))
            local closest, distance = nil, math.huge
            for _, c in corners do
                local d = (c.uv-uv).Magnitude
                if d < distance then closest=c;distance=d end
            end
            maximum=math.max(maximum,(closest.position-target).Magnitude)
        end
        if maximum < bestError then bestError=maximum;bestFlip=flip end
    end
    mesh:Destroy()
    table.insert(report,{name=spec.name,maximumProbeError=bestError,uvFlipped=bestFlip,passed=bestError<.025})
end
return report
