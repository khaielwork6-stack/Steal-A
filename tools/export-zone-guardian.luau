-- Losslessly export the selected AI draft through chunked MCP responses.
local name = "Zone01_NightWatchman"
local source = workspace.ZoneGuardianReview:FindFirstChild(name .. "_AI_Draft")
assert(source and not game:GetService("RunService"):IsRunning())
local assets = game:GetService("AssetService")
local encoding = game:GetService("EncodingService")
local http = game:GetService("HttpService")
local exports = game.ServerStorage:FindFirstChild("ZoneGuardianTransfers") or Instance.new("Folder")
exports.Name = "ZoneGuardianTransfers"
exports.Parent = game.ServerStorage
local target = exports:FindFirstChild(name) or Instance.new("Folder")
target.Name = name
target.Parent = exports
local manifest = { name = name, files = {}, parts = {} }
local function save(key, bytes)
	local encoded = buffer.tostring(encoding:Base64Encode(encoding:CompressBuffer(bytes, Enum.CompressionAlgorithm.Zstd, 3)))
	local count = math.ceil(#encoded / 24000)
	for i = 1, count do
		local chunk = target:FindFirstChild(key .. "_" .. i) or Instance.new("StringValue")
		chunk.Name = key .. "_" .. i
		chunk.Value = encoded:sub((i - 1) * 24000 + 1, i * 24000)
		chunk.Parent = target
	end
	table.insert(manifest.files, { name = key, chunks = count, length = #encoded })
end
local frame, size = source:GetBoundingBox()
local geometry = { parts = {}, bounds = { size.X, size.Y, size.Z } }
local parts = {}
for _, p in source:GetDescendants() do if p:IsA("MeshPart") then table.insert(parts, p) end end
table.sort(parts, function(a, b) return a.Name < b.Name end)
for index, p in parts do
	local mesh = assets:CreateEditableMeshAsync(p.MeshContent)
	local part = { name = p.Name, faces = {} }
	-- The generator authored this draft facing +Z. Rotate the complete mesh
	-- into the required -Z orientation before baking or adding bind poses.
	local transform = CFrame.Angles(0, math.pi, 0) * CFrame.new(0, size.Y / 2, 0) * frame:Inverse() * p.CFrame
	for _, f in mesh:GetFaces() do
		local vs, ns, us = mesh:GetFaceVertices(f), mesh:GetFaceNormals(f), mesh:GetFaceUVs(f)
		local face = {}
		for j, v in vs do
			local pos = transform:PointToWorldSpace(mesh:GetPosition(v) * (p.Size / p.MeshSize))
			local normal = transform:VectorToWorldSpace(mesh:GetNormal(ns[j]))
			local uv = mesh:GetUV(us[j])
			table.insert(face, { pos.X, pos.Y, pos.Z, normal.X, normal.Y, normal.Z, uv.X, uv.Y })
		end
		table.insert(part.faces, face)
	end
	mesh:Destroy()
	table.insert(geometry.parts, part)
	local image = assets:CreateEditableImageAsync(p.TextureContent)
	local key = "texture_" .. index
	save(key, image:ReadPixelsBuffer(Vector2.zero, image.Size))
	table.insert(manifest.parts, { name = p.Name, texture = key, textureSize = { image.Size.X, image.Size.Y } })
	image:Destroy()
end
save("mesh", buffer.fromstring(http:JSONEncode(geometry)))
return http:JSONEncode(manifest)
