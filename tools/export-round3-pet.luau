-- Change only animal before running in Studio Edit. All export chunks are local.
local animal = "Cat"
local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")
local EncodingService = game:GetService("EncodingService")
local drafts = game.ServerStorage.Round3GenerationDrafts
local model = drafts[animal .. "Draft"]
local exports = drafts:FindFirstChild(animal .. "Export") or Instance.new("Folder")
exports.Name = animal .. "Export"
exports.Parent = drafts
local manifest = { name = animal, files = {}, parts = {} }
local function save(name, raw)
	local encoded = buffer.tostring(EncodingService:Base64Encode(EncodingService:CompressBuffer(raw, Enum.CompressionAlgorithm.Zstd, 3)))
	local count = math.ceil(#encoded / 90000)
	for index = 1, count do
		local key = name .. "_" .. index
		local value = exports:FindFirstChild(key) or Instance.new("StringValue")
		value.Name = key
		value.Value = encoded:sub((index - 1) * 90000 + 1, index * 90000)
		value.Parent = exports
	end
	table.insert(manifest.files, { name = name, chunks = count, length = #encoded })
end
local parts = {}
for _, part in model:GetDescendants() do
	if not part:IsA("MeshPart") then continue end
	local mesh = AssetService:CreateEditableMeshAsync(part.MeshContent)
	local faces = {}
	for _, faceId in mesh:GetFaces() do
		local vertices = mesh:GetFaceVertices(faceId)
		local normals = mesh:GetFaceNormals(faceId)
		local uvs = mesh:GetFaceUVs(faceId)
		local face = {}
		for index, vertex in vertices do
			local p = mesh:GetPosition(vertex)
			local n = mesh:GetNormal(normals[index])
			local uv = mesh:GetUV(uvs[index])
			table.insert(face, { p.X, p.Y, p.Z, n.X, n.Y, n.Z, uv.X, uv.Y })
		end
		table.insert(faces, face)
	end
	mesh:Destroy()
	local name = part.Name:gsub("_geom$", "")
	table.insert(parts, { name = name, faces = faces, cframe = { part.CFrame:GetComponents() } })
	local texture = AssetService:CreateEditableImageAsync(part.TextureContent)
	save("texture_" .. name, texture:ReadPixelsBuffer(Vector2.zero, texture.Size))
	table.insert(manifest.parts, { name = name, textureSize = { texture.Size.X, texture.Size.Y }, faces = #faces })
	texture:Destroy()
end
save("mesh", buffer.fromstring(HttpService:JSONEncode({ parts = parts })))
return HttpService:JSONEncode(manifest)
