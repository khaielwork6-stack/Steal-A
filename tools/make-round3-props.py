"""Author bounded decorative models; no gameplay scripts or map changes."""
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "art/round3/models/Authored"
MATERIALS = {"plastic":272,"metal":1088,"glass":1568,"wood":512,"marble":784,"neon":288,"slate":800,"granite":832}
NAVY=(24,31,58); GOLD=(237,180,53); STEEL=(83,99,120); CYAN=(55,224,255); WHITE=(235,241,244)
models=[]


def model(name, destination):
    result={"name":name,"destination":destination,"parts":[]}
    models.append(result)
    part(result,"Origin",(.1,.1,.1),(0,0,0),NAVY,alpha=1)
    return result


def part(m,name,size,pos,color,material="plastic",shape="block",rot=(0,0,0),alpha=0):
    p={"name":name,"size":size,"position":pos,"color":color,"material":material,"shape":shape,"rotation":rot,"transparency":alpha}
    m["parts"].append(p)
    return p


def cylinder(m,name,radius,height,pos,color,material="metal"):
    return part(m,name,(height,radius*2,radius*2),pos,color,material,"cylinder",(0,0,90))


def ball(m,name,size,pos,color,material="plastic",alpha=0):
    return part(m,name,size,pos,color,material,"ball",alpha=alpha)


def ring(m,name,radius,y,color,thickness=.12):
    # A shallow broad cylinder reads as a polished collar at this scale.
    return cylinder(m,name,radius,thickness,(0,y,0),color)


def make_themes():
    dest="ServerStorage.GameAssets.ThemeDecor."
    m=model("SunsetLantern",dest+"SunsetLantern")
    cylinder(m,"Foot",.45,.18,(0,.09,0),NAVY)
    ball(m,"PaperGlobe",(1.8,2,1.8),(0,1.35,0),(255,140,55),"neon")
    for i in range(7):ring(m,"PaperRib"+str(i),.9*math.sqrt(max(.08,1-((i-3)/3.5)**2)),.5+i*.28,(200,86,27),.045)
    ring(m,"TopCap",.38,2.38,GOLD);ring(m,"LowerCap",.4,.36,GOLD)
    part(m,"Finial",(.14,.35,.14),(0,2.56,0),GOLD)
    m["parts"][2]["light"]={"color":(255,151,56),"range":10,"brightness":.6}
    m=model("MidnightBeacon",dest+"MidnightBeacon")
    cylinder(m,"Plinth",.65,.3,(0,.15,0),NAVY);cylinder(m,"Stem",.35,1.5,(0,1,0),STEEL)
    for y in (.5,1.35,1.65):cylinder(m,"LightCollar",.52,.15,(0,y,0),CYAN,"neon")
    ball(m,"Lens",(.9,.5,.9),(0,1.95,0),CYAN,"glass",.25)
    cylinder(m,"Cap",.55,.15,(0,2.25,0),NAVY)
    for name,color in (("MidnightOrb",CYAN),("NeonOrb",(242,63,246))):
        m=model(name,dest+name);cylinder(m,"Base",.62,.18,(0,.09,0),NAVY)
        cylinder(m,"Stem",.1,.9,(0,.62,0),GOLD)
        ball(m,"Glass",(1.55,1.55,1.55),(0,1.68,0),color,"glass",.55)
        ball(m,"Core",(.73,.73,.73),(0,1.68,0),color,"neon")
        for j in range(4):
            angle=j*math.pi/2;ball(m,"OrbitStud",(.18,.18,.18),(.81*math.cos(angle),1.68,.81*math.sin(angle)),GOLD,"metal")
    m=model("JungleTotem",dest+"JungleTotem")
    part(m,"Foot",(1.65,.35,1.45),(0,.175,0),(70,89,73),"slate")
    part(m,"CarvedStone",(1.22,2.3,1.05),(0,1.48,0),(112,131,104),"slate")
    part(m,"Brow",(1.45,.26,1.23),(0,2.35,-.05),(57,74,58),"slate")
    for x in (-.34,.34):part(m,"Eye",(.3,.22,.08),(x,1.94,-.565),(163,230,129),"neon")
    part(m,"Nose",(.26,.4,.32),(0,1.63,-.65),(74,90,72),"slate")
    part(m,"Mouth",(.62,.11,.1),(0,1.25,-.57),NAVY)
    for j in range(5):ball(m,"Moss",(.48,.2,.43),(-.5+j*.23,2.67,.14*math.sin(j)),(48,113,53))
    m=model("JungleBush",dest+"JungleBush")
    cylinder(m,"WoodCore",.18,1,(0,.5,0),(90,64,41),"wood")
    for j in range(9):
        a=j*2.4;r=.65 if j else 0
        ball(m,"LeafCluster",(1.1,1.1,1.1),(r*math.cos(a),.95+.32*(j%3),r*math.sin(a)),(38+j*4,107+j*7,49+j*3))
    for x in (-.6,.6):part(m,"TrailingVine",(.13,1,.13),(x,.65,-.35),(34,89,41),"wood",rot=(0,0,x*18))
    m=model("FrostCrystal",dest+"FrostCrystal")
    for j,(x,z,h) in enumerate(((0,0,3.4),(-.62,.12,2.4),(.55,.32,2),(.12,-.55,1.7))):
        part(m,"IceShaft",(.55,h-.5,.55),(x,(h-.5)/2,z),(128+j*15,214+j*7,250),"glass",rot=(0,j*35,0),alpha=.17)
        part(m,"IcePoint",(.55,.65,.55),(x,h-.42,z),(183,241,255),"glass","wedge",(0,j*35,0),.12)
    m=model("LavaBrazier",dest+"LavaBrazier")
    cylinder(m,"Foot",.63,.22,(0,.11,0),NAVY);cylinder(m,"Pedestal",.28,1,(0,.7,0),STEEL)
    ball(m,"IronBowl",(1.8,.75,1.8),(0,1.38,0),NAVY,"metal")
    cylinder(m,"MoltenPool",.75,.12,(0,1.7,0),(255,102,22),"neon")
    m["parts"][-1]["light"]={"color":(255,115,28),"range":10,"brightness":.6}
    for j in range(5):
        a=j*math.pi*.4;part(m,"BowlClaw",(.15,.65,.15),(.77*math.cos(a),1.73,.77*math.sin(a)),GOLD,"metal")
    m=model("RoyalCrown",dest+"RoyalCrown")
    cylinder(m,"VelvetBase",.8,.42,(0,.3,0),(85,26,85));ring(m,"GoldBand",.9,.45,GOLD,.28)
    for j in range(5):
        a=j*2*math.pi/5;x,z=.7*math.cos(a),.7*math.sin(a)
        part(m,"CrownPoint",(.3,1.1,.26),(x,.98,z),GOLD,"metal","wedge",(0,-j*72,0))
        ball(m,"TipJewel",(.25,.25,.25),(x,1.55,z),(54,218,242),"neon")
    m=model("RoyalUrn",dest+"RoyalUrn")
    cylinder(m,"Foot",.56,.2,(0,.1,0),GOLD);cylinder(m,"Stem",.2,.4,(0,.4,0),WHITE,"marble")
    ball(m,"MarbleBody",(1.55,1.75,1.35),(0,1.37,0),WHITE,"marble")
    cylinder(m,"Neck",.4,.45,(0,2.26,0),WHITE,"marble");ring(m,"Lip",.57,2.5,GOLD,.18)
    for x in (-.85,.85):ball(m,"GoldHandle",(.35,1,.3),(x,1.67,0),GOLD,"metal")


def make_vault():
    m=model("VaultDoor","ServerStorage.GameAssets.Vault.VaultDoor")
    def disc(name,radius,depth,z,color):return part(m,name,(depth,2*radius,2*radius),(0,0,z),color,"metal","cylinder",(0,90,0))
    disc("GoldRim",13,2.7,0,GOLD);disc("SteelFace",11.9,2.85,-.05,STEEL);disc("InsetFace",10.8,2.95,-.1,NAVY)
    for j in range(8):
        a=j*math.pi/4;part(m,"Bolt",(.48,1.2,1.2),(11.25*math.cos(a),11.25*math.sin(a),-1.65),GOLD,"metal","cylinder",(0,90,0))
    disc("Hub",2.1,3.7,-.45,GOLD);disc("HubInset",1.6,3.8,-.5,STEEL)
    for j in range(3):
        a=j*2*math.pi/3;part(m,"WheelSpoke",(6,.55,.55),(3*math.cos(a),3*math.sin(a),-2.65),GOLD,"metal",rot=(0,0,j*120))
        ball(m,"WheelGrip",(1,1,1),(6*math.cos(a),6*math.sin(a),-2.65),GOLD,"metal")
    for x in (-6,6):part(m,"FaceBrace",(.65,13,.24),(x,0,-1.7),STEEL,"metal")
    m=model("VaultDecor","ServerStorage.GameAssets.Vault.VaultDecor")
    for sign in (-1,1):
        x=sign*14
        part(m,"Pallet",(2.6,.3,4),(x,.15,14),NAVY,"wood")
        for row in range(2):
            for col in range(2):part(m,"GoldBullion",(1.1,.5,1.1),(x+(row-.5)*1.2,.6+row*.48,13+(col-.5)*1.2),GOLD,"metal")
        for z in (8,49):
            part(m,"DepositPanel",(.25,5,5.8),(sign*15.35,6,z),STEEL,"metal")
            for row in range(2):
                for col in range(2):
                    part(m,"SafeDoor",(.18,2.1,2.45),(sign*15.18,4.8+row*2.4,z-1.35+col*2.7),NAVY,"metal")
                    part(m,"SafeHandle",(.28,.13,.65),(sign*15.02,4.8+row*2.4,z-1.35+col*2.7),GOLD,"metal")
        for k in range(2):
            ball(m,"MoneyBag",(1.25,1.9,1.35),(x+(k-.5)*1.2,.95,54),(160,127,72))
            cylinder(m,"BagTie",.22,.2,(x+(k-.5)*1.2,1.9,54),GOLD)
        part(m,"SteelPlate",(.22,6,5),(sign*15.38,5,25),STEEL,"metal")
        ball(m,"AlarmBeacon",(.7,1.1,.7),(sign*15,10,25),(245,48,40),"glass")
    assert len(m["parts"]) <= 60


def make_fusion():
    m=model("FusionMachine","ServerStorage.GameAssets.Props.FusionMachine")
    part(m,"Foundation",(12,.65,12),(0,.325,0),NAVY,"metal")
    part(m,"FrontTrim",(11.5,.16,.15),(0,.7,-5.8),CYAN,"neon")
    core=part(m,"Chamber",(4.2,8,3.6),(0,4.7,1.8),WHITE)
    core["mesh"]={"id":"119080625621647","texture":"74397465322379","scale":[8/1.9192166328430176]*3}
    core["attachment"]={"name":"Core","position":(0,.6,0)}
    for index,x in enumerate((-4,0,4)):
        cylinder(m,"InputFoot",1,.3,(x,.85,-3.7),GOLD)
        tube=cylinder(m,"InputGlass",.79,3.7,(x,2.85,-3.7),CYAN,"glass");tube["transparency"]=.55
        cylinder(m,"InputFluid",.52,2.5,(x,2.3,-3.7),[(79,229,255),(211,102,255),(122,245,156)][index],"neon")
        cylinder(m,"InputCap",1,.3,(x,4.85,-3.7),GOLD)
        part(m,"Conduit",(.22,.22,4.4),(x,.95,-1.45),CYAN,"neon")
        part(m,"ConduitRiser",(.22,2,.22),(x,1.95,.72),CYAN,"neon")
    for x in (-5.45,5.45):
        part(m,"OuterPylon",(.55,5,.55),(x,3,2.8),STEEL,"metal")
        ball(m,"PowerNode",(.8,.8,.8),(x,5.6,2.8),CYAN,"neon")


def tag(parent,kind,name,value):
    node=ET.SubElement(parent,kind,{"name":name});node.text=str(value);return node


def vector(parent,name,values,kind="Vector3",axes=("X","Y","Z")):
    node=ET.SubElement(parent,kind,{"name":name})
    for key,value in zip(axes,values):ET.SubElement(node,key).text=str(value)


def cframe(parent,name,pos,rot):
    a,b,c=map(math.radians,rot);ca,sa,cb,sb,cc,sc=math.cos(a),math.sin(a),math.cos(b),math.sin(b),math.cos(c),math.sin(c)
    values=[*pos,cb*cc,-cb*sc,sb,ca*sc+sa*sb*cc,ca*cc-sa*sb*sc,-sa*cb,sa*sc-ca*sb*cc,sa*cc+ca*sb*sc,ca*cb]
    vector(parent,name,values,"CoordinateFrame",("X","Y","Z","R00","R01","R02","R10","R11","R12","R20","R21","R22"))


def item(parent,kind,name,ref=None):
    node=ET.SubElement(parent,"Item",{"class":kind,**({"referent":ref} if ref else {})});props=ET.SubElement(node,"Properties");tag(props,"string","Name",name);return node,props


def write_model(m):
    root=ET.Element("roblox",{"version":"4"});node,props=item(root,"Model",m["name"])
    tag(props,"Ref","PrimaryPart","P0")
    part_nodes={}
    for index,p in enumerate(m["parts"]):
        part_node,props=item(node,"WedgePart" if p["shape"]=="wedge" else "Part",p["name"],"P"+str(index))
        part_nodes[p["name"]]=(part_node,"P"+str(index),p)
        vector(props,"size",p["size"]);cframe(props,"CFrame",p["position"],p["rotation"])
        red,green,blue=p["color"]
        tag(props,"Color3uint8","Color3uint8",(red<<16)|(green<<8)|blue)
        tag(props,"token","Material",MATERIALS[p["material"]]);tag(props,"float","Transparency",p["transparency"])
        for flag,val in (("Anchored",not m.get("humanoid") or index==0),("CanCollide",False),("CanTouch",False),("CanQuery",False),("CastShadow",False),("Massless",bool(m.get("humanoid")))):
            tag(props,"bool",flag,str(val).lower())
        if p["shape"]!="wedge":tag(props,"token","shape",{"block":1,"ball":0,"cylinder":2}[p["shape"]])
        for surface in ("TopSurface","BottomSurface"):tag(props,"token",surface,0)
        if "light" in p:
            light=p["light"];_,lp=item(part_node,"PointLight","WarmGlow")
            vector(lp,"Color",[c/255 for c in light["color"]],"Color3",("R","G","B"));tag(lp,"float","Range",light["range"]);tag(lp,"float","Brightness",light["brightness"]);tag(lp,"bool","Shadows","false")
        if "mesh" in p:
            mesh=p["mesh"];_,mp=item(part_node,"SpecialMesh","PublishedCore");tag(mp,"token","MeshType",5)
            for key,value in (("MeshId",mesh["id"]),("TextureId",mesh["texture"])):
                content=ET.SubElement(mp,"Content",{"name":key});ET.SubElement(content,"url").text="rbxassetid://"+value
            vector(mp,"Scale",mesh["scale"])
        if "attachment" in p:
            attachment=p["attachment"];_,ap=item(part_node,"Attachment",attachment["name"]);cframe(ap,"CFrame",attachment["position"],(0,0,0))
    if m.get("humanoid"):
        humanoid,hp=item(node,"Humanoid","Humanoid")
        tag(hp,"token","RigType",1);tag(hp,"bool","RequiresNeck","false")
        tag(hp,"float","HipHeight",m.get("hipHeight",2));tag(hp,"float","MaxHealth",100);tag(hp,"float","Health",100)
        item(humanoid,"Animator","Animator")
    for joint in m.get("joints",[]):
        parent,pref,pp=part_nodes[joint["parent"]];_,cref,cp=part_nodes[joint["child"]]
        _,jp=item(parent,joint.get("kind","Motor6D"),joint["name"])
        tag(jp,"Ref","Part0",pref);tag(jp,"Ref","Part1",cref)
        for key,part_spec in (("C0",pp),("C1",cp)):
            if key in joint:
                vector(jp,key,joint[key],"CoordinateFrame",("X","Y","Z","R00","R01","R02","R10","R11","R12","R20","R21","R22"))
            else:
                cframe(jp,key,[joint["position"][i]-part_spec["position"][i] for i in range(3)],(0,0,0))
    ET.indent(root,space="  ");ET.ElementTree(root).write(OUT/(m["name"]+".rbxmx"),encoding="utf-8",xml_declaration=True)


if __name__=="__main__":
    OUT.mkdir(parents=True,exist_ok=True);make_themes();make_vault();make_fusion()
    for m in models:write_model(m)
    (OUT/"prop-sources.json").write_text(json.dumps(models,indent=2)+"\n")
    print(json.dumps([{ "name":m["name"],"parts":len(m["parts"])} for m in models]))
