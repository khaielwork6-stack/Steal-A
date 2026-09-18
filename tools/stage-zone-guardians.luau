-- Caller replaces INPUT_JSON with the published asset manifest as a Lua string.
-- Only imported art created by this task is normalized; live models stay in place.
assert(not game:GetService("RunService"):IsRunning(), "Edit mode required")
assert(game.PlaceId == 134344354476234 and game.CreatorId == 3774675, "Wrong place")
local specs = game:GetService("HttpService"):JSONDecode(INPUT_JSON)
local folder = game.ServerStorage:FindFirstChild("ZoneGuardianProduction") or Instance.new("Folder")
folder.Name = "ZoneGuardianProduction"
folder.Parent = game.ServerStorage
local report = {}
for _, spec in specs do
    assert(not folder:FindFirstChild(spec.name), "Already staged: " .. spec.name)
    local imported = game:GetService("InsertService"):LoadAsset(spec.modelId)
    local parts = {}
    for _, item in imported:GetDescendants() do
        assert(not item:IsA("LuaSourceContainer") and not item:IsA("Sound") and not item:IsA("Light"), "Unexpected executable content")
        if item:IsA("BasePart") then
            assert(item:IsA("MeshPart"), "Non-mesh geometry")
            table.insert(parts, item)
        end
    end
    assert(#parts == 1, "Expected one atlas mesh")
    local model = Instance.new("Model")
    model.Name = spec.name
    local body = parts[1]
    body.Name = "Body"
    body.Parent = model
    -- glTF import turns the authored mesh by 180 degrees about Y.
    body.CFrame = CFrame.Angles(0, math.pi, 0) * body.CFrame
    body.Anchored = false
    body.CanCollide = false
    body.CanTouch = false
    body.CanQuery = false
    body.Massless = true
    local surface = body:FindFirstChildOfClass("SurfaceAppearance")
    assert(surface, "Missing PBR surface")
    surface.AlphaMode = spec.name == "Zone02_GhostCaptain" and Enum.AlphaMode.Transparency or Enum.AlphaMode.Overlay
    local controller = Instance.new("AnimationController")
    controller.Parent = model
    Instance.new("Animator", controller)
    local frame, size = model:GetBoundingBox()
    body.CFrame = CFrame.new(-frame.X, size.Y / 2 - frame.Y, -frame.Z) * body.CFrame
    model.PrimaryPart = nil
    model.WorldPivot = CFrame.new(0, size.Y / 2, 0)
    model:SetAttribute("ArtSource", "zone-guardians-2026-09")
    model:SetAttribute("SkinnedGuardian", true)
    model:SetAttribute("WalkAnimationId", "rbxassetid://" .. spec.walkId)
    model:SetAttribute("IdleAnimationId", "rbxassetid://112229916598460")
    model:SetAttribute("SourceModelAssetId", tostring(spec.modelId))
    model:SetAttribute("AuthoredFront", "-Z")
    model:SetAttribute("TextureResolution", 1024)
    model.Parent = folder
    imported:Destroy()
    table.insert(report, {name=spec.name, size={size.X,size.Y,size.Z}, meshId=body.MeshId})
end
return report
