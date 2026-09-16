-- Studio MCP client-only review sheet; no profile changes. Remove ArtZoneReview
-- from PlayerGui to close. Pass the zone index as the chunk's first argument.
local zone, defs = ...
assert(zone and defs, "Pass zone index and the eight item metadata rows")
local RS = game:GetService("ReplicatedStorage")
local colors={Common=Color3.fromRGB(198,205,216),Uncommon=Color3.fromRGB(96,220,118),Rare=Color3.fromRGB(74,156,255),Epic=Color3.fromRGB(180,106,255),Legendary=Color3.fromRGB(255,178,46),Mythic=Color3.fromRGB(255,95,161),Cosmic=Color3.fromRGB(125,120,255),Secret=Color3.fromRGB(125,255,82),Eternal=Color3.fromRGB(255,236,167),Divine=Color3.new(1,1,1)}
local pg = game.Players.LocalPlayer.PlayerGui
local old = pg:FindFirstChild("ArtZoneReview")
if old then old:Destroy() end
local gui = Instance.new("ScreenGui")
gui.Name, gui.DisplayOrder, gui.IgnoreGuiInset = "ArtZoneReview", 10000, true
gui.Parent = pg
local bg = Instance.new("Frame")
bg.Size, bg.BackgroundColor3, bg.BorderSizePixel = UDim2.fromScale(1,1), Color3.fromRGB(14,22,34), 0
bg.Parent = gui
local function label(parent, text, x, y, w, h, size, color)
 local t=Instance.new("TextLabel")
 t.BackgroundTransparency=1; t.Size=UDim2.fromScale(w,h); t.Position=UDim2.fromScale(x,y)
 t.Text=text; t.TextSize=size; t.Font=Enum.Font.GothamBold; t.TextColor3=color or Color3.fromRGB(240,235,225)
 t.TextWrapped=true; t.Parent=parent
 return t
end
label(bg, string.format("STEAL & RUN!  /  ZONE %02d",zone),0,0.025,1,0.06,24)
label(bg,"Generated meshes · front views and black silhouettes · actual Roblox assets",0,0.09,1,0.04,13,Color3.fromRGB(170,185,205))
local preload={}
for i,def in defs do
 local x=0.014+(i-1)*0.122
 local card=Instance.new("Frame"); card.Size=UDim2.fromScale(0.116,0.80); card.Position=UDim2.fromScale(x,0.155)
 card.BackgroundColor3=Color3.fromRGB(36,49,65); card.BorderSizePixel=0; card.Parent=bg
 local corner=Instance.new("UICorner"); corner.CornerRadius=UDim.new(0,10); corner.Parent=card
 label(card,def.rarity:upper(),0,0.02,1,0.05,12,colors[def.rarity])
 label(card,def.name,0.04,0.52,0.92,0.09,14)
 local source=RS.LootPreviews:FindFirstChild(def.id)
 assert(source,def.id.." missing preview")
 for row=1,2 do
  local vp=Instance.new("ViewportFrame"); vp.BackgroundTransparency=1; vp.BorderSizePixel=0
  vp.Size=UDim2.fromScale(0.94,if row==1 then 0.44 else 0.30)
  vp.Position=UDim2.fromScale(0.03,if row==1 then 0.08 else 0.65); vp.Parent=card
  vp.Ambient=if row==1 then Color3.fromRGB(150,150,165) else Color3.new()
  vp.LightColor=if row==1 then Color3.fromRGB(255,244,225) else Color3.new()
  vp.LightDirection=Vector3.new(-0.6,-1,-0.8)
  local model=source:Clone()
  for _,p in model:GetDescendants() do
   if p:IsA("BasePart") then
    p.Anchored=true
    if row==2 then p.Color=Color3.new(); p.Material=Enum.Material.SmoothPlastic; p.Transparency=0 end
   elseif row==2 and (p:IsA("SurfaceAppearance") or p:IsA("Decal") or p:IsA("Texture") or p:IsA("ParticleEmitter") or p:IsA("Light")) then p:Destroy() end
  end
  model:PivotTo(CFrame.identity); model.Parent=vp; table.insert(preload,model)
  local cf,sz=model:GetBoundingBox(); local center=cf.Position
  local camera=Instance.new("Camera"); camera.FieldOfView=35; camera.Parent=vp; vp.CurrentCamera=camera
  -- Review direction is front-facing; yaw metadata is visual only, never a save key.
  local yaw=def.yaw or 0
  local direction=CFrame.Angles(0,math.rad(yaw),0):VectorToWorldSpace(Vector3.new(0,0.12,1).Unit)
  local pixels=vp.AbsoluteSize
  local aspect=math.max(pixels.X/math.max(pixels.Y,1),0.1)
  local distance=(math.max(sz.Y,math.max(sz.X,sz.Z)/aspect)*0.5/math.tan(math.rad(17.5))+math.max(sz.X,sz.Z)*0.5)*1.12
  camera.CFrame=CFrame.lookAt(center+direction*distance,center)
 end
end
game:GetService("ContentProvider"):PreloadAsync(preload)
return "Zone sheet ready"
