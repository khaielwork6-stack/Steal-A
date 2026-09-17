local pg=game.Players.LocalPlayer.PlayerGui
local old=pg:FindFirstChild("FinalItemsReview") if old then old:Destroy() end
local gui=Instance.new("ScreenGui") gui.Name="FinalItemsReview" gui.IgnoreGuiInset=true gui.DisplayOrder=10000 gui.Parent=pg
local bg=Instance.new("Frame") bg.Size=UDim2.fromScale(1,1) bg.BackgroundColor3=Color3.fromRGB(15,22,33) bg.Parent=gui
local function label(text,x,y,w,h,size)
 local t=Instance.new("TextLabel") t.Text=text;t.Position=UDim2.fromScale(x,y);t.Size=UDim2.fromScale(w,h);t.BackgroundTransparency=1;t.Font=Enum.Font.GothamBold;t.TextSize=size;t.TextColor3=Color3.fromRGB(242,238,224);t.Parent=bg
end
label("STEAL & RUN! · FINAL TWO MESHES",0,0.01,1,0.07,23)
local ids={"Grandma_CandyBowl","SecretLab_SecretFormula"}
local names={"Grandmas Cookies · Epic","Mutant Specimen · Epic"}
local preload={}
for row,id in ids do
 label(names[row],0.01,0.09+(row-1)*0.45,0.23,0.07,17)
 local source=game.ReplicatedStorage:WaitForChild("LootPreviews"):WaitForChild(id,20)
 for col,caption in {"FRONT","THREE-QUARTER","SILHOUETTE"} do
  local vp=Instance.new("ViewportFrame") vp.Size=UDim2.fromScale(0.27,0.34);vp.Position=UDim2.fromScale(0.12+(col-1)*0.285,0.16+(row-1)*0.45);vp.BackgroundColor3=Color3.fromRGB(37,49,65);vp.BorderSizePixel=0;vp.Parent=bg
  vp.Ambient=if col==3 then Color3.new() else Color3.fromRGB(165,165,175)
  vp.LightColor=if col==3 then Color3.new() else Color3.fromRGB(255,241,220);vp.LightDirection=Vector3.new(-0.5,-1,-0.5)
  local m=source:Clone()
  for _,d in m:GetDescendants() do
   if d:IsA("BasePart") then d.Anchored=true
    if col==3 then d.Color=Color3.new();d.Material=Enum.Material.SmoothPlastic;if d.Transparency<1 then d.Transparency=0 end;if d:IsA("MeshPart") then d.TextureID="" end end
   elseif col==3 and (d:IsA("SurfaceAppearance") or d:IsA("ParticleEmitter") or d:IsA("Light")) then d:Destroy() end
  end
  m:PivotTo(CFrame.identity);m.Parent=vp;table.insert(preload,m)
  local cf,sz=m:GetBoundingBox()
  local cam=Instance.new("Camera");cam.FieldOfView=35;cam.Parent=vp;vp.CurrentCamera=cam
  local dir=if col==2 then Vector3.new(1,0.35,1).Unit else Vector3.new(0,.12,1).Unit
  cam.CFrame=CFrame.lookAt(cf.Position+dir*(math.max(sz.X,sz.Y,sz.Z)*2.3),cf.Position)
  label(caption,0.12+(col-1)*0.285,0.12+(row-1)*0.45,0.27,0.035,11)
 end
end
game.ContentProvider:PreloadAsync(preload)
return "Final two review ready"
