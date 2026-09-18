-- Run in Studio Edit through execute_luau; only exports a generated draft.
local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")
local part = game.ServerStorage.Round3GenerationDrafts.FusionMachineDraft:FindFirstChildWhichIsA("MeshPart", true)
assert(part, "Draft mesh missing")
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
local encoding = game:GetService("EncodingService")
local folder = game.ServerStorage.Round3GenerationDrafts
local function save(name, data)
	local encoded = buffer.tostring(encoding:Base64Encode(encoding:CompressBuffer(data, Enum.CompressionAlgorithm.Zstd, 3)))
	local count = math.ceil(#encoded / 60000)
	for index = 1, count do
		local key = name .. index
		local chunk = folder:FindFirstChild(key) or Instance.new("StringValue")
		chunk.Name = key
		chunk.Parent = folder
		chunk.Value = encoded:sub((index - 1) * 60000 + 1, index * 60000)
	end
	return { length = #encoded, chunks = count }
end
local geometry = save("FusionMeshExport", buffer.fromstring(HttpService:JSONEncode({ faces = faces })))
local texture = AssetService:CreateEditableImageAsync(part.TextureContent)
local pixels = texture:ReadPixelsBuffer(Vector2.zero, texture.Size)
local textureData = save("FusionTextureExport", pixels)
local size = { texture.Size.X, texture.Size.Y }
texture:Destroy()
return HttpService:JSONEncode({ geometry = geometry, texture = textureData, size = size })
