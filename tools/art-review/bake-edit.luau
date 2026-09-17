
assert(not game:GetService("RunService"):IsRunning(),"Install only in Edit")
local rows=...
local ss=game:GetService("ServerStorage")
local sources=assert(ss:FindFirstChild("_ItemArtBakeSources"))
local loot=ss.GameAssets.Loot
local meshes={}
for _,p in sources:GetDescendants() do if p:IsA("MeshPart") then meshes[p.MeshId]=p end end
local function unpackValue(v)
 if type(v)~="table" or not v.t then return v end
 if v.t=="CFrame" then return CFrame.new(table.unpack(v.v)) elseif v.t=="Vector3" then return Vector3.new(table.unpack(v.v)) elseif v.t=="Vector2" then return Vector2.new(table.unpack(v.v)) elseif v.t=="Color3" then return Color3.new(table.unpack(v.v)) elseif v.t=="EnumItem" then return Enum[v.e][v.v] elseif v.t=="NumberRange" then return NumberRange.new(table.unpack(v.v)) elseif v.t=="NumberSequence" then local a={} for _,k in v.v do table.insert(a,NumberSequenceKeypoint.new(table.unpack(k))) end return NumberSequence.new(a) elseif v.t=="ColorSequence" then local a={} for _,k in v.v do table.insert(a,ColorSequenceKeypoint.new(k[1],Color3.new(k[2],k[3],k[4]))) end return ColorSequence.new(a) end error(v.t)
end
local function attributes(obj,attrs) for key in obj:GetAttributes() do obj:SetAttribute(key,nil) end for key,v in attrs do obj:SetAttribute(key,v) end end
local installed={}
for _,r in rows do
 local m=Instance.new("Model") m.Name=r.id attributes(m,r.attributes)
 for _,p in r.parts do
  local part
  if p.mesh then part=assert(meshes[p.mesh],"Missing inserted mesh "..p.mesh):Clone()
  else part=Instance.new(p.class) end
  for _,d in part:GetChildren() do if not(p.keepSurface and d:IsA("SurfaceAppearance")) then d:Destroy() end end
  part.Name=p.name attributes(part,p.attributes)
  for key,v in p.properties do part[key]=unpackValue(v) end
  part.Anchored=false part.CanCollide=false part.CanTouch=false part.CanQuery=false part.Parent=m
  for _,e in p.effects do
   local parent=part if e.attachment then parent=Instance.new("Attachment") parent.CFrame=unpackValue(e.attachment) parent.Parent=part end
   local em=Instance.new("ParticleEmitter") for key,v in e.properties do em[key]=unpackValue(v) end attributes(em,e.attributes) em.Parent=parent
  end
 end
 m.PrimaryPart=assert(m:FindFirstChild(r.primary)) 
 for _,p in m:GetChildren() do if p:IsA("BasePart") and p~=m.PrimaryPart then local w=Instance.new("WeldConstraint") w.Name="ItemArtWeld" w.Part0=m.PrimaryPart w.Part1=p w.Parent=m.PrimaryPart end end
 local previous=loot:FindFirstChild(r.id)
 if previous then
  if not previous:GetAttribute("ProceduralItemArt") then
   local backup=loot:FindFirstChild("_OriginalArt") if not backup then backup=Instance.new("Folder") backup.Name="_OriginalArt" backup.Parent=loot end
   if backup:FindFirstChild(r.id) then previous:Destroy() else previous.Parent=backup end
  else previous:Destroy() end
 end
 m.Parent=loot table.insert(installed,r.id)
end
return installed
