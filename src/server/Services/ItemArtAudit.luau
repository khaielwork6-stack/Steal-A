--!strict
-- Read-only integration checks for authored art. Temporary clones are never
-- parented into the world and no player/profile state is changed.
local RS = game:GetService("ReplicatedStorage")
local LootConfig = require(RS.Shared.Config.LootConfig)
local LootModel = require(RS.Shared.Util.LootModel)
local MutationVfx = require(RS.Shared.Util.MutationVfx)
local SizeAura = require(RS.Shared.Util.SizeAura)
local RarityConfig = require(RS.Shared.Config.RarityConfig)
local Audit = {}
function Audit.run()
 local failures, oldArt = {}, {}
 local checks, generated, maximumParts, scaleBuilds, effectBuilds = 0,0,0,0,0
 local function check(ok: boolean, message: string)
  checks += 1
  if not ok then table.insert(failures,message) end
 end
 local loot = game:GetService("ServerStorage").GameAssets.Loot
 for zone=1,12 do
  for _,def in LootConfig.pool(zone) do
   local source = loot:FindFirstChild(LootConfig.modelNameFor(def.id))
   if not source or not source:GetAttribute("ProceduralItemArt") then
    table.insert(oldArt,def.id)
    continue
   end
   generated += 1
   check(source:IsA("Model"),def.id..": not a Model")
   if not source:IsA("Model") then continue end
   local primary=source.PrimaryPart
   check(primary~=nil and source:GetPivot().UpVector.Y>0.9999,def.id..": pivot")
   local count,emitters,meshes=0,0,0
   local welded: {[BasePart]: boolean}={}
   for _,v in source:GetDescendants() do
    if v:IsA("WeldConstraint") and v.Part0==primary and v.Part1 then welded[v.Part1]=true end
   end
   for _,v in source:GetDescendants() do
    if v:IsA("BasePart") then
     count+=1
     if v:IsA("MeshPart") then meshes+=1 end
     check(not v.Anchored and not v.CanCollide,def.id..": physics "..v.Name)
     check(v.PivotOffset==CFrame.identity,def.id..": PivotOffset "..v.Name)
     check(v==primary or welded[v]==true,def.id..": unwelded "..v.Name)
    elseif v:IsA("ParticleEmitter") then emitters+=1
    elseif v:IsA("LuaSourceContainer") or v:IsA("Tool") or v:IsA("Accessory") or v:IsA("Humanoid") or v:IsA("Seat") or v:IsA("Beam") or v:IsA("Trail") then
     check(false,def.id..": forbidden "..v.ClassName)
    end
   end
   maximumParts=math.max(maximumParts,count)
   check(meshes>0 and count<=40,def.id..": part budget or missing mesh")
   check(count==source:GetAttribute("ItemArtPartCount"),def.id..": readiness count")
   check(emitters<=1,def.id..": emitter budget")
   local lower=def.rarity=="Common" or def.rarity=="Uncommon" or def.rarity=="Rare" or def.rarity=="Epic" or def.rarity=="Legendary"
   check(not lower or emitters==0,def.id..": low-tier emitter")
   local preview=RS.LootPreviews:FindFirstChild(def.id)
   check(preview~=nil,def.id..": missing preview")
   local min,max=LootModel.visibleExtents(source)
   check(min~=nil and math.abs((min :: Vector3).Y)<0.02,def.id..": authored foot")
   local normalSize: Vector3?=nil
   for _,scale in {1,1.5,3,6,10,20} do
    local model,real=LootModel.build({itemId=def.id,rarity=def.rarity,targetHeight=5,sizeScale=scale})
    scaleBuilds+=1
    check(real and model.PrimaryPart~=nil,def.id..": build scale "..scale)
    model:PivotTo(CFrame.identity)
    local lo,hi=LootModel.visibleExtents(model)
    if lo and hi then
     local size=hi-lo
     if scale==1 then normalSize=size else
      check(normalSize~=nil and (size-(normalSize :: Vector3)*scale).Magnitude<0.05,def.id..": scale applied incorrectly "..scale)
     end
    else check(false,def.id..": empty build") end
    check(model:GetPivot().UpVector.Y>0.9999,def.id..": built upright")
    if scale==1 then
     for mutation in RarityConfig.MutationColors do
      check(MutationVfx.apply(model,mutation),def.id..": mutation "..mutation)
      MutationVfx.clear(model); effectBuilds+=1
     end
    else
     local labels={[1.5]="Big",[3]="Huge",[6]="Giant",[10]="Titan",[20]="Colossal"}
     check(SizeAura.apply(model,labels[scale]),def.id..": aura "..labels[scale])
     SizeAura.clear(model); effectBuilds+=1
    end
    model:Destroy()
   end
  end
 end
 return {checks=checks,generated=generated,oldArt=oldArt,maximumParts=maximumParts,scaleBuilds=scaleBuilds,effectBuilds=effectBuilds,failures=failures}
end
return Audit
