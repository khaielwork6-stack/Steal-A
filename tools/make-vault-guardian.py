"""Author a script-free R15 vault security costume with articulated armor."""
import importlib.util
import json
from pathlib import Path

spec=importlib.util.spec_from_file_location("props",Path(__file__).with_name("make-round3-props.py"))
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
m=p.model("VaultGuardian","ServerStorage.GameAssets.Guardians.VaultGuardian")
m["parts"][0].update(name="HumanoidRootPart",size=(2,2,1),position=(0,3,0))
m.update(humanoid=True,hipHeight=2,joints=[])

def body(name,size,pos,color=p.NAVY):return p.part(m,name,size,pos,color,"metal")
def joint(name,parent,child,pos,kind="Motor6D"):
    m["joints"].append({"name":name,"parent":parent,"child":child,"position":pos,"kind":kind})
def armor(parent,name,size,pos,color=p.STEEL,shape="block",material="metal"):
    part=p.part(m,name,size,pos,color,material,shape);joint(name+"Weld",parent,name,pos,"Weld");return part

body("LowerTorso",(1.8,.9,1),(0,3.1,0));body("UpperTorso",(2.3,1.7,1.2),(0,4.3,0))
body("Head",(1.45,1.35,1.35),(0,5.83,0))
joint("Root","HumanoidRootPart","LowerTorso",(0,3,0));joint("Waist","LowerTorso","UpperTorso",(0,3.5,0));joint("Neck","UpperTorso","Head",(0,5.2,0))
for side,sign in (("Left",-1),("Right",1)):
    x=sign*1.65
    body(side+"UpperArm",(.85,1.3,1),(x,4.2,0));body(side+"LowerArm",(.8,1.1,.9),(x,3.12,0));body(side+"Hand",(.85,.55,.95),(x,2.38,0))
    joint(side+"Shoulder","UpperTorso",side+"UpperArm",(sign*1.2,4.8,0));joint(side+"Elbow",side+"UpperArm",side+"LowerArm",(x,3.55,0));joint(side+"Wrist",side+"LowerArm",side+"Hand",(x,2.58,0))
    x=sign*.55
    body(side+"UpperLeg",(.92,1.3,1),(x,2.22,0));body(side+"LowerLeg",(.9,1.05,.95),(x,1.17,0));body(side+"Foot",(1,.55,1.45),(x,.35,-.22))
    joint(side+"Hip","LowerTorso",side+"UpperLeg",(x,2.85,0));joint(side+"Knee",side+"UpperLeg",side+"LowerLeg",(x,1.6,0));joint(side+"Ankle",side+"LowerLeg",side+"Foot",(x,.65,-.1))
    armor(side+"UpperArm",side+"ShoulderPlate",(1.2,.65,1.35),(sign*1.65,4.7,0),p.STEEL,"ball")
    armor(side+"UpperArm",side+"GoldEpaulet",(1.05,.14,1.2),(sign*1.65,4.97,0),p.GOLD)
    armor(side+"LowerLeg",side+"ShinPlate",(.7,.85,.15),(x,1.2,-.56))
armor("Head","Helmet",(1.72,1.65,1.62),(0,5.95,0),p.STEEL,"ball")
armor("Head","VisorPlate",(1.45,.46,.18),(0,5.91,-.8),p.NAVY)
armor("Head","RedVisor",(1.24,.13,.12),(0,5.95,-.94),(255,53,45),material="neon")
armor("UpperTorso","ChestPlate",(1.95,1.05,.2),(0,4.4,-.72),p.STEEL)
armor("UpperTorso","GoldBadge",(.35,.45,.15),(-.55,4.56,-.89),p.GOLD)
armor("LowerTorso","GoldBelt",(1.95,.15,1.1),(0,3.2,0),p.GOLD)
armor("LowerTorso","KeyRing",(.5,.5,.1),(.9,2.8,-.64),p.GOLD,"ball")
for i in range(3):armor("LowerTorso","Key"+str(i),(.09,.55,.1),(.68+i*.17,2.44,-.64),p.GOLD)
armor("RightHand","Baton",(.22,1.9,.22),(1.65,2.45,-.65))
armor("RightHand","BatonGrip",(.32,.6,.32),(1.65,2.05,-.65),p.NAVY)
p.OUT.mkdir(parents=True,exist_ok=True);p.write_model(m)
(p.OUT/"vault-guardian-source.json").write_text(json.dumps(m,indent=2)+"\n")
print(json.dumps({"parts":len(m["parts"]),"joints":len(m["joints"]),"file":"VaultGuardian.rbxmx"}))
