-- Read-only production audit. Run through Studio MCP in Edit mode.
-- Do not install a draft until every requirement has evidence in this report.
local AssetService = game:GetService("AssetService")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")
assert(not game:GetService("RunService"):IsRunning(), "Guardian audit requires Edit mode")
assert(game.PlaceId == 134344354476234 and game.CreatorId == 3774675, "Wrong experience")

local specs = {
	{ "Zone01_NightWatchman", Vector3.new(5.2, 7, 3.3) },
	{ "Zone02_GhostCaptain", Vector3.new(5.8, 7.8, 3.2) },
	{ "Zone03_IronKnight", Vector3.new(7.4, 8.8, 4.2) },
	{ "Zone04_GreyAgent", Vector3.new(5.8, 10, 3.4) },
	{ "Zone05_FrostYeti", Vector3.new(10.5, 11.5, 5.8) },
	{ "Zone06_Mummy", Vector3.new(9.5, 14, 5.6) },
	{ "Zone07_IronTitan", Vector3.new(19.5, 17, 8.2) },
	{ "Zone08_VaultBot", Vector3.new(19, 20.5, 10.5) },
	{ "Zone09_LabMutant", Vector3.new(20, 24.5, 12) },
	{ "Zone10_Granny", Vector3.new(21, 29, 12.5) },
	{ "Zone11_WreckingForeman", Vector3.new(26, 34, 16.5) },
	{ "Zone12_SkyMarshal", Vector3.new(27, 40, 17) },
}
local assets = game.ServerStorage:FindFirstChild("GameAssets")
local folder = assets and assets:FindFirstChild("Guardians")
local ownership = {}
local function groupOwned(content)
	local id = tonumber(tostring(content):match("%d+"))
	if not id or id == 0 then return false end
	if ownership[id] == nil then
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.Asset)
		ownership[id] = ok and info.Creator.CreatorType == "Group"
			and tonumber(info.Creator.CreatorTargetId) == 3774675
	end
	return ownership[id]
end

local report = { allPassed = true, guardians = {} }
for _, spec in specs do
	local row = { name = spec[1], issues = {}, triangles = 0, meshParts = 0, bones = 0 }
	local function check(condition, message)
		if not condition then table.insert(row.issues, message) end
	end
	local model = folder and folder:FindFirstChild(spec[1])
	check(model and model:IsA("Model"), "Installed model missing")
	if model and model:IsA("Model") then
		local frame, size = model:GetBoundingBox()
		row.size = { size.X, size.Y, size.Z }
		check((size - spec[2]).Magnitude < 0.02, "Bounds differ from production.json")
		check(math.abs(frame.Position.Y - size.Y / 2) < 0.02, "Feet are not on Y=0")
		check(model:GetAttribute("ArtSource") == "zone-guardians-2026-09", "ArtSource missing")
		local controller = model:FindFirstChildOfClass("AnimationController")
		check(controller and controller:FindFirstChildOfClass("Animator"), "AnimationController/Animator missing")
		for _, attr in { "WalkAnimationId", "IdleAnimationId" } do
			check(groupOwned(model:GetAttribute(attr)), attr .. " is not verified group-owned")
		end
		for _, item in model:GetDescendants() do
			check(not item:IsA("LuaSourceContainer") and not item:IsA("Sound") and not item:IsA("Light"),
				"Forbidden script/sound/light: " .. item.Name)
			if item:IsA("Bone") then row.bones += 1 end
			if item:IsA("BasePart") then
				check(item:IsA("MeshPart"), "Non-mesh geometry: " .. item.Name)
				check(not item.Anchored and not item.CanCollide and item.Massless, "Unsafe part flags: " .. item.Name)
			end
			if item:IsA("MeshPart") then
				row.meshParts += 1
				check(groupOwned(item.MeshId), "Mesh ownership not verified: " .. item.Name)
				local ok, err = pcall(function()
					local mesh = AssetService:CreateEditableMeshAsync(item.MeshContent)
					row.triangles += #mesh:GetFaces()
					for _, vertex in mesh:GetVertices() do
						local weights = mesh:GetVertexBoneWeights(vertex)
						local bones = mesh:GetVertexBones(vertex)
						local total = 0
						for _, weight in weights do total += weight end
						check(#weights > 0 and #weights == #bones and #weights <= 4 and math.abs(total - 1) < 0.001,
							"Invalid vertex skin weights: " .. item.Name)
					end
					mesh:Destroy()
				end)
				check(ok, "Mesh validation unavailable: " .. tostring(err))
				local surface = item:FindFirstChildOfClass("SurfaceAppearance")
				check(surface ~= nil, "SurfaceAppearance missing: " .. item.Name)
				if surface then
					for _, map in { "ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap" } do
						local content = surface[map]
						check(groupOwned(content), map .. " ownership not verified: " .. item.Name)
						local imageOk, imageErr = pcall(function()
							local image = AssetService:CreateEditableImageAsync(Content.fromUri(content))
							check(image.Size == Vector2.new(1024, 1024), map .. " must be 1024 px")
							image:Destroy()
						end)
						check(imageOk, map .. " inspection unavailable: " .. tostring(imageErr))
					end
				end
			end
		end
		check(row.triangles > 0 and row.triangles < 4000, "Character triangle budget failed")
		check(row.bones > 0, "No instance bones")
	end
	row.passed = #row.issues == 0
	report.allPassed = report.allPassed and row.passed
	table.insert(report.guardians, row)
end
return HttpService:JSONEncode(report)
