-- Studio Client only: opens local UI panels and scrolls their lists without firing actions.
-- GetGuiObjectsAtPosition uses AbsolutePosition coordinates; add GuiInset only for screen bounds.

local pg=game.Players.LocalPlayer.PlayerGui
local frames=pg.MainUI.Frames
local view=workspace.CurrentCamera.ViewportSize
local inset=game.GuiService:GetGuiInset()
local results={}
local function shown(b)
 local n=b
 while n and n~=pg do
  if n:IsA("GuiObject") and not n.Visible then return false end
  if n:IsA("ScreenGui") and not n.Enabled then return false end
  n=n.Parent
 end
 return true
end
local function scan(panel)
 local r={panel=panel.Name, small={},unreachable={},blocked={},buttons=0}
 local pos=panel.AbsolutePosition+inset local size=panel.AbsoluteSize
 r.position={pos.X,pos.Y} r.size={size.X,size.Y}
 r.fits=pos.X>=-1 and pos.Y>=-1 and pos.X+size.X<=view.X+1 and pos.Y+size.Y<=view.Y+1
 local scrolls={}
 for _,d in panel:GetDescendants() do if d:IsA("ScrollingFrame") then scrolls[d]=d.CanvasPosition end end
 for _,b in panel:GetDescendants() do
  if not b:IsA("GuiButton") or not shown(b) then continue end
  r.buttons+=1
  local bs=b.AbsoluteSize
  if b.Active and math.min(bs.X,bs.Y)<43.9 then table.insert(r.small,{name=b:GetFullName(),size={bs.X,bs.Y}}) end
  if not b.Active then continue end
  local parents={} local n=b.Parent
  while n and n~=panel do
   if n:IsA("ScrollingFrame") then table.insert(parents,1,n) end
   n=n.Parent
  end
  for _,s in parents do
   local center=b.AbsolutePosition+b.AbsoluteSize/2
   local delta=center-(s.AbsolutePosition+s.AbsoluteWindowSize/2)
   local x=if s.ScrollingDirection==Enum.ScrollingDirection.Y then s.CanvasPosition.X else s.CanvasPosition.X+delta.X
   local y=if s.ScrollingDirection==Enum.ScrollingDirection.X then s.CanvasPosition.Y else s.CanvasPosition.Y+delta.Y
   s.CanvasPosition=Vector2.new(math.clamp(x,0,math.max(0,s.AbsoluteCanvasSize.X-s.AbsoluteWindowSize.X)),math.clamp(y,0,math.max(0,s.AbsoluteCanvasSize.Y-s.AbsoluteWindowSize.Y)))
   task.wait(.035)
  end
  local center=b.AbsolutePosition+b.AbsoluteSize/2
  local hits=pg:GetGuiObjectsAtPosition(center.X,center.Y)
  local found=false local obstruction=nil
  for _,h in hits do
   if h==b or h:IsDescendantOf(b) then found=true break end
   if h:IsA("GuiButton") and h.Active and not b:IsDescendantOf(h) then obstruction=h:GetFullName() break end
  end
  if not found then
   table.insert(if obstruction then r.blocked else r.unreachable,{name=b:GetFullName(),by=obstruction,center={center.X,center.Y}})
  end
 end
 for s,p in scrolls do s.CanvasPosition=p end
 table.insert(results,r)
end
for _,panel in frames:GetChildren() do
 if panel:IsA("Frame") then
  for _,f in frames:GetChildren() do if f:IsA("GuiObject") then f.Visible=f==panel end end
  task.wait(.5)
  scan(panel)
 end
end
return game.HttpService:JSONEncode({viewport={view.X,view.Y},panels=results})

