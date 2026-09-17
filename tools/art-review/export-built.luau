local function pack(v)
 local t=typeof(v)
 if t=="Vector3" then return {t=t,v={v.X,v.Y,v.Z}} elseif t=="Vector2" then return {t=t,v={v.X,v.Y}} elseif t=="Color3" then return {t=t,v={v.R,v.G,v.B}} elseif t=="CFrame" then return {t=t,v={v:GetComponents()}} elseif t=="EnumItem" then return {t=t,e=tostring(v.EnumType):gsub("Enum.",""),v=v.Name} elseif t=="NumberRange" then return {t=t,v={v.Min,v.Max}} elseif t=="NumberSequence" then local a={} for _,k in v.Keypoints do table.insert(a,{k.Time,k.Value,k.Envelope}) end return {t=t,v=a} elseif t=="ColorSequence" then local a={} for _,k in v.Keypoints do table.insert(a,{k.Time,k.Value.R,k.Value.G,k.Value.B}) end return {t=t,v=a} end return v
end
local out={}
for _,m in game.ServerStorage.GameAssets.Loot:GetChildren() do if m:IsA("Model") and m:GetAttribute("ProceduralItemArt")==1 then
 local row={id=m.Name,attributes=m:GetAttributes(),primary=m.PrimaryPart.Name,parts={}}
 for _,p in m:GetChildren() do if p:IsA("BasePart") then
  local r={name=p.Name,class=p.ClassName,attributes=p:GetAttributes(),properties={},effects={}}
  for _,key in {"Size","CFrame","Color","Material","Transparency","Reflectance","CastShadow","Massless","PivotOffset"} do r.properties[key]=pack(p[key]) end
  if p:IsA("MeshPart") then r.mesh=p.MeshId;r.properties.TextureID=p.TextureID;r.keepSurface=p:FindFirstChildWhichIsA("SurfaceAppearance")~=nil elseif p:IsA("Part") then r.properties.Shape=pack(p.Shape) end
  for _,d in p:GetDescendants() do if d:IsA("ParticleEmitter") then
   local e={attributes=d:GetAttributes(),properties={}}
   for _,key in {"Texture","Rate","Lifetime","Speed","SpreadAngle","LightEmission","LightInfluence","Color","Size","Transparency","Rotation","RotSpeed","Acceleration","Drag","VelocityInheritance","Enabled","ZOffset","EmissionDirection","Orientation"} do e.properties[key]=pack(d[key]) end
   if d.Parent:IsA("Attachment") then e.attachment=pack(d.Parent.CFrame) end
   table.insert(r.effects,e)
  end end
  table.insert(row.parts,r)
 end end
 table.insert(out,row)
end end return game.HttpService:JSONEncode(out)
